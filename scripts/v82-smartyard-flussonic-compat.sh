#!/usr/bin/env bash
set -Eeuo pipefail

# NewDomofon Video: v82 SmartYard / Flussonic-compatible DVR gateway
#
# Goal:
#   Make the public DVR base URL accepted by SmartYard-Server / SmartYard-Vue:
#
#     https://DOMAIN/<stream>/index.m3u8?token=TOKEN
#     https://DOMAIN/<stream>/recording_status.json?from=...&token=TOKEN
#     https://DOMAIN/<stream>/archive-<unix_from>-<duration>.mp4?token=TOKEN
#     https://DOMAIN/<stream>/<unix>-preview.mp4?token=TOKEN
#     https://DOMAIN/<stream>/preview.mp4?token=TOKEN
#
# Why:
#   SmartYard uses the Flussonic branch by default for archive ranges and calls
#   /recording_status.json on the camera base URL. Earlier NewDomofon routes served
#   live HLS, but did not expose a true Flussonic-like ranges endpoint at /<stream>/.
#
# Safety:
#   - Does not modify PostgreSQL.
#   - Does not modify dvr-engine.
#   - Does not rebuild frontend.
#   - Adds an isolated local gateway service on 127.0.0.1:3082 and nginx routes.
#   - Replaces old public-media nginx snippet includes with v82 routes only.
#
# Usage:
#   sudo PROJECT_DIR=/opt/newdomofon-video \
#     SITE_URL=https://new-video.domofon-37.ru \
#     SMARTYARD_AUTH_TOKEN='1qaz!QAZ' \
#     bash scripts/v82-smartyard-flussonic-compat.sh

PROJECT_DIR="${PROJECT_DIR:-/opt/newdomofon-video}"
SITE_URL="${SITE_URL:-https://new-video.domofon-37.ru}"
ENV_FILE="${ENV_FILE:-/etc/newdomofon-video/app.env}"
BACKEND_ENV="${BACKEND_ENV:-$PROJECT_DIR/backend/.env}"
FRONTEND_ENV="${FRONTEND_ENV:-$PROJECT_DIR/frontend/.env.production}"
SERVICE_NAME="${SERVICE_NAME:-newdomofon-smartyard-compat}"
SERVICE_DIR="${SERVICE_DIR:-$PROJECT_DIR/smartyard-compat-proxy}"
SERVICE_PORT="${SERVICE_PORT:-3082}"
SERVICE_HOST="${SERVICE_HOST:-127.0.0.1}"
DVR_ENGINE_URL="${DVR_ENGINE_URL:-http://127.0.0.1:3010}"
DVR_ROOTS="${DVR_ROOTS:-/var/lib/newdomofon-video/dvr,/var/dvr}"
CAMERA_STREAM_MAP="${CAMERA_STREAM_MAP:-/etc/newdomofon-video/camera-stream-map.json}"
STREAM_ALIASES_FILE="${STREAM_ALIASES_FILE:-/etc/newdomofon-video/stream-aliases.json}"
ACCEPTED_TOKENS_FILE="${ACCEPTED_TOKENS_FILE:-/etc/newdomofon-video/restream-accepted-tokens.json}"
SMARTYARD_AUTH_TOKEN="${SMARTYARD_AUTH_TOKEN:-1qaz!QAZ}"
EXTRA_RESTREAM_PUBLIC_TOKENS="${EXTRA_RESTREAM_PUBLIC_TOKENS:-}"
PREVIEW_FALLBACK_MP4="${PREVIEW_FALLBACK_MP4:-/var/lib/newdomofon-video/smartyard-preview-v82.mp4}"
SNIPPET="${SNIPPET:-/etc/nginx/snippets/newdomofon-v82-smartyard-flussonic-compat.conf}"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run as root with sudo." >&2
  exit 1
fi

for c in node python3 nginx systemctl curl grep awk sed find sort; do
  command -v "$c" >/dev/null || { echo "$c not found" >&2; exit 1; }
done

[[ -d "$PROJECT_DIR" ]] || { echo "PROJECT_DIR not found: $PROJECT_DIR" >&2; exit 1; }
[[ -s "$CAMERA_STREAM_MAP" ]] || { echo "camera stream map not found: $CAMERA_STREAM_MAP" >&2; exit 1; }

TS="$(date +%Y%m%d-%H%M%S)"
BACKUP="$PROJECT_DIR/backups/v82-smartyard-flussonic-compat-$TS"
mkdir -p "$BACKUP"

