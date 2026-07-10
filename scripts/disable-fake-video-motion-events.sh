#!/usr/bin/env bash
set -Eeuo pipefail

ENV_FILE="${ENV_FILE:-/etc/newdomofon-video/app.env}"
SERVICE="${SERVICE:-newdomofon-video-motion-events.service}"
BACKUP_DIR="/opt/newdomofon-video-node/backups/disable-fake-video-motion-events-$(date +%Y%m%d-%H%M%S)"

mkdir -p "$BACKUP_DIR"
[ -f "$ENV_FILE" ] && cp -a "$ENV_FILE" "$BACKUP_DIR/app.env.bak" || true

sudo systemctl disable --now "$SERVICE" 2>/dev/null || true
sudo systemctl reset-failed "$SERVICE" 2>/dev/null || true

sudo sed -i -E '/^(VIDEO_MOTION_ENABLED|VIDEO_MOTION_STREAMS|DVR_VIDEO_MOTION_STREAMS|VIDEO_MOTION_SOURCE|DVR_VIDEO_MOTION_SOURCE|VIDEO_MOTION_FPS|VIDEO_MOTION_SCALE_WIDTH|VIDEO_MOTION_SCENE_THRESHOLD|VIDEO_MOTION_END_IDLE_MS|VIDEO_MOTION_COOLDOWN_MS|VIDEO_MOTION_RELOAD_MS|VIDEO_MOTION_MAX_DETECTORS|VIDEO_MOTION_EVENT_TYPE|VIDEO_MOTION_LOG_SCORES|VIDEO_MOTION_SCORE_LOG_MS)=/d' "$ENV_FILE" 2>/dev/null || true
cat <<'EOF' | sudo tee -a "$ENV_FILE" >/dev/null
VIDEO_MOTION_ENABLED=false
EOF

echo "---- service ----"
systemctl --no-pager --full status "$SERVICE" 2>/dev/null | sed -n '1,14p' || true

echo "OK: fake video-motion events service disabled"
echo "backup_dir=$BACKUP_DIR"
