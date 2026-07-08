#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="${PROJECT_DIR:-/opt/newdomofon-video}"
TARGET="$PROJECT_DIR/smartyard-compat-proxy/server.js"
ENV_FILE="${ENV_FILE:-/etc/newdomofon-video/app.env}"
BACKUP_DIR="$PROJECT_DIR/backups/smartyard-compat-force-node-media-source-$(date +%Y%m%d-%H%M%S)"

mkdir -p "$BACKUP_DIR"
cp -a "$TARGET" "$BACKUP_DIR/server.js.bak"
[ -f "$ENV_FILE" ] && cp -a "$ENV_FILE" "$BACKUP_DIR/app.env.bak" || true

cd "$PROJECT_DIR"

python3 - <<'PY'
from pathlib import Path
import re

p = Path('smartyard-compat-proxy/server.js')
s = p.read_text()

s = re.sub(r"const VERSION = '[^']+';", "const VERSION = 'v85.0-force-node-media-source';", s, count=1)

needle = "const LIVE_PLAYLIST_MAX_AGE_MS = Number(process.env.LIVE_PLAYLIST_MAX_AGE_MS || 30000);"
insert = """const LIVE_PLAYLIST_MAX_AGE_MS = Number(process.env.LIVE_PLAYLIST_MAX_AGE_MS || 30000);
const LIVE_FROM_DVR = !['0', 'false', 'no', 'off'].includes(String(process.env.SMARTYARD_COMPAT_LIVE_FROM_DVR || 'true').toLowerCase());
const RECORDING_STATUS_FROM_DVR = !['0', 'false', 'no', 'off'].includes(String(process.env.SMARTYARD_COMPAT_RECORDING_STATUS_FROM_DVR || 'true').toLowerCase());
const ARCHIVE_PLAYLIST_FROM_DVR = !['0', 'false', 'no', 'off'].includes(String(process.env.SMARTYARD_COMPAT_ARCHIVE_PLAYLIST_FROM_DVR || 'true').toLowerCase());
const RECORDING_STATUS_LOOKBACK_DAYS = Math.max(1, Number(process.env.SMARTYARD_COMPAT_RECORDING_STATUS_LOOKBACK_DAYS || 31));"""
if needle in s and 'const LIVE_FROM_DVR =' not in s:
    s = s.replace(needle, insert, 1)

# Add decoded camera-token auth fallback. The node still validates the HMAC on every DVR request.
if 'function __ndDecodeCameraTokenPayload' not in s:
    marker = '/* END newdomofon-accept-permanent-camera-token */'
    addon = r'''
function __ndDecodeCameraTokenPayload(token) {
  try {
    const raw = String(token || '').trim();
    const parts = raw.split('.');
    const payloadPart = parts.length === 3 ? parts[1] : parts[0];
    if (!payloadPart) return null;
    const payload = JSON.parse(Buffer.from(payloadPart, 'base64url').toString('utf8'));
    if (!payload || typeof payload !== 'object') return null;
    if (String(payload.scope || '') !== 'camera') return null;
    if (!payload.stream_name) return null;
    if (payload.exp && Number(payload.exp) < Math.floor(Date.now() / 1000)) return null;
    return payload;
  } catch {
    return null;
  }
}

function __ndAllowDeferCameraTokenToDvr(token, stream) {
  if (!['1', 'true', 'yes', 'on'].includes(String(process.env.SMARTYARD_COMPAT_DEFER_CAMERA_TOKEN_AUTH_TO_DVR || '').toLowerCase())) return false;
  const payload = __ndDecodeCameraTokenPayload(token);
  return Boolean(payload && String(payload.stream_name || '') === String(stream || ''));
}
'''
    if marker not in s:
        raise SystemExit('camera-token marker not found')
    s = s.replace(marker, addon + '\n' + marker, 1)

