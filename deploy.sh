#!/usr/bin/env bash
set -Eeuo pipefail

# ========================================================================
# Galaxy Deployment Tool (Final Restructured Edition)
# ========================================================================

OS_NAME="$(uname -s)"
DEPLOYMENT_MODE="remote"

# ------------------------------------------------------------------------
# Terminal Colors Setup
# ------------------------------------------------------------------------
if [[ -t 1 ]]; then
  RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
else
  RED=''; GREEN=''; YELLOW=''; BLUE=''; NC=''
fi

step()   { echo -e "${BLUE}[INFO]${NC} $1"; }
warn()   { echo -e "${YELLOW}[WARN]${NC} $1"; }
error()  { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }
success(){ echo -e "${GREEN}[OK]${NC} $1"; }

# ------------------------------------------------------------------------
# Path Configurations
# ------------------------------------------------------------------------
PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
VENV_DIR="$PROJECT_DIR/venv"
LOCAL_TMP="$PROJECT_DIR/.tmp"

# 🌟 Core Architecture Mapping: Points to your merged group_vars source of truth
CONFIG_FILE="$PROJECT_DIR/group_vars/galaxyservers.yml"
INVENTORY_FILE="$PROJECT_DIR/hosts"
PLAYBOOK="$PROJECT_DIR/playbooks/galaxy-role.yml"    #playbooks/galaxy-role.yml"  #galaxy.yml"
DEFAULT_REMOTE_ROOT="/home/ubuntu/galaxy"

# ========================================================================
# ✅ CONFIGURATION LOADER
# ========================================================================
load_config() {
  step "Loading unified configuration file"
  [[ -f "$CONFIG_FILE" ]] || error "Missing target file: group_vars/galaxyservers.yml"
  command -v yq >/dev/null || error "yq utility missing. Please install it (e.g., 'brew install yq' or 'sudo apt install yq')"

  # Extract parameters using yq from the top section of the YAML
   GALAXY_HOST_IP=$(yq -r '.galaxy.host_ip' "$CONFIG_FILE")
   GALAXY_SSH_USER=$(yq -r '.galaxy.ssh_user' "$CONFIG_FILE")
   GALAXY_ROOT=$(yq -r '.galaxy_root // "'"$DEFAULT_REMOTE_ROOT"'"' "$CONFIG_FILE")

  [[ -z "$GALAXY_HOST_IP" || "$GALAXY_HOST_IP" == "null" ]] && error "Missing 'galaxy.host_ip' entry in group_vars/galaxyservers.yml"
  [[ -z "$GALAXY_SSH_USER" || "$GALAXY_SSH_USER" == "null" ]] && error "Missing 'galaxy.ssh_user' entry in group_vars/galaxyservers.yml"
  success "Configuration validated and parsed successfully ✅"
}

# ========================================================================
# ✅ DYNAMIC INVENTORY GENERATOR
# ========================================================================
generate_inventory() {
  step "Generating inventory host mapping file"
  if [[ "$DEPLOYMENT_MODE" == "local" ]]; then
    cat > "$INVENTORY_FILE" <<EOF
[galaxyservers]
localhost ansible_connection=local ansible_python_interpreter=/usr/bin/python3

[dbservers]
localhost ansible_connection=local
EOF
  else
    cat > "$INVENTORY_FILE" <<EOF
[galaxyservers]
galaxy ansible_host=$GALAXY_HOST_IP ansible_user=$GALAXY_SSH_USER ansible_become=true ansible_become_method=sudo ansible_python_interpreter=/usr/bin/python3

[dbservers]
galaxy
EOF
  fi
  success "Hosts inventory updated at: $INVENTORY_FILE ✅"
}

# ========================================================================
# ✅ CONTROL NODE PREPARATION
# ========================================================================
prepare_control_node() {
  step "Setting up local Python virtual environment execution context"
  mkdir -p "$LOCAL_TMP/ansible_tmp"
  chmod 777 "$LOCAL_TMP/ansible_tmp"
  export ANSIBLE_LOCAL_TEMP="$LOCAL_TMP/ansible_tmp"

  rm -rf "$VENV_DIR"
  python3 -m venv "$VENV_DIR"
  source "$VENV_DIR/bin/activate"

  pip install --upgrade pip setuptools wheel
  pip install ansible yq
  success "Control node operational dependencies established ✅"
}

install_roles() {
  step "Installing official community Galaxy/PostgreSQL/Nginx requirements"
  source "$VENV_DIR/bin/activate"
  ansible-galaxy install -r requirements.yml --force
  success "Ansible roles fetched successfully ✅"
}

validate_playbook() {
  step "Validating playbook code syntax rules"
  source "$VENV_DIR/bin/activate"
  ansible-playbook -i "$INVENTORY_FILE" "$PLAYBOOK" --syntax-check
  success "Playbook configuration structural checking completed successfully ✅"
}

