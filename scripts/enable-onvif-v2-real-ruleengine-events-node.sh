#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="${PROJECT_DIR:-/opt/newdomofon-video}"
ENV_FILE="${ENV_FILE:-/etc/newdomofon-video/app.env}"
SERVICE="${SERVICE:-newdomofon-video-dvr.service}"
STREAMS="${EVENT_STREAMS:-onvif2,onf}"
TARGET="$PROJECT_DIR/dvr-engine/src/onvifEventsV2.ts"
BACKUP_DIR="$PROJECT_DIR/backups/enable-onvif-v2-real-ruleengine-$(date +%Y%m%d-%H%M%S)"

mkdir -p "$BACKUP_DIR"
cp -a "$TARGET" "$BACKUP_DIR/onvifEventsV2.ts.bak"
cp -a "$ENV_FILE" "$BACKUP_DIR/app.env.bak" 2>/dev/null || true

cd "$PROJECT_DIR"

# Use the current compat PullPoint collector from the repository. It subscribes without the unsupported MotionAlarm filter
# and parses RuleEngine SimpleItem values like IsMotion=true/false.
curl --retry 5 --retry-delay 2 --connect-timeout 20 --max-time 120 -fsSL \
  "https://raw.githubusercontent.com/rirodevdom/newdomofon-video/main/dvr-engine/src/onvifEventsV2.ts?nocache=$(date +%s%N)" \
  -o "$TARGET"

sudo sed -i -E '/^(EVENTS_ENABLED|ONVIF_EVENTS_ENABLED|ONVIF_V2_SKIP_STREAMS|ONVIF_EVENTS_V2_SKIP_STREAMS|ONVIF_LEGACY_FALLBACK_STREAMS|ONVIF_EVENT_POLL_INTERVAL_MS|EVENT_POLL_INTERVAL_MS|ONVIF_PULL_LIMIT|ONVIF_PULL_TIMEOUT|ONVIF_SUBSCRIBE_TTL_MS|ONVIF_EVENT_CONCURRENCY|ONVIF_FAIL_RETRY_MIN_MS|ONVIF_FAIL_RETRY_MAX_MS|ONVIF_QUIET_LOG_MS|ONVIF_SYNC_LOG_MS)=/d' "$ENV_FILE" 2>/dev/null || true
cat <<EOF | sudo tee -a "$ENV_FILE" >/dev/null
EVENTS_ENABLED=true
ONVIF_EVENTS_ENABLED=true
ONVIF_V2_SKIP_STREAMS=
ONVIF_EVENTS_V2_SKIP_STREAMS=
ONVIF_LEGACY_FALLBACK_STREAMS=
ONVIF_EVENT_POLL_INTERVAL_MS=1000
EVENT_POLL_INTERVAL_MS=1000
ONVIF_PULL_LIMIT=100
ONVIF_PULL_TIMEOUT=PT3S
ONVIF_SUBSCRIBE_TTL_MS=600000
ONVIF_EVENT_CONCURRENCY=4
ONVIF_FAIL_RETRY_MIN_MS=3000
ONVIF_FAIL_RETRY_MAX_MS=15000
ONVIF_QUIET_LOG_MS=30000
ONVIF_SYNC_LOG_MS=30000
EOF

cd "$PROJECT_DIR/dvr-engine"
npm install --include=dev
npm run build
sudo systemctl restart "$SERVICE"
sleep 8

echo "---- health ----"
curl -fsS http://127.0.0.1:3010/health || true
echo

echo "---- onvif v2 logs ----"
sudo journalctl -u "$SERVICE" --since "2 minutes ago" --no-pager -l | grep -E 'onvif-events:v2|pullpoint created|stored events|poll ok|poll failed|RuleEngine|IsMotion|legacy-fallback' || true

echo "OK: ONVIF v2 real RuleEngine collector enabled for streams: $STREAMS"
echo "backup_dir=$BACKUP_DIR"
