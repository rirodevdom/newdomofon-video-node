#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="${PROJECT_DIR:-/opt/newdomofon-video}"
TARGET="$PROJECT_DIR/smartyard-compat-proxy/server.js"
ENV_FILE="${ENV_FILE:-/etc/newdomofon-video/app.env}"
SERVICE="${SERVICE:-newdomofon-smartyard-compat.service}"
BACKUP_DIR="$PROJECT_DIR/backups/smartyard-recording-status-dvr-window-fix-$(date +%Y%m%d-%H%M%S)"

mkdir -p "$BACKUP_DIR"
cp -a "$TARGET" "$BACKUP_DIR/server.js.bak"
[ -f "$ENV_FILE" ] && cp -a "$ENV_FILE" "$BACKUP_DIR/app.env.bak" || true

cd "$PROJECT_DIR"

python3 - <<'PY'
from pathlib import Path
import re

p = Path('smartyard-compat-proxy/server.js')
s = p.read_text()

s = re.sub(r"const VERSION = '[^']+';", "const VERSION = 'v85.6-recording-status-dvr-window-fix';", s, count=1)

# Remove previous duplicates if present.
s = re.sub(r"^const\s+RECORDING_STATUS_MAX_QUERY_SECONDS\s*=.*?;\n", "", s, flags=re.M)
s = re.sub(r"^const\s+RECORDING_STATUS_FUTURE_GRACE_SECONDS\s*=.*?;\n", "", s, flags=re.M)

anchor = "const RECORDING_STATUS_LOOKBACK_DAYS = Math.max(1, Number(process.env.SMARTYARD_COMPAT_RECORDING_STATUS_LOOKBACK_DAYS || 31));"
if anchor not in s:
    anchor = "const RECORDING_STATUS_LOOKBACK_DAYS = Math.max(1, Number(process.env.SMARTYARD_COMPAT_RECORDING_STATUS_LOOKBACK_DAYS || 30));"
if anchor not in s:
    raise SystemExit('RECORDING_STATUS_LOOKBACK_DAYS anchor not found')

replacement_anchor = "const RECORDING_STATUS_LOOKBACK_DAYS = Math.max(1, Number(process.env.SMARTYARD_COMPAT_RECORDING_STATUS_LOOKBACK_DAYS || 30));"
s = s.replace(anchor, replacement_anchor + "\nconst RECORDING_STATUS_MAX_QUERY_SECONDS = Math.max(3600, Number(process.env.SMARTYARD_COMPAT_RECORDING_STATUS_MAX_QUERY_SECONDS || 30 * 24 * 60 * 60));\nconst RECORDING_STATUS_FUTURE_GRACE_SECONDS = Math.max(0, Number(process.env.SMARTYARD_COMPAT_RECORDING_STATUS_FUTURE_GRACE_SECONDS || 0));", 1)

# Replace fetchDvrArchiveRanges with a version that never asks node DVR for more than its /archive/ranges max window.
start = s.find('async function fetchDvrArchiveRanges(')
if start < 0:
    raise SystemExit('fetchDvrArchiveRanges not found')
brace = s.find('{', start)
depth = 0
i = brace
while i < len(s):
    if s[i] == '{':
        depth += 1
    elif s[i] == '}':
        depth -= 1
        if depth == 0:
            end = i + 1
            break
    i += 1
else:
    raise SystemExit('fetchDvrArchiveRanges end not found')

