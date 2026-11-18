#!/bin/bash
# BWA-MEM on Pulsar against the hg38 index from CVMFS, with reads cut from hg38 chr21.
# Reads the Galaxy API key from stdin. Needs devteam/bwa installed.
set -euo pipefail
read -r KEY
G=https://semsec-galaxy:8080
export CURL_CA_BUNDLE=$HOME/semsec-pki/ca.pem
BWA=toolshed.g2.bx.psu.edu/repos/devteam/bwa/bwa_mem/0.7.19+galaxy2
api() { curl -sS -f -X "$1" -H "x-api-key: $KEY" -H content-type:application/json ${3:+-d "$3"} "$G$2"; }
wait_job() { for _ in $(seq 1 360); do s=$(api GET /api/jobs/$1 | jq -r .state); case $s in ok|error|failed|deleted) echo $s; return;; esac; sleep 5; done; echo timeout; }

# 20 reads of 100 bp from chr21:30,000,000, read through the .fai of the IDC hg38 FASTA
ssh semsec-galaxy python3 - > /tmp/hg38-chr21.fastqsanger <<'PY'
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
h=$(api POST /api/histories '{"name":"reference data test"}' | jq -r .id)
up=$(curl -sS -f -H "x-api-key: $KEY" -F "history_id=$h" \
  -F 'targets=[{"destination":{"type":"hdas"},"elements":[{"src":"files","name":"hg38-chr21.fastqsanger","ext":"fastqsanger"}]}]' \
  -F "files_0|file_data=@/tmp/hg38-chr21.fastqsanger" $G/api/tools/fetch)
echo "upload: $(wait_job $(jq -r '.jobs[0].id' <<<"$up"))"
reads=$(jq -r '.outputs[0].id' <<<"$up")

run=$(api POST /api/tools "$(jq -n --arg t "$BWA" --arg h "$h" --arg r "$reads" '{tool_id:$t, history_id:$h, inputs:{
  "reference_source|reference_source_selector":"cached", "reference_source|ref_file":"hg38",
  "fastq_input|fastq_input_selector":"single", "fastq_input|fastq_input1":{src:"hda", id:$r}}}')")
j=$(jq -r '.jobs[0].id' <<<"$run"); o=$(jq -r '.outputs[0].id' <<<"$run")
echo "bwa_mem: $(wait_job $j)"
api GET "/api/jobs/$j?full=true" | jq -r '.command_line' | grep -o -E '(apptainer|singularity) exec|/cvmfs/[^ "]*' | sort -u
api GET "/api/jobs/$j?full=true" | jq -r '.tool_stderr' | grep -E 'Processed|Version' || true
api GET /api/datasets/$o | jq -c '{name, state, extension, file_size, genome_build, misc_info}'
rm -f /tmp/hg38-chr21.fastqsanger
