#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="${PROJECT_DIR:-/opt/newdomofon-video}"
SITE_URL="${SITE_URL:-https://new-video.domofon-37.ru}"
TOKEN="${TOKEN:-}"
STREAM_NAME="${STREAM_NAME:-}"
CAMERA_ID="${CAMERA_ID:-}"

APPLY="${APPLY:-0}"
CONFIRM_CLEAN="${CONFIRM_CLEAN:-NO}"

ARCHIVE_KEEP_DAYS="${ARCHIVE_KEEP_DAYS:-7}"
EVENTS_KEEP_DAYS="${EVENTS_KEEP_DAYS:-7}"
PROJECT_BACKUPS_KEEP_DAYS="${PROJECT_BACKUPS_KEEP_DAYS:-14}"
PROJECT_DIAGNOSTICS_KEEP_DAYS="${PROJECT_DIAGNOSTICS_KEEP_DAYS:-14}"
PROJECT_QUARANTINE_KEEP_DAYS="${PROJECT_QUARANTINE_KEEP_DAYS:-3}"
JOURNAL_KEEP_DAYS="${JOURNAL_KEEP_DAYS:-14}"

CLEAN_PROJECT_JUNK="${CLEAN_PROJECT_JUNK:-1}"
CLEAN_CAMERA_ARCHIVE="${CLEAN_CAMERA_ARCHIVE:-1}"
CLEAN_OLD_EVENTS="${CLEAN_OLD_EVENTS:-1}"
CLEAN_JOURNAL="${CLEAN_JOURNAL:-0}"
CLEAN_NODE_MODULES="${CLEAN_NODE_MODULES:-0}"

LOG_SINCE="${LOG_SINCE:-24 hours ago}"
DIAG_BASE="${DIAG_BASE:-$PROJECT_DIR/diagnostics}"
RUN_ID="v133-cleanup-and-diagnostics-$(date +%Y%m%d-%H%M%S)"
DIAG_DIR="$DIAG_BASE/$RUN_ID"
SAFETY_DIR="$PROJECT_DIR/backups/$RUN_ID-safety"

mkdir -p "$DIAG_DIR" "$SAFETY_DIR"

exec > >(tee "$DIAG_DIR/run.log") 2>&1

echo "===== v133 cleanup and diagnostics ====="
echo "project:                    $PROJECT_DIR"
echo "site:                       $SITE_URL"
echo "stream:                     ${STREAM_NAME:-<all>}"
echo "camera_id:                  ${CAMERA_ID:-<not-set>}"
echo "apply:                      $APPLY"
echo "confirm_clean:              $CONFIRM_CLEAN"
echo "archive_keep_days:          $ARCHIVE_KEEP_DAYS"
echo "events_keep_days:           $EVENTS_KEEP_DAYS"
echo "project_backups_keep_days:  $PROJECT_BACKUPS_KEEP_DAYS"
echo "project_diagnostics_keep:   $PROJECT_DIAGNOSTICS_KEEP_DAYS"
echo "project_quarantine_keep:    $PROJECT_QUARANTINE_KEEP_DAYS"
echo "journal_keep_days:          $JOURNAL_KEEP_DAYS"
echo "log_since:                  $LOG_SINCE"
echo "diagnostics:                $DIAG_DIR"
echo "safety_backup:              $SAFETY_DIR"
echo

if [ ! -d "$PROJECT_DIR" ]; then
  echo "ERROR: PROJECT_DIR not found: $PROJECT_DIR" >&2
  exit 1
fi

if [ "$APPLY" = "1" ] && [ "$CONFIRM_CLEAN" != "YES" ]; then
  echo "ERROR: destructive cleanup requires CONFIRM_CLEAN=YES"
  echo "Run first without APPLY, review manifests in:"
  echo "  $DIAG_DIR"
  exit 2
fi

run() {
  echo
  echo "+ $*"
  "$@" || true
}

