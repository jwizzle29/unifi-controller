#!/usr/bin/env bash
# deploy.sh — install/refresh the UniFi Network Application controller +
# its dedicated MongoDB.
#
# Usage:
#   sudo ./deploy.sh
#
# Idempotent: re-running re-installs quadlets, refreshes envs, restarts
# the units, ensures the unifi mongo user exists. Container data persists
# in /srv/unifi/{data,mongo-data} across runs.
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

for cmd in podman openssl; do
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

echo "==> writing /srv/unifi/mongo.env"
umask 077
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

echo "==> starting unifi-mongo"
# Stop unifi while we set up mongo so it doesn't keep failing during the window.
systemctl stop unifi.service 2>/dev/null || true
systemctl restart unifi-mongo.service

echo "==> waiting for mongo to accept auth"
for i in $(seq 1 60); do
    if podman exec unifi-mongo mongosh --quiet \
        -u root -p "$MONGO_PASS" --authenticationDatabase admin \
        --eval 'db.runCommand({ping:1})' >/dev/null 2>&1; then
        echo "    mongo ready after ${i}s"
        break
    fi
    sleep 1
    if [[ $i -eq 60 ]]; then
        echo "ERROR: mongo not responding after 60s — check 'sudo journalctl -u unifi-mongo'" >&2
        exit 1
    fi
done

echo "==> ensuring unifi mongo user exists"
podman exec -i unifi-mongo mongosh --quiet \
    -u root -p "$MONGO_PASS" --authenticationDatabase admin <<EOF
use unifi
try {
  db.createUser({
    user: "unifi",
    pwd: "$MONGO_PASS",
    roles: [
      { role: "dbOwner", db: "unifi" },
      { role: "dbOwner", db: "unifi_stat" }
    ]
  });
  print("created unifi user");
} catch (e) {
  if (e.codeName === "DuplicateKey" || /already exists/i.test(e.message)) {
    db.updateUser("unifi", {
      pwd: "$MONGO_PASS",
      roles: [
        { role: "dbOwner", db: "unifi" },
        { role: "dbOwner", db: "unifi_stat" }
      ]
    });
    print("updated unifi user (was already present)");
  } else {
    throw e;
  }
}
EOF

echo "==> starting unifi.service"
systemctl restart unifi.service

cat <<EOF

==========================================
  UniFi Network Application deployed
==========================================
  Web UI:     https://$(hostname -I | awk '{print $1}'):8443
  Logs:       sudo journalctl -u unifi -u unifi-mongo -f
  Status:     systemctl status unifi unifi-mongo

First-run takes 1-3 min while the controller schema deploys. Then:
  1. Open the web UI above
  2. Skip the cloud sign-in, use local admin
  3. Adopt the AP from "Pending Adoption"
  4. Set SSID + WPA password

EOF
