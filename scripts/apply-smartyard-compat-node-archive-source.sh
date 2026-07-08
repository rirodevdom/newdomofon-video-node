#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="${PROJECT_DIR:-/opt/newdomofon-video}"
TARGET="$PROJECT_DIR/smartyard-compat-proxy/server.js"
ENV_FILE="${ENV_FILE:-/etc/newdomofon-video/app.env}"
BACKUP_DIR="$PROJECT_DIR/backups/smartyard-compat-node-archive-source-$(date +%Y%m%d-%H%M%S)"

mkdir -p "$BACKUP_DIR"
cp -a "$TARGET" "$BACKUP_DIR/server.js.bak"
[ -f "$ENV_FILE" ] && cp -a "$ENV_FILE" "$BACKUP_DIR/app.env.bak" || true

cd "$PROJECT_DIR"

python3 - <<'PY'
from pathlib import Path
import re

p = Path('smartyard-compat-proxy/server.js')
s = p.read_text()

# Bump visible version marker once.
s = re.sub(
    r"const VERSION = '([^']+)';",
    "const VERSION = 'v84.0-node-archive-source';",
    s,
    count=1,
)

# Add env switches after LIVE_PLAYLIST_MAX_AGE_MS.
needle = "const LIVE_PLAYLIST_MAX_AGE_MS = Number(process.env.LIVE_PLAYLIST_MAX_AGE_MS || 30000);"
insert = """const LIVE_PLAYLIST_MAX_AGE_MS = Number(process.env.LIVE_PLAYLIST_MAX_AGE_MS || 30000);
const RECORDING_STATUS_FROM_DVR = !['0', 'false', 'no', 'off'].includes(String(process.env.SMARTYARD_COMPAT_RECORDING_STATUS_FROM_DVR || 'true').toLowerCase());
const ARCHIVE_PLAYLIST_FROM_DVR = !['0', 'false', 'no', 'off'].includes(String(process.env.SMARTYARD_COMPAT_ARCHIVE_PLAYLIST_FROM_DVR || 'true').toLowerCase());
const RECORDING_STATUS_LOOKBACK_DAYS = Math.max(1, Number(process.env.SMARTYARD_COMPAT_RECORDING_STATUS_LOOKBACK_DAYS || 14));"""
if needle in s and 'SMARTYARD_COMPAT_RECORDING_STATUS_FROM_DVR' not in s:
    s = s.replace(needle, insert, 1)

# Make fetchUpstream able to append token if this was not done by the single-link patch yet.
if 'function upstreamPathWithToken' not in s:
    old = """async function fetchUpstream(pathname, timeoutMs = 5000) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    return await fetch(`${DVR_ENGINE_URL}${pathname}`, {
"""
    new = """function upstreamPathWithToken(pathname, token) {
  if (!token) return pathname;
  try {
    const parsed = new URL(String(pathname), 'http://newdomofon.local');
    parsed.searchParams.set('token', token);
    return `${parsed.pathname}${parsed.search}`;
  } catch {
    const sep = String(pathname).includes('?') ? '&' : '?';
    return `${pathname}${sep}token=${encodeURIComponent(token)}`;
  }
}

async function fetchUpstream(pathname, timeoutMs = 5000, token = '') {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  const upstreamPath = upstreamPathWithToken(pathname, token);
  try {
    return await fetch(`${DVR_ENGINE_URL}${upstreamPath}`, {
"""
    if old not in s:
        raise SystemExit('fetchUpstream block not found')
    s = s.replace(old, new, 1)
else:
    s = s.replace('async function fetchUpstream(pathname, timeoutMs = 5000) {', "async function fetchUpstream(pathname, timeoutMs = 5000, token = '') {")

# If fetchUpstream function exists with upstreamPath but still fetches pathname, fix it.
s = s.replace('fetch(`${DVR_ENGINE_URL}${pathname}`, {', 'fetch(`${DVR_ENGINE_URL}${upstreamPath}`, {')

# Add helper functions before handleRecordingStatus.
if 'async function fetchDvrArchiveRanges' not in s:
    marker = 'async function handleRecordingStatus(res, stream, reqUrl) {'
    helper = r'''
function smartyardRangeFromIso(startIso, endIso) {
  const startMs = Date.parse(startIso);
  const endMs = Date.parse(endIso);
  if (!Number.isFinite(startMs) || !Number.isFinite(endMs) || endMs <= startMs) return null;
  return {
    from: Math.floor(startMs / 1000),
    duration: Math.max(1, Math.ceil((endMs - startMs) / 1000))
  };
}

async function fetchDvrArchiveRanges(stream, reqUrl, token) {
  if (!RECORDING_STATUS_FROM_DVR) return null;
  const fromSec = Number(reqUrl.searchParams.get('from') || 0);
  const startMs = Number.isFinite(fromSec) && fromSec > 0
    ? fromSec * 1000
    : Date.now() - RECORDING_STATUS_LOOKBACK_DAYS * 86400_000;
  const endMs = Date.now() + 10 * 60_000;
  const startIso = new Date(startMs).toISOString();
  const endIso = new Date(endMs).toISOString();
  const path = `/cameras/${encodeURIComponent(stream)}/archive/ranges?start=${encodeURIComponent(startIso)}&end=${encodeURIComponent(endIso)}`;
  const upstream = await fetchUpstream(path, 15000, tokenForPlaylist(token));
  const text = await upstream.text();
  if (!upstream.ok) {
    console.warn('[smartyard-compat] dvr archive ranges failed', { stream, status: upstream.status, body: text.slice(0, 300) });
    return null;
  }
  try {
    const parsed = JSON.parse(text);
    const items = Array.isArray(parsed) ? parsed : Array.isArray(parsed.items) ? parsed.items : [];
    const ranges = items
      .map((item) => smartyardRangeFromIso(item.start || item.from || item.start_at, item.end || item.to || item.end_at))
      .filter(Boolean);
    return { ranges, startIso, endIso, rawCount: items.length };
  } catch (error) {
    console.warn('[smartyard-compat] dvr archive ranges parse failed', { stream, error: String(error), body: text.slice(0, 300) });
    return null;
  }
}

'''
    if marker not in s:
        raise SystemExit('handleRecordingStatus marker not found')
    s = s.replace(marker, helper + marker, 1)

