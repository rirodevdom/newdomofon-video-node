#!/usr/bin/env bash
set -Eeuo pipefail

# NewDomofon Video: v83.2 SmartYard-Vue token + preview ffmpeg fix
#
# Fixes two issues observed after v83.1:
#   1) ffmpeg cannot infer output format for preview temp file without .mp4 extension
#   2) SmartYard-Vue may use a different token returned by /mobile/cctv/all than SMARTYARD_AUTH_TOKEN
#
# This patch:
#   - patches smartyard-compat-proxy/server.js preview temp file to end with .mp4 and forces -f mp4
#   - creates a valid fallback preview MP4 if missing or too small
#   - appends SMARTYARD_AUTH_TOKEN, SMARTYARD_WEB_TOKEN and EXTRA_RESTREAM_PUBLIC_TOKENS to accepted token file
#   - restarts newdomofon-smartyard-compat and reloads nginx

PROJECT_DIR="${PROJECT_DIR:-/opt/newdomofon-video}"
SERVICE_NAME="${SERVICE_NAME:-newdomofon-smartyard-compat}"
SERVICE_DIR="${SERVICE_DIR:-$PROJECT_DIR/smartyard-compat-proxy}"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
ENV_FILE="${ENV_FILE:-/etc/newdomofon-video/app.env}"
ACCEPTED_TOKENS_FILE="${ACCEPTED_TOKENS_FILE:-/etc/newdomofon-video/restream-accepted-tokens.json}"
PREVIEW_CACHE_DIR="${PREVIEW_CACHE_DIR:-/var/cache/newdomofon-video/smartyard-preview}"
PREVIEW_FALLBACK_MP4="${PREVIEW_FALLBACK_MP4:-/var/lib/newdomofon-video/smartyard-preview-v82.mp4}"
SITE_URL="${SITE_URL:-https://new-video.domofon-37.ru}"
SMARTYARD_AUTH_TOKEN="${SMARTYARD_AUTH_TOKEN:-1qaz!QAZ}"
SMARTYARD_WEB_TOKEN="${SMARTYARD_WEB_TOKEN:-}"
EXTRA_RESTREAM_PUBLIC_TOKENS="${EXTRA_RESTREAM_PUBLIC_TOKENS:-}"
STREAM_NAME="${STREAM_NAME:-cam_10_130_1_219}"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run as root with sudo." >&2
  exit 1
fi

for c in node python3 systemctl nginx curl grep sed awk ffmpeg; do
  command -v "$c" >/dev/null || { echo "$c not found" >&2; exit 1; }
done

[[ -d "$PROJECT_DIR" ]] || { echo "PROJECT_DIR not found: $PROJECT_DIR" >&2; exit 1; }
[[ -f "$SERVICE_DIR/server.js" ]] || { echo "service not found: $SERVICE_DIR/server.js. Run v82/v83 first." >&2; exit 1; }

TS="$(date +%Y%m%d-%H%M%S)"
BACKUP="$PROJECT_DIR/backups/v83.2-smartyard-vue-token-preview-fix-$TS"
mkdir -p "$BACKUP"

