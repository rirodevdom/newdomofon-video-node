#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="${PROJECT_DIR:-/opt/newdomofon-video}"
PLAYER_DIR="${PLAYER_DIR:-/var/www/newdomofon-video/newdomofon-player}"
ARCHIVE_PROXY_DIR="${ARCHIVE_PROXY_DIR:-$PROJECT_DIR/dvr-archive-proxy}"
ARCHIVE_PROXY_JS="${ARCHIVE_PROXY_JS:-$ARCHIVE_PROXY_DIR/server.js}"
DVR_ROOT="${DVR_ROOT:-/var/lib/newdomofon-video/dvr}"
SERVICE_NAME="${SERVICE_NAME:-newdomofon-dvr-archive-proxy.service}"
TS="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="$PROJECT_DIR/backups/v114-hls-discontinuity-filter-$TS"
MODULE_JS="$ARCHIVE_PROXY_DIR/hls-discontinuity-filter-v114.js"

log(){ printf '\n===== %s =====\n' "$*"; }
backup_file(){
  local f="$1"
  if [ -e "$f" ]; then
    local dst="$BACKUP_DIR${f}"
    mkdir -p "$(dirname "$dst")"
    cp -a "$f" "$dst"
    echo "backup: $f"
  fi
}

log "Validate paths"
[ -d "$PROJECT_DIR" ] || { echo "ERROR: PROJECT_DIR not found: $PROJECT_DIR" >&2; exit 1; }
[ -f "$ARCHIVE_PROXY_JS" ] || { echo "ERROR: archive proxy server.js not found: $ARCHIVE_PROXY_JS" >&2; exit 1; }
command -v node >/dev/null || { echo "ERROR: node not found" >&2; exit 1; }
command -v ffprobe >/dev/null || echo "WARN: ffprobe not found now; v114 filter will pass playlists through until ffprobe is installed" >&2
mkdir -p "$BACKUP_DIR"

log "Backup"
backup_file "$ARCHIVE_PROXY_JS"
backup_file "$MODULE_JS"
backup_file "/etc/systemd/system/$SERVICE_NAME"

log "Write hls discontinuity filter module"
cat > "$MODULE_JS" <<'NODE'
'use strict';

// NewDomofon v114 HLS discontinuity filter.
// Purpose: DVR archive playlists can contain continuous wall-clock PDT but MPEG-TS PTS resets/jumps.
// hls.js can stall on these playlists unless #EXT-X-DISCONTINUITY is inserted before the new timestamp sequence.

const fs = require('fs');
const path = require('path');
const cp = require('child_process');

const VERSION = 'v114-hls-discontinuity-filter';
const DVR_ROOT = process.env.DVR_ROOT || '/var/lib/newdomofon-video/dvr';
const CACHE_MAX = Number(process.env.ND_HLS_DISC_CACHE_MAX || 50000);
const FFPROBE_TIMEOUT_MS = Number(process.env.ND_HLS_DISC_FFPROBE_TIMEOUT_MS || 1200);
const ENABLED = process.env.ND_HLS_DISCONTINUITY_FILTER !== '0';
const DEBUG = process.env.ND_HLS_DISC_DEBUG === '1';

const metaCache = new Map();
let logCount = 0;
function log(...args) {
  if (!DEBUG && logCount > 20) return;
  logCount += 1;
  console.log('[NewDomofon hls-discontinuity-v114]', ...args);
}

function toText(body) {
  if (typeof body === 'string') return body;
  if (Buffer.isBuffer(body)) return body.toString('utf8');
  return null;
}

