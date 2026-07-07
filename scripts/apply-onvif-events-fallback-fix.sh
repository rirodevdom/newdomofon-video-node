#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="${PROJECT_DIR:-/opt/newdomofon-video}"
ENV_FILE="${ENV_FILE:-/etc/newdomofon-video/app.env}"
TARGET_STREAM="${TARGET_STREAM:-${TEST_STREAM:-onvif2}}"
DVR_FILE="$PROJECT_DIR/dvr-engine/src/onvifEventsV2.ts"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="$PROJECT_DIR/backups/onvif-events-fallback-fix-$STAMP"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run as root: sudo bash scripts/apply-onvif-events-fallback-fix.sh" >&2
  exit 1
fi

if [[ -z "$TARGET_STREAM" ]]; then
  echo "TARGET_STREAM is empty" >&2
  exit 2
fi

if [[ ! -f "$DVR_FILE" ]]; then
  echo "Missing ONVIF v2 collector source: $DVR_FILE" >&2
  exit 3
fi

install -d -m 0750 "$BACKUP_DIR"
cp -a "$DVR_FILE" "$BACKUP_DIR/onvifEventsV2.ts.bak"
if [[ -f "$ENV_FILE" ]]; then
  cp -a "$ENV_FILE" "$BACKUP_DIR/app.env.bak"
else
  install -d -m 0750 "$(dirname "$ENV_FILE")"
  touch "$ENV_FILE"
  chmod 0640 "$ENV_FILE" || true
fi

node - "$DVR_FILE" <<'NODE'
const fs = require('fs');

const file = process.argv[2];
let source = fs.readFileSync(file, 'utf8');

if (!source.includes('skipStreams: new Set(')) {
  source = source.replace(
    "    quietLogMs: Math.max(Number(process.env.ONVIF_QUIET_LOG_MS || 120_000), 30_000)\n  };",
    `    quietLogMs: Math.max(Number(process.env.ONVIF_QUIET_LOG_MS || 120_000), 30_000),
    skipStreams: new Set(
      String(process.env.ONVIF_V2_SKIP_STREAMS || process.env.ONVIF_EVENTS_V2_SKIP_STREAMS || '')
        .split(',')
        .map((value) => value.trim())
        .filter(Boolean)
    )
  };`
  );
}

if (!source.includes('let lastSkipLogAt = 0;')) {
  source = source.replace(
    'let running = false;\n',
    'let running = false;\nlet lastSkipLogAt = 0;\n'
  );
}

if (!source.includes('const allCameras = await fetchCameras();')) {
  source = source.replace(
    '    const cameras = await fetchCameras();\n    const ids = new Set(cameras.map((camera) => camera.id));',
    `    const allCameras = await fetchCameras();
    const skippedCameras = allCameras.filter((camera) => config.skipStreams.has(camera.stream_name));
    const cameras = allCameras.filter((camera) => !config.skipStreams.has(camera.stream_name));

    if (skippedCameras.length && Date.now() - lastSkipLogAt > config.quietLogMs) {
      lastSkipLogAt = Date.now();
      console.log('[onvif-events:v2] skipped streams', {
        streams: skippedCameras.map((camera) => camera.stream_name),
        count: skippedCameras.length
      });
    }

    const ids = new Set(cameras.map((camera) => camera.id));`
  );
}

if (!source.includes('skipStreams: Array.from(config.skipStreams)')) {
  source = source.replace(
    '    subscribeTtlMs: config.subscribeTtlMs\n  });',
    `    subscribeTtlMs: config.subscribeTtlMs,
    skipStreams: Array.from(config.skipStreams)
  });`
  );
}

if (!source.includes('skipStreams: new Set(') || !source.includes('const allCameras = await fetchCameras();')) {
  throw new Error('Failed to patch onvifEventsV2.ts; source layout was not recognized');
}

fs.writeFileSync(file, source);
NODE

node - "$ENV_FILE" "$TARGET_STREAM" <<'NODE'
const fs = require('fs');

const file = process.argv[2];
const stream = process.argv[3];
let source = fs.existsSync(file) ? fs.readFileSync(file, 'utf8') : '';

function escapeRegExp(value) {
  return value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

function setCsv(key, value) {
  const re = new RegExp(`^${escapeRegExp(key)}=(.*)$`, 'm');
  const match = source.match(re);
  if (!match) {
    source = `${source.replace(/\s*$/, '')}\n${key}=${value}\n`;
    return;
  }

  const current = match[1]
    .split(',')
    .map((item) => item.trim())
    .filter(Boolean);
  if (!current.includes(value)) current.push(value);
  source = source.replace(re, `${key}=${current.join(',')}`);
}

setCsv('ONVIF_LEGACY_FALLBACK_STREAMS', stream);
setCsv('ONVIF_V2_SKIP_STREAMS', stream);

fs.writeFileSync(file, source);
NODE

echo "Updated event collector env:"
grep -E '^(ONVIF_LEGACY_FALLBACK_STREAMS|ONVIF_V2_SKIP_STREAMS)=' "$ENV_FILE" || true

pushd "$PROJECT_DIR/dvr-engine" >/dev/null
if [[ ! -x node_modules/.bin/tsc ]]; then
  npm ci --include=dev
fi
npm run build
popd >/dev/null

systemctl restart newdomofon-video-dvr.service

echo
curl -fsS -m 5 -i http://127.0.0.1:3010/health | sed -n '1,30p' || true

echo
systemctl status newdomofon-video-dvr.service --no-pager -l | sed -n '1,40p' || true

echo
journalctl -u newdomofon-video-dvr -n 120 --no-pager -l \
  | grep -E "onvif-events:(v2|legacy-fallback)|$TARGET_STREAM|CreatePullPoint|poll failed|stored event" || true

echo
echo "ONVIF events fallback fix applied. Backup: $BACKUP_DIR"
