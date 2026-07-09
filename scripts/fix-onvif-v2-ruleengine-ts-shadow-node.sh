#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="${PROJECT_DIR:-/opt/newdomofon-video}"
SERVICE="${SERVICE:-newdomofon-video-dvr.service}"
TARGET="$PROJECT_DIR/dvr-engine/src/onvifEventsV2.ts"
BACKUP_DIR="$PROJECT_DIR/backups/fix-onvif-v2-ruleengine-ts-shadow-$(date +%Y%m%d-%H%M%S)"

mkdir -p "$BACKUP_DIR"
cp -a "$TARGET" "$BACKUP_DIR/onvifEventsV2.ts.bak"

python3 - <<'PY'
from pathlib import Path
p = Path('/opt/newdomofon-video/dvr-engine/src/onvifEventsV2.ts')
s = p.read_text()

s = s.replace(
    '    const state = eventState(items);',
    '    const currentState: string | null = eventState(items);'
)
s = s.replace(
    '    const motionValue = items.IsMotion !== undefined ? String(items.IsMotion) : (items.isMotion !== undefined ? String(items.isMotion) : state);',
    '    const motionValue: string | null = items.IsMotion !== undefined ? String(items.IsMotion) : (items.isMotion !== undefined ? String(items.isMotion) : currentState);'
)
s = s.replace(
    '    const eventState = looksLikeMotion ? motionValue : state;',
    '    const normalizedEventState: string | null = looksLikeMotion ? motionValue : currentState;'
)
s = s.replace('looksLikeMotion && eventState !== null', 'looksLikeMotion && normalizedEventState !== null')
s = s.replace('!isTrueLike(eventState)', '!isTrueLike(normalizedEventState)')
s = s.replace('!isFalseLike(eventState)', '!isFalseLike(normalizedEventState)')
s = s.replace('dedupMotionState && eventState !== null', 'dedupMotionState && normalizedEventState !== null')
s = s.replace('previous === String(eventState)', 'previous === String(normalizedEventState)')
s = s.replace('motionStates.set(dedupKey, String(eventState));', 'motionStates.set(dedupKey, String(normalizedEventState));')
s = s.replace('      event_state: eventState,', '      event_state: normalizedEventState,')

p.write_text(s)
PY

cd "$PROJECT_DIR/dvr-engine"
npm install --include=dev
npm run build
sudo systemctl restart "$SERVICE"
sleep 8

echo "---- health ----"
curl -fsS http://127.0.0.1:3010/health || true
echo

echo "---- version/typecheck markers ----"
grep -nE "v144-ruleengine-ismotion-dedup|currentState|motionValue|normalizedEventState|event_state" "$TARGET" | head -80 || true

echo "---- onvif logs ----"
sudo journalctl -u "$SERVICE" --since "2 minutes ago" --no-pager -l | grep -E 'onvif-events:v2|pullpoint created|stored events|poll ok|poll failed|legacy-fallback' || true

echo "OK: ONVIF v2 RuleEngine TypeScript shadow issue fixed"
echo "backup_dir=$BACKUP_DIR"
