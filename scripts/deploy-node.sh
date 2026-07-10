#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="${PROJECT_DIR:-/opt/newdomofon-video-node}"
ENV_FILE="${ENV_FILE:-/etc/newdomofon-video/app.env}"
INSTALL_DISK_GUARD="${INSTALL_DISK_GUARD:-1}"
INSTALL_JOURNAL_LIMITS="${INSTALL_JOURNAL_LIMITS:-1}"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run as root: sudo PROJECT_DIR=$PROJECT_DIR bash scripts/deploy-node.sh" >&2
  exit 1
fi

cd "$PROJECT_DIR"
install -d -m 0750 "$(dirname "$ENV_FILE")"
if [[ ! -f "$ENV_FILE" ]]; then
  cp deploy/env/node.env.example "$ENV_FILE"
  chmod 0640 "$ENV_FILE"
  echo "Created $ENV_FILE. Paste node credentials and rerun this script."
  exit 2
fi

cd "$PROJECT_DIR/dvr-engine"
npm ci --include=dev
npm run build
npm prune --omit=dev

install -d -o newdomofon -g newdomofon /var/lib/newdomofon-video/dvr /var/lib/newdomofon-video/events /var/log/newdomofon-video
cp "$PROJECT_DIR/deploy/systemd/newdomofon-video-dvr.service" /etc/systemd/system/
cp "$PROJECT_DIR/deploy/nginx/newdomofon-video-node.conf" /etc/nginx/sites-available/newdomofon-video-node.conf
ln -sf /etc/nginx/sites-available/newdomofon-video-node.conf /etc/nginx/sites-enabled/newdomofon-video-node.conf

systemctl daemon-reload
systemctl enable --now newdomofon-video-dvr

if [[ "$INSTALL_DISK_GUARD" =~ ^(1|true|yes|on)$ ]]; then
  PROJECT_DIR="$PROJECT_DIR" INSTALL_JOURNAL_LIMITS="$INSTALL_JOURNAL_LIMITS" \
    bash "$PROJECT_DIR/scripts/install-node-disk-guard.sh"
fi

nginx -t
systemctl reload nginx

echo "Node deployed. Check: curl -fsS http://127.0.0.1:3010/health"
if [[ "$INSTALL_DISK_GUARD" =~ ^(1|true|yes|on)$ ]]; then
  echo "Disk guard: cat /run/newdomofon-video/node-disk-state.json"
fi
