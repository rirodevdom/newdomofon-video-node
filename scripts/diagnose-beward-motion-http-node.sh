#!/usr/bin/env bash
set -Eeuo pipefail

ENV_FILE="${ENV_FILE:-/etc/newdomofon-video/app.env}"
BACKEND_URL="${BACKEND_INTERNAL_URL:-${BACKEND_URL:-https://new-video.domofon-37.ru}}"
NODE_ID="${DVR_NODE_ID:-3348ffdf-2455-472f-a941-4eb456fb1df6}"
STREAMS="${EVENT_STREAMS:-onvif2,onf}"
POLL_SECONDS="${POLL_SECONDS:-90}"
OUT_DIR="${OUT_DIR:-/tmp/newdomofon-beward-motion-http-$(date +%Y%m%d-%H%M%S)}"

set -a
[ -f "$ENV_FILE" ] && . "$ENV_FILE"
set +a

BACKEND_URL="${BACKEND_INTERNAL_URL:-${BACKEND_URL:-$BACKEND_URL}}"
NODE_ID="${DVR_NODE_ID:-$NODE_ID}"

if [ -z "${INTERNAL_DVR_SECRET:-}" ]; then
  echo "ERROR: INTERNAL_DVR_SECRET is empty" >&2
  exit 1
fi

mkdir -p "$OUT_DIR"

curl -k -fsS \
  -H "x-internal-secret: ${INTERNAL_DVR_SECRET}" \
  -H "x-node-id: ${NODE_ID}" \
  "${BACKEND_URL%/}/api/internal/cameras/onvif" \
  -o "$OUT_DIR/cameras.json"

python3 - "$OUT_DIR/cameras.json" "$STREAMS" > "$OUT_DIR/cameras.tsv" <<'PY'
import json, sys, urllib.parse
cams=json.load(open(sys.argv[1])).get('items', [])
streams=set(x.strip() for x in sys.argv[2].split(',') if x.strip())
for c in cams:
    if c.get('stream_name') not in streams: continue
    xaddr=c.get('onvif_xaddr') or ''
    host=urllib.parse.urlparse(xaddr).hostname or urllib.parse.urlparse(c.get('source_url') or '').hostname or ''
    rtsp=urllib.parse.urlparse(c.get('source_url') or '')
    user=c.get('onvif_username') or urllib.parse.unquote(rtsp.username or '')
    password=c.get('onvif_password') or urllib.parse.unquote(rtsp.password or '')
    print('\t'.join([c.get('stream_name',''), host, user, password]))
PY

sanitize() {
  sed -E 's#(password|passwd|pwd|pass|secret|token)([=: ]+)[^&[:space:]]+#\1\2***#Ig; s#rtsp://([^:/@]+):([^@]+)@#rtsp://\1:***@#Ig'
}

fetch_one() {
  local stream="$1" ip="$2" user="$3" pass="$4" path="$5" tag="$6" auth="$7"
  local url="http://${ip}${path}"
  local body="$OUT_DIR/${stream}-${tag}-${auth}.body"
  local meta="$OUT_DIR/${stream}-${tag}-${auth}.meta"
  local code
  if [ "$auth" = "digest" ]; then
    code="$(curl --digest -u "$user:$pass" --connect-timeout 5 --max-time 12 -sS -o "$body" -w '%{http_code}' "$url" 2>"$meta.err" || true)"
  else
    code="$(curl -u "$user:$pass" --connect-timeout 5 --max-time 12 -sS -o "$body" -w '%{http_code}' "$url" 2>"$meta.err" || true)"
  fi
  printf '%s\t%s\t%s\t%s\t%s\n' "$stream" "$auth" "$code" "$tag" "$path" | tee -a "$OUT_DIR/http-summary.tsv"
  {
    echo "===== $stream $auth HTTP $code $path ====="
    head -c 4000 "$body" 2>/dev/null | sanitize || true
    echo
  } >> "$OUT_DIR/http-bodies.txt"
}

PATHS=(
'/cgi-bin/hi3510/param.cgi?cmd=getserverinfo'
'/cgi-bin/hi3510/param.cgi?cmd=getmdattr'
'/cgi-bin/hi3510/param.cgi?cmd=getmdalarm'
'/cgi-bin/hi3510/param.cgi?cmd=getalarmattr'
'/cgi-bin/hi3510/param.cgi?cmd=geteventattr'
'/cgi-bin/hi3510/param.cgi?cmd=getioattr'
'/cgi-bin/hi3510/param.cgi?cmd=getvideoalarmattr'
'/cgi-bin/hi3510/param.cgi?cmd=getnotifyattr'
'/cgi-bin/hi3510/param.cgi?cmd=getpirattr'
'/cgi-bin/hi3510/param.cgi?cmd=getaudioalarmattr'
'/cgi-bin/magicBox.cgi?action=getSystemInfo'
'/cgi-bin/configManager.cgi?action=getConfig&name=MotionDetect'
'/cgi-bin/configManager.cgi?action=getConfig&name=VideoMotion'
'/cgi-bin/configManager.cgi?action=getConfig&name=Alarm'
'/cgi-bin/eventManager.cgi?action=getEventIndexes&code=VideoMotion'
)

: > "$OUT_DIR/http-summary.tsv"
: > "$OUT_DIR/http-bodies.txt"

while IFS=$'\t' read -r stream ip user pass; do
  [ -n "$ip" ] || continue
  echo "---- scan $stream $ip ----" | tee -a "$OUT_DIR/http-bodies.txt"
  i=0
  for path in "${PATHS[@]}"; do
    tag="$(printf '%02d' "$i")"
    fetch_one "$stream" "$ip" "$user" "$pass" "$path" "$tag" digest
    i=$((i+1))
  done
  echo "---- quick motion poll $stream $ip ----" | tee -a "$OUT_DIR/poll.log"
  end=$((SECONDS + POLL_SECONDS))
  last=""
  while [ "$SECONDS" -lt "$end" ]; do
    line="$(curl --digest -u "$user:$pass" --connect-timeout 3 --max-time 5 -sS "http://${ip}/cgi-bin/hi3510/param.cgi?cmd=getmdalarm" 2>/dev/null | sanitize | tr '\r\n' ' ' | head -c 1000 || true)"
    if [ "$line" != "$last" ]; then
      printf '%s stream=%s mdalarm=%s\n' "$(date -Is)" "$stream" "$line" | tee -a "$OUT_DIR/poll.log"
      last="$line"
    fi
    sleep 1
  done
done < "$OUT_DIR/cameras.tsv"

echo "OUT_DIR=$OUT_DIR"
echo "---- interesting HTTP bodies ----"
grep -RniE 'motion|md|alarm|event|enable|state|detect|Rule|VideoMotion|IsMotion|error|not found|unauthorized' "$OUT_DIR/http-bodies.txt" | head -250 || true

echo "---- poll changes ----"
cat "$OUT_DIR/poll.log" 2>/dev/null || true
