#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="${PROJECT_DIR:-/opt/newdomofon-video}"
TARGET="$PROJECT_DIR/smartyard-compat-proxy/server.js"
ENV_FILE="${ENV_FILE:-/etc/newdomofon-video/app.env}"
SERVICE="${SERVICE:-newdomofon-smartyard-compat.service}"
BACKUP_DIR="$PROJECT_DIR/backups/smartyard-recording-status-dual-range-fields-$(date +%Y%m%d-%H%M%S)"

mkdir -p "$BACKUP_DIR"
cp -a "$TARGET" "$BACKUP_DIR/server.js.bak"
[ -f "$ENV_FILE" ] && cp -a "$ENV_FILE" "$BACKUP_DIR/app.env.bak" || true

cd "$PROJECT_DIR"

python3 - <<'PY'
from pathlib import Path
import re

p = Path('smartyard-compat-proxy/server.js')
s = p.read_text()

s = re.sub(r"const VERSION = '[^']+';", "const VERSION = 'v85.4-recording-status-dual-range-fields';", s, count=1)

start = s.find('function recordingStatusPayload(')
if start < 0:
    raise SystemExit('recordingStatusPayload not found')
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
    raise SystemExit('recordingStatusPayload end not found')

replacement = r'''function recordingStatusPayload(stream, ranges) {
  const cleanRanges = (Array.isArray(ranges) ? ranges : [])
    .flatMap(splitSmartYardRange)
    .filter(Boolean);

  if (RECORDING_STATUS_FORMAT === 'array') {
    return [{ stream, ranges: cleanRanges.map((range) => ({ from: range.from, duration: range.duration })) }];
  }

  // Dual-compatible object:
  // - SmartYard-Vue DM mode reads value.from and value.to.
  // - NewDomofon player archive-ranges can also consume value.ranges[].
  const out = {};
  cleanRanges.forEach((range, index) => {
    out[String(index)] = {
      from: range.from,
      to: range.to,
      duration: range.duration,
      stream,
      ranges: [
        {
          from: range.from,
          duration: range.duration,
          to: range.to
        }
      ]
    };
  });
  return out;
}'''

s = s[:start] + replacement + s[end:]

s = s.replace("'x-newdomofon-ranges-format': RECORDING_STATUS_FORMAT,", "'x-newdomofon-ranges-format': RECORDING_STATUS_FORMAT,\n      'x-newdomofon-ranges-dual-fields': '1',", 1)
s = s.replace("'x-newdomofon-ranges-format': RECORDING_STATUS_FORMAT,", "'x-newdomofon-ranges-format': RECORDING_STATUS_FORMAT,\n    'x-newdomofon-ranges-dual-fields': '1',", 1)

p.write_text(s)
PY

node --check "$TARGET"
sudo systemctl daemon-reload
sudo systemctl restart "$SERVICE"
sleep 2
systemctl --no-pager --full status "$SERVICE" | sed -n '1,18p'
echo "---- health ----"
curl -fsS http://127.0.0.1:3082/health || true
echo

echo "OK: recording_status.json now includes both from/to and nested ranges[] fields"
echo "backup_dir=$BACKUP_DIR"
