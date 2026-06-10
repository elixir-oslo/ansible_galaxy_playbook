#!/usr/bin/env bash
# ========================================================================
# GALAXY QUICK TEST - Verify deployment without full installation
# ========================================================================
# This script tests connectivity and configuration without deploying

set -e

PLAYBOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
VENV_DIR="$PLAYBOOK_DIR/venv"

echo "🔍 Galaxy Ansible Deployment - Quick Test"
echo ""

# Check if venv exists
if [ ! -d "$VENV_DIR" ]; then
    echo "❌ Virtual environment not found at $VENV_DIR"
    echo "   Run './run.sh' first to set up Ansible"
    exit 1
fi

source "$VENV_DIR/bin/activate"

echo "✓ Virtual environment activated"
echo ""

# Check requirements
echo "🔧 Checking deployment requirements..."
if ! command -v python3 >/dev/null 2>&1; then
    echo "❌ Python 3 not found"
    exit 1
fi
echo "✓ Python 3 available"

if ! command -v ansible >/dev/null 2>&1; then
    echo "❌ Ansible not found"
    exit 1
fi
echo "✓ Ansible available"

if ! command -v git >/dev/null 2>&1; then
    echo "❌ Git not found"
    exit 1
fi
echo "✓ Git available"

echo ""

# Test inventory
echo "📋 Testing Ansible inventory..."
if ! ansible -i "$PLAYBOOK_DIR/hosts" all --list-hosts >/dev/null 2>&1; then
    echo "❌ Inventory test failed"
    exit 1
fi
echo "✓ Inventory is valid"

# Test connectivity
echo ""
echo "🔌 Testing connectivity to galaxyservers..."
ansible -i "$PLAYBOOK_DIR/hosts" galaxyservers -m ping

# Test syntax
echo ""
echo "📝 Validating main playbook syntax..."
ansible-playbook -i "$PLAYBOOK_DIR/hosts" "$PLAYBOOK_DIR/galaxy.yml" --syntax-check

echo ""
echo "📝 Validating role playbook syntax..."
ansible-playbook -i "$PLAYBOOK_DIR/hosts" "$PLAYBOOK_DIR/playbooks/galaxy-role.yml" --syntax-check


echo ""
echo "✅ All tests passed!"
echo ""
echo "To deploy Galaxy, run:"
echo "  ./deploy.sh"
