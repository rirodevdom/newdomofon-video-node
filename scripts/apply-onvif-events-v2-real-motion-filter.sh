#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="${PROJECT_DIR:-/opt/newdomofon-video}"
RAW_BASE="${RAW_BASE:-https://raw.githubusercontent.com/rirodevdom/newdomofon-video/main}"
ENV_FILE="${ENV_FILE:-/etc/newdomofon-video/app.env}"
DVR_FILE="$PROJECT_DIR/dvr-engine/src/onvifEventsV2.ts"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="$PROJECT_DIR/backups/onvif-events-v2-real-motion-filter-$STAMP"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run as root: sudo bash scripts/apply-onvif-events-v2-real-motion-filter.sh" >&2
  exit 1
fi

if [[ ! -f "$DVR_FILE" ]]; then
  echo "Missing ONVIF v2 collector source: $DVR_FILE" >&2
  exit 2
fi

install -d -m 0750 "$BACKUP_DIR"
cp -a "$DVR_FILE" "$BACKUP_DIR/onvifEventsV2.ts.bak"
cp -a "$ENV_FILE" "$BACKUP_DIR/app.env.bak" 2>/dev/null || true

if command -v curl >/dev/null 2>&1; then
  echo "Refreshing ONVIF v2 collector from $RAW_BASE"
  curl -fsSL "$RAW_BASE/dvr-engine/src/onvifEventsV2.ts?$(date +%s%N)" -o "$DVR_FILE"
fi

node - "$DVR_FILE" <<'NODE'
const fs = require('fs');
const file = process.argv[2];
let source = fs.readFileSync(file, 'utf8');

source = source.replace(/const VERSION = '[^']*';/, "const VERSION = 'v145-snapshot-state-transitions';");

source = source.replace(
  "const sessions = new Map<string, CameraSession>();\nlet timer: NodeJS.Timeout | null = null;",
  "const sessions = new Map<string, CameraSession>();\nconst snapshotStates = new Map<string, string>();\nlet timer: NodeJS.Timeout | null = null;"
);

source = source.replace(
  "    subscribeTtlMs: Math.max(Number(process.env.ONVIF_SUBSCRIBE_TTL_MS || 5 * 60_000), 60_000),",
  "    subscribeTtlMs: Math.max(Number(process.env.ONVIF_SUBSCRIBE_TTL_MS || 60 * 60_000), 60_000),"
);

source = source.replace(
  /    skipStreams: new Set\(\n      String\(process\.env\.ONVIF_V2_SKIP_STREAMS \|\| process\.env\.ONVIF_EVENTS_V2_SKIP_STREAMS \|\| ''\)\n        \.split\(','\)\n        \.map\(\(value\) => value\.trim\(\)\)\n        \.filter\(Boolean\)\n    \)\n  };\n}/,
  `    skipStreams: new Set(
      String(process.env.ONVIF_V2_SKIP_STREAMS || process.env.ONVIF_EVENTS_V2_SKIP_STREAMS || '')
        .split(',')
        .map((value) => value.trim())
        .filter(Boolean)
    ),
    ignoreInitialized: String(process.env.ONVIF_V2_IGNORE_INITIALIZED || 'true').toLowerCase() !== 'false',
    detailLog: String(process.env.ONVIF_EVENT_DETAIL_LOG || 'true').toLowerCase() !== 'false',
    snapshotTransitions: String(process.env.ONVIF_V2_SNAPSHOT_TRANSITIONS || 'true').toLowerCase() !== 'false'
  };
}`
);

const mapStart = source.indexOf('function mapEvents(camera: OnvifCamera, xml: any) {');
const backendStart = source.indexOf('async function backendGet(path: string)', mapStart);
if (mapStart < 0 || backendStart < 0) {
  throw new Error('Could not locate mapEvents/backendGet block');
}

