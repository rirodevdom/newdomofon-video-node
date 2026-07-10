#!/usr/bin/env bash
set -Eeuo pipefail

ENV_FILE="${NEWDOMOFON_ENV_FILE:-/etc/newdomofon-video/app.env}"
if [[ -r "$ENV_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  . "$ENV_FILE"
  set +a
fi

SERVICE="${DVR_DISK_GUARD_SERVICE:-newdomofon-video-dvr.service}"
DVR_ROOT="${DVR_ROOT:-/var/lib/newdomofon-video/dvr}"
EVENT_DB="${DVR_EVENT_DB:-/var/lib/newdomofon-video/events/events.sqlite3}"
EVENT_ROOT="$(dirname "$EVENT_DB")"
STATE_DIR="${DVR_DISK_GUARD_STATE_DIR:-/run/newdomofon-video}"
STATE_FILE="$STATE_DIR/node-disk-state.json"
PAUSE_MARKER="$STATE_DIR/node-disk-paused"
LOCK_FILE="${DVR_DISK_GUARD_LOCK_FILE:-/run/lock/newdomofon-video-node-disk-guard.lock}"

MIN_FREE_BYTES="${DVR_DISK_MIN_FREE_BYTES:-10737418240}"
MIN_FREE_PERCENT="${DVR_DISK_MIN_FREE_PERCENT:-10}"
RESUME_FREE_BYTES="${DVR_DISK_RESUME_FREE_BYTES:-16106127360}"
RESUME_FREE_PERCENT="${DVR_DISK_RESUME_FREE_PERCENT:-15}"
MIN_FREE_INODES_PERCENT="${DVR_DISK_MIN_FREE_INODES_PERCENT:-5}"
RESUME_FREE_INODES_PERCENT="${DVR_DISK_RESUME_FREE_INODES_PERCENT:-8}"
MIN_ARCHIVE_AGE_MINUTES="${DVR_DISK_MIN_ARCHIVE_AGE_MINUTES:-60}"
MAX_DELETE_DIRS="${DVR_DISK_MAX_DELETE_DIRS_PER_RUN:-500}"
REQUIRE_MOUNTPOINT="${DVR_DISK_REQUIRE_MOUNTPOINT:-false}"
STALE_TMP_MINUTES="${DVR_DISK_STALE_TMP_MINUTES:-60}"
SYSTEM_MIN_FREE_BYTES="${DVR_SYSTEM_MIN_FREE_BYTES:-2147483648}"
SYSTEM_MIN_FREE_PERCENT="${DVR_SYSTEM_MIN_FREE_PERCENT:-5}"
SYSTEM_RESUME_FREE_BYTES="${DVR_SYSTEM_RESUME_FREE_BYTES:-4294967296}"
SYSTEM_RESUME_FREE_PERCENT="${DVR_SYSTEM_RESUME_FREE_PERCENT:-10}"

mkdir -p "$STATE_DIR" "$(dirname "$LOCK_FILE")"
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  exit 0
fi

log() {
  local level="$1"; shift
  logger -t newdomofon-node-disk-guard -p "daemon.${level}" -- "$*" 2>/dev/null || true
  printf '%s [%s] %s\n' "$(date -Is)" "$level" "$*"
}

is_true() {
  case "${1,,}" in
    1|true|yes|on) return 0 ;;
    *) return 1 ;;
  esac
}

is_uint() {
  [[ "$1" =~ ^[0-9]+$ ]]
}

for value in "$MIN_FREE_BYTES" "$MIN_FREE_PERCENT" "$RESUME_FREE_BYTES" "$RESUME_FREE_PERCENT" \
             "$MIN_FREE_INODES_PERCENT" "$RESUME_FREE_INODES_PERCENT" "$MIN_ARCHIVE_AGE_MINUTES" \
             "$MAX_DELETE_DIRS" "$STALE_TMP_MINUTES" "$SYSTEM_MIN_FREE_BYTES" "$SYSTEM_MIN_FREE_PERCENT" \
             "$SYSTEM_RESUME_FREE_BYTES" "$SYSTEM_RESUME_FREE_PERCENT"; do
  if ! is_uint "$value"; then
    log err "invalid numeric disk guard configuration: $value"
    exit 0
  fi
done

