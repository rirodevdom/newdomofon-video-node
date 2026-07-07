#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="${PROJECT_DIR:-/opt/newdomofon-video}"
ENV_FILE="${ENV_FILE:-/etc/newdomofon-video/app.env}"
TARGET_STREAM="${TARGET_STREAM:-${TEST_STREAM:-onvif2}}"
RAW_BASE="${RAW_BASE:-https://raw.githubusercontent.com/rirodevdom/newdomofon-video/main}"
DVR_FILE="$PROJECT_DIR/dvr-engine/src/onvifEventsV2.ts"
LEGACY_FILE="$PROJECT_DIR/dvr-engine/src/onvifEventsLegacyFallback.ts"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="$PROJECT_DIR/backups/onvif-events-fallback-fix-v2-$STAMP"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run as root: sudo bash scripts/apply-onvif-events-fallback-fix-v2.sh" >&2
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
if [[ -f "$LEGACY_FILE" ]]; then
  cp -a "$LEGACY_FILE" "$BACKUP_DIR/onvifEventsLegacyFallback.ts.bak"
fi
if [[ -f "$ENV_FILE" ]]; then
  cp -a "$ENV_FILE" "$BACKUP_DIR/app.env.bak"
else
  install -d -m 0750 "$(dirname "$ENV_FILE")"
  touch "$ENV_FILE"
  chmod 0640 "$ENV_FILE" || true
fi

if command -v curl >/dev/null 2>&1; then
  echo "Updating ONVIF event collectors from $RAW_BASE"
  curl -fsSL "$RAW_BASE/dvr-engine/src/onvifEventsV2.ts?$(date +%s)" -o "$DVR_FILE"
  curl -fsSL "$RAW_BASE/dvr-engine/src/onvifEventsLegacyFallback.ts?$(date +%s)" -o "$LEGACY_FILE"
fi

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

function setValue(key, value) {
  const re = new RegExp(`^${escapeRegExp(key)}=.*$`, 'm');
  if (re.test(source)) {
    source = source.replace(re, `${key}=${value}`);
    return;
  }
  source = `${source.replace(/\s*$/, '')}\n${key}=${value}\n`;
}

function deleteValue(key) {
  const re = new RegExp(`^${escapeRegExp(key)}=.*\\n?`, 'm');
  source = source.replace(re, '');
}

setCsv('ONVIF_LEGACY_FALLBACK_STREAMS', stream);
setCsv('ONVIF_V2_SKIP_STREAMS', stream);
setValue('ONVIF_LEGACY_IGNORE_INITIALIZED', 'true');
setValue('ONVIF_LEGACY_INITIALIZED_STATE_EVENTS', 'true');
setValue('ONVIF_LEGACY_SESSION_TTL_MS', process.env.ONVIF_LEGACY_SESSION_TTL_MS || '0');
deleteValue('ONVIF_LEGACY_RECONNECT_MS');

fs.writeFileSync(file, source);
NODE

echo "Updated event collector env:"
grep -E '^(ONVIF_LEGACY_FALLBACK_STREAMS|ONVIF_V2_SKIP_STREAMS|ONVIF_LEGACY_IGNORE_INITIALIZED|ONVIF_LEGACY_INITIALIZED_STATE_EVENTS|ONVIF_LEGACY_SESSION_TTL_MS|ONVIF_LEGACY_RECONNECT_MS)=' "$ENV_FILE" || true

pushd "$PROJECT_DIR/dvr-engine" >/dev/null
echo "Installing DVR build dependencies with dev packages..."
export NODE_ENV=
export NPM_CONFIG_PRODUCTION=false
if [[ -f package-lock.json ]]; then
  npm ci --include=dev || npm install --include=dev
else
  npm install --include=dev
fi

if [[ ! -x ./node_modules/.bin/tsc ]]; then
  echo "typescript compiler is still missing: ./node_modules/.bin/tsc" >&2
  exit 4
fi

./node_modules/.bin/tsc --version
npm run build
popd >/dev/null

systemctl restart newdomofon-video-dvr.service

echo
curl -fsS -m 5 -i http://127.0.0.1:3010/health | sed -n '1,30p' || true

echo
systemctl status newdomofon-video-dvr.service --no-pager -l | sed -n '1,40p' || true

echo
journalctl -u newdomofon-video-dvr -n 180 --no-pager -l \
  | grep -E "onvif-events:(v2|legacy-fallback)|$TARGET_STREAM|CreatePullPoint|poll failed|stored event|ignored initialized" || true

echo
echo "ONVIF events fallback fix v2 applied. Backup: $BACKUP_DIR"