# ========================================================================
# ✅ REMOTE INFRASTRUCTURE OPERATIONS
# ========================================================================
test_connection() {
  load_config
  generate_inventory
  step "Testing connection capabilities to remote system host"
  source "$VENV_DIR/bin/activate"
  ansible galaxyservers -i "$INVENTORY_FILE" -m ping || error "Failed to establish a connection with the remote machine over SSH."
  success "Remote SSH authentication successful ✅"
}

deploy_remote() {
  load_config
  generate_inventory
  step "Initiating remote automation play run processing steps"
  source "$VENV_DIR/bin/activate"
  ansible-playbook -i "$INVENTORY_FILE" "$PLAYBOOK" --flush-cache
  success "Playbook run successfully complete ✅"
}

validate_remote() {
  load_config
  generate_inventory
  step "Querying running status from production web services endpoint"
  source "$VENV_DIR/bin/activate"
  ansible galaxyservers -i "$INVENTORY_FILE" -b -m shell -a "curl -sf http://127.0.0.1/api/version"
  success "Galaxy platform web engine responding with normal parameters ✅"
}

full_remote() {
  prepare_control_node
  install_roles
  validate_playbook
  test_connection
  deploy_remote
  validate_remote
  success "FULL REMOTE AUTOMATION PIPELINE FINISHED 🚀"
}

# ========================================================================
# ✅ LOCAL INSTANCE INFRASTRUCTURE (Linux Only Deployment)
# ========================================================================
deploy_local() {
  DEPLOYMENT_MODE="local"
  [[ "$OS_NAME" == "Linux" ]] || error "Local system installations are only supported running inside native Linux targets"
  load_config
  generate_inventory
  step "Executing automation play routines against local target localhost instance"
  source "$VENV_DIR/bin/activate"
  ansible-playbook -i "$INVENTORY_FILE" "$PLAYBOOK" --flush-cache
  success "Local system execution operations completed successfully ✅"
}

# ========================================================================
# ✅ ENVIRONMENT PURGING SCRIPTS
# ========================================================================
clean_local() {
  step "Cleaning local execution space assets"
  read -rp "Delete control isolation venv and dependency download directory trees? (y/n) [default=n]: " ans
  ans="${ans:-n}"
  if [[ ! "$ans" =~ ^[Yy]$ ]]; then
    step "Local deletion operations canceled"
    return 0
  fi
  rm -rf "$VENV_DIR" "$LOCAL_TMP"
  success "Local dependency footprints cleared successfully ✅"
}

clean_remote() {
  load_config
  generate_inventory

  warn "DANGER WARNING: This operation destroys the remote instance database, application files, configurations, and raw datasets."
  warn "If /srv/galaxy is a mounted disk, the mount point will be preserved and only its contents will be removed."

  read -rp "Proceed with deep purge operations against target system host machine? (y/n): " ans
  [[ "$ans" =~ ^[Yy]$ ]] || { step "Destruction routine aborted"; return; }

  source "$VENV_DIR/bin/activate"

  step "Stopping remote structural processes"
  ansible galaxyservers -i "$INVENTORY_FILE" -b -m service -a "name=galaxy state=stopped" || true
  ansible galaxyservers -i "$INVENTORY_FILE" -b -m service -a "name=nginx state=stopped" || true
  ansible galaxyservers -i "$INVENTORY_FILE" -b -m service -a "name=postgresql state=stopped" || true

  step "Killing leftover Galaxy-related processes"
  ansible galaxyservers -i "$INVENTORY_FILE" -b -m shell -a "
    pkill -f galaxy || true
    pkill -f gunicorn || true
    pkill -f celery || true
    pkill -f supervisord || true
    pkill -f node || true
    pkill -f pnpm || true
    pkill -f yarn || true
  " || true

  step "Checking whether $GALAXY_ROOT is a mount point"
  ansible galaxyservers -i "$INVENTORY_FILE" -b -m shell -a "
    findmnt $GALAXY_ROOT || true
  " || true

  step "Purging Galaxy contents while preserving mount point"
  ansible galaxyservers -i "$INVENTORY_FILE" -b -m shell -a "
    if [ -d '$GALAXY_ROOT' ]; then
      find '$GALAXY_ROOT' -mindepth 1 -maxdepth 1 -exec rm -rf {} +
    else
      mkdir -p '$GALAXY_ROOT'
    fi
  " || true

  step "Recreating Galaxy root mount directory permissions"
  ansible galaxyservers -i "$INVENTORY_FILE" -b -m file -a "path=$GALAXY_ROOT state=directory owner=root group=root mode=0755"

  step "Purging PostgreSQL packages and data"
  ansible galaxyservers -i "$INVENTORY_FILE" -b -m apt -a "name='postgresql*' state=absent purge=yes autoremove=yes" || true

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

  success "Target platform system environment reset completed while preserving $GALAXY_ROOT mount point ✅"
}

# ========================================================================
# ✅ INTERACTIVE INTERFACE NAVIGATION MENU
# ========================================================================
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
  echo "9)  Wipe remote host runtime database and server assets"
  echo "10) Terminate run engine context"
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
    9) clean_remote ;;
    10) exit 0 ;;
    *) warn "Selected instruction parameters are invalid." ; menu ;;
  esac
}

# Launch the execution loop interface
menu