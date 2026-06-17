# ansible-role-galaxy-deployment
usable Galaxy deployment role for production-style Galaxy baseline.
# Using `galaxy_deployment` as a Reusable Role

This document explains how to use the generated `galaxy_deployment` role from another Ansible project.

The generated role deploys a production-style Galaxy stack with:

- PostgreSQL 16
- Galaxy `release_26.0`
- Galaxy backend on `127.0.0.1:8080`
- Galaxy client build using `make client-production`
- Manual nginx configuration for `/static/`
- Backend API health checks and a final deployment summary

The goal is to let other projects reuse the Galaxy deployment without copying the full `galaxy.yml` playbook.

---

## Quick deploy with `deploy.sh`

`deploy.sh` is the main wrapper for deploying Galaxy using `playbooks/galaxy-role.yml`, with both command and interactive menu modes.

### Required input

Set these values in `group_vars/galaxyservers.yml`:

```yaml
galaxy:
  host_ip: "<VM_IP_OR_HOSTNAME>"
  ssh_user: "<SSH_USER>"
```

### Script commands

```bash
./deploy.sh          # default: open interactive deployment menu
./deploy.sh deploy   # run playbook deploy sequence directly
./deploy.sh check    # syntax check only
./deploy.sh ping     # ansible ping against galaxyservers
./deploy.sh prepare  # prepare/update local venv and ansible
./deploy.sh wipe-assets  # wipe Galaxy server assets but keep PostgreSQL files
./deploy.sh menu     # interactive menu (same as default)
./deploy.sh help
```

If you want to run manually without the wrapper script, use:

```bash
ansible-playbook -i hosts playbooks/galaxy-role.yml
```

### Manual run from `hosts.sample`

If you want to manage inventory manually:

```bash
cp hosts.sample hosts
```

Then edit `hosts` and replace:

- `YOUR_SERVER_IP_OR_DOMAIN` with your VM IP or DNS
- `YOUR_SSH_USER` with your SSH user

Also ensure `group_vars/galaxyservers.yml` has at least:

```yaml
galaxy_admin_email: "admin@example.com"
galaxy_database_password: "CHANGE_ME_STRONG_PASSWORD"
```

Run the playbook manually:

```bash
ansible-playbook -i hosts playbooks/galaxy-role.yml --syntax-check
ansible-playbook -i hosts playbooks/galaxy-role.yml
```

---

## Use this as a role in another project

Use this flow if you want to consume `galaxy_deployment` from your own Ansible repository.

1. Copy role dependencies into your project `requirements.yml`:

```yaml
---
roles:
    #  Galaxy baseline role used by the ImmuneML orchestrator.
  - name: galaxy_deployment
    src: git+ssh://git@github.com/yehiafarag/ansible-role-galaxy-deployment.git
    version: galaxy-role-v1.0.0

    # External roles required by galaxy_deployment.
  - name: galaxyproject.postgresql
    version: 1.1.2
  - name: galaxyproject.postgresql_objects
    version: 1.2.0
  - name: galaxyproject.galaxy
    version: 0.12.1
  - name: galaxyproject.miniconda
    version: 0.3.3
```

2. Add required role configuration to your `group_vars/galaxyservers.yml`:

```yaml
galaxy_admin_email: "admin@example.com"
galaxy_database_password: "CHANGE_ME_STRONG_PASSWORD"
```

3. Create inventory from sample and replace placeholders:

```bash
cp hosts.sample hosts
```

Update in `hosts`:
- `YOUR_SERVER_IP_OR_DOMAIN`
- `YOUR_SSH_USER`

4. Install role dependencies and run:

```bash
ansible-galaxy install -r requirements.yml --force
ansible-playbook -i hosts playbooks/galaxy-role.yml --syntax-check
ansible-playbook -i hosts playbooks/galaxy-role.yml
```

### Optional wrapper play pattern

If you want health-aware redeploy behavior in your own project, you can use `ansible.builtin.include_role` and conditionally run the role:

