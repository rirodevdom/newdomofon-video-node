#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="${PROJECT_DIR:-/opt/newdomofon-video}"
BACKUP_ROOT="${PROJECT_DIR}/backups"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="${BACKUP_ROOT}/v124-public-events-sdk-api-fix-${STAMP}"

log(){ printf '\n===== %s =====\n' "$*"; }
die(){ echo "ERROR: $*" >&2; exit 1; }
backup_file(){
  local f="$1"
  [ -e "$f" ] || return 0
  local dest="${BACKUP_DIR}${f}"
  mkdir -p "$(dirname "$dest")"
  cp -a "$f" "$dest"
  echo "backup: $f"
}

log "Validate project"
[ -d "$PROJECT_DIR" ] || die "PROJECT_DIR not found: $PROJECT_DIR"
mkdir -p "$BACKUP_DIR"

log "Locate public-events proxy"
mapfile -t CANDIDATES < <(
  {
    [ -f "$PROJECT_DIR/public-events-proxy/server.js" ] && echo "$PROJECT_DIR/public-events-proxy/server.js"
    [ -f "$PROJECT_DIR/events-public-proxy/server.js" ] && echo "$PROJECT_DIR/events-public-proxy/server.js"
    [ -f "$PROJECT_DIR/public-events/server.js" ] && echo "$PROJECT_DIR/public-events/server.js"
    grep -Rsl --exclude-dir=node_modules --exclude-dir=dist --exclude-dir=backups \
      -E 'public-events|camera_events|PUBLIC_EVENTS_PORT' "$PROJECT_DIR" 2>/dev/null || true
  } | awk '!seen[$0]++'
)

PUBLIC_EVENTS_JS=""
for f in "${CANDIDATES[@]:-}"; do
  [ -f "$f" ] || continue
  if grep -qE 'camera_events|PUBLIC_EVENTS_PORT|/public-events' "$f"; then
    PUBLIC_EVENTS_JS="$f"
    break
  fi
done

[ -n "$PUBLIC_EVENTS_JS" ] || die "public-events proxy server.js not found"
echo "public-events proxy: $PUBLIC_EVENTS_JS"

log "Backup"
backup_file "$PUBLIC_EVENTS_JS"

log "Install v124 public-events SDK API server"
cat > "$PUBLIC_EVENTS_JS" <<'JS'
'use strict';

const http = require('http');
const fs = require('fs');
const { URL } = require('url');
const { Pool } = require('pg');

const VERSION = 'v124-sdk-events-api';
const PORT = Number(process.env.PUBLIC_EVENTS_PORT || 3057);
const DATABASE_URL = process.env.DATABASE_URL || '';
const RESTREAM_PUBLIC_TOKEN = process.env.RESTREAM_PUBLIC_TOKEN || process.env.VITE_RESTREAM_PUBLIC_TOKEN || '';
const CAMERA_STREAM_MAP_FILE = process.env.CAMERA_STREAM_MAP || '/etc/newdomofon-video/camera-stream-map.json';
const ACCEPTED_TOKENS_FILE = process.env.ACCEPTED_TOKENS_FILE || '/etc/newdomofon-video/restream-accepted-tokens.json';
const REQUIRE_TOKEN = String(process.env.PUBLIC_EVENTS_REQUIRE_TOKEN || 'auto').toLowerCase();
const DEFAULT_LIMIT = Number(process.env.PUBLIC_EVENTS_DEFAULT_LIMIT || 20000);
const MAX_LIMIT = Number(process.env.PUBLIC_EVENTS_MAX_LIMIT || 50000);

const pool = DATABASE_URL ? new Pool({ connectionString: DATABASE_URL }) : null;

let discovered = null;
let discoveredAt = 0;

