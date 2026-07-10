#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="${PROJECT_DIR:-/opt/newdomofon-video-node}"
ENV_FILE="${ENV_FILE:-/etc/newdomofon-video/app.env}"
DVR_SERVICE="${DVR_SERVICE:-newdomofon-video-dvr.service}"
BACKUP_DIR="$PROJECT_DIR/backups/events-unified-v1-node-$(date +%Y%m%d-%H%M%S)"

mkdir -p "$BACKUP_DIR"
[ -f "$ENV_FILE" ] && cp -a "$ENV_FILE" "$BACKUP_DIR/app.env.bak" || true

set -a
[ -f "$ENV_FILE" ] && . "$ENV_FILE"
set +a

if [ -z "${INTERNAL_DVR_SECRET:-}" ]; then
  echo "ERROR: INTERNAL_DVR_SECRET is empty on node. It must match master." >&2
  echo "Set it in $ENV_FILE before running this script." >&2
  exit 1
fi

if [ -z "${BACKEND_INTERNAL_URL:-${BACKEND_URL:-}}" ]; then
  echo "WARN: BACKEND_INTERNAL_URL/BACKEND_URL is empty, using http://10.106.1.30:3000" >&2
  sudo sed -i -E '/^(BACKEND_INTERNAL_URL|BACKEND_URL)=/d' "$ENV_FILE"
  echo 'BACKEND_INTERNAL_URL=http://10.106.1.30:3000' | sudo tee -a "$ENV_FILE" >/dev/null
fi

sudo sed -i -E '/^(EVENTS_ENABLED|ONVIF_EVENTS_ENABLED|ONVIF_EVENT_POLL_INTERVAL_MS|EVENT_POLL_INTERVAL_MS|ONVIF_PULL_LIMIT|ONVIF_PULL_TIMEOUT|ONVIF_SUBSCRIBE_TTL_MS|ONVIF_EVENT_CONCURRENCY|ONVIF_EVENT_MAX_CLOCK_SKEW_MS)=/d' "$ENV_FILE"
cat <<'EOF' | sudo tee -a "$ENV_FILE" >/dev/null
EVENTS_ENABLED=true
ONVIF_EVENTS_ENABLED=true
ONVIF_EVENT_POLL_INTERVAL_MS=3000
EVENT_POLL_INTERVAL_MS=3000
ONVIF_PULL_LIMIT=100
ONVIF_PULL_TIMEOUT=PT3S
ONVIF_SUBSCRIBE_TTL_MS=300000
ONVIF_EVENT_CONCURRENCY=8
ONVIF_EVENT_MAX_CLOCK_SKEW_MS=300000
EOF

cd "$PROJECT_DIR/dvr-engine"
npm install --include=dev
npm run build
sudo systemctl restart "$DVR_SERVICE"
sleep 4

echo "---- dvr health ----"
curl -fsS http://127.0.0.1:3010/health || true
echo

echo "---- onvif event logs ----"
sudo journalctl -u "$DVR_SERVICE" -n 160 --no-pager -l | grep -E 'onvif-events|stored events|poll ok|sync|missing onvif|INTERNAL_DVR_SECRET|pullpoint|event service' || true

echo "OK: unified events node pipeline enabled"
echo "backup_dir=$BACKUP_DIR"