backup() {
  [[ -e "$1" ]] || return 0
  mkdir -p "$BACKUP/$(dirname "${1#/}")"
  cp -a "$1" "$BACKUP/${1#/}"
  echo "backup: $1"
}

backup "$SERVICE_DIR/server.js"
backup "$SERVICE_FILE"
backup "$ENV_FILE"
backup "$ACCEPTED_TOKENS_FILE"
backup "$PREVIEW_FALLBACK_MP4"

install -d -m 0755 "$PREVIEW_CACHE_DIR"
install -d -m 0755 "$(dirname "$PREVIEW_FALLBACK_MP4")"
install -d -m 0755 "$(dirname "$ACCEPTED_TOKENS_FILE")"

# Load tokens from env file as additional accepted tokens.
PRIMARY_TOKEN=""
VITE_TOKEN=""
if [[ -f "$ENV_FILE" ]]; then
  PRIMARY_TOKEN="$(grep -E '^RESTREAM_PUBLIC_TOKEN=' "$ENV_FILE" | tail -1 | cut -d= -f2- || true)"
  VITE_TOKEN="$(grep -E '^VITE_RESTREAM_PUBLIC_TOKEN=' "$ENV_FILE" | tail -1 | cut -d= -f2- || true)"
fi

python3 - "$ACCEPTED_TOKENS_FILE" "$SMARTYARD_AUTH_TOKEN" "$SMARTYARD_WEB_TOKEN" "$EXTRA_RESTREAM_PUBLIC_TOKENS" "$PRIMARY_TOKEN" "$VITE_TOKEN" <<'PY'
import json
import pathlib
import re
import sys

out = pathlib.Path(sys.argv[1])
values = []
for arg in sys.argv[2:]:
    if not arg:
        continue
    # accept comma/space/newline separated values, but preserve tokens with punctuation
    for part in re.split(r'[\s,]+', arg.strip()):
        if part and part not in values:
            values.append(part)

existing = []
try:
    data = json.loads(out.read_text())
    if isinstance(data, list):
        existing = [str(x).strip() for x in data if str(x).strip()]
except Exception:
    existing = []

merged = []
for token in existing + values:
    if token and token not in merged:
        merged.append(token)

out.write_text(json.dumps(merged, ensure_ascii=False, indent=2) + '\n')
print('accepted tokens count:', len(merged))
for token in merged:
    print(' -', token[:8] + ('...' if len(token) > 8 else ''))
PY

python3 - "$SERVICE_DIR/server.js" <<'PY'
from pathlib import Path
import re
import sys

p = Path(sys.argv[1])
s = p.read_text()

if 'newdomofon-smartyard-compat' not in s:
    raise SystemExit('This does not look like SmartYard compat server.js')

s = re.sub(r"const VERSION = '[^']*';", "const VERSION = 'v83.2-smartyard-vue-token-preview-fix';", s, count=1)

# v83.1 bug: ffmpeg temp file had no extension, so ffmpeg could not infer output format.
s = s.replace(
    "const tmp = `${outputFile}.tmp-${process.pid}-${Date.now()}`;",
    "const tmp = `${outputFile}.tmp-${process.pid}-${Date.now()}.mp4`;"
)

# Make preview generation robust even if someone changes temp naming later.
if "'-f', 'mp4',\n      tmp" not in s:
    s = s.replace(
        "'-movflags', '+faststart',\n      tmp",
        "'-movflags', '+faststart',\n      '-f', 'mp4',\n      tmp"
    )

# Avoid long preview stalls in web UI if ffmpeg hangs on a bad segment.
s = s.replace('}, 15000);', '}, Number(process.env.PREVIEW_FFMPEG_TIMEOUT_MS || 8000));')

# Ensure generated preview response gets explicit MP4 headers. sendFile already sets CORS; this just makes browser sniffing stricter.
s = s.replace(
    "'content-type': 'video/mp4',\n        'content-disposition': 'inline; filename=\"preview.mp4\"',",
    "'content-type': 'video/mp4',\n        'content-disposition': 'inline; filename=\"preview.mp4\"',\n        'x-content-type-options': 'nosniff',"
)

p.write_text(s)
PY

node --check "$SERVICE_DIR/server.js"

# Create/replace fallback only when it is missing or suspiciously tiny.
FALLBACK_SIZE=0
if [[ -f "$PREVIEW_FALLBACK_MP4" ]]; then
  FALLBACK_SIZE="$(stat -c '%s' "$PREVIEW_FALLBACK_MP4" || echo 0)"
fi

if [[ "$FALLBACK_SIZE" -lt 50000 ]]; then
  echo "creating valid fallback preview mp4: $PREVIEW_FALLBACK_MP4"
  TMP_FB="${PREVIEW_FALLBACK_MP4}.tmp-$$.mp4"
  ffmpeg -hide_banner -loglevel error -y \
    -f lavfi -i color=c=black:s=640x360:r=25:d=1 \
    -f lavfi -i anullsrc=channel_layout=stereo:sample_rate=44100 \
    -shortest \
    -c:v libx264 -preset veryfast -pix_fmt yuv420p \
    -c:a aac -b:a 96k \
    -movflags +faststart \
    -f mp4 "$TMP_FB"
  mv -f "$TMP_FB" "$PREVIEW_FALLBACK_MP4"
  chmod 0644 "$PREVIEW_FALLBACK_MP4"
fi

if [[ -f "$SERVICE_FILE" ]]; then
  if ! grep -q '^Environment=ACCEPTED_TOKENS_FILE=' "$SERVICE_FILE"; then
    sed -i "/^Environment=PREVIEW_FALLBACK_MP4=/a Environment=ACCEPTED_TOKENS_FILE=$ACCEPTED_TOKENS_FILE" "$SERVICE_FILE"
  fi
  if ! grep -q '^Environment=PREVIEW_CACHE_DIR=' "$SERVICE_FILE"; then
    sed -i "/^Environment=PREVIEW_FALLBACK_MP4=/a Environment=PREVIEW_CACHE_DIR=$PREVIEW_CACHE_DIR" "$SERVICE_FILE"
  fi
  if ! grep -q '^Environment=PREVIEW_FFMPEG_TIMEOUT_MS=' "$SERVICE_FILE"; then
    sed -i "/^Environment=PREVIEW_FALLBACK_MP4=/a Environment=PREVIEW_FFMPEG_TIMEOUT_MS=8000" "$SERVICE_FILE"
  fi
fi

systemctl daemon-reload
systemctl restart "$SERVICE_NAME"
sleep 1
systemctl --no-pager --full status "$SERVICE_NAME" | sed -n '1,18p' || true

nginx -t
systemctl reload nginx || systemctl restart nginx

echo
PUBLIC_BASE="${SITE_URL%/}/$STREAM_NAME"
TEST_TOKEN="$SMARTYARD_WEB_TOKEN"
if [[ -z "$TEST_TOKEN" ]]; then
  TEST_TOKEN="$SMARTYARD_AUTH_TOKEN"
fi

echo "Verification URLs using token prefix: ${TEST_TOKEN:0:8}"
echo "Preview: $PUBLIC_BASE/preview.mp4?token=$TEST_TOKEN"
echo "Live:    $PUBLIC_BASE/index.m3u8?token=$TEST_TOKEN"
echo

curl -k --max-time 15 -I "$PUBLIC_BASE/preview.mp4?token=$TEST_TOKEN" | sed -n '1,35p' || true
echo
curl -k --max-time 15 "$PUBLIC_BASE/index.m3u8?token=$TEST_TOKEN" | sed -n '1,40p' || true

echo
cat <<MSG
DONE: v83.2 SmartYard-Vue token/preview fix installed.
Backup: $BACKUP

Next browser check:
  Ctrl+F5 SmartYard-Vue, then verify preview.mp4 and index.m3u8 are requested with accepted token prefix ${TEST_TOKEN:0:8}.
MSG
