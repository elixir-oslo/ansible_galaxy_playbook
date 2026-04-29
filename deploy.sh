#!/usr/bin/env bash
set -Eeuo pipefail

# =====================================================================
# Galaxy Ansible Deployment Tool (Merged & Hardened)
# =====================================================================

# ---------------------------------------------------------------------
# Colors (only for interactive terminal)
# ---------------------------------------------------------------------
if [[ -t 1 ]]; then
  RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
  BLUE='\033[0;34m'; CYAN='\033[0;36m'; PURPLE='\033[0;35m'
  BOLD='\033[1m'; NC='\033[0m'
else
  RED=''; GREEN=''; YELLOW=''; BLUE=''; CYAN=''; PURPLE=''; BOLD=''; NC=''
fi

step()    { printf "${BLUE}[INFO]${NC} %s\n" "$1"; }
warn()   { printf "${YELLOW}[WARN]${NC} %s\n" "$1"; }
error()  { printf "${RED}[ERROR]${NC} %s\n" "$1"; }
success(){ printf "${GREEN}[OK]${NC} %s\n" "$1"; }

# ---------------------------------------------------------------------
# Prompt helper (MUST be before use)
# ---------------------------------------------------------------------
ask() {
  local q="$1" d="$2" a
  while true; do
    printf "%s (y/n) [default=%s]: " "$q" "$d"
    read -r a
    a="${a:-$d}"
    [[ "$a" =~ ^[Yy]$ ]] && return 0
    [[ "$a" =~ ^[Nn]$ ]] && return 1
    warn "Please answer y or n"
  done
}


# ---------------------------------------------------------------------
# Dependency installer
# ---------------------------------------------------------------------
install_dependencies() {
  step "Installing required system dependencies"

  sudo apt update -y

  # yq (YAML processor)
  if ! command -v yq >/dev/null 2>&1; then
    step "Installing yq"
    sudo apt install -y yq
  fi

  success "System dependencies installed"
}
# ---------------------------------------------------------------------
# Dependency checks (fail fast)
# ---------------------------------------------------------------------
if ! command -v yq >/dev/null 2>&1; then
  warn "Required dependency 'yq' is not installed."

  if [[ -t 1 ]]; then
    if ask "Install required dependencies now?" "y"; then
      install_dependencies
    else
      error "yq is required to continue. Aborting."
      exit 1
    fi
  else
    error "yq is required but not installed. Run install_dependencies first."
    exit 1
  fi
fi

# ---------------------------------------------------------------------
# Project paths
# ---------------------------------------------------------------------
PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
VENV_DIR="$PROJECT_DIR/venv"
GALAXY_ROOT="/srv/galaxy"
OPS_DIR="$PROJECT_DIR/devops-scripts"
CONFIGS_DIR="$PROJECT_DIR/configs"
CONFIG_FILE="$CONFIGS_DIR/config.yml"
INVENTORY_FILE="$PROJECT_DIR/hosts"

# ---------------------------------------------------------------------
# Load local environment configuration
# ---------------------------------------------------------------------

if [[ ! -f "$CONFIG_FILE" ]]; then
  error "config.yml not found at $CONFIG_FILE"
  exit 1
fi
# Load configuration from YAML
GALAXY_HOST_IP="$(yq -r '.galaxy.host_ip' "$CONFIG_FILE")"
GALAXY_SSH_USER="$(yq -r '.galaxy.ssh_user' "$CONFIG_FILE")"
GALAXY_ADMIN_EMAIL="$(yq -r '.admin.email' "$CONFIG_FILE")"
GALAXY_DB_PASSWORD="$(yq -r '.database.password' "$CONFIG_FILE")"

# ---------------------------------------------------------------------
# Required configuration validation
# ---------------------------------------------------------------------
required_vars=(
  GALAXY_HOST_IP
  GALAXY_SSH_USER
  GALAXY_ADMIN_EMAIL
  GALAXY_DB_PASSWORD
)

for var in "${required_vars[@]}"; do
  if [[ -z "${!var:-}" ]]; then
    echo "[ERROR] Required variable '$var' is not set in local_config.sh"
    exit 1
  fi
done





# ---------------------------------------------------------------------
# UI helpers
# ---------------------------------------------------------------------
header() {
  [[ -t 1 ]] && clear
  printf "${PURPLE}${BOLD}"
  printf "============================================================\n"
  printf "          Galaxy Ansible Deployment Tool (Hardened)\n"
  printf "============================================================\n"
  printf "${NC}"
}

