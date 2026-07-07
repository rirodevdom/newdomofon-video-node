#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="${PROJECT_DIR:-/opt/newdomofon-video}"
APPLY="${APPLY:-0}"
STREAM_NAME="${STREAM_NAME:-cam_10_130_1_219}"
SITE_URL="${SITE_URL:-https://new-video.domofon-37.ru}"
TOKEN="${TOKEN:-}"
ROLLBACK_BACKUP="$PROJECT_DIR/backups/v132-rollback-today-before-$(date +%Y%m%d-%H%M%S)"

echo "===== v132 rollback all today's updates ====="
echo "project:         $PROJECT_DIR"
echo "apply:           $APPLY"
echo "stream:          $STREAM_NAME"
echo "site:            $SITE_URL"
echo "safety backup:   $ROLLBACK_BACKUP"

test -d "$PROJECT_DIR"
mkdir -p "$ROLLBACK_BACKUP"

latest_backup() {
  local pattern="$1"
  ls -td "$PROJECT_DIR"/backups/$pattern 2>/dev/null | head -1 || true
}

copy_current_to_safety_backup() {
  local f="$1"
  [ -n "$f" ] || return 0
  if [ -e "$f" ] || [ -L "$f" ]; then
    mkdir -p "$ROLLBACK_BACKUP$(dirname "$f")"
    cp -a "$f" "$ROLLBACK_BACKUP$f"
    echo "safety backup: $f"
  fi
}

restore_from_backup() {
  local backup_dir="$1"
  local abs_path="$2"
  local label="${3:-}"
  [ -n "$backup_dir" ] || return 0
  local src="$backup_dir$abs_path"

  if [ ! -e "$src" ] && [ ! -L "$src" ]; then
    echo "skip: $abs_path not found in $(basename "$backup_dir") ${label:+($label)}"
    return 0
  fi

  echo "restore: $abs_path <- $(basename "$backup_dir") ${label:+($label)}"

  if [ "$APPLY" = "1" ]; then
    mkdir -p "$(dirname "$abs_path")"
    rm -rf "$abs_path"
    cp -a "$src" "$abs_path"
  fi
}

show_backup() {
  local name="$1"
  local dir="$2"
  if [ -n "$dir" ]; then
    echo "found: $name -> $dir"
  else
    echo "missing: $name"
  fi
}

echo
echo "===== Locate latest backups ====="
B131="$(latest_backup 'v131-archive-metadata-single-source-*')"
B130="$(latest_backup 'v130-archive-coverage-ranges-exact-nginx-route-*')"
B129="$(latest_backup 'v129-recording-status-exact-nginx-route-*')"
B128="$(latest_backup 'v128-recording-status-public-ranges-router-*')"
B127="$(latest_backup 'v127-archive-status-ranges-repair-*')"
B1261="$(latest_backup 'v1261-onvif-events-reconnect-watchdog-fixed-*')"
B126="$(latest_backup 'v126-onvif-events-reconnect-watchdog-*')"

show_backup "v131" "$B131"
show_backup "v130" "$B130"
show_backup "v129" "$B129"
show_backup "v128" "$B128"
show_backup "v127" "$B127"
show_backup "v126.1" "$B1261"
show_backup "v126" "$B126"

echo
echo "===== Safety backup current files before rollback ====="
CURRENT_FILES=(
  "/etc/nginx/conf.d/newdomofon-restream-8445-http-gateway.conf"
  "/etc/nginx/sites-available/newdomofon-video.conf"
  "/etc/nginx/sites-enabled/newdomofon-video.conf"
  "/etc/newdomofon-video/app.env"
  "/etc/systemd/system/newdomofon-dvr-archive-proxy.service"
  "/etc/systemd/system/newdomofon-smartyard-compat.service"
  "/etc/systemd/system/newdomofon-video-dvr.service"
  "$PROJECT_DIR/dvr-archive-proxy/server.js"
  "$PROJECT_DIR/smartyard-compat-proxy/server.js"
  "$PROJECT_DIR/dvr-engine/src/onvifEventsV2.ts"
  "$PROJECT_DIR/dvr-engine/dist/onvifEventsV2.js"
)
for f in "${CURRENT_FILES[@]}"; do
  copy_current_to_safety_backup "$f"
done

echo
echo "===== Rollback plan ====="
cat <<'PLAN'
Reverse order:
  1. v131 if it was applied: restore dvr-archive-proxy/server.js.
  2. v130: remove exact nginx routes for coverage.json/ranges.json by restoring nginx configs.
  3. v129: remove exact nginx routes for recording_status.json by restoring nginx configs.
  4. v128: remove regex nginx route experiment and restore related proxy/unit files.
  5. v127: restore archive proxy/app.env/systemd units to the state before archive ranges repair.
  6. v126.1: restore ONVIF events collector files to the state before reconnect watchdog.
PLAN

echo
echo "===== Restore v131 if present ====="
restore_from_backup "$B131" "$PROJECT_DIR/dvr-archive-proxy/server.js" "v131 rollback"

echo
echo "===== Restore v130 nginx configs ====="
restore_from_backup "$B130" "/etc/nginx/conf.d/newdomofon-restream-8445-http-gateway.conf" "v130 rollback"
restore_from_backup "$B130" "/etc/nginx/sites-available/newdomofon-video.conf" "v130 rollback"
restore_from_backup "$B130" "/etc/nginx/sites-enabled/newdomofon-video.conf" "v130 rollback"

