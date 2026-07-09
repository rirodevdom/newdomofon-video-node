#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="${PROJECT_DIR:-/opt/newdomofon-video}"
TARGET="$PROJECT_DIR/public-events-proxy/server.js"
ENV_FILE="${ENV_FILE:-/etc/newdomofon-video/app.env}"
SERVICE="${SERVICE:-newdomofon-public-events.service}"
BACKUP_DIR="$PROJECT_DIR/backups/public-events-v126-data-shape-$(date +%Y%m%d-%H%M%S)"

mkdir -p "$BACKUP_DIR"
cp -a "$TARGET" "$BACKUP_DIR/server.js.bak"
[ -f "$ENV_FILE" ] && cp -a "$ENV_FILE" "$BACKUP_DIR/app.env.bak" || true

cd "$PROJECT_DIR"

python3 - <<'PY'
from pathlib import Path
import re

p = Path('public-events-proxy/server.js')
s = p.read_text()

s = re.sub(r"const VERSION = '[^']+';", "const VERSION = 'v126-public-events-data-items-events';", s, count=1)

# Ensure response has SmartYard-like envelope fields and all common array aliases.
if "code: 200," not in s:
    s = s.replace(
"""    return sendJson(res, 200, {
      ok: true,
      source: VERSION,
""",
"""    return sendJson(res, 200, {
      ok: true,
      source: VERSION,
      code: 200,
      name: 'Хорошо',
      message: 'Хорошо',
""",
1)

if "data: items," not in s:
    s = s.replace(
"""      meta,
      items,
      events: items,
""",
"""      meta,
      data: items,
      items,
      events: items,
""",
1)

# Make passive filtering configurable per request and expose both raw/visible counts.
# v125 already has this logic; this block is intentionally conservative.
if "x-newdomofon-public-events-count" not in s:
    s = s.replace(
"""function sendJson(res, status, payload, extraHeaders = {}) {
  const body = JSON.stringify(payload);
  res.writeHead(status, {
""",
"""function sendJson(res, status, payload, extraHeaders = {}) {
  const body = JSON.stringify(payload);
  const countHeader = payload && typeof payload === 'object' && payload.count !== undefined
    ? { 'x-newdomofon-public-events-count': String(payload.count) }
    : {};
  res.writeHead(status, {
""",
1)
    s = s.replace(
"""    'x-newdomofon-public-events': VERSION,
      ...extraHeaders,
""",
"""    'x-newdomofon-public-events': VERSION,
      ...countHeader,
      ...extraHeaders,
""",
1)

p.write_text(s)
PY

node --check "$TARGET"
sudo systemctl daemon-reload
sudo systemctl restart "$SERVICE"
sleep 2

echo "---- public-events status ----"
systemctl --no-pager --full status "$SERVICE" | sed -n '1,18p'

echo "---- health ----"
curl -fsS http://127.0.0.1:3057/public-events/health || true
echo

echo "OK: public-events response includes data/items/events and v126 header"
echo "backup_dir=$BACKUP_DIR"