ask() {
  local q="$1"; local d="$2"; local a
  while true; do
    printf "${CYAN}%s (y/n) [default=%s]: ${NC}" "$q" "$d"
    read -r a
    a="${a:-$d}"
    [[ "$a" =~ ^[Yy]$ ]] && return 0
    [[ "$a" =~ ^[Nn]$ ]] && return 1
    warn "Please answer y or n"
  done
}

# =====================================================================
# Core actions
# =====================================================================

validate_galaxy() {
  # header
  step "Validating Galaxy deployment (locally run)"

  VALIDATE_SCRIPT="$OPS_DIR/validate_galaxy.sh"

  if [[ ! -x "$VALIDATE_SCRIPT" ]]; then
    error "validate_galaxy.sh not found or not executable"
    exit 1
  fi

  sudo "$VALIDATE_SCRIPT"

  success "Galaxy validation completed successfully"
}


run_one_time_bootstrap() {
  # header
  step "Running Galaxy one-time bootstrap"

  local BOOTSTRAP_SCRIPT="$OPS_DIR/one-time-bootstrap.sh"

  if [[ ! -x "$BOOTSTRAP_SCRIPT" ]]; then
    error "Bootstrap script not found or not executable: $BOOTSTRAP_SCRIPT"
    return 1
  fi

  sudo "$BOOTSTRAP_SCRIPT"

  success "One-time bootstrap completed"
}

fix_nginx_ui() {
  # header
  step "Applying Galaxy nginx + UI fix"

  local FIX_SCRIPT="$OPS_DIR/fix_nginx_ui_after_deployment.sh"

  if [[ ! -x "$FIX_SCRIPT" ]]; then
    error "UI fix script not found or not executable: $FIX_SCRIPT"
    return 1
  fi

  sudo "$FIX_SCRIPT"

  success "Galaxy nginx + UI fix applied"
}

prepare_system() {
  # header
  step "Preparing system"

  if ! command -v python3 >/dev/null 2>&1; then
    step "Installing Python 3"
    sudo apt update -y
    sudo apt install -y python3 python3-venv python3-pip
  fi

  rm -rf "$VENV_DIR"
  python3 -m venv "$VENV_DIR"
  source "$VENV_DIR/bin/activate"
  chmod -R a+rx "$VENV_DIR"

  sudo mkdir -p "$GALAXY_ROOT/ansible_tmp" "$GALAXY_ROOT/.cache/yarn"
  sudo chmod 777 "$GALAXY_ROOT/ansible_tmp"

  # Redirect temporary paths (from Script 1)
  export ANSIBLE_LOCAL_TEMP="$GALAXY_ROOT/ansible_tmp"
  export ANSIBLE_REMOTE_TEMP="$GALAXY_ROOT/ansible_tmp"
  export TMPDIR="$GALAXY_ROOT/ansible_tmp"
  export TMP="$GALAXY_ROOT/ansible_tmp"
  export TEMP="$GALAXY_ROOT/ansible_tmp"
  export YARN_CACHE_FOLDER="$GALAXY_ROOT/.cache/yarn"

  success "System prepared"
}
prepare_system_remote() {
  # header
  step "Preparing system"

  unset ANSIBLE_REMOTE_TEMP ANSIBLE_LOCAL_TEMP TMP TMPDIR TEMP


  if ! command -v python3 >/dev/null 2>&1; then
    step "Installing Python 3"
    sudo apt update -y
    sudo apt install -y python3 python3-venv python3-pip
  fi

  rm -rf "$VENV_DIR"
  python3 -m venv "$VENV_DIR"
  source "$VENV_DIR/bin/activate"
  chmod -R a+rx "$VENV_DIR"

  sudo mkdir -p "$GALAXY_ROOT/ansible_tmp" "$GALAXY_ROOT/.cache/yarn"
  sudo chmod 777 "$GALAXY_ROOT/ansible_tmp"


  success "System prepared"
}