```yaml
- name: Redeploy Galaxy baseline when unhealthy
  hosts: galaxyservers
  become: true
  tasks:
    - name: Run galaxy_deployment role when Galaxy is unhealthy
      ansible.builtin.include_role:
        name: galaxy_deployment
      when: galaxy_needs_redeploy | default(true) | bool
```

You can also add a second play to enforce static file permissions for nginx (like your PLAY 2B pattern).

---

## 1. Role location

The reusable role is:

```text
galaxy_deployment
```

Expected role path inside a project:

```text
roles/galaxy_deployment/
```

Expected role layout:

```text
roles/galaxy_deployment/
├── defaults/
│   └── main.yml
├── handlers/
│   └── main.yml
└── tasks/
    ├── main.yml
    ├── preflight.yml
    ├── postgresql.yml
    ├── db_objects.yml
    ├── galaxy_server.yml
    ├── backend_start.yml
    ├── client_build.yml
    ├── nginx.yml
    └── healthcheck.yml
```

---

## 2. Configuration model

The role is designed so users do **not** need to configure every Galaxy variable manually.

Most defaults are provided by:

```text
roles/galaxy_deployment/defaults/main.yml
```

Users normally only need to provide:

```yaml
galaxy_admin_email: "admin@example.com"
galaxy_database_password: "CHANGE_ME_STRONG_PASSWORD"

```

For role-only/manual inventory usage, only `galaxy_admin_email` and `galaxy_database_password` are required.

`galaxy.host_ip` and `galaxy.ssh_user` are only needed when you generate inventory from `deploy.sh`.

Everything else can use role defaults.

You can still override any default in:

```text
group_vars/galaxyservers.yml
```

if needed.

---

## 3. Minimum required configuration

Create or update:

```text
group_vars/galaxyservers.yml
```

Minimum example (role-only/manual inventory):

```yaml
# ---------------------------------------------------------------------
# Galaxy admin
# ---------------------------------------------------------------------
galaxy_admin_email: "admin@example.com"

# ---------------------------------------------------------------------
# Database secret
# ---------------------------------------------------------------------
galaxy_database_password: "CHANGE_ME_STRONG_PASSWORD"

```

If you use `deploy.sh` inventory generation, also include:

```yaml
galaxy:
  host_ip: "<VM_IP_OR_HOSTNAME>"
  ssh_user: "<SSH_USER>"
```

That is the minimal user-facing configuration.

The role provides defaults for:

```text
Galaxy paths
Galaxy user
Galaxy repository
Galaxy backend port
PostgreSQL database name/user/host/port
Client build strategy
Systemd environment
Galaxy app config paths
nginx behavior
```

---

## 4. Optional common overrides

Only override these if your deployment needs different values.

```yaml
# Install Galaxy somewhere else
galaxy_root: "/srv/galaxy"

# Use another Galaxy branch/tag/commit
galaxy_commit_id: release_26.0

# Change backend port
galaxy_web_port: 8080

# Disable client build if static/dist already exists
build_galaxy_client_after_api: false

# Change SSH user metadata if using deploy.sh
galaxy:
  host_ip: "<VM_IP_OR_HOSTNAME>"
  ssh_user: "ubuntu"
```

---

## 5. Defaults in the generated role

The sync script writes defaults to:

```text
roles/galaxy_deployment/defaults/main.yml
```

Important generated defaults include:

