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
DVR_STORAGE_ROOTS="${DVR_STORAGE_ROOTS:-$DVR_ROOT}"
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
flock -n 9 || exit 0

log() {
  local level="$1"; shift
  logger -t newdomofon-node-disk-guard -p "daemon.${level}" -- "$*" 2>/dev/null || true
  printf '%s [%s] %s\n' "$(date -Is)" "$level" "$*" >&2
}

is_true() {
  case "${1,,}" in
    1|true|yes|on) return 0 ;;
    *) return 1 ;;
  esac
}

is_uint() { [[ "$1" =~ ^[0-9]+$ ]]; }

for value in "$MIN_FREE_BYTES" "$MIN_FREE_PERCENT" "$RESUME_FREE_BYTES" "$RESUME_FREE_PERCENT" \
             "$MIN_FREE_INODES_PERCENT" "$RESUME_FREE_INODES_PERCENT" "$MIN_ARCHIVE_AGE_MINUTES" \
             "$MAX_DELETE_DIRS" "$STALE_TMP_MINUTES" "$SYSTEM_MIN_FREE_BYTES" "$SYSTEM_MIN_FREE_PERCENT" \
             "$SYSTEM_RESUME_FREE_BYTES" "$SYSTEM_RESUME_FREE_PERCENT"; do
  if ! is_uint "$value"; then
    log err "invalid numeric disk guard configuration: $value"
    exit 0
  fi
done

mapfile -t STORAGE_ROOTS < <(
  python3 - "$DVR_STORAGE_ROOTS" "$DVR_ROOT" <<'PY'
import os
import sys
raw = sys.argv[1].strip() or sys.argv[2]
seen = set()
for item in raw.split(','):
    item = item.strip()
    if not item:
        continue
    value = os.path.abspath(item)
    if value not in seen:
        seen.add(value)
        print(value)
PY
)