clean_galaxy() {

  # header
  warn "This will COMPLETELY remove Galaxy, Conda environments, and runtime state (local installation)."
  warn "Target path: $GALAXY_ROOT"

  if ! ask "Continue with FULL Galaxy cleanup?" "n"; then
    step "Cleanup cancelled"
    return 0
  fi


 step "Stopping Galaxy and Nginx services (non-blocking)"

 timeout 10s sudo systemctl stop galaxy || true
 timeout 10s sudo systemctl stop nginx || true

 sudo rm -f /etc/nginx/conf.d/http_options.conf || true
 sleep 2

 step "Terminating Galaxy-related processes"
 set +m
 # Graceful

sudo killall -q gunicorn celery supervisord 2>/dev/null || true
sudo killall -q -u galaxy 2>/dev/null || true

 sleep 2

 step "Force-killing any remaining processes"

 set +m
sudo killall -q gunicorn celery supervisord 2>/dev/null || true
sudo killall -q -u galaxy 2>/dev/null || true


 # DO NOT WAIT FOR KERNEL ACKNOWLEDGEMENT
 # DO NOT USE lsof +D
 # DO NOT USE fuser -k

 step "Resetting Gravity runtime state"
 sudo rm -rf "$GALAXY_ROOT/mutable/gravity/state" || true

 step "Removing Conda environments"
 sudo rm -rf \
   "$GALAXY_ROOT/mutable/dependencies/_conda" \
   "$GALAXY_ROOT/_conda" \
   "/_conda" \
   /home/galaxy/.conda \
   /home/galaxy/.miniconda \
   /home/galaxy/.miniforge \
   /root/.conda \
   /root/.miniconda \
   /root/.miniforge || true


step "Detaching Galaxy root directory (non-blocking)"

if [[ -d "$GALAXY_ROOT" ]]; then
  sudo mv "$GALAXY_ROOT" "${GALAXY_ROOT}.DELETE.$(date +%s)" || true
fi

success "Galaxy directory detached. Reboot recommended to finalize cleanup."
warn "If deployment continues, Galaxy will use a fresh /srv/galaxy."

}



install_ansible() {
  # header
  step "Installing Ansible"

  source "$VENV_DIR/bin/activate"
  pip install --upgrade pip setuptools wheel
  pip install --upgrade ansible ansible-core jinja2
  success "Ansible installed"
}

install_roles() {
  # header
  step "Installing Ansible Galaxy roles"
  require_ansible
  source "$VENV_DIR/bin/activate"
  ansible-galaxy install -r "$PROJECT_DIR/requirements.yml" --force
  success "Roles installed"
}

validate_playbook() {
  # header
  step "Validating playbook syntax"
  require_ansible
  source "$VENV_DIR/bin/activate"
  ansible-playbook -i "$INVENTORY_FILE" "$PROJECT_DIR/galaxy.yml" --syntax-check
  ansible-playbook -i "$INVENTORY_FILE" "$PROJECT_DIR/nginx.yml" --syntax-check
  success "Playbook syntax valid"
}

deploy_galaxy() {
  # header
  require_ansible
  step "Running nginx configuration sanity check..."
  if ! sudo nginx -t; then
      step "❌ Nginx configuration is invalid. Fix errors before continuing."
      exit 1
  fi

  step "✅ Nginx configuration"

  step "Deploying Galaxy"
  source "$VENV_DIR/bin/activate"


ansible-playbook -i "$INVENTORY_FILE" \
    "$PROJECT_DIR/galaxy.yml" \
    -e "galaxy_db_password=$GALAXY_DB_PASSWORD"


  step "Fixing ownership & permissions"
  sudo chown -R galaxy:galaxy "$GALAXY_ROOT"
  sudo chmod 755 "$GALAXY_ROOT"

  step "Configuring Git safe.directory"
  sudo git config --global --add safe.directory "$GALAXY_ROOT/server" || true

  success "Galaxy deployment completed"
}
# ---------------------------------------------------------------------
# Rebuild Galaxy client (frontend only, Ansible-based)
# ---------------------------------------------------------------------

rebuild_client() {
  # header
  step "Rebuilding Galaxy client (frontend only)"
  require_ansible

  # Guard: virtualenv must exist
  if [[ ! -f "$VENV_DIR/bin/activate" ]]; then
    error "Ansible virtualenv not found at $VENV_DIR"
    error "Run 'Prepare system' first."
    return 1
  fi

  # Guard: playbook must exist
  if [[ ! -f "$PROJECT_DIR/galaxy.yml" ]]; then
    error "galaxy.yml not found in $PROJECT_DIR"
    return 1
  fi

  source "$VENV_DIR/bin/activate"

  ansible-playbook \
    -i "$INVENTORY_FILE" \
    "$PROJECT_DIR/galaxy.yml" \
    --tags galaxy_client || {
      error "Galaxy client rebuild failed"
      return 1
    }

  success "Galaxy client rebuilt successfully"
}