const mapReplacement = `function propertyOperation(notification: any) {
  const value = firstString(notification, ['@_PropertyOperation', 'PropertyOperation', 'propertyOperation']);
  return value ? String(value).trim() : null;
}

function eventDebugSample(event: any) {
  const simple = event?.data?.simple || {};
  return {
    type: event.event_type,
    state: event.event_state,
    occurred_at: event.occurred_at,
    topic: event.topic || null,
    source: event.source_name || null,
    operation: event?.data?.operation || null,
    state_key: event?.data?.state_key || null,
    synthetic: Boolean(event?.data?._newdomofon_snapshot_transition),
    previous: event?.data?._newdomofon_previous_state || null,
    simple
  };
}

function snapshotStateKey(camera: OnvifCamera, topic: string, source: string | null, key: string | null) {
  return [camera.id, camera.stream_name, topic || 'onvif.event', source || '', key || 'state'].join('|');
}

function mapEvents(camera: OnvifCamera, xml: any) {
  const config = cfg();
  let ignoredInitialized = 0;
  let snapshotsSeen = 0;
  let synthesizedTransitions = 0;
  const events: any[] = [];

  for (const notification of collectNotifications(xml)) {
    const topic = topicFromNotification(notification);
    const items = collectSimpleItems(notification);
    const key = stateKey(items);
    const state = eventState(items);
    const source = sourceName(items);
    const operation = propertyOperation(notification);
    const normalizedTopic = topic || topicLeaf(topic);
    const originalOccurredAt = occurredAt(notification);

    const baseEvent = {
      camera_id: camera.id,
      stream_name: camera.stream_name,
      event_type: normalizedTopic,
      event_state: state,
      topic,
      source_name: source,
      occurred_at: originalOccurredAt,
      data: {
        simple: items,
        simpleItems: items,
        state_key: key,
        source_name: source,
        operation,
        raw: notification
      }
    };

    if (String(operation || '').toLowerCase() === 'initialized') {
      snapshotsSeen += 1;
      const snapshotState = state === null || state === undefined ? null : String(state);
      const keyName = snapshotStateKey(camera, normalizedTopic, source, key);
      const previous = snapshotStates.get(keyName);

      if (snapshotState !== null) {
        snapshotStates.set(keyName, snapshotState);
      }

      if (config.snapshotTransitions && snapshotState !== null && previous !== undefined && previous !== snapshotState) {
        synthesizedTransitions += 1;
        events.push({
          ...baseEvent,
          occurred_at: nowIso(),
          data: {
            ...baseEvent.data,
            operation: 'SnapshotStateChanged',
            original_operation: operation,
            original_occurred_at: originalOccurredAt,
            _newdomofon_snapshot_transition: true,
            _newdomofon_previous_state: previous,
            _newdomofon_current_state: snapshotState
          }
        });
      } else if (config.ignoreInitialized) {
        ignoredInitialized += 1;
      } else {
        events.push(baseEvent);
      }

      continue;
    }

    events.push(baseEvent);
  }

  return { events, ignoredInitialized, snapshotsSeen, synthesizedTransitions };
}

`;
source = source.slice(0, mapStart) + mapReplacement + source.slice(backendStart);

source = source.replace(
  '    const messages = await pullMessages(session.pullPoint, creds.username, creds.password);\n    const events = mapEvents(camera, messages);\n\n    markOk(session);',
  `    const messages = await pullMessages(session.pullPoint, creds.username, creds.password);
    const mapped = mapEvents(camera, messages);
    const events = mapped.events;

    if ((mapped.ignoredInitialized || mapped.synthesizedTransitions) && config.detailLog && (!session.lastLogAt || now - session.lastLogAt > config.quietLogMs || mapped.synthesizedTransitions)) {
      console.log('[onvif-events:v2] ' + camera.stream_name + ' snapshot states: seen=' + mapped.snapshotsSeen + ' ignored=' + mapped.ignoredInitialized + ' synthesized=' + mapped.synthesizedTransitions);
    }

    markOk(session);`
);

source = source.replace(
  `      console.log('[onvif-events:v2] stored events', {
        stream_name: camera.stream_name,
        events: events.length,
        inserted,
        lastEventAt: session.lastEventAt
      });`,
  `      if (config.detailLog) {
        const samples = events.slice(0, 8).map(eventDebugSample);
        console.log('[onvif-events:v2] ' + camera.stream_name + ' stored events: events=' + events.length + ' inserted=' + inserted + ' lastEventAt=' + session.lastEventAt + ' samples=' + JSON.stringify(samples));
      } else {
        console.log('[onvif-events:v2] stored events', {
          stream_name: camera.stream_name,
          events: events.length,
          inserted,
          lastEventAt: session.lastEventAt
        });
      }`
);

