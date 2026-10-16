# Upstream fixes

Problems found while deploying, with the local workaround. Remove an entry once fixed upstream.

## galaxyproject/ansible-pulsar (1.0.11)

- `pulsar_systemd_runner: paste` runs `paster serve`, removed in Pulsar 0.15.15 (Paste replaced by Gunicorn, pulsar PR 440). Needs a `pulsar-serve` runner and `gunicorn` installed.
  Workaround: `pulsar_systemd: false`, own unit `templates/pulsar.service.j2`, `gunicorn` in `pulsar_optional_dependencies`.
- Unit sets `MemoryLimit=` on non-RedHat hosts, deprecated in systemd (`MemoryMax=`).

## galaxyproject/ansible-galaxy (0.12.13)

- The "restart galaxy" gravity handler for Galaxy >= 23.0 has no `galaxy_manage_systemd` check, so code-only installs (e.g. `galaxy_home` for Pulsar remote metadata) try to run `galaxyctl`.
  Workaround: `galaxy_systemd_mode: mule` on the Pulsar host.
- Creates the venv with the `virtualenv` command by default, which Ubuntu 24.04 doesn't ship (same in ansible-pulsar).
  Workaround: `galaxy_virtualenv_command` / `pulsar_virtualenv_command: /usr/bin/python3 -m venv`.

## elixir-europe/crypt4gh-recryptor-service (25ed776)

- `host` is both the bind address and the only certificate name, so the service can't listen on `0.0.0.0` with a certificate for its real names.
  Workaround: pre-create the mkcert certificate, set `ssl_certfile`/`ssl_keyfile` in `c4gh_config.yml`.
- Starts `uvicorn` through a shell, so it must be on `PATH`; fails with exit 127 under `uv tool install` + systemd.
  Workaround: tool venv `bin` added to `PATH` in the unit.
- `GET /info` returns `"mode": false` instead of the mode name.
- Always runs `mkcert -install` with `check=True`; a non-root service user can't install into the system store.
  Workaround: root runs `mkcert -install` with the same `CAROOT` first.

## elixir-oslo/ansible-role-galaxy-deployment (main)

- `galaxy_app_config` is ignored by galaxyproject.galaxy (it only renders `galaxy_config`), hence the later `lineinfile` patches of `galaxy.yml`.
- `tasks/galaxy_server.yml` uses `{{ playbook_dir }}/templates/dependency_resolvers_conf.xml.j2`, which the playbook repo doesn't have.
- Task-level `galaxy_config` can't be extended from inventory.

## elixir-oslo/ansible_galaxy_playbook (main)

- `deploy.sh` starts with a blank line, so the shebang is ignored when not run from bash (e.g. `nohup`, cron) and `/bin/sh` fails on `set -o pipefail`.
- `requirements.yml` installs the role over `git@github.com:`, which fails without a GitHub SSH key; `deploy.sh install` hides that with `|| true`.

## galaxyproject/galaxy PR #23986 (confirmed on these VMs)

- Protected Pulsar jobs need `metadata_strategy: extended` + `remote_metadata: true`. With that, Pulsar stages no outputs back: the metadata step on the Pulsar host writes them into Galaxy's object store, using the object store config serialized into the job directory (`lib/galaxy/jobs/runners/pulsar.py` `__client_outputs`, `lib/galaxy/metadata/set_metadata.py` `push_if_necessary`). Upstream docs say the same: https://docs.galaxyproject.org/en/latest/admin/containerized_metadata.html#configure-a-destination
- Test, plain `cat1` job (no encryption), REST Pulsar on a separate host, disk object store: job and dataset "ok", `file_size: 27`, but the file on the Galaxy host is 0 bytes; the 27-byte output sits at the same path on the Pulsar host. Silent data loss. Downloading it sends `Content-Length: 27` (the stored size) and then 0 bytes, so the connection closes early and browsers drop the download without an error.
- The Pulsar tests in the PR are all embedded (one host), so they can't catch this.
- Protected test (`fastqsanger.c4gh`, `cat1`): refusal before authorization, authorization (user service -> compute service -> `PUT /api/datasets/{id}/protection`), stage-in decryption on Pulsar (`/recrypt_header_to_job_key`) and output encryption (`/recrypt_header_to_user_key`) all work. The encrypted output (206 bytes, decrypts with the user key to the input) is written on the Pulsar host; Galaxy finds nothing, fails closed ("could not be verified to be encrypted and were purged").
- Outputs written on the Pulsar host this way are never cleaned up there (plaintext for unprotected jobs, ciphertext for protected ones).

