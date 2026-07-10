#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="${PROJECT_DIR:-/opt/newdomofon-video-node}"
TARGET="$PROJECT_DIR/smartyard-compat-proxy/server.js"
ENV_FILE="${ENV_FILE:-/etc/newdomofon-video/app.env}"
NODE_DVR_URL="${NODE_DVR_URL:-http://10.106.1.31:3010}"
SERVICE="${SERVICE:-newdomofon-smartyard-compat.service}"
BACKUP_DIR="$PROJECT_DIR/backups/recover-smartyard-compat-node-url-$(date +%Y%m%d-%H%M%S)"

mkdir -p "$BACKUP_DIR"
cp -a "$TARGET" "$BACKUP_DIR/server.js.bak"
[ -f "$ENV_FILE" ] && cp -a "$ENV_FILE" "$BACKUP_DIR/app.env.bak" || true

cd "$PROJECT_DIR"

python3 - <<'PY'
from pathlib import Path
import re

p = Path('smartyard-compat-proxy/server.js')
s = p.read_text()

# 1) Remove duplicate const declarations left by previous partial patch attempts.
remove_names = [
    'LIVE_FROM_DVR',
    'RECORDING_STATUS_FROM_DVR',
    'ARCHIVE_PLAYLIST_FROM_DVR',
    'RECORDING_STATUS_LOOKBACK_DAYS',
]
for name in remove_names:
    s = re.sub(rf"^const\s+{name}\s*=.*?;\n", '', s, flags=re.M)

# 2) Keep one VERSION declaration.
s = re.sub(r"^const VERSION = '.*?';\n", '', s, flags=re.M)
version_anchor = "const PORT = Number(process.env.SMARTYARD_COMPAT_PORT || 3082);"
if version_anchor not in s:
    raise SystemExit('PORT anchor not found')
s = s.replace(version_anchor, "const VERSION = 'v85.1-recovered-node-dvr-url';\n" + version_anchor, 1)

# 3) Insert the media-source switches exactly once after LIVE_PLAYLIST_MAX_AGE_MS.
anchor = "const LIVE_PLAYLIST_MAX_AGE_MS = Number(process.env.LIVE_PLAYLIST_MAX_AGE_MS || 30000);"
if anchor not in s:
    raise SystemExit('LIVE_PLAYLIST_MAX_AGE_MS anchor not found')
insert = anchor + """
const LIVE_FROM_DVR = !['0', 'false', 'no', 'off'].includes(String(process.env.SMARTYARD_COMPAT_LIVE_FROM_DVR || 'true').toLowerCase());
const RECORDING_STATUS_FROM_DVR = !['0', 'false', 'no', 'off'].includes(String(process.env.SMARTYARD_COMPAT_RECORDING_STATUS_FROM_DVR || 'true').toLowerCase());
const ARCHIVE_PLAYLIST_FROM_DVR = !['0', 'false', 'no', 'off'].includes(String(process.env.SMARTYARD_COMPAT_ARCHIVE_PLAYLIST_FROM_DVR || 'true').toLowerCase());
const RECORDING_STATUS_LOOKBACK_DAYS = Math.max(1, Number(process.env.SMARTYARD_COMPAT_RECORDING_STATUS_LOOKBACK_DAYS || 31));"""
s = s.replace(anchor, insert, 1)

# 4) Make token-forwarding fetchUpstream idempotent and syntactically clean.
if 'function upstreamPathWithToken' not in s:
    marker = 'async function fetchUpstream(pathname, timeoutMs = 5000'
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
    idx = s.find(marker)
    if idx < 0:
        raise SystemExit('fetchUpstream marker not found')
    s = s[:idx] + helper + s[idx:]

s = re.sub(r"async function fetchUpstream\(pathname, timeoutMs = 5000(?:, token = '')?\) \{", "async function fetchUpstream(pathname, timeoutMs = 5000, token = '') {", s, count=1)

