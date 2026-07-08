#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="${PROJECT_DIR:-/opt/newdomofon-video}"
ENV_FILE="${ENV_FILE:-/etc/newdomofon-video/app.env}"
OUT_DIR="${OUT_DIR:-$PROJECT_DIR/diagnostics}"
STAMP="$(date +%Y%m%d-%H%M%S)"
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

section() { printf '\n===== %s =====\n' "$1"; }

run() {
  echo "+ $*"
  set +e
  "$@" 2>&1 | redact
  local code=${PIPESTATUS[0]}
  set -e
  echo "exit=$code"
}

[[ -f "$ENV_FILE" ]] && { set -a; . "$ENV_FILE"; set +a; }

section host
echo "date=$(date -Is)"
echo "hostname=$(hostname -f 2>/dev/null || hostname)"
echo "project=$PROJECT_DIR"
echo "env=$ENV_FILE"
run uname -a
run ip -br addr
run ip route

section role
ROLE="standalone-or-master"
if [[ -n "${DVR_MASTER_URL:-}" && -n "${DVR_NODE_ID:-}" && -n "${DVR_NODE_TOKEN:-}" ]]; then
  ROLE="node"
elif [[ -n "${DATABASE_URL:-}" ]]; then
  ROLE="master-or-standalone"
fi
echo "detected_role=$ROLE"
for key in DVR_ENGINE_ROLE DVR_MASTER_URL DVR_NODE_ID DVR_NODE_PUBLIC_BASE_URL DVR_NODE_INTERNAL_URL DATABASE_URL DVR_REQUIRE_MEDIA_TOKEN VIDEO_MOTION_ENABLED EVENTS_ENABLED ONVIF_EVENTS_ENABLED DVR_HIKVISION_EVENTS_ENABLED DVR_HIKVISION_ARCHIVE_INDEX_ENABLED ONVIF_LEGACY_FALLBACK_STREAMS ONVIF_V2_SKIP_STREAMS ONVIF_EVENTS_V2_SKIP_STREAMS; do
  value="${!key-}"
  case "$key" in
    DATABASE_URL|DVR_NODE_TOKEN|INTERNAL_DVR_SECRET|JWT_SECRET) [[ -n "$value" ]] && value="set" ;;
  esac
  echo "$key=$value" | redact
done

section services
for service in newdomofon-video-backend newdomofon-video-dvr newdomofon-public-events-proxy newdomofon-smartyard-compat nginx postgresql; do
  if systemctl list-unit-files "$service.service" >/dev/null 2>&1 || systemctl status "$service.service" >/dev/null 2>&1; then
    echo "--- $service ---"
    systemctl is-enabled "$service.service" 2>/dev/null || true
    systemctl is-active "$service.service" 2>/dev/null || true
    systemctl --no-pager -l status "$service.service" 2>/dev/null | sed -n '1,14p' | redact || true
  fi
done

section health
run curl -fsS --max-time 5 http://127.0.0.1:3000/api/health
run curl -fsS --max-time 5 http://127.0.0.1:3010/health
run curl -fsS --max-time 5 http://127.0.0.1:3010/recorders
[[ -n "${DVR_MASTER_URL:-}" ]] && run curl -fsS --max-time 10 "$DVR_MASTER_URL/api/health"

section node_config_and_camera_network
if [[ -n "${DVR_MASTER_URL:-}" && -n "${DVR_NODE_ID:-}" && -n "${DVR_NODE_TOKEN:-}" ]]; then
  TMP_CONFIG="$(mktemp)"
  set +e
  curl -fsS --max-time 25 -H "Authorization: Bearer $DVR_NODE_TOKEN" -H "x-node-id: $DVR_NODE_ID" "$DVR_MASTER_URL/api/node-agent/config" > "$TMP_CONFIG"
  code=$?
  set -e
  echo "node_config_exit=$code"
  if [[ $code -eq 0 ]]; then
    node -e "const fs=require('fs');const d=JSON.parse(fs.readFileSync(process.argv[1],'utf8'));const cams=d.cameras||[];console.log('assigned_cameras='+cams.length); for(const c of cams){let h='',p='';try{const u=new URL(c.source_url||'');h=u.hostname;p=u.port||(u.protocol==='rtsp:'?'554':'80')}catch{} console.log([c.stream_name,c.id,c.device_connection_type||'',c.archive_storage||'',h,p].join('\\t'))}" "$TMP_CONFIG" | redact
    node -e "const fs=require('fs');const d=JSON.parse(fs.readFileSync(process.argv[1],'utf8'));const seen=new Set();for(const c of (d.cameras||[])){try{const u=new URL(c.source_url||'');const h=u.hostname;const p=u.port||(u.protocol==='rtsp:'?'554':'80');const k=h+':'+p;if(h&&!seen.has(k)){seen.add(k);console.log([c.stream_name,h,p].join('\\t'))}}catch{}}" "$TMP_CONFIG" > /tmp/newdomofon-camera-hosts.txt
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
else
  echo "not a node or node credentials missing"
fi

section database_summary
if [[ -n "${DATABASE_URL:-}" ]] && command -v psql >/dev/null 2>&1; then
  run psql "$DATABASE_URL" -c "select count(*)::int cameras_total, count(*) filter(where is_enabled)::int cameras_enabled from cameras;"
  run psql "$DATABASE_URL" -c "select ds.name node, ds.status, count(c.id)::int cameras from dvr_servers ds left join cameras c on c.dvr_server_id=ds.id group by ds.id,ds.name,ds.status order by ds.name;"
  run psql "$DATABASE_URL" -c "select stream_name,event_type,event_state,occurred_at,created_at from camera_events order by occurred_at desc limit 30;"
  run psql "$DATABASE_URL" -c "select stream_name,event_type,count(*)::int count,max(occurred_at) last_at from camera_events where occurred_at > now() - interval '6 hours' group by stream_name,event_type order by last_at desc limit 30;"
else
  echo "DATABASE_URL or psql is unavailable"
fi

section ffmpeg_processes
pgrep -af ffmpeg 2>/dev/null | redact || true

section recent_dvr_logs
journalctl -u newdomofon-video-dvr -n 240 --no-pager -l 2>/dev/null \
  | grep -E 'DVR engine listening|Started recorder|Recorder .* exited|ffmpeg:|No route|Connection timed out|video-motion|onvif-events|hikvision-events|archive-index' \
  | redact || true

section verdict_hints
if [[ "$ROLE" != "node" ]] && systemctl is-active --quiet newdomofon-video-dvr.service 2>/dev/null; then
  echo "WARN: DVR service is active on a non-node role. In strict master/node production it should be disabled on master."
fi
case "$(echo "${VIDEO_MOTION_ENABLED:-}" | tr '[:upper:]' '[:lower:]')" in 1|true|yes|on) echo "WARN: VIDEO_MOTION is enabled. Keep it disabled until live is stable.";; esac
[[ -n "${ONVIF_LEGACY_FALLBACK_STREAMS:-}" ]] && echo "WARN: ONVIF legacy fallback enabled: $ONVIF_LEGACY_FALLBACK_STREAMS"

echo
echo "diagnostic_file=$OUT"
