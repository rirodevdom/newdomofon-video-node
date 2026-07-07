#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="${PROJECT_DIR:-/opt/newdomofon-video}"
ENV_FILE="${ENV_FILE:-/etc/newdomofon-video/app.env}"
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
  curl -fsS -m 8 -i "$url" | sed -n '1,60p' || true
}

need_file "$PROJECT_DIR/backend/package.json"
need_file "$PROJECT_DIR/backend/src/routes/internalOnvifEvents.ts"
need_file "$PROJECT_DIR/backend/src/routes/tokens.ts"
need_file "$PROJECT_DIR/public-events-proxy/server.js"
need_file "$ENV_FILE"

install -d -m 0750 "$BACKUP_DIR"
cp -a "$PROJECT_DIR/backend/src/routes/internalOnvifEvents.ts" "$BACKUP_DIR/internalOnvifEvents.ts.bak"
cp -a "$PROJECT_DIR/backend/src/routes/tokens.ts" "$BACKUP_DIR/tokens.ts.bak"
cp -a "$PROJECT_DIR/public-events-proxy/server.js" "$BACKUP_DIR/public-events-server.js.bak"

append_env_default PUBLIC_EVENTS_INCLUDE_PASSIVE false
append_env_default ONVIF_EVENT_SUPPRESS_REPEATED_STATE true

node - "$PROJECT_DIR/public-events-proxy/server.js" <<'NODE'
const fs = require('fs');

const file = process.argv[2];
let source = fs.readFileSync(file, 'utf8');

function replaceOnce(from, to, label) {
  if (!source.includes(from)) throw new Error(`Could not find ${label}`);
  source = source.replace(from, to);
}

if (!source.includes('PUBLIC_EVENTS_INCLUDE_PASSIVE')) {
  replaceOnce(
    "const MAX_LIMIT = Number(process.env.PUBLIC_EVENTS_MAX_LIMIT || 50000);\n",
    "const MAX_LIMIT = Number(process.env.PUBLIC_EVENTS_MAX_LIMIT || 50000);\nconst INCLUDE_PASSIVE_DEFAULT = flag(process.env.PUBLIC_EVENTS_INCLUDE_PASSIVE, false);\n",
    'public events constants'
  );

  replaceOnce(
    "let discovered = null;\nlet discoveredAt = 0;\n",
    "let discovered = null;\nlet discoveredAt = 0;\n\nfunction flag(value, fallback) {\n  if (value === undefined || value === null || value === '') return fallback;\n  return ['1', 'true', 'yes', 'on'].includes(String(value).trim().toLowerCase());\n}\n",
    'public events flag helper'
  );

  replaceOnce(
    "function deepSearchState(node, depth = 0) {\n",
    "function requestFlag(url, name, fallback) {\n  if (!url.searchParams.has(name)) return fallback;\n  return flag(url.searchParams.get(name), fallback);\n}\n\nfunction deepSearchState(node, depth = 0) {\n",
    'public events request flag helper'
  );

  replaceOnce(
    "async function listEvents(cameraId, streamName, start, end, limit) {\n",
    "function isPassiveSnapshot(item) {\n  if (!item || item.state !== false) return false;\n\n  const type = String(item.event_type || item.type || '').toLowerCase();\n  const rawState = String(item.event_state || '').trim().toLowerCase();\n  const looksLikeStateOnly =\n    /logicalstate|ismotion|motion|relay|digitalinput|trigger/.test(type) ||\n    ['false', '0', 'no', 'off', 'inactive', 'clear', 'idle', 'none', 'end', 'ended'].includes(rawState);\n\n  return looksLikeStateOnly;\n}\n\nfunction filterTimelineItems(items, options = {}) {\n  if (options.includePassive) return items;\n  return items.filter((item) => !isPassiveSnapshot(item));\n}\n\nasync function listEvents(cameraId, streamName, start, end, limit, options = {}) {\n",
    'public events listEvents signature'
  );

  source = source
    .replaceAll("return { meta, items: [] };", "return { meta, items: [], rawCount: 0 };")
    .replace(
      "  return { meta, items };\n}",
      "  return { meta, items: filterTimelineItems(items, options), rawCount: items.length };\n}"
    );

  replaceOnce(
    "        accepted_tokens_file: ACCEPTED_TOKENS_FILE,\n        discovered: discovered || null,\n",
    "        accepted_tokens_file: ACCEPTED_TOKENS_FILE,\n        include_passive_default: INCLUDE_PASSIVE_DEFAULT,\n        discovered: discovered || null,\n",
    'public events health payload'
  );

  replaceOnce(
    "    const { meta, items } = await listEvents(cameraId, streamName, start, end, limit);\n",
    "    const includePassive = requestFlag(url, 'include_passive', INCLUDE_PASSIVE_DEFAULT);\n    const { meta, items, rawCount } = await listEvents(cameraId, streamName, start, end, limit, { includePassive });\n",
    'public events handler call'
  );

  replaceOnce(
    "      count: items.length,\n      meta,\n",
    "      count: items.length,\n      raw_count: rawCount,\n      filtered_count: Math.max(0, rawCount - items.length),\n      include_passive: includePassive,\n      meta,\n",
    'public events response counts'
  );
}

