# Galaxy Deployment Playbook

Ansible-based deployment workflow for a production-style Galaxy server on Ubuntu.

This repository provides:

- a reusable Galaxy baseline role at `roles/galaxy_deployment`
- a wrapper playbook at `galaxy-role.yml`
- an operations helper script at `deploy.sh`

The current baseline targets:

- Galaxy `release_26.0`
- PostgreSQL
- nginx reverse proxy
- optional HTTPS
- optional Galaxy branding and favicon customization

---

## What this repository is for

This repository is a deployment project around the reusable `galaxy_deployment` role.

Use this repository when you want to:

- deploy a standalone Galaxy server
- test the reusable Galaxy role on a VM
- run operational commands through `deploy.sh`
- wipe and redeploy Galaxy during development
- validate Galaxy, nginx, PostgreSQL, and static assets

If you only want to consume the role from another project, install the dedicated role repository in your own `requirements.yml`.

---

## Repository layout

```text
ansible_galaxy_playbook/
├── ansible.cfg
├── deploy.sh
├── galaxy-role.yml
├── requirements.yml
├── hosts.sample
├── hosts                         # generated or copied locally, usually not committed
├── group_vars/
│   └── galaxyservers.yml
└── roles/
    └── galaxy_deployment/
```

---

## Main components

### `galaxy-role.yml`

Wrapper playbook that applies the `galaxy_deployment` role to the target host group.

### `roles/galaxy_deployment`

Reusable role that manages the Galaxy baseline:

- PostgreSQL
- Galaxy server
- Galaxy virtual environment
- Galaxy systemd/Gravity services
- nginx
- optional HTTPS
- optional branding
- optional client build

### `deploy.sh`

Operational helper script for common workflows:

- prepare local Ansible environment
- install role dependencies
- run syntax checks
- ping target host
- deploy Galaxy
- validate Galaxy API
- wipe runtime assets
- deep wipe VM state

---

## Prerequisites

### Control node

Supported control node operating systems:

- macOS
- Linux

Required tools:

```bash
python3
git
ssh
```

The script creates and manages a local Python virtual environment at:

```text
venv/
```

### Target VM

The target VM should be Ubuntu-based and have:

- SSH access
- sudo access
- package repository access
- enough disk space for Galaxy

Recommended Galaxy storage:

```text
100 GB or larger mounted at /srv/galaxy
```

Check on the VM:

```bash
df -h /srv/galaxy
findmnt /srv/galaxy
```

---

## Configuration

Edit:

```text
group_vars/galaxyservers.yml
```

Minimum required values:

```yaml
galaxy:
  host_ip: "<VM_IP_OR_HOSTNAME>"
  ssh_user: "<SSH_USER>"

galaxy_admin_email: "admin@example.com"
galaxy_database_password: "CHANGE_ME_STRONG_PASSWORD"
```

For production, store secrets such as `galaxy_database_password` in Ansible Vault.

---

## Common configuration variables

```yaml
galaxy_root: "/srv/galaxy"
galaxy_commit_id: "release_26.0"
galaxy_web_port: 8080

build_galaxy_client_after_api: true
galaxy_force_client_rebuild: false
```

---

## HTTPS configuration

HTTPS is optional.

### HTTP only

```yaml
galaxy_enable_https: false
```

### Self-signed HTTPS for testing

Useful when testing on a VM without a real DNS name:

```yaml
galaxy_enable_https: true
galaxy_https_mode: "selfsigned"
galaxy_server_name: "galaxy.local"
galaxy_https_redirect: false
```

This allows both:

```bash
curl http://127.0.0.1/api/version
curl -k https://127.0.0.1/api/version
```

The self-signed certificate is created on the VM:

```text
/etc/ssl/galaxy/galaxy.crt
/etc/ssl/galaxy/galaxy.key
```

### Let's Encrypt HTTPS

Use this when a real DNS name points to the VM:

```yaml
galaxy_enable_https: true
galaxy_https_mode: "letsencrypt"
galaxy_server_name: "galaxy.example.org"
galaxy_letsencrypt_email: "admin@example.org"
galaxy_https_redirect: true
```

Requirements:

- DNS A record points to the VM public IP
- TCP port `80` is open
- TCP port `443` is open
- `galaxy_server_name` is publicly resolvable

### Existing certificate

Use this when certificate files already exist on the VM:

```yaml
galaxy_enable_https: true
galaxy_https_mode: "existing"
galaxy_server_name: "galaxy.example.org"
galaxy_ssl_certificate_path: "/etc/ssl/certs/galaxy.crt"
galaxy_ssl_certificate_key_path: "/etc/ssl/private/galaxy.key"
galaxy_https_redirect: true
```