# Ensure upstreamPath exists inside fetchUpstream exactly once.
def ensure_fetch_upstream_path(src: str) -> str:
    start = src.find('async function fetchUpstream(')
    if start < 0:
        raise SystemExit('fetchUpstream function not found')
    brace = src.find('{', start)
    depth = 0
    i = brace
    while i < len(src):
        if src[i] == '{':
            depth += 1
        elif src[i] == '}':
            depth -= 1
            if depth == 0:
                end = i + 1
                fn = src[start:end]
                fn = re.sub(r"\n\s*const upstreamPath = upstreamPathWithToken\(pathname, token\);", '', fn)
                fn = fn.replace(
                    "  const timer = setTimeout(() => controller.abort(), timeoutMs);",
                    "  const timer = setTimeout(() => controller.abort(), timeoutMs);\n  const upstreamPath = upstreamPathWithToken(pathname, token);",
                    1,
                )
                fn = fn.replace('fetch(`${DVR_ENGINE_URL}${pathname}`, {', 'fetch(`${DVR_ENGINE_URL}${upstreamPath}`, {')
                return src[:start] + fn + src[end:]
        i += 1
    raise SystemExit('fetchUpstream function end not found')

s = ensure_fetch_upstream_path(s)

# 5) Ensure token auth can be deferred to node DVR for camera scope tokens.
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
        raise SystemExit('permanent-camera-token end marker not found')
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

p.write_text(s)
PY

# Force SmartYard compat to use node DVR. Do it via systemd drop-in because unit has hardcoded 127.0.0.1:3010.
sudo mkdir -p /etc/systemd/system/${SERVICE}.d
sudo tee /etc/systemd/system/${SERVICE}.d/override.conf >/dev/null <<EOF
[Service]
Environment=NODE_ENV=production
Environment=SMARTYARD_COMPAT_PORT=3082
Environment=DVR_ENGINE_URL=${NODE_DVR_URL}
Environment=SMARTYARD_COMPAT_LIVE_FROM_DVR=true
Environment=SMARTYARD_COMPAT_RECORDING_STATUS_FROM_DVR=true
Environment=SMARTYARD_COMPAT_ARCHIVE_PLAYLIST_FROM_DVR=true
Environment=SMARTYARD_COMPAT_RECORDING_STATUS_LOOKBACK_DAYS=31
Environment=SMARTYARD_COMPAT_DEFER_CAMERA_TOKEN_AUTH_TO_DVR=true
EOF

# Keep app.env consistent too, but systemd override is authoritative.
sudo sed -i -E '/^(SMARTYARD_COMPAT_LIVE_FROM_DVR|SMARTYARD_COMPAT_RECORDING_STATUS_FROM_DVR|SMARTYARD_COMPAT_ARCHIVE_PLAYLIST_FROM_DVR|SMARTYARD_COMPAT_RECORDING_STATUS_LOOKBACK_DAYS|SMARTYARD_COMPAT_DEFER_CAMERA_TOKEN_AUTH_TO_DVR|DVR_ENGINE_URL)=/d' "$ENV_FILE" 2>/dev/null || true
cat <<EOF | sudo tee -a "$ENV_FILE" >/dev/null
SMARTYARD_COMPAT_LIVE_FROM_DVR=true
SMARTYARD_COMPAT_RECORDING_STATUS_FROM_DVR=true
SMARTYARD_COMPAT_ARCHIVE_PLAYLIST_FROM_DVR=true
SMARTYARD_COMPAT_RECORDING_STATUS_LOOKBACK_DAYS=31
SMARTYARD_COMPAT_DEFER_CAMERA_TOKEN_AUTH_TO_DVR=true
DVR_ENGINE_URL=${NODE_DVR_URL}
EOF

node --check "$TARGET"
sudo systemctl daemon-reload
sudo systemctl restart "$SERVICE"
sleep 2

systemctl --no-pager --full status "$SERVICE" | sed -n '1,18p'
echo "---- effective environment ----"
systemctl show "$SERVICE" -p Environment

echo "---- compat health ----"
curl -fsS http://127.0.0.1:3082/health || true
echo

echo "OK: SmartYard compat recovered and pointed to ${NODE_DVR_URL}"
echo "backup_dir=$BACKUP_DIR"
