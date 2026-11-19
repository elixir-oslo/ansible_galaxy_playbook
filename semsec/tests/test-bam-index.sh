#!/bin/bash
# Protected BWA-MEM on encrypted hg38 chr21 reads, then samtools idxstats on the protected BAM,
# which reads the BAM index Galaxy stored encrypted with it.
# Reads the Galaxy API key from stdin. Needs devteam/bwa and devteam/samtools_idxstats installed.
set -euo pipefail
read -r KEY
G=https://semsec-galaxy:8080
export CURL_CA_BUNDLE=$HOME/semsec-pki/ca.pem
BWA=toolshed.g2.bx.psu.edu/repos/devteam/bwa/bwa_mem/0.7.19+galaxy2
IDX=toolshed.g2.bx.psu.edu/repos/devteam/samtools_idxstats/samtools_idxstats/2.0.8
USER_SVC='sudo -u recryptor bash -c "cd /srv/recryptor/usertest && export HOME=/srv/recryptor PATH=/usr/local/bin:/usr/bin:/bin && uvx -q crypt4gh'
api() { curl -sS -f -X "$1" -H "x-api-key: $KEY" -H content-type:application/json ${3:+-d "$3"} "$G$2"; }
wait_job() { for _ in $(seq 1 360); do s=$(api GET /api/jobs/$1 | jq -r .state); case $s in ok|error|failed|deleted) echo $s; return;; esac; sleep 5; done; echo timeout; }
run_tool() { api POST /api/tools "$(jq -n --arg t "$1" --arg h "$h" --argjson i "$2" '{tool_id:$t, history_id:$h, inputs:$i}')"; }

# 20 reads of 100 bp from chr21:30,000,000, encrypted for the test user key
ssh semsec-galaxy python3 - <<'PY' | ssh semsec-recryptor "$USER_SVC encrypt --recipient_pk c4gh_recryptor_user/user_keys/user_key.pub\"" > /tmp/bam-test.fastqsanger.c4gh
fa = "/cvmfs/idc.galaxyproject.org/data/genomes/hg38/sam_fasta_index/v1/hg38canon/hg38canon.fa"
name, length, offset, bases, width = next(l.split("\t") for l in open(fa + ".fai") if l.startswith("chr21\t"))
offset, bases, width = int(offset), int(bases), int(width)
start = 30_000_000
with open(fa) as f:
    f.seek(offset + start // bases * width + start % bases)
    seq = f.read(3000).replace("\n", "").upper()
for i in range(20):
    print(f"@chr21_{start + i * 100}\n{seq[i * 100:i * 100 + 100]}\n+\n{'I' * 100}")
PY
h=$(api POST /api/histories '{"name":"BAM index test"}' | jq -r .id)
up=$(curl -sS -f -H "x-api-key: $KEY" -F "history_id=$h" \
  -F 'targets=[{"destination":{"type":"hdas"},"elements":[{"src":"files","name":"hg38-chr21.fastqsanger.c4gh","ext":"auto"}]}]' \
  -F "files_0|file_data=@/tmp/bam-test.fastqsanger.c4gh" $G/api/tools/fetch)
echo "upload: $(wait_job $(jq -r '.jobs[0].id' <<<"$up"))"
reads=$(jq -r '.outputs[0].id' <<<"$up")
echo "reads: $(api GET /api/datasets/$reads | jq -r .extension)"
hdr=$(api GET /api/datasets/$reads | jq -r .metadata_crypt4gh_header)
rec=$(ssh semsec-recryptor "curl -sS -m 30 -X POST https://localhost:61357/recrypt_header -H content-type:application/json -d '{\"crypt4gh_header\":\"$hdr\"}'")
api PUT /api/datasets/$reads/protection "$(jq -c '{scheme:"crypt4gh", crypt4gh_compute_header:.crypt4gh_header, crypt4gh_compute_keypair_id, crypt4gh_compute_keypair_expiration_date}' <<<"$rec")" | jq -c '{ready, expires_at}'

run=$(run_tool $BWA "$(jq -n --arg r "$reads" '{"reference_source|reference_source_selector":"cached", "reference_source|ref_file":"hg38",
  "fastq_input|fastq_input_selector":"single", "fastq_input|fastq_input1":{src:"hda", id:$r}}')")
j=$(jq -r '.jobs[0].id' <<<"$run"); bam=$(jq -r '.outputs[0].id' <<<"$run")
echo "bwa_mem: $(wait_job $j)"
api GET /api/datasets/$bam | jq -c '{extension, file_size, bam_index: (.metadata_bam_index != null)}'

run=$(run_tool $IDX "$(jq -n --arg b "$bam" '{input:{src:"hda", id:$b}}')")
j=$(jq -r '.jobs[0].id' <<<"$run"); out=$(jq -r '.outputs[0].id' <<<"$run")
echo "idxstats: $(wait_job $j)"
api GET "/api/jobs/$j?full=true" | jq -r .command_line | grep -o -E "ln -s '[^']*' infile.bai|samtools index infile infile.bai" | sed -E "s|'[^']*/|'.../|"
echo "decrypted idxstats output (chr21 should have 20 mapped reads):"
curl -sS -f -H "x-api-key: $KEY" "$G/api/datasets/$out/display?to_ext=$(api GET /api/datasets/$out | jq -r .extension)" \
  | ssh semsec-recryptor "$USER_SVC decrypt --sk c4gh_recryptor_user/user_keys/user_key.priv\"" | awk '$3 > 0 || $4 > 0'
rm -f /tmp/bam-test.fastqsanger.c4gh