s = re.sub(
    r"function isAcceptedToken\(token(?:,\s*stream\s*=\s*''\s*)?\) \{[\s\S]*?\n\}",
    """function isAcceptedToken(token, stream = '') {
  if (__ndAcceptPermanentCameraToken(token)) return true;
  if (__ndAllowDeferCameraTokenToDvr(token, stream)) return true;
  return acceptedTokens().includes(String(token || ''));
}""",
    s,
    count=1,
)
s = s.replace('if (!isAcceptedToken(actualToken)) {', 'if (!isAcceptedToken(actualToken, stream)) {')

# Ensure fetchUpstream can append token to node DVR requests.
if 'function upstreamPathWithToken' not in s:
    marker = 'async function fetchUpstream(pathname, timeoutMs = 5000) {'
    helper = r'''function upstreamPathWithToken(pathname, token) {
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

'''
    if marker not in s:
        raise SystemExit('fetchUpstream marker not found')
    s = s.replace(marker, helper + marker, 1)

s = s.replace('async function fetchUpstream(pathname, timeoutMs = 5000) {', "async function fetchUpstream(pathname, timeoutMs = 5000, token = '') {")
if 'const upstreamPath = upstreamPathWithToken(pathname, token);' not in s:
    s = s.replace('  const timer = setTimeout(() => controller.abort(), timeoutMs);\n  try {', '  const timer = setTimeout(() => controller.abort(), timeoutMs);\n  const upstreamPath = upstreamPathWithToken(pathname, token);\n  try {', 1)
s = s.replace('fetch(`${DVR_ENGINE_URL}${pathname}`, {', 'fetch(`${DVR_ENGINE_URL}${upstreamPath}`, {')


def replace_function(src, name, replacement):
    start = src.find(f'async function {name}')
    if start < 0:
        raise SystemExit(f'{name} not found')
    brace = src.find('{', start)
    depth = 0
    i = brace
    while i < len(src):
        if src[i] == '{':
            depth += 1
        elif src[i] == '}':
            depth -= 1
            if depth == 0:
                i += 1
                return src[:start] + replacement + src[i:]
        i += 1
    raise SystemExit(f'{name} end not found')