backup() {
  [[ -e "$1" ]] || return 0
  mkdir -p "$BACKUP/$(dirname "${1#/}")"
  cp -a "$1" "$BACKUP/${1#/}"
  echo "backup: $1"
}

read_env_value() {
  local file="$1"
  local key="$2"
  [[ -f "$file" ]] || return 0
  grep -E "^${key}=" "$file" | tail -1 | cut -d= -f2- || true
}

set_env_value() {
  local file="$1"
  local key="$2"
  local value="$3"
  install -d -m 0755 "$(dirname "$file")"
  touch "$file"
  if grep -qE "^${key}=" "$file"; then
    sed -i -E "s#^${key}=.*#${key}=${value}#" "$file"
  else
    printf '%s=%s\n' "$key" "$value" >> "$file"
  fi
}

echo "===== Backup ====="
backup "$ENV_FILE"
backup "$BACKEND_ENV"
backup "$FRONTEND_ENV"
backup "$ACCEPTED_TOKENS_FILE"
backup "$STREAM_ALIASES_FILE"
backup "$SERVICE_DIR/server.js"
backup "$SERVICE_FILE"
backup "$SNIPPET"
for f in /etc/nginx/sites-enabled/*.conf /etc/nginx/conf.d/*.conf; do
  [[ -f "$f" ]] && backup "$f"
done

echo
echo "===== Resolve tokens ====="
PRIMARY_TOKEN="${RESTREAM_PUBLIC_TOKEN:-}"
[[ -z "$PRIMARY_TOKEN" ]] && PRIMARY_TOKEN="$(read_env_value "$ENV_FILE" RESTREAM_PUBLIC_TOKEN)"
[[ -z "$PRIMARY_TOKEN" ]] && PRIMARY_TOKEN="$(read_env_value "$BACKEND_ENV" RESTREAM_PUBLIC_TOKEN)"
[[ -z "$PRIMARY_TOKEN" ]] && PRIMARY_TOKEN="$(read_env_value "$FRONTEND_ENV" VITE_RESTREAM_PUBLIC_TOKEN)"
PRIMARY_TOKEN="${PRIMARY_TOKEN:-}"

if [[ -n "$PRIMARY_TOKEN" ]]; then
  set_env_value "$ENV_FILE" RESTREAM_PUBLIC_TOKEN "$PRIMARY_TOKEN"
  echo "primary token prefix: ${PRIMARY_TOKEN:0:8}"
else
  echo "WARNING: RESTREAM_PUBLIC_TOKEN not found; SmartYard token and existing accepted tokens will still work."
fi

install -d -m 0755 "$(dirname "$ACCEPTED_TOKENS_FILE")"
python3 - "$PRIMARY_TOKEN" "$SMARTYARD_AUTH_TOKEN" "$EXTRA_RESTREAM_PUBLIC_TOKENS" "$ACCEPTED_TOKENS_FILE" <<'PY'
import json
import pathlib
import sys

primary = sys.argv[1].strip()
smartyard = sys.argv[2].strip()
extra = sys.argv[3].strip()
out = pathlib.Path(sys.argv[4])

tokens = []
for value in [primary, smartyard, *extra.replace(',', ' ').split()]:
    value = str(value).strip()
    if value and value not in tokens:
        tokens.append(value)

if out.exists():
    try:
        old = json.loads(out.read_text())
        if isinstance(old, list):
            for value in old:
                value = str(value).strip()
                if value and value not in tokens:
                    tokens.append(value)
    except Exception:
        pass

out.write_text(json.dumps(tokens, ensure_ascii=False, indent=2) + '\n')
print('accepted tokens count:', len(tokens))
for value in tokens:
    print(' -', value[:8] + ('...' if len(value) > 8 else ''))
PY

echo
echo "===== Ensure stream aliases file exists ====="
install -d -m 0755 "$(dirname "$STREAM_ALIASES_FILE")"
if [[ ! -s "$STREAM_ALIASES_FILE" ]]; then
  python3 - "$CAMERA_STREAM_MAP" "$STREAM_ALIASES_FILE" <<'PY'
import json
import pathlib
import sys

camera_map = json.loads(pathlib.Path(sys.argv[1]).read_text())
out = pathlib.Path(sys.argv[2])
streams = list(dict.fromkeys(str(v).strip() for v in camera_map.values() if str(v).strip()))
aliases = {f'cam{i}': stream for i, stream in enumerate(streams, 1)}
out.write_text(json.dumps(aliases, ensure_ascii=False, separators=(',', ':')) + '\n')
print(json.dumps(aliases, ensure_ascii=False, indent=2))
PY
else
  cat "$STREAM_ALIASES_FILE"
fi

echo
echo "===== Create fallback preview mp4 ====="
install -d -m 0755 "$(dirname "$PREVIEW_FALLBACK_MP4")"
if command -v ffmpeg >/dev/null; then
  if ! ffmpeg -hide_banner -loglevel error -y \
    -f lavfi -i "color=c=black:s=320x180:r=1:d=1" \
    -an -c:v libx264 -pix_fmt yuv420p -movflags +faststart \
    "$PREVIEW_FALLBACK_MP4" >/dev/null 2>&1; then
    echo "WARNING: ffmpeg failed to create fallback preview; preview route will return 204 if no file exists."
    rm -f "$PREVIEW_FALLBACK_MP4"
  else
    chmod 0644 "$PREVIEW_FALLBACK_MP4"
    echo "preview fallback: $PREVIEW_FALLBACK_MP4"
  fi
else
  echo "WARNING: ffmpeg not found; preview route will return 204 if no fallback file exists."
fi

echo
echo "===== Write SmartYard compatibility service ====="
install -d -o root -g root -m 0755 "$SERVICE_DIR"
cat > "$SERVICE_DIR/server.js" <<'NODE'
'use strict';

const http = require('node:http');
const fs = require('node:fs');
const fsp = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const { spawn } = require('node:child_process');
const { URL } = require('node:url');

const VERSION = 'v82-smartyard-flussonic-compat';
const PORT = Number(process.env.SMARTYARD_COMPAT_PORT || 3082);
const HOST = process.env.SMARTYARD_COMPAT_HOST || '127.0.0.1';
const DVR_ENGINE_URL = String(process.env.DVR_ENGINE_URL || 'http://127.0.0.1:3010').replace(/\/+$/, '');
const PRIMARY_TOKEN = String(process.env.RESTREAM_PUBLIC_TOKEN || process.env.VITE_RESTREAM_PUBLIC_TOKEN || '');
const CAMERA_STREAM_MAP = process.env.CAMERA_STREAM_MAP || '/etc/newdomofon-video/camera-stream-map.json';
const STREAM_ALIASES_FILE = process.env.STREAM_ALIASES_FILE || '/etc/newdomofon-video/stream-aliases.json';
const ACCEPTED_TOKENS_FILE = process.env.ACCEPTED_TOKENS_FILE || '/etc/newdomofon-video/restream-accepted-tokens.json';
const PREVIEW_FALLBACK_MP4 = process.env.PREVIEW_FALLBACK_MP4 || '/var/lib/newdomofon-video/smartyard-preview-v82.mp4';
const SEGMENT_SECONDS = Number(process.env.SMARTYARD_SEGMENT_SECONDS || 4);
const RANGE_GAP_SECONDS = Number(process.env.SMARTYARD_RANGE_GAP_SECONDS || 30);
const DVR_ROOTS = String(process.env.DVR_ROOTS || '/var/lib/newdomofon-video/dvr,/var/dvr')
  .split(',')
  .map((item) => item.trim())
  .filter(Boolean);

function readJson(file, fallback) {
  try {
    return JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch {
    return fallback;
  }
}

function cameraMap() {
  const value = readJson(CAMERA_STREAM_MAP, {});
  return value && typeof value === 'object' ? value : {};
}

function aliasMap() {
  const value = readJson(STREAM_ALIASES_FILE, {});
  return value && typeof value === 'object' ? value : {};
}

function acceptedTokens() {
  const fromFile = readJson(ACCEPTED_TOKENS_FILE, []);
  const tokens = Array.isArray(fromFile) ? fromFile.map(String).map((s) => s.trim()).filter(Boolean) : [];
  if (PRIMARY_TOKEN && !tokens.includes(PRIMARY_TOKEN)) tokens.unshift(PRIMARY_TOKEN);
  return tokens;
}

function extractToken(req, reqUrl) {
  const queryToken = reqUrl.searchParams.get('token') || '';
  if (queryToken) return queryToken;

  const auth = String(req.headers.authorization || '');
  if (/^Bearer\s+/i.test(auth)) return auth.replace(/^Bearer\s+/i, '').trim();

  if (/^Basic\s+/i.test(auth)) {
    try {
      const decoded = Buffer.from(auth.replace(/^Basic\s+/i, ''), 'base64').toString('utf8');
      const idx = decoded.indexOf(':');
      return idx >= 0 ? decoded.slice(idx + 1) : decoded;
    } catch {
      return '';
    }
  }

  return '';
}

function isAcceptedToken(token) {
  return acceptedTokens().includes(String(token || ''));
}

function tokenForPlaylist(actualToken) {
  return actualToken || PRIMARY_TOKEN || acceptedTokens()[0] || '';
}

function cors(extra = {}) {
  return {
    'access-control-allow-origin': '*',
    'access-control-allow-methods': 'GET,HEAD,OPTIONS',
    'access-control-allow-headers': '*',
    'access-control-expose-headers': 'Content-Length,Content-Range,Accept-Ranges,X-Newdomofon-Resolved-Stream,X-Newdomofon-SmartYard-Compat',
    'x-newdomofon-smartyard-compat': VERSION,
    ...extra
  };
}

function sendJson(res, status, body, extra = {}) {
  const text = JSON.stringify(body);
  res.writeHead(status, cors({
    'content-type': 'application/json; charset=utf-8',
    'cache-control': 'no-store',
    'content-length': Buffer.byteLength(text),
    ...extra
  }));
  res.end(text);
}

function sendText(res, status, text, contentType = 'text/plain; charset=utf-8', extra = {}) {
  res.writeHead(status, cors({
    'content-type': contentType,
    'cache-control': 'no-store',
    'content-length': Buffer.byteLength(text),
    ...extra
  }));
  res.end(text);
}

function sendNoContent(res, extra = {}) {
  res.writeHead(204, cors({
    'cache-control': 'no-store',
    'content-length': '0',
    ...extra
  }));
  res.end();
}

function contentTypeFor(filePath) {
  const ext = path.extname(filePath).toLowerCase();
  if (ext === '.m3u8') return 'application/vnd.apple.mpegurl; charset=utf-8';
  if (ext === '.ts') return 'video/mp2t';
  if (ext === '.m4s') return 'video/iso.segment';
  if (ext === '.mp4') return 'video/mp4';
  if (ext === '.jpg' || ext === '.jpeg') return 'image/jpeg';
  if (ext === '.png') return 'image/png';
  return 'application/octet-stream';
}

function sendFile(req, res, filePath, stat, stream, extraHeaders = {}) {
  const total = stat.size;
  const range = req.headers.range;
  const baseHeaders = {
    'content-type': extraHeaders['content-type'] || contentTypeFor(filePath),
    'cache-control': 'no-store',
    'accept-ranges': 'bytes',
    'x-newdomofon-resolved-stream': stream,
    ...extraHeaders
  };

  if (range) {
    const match = /^bytes=(\d*)-(\d*)$/.exec(String(range));
    if (match) {
      const start = match[1] ? Number(match[1]) : 0;
      const end = match[2] ? Number(match[2]) : total - 1;
      if (Number.isFinite(start) && Number.isFinite(end) && start <= end && start < total) {
        const finalEnd = Math.min(end, total - 1);
        const chunkSize = finalEnd - start + 1;
        res.writeHead(206, cors({
          ...baseHeaders,
          'content-range': `bytes ${start}-${finalEnd}/${total}`,
          'content-length': chunkSize
        }));
        if (req.method === 'HEAD') res.end();
        else fs.createReadStream(filePath, { start, end: finalEnd }).pipe(res);
        return;
      }
    }
  }

  res.writeHead(200, cors({ ...baseHeaders, 'content-length': total }));
  if (req.method === 'HEAD') res.end();
  else fs.createReadStream(filePath).pipe(res);
}

function isBadStream(stream) {
  return !stream || stream === 'undefined' || stream === 'null' || stream.includes('..') || stream.includes('/') || stream.includes('\\');
}

function refererCameraId(req) {
  const ref = String(req.headers.referer || req.headers.referrer || '');
  if (!ref) return '';
  try {
    const url = new URL(ref);
    const match = /\/cameras\/([^/?#]+)/.exec(url.pathname);
    return match ? decodeURIComponent(match[1]) : '';
  } catch {
    const match = /\/cameras\/([^/?#]+)/.exec(ref);
    return match ? decodeURIComponent(match[1]) : '';
  }
}

function firstQuery(reqUrl, names) {
  for (const name of names) {
    const value = reqUrl.searchParams.get(name);
    if (value) return String(value).trim();
  }
  return '';
}

function resolveStreamName(rawStream, req, reqUrl) {
  const cameras = cameraMap();
  const aliases = aliasMap();
  const raw = String(rawStream || '').trim();
  const candidates = [];

  if (raw && raw !== 'undefined' && raw !== 'null') candidates.push(raw);

  const fromQuery = firstQuery(reqUrl, ['camera_id', 'cameraId', 'camera_uuid', 'cameraUuid', 'id', 'route_id', 'routeId']);
  if (fromQuery) candidates.push(fromQuery);

  const fromReferer = refererCameraId(req);
  if (fromReferer) candidates.push(fromReferer);

  for (const candidate of candidates) {
    if (aliases[candidate]) return String(aliases[candidate]);
    if (cameras[candidate]) return String(cameras[candidate]);
    if (!isBadStream(candidate)) return candidate;
  }

  return raw;
}

function safeRel(p) {
  const clean = String(p || '').split('?')[0];
  if (!clean || clean.startsWith('/') || clean.includes('..') || clean.includes('\\') || clean.includes('\0')) return '';
  return clean.split('/').filter(Boolean).join('/');
}

function streamRoots(stream) {
  return DVR_ROOTS.map((root) => path.resolve(root, stream));
}

function filenameLocalMs(filePath) {
  const base = path.basename(filePath);
  const match = /^(\d{4})(\d{2})(\d{2})_(\d{2})(\d{2})(\d{2})\.(ts|m4s|mp4)$/i.exec(base);
  if (!match) return NaN;
  return new Date(Number(match[1]), Number(match[2]) - 1, Number(match[3]), Number(match[4]), Number(match[5]), Number(match[6])).getTime();
}

async function scanSegments(stream, startMs = 0, endMs = Number.MAX_SAFE_INTEGER) {
  const results = [];

  for (const root of streamRoots(stream)) {
    try {
      const stat = await fsp.stat(root);
      if (!stat.isDirectory()) continue;
    } catch {
      continue;
    }

    const stack = [root];
    while (stack.length) {
      const dir = stack.pop();
      let entries;
      try {
        entries = await fsp.readdir(dir, { withFileTypes: true });
      } catch {
        continue;
      }

      for (const entry of entries) {
        const full = path.join(dir, entry.name);
        if (entry.isDirectory()) {
          stack.push(full);
          continue;
        }
        if (!entry.isFile() || !/\.(ts|m4s|mp4)$/i.test(entry.name)) continue;
        if (entry.name === path.basename(PREVIEW_FALLBACK_MP4)) continue;

        const ms = filenameLocalMs(full);
        if (!Number.isFinite(ms)) continue;
        if (ms < startMs || ms > endMs) continue;

        const relative = path.relative(root, full).split(path.sep).join('/');
        results.push({ filePath: full, relative, ms });
      }
    }
  }

  results.sort((a, b) => a.ms - b.ms || a.relative.localeCompare(b.relative));
  return results;
}

async function findSegmentFile(stream, relPath) {
  const safe = safeRel(relPath);
  if (!safe) return null;

  for (const root of streamRoots(stream)) {
    const rootResolved = path.resolve(root);
    const candidate = path.resolve(rootResolved, safe);
    if (!candidate.startsWith(rootResolved + path.sep)) continue;
    try {
      const stat = await fsp.stat(candidate);
      if (stat.isFile()) return { filePath: candidate, stat };
    } catch {
      // next root
    }
  }

  return null;
}

function appendTokenToPlaylist(body, token) {
  return body
    .split(/\r?\n/)
    .map((line) => {
      const trimmed = line.trim();
      if (!trimmed || trimmed.startsWith('#')) return line;
      if (trimmed.includes('token=')) return line;
      const sep = trimmed.includes('?') ? '&' : '?';
      return `${trimmed}${sep}token=${encodeURIComponent(token)}`;
    })
    .join('\n');
}

async function fetchUpstream(pathname) {
  return fetch(`${DVR_ENGINE_URL}${pathname}`, {
    headers: {
      accept: '*/*',
      'user-agent': `newdomofon-smartyard-compat-${VERSION}`
    }
  });
}