```yaml
---

# ---------------------------------------------------------------------
# Galaxy root paths
# ---------------------------------------------------------------------
galaxy_root: "/srv/galaxy"
galaxy_layout: root-dir

galaxy_server_dir: "{{ galaxy_root }}/server"
galaxy_config_dir: "{{ galaxy_root }}/config"
galaxy_mutable_data_dir: "{{ galaxy_root }}/mutable"
galaxy_mutable_config_dir: "{{ galaxy_mutable_data_dir }}/config"
galaxy_cache_dir: "{{ galaxy_mutable_data_dir }}/cache"
galaxy_shed_tools_dir: "{{ galaxy_mutable_data_dir }}/shed_tools"
galaxy_tool_data_path: "{{ galaxy_mutable_data_dir }}/tool_data"
galaxy_local_tools_dir: "{{ galaxy_root }}/local_tools"
galaxy_virtual_env: "{{ galaxy_root }}/venv"

# ---------------------------------------------------------------------
# Galaxy user/path/systemd behavior
# ---------------------------------------------------------------------
galaxy_user_name: galaxy

galaxy_user:
  name: "{{ galaxy_user_name }}"
  shell: /bin/bash

galaxy_create_user: true
galaxy_manage_paths: true
galaxy_manage_systemd: true
galaxy_separate_privileges: true

# ---------------------------------------------------------------------
# Galaxy repository
# ---------------------------------------------------------------------
galaxy_repo: https://github.com/galaxyproject/galaxy.git
galaxy_commit_id: release_26.0
galaxy_force_checkout: true

# ---------------------------------------------------------------------
# Galaxy backend
# ---------------------------------------------------------------------
galaxy_web_port: 8080

galaxy_systemd_environment:
  HOME: "{{ galaxy_root }}"
  PATH: "{{ galaxy_virtual_env }}/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/bin"


# ---------------------------------------------------------------------
# Gravity config
# ---------------------------------------------------------------------
galaxy_config:
  gravity:
    galaxy_user: "{{ galaxy_user_name }}"
    galaxy_root: "{{ galaxy_server_dir }}"
    virtualenv: "{{ galaxy_virtual_env }}"

# ---------------------------------------------------------------------
# Galaxy admin defaults
# ---------------------------------------------------------------------
galaxy_admin_email: ""

admin:
  email: "{{ galaxy_admin_email }}"

# ---------------------------------------------------------------------
# PostgreSQL defaults
# ---------------------------------------------------------------------
galaxy_database_user: "galaxy"
galaxy_database_name: "galaxy"
galaxy_database_host: "localhost"
galaxy_database_port: 5432
galaxy_database_password: ""

database:
  user: "{{ galaxy_database_user }}"
  name: "{{ galaxy_database_name }}"
  host: "{{ galaxy_database_host }}"
  port: "{{ galaxy_database_port }}"
  password: "{{ galaxy_database_password }}"

postgresql_objects_users:
  - name: "{{ database.user }}"
    password: "{{ database.password }}"

postgresql_objects_databases:
  - name: "{{ database.name }}"
    owner: "{{ database.user }}"

# ---------------------------------------------------------------------
# Miniconda / tool dependency defaults
# ---------------------------------------------------------------------
miniconda_prefix: "{{ galaxy_mutable_data_dir }}/dependencies/_conda"
miniconda_version: latest

miniconda_channels:
  - conda-forge
  - bioconda
  - defaults

miniconda_manage_dependencies: true
miniconda_conda_environments: []


# ---------------------------------------------------------------------
# Client build strategy
# ---------------------------------------------------------------------
build_galaxy_client_after_api: true

galaxy_client_use_prebuilt: false
galaxy_build_client: false
galaxy_client_make: false
galaxy_skip_client_build: true
galaxy_manage_node: false
galaxy_create_web_server_config: false

# ---------------------------------------------------------------------
# Galaxy app config
# ---------------------------------------------------------------------
galaxy_app_config:
  galaxy:
    root: "{{ galaxy_server_dir }}"
    database_connection: "postgresql://{{ database.user }}:{{ database.password }}@{{ database.host }}:{{ database.port }}/{{ database.name }}?client_encoding=utf8"

    data_dir: "{{ galaxy_mutable_data_dir }}"
    file_path: "{{ galaxy_mutable_data_dir }}/datasets"
    job_working_directory: "{{ galaxy_mutable_data_dir }}/job_working_directory"

    tool_config_file: "{{ galaxy_mutable_data_dir }}/config/tool_conf.xml"
    tool_dependency_dir: "{{ galaxy_mutable_data_dir }}/dependencies"
    tool_data_path: "{{ galaxy_mutable_data_dir }}/tool_data"

    tool_data_table_config_path: "{{ galaxy_server_dir }}/config/tool_data_table_conf.xml.sample"
    shed_tool_data_table_config: "{{ galaxy_mutable_data_dir }}/config/shed_tool_data_table_conf.xml"
    integrated_tool_panel_config: "{{ galaxy_mutable_data_dir }}/config/integrated_tool_panel.xml"
    migrated_tools_config: "{{ galaxy_mutable_data_dir }}/config/migrated_tools_conf.xml"

    dependency_resolvers_config_file: "{{ galaxy_config_dir }}/dependency_resolvers_conf.xml"
    job_metrics_config_file: "{{ galaxy_config_dir }}/job_metrics_conf.xml"

    datatypes_config_file: "{{ galaxy_server_dir }}/config/datatypes_conf.xml.sample"
    openid_config_file: "{{ galaxy_server_dir }}/config/openid_conf.xml.sample"
    themes_config_file: "{{ galaxy_config_dir }}/themes_conf.yml"

    visualization_plugins_directory: config/plugins/visualizations

    static_enabled: true
    static_dir: "{{ galaxy_server_dir }}/static"
```

