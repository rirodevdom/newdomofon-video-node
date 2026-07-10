#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="${PROJECT_DIR:-/opt/newdomofon-video-node}"
ENV_FILE="${ENV_FILE:-/etc/newdomofon-video/app.env}"
STREAMS_CSV="${STREAMS:-onvif2,onf}"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="$PROJECT_DIR/backups/live-stall-recovery-$STAMP"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run as root: sudo bash scripts/recover-live-stall-onvif2.sh" >&2
  exit 1
fi

install -d -m 0750 "$BACKUP_DIR" "$(dirname "$ENV_FILE")"
cp -a "$ENV_FILE" "$BACKUP_DIR/app.env.bak" 2>/dev/null || true

node - "$ENV_FILE" "$STREAMS_CSV" <<'NODE'
const fs = require('fs');
const [file, streamsCsv] = process.argv.slice(2);
let lines = fs.existsSync(file) ? fs.readFileSync(file, 'utf8').split(/\r?\n/) : [];
const managed = new Set([
  'VIDEO_MOTION_ENABLED',
  'VIDEO_MOTION_STREAMS',
  'VIDEO_MOTION_SOURCE',
  'ONVIF_V2_SKIP_STREAMS',
  'ONVIF_EVENTS_V2_SKIP_STREAMS',
  'ONVIF_LEGACY_FALLBACK_STREAMS'
]);
lines = lines.filter((line) => {
  const key = String(line).split('=')[0].trim();
  return key && !managed.has(key);
});
const streams = String(streamsCsv || 'onvif2,onf')
  .split(',')
  .map((value) => value.trim())
  .filter(Boolean)
  .join(',');
lines.push('VIDEO_MOTION_ENABLED=false');
lines.push('VIDEO_MOTION_STREAMS=');
lines.push('VIDEO_MOTION_SOURCE=hls');
lines.push(`ONVIF_V2_SKIP_STREAMS=${streams}`);
lines.push(`ONVIF_EVENTS_V2_SKIP_STREAMS=${streams}`);
lines.push('ONVIF_LEGACY_FALLBACK_STREAMS=');
fs.writeFileSync(file, lines.join('\n').replace(/\n*$/, '\n'));
NODE

pkill -TERM -f 'metadata=mode=print:key=lavfi.scene_score' 2>/dev/null || true
pkill -TERM -f 'ffmpeg.*lavfi\.scene_score' 2>/dev/null || true
sleep 1
pkill -KILL -f 'metadata=mode=print:key=lavfi.scene_score' 2>/dev/null || true
pkill -KILL -f 'ffmpeg.*lavfi\.scene_score' 2>/dev/null || true

systemctl restart newdomofon-video-dvr.service
sleep 5

set -a
# shellcheck disable=SC1090
[ -f "$ENV_FILE" ] && . "$ENV_FILE"
set +a

printf '\n=== recovery env ===\n'
grep -E '^(VIDEO_MOTION_ENABLED|VIDEO_MOTION_STREAMS|VIDEO_MOTION_SOURCE|ONVIF_V2_SKIP_STREAMS|ONVIF_EVENTS_V2_SKIP_STREAMS|ONVIF_LEGACY_FALLBACK_STREAMS)=' "$ENV_FILE" || true

printf '\n=== camera rtsp/network diagnostics ===\n'
if [[ -n "${DATABASE_URL:-}" ]] && command -v psql >/dev/null 2>&1; then
  IFS=',' read -ra STREAMS <<< "$STREAMS_CSV"
  for stream in "${STREAMS[@]}"; do
    stream="$(echo "$stream" | xargs)"
    [[ -z "$stream" ]] && continue
    rtsp="$(psql "$DATABASE_URL" -Atc "select source_url from cameras where stream_name='${stream//\'/\'\'}' limit 1" 2>/dev/null || true)"
    host=""
    if [[ "$rtsp" =~ @([^/:]+) ]]; then host="${BASH_REMATCH[1]}"; fi
    if [[ -z "$host" && "$rtsp" =~ rtsp://([^/:]+) ]]; then host="${BASH_REMATCH[1]}"; fi
    echo "--- $stream ---"
    echo "rtsp=${rtsp%%@*}@***"
    if [[ -n "$host" ]]; then
      ip route get "$host" 2>&1 || true
      ping -c 2 -W 1 "$host" 2>&1 || true
      timeout 5 bash -c "</dev/tcp/$host/554" >/dev/null 2>&1 && echo "tcp/554 OK" || echo "tcp/554 FAIL"
      timeout 5 bash -c "</dev/tcp/$host/80" >/dev/null 2>&1 && echo "tcp/80 OK" || echo "tcp/80 FAIL"
    fi
  done
else
  echo "DATABASE_URL or psql is unavailable; skipping DB-based diagnostics"
fi

printf '\n=== recorder/video-motion logs ===\n'
journalctl -u newdomofon-video-dvr -n 180 --no-pager -l \
  | grep -E 'video-motion|Started recorder onvif2|Recorder onvif2 exited|Started recorder onf|Recorder onf exited|No route|Connection timed out|poll failed|DVR engine listening' || true

printf '\nRecovery applied. Backup: %s\n' "$BACKUP_DIR"