Protect the private key:

```bash
sudo chown root:root /etc/ssl/private/galaxy.key
sudo chmod 600 /etc/ssl/private/galaxy.key
```

---

## Branding configuration

Basic Galaxy branding variables:

```yaml
galaxy_brand: "Galaxy"
galaxy_page_title: "{{ galaxy_brand }}"
```

Example:

```yaml
galaxy_brand: "immuneML Galaxy"
galaxy_page_title: "immuneML Galaxy"
```

Optional favicon variables:

```yaml
galaxy_favicon_ico_src: "files/favicon.ico"
galaxy_favicon_svg_src: "files/favicon.svg"
```

The role installs them to:

```yaml
galaxy_favicon_ico_dest: "{{ galaxy_server_dir }}/static/favicon.ico"
galaxy_favicon_svg_dest: "{{ galaxy_server_dir }}/static/favicon.svg"
```

Verify after deployment:

```bash
curl -I http://127.0.0.1/static/favicon.ico
curl -I http://127.0.0.1/static/favicon.svg
```

For self-signed HTTPS:

```bash
curl -k -I https://127.0.0.1/static/favicon.ico
curl -k -I https://127.0.0.1/static/favicon.svg
```

Browsers cache favicons aggressively. Use a hard refresh or open the favicon URL directly.

---

## Quick start

Run the full workflow step by step:

```bash
./deploy.sh prepare
./deploy.sh install
./deploy.sh check
./deploy.sh ping
./deploy.sh deploy
./deploy.sh validate
```

Or run the full remote pipeline:

```bash
./deploy.sh full
```

Interactive menu:

```bash
./deploy.sh
```

---

## `deploy.sh` command reference

```bash
./deploy.sh menu
./deploy.sh full
./deploy.sh prepare
./deploy.sh install
./deploy.sh check
./deploy.sh ping
./deploy.sh deploy
./deploy.sh validate
./deploy.sh local
./deploy.sh clean
./deploy.sh wipe-assets
./deploy.sh wipe
./deploy.sh help
```

### Command details

#### `prepare`

Creates and updates the local Python virtual environment:

```text
venv/
```

Installs:

- Ansible
- yq
- PyYAML

#### `install`

Installs Ansible roles and collections from:

```text
requirements.yml
```

Equivalent to:

```bash
ansible-galaxy role install -r requirements.yml -p roles --force
ansible-galaxy collection install -r requirements.yml --force
```

#### `check`

Runs syntax validation:

```bash
ansible-playbook -i hosts galaxy-role.yml --syntax-check
```

#### `ping`

Tests SSH/Ansible connectivity to the remote host.

#### `deploy`

Runs the Galaxy deployment playbook.

#### `validate`

Checks that the Galaxy API responds through nginx:

```bash
curl -sf http://127.0.0.1/api/version
```

#### `local`

Runs the deployment against localhost.

Only supported on Linux.

#### `clean`

Removes local development/runtime files:

```text
venv/
.tmp/
```

#### `wipe-assets`

Wipes rebuildable Galaxy runtime assets while preserving:

```text
/srv/galaxy/mutable
/srv/galaxy/datasets
PostgreSQL database/user
```

Removes:

```text
/srv/galaxy/config
/srv/galaxy/jobs
/srv/galaxy/local_tools
/srv/galaxy/server
/srv/galaxy/venv
```

Use this when you want to rebuild Galaxy runtime files but keep existing data.

#### `wipe`

Performs a deep cleanup:

- stops Galaxy/nginx/PostgreSQL
- removes Galaxy files
- removes Galaxy systemd units
- purges PostgreSQL packages and data
- preserves the `/srv/galaxy` mount point itself

This is destructive and intended for fresh test redeployments.

---

## Manual Ansible usage

If you prefer running commands manually:

```bash
ansible-galaxy role install -r requirements.yml -p roles --force
ansible-galaxy collection install -r requirements.yml --force
ansible-playbook -i hosts galaxy-role.yml --syntax-check
ansible-playbook -i hosts galaxy-role.yml
```

---

## Running only health checks

If `healthcheck.yml` is tagged in the role, run:

```bash
ansible-playbook -i hosts galaxy-role.yml --tags healthcheck
```

Alternatively, create a small wrapper playbook that imports only:

```text
roles/galaxy_deployment/tasks/healthcheck.yml
```

---

## Safety notes for cleanup commands

Before running destructive commands, verify:

```yaml
galaxy_root: "/srv/galaxy"
```

