#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="${PROJECT_DIR:-/opt/newdomofon-video}"
DVR_SERVICE="${DVR_SERVICE:-newdomofon-video-dvr.service}"
DVR_DIR="$PROJECT_DIR/dvr-engine"
BACKUP_DIR="$PROJECT_DIR/backups/v1262-onvif-events-watchdog-finish-restart-$(date +%Y%m%d-%H%M%S)"

echo "===== v126.2 ONVIF events watchdog finish/restart ====="
echo "project: $PROJECT_DIR"
echo "dvr_dir: $DVR_DIR"
echo "service: $DVR_SERVICE"
echo "backup:  $BACKUP_DIR"

test -d "$PROJECT_DIR"
test -d "$DVR_DIR"

mkdir -p "$BACKUP_DIR"

echo
echo "===== Backup current ONVIF event files ====="
for f in \
  "$DVR_DIR/src/onvifEventsV2.ts" \
  "$DVR_DIR/dist/onvifEventsV2.js" \
  "$DVR_DIR/src/index.ts" \
  "$DVR_DIR/dist/index.js"
do
  if [ -f "$f" ]; then
    mkdir -p "$BACKUP_DIR$(dirname "$f")"
    cp -a "$f" "$BACKUP_DIR$f"
    echo "backup: $f"
  fi
done

echo
echo "===== Check installed source marker ====="
if grep -RIn "v126.*onvif-events-reconnect-watchdog" "$DVR_DIR/src" >/tmp/v1262-src-marker.txt 2>/dev/null; then
  cat /tmp/v1262-src-marker.txt
  echo "source marker: OK"
else
  echo "ERROR: v126/v126.1 source marker not found in $DVR_DIR/src"
  echo "This means v126.1 did not write the new collector source correctly."
  echo "Re-run v126.1 first or send:"
  echo "  grep -RIn \"onvif-events\" $DVR_DIR/src | head -50"
  exit 1
fi

echo
echo "===== Check collector is imported by dvr entry ====="
grep -RIn "startOnvifEventCollectorV2\\|onvifEventsV2" "$DVR_DIR/src" "$DVR_DIR/dist" 2>/dev/null | head -100 || true

echo
echo "===== Build dvr-engine ====="
cd "$DVR_DIR"
npm run build

echo
echo "===== Find compiled v126 marker ====="
set +e
grep -RIn "v126.*onvif-events-reconnect-watchdog" "$DVR_DIR/dist" >/tmp/v1262-dist-marker.txt 2>/dev/null
DIST_MARKER_RC=$?
set -e

if [ "$DIST_MARKER_RC" -eq 0 ]; then
  cat /tmp/v1262-dist-marker.txt
  echo "dist marker: OK"
else
  echo "WARNING: v126 marker not found in dist."
  echo "Build succeeded, but TypeScript output may be in another folder or version string may be transformed."
  echo "Showing dist files and onvif references:"
  find "$DVR_DIR/dist" -maxdepth 3 -type f | sort | sed -n '1,120p'
  grep -RIn "onvif-events:v2\\|startOnvifEventCollectorV2\\|onvifEventsV2" "$DVR_DIR/dist" 2>/dev/null | head -100 || true
fi

echo
echo "===== Node syntax checks ====="
for f in "$DVR_DIR/dist/onvifEventsV2.js" "$DVR_DIR/dist/index.js"; do
  if [ -f "$f" ]; then
    node --check "$f"
    echo "node --check OK: $f"
  fi
done

echo
echo "===== Show service ExecStart ====="
systemctl cat "$DVR_SERVICE" --no-pager || true

echo
echo "===== Restart DVR service ====="
sudo systemctl restart "$DVR_SERVICE"

sleep 5

echo
echo "===== Service status ====="
systemctl status "$DVR_SERVICE" --no-pager -l || true

echo
echo "===== Recent ONVIF logs ====="
journalctl -u "$DVR_SERVICE" --since '3 minutes ago' --no-pager -l \
  | grep -Ei 'v126|onvif-events:v2|pullpoint|poll ok|poll failed|stored events|session start|enabled|sync|error|failed' \
  | tail -n 200 || true

cat <<EOF

installed:
  v126.2 finish/restart helper

backup:
  $BACKUP_DIR

Meaning:
  v126.1 stopped before restart because its static grep check failed silently.
  v126.2 rebuilds, does non-fatal marker discovery, restarts $DVR_SERVICE, and prints the real logs.

Expected new logs after restart:
  [onvif-events:v2] enabled { version: 'v126.1-...' }
  [onvif-events:v2] session start
  [onvif-events:v2] event service resolved
  [onvif-events:v2] pullpoint created
  [onvif-events:v2] poll ok

If you still only see old:
  [onvif-events:v2] event {
  [onvif-events:v2] sync { cameras: 3, active: 3 }

then the running service is not loading dvr-engine/dist/onvifEventsV2.js.
Send the output of:
  systemctl cat $DVR_SERVICE --no-pager
  grep -RIn "startOnvifEventCollectorV2\\|onvifEventsV2" $DVR_DIR/src $DVR_DIR/dist | head -100
EOF
