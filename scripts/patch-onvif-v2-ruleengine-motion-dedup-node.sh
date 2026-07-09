#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="${PROJECT_DIR:-/opt/newdomofon-video}"
ENV_FILE="${ENV_FILE:-/etc/newdomofon-video/app.env}"
SERVICE="${SERVICE:-newdomofon-video-dvr.service}"
TARGET="$PROJECT_DIR/dvr-engine/src/onvifEventsV2.ts"
BACKUP_DIR="$PROJECT_DIR/backups/onvif-v2-ruleengine-motion-dedup-$(date +%Y%m%d-%H%M%S)"

mkdir -p "$BACKUP_DIR"
cp -a "$TARGET" "$BACKUP_DIR/onvifEventsV2.ts.bak"
cp -a "$ENV_FILE" "$BACKUP_DIR/app.env.bak" 2>/dev/null || true

python3 - <<'PY'
from pathlib import Path

p = Path('/opt/newdomofon-video/dvr-engine/src/onvifEventsV2.ts')
s = p.read_text()

if 'v144-ruleengine-ismotion-dedup' not in s:
    s = s.replace("const VERSION = 'v143-pullpoint-compat';", "const VERSION = 'v144-ruleengine-ismotion-dedup';")

if 'const motionStates = new Map<string, string>();' not in s:
    s = s.replace('const sessions = new Map<string, CameraSession>();', 'const sessions = new Map<string, CameraSession>();\nconst motionStates = new Map<string, string>();')

def replace_function(src: str, name: str, replacement: str) -> str:
    sig = f'function {name}'
    start = src.find(sig)
    if start < 0:
        raise SystemExit(f'{sig} not found')
    brace = src.find('{', start)
    if brace < 0:
        raise SystemExit(f'{sig} brace not found')
    depth = 0
    i = brace
    while i < len(src):
        if src[i] == '{':
            depth += 1
        elif src[i] == '}':
            depth -= 1
            if depth == 0:
                return src[:start] + replacement + src[i+1:]
        i += 1
    raise SystemExit(f'{sig} end not found')

new_map = r'''function operationFromNotification(notification: any): string | null {
  return firstString(notification, ['@_PropertyOperation', 'PropertyOperation', 'propertyOperation']);
}

function isTrueLike(value: string | null) {
  const normalized = String(value ?? '').trim().toLowerCase();
  return ['true', '1', 'yes', 'on', 'active', 'motion', 'detected'].includes(normalized);
}

function isFalseLike(value: string | null) {
  const normalized = String(value ?? '').trim().toLowerCase();
  return ['false', '0', 'no', 'off', 'inactive', 'idle', 'clear', 'none'].includes(normalized);
}

function mapEvents(camera: OnvifCamera, xml: any) {
  const motionOnly = String(process.env.ONVIF_RULEENGINE_MOTION_ONLY || 'true').toLowerCase() !== 'false';
  const ignoreInitialized = String(process.env.ONVIF_IGNORE_INITIALIZED || 'true').toLowerCase() !== 'false';
  const normalizeMotionType = String(process.env.ONVIF_NORMALIZE_MOTION_EVENT_TYPE || 'true').toLowerCase() !== 'false';
  const dedupMotionState = String(process.env.ONVIF_MOTION_STATE_DEDUP || 'true').toLowerCase() !== 'false';
  const events: any[] = [];

  for (const notification of collectNotifications(xml)) {
    const topic = topicFromNotification(notification);
    const items = collectSimpleItems(notification);
    const key = stateKey(items);
    const state = eventState(items);
    const operation = operationFromNotification(notification);
    const source = sourceName(items);
    const hasIsMotion = items.IsMotion !== undefined || items.isMotion !== undefined;
    const motionValue = items.IsMotion !== undefined ? String(items.IsMotion) : (items.isMotion !== undefined ? String(items.isMotion) : state);
    const looksLikeMotion = hasIsMotion || /RuleEngine|Motion|MyMotion|VideoAnalytics/i.test(topic) || key === 'IsMotion' || key === 'Motion';

    if (ignoreInitialized && String(operation || '').trim().toLowerCase() === 'initialized') continue;
    if (motionOnly && !looksLikeMotion) continue;

    const eventType = looksLikeMotion && normalizeMotionType ? 'onvif.motion' : (topic || topicLeaf(topic));
    const eventState = looksLikeMotion ? motionValue : state;
    if (looksLikeMotion && eventState !== null && !isTrueLike(eventState) && !isFalseLike(eventState)) continue;

    const dedupKey = `${camera.id}|${camera.stream_name}|${eventType}|${key || 'state'}`;
    if (dedupMotionState && eventState !== null) {
      const previous = motionStates.get(dedupKey);
      if (previous === String(eventState)) continue;
      motionStates.set(dedupKey, String(eventState));
    }

    events.push({
      camera_id: camera.id,
      stream_name: camera.stream_name,
      event_type: eventType,
      event_state: eventState,
      topic,
      source_name: source || 'onvif-ruleengine',
      occurred_at: occurredAt(notification),
      data: {
        collector: VERSION,
        simple: items,
        simpleItems: items,
        state_key: key,
        operation: operation || null,
        source_name: source || 'onvif-ruleengine',
        topic,
        normalized_event_type: eventType,
        is_motion: looksLikeMotion,
        raw: notification
      }
    });
  }

  return events;
}'''

s = replace_function(s, 'mapEvents', new_map)
p.write_text(s)
PY

sudo sed -i -E '/^(ONVIF_RULEENGINE_MOTION_ONLY|ONVIF_IGNORE_INITIALIZED|ONVIF_NORMALIZE_MOTION_EVENT_TYPE|ONVIF_MOTION_STATE_DEDUP|ONVIF_V2_SKIP_STREAMS|ONVIF_EVENTS_V2_SKIP_STREAMS|ONVIF_LEGACY_FALLBACK_STREAMS)=/d' "$ENV_FILE" 2>/dev/null || true
cat <<'EOF' | sudo tee -a "$ENV_FILE" >/dev/null
ONVIF_RULEENGINE_MOTION_ONLY=true
ONVIF_IGNORE_INITIALIZED=true
ONVIF_NORMALIZE_MOTION_EVENT_TYPE=true
ONVIF_MOTION_STATE_DEDUP=true
ONVIF_V2_SKIP_STREAMS=
ONVIF_EVENTS_V2_SKIP_STREAMS=
ONVIF_LEGACY_FALLBACK_STREAMS=__disabled__
EOF

cd "$PROJECT_DIR/dvr-engine"
npm install --include=dev
npm run build
sudo systemctl restart "$SERVICE"
sleep 8

echo "---- health ----"
curl -fsS http://127.0.0.1:3010/health || true
echo

echo "---- onvif logs ----"
sudo journalctl -u "$SERVICE" --since "2 minutes ago" --no-pager -l | grep -E 'onvif-events:v2|pullpoint created|stored events|poll ok|poll failed|legacy-fallback' || true

echo "OK: ONVIF v2 now stores only real RuleEngine IsMotion state changes as onvif.motion"
echo "backup_dir=$BACKUP_DIR"
