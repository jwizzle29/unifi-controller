#!/usr/bin/env bash
# deploy.sh — install/refresh the UniFi Network Application controller +
# its dedicated MongoDB.
#
# Usage:
#   sudo ./deploy.sh
#
# Idempotent: re-running re-installs quadlets, refreshes envs, restarts
# the units. Container data persists in /srv/unifi/{data,mongo-data}
# across runs.
#
# Reads .env at the repo root for PUID, PGID, TZ. Generates MONGO_PASS
# on first run and persists it back to .env.

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "must run as root" >&2
    exit 1
fi

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$REPO_DIR/.env"
QUADLET_DIR="/etc/containers/systemd"

[[ -f "$ENV_FILE" ]] || { echo "missing $ENV_FILE (cp .env.example .env)" >&2; exit 1; }

for cmd in podman openssl envsubst; do
    command -v "$cmd" >/dev/null 2>&1 || { echo "missing: $cmd" >&2; exit 1; }
done

# shellcheck source=/dev/null
set -a; source "$ENV_FILE"; set +a

: "${PUID:=1000}"
: "${PGID:=1000}"
: "${TZ:=UTC}"

# Generate MongoDB password on first run, persist to .env.
if [[ -z "${MONGO_PASS:-}" ]]; then
    MONGO_PASS=$(openssl rand -base64 24 | tr -d '=+/' | cut -c1-32)
    echo "MONGO_PASS=$MONGO_PASS" >> "$ENV_FILE"
fi

echo "==> creating /srv/unifi layout"
mkdir -p /srv/unifi/data /srv/unifi/mongo-data

echo "==> rendering mongo init script"
umask 077
export MONGO_PASS
envsubst '${MONGO_PASS}' < "$REPO_DIR/config/mongo-init.js.tmpl" > /srv/unifi/mongo-init.js

echo "==> writing /srv/unifi/mongo.env"
cat > /srv/unifi/mongo.env <<EOF
MONGO_INITDB_ROOT_USERNAME=root
MONGO_INITDB_ROOT_PASSWORD=$MONGO_PASS
EOF

echo "==> writing /srv/unifi/unifi.env"
cat > /srv/unifi/unifi.env <<EOF
PUID=$PUID
PGID=$PGID
TZ=$TZ
MONGO_HOST=unifi-mongo
MONGO_PORT=27017
MONGO_USER=unifi
MONGO_PASS=$MONGO_PASS
MONGO_DBNAME=unifi
MONGO_AUTHSOURCE=unifi
EOF
umask 022

echo "==> installing quadlets"
install -m 0644 "$REPO_DIR/containers/unifi.network"          /srv/unifi/unifi.network
install -m 0644 "$REPO_DIR/containers/unifi-mongo.container"  /srv/unifi/unifi-mongo.container
install -m 0644 "$REPO_DIR/containers/unifi.container"        /srv/unifi/unifi.container

ln -sfn /srv/unifi/unifi.network          "$QUADLET_DIR/unifi.network"
ln -sfn /srv/unifi/unifi-mongo.container  "$QUADLET_DIR/unifi-mongo.container"
ln -sfn /srv/unifi/unifi.container        "$QUADLET_DIR/unifi.container"

systemctl daemon-reload

echo "==> starting services"
# Quadlet-generated units can't be `enable`d (they're transient).
# Auto-start at boot is handled by [Install] in each .container file.
systemctl restart unifi-mongo.service
sleep 5
systemctl restart unifi.service

cat <<EOF

==========================================
  UniFi Network Application deployed
==========================================
  Web UI:     https://$(hostname -I | awk '{print $1}'):8443
  Logs:       sudo journalctl -u unifi -u unifi-mongo -f
  Status:     systemctl status unifi unifi-mongo

First-run takes 1-3 min while MongoDB initializes and the controller
schema deploys. Then:
  1. Open the web UI above
  2. Skip the cloud sign-in, use local admin
  3. Adopt the AP from "Pending Adoption"
  4. Set SSID + WPA password

EOF
