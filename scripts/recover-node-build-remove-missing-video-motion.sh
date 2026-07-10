#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="${PROJECT_DIR:-/opt/newdomofon-video-node}"
SERVICE="${SERVICE:-newdomofon-video-dvr.service}"
INDEX="$PROJECT_DIR/dvr-engine/src/index.ts"
VMOTION="$PROJECT_DIR/dvr-engine/src/videoMotionDetector.ts"
BACKUP_DIR="$PROJECT_DIR/backups/recover-node-build-no-video-motion-$(date +%Y%m%d-%H%M%S)"

mkdir -p "$BACKUP_DIR"
cp -a "$INDEX" "$BACKUP_DIR/index.ts.bak"
[ -f "$VMOTION" ] && cp -a "$VMOTION" "$BACKUP_DIR/videoMotionDetector.ts.bak" || true

cd "$PROJECT_DIR"

if [ ! -f "$VMOTION" ]; then
  python3 - <<'PY'
from pathlib import Path
import re

p = Path('dvr-engine/src/index.ts')
s = p.read_text()

# Remove stale import inserted by older recovery scripts on installations that do not have this source file.
s = re.sub(r"^import \{ startVideoMotionDetector, stopAllVideoMotionDetectors \} from './videoMotionDetector\.js';\n", "", s, flags=re.M)

# Remove standalone calls.
s = re.sub(r"^\s*startVideoMotionDetector\(\);\n", "", s, flags=re.M)
s = re.sub(r"^\s*stopAllVideoMotionDetectors\(\);\n", "", s, flags=re.M)

# If an older patch expanded restart_recordings callback, make it safe without videoMotionDetector.
s = s.replace(
"""setInterval(() => pollCommands(reloadCameras, async () => {
      stopAllRecorders();
      await reloadCameras();
    }).catch(console.error), 10_000);""",
"""setInterval(() => pollCommands(reloadCameras, async () => {
      stopAllRecorders();
      await reloadCameras();
    }).catch(console.error), 10_000);"""
)

p.write_text(s)
PY
  echo "Removed stale videoMotionDetector import/calls because $VMOTION is absent"
else
  echo "videoMotionDetector source exists; no removal needed"
fi

cd "$PROJECT_DIR/dvr-engine"
npm install --include=dev
npm run build
sudo systemctl restart "$SERVICE"
sleep 4

echo "---- dvr health ----"
curl -fsS http://127.0.0.1:3010/health || true
echo

echo "---- build recovery OK ----"
echo "backup_dir=$BACKUP_DIR"
