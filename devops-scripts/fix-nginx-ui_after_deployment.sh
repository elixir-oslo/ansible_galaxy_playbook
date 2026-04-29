#!/usr/bin/env bash
set -euo pipefail

# =====================================================================
# Galaxy nginx + UI reproducibility fix
# =====================================================================

# Must be run as root (no sudo prompts)
if [[ "$EUID" -ne 0 ]]; then
  echo "ERROR: This script must be run as root."
  echo "Run it with: sudo $0"
  exit 1
fi

echo "=== Galaxy nginx + UI stabilization ==="

GALAXY_STATIC="/srv/galaxy/server/static"
NGINX_SITE="/etc/nginx/sites-available/galaxy"
GALAXY_BIND="127.0.0.1:8080"

# ---------------------------------------------------------------------
# Step 1: Verify Galaxy backend is responding
# ---------------------------------------------------------------------
echo ">>> Step 1: Verifying Galaxy backend on ${GALAXY_BIND}"
if ! curl -sf "http://${GALAXY_BIND}/api/version" >/dev/null; then
  echo "ERROR: Galaxy backend is not reachable on ${GALAXY_BIND}"
  exit 1
fi
echo "✅ Galaxy backend reachable"

# ---------------------------------------------------------------------
# Step 2: Ensure static assets exist
# ---------------------------------------------------------------------
echo ">>> Step 2: Verifying Galaxy static assets"
if [[ ! -d "${GALAXY_STATIC}/dist" ]]; then
  echo "ERROR: Galaxy static assets not found (${GALAXY_STATIC}/dist missing)"
  exit 1
fi
echo "✅ Galaxy static assets present"

# ---------------------------------------------------------------------
# Step 3: Fix ownership & permissions (idempotent)
# ---------------------------------------------------------------------
echo ">>> Step 3: Fixing ownership & permissions"
chown -R galaxy:galaxy "${GALAXY_STATIC}"
find "${GALAXY_STATIC}" -type d -exec chmod 755 {} \;
find "${GALAXY_STATIC}" -type f -exec chmod 644 {} \;
echo "✅ Ownership and permissions fixed"

# ---------------------------------------------------------------------
# Step 4: Install correct nginx Galaxy site
# ---------------------------------------------------------------------
echo ">>> Step 4: Installing nginx Galaxy site"

cat > "${NGINX_SITE}" <<EOF
server {
    listen 80;
    server_name _;

    client_max_body_size 10G;

    # Serve Galaxy static assets
    location ^~ /static/ {
        alias ${GALAXY_STATIC}/;
        access_log off;
        expires 30d;
        add_header Cache-Control "public, max-age=2592000";
    }

    # Proxy dynamic requests to Galaxy
    location / {
        proxy_pass http://${GALAXY_BIND};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;

        proxy_buffering off;
        proxy_redirect off;
    }
}
EOF

ln -sf "${NGINX_SITE}" /etc/nginx/sites-enabled/galaxy
rm -f /etc/nginx/sites-enabled/default || true

echo "✅ nginx Galaxy site installed"

# ---------------------------------------------------------------------
# Step 5: Validate nginx configuration
# ---------------------------------------------------------------------
echo ">>> Step 5: Validating nginx configuration"
nginx -t
echo "✅ nginx configuration valid"

# ---------------------------------------------------------------------
# Step 6: Reload services
# ---------------------------------------------------------------------
echo ">>> Step 6: Reloading services"
systemctl reload nginx
systemctl restart galaxy
sleep 5

# ---------------------------------------------------------------------
# Step 7: Final verification
# ---------------------------------------------------------------------
echo ">>> Step 7: Verifying UI & API"

# Static check
STATIC_TEST_FILE="$(ls ${GALAXY_STATIC}/dist | head -n 1)"
curl -sf "http://localhost/static/dist/${STATIC_TEST_FILE}" >/dev/null \
  && echo "✅ Static assets served correctly"

# API check
curl -sf "http://localhost/api/version" >/dev/null \
  && echo "✅ Galaxy API reachable through nginx"

echo ""
echo "🎉 Galaxy UI fix applied successfully"
echo "🌐 Galaxy URL: http://$(hostname -I | awk '{print $1}')"
