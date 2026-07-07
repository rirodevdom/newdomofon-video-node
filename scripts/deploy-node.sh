#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="${PROJECT_DIR:-/opt/newdomofon-video}"
ENV_FILE="${ENV_FILE:-/etc/newdomofon-video/app.env}"

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

install -d -o newdomofon -g newdomofon /var/lib/newdomofon-video/dvr /var/log/newdomofon-video
cp "$PROJECT_DIR/deploy/systemd/newdomofon-video-dvr.service" /etc/systemd/system/
cp "$PROJECT_DIR/deploy/nginx/newdomofon-video-node.conf" /etc/nginx/sites-available/newdomofon-video-node.conf
ln -sf /etc/nginx/sites-available/newdomofon-video-node.conf /etc/nginx/sites-enabled/newdomofon-video-node.conf

systemctl daemon-reload
systemctl enable --now newdomofon-video-dvr
nginx -t
systemctl reload nginx

echo "Node deployed. Check: curl -fsS http://127.0.0.1:3010/health"
