# Galaxy Ansible Playbook

An Ansible-based deployment toolkit for installing and validating a Galaxy server with PostgreSQL, Gravity, and Nginx.

This repository is centered around `deploy.sh`, which provides an interactive menu and callable functions for both **local** deployments (Ansible runs on the Galaxy server itself) and **remote** deployments (Ansible runs from a separate control node over SSH).

## What this repository deploys

Based on `galaxy.yml`, `nginx.yml`, `requirements.yml`, and `group_vars/galaxyservers.yml`, this project deploys:

- Galaxy from `https://github.com/galaxyproject/galaxy.git`
- Galaxy release `release_26.0`
- PostgreSQL for the Galaxy database
- Gravity-managed Galaxy services
- Nginx as a reverse proxy
- Micromamba/Miniconda-managed tool dependencies

Installed Ansible Galaxy roles:

- `galaxyproject.galaxy` `0.12.1`
- `galaxyproject.nginx` `0.7.1`
- `galaxyproject.postgresql` `1.1.2`
- `galaxyproject.postgresql_objects` `1.2.0`
- `galaxyproject.miniconda` `0.3.3`
- `usegalaxy_eu.certbot` `0.1.13`

## Repository layout

- `deploy.sh` – main entrypoint for setup, deployment, repair, and validation
- `galaxy.yml` – full Galaxy + PostgreSQL + Nginx deployment playbook
- `nginx.yml` – standalone Nginx deployment/check playbook
- `requirements.yml` – required Ansible Galaxy roles
- `hosts` – inventory for local or remote execution
- `group_vars/galaxyservers.yml` – Galaxy, PostgreSQL, Nginx, and service configuration
- `configs/config.yml.example` – example environment-specific settings
- `configs/config.yml` – required local configuration file consumed by `deploy.sh`
- `devops-scripts/one-time-bootstrap.sh` – first-run stabilization script
- `devops-scripts/fix-nginx-ui_after_deployment.sh` – Nginx/UI repair script
- `devops-scripts/validate_galaxy.sh` – runtime health and restart validation
- `devops-scripts/test_playbooks.sh` – quick inventory/connectivity/syntax test

## Prerequisites

From the included files, this project assumes a Debian/Ubuntu-style environment with:

- `bash`
- `sudo`
- `apt`
- `python3`
- `python3-venv`
- `pip`
- `git`
- `yq`

Notes:

- `deploy.sh` requires `yq` before it can read `configs/config.yml`.
- If `yq` is missing, `deploy.sh` can prompt to install it interactively.
- `prepare_system` in `deploy.sh` creates a Python virtual environment in `venv/` and prepares temporary directories under `/srv/galaxy`.
- Remote deployment additionally requires SSH connectivity to the target host.

## Configuration

### 1. Create `configs/config.yml`

Copy the example file and fill in your environment values:

```bash
cp configs/config.yml.example configs/config.yml
```

Set at least:

- `galaxy.host_ip`
- `galaxy.ssh_user`
- `admin.email`
- `database.password`

Example structure:

```yaml
galaxy:
  host_ip: "your-server-ip-or-dns"
  ssh_user: "ubuntu"

admin:
  email: "admin@example.com"

database:
  password: "CHANGE_ME_TO_A_STRONG_PASSWORD"
```

### 2. Configure inventory in `hosts`

The provided `hosts` file documents both supported modes.

#### Local deployment
Use this when Ansible runs on the same server that will host Galaxy:

```ini
[galaxyservers]
galaxy ansible_connection=local ansible_python_interpreter=/usr/bin/python3

[dbservers]
galaxy
```

#### Remote deployment
Use this when Ansible runs from another machine:

```ini
[galaxyservers]
galaxy ansible_host=host_ip_address ansible_user=ssh_user ansible_become=true ansible_become_method=sudo ansible_python_interpreter=/usr/bin/python3

[dbservers]
galaxy
```

Important remote deployment behavior from `deploy.sh`:

- it refuses to continue if `hosts` contains `ansible_connection=local`
- it refuses to continue if the inventory points to `localhost` or `127.0.0.1`
- it checks SSH/Ansible reachability with `ansible ... -m ping`

### 3. Environment-backed playbook values

`group_vars/galaxyservers.yml` reads some values from environment variables:

- `GALAXY_DB_PASSWORD`
- `GALAXY_ADMIN_EMAIL`

These are used for:

- PostgreSQL connection and database user creation
- Galaxy admin email / admin user configuration

If you run the playbooks manually instead of through `deploy.sh`, make sure those environment variables are set in your shell first.

## How `deploy.sh` works

Running `deploy.sh` with no arguments opens an interactive menu. The script first:

1. checks that `yq` is installed
2. reads `configs/config.yml`
3. prepares the local Python virtual environment and Ansible temp directories
4. asks whether the deployment mode is `local` or `remote`
5. shows the corresponding action menu

Make the script executable if needed:

```bash
chmod +x deploy.sh
```

Start the interactive menu:

```bash
./deploy.sh
```

## Recommended deployment flow

### Local deployment

The recommended local option is **Full Galaxy deployment**. In `deploy.sh`, `full_run` performs:

1. `prepare_system`
2. `install_ansible`
3. `install_roles`
4. `validate_playbook`
5. `deploy_galaxy`
6. wait 30 seconds
7. `run_one_time_bootstrap`
8. wait 30 seconds
9. `fix_nginx_ui`
10. wait 30 seconds
11. `validate_galaxy`

### Remote deployment

The recommended remote option performs this sequence:

1. `prepare_system` on the control node
2. `install_ansible`
3. `install_roles`
4. `deploy_galaxy_remote`
5. wait 30 seconds
6. `run_one_time_bootstrap_remote`
7. wait 30 seconds
8. `fix_nginx_ui_remote`
9. wait 30 seconds
10. `validate_galaxy_remote`

## Direct function-based usage

`deploy.sh` can also run functions directly by passing the function name as the first argument.

Examples:

```bash
./deploy.sh prepare_system
./deploy.sh install_ansible
./deploy.sh install_roles
./deploy.sh validate_playbook
./deploy.sh deploy_galaxy
./deploy.sh full_run
```

Useful local functions exposed by the script:

- `full_run`
- `clean_galaxy`
- `prepare_system`
- `install_ansible`
- `install_roles`
- `validate_playbook`
- `deploy_galaxy`
- `run_one_time_bootstrap`
- `fix_nginx_ui`
- `validate_galaxy`
- `rebuild_client`
- `force_rebuild_client`
- `manual_client_build`

Useful remote-capable functions exposed by the script:

- `deploy_galaxy_remote`
- `run_one_time_bootstrap_remote`
- `fix_nginx_ui_remote`
- `validate_galaxy_remote`

## What the playbooks configure

### `galaxy.yml`

This is the main deployment playbook. It:

- installs PostgreSQL on `galaxyservers`
- creates the Galaxy database and database user on `dbservers`
- installs system packages such as `git`, `python3`, `python3-venv`, `acl`, `nginx`, and `postgresql`
- deploys Galaxy using `galaxyproject.galaxy`
- installs Micromamba/Miniconda support using `galaxyproject.miniconda`
- configures Nginx using `galaxyproject.nginx`
- reloads systemd
- starts and restarts Galaxy and Nginx
- resets Gravity runtime state
- checks for `gunicorn`
- waits for Galaxy on `127.0.0.1:8080`
- tests `http://127.0.0.1:8080/api/version`

### `nginx.yml`

This playbook can be used to deploy or re-apply the Nginx role and then:

- restart Nginx
- wait for the HTTP port
- test connectivity to the server root URL

## Post-deployment helper scripts

### `devops-scripts/one-time-bootstrap.sh`

This script is intended to run once after deployment. It:

- creates `/var/lib/galaxy/bootstrap.done` as a marker
- stops Galaxy and Nginx
- removes `/etc/nginx/conf.d/http_options.conf` if present
- ensures `/etc/nginx/sites-available/galaxy` exists
- enables the Galaxy Nginx site
- resets `/srv/galaxy/mutable/gravity/state`
- reloads systemd
- validates Nginx config with `nginx -t`
- starts Galaxy, waits, then starts Nginx
- verifies `http://localhost/api/version`

### `devops-scripts/fix-nginx-ui_after_deployment.sh`

This repeatable repair script:

- verifies the Galaxy backend on `127.0.0.1:8080`
- checks that static assets exist under `/srv/galaxy/server/static/dist`
- fixes ownership and permissions for static files
- writes an Nginx site that serves `/static/` directly
- reloads Nginx and restarts Galaxy
- verifies both a static asset and the Galaxy API via `http://localhost`

### `devops-scripts/validate_galaxy.sh`

This validation script checks:

- Galaxy service state via `galaxyctl`
- listening ports `8080` and `80`
- internal API availability at `http://127.0.0.1:8080/api/version`
- external API availability through Nginx
- that Galaxy is using PostgreSQL rather than SQLite
- restart resilience for both Galaxy and Nginx

## Quick test before deployment

The helper script `devops-scripts/test_playbooks.sh` performs a lightweight preflight by:

- activating the local virtual environment
- checking `python3`, `ansible`, and `git`
- validating the inventory
- pinging the target hosts with Ansible
- running syntax checks for `galaxy.yml` and `nginx.yml`

Run it with:

```bash
bash devops-scripts/test_playbooks.sh
```

## Important defaults from `group_vars/galaxyservers.yml`

The main defaults currently defined in the repository are:

- Galaxy root: `/srv/galaxy`
- Galaxy internal bind: `127.0.0.1:8080`
- public Nginx listener: port `80`
- Galaxy system user: `galaxy`
- Galaxy layout: `root-dir`
- client prebuilt assets: disabled (`galaxy_client_use_prebuilt: false`)
- Galaxy admin values pulled from `GALAXY_ADMIN_EMAIL`

## Verification endpoints

After a successful deployment, the included files indicate these useful checks:

- internal API: `http://127.0.0.1:8080/api/version`
- external API through Nginx: `http://<server-ip>/api/version`
- main UI: `http://<server-ip>/`

## Cleanup and rebuild operations

`deploy.sh` also includes maintenance actions:

- `clean_galaxy` – stops services, removes Conda environments, resets Gravity state, and detaches `/srv/galaxy`
- `rebuild_client` – reruns only the `galaxy_client` Ansible tag
- `force_rebuild_client` – removes `client_build_hash.txt` and rebuilds the frontend
- `manual_client_build` – runs `make client-clean` and `make client-build` as the `galaxy` user

Use these with care, especially `clean_galaxy`, which is intentionally destructive.

## Typical local quick start

```bash
sudo apt update
sudo apt install -y yq
cp configs/config.yml.example configs/config.yml
chmod +x deploy.sh
./deploy.sh
```

Then choose:

1. local deployment mode if you are running on the target Galaxy server
2. `Full Galaxy deployment (recommended)`

## Typical remote quick start

```bash
sudo apt update
sudo apt install -y yq
cp configs/config.yml.example configs/config.yml
chmod +x deploy.sh
./deploy.sh
```

Then:

1. update `hosts` to use a remote target
2. choose remote deployment mode
3. select `Full Galaxy deployment (recommended)`

## Troubleshooting notes from the repository

- If `configs/config.yml` is missing, `deploy.sh` exits immediately.
- If `yq` is missing in non-interactive mode, `deploy.sh` exits and asks you to install dependencies first.
- If Nginx configuration is invalid, `deploy_galaxy` stops before running the main playbook.
- Remote mode depends on a non-local inventory and successful SSH/Ansible ping.
- Validation scripts assume services are managed with `systemd` and installed under `/srv/galaxy`.

## License

See `LICENSE`.

