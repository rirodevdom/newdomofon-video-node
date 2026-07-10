#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="${PROJECT_DIR:-/opt/newdomofon-video-node}"
TARGET="$PROJECT_DIR/smartyard-compat-proxy/server.js"
ENV_FILE="${ENV_FILE:-/etc/newdomofon-video/app.env}"
SERVICE="${SERVICE:-newdomofon-smartyard-compat.service}"
BACKUP_DIR="$PROJECT_DIR/backups/smartyard-recording-status-split-ranges-$(date +%Y%m%d-%H%M%S)"

mkdir -p "$BACKUP_DIR"
cp -a "$TARGET" "$BACKUP_DIR/server.js.bak"
[ -f "$ENV_FILE" ] && cp -a "$ENV_FILE" "$BACKUP_DIR/app.env.bak" || true

cd "$PROJECT_DIR"

python3 - <<'PY'
from pathlib import Path
import re

p = Path('smartyard-compat-proxy/server.js')
s = p.read_text()

s = re.sub(r"const VERSION = '[^']+';", "const VERSION = 'v85.3-recording-status-split-ranges';", s, count=1)

# Remove old duplicate split consts if any.
s = re.sub(r"^const\s+RECORDING_STATUS_MAX_RANGE_SECONDS\s*=.*?;\n", "", s, flags=re.M)

anchor = "const RECORDING_STATUS_FORMAT = String(process.env.SMARTYARD_COMPAT_RECORDING_STATUS_FORMAT || 'dm-object').toLowerCase();"
if anchor not in s:
    fallback = "const RECORDING_STATUS_LOOKBACK_DAYS = Math.max(1, Number(process.env.SMARTYARD_COMPAT_RECORDING_STATUS_LOOKBACK_DAYS || 31));"
    if fallback not in s:
        raise SystemExit('Cannot find recording status constants anchor')
    s = s.replace(fallback, fallback + "\n" + anchor, 1)

if 'RECORDING_STATUS_MAX_RANGE_SECONDS' not in s:
    s = s.replace(anchor, anchor + "\nconst RECORDING_STATUS_MAX_RANGE_SECONDS = Math.max(300, Number(process.env.SMARTYARD_COMPAT_RECORDING_STATUS_MAX_RANGE_SECONDS || 1800));", 1)

# Replace helper functions with split-capable versions.
start = s.find('function normalizeSmartYardRange(')
end = s.find('async function handleRecordingStatus', start)
if start < 0 or end < 0:
    raise SystemExit('normalizeSmartYardRange/handleRecordingStatus block not found')

helper = r'''function normalizeSmartYardRange(range) {
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

function nextLocalMidnightSec(fromSec) {
  const d = new Date(fromSec * 1000);
  return Math.floor(new Date(d.getFullYear(), d.getMonth(), d.getDate() + 1, 0, 0, 0, 0).getTime() / 1000);
}

function splitSmartYardRange(range) {
  const normalized = normalizeSmartYardRange(range);
  if (!normalized) return [];

  const out = [];
  let cursor = normalized.from;
  const finalTo = normalized.to;

  while (cursor < finalTo) {
    const nextMidnight = nextLocalMidnightSec(cursor);
    const maxChunkTo = cursor + RECORDING_STATUS_MAX_RANGE_SECONDS;
    const chunkTo = Math.min(finalTo, nextMidnight, maxChunkTo);
    if (chunkTo <= cursor) break;
    out.push({
      from: cursor,
      to: chunkTo,
      duration: chunkTo - cursor
    });
    cursor = chunkTo;
  }

  return out;
}

function recordingStatusPayload(stream, ranges) {
  const cleanRanges = (Array.isArray(ranges) ? ranges : [])
    .flatMap(splitSmartYardRange)
    .filter(Boolean);

  if (RECORDING_STATUS_FORMAT === 'array') {
    return [{ stream, ranges: cleanRanges.map((range) => ({ from: range.from, duration: range.duration })) }];
  }

  // SmartYard-Vue DM path expects an object where every value has `from` and `to`.
  // It also builds selectable dates from range.from, so long ranges must be split
  // at local midnight and into short chunks. Otherwise archive after midnight can
  // exist but still be shown as a red/no-archive zone.
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

s = s[:start] + helper + s[end:]

# Add split diagnostics header if handleRecordingStatus exists.
s = s.replace("'x-newdomofon-ranges-format': RECORDING_STATUS_FORMAT,", "'x-newdomofon-ranges-format': RECORDING_STATUS_FORMAT,\n      'x-newdomofon-ranges-split-seconds': String(RECORDING_STATUS_MAX_RANGE_SECONDS),")
s = s.replace("'x-newdomofon-ranges-format': RECORDING_STATUS_FORMAT,", "'x-newdomofon-ranges-format': RECORDING_STATUS_FORMAT,\n    'x-newdomofon-ranges-split-seconds': String(RECORDING_STATUS_MAX_RANGE_SECONDS),")

p.write_text(s)
PY

sudo sed -i -E '/^SMARTYARD_COMPAT_RECORDING_STATUS_MAX_RANGE_SECONDS=/d' "$ENV_FILE" 2>/dev/null || true
echo 'SMARTYARD_COMPAT_RECORDING_STATUS_MAX_RANGE_SECONDS=1800' | sudo tee -a "$ENV_FILE" >/dev/null

sudo mkdir -p /etc/systemd/system/${SERVICE}.d
if [ -f /etc/systemd/system/${SERVICE}.d/override.conf ]; then
  if ! grep -q '^Environment=SMARTYARD_COMPAT_RECORDING_STATUS_MAX_RANGE_SECONDS=' /etc/systemd/system/${SERVICE}.d/override.conf; then
    sudo tee -a /etc/systemd/system/${SERVICE}.d/override.conf >/dev/null <<'EOF'
Environment=SMARTYARD_COMPAT_RECORDING_STATUS_MAX_RANGE_SECONDS=1800
EOF
  else
    sudo sed -i 's/^Environment=SMARTYARD_COMPAT_RECORDING_STATUS_MAX_RANGE_SECONDS=.*/Environment=SMARTYARD_COMPAT_RECORDING_STATUS_MAX_RANGE_SECONDS=1800/' /etc/systemd/system/${SERVICE}.d/override.conf
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

echo "OK: recording_status.json ranges are split for SmartYard timeline"
echo "backup_dir=$BACKUP_DIR"
