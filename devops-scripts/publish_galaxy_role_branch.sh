#!/usr/bin/env bash
set -Eeuo pipefail

# =====================================================================
# Publish generated galaxy_deployment role to a role-only Git branch.
#
# What this script does:
#   1. Ensures you are on the main/source branch.
#   2. Runs scripts/sync_galaxy_playbook_to_role.py.
#   3. Runs syntax check for playbooks/galaxy-role.yml.
#   4. Commits regenerated role files on the source branch if changed.
#   5. Creates/updates a separate worktree for the role-only branch.
#   6. Copies roles/galaxy_deployment/* to the root of that branch.
#   7. Adds meta/main.yml and README.md.
#   8. Commits and pushes the role-only branch.
#   9. Creates and pushes a release tag for the role branch.
#
# Usage:
#   ./scripts/publish_galaxy_role_branch.sh galaxy-deployment-role-v1.0.2
#
# If no tag is provided, a timestamp tag will be generated:
#   galaxy-deployment-role-YYYYMMDD-HHMM
# =====================================================================

SOURCE_BRANCH="${SOURCE_BRANCH:-main}"
ROLE_BRANCH="${ROLE_BRANCH:-galaxy-deployment-role}"
ROLE_WORKTREE="${ROLE_WORKTREE:-../ansible_galaxy_playbook_role}"
REMOTE="${REMOTE:-origin}"
SYNC_SCRIPT="${SYNC_SCRIPT:-devops-scripts/sync_galaxy_playbook_to_role.py}"
ROLE_SOURCE_DIR="${ROLE_SOURCE_DIR:-roles/galaxy_deployment}"
ROLE_WRAPPER_PLAYBOOK="${ROLE_WRAPPER_PLAYBOOK:-playbooks/galaxy-role.yml}"
ROLE_README_SOURCE="${ROLE_README_SOURCE:-docs/using-galaxy-deployment-role.md}"

TAG_PREFIX="${TAG_PREFIX:-galaxy-deployment-role-v}"
REQUESTED_TAG="${1:-}"
TAG_NAME=""


info() {
  printf '\033[1;34m[INFO]\033[0m %s\n' "$*"
}

ok() {
  printf '\033[1;32m[OK]\033[0m %s\n' "$*"
}

warn() {
  printf '\033[1;33m[WARN]\033[0m %s\n' "$*"
}

fail() {
  printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "Required command not found: $1"
}

run() {
  info "$*"
  "$@"
}
next_role_tag() {
  # Fetch remote tags so we calculate from the latest known state.
  git fetch --tags "$REMOTE" >/dev/null 2>&1 || true

  local latest
  latest="$(
    {
      git tag -l "${TAG_PREFIX}*"
      git ls-remote --tags "$REMOTE" "${TAG_PREFIX}*" 2>/dev/null | awk '{print $2}' | sed 's#refs/tags/##'
    } \
    | sed 's/\^{}$//' \
    | sort -u \
    | grep -E "^${TAG_PREFIX}[0-9]+\.[0-9]+\.[0-9]+$" \
    | sed "s/^${TAG_PREFIX}//" \
    | sort -V \
    | tail -n 1
  )"

  if [[ -z "$latest" ]]; then
    echo "${TAG_PREFIX}1.0.0"
    return
  fi

  local major minor patch
  IFS='.' read -r major minor patch <<< "$latest"

  patch=$((patch + 1))

  echo "${TAG_PREFIX}${major}.${minor}.${patch}"
}

# Auto-activate project virtual environment if available.
if [[ -f "./venv/bin/activate" ]]; then
  # shellcheck disable=SC1091
  source "./venv/bin/activate"
fi


require_cmd git
require_cmd ansible-playbook
require_cmd python3

PROJECT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || fail "Run this script from inside the Git repository."
cd "$PROJECT_ROOT"

CURRENT_BRANCH="$(git branch --show-current)"

if [[ "$CURRENT_BRANCH" != "$SOURCE_BRANCH" ]]; then
  fail "You are on branch '$CURRENT_BRANCH'. Please checkout '$SOURCE_BRANCH' before publishing the role branch."
fi