Important:

```yaml
database:
  password: ""
```

is only a placeholder. The consuming project must set a real database password in `group_vars/galaxyservers.yml` or Ansible Vault.

---

## 6. Validation tasks generated by sync

The sync script injects preflight validation so the role fails early when required values are missing.

Generated checks in:

```text
roles/galaxy_deployment/tasks/preflight.yml
```

```yaml

- name: Validate required database password is set
  assert:
    that:
      - galaxy_database_password is defined
      - galaxy_database_password | length > 0
    fail_msg: "galaxy_database_password must be set in group_vars/galaxyservers.yml or Ansible Vault."

- name: Validate admin email is set
  assert:
    that:
      - galaxy_admin_email is defined
      - galaxy_admin_email | length > 0
    fail_msg: "galaxy_admin_email must be set in group_vars/galaxyservers.yml."

```

`sync_galaxy_playbook_to_role.py` currently does not inject host metadata asserts for `galaxy.host_ip` and `galaxy.ssh_user`.

If your consuming project relies on `deploy.sh` inventory generation, you can add this optional check:

```yaml
- name: Validate Galaxy host metadata is set
  assert:
    that:
      - galaxy.host_ip is defined
      - galaxy.host_ip | length > 0
      - galaxy.ssh_user is defined
      - galaxy.ssh_user | length > 0
    fail_msg: "galaxy.host_ip and galaxy.ssh_user must be set when using deploy.sh inventory generation."
```

---

## 7. Required Ansible configuration

A consuming project should include an `ansible.cfg` file like this:

```ini
[defaults]
interpreter_python = /usr/bin/python3
allow_world_readable_tmpfiles = True
remote_tmp = /tmp/.ansible-${USER}
roles_path = ./roles:~/.ansible/roles:/usr/share/ansible/roles:/etc/ansible/roles
host_key_checking = False
retry_files_enabled = False

[privilege_escalation]
become_method = sudo
become_flags = -H -n
become_allow_world_readable_tmpfiles = True
```

Important setting:

```ini
roles_path = ./roles:~/.ansible/roles:/usr/share/ansible/roles:/etc/ansible/roles
```

This allows Ansible to find both:

```text
./roles/galaxy_deployment
~/.ansible/roles/galaxyproject.*
```

---

## 8. Required external roles

The `galaxy_deployment` role depends on these external roles:

```yaml
---
roles:
  - name: galaxyproject.postgresql
    version: 1.1.2

  - name: galaxyproject.postgresql_objects
    version: 1.2.0

  - name: galaxyproject.galaxy
    version: 0.12.1

  - name: galaxyproject.miniconda
    version: 0.3.3
```

Install them with:

```bash
ansible-galaxy install -r requirements.yml --force
```

---

## 9. Required inventory

The role expects two inventory groups:

```text
galaxyservers
dbservers
```

For a single-VM deployment, both can point to the same host.

Example `hosts` file:

