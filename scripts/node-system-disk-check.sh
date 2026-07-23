#!/usr/bin/env bash
set -Eeuo pipefail

ENV_FILE="${NEWDOMOFON_ENV_FILE:-/etc/newdomofon-video/app.env}"
if [[ -r "$ENV_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  . "$ENV_FILE"
  set +a
fi

PROJECT_DIR="${PROJECT_DIR:-/opt/newdomofon-video-node}"
STORAGE_PREPARER="$PROJECT_DIR/scripts/prepare-node-runtime-storage.sh"
if [[ -f "$STORAGE_PREPARER" ]]; then
  NEWDOMOFON_ENV_FILE="$ENV_FILE" PROJECT_DIR="$PROJECT_DIR" \
    bash "$STORAGE_PREPARER"
fi

SERVICE="${DVR_DISK_GUARD_SERVICE:-newdomofon-video-dvr.service}"
STATE_DIR="${DVR_DISK_GUARD_STATE_DIR:-/run/newdomofon-video}"
STATE_FILE="$STATE_DIR/node-disk-state.json"
PAUSE_MARKER="$STATE_DIR/node-disk-paused"
MIN_FREE_BYTES="${DVR_SYSTEM_MIN_FREE_BYTES:-2147483648}"
MIN_FREE_PERCENT="${DVR_SYSTEM_MIN_FREE_PERCENT:-5}"
MIN_FREE_INODES_PERCENT="${DVR_DISK_MIN_FREE_INODES_PERCENT:-5}"
STALE_TMP_MINUTES="${DVR_DISK_STALE_TMP_MINUTES:-60}"

mkdir -p "$STATE_DIR"

read -r total available used_pct < <(df -P -B1 / | awk 'NR==2 {gsub(/%/, "", $5); print $2, $4, $5}')
inode_used_pct="$(df -Pi / | awk 'NR==2 {gsub(/%/, "", $5); print $5}')"
inode_free_pct=$((100 - inode_used_pct))
by_percent=$((total * MIN_FREE_PERCENT / 100))
required="$MIN_FREE_BYTES"
if (( by_percent > required )); then required="$by_percent"; fi

if (( available < required || inode_free_pct < MIN_FREE_INODES_PERCENT )); then
  journalctl --vacuum-size=512M --vacuum-time=7d >/dev/null 2>&1 || true
  find /tmp /var/tmp -xdev -type d \
    \( -name 'newdomofon-export-*' -o -name 'nd-export-*' -o -name 'newdomofon-video-device-archive' \) \
    -mmin "+$STALE_TMP_MINUTES" -print0 2>/dev/null \
    | xargs -0r rm -rf -- 2>/dev/null || true
  read -r total available used_pct < <(df -P -B1 / | awk 'NR==2 {gsub(/%/, "", $5); print $2, $4, $5}')
  inode_used_pct="$(df -Pi / | awk 'NR==2 {gsub(/%/, "", $5); print $5}')"
  inode_free_pct=$((100 - inode_used_pct))
fi

if (( available < required || inode_free_pct < MIN_FREE_INODES_PERCENT )); then
  if systemctl is-active --quiet "$SERVICE"; then systemctl stop "$SERVICE" || true; fi
  printf '%s\n' 'operating_system_filesystem_low_space' >"$PAUSE_MARKER"
  cat >"$STATE_FILE.tmp.$$" <<JSON
{"ok":false,"state":"critical","reason":"operating_system_filesystem_low_space","path":"/","total_bytes":$total,"available_bytes":$available,"used_percent":$used_pct,"inode_free_percent":$inode_free_pct,"required_start_bytes":$required,"service":"$SERVICE","checked_at":"$(date -u +%Y-%m-%dT%H:%M:%SZ)"}
JSON
  mv -f "$STATE_FILE.tmp.$$" "$STATE_FILE"
  logger -t newdomofon-node-disk-guard -p daemon.crit -- "root filesystem critically low; DVR stopped" 2>/dev/null || true
  exit 75
fi

exit 0
