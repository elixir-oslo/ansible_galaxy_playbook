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
../venv/bin/ansible-playbook hosts.yml recryptor.yml s3.yml galaxy.yml pulsar.yml
```

Secrets go in `group_vars/all/secrets.yml` (not in git): `galaxy_database_password`, `galaxy_id_secret`, `pulsar_private_token`, `recryptor_private_key_passphrase`, `rustfs_root_access_key`, `rustfs_root_secret_key`, `rustfs_demo_access_key`, `rustfs_demo_secret_key`, `galaxy_vault_encryption_key`.

To test another Galaxy commit, set `galaxy_commit_id` in `group_vars/galaxyservers/galaxy.yml` and rerun `galaxy.yml pulsar.yml`.

## User storages

Protected jobs on Pulsar need the history to be on a user-defined S3 storage. The metadata step on the Pulsar host encrypts the outputs and writes them straight to the user's bucket, and Galaxy then checks each output's header there. On Galaxy's default disk storage, Pulsar writes the outputs to its own disk instead, so unencrypted outputs come back empty and encrypted ones fail the check.

To set one up, in User, Preferences, Manage Your Galaxy Storage, create a storage from "Any S3 Compatible Storage" with endpoint `http://semsec-galaxy:8443`, bucket `galaxy-c4gh` and the demo key (`rustfs_demo_access_key` and `rustfs_demo_secret_key` from the secrets). Then select it for a history under the history's title. The demo key can only use that bucket.

The storage's configuration, including its secret key, goes to the Pulsar host with each job. A user should only create such a storage with a key they are willing to give to the compute host.

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
sudo pkill -u recryptor -f "crypt4gh-recryptor-service user"
```

The user key pair is in `/srv/recryptor/usertest/c4gh_recryptor_user/user_keys/`. Remove the directory to start again with a new key.

Results and open problems: [UPSTREAM.md](UPSTREAM.md).