```ini
[galaxyservers]
galaxy ansible_host=<VM_IP_OR_SSH_ALIAS> ansible_user=ubuntu ansible_become=true ansible_python_interpreter=/usr/bin/python3

[dbservers]
galaxy ansible_host=<VM_IP_OR_SSH_ALIAS> ansible_user=ubuntu ansible_become=true ansible_python_interpreter=/usr/bin/python3
```


---

## 10. Required VM storage

Galaxy is deployed under:

```text
/srv/galaxy
```

Recommended storage:

```text
100 GB or larger mounted at /srv/galaxy
```

Check on the VM:

```bash
df -h /srv/galaxy
findmnt /srv/galaxy
```

Expected example:

```text
/dev/sdb   98G   ...   /srv/galaxy
```

Important cleanup rule:

```bash
# Do not remove the mount point itself
sudo rm -rf /srv/galaxy
```

Use this instead:

```bash
sudo find /srv/galaxy -mindepth 1 -maxdepth 1 -exec rm -rf {} +
```

---

## 11. Wrapper playbook

In this repository, the wrapper playbook is generated at:

```text
playbooks/galaxy-role.yml
```

Generated example:

```yaml
---
- name: Deploy Galaxy using galaxy_deployment role
  hosts: galaxyservers
  become: true

  vars_files:
    - ../group_vars/galaxyservers.yml

  roles:
    - role: galaxy_deployment
```

In a separate consuming project, you can use the same content with any playbook name (for example `playbooks/galaxy.yml`).

Create a wrapper playbook in the consuming project:

```text
playbooks/galaxy.yml
```

Example:

```yaml
---
- name: Deploy Galaxy using reusable galaxy_deployment role
  hosts: galaxyservers
  become: true

  vars_files:
    - ../group_vars/galaxyservers.yml

  roles:
    - role: galaxy_deployment
```

Run syntax check:

```bash
ansible-playbook -i hosts playbooks/galaxy.yml --syntax-check
```

Run deployment:

```bash
ansible-playbook -i hosts playbooks/galaxy.yml
```

---

## 12. Example consuming project layout

A separate project using the role can look like this:

```text
my_galaxy_project/
├── ansible.cfg
├── hosts
├── requirements.yml
├── playbooks/
│   └── galaxy.yml
├── group_vars/
│   └── galaxyservers.yml
└── roles/
    └── galaxy_deployment/
```

---

## 13. Using the role from another project

There are three supported approaches.

### Option 1 — Copy the role folder

Copy:

```text
roles/galaxy_deployment/
```

into the other project:

```text
my_galaxy_project/roles/galaxy_deployment/
```

### Option 2 — Install from a dedicated Git role repository

If the role is published in a dedicated repository, add it to `requirements.yml`:

```yaml
---
roles:
  - name: galaxy_deployment
    src: git+ssh://git@github.com/yehiafarag/ansible_galaxy_playbook.git
    version: galaxy-deployment-role-v1.0.1
```

Use the latest published `galaxy-deployment-role-v*` tag when pinning.

Install it:

```bash
ansible-galaxy role install -r requirements.yml -p roles/
```

### Option 3 — Use a Git submodule

```bash
git submodule add https://github.com/yehiafarag/ansible_galaxy_playbook.git roles/galaxy_deployment
git submodule update --init --recursive
```

---

## 14. Deployment flow inside the role

The role runs in this order:

```text
preflight.yml
  Prepare system dependencies, Galaxy user, Node.js 22, Corepack, and cache paths

postgresql.yml
  Install PostgreSQL 16

db_objects.yml
  Create Galaxy database user and database

galaxy_server.yml
  Run galaxyproject.galaxy and galaxyproject.miniconda

backend_start.yml
  Start Galaxy backend and validate http://127.0.0.1:8080/api/version

client_build.yml
  Stop Galaxy, build UI with make client-production, and validate static/dist

nginx.yml
  Configure nginx to serve /static/ and proxy to 127.0.0.1:8080

healthcheck.yml
  Print final deployment summary
```

---