function parseArchiveWindow(mediaPath, reqUrl) {
  const start = reqUrl.searchParams.get('start');
  const end = reqUrl.searchParams.get('end');

  if (start && end) {
    const startMs = Date.parse(start);
    const endMs = Date.parse(end);
    if (Number.isFinite(startMs) && Number.isFinite(endMs) && endMs > startMs) {
      return { startMs, endMs, source: 'query-start-end' };
    }
  }

  let match = /^(archive|index|video|mono)-(\d+)-(now|\d+)\.(m3u8|mp4)$/i.exec(mediaPath);
  if (match) {
    const from = Number(match[2]);
    const duration = match[3] === 'now' ? Math.floor(Date.now() / 1000) - from : Number(match[3]);
    if (Number.isFinite(from) && Number.isFinite(duration) && duration > 0) {
      return { startMs: from * 1000, endMs: (from + duration) * 1000, source: `${match[1]}-${match[4]}` };
    }
  }

  match = /^timeshift_abs-(\d+)\.m3u8$/i.exec(mediaPath);
  if (match) return { startMs: Number(match[1]) * 1000, endMs: Date.now(), source: 'timeshift_abs' };

  match = /^timeshift_rel-(\d+)\.m3u8$/i.exec(mediaPath);
  if (match) return { startMs: Date.now() - Number(match[1]) * 1000, endMs: Date.now(), source: 'timeshift_rel' };

  return null;
}

