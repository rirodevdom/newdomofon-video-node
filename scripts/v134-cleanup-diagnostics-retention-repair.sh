#!/usr/bin/env bash
# v134 NewDomofon cleanup + diagnostics + retention repair
#
# Safe by default:
#   - without APPLY=1 it only collects diagnostics and writes cleanup manifests.
#   - destructive cleanup additionally requires CONFIRM_CLEAN=YES.
#
# Main fixes over v133:
#   - does not stop diagnostics if one command fails;
#   - redacts RTSP passwords/tokens more aggressively;
#   - creates cleanup manifests even when DB diagnostics fail;
#   - optionally repairs broken events retention timers/services.

set -uo pipefail

PROJECT_DIR="${PROJECT_DIR:-/opt/newdomofon-video}"
SITE_URL="${SITE_URL:-https://new-video.domofon-37.ru}"
STREAM_NAME="${STREAM_NAME:-}"
TOKEN="${TOKEN:-}"

APPLY="${APPLY:-0}"
CONFIRM_CLEAN="${CONFIRM_CLEAN:-NO}"

ARCHIVE_KEEP_DAYS="${ARCHIVE_KEEP_DAYS:-7}"
EVENTS_KEEP_DAYS="${EVENTS_KEEP_DAYS:-7}"
PROJECT_BACKUPS_KEEP_DAYS="${PROJECT_BACKUPS_KEEP_DAYS:-14}"
PROJECT_DIAGNOSTICS_KEEP_DAYS="${PROJECT_DIAGNOSTICS_KEEP_DAYS:-14}"
PROJECT_QUARANTINE_KEEP_DAYS="${PROJECT_QUARANTINE_KEEP_DAYS:-3}"
JOURNAL_KEEP_DAYS="${JOURNAL_KEEP_DAYS:-14}"
LOG_SINCE="${LOG_SINCE:-24 hours ago}"

CLEAN_PROJECT_JUNK="${CLEAN_PROJECT_JUNK:-1}"
CLEAN_CAMERA_ARCHIVE="${CLEAN_CAMERA_ARCHIVE:-1}"
CLEAN_OLD_EVENTS="${CLEAN_OLD_EVENTS:-1}"
CLEAN_JOURNAL="${CLEAN_JOURNAL:-0}"
CLEAN_NODE_MODULES="${CLEAN_NODE_MODULES:-0}"
REPAIR_EVENTS_RETENTION="${REPAIR_EVENTS_RETENTION:-1}"

DIAG_BASE="${DIAG_BASE:-$PROJECT_DIR/diagnostics}"
RUN_ID="v134-cleanup-diagnostics-retention-repair-$(date +%Y%m%d-%H%M%S)"
DIAG_DIR="$DIAG_BASE/$RUN_ID"
BACKUP_DIR="$PROJECT_DIR/backups/$RUN_ID-safety"

mkdir -p "$DIAG_DIR" "$BACKUP_DIR"
exec > >(tee "$DIAG_DIR/run.log") 2>&1

echo "===== v134 cleanup diagnostics retention repair ====="
echo "project:                   $PROJECT_DIR"
echo "site:                      $SITE_URL"
echo "stream:                    ${STREAM_NAME:-<all>}"
echo "apply:                     $APPLY"
echo "confirm_clean:             $CONFIRM_CLEAN"
echo "archive_keep_days:         $ARCHIVE_KEEP_DAYS"
echo "events_keep_days:          $EVENTS_KEEP_DAYS"
echo "repair_events_retention:   $REPAIR_EVENTS_RETENTION"
echo "diagnostics:               $DIAG_DIR"
echo "safety_backup:             $BACKUP_DIR"
echo

if [ ! -d "$PROJECT_DIR" ]; then
  echo "ERROR: PROJECT_DIR not found: $PROJECT_DIR" >&2
  exit 1
fi

if [ "$APPLY" = "1" ] && [ "$CONFIRM_CLEAN" != "YES" ]; then
  echo "ERROR: destructive mode requires CONFIRM_CLEAN=YES"
  exit 2
fi

have() { command -v "$1" >/dev/null 2>&1; }

safe_copy() {
  local src="$1"
  local dst_root="$2"
  [ -e "$src" ] || [ -L "$src" ] || return 0
  mkdir -p "$dst_root$(dirname "$src")"
  cp -a "$src" "$dst_root$src" 2>/dev/null || true
}

