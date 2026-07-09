#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="${PROJECT_DIR:-/opt/newdomofon-video}"
ENV_FILE="${ENV_FILE:-/etc/newdomofon-video/app.env}"
SERVICE="${SERVICE:-newdomofon-video-dvr.service}"
STREAMS="${EVENT_STREAMS:-onvif2,onf}"
DURATION="${SECONDS:-180}"
BACKUP_DIR="$PROJECT_DIR/backups/solo-onvif-ruleengine-motion-test-$(date +%Y%m%d-%H%M%S)"
DIAG_SCRIPT="/tmp/diagnose-onvif-live-ruleengine-node.sh"

mkdir -p "$BACKUP_DIR"
cp -a "$ENV_FILE" "$BACKUP_DIR/app.env.bak"

restore() {
  cp -a "$BACKUP_DIR/app.env.bak" "$ENV_FILE"
  systemctl restart "$SERVICE" >/dev/null 2>&1 || true
}
trap restore EXIT

# Temporarily stop only DVR embedded event collectors. Recording service restarts once before and once after the test.
sed -i -E '/^(EVENTS_ENABLED|ONVIF_EVENTS_ENABLED|ONVIF_V2_SKIP_STREAMS|ONVIF_EVENTS_V2_SKIP_STREAMS|ONVIF_LEGACY_FALLBACK_STREAMS)=/d' "$ENV_FILE"
cat <<'EOF' >> "$ENV_FILE"
EVENTS_ENABLED=false
ONVIF_EVENTS_ENABLED=false
ONVIF_V2_SKIP_STREAMS=*
ONVIF_EVENTS_V2_SKIP_STREAMS=*
ONVIF_LEGACY_FALLBACK_STREAMS=__disabled__
EOF

systemctl restart "$SERVICE"
sleep 8

echo "Embedded ONVIF collectors are disabled for the test. Now run movement in front of the camera for ${DURATION}s."

if [ ! -s "$DIAG_SCRIPT" ]; then
  curl --retry 5 --retry-delay 2 --connect-timeout 20 --max-time 120 -fsSL \
    "https://raw.githubusercontent.com/rirodevdom/newdomofon-video/main/scripts/diagnose-onvif-live-ruleengine-node.sh?nocache=$(date +%s%N)" \
    -o "$DIAG_SCRIPT"
fi
chmod +x "$DIAG_SCRIPT"

EVENT_STREAMS="$STREAMS" SECONDS="$DURATION" OUT_DIR="$BACKUP_DIR/live-dump" bash "$DIAG_SCRIPT" || true

echo "---- summary ----"
grep -RniE '"operation":"Changed"|IsMotion|RuleEngine|CellMotionDetector|Motion|Initialized' "$BACKUP_DIR/live-dump" | head -300 || true

echo "OUT_DIR=$BACKUP_DIR/live-dump"
echo "backup_dir=$BACKUP_DIR"
echo "The DVR env will be restored now."
