#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="${PROJECT_DIR:-/opt/newdomofon-video-node}"
ENV_FILE="${ENV_FILE:-/etc/newdomofon-video/app.env}"
ROLE="${ROLE:-}"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="$PROJECT_DIR/backups/live-first-baseline-$STAMP"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run as root, for example: sudo ROLE=node bash scripts/apply-live-first-baseline.sh" >&2
  exit 1
fi

if [[ "$ROLE" != "master" && "$ROLE" != "node" ]]; then
  echo "ROLE is required: ROLE=master or ROLE=node" >&2
  exit 2
fi

install -d -m 0750 "$BACKUP_DIR" "$(dirname "$ENV_FILE")"
touch "$ENV_FILE"
cp -a "$ENV_FILE" "$BACKUP_DIR/app.env.bak"

upsert_env() {
  local key="$1"
  local value="$2"
  sed -i -E "/^${key}=.*/d" "$ENV_FILE"
  printf '%s=%s\n' "$key" "$value" >> "$ENV_FILE"
}

remove_env_prefixes() {
  local pattern="$1"
  sed -i -E "/^(${pattern})=/d" "$ENV_FILE"
}

stop_disable_service_if_exists() {
  local service="$1"
  if systemctl list-unit-files "$service.service" >/dev/null 2>&1 || systemctl status "$service.service" >/dev/null 2>&1; then
    systemctl disable --now "$service.service" || true
  fi
}

restart_service_if_exists() {
  local service="$1"
  if systemctl list-unit-files "$service.service" >/dev/null 2>&1 || systemctl status "$service.service" >/dev/null 2>&1; then
    systemctl restart "$service.service"
  fi
}

case "$ROLE" in
  master)
    upsert_env DVR_ENGINE_ROLE master
    upsert_env VIDEO_MOTION_ENABLED false
    upsert_env ONVIF_EVENTS_ENABLED false
    upsert_env EVENTS_ENABLED false
    upsert_env DVR_HIKVISION_EVENTS_ENABLED false
    upsert_env DVR_HIKVISION_ARCHIVE_INDEX_ENABLED false
    upsert_env ONVIF_LEGACY_FALLBACK_STREAMS ''

    pkill -TERM -f 'lavfi.scene_score' 2>/dev/null || true
    stop_disable_service_if_exists newdomofon-video-dvr
    restart_service_if_exists newdomofon-video-backend
    systemctl reload nginx 2>/dev/null || true
    ;;

  node)
    upsert_env DVR_ENGINE_ROLE node
    upsert_env VIDEO_MOTION_ENABLED false
    upsert_env VIDEO_MOTION_STREAMS ''
    upsert_env VIDEO_MOTION_SOURCE hls

    # Live-first mode: do not poll ONVIF/Hikvision/device archive until live is stable.
    # Re-enable these one-by-one after recorders run without exits.
    upsert_env EVENTS_ENABLED false
    upsert_env ONVIF_EVENTS_ENABLED false
    upsert_env ONVIF_V2_SKIP_STREAMS ''
    upsert_env ONVIF_EVENTS_V2_SKIP_STREAMS ''
    upsert_env ONVIF_LEGACY_FALLBACK_STREAMS ''
    upsert_env DVR_HIKVISION_EVENTS_ENABLED false
    upsert_env DVR_HIKVISION_ARCHIVE_INDEX_ENABLED false
    upsert_env DVR_DEVICE_ARCHIVE_MAX_SESSIONS_PER_DEVICE 1

    pkill -TERM -f 'lavfi.scene_score' 2>/dev/null || true
    pkill -TERM -f 'ffmpeg.*lavfi\.scene_score' 2>/dev/null || true
    sleep 1
    pkill -KILL -f 'lavfi.scene_score' 2>/dev/null || true
    restart_service_if_exists newdomofon-video-dvr
    ;;
esac

sleep 3

echo "Applied live-first baseline for ROLE=$ROLE"
echo "Backup: $BACKUP_DIR"
echo

echo "Effective env:"
grep -E '^(DVR_ENGINE_ROLE|DVR_MASTER_URL|DVR_NODE_ID|DVR_NODE_PUBLIC_BASE_URL|VIDEO_MOTION_ENABLED|VIDEO_MOTION_SOURCE|EVENTS_ENABLED|ONVIF_EVENTS_ENABLED|ONVIF_V2_SKIP_STREAMS|ONVIF_EVENTS_V2_SKIP_STREAMS|ONVIF_LEGACY_FALLBACK_STREAMS|DVR_HIKVISION_EVENTS_ENABLED|DVR_HIKVISION_ARCHIVE_INDEX_ENABLED|DVR_DEVICE_ARCHIVE_MAX_SESSIONS_PER_DEVICE)=' "$ENV_FILE" || true

echo
for service in newdomofon-video-backend newdomofon-video-dvr nginx; do
  if systemctl list-unit-files "$service.service" >/dev/null 2>&1 || systemctl status "$service.service" >/dev/null 2>&1; then
    echo "--- $service ---"
    systemctl is-enabled "$service.service" 2>/dev/null || true
    systemctl is-active "$service.service" 2>/dev/null || true
  fi
done

echo
if [[ "$ROLE" == "node" ]]; then
  curl -fsS --max-time 5 http://127.0.0.1:3010/health || true
  echo
  curl -fsS --max-time 5 http://127.0.0.1:3010/recorders || true
  echo
fi
