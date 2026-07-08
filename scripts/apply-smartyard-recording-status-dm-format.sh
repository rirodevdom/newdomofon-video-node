#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="${PROJECT_DIR:-/opt/newdomofon-video}"
TARGET="$PROJECT_DIR/smartyard-compat-proxy/server.js"
ENV_FILE="${ENV_FILE:-/etc/newdomofon-video/app.env}"
SERVICE="${SERVICE:-newdomofon-smartyard-compat.service}"
BACKUP_DIR="$PROJECT_DIR/backups/smartyard-recording-status-dm-format-$(date +%Y%m%d-%H%M%S)"

mkdir -p "$BACKUP_DIR"
cp -a "$TARGET" "$BACKUP_DIR/server.js.bak"
[ -f "$ENV_FILE" ] && cp -a "$ENV_FILE" "$BACKUP_DIR/app.env.bak" || true

cd "$PROJECT_DIR"

python3 - <<'PY'
from pathlib import Path
import re

p = Path('smartyard-compat-proxy/server.js')
s = p.read_text()

s = re.sub(r"const VERSION = '[^']+';", "const VERSION = 'v85.2-recording-status-dm-format';", s, count=1)

# Add format switch exactly once.
anchor_candidates = [
    "const RECORDING_STATUS_LOOKBACK_DAYS = Math.max(1, Number(process.env.SMARTYARD_COMPAT_RECORDING_STATUS_LOOKBACK_DAYS || 31));",
    "const LIVE_PLAYLIST_MAX_AGE_MS = Number(process.env.LIVE_PLAYLIST_MAX_AGE_MS || 30000);",
]
if 'SMARTYARD_COMPAT_RECORDING_STATUS_FORMAT' not in s:
    for anchor in anchor_candidates:
        if anchor in s:
            s = s.replace(anchor, anchor + "\nconst RECORDING_STATUS_FORMAT = String(process.env.SMARTYARD_COMPAT_RECORDING_STATUS_FORMAT || 'dm-object').toLowerCase();", 1)
            break
    else:
        raise SystemExit('Cannot find insertion point for RECORDING_STATUS_FORMAT')

helper = r'''
function normalizeSmartYardRange(range) {
  if (!range || typeof range !== 'object') return null;
  const from = Number(range.from ?? range.start_sec ?? range.start);
  const duration = Number(range.duration ?? range.dur);
  const to = Number(range.to ?? range.end_sec ?? range.end);
  if (Number.isFinite(from) && Number.isFinite(duration) && duration > 0) {
    return { from: Math.floor(from), duration: Math.ceil(duration), to: Math.floor(from + duration) };
  }
  if (Number.isFinite(from) && Number.isFinite(to) && to > from) {
    return { from: Math.floor(from), duration: Math.ceil(to - from), to: Math.floor(to) };
  }
  return null;
}

function recordingStatusPayload(stream, ranges) {
  const cleanRanges = (Array.isArray(ranges) ? ranges : [])
    .map(normalizeSmartYardRange)
    .filter(Boolean);

  if (RECORDING_STATUS_FORMAT === 'array') {
    return [{ stream, ranges: cleanRanges.map((range) => ({ from: range.from, duration: range.duration })) }];
  }

  // SmartYard-Vue DM path expects an object where every value has `from` and `to`.
  // See SmartYard-Vue src/hooks/useRanges.ts: Object.keys(res.data).map(key => res.data[key].from/to).
  const out = {};
  cleanRanges.forEach((range, index) => {
    out[String(index)] = {
      from: range.from,
      to: range.to,
      duration: range.duration,
      stream
    };
  });
  return out;
}

'''
if 'function recordingStatusPayload(' not in s:
    marker = 'async function handleRecordingStatus'
    if marker not in s:
        raise SystemExit('handleRecordingStatus marker not found')
    s = s.replace(marker, helper + marker, 1)


def replace_async_function(src, name, replacement):
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
                return src[:start] + replacement + src[i + 1:]
        i += 1
    raise SystemExit(f'{name} end not found')

replacement = r'''async function handleRecordingStatus(res, stream, reqUrl, token = '') {
  const dvrRanges = await fetchDvrArchiveRanges(stream, reqUrl, token);
  if (dvrRanges) {
    const payload = recordingStatusPayload(stream, dvrRanges.ranges);
    sendJson(res, 200, payload, {
      'x-newdomofon-resolved-stream': stream,
      'x-newdomofon-ranges-source': 'dvr-engine',
      'x-newdomofon-ranges-format': RECORDING_STATUS_FORMAT,
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
  const payload = recordingStatusPayload(stream, ranges);

  sendJson(res, 200, payload, {
    'x-newdomofon-resolved-stream': stream,
    'x-newdomofon-ranges-source': 'local-filesystem-fallback',
    'x-newdomofon-ranges-format': RECORDING_STATUS_FORMAT,
    'x-newdomofon-ranges-count': String(ranges.length),
    'x-newdomofon-segments-count': String(segments.length)
  });
}'''

s = replace_async_function(s, 'handleRecordingStatus', replacement)
s = s.replace('await handleRecordingStatus(res, stream, reqUrl);', 'await handleRecordingStatus(res, stream, reqUrl, actualToken);')

p.write_text(s)
PY

sudo sed -i -E '/^SMARTYARD_COMPAT_RECORDING_STATUS_FORMAT=/d' "$ENV_FILE" 2>/dev/null || true
echo 'SMARTYARD_COMPAT_RECORDING_STATUS_FORMAT=dm-object' | sudo tee -a "$ENV_FILE" >/dev/null

sudo mkdir -p /etc/systemd/system/${SERVICE}.d
if [ -f /etc/systemd/system/${SERVICE}.d/override.conf ]; then
  if ! grep -q '^Environment=SMARTYARD_COMPAT_RECORDING_STATUS_FORMAT=' /etc/systemd/system/${SERVICE}.d/override.conf; then
    sudo tee -a /etc/systemd/system/${SERVICE}.d/override.conf >/dev/null <<'EOF'
Environment=SMARTYARD_COMPAT_RECORDING_STATUS_FORMAT=dm-object
EOF
  else
    sudo sed -i 's/^Environment=SMARTYARD_COMPAT_RECORDING_STATUS_FORMAT=.*/Environment=SMARTYARD_COMPAT_RECORDING_STATUS_FORMAT=dm-object/' /etc/systemd/system/${SERVICE}.d/override.conf
  fi
fi

node --check "$TARGET"
sudo systemctl daemon-reload
sudo systemctl restart "$SERVICE"
sleep 2
systemctl --no-pager --full status "$SERVICE" | sed -n '1,18p'
echo "---- health ----"
curl -fsS http://127.0.0.1:3082/health || true
echo

echo "OK: recording_status.json switched to SmartYard-Vue DM object format"
echo "backup_dir=$BACKUP_DIR"