# Helpers for DVR ranges.
if 'function smartyardRangeFromIso' not in s:
    marker = 'async function handleRecordingStatus'
    helper = r'''function smartyardRangeFromIso(startIso, endIso) {
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
  const upstreamPath = `/cameras/${encodeURIComponent(stream)}/archive/ranges?start=${encodeURIComponent(startIso)}&end=${encodeURIComponent(endIso)}`;
  const upstream = await fetchUpstream(upstreamPath, 15000, tokenForPlaylist(token));
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
    s = s.replace(marker, helper + marker, 1)

s = replace_function(s, 'handleRecordingStatus', r'''async function handleRecordingStatus(res, stream, reqUrl, token = '') {
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
    'x-newdomofon-ranges-source': 'local-filesystem-fallback',
    'x-newdomofon-ranges-count': String(ranges.length),
    'x-newdomofon-segments-count': String(segments.length)
  });
}''')

s = replace_function(s, 'handleLive', r'''async function handleLive(res, stream, token) {
  const tokenToUse = tokenForPlaylist(token);

  if (LIVE_FROM_DVR) {
    const upstream = await fetchUpstream(`/cameras/${encodeURIComponent(stream)}/live.m3u8`, 5000, tokenToUse);
    const body = await upstream.text();
    if (upstream.ok) {
      sendText(
        res,
        upstream.status,
        body,
        upstream.headers.get('content-type') || 'application/vnd.apple.mpegurl; charset=utf-8',
        { 'x-newdomofon-resolved-stream': stream, 'x-newdomofon-live-source': 'dvr-engine' }
      );
      return;
    }
    console.warn('[smartyard-compat] dvr live playlist failed, falling back to local filesystem', { stream, status: upstream.status, body: body.slice(0, 300) });
  }

  const direct = await findLivePlaylistFile(stream);

  if (direct) {
    const ageMs = Date.now() - direct.stat.mtimeMs;
    const body = await fsp.readFile(direct.filePath, 'utf8');
    sendText(
      res,
      200,
      normalizePlaylist(body, tokenToUse, stream),
      'application/vnd.apple.mpegurl; charset=utf-8',
      {
        'x-newdomofon-resolved-stream': stream,
        'x-newdomofon-live-source': 'filesystem-fallback',
        'x-newdomofon-live-age-ms': String(Math.max(0, Math.floor(ageMs))),
        'x-newdomofon-live-stale': ageMs > LIVE_PLAYLIST_MAX_AGE_MS ? '1' : '0'
      }
    );
    return;
  }

  const upstream = await fetchUpstream(`/cameras/${encodeURIComponent(stream)}/live.m3u8`, 5000, tokenToUse);
  const body = await upstream.text();
  const contentType = upstream.headers.get('content-type') || 'application/vnd.apple.mpegurl; charset=utf-8';

  sendText(
    res,
    upstream.status,
    upstream.ok ? body : body,
    contentType,
    { 'x-newdomofon-resolved-stream': stream, 'x-newdomofon-live-source': 'dvr-engine-fallback' }
  );
}''')

s = replace_function(s, 'handleArchivePlaylist', r'''async function handleArchivePlaylist(res, stream, mediaPath, reqUrl, token) {
  let win = parseArchiveWindow(mediaPath, reqUrl);
  if (!win) {
    const now = Date.now();
    win = { startMs: now - 3600_000, endMs: now, source: 'default-last-hour' };
  }

  if (ARCHIVE_PLAYLIST_FROM_DVR) {
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

  const segments = await scanSegments(stream, win.startMs, win.endMs);
  if (!segments.length) {
    sendJson(res, 404, {
      error: 'No archive segments in selected range',
      stream_name: stream,
      start: new Date(win.startMs).toISOString(),
      end: new Date(win.endMs).toISOString(),
      source: win.source
    }, { 'x-newdomofon-resolved-stream': stream, 'x-newdomofon-archive-source': 'local-filesystem-fallback' });
    return;
  }

  sendText(res, 200, archivePlaylist(segments, tokenForPlaylist(token)), 'application/vnd.apple.mpegurl; charset=utf-8', {
    'x-newdomofon-resolved-stream': stream,
    'x-newdomofon-archive-source': 'local-filesystem-fallback',
    'x-newdomofon-archive-window-source': win.source
  });
}''')

s = s.replace('await handleRecordingStatus(res, stream, reqUrl);', 'await handleRecordingStatus(res, stream, reqUrl, actualToken);')

p.write_text(s)
PY

sudo sed -i -E '/^(SMARTYARD_COMPAT_LIVE_FROM_DVR|SMARTYARD_COMPAT_RECORDING_STATUS_FROM_DVR|SMARTYARD_COMPAT_ARCHIVE_PLAYLIST_FROM_DVR|SMARTYARD_COMPAT_RECORDING_STATUS_LOOKBACK_DAYS|SMARTYARD_COMPAT_DEFER_CAMERA_TOKEN_AUTH_TO_DVR)=/d' "$ENV_FILE"
cat <<'EOF' | sudo tee -a "$ENV_FILE" >/dev/null
SMARTYARD_COMPAT_LIVE_FROM_DVR=true
SMARTYARD_COMPAT_RECORDING_STATUS_FROM_DVR=true
SMARTYARD_COMPAT_ARCHIVE_PLAYLIST_FROM_DVR=true
SMARTYARD_COMPAT_RECORDING_STATUS_LOOKBACK_DAYS=31
SMARTYARD_COMPAT_DEFER_CAMERA_TOKEN_AUTH_TO_DVR=true
EOF

node --check "$TARGET"
sudo systemctl restart newdomofon-smartyard-compat.service
sleep 2
systemctl --no-pager --full status newdomofon-smartyard-compat.service | sed -n '1,18p'
echo "OK: SmartYard compat forced to node DVR for live, recording_status and archive playlists"
echo "backup_dir=$BACKUP_DIR"
