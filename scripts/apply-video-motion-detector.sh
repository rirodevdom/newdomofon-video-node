#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="${PROJECT_DIR:-/opt/newdomofon-video-node}"
ENV_FILE="${ENV_FILE:-/etc/newdomofon-video/app.env}"
RAW_BASE="${RAW_BASE:-https://raw.githubusercontent.com/rirodevdom/newdomofon-video/main}"
STREAMS="${VIDEO_MOTION_STREAMS:-${DVR_VIDEO_MOTION_STREAMS:-onvif2}}"
SOURCE="${VIDEO_MOTION_SOURCE:-${DVR_VIDEO_MOTION_SOURCE:-hls}}"
THRESHOLD="${VIDEO_MOTION_SCENE_THRESHOLD:-0.010}"
END_IDLE_MS="${VIDEO_MOTION_END_IDLE_MS:-7000}"
FPS="${VIDEO_MOTION_FPS:-3}"
SCALE_WIDTH="${VIDEO_MOTION_SCALE_WIDTH:-320}"
MAX_DETECTORS="${VIDEO_MOTION_MAX_DETECTORS:-4}"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="$PROJECT_DIR/backups/video-motion-detector-$STAMP"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run as root: sudo bash scripts/apply-video-motion-detector.sh" >&2
  exit 1
fi

install -d -m 0750 "$BACKUP_DIR" "$PROJECT_DIR/dvr-engine/src" "$(dirname "$ENV_FILE")"

for path in \
  dvr-engine/src/videoMotionDetector.ts \
  dvr-engine/src/index.ts \
  dvr-engine/src/nodeClient.ts \
  dvr-engine/src/recorder.ts
  do
    if [[ -f "$PROJECT_DIR/$path" ]]; then
      cp -a "$PROJECT_DIR/$path" "$BACKUP_DIR/$(basename "$path").bak"
    fi
    echo "Downloading $path"
    curl --retry 5 --retry-delay 2 --connect-timeout 20 --max-time 120 -fsSL \
      "$RAW_BASE/$path?nocache=$(date +%s%N)" \
      -o "$PROJECT_DIR/$path"
  done

touch "$ENV_FILE"
chmod 0640 "$ENV_FILE" || true
cp -a "$ENV_FILE" "$BACKUP_DIR/app.env.bak" 2>/dev/null || true

node - "$ENV_FILE" "$STREAMS" "$SOURCE" "$THRESHOLD" "$END_IDLE_MS" "$FPS" "$SCALE_WIDTH" "$MAX_DETECTORS" <<'NODE'
const fs = require('fs');
const [file, streams, source, threshold, endIdleMs, fps, scaleWidth, maxDetectors] = process.argv.slice(2);
let lines = fs.existsSync(file) ? fs.readFileSync(file, 'utf8').split(/\r?\n/) : [];
const managed = new Set([
  'VIDEO_MOTION_ENABLED',
  'VIDEO_MOTION_STREAMS',
  'VIDEO_MOTION_SOURCE',
  'VIDEO_MOTION_SCENE_THRESHOLD',
  'VIDEO_MOTION_END_IDLE_MS',
  'VIDEO_MOTION_FPS',
  'VIDEO_MOTION_SCALE_WIDTH',
  'VIDEO_MOTION_MAX_DETECTORS',
  'VIDEO_MOTION_EVENT_TYPE'
]);
lines = lines.filter((line) => {
  const key = String(line).split('=')[0].trim();
  return key && !managed.has(key);
});
function setValue(key, value) {
  lines.push(`${key}=${value}`);
}
setValue('VIDEO_MOTION_ENABLED', 'true');
setValue('VIDEO_MOTION_STREAMS', streams || 'onvif2');
setValue('VIDEO_MOTION_SOURCE', String(source || 'hls').toLowerCase() === 'rtsp' ? 'rtsp' : 'hls');
setValue('VIDEO_MOTION_SCENE_THRESHOLD', threshold || '0.010');
setValue('VIDEO_MOTION_END_IDLE_MS', endIdleMs || '7000');
setValue('VIDEO_MOTION_FPS', fps || '3');
setValue('VIDEO_MOTION_SCALE_WIDTH', scaleWidth || '320');
setValue('VIDEO_MOTION_MAX_DETECTORS', maxDetectors || '4');
setValue('VIDEO_MOTION_EVENT_TYPE', 'video.motion');
fs.writeFileSync(file, lines.join('\n').replace(/\n*$/, '\n'));
NODE

pushd "$PROJECT_DIR/dvr-engine" >/dev/null
export NODE_ENV=
export NPM_CONFIG_PRODUCTION=false
if [[ -f package-lock.json ]]; then
  npm install --include=dev
else
  npm install --include=dev
fi
npm run build
popd >/dev/null

systemctl restart newdomofon-video-dvr.service
sleep 2

echo "Video motion env:"
grep -E '^(VIDEO_MOTION_ENABLED|VIDEO_MOTION_STREAMS|VIDEO_MOTION_SOURCE|VIDEO_MOTION_SCENE_THRESHOLD|VIDEO_MOTION_END_IDLE_MS|VIDEO_MOTION_FPS|VIDEO_MOTION_SCALE_WIDTH|VIDEO_MOTION_MAX_DETECTORS|VIDEO_MOTION_EVENT_TYPE)=' "$ENV_FILE" || true

echo
echo "Recent logs:"
journalctl -u newdomofon-video-dvr -n 160 --no-pager -l \
  | grep -E 'video-motion|video\.motion|motion start|motion end|DVR engine listening' || true

echo
echo "Video motion detector applied. Backup: $BACKUP_DIR"