new_fn = r'''async function fetchDvrArchiveRanges(stream, reqUrl, token) {
  if (!RECORDING_STATUS_FROM_DVR) return null;

  const fromSec = Number(reqUrl.searchParams.get('from') || 0);

  // DVR node /archive/ranges has a max window. SmartYard-Server asks with a very
  // old hardcoded from=1525186456, so cap the request before sending it upstream.
  const endMs = Date.now() + RECORDING_STATUS_FUTURE_GRACE_SECONDS * 1000;
  const configuredLookbackSeconds = Math.max(3600, RECORDING_STATUS_LOOKBACK_DAYS * 86400);
  const effectiveLookbackSeconds = Math.min(configuredLookbackSeconds, RECORDING_STATUS_MAX_QUERY_SECONDS);
  const lookbackStartMs = endMs - effectiveLookbackSeconds * 1000;

  let startMs = Number.isFinite(fromSec) && fromSec > 0
    ? fromSec * 1000
    : lookbackStartMs;

  if (RECORDING_STATUS_CAP_OLD_FROM && startMs < lookbackStartMs) startMs = lookbackStartMs;
  if (startMs >= endMs) startMs = endMs - Math.min(3600, effectiveLookbackSeconds) * 1000;

  const startIso = new Date(startMs).toISOString();
  const endIso = new Date(endMs).toISOString();
  const path = `/cameras/${encodeURIComponent(stream)}/archive/ranges?start=${encodeURIComponent(startIso)}&end=${encodeURIComponent(endIso)}`;
  const upstream = await fetchUpstream(path, 15000, tokenForPlaylist(token));
  const text = await upstream.text();
  if (!upstream.ok) {
    console.warn('[smartyard-compat] dvr archive ranges failed', { stream, status: upstream.status, startIso, endIso, body: text.slice(0, 300) });
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
}'''

s = s[:start] + new_fn + s[end:]

# Add diagnostic headers once.
s = s.replace("'x-newdomofon-ranges-cap-old-from': RECORDING_STATUS_CAP_OLD_FROM ? '1' : '0',", "'x-newdomofon-ranges-cap-old-from': RECORDING_STATUS_CAP_OLD_FROM ? '1' : '0',\n      'x-newdomofon-ranges-max-query-seconds': String(RECORDING_STATUS_MAX_QUERY_SECONDS),", 1)
s = s.replace("'x-newdomofon-ranges-cap-old-from': RECORDING_STATUS_CAP_OLD_FROM ? '1' : '0'", "'x-newdomofon-ranges-cap-old-from': RECORDING_STATUS_CAP_OLD_FROM ? '1' : '0',\n    'x-newdomofon-ranges-max-query-seconds': String(RECORDING_STATUS_MAX_QUERY_SECONDS)", 1)

p.write_text(s)
PY

# Keep the default under the node DVR /archive/ranges limit.
sudo sed -i -E '/^(SMARTYARD_COMPAT_RECORDING_STATUS_LOOKBACK_DAYS|SMARTYARD_COMPAT_RECORDING_STATUS_MAX_QUERY_SECONDS|SMARTYARD_COMPAT_RECORDING_STATUS_FUTURE_GRACE_SECONDS)=/d' "$ENV_FILE" 2>/dev/null || true
cat <<'EOF' | sudo tee -a "$ENV_FILE" >/dev/null
SMARTYARD_COMPAT_RECORDING_STATUS_LOOKBACK_DAYS=30
SMARTYARD_COMPAT_RECORDING_STATUS_MAX_QUERY_SECONDS=2592000
SMARTYARD_COMPAT_RECORDING_STATUS_FUTURE_GRACE_SECONDS=0
EOF

sudo mkdir -p /etc/systemd/system/${SERVICE}.d
if [ -f /etc/systemd/system/${SERVICE}.d/override.conf ]; then
  sudo sed -i -E '/^Environment=SMARTYARD_COMPAT_RECORDING_STATUS_LOOKBACK_DAYS=/d;/^Environment=SMARTYARD_COMPAT_RECORDING_STATUS_MAX_QUERY_SECONDS=/d;/^Environment=SMARTYARD_COMPAT_RECORDING_STATUS_FUTURE_GRACE_SECONDS=/d' /etc/systemd/system/${SERVICE}.d/override.conf
  sudo tee -a /etc/systemd/system/${SERVICE}.d/override.conf >/dev/null <<'EOF'
Environment=SMARTYARD_COMPAT_RECORDING_STATUS_LOOKBACK_DAYS=30
Environment=SMARTYARD_COMPAT_RECORDING_STATUS_MAX_QUERY_SECONDS=2592000
Environment=SMARTYARD_COMPAT_RECORDING_STATUS_FUTURE_GRACE_SECONDS=0
EOF
fi

node --check "$TARGET"
sudo systemctl daemon-reload
sudo systemctl restart "$SERVICE"
sleep 2
systemctl --no-pager --full status "$SERVICE" | sed -n '1,18p'
echo "---- health ----"
curl -fsS http://127.0.0.1:3082/health || true
echo

echo "OK: recording_status DVR upstream window is now capped below node DVR limit"
echo "backup_dir=$BACKUP_DIR"
