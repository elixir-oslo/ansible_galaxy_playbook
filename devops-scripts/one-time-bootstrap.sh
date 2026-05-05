#!/usr/bin/env bash
set -euo pipefail



BOOTSTRAP_MARKER="/var/lib/galaxy/bootstrap.done"

mkdir -p /var/lib/galaxy

if [[ -f "$BOOTSTRAP_MARKER" ]]; then
  echo "✅ Galaxy bootstrap already completed — skipping"
  exit 0
fi


# ---------------------------------------------------------------------
# Must be run as root (no sudo prompts)
# ---------------------------------------------------------------------
if [[ "$EUID" -ne 0 ]]; then
  echo "ERROR: This script must be run as root."
  echo "Run it with: sudo $0"
  exit 1
fi

echo "=== Galaxy one-time stabilization script ==="

GALAXY_EXTERNAL_IP="$(hostname -I | awk '{print $1}')"
NGINX_SITE="/etc/nginx/sites-available/galaxy"
GALAXY_SOCKET="/srv/galaxy/mutable/gunicorn.sock"

echo ">>> Step 1: Stop services"
systemctl stop nginx 2>/dev/null || true
systemctl stop galaxy 2>/dev/null || true

echo ">>> Step 2: Remove legacy broken nginx config (safe)"
rm -f /etc/nginx/conf.d/http_options.conf || true

echo ">>> Step 3: Ensure Galaxy nginx site exists"
if [[ ! -f "$NGINX_SITE" ]]; then
  cat <<EOF > "$NGINX_SITE"
server {
    listen 80;
    server_name _;

    location / {
        proxy_pass http://unix:${GALAXY_SOCKET};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF
else
  echo "Galaxy nginx site already exists ✅"
fi

echo ">>> Step 4: Enable Galaxy nginx site"
ln -sf /etc/nginx/sites-available/galaxy /etc/nginx/sites-enabled/galaxy

echo ">>> Step 5: Reset Gravity runtime state (safe)"
rm -rf /srv/galaxy/mutable/gravity/state || true

echo ">>> Step 6: Reload systemd"
systemctl daemon-reload

echo ">>> Step 7: Validate nginx config"
nginx -t

echo ">>> Step 8: Start Galaxy service"
systemctl start galaxy

echo ">>> Waiting for Galaxy to initialize..."
sleep 20

echo ">>> Step 9: Start nginx"
systemctl start nginx

echo ">>> Step 10: Verify Galaxy API via nginx"

if curl -sf "http://localhost/api/version" >/dev/null; then
  echo "✅ Galaxy API reachable via nginx"
else
  echo ""


echo ""
echo "✅ Galaxy stabilization completed successfully"
echo "🌐 Galaxy is available at: http://${GALAXY_EXTERNAL_IP}"

touch "$BOOTSTRAP_MARKER"