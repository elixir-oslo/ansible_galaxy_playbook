#!/bin/bash
# Protected and plain cat1 jobs on Pulsar, in a history on a user-defined S3 storage.
# Reads the Galaxy API key from stdin; the demo S3 key comes from the deployment secrets.
set -euo pipefail
read -r KEY
G=http://semsec-galaxy:8080
D=$(cd "$(dirname "$0")/.." && pwd)
SEC=$D/group_vars/all/secrets.yml
VARS=$D/group_vars/all/semsec.yml
py=$D/../venv/bin/python
val() { $py -c "import yaml,sys; print(yaml.safe_load(open(sys.argv[1]))[sys.argv[2]])" "$1" "$2"; }
AK=$(val $SEC rustfs_demo_access_key); SK=$(val $SEC rustfs_demo_secret_key)
EP=$(val $VARS s3_endpoint); BK=$(val $VARS s3_demo_bucket)
api() { curl -sS -f -X "$1" -H "x-api-key: $KEY" -H content-type:application/json ${3:+-d "$3"} "$G$2"; }
wait_job() { for _ in $(seq 1 100); do s=$(api GET /api/jobs/$1 | jq -r .state); case $s in ok|error|failed|deleted) echo $s; return;; esac; sleep 3; done; echo timeout; }

store=$(api POST /api/object_store_instances "$(jq -n --arg ak "$AK" --arg sk "$SK" --arg ep "$EP" --arg bk "$BK" \
  '{name:"RustFS demo", template_id:"generic_s3", template_version:0, variables:{access_key:$ak, bucket:$bk, endpoint_url:$ep}, secrets:{secret_key:$sk}}')")
sid=$(jq -r .object_store_id <<<"$store"); echo "storage: $(jq -r .name <<<"$store") $sid"
h=$(api POST /api/histories '{"name":"user storage test"}' | jq -r .id)
api PUT /api/histories/$h "{\"preferred_object_store_id\":\"$sid\"}" >/dev/null
echo "history: $h on $(api GET /api/histories/$h | jq -r .preferred_object_store_id)"

# Encrypted input, made on semsec-recryptor for the test user key
ssh semsec-recryptor 'sudo -u recryptor bash -c "cd /srv/recryptor/usertest && export HOME=/srv/recryptor PATH=/usr/local/bin:/usr/bin:/bin && printf \"@r1\nACGT\n+\nIIII\n\" | uvx -q crypt4gh encrypt --recipient_pk c4gh_recryptor_user/user_keys/user_key.pub"' > /tmp/reads.fastqsanger.c4gh
up=$(curl -sS -f -H "x-api-key: $KEY" -F "history_id=$h" \
  -F 'targets=[{"destination":{"type":"hdas"},"elements":[{"src":"files","name":"reads.fastqsanger.c4gh","ext":"auto"},{"src":"pasted","paste_content":"plain text\n","ext":"txt","name":"plain.txt"}]}]' \
  -F "files_0|file_data=@/tmp/reads.fastqsanger.c4gh" $G/api/tools/fetch)
echo "upload: $(wait_job $(jq -r '.jobs[0].id' <<<"$up"))"
enc=$(jq -r '.outputs[0].id' <<<"$up"); pln=$(jq -r '.outputs[1].id' <<<"$up")
echo "uploaded: $(api GET /api/datasets/$enc | jq -r '[.extension, .object_store_id] | join(" on ")')"

hdr=$(api GET /api/datasets/$enc | jq -r .metadata_crypt4gh_header)
rec=$(ssh semsec-recryptor "curl -sS -m 30 -X POST https://localhost:61357/recrypt_header -H content-type:application/json -d '{\"crypt4gh_header\":\"$hdr\"}'")
api PUT /api/datasets/$enc/protection "$(jq -c '{scheme:"crypt4gh", crypt4gh_compute_header:.crypt4gh_header, crypt4gh_compute_keypair_id, crypt4gh_compute_keypair_expiration_date}' <<<"$rec")" | jq -c '{ready, expires_at}'

for in_id in $enc $pln; do
  run=$(api POST /api/tools "{\"tool_id\":\"cat1\",\"history_id\":\"$h\",\"inputs\":{\"input1\":{\"src\":\"hda\",\"id\":\"$in_id\"}}}")
  j=$(jq -r '.jobs[0].id' <<<"$run"); o=$(jq -r '.outputs[0].id' <<<"$run")
  echo "cat1 on $(api GET /api/datasets/$in_id | jq -r .name): $(wait_job $j)"
  api GET /api/datasets/$o | jq -c '{name, state, extension, file_size, uuid, object_store_id, misc_info}'
  echo "$o" >> /tmp/user-storage-test-outputs
done

echo "bucket:"; curl -s --aws-sigv4 aws:amz:us-east-1:s3 --user "$AK:$SK" "$EP/$BK?list-type=2" | grep -o -E '<(Key|Size)>[^<]*' | paste - - | sed 's/<Key>//; s/<Size>/ /'
o=$(sed -n 1p /tmp/user-storage-test-outputs)
echo "decrypted protected output:"
curl -sS -f -H "x-api-key: $KEY" "$G/api/datasets/$o/display?to_ext=fastqsanger.c4gh" \
  | ssh semsec-recryptor 'sudo -u recryptor bash -c "cd /srv/recryptor/usertest && export HOME=/srv/recryptor PATH=/usr/local/bin:/usr/bin:/bin && uvx -q crypt4gh decrypt --sk c4gh_recryptor_user/user_keys/user_key.priv"'
rm -f /tmp/user-storage-test-outputs /tmp/reads.fastqsanger.c4gh
