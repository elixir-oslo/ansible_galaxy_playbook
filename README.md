# Galaxy Ansible Playbook

An Ansible deployment toolkit for Galaxy with PostgreSQL, Gravity, and Nginx.

The main entrypoint is `deploy.sh`.

## What gets deployed

From `galaxy.yml`, `requirements.yml`, and `group_vars/galaxyservers.yml`:
- Galaxy from `https://github.com/galaxyproject/galaxy.git`
- Galaxy release `release_26.0`
- PostgreSQL 16 and Galaxy DB objects
- Galaxy services via Gravity
- Nginx reverse proxy
- Micromamba-based tool dependency stack

Installed roles (`requirements.yml`):
- `galaxyproject.galaxy` `0.12.1`
- `galaxyproject.nginx` `0.7.1`
- `galaxyproject.postgresql` `1.1.2`
- `galaxyproject.postgresql_objects` `1.2.0`
- `galaxyproject.miniconda` `0.3.3`
- `usegalaxy_eu.certbot` `0.1.13`

## Repository layout

- `deploy.sh`: main interactive deployment script
- `galaxy.yml`: full Galaxy deployment playbook
- `nginx.yml`: standalone Nginx playbook
- `requirements.yml`: Ansible Galaxy role dependencies
- `hosts`: inventory file (auto-updated by `updated_deploy.sh`)
- `group_vars/galaxyservers.yml`: Galaxy/PostgreSQL/Nginx defaults
- `configs/config.yml.example`: config template
- `configs/config.yml`: required config file
- `devops-scripts/one-time-bootstrap.sh`: one-time post-deploy stabilization
- `devops-scripts/fix_nginx_ui_after_deployment.sh`: repeatable nginx/UI repair
- `devops-scripts/validate_galaxy.sh`: runtime validation

## Prerequisites

### Control node (where `updated_deploy.sh` runs)
- `bash`
- `python3`
- `yq`

`deploy.sh` creates `venv/` and installs Python packages (`ansible`, `yq`) inside it.

### Platform notes
- **macOS**: supported as control node.
- **Linux**: supported as control node and required for local Galaxy deployment target.
- Target Galaxy host is expected to be Linux with `systemd` and `/srv/galaxy`-style service paths.

## Configuration

1. Create config file:

```bash
cp configs/config.yml.example configs/config.yml
```

2. Required values used by `deploy.sh`:
- `galaxy.host_ip`
- `galaxy.ssh_user`
- `database.password`

3. Optional value:
- `paths.galaxy_root` (defaults to `/home/ubuntu/galaxy` in script if missing)

The script updates `hosts` automatically using values from `configs/config.yml`.

## Run

```bash
chmod +x deploy.sh
./deploy.sh
```

## Menu actions (`deploy.sh`)

1. Full remote deployment (`full_remote`)
2. Prepare control node (`prepare_control_node`)
3. Install roles (`install_roles`)
4. Test SSH (`test_connection`)
5. Deploy Galaxy (`deploy_remote`)
6. Fix nginx (`fix_nginx`)
7. Validate (`validate_remote`)
8. Local deployment, Linux only (`deploy_local`)
9. Clean local environment (`clean_local`)
10. Clean remote environment (`clean_remote`)
11. Exit

## Recommended flow

### Remote deployment
1. `Prepare control node`
2. `Install roles`
3. `Test SSH`
4. `Deploy Galaxy`
5. `Fix nginx`
6. `Validate`

Or run `Full remote deployment` to execute the scripted sequence.

### Local deployment
Use `Local deployment (Linux only)` after control node prep.

## `galaxy.yml` behavior (current)

`galaxy.yml` runs three plays:
1. Install PostgreSQL role on `galaxyservers`
2. Create DB user/database on `dbservers`
3. Deploy Galaxy + Miniconda + Nginx on `galaxyservers`

Key post-deploy tasks in play 3:
- one-time bootstrap marker flow (`/var/lib/galaxy/bootstrap.done`)
- nginx site setup and Gravity state reset
- API verification through nginx
- static/UI repair and nginx reload
- final health checks for `gunicorn`, port `8080`, and API response

## Validation and maintenance scripts
- `devops-scripts/validate_galaxy.sh`: service/API/DB validation

## Common checks

- internal API: `http://127.0.0.1:8080/api/version`
- external API via nginx: `http://<server>/api/version`
- UI: `http://<server>/`

## Troubleshooting

- If `configs/config.yml` is missing, script exits.
- If `yq` is missing, script exits with instruction to install it.
- If SSH test fails, verify host/user/network and rerun `Test SSH`.
- If deployment fails, rerun `Fix nginx` then `Validate`.

## License

See `LICENSE`.