[[ -f "$SYNC_SCRIPT" ]] || fail "Sync script not found: $SYNC_SCRIPT"
[[ -f "galaxy.yml" ]] || fail "Source playbook not found: galaxy.yml"

if [[ -n "$REQUESTED_TAG" ]]; then
  TAG_NAME="$REQUESTED_TAG"
else
  TAG_NAME="$(next_role_tag)"
fi

info "Source branch: $SOURCE_BRANCH"
info "Role branch: $ROLE_BRANCH"
info "Role worktree: $ROLE_WORKTREE"
info "Tag prefix: $TAG_PREFIX"
info "Tag name: $TAG_NAME"

# ---------------------------------------------------------------------
# 1. Regenerate role from galaxy.yml
# ---------------------------------------------------------------------
run "$SYNC_SCRIPT"

[[ -d "$ROLE_SOURCE_DIR/tasks" ]] || fail "Generated role tasks not found: $ROLE_SOURCE_DIR/tasks"
[[ -f "$ROLE_WRAPPER_PLAYBOOK" ]] || fail "Generated wrapper playbook not found: $ROLE_WRAPPER_PLAYBOOK"

# ---------------------------------------------------------------------
# 2. Syntax check generated role wrapper playbook
# ---------------------------------------------------------------------
run ansible-playbook -i hosts "$ROLE_WRAPPER_PLAYBOOK" --syntax-check

# ---------------------------------------------------------------------
# 3. Commit regenerated files on source branch if changed
# ---------------------------------------------------------------------
info "Checking for regenerated changes on $SOURCE_BRANCH"

if ! git diff --quiet || ! git diff --cached --quiet; then
  git add galaxy.yml "$SYNC_SCRIPT" "$ROLE_SOURCE_DIR" "$ROLE_WRAPPER_PLAYBOOK" ansible.cfg README.md docs 2>/dev/null || true

  if ! git diff --cached --quiet; then
    run git commit -m "Sync generated Galaxy deployment role from playbook"
    run git push "$REMOTE" "$SOURCE_BRANCH"
  else
    ok "No staged changes to commit on $SOURCE_BRANCH"
  fi
else
  ok "No source branch changes detected"
fi

# ---------------------------------------------------------------------
# 4. Ensure role worktree exists
# ---------------------------------------------------------------------
if [[ -d "$ROLE_WORKTREE" ]]; then
  info "Role worktree directory exists, checking if it is valid"

  if git -C "$ROLE_WORKTREE" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    ROLE_WORKTREE_BRANCH="$(git -C "$ROLE_WORKTREE" branch --show-current || true)"

    if [[ "$ROLE_WORKTREE_BRANCH" != "$ROLE_BRANCH" ]]; then
      warn "Existing worktree is not on expected branch '$ROLE_BRANCH'. Recreating it."
      git worktree remove "$ROLE_WORKTREE" --force 2>/dev/null || rm -rf "$ROLE_WORKTREE"
      git worktree prune
    else
      ok "Role worktree already exists on branch: $ROLE_BRANCH"
    fi
  else
    warn "Existing role worktree path is not a valid Git worktree. Removing it."
    rm -rf "$ROLE_WORKTREE"
    git worktree prune
  fi
fi

if [[ ! -d "$ROLE_WORKTREE" ]]; then
  info "Creating worktree for role branch"

  if git show-ref --verify --quiet "refs/heads/$ROLE_BRANCH"; then
    run git worktree add "$ROLE_WORKTREE" "$ROLE_BRANCH"

  elif git ls-remote --exit-code --heads "$REMOTE" "$ROLE_BRANCH" >/dev/null 2>&1; then
    run git fetch "$REMOTE" "$ROLE_BRANCH:$ROLE_BRANCH"
    run git worktree add "$ROLE_WORKTREE" "$ROLE_BRANCH"

  else
    info "Role branch does not exist locally or remotely. Creating it from $SOURCE_BRANCH."
    run git worktree add "$ROLE_WORKTREE" -b "$ROLE_BRANCH" "$SOURCE_BRANCH"
  fi
fi


