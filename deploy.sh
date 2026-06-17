
#!/usr/bin/env bash
set -Eeuo pipefail

OS_NAME="$(uname -s)"
DEPLOYMENT_MODE="remote"

if [[ -t 1 ]]; then
  RED='\033[0;31m'
  GREEN='\033[0;32m'
  YELLOW='\033[1;33m'
  BLUE='\033[0;34m'
  NC='\033[0m'
else
  RED=''
  GREEN=''
  YELLOW=''
  BLUE=''
  NC=''
fi

step()    { echo -e "${BLUE}[INFO]${NC} $1"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
success() { echo -e "${GREEN}[OK]${NC} $1"; }
error()   { echo -e "${RED}[ERROR]${NC} $1" >&2; exit 1; }

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
VENV_DIR="$PROJECT_DIR/venv"
LOCAL_TMP="$PROJECT_DIR/.tmp"
CONFIG_FILE="$PROJECT_DIR/group_vars/galaxyservers.yml"
INVENTORY_FILE="$PROJECT_DIR/hosts"
PLAYBOOK="$PROJECT_DIR/galaxy-role.yml"
DEFAULT_REMOTE_ROOT="/srv/galaxy"

GALAXY_HOST_IP=""
GALAXY_SSH_USER=""
GALAXY_ROOT=""

usage() {
  cat <<EOF
Usage: ./deploy.sh [command]

Commands:
  menu         Open the interactive deployment menu (default)
  full         Run full remote pipeline
  prepare      Prepare local control node
  install      Install Ansible role and collection dependencies
  check        Run playbook syntax check
  ping         Ping remote hosts
  deploy       Execute playbook deploy
  validate     Run remote Galaxy API validation
  local        Deploy against localhost (Linux only)
  clean        Clean local workspace
  wipe-assets  Wipe remote Galaxy runtime assets only, keeping DB/datasets/mutable
  wipe         Deep wipe remote runtime data and PostgreSQL packages/data
  help         Show this help
EOF
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || error "Missing required command: $1"
}

activate_venv() {
  if [[ ! -f "$VENV_DIR/bin/activate" ]]; then
    warn "Missing virtualenv at $VENV_DIR. Running local control node preparation."
    prepare_control_node
  fi

  [[ -f "$VENV_DIR/bin/activate" ]] || error "Virtualenv activation file is still missing at $VENV_DIR/bin/activate"

  # shellcheck disable=SC1091
  source "$VENV_DIR/bin/activate"
}

load_config() {
  step "Loading unified configuration file"

  [[ -f "$CONFIG_FILE" ]] || error "Missing target file: group_vars/galaxyservers.yml"

  activate_venv
  require_cmd yq

  GALAXY_HOST_IP="$(yq -r '.galaxy.host_ip' "$CONFIG_FILE")"
  GALAXY_SSH_USER="$(yq -r '.galaxy.ssh_user' "$CONFIG_FILE")"
  GALAXY_ROOT="$(yq -r '.galaxy_root // "'"$DEFAULT_REMOTE_ROOT"'"' "$CONFIG_FILE")"

  [[ -n "$GALAXY_HOST_IP" && "$GALAXY_HOST_IP" != "null" ]] || error "Missing 'galaxy.host_ip' entry in group_vars/galaxyservers.yml"
  [[ -n "$GALAXY_SSH_USER" && "$GALAXY_SSH_USER" != "null" ]] || error "Missing 'galaxy.ssh_user' entry in group_vars/galaxyservers.yml"

  if [[ -z "$GALAXY_ROOT" || "$GALAXY_ROOT" == "null" ]]; then
    GALAXY_ROOT="$DEFAULT_REMOTE_ROOT"
  fi

  success "Configuration validated and parsed successfully"
}

generate_inventory() {
  step "Generating inventory host mapping file"

  if [[ "$DEPLOYMENT_MODE" == "local" ]]; then
    cat > "$INVENTORY_FILE" <<EOF
[galaxyservers]
localhost ansible_connection=local ansible_python_interpreter=/usr/bin/python3

[dbservers]
localhost ansible_connection=local ansible_python_interpreter=/usr/bin/python3
EOF
  else
    cat > "$INVENTORY_FILE" <<EOF
[galaxyservers]
galaxy ansible_host=$GALAXY_HOST_IP ansible_user=$GALAXY_SSH_USER ansible_become=true ansible_become_method=sudo ansible_python_interpreter=/usr/bin/python3

[dbservers]
galaxy ansible_host=$GALAXY_HOST_IP ansible_user=$GALAXY_SSH_USER ansible_become=true ansible_become_method=sudo ansible_python_interpreter=/usr/bin/python3
EOF
  fi

  success "Hosts inventory updated at: $INVENTORY_FILE"
}

prepare_control_node() {
  step "Setting up local Python virtual environment execution context"

  require_cmd python3

  mkdir -p "$LOCAL_TMP/ansible_tmp"
  chmod 700 "$LOCAL_TMP/ansible_tmp"
  export ANSIBLE_LOCAL_TEMP="$LOCAL_TMP/ansible_tmp"

  if [[ ! -d "$VENV_DIR" ]]; then
    python3 -m venv "$VENV_DIR"
  fi

  # shellcheck disable=SC1091
  source "$VENV_DIR/bin/activate"

  python -m pip install --upgrade pip setuptools wheel
  python -m pip install --upgrade ansible yq PyYAML

  success "Control node operational dependencies established"
}

install_roles() {
  step "Installing Ansible role and collection requirements"

  activate_venv

  if [[ -f "$PROJECT_DIR/requirements.yml" ]]; then
    ansible-galaxy role install -r "$PROJECT_DIR/requirements.yml" -p "$PROJECT_DIR/roles" --force || true
    ansible-galaxy collection install -r "$PROJECT_DIR/requirements.yml" --force || true
    success "Ansible roles and collections fetched successfully"
  else
    warn "No requirements.yml found at $PROJECT_DIR/requirements.yml"
  fi
}

validate_playbook() {
  step "Validating playbook code syntax rules"

  activate_venv
  load_config
  generate_inventory

  ansible-playbook -i "$INVENTORY_FILE" "$PLAYBOOK" --syntax-check

  success "Playbook configuration structural checking completed successfully"
}

test_connection() {
  load_config
  generate_inventory

  step "Testing connection capabilities to remote system host"

  activate_venv

  ansible galaxyservers -i "$INVENTORY_FILE" -m ping || error "Failed to establish a connection with the remote machine over SSH."

  success "Remote SSH authentication successful"
}

deploy_remote() {
  load_config
  generate_inventory

  step "Initiating remote automation play run processing steps"

  activate_venv

  ansible-playbook -i "$INVENTORY_FILE" "$PLAYBOOK" --flush-cache

  success "Playbook run successfully complete"
}

validate_remote() {
  load_config
  generate_inventory

  step "Querying running status from production web services endpoint"

  activate_venv

  ansible galaxyservers -i "$INVENTORY_FILE" -b -m shell -a "curl -sf http://127.0.0.1/api/version" \
    || error "Galaxy API endpoint is not responding."

  success "Galaxy platform web engine responding with normal parameters"
}

full_remote() {
  prepare_control_node
  install_roles
  validate_playbook
  test_connection
  deploy_remote
  validate_remote

  success "FULL REMOTE AUTOMATION PIPELINE FINISHED"
}

deploy_local() {
  DEPLOYMENT_MODE="local"

  [[ "$OS_NAME" == "Linux" ]] || error "Local system installations are only supported on Linux targets"

  load_config
  generate_inventory

  step "Executing automation play routines against local target localhost instance"

  activate_venv

  ansible-playbook -i "$INVENTORY_FILE" "$PLAYBOOK" --flush-cache

  success "Local system execution operations completed successfully"
}

clean_local() {
  step "Cleaning local execution space assets"

  read -rp "Delete control isolation venv and dependency download directory trees? (y/n) [default=n]: " ans
  ans="${ans:-n}"

  if [[ ! "$ans" =~ ^[Yy]$ ]]; then
    step "Local deletion operations canceled"
    return 0
  fi

  rm -rf "$VENV_DIR" "$LOCAL_TMP"

  success "Local dependency footprints cleared successfully"
}

run_remote_script() {
  local script_path="$1"

  ansible galaxyservers -i "$INVENTORY_FILE" -b \
    -m ansible.builtin.script \
    -a "$script_path"
}

stop_remote_galaxy_processes() {
  step "Stopping Galaxy-related services and processes"

  local tmp_script
  tmp_script="$(mktemp)"

  cat > "$tmp_script" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail

GALAXY_ROOT="${GALAXY_ROOT:-/srv/galaxy}"

echo "[INFO] Stopping Galaxy systemd units if present"
systemctl stop galaxy 2>/dev/null || true
systemctl stop galaxy-gunicorn 2>/dev/null || true
systemctl stop galaxy-celery 2>/dev/null || true
systemctl stop galaxy-celery-beat 2>/dev/null || true
systemctl stop galaxy-reports 2>/dev/null || true

echo "[INFO] Killing leftover Galaxy processes only"
pkill -f "\$GALAXY_ROOT/venv/bin/galaxyctl" 2>/dev/null || true
pkill -f "\$GALAXY_ROOT/server" 2>/dev/null || true
pkill -f "gunicorn.*\$GALAXY_ROOT" 2>/dev/null || true
pkill -f "celery.*\$GALAXY_ROOT" 2>/dev/null || true
pkill -f "supervisord.*\$GALAXY_ROOT" 2>/dev/null || true
pkill -f "node.*\$GALAXY_ROOT/server/client" 2>/dev/null || true
pkill -f "pnpm.*\$GALAXY_ROOT/server/client" 2>/dev/null || true
pkill -f "yarn.*\$GALAXY_ROOT/server/client" 2>/dev/null || true

sleep 2

echo "[INFO] Force-killing remaining Galaxy processes only"
pkill -9 -f "\$GALAXY_ROOT/venv/bin/galaxyctl" 2>/dev/null || true
pkill -9 -f "\$GALAXY_ROOT/server" 2>/dev/null || true
pkill -9 -f "gunicorn.*\$GALAXY_ROOT" 2>/dev/null || true
pkill -9 -f "celery.*\$GALAXY_ROOT" 2>/dev/null || true
pkill -9 -f "supervisord.*\$GALAXY_ROOT" 2>/dev/null || true

systemctl reset-failed || true

echo "[OK] Galaxy process cleanup completed"
EOF

  chmod +x "$tmp_script"
  run_remote_script "$tmp_script" || true
  rm -f "$tmp_script"
}

remove_remote_galaxy_systemd_units() {
  step "Removing Galaxy systemd unit files"

  local tmp_script
  tmp_script="$(mktemp)"

  cat > "$tmp_script" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

rm -f /etc/systemd/system/galaxy.service
rm -f /etc/systemd/system/galaxy-gunicorn.service
rm -f /etc/systemd/system/galaxy-celery.service
rm -f /etc/systemd/system/galaxy-celery-beat.service
rm -f /etc/systemd/system/galaxy-reports.service

rm -f /etc/systemd/system/multi-user.target.wants/galaxy.service
rm -f /etc/systemd/system/multi-user.target.wants/galaxy-gunicorn.service
rm -f /etc/systemd/system/multi-user.target.wants/galaxy-celery.service
rm -f /etc/systemd/system/multi-user.target.wants/galaxy-celery-beat.service
rm -f /etc/systemd/system/multi-user.target.wants/galaxy-reports.service

systemctl daemon-reload
systemctl reset-failed || true

echo "[OK] Galaxy systemd unit cleanup completed"
EOF

  chmod +x "$tmp_script"
  run_remote_script "$tmp_script" || true
  rm -f "$tmp_script"
}

purge_remote_runtime_keep_db() {
  step "Purging Galaxy runtime directories while preserving mutable and datasets"

  local tmp_script
  tmp_script="$(mktemp)"

  cat > "$tmp_script" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail

GALAXY_ROOT="${GALAXY_ROOT:-/srv/galaxy}"

if [ -z "\$GALAXY_ROOT" ] || [ "\$GALAXY_ROOT" = "/" ] || [ "\$GALAXY_ROOT" = "/srv" ]; then
  echo "[ERROR] Unsafe GALAXY_ROOT: \$GALAXY_ROOT"
  exit 1
fi

if [ -d "\$GALAXY_ROOT" ]; then
  for d in config jobs local_tools server venv; do
    target="\$GALAXY_ROOT/\$d"
    echo "[INFO] Removing \$target"
    rm -rf "\$target"
  done
else
  echo "[INFO] Creating \$GALAXY_ROOT"
  mkdir -p "\$GALAXY_ROOT"
fi

chown root:root "\$GALAXY_ROOT"
chmod 0755 "\$GALAXY_ROOT"

echo "[INFO] Preserved directories if present:"
ls -ld "\$GALAXY_ROOT/mutable" 2>/dev/null || true
ls -ld "\$GALAXY_ROOT/datasets" 2>/dev/null || true

systemctl daemon-reload
systemctl reset-failed || true

echo "[OK] Runtime directory purge completed"
EOF

  chmod +x "$tmp_script"
  run_remote_script "$tmp_script" || true
  rm -f "$tmp_script"
}

purge_remote_everything_keep_mount() {
  step "Purging Galaxy contents while preserving mount point"

  local tmp_script
  tmp_script="$(mktemp)"

  cat > "$tmp_script" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail

GALAXY_ROOT="${GALAXY_ROOT:-/srv/galaxy}"

if [ -z "\$GALAXY_ROOT" ] || [ "\$GALAXY_ROOT" = "/" ] || [ "\$GALAXY_ROOT" = "/srv" ]; then
  echo "[ERROR] Unsafe GALAXY_ROOT: \$GALAXY_ROOT"
  exit 1
fi

if [ -d "\$GALAXY_ROOT" ]; then
  find "\$GALAXY_ROOT" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
else
  mkdir -p "\$GALAXY_ROOT"
fi

chown root:root "\$GALAXY_ROOT"
chmod 0755 "\$GALAXY_ROOT"

echo "[OK] Full Galaxy root purge completed"
EOF

  chmod +x "$tmp_script"
  run_remote_script "$tmp_script" || true
  rm -f "$tmp_script"
}

wipe_remote_assets_keep_db() {
  load_config
  generate_inventory
  activate_venv

  warn "DANGER WARNING: This operation destroys Galaxy runtime files and service configs on the remote host."
  warn "PostgreSQL packages and database files will be left untouched."
  warn "The following will be preserved if present:"
  warn "  - $GALAXY_ROOT/mutable"
  warn "  - $GALAXY_ROOT/datasets"
  warn "  - PostgreSQL database/user"
  warn "If $GALAXY_ROOT is a mounted disk, the mount point will be preserved."

  read -rp "Proceed with Galaxy assets wipe while preserving DB and datasets? (y/n): " ans
  [[ "$ans" =~ ^[Yy]$ ]] || { step "Assets wipe aborted"; return 0; }

  stop_remote_galaxy_processes

  step "Stopping nginx service"
  ansible galaxyservers -i "$INVENTORY_FILE" -b -m service -a "name=nginx state=stopped" || true

  step "Checking whether $GALAXY_ROOT is a mount point"
  ansible galaxyservers -i "$INVENTORY_FILE" -b -m shell -a "findmnt '$GALAXY_ROOT' || true" || true

  purge_remote_runtime_keep_db
  remove_remote_galaxy_systemd_units

  step "Recreating Galaxy root mount directory permissions"
  ansible galaxyservers -i "$INVENTORY_FILE" -b -m file -a "path=$GALAXY_ROOT state=directory owner=root group=root mode=0755"

  step "Removing Galaxy nginx configuration"
  ansible galaxyservers -i "$INVENTORY_FILE" -b -m file -a "path=/etc/nginx/sites-available/galaxy state=absent" || true
  ansible galaxyservers -i "$INVENTORY_FILE" -b -m file -a "path=/etc/nginx/sites-enabled/galaxy state=absent" || true
  ansible galaxyservers -i "$INVENTORY_FILE" -b -m file -a "path=/var/lib/galaxy state=absent" || true

  step "Restarting nginx if still installed"
  ansible galaxyservers -i "$INVENTORY_FILE" -b -m service -a "name=nginx state=started enabled=yes" || true

  success "Galaxy server assets wiped successfully while preserving PostgreSQL, mutable, and datasets"
}

clean_remote() {
  load_config
  generate_inventory
  activate_venv

  warn "DANGER WARNING: This operation destroys the remote instance database, application files, configurations, and raw datasets."
  warn "If $GALAXY_ROOT is a mounted disk, the mount point will be preserved and only its contents will be removed."

  read -rp "Proceed with deep purge operations against target system host machine? (y/n): " ans
  [[ "$ans" =~ ^[Yy]$ ]] || { step "Destruction routine aborted"; return 0; }

  stop_remote_galaxy_processes

  step "Stopping nginx and PostgreSQL"
  ansible galaxyservers -i "$INVENTORY_FILE" -b -m service -a "name=nginx state=stopped" || true
  ansible galaxyservers -i "$INVENTORY_FILE" -b -m service -a "name=postgresql state=stopped" || true

  step "Checking whether $GALAXY_ROOT is a mount point"
  ansible galaxyservers -i "$INVENTORY_FILE" -b -m shell -a "findmnt '$GALAXY_ROOT' || true" || true

  purge_remote_everything_keep_mount
  remove_remote_galaxy_systemd_units

  step "Recreating Galaxy root mount directory permissions"
  ansible galaxyservers -i "$INVENTORY_FILE" -b -m file -a "path=$GALAXY_ROOT state=directory owner=root group=root mode=0755"

  step "Purging PostgreSQL packages and data"
  ansible galaxyservers -i "$INVENTORY_FILE" -b -m apt -a "name=postgresql* state=absent purge=yes autoremove=yes" || true

  step "Removing PostgreSQL residual data directories"
  ansible galaxyservers -i "$INVENTORY_FILE" -b -m file -a "path=/var/lib/postgresql state=absent" || true
  ansible galaxyservers -i "$INVENTORY_FILE" -b -m file -a "path=/etc/postgresql state=absent" || true
  ansible galaxyservers -i "$INVENTORY_FILE" -b -m file -a "path=/etc/postgresql-common state=absent" || true

  step "Removing Galaxy nginx configuration"
  ansible galaxyservers -i "$INVENTORY_FILE" -b -m file -a "path=/etc/nginx/sites-available/galaxy state=absent" || true
  ansible galaxyservers -i "$INVENTORY_FILE" -b -m file -a "path=/etc/nginx/sites-enabled/galaxy state=absent" || true
  ansible galaxyservers -i "$INVENTORY_FILE" -b -m file -a "path=/var/lib/galaxy state=absent" || true

  step "Restarting nginx if still installed"
  ansible galaxyservers -i "$INVENTORY_FILE" -b -m service -a "name=nginx state=started enabled=yes" || true

  success "Target platform system environment reset completed while preserving $GALAXY_ROOT mount point"
}

menu() {
  echo ""
  echo "===================================================="
  echo " Galaxy Production Enterprise Deployment System"
  echo "===================================================="
  echo "1)  Full automated remote production deployment run"
  echo "2)  Prepare local context control environment (venv)"
  echo "3)  Install dependent Galaxy community role packages"
  echo "4)  Run remote system ping connectivity analysis"
  echo "5)  Execute standard playbook deploy target sequence"
  echo "6)  Run remote platform web endpoint diagnostics"
  echo "7)  Execute deployment routines against localhost (Linux only)"
  echo "8)  Clean local context development dependencies workspace"
  echo "9)  Wipe remote Galaxy runtime assets only (keep DB, mutable, datasets)"
  echo "10) Wipe remote Galaxy database and server assets"
  echo "11) Terminate run engine context"
  echo "----------------------------------------------------"

  read -rp "Action Selection: " c

  case "$c" in
    1) full_remote ;;
    2) prepare_control_node ;;
    3) install_roles ;;
    4) test_connection ;;
    5) deploy_remote ;;
    6) validate_remote ;;
    7) deploy_local ;;
    8) clean_local ;;
    9) wipe_remote_assets_keep_db ;;
    10) clean_remote ;;
    11) exit 0 ;;
    *) warn "Selected instruction parameters are invalid." ;;
  esac

  menu
}

main() {
  local cmd="${1:-menu}"

  [[ "$OS_NAME" == "Darwin" || "$OS_NAME" == "Linux" ]] || error "Unsupported OS: $OS_NAME"
  [[ -f "$PLAYBOOK" ]] || error "Missing playbook: $PLAYBOOK"

  case "$cmd" in
    menu) menu ;;
    full) full_remote ;;
    prepare) prepare_control_node ;;
    install) install_roles ;;
    check) validate_playbook ;;
    ping) test_connection ;;
    deploy) deploy_remote ;;
    validate) validate_remote ;;
    local) deploy_local ;;
    clean) clean_local ;;
    wipe-assets) wipe_remote_assets_keep_db ;;
    wipe) clean_remote ;;
    help|-h|--help) usage ;;
    *)
      usage
      error "Unknown command: $cmd"
      ;;
  esac
}

main "$@"