## 15. Client build behavior

The role intentionally prevents `galaxyproject.galaxy` from building the client too early:

```yaml
galaxy_build_client: false
galaxy_skip_client_build: true
```

Instead, the role builds the client after the backend API is healthy:

```text
Start Galaxy backend
→ Validate /api/version
→ Stop Galaxy
→ Run make client-production
→ Validate static/dist
→ Start Galaxy again
```

Expected static output:

```text
/srv/galaxy/server/static/dist/*.js
/srv/galaxy/server/static/dist/*.css
/srv/galaxy/server/static/dist/*.woff
/srv/galaxy/server/static/dist/*.ttf
```

Client build can take several minutes.

Monitor it on the VM:

```bash
ps aux | grep -E "node|pnpm|make|vite|esbuild" | grep -v grep
watch -n 5 "du -sh /srv/galaxy/server/client/node_modules /srv/galaxy/server/static/dist 2>/dev/null"
```

---

## 16. nginx behavior

Galaxy backend listens on:

```text
127.0.0.1:8080
```

nginx listens on port `80` and handles:

```text
/static/  → /srv/galaxy/server/static/
/         → http://127.0.0.1:8080
```

Important nginx static block:

```nginx
location /static/ {
    alias /srv/galaxy/server/static/;
    expires 30d;
    add_header Cache-Control "public, max-age=2592000";
    access_log off;
}
```

The trailing slash in:

```nginx
alias /srv/galaxy/server/static/;
```

is important.

---

## 17. Validation after deployment

Validate Galaxy backend directly:

```bash
curl http://127.0.0.1:8080/api/version
```

Expected:

```json
{"version_major":"26.0","version_minor":"2.dev0"}
```

Validate client files:

```bash
find /srv/galaxy/server/static/dist -type f | head -n 10
du -sh /srv/galaxy/server/static/dist
```

Validate nginx:

```bash
sudo nginx -t
sudo systemctl status nginx --no-pager
```

Validate Galaxy API through nginx:

```bash
curl http://127.0.0.1/api/version
```

Validate static file through nginx:

```bash
ASSET=$(find /srv/galaxy/server/static/dist -type f | head -n 1)
URL="/static/dist/${ASSET#/srv/galaxy/server/static/dist/}"
curl -I "http://127.0.0.1${URL}"
```

Expected:

```text
HTTP/1.1 200 OK
```

---

## 18. Important note about static files

In this deployment style, Galaxy backend on port `8080` may not serve `/static/dist/...` directly.

This may return `404`:

```bash
curl -I http://127.0.0.1:8080/static/dist/<asset>.js
```

That is expected.

Static files should be served through nginx:

```bash
curl -I http://127.0.0.1/static/dist/<asset>.js
```

---

## 19. Troubleshooting

### Role not found

Check `ansible.cfg`:

```ini
roles_path = ./roles:~/.ansible/roles:/usr/share/ansible/roles:/etc/ansible/roles
```

### PostgreSQL 16 package not found

Make sure PGDG is enabled:

```yaml
postgresql_use_pgdg: true
```

### `virtualenv` missing

Make sure the target has:

```yaml
python3-virtualenv
python3-pip
```

### Gunicorn spawn error caused by `/srv/galaxy/.cache`

Ensure cache exists and is owned by the Galaxy user:

```bash
sudo mkdir -p /srv/galaxy/.cache
sudo chown -R galaxy:galaxy /srv/galaxy/.cache
```

The role handles this in `preflight.yml`.

### Static files return 404 through nginx

Check nginx config:

```bash
sudo cat /etc/nginx/sites-available/galaxy
```

The static block must use:

```nginx
location /static/ {
    alias /srv/galaxy/server/static/;
}
```

The trailing slash matters.

---

## 20. Stable role release recommendation

After a successful role-based deployment, tag the repository:

```bash
git tag galaxy-deployment-role-v1.0.1
git push origin galaxy-deployment-role-v1.0.1
```

If using the role from Git, pin consuming projects to a published `galaxy-deployment-role-v*` tag.