function segmentDuration(current, next) {
  if (!next) return Math.max(1, SEGMENT_SECONDS);
  return Math.max(1, Math.min(30, (next.ms - current.ms) / 1000));
}

function archivePlaylist(segments, token) {
  const target = Math.max(4, ...segments.slice(0, -1).map((s, i) => Math.ceil(segmentDuration(s, segments[i + 1]))));
  const lines = [
    '#EXTM3U',
    '#EXT-X-VERSION:6',
    `#EXT-X-TARGETDURATION:${target}`,
    '#EXT-X-MEDIA-SEQUENCE:0',
    '#EXT-X-INDEPENDENT-SEGMENTS',
    '#EXT-X-PLAYLIST-TYPE:VOD'
  ];

  for (let i = 0; i < segments.length; i += 1) {
    const segment = segments[i];
    const duration = segmentDuration(segment, segments[i + 1]);
    const uri = token ? `${segment.relative}?token=${encodeURIComponent(token)}` : segment.relative;
    lines.push(`#EXT-X-PROGRAM-DATE-TIME:${new Date(segment.ms).toISOString()}`);
    lines.push(`#EXTINF:${duration.toFixed(3)},`);
    lines.push(uri);
  }

  lines.push('#EXT-X-ENDLIST');
  return `${lines.join('\n')}\n`;
}