function readJson(file, fallback) {
  try {
    return JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch (_) {
    return fallback;
  }
}

function cameraMap() {
  const data = readJson(CAMERA_STREAM_MAP_FILE, {});
  return data && typeof data === 'object' ? data : {};
}

function acceptedTokens() {
  const tokens = new Set();

  if (RESTREAM_PUBLIC_TOKEN) tokens.add(RESTREAM_PUBLIC_TOKEN);

  const list = readJson(ACCEPTED_TOKENS_FILE, []);
  if (Array.isArray(list)) {
    for (const item of list) {
      const token = String(item || '').trim();
      if (token) tokens.add(token);
    }
  } else if (list && typeof list === 'object') {
    for (const value of Object.values(list)) {
      if (Array.isArray(value)) {
        for (const item of value) {
          const token = String(item || '').trim();
          if (token) tokens.add(token);
        }
      } else {
        const token = String(value || '').trim();
        if (token) tokens.add(token);
      }
    }
  }

  return tokens;
}

function tokenRequired(tokens) {
  if (REQUIRE_TOKEN === '0' || REQUIRE_TOKEN === 'false' || REQUIRE_TOKEN === 'no') return false;
  if (REQUIRE_TOKEN === '1' || REQUIRE_TOKEN === 'true' || REQUIRE_TOKEN === 'yes') return true;
  return tokens.size > 0;
}

function sendJson(res, status, payload, extraHeaders = {}) {
  const body = JSON.stringify(payload);
  res.writeHead(status, {
    'content-type': 'application/json; charset=utf-8',
    'cache-control': 'no-store',
    'access-control-allow-origin': '*',
    'access-control-allow-methods': 'GET,HEAD,OPTIONS',
    'access-control-allow-headers': '*',
    'access-control-expose-headers': 'X-Newdomofon-Public-Events',
    'x-newdomofon-public-events': VERSION,
    ...extraHeaders,
  });
  res.end(body);
}

function qident(value) {
  return '"' + String(value).replace(/"/g, '""') + '"';
}

function pick(columns, names) {
  const lower = new Map(columns.map((c) => [String(c.name || c.column_name || c).toLowerCase(), c]));
  for (const name of names) {
    const hit = lower.get(String(name).toLowerCase());
    if (hit) return hit.name || hit.column_name || hit;
  }
  return null;
}

function normalizeDate(value) {
  const d = new Date(String(value || ''));
  return Number.isFinite(d.getTime()) ? d : null;
}

function clampWindow(start, end) {
  const now = Date.now();
  let s = normalizeDate(start);
  let e = normalizeDate(end);

  if (!s || !e) {
    e = new Date(now);
    s = new Date(now - 60 * 60 * 1000);
  }

  if (e.getTime() < s.getTime()) {
    const tmp = s;
    s = e;
    e = tmp;
  }

  const maxMs = 31 * 24 * 60 * 60 * 1000;
  if (e.getTime() - s.getTime() > maxMs) {
    s = new Date(e.getTime() - maxMs);
  }

  return { start: s, end: e };
}

function parseLimit(value) {
  const n = Number(value);
  if (!Number.isFinite(n) || n <= 0) return Math.min(DEFAULT_LIMIT, MAX_LIMIT);
  return Math.max(1, Math.min(MAX_LIMIT, Math.floor(n)));
}

function asBool(value) {
  if (value === true || value === false) return value;
  if (typeof value === 'number') {
    if (value === 1) return true;
    if (value === 0) return false;
  }

  const s = String(value == null ? '' : value).trim().toLowerCase();
  if (!s) return null;

  if (['true', '1', 'yes', 'on', 'active', 'motion', 'detected', 'start', 'started'].includes(s)) return true;
  if (['false', '0', 'no', 'off', 'inactive', 'clear', 'idle', 'none', 'end', 'ended'].includes(s)) return false;

  return null;
}

function deepSearchState(node, depth = 0) {
  if (!node || depth > 8) return null;

  if (Array.isArray(node)) {
    for (const item of node) {
      const hit = deepSearchState(item, depth + 1);
      if (hit !== null) return hit;
    }
    return null;
  }

  if (typeof node !== 'object') return asBool(node);

  const preferredKeys = [
    'IsMotion',
    'is_motion',
    'event_state',
    'state',
    'motion',
    'active',
    'Value',
    'value',
    'SimpleItem',
    'simpleItem',
  ];

  for (const key of preferredKeys) {
    if (Object.prototype.hasOwnProperty.call(node, key)) {
      const direct = asBool(node[key]);
      if (direct !== null) return direct;
      const nested = deepSearchState(node[key], depth + 1);
      if (nested !== null) return nested;
    }
  }

  for (const [key, value] of Object.entries(node)) {
    if (/ismotion|motion|state|active|value/i.test(key)) {
      const direct = asBool(value);
      if (direct !== null) return direct;
      const nested = deepSearchState(value, depth + 1);
      if (nested !== null) return nested;
    }
  }

  return null;
}

function dataSimpleObject(data) {
  const out = {};

  function add(name, value) {
    if (name != null && value != null) out[String(name)] = value;
  }

  function scan(node, depth = 0) {
    if (!node || depth > 8) return;

    if (Array.isArray(node)) {
      for (const item of node) scan(item, depth + 1);
      return;
    }

    if (typeof node !== 'object') return;

    if (node.$ && (node.$.Name != null || node.$.name != null)) {
      add(node.$.Name ?? node.$.name, node.$.Value ?? node.$.value);
    }

    if (node.Name != null || node.name != null) {
      add(node.Name ?? node.name, node.Value ?? node.value);
    }

    for (const value of Object.values(node)) scan(value, depth + 1);
  }

  scan(data);
  return out;
}

async function discoverEventsTable() {
  const now = Date.now();
  if (discovered && now - discoveredAt < 60_000) return discovered;

  if (!pool) {
    discovered = { ok: false, reason: 'DATABASE_URL is not configured' };
    discoveredAt = now;
    return discovered;
  }

  const sql = `
    select table_schema, table_name, column_name, data_type, udt_name, ordinal_position
    from information_schema.columns
    where table_schema not in ('pg_catalog', 'information_schema')
      and (
        table_name ilike '%event%'
        or table_name ilike '%motion%'
        or table_name ilike '%detect%'
      )
    order by table_schema, table_name, ordinal_position
  `;

  const result = await pool.query(sql);
  const grouped = new Map();

  for (const row of result.rows) {
    const key = `${row.table_schema}.${row.table_name}`;
    if (!grouped.has(key)) grouped.set(key, { schema: row.table_schema, table: row.table_name, columns: [] });
    grouped.get(key).columns.push({ name: row.column_name, data_type: row.data_type, udt_name: row.udt_name });
  }

  const priority = [
    'public.camera_events',
    'camera_events',
    'public.camera_event',
    'camera_event',
    'public.events',
    'events',
    'public.dvr_events',
    'dvr_events',
    'public.video_events',
    'video_events',
    'public.motion_events',
    'motion_events',
    'public.detections',
    'detections',
  ];

  const candidates = Array.from(grouped.values()).map((entry) => {
    const columns = entry.columns;
    const names = columns.map((c) => c.name);
    const timeCol = pick(columns, ['occurred_at', 'event_time', 'detected_at', 'created_at', 'timestamp', 'ts', 'time']);
    const cameraCol = pick(columns, ['camera_id', 'camera_uuid', 'camera', 'cameraid']);
    const streamCol = pick(columns, ['stream_name', 'stream', 'channel', 'channel_name']);
    const typeCol = pick(columns, ['event_type', 'type', 'kind', 'name', 'topic']);
    const stateCol = pick(columns, ['event_state', 'state', 'status', 'value', 'is_motion', 'motion']);
    const idCol = pick(columns, ['id', 'event_id']);
    const titleCol = pick(columns, ['title', 'message', 'description', 'label']);
    const dataCol = pick(columns, ['data', 'payload', 'raw', 'metadata', 'details']);
    const hashCol = pick(columns, ['event_hash', 'hash']);
    const createdCol = pick(columns, ['created_at', 'inserted_at']);

    let score = 0;
    if (timeCol) score += 8;
    if (cameraCol) score += 5;
    if (streamCol) score += 5;
    if (typeCol) score += 2;
    if (stateCol) score += 4;
    if (dataCol) score += 2;

    const full = `${entry.schema}.${entry.table}`;
    const p = priority.findIndex((x) => x === full || x === entry.table);
    if (p >= 0) score += 50 - p;

    return {
      schema: entry.schema,
      table: entry.table,
      full,
      columns: names,
      timeCol,
      cameraCol,
      streamCol,
      typeCol,
      stateCol,
      idCol,
      titleCol,
      dataCol,
      hashCol,
      createdCol,
      score,
    };
  })
    .filter((c) => c.timeCol && (c.cameraCol || c.streamCol))
    .sort((a, b) => b.score - a.score);

  discovered = candidates[0] || {
    ok: false,
    reason: 'No compatible event table found',
    tables: Array.from(grouped.values()).map((x) => `${x.schema}.${x.table}`),
  };

  discoveredAt = now;
  return discovered;
}

function rowToEvent(row, cameraId, streamName) {
  const data = row.data && typeof row.data === 'object' ? row.data : {};
  const simple = dataSimpleObject(data);
  const state = asBool(row.event_state) ?? deepSearchState(data);
  const occurred = new Date(row.occurred_at);

  const eventType = row.event_type || row.type || row.topic || 'event';
  const title = row.title || eventType || 'event';

  const item = {
    id: row.id || row.event_hash || `${row.camera_id || cameraId || row.stream_name || streamName}-${occurred.toISOString()}`,
    camera_id: row.camera_id || cameraId || null,
    stream_name: row.stream_name || streamName || null,
    occurred_at: occurred.toISOString(),
    event_type: eventType,
    type: eventType,
    title,
    event_state: state === null ? (row.event_state == null ? null : String(row.event_state)) : (state ? 'true' : 'false'),
    state,
    IsMotion: state,
    is_motion: state,
    motion_state: state === null ? null : (state ? 'start' : 'end'),
    source: simple.VideoSourceConfigurationToken || simple.Source || simple.source || null,
    rule: simple.Rule || simple.rule || null,
    video_source: simple.VideoSourceConfigurationToken || null,
    analytics_token: simple.VideoAnalyticsConfigurationToken || null,
    simple,
    raw: data,
  };

  return item;
}

async function listEvents(cameraId, streamName, start, end, limit) {
  const meta = await discoverEventsTable();

  if (!meta || !meta.table) {
    return { meta, items: [] };
  }

  const values = [start.toISOString(), end.toISOString()];
  const where = [
    `${qident(meta.timeCol)} >= $1::timestamptz`,
    `${qident(meta.timeCol)} <= $2::timestamptz`,
  ];

  const identityParts = [];
  if (meta.cameraCol && cameraId) {
    values.push(cameraId);
    identityParts.push(`${qident(meta.cameraCol)}::text = $${values.length}`);
  }
  if (meta.streamCol && streamName) {
    values.push(streamName);
    identityParts.push(`${qident(meta.streamCol)}::text = $${values.length}`);
  }

  if (!identityParts.length) {
    return { meta, items: [] };
  }

  where.push(`(${identityParts.join(' OR ')})`);

  values.push(limit);
  const limitParam = `$${values.length}`;

  const cols = [
    meta.idCol ? `${qident(meta.idCol)}::text as id` : `NULL::text as id`,
    meta.hashCol ? `${qident(meta.hashCol)}::text as event_hash` : `NULL::text as event_hash`,
    meta.cameraCol ? `${qident(meta.cameraCol)}::text as camera_id` : `NULL::text as camera_id`,
    meta.streamCol ? `${qident(meta.streamCol)}::text as stream_name` : `NULL::text as stream_name`,
    `${qident(meta.timeCol)} as occurred_at`,
    meta.typeCol ? `${qident(meta.typeCol)}::text as event_type` : `'event'::text as event_type`,
    meta.stateCol ? `${qident(meta.stateCol)}::text as event_state` : `NULL::text as event_state`,
    meta.titleCol ? `${qident(meta.titleCol)}::text as title` : `NULL::text as title`,
    meta.dataCol ? `${qident(meta.dataCol)} as data` : `'{}'::jsonb as data`,
    meta.createdCol ? `${qident(meta.createdCol)} as created_at` : `NULL::timestamptz as created_at`,
  ];

  const sql = `
    select ${cols.join(', ')}
    from ${qident(meta.schema)}.${qident(meta.table)}
    where ${where.join(' AND ')}
    order by ${qident(meta.timeCol)} asc
    limit ${limitParam}
  `;

  const result = await pool.query(sql, values);
  const items = result.rows
    .filter((row) => Number.isFinite(new Date(row.occurred_at).getTime()))
    .map((row) => rowToEvent(row, cameraId, streamName));

  return { meta, items };
}

function tokenFromRequest(url, req) {
  const explicit = url.searchParams.get('token') || '';
  if (explicit) return explicit;

  const auth = req.headers.authorization || '';
  const m = /^Bearer\s+(.+)$/i.exec(auth);
  return m ? m[1] : '';
}

function resolveRequestIdentity(url, pathCameraId) {
  const queryCamera =
    url.searchParams.get('camera_id') ||
    url.searchParams.get('cameraId') ||
    url.searchParams.get('camera') ||
    '';

  const cameraId = decodeURIComponent(pathCameraId || queryCamera || '').trim();

  const queryStream =
    url.searchParams.get('stream') ||
    url.searchParams.get('stream_name') ||
    url.searchParams.get('streamName') ||
    url.searchParams.get('channel') ||
    '';

  const map = cameraMap();
  const streamName = String(queryStream || map[cameraId] || cameraId || '').trim();

  return { cameraId, streamName, map };
}

async function handle(req, res) {
  try {
    const url = new URL(req.url, `http://${req.headers.host || '127.0.0.1'}`);

    if (req.method === 'OPTIONS') {
      return sendJson(res, 200, { ok: true, version: VERSION });
    }

    if (url.pathname === '/health' || url.pathname === '/public-events/health') {
      const tokens = acceptedTokens();
      return sendJson(res, 200, {
        ok: true,
        service: 'newdomofon-public-events-proxy',
        version: VERSION,
        port: PORT,
        database_configured: Boolean(DATABASE_URL),
        token_count: tokens.size,
        require_token: tokenRequired(tokens),
        camera_map: CAMERA_STREAM_MAP_FILE,
        accepted_tokens_file: ACCEPTED_TOKENS_FILE,
        discovered: discovered || null,
      });
    }

    const matchPath = /^\/public-events\/([^/]+)\/events$/.exec(url.pathname);
    const matchQuery = url.pathname === '/public-events/events' || url.pathname === '/events';

    if (!matchPath && !matchQuery) {
      return sendJson(res, 404, { ok: false, error: 'Not found' });
    }

    const tokens = acceptedTokens();
    const token = tokenFromRequest(url, req);
    if (tokenRequired(tokens) && !tokens.has(token)) {
      return sendJson(res, 401, {
        ok: false,
        error: 'Invalid public events token',
        version: VERSION,
        token_count: tokens.size,
      });
    }

    const { cameraId, streamName } = resolveRequestIdentity(url, matchPath ? matchPath[1] : '');
    if (!cameraId && !streamName) {
      return sendJson(res, 400, { ok: false, error: 'camera_id or stream is required' });
    }

    const { start, end } = clampWindow(url.searchParams.get('start'), url.searchParams.get('end'));
    const limit = parseLimit(url.searchParams.get('limit'));
    const { meta, items } = await listEvents(cameraId, streamName, start, end, limit);

    return sendJson(res, 200, {
      ok: true,
      source: VERSION,
      camera_id: cameraId || null,
      stream_name: streamName || null,
      start: start.toISOString(),
      end: end.toISOString(),
      limit,
      count: items.length,
      meta,
      items,
      events: items,
    });
  } catch (error) {
    console.error('[public-events-v124]', error);
    return sendJson(res, 500, {
      ok: false,
      error: error.message || String(error),
      source: VERSION,
    });
  }
}

const server = http.createServer(handle);

server.listen(PORT, '127.0.0.1', () => {
  console.log(`[public-events-v124] listening on 127.0.0.1:${PORT}`);
});
JS

log "Syntax check"
node --check "$PUBLIC_EVENTS_JS"

log "Restart public-events services"
systemctl daemon-reload || true
for svc in newdomofon-events-public-proxy.service newdomofon-public-events-proxy.service; do
  if systemctl list-unit-files "$svc" --no-pager --no-legend 2>/dev/null | grep -q "$svc"; then
    echo "restart: $svc"
    systemctl restart "$svc"
  fi
done

log "Status"
for svc in newdomofon-events-public-proxy.service newdomofon-public-events-proxy.service; do
  if systemctl list-units --all "$svc" --no-pager --no-legend 2>/dev/null | grep -q "$svc"; then
    systemctl status "$svc" --no-pager -l || true
  fi
done

cat <<EOF

installed:
  $PUBLIC_EVENTS_JS

backup:
  $BACKUP_DIR

Checks:
  curl -k 'https://new-video.domofon-37.ru/public-events/health' | jq .

  curl -k 'https://new-video.domofon-37.ru/public-events/f0486587-8a79-4cc2-b257-0671f874c08b/events?start=2026-06-11T10:00:00Z&end=2026-06-11T11:00:00Z&stream=cam_10_130_1_219&limit=20&token=TOKEN' \\
    | jq '{ok, count, source, first: .items[0]}'

Expected item fields for player-kit:
  occurred_at
  event_type
  title
  event_state
  state
  IsMotion
  is_motion
EOF
