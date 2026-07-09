#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="${PROJECT_DIR:-/opt/newdomofon-video}"
TARGET="$PROJECT_DIR/dvr-engine/src/onvifEventsLegacyFallback.ts"
SERVICE="${SERVICE:-newdomofon-video-dvr.service}"
BACKUP_DIR="$PROJECT_DIR/backups/fix-node-onvif-spool-fs-import-$(date +%Y%m%d-%H%M%S)"

mkdir -p "$BACKUP_DIR"
cp -a "$TARGET" "$BACKUP_DIR/onvifEventsLegacyFallback.ts.bak"

python3 - <<'PY'
from pathlib import Path
p = Path('/opt/newdomofon-video/dvr-engine/src/onvifEventsLegacyFallback.ts')
s = p.read_text()
if "import fs from 'node:fs/promises';" not in s:
    if "import crypto from 'node:crypto';" in s:
        s = s.replace(
            "import crypto from 'node:crypto';",
            "import crypto from 'node:crypto';\nimport fs from 'node:fs/promises';",
            1,
        )
    else:
        s = "import fs from 'node:fs/promises';\n" + s
p.write_text(s)
PY

cd "$PROJECT_DIR/dvr-engine"
npm install --include=dev
npm run build
sudo systemctl restart "$SERVICE"
sleep 5

echo "---- fs import ----"
grep -n "import fs from 'node:fs/promises'" "$TARGET" || true

echo "---- health ----"
curl -fsS http://127.0.0.1:3010/health || true
echo

echo "OK: fs import fixed and DVR rebuilt"
echo "backup_dir=$BACKUP_DIR"
