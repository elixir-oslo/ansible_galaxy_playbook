#!/usr/bin/env bash
set -euo pipefail

# -------------------------------
# CONFIG
# -------------------------------
GALAXY_USER="galaxy"
GALAXY_CONFIG="/srv/galaxy/config/galaxy.yml"
GALAXY_INTERNAL="http://127.0.0.1:8080"
GALAXY_EXTERNAL="http://$(hostname -I | awk '{print $1}')"
LOG_DIR="/srv/galaxy/mutable/gravity/log"

# -------------------------------
# HELPERS
# -------------------------------
ok()   { echo "✅  $1"; }
fail() { echo "❌  $1"; exit 1; }
step() { echo -e "\n🔹 $1"; }

# -------------------------------
# TESTS
# -------------------------------

step "1. Checking Galaxy process status"
sudo -u "$GALAXY_USER" /srv/galaxy/venv/bin/galaxyctl \
  -c "$GALAXY_CONFIG" status | grep -q RUNNING \
  || fail "Galaxy services are not all RUNNING"
ok "Galaxy services are RUNNING"

step "2. Checking listening ports"
ss -tulpn | grep -q ":8080" || fail "Galaxy not listening on 127.0.0.1:8080"
ss -tulpn | grep -q ":80" || fail "Nginx not listening on port 80"
ok "Ports 8080 and 80 are listening"

step "3. Checking internal Galaxy API"
curl -sf "$GALAXY_INTERNAL/api/version" \
  || fail "Galaxy internal API not responding"
ok "Internal API OK"

step "4. Checking external Galaxy API via Nginx"
curl -sf "$GALAXY_EXTERNAL/api/version" \
  || fail "Galaxy external API not responding"
ok "External API OK"

step "5. Verifying PostgreSQL usage (no SQLite)"
grep -qi sqliteimpl "$LOG_DIR/gunicorn.log" \
  && fail "SQLite detected in gunicorn.log"
ok "PostgreSQL confirmed"

step "6. Restart resilience test (Galaxy)"
sudo systemctl restart galaxy
sleep 30
sudo -u "$GALAXY_USER" /srv/galaxy/venv/bin/galaxyctl \
  -c "$GALAXY_CONFIG" status | grep -q RUNNING \
  || fail "Galaxy did not recover after restart"
ok "Galaxy restart OK"

step "7. Restart resilience test (Nginx)"
sudo systemctl restart nginx
curl -sf "$GALAXY_EXTERNAL/api/version" \
  || fail "Galaxy not reachable after Nginx restart"
ok "Nginx restart OK"

echo -e "\n🎉 Galaxy validation PASSED"
