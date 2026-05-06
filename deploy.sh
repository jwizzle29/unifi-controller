#!/usr/bin/env bash
# deploy.sh — install/refresh the UniFi Network Application controller.
#
# Usage:
#   sudo ./deploy.sh
#
# Idempotent: re-running re-installs the quadlet, refreshes env, restarts
# the unit. Container data persists in /srv/unifi/data across runs.
#
# Reads .env at the repo root for PUID, PGID, TZ.

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "must run as root" >&2
    exit 1
fi

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$REPO_DIR/.env"
QUADLET_DIR="/etc/containers/systemd"

[[ -f "$ENV_FILE" ]] || { echo "missing $ENV_FILE (cp .env.example .env)" >&2; exit 1; }

command -v podman >/dev/null 2>&1 || { echo "missing: podman" >&2; exit 1; }

# shellcheck source=/dev/null
set -a; source "$ENV_FILE"; set +a

: "${PUID:=1000}"
: "${PGID:=1000}"
: "${TZ:=UTC}"

echo "==> creating /srv/unifi layout"
mkdir -p /srv/unifi/data

echo "==> writing /srv/unifi/unifi.env"
umask 077
cat > /srv/unifi/unifi.env <<EOF
PUID=$PUID
PGID=$PGID
TZ=$TZ
EOF
umask 022

echo "==> installing quadlet"
install -m 0644 "$REPO_DIR/containers/unifi.container" /srv/unifi/unifi.container
ln -sfn /srv/unifi/unifi.container "$QUADLET_DIR/unifi.container"

systemctl daemon-reload

echo "==> starting unifi.service"
systemctl enable --now unifi.service
systemctl restart unifi.service

cat <<EOF

==========================================
  UniFi Network Application deployed
==========================================
  Web UI:  https://$(hostname -I | awk '{print $1}'):8443
  Logs:    sudo journalctl -u unifi.service -f
  Status:  systemctl status unifi.service

First-run:
  1. Open the web UI above
  2. Skip the cloud sign-in, use local admin
  3. Adopt the AP from "Pending Adoption"
  4. Set SSID + WPA password

EOF