require_ansible() {
if ! command -v ansible-playbook >/dev/null 2>&1; then
    warn "Ansible not found — installing automatically"
    install_ansible
  fi

}


# ---------------------------------------------------------------------
# Force Galaxy client rebuild (remove hash first)
# ---------------------------------------------------------------------
force_rebuild_client() {
  # header

  step "Forcing Galaxy client rebuild"
require_ansible
  local CLIENT_HASH="$GALAXY_ROOT/server/client_build_hash.txt"

  # Guard: inventory must exist
  if [[ ! -f "$INVENTORY_FILE" ]]; then
    error "Ansible inventory not found at $INVENTORY_FILE"
    return 1
  fi

  if ! ask "Remove client_build_hash.txt on Galaxy server and rebuild client?" "n"; then
    step "Force rebuild cancelled"
    return 0
  fi

  source "$VENV_DIR/bin/activate"

  step "Removing client build hash on Galaxy server (via Ansible)"

  ansible \
    -i "$INVENTORY_FILE" \
    galaxy \
    -b \
    -m file \
    -a "path=$CLIENT_HASH state=absent" || {
      error "Failed to remove client_build_hash.txt on Galaxy server"
      return 1
    }

  success "client_build_hash.txt removed on Galaxy server"

  rebuild_client
}


# ---------------------------------------------------------------------
# Manual Galaxy client build (debug / emergency)
# ---------------------------------------------------------------------

manual_client_build() {
  # header
  step "Manual Galaxy client build (advanced)"
  require_ansible

  # Ensure Galaxy user exists
  if ! id galaxy >/dev/null 2>&1; then
    error "Galaxy system user does not exist."
    error "Galaxy must be deployed before running a manual client build."
    return 1
  fi

  if ! ask "Run manual client build as galaxy user?" "n"; then
    step "Manual client build cancelled"
    return
  fi

  sudo -iu galaxy bash <<'EOF'
set -e
cd /srv/galaxy/server
source /srv/galaxy/venv/bin/activate
make client-clean
make client-build
EOF

  uccess "Manual Galaxy client build completed"
}


full_run() {
  # prepare_system
  install_ansible
  install_roles
  validate_playbook
  deploy_galaxy
  sleep 30 # Wait for services to stabilize before running next steps
  run_one_time_bootstrap
   sleep 30 # Wait for services to stabilize before running next steps
  fix_nginx_ui
   sleep 30 # Wait for services to stabilize before validating
  validate_galaxy

}

check_remote_connectivity() {

 step "Checking remote SSH connectivity"

  if ! ansible -i "$INVENTORY_FILE" galaxy -m ping; then
    error "Cannot reach Galaxy server via SSH"
    exit 1
  fi

}



assert_remote_inventory() {
  local inventory="$INVENTORY_FILE"

  step "Verifying inventory is remote (not local)"

  # 1) Inventory file must exist
  [[ -f "$inventory" ]] || error "Inventory file not found: $inventory"

  # 2) Reject explicit local connection

if grep -Eq '^[[:space:]]*[^#].*ansible_connection[[:space:]]*=[[:space:]]*local' "$inventory"; then
  error "Inventory uses ansible_connection=local — this is NOT remote deployment"
  exit 1
fi

  # 3) Reject localhost or 127.0.0.1
  if grep -Eq '(^|[^0-9])(localhost|127\.0\.0\.1)' "$inventory"; then
    error "Inventory points to localhost — refusing remote deployment"
    exit 1
  fi

  step "Inventory validated as REMOTE ✅"
}



