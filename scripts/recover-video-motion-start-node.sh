#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="${PROJECT_DIR:-/opt/newdomofon-video}"
ENV_FILE="${ENV_FILE:-/etc/newdomofon-video/app.env}"
DVR_SERVICE="${DVR_SERVICE:-newdomofon-video-dvr.service}"
STREAMS="${EVENT_STREAMS:-${VIDEO_MOTION_STREAMS:-onvif2,onf}}"
BACKUP_DIR="$PROJECT_DIR/backups/recover-video-motion-start-node-$(date +%Y%m%d-%H%M%S)"

mkdir -p "$BACKUP_DIR"
cd "$PROJECT_DIR"
cp -a dvr-engine/src/index.ts "$BACKUP_DIR/index.ts.bak" 2>/dev/null || true
cp -a dvr-engine/src/videoMotionDetector.ts "$BACKUP_DIR/videoMotionDetector.ts.bak" 2>/dev/null || true
[ -f "$ENV_FILE" ] && cp -a "$ENV_FILE" "$BACKUP_DIR/app.env.bak" || true

python3 - <<'PY'
from pathlib import Path

p = Path('dvr-engine/src/index.ts')
s = p.read_text()

if "from './videoMotionDetector.js'" not in s:
    anchor = "import { startDeviceArchiveIndexer } from './deviceArchiveIndexer.js';"
    if anchor not in s:
        raise SystemExit('index.ts import anchor not found')
    s = s.replace(anchor, anchor + "\nimport { startVideoMotionDetector, stopAllVideoMotionDetectors } from './videoMotionDetector.js';", 1)

if 'startVideoMotionDetector();' not in s:
    anchor = 'startDeviceArchiveIndexer();'
    if anchor not in s:
        raise SystemExit('index.ts startup anchor not found')
    s = s.replace(anchor, anchor + "\n  startVideoMotionDetector();", 1)

if 'stopAllVideoMotionDetectors();' not in s:
    anchor = 'stopAllRecorders();'
    if anchor not in s:
        raise SystemExit('index.ts shutdown anchor not found')
    s = s.replace(anchor, anchor + "\n  stopAllVideoMotionDetectors();", 1)

p.write_text(s)
PY

# Make video-motion startup log impossible to miss and print desired camera count after every sync.
python3 - <<'PY'
from pathlib import Path

p = Path('dvr-engine/src/videoMotionDetector.ts')
s = p.read_text()

if "v3-hls-scene-motion-startup-diagnostics" not in s:
    s = s.replace("const VERSION = 'v2-hls-scene-motion';", "const VERSION = 'v3-hls-scene-motion-startup-diagnostics';", 1)

if '[video-motion] desired cameras' not in s:
    marker = "    const desired = new Map(cameras.map((camera) => [camera.stream_name, camera]));\n"
    if marker not in s:
        raise SystemExit('videoMotionDetector desired marker not found')
    s = s.replace(marker, marker + "    console.log('[video-motion] desired cameras', { streams: cameras.map((camera) => camera.stream_name), count: cameras.length });\n", 1)

p.write_text(s)
PY

sudo sed -i -E '/^(VIDEO_MOTION_ENABLED|VIDEO_MOTION_STREAMS|DVR_VIDEO_MOTION_STREAMS|VIDEO_MOTION_SOURCE|DVR_VIDEO_MOTION_SOURCE|VIDEO_MOTION_FPS|VIDEO_MOTION_SCALE_WIDTH|VIDEO_MOTION_SCENE_THRESHOLD|VIDEO_MOTION_END_IDLE_MS|VIDEO_MOTION_COOLDOWN_MS|VIDEO_MOTION_RELOAD_MS|VIDEO_MOTION_MAX_DETECTORS|VIDEO_MOTION_EVENT_TYPE)=/d' "$ENV_FILE"
cat <<EOF | sudo tee -a "$ENV_FILE" >/dev/null
VIDEO_MOTION_ENABLED=true
VIDEO_MOTION_STREAMS=${STREAMS}
DVR_VIDEO_MOTION_STREAMS=${STREAMS}
VIDEO_MOTION_SOURCE=hls
DVR_VIDEO_MOTION_SOURCE=hls
VIDEO_MOTION_FPS=2
VIDEO_MOTION_SCALE_WIDTH=320
VIDEO_MOTION_SCENE_THRESHOLD=${VIDEO_MOTION_SCENE_THRESHOLD_VALUE:-0.006}
VIDEO_MOTION_END_IDLE_MS=8000
VIDEO_MOTION_COOLDOWN_MS=3000
VIDEO_MOTION_RELOAD_MS=15000
VIDEO_MOTION_MAX_DETECTORS=4
VIDEO_MOTION_EVENT_TYPE=video.motion
EOF

cd "$PROJECT_DIR/dvr-engine"
npm install --include=dev
npm run build

# Verify compiled code really contains video-motion startup.
if ! grep -R "startVideoMotionDetector" -n dist/index.js >/dev/null 2>&1; then
  echo "ERROR: compiled dist/index.js does not contain startVideoMotionDetector" >&2
  exit 1
fi
if ! grep -R "video-motion" -n dist/videoMotionDetector.js >/dev/null 2>&1; then
  echo "ERROR: compiled dist/videoMotionDetector.js does not contain video-motion logs" >&2
  exit 1
fi

sudo systemctl restart "$DVR_SERVICE"
sleep 8

echo "---- effective env ----"
systemctl show "$DVR_SERVICE" -p Environment | tr ' ' '\n' | grep -E 'VIDEO_MOTION|DVR_VIDEO_MOTION|ONVIF_V2_SKIP_STREAMS|ONVIF_EVENTS_V2_SKIP_STREAMS|BACKEND_INTERNAL_URL|INTERNAL_DVR_SECRET' || true

echo "---- dvr health ----"
curl -fsS http://127.0.0.1:3010/health || true
echo

echo "---- video-motion logs ----"
sudo journalctl -u "$DVR_SERVICE" --since "2 minutes ago" --no-pager -l | grep -E 'video-motion|motion start|motion end|detector started|detector exited|sync failed|desired cameras' || true

echo "OK: video-motion startup forced and diagnostics enabled"
echo "backup_dir=$BACKUP_DIR"