fs.writeFileSync(file, source);
NODE

node - "$PROJECT_DIR/backend/src/routes/internalOnvifEvents.ts" <<'NODE'
const fs = require('fs');

const file = process.argv[2];
let source = fs.readFileSync(file, 'utf8');

function replaceOnce(from, to, label) {
  if (!source.includes(from)) throw new Error(`Could not find ${label}`);
  source = source.replace(from, to);
}

if (!source.includes('ONVIF_EVENT_SUPPRESS_REPEATED_STATE')) {
  replaceOnce(
    "function eventHash(input: {\n  camera_id: string;\n  stream_name: string;\n  event_type: string;\n  event_state: string | null;\n  occurred_at: Date;\n  data: unknown;\n}) {\n  return crypto\n    .createHash('sha256')\n    .update([\n      input.camera_id,\n      input.stream_name,\n      input.event_type,\n      input.event_state ?? '',\n      input.occurred_at.toISOString(),\n      stableJson(input.data)\n    ].join('|'))\n    .digest('hex');\n}\n",
    "function eventHash(input: {\n  camera_id: string;\n  stream_name: string;\n  event_type: string;\n  event_state: string | null;\n  occurred_at: Date;\n  data: unknown;\n}) {\n  return crypto\n    .createHash('sha256')\n    .update([\n      input.camera_id,\n      input.stream_name,\n      input.event_type,\n      input.event_state ?? '',\n      input.occurred_at.toISOString(),\n      stableJson(input.data)\n    ].join('|'))\n    .digest('hex');\n}\n\nfunction envFlag(name: string, fallback: boolean) {\n  const value = process.env[name];\n  if (value === undefined || value === null || value === '') return fallback;\n  return ['1', 'true', 'yes', 'on'].includes(String(value).trim().toLowerCase());\n}\n\nfunction normalizedState(value: string | null | undefined) {\n  if (value === null || value === undefined) return null;\n  const state = String(value).trim().toLowerCase();\n  if (!state) return null;\n\n  if (['true', '1', 'yes', 'on', 'active', 'motion', 'detected', 'start', 'started'].includes(state)) return 'true';\n  if (['false', '0', 'no', 'off', 'inactive', 'clear', 'idle', 'none', 'end', 'ended'].includes(state)) return 'false';\n\n  return state;\n}\n",
    'backend eventHash helper block'
  );

  replaceOnce(
    "  const hash = eventHash({\n",
    "  if (eventState !== null && envFlag('ONVIF_EVENT_SUPPRESS_REPEATED_STATE', true)) {\n    const previous = await query<{ event_state: string | null; occurred_at: Date }>(\n      `SELECT event_state, occurred_at\n         FROM public.camera_events\n        WHERE camera_id = $1::uuid\n          AND stream_name = $2\n          AND event_type = $3\n        ORDER BY occurred_at DESC\n        LIMIT 1`,\n      [body.camera_id, body.stream_name, eventType]\n    );\n\n    const previousState = normalizedState(previous.rows[0]?.event_state);\n    const currentState = normalizedState(eventState);\n    if (previousState !== null && currentState !== null && previousState === currentState) {\n      console.log('[onvif-events] repeated state skipped', {\n        stream_name: body.stream_name,\n        event_type: eventType,\n        event_state: eventState,\n        previous_occurred_at: previous.rows[0]?.occurred_at?.toISOString?.() ?? null,\n        occurred_at: occurredAt.toISOString()\n      });\n\n      return res.status(200).json({ ok: true, inserted: false, skipped: 'repeated_state' });\n    }\n  }\n\n  const hash = eventHash({\n",
    'backend repeated state guard'
  );
}

fs.writeFileSync(file, source);
NODE

node - "$PROJECT_DIR/backend/src/routes/tokens.ts" <<'NODE'
const fs = require('fs');

const file = process.argv[2];
let source = fs.readFileSync(file, 'utf8');
const from = "Buffer.from(String(chunk), typeof encoding === 'string' ? encoding : undefined)";
const to = "Buffer.from(String(chunk), (typeof encoding === 'string' ? encoding : undefined) as BufferEncoding | undefined)";

if (source.includes(from)) {
  source = source.replaceAll(from, to);
}

fs.writeFileSync(file, source);
NODE

node --check "$PROJECT_DIR/public-events-proxy/server.js"

pushd "$PROJECT_DIR/backend" >/dev/null
if [[ -f package-lock.json ]]; then
  npm ci
else
  npm install
fi
npm run build
popd >/dev/null

systemctl restart newdomofon-video-backend.service
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
