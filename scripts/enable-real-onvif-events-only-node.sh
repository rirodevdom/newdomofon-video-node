#!/usr/bin/env bash
set -Eeuo pipefail

ENV_FILE="${ENV_FILE:-/etc/newdomofon-video/app.env}"
DVR_SERVICE="${DVR_SERVICE:-newdomofon-video-dvr.service}"
STREAMS="${EVENT_STREAMS:-onvif2,onf}"
BACKUP_DIR="/opt/newdomofon-video/backups/enable-real-onvif-events-only-$(date +%Y%m%d-%H%M%S)"

mkdir -p "$BACKUP_DIR"
[ -f "$ENV_FILE" ] && cp -a "$ENV_FILE" "$BACKUP_DIR/app.env.bak" || true

# Stop and disable the temporary fake video-analysis event source.
sudo systemctl disable --now newdomofon-video-motion-events.service 2>/dev/null || true
sudo systemctl reset-failed newdomofon-video-motion-events.service 2>/dev/null || true

# Keep only camera-originated ONVIF events for these streams.
sudo sed -i -E '/^(VIDEO_MOTION_ENABLED|VIDEO_MOTION_STREAMS|DVR_VIDEO_MOTION_STREAMS|VIDEO_MOTION_SOURCE|DVR_VIDEO_MOTION_SOURCE|VIDEO_MOTION_FPS|VIDEO_MOTION_SCALE_WIDTH|VIDEO_MOTION_SCENE_THRESHOLD|VIDEO_MOTION_END_IDLE_MS|VIDEO_MOTION_COOLDOWN_MS|VIDEO_MOTION_RELOAD_MS|VIDEO_MOTION_MAX_DETECTORS|VIDEO_MOTION_EVENT_TYPE|VIDEO_MOTION_LOG_SCORES|VIDEO_MOTION_SCORE_LOG_MS|EVENTS_ENABLED|ONVIF_EVENTS_ENABLED|ONVIF_V2_SKIP_STREAMS|ONVIF_EVENTS_V2_SKIP_STREAMS|ONVIF_LEGACY_FALLBACK_STREAMS|ONVIF_LEGACY_SYNC_MS|ONVIF_LEGACY_IGNORE_INITIALIZED|ONVIF_LEGACY_INITIALIZED_STATE_EVENTS)=/d' "$ENV_FILE" 2>/dev/null || true

cat <<EOF | sudo tee -a "$ENV_FILE" >/dev/null
VIDEO_MOTION_ENABLED=false
EVENTS_ENABLED=true
ONVIF_EVENTS_ENABLED=true
# v2 is skipped for these cameras because the camera does not support the hardcoded MotionAlarm topic filter.
ONVIF_V2_SKIP_STREAMS=${STREAMS}
ONVIF_EVENTS_V2_SKIP_STREAMS=${STREAMS}
# legacy fallback uses the camera-originated event stream and stores only real ONVIF notifications.
ONVIF_LEGACY_FALLBACK_STREAMS=${STREAMS}
ONVIF_LEGACY_SYNC_MS=10000
ONVIF_LEGACY_IGNORE_INITIALIZED=true
ONVIF_LEGACY_INITIALIZED_STATE_EVENTS=false
EOF

sudo systemctl restart "$DVR_SERVICE"
sleep 5

echo "---- dvr status ----"
systemctl --no-pager --full status "$DVR_SERVICE" | sed -n '1,18p'

echo "---- recent real onvif logs ----"
sudo journalctl -u "$DVR_SERVICE" --since "2 minutes ago" --no-pager -l | grep -E 'onvif-events:legacy-fallback|stored event|ready|duplicate event|ignored initialized|skip|video-motion' || true

echo "OK: fake video events disabled; real ONVIF legacy fallback enabled for ${STREAMS}"
echo "backup_dir=$BACKUP_DIR"
