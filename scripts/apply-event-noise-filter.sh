#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="${PROJECT_DIR:-/opt/newdomofon-video}"
ENV_FILE="${ENV_FILE:-/etc/newdomofon-video/app.env}"
CAMERA_STREAM_MAP_FILE="${CAMERA_STREAM_MAP_FILE:-/etc/newdomofon-video/camera-stream-map.json}"
RAW_BASE="${RAW_BASE:-https://raw.githubusercontent.com/rirodevdom/newdomofon-video/main}"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="$PROJECT_DIR/backups/event-noise-filter-$STAMP"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run as root: sudo PROJECT_DIR=$PROJECT_DIR bash scripts/apply-event-noise-filter.sh" >&2
  exit 1
fi

need_file() {
  if [[ ! -e "$1" ]]; then
    echo "Missing required path: $1" >&2
    exit 2
  fi
}

append_env_default() {
  local key="$1"
  local value="$2"
  if [[ ! -f "$ENV_FILE" ]] || ! grep -qE "^${key}=" "$ENV_FILE"; then
    install -d -m 0750 "$(dirname "$ENV_FILE")"
    printf '%s=%s\n' "$key" "$value" >>"$ENV_FILE"
  fi
}

smoke() {
  local name="$1"
  local url="$2"
  echo
  echo "== $name =="
  curl -fsS -m 8 -i "$url" | sed -n '1,80p' || true
}

need_file "$PROJECT_DIR/backend/package.json"
need_file "$PROJECT_DIR/public-events-proxy/server.js"
need_file "$ENV_FILE"

install -d -m 0750 "$BACKUP_DIR"
cp -a "$PROJECT_DIR/public-events-proxy/server.js" "$BACKUP_DIR/public-events-server.js.bak"
if [[ -f "$PROJECT_DIR/backend/src/routes/tokens.ts" ]]; then
  cp -a "$PROJECT_DIR/backend/src/routes/tokens.ts" "$BACKUP_DIR/tokens.ts.bak"
fi
if [[ -f "$CAMERA_STREAM_MAP_FILE" ]]; then
  cp -a "$CAMERA_STREAM_MAP_FILE" "$BACKUP_DIR/camera-stream-map.json.bak"
fi

append_env_default PUBLIC_EVENTS_INCLUDE_PASSIVE false
append_env_default ONVIF_EVENT_SUPPRESS_REPEATED_STATE true

mkdir -p "$PROJECT_DIR/public-events-proxy"
echo "Updating public-events proxy source from $RAW_BASE"
curl -fsSL "$RAW_BASE/public-events-proxy/server.js?$(date +%s)" \
  -o "$PROJECT_DIR/public-events-proxy/server.js"
node --check "$PROJECT_DIR/public-events-proxy/server.js"

mkdir -p "$PROJECT_DIR/backend/src/types"
cat >"$PROJECT_DIR/backend/src/types/bufferEncodingCompat.d.ts" <<'EOF'
declare global {
  interface BufferConstructor {
    from(string: string, encoding: string | undefined): Buffer;
  }
}

export {};
EOF

if [[ -n "${TEST_CAMERA_ID:-}" && -n "${TEST_STREAM:-}" ]]; then
  install -d -m 0750 "$(dirname "$CAMERA_STREAM_MAP_FILE")"
  node - "$CAMERA_STREAM_MAP_FILE" "$TEST_CAMERA_ID" "$TEST_STREAM" <<'NODE'
const fs = require('fs');
const [file, cameraId, stream] = process.argv.slice(2);
let map = {};
try { map = JSON.parse(fs.readFileSync(file, 'utf8')); } catch {}
if (cameraId && stream) map[String(cameraId)] = String(stream);
fs.writeFileSync(file, JSON.stringify(map, null, 2) + '\n');
NODE
fi

if [[ -f "$CAMERA_STREAM_MAP_FILE" ]]; then
  chgrp newdomofon "$(dirname "$CAMERA_STREAM_MAP_FILE")" "$CAMERA_STREAM_MAP_FILE" 2>/dev/null || true
  chmod 0750 "$(dirname "$CAMERA_STREAM_MAP_FILE")" 2>/dev/null || true
  chmod 0640 "$CAMERA_STREAM_MAP_FILE" 2>/dev/null || true
fi

pushd "$PROJECT_DIR/backend" >/dev/null
if [[ -f package-lock.json ]]; then
  npm ci --include=dev
else
  npm install --include=dev
fi
npm run build
popd >/dev/null

systemctl restart newdomofon-video-backend.service || true
systemctl restart newdomofon-public-events-proxy.service

smoke "backend" "http://127.0.0.1:3000/api/health"
smoke "public-events-proxy" "http://127.0.0.1:3057/health"

if [[ -n "${TEST_CAMERA_ID:-}" && -n "${TEST_STREAM:-}" ]]; then
  token_query=""
  if [[ -n "${TEST_TOKEN:-}" ]]; then
    token_query="&token=${TEST_TOKEN}"
  fi

  smoke "public events filtered" \
    "http://127.0.0.1:3057/public-events/${TEST_CAMERA_ID}/events?stream=${TEST_STREAM}&limit=20${token_query}"

  smoke "public events with passive" \
    "http://127.0.0.1:3057/public-events/${TEST_CAMERA_ID}/events?stream=${TEST_STREAM}&limit=20&include_passive=1${token_query}"
fi

echo
echo "Event noise filter applied. Backup: $BACKUP_DIR"
