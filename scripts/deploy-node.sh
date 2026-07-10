#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="${PROJECT_DIR:-/opt/newdomofon-video-node}"
ENV_FILE="${ENV_FILE:-/etc/newdomofon-video/app.env}"
INSTALL_DISK_GUARD="${INSTALL_DISK_GUARD:-1}"
INSTALL_JOURNAL_LIMITS="${INSTALL_JOURNAL_LIMITS:-1}"
INSTALL_ARCHIVE_EVENT_SYNC="${INSTALL_ARCHIVE_EVENT_SYNC:-1}"

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

if [[ "$INSTALL_DISK_GUARD" =~ ^(1|true|yes|on)$ ]]; then
  NEWDOMOFON_ENV_FILE="$ENV_FILE" bash "$PROJECT_DIR/scripts/node-system-disk-check.sh" || true
  if [[ ! -e /run/newdomofon-video/node-disk-paused ]]; then
    NEWDOMOFON_ENV_FILE="$ENV_FILE" bash "$PROJECT_DIR/scripts/node-disk-guard.sh"
  fi
  if [[ -e /run/newdomofon-video/node-disk-paused ]]; then
    echo "Deployment aborted: node disk guard is critical." >&2
    cat /run/newdomofon-video/node-disk-state.json >&2 2>/dev/null || true
    exit 75
  fi
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
systemctl enable newdomofon-video-dvr

if [[ "$INSTALL_DISK_GUARD" =~ ^(1|true|yes|on)$ ]]; then
  PROJECT_DIR="$PROJECT_DIR" INSTALL_JOURNAL_LIMITS="$INSTALL_JOURNAL_LIMITS" \
    bash "$PROJECT_DIR/scripts/install-node-disk-guard.sh"
fi

if [[ "$INSTALL_ARCHIVE_EVENT_SYNC" =~ ^(1|true|yes|on)$ ]]; then
  PROJECT_DIR="$PROJECT_DIR" \
    bash "$PROJECT_DIR/scripts/install-archive-event-sync.sh"
fi

if [[ ! -e /run/newdomofon-video/node-disk-paused ]]; then
  systemctl restart newdomofon-video-dvr
else
  echo "DVR remains stopped because disk guard is critical." >&2
fi

nginx -t
systemctl reload nginx

echo "Node deployed. Check: curl -fsS http://127.0.0.1:3010/health"
if [[ "$INSTALL_DISK_GUARD" =~ ^(1|true|yes|on)$ ]]; then
  echo "Disk guard: cat /run/newdomofon-video/node-disk-state.json"
fi
if [[ "$INSTALL_ARCHIVE_EVENT_SYNC" =~ ^(1|true|yes|on)$ ]]; then
  echo "Archive/event sync: cat /var/lib/newdomofon-video/events/archive-event-sync-state.json"
fi
