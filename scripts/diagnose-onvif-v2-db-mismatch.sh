#!/usr/bin/env bash
set -Eeuo pipefail

ENV_FILE="${ENV_FILE:-/etc/newdomofon-video/app.env}"
SINCE="${SINCE:-30 minutes ago}"

set -a
[ -f "$ENV_FILE" ] && . "$ENV_FILE"
set +a

echo "---- node env ----"
grep -E '^(BACKEND_INTERNAL_URL|BACKEND_URL|API_BASE_URL|INTERNAL_DVR_SECRET|DVR_NODE_ID|ONVIF_V2_SKIP_STREAMS|ONVIF_EVENTS_V2_SKIP_STREAMS|ONVIF_LEGACY_FALLBACK_STREAMS|ONVIF_EVENT_POLL_INTERVAL_MS)=' "$ENV_FILE" | sed -E 's/(INTERNAL_DVR_SECRET=).*/\1***REDACTED***/'

echo "---- dvr logs ----"
journalctl -u newdomofon-video-dvr.service --since "$SINCE" --no-pager -l \
  | grep -E 'onvif-events:v2|stored events|pullpoint created|poll ok|poll failed|Backend POST|duplicate|inserted|legacy-fallback' \
  | tail -200 || true

echo "---- post route smoke test ----"
NOW="$(date -u +%FT%T.%3NZ)"
CAM_JSON="/tmp/onvif-cameras-for-smoke.json"
curl -fsS \
  -H "x-internal-secret: ${INTERNAL_DVR_SECRET}" \
  -H "x-node-id: ${DVR_NODE_ID:-3348ffdf-2455-472f-a941-4eb456fb1df6}" \
  "${BACKEND_INTERNAL_URL:-${BACKEND_URL:-http://10.106.1.30:3000}}/api/internal/cameras/onvif" \
  -o "$CAM_JSON"

node - "$CAM_JSON" "$NOW" <<'JS' > /tmp/onvif-smoke-event.json
const fs=require('fs');
const cams=JSON.parse(fs.readFileSync(process.argv[2],'utf8')).items||[];
const now=process.argv[3];
const cam=cams.find(c=>c.stream_name==='onvif2')||cams[0];
if(!cam) process.exit(2);
console.log(JSON.stringify({
  camera_id: cam.id,
  stream_name: cam.stream_name,
  event_type: 'diag.onvif.smoke',
  event_state: 'true',
  occurred_at: now,
  data: {collector:'diag', simple:{IsMotion:'true'}, note:'delete-safe diagnostic event'}
}));
JS

curl -fsS -X POST \
  -H "content-type: application/json" \
  -H "x-internal-secret: ${INTERNAL_DVR_SECRET}" \
  -H "x-node-id: ${DVR_NODE_ID:-3348ffdf-2455-472f-a941-4eb456fb1df6}" \
  --data-binary @/tmp/onvif-smoke-event.json \
  "${BACKEND_INTERNAL_URL:-${BACKEND_URL:-http://10.106.1.30:3000}}/api/internal/events/onvif"
echo

echo "Smoke event sent. Check master DB by event_type='diag.onvif.smoke'."
