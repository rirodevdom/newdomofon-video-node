#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="${PROJECT_DIR:-/opt/newdomofon-video}"
ENV_FILE="${ENV_FILE:-/etc/newdomofon-video/app.env}"
STAMP="$(date +%Y%m%d-%H%M%S)"
OUT_DIR="${OUT_DIR:-$PROJECT_DIR/diagnostics}"
OUT="$OUT_DIR/master-node-diagnose-$STAMP.txt"

install -d -m 0750 "$OUT_DIR"

exec > >(tee "$OUT") 2>&1

redact() {
  sed -E \
    -e 's#(rtsp://)[^:@/]+(:[^@/]+)?@#\1***:***@#g' \
    -e 's#(postgres(ql)?://)[^:@/]+(:[^@/]+)?@#\1***:***@#g' \
    -e 's#([?&]token=)[^&[:space:]]+#\1***#g' \
    -e 's#(Authorization: Bearer )[A-Za-z0-9._~+/=-]+#\1***#g'
}

section() {
  printf '\n===== %s =====\n' "$1"
}

run() {
  echo "+ $*"
  set +e
  "$@" 2>&1 | redact
  local code=${PIPESTATUS[0]}
  set -e
  echo "exit=$code"
}

load_env() {
  if [[ -f "$ENV_FILE" ]]; then
    set -a
    # shellcheck disable=SC1090
    . "$ENV_FILE"
    set +a
  fi
}

bool_enabled() {
  case "$(echo "${1:-}" | tr '[:upper:]' '[:lower:]')" in
    1|true|yes|on) return 0 ;;
    *) return 1 ;;
  esac
}

node -v >/dev/null 2>&1 || true
load_env

section "host"
echo "date=$(date -Is)"
echo "hostname=$(hostname -f 2>/dev/null || hostname)"
echo "project=$PROJECT_DIR"
echo "env=$ENV_FILE"
run uname -a
run ip -br addr
run ip route

section "role detection"
ROLE="standalone-or-master"
if [[ -n "${DVR_MASTER_URL:-}" && -n "${DVR_NODE_ID:-}" && -n "${DVR_NODE_TOKEN:-}" ]]; then
  ROLE="node"
elif [[ -n "${DATABASE_URL:-}" ]]; then
  ROLE="master-or-standalone"
fi
echo "detected_role=$ROLE"
echo "DVR_MASTER_URL=${DVR_MASTER_URL:-}"
echo "DVR_NODE_ID=${DVR_NODE_ID:+set}"
echo "DVR_NODE_TOKEN=${DVR_NODE_TOKEN:+set}"
echo "DVR_NODE_PUBLIC_BASE_URL=${DVR_NODE_PUBLIC_BASE_URL:-}"
echo "DVR_NODE_INTERNAL_URL=${DVR_NODE_INTERNAL_URL:-}"
echo "DATABASE_URL=${DATABASE_URL:+set}"
echo "DVR_REQUIRE_MEDIA_TOKEN=${DVR_REQUIRE_MEDIA_TOKEN:-}"
echo "VIDEO_MOTION_ENABLED=${VIDEO_MOTION_ENABLED:-}"
echo "EVENTS_ENABLED=${EVENTS_ENABLED:-}"
echo "ONVIF_EVENTS_ENABLED=${ONVIF_EVENTS_ENABLED:-}"
echo "DVR_HIKVISION_EVENTS_ENABLED=${DVR_HIKVISION_EVENTS_ENABLED:-}"
echo "DVR_HIKVISION_ARCHIVE_INDEX_ENABLED=${DVR_HIKVISION_ARCHIVE_INDEX_ENABLED:-}"
echo "ONVIF_LEGACY_FALLBACK_STREAMS=${ONVIF_LEGACY_FALLBACK_STREAMS:-}"
echo "ONVIF_V2_SKIP_STREAMS=${ONVIF_V2_SKIP_STREAMS:-${ONVIF_EVENTS_V2_SKIP_STREAMS:-}}"

section "services"
for service in newdomofon-video-backend newdomofon-video-dvr newdomofon-public-events-proxy newdomofon-smartyard-compat nginx postgresql; do
  if systemctl list-unit-files "$service.service" >/dev/null 2>&1 || systemctl status "$service.service" >/dev/null 2>&1; then
    echo "--- $service ---"
    systemctl is-enabled "$service.service" 2>/dev/null || true
    systemctl is-active "$service.service" 2>/dev/null || true
    systemctl --no-pager -l status "$service.service" 2>/dev/null | sed -n '1,16p' | redact || true
  fi
done

section "local health"
run curl -fsS --max-time 5 http://127.0.0.1:3000/api/health
run curl -fsS --max-time 5 http://127.0.0.1:3010/health
run curl -fsS --max-time 5 http://127.0.0.1:3010/recorders