[[ -d "$DVR_ROOT" ]] || mkdir -p "$DVR_ROOT"
[[ -d "$EVENT_ROOT" ]] || mkdir -p "$EVENT_ROOT"

# Prints: total_bytes available_bytes used_percent inode_free_percent
fs_stats() {
  local target="$1"
  local bytes_line inode_line total available used_pct inode_used_pct inode_free_pct
  bytes_line="$(df -P -B1 "$target" 2>/dev/null | awk 'NR==2 {print $2, $4, $5}')" || return 1
  inode_line="$(df -Pi "$target" 2>/dev/null | awk 'NR==2 {gsub(/%/, "", $5); print $5}')" || return 1
  read -r total available used_pct <<<"$bytes_line"
  used_pct="${used_pct%%%}"
  inode_used_pct="$inode_line"
  if ! [[ "$inode_used_pct" =~ ^[0-9]+$ ]]; then inode_used_pct=0; fi
  inode_free_pct=$((100 - inode_used_pct))
  printf '%s %s %s %s\n' "$total" "$available" "$used_pct" "$inode_free_pct"
}

required_bytes() {
  local total="$1" absolute="$2" percent="$3" by_percent
  by_percent=$((total * percent / 100))
  if (( absolute > by_percent )); then
    printf '%s\n' "$absolute"
  else
    printf '%s\n' "$by_percent"
  fi
}

write_state() {
  local state="$1" reason="$2" total="$3" available="$4" used_pct="$5" inode_free_pct="$6" \
        required_start="$7" required_resume="$8" deleted_dirs="$9"
  local tmp="$STATE_FILE.tmp.$$"
  cat >"$tmp" <<JSON
{"ok":$([[ "$state" == "ok" ]] && echo true || echo false),"state":"$state","reason":"$reason","path":"$DVR_ROOT","total_bytes":$total,"available_bytes":$available,"used_percent":$used_pct,"inode_free_percent":$inode_free_pct,"required_start_bytes":$required_start,"required_resume_bytes":$required_resume,"deleted_archive_directories":$deleted_dirs,"service":"$SERVICE","checked_at":"$(date -u +%Y-%m-%dT%H:%M:%SZ)"}
JSON
  mv -f "$tmp" "$STATE_FILE"
}

stop_dvr() {
  local reason="$1"
  if systemctl is-active --quiet "$SERVICE"; then
    log crit "stopping $SERVICE: $reason"
    systemctl stop "$SERVICE" || true
  fi
  printf '%s\n' "$reason" >"$PAUSE_MARKER"
}

resume_dvr() {
  if [[ -e "$PAUSE_MARKER" ]]; then
    rm -f "$PAUSE_MARKER"
    log notice "disk recovered; starting $SERVICE"
    systemctl start "$SERVICE" || log err "failed to start $SERVICE after disk recovery"
  fi
}

cleanup_stale_tmp() {
  local root candidate archive_root
  for root in /tmp /var/tmp; do
    [[ -d "$root" ]] || continue
    while IFS= read -r -d '' candidate; do
      rm -rf -- "$candidate" 2>/dev/null || true
      log info "removed stale temporary directory $candidate"
    done < <(
      find "$root" -xdev -type d \
        \( -name 'newdomofon-export-*' -o -name 'nd-export-*' \) \
        -mmin "+$STALE_TMP_MINUTES" -print0 2>/dev/null
    )

    while IFS= read -r -d '' archive_root; do
      while IFS= read -r -d '' candidate; do
        rm -rf -- "$candidate" 2>/dev/null || true
        log info "removed stale device-archive session $candidate"
      done < <(
        find "$archive_root" -mindepth 1 -maxdepth 1 -type d \
          -mmin "+$STALE_TMP_MINUTES" -print0 2>/dev/null
      )
    done < <(find "$root" -xdev -type d -name 'newdomofon-video-device-archive' -print0 2>/dev/null)
  done
}