echo
echo "===== Restore v129 nginx configs ====="
restore_from_backup "$B129" "/etc/nginx/conf.d/newdomofon-restream-8445-http-gateway.conf" "v129 rollback"
restore_from_backup "$B129" "/etc/nginx/sites-available/newdomofon-video.conf" "v129 rollback"
restore_from_backup "$B129" "/etc/nginx/sites-enabled/newdomofon-video.conf" "v129 rollback"

echo
echo "===== Restore v128 nginx/proxy files ====="
restore_from_backup "$B128" "/etc/nginx/conf.d/newdomofon-restream-8445-http-gateway.conf" "v128 rollback"
restore_from_backup "$B128" "/etc/nginx/sites-available/newdomofon-video.conf" "v128 rollback"
restore_from_backup "$B128" "/etc/nginx/sites-enabled/newdomofon-video.conf" "v128 rollback"
restore_from_backup "$B128" "$PROJECT_DIR/dvr-archive-proxy/server.js" "v128 rollback"
restore_from_backup "$B128" "$PROJECT_DIR/smartyard-compat-proxy/server.js" "v128 rollback"
restore_from_backup "$B128" "/etc/systemd/system/newdomofon-dvr-archive-proxy.service" "v128 rollback"
restore_from_backup "$B128" "/etc/systemd/system/newdomofon-smartyard-compat.service" "v128 rollback"

echo
echo "===== Restore v127 archive repair files ====="
restore_from_backup "$B127" "$PROJECT_DIR/dvr-archive-proxy/server.js" "v127 rollback"
restore_from_backup "$B127" "/etc/newdomofon-video/app.env" "v127 rollback"
restore_from_backup "$B127" "/etc/systemd/system/newdomofon-dvr-archive-proxy.service" "v127 rollback"
restore_from_backup "$B127" "/etc/systemd/system/newdomofon-smartyard-compat.service" "v127 rollback"

echo
echo "===== Restore v126.1 ONVIF watchdog files ====="
restore_from_backup "$B1261" "$PROJECT_DIR/dvr-engine/src/onvifEventsV2.ts" "v126.1 rollback"
restore_from_backup "$B1261" "$PROJECT_DIR/dvr-engine/dist/onvifEventsV2.js" "v126.1 rollback"

# v126 failed early in the previous log, but support it if a useful backup exists.
restore_from_backup "$B126" "$PROJECT_DIR/dvr-engine/src/onvifEventsV2.ts" "v126 rollback optional"
restore_from_backup "$B126" "$PROJECT_DIR/dvr-engine/dist/onvifEventsV2.js" "v126 rollback optional"

if [ "$APPLY" != "1" ]; then
  cat <<EOF

DRY-RUN only. Nothing restored.

To apply rollback:
  sudo PROJECT_DIR=$PROJECT_DIR \\
    STREAM_NAME=$STREAM_NAME \\
    SITE_URL=$SITE_URL \\
    TOKEN='...' \\
    APPLY=1 \\
    bash scripts/v132-rollback-today.sh

Safety backup of current state was created at:
  $ROLLBACK_BACKUP
EOF
  exit 0
fi

echo
echo "===== systemd daemon-reload ====="
systemctl daemon-reload || true

echo
echo "===== Validate nginx before reload ====="
if nginx -t; then
  echo "nginx config OK, reload nginx"
  systemctl reload nginx || systemctl restart nginx
else
  echo "ERROR: nginx config test failed after rollback."
  echo "Current files are backed up in: $ROLLBACK_BACKUP"
  echo "Do not restart nginx manually until config is fixed."
  exit 2
fi

echo
echo "===== Restart affected services ====="
for svc in \
  newdomofon-dvr-archive-proxy.service \
  newdomofon-smartyard-compat.service \
  newdomofon-video-dvr.service
do
  if systemctl list-unit-files "$svc" >/dev/null 2>&1; then
    echo "restart: $svc"
    systemctl restart "$svc" || true
  fi
done

sleep 3

echo
echo "===== Service status summary ====="
for svc in \
  nginx.service \
  newdomofon-dvr-archive-proxy.service \
  newdomofon-smartyard-compat.service \
  newdomofon-video-dvr.service
do
  systemctl --no-pager --full status "$svc" | sed -n '1,12p' || true
  echo
done

echo
echo "===== Post-rollback checks ====="
TOKEN_Q=""
if [ -n "$TOKEN" ]; then TOKEN_Q="?token=$TOKEN"; fi

for ep in recording_status.json coverage.json ranges.json; do
  url="$SITE_URL/dvr-archive/$STREAM_NAME/$ep$TOKEN_Q"
  echo "--- $ep"
  curl -k -sS --max-time 20 -D /tmp/v132-$ep.headers -o /tmp/v132-$ep.json "$url" || true
  grep -Ei '^(HTTP/|x-nd-|cache-control:|content-type:)' /tmp/v132-$ep.headers || true
  cat /tmp/v132-$ep.json 2>/dev/null | jq 'if type=="array" then .[0] else . end | {
    version,
    from_iso,
    to_iso,
    ranges_count: (.ranges|length?),
    gaps_count: (.gaps|length?)
  }' 2>/dev/null || cat /tmp/v132-$ep.json 2>/dev/null || true
  echo
done

cat <<EOF

rollback completed.

Restored today's changes from backups where available:
  - v126.1 ONVIF watchdog
  - v127 archive ranges repair
  - v128 recording_status route attempt
  - v129 exact recording_status routes
  - v130 coverage/ranges exact routes
  - v131 archive metadata single-source, if it had been applied

Current state before rollback was saved here:
  $ROLLBACK_BACKUP

If something needs to be returned, restore from this safety backup.
EOF