have() {
  command -v "$1" >/dev/null 2>&1
}

safe_copy() {
  local src="$1"
  local dst_root="$2"
  if [ -e "$src" ] || [ -L "$src" ]; then
    mkdir -p "$dst_root$(dirname "$src")"
    cp -a "$src" "$dst_root$src" 2>/dev/null || true
  fi
}

redact_file() {
  local file="$1"
  [ -f "$file" ] || return 0
  perl -0777 -pi -e '
    s/([?&]token=)[^&\s"<>]+/${1}<REDACTED>/gi;
    s/(Bearer\s+)[A-Za-z0-9._~+\/=-]+/${1}<REDACTED>/gi;
    s/(Authorization:\s*Basic\s+)[A-Za-z0-9._~+\/=-]+/${1}<REDACTED>/gi;
    s/(password["'\''\s:=]+)([^,"'\''\s}]+)/${1}<REDACTED>/gi;
    s/(ADMIN_PASSWORD=).*/${1}<REDACTED>/gi;
    s/(JWT_SECRET=).*/${1}<REDACTED>/gi;
    s/(DATABASE_URL=postgres(?:ql)?:\/\/)([^@\s]+)@/${1}<REDACTED>@/gi;
    s/(RESTREAM_PUBLIC_TOKEN=).*/${1}<REDACTED>/gi;
    s/(VITE_RESTREAM_PUBLIC_TOKEN=).*/${1}<REDACTED>/gi;
  ' "$file" 2>/dev/null || true
}

write_section() {
  echo
  echo "===== $* ====="
}