redact_file() {
  local file="$1"
  [ -f "$file" ] || return 0
  perl -0777 -pi -e '
    s#(rtsp://)([^:@/\s]+):([^@/\s]+)@#${1}${2}:<REDACTED>@#gi;
    s#(rtsp://)([^@/\s]+)@#${1}<REDACTED>@#gi;
    s/([?&]token=)[^&\s"<>]+/${1}<REDACTED>/gi;
    s/(TOKEN=).*/${1}<REDACTED>/gi;
    s/(RESTREAM_PUBLIC_TOKEN=).*/${1}<REDACTED>/gi;
    s/(VITE_RESTREAM_PUBLIC_TOKEN=).*/${1}<REDACTED>/gi;
    s/(Bearer\s+)[A-Za-z0-9._~+\/=-]+/${1}<REDACTED>/gi;
    s/(Authorization:\s*Basic\s+)[A-Za-z0-9._~+\/=-]+/${1}<REDACTED>/gi;
    s/(password["'\''\s:=]+)([^,"'\''\s}]+)/${1}<REDACTED>/gi;
    s/(PASSWORD=).*/${1}<REDACTED>/gi;
    s/(ADMIN_PASSWORD=).*/${1}<REDACTED>/gi;
    s/(JWT_SECRET=).*/${1}<REDACTED>/gi;
    s/(DATABASE_URL=postgres(?:ql)?:\/\/)([^@\s]+)@/${1}<REDACTED>@/gi;
  ' "$file" 2>/dev/null || true
}

cmd_to_file() {
  local out="$1"; shift
  echo "+ $*" > "$out"
  "$@" >> "$out" 2>&1 || true
  redact_file "$out"
}

load_envs() {
  echo "===== Load env ====="
  set +u
  for envf in /etc/newdomofon-video/app.env "$PROJECT_DIR/backend/.env" "$PROJECT_DIR/.env"; do
    if [ -f "$envf" ]; then
      echo "load: $envf"
      set -a
      # shellcheck disable=SC1090
      . "$envf"
      set +a
      safe_copy "$envf" "$DIAG_DIR"
      redact_file "$DIAG_DIR$envf"
    fi
  done
  set -u
}

detect_database_url() {
  if [ -n "${DATABASE_URL:-}" ]; then echo "$DATABASE_URL"; return 0; fi
  for envf in /etc/newdomofon-video/app.env "$PROJECT_DIR/backend/.env" "$PROJECT_DIR/.env"; do
    [ -f "$envf" ] || continue
    grep -E '^DATABASE_URL=' "$envf" 2>/dev/null | tail -1 | cut -d= -f2- && return 0
  done
  echo ""
}

detect_dvr_roots() {
  local raw="${DVR_ROOTS:-/var/lib/newdomofon-video/dvr,/var/dvr}"
  echo "$raw" | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | awk 'NF'
}

backup_current_files() {
  echo
  echo "===== Safety backup current important files ====="
  local files=(
    /etc/newdomofon-video/app.env
    /etc/systemd/system/newdomofon-events-retention.service
    /etc/systemd/system/newdomofon-events-retention.timer
    /etc/systemd/system/newdomofon-events-archive-retention.service
    /etc/systemd/system/newdomofon-events-archive-retention.timer
    /etc/systemd/system/newdomofon-events-archive-retention-v1153.service
    /etc/systemd/system/newdomofon-events-archive-retention-v1153.timer
    "$PROJECT_DIR/scripts/events-retention-cleanup.sh"
    "$PROJECT_DIR/scripts/events-align-to-archive-cleanup.sh"
    "$PROJECT_DIR/scripts/events-retention-cleanup.js"
    "$PROJECT_DIR/scripts/events-align-to-archive-cleanup.js"
  )
  for f in "${files[@]}"; do
    if [ -e "$f" ] || [ -L "$f" ]; then
      safe_copy "$f" "$BACKUP_DIR"
      echo "backup: $f"
    fi
  done
}

