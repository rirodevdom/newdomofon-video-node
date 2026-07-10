#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="${PROJECT_DIR:-/opt/newdomofon-video-node}"
TARGET="$PROJECT_DIR/smartyard-compat-proxy/server.js"
ENV_FILE="${ENV_FILE:-/etc/newdomofon-video/app.env}"
SERVICE="${SERVICE:-newdomofon-smartyard-compat.service}"
BACKUP_DIR="$PROJECT_DIR/backups/smartyard-recording-status-cap-old-from-$(date +%Y%m%d-%H%M%S)"

mkdir -p "$BACKUP_DIR"
cp -a "$TARGET" "$BACKUP_DIR/server.js.bak"
[ -f "$ENV_FILE" ] && cp -a "$ENV_FILE" "$BACKUP_DIR/app.env.bak" || true

cd "$PROJECT_DIR"

python3 - <<'PY'
from pathlib import Path
import re

p = Path('smartyard-compat-proxy/server.js')
s = p.read_text()

s = re.sub(r"const VERSION = '[^']+';", "const VERSION = 'v85.5-recording-status-cap-old-from';", s, count=1)

# Remove duplicate const if a previous attempt added it.
s = re.sub(r"^const\s+RECORDING_STATUS_CAP_OLD_FROM\s*=.*?;\n", "", s, flags=re.M)

anchor = "const RECORDING_STATUS_LOOKBACK_DAYS = Math.max(1, Number(process.env.SMARTYARD_COMPAT_RECORDING_STATUS_LOOKBACK_DAYS || 31));"
if anchor not in s:
    raise SystemExit('RECORDING_STATUS_LOOKBACK_DAYS anchor not found')
s = s.replace(anchor, anchor + "\nconst RECORDING_STATUS_CAP_OLD_FROM = !['0', 'false', 'no', 'off'].includes(String(process.env.SMARTYARD_COMPAT_RECORDING_STATUS_CAP_OLD_FROM || 'true').toLowerCase());", 1)

old = """  const fromSec = Number(reqUrl.searchParams.get('from') || 0);
  const startMs = Number.isFinite(fromSec) && fromSec > 0
    ? fromSec * 1000
    : Date.now() - RECORDING_STATUS_LOOKBACK_DAYS * 86400_000;
  const endMs = Date.now() + 10 * 60_000;
"""
new = """  const fromSec = Number(reqUrl.searchParams.get('from') || 0);
  const lookbackStartMs = Date.now() - RECORDING_STATUS_LOOKBACK_DAYS * 86400_000;
  let startMs = Number.isFinite(fromSec) && fromSec > 0
    ? fromSec * 1000
    : lookbackStartMs;

  // SmartYard-Server flussonic adapter asks recording_status.json with a very old
  // hardcoded `from=1525186456`. Cap it to the configured lookback window, otherwise
  // timeline discovery can become slow or return an incomplete early archive window.
  if (RECORDING_STATUS_CAP_OLD_FROM && startMs < lookbackStartMs) startMs = lookbackStartMs;

  const endMs = Date.now() + 10 * 60_000;
"""
if old not in s:
    raise SystemExit('fetchDvrArchiveRanges from/start block not found')
s = s.replace(old, new, 1)

# Add diagnostic header for capped mode in both dvr/local responses if not present.
s = s.replace("'x-newdomofon-ranges-start': dvrRanges.startIso,", "'x-newdomofon-ranges-start': dvrRanges.startIso,\n      'x-newdomofon-ranges-cap-old-from': RECORDING_STATUS_CAP_OLD_FROM ? '1' : '0',", 1)
s = s.replace("'x-newdomofon-segments-count': String(segments.length)", "'x-newdomofon-segments-count': String(segments.length),\n    'x-newdomofon-ranges-cap-old-from': RECORDING_STATUS_CAP_OLD_FROM ? '1' : '0'", 1)

p.write_text(s)
PY

sudo sed -i -E '/^SMARTYARD_COMPAT_RECORDING_STATUS_CAP_OLD_FROM=/d' "$ENV_FILE" 2>/dev/null || true
echo 'SMARTYARD_COMPAT_RECORDING_STATUS_CAP_OLD_FROM=true' | sudo tee -a "$ENV_FILE" >/dev/null

sudo mkdir -p /etc/systemd/system/${SERVICE}.d
if [ -f /etc/systemd/system/${SERVICE}.d/override.conf ]; then
  if ! grep -q '^Environment=SMARTYARD_COMPAT_RECORDING_STATUS_CAP_OLD_FROM=' /etc/systemd/system/${SERVICE}.d/override.conf; then
    sudo tee -a /etc/systemd/system/${SERVICE}.d/override.conf >/dev/null <<'EOF'
Environment=SMARTYARD_COMPAT_RECORDING_STATUS_CAP_OLD_FROM=true
EOF
  else
    sudo sed -i 's/^Environment=SMARTYARD_COMPAT_RECORDING_STATUS_CAP_OLD_FROM=.*/Environment=SMARTYARD_COMPAT_RECORDING_STATUS_CAP_OLD_FROM=true/' /etc/systemd/system/${SERVICE}.d/override.conf
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

echo "OK: old recording_status from= timestamps are capped to the configured lookback window"
echo "backup_dir=$BACKUP_DIR"
