#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
# Galaxy Deployment Tool (Final: config.yml + cross-platform)
# ============================================================

OS_NAME="$(uname -s)"
DEPLOYMENT_MODE="remote"


# -------------------------------
# Colors
# -------------------------------
if [[ -t 1 ]]; then
  RED='\033[0;31m'; GREEN='\033[0;32m'
  YELLOW='\033[1;33m'; BLUE='\033[0;34m'
  NC='\033[0m'
else
  RED=''; GREEN=''; YELLOW=''; BLUE=''; NC=''
fi

step()   { echo -e "${BLUE}[INFO]${NC} $1"; }
warn()   { echo -e "${YELLOW}[WARN]${NC} $1"; }
error()  { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }
success(){ echo -e "${GREEN}[OK]${NC} $1"; }

# -------------------------------
# Paths
# -------------------------------
PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
VENV_DIR="$PROJECT_DIR/venv"
LOCAL_TMP="$PROJECT_DIR/.tmp"

CONFIG_FILE="$PROJECT_DIR/configs/config.yml"
INVENTORY_FILE="$PROJECT_DIR/hosts"
PLAYBOOK="$PROJECT_DIR/galaxy.yml"

# Default fallback
DEFAULT_REMOTE_ROOT="/home/ubuntu/galaxy"

# ============================================================
# ✅ LOAD CONFIG
# ============================================================

load_config() {
  step "Loading configuration"

  [[ -f "$CONFIG_FILE" ]] || error "Missing config.yml"

  command -v yq >/dev/null || error "yq is required (brew install yq)"

  GALAXY_HOST_IP=$(yq -r '.galaxy.host_ip' "$CONFIG_FILE")
  GALAXY_SSH_USER=$(yq -r '.galaxy.ssh_user' "$CONFIG_FILE")
  GALAXY_ROOT=$(yq -r '.paths.galaxy_root // "'"$DEFAULT_REMOTE_ROOT"'"' "$CONFIG_FILE")
  DB_PASSWORD=$(yq -r '.database.password' "$CONFIG_FILE")

  [[ -z "$GALAXY_HOST_IP" || "$GALAXY_HOST_IP" == "null" ]] && error "Missing host_ip"
  [[ -z "$GALAXY_SSH_USER" || "$GALAXY_SSH_USER" == "null" ]] && error "Missing ssh_user"

  success "Config loaded ✅"
}

# ============================================================
# ✅ INVENTORY GENERATION
# ============================================================


generate_inventory() {
  step "Generating inventory based on deployment mode"

  [[ -f "$INVENTORY_FILE" ]] || error "hosts file not found"

  if [[ "$DEPLOYMENT_MODE" == "local" ]]; then
    cat > "$INVENTORY_FILE" <<EOF
[galaxyservers]
galaxy ansible_connection=local ansible_python_interpreter=/usr/bin/python3

[dbservers]
galaxy
EOF

  else
    cat > "$INVENTORY_FILE" <<EOF
[galaxyservers]
galaxy ansible_host=$GALAXY_HOST_IP ansible_user=$GALAXY_SSH_USER ansible_become=true ansible_become_method=sudo ansible_python_interpreter=/usr/bin/python3

[dbservers]
galaxy
EOF

  fi

  success "Inventory generated ✅"
}



# ============================================================
# ✅ CONTROL NODE PREP
# ============================================================

prepare_control_node() {
  step "Preparing control node"

  mkdir -p "$LOCAL_TMP/ansible_tmp"
  chmod 777 "$LOCAL_TMP/ansible_tmp"

  export ANSIBLE_LOCAL_TEMP="$LOCAL_TMP/ansible_tmp"

  rm -rf "$VENV_DIR"
  python3 -m venv "$VENV_DIR"
  source "$VENV_DIR/bin/activate"

  pip install --upgrade pip setuptools wheel
  pip install ansible yq

  success "Control node ready ✅"
}

install_roles() {
  step "Installing roles"
  source "$VENV_DIR/bin/activate"
  ansible-galaxy install -r requirements.yml --force
  success "Roles installed ✅"
}

validate_playbook() {
  step "Validating playbook"
  source "$VENV_DIR/bin/activate"

  ansible-playbook -i "$INVENTORY_FILE" "$PLAYBOOK" --syntax-check

  success "Playbook valid ✅"
}

# ============================================================
# ✅ REMOTE
# ============================================================

test_connection() {

  load_config
  generate_inventory

  step "Testing SSH"
  source "$VENV_DIR/bin/activate"

  ansible galaxy -i "$INVENTORY_FILE" -m ping || error "SSH failed"

  success "SSH OK ✅"
}

deploy_remote() {

  load_config
  generate_inventory

  step "Deploying Galaxy remotely"

  source "$VENV_DIR/bin/activate"

  ansible-playbook \
    -i "$INVENTORY_FILE" \
    "$PLAYBOOK" \
    -e "galaxy_root=$GALAXY_ROOT galaxy_db_password=$DB_PASSWORD"

  success "Deployment complete ✅"
}