deploy_galaxy_remote() {
  # header
  step "Starting REMOTE Galaxy deployment"
  check_remote_connectivity

 # step "Running Galaxy playbook on remote host"

ansible-playbook -i "$INVENTORY_FILE" \
    "$PROJECT_DIR/galaxy.yml" \
    -e "galaxy_db_password=$GALAXY_DB_PASSWORD"

  # success "Remote Galaxy deployment completed"
}
run_one_time_bootstrap_remote() {
 # header
  step "Running one-time bootstrap on remote Galaxy server"
  require_ansible

  local BOOTSTRAP_SCRIPT="$OPS_DIR/one-time-bootstrap.sh"

  [[ -x "$BOOTSTRAP_SCRIPT" ]] ||
    error "Bootstrap script not found or not executable"

  ansible -i "$INVENTORY_FILE" galaxy -b -m script \
    -a "$BOOTSTRAP_SCRIPT"

  success "Remote bootstrap completed"
}
fix_nginx_ui_remote() {
  #header
  step "Applying nginx + UI fix on REMOTE Galaxy server"
  require_ansible

  local FIX_SCRIPT="$OPS_DIR/fix_nginx_ui_after_deployment.sh"

  # ----------------------------------------------------
  # 1) Sanity check: script exists and executable
  # ----------------------------------------------------
  if [[ ! -x "$FIX_SCRIPT" ]]; then
    error "nginx/UI fix script not found or not executable: $FIX_SCRIPT"
  fi

  # ----------------------------------------------------
  # 2) Sanity check: remote connectivity
  # ----------------------------------------------------
  step "Checking remote host connectivity"
  ansible -i "$INVENTORY_FILE" galaxy -m ping >/dev/null \
    || error "Cannot reach Galaxy host via Ansible"

  # ----------------------------------------------------
  # 3) Execute fix script on remote host (root)
  # ----------------------------------------------------
  step "Running nginx + UI fix script on remote host"
  ansible -i "$INVENTORY_FILE" galaxy -b -m script \
    -a "$FIX_SCRIPT" \
    || error "Remote nginx/UI fix script failed"

  # ----------------------------------------------------
  # 4) Post-check: nginx syntax
  # ----------------------------------------------------
  step "Validating nginx configuration on remote host"
  ansible -i "$INVENTORY_FILE" galaxy -b -m shell \
    -a "nginx -t" \
    || error "Remote nginx configuration is invalid after fix"

  success "nginx + UI fix applied successfully on remote host ✅"
}
validate_galaxy_remote() {
 # header
  step "Validating Galaxy deployment on REMOTE server"
  require_ansible

  local VALIDATE_SCRIPT="$OPS_DIR/validate_galaxy.sh"

  # ----------------------------------------------------
  # 1) Sanity check: Ansible connectivity
  # ----------------------------------------------------
  step "Checking remote host connectivity"
  ansible -i "$INVENTORY_FILE" galaxy -m ping >/dev/null \
    || error "Cannot reach Galaxy host via Ansible"

  # ----------------------------------------------------
  # 2) Ensure Galaxy service is running
  # ----------------------------------------------------
  step "Checking Galaxy service status on remote host"
  ansible -i "$INVENTORY_FILE" galaxy -b -m systemd \
    -a "name=galaxy state=started" >/dev/null \
    || error "Galaxy service is not running on remote host"

  # ----------------------------------------------------
  # 3) Run remote validation script (authoritative)
  # ----------------------------------------------------
  if [[ ! -x "$VALIDATE_SCRIPT" ]]; then
    error "Validation script not found or not executable: $VALIDATE_SCRIPT"
  fi

  step "Running remote Galaxy validation script"
  ansible -i "$INVENTORY_FILE" galaxy -b -m script \
    -a "$VALIDATE_SCRIPT" \
    || error "Remote Galaxy validation script failed"

  # ----------------------------------------------------
  # 4) Explicit API check via nginx (extra guard)
  # ----------------------------------------------------
  step "Verifying Galaxy API via nginx on remote host"
  ansible -i "$INVENTORY_FILE" galaxy -b -m shell \
    -a "curl -sf http://localhost/api/version >/dev/null" \
    || error "Galaxy API not reachable via nginx on remote host"

  # ----------------------------------------------------
  # 5) Final success
  # ----------------------------------------------------
  success "Remote Galaxy validation completed successfully ✅"
}


full_run_remote() {
  # prepare_system
  install_ansible
  install_roles
  validate_playbook
  check_remote_connectivity
  deploy_galaxy_remote
  sleep 30 # Wait for services to stabilize before running next steps
  run_one_time_bootstrap_remote
  sleep 30 # Wait for services to stabilize before running next steps
  fix_nginx_ui_remote
  sleep 30 # Wait for services to stabilize before validating
  validate_galaxy_remote

}

