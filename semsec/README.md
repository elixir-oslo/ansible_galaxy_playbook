# SemSec demo deployment (Crypt4GH Galaxy at BSC)

Galaxy with Add Crypt4GH-encrypted datasets with server-managed compute grants ([galaxy#23986](https://github.com/galaxyproject/galaxy/pull/23986)), a separate Pulsar host (REST, no shared filesystem), an S3 server for user-defined storages and the [crypt4gh-recryptor-service](https://github.com/elixir-europe/crypt4gh-recryptor-service) compute service, on three Ubuntu 24.04 VMs. Uses the galaxyproject roles directly; the rest of this repo is not used.

| Host | Runs |
|---|---|
| semsec-galaxy | Galaxy (gravity, gunicorn on :8080), PostgreSQL, RustFS S3 server on :8443 |
| semsec-pulsar | Pulsar 0.16.0 on :8913, Galaxy checkout of the same commit as `galaxy_home` |
| semsec-recryptor | recryptor compute service on :61358 (mkcert) |

The public proxy (galaxy.semsec.bsc.es) runs on the BSC login node and is not managed here. Between the VMs, the BSC network only lets ports 22, 80, 443, 8080, 8443 and 61358 through, which is why the S3 server listens on 8443.

## Run

On the login node the venv is in the repo root (uv works without `python3-venv`): `uv venv --seed venv && VIRTUAL_ENV=$PWD/venv uv pip install ansible==10.7.0`.

```
cd semsec
../venv/bin/ansible-galaxy role install -r requirements.yml -p roles
../venv/bin/ansible-playbook hosts.yml recryptor.yml s3.yml pki.yml galaxy.yml pulsar.yml
```

Secrets go in `group_vars/all/secrets.yml` (not in git): `galaxy_database_password`, `galaxy_id_secret`, `pulsar_private_token`, `recryptor_private_key_passphrase`, `rustfs_root_access_key`, `rustfs_root_secret_key`, `rustfs_demo_access_key`, `rustfs_demo_secret_key`, `galaxy_vault_encryption_key`.

To test another Galaxy commit, set `galaxy_commit_id` in `group_vars/galaxyservers/galaxy.yml` and rerun `galaxy.yml pulsar.yml`.

## Internal TLS

All traffic between the VMs is encrypted. `pki.yml` makes a small internal certificate authority (CA) and a certificate for each VM, named after the VM (`semsec-galaxy`, `semsec-pulsar`, `semsec-recryptor`) and its address. The CA and the keys stay on the control node in `~/semsec-pki`, outside git. The playbook adds the CA to each VM's trust store and gives each service its own copy of the certificate and key:

| Service | Listens with TLS on | Certificate files |
|---|---|---|
| Galaxy (gunicorn) | semsec-galaxy:8080 | `/etc/ssl/semsec/host.pem`, `galaxy-key.pem` |
| RustFS | semsec-galaxy:8443 | `/etc/rustfs/tls/rustfs_cert.pem`, `rustfs_key.pem` |
| Pulsar | semsec-pulsar:8913 | `/etc/ssl/semsec/pulsar.pem` (certificate and key in one file) |
| recryptor compute service | semsec-recryptor:61358 | `c4gh_recryptor_compute/certs/server.pem`, `server-key.pem` |

Python tools such as `requests` and `boto3` bring their own list of certificate authorities, so Galaxy, its jobs and Pulsar get `REQUESTS_CA_BUNDLE` and `AWS_CA_BUNDLE` pointing to the system bundle, which includes the internal CA. Run `pki.yml` before the service playbooks, since they expect the certificates in place. Rerunning it renews nothing until a certificate is close to expiring (they last 825 days, the CA ten years).

The login-node proxy connects to Galaxy and the recryptor over HTTPS and checks their certificates against the internal CA (`~/semsec-pki/ca.pem`, copied to the login node). Galaxy only accepts HTTPS once `galaxy.yml` has run, so its proxy upstream changes at the same time.

User storages created with the old `http://semsec-galaxy:8443` endpoint stop working when RustFS switches to TLS. Create them again with `https://`.

## User storages

Protected jobs on Pulsar need the history to be on a user-defined S3 storage. The metadata step on the Pulsar host encrypts the outputs and writes them straight to the user's bucket, and Galaxy then checks each output's header there. On Galaxy's default disk storage, Pulsar writes the outputs to its own disk instead, so unencrypted outputs come back empty and encrypted ones fail the check.

To set one up, in User, Preferences, Manage Your Galaxy Storage, create a storage from "Any S3 Compatible Storage" with endpoint `https://semsec-galaxy:8443`, bucket `galaxy-c4gh` and the demo key (`rustfs_demo_access_key` and `rustfs_demo_secret_key` from the secrets). Then select it for a history under the history's title. The demo key can only use that bucket.

The storage's configuration, including its secret key, goes to the Pulsar host with each job. A user should only create such a storage with a key they are willing to give to the compute host.

## EGA Live Outbox

Users can browse their Central EGA Live Outbox in Galaxy's upload dialog and import files from it. Galaxy connects to `outbox.ega-archive.org` over SFTP with the user's own EGA login, which Galaxy keeps in its vault. The template is `files/galaxy/ega_outbox_file_source.yml`.

To set one up, in User, Preferences, Manage Your Remote File Sources, create one from "EGA Live Outbox" with your EGA username and password, or an SSH key registered in your EGA profile. The files arrive encrypted for the Crypt4GH keys in that profile, so Galaxy detects them as encrypted datasets.

semsec-galaxy reaches the outbox on port 22 since BSC opened it. The FEGA Spain outbox (`outbox.spain.ega-archive.org`, port 2233) is still blocked, so there is no template for it yet.

The walltime limit is 1 hour. Galaxy only accepts compute keypairs valid for 1 day + the walltime + 1 hour, and the compute service only renews them in their last day, so authorizing fails for "walltime + 1 hour" before each renewal (see UPSTREAM.md). A short walltime keeps that window small.

## Tests

`tests/test-user-storage.sh` runs the protected test end to end from the login node, with the API key on its standard input: `tests/test-user-storage.sh < ~/.galaxy-api-key`. It creates a storage with the demo key, a history on it, uploads an encrypted FASTQ and a text file, authorizes the encrypted one through the test user service, runs `cat1` on both, lists the bucket and decrypts the protected output with the user key.

The steps by hand, with an API key in `KEY` and `G=https://galaxy.semsec.bsc.es`:


With an API key in `KEY` and `G=https://galaxy.semsec.bsc.es`:

1. Plain job on Pulsar in a history on the default storage: upload a text file (`POST $G/api/tools/fetch`), run `cat1` on it (`POST $G/api/tools`). The output is 0 bytes on the Galaxy host and complete on the Pulsar host, at the same path under `/srv/galaxy/datasets`.
2. Protected job, without a browser, in a history on a user storage: run the user service next to the compute service, encrypt a file to its `user_keys/user_key.pub`, upload it as `reads.fastqsanger.c4gh`, then:
   - `GET $G/api/datasets/<id>` and take `metadata_crypt4gh_header`
   - `POST https://localhost:61357/recrypt_header` with `{"crypt4gh_header": "<header>"}`
   - `PUT $G/api/datasets/<id>/protection` with `scheme: crypt4gh` and the returned `crypt4gh_header`, `crypt4gh_compute_keypair_id`, `crypt4gh_compute_keypair_expiration_date` (as `crypt4gh_compute_header`, `crypt4gh_compute_keypair_id`, `crypt4gh_compute_keypair_expiration_date`)
   - run `cat1` on the dataset

### Test user service on semsec-recryptor

For the protected test, a user service runs on semsec-recryptor, next to the compute service. In a real setup it runs on each user's own machine. It runs as `recryptor` in `/srv/recryptor/usertest`, listens on `localhost:61357` only, and uses a throwaway key without a passphrase. It is not a systemd unit, so it does not come back after a reboot.

Start it:

```
sudo -u recryptor bash -c 'cd /srv/recryptor/usertest \
  && echo C4GH_RECRYPTOR_PRIVATE_KEY_PASSPHRASE= > .env && chmod 600 .env \
  && export HOME=/srv/recryptor CAROOT=/srv/recryptor/mkcert \
     PATH=/srv/recryptor/bin:/srv/recryptor/uv-tools/crypt4gh-recryptor-service/bin:/usr/local/bin:/usr/bin:/bin \
  && nohup crypt4gh-recryptor-service user > usertest.log 2>&1 < /dev/null &'
curl -sS https://localhost:61357/info
```

Stop it:

```
sudo pkill -u recryptor -f "uvicorn --host localhost --port 61357"
```

Its settings are in `/srv/recryptor/usertest/c4gh_recryptor_user/c4gh_config.yml`. `compute_host` must be `semsec-recryptor`, the name on the compute service's certificate, not `localhost`. The service starts `uvicorn` through a shell, which is why the stop command matches the `uvicorn` process.

The user key pair is in `/srv/recryptor/usertest/c4gh_recryptor_user/user_keys/`. Remove the directory to start again with a new key.

Results and open problems: [UPSTREAM.md](UPSTREAM.md).
