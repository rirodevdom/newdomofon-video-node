#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="${PROJECT_DIR:-/opt/newdomofon-video-node}"
ENV_FILE="${ENV_FILE:-/etc/newdomofon-video/app.env}"
DVR_SERVICE="${DVR_SERVICE:-newdomofon-video-dvr.service}"
BACKUP_DIR="$PROJECT_DIR/backups/events-video-motion-fallback-onvif-node-$(date +%Y%m%d-%H%M%S)"

mkdir -p "$BACKUP_DIR"
[ -f "$ENV_FILE" ] && cp -a "$ENV_FILE" "$BACKUP_DIR/app.env.bak" || true

set -a
[ -f "$ENV_FILE" ] && . "$ENV_FILE"
set +a

if [ -z "${INTERNAL_DVR_SECRET:-}" ]; then
  echo "ERROR: INTERNAL_DVR_SECRET is empty on node. It must match master." >&2
  exit 1
fi

BACKEND_URL_EFFECTIVE="${BACKEND_INTERNAL_URL:-${BACKEND_URL:-http://10.106.1.30:3000}}"
NODE_ID_EFFECTIVE="${DVR_NODE_ID:-${NODE_ID:-3348ffdf-2455-472f-a941-4eb456fb1df6}}"
STREAMS="${EVENT_STREAMS:-${VIDEO_MOTION_STREAMS:-}}"

if [ -z "$STREAMS" ]; then
  STREAMS="$({
    curl -fsS \
      -H "x-internal-secret: ${INTERNAL_DVR_SECRET}" \
      -H "x-node-id: ${NODE_ID_EFFECTIVE}" \
      "${BACKEND_URL_EFFECTIVE%/}/api/internal/cameras/onvif" || true
  } | python3 - <<'PY'
import json, sys
try:
    data=json.load(sys.stdin)
    streams=[str(x.get('stream_name','')).strip() for x in data.get('items', [])]
    print(','.join([x for x in streams if x]))
except Exception:
    print('')
PY
)"
fi

if [ -z "$STREAMS" ]; then
  echo "ERROR: unable to auto-detect ONVIF streams. Run with EVENT_STREAMS=onvif2,onf" >&2
  exit 1
fi

echo "ONVIF/video-motion streams: $STREAMS"

# Remove old duplicated keys.
sudo sed -i -E '/^(VIDEO_MOTION_ENABLED|VIDEO_MOTION_STREAMS|DVR_VIDEO_MOTION_STREAMS|VIDEO_MOTION_SOURCE|DVR_VIDEO_MOTION_SOURCE|VIDEO_MOTION_FPS|VIDEO_MOTION_SCALE_WIDTH|VIDEO_MOTION_SCENE_THRESHOLD|VIDEO_MOTION_END_IDLE_MS|VIDEO_MOTION_COOLDOWN_MS|VIDEO_MOTION_RELOAD_MS|VIDEO_MOTION_MAX_DETECTORS|VIDEO_MOTION_EVENT_TYPE|ONVIF_V2_SKIP_STREAMS|ONVIF_EVENTS_V2_SKIP_STREAMS|ONVIF_LEGACY_FALLBACK_STREAMS|ONVIF_LEGACY_SYNC_MS|ONVIF_LEGACY_SESSION_TTL_MS|ONVIF_LEGACY_IGNORE_INITIALIZED|ONVIF_LEGACY_INITIALIZED_STATE_EVENTS)=/d' "$ENV_FILE"

cat <<EOF | sudo tee -a "$ENV_FILE" >/dev/null
# Unified events fallback for ONVIF cameras whose PullPoint subscription fails with HTTP 400.
# The old ONVIF events are still allowed for other streams, but these streams use video-motion fallback.
ONVIF_V2_SKIP_STREAMS=${STREAMS}
ONVIF_EVENTS_V2_SKIP_STREAMS=${STREAMS}
ONVIF_LEGACY_FALLBACK_STREAMS=${STREAMS}
ONVIF_LEGACY_SYNC_MS=10000
ONVIF_LEGACY_SESSION_TTL_MS=0
ONVIF_LEGACY_IGNORE_INITIALIZED=true
ONVIF_LEGACY_INITIALIZED_STATE_EVENTS=false

VIDEO_MOTION_ENABLED=true
VIDEO_MOTION_STREAMS=${STREAMS}
DVR_VIDEO_MOTION_STREAMS=${STREAMS}
VIDEO_MOTION_SOURCE=hls
DVR_VIDEO_MOTION_SOURCE=hls
VIDEO_MOTION_FPS=2
VIDEO_MOTION_SCALE_WIDTH=320
VIDEO_MOTION_SCENE_THRESHOLD=${VIDEO_MOTION_SCENE_THRESHOLD_VALUE:-0.006}
VIDEO_MOTION_END_IDLE_MS=8000
VIDEO_MOTION_COOLDOWN_MS=3000
VIDEO_MOTION_RELOAD_MS=15000
VIDEO_MOTION_MAX_DETECTORS=4
VIDEO_MOTION_EVENT_TYPE=video.motion
EOF

cd "$PROJECT_DIR/dvr-engine"
npm install --include=dev
npm run build
sudo systemctl restart "$DVR_SERVICE"
sleep 5

echo "---- dvr health ----"
curl -fsS http://127.0.0.1:3010/health || true
echo

echo "---- video-motion / onvif logs ----"
sudo journalctl -u "$DVR_SERVICE" -n 220 --no-pager -l | grep -E 'video-motion|onvif-events|stored event|motion start|motion end|detector started|detector exited|skip' || true

echo "OK: video-motion fallback enabled for ONVIF event timeline"
echo "backup_dir=$BACKUP_DIR"