# ---------------------------------------------------------------------
# 5. Update role-only branch contents
# ---------------------------------------------------------------------
cd "$ROLE_WORKTREE"

ROLE_CURRENT_BRANCH="$(git branch --show-current)"

if [[ "$ROLE_CURRENT_BRANCH" != "$ROLE_BRANCH" ]]; then
  run git checkout "$ROLE_BRANCH"
fi

# Pull latest branch if it exists remotely.
if git ls-remote --exit-code --heads "$REMOTE" "$ROLE_BRANCH" >/dev/null 2>&1; then
  run git pull --ff-only "$REMOTE" "$ROLE_BRANCH" || warn "Could not fast-forward role branch; continuing with local branch."
fi

# Remove tracked and untracked files from role branch working tree.
info "Clearing role branch working tree"

git rm -r --ignore-unmatch . >/dev/null 2>&1 || true
find . -mindepth 1 -maxdepth 1 ! -name .git -exec rm -rf {} +

# Extra safety: the role-only branch must not contain project-level folders.
rm -rf devops-scripts
rm -rf playbooks
rm -rf group_vars
rm -rf docs
rm -rf scripts
rm -rf roles
rm -f galaxy.yml
rm -f deploy.sh
rm -f nginx.yml
rm -f requirements.yml
rm -f hosts
rm -f ansible.cfg

# Copy generated role files to branch root.
info "Copying generated role files to role branch root"

cp -R "$PROJECT_ROOT/$ROLE_SOURCE_DIR"/* .

# Add README.md.
if [[ -f "$PROJECT_ROOT/$ROLE_README_SOURCE" ]]; then
  cp "$PROJECT_ROOT/$ROLE_README_SOURCE" README.md
else
  warn "Role README source not found: $ROLE_README_SOURCE. Creating minimal README.md."

  cat > README.md <<'EOF'
# galaxy_deployment

Reusable Ansible role for deploying Galaxy with PostgreSQL, Gravity, local client build, and nginx.
EOF
fi

# Add role metadata.
mkdir -p meta

cat > meta/main.yml <<'EOF'
---
galaxy_info:
  role_name: galaxy_deployment
  author: Yehia Mokhtar Farag
  description: Reusable Galaxy deployment role generated from the stable Galaxy Ansible playbook.
  license: MIT
  min_ansible_version: "2.14"
  platforms:
    - name: Ubuntu
      versions:
        - jammy
        - noble

dependencies:
  - role: galaxyproject.postgresql
  - role: galaxyproject.postgresql_objects
  - role: galaxyproject.galaxy
  - role: galaxyproject.miniconda
EOF

# Add .gitignore for role-only branch.
cat > .gitignore <<'EOF'
.venv/
venv/
__pycache__/
*.pyc
*.retry
.ansible/
ansible.log
.env
*.vault_pass
vault-password.txt
secrets.yml
.DS_Store
.idea/
.vscode/
tmp/
*.tmp
EOF

# Commit branch changes if any.
run git add .

if ! git diff --cached --quiet; then
  run git commit -m "Sync galaxy_deployment role from main playbook"
else
  ok "No role branch changes to commit"
fi

# Push role branch.
run git push "$REMOTE" "$ROLE_BRANCH"

# ---------------------------------------------------------------------
# 6. Create and push tag
# ---------------------------------------------------------------------
info "Checking tag availability: $TAG_NAME"

if git rev-parse -q --verify "refs/tags/$TAG_NAME" >/dev/null; then
  fail "Local tag already exists: $TAG_NAME. Use a new tag name."
fi

if git ls-remote --exit-code --tags "$REMOTE" "$TAG_NAME" >/dev/null 2>&1; then
  fail "Remote tag already exists: $TAG_NAME. Use a new tag name."
fi

run git tag "$TAG_NAME"
run git push "$REMOTE" "$TAG_NAME"

ok "Published role branch and tag successfully"
info "Role branch: $ROLE_BRANCH"
info "Role tag: $TAG_NAME"

info "Install from another project with:"
cat <<EOF

roles:
  - name: galaxy_deployment
    src: git+ssh://git@github.com/yehiafarag/ansible_galaxy_playbook.git
    version: $TAG_NAME

EOF