load_envs() {
  write_section "Load environment"
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

detect_dvr_roots() {
  local raw="${DVR_ROOTS:-/var/lib/newdomofon-video/dvr,/var/dvr}"
  echo "$raw" | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | awk 'NF'
}

detect_database_url() {
  if [ -n "${DATABASE_URL:-}" ]; then
    echo "$DATABASE_URL"
    return 0
  fi
  local envf
  for envf in /etc/newdomofon-video/app.env "$PROJECT_DIR/backend/.env" "$PROJECT_DIR/.env"; do
    if [ -f "$envf" ]; then
      local found
      found="$(grep -E '^DATABASE_URL=' "$envf" 2>/dev/null | tail -1 | cut -d= -f2- || true)"
      if [ -n "$found" ]; then
        echo "$found"
        return 0
      fi
    fi
  done
  echo ""
}

collect_basic_diagnostics() {
  write_section "Collect basic diagnostics"
  mkdir -p "$DIAG_DIR/system" "$DIAG_DIR/config" "$DIAG_DIR/logs" "$DIAG_DIR/db" "$DIAG_DIR/archive" "$DIAG_DIR/project"

  {
    echo "date_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "date_local=$(date)"
    echo "hostname=$(hostname -f 2>/dev/null || hostname)"
    echo "project=$PROJECT_DIR"
    echo "site=$SITE_URL"
    echo "stream=${STREAM_NAME:-}"
    echo "camera_id=${CAMERA_ID:-}"
    echo "apply=$APPLY"
    echo "archive_keep_days=$ARCHIVE_KEEP_DAYS"
    echo "events_keep_days=$EVENTS_KEEP_DAYS"
  } > "$DIAG_DIR/summary.env"

  run uname -a > "$DIAG_DIR/system/uname.txt"
  run hostnamectl > "$DIAG_DIR/system/hostnamectl.txt"
  run uptime > "$DIAG_DIR/system/uptime.txt"
  run df -hT > "$DIAG_DIR/system/df-hT.txt"
  run df -ih > "$DIAG_DIR/system/df-ih.txt"
  run free -h > "$DIAG_DIR/system/free-h.txt"
  run lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT,UUID > "$DIAG_DIR/system/lsblk.txt"
  run mount > "$DIAG_DIR/system/mount.txt"
  run ss -lntup > "$DIAG_DIR/system/ss-lntup.txt"
  run ps aux --sort=-%mem > "$DIAG_DIR/system/ps-aux-sort-mem.txt"
  run ps aux --sort=-%cpu > "$DIAG_DIR/system/ps-aux-sort-cpu.txt"
  run top -b -n 1 > "$DIAG_DIR/system/top.txt"

  run du -h -d 2 "$PROJECT_DIR" > "$DIAG_DIR/project/du-project-depth2.txt"
  run find "$PROJECT_DIR" -maxdepth 4 -type d \( -name node_modules -o -name .git -o -name dist -o -name backups -o -name diagnostics -o -name quarantine \) -print > "$DIAG_DIR/project/special-dirs.txt"
  run find "$PROJECT_DIR" -xdev -type f -size +20M -printf '%s %TY-%Tm-%Td %TT %p\n' | sort -nr > "$DIAG_DIR/project/large-files-over-20m.txt"

  if have node; then node --version > "$DIAG_DIR/system/node-version.txt" 2>&1 || true; fi
  if have npm; then npm --version > "$DIAG_DIR/system/npm-version.txt" 2>&1 || true; fi
  if have ffmpeg; then ffmpeg -version > "$DIAG_DIR/system/ffmpeg-version.txt" 2>&1 || true; fi
  if have psql; then psql --version > "$DIAG_DIR/system/psql-version.txt" 2>&1 || true; fi
  if have nginx; then nginx -V > "$DIAG_DIR/system/nginx-version.txt" 2>&1 || true; fi
}

collect_config_diagnostics() {
  write_section "Collect config diagnostics"
  mkdir -p "$DIAG_DIR/config/systemd" "$DIAG_DIR/config/nginx" "$DIAG_DIR/config/project"

  run systemctl list-units --all --type=service --type=timer > "$DIAG_DIR/config/systemd/list-units-services-timers.txt"

  local services=(
    newdomofon-video-dvr.service
    newdomofon-dvr-archive-proxy.service
    newdomofon-smartyard-compat.service
    newdomofon-restreamer.service
    mediamtx.service
    newdomofon-events-public-proxy.service
    newdomofon-public-events-proxy.service
    newdomofon-events-retention.service
    newdomofon-events-archive-retention.service
    newdomofon-live-only-engine.service
    newdomofon-media-public-proxy.service
    newdomofon-video-backend.service
    nginx.service
    postgresql.service
  )

  for svc in "${services[@]}"; do
    systemctl cat "$svc" --no-pager > "$DIAG_DIR/config/systemd/$svc.cat.txt" 2>&1 || true
    systemctl status "$svc" --no-pager -l > "$DIAG_DIR/config/systemd/$svc.status.txt" 2>&1 || true
  done

  if have nginx; then
    nginx -T > "$DIAG_DIR/config/nginx/nginx-T.txt" 2>&1 || true
    nginx -t > "$DIAG_DIR/config/nginx/nginx-test.txt" 2>&1 || true
    redact_file "$DIAG_DIR/config/nginx/nginx-T.txt"
  fi

  for f in \
    /etc/newdomofon-video/camera-stream-map.json \
    /etc/newdomofon-video/stream-aliases.json \
    /etc/newdomofon-video/restream-accepted-tokens.json \
    /etc/newdomofon-video/archive-start-overrides.json \
    "$PROJECT_DIR/package.json" \
    "$PROJECT_DIR/backend/package.json" \
    "$PROJECT_DIR/dvr-engine/package.json" \
    "$PROJECT_DIR/frontend/package.json" \
    "$PROJECT_DIR/dvr-archive-proxy/server.js" \
    "$PROJECT_DIR/smartyard-compat-proxy/server.js"
  do
    if [ -f "$f" ]; then
      safe_copy "$f" "$DIAG_DIR/config/project"
      redact_file "$DIAG_DIR/config/project$f"
    fi
  done

  find "$PROJECT_DIR/scripts" -maxdepth 1 -type f -printf '%TY-%Tm-%Td %TT %s %f\n' 2>/dev/null | sort > "$DIAG_DIR/project/scripts-list.txt" || true
  find "$PROJECT_DIR/backups" -maxdepth 1 -type d -printf '%TY-%Tm-%Td %TT %p\n' 2>/dev/null | sort > "$DIAG_DIR/project/backups-list.txt" || true
}

collect_logs() {
  write_section "Collect logs"
  mkdir -p "$DIAG_DIR/logs/journal" "$DIAG_DIR/logs/files"

  local services=(
    newdomofon-video-dvr.service
    newdomofon-dvr-archive-proxy.service
    newdomofon-smartyard-compat.service
    newdomofon-restreamer.service
    mediamtx.service
    newdomofon-events-public-proxy.service
    newdomofon-public-events-proxy.service
    newdomofon-events-retention.service
    newdomofon-events-archive-retention.service
    newdomofon-live-only-engine.service
    newdomofon-media-public-proxy.service
    newdomofon-video-backend.service
    nginx.service
    postgresql.service
  )

  for svc in "${services[@]}"; do
    journalctl -u "$svc" --since "$LOG_SINCE" --no-pager -o short-iso > "$DIAG_DIR/logs/journal/$svc.log" 2>&1 || true
    redact_file "$DIAG_DIR/logs/journal/$svc.log"
  done

  journalctl --since "$LOG_SINCE" --no-pager -p warning -o short-iso > "$DIAG_DIR/logs/journal/system-warnings.log" 2>&1 || true
  redact_file "$DIAG_DIR/logs/journal/system-warnings.log"

  if [ -d /var/log/newdomofon-video ]; then
    find /var/log/newdomofon-video -type f -maxdepth 2 -printf '%s %TY-%Tm-%Td %TT %p\n' > "$DIAG_DIR/logs/files/newdomofon-log-files.txt" 2>/dev/null || true
    find /var/log/newdomofon-video -type f -maxdepth 2 -name '*.log' -print0 2>/dev/null \
      | while IFS= read -r -d '' f; do
          out="$DIAG_DIR/logs/files/var-log-newdomofon-video-$(basename "$f").tail.txt"
          tail -n 2000 "$f" > "$out" 2>&1 || true
          redact_file "$out"
        done
  fi

  for f in /var/log/nginx/access.log /var/log/nginx/error.log /var/log/postgresql/postgresql-*.log; do
    for real in $f; do
      [ -f "$real" ] || continue
      out="$DIAG_DIR/logs/files/$(echo "$real" | sed 's#^/##;s#/#_#g').tail.txt"
      tail -n 2000 "$real" > "$out" 2>&1 || true
      redact_file "$out"
    done
  done
}

collect_archive_diagnostics() {
  write_section "Collect archive diagnostics"
  mkdir -p "$DIAG_DIR/archive"
  mapfile -t roots < <(detect_dvr_roots)

  printf '%s\n' "${roots[@]}" > "$DIAG_DIR/archive/dvr-roots.txt"

  for root in "${roots[@]}"; do
    [ -d "$root" ] || continue
    local_safe="$(echo "$root" | sed 's#^/##;s#/#_#g')"
    run du -h -d 3 "$root" > "$DIAG_DIR/archive/du-$local_safe.txt"
    run find "$root" -maxdepth 4 -type d -printf '%TY-%Tm-%Td %TT %p\n' | sort > "$DIAG_DIR/archive/dirs-$local_safe.txt"
    run find "$root" -type f \( -name '*.ts' -o -name '*.m3u8' -o -name '*.mp4' \) -printf '%T@ %s %p\n' \
      | sort -n > "$DIAG_DIR/archive/files-$local_safe.sorted.txt"

    {
      echo "root=$root"
      echo "files_count=$(find "$root" -type f \( -name '*.ts' -o -name '*.m3u8' -o -name '*.mp4' \) 2>/dev/null | wc -l)"
      echo "old_files_count=$(find "$root" -type f \( -name '*.ts' -o -name '*.m3u8' -o -name '*.mp4' \) -mtime +"$ARCHIVE_KEEP_DAYS" 2>/dev/null | wc -l)"
      echo "newest_files:"
      find "$root" -type f \( -name '*.ts' -o -name '*.m3u8' -o -name '*.mp4' \) -printf '%TY-%Tm-%Td %TT %s %p\n' 2>/dev/null | sort | tail -50
      echo
      echo "oldest_files:"
      find "$root" -type f \( -name '*.ts' -o -name '*.m3u8' -o -name '*.mp4' \) -printf '%TY-%Tm-%Td %TT %s %p\n' 2>/dev/null | sort | head -50
    } > "$DIAG_DIR/archive/summary-$local_safe.txt"
  done

  if [ -n "$TOKEN" ] && [ -n "$STREAM_NAME" ]; then
    for ep in \
      "$SITE_URL/$STREAM_NAME/recording_status.json?token=$TOKEN" \
      "$SITE_URL/dvr-archive/$STREAM_NAME/recording_status.json?token=$TOKEN" \
      "$SITE_URL/dvr-archive/$STREAM_NAME/coverage.json?token=$TOKEN" \
      "$SITE_URL/dvr-archive/$STREAM_NAME/ranges.json?token=$TOKEN"
    do
      name="$(echo "$ep" | sed 's#https\?://##;s#[/?&=:.]#_#g' | cut -c1-160)"
      curl -k -sS --max-time 20 -D "$DIAG_DIR/archive/http-$name.headers" -o "$DIAG_DIR/archive/http-$name.body" "$ep" || true
      redact_file "$DIAG_DIR/archive/http-$name.headers"
      redact_file "$DIAG_DIR/archive/http-$name.body"
    done
  fi
}

collect_db_diagnostics() {
  write_section "Collect DB diagnostics"
  mkdir -p "$DIAG_DIR/db"

  DB_URL="$(detect_database_url)"
  if [ -z "$DB_URL" ]; then
    echo "DATABASE_URL not found; skip DB diagnostics"
    return 0
  fi
  if ! have psql; then
    echo "psql not found; skip DB diagnostics"
    return 0
  fi

  {
    echo "\\pset pager off"
    echo "SELECT now() AS db_now;"
    echo "SELECT current_database(), current_user, version();"
    echo "SELECT schemaname, tablename, n_live_tup, n_dead_tup, last_vacuum, last_autovacuum, last_analyze, last_autoanalyze FROM pg_stat_user_tables ORDER BY n_live_tup DESC;"
    echo "SELECT count(*) AS camera_events_count, min(occurred_at) AS oldest, max(occurred_at) AS newest FROM public.camera_events;"
    echo "SELECT stream_name, count(*) AS events, min(occurred_at) AS oldest, max(occurred_at) AS newest FROM public.camera_events GROUP BY stream_name ORDER BY events DESC LIMIT 50;"
    echo "SELECT event_type, event_state, count(*) AS events, min(occurred_at) AS oldest, max(occurred_at) AS newest FROM public.camera_events GROUP BY event_type, event_state ORDER BY events DESC LIMIT 100;"
    echo "SELECT count(*) AS events_older_than_keep FROM public.camera_events WHERE occurred_at < now() - interval '$EVENTS_KEEP_DAYS days';"
    echo "SELECT count(*) AS events_without_stream FROM public.camera_events WHERE stream_name IS NULL OR stream_name = '';"
  } > "$DIAG_DIR/db/diagnostics.sql"

  psql "$DB_URL" -v ON_ERROR_STOP=0 -f "$DIAG_DIR/db/diagnostics.sql" > "$DIAG_DIR/db/diagnostics.out.txt" 2>&1 || true
  redact_file "$DIAG_DIR/db/diagnostics.out.txt"

  if have pg_dump; then
    pg_dump "$DB_URL" -Fc -t public.camera_events -f "$DIAG_DIR/db/camera_events-before-clean.dump" > "$DIAG_DIR/db/pg_dump-camera_events.log" 2>&1 || true
    redact_file "$DIAG_DIR/db/pg_dump-camera_events.log"
  fi
}

build_cleanup_manifests() {
  write_section "Build cleanup manifests"
  mkdir -p "$DIAG_DIR/cleanup"

  : > "$DIAG_DIR/cleanup/project-junk-files.txt"
  : > "$DIAG_DIR/cleanup/project-junk-dirs.txt"
  : > "$DIAG_DIR/cleanup/archive-old-files.txt"
  : > "$DIAG_DIR/cleanup/archive-empty-dirs.txt"

  if [ "$CLEAN_PROJECT_JUNK" = "1" ]; then
    # Old project backups and diagnostics. Keep current diagnostics and safety backup.
    if [ -d "$PROJECT_DIR/backups" ]; then
      find "$PROJECT_DIR/backups" -mindepth 1 -maxdepth 1 -type d -mtime +"$PROJECT_BACKUPS_KEEP_DAYS" \
        ! -path "$SAFETY_DIR" -printf '%p\n' >> "$DIAG_DIR/cleanup/project-junk-dirs.txt" 2>/dev/null || true
    fi

    if [ -d "$PROJECT_DIR/diagnostics" ]; then
      find "$PROJECT_DIR/diagnostics" -mindepth 1 -maxdepth 1 \( -type d -o -type f \) -mtime +"$PROJECT_DIAGNOSTICS_KEEP_DAYS" \
        ! -path "$DIAG_DIR" -printf '%p\n' >> "$DIAG_DIR/cleanup/project-junk-dirs.txt" 2>/dev/null || true
    fi

    find "$PROJECT_DIR" -maxdepth 1 -type d -name 'scripts-archive-before-clean-*' -mtime +"$PROJECT_BACKUPS_KEEP_DAYS" -printf '%p\n' >> "$DIAG_DIR/cleanup/project-junk-dirs.txt" 2>/dev/null || true
    find "$PROJECT_DIR" -maxdepth 1 -type d -name 'newdomofon-clean-scripts-v*' -mtime +"$PROJECT_BACKUPS_KEEP_DAYS" -printf '%p\n' >> "$DIAG_DIR/cleanup/project-junk-dirs.txt" 2>/dev/null || true

    if [ -d "$PROJECT_DIR/quarantine" ]; then
      find "$PROJECT_DIR/quarantine" -mindepth 1 \( -type f -o -type d \) -mtime +"$PROJECT_QUARANTINE_KEEP_DAYS" -printf '%p\n' >> "$DIAG_DIR/cleanup/project-junk-dirs.txt" 2>/dev/null || true
    fi

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
      if [ -n "$STREAM_NAME" ] && [ -d "$root/$STREAM_NAME" ]; then
        find "$root/$STREAM_NAME" -type f \( -name '*.ts' -o -name '*.m3u8' -o -name '*.mp4' \) -mtime +"$ARCHIVE_KEEP_DAYS" -print >> "$DIAG_DIR/cleanup/archive-old-files.txt" 2>/dev/null || true
        find "$root/$STREAM_NAME" -depth -type d -empty -print >> "$DIAG_DIR/cleanup/archive-empty-dirs.txt" 2>/dev/null || true
      else
        find "$root" -type f \( -name '*.ts' -o -name '*.m3u8' -o -name '*.mp4' \) -mtime +"$ARCHIVE_KEEP_DAYS" -print >> "$DIAG_DIR/cleanup/archive-old-files.txt" 2>/dev/null || true
        find "$root" -depth -type d -empty -print >> "$DIAG_DIR/cleanup/archive-empty-dirs.txt" 2>/dev/null || true
      fi
    done
  fi

  sort -u -o "$DIAG_DIR/cleanup/project-junk-files.txt" "$DIAG_DIR/cleanup/project-junk-files.txt"
  sort -u -o "$DIAG_DIR/cleanup/project-junk-dirs.txt" "$DIAG_DIR/cleanup/project-junk-dirs.txt"
  sort -u -o "$DIAG_DIR/cleanup/archive-old-files.txt" "$DIAG_DIR/cleanup/archive-old-files.txt"
  sort -u -o "$DIAG_DIR/cleanup/archive-empty-dirs.txt" "$DIAG_DIR/cleanup/archive-empty-dirs.txt"

  {
    echo "project_junk_files=$(wc -l < "$DIAG_DIR/cleanup/project-junk-files.txt")"
    echo "project_junk_dirs=$(wc -l < "$DIAG_DIR/cleanup/project-junk-dirs.txt")"
    echo "archive_old_files=$(wc -l < "$DIAG_DIR/cleanup/archive-old-files.txt")"
    echo "archive_empty_dirs=$(wc -l < "$DIAG_DIR/cleanup/archive-empty-dirs.txt")"
    if have du; then
      echo "archive_old_files_size_bytes=$(while IFS= read -r f; do [ -f "$f" ] && stat -c '%s' "$f"; done < "$DIAG_DIR/cleanup/archive-old-files.txt" | awk '{s+=$1} END{print s+0}')"
    fi
  } > "$DIAG_DIR/cleanup/summary.env"

  cat "$DIAG_DIR/cleanup/summary.env"
}

apply_project_cleanup() {
  [ "$CLEAN_PROJECT_JUNK" = "1" ] || return 0
  write_section "Apply project cleanup"
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    if [ -f "$f" ] || [ -L "$f" ]; then
      echo "delete file: $f"
      rm -f -- "$f"
    fi
  done < "$DIAG_DIR/cleanup/project-junk-files.txt"

  # Directories deepest first.
  sort -r "$DIAG_DIR/cleanup/project-junk-dirs.txt" | while IFS= read -r d; do
    [ -n "$d" ] || continue
    case "$d" in
      "$PROJECT_DIR"|"/"|"/var"|"/var/lib"|"/var/lib/newdomofon-video") echo "skip dangerous dir: $d"; continue ;;
    esac
    if [ -d "$d" ]; then
      echo "delete dir: $d"
      rm -rf -- "$d"
    fi
  done
}