function streamFromUrl(reqUrl) {
  const u = String(reqUrl || '').split('?')[0];
  let m = u.match(/\/dvr-archive\/([^/]+)\//);
  if (m) return decodeURIComponent(m[1]);
  m = u.match(/^\/([^/]+)\/(?:index-\d+-\d+|archive-\d+-\d+)\.m3u8$/);
  if (m) return decodeURIComponent(m[1]);
  return null;
}

function isArchivePlaylistRequest(reqUrl) {
  const u = String(reqUrl || '').split('?')[0];
  return /\/dvr-archive\/[^/]+\/archive-\d+-\d+\.m3u8$/.test(u) ||
         /^\/[^/]+\/index-\d+-\d+\.m3u8$/.test(u) ||
         /^\/[^/]+\/archive-\d+-\d+\.m3u8$/.test(u);
}

function safeLocalTsPath(stream, uri) {
  if (!stream || !uri) return null;
  const rel = String(uri).split('?')[0].replace(/^\/+/, '');
  if (!rel || rel.includes('\0') || rel.includes('..') || !rel.endsWith('.ts')) return null;
  const base = path.resolve(DVR_ROOT, stream);
  const full = path.resolve(base, rel);
  if (!full.startsWith(base + path.sep)) return null;
  return full;
}

function cacheSet(key, value) {
  metaCache.set(key, value);
  if (metaCache.size > CACHE_MAX) {
    const first = metaCache.keys().next().value;
    if (first) metaCache.delete(first);
  }
}

function ffprobeMeta(file) {
  try {
    const st = fs.statSync(file);
    const key = file + ':' + st.size + ':' + Math.floor(st.mtimeMs);
    if (metaCache.has(key)) return metaCache.get(key);

    const out = cp.execFileSync('ffprobe', [
      '-v', 'error',
      '-select_streams', 'v:0',
      '-show_entries', 'stream=start_time,duration,codec_name,codec_type',
      '-of', 'json',
      file
    ], { encoding: 'utf8', timeout: FFPROBE_TIMEOUT_MS, maxBuffer: 128 * 1024 });

    const data = JSON.parse(out || '{}');
    const s = Array.isArray(data.streams) ? data.streams.find(x => x.codec_type === 'video') : null;
    const start = s && isFinite(Number(s.start_time)) ? Number(s.start_time) : null;
    const duration = s && isFinite(Number(s.duration)) ? Number(s.duration) : null;
    const meta = { ok: start !== null, start, duration, size: st.size, file };
    cacheSet(key, meta);
    return meta;
  } catch (e) {
    return { ok: false, error: String(e && e.message || e), file };
  }
}

function parseIsoToEpoch(s) {
  if (!s) return null;
  const t = Date.parse(s);
  return Number.isFinite(t) ? t / 1000 : null;
}

function parsePlaylist(text) {
  const lines = text.split(/\r?\n/);
  const segments = [];
  let pendingPdt = null;
  let pendingPdtLine = -1;
  let pendingExtinf = null;
  let pendingExtinfLine = -1;
  let discPending = false;
  let gapPending = false;

  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    const pdt = line.match(/^#EXT-X-PROGRAM-DATE-TIME:(.+)$/);
    if (pdt) {
      pendingPdt = parseIsoToEpoch(pdt[1].trim());
      pendingPdtLine = i;
      continue;
    }
    const extinf = line.match(/^#EXTINF:([0-9.]+)/);
    if (extinf) {
      pendingExtinf = Number(extinf[1]);
      pendingExtinfLine = i;
      continue;
    }
    if (line.startsWith('#EXT-X-DISCONTINUITY')) {
      discPending = true;
      continue;
    }
    if (line.startsWith('#EXT-X-GAP')) {
      gapPending = true;
      continue;
    }
    if (line && !line.startsWith('#') && line.includes('.ts')) {
      segments.push({
        lineIndex: i,
        uri: line.trim(),
        pdt: pendingPdt,
        pdtLine: pendingPdtLine,
        duration: Number.isFinite(pendingExtinf) ? pendingExtinf : null,
        extinfLine: pendingExtinfLine,
        alreadyDisc: discPending,
        gap: gapPending,
      });
      pendingPdt = null;
      pendingPdtLine = -1;
      pendingExtinf = null;
      pendingExtinfLine = -1;
      discPending = false;
      gapPending = false;
    }
  }
  return { lines, segments };
}

function hasDiscontinuityImmediatelyBefore(lines, insertAt) {
  for (let i = Math.max(0, insertAt - 4); i < insertAt; i++) {
    if (String(lines[i] || '').startsWith('#EXT-X-DISCONTINUITY')) return true;
  }
  return false;
}

function shouldDiscontinue(prev, cur) {
  if (!prev || !cur || !prev.meta || !cur.meta || !prev.meta.ok || !cur.meta.ok) return false;
  const actualDelta = cur.meta.start - prev.meta.start;
  const expectedDelta = (cur.pdt !== null && prev.pdt !== null)
    ? (cur.pdt - prev.pdt)
    : (Number.isFinite(prev.duration) ? prev.duration : null);

  if (actualDelta < -0.5) return { yes: true, reason: `PTS reset ${prev.meta.start.toFixed(3)} -> ${cur.meta.start.toFixed(3)}` };
  if (expectedDelta !== null && expectedDelta >= 0) {
    const diff = Math.abs(actualDelta - expectedDelta);
    const threshold = Math.max(1.5, expectedDelta * 0.75);
    if (diff > threshold) {
      return { yes: true, reason: `PTS/PDT delta mismatch actual=${actualDelta.toFixed(3)} expected=${expectedDelta.toFixed(3)}` };
    }
  }
  return false;
}

function filterPlaylist(text, reqUrl) {
  if (!ENABLED || typeof text !== 'string' || !text.includes('#EXTM3U') || !text.includes('.ts')) return text;
  if (!isArchivePlaylistRequest(reqUrl)) return text;

  const stream = streamFromUrl(reqUrl);
  if (!stream) return text;

  const parsed = parsePlaylist(text);
  const { lines, segments } = parsed;
  if (segments.length < 2) return text;

  for (const seg of segments) {
    const file = safeLocalTsPath(stream, seg.uri);
    seg.localFile = file;
    seg.meta = file ? ffprobeMeta(file) : { ok: false };
  }

  const inserts = new Map();
  let prev = null;
  const inserted = [];

  for (const cur of segments) {
    if (cur.gap) { prev = cur; continue; }
    if (prev && !cur.alreadyDisc) {
      const decision = shouldDiscontinue(prev, cur);
      if (decision && decision.yes) {
        const insertAt = cur.pdtLine >= 0 ? cur.pdtLine : (cur.extinfLine >= 0 ? cur.extinfLine : cur.lineIndex);
        if (!hasDiscontinuityImmediatelyBefore(lines, insertAt)) {
          inserts.set(insertAt, '#EXT-X-DISCONTINUITY');
          inserted.push({ before: cur.uri.split('?')[0], reason: decision.reason });
        }
      }
    }
    prev = cur;
  }

  if (!inserts.size) return text;

  const out = [];
  for (let i = 0; i < lines.length; i++) {
    if (inserts.has(i)) out.push(inserts.get(i));
    out.push(lines[i]);
  }
  log('inserted discontinuities', { url: reqUrl, stream, count: inserted.length, inserted: inserted.slice(0, 8) });
  return out.join('\n');
}

function middleware() {
  return function ndHlsDiscontinuityMiddleware(req, res, next) {
    if (!ENABLED || !isArchivePlaylistRequest(req.url)) return next();

    const oldSend = res.send ? res.send.bind(res) : null;
    const oldEnd = res.end.bind(res);
    let filteredBySend = false;

    if (oldSend) {
      res.send = function ndV114Send(body) {
        const text = toText(body);
        if (text && text.includes('#EXTM3U')) {
          filteredBySend = true;
          try {
            const filtered = filterPlaylist(text, req.url);
            res.setHeader('X-Newdomofon-HLS-Discontinuity-Filter', VERSION);
            if (Buffer.isBuffer(body)) return oldSend(Buffer.from(filtered, 'utf8'));
            return oldSend(filtered);
          } catch (e) {
            console.error('[NewDomofon hls-discontinuity-v114] filter failed:', e);
            return oldSend(body);
          }
        }
        return oldSend(body);
      };
    }

    res.end = function ndV114End(chunk, encoding, cb) {
      if (!filteredBySend) {
        const text = toText(chunk);
        if (text && text.includes('#EXTM3U')) {
          try {
            const filtered = filterPlaylist(text, req.url);
            res.setHeader('X-Newdomofon-HLS-Discontinuity-Filter', VERSION);
            return oldEnd(Buffer.from(filtered, 'utf8'), encoding, cb);
          } catch (e) {
            console.error('[NewDomofon hls-discontinuity-v114] end filter failed:', e);
          }
        }
      }
      return oldEnd(chunk, encoding, cb);
    };

    next();
  };
}

module.exports = { VERSION, middleware, filterPlaylist, parsePlaylist };
NODE

node -c "$MODULE_JS"

log "Patch archive proxy server.js"
python3 - "$ARCHIVE_PROXY_JS" <<'PY'
from pathlib import Path
import re, sys
p = Path(sys.argv[1])
s = p.read_text()
if "hls-discontinuity-filter-v114" in s:
    print("server.js already contains v114 hook")
    sys.exit(0)

hook = r'''

// NewDomofon v114: insert HLS discontinuity tags when TS PTS resets/jumps inside DVR archive playlists.
try {
  const ndHlsDiscontinuityV114 = require('./hls-discontinuity-filter-v114');
  if (typeof app !== 'undefined' && app && typeof app.use === 'function') {
    app.use(ndHlsDiscontinuityV114.middleware());
    console.log('[NewDomofon hls-discontinuity-v114] middleware installed');
  }
} catch (e) {
  console.error('[NewDomofon hls-discontinuity-v114] middleware install failed:', e);
}
'''

patterns = [
    r"(const\s+app\s*=\s*express\s*\(\s*\)\s*;)",
    r"(let\s+app\s*=\s*express\s*\(\s*\)\s*;)",
    r"(var\s+app\s*=\s*express\s*\(\s*\)\s*;)",
]
for pat in patterns:
    m = re.search(pat, s)
    if m:
        s = s[:m.end()] + hook + s[m.end():]
        p.write_text(s)
        print("patched after express app creation")
        sys.exit(0)

print("ERROR: could not find express app creation in server.js. Manual insertion needed:", file=sys.stderr)
print("  const ndHlsDiscontinuityV114 = require('./hls-discontinuity-filter-v114');", file=sys.stderr)
print("  app.use(ndHlsDiscontinuityV114.middleware());", file=sys.stderr)
sys.exit(2)
PY

node -c "$ARCHIVE_PROXY_JS"

log "Restart archive proxy"
if systemctl list-unit-files | grep -q "^$SERVICE_NAME"; then
  systemctl restart "$SERVICE_NAME"
  sleep 1
  systemctl status "$SERVICE_NAME" --no-pager -l | sed -n '1,40p'
else
  echo "WARN: systemd unit not found: $SERVICE_NAME" >&2
fi

log "Installed"
echo "module:  $MODULE_JS"
echo "server:  $ARCHIVE_PROXY_JS"
echo "backup:  $BACKUP_DIR"
echo
echo "Check problematic playlist after restart:"
echo "  curl -k -I '<archive-url>' | grep -i X-Newdomofon-HLS-Discontinuity-Filter"
echo "  curl -k '<archive-url>' | sed -n '1,80p' | grep -n -E 'DISCONTINUITY|172105|172107|172111|172114'"
echo
echo "Disable filter without rollback:"
echo "  sudo systemctl edit $SERVICE_NAME"
echo "  [Service]"
echo "  Environment=ND_HLS_DISCONTINUITY_FILTER=0"
echo "  sudo systemctl daemon-reload && sudo systemctl restart $SERVICE_NAME"