function buildRanges(segments) {
  const ranges = [];
  if (!segments.length) return ranges;

  let start = Math.floor(segments[0].ms / 1000);
  let lastEnd = start + SEGMENT_SECONDS;

  for (let i = 1; i < segments.length; i += 1) {
    const ts = Math.floor(segments[i].ms / 1000);
    const nextEnd = ts + SEGMENT_SECONDS;

    if (ts <= lastEnd + RANGE_GAP_SECONDS) {
      lastEnd = Math.max(lastEnd, nextEnd);
      continue;
    }

    if (lastEnd > start) ranges.push({ from: start, duration: lastEnd - start });
    start = ts;
    lastEnd = nextEnd;
  }

  if (lastEnd > start) ranges.push({ from: start, duration: lastEnd - start });
  return ranges;
}

async function handleRecordingStatus(res, stream, reqUrl) {
  const fromSec = Number(reqUrl.searchParams.get('from') || 0);
  const startMs = Number.isFinite(fromSec) && fromSec > 0 ? fromSec * 1000 : 0;
  const segments = await scanSegments(stream, startMs, Number.MAX_SAFE_INTEGER);
  const ranges = buildRanges(segments);

  sendJson(res, 200, [
    {
      stream,
      ranges
    }
  ], {
    'x-newdomofon-resolved-stream': stream,
    'x-newdomofon-ranges-count': String(ranges.length),
    'x-newdomofon-segments-count': String(segments.length)
  });
}

async function handleMediaInfo(res, stream) {
  sendJson(res, 200, {
    stream,
    name: stream,
    tracks: [
      { content: 'video', codec: 'h264' },
      { content: 'audio', codec: 'aac', optional: true }
    ]
  }, { 'x-newdomofon-resolved-stream': stream });
}

async function handleLive(res, stream, token) {
  const upstream = await fetchUpstream(`/cameras/${encodeURIComponent(stream)}/live.m3u8`);
  const body = await upstream.text();
  const contentType = upstream.headers.get('content-type') || 'application/vnd.apple.mpegurl; charset=utf-8';

  sendText(
    res,
    upstream.status,
    upstream.ok ? appendTokenToPlaylist(body, tokenForPlaylist(token)) : body,
    contentType,
    { 'x-newdomofon-resolved-stream': stream }
  );
}

async function handleArchivePlaylist(res, stream, mediaPath, reqUrl, token) {
  let win = parseArchiveWindow(mediaPath, reqUrl);
  if (!win) {
    const now = Date.now();
    win = { startMs: now - 3600_000, endMs: now, source: 'default-last-hour' };
  }

  const segments = await scanSegments(stream, win.startMs, win.endMs);
  if (!segments.length) {
    sendJson(res, 404, {
      error: 'No archive segments in selected range',
      stream_name: stream,
      start: new Date(win.startMs).toISOString(),
      end: new Date(win.endMs).toISOString(),
      source: win.source
    }, { 'x-newdomofon-resolved-stream': stream });
    return;
  }

  sendText(res, 200, archivePlaylist(segments, tokenForPlaylist(token)), 'application/vnd.apple.mpegurl; charset=utf-8', {
    'x-newdomofon-resolved-stream': stream,
    'x-newdomofon-archive-window-source': win.source
  });
}