apply_archive_cleanup() {
  [ "$CLEAN_CAMERA_ARCHIVE" = "1" ] || return 0
  write_section "Apply old camera archive cleanup"
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    if [ -f "$f" ]; then
      echo "delete archive file: $f"
      rm -f -- "$f"
    fi
  done < "$DIAG_DIR/cleanup/archive-old-files.txt"

  sort -r "$DIAG_DIR/cleanup/archive-empty-dirs.txt" | while IFS= read -r d; do
    [ -n "$d" ] || continue
    case "$d" in "/"|"/var"|"/var/lib"|"/var/lib/newdomofon-video"|"/var/lib/newdomofon-video/dvr"|"/var/dvr") continue ;; esac
    if [ -d "$d" ]; then
      rmdir --ignore-fail-on-non-empty "$d" 2>/dev/null || true
    fi
  done
}

apply_events_cleanup() {
  [ "$CLEAN_OLD_EVENTS" = "1" ] || return 0
  write_section "Apply old events cleanup"

  DB_URL="$(detect_database_url)"
  if [ -z "$DB_URL" ]; then
    echo "DATABASE_URL not found; skip events cleanup"
    return 0
  fi
  if ! have psql; then
    echo "psql not found; skip events cleanup"
    return 0
  fi

  cat > "$DIAG_DIR/db/delete-old-camera-events.sql" <<SQL
\\pset pager off
BEGIN;
SELECT count(*) AS before_total FROM public.camera_events;
SELECT count(*) AS to_delete FROM public.camera_events WHERE occurred_at < now() - interval '$EVENTS_KEEP_DAYS days';
DELETE FROM public.camera_events WHERE occurred_at < now() - interval '$EVENTS_KEEP_DAYS days';
SELECT count(*) AS after_total FROM public.camera_events;
COMMIT;
VACUUM (ANALYZE) public.camera_events;
SQL

  psql "$DB_URL" -v ON_ERROR_STOP=1 -f "$DIAG_DIR/db/delete-old-camera-events.sql" > "$DIAG_DIR/db/delete-old-camera-events.out.txt" 2>&1 || {
    echo "ERROR: event cleanup SQL failed; see $DIAG_DIR/db/delete-old-camera-events.out.txt"
    redact_file "$DIAG_DIR/db/delete-old-camera-events.out.txt"
    return 1
  }
  redact_file "$DIAG_DIR/db/delete-old-camera-events.out.txt"
}

