#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="${PROJECT_DIR:-/opt/newdomofon-video}"
ENV_FILE="${ENV_FILE:-/etc/newdomofon-video/app.env}"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run as root: sudo PROJECT_DIR=$PROJECT_DIR bash scripts/deploy-master.sh" >&2
  exit 1
fi

cd "$PROJECT_DIR"
install -d -m 0750 "$(dirname "$ENV_FILE")"
if [[ ! -f "$ENV_FILE" ]]; then
  cp deploy/env/master.env.example "$ENV_FILE"
  chmod 0640 "$ENV_FILE"
  echo "Created $ENV_FILE. Edit secrets and rerun this script."
  exit 2
fi

set -a
# shellcheck disable=SC1090
. "$ENV_FILE"
set +a

cd "$PROJECT_DIR/backend"
npm ci --include=dev
npm run build
npm run migrate
npm run seed
npm prune --omit=dev

cd "$PROJECT_DIR/frontend"
npm ci --include=dev
npm run build
rsync -a --delete dist/ /var/www/newdomofon-video/
chown -R newdomofon:newdomofon /var/www/newdomofon-video

if [[ -d "$PROJECT_DIR/public-events-proxy" ]]; then
  cd "$PROJECT_DIR/public-events-proxy"
  if [[ -f package-lock.json ]]; then
    npm ci --omit=dev
  else
    npm install --omit=dev
  fi
fi

install -d -o newdomofon -g newdomofon -m 0755 \
  /var/lib/newdomofon-video \
  /var/cache/newdomofon-video \
  /var/cache/newdomofon-video/smartyard-preview \
  /var/log/newdomofon-video

cp "$PROJECT_DIR/deploy/systemd/newdomofon-video-backend.service" /etc/systemd/system/
cp "$PROJECT_DIR/deploy/systemd/newdomofon-public-events-proxy.service" /etc/systemd/system/
if [[ -f "$PROJECT_DIR/deploy/systemd/newdomofon-smartyard-compat.service" ]]; then
  cp "$PROJECT_DIR/deploy/systemd/newdomofon-smartyard-compat.service" /etc/systemd/system/
fi
cp "$PROJECT_DIR/deploy/nginx/newdomofon-video.conf" /etc/nginx/sites-available/newdomofon-video.conf
ln -sf /etc/nginx/sites-available/newdomofon-video.conf /etc/nginx/sites-enabled/newdomofon-video.conf

systemctl daemon-reload
systemctl enable --now newdomofon-video-backend
systemctl enable --now newdomofon-public-events-proxy
if [[ -f /etc/systemd/system/newdomofon-smartyard-compat.service ]]; then
  systemctl enable --now newdomofon-smartyard-compat
fi
nginx -t
systemctl reload nginx

echo "Master deployed."