if ((${#STORAGE_ROOTS[@]} == 0)); then
  log err "no archive storage roots configured"
  exit 0
fi

mkdir -p "$EVENT_ROOT"
if ! is_true "$REQUIRE_MOUNTPOINT"; then
  for root in "${STORAGE_ROOTS[@]}"; do mkdir -p "$root"; done
fi

# Prints: total available used_percent inode_free_percent
fs_stats() {
  local target="$1"
  local bytes_line inode_line total available used_pct inode_used_pct inode_free_pct
  bytes_line="$(df -P -B1 "$target" 2>/dev/null | awk 'NR==2 {print $2, $4, $5}')" || return 1
  inode_line="$(df -Pi "$target" 2>/dev/null | awk 'NR==2 {gsub(/%/, "", $5); print $5}')" || return 1
  read -r total available used_pct <<<"$bytes_line"
  used_pct="${used_pct%%%}"
  inode_used_pct="$inode_line"
  [[ "$inode_used_pct" =~ ^[0-9]+$ ]] || inode_used_pct=0
  inode_free_pct=$((100 - inode_used_pct))
  printf '%s %s %s %s\n' "$total" "$available" "$used_pct" "$inode_free_pct"
}

required_bytes() {
  local total="$1" absolute="$2" percent="$3" by_percent
  by_percent=$((total * percent / 100))
  (( absolute > by_percent )) && printf '%s\n' "$absolute" || printf '%s\n' "$by_percent"
}

cleanup_stale_tmp() {
  local root candidate archive_root
  for root in /tmp /var/tmp; do
    [[ -d "$root" ]] || continue
    while IFS= read -r -d '' candidate; do
      rm -rf -- "$candidate" 2>/dev/null || true
      log info "removed stale temporary directory $candidate"
    done < <(
      find "$root" -xdev -type d \( -name 'newdomofon-export-*' -o -name 'nd-export-*' \) \
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
  local root="$1" required_resume="$2"
  local candidate_file current_suffix line dir total available used_pct inode_free_pct
  local deleted=0
  candidate_file="$(mktemp "$STATE_DIR/archive-candidates.XXXXXX")"
  current_suffix="/$(date +%Y-%m-%d)/$(date +%H)"

  find "$root" -mindepth 3 -maxdepth 3 -type d -mmin "+$MIN_ARCHIVE_AGE_MINUTES" \
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

    read -r total available used_pct inode_free_pct < <(fs_stats "$root") || break
    if (( available >= required_resume && inode_free_pct >= RESUME_FREE_INODES_PERCENT )); then break; fi
    if (( deleted >= MAX_DELETE_DIRS )); then break; fi
  done <"$candidate_file"

  rm -f "$candidate_file"
  printf '%s\n' "$deleted"
}

previous_signature="$(python3 - "$STATE_FILE" <<'PY'
import json, sys
try:
    print(json.load(open(sys.argv[1], encoding='utf-8')).get('degraded_signature', ''))
except Exception:
    print('')
PY
)"

cleanup_stale_tmp
STATUS_TSV="$(mktemp "$STATE_DIR/storage-status.XXXXXX")"
trap 'rm -f "$STATUS_TSV"' EXIT
healthy_roots=0
warning_roots=0
critical_roots=0
critical_names=()

for root in "${STORAGE_ROOTS[@]}"; do
  mounted=false
  mountpoint -q "$root" 2>/dev/null && mounted=true

  if is_true "$REQUIRE_MOUNTPOINT" && [[ "$mounted" != true ]]; then
    printf '%s\tcritical\tmount_missing\t0\t0\t100\t0\t0\t0\t0\t%s\n' "$root" "$mounted" >>"$STATUS_TSV"
    critical_roots=$((critical_roots + 1))
    critical_names+=("$root:mount_missing")
    continue
  fi

  if [[ ! -d "$root" ]]; then
    printf '%s\tcritical\tpath_missing\t0\t0\t100\t0\t0\t0\t0\t%s\n' "$root" "$mounted" >>"$STATUS_TSV"
    critical_roots=$((critical_roots + 1))
    critical_names+=("$root:path_missing")
    continue
  fi

  if ! read -r total available used_pct inode_free_pct < <(fs_stats "$root"); then
    printf '%s\tcritical\tstatfs_failed\t0\t0\t100\t0\t0\t0\t0\t%s\n' "$root" "$mounted" >>"$STATUS_TSV"
    critical_roots=$((critical_roots + 1))
    critical_names+=("$root:statfs_failed")
    continue
  fi

  required_start="$(required_bytes "$total" "$MIN_FREE_BYTES" "$MIN_FREE_PERCENT")"
  required_resume="$(required_bytes "$total" "$RESUME_FREE_BYTES" "$RESUME_FREE_PERCENT")"
  deleted_dirs=0

  if (( available < required_start || inode_free_pct < MIN_FREE_INODES_PERCENT )); then
    log warning "disk pressure path=$root available=$available required=$required_start inode_free=${inode_free_pct}%"
    deleted_dirs="$(prune_old_archive_hours "$root" "$required_resume")"
    read -r total available used_pct inode_free_pct < <(fs_stats "$root") || true
  fi

  state=healthy
  reason=healthy
  if (( available < required_start || inode_free_pct < MIN_FREE_INODES_PERCENT )); then
    state=critical
    reason=low_space_after_cleanup
    critical_roots=$((critical_roots + 1))
    critical_names+=("$root:$reason")
  elif (( available < required_resume || inode_free_pct < RESUME_FREE_INODES_PERCENT )); then
    state=warning
    reason=below_resume_watermark
    warning_roots=$((warning_roots + 1))
    healthy_roots=$((healthy_roots + 1))
  else
    healthy_roots=$((healthy_roots + 1))
  fi

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$root" "$state" "$reason" "$total" "$available" "$used_pct" "$inode_free_pct" \
    "$required_start" "$required_resume" "$deleted_dirs" "$mounted" >>"$STATUS_TSV"
done

read -r event_total event_available event_used_pct event_inode_free_pct < <(fs_stats "$EVENT_ROOT") || {
  event_total=0; event_available=0; event_used_pct=100; event_inode_free_pct=0;
}
event_required_start="$(required_bytes "$event_total" "$SYSTEM_MIN_FREE_BYTES" "$SYSTEM_MIN_FREE_PERCENT")"
event_required_resume="$(required_bytes "$event_total" "$SYSTEM_RESUME_FREE_BYTES" "$SYSTEM_RESUME_FREE_PERCENT")"
system_critical=false
if (( event_available < event_required_start || event_inode_free_pct < MIN_FREE_INODES_PERCENT )); then
  system_critical=true
  critical_names+=("system:event_or_root_filesystem_low_space")
fi

signature="$(printf '%s\n' "${critical_names[@]:-}" | sed '/^$/d' | sort | paste -sd, -)"
overall_state=ok
reason=healthy
if [[ "$system_critical" == true || "$healthy_roots" -eq 0 ]]; then
  overall_state=critical
  reason=$([[ "$system_critical" == true ]] && echo event_or_root_filesystem_low_space || echo no_healthy_archive_storage)
elif (( critical_roots > 0 )); then
  overall_state=degraded
  reason=some_storage_roots_unavailable
elif (( warning_roots > 0 )); then
  overall_state=warning
  reason=below_resume_watermark
fi

if [[ "$overall_state" == critical ]]; then
  if systemctl is-active --quiet "$SERVICE"; then
    log crit "stopping $SERVICE: $reason"
    systemctl stop "$SERVICE" || true
  fi
  printf '%s\n' "$reason" >"$PAUSE_MARKER"
else
  if [[ -e "$PAUSE_MARKER" ]]; then
    rm -f "$PAUSE_MARKER"
    log notice "storage pool recovered; starting $SERVICE"
    systemctl start "$SERVICE" || log err "failed to start $SERVICE after recovery"
  elif ! systemctl is-active --quiet "$SERVICE"; then
    systemctl start "$SERVICE" || log err "failed to start $SERVICE"
  elif [[ "$signature" != "$previous_signature" ]]; then
    log notice "storage pool membership changed; restarting DVR to reassign cameras"
    systemctl restart "$SERVICE" || log err "failed to restart $SERVICE after storage change"
  fi
fi

python3 - "$STATUS_TSV" "$STATE_FILE" "$overall_state" "$reason" "$SERVICE" "$signature" \
  "$event_total" "$event_available" "$event_used_pct" "$event_inode_free_pct" \
  "$event_required_start" "$event_required_resume" <<'PY'
import json
import os
import sys
from datetime import datetime, timezone

(tsv, state_file, state, reason, service, signature,
 event_total, event_available, event_used, event_inodes,
 event_required_start, event_required_resume) = sys.argv[1:]

roots = []
with open(tsv, encoding='utf-8') as handle:
    for raw in handle:
        fields = raw.rstrip('\n').split('\t')
        if len(fields) != 11:
            continue
        root, root_state, root_reason, total, available, used, inodes, required_start, required_resume, deleted, mounted = fields
        roots.append({
            'root': root,
            'state': root_state,
            'reason': root_reason,
            'mounted': mounted == 'true',
            'total_bytes': int(total),
            'available_bytes': int(available),
            'free_bytes': int(available),
            'used_bytes': max(0, int(total) - int(available)),
            'used_percent': int(used),
            'inode_free_percent': int(inodes),
            'required_start_bytes': int(required_start),
            'required_resume_bytes': int(required_resume),
            'deleted_archive_directories': int(deleted),
        })

payload = {
    'ok': state != 'critical',
    'state': state,
    'reason': reason,
    'root': roots[0]['root'] if roots else None,
    'pool_size': len(roots),
    'healthy_roots': sum(1 for item in roots if item['state'] == 'healthy'),
    'available_roots': sum(1 for item in roots if item['state'] != 'critical'),
    'total_bytes': sum(item['total_bytes'] for item in roots),
    'available_bytes': sum(item['available_bytes'] for item in roots),
    'free_bytes': sum(item['free_bytes'] for item in roots),
    'used_bytes': sum(item['used_bytes'] for item in roots),
    'roots': roots,
    'system_filesystem': {
        'total_bytes': int(event_total),
        'available_bytes': int(event_available),
        'used_percent': int(event_used),
        'inode_free_percent': int(event_inodes),
        'required_start_bytes': int(event_required_start),
        'required_resume_bytes': int(event_required_resume),
    },
    'service': service,
    'degraded_signature': signature,
    'checked_at': datetime.now(timezone.utc).isoformat().replace('+00:00', 'Z'),
}

tmp = f'{state_file}.tmp.{os.getpid()}'
with open(tmp, 'w', encoding='utf-8') as handle:
    json.dump(payload, handle, separators=(',', ':'))
    handle.write('\n')
os.replace(tmp, state_file)
PY

exit 0