apply_journal_cleanup() {
  [ "$CLEAN_JOURNAL" = "1" ] || return 0
  write_section "Apply journal cleanup"
  journalctl --disk-usage > "$DIAG_DIR/logs/journal-disk-usage-before.txt" 2>&1 || true
  journalctl --vacuum-time="${JOURNAL_KEEP_DAYS}d" > "$DIAG_DIR/logs/journal-vacuum.txt" 2>&1 || true
  journalctl --disk-usage > "$DIAG_DIR/logs/journal-disk-usage-after.txt" 2>&1 || true
}

finalize_diagnostics() {
  write_section "Finalize diagnostics"
  find "$DIAG_DIR" -type f -maxdepth 8 | while IFS= read -r f; do
    case "$f" in
      *.dump) ;;
      *) redact_file "$f" ;;
    esac
  done

  tarball="$DIAG_BASE/$RUN_ID.tar.gz"
  tar -C "$DIAG_BASE" -czf "$tarball" "$RUN_ID"
  echo "diagnostics directory: $DIAG_DIR"
  echo "diagnostics tarball:   $tarball"
  ls -lh "$tarball" || true
}

load_envs
collect_basic_diagnostics
collect_config_diagnostics
collect_logs
collect_archive_diagnostics
collect_db_diagnostics
build_cleanup_manifests