The cleanup commands are interactive by design.

Important behavior:

- `wipe-assets` preserves PostgreSQL and datasets
- `wipe` removes PostgreSQL packages/data
- both commands preserve the mount point directory itself

Do not delete `datasets` while keeping the database, because the database may reference dataset files.

---

## Validation after deployment

Backend API directly:

```bash
curl http://127.0.0.1:8080/api/version
```

Through nginx HTTP:

```bash
curl http://127.0.0.1/api/version
```

Through nginx HTTPS:

```bash
curl -k https://127.0.0.1/api/version
```

nginx config:

```bash
sudo nginx -t
sudo systemctl status nginx --no-pager
```

Galaxy service:

```bash
sudo systemctl status galaxy --no-pager
sudo journalctl -u galaxy -n 150 --no-pager
```

Static assets:

```bash
ASSET=$(sudo find /srv/galaxy/server/static/dist -type f | head -n 1)
URL="/static/dist/${ASSET#/srv/galaxy/server/static/dist/}"
curl -I "http://127.0.0.1${URL}"
```

Expected:

```text
HTTP/1.1 200 OK
```

---

## Troubleshooting

### Role not found

If Ansible reports:

```text
the role 'galaxy_deployment' was not found
```

Check `ansible.cfg`:

```ini
roles_path = ./roles:~/.ansible/roles:/usr/share/ansible/roles:/etc/ansible/roles
```

And verify the role is installed at:

```text
roles/galaxy_deployment
```

---

### Missing Galaxy dependency role files

If `galaxyproject.galaxy` fails with missing files such as:

```text
Could not find or access 'makepyc.py'
```

reinstall dependencies:

```bash
rm -rf roles/galaxyproject.galaxy
ansible-galaxy role install -r requirements.yml -p roles --force
```

---

### Galaxy falls back to SQLite

Check:

```bash
sudo grep -nE "database_connection|postgresql|sqlite" /srv/galaxy/config/galaxy.yml
```

Expected:

```text
database_connection: postgresql://...
```

If this is missing, Galaxy may use SQLite and jobs may get stuck with database lock errors.

---

### `psycopg2` is missing

If Galaxy logs show:

```text
ModuleNotFoundError: No module named 'psycopg2'
```

install it into the Galaxy virtual environment:

```bash
sudo -u galaxy /srv/galaxy/venv/bin/python -m pip install psycopg2-binary
sudo -u galaxy /srv/galaxy/venv/bin/python -c "import psycopg2"
sudo systemctl restart galaxy
```

---

### API health check retries forever

Check whether Galaxy itself is healthy:

```bash
sudo systemctl status galaxy --no-pager
sudo journalctl -u galaxy -n 150 --no-pager
curl -s http://127.0.0.1:8080/api/version
```

If Galaxy works on `8080` but not through nginx, check nginx:

```bash
sudo nginx -t
sudo systemctl status nginx --no-pager
curl -s http://127.0.0.1/api/version
```

If HTTPS self-signed is enabled:

```bash
curl -k https://127.0.0.1/api/version
```

---

### nginx returns 403 for static assets

Check permissions:

```bash
ASSET=$(sudo find /srv/galaxy/server/static/dist -type f | head -n 1)
namei -l "$ASSET"
```

Fix permissions:

```bash
sudo chmod 0755 /srv/galaxy
sudo chmod 0755 /srv/galaxy/server
sudo find /srv/galaxy/server/static -type d -exec chmod 0755 {} \;
sudo find /srv/galaxy/server/static -type f -exec chmod 0644 {} \;
sudo systemctl restart nginx
```

---

### nginx fails with `unknown directive "http2"`

Use:

```nginx
listen 443 ssl;
```

Do not use:

```nginx
http2 on;
```

This keeps the role compatible with Ubuntu nginx packages.

---

## Reusing the role from another project

Add the role to another project through `requirements.yml`:

```yaml
---
roles:
  - name: galaxy_deployment
    src: git+ssh://git@github.com/yehiafarag/ansible-role-galaxy-deployment.git
    version: v1.0.0
```

Minimum required variables for consumers:

```yaml
galaxy_admin_email: "admin@example.com"
galaxy_database_password: "CHANGE_ME_STRONG_PASSWORD"
```

---

## Development notes

For local testing inside the dedicated role repository, create a local symlink:

```bash
mkdir -p roles
ln -sfn "$PWD" roles/galaxy_deployment
```

Add this to `.gitignore`:

```gitignore
roles/galaxy_deployment
```

---

## License

MIT

---

## Author

Yehia Mokhtar Farag