if (!source.includes("v145-snapshot-state-transitions") || !source.includes('snapshotStateKey') || !source.includes('SnapshotStateChanged')) {
  throw new Error('ONVIF v145 snapshot transition patch did not apply cleanly');
}

fs.writeFileSync(file, source);
NODE

install -d -m 0750 "$(dirname "$ENV_FILE")"
touch "$ENV_FILE"
chmod 0640 "$ENV_FILE" || true

node - "$ENV_FILE" <<'NODE'
const fs = require('fs');
const file = process.argv[2];
let lines = fs.existsSync(file) ? fs.readFileSync(file, 'utf8').split(/\r?\n/) : [];
const remove = new Set([
  'ONVIF_LEGACY_FALLBACK_STREAMS',
  'ONVIF_V2_SKIP_STREAMS',
  'ONVIF_EVENTS_V2_SKIP_STREAMS',
  'ONVIF_LEGACY_RECONNECT_MS'
]);
lines = lines.filter((line) => {
  const key = String(line).split('=')[0].trim();
  return key && !remove.has(key);
});
function setValue(key, value) {
  lines = lines.filter((line) => String(line).split('=')[0].trim() !== key);
  lines.push(`${key}=${value}`);
}
setValue('ONVIF_EVENT_POLL_INTERVAL_MS', process.env.ONVIF_EVENT_POLL_INTERVAL_MS || '2000');
setValue('ONVIF_EVENT_CONCURRENCY', process.env.ONVIF_EVENT_CONCURRENCY || '8');
setValue('ONVIF_SYNC_LOG_MS', process.env.ONVIF_SYNC_LOG_MS || '60000');
setValue('ONVIF_SUBSCRIBE_TTL_MS', process.env.ONVIF_SUBSCRIBE_TTL_MS || '3600000');
setValue('ONVIF_V2_IGNORE_INITIALIZED', process.env.ONVIF_V2_IGNORE_INITIALIZED || 'true');
setValue('ONVIF_EVENT_DETAIL_LOG', process.env.ONVIF_EVENT_DETAIL_LOG || 'true');
setValue('ONVIF_V2_SNAPSHOT_TRANSITIONS', process.env.ONVIF_V2_SNAPSHOT_TRANSITIONS || 'true');
fs.writeFileSync(file, lines.join('\n').replace(/\n*$/, '\n'));
NODE

echo "Patched collector version:"
grep -m1 "const VERSION" "$DVR_FILE" || true

echo "Updated ONVIF event env:"
grep -E '^(ONVIF_EVENT_POLL_INTERVAL_MS|ONVIF_EVENT_CONCURRENCY|ONVIF_SYNC_LOG_MS|ONVIF_SUBSCRIBE_TTL_MS|ONVIF_V2_IGNORE_INITIALIZED|ONVIF_EVENT_DETAIL_LOG|ONVIF_V2_SNAPSHOT_TRANSITIONS|ONVIF_LEGACY_FALLBACK_STREAMS|ONVIF_V2_SKIP_STREAMS)=' "$ENV_FILE" || true

pushd "$PROJECT_DIR/dvr-engine" >/dev/null
echo "Building DVR engine..."
export NODE_ENV=
export NPM_CONFIG_PRODUCTION=false
if [[ -f package-lock.json ]]; then
  npm ci --include=dev || npm install --include=dev
else
  npm install --include=dev
fi
npm run build
popd >/dev/null

systemctl restart newdomofon-video-dvr.service
sleep 1

echo
systemctl status newdomofon-video-dvr.service --no-pager -l | sed -n '1,35p' || true

echo
journalctl -u newdomofon-video-dvr -n 180 --no-pager -l \
  | grep -E "v145|snapshot states|stored events:|pullpoint created|poll failed|legacy-fallback" || true

echo
echo "ONVIF v2 snapshot transition filter applied. Backup: $BACKUP_DIR"