if [[ -n "${DVR_MASTER_URL:-}" ]]; then
  section "node to master"
  run curl -fsS --max-time 10 "$DVR_MASTER_URL/api/health"
  if [[ -n "${DVR_NODE_ID:-}" && -n "${DVR_NODE_TOKEN:-}" ]]; then
    TMP_CONFIG="$(mktemp)"
    set +e
    curl -fsS --max-time 20 \
      -H "Authorization: Bearer $DVR_NODE_TOKEN" \
      -H "x-node-id: $DVR_NODE_ID" \
      "$DVR_MASTER_URL/api/node-agent/config" > "$TMP_CONFIG"
    CURL_CODE=$?
    set -e
    echo "node_config_http_exit=$CURL_CODE"
    if [[ $CURL_CODE -eq 0 ]]; then
      node - "$TMP_CONFIG" <<'NODE'
const fs = require('fs');
const file = process.argv[2];
const data = JSON.parse(fs.readFileSync(file, 'utf8'));
const cameras = Array.isArray(data.cameras) ? data.cameras : [];
console.log(`assigned_cameras=${cameras.length}`);
for (const cam of cameras) {
  let host = '';
  let port = '';
  try {
    const u = new URL(cam.source_url || '');
    host = u.hostname;
    port = u.port || (u.protocol === 'rtsp:' ? '554' : '80');
  } catch {}
  console.log([cam.stream_name, cam.id, cam.device_connection_type || '', cam.archive_storage || '', host, port].join('\t'));
}
NODE
      section "camera network checks"
      node - "$TMP_CONFIG" <<'NODE' > /tmp/newdomofon-camera-hosts.txt
const fs = require('fs');
const data = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const cameras = Array.isArray(data.cameras) ? data.cameras : [];
const seen = new Set();
for (const cam of cameras) {
  try {
    const u = new URL(cam.source_url || '');
    const host = u.hostname;
    const port = u.port || (u.protocol === 'rtsp:' ? '554' : '80');
    const key = `${host}:${port}`;
    if (!host || seen.has(key)) continue;
    seen.add(key);
    console.log(`${cam.stream_name}\t${host}\t${port}`);
  } catch {}
}
NODE
      while IFS=$'\t' read -r stream host port; do
        [[ -z "$host" ]] && continue
        echo "--- $stream $host:$port ---"
        run ip route get "$host"
        run ping -c 2 -W 1 "$host"
        timeout 5 bash -c "</dev/tcp/$host/$port" >/dev/null 2>&1 && echo "tcp/$port OK" || echo "tcp/$port FAIL"
      done < /tmp/newdomofon-camera-hosts.txt
    else
      cat "$TMP_CONFIG" 2>/dev/null | redact || true
    fi
    rm -f "$TMP_CONFIG"
  fi
fi

if [[ -n "${DATABASE_URL:-}" ]] && command -v psql >/dev/null 2>&1; then
  section "database summary"
  run psql "$DATABASE_URL" -c "select count(*)::int as cameras_total, count(*) filter (where is_enabled)::int as cameras_enabled from cameras;"
  run psql "$DATABASE_URL" -c "select ds.name as node, ds.status, count(c.id)::int as cameras from dvr_servers ds left join cameras c on c.dvr_server_id=ds.id group by ds.id, ds.name, ds.status order by ds.name;"
  run psql "$DATABASE_URL" -c "select stream_name, event_type, event_state, occurred_at, created_at from camera_events order by occurred_at desc limit 30;"
  run psql "$DATABASE_URL" -c "select stream_name, event_type, count(*)::int as count, max(occurred_at) as last_at from camera_events where occurred_at > now() - interval '6 hours' group by stream_name,event_type order by last_at desc limit 30;"
fi

section "ffmpeg processes"
pgrep -af ffmpeg 2>/dev/null | redact || true

section "recent dvr logs"
journalctl -u newdomofon-video-dvr -n 220 --no-pager -l 2>/dev/null \
  | grep -E 'DVR engine listening|Started recorder|Recorder .* exited|ffmpeg:|No route|Connection timed out|video-motion|onvif-events|hikvision-events|archive-index' \
  | redact || true

section "verdict hints"
if [[ "$ROLE" != "node" ]] && systemctl is-active --quiet newdomofon-video-dvr.service 2>/dev/null; then
  echo "WARN: DVR service is active on a non-node role. In strict master/node production this should be stopped on master."
fi
if bool_enabled "${VIDEO_MOTION_ENABLED:-}"; then
  echo "WARN: VIDEO_MOTION is enabled. Keep it disabled until live is stable."
fi
if [[ -n "${ONVIF_LEGACY_FALLBACK_STREAMS:-}" ]]; then
  echo "WARN: ONVIF legacy fallback is enabled for streams: $ONVIF_LEGACY_FALLBACK_STREAMS"
fi

echo
echo "diagnostic_file=$OUT"