validate_remote() {

  load_config
  generate_inventory

  step "Validating Galaxy"

  source "$VENV_DIR/bin/activate"

  ansible galaxy -i "$INVENTORY_FILE" -b -m shell \
    -a "curl -sf http://localhost/api/version"

  success "Galaxy is running ✅"
}

full_remote() {

  prepare_control_node
  install_roles
  validate_playbook
  test_connection
  deploy_remote

  step "Waiting..."
  sleep 60

  fix_nginx
  validate_remote

  success "FULL REMOTE DEPLOYMENT DONE 🚀"
}

# ============================================================
# ✅ LOCAL (Linux only)
# ============================================================

deploy_local() {
  DEPLOYMENT_MODE="local"
  [[ "$OS_NAME" == "Linux" ]] || error "Local only on Linux"

  load_config
  generate_inventory

  step "Deploying locally"

  source "$VENV_DIR/bin/activate"

  ansible-playbook \
    -i localhost, \
    -c local \
    "$PLAYBOOK" \
    -e "galaxy_root=$GALAXY_ROOT galaxy_db_password=$DB_PASSWORD"

  success "Local deployment done ✅"
}
# ============================================================
# ✅ CLEAN LOCAL ENVIRONMENT
# ============================================================

clean_local() {
  step "Cleaning local Ansible environment (Mac/Linux)"

  read -rp "Delete virtualenv, roles, temp files? (y/n) [default=n]: " ans
  ans="${ans:-n}"

  if [[ ! "$ans" =~ ^[Yy]$ ]]; then
    step "Cleanup cancelled"
    return 0
  fi

  # Remove virtualenv
  if [[ -d "$VENV_DIR" ]]; then
    rm -rf "$VENV_DIR"
    step "Removed venv/"
  fi

  # Remove roles
  if [[ -d "$PROJECT_DIR/roles" ]]; then
    rm -rf "$PROJECT_DIR/roles"
    step "Removed roles/"
  fi

  # Remove temp files
  if [[ -d "$LOCAL_TMP" ]]; then
    rm -rf "$LOCAL_TMP"
    step "Removed .tmp/"
  fi

#  # Remove generated inventory
#  if [[ -f "$INVENTORY_FILE" ]]; then
#    rm -f "$INVENTORY_FILE"
#    step "Removed hosts file"
#  fi

  success "Local cleanup completed ✅"
}
# ============================================================
# ✅ CLEAN REMOTE ENVIRONMENT
# ============================================================
clean_remote() {

  load_config
  generate_inventory

  step "Cleaning remote Galaxy VM"

  read -rp "⚠️ This will DELETE Galaxy, PostgreSQL, nginx configs. Continue? (y/n): " ans
  [[ "$ans" =~ ^[Yy]$ ]] || { step "Cancelled"; return; }

  source "$VENV_DIR/bin/activate"

  # Stop services
  ansible galaxy -i "$INVENTORY_FILE" -b -m service -a "name=galaxy state=stopped" || true
  ansible galaxy -i "$INVENTORY_FILE" -b -m service -a "name=nginx state=stopped" || true
  ansible galaxy -i "$INVENTORY_FILE" -b -m service -a "name=postgresql state=stopped" || true

  # Kill processes using Galaxy dir
  ansible galaxy -i "$INVENTORY_FILE" -b -m shell \-a "fuser -km /srv/galaxy || true"

  # Unmount (if volume)

ansible galaxy -i "$INVENTORY_FILE" -b -m shell \
  -a "umount /srv/galaxy || true"


  # Remove Galaxy directory
  ansible galaxy -i "$INVENTORY_FILE" -b -m file -a "path=/srv/galaxy state=absent"

  # Remove PostgreSQL
  ansible galaxy -i "$INVENTORY_FILE" -b -m apt -a "name='postgresql*' state=absent purge=yes autoremove=yes"

  # Remove nginx config
  ansible galaxy -i "$INVENTORY_FILE" -b -m file -a "path=/etc/nginx/sites-available/galaxy state=absent"
  ansible galaxy -i "$INVENTORY_FILE" -b -m file -a "path=/etc/nginx/sites-enabled/galaxy state=absent"

  # Clean apt cache
  ansible galaxy -i "$INVENTORY_FILE" -b -m apt -a "autoremove=yes autoclean=yes"

  # Remove bootstrap marker
  ansible galaxy -i "$INVENTORY_FILE" -b -m file -a "path=/var/lib/galaxy state=absent"

  success "Remote VM cleaned ✅"
}

# ============================================================
# ✅ MENU
# ============================================================

menu() {
  echo ""
  echo "====================================="
  echo " Galaxy Deployment Tool"
  echo "====================================="

  echo "1)  Full remote deployment"
  echo "2)  Prepare control node"
  echo "3)  Install roles"
  echo "4)  Test SSH"
  echo "5)  Deploy Galaxy"
  echo "6)  Validate"
  echo "7)  Local deployment (Linux only)"
  echo "8)  Clean local environment"
  echo "9)  Clean remote environment"
  echo "10) Exit"

  read -rp "Choice: " c

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
    *) warn "Invalid option" ;;
  esac
}

menu