# Replace handleRecordingStatus implementation.
old = r'''async function handleRecordingStatus(res, stream, reqUrl) {
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
'''
new = r'''async function handleRecordingStatus(res, stream, reqUrl, token = '') {
  const dvrRanges = await fetchDvrArchiveRanges(stream, reqUrl, token);
  if (dvrRanges) {
    sendJson(res, 200, [
      {
        stream,
        ranges: dvrRanges.ranges
      }
    ], {
      'x-newdomofon-resolved-stream': stream,
      'x-newdomofon-ranges-source': 'dvr-engine',
      'x-newdomofon-ranges-count': String(dvrRanges.ranges.length),
      'x-newdomofon-ranges-raw-count': String(dvrRanges.rawCount),
      'x-newdomofon-ranges-start': dvrRanges.startIso,
      'x-newdomofon-ranges-end': dvrRanges.endIso
    });
    return;
  }

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
    'x-newdomofon-ranges-source': 'local-filesystem',
    'x-newdomofon-ranges-count': String(ranges.length),
    'x-newdomofon-segments-count': String(segments.length)
  });
}
'''
if old not in s:
    raise SystemExit('old handleRecordingStatus implementation not found')
s = s.replace(old, new, 1)

# Patch handle call to pass actualToken.
s = s.replace('await handleRecordingStatus(res, stream, reqUrl);', 'await handleRecordingStatus(res, stream, reqUrl, actualToken);')

# Add DVR-first archive playlist before local scan.
if 'x-newdomofon-archive-source' not in s:
    marker = """  const segments = await scanSegments(stream, win.startMs, win.endMs);
"""
    insert = r'''  if (ARCHIVE_PLAYLIST_FROM_DVR) {
    const tokenToUse = tokenForPlaylist(token);
    const startIso = new Date(win.startMs).toISOString();
    const endIso = new Date(win.endMs).toISOString();
    const upstreamPath = `/cameras/${encodeURIComponent(stream)}/archive.m3u8?start=${encodeURIComponent(startIso)}&end=${encodeURIComponent(endIso)}`;
    const upstream = await fetchUpstream(upstreamPath, 15000, tokenToUse);
    const body = await upstream.text();
    if (upstream.ok) {
      sendText(res, upstream.status, body, upstream.headers.get('content-type') || 'application/vnd.apple.mpegurl; charset=utf-8', {
        'x-newdomofon-resolved-stream': stream,
        'x-newdomofon-archive-source': 'dvr-engine',
        'x-newdomofon-archive-window-source': win.source
      });
      return;
    }
    console.warn('[smartyard-compat] dvr archive playlist failed, falling back to local scan', { stream, status: upstream.status, body: body.slice(0, 300) });
  }

'''
    if marker not in s:
        raise SystemExit('archive playlist scan marker not found')
    s = s.replace(marker, insert + marker, 1)

p.write_text(s)
PY

# Enable DVR as archive source for SmartYard compat on master.
sudo sed -i -E '/^(SMARTYARD_COMPAT_RECORDING_STATUS_FROM_DVR|SMARTYARD_COMPAT_ARCHIVE_PLAYLIST_FROM_DVR|SMARTYARD_COMPAT_RECORDING_STATUS_LOOKBACK_DAYS)=/d' "$ENV_FILE"
cat <<'EOF' | sudo tee -a "$ENV_FILE" >/dev/null
SMARTYARD_COMPAT_RECORDING_STATUS_FROM_DVR=true
SMARTYARD_COMPAT_ARCHIVE_PLAYLIST_FROM_DVR=true
SMARTYARD_COMPAT_RECORDING_STATUS_LOOKBACK_DAYS=31
EOF

node --check "$TARGET"
sudo systemctl restart newdomofon-smartyard-compat.service
sleep 2
systemctl --no-pager --full status newdomofon-smartyard-compat.service | sed -n '1,18p'
echo "OK: SmartYard compat now prefers node DVR for recording_status and archive playlists"
echo "backup_dir=$BACKUP_DIR"