# =====================================================================
# Menu
# =====================================================================

menu() {
  header
  select_deployment_mode

  case "$DEPLOY_MODE" in
    local)
      menu_local
      ;;
    remote)
      menu_remote
      ;;
    *)
      error "Unknown deployment mode: $DEPLOY_MODE"
      exit 1
      ;;
  esac
}


menu_local() {
  # header
  prepare_system
  printf " Local deployment menu\n\n"
  printf " 1) Full Galaxy deployment (recommended)\n"
  printf " 2) Clean Galaxy installation (FULL)\n"
  printf " 3) Prepare system\n"
  printf " 4) Install Ansible\n"
  printf " 5) Install Ansible roles\n"
  printf " 6) Validate playbook\n"
  printf " 7) Deploy Galaxy (run playbook)\n"
  printf " 8) Run one-time bootstrap (manual, ONCE)\n"
  printf " 9) Fix nginx + UI (repeatable)\n"
  printf " 10) Validate Galaxy\n"
  printf " 11) Rebuild Galaxy client (frontend only)\n"
  printf " 12) Force Galaxy client rebuild\n"
  printf " 13) Manual client build (debug)\n"
  printf " 14) Exit\n"

  read -rp "Select option (1–14): " c
  case "$c" in
    1)  full_run ;;
    2)  clean_galaxy ;;
    3)  prepare_system ;;
    4)  install_ansible ;;
    5)  install_roles ;;
    6)  validate_playbook ;;
    7)  deploy_galaxy ;;
    8)  run_one_time_bootstrap ;;
    9)  fix_nginx_ui ;;
    10) validate_galaxy ;;
   11)  rebuild_client ;;
   12)  force_rebuild_client ;;
   13)  manual_client_build ;;
   14)  printf "${DIM}Goodbye!${NC}\n"; exit 0 ;;
    *)  warn "Invalid option" ;;
  esac
}




menu_remote() {
  prepare_system_remote
  # header
  assert_remote_inventory
  printf "\n\n Remote Deployment Menu\n\n"

  printf " 1) Full Galaxy deployment (recommended)\n"
  printf " 2) Prepare installation (control node)\n"
  printf " 3) Install Ansible (control node)\n"
  printf " 4) Install Ansible roles (control node)\n"
  printf " 5) Validate playbook (control node)\n"
  printf " 6) Deploy Galaxy (run playbook)\n"
  printf " 7) Run one-time bootstrap (remote, ONCE)\n"
  printf " 8) Fix nginx + UI (remote, repeatable)\n"
  printf " 9) Validate Galaxy (remote)\n"
  printf "10) Rebuild Galaxy client (frontend only)\n"
  printf "11) Force Galaxy client rebuild\n"
  printf "12) Manual client build (debug)\n"
  printf "13) Exit\n"

  read -rp "Select option: " c
  case "$c" in
    1)
      full_run_remote;;

    2)  prepare_system ;;
    3)  install_ansible ;;
    4)  install_roles ;;
    5)  validate_playbook ;;
    6)  deploy_galaxy_remote ;;
    7)  run_one_time_bootstrap_remote ;;
    8)  fix_nginx_ui_remote ;;
    9)  validate_galaxy_remote ;;
   10)  rebuild_client ;;
   11)  force_rebuild_client ;;
   12)  manual_client_build ;;
   13) printf "${DIM}Goodbye!${NC}\n"; exit 0 ;;
    *)  warn "Invalid option" ;;
  esac
}



# ---------------------------------------------------------------------
# Deployment mode selection
# ---------------------------------------------------------------------
select_deployment_mode() {

  if [[ -z "${DEPLOY_MODE:-}" ]]; then
   # header
    step "Select deployment mode"

    if ask "Deploy Galaxy on THIS machine (local setup)?" "n"; then
      DEPLOY_MODE="local"
    else
      DEPLOY_MODE="remote"
    fi
  fi

  export DEPLOY_MODE
  step "Deployment mode set to: $DEPLOY_MODE"
}


# ---------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------
if [[ -z "${1-}" ]]; then
  menu
else
  FUNC="$1"
  if declare -f "$FUNC" >/dev/null; then
    header
    "$FUNC"
  else
    error "Unknown command: $FUNC"
    step "Available commands:"
    declare -F | awk '{print "  - " $3}'
    exit 1
  fi
fi


