# SemSec demo deployment (Crypt4GH Galaxy at BSC)

Galaxy with [PR #23986](https://github.com/galaxyproject/galaxy/pull/23986), a separate Pulsar host (REST, no shared storage) and the [crypt4gh-recryptor-service](https://github.com/elixir-europe/crypt4gh-recryptor-service) compute service, on three Ubuntu 24.04 VMs. Uses the galaxyproject roles directly; the rest of this repo is not used.

| Host | Runs |
|---|---|
| semsec-galaxy | Galaxy (gravity, gunicorn on :8080), PostgreSQL |
| semsec-pulsar | Pulsar 0.15.16 on :8913, Galaxy checkout of the same commit as `galaxy_home` |
| semsec-recryptor | recryptor compute service on :61358 (mkcert) |

The public proxy (galaxy.semsec.bsc.es) runs on the BSC login node and is not managed here.

## Run

On the login node the venv is in the repo root (uv works without `python3-venv`): `uv venv --seed venv && VIRTUAL_ENV=$PWD/venv uv pip install ansible==10.7.0`.

```
cd semsec
../venv/bin/ansible-galaxy role install -r requirements.yml -p roles
../venv/bin/ansible-playbook hosts.yml recryptor.yml galaxy.yml pulsar.yml
```

Secrets go in `group_vars/all/secrets.yml` (not in git): `galaxy_database_password`, `galaxy_id_secret`, `pulsar_private_token`, `recryptor_private_key_passphrase`.

To test another Galaxy commit, set `galaxy_commit_id` in `group_vars/galaxyservers/galaxy.yml` and rerun `galaxy.yml pulsar.yml`.

## Tests

With an API key in `KEY` and `G=https://galaxy.semsec.bsc.es`:

1. Plain job on Pulsar: upload a text file (`POST $G/api/tools/fetch`), run `cat1` on it (`POST $G/api/tools`). Compare the output file on the Galaxy host and on the Pulsar host (same path under `/srv/galaxy/datasets`).
2. Protected job, without a browser: run the user service next to the compute service (`crypt4gh-recryptor-service user`), encrypt a file to its `user_keys/user_key.pub`, upload it as `reads.fastqsanger.c4gh`, then:
   - `GET $G/api/datasets/<id>` and take `metadata_crypt4gh_header`
   - `POST https://localhost:61357/recrypt_header` with `{"crypt4gh_header": "<header>"}`
   - `PUT $G/api/datasets/<id>/protection` with `scheme: crypt4gh` and the returned `crypt4gh_header`, `crypt4gh_compute_keypair_id`, `crypt4gh_compute_keypair_expiration_date` (as `crypt4gh_compute_header`, `crypt4gh_compute_keypair_id`, `crypt4gh_compute_keypair_expiration_date`)
   - run `cat1` on the dataset

Results and open problems: [UPSTREAM.md](UPSTREAM.md).