collect_system_diagnostics() {
  echo
  echo "===== Collect diagnostics ====="
  mkdir -p "$DIAG_DIR/system" "$DIAG_DIR/config/systemd" "$DIAG_DIR/config/nginx" "$DIAG_DIR/project" "$DIAG_DIR/logs/journal" "$DIAG_DIR/logs/files" "$DIAG_DIR/archive" "$DIAG_DIR/db" "$DIAG_DIR/cleanup"

  {
    echo "date_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "date_local=$(date)"
    echo "hostname=$(hostname -f 2>/dev/null || hostname)"
    echo "project=$PROJECT_DIR"
    echo "site=$SITE_URL"
    echo "stream=${STREAM_NAME:-}"
    echo "apply=$APPLY"
  } > "$DIAG_DIR/summary.env"

  cmd_to_file "$DIAG_DIR/system/df-hT.txt" df -hT
  cmd_to_file "$DIAG_DIR/system/df-ih.txt" df -ih
  cmd_to_file "$DIAG_DIR/system/free-h.txt" free -h
  cmd_to_file "$DIAG_DIR/system/uptime.txt" uptime
  cmd_to_file "$DIAG_DIR/system/lsblk.txt" lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT,UUID
  cmd_to_file "$DIAG_DIR/system/ps-aux-sort-mem.txt" ps aux --sort=-%mem
  cmd_to_file "$DIAG_DIR/system/ps-aux-sort-cpu.txt" ps aux --sort=-%cpu
  cmd_to_file "$DIAG_DIR/system/ss-lntup.txt" ss -lntup
  cmd_to_file "$DIAG_DIR/project/du-project-depth2.txt" du -h -d 2 "$PROJECT_DIR"
  find "$PROJECT_DIR" -maxdepth 4 -type d \( -name node_modules -o -name .git -o -name dist -o -name backups -o -name diagnostics -o -name quarantine \) -print > "$DIAG_DIR/project/special-dirs.txt" 2>&1 || true
  find "$PROJECT_DIR" -xdev -type f -size +20M -printf '%s %TY-%Tm-%Td %TT %p\n' 2>/dev/null | sort -nr > "$DIAG_DIR/project/large-files-over-20m.txt" || true

  if have nginx; then
    nginx -t > "$DIAG_DIR/config/nginx/nginx-test.txt" 2>&1 || true
    nginx -T > "$DIAG_DIR/config/nginx/nginx-T.txt" 2>&1 || true
    redact_file "$DIAG_DIR/config/nginx/nginx-T.txt"
  fi

  systemctl list-units --all --type=service --type=timer > "$DIAG_DIR/config/systemd/list-units-services-timers.txt" 2>&1 || true

  mapfile -t svcs < <(systemctl list-units --all --type=service --type=timer --no-legend 2>/dev/null | awk '{print $1}' | grep -E 'newdomofon|mediamtx|nginx|postgresql' | sort -u || true)
  for svc in "${svcs[@]}"; do
    systemctl cat "$svc" --no-pager > "$DIAG_DIR/config/systemd/$svc.cat.txt" 2>&1 || true
    systemctl status "$svc" --no-pager -l > "$DIAG_DIR/config/systemd/$svc.status.txt" 2>&1 || true
    redact_file "$DIAG_DIR/config/systemd/$svc.cat.txt"
    redact_file "$DIAG_DIR/config/systemd/$svc.status.txt"
  done

  for svc in "${svcs[@]}"; do
    journalctl -u "$svc" --since "$LOG_SINCE" --no-pager -o short-iso > "$DIAG_DIR/logs/journal/$svc.log" 2>&1 || true
    redact_file "$DIAG_DIR/logs/journal/$svc.log"
  done
  journalctl --since "$LOG_SINCE" --no-pager -p warning -o short-iso > "$DIAG_DIR/logs/journal/system-warnings.log" 2>&1 || true
  redact_file "$DIAG_DIR/logs/journal/system-warnings.log"

  for f in /var/log/nginx/access.log /var/log/nginx/error.log /var/log/postgresql/postgresql-*.log /var/log/newdomofon-video/*.log; do
    for real in $f; do
      [ -f "$real" ] || continue
      out="$DIAG_DIR/logs/files/$(echo "$real" | sed 's#^/##;s#/#_#g').tail.txt"
      tail -n 2000 "$real" > "$out" 2>&1 || true
      redact_file "$out"
    done
  done
}

collect_archive_diagnostics() {
  echo
  echo "===== Collect archive diagnostics ====="
  mapfile -t roots < <(detect_dvr_roots)
  printf '%s\n' "${roots[@]}" > "$DIAG_DIR/archive/dvr-roots.txt"

  for root in "${roots[@]}"; do
    [ -d "$root" ] || continue
    local_safe="$(echo "$root" | sed 's#^/##;s#/#_#g')"
    cmd_to_file "$DIAG_DIR/archive/du-$local_safe.txt" du -h -d 3 "$root"

    {
      echo "root=$root"
      find "$root" -maxdepth 2 -type d -mindepth 1 -exec du -sh {} \; 2>/dev/null | sort -h
      echo
      echo "files_count=$(find "$root" -type f \( -name '*.ts' -o -name '*.m3u8' -o -name '*.mp4' \) 2>/dev/null | wc -l)"
      echo "old_files_count=$(find "$root" -type f \( -name '*.ts' -o -name '*.m3u8' -o -name '*.mp4' \) -mtime +"$ARCHIVE_KEEP_DAYS" 2>/dev/null | wc -l)"
      echo
      echo "newest_files:"
      find "$root" -type f \( -name '*.ts' -o -name '*.m3u8' -o -name '*.mp4' \) -printf '%TY-%Tm-%Td %TT %s %p\n' 2>/dev/null | sort | tail -80
      echo
      echo "oldest_files:"
      find "$root" -type f \( -name '*.ts' -o -name '*.m3u8' -o -name '*.mp4' \) -printf '%TY-%Tm-%Td %TT %s %p\n' 2>/dev/null | sort | head -80
    } > "$DIAG_DIR/archive/summary-$local_safe.txt" 2>&1 || true
  done

  if [ -n "$TOKEN" ] && [ -n "$STREAM_NAME" ]; then
    for ep in \
      "$SITE_URL/$STREAM_NAME/recording_status.json?token=$TOKEN" \
      "$SITE_URL/dvr-archive/$STREAM_NAME/recording_status.json?token=$TOKEN" \
      "$SITE_URL/dvr-archive/$STREAM_NAME/coverage.json?token=$TOKEN" \
      "$SITE_URL/dvr-archive/$STREAM_NAME/ranges.json?token=$TOKEN"
    do
      name="$(echo "$ep" | sed 's#https\?://##;s#[/?&=:.]#_#g' | cut -c1-180)"
      curl -k -sS --max-time 20 -D "$DIAG_DIR/archive/http-$name.headers" -o "$DIAG_DIR/archive/http-$name.body" "$ep" || true
      redact_file "$DIAG_DIR/archive/http-$name.headers"
      redact_file "$DIAG_DIR/archive/http-$name.body"
    done
  fi
}

collect_db_diagnostics() {
  echo
  echo "===== Collect DB diagnostics ====="
  DB_URL="$(detect_database_url)"
  if [ -z "$DB_URL" ]; then echo "DATABASE_URL not found"; return 0; fi
  if ! have psql; then echo "psql not found"; return 0; fi

  cat > "$DIAG_DIR/db/diagnostics.sql" <<SQL
\\pset pager off
SELECT now() AS db_now;
SELECT current_database(), current_user, version();
SELECT schemaname, tablename, n_live_tup, n_dead_tup, last_vacuum, last_autovacuum, last_analyze, last_autoanalyze
FROM pg_stat_user_tables ORDER BY n_live_tup DESC;
SELECT count(*) AS camera_events_count, min(occurred_at) AS oldest, max(occurred_at) AS newest FROM public.camera_events;
SELECT stream_name, count(*) AS events, min(occurred_at) AS oldest, max(occurred_at) AS newest FROM public.camera_events GROUP BY stream_name ORDER BY events DESC LIMIT 50;
SELECT event_type, event_state, count(*) AS events, min(occurred_at) AS oldest, max(occurred_at) AS newest FROM public.camera_events GROUP BY event_type, event_state ORDER BY events DESC LIMIT 100;
SELECT count(*) AS events_older_than_keep FROM public.camera_events WHERE occurred_at < now() - interval '$EVENTS_KEEP_DAYS days';
SQL
  psql "$DB_URL" -v ON_ERROR_STOP=0 -f "$DIAG_DIR/db/diagnostics.sql" > "$DIAG_DIR/db/diagnostics.out.txt" 2>&1 || true
  redact_file "$DIAG_DIR/db/diagnostics.out.txt"

  if have pg_dump; then
    pg_dump "$DB_URL" -Fc -t public.camera_events -f "$DIAG_DIR/db/camera_events-before-clean.dump" > "$DIAG_DIR/db/pg_dump-camera_events.log" 2>&1 || true
    redact_file "$DIAG_DIR/db/pg_dump-camera_events.log"
  fi
}

build_cleanup_manifests() {
  echo
  echo "===== Build cleanup manifests ====="
  : > "$DIAG_DIR/cleanup/project-junk-files.txt"
  : > "$DIAG_DIR/cleanup/project-junk-dirs.txt"
  : > "$DIAG_DIR/cleanup/archive-old-files.txt"
  : > "$DIAG_DIR/cleanup/archive-empty-dirs.txt"

  if [ "$CLEAN_PROJECT_JUNK" = "1" ]; then
    [ -d "$PROJECT_DIR/backups" ] && find "$PROJECT_DIR/backups" -mindepth 1 -maxdepth 1 -type d -mtime +"$PROJECT_BACKUPS_KEEP_DAYS" -printf '%p\n' >> "$DIAG_DIR/cleanup/project-junk-dirs.txt" 2>/dev/null || true
    [ -d "$PROJECT_DIR/diagnostics" ] && find "$PROJECT_DIR/diagnostics" -mindepth 1 -maxdepth 1 \( -type d -o -type f \) -mtime +"$PROJECT_DIAGNOSTICS_KEEP_DAYS" ! -path "$DIAG_DIR" -printf '%p\n' >> "$DIAG_DIR/cleanup/project-junk-dirs.txt" 2>/dev/null || true
    [ -d "$PROJECT_DIR/quarantine" ] && find "$PROJECT_DIR/quarantine" -mindepth 1 \( -type f -o -type d \) -mtime +"$PROJECT_QUARANTINE_KEEP_DAYS" -printf '%p\n' >> "$DIAG_DIR/cleanup/project-junk-dirs.txt" 2>/dev/null || true
    find "$PROJECT_DIR" -maxdepth 2 -type f \( -name '*.tar.gz' -o -name '*.tgz' -o -name '*.zip' -o -name '*.bak' -o -name '*.orig' -o -name '*.tmp' \) -mtime +"$PROJECT_BACKUPS_KEEP_DAYS" -printf '%p\n' >> "$DIAG_DIR/cleanup/project-junk-files.txt" 2>/dev/null || true

    if [ "$CLEAN_NODE_MODULES" = "1" ]; then
      find "$PROJECT_DIR" -maxdepth 3 -type d -name node_modules -printf '%p\n' >> "$DIAG_DIR/cleanup/project-junk-dirs.txt" 2>/dev/null || true
    else
      find "$PROJECT_DIR" -maxdepth 3 -type d -name node_modules -exec du -sh {} \; > "$DIAG_DIR/cleanup/node_modules-report-only.txt" 2>/dev/null || true
    fi
  fi

  if [ "$CLEAN_CAMERA_ARCHIVE" = "1" ]; then
    mapfile -t roots < <(detect_dvr_roots)
    for root in "${roots[@]}"; do
      [ -d "$root" ] || continue
      target="$root"
      [ -n "$STREAM_NAME" ] && [ -d "$root/$STREAM_NAME" ] && target="$root/$STREAM_NAME"
      find "$target" -type f \( -name '*.ts' -o -name '*.m3u8' -o -name '*.mp4' \) -mtime +"$ARCHIVE_KEEP_DAYS" -print >> "$DIAG_DIR/cleanup/archive-old-files.txt" 2>/dev/null || true
      find "$target" -depth -type d -empty -print >> "$DIAG_DIR/cleanup/archive-empty-dirs.txt" 2>/dev/null || true
    done
  fi

  sort -u -o "$DIAG_DIR/cleanup/project-junk-files.txt" "$DIAG_DIR/cleanup/project-junk-files.txt"
  sort -u -o "$DIAG_DIR/cleanup/project-junk-dirs.txt" "$DIAG_DIR/cleanup/project-junk-dirs.txt"
  sort -u -o "$DIAG_DIR/cleanup/archive-old-files.txt" "$DIAG_DIR/cleanup/archive-old-files.txt"
  sort -u -o "$DIAG_DIR/cleanup/archive-empty-dirs.txt" "$DIAG_DIR/cleanup/archive-empty-dirs.txt"

  archive_bytes="$(while IFS= read -r f; do [ -f "$f" ] && stat -c '%s' "$f"; done < "$DIAG_DIR/cleanup/archive-old-files.txt" | awk '{s+=$1} END{print s+0}')"
  {
    echo "project_junk_files=$(wc -l < "$DIAG_DIR/cleanup/project-junk-files.txt")"
    echo "project_junk_dirs=$(wc -l < "$DIAG_DIR/cleanup/project-junk-dirs.txt")"
    echo "archive_old_files=$(wc -l < "$DIAG_DIR/cleanup/archive-old-files.txt")"
    echo "archive_empty_dirs=$(wc -l < "$DIAG_DIR/cleanup/archive-empty-dirs.txt")"
    echo "archive_old_files_size_bytes=$archive_bytes"
  } > "$DIAG_DIR/cleanup/summary.env"
  cat "$DIAG_DIR/cleanup/summary.env"
}

repair_retention_services() {
  [ "$REPAIR_EVENTS_RETENTION" = "1" ] || return 0

  echo
  echo "===== Repair events retention services ====="

  if [ "$APPLY" != "1" ]; then
    cat <<EOF
DRY-RUN: would:
  - create $PROJECT_DIR/scripts/events-retention-cleanup.sh
  - create $PROJECT_DIR/scripts/events-align-to-archive-cleanup.sh
  - patch newdomofon-events-retention.service to use shell cleanup script
  - patch newdomofon-events-archive-retention.service to use shell archive-aligned cleanup script
  - disable broken v1153 timer/service if present and if its ExecStart target is missing
EOF
    return 0
  fi

  mkdir -p "$PROJECT_DIR/scripts"

  cat > "$PROJECT_DIR/scripts/events-retention-cleanup.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
PROJECT_DIR="${PROJECT_DIR:-/opt/newdomofon-video}"
EVENTS_RETENTION_FALLBACK_DAYS="${EVENTS_RETENTION_FALLBACK_DAYS:-7}"
EVENTS_RETENTION_BATCH="${EVENTS_RETENTION_BATCH:-50000}"

set +u
for envf in /etc/newdomofon-video/app.env "$PROJECT_DIR/backend/.env" "$PROJECT_DIR/.env"; do
  [ -f "$envf" ] && set -a && . "$envf" && set +a
done
set -u

if [ -z "${DATABASE_URL:-}" ]; then
  echo "DATABASE_URL is required" >&2
  exit 1
fi

psql "$DATABASE_URL" -v ON_ERROR_STOP=1 <<SQL
WITH doomed AS (
  SELECT id
  FROM public.camera_events
  WHERE occurred_at < now() - interval '${EVENTS_RETENTION_FALLBACK_DAYS} days'
  ORDER BY occurred_at
  LIMIT ${EVENTS_RETENTION_BATCH}
),
deleted AS (
  DELETE FROM public.camera_events e
  USING doomed d
  WHERE e.id = d.id
  RETURNING e.id
)
SELECT count(*) AS deleted FROM deleted;
VACUUM (ANALYZE) public.camera_events;
SQL
SH
  chmod +x "$PROJECT_DIR/scripts/events-retention-cleanup.sh"

  cat > "$PROJECT_DIR/scripts/events-align-to-archive-cleanup.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
PROJECT_DIR="${PROJECT_DIR:-/opt/newdomofon-video}"
DVR_ROOT="${DVR_ROOT:-/var/lib/newdomofon-video/dvr}"
EVENTS_RETENTION_FALLBACK_DAYS="${EVENTS_RETENTION_FALLBACK_DAYS:-7}"
EVENTS_RETENTION_BATCH="${EVENTS_RETENTION_BATCH:-100000}"

set +u
for envf in /etc/newdomofon-video/app.env "$PROJECT_DIR/backend/.env" "$PROJECT_DIR/.env"; do
  [ -f "$envf" ] && set -a && . "$envf" && set +a
done
set -u

if [ -z "${DATABASE_URL:-}" ]; then
  echo "DATABASE_URL is required" >&2
  exit 1
fi

cutoff_iso="$(find "$DVR_ROOT" -type f -name '*.ts' -printf '%T@ %p\n' 2>/dev/null | sort -n | head -1 | awk '{print $1}' | xargs -r -I{} date -u -d @{} +%Y-%m-%dT%H:%M:%SZ || true)"
if [ -z "$cutoff_iso" ]; then
  cutoff_expr="now() - interval '${EVENTS_RETENTION_FALLBACK_DAYS} days'"
else
  cutoff_expr="'$cutoff_iso'::timestamptz"
fi

psql "$DATABASE_URL" -v ON_ERROR_STOP=1 <<SQL
WITH doomed AS (
  SELECT id
  FROM public.camera_events
  WHERE occurred_at < $cutoff_expr
  ORDER BY occurred_at
  LIMIT ${EVENTS_RETENTION_BATCH}
),
deleted AS (
  DELETE FROM public.camera_events e
  USING doomed d
  WHERE e.id = d.id
  RETURNING e.id
)
SELECT '$cutoff_expr' AS effective_cutoff, count(*) AS deleted FROM deleted;
VACUUM (ANALYZE) public.camera_events;
SQL
SH
  chmod +x "$PROJECT_DIR/scripts/events-align-to-archive-cleanup.sh"

  cat > /etc/systemd/system/newdomofon-events-retention.service <<EOF
[Unit]
Description=NewDomofon camera events retention cleanup
After=network-online.target postgresql.service
Wants=network-online.target

[Service]
Type=oneshot
Environment=PROJECT_DIR=$PROJECT_DIR
Environment=EVENTS_RETENTION_FALLBACK_DAYS=$EVENTS_KEEP_DAYS
Environment=EVENTS_RETENTION_BATCH=50000
EnvironmentFile=-/etc/newdomofon-video/app.env
WorkingDirectory=$PROJECT_DIR
ExecStart=/usr/bin/bash $PROJECT_DIR/scripts/events-retention-cleanup.sh
Nice=10
IOSchedulingClass=best-effort
IOSchedulingPriority=7
EOF

  cat > /etc/systemd/system/newdomofon-events-archive-retention.service <<EOF
[Unit]
Description=NewDomofon align camera events with current DVR archive window
After=postgresql.service network.target

[Service]
Type=oneshot
EnvironmentFile=-/etc/newdomofon-video/app.env
Environment=PROJECT_DIR=$PROJECT_DIR
Environment=DVR_ROOT=/var/lib/newdomofon-video/dvr
Environment=EVENTS_RETENTION_FALLBACK_DAYS=$EVENTS_KEEP_DAYS
Environment=EVENTS_RETENTION_BATCH=100000
ExecStart=/usr/bin/bash $PROJECT_DIR/scripts/events-align-to-archive-cleanup.sh
Nice=10
IOSchedulingClass=best-effort
IOSchedulingPriority=7
EOF

  # Disable broken experiment timer if it references a missing runner.
  if systemctl list-unit-files newdomofon-events-archive-retention-v1153.timer >/dev/null 2>&1; then
    if ! systemctl cat newdomofon-events-archive-retention-v1153.service --no-pager 2>/dev/null | grep -q 'ExecStart=.*[[:space:]]/.*'; then
      true
    fi
    if ! [ -f "$PROJECT_DIR/scripts/events-archive-retention-v1153-run.sh" ]; then
      systemctl disable --now newdomofon-events-archive-retention-v1153.timer 2>/dev/null || true
      systemctl reset-failed newdomofon-events-archive-retention-v1153.service 2>/dev/null || true
      echo "disabled broken v1153 retention timer/service"
    fi
  fi

  systemctl daemon-reload
  systemctl reset-failed newdomofon-events-retention.service newdomofon-events-archive-retention.service 2>/dev/null || true
  systemctl start newdomofon-events-retention.service || true
  systemctl start newdomofon-events-archive-retention.service || true
}

apply_cleanup() {
  echo
  echo "===== Apply cleanup ====="

  if [ "$CLEAN_PROJECT_JUNK" = "1" ]; then
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      [ -f "$f" ] || [ -L "$f" ] || continue
      echo "delete file: $f"
      rm -f -- "$f"
    done < "$DIAG_DIR/cleanup/project-junk-files.txt"

    sort -r "$DIAG_DIR/cleanup/project-junk-dirs.txt" | while IFS= read -r d; do
      [ -n "$d" ] || continue
      case "$d" in "$PROJECT_DIR"|"/"|"/var"|"/var/lib"|"/var/lib/newdomofon-video") echo "skip dangerous dir: $d"; continue ;; esac
      [ -d "$d" ] || continue
      echo "delete dir: $d"
      rm -rf -- "$d"
    done
  fi

  if [ "$CLEAN_CAMERA_ARCHIVE" = "1" ]; then
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      [ -f "$f" ] || continue
      echo "delete archive: $f"
      rm -f -- "$f"
    done < "$DIAG_DIR/cleanup/archive-old-files.txt"

    sort -r "$DIAG_DIR/cleanup/archive-empty-dirs.txt" | while IFS= read -r d; do
      [ -n "$d" ] || continue
      case "$d" in "/"|"/var"|"/var/lib"|"/var/lib/newdomofon-video"|"/var/lib/newdomofon-video/dvr"|"/var/dvr") continue ;; esac
      rmdir --ignore-fail-on-non-empty "$d" 2>/dev/null || true
    done
  fi

  if [ "$CLEAN_OLD_EVENTS" = "1" ]; then
    DB_URL="$(detect_database_url)"
    if [ -n "$DB_URL" ] && have psql; then
      if have pg_dump; then
        pg_dump "$DB_URL" -Fc -t public.camera_events -f "$DIAG_DIR/db/camera_events-before-apply-clean.dump" > "$DIAG_DIR/db/pg_dump-before-apply.log" 2>&1 || true
      fi
      psql "$DB_URL" -v ON_ERROR_STOP=1 <<SQL > "$DIAG_DIR/db/delete-old-events-apply.out.txt" 2>&1 || true
WITH doomed AS (
  SELECT id
  FROM public.camera_events
  WHERE occurred_at < now() - interval '$EVENTS_KEEP_DAYS days'
  ORDER BY occurred_at
  LIMIT 100000
),
deleted AS (
  DELETE FROM public.camera_events e
  USING doomed d
  WHERE e.id = d.id
  RETURNING e.id
)
SELECT count(*) AS deleted FROM deleted;
VACUUM (ANALYZE) public.camera_events;
SQL
      redact_file "$DIAG_DIR/db/delete-old-events-apply.out.txt"
    else
      echo "skip old events cleanup: DATABASE_URL or psql missing"
    fi
  fi

  if [ "$CLEAN_JOURNAL" = "1" ]; then
    journalctl --disk-usage > "$DIAG_DIR/logs/journal-disk-usage-before.txt" 2>&1 || true
    journalctl --vacuum-time="${JOURNAL_KEEP_DAYS}d" > "$DIAG_DIR/logs/journal-vacuum.txt" 2>&1 || true
    journalctl --disk-usage > "$DIAG_DIR/logs/journal-disk-usage-after.txt" 2>&1 || true
  fi
}

finalize() {
  echo
  echo "===== Finalize ====="
  find "$DIAG_DIR" -type f | while IFS= read -r f; do
    case "$f" in *.dump) ;; *) redact_file "$f" ;; esac
  done

  tarball="$DIAG_BASE/$RUN_ID.tar.gz"
  tar -C "$DIAG_BASE" -czf "$tarball" "$RUN_ID" 2>/dev/null || true
  echo "diagnostics directory: $DIAG_DIR"
  echo "diagnostics tarball:   $tarball"
  ls -lh "$tarball" 2>/dev/null || true

  echo
  echo "===== Quick status ====="
  for svc in newdomofon-video-dvr.service newdomofon-events-retention.service newdomofon-events-archive-retention.service newdomofon-dvr-archive-proxy.service newdomofon-smartyard-compat.service nginx.service; do
    systemctl is-active "$svc" 2>/dev/null | awk -v s="$svc" '{print s ": " $0}' || true
  done
}

load_envs
backup_current_files
collect_system_diagnostics
collect_archive_diagnostics
collect_db_diagnostics
build_cleanup_manifests
repair_retention_services

if [ "$APPLY" = "1" ]; then
  apply_cleanup
else
  echo
  echo "===== DRY-RUN ONLY ====="
  echo "Nothing deleted."
  echo "Review:"
  echo "  $DIAG_DIR/cleanup/summary.env"
  echo "  $DIAG_DIR/cleanup/archive-old-files.txt"
  echo "  $DIAG_DIR/cleanup/project-junk-dirs.txt"
  echo "  $DIAG_DIR/db/diagnostics.out.txt"
  echo
  echo "Apply after review:"
  echo "  sudo PROJECT_DIR=$PROJECT_DIR SITE_URL=$SITE_URL STREAM_NAME='${STREAM_NAME:-}' TOKEN='...' APPLY=1 CONFIRM_CLEAN=YES bash scripts/v134-cleanup-diagnostics-retention-repair.sh"
fi

finalize

echo "Done."