prune_old_archive_hours() {
  local required_resume="$1" candidate_file current_suffix line dir total available used_pct inode_free_pct
  local deleted=0
  candidate_file="$(mktemp "$STATE_DIR/archive-candidates.XXXXXX")"
  current_suffix="/$(date -u +%Y-%m-%d)/$(date -u +%H)"

  find "$DVR_ROOT" -mindepth 3 -maxdepth 3 -type d -mmin "+$MIN_ARCHIVE_AGE_MINUTES" \
    -printf '%T@ %p\n' 2>/dev/null | sort -n >"$candidate_file"

  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    dir="${line#* }"
    [[ "$dir" =~ /[A-Za-z0-9_-]+/[0-9]{4}-[0-9]{2}-[0-9]{2}/[0-9]{2}$ ]] || continue
    [[ "$dir" == *"$current_suffix" ]] && continue
    [[ -d "$dir" ]] || continue

    rm -rf -- "$dir" || continue
    deleted=$((deleted + 1))
    rmdir --ignore-fail-on-non-empty "$(dirname "$dir")" 2>/dev/null || true
    log warning "emergency archive cleanup removed $dir"

    read -r total available used_pct inode_free_pct < <(fs_stats "$DVR_ROOT") || break
    if (( available >= required_resume && inode_free_pct >= RESUME_FREE_INODES_PERCENT )); then break; fi
    if (( deleted >= MAX_DELETE_DIRS )); then break; fi
  done <"$candidate_file"

  rm -f "$candidate_file"
  printf '%s\n' "$deleted"
}

cleanup_stale_tmp

if is_true "$REQUIRE_MOUNTPOINT" && ! mountpoint -q "$DVR_ROOT"; then
  stop_dvr "required DVR mount is missing: $DVR_ROOT"
  write_state "critical" "mount_missing" 0 0 100 0 0 0 0
  exit 0
fi

read -r total available used_pct inode_free_pct < <(fs_stats "$DVR_ROOT") || {
  stop_dvr "cannot read filesystem statistics for $DVR_ROOT"
  write_state "critical" "statfs_failed" 0 0 100 0 0 0 0
  exit 0
}

required_start="$(required_bytes "$total" "$MIN_FREE_BYTES" "$MIN_FREE_PERCENT")"
required_resume="$(required_bytes "$total" "$RESUME_FREE_BYTES" "$RESUME_FREE_PERCENT")"
deleted_dirs=0

if (( available < required_start || inode_free_pct < MIN_FREE_INODES_PERCENT )); then
  log warning "disk pressure detected path=$DVR_ROOT available=$available required=$required_start inode_free=${inode_free_pct}%"
  deleted_dirs="$(prune_old_archive_hours "$required_resume")"
  read -r total available used_pct inode_free_pct < <(fs_stats "$DVR_ROOT") || true
fi

# Protect the filesystem containing SQLite/events and the operating system too.
read -r event_total event_available event_used_pct event_inode_free_pct < <(fs_stats "$EVENT_ROOT") || {
  event_total=0; event_available=0; event_used_pct=100; event_inode_free_pct=0;
}
event_required_start="$(required_bytes "$event_total" "$SYSTEM_MIN_FREE_BYTES" "$SYSTEM_MIN_FREE_PERCENT")"
event_required_resume="$(required_bytes "$event_total" "$SYSTEM_RESUME_FREE_BYTES" "$SYSTEM_RESUME_FREE_PERCENT")"
event_critical=0
if (( event_available < event_required_start || event_inode_free_pct < MIN_FREE_INODES_PERCENT )); then
  event_critical=1
fi

if (( available < required_start || inode_free_pct < MIN_FREE_INODES_PERCENT || event_critical == 1 )); then
  reason="low_space_after_cleanup"
  if (( event_critical == 1 )); then reason="event_or_root_filesystem_low_space"; fi
  stop_dvr "$reason"
  write_state "critical" "$reason" "$total" "$available" "$used_pct" "$inode_free_pct" "$required_start" "$required_resume" "$deleted_dirs"
  exit 0
fi

if (( available >= required_resume && inode_free_pct >= RESUME_FREE_INODES_PERCENT && event_available >= event_required_resume && event_inode_free_pct >= RESUME_FREE_INODES_PERCENT )); then
  resume_dvr
fi

state="ok"
reason="healthy"
if (( available < required_resume || inode_free_pct < RESUME_FREE_INODES_PERCENT )); then
  state="warning"
  reason="below_resume_watermark"
fi
write_state "$state" "$reason" "$total" "$available" "$used_pct" "$inode_free_pct" "$required_start" "$required_resume" "$deleted_dirs"
exit 0