function quoteForConcat(filePath) {
  return String(filePath).replace(/'/g, "'\\''");
}

async function runFfmpegConcat(files, outFile) {
  const listFile = path.join(path.dirname(outFile), 'concat.txt');
  await fsp.writeFile(listFile, files.map((file) => `file '${quoteForConcat(file)}'`).join('\n') + '\n', 'utf8');

  await new Promise((resolve, reject) => {
    const child = spawn('ffmpeg', [
      '-hide_banner',
      '-loglevel', 'error',
      '-y',
      '-f', 'concat',
      '-safe', '0',
      '-i', listFile,
      '-c', 'copy',
      '-movflags', '+faststart',
      outFile
    ], { stdio: ['ignore', 'ignore', 'pipe'] });

    let stderr = '';
    child.stderr.on('data', (chunk) => {
      stderr += chunk.toString();
      if (stderr.length > 12000) stderr = stderr.slice(-12000);
    });
    child.on('error', reject);
    child.on('close', (code) => {
      if (code === 0) resolve();
      else reject(new Error(stderr || `ffmpeg exited with code ${code}`));
    });
  });
}

function safeName(value) {
  return String(value || 'archive')
    .replace(/[^A-Za-z0-9_.-]+/g, '_')
    .replace(/^_+|_+$/g, '')
    .slice(0, 120) || 'archive';
}

async function handleArchiveMp4(req, res, stream, mediaPath, reqUrl) {
  const win = parseArchiveWindow(mediaPath, reqUrl);
  if (!win) {
    sendJson(res, 400, {
      error: 'Missing archive window',
      supported: ['export.mp4?start=<iso>&end=<iso>', 'archive-<unix>-<duration>.mp4']
    }, { 'x-newdomofon-resolved-stream': stream });
    return;
  }

  const segments = await scanSegments(stream, win.startMs, win.endMs);
  if (!segments.length) {
    sendJson(res, 404, {
      error: 'No archive segments in selected range',
      stream_name: stream,
      start: new Date(win.startMs).toISOString(),
      end: new Date(win.endMs).toISOString(),
      source: win.source
    }, { 'x-newdomofon-resolved-stream': stream });
    return;
  }

  const tmpDir = await fsp.mkdtemp(path.join(os.tmpdir(), 'newdomofon-smartyard-export-'));
  const outFile = path.join(tmpDir, `${safeName(stream)}-${Date.now()}.mp4`);

  try {
    await runFfmpegConcat(segments.map((s) => s.filePath), outFile);
    const stat = await fsp.stat(outFile);
    sendFile(req, res, outFile, stat, stream, {
      'content-type': 'video/mp4',
      'content-disposition': `attachment; filename="${safeName(stream)}-${Math.floor(win.startMs / 1000)}-${Math.floor((win.endMs - win.startMs) / 1000)}.mp4"`
    });

    const cleanup = () => fsp.rm(tmpDir, { recursive: true, force: true }).catch(() => {});
    res.on('finish', cleanup);
    res.on('close', cleanup);
  } catch (error) {
    await fsp.rm(tmpDir, { recursive: true, force: true }).catch(() => {});
    sendJson(res, 500, {
      error: 'Export failed',
      message: String((error && error.message) || error),
      stream_name: stream
    }, { 'x-newdomofon-resolved-stream': stream });
  }
}

async function handlePreview(req, res, stream) {
  try {
    const stat = await fsp.stat(PREVIEW_FALLBACK_MP4);
    if (stat.isFile() && stat.size > 0) {
      sendFile(req, res, PREVIEW_FALLBACK_MP4, stat, stream, {
        'content-type': 'video/mp4',
        'content-disposition': 'inline; filename="preview.mp4"'
      });
      return;
    }
  } catch {
    // fallback below
  }

  sendNoContent(res, { 'x-newdomofon-resolved-stream': stream });
}

function parseRequestPath(reqUrl) {
  const pathname = decodeURIComponent(reqUrl.pathname || '/');
  let rest = '';

  if (pathname.startsWith('/api/media/')) rest = pathname.slice('/api/media/'.length);
  else if (pathname.startsWith('/dvr-archive/')) rest = pathname.slice('/dvr-archive/'.length);
  else if (pathname.startsWith('/api/dvr-archive/')) rest = pathname.slice('/api/dvr-archive/'.length);
  else if (pathname.startsWith('/')) rest = pathname.slice(1);
  else rest = pathname;

  const parts = rest.split('/').filter(Boolean);
  const rawStream = parts.shift() || '';
  const mediaPath = parts.join('/');
  return { rawStream, mediaPath };
}

async function handle(req, res) {
  try {
    const reqUrl = new URL(req.url || '/', 'http://127.0.0.1');

    if (req.method === 'OPTIONS') {
      sendNoContent(res);
      return;
    }

    if (reqUrl.pathname === '/health') {
      sendJson(res, 200, {
        ok: true,
        service: 'newdomofon-smartyard-compat',
        version: VERSION,
        dvr: DVR_ENGINE_URL,
        dvr_roots: DVR_ROOTS,
        camera_map: CAMERA_STREAM_MAP,
        aliases: aliasMap(),
        accepted_tokens_count: acceptedTokens().length,
        token_configured: acceptedTokens().length > 0,
        flussonic_like: true,
        recording_status_array: true,
        preview_fallback: PREVIEW_FALLBACK_MP4
      });
      return;
    }

    const { rawStream, mediaPath } = parseRequestPath(reqUrl);
    const stream = resolveStreamName(rawStream, req, reqUrl);

    if (isBadStream(stream)) {
      sendJson(res, 400, {
        error: 'Invalid stream_name',
        stream_name: rawStream,
        resolved_stream_name: stream || '',
        referer_camera_id: refererCameraId(req)
      });
      return;
    }

    const actualToken = extractToken(req, reqUrl);
    if (!isAcceptedToken(actualToken)) {
      sendJson(res, 401, {
        error: 'Invalid playback token',
        accepted_count: acceptedTokens().length,
        actual_prefix: actualToken.slice(0, 8)
      }, { 'x-newdomofon-resolved-stream': stream });
      return;
    }

    if (!mediaPath) {
      sendJson(res, 400, { error: 'Missing media path' }, { 'x-newdomofon-resolved-stream': stream });
      return;
    }

    if (mediaPath === 'recording_status.json') {
      await handleRecordingStatus(res, stream, reqUrl);
      return;
    }

    if (mediaPath === 'media_info.json') {
      await handleMediaInfo(res, stream);
      return;
    }

    if (mediaPath === 'preview.mp4' || /^\d+-preview\.mp4$/i.test(mediaPath)) {
      await handlePreview(req, res, stream);
      return;
    }

    if (mediaPath === 'live.m3u8' || mediaPath === 'index.m3u8' || mediaPath === 'video.m3u8') {
      await handleLive(res, stream, actualToken);
      return;
    }

    const isArchivePlaylist =
      mediaPath === 'archive.m3u8' ||
      /^(archive|index|video|mono)-\d+-(now|\d+)\.m3u8$/i.test(mediaPath) ||
      /^timeshift_(abs|rel)-\d+\.m3u8$/i.test(mediaPath);

    if (isArchivePlaylist) {
      await handleArchivePlaylist(res, stream, mediaPath, reqUrl, actualToken);
      return;
    }

    const isMp4Export =
      mediaPath === 'export.mp4' ||
      /^(archive|index|video|mono)-\d+-(now|\d+)\.mp4$/i.test(mediaPath);

    if (isMp4Export) {
      await handleArchiveMp4(req, res, stream, mediaPath, reqUrl);
      return;
    }

    const found = await findSegmentFile(stream, mediaPath);
    if (found) {
      sendFile(req, res, found.filePath, found.stat, stream);
      return;
    }

    sendJson(res, 404, {
      error: 'Media file not found',
      stream_name: stream,
      path: mediaPath
    }, { 'x-newdomofon-resolved-stream': stream });
  } catch (error) {
    console.error('[smartyard-compat] error', error);
    sendJson(res, 502, {
      error: 'smartyard compat proxy error',
      message: String((error && error.message) || error)
    });
  }
}

const server = http.createServer((req, res) => {
  void handle(req, res);
});

server.listen(PORT, HOST, () => {
  console.log('[smartyard-compat] listening', {
    host: HOST,
    port: PORT,
    dvr: DVR_ENGINE_URL,
    dvr_roots: DVR_ROOTS,
    camera_map: CAMERA_STREAM_MAP,
    aliases_file: STREAM_ALIASES_FILE,
    accepted_tokens_file: ACCEPTED_TOKENS_FILE,
    accepted_tokens_count: acceptedTokens().length,
    version: VERSION
  });
});

process.on('SIGTERM', () => server.close(() => process.exit(0)));
process.on('SIGINT', () => server.close(() => process.exit(0)));
NODE

node --check "$SERVICE_DIR/server.js"

cat > "$SERVICE_FILE" <<UNIT
[Unit]
Description=NewDomofon SmartYard Flussonic-compatible DVR gateway
After=network-online.target newdomofon-video-dvr.service
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=$SERVICE_DIR
EnvironmentFile=-$ENV_FILE
Environment=SMARTYARD_COMPAT_HOST=$SERVICE_HOST
Environment=SMARTYARD_COMPAT_PORT=$SERVICE_PORT
Environment=DVR_ENGINE_URL=$DVR_ENGINE_URL
Environment=DVR_ROOTS=$DVR_ROOTS
Environment=CAMERA_STREAM_MAP=$CAMERA_STREAM_MAP
Environment=STREAM_ALIASES_FILE=$STREAM_ALIASES_FILE
Environment=ACCEPTED_TOKENS_FILE=$ACCEPTED_TOKENS_FILE
Environment=PREVIEW_FALLBACK_MP4=$PREVIEW_FALLBACK_MP4
ExecStart=/usr/bin/node $SERVICE_DIR/server.js
Restart=always
RestartSec=3
KillSignal=SIGTERM
TimeoutStopSec=10
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable "$SERVICE_NAME" >/dev/null
systemctl restart "$SERVICE_NAME"
sleep 1
systemctl --no-pager --full status "$SERVICE_NAME" | sed -n '1,14p' || true

echo
echo "===== Write nginx v82 SmartYard snippet ====="
install -d -m 0755 /etc/nginx/snippets
cat > "$SNIPPET" <<NGINX
# NewDomofon v82 SmartYard / Flussonic-compatible public DVR routes.
# SmartYard calls camera base URL directly:
#   /<stream>/index.m3u8
#   /<stream>/recording_status.json
#   /<stream>/archive-<from>-<duration>.mp4
#   /<stream>/<time>-preview.mp4

location ^~ /api/media/ {
    if (\$request_method = OPTIONS) { return 204; }

    proxy_pass http://${SERVICE_HOST}:${SERVICE_PORT};
    proxy_http_version 1.1;
    proxy_buffering off;
    proxy_request_buffering off;
    proxy_connect_timeout 5s;
    proxy_read_timeout 3600s;
    proxy_send_timeout 3600s;
    proxy_set_header Host \$host;
    proxy_set_header X-Forwarded-Host \$host;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header Authorization \$http_authorization;
    proxy_hide_header Access-Control-Allow-Origin;
    add_header Access-Control-Allow-Origin "*" always;
    add_header Access-Control-Allow-Methods "GET,HEAD,OPTIONS" always;
    add_header Access-Control-Allow-Headers "*" always;
    add_header Access-Control-Expose-Headers "Content-Length,Content-Range,Accept-Ranges,X-Newdomofon-Resolved-Stream,X-Newdomofon-SmartYard-Compat" always;
    add_header Cache-Control "no-store" always;
}

location ^~ /dvr-archive/ {
    if (\$request_method = OPTIONS) { return 204; }

    proxy_pass http://${SERVICE_HOST}:${SERVICE_PORT};
    proxy_http_version 1.1;
    proxy_buffering off;
    proxy_request_buffering off;
    proxy_connect_timeout 5s;
    proxy_read_timeout 3600s;
    proxy_send_timeout 3600s;
    proxy_set_header Host \$host;
    proxy_set_header X-Forwarded-Host \$host;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header Authorization \$http_authorization;
    proxy_hide_header Access-Control-Allow-Origin;
    add_header Access-Control-Allow-Origin "*" always;
    add_header Access-Control-Allow-Methods "GET,HEAD,OPTIONS" always;
    add_header Access-Control-Allow-Headers "*" always;
    add_header Access-Control-Expose-Headers "Content-Length,Content-Range,Accept-Ranges,X-Newdomofon-Resolved-Stream,X-Newdomofon-SmartYard-Compat" always;
    add_header Cache-Control "no-store" always;
}

location ~ ^/[A-Za-z0-9_.-]+/(index\.m3u8|video\.m3u8|live\.m3u8|archive\.m3u8|recording_status\.json|media_info\.json|preview\.mp4|[0-9]+-preview\.mp4|export\.mp4)$ {
    if (\$request_method = OPTIONS) { return 204; }

    proxy_pass http://${SERVICE_HOST}:${SERVICE_PORT}\$request_uri;
    proxy_http_version 1.1;
    proxy_buffering off;
    proxy_request_buffering off;
    proxy_connect_timeout 5s;
    proxy_read_timeout 3600s;
    proxy_send_timeout 3600s;
    proxy_set_header Host \$host;
    proxy_set_header X-Forwarded-Host \$host;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header Authorization \$http_authorization;
    proxy_hide_header Access-Control-Allow-Origin;
    add_header Access-Control-Allow-Origin "*" always;
    add_header Access-Control-Allow-Methods "GET,HEAD,OPTIONS" always;
    add_header Access-Control-Allow-Headers "*" always;
    add_header Access-Control-Expose-Headers "Content-Length,Content-Range,Accept-Ranges,X-Newdomofon-Resolved-Stream,X-Newdomofon-SmartYard-Compat" always;
    add_header Cache-Control "no-store" always;
}

location ~ ^/[A-Za-z0-9_.-]+/(archive|index|video|mono)-[0-9]+-(now|[0-9]+)\.(m3u8|mp4)$ {
    if (\$request_method = OPTIONS) { return 204; }

    proxy_pass http://${SERVICE_HOST}:${SERVICE_PORT}\$request_uri;
    proxy_http_version 1.1;
    proxy_buffering off;
    proxy_request_buffering off;
    proxy_connect_timeout 5s;
    proxy_read_timeout 3600s;
    proxy_send_timeout 3600s;
    proxy_set_header Host \$host;
    proxy_set_header X-Forwarded-Host \$host;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header Authorization \$http_authorization;
    proxy_hide_header Access-Control-Allow-Origin;
    add_header Access-Control-Allow-Origin "*" always;
    add_header Access-Control-Allow-Methods "GET,HEAD,OPTIONS" always;
    add_header Access-Control-Allow-Headers "*" always;
    add_header Access-Control-Expose-Headers "Content-Length,Content-Range,Accept-Ranges,X-Newdomofon-Resolved-Stream,X-Newdomofon-SmartYard-Compat" always;
    add_header Cache-Control "no-store" always;
}

location ~ ^/[A-Za-z0-9_.-]+/.+\.(ts|m4s|mp4)$ {
    if (\$request_method = OPTIONS) { return 204; }

    proxy_pass http://${SERVICE_HOST}:${SERVICE_PORT}\$request_uri;
    proxy_http_version 1.1;
    proxy_buffering off;
    proxy_request_buffering off;
    proxy_connect_timeout 5s;
    proxy_read_timeout 3600s;
    proxy_send_timeout 3600s;
    proxy_set_header Host \$host;
    proxy_set_header X-Forwarded-Host \$host;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header Authorization \$http_authorization;
    proxy_hide_header Access-Control-Allow-Origin;
    add_header Access-Control-Allow-Origin "*" always;
    add_header Access-Control-Allow-Methods "GET,HEAD,OPTIONS" always;
    add_header Access-Control-Allow-Headers "*" always;
    add_header Access-Control-Expose-Headers "Content-Length,Content-Range,Accept-Ranges,X-Newdomofon-Resolved-Stream,X-Newdomofon-SmartYard-Compat" always;
    add_header Cache-Control "no-store" always;
}
NGINX


echo
echo "===== Include v82 snippet and remove superseded media snippets ====="
python3 - "$SNIPPET" <<'PY'
import pathlib
import re
import sys

snippet = sys.argv[1]
needle = pathlib.Path(snippet).name
include = f"    include {snippet};\n"

old_snippets = [
    'newdomofon-api-media-global-proxy.conf',
    'newdomofon-public-hls-channel-links.conf',
    'newdomofon-exact-public-hls-streams.conf',
    'newdomofon-flussonic-style-restream.conf',
    'newdomofon-restream-domain-locations.conf',
    'newdomofon-v40-public-media.conf',
    'newdomofon-v41-public-media.conf',
    'newdomofon-v42-public-media.conf',
    'newdomofon-v43-force-media.conf',
    'newdomofon-v44-force-media.conf',
    'newdomofon-v45-flussonic-dvr-compat.conf',
    'newdomofon-v46-safe-archive-only.conf',
]

patched = 0
for base in [pathlib.Path('/etc/nginx/sites-enabled'), pathlib.Path('/etc/nginx/conf.d')]:
    if not base.exists():
        continue
    for path in base.rglob('*.conf'):
        try:
            text = path.read_text()
        except Exception:
            continue

        if not (
            'newdomofon' in text
            or 'new-video.domofon-37.ru' in text
            or '10.106.1.28' in text
            or re.search(r'listen\s+[^;]*(80|443|8445|8446)', text)
        ):
            continue

        original = text
        for name in old_snippets:
            text = re.sub(rf'^\s*include\s+/etc/nginx/snippets/{re.escape(name)};\s*\n', '', text, flags=re.M)

        if needle not in text:
            # Put v82 before the first location to let ^~ /api/media and /dvr-archive win over /api/.
            match = re.search(r'^\s*location\s+', text, flags=re.M)
            if match:
                text = text[:match.start()] + include + '\n' + text[match.start():]
            else:
                pos = text.rfind('}')
                if pos != -1:
                    text = text[:pos] + include + text[pos:]

        if text != original:
            path.write_text(text)
            patched += 1
            print('patched', path)

if patched == 0:
    raise SystemExit('no nginx server config was patched')
PY

nginx -t
systemctl reload nginx || systemctl restart nginx

echo
echo "===== Verification ====="
curl -fsS "http://${SERVICE_HOST}:${SERVICE_PORT}/health" && echo

STREAM_NAME="cam_10_130_1_219"
if ! grep -q "$STREAM_NAME" "$CAMERA_STREAM_MAP"; then
  STREAM_NAME="$(node -e "const m=require(process.argv[1]); console.log(Object.values(m)[0]||'')" "$CAMERA_STREAM_MAP")"
fi
TOKEN_FOR_TEST="$PRIMARY_TOKEN"
if [[ -z "$TOKEN_FOR_TEST" ]]; then
  TOKEN_FOR_TEST="$SMARTYARD_AUTH_TOKEN"
fi

LAST_SEG="$(find "${DVR_ROOTS%%,*}/$STREAM_NAME" -type f -name '*.ts' 2>/dev/null | sort | tail -1 || true)"
if [[ -n "$LAST_SEG" ]]; then
  BASE="$(basename "$LAST_SEG" .ts)"
  # Filename format: YYYYMMDD_HHMMSS.ts, interpreted as local time to match existing archive proxy behavior.
  LOCAL_TS="${BASE:0:4}-${BASE:4:2}-${BASE:6:2} ${BASE:9:2}:${BASE:11:2}:${BASE:13:2}"
  FROM_EPOCH="$(date -d "$LOCAL_TS - 5 minutes" +%s)"
  DURATION="360"
else
  FROM_EPOCH="$(date -d '10 minutes ago' +%s)"
  DURATION="600"
fi

PUBLIC_BASE="${SITE_URL%/}/$STREAM_NAME"
echo "SmartYard base: ${PUBLIC_BASE}/"
echo "Live:          ${PUBLIC_BASE}/index.m3u8?token=${TOKEN_FOR_TEST}"
echo "Ranges:        ${PUBLIC_BASE}/recording_status.json?from=1525186456&token=${TOKEN_FOR_TEST}"
echo "Preview:       ${PUBLIC_BASE}/preview.mp4?token=${TOKEN_FOR_TEST}"
echo "Archive MP4:   ${PUBLIC_BASE}/archive-${FROM_EPOCH}-${DURATION}.mp4?token=${TOKEN_FOR_TEST}"

for url in \
  "${PUBLIC_BASE}/recording_status.json?from=1525186456&token=${TOKEN_FOR_TEST}" \
  "${PUBLIC_BASE}/preview.mp4?token=${TOKEN_FOR_TEST}" \
  "${PUBLIC_BASE}/index.m3u8?token=${TOKEN_FOR_TEST}"; do
  echo
  echo "$url"
  curl -k --max-time 30 -i "$url" | sed -n '1,24p' || true
done

echo
echo "DONE: v82 SmartYard compatibility installed."
echo "Backup: $BACKUP"