if [ "$APPLY" = "1" ]; then
  write_section "Apply cleanup"
  apply_project_cleanup
  apply_archive_cleanup
  apply_events_cleanup
  apply_journal_cleanup
else
  write_section "Dry-run only"
  cat <<EOF
Nothing deleted.

Review manifests:
  $DIAG_DIR/cleanup/project-junk-files.txt
  $DIAG_DIR/cleanup/project-junk-dirs.txt
  $DIAG_DIR/cleanup/archive-old-files.txt
  $DIAG_DIR/cleanup/archive-empty-dirs.txt
  $DIAG_DIR/db/diagnostics.out.txt

To apply cleanup after review:
  sudo PROJECT_DIR=$PROJECT_DIR \\
    SITE_URL=$SITE_URL \\
    TOKEN='...' \\
    STREAM_NAME='${STREAM_NAME:-}' \\
    ARCHIVE_KEEP_DAYS=$ARCHIVE_KEEP_DAYS \\
    EVENTS_KEEP_DAYS=$EVENTS_KEEP_DAYS \\
    APPLY=1 \\
    CONFIRM_CLEAN=YES \\
    bash scripts/v133-cleanup-and-diagnostics.sh

Optional:
  CLEAN_NODE_MODULES=1   # dangerous for Node services unless you will reinstall dependencies
  CLEAN_JOURNAL=1        # also vacuum systemd journal older than JOURNAL_KEEP_DAYS
EOF
fi

finalize_diagnostics

echo
echo "Done."
