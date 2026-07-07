#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="${PROJECT_DIR:-/opt/newdomofon-video}"
ENV_FILE="${ENV_FILE:-/etc/newdomofon-video/app.env}"
TARGET_STREAM="${TARGET_STREAM:-${TEST_STREAM:-}}"
RAW_BASE="${RAW_BASE:-https://raw.githubusercontent.com/rirodevdom/newdomofon-video/main}"
DVR_FILE="$PROJECT_DIR/dvr-engine/src/onvifEventsV2.ts"
LEGACY_FILE="$PROJECT_DIR/dvr-engine/src/onvifEventsLegacyFallback.ts"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="$PROJECT_DIR/backups/onvif-events-fallback-fix-v2-$STAMP"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run as root: sudo bash scripts/apply-onvif-events-fallback-fix-v2.sh" >&2
  exit 1
fi

if [[ ! -f "$DVR_FILE" ]]; then
  echo "Missing ONVIF v2 collector source: $DVR_FILE" >&2
  exit 3
fi

install -d -m 0750 "$BACKUP_DIR"
cp -a "$DVR_FILE" "$BACKUP_DIR/onvifEventsV2.ts.bak"
if [[ -f "$LEGACY_FILE" ]]; then
  cp -a "$LEGACY_FILE" "$BACKUP_DIR/onvifEventsLegacyFallback.ts.bak"
fi
if [[ -f "$ENV_FILE" ]]; then
  cp -a "$ENV_FILE" "$BACKUP_DIR/app.env.bak"
else
  install -d -m 0750 "$(dirname "$ENV_FILE")"
  touch "$ENV_FILE"
  chmod 0640 "$ENV_FILE" || true
fi

if command -v curl >/dev/null 2>&1; then
  echo "Updating ONVIF event collectors from $RAW_BASE"
  curl -fsSL "$RAW_BASE/dvr-engine/src/onvifEventsV2.ts?$(date +%s)" -o "$DVR_FILE"
  curl -fsSL "$RAW_BASE/dvr-engine/src/onvifEventsLegacyFallback.ts?$(date +%s)" -o "$LEGACY_FILE"
fi

node - "$LEGACY_FILE" <<'NODE'
const fs = require('fs');

const file = process.argv[2];
let source = fs.readFileSync(file, 'utf8');

if (!source.includes("v141-legacy-fallback-visibility-watchdog")) {
source = source.replace(
  "const VERSION = 'v140-stable-legacy-fallback-session';",
  "const VERSION = 'v141-legacy-fallback-visibility-watchdog';"
);

source = source.replace(
  `interface LegacySession {
  cam: any;
  startedAt: number;
  fingerprint: string;
}`,
  `interface LegacySession {
  cam: any;
  startedAt: number;
  fingerprint: string;
  readyAt?: number;
  lastRawEventAt?: number;
  lastStoredAt?: number;
  lastIgnoredAt?: number;
  lastStatusLogAt?: number;
}`
);

source = source.replace(
  "    sessionTtlMs: Math.max(Number(process.env.ONVIF_LEGACY_SESSION_TTL_MS || 0), 0),\n    ignoreInitialized:",
  "    sessionTtlMs: Math.max(Number(process.env.ONVIF_LEGACY_SESSION_TTL_MS || 0), 0),\n    idleReconnectMs: Math.max(Number(process.env.ONVIF_LEGACY_IDLE_RECONNECT_MS || 10 * 60_000), 0),\n    statusLogMs: Math.max(Number(process.env.ONVIF_LEGACY_STATUS_LOG_MS || 60_000), 15_000),\n    rawEventLog: String(process.env.ONVIF_LEGACY_RAW_EVENT_LOG || 'true').toLowerCase() !== 'false',\n    ignoreInitialized:"
);

source = source.replace(
  `function logIgnoredSnapshot(payload: any) {
  const config = cfg();
  const now = Date.now();
  if (now - lastIgnoredSnapshotLogAt < config.quietLogMs) return;`,
  `function logIgnoredSnapshot(payload: any) {
  const config = cfg();
  const now = Date.now();
  const session = sessions.get(payload.stream_name);
  if (session) session.lastIgnoredAt = now;
  if (now - lastIgnoredSnapshotLogAt < config.quietLogMs) return;`
);

source = source.replace(
  `function startSession(camera: OnvifCamera) {`,
  `function ageMs(value?: number) {
  return value ? Date.now() - value : null;
}

function logSessionStatus(streamName: string, session: LegacySession) {
  const config = cfg();
  const now = Date.now();
  if (session.lastStatusLogAt && now - session.lastStatusLogAt < config.statusLogMs) return;
  session.lastStatusLogAt = now;
  console.log('[onvif-events:legacy-fallback] status', {
    stream_name: streamName,
    ready: Boolean(session.readyAt),
    ageMs: ageMs(session.startedAt),
    readyAgeMs: ageMs(session.readyAt),
    lastRawEventAgeMs: ageMs(session.lastRawEventAt),
    lastStoredAgeMs: ageMs(session.lastStoredAt),
    lastIgnoredAgeMs: ageMs(session.lastIgnoredAt)
  });
}

function startSession(camera: OnvifCamera) {`
);

source = source.replace(
  `    console.log('[onvif-events:legacy-fallback] ready', {
      stream_name: camera.stream_name
    });

    this.on('event', async (event: any) => {
      try {
        let payload = normalize(camera, event);`,
  `    console.log('[onvif-events:legacy-fallback] ready', {
      stream_name: camera.stream_name
    });
    const readySession = sessions.get(camera.stream_name);
    if (readySession) readySession.readyAt = Date.now();

    this.on('event', async (event: any) => {
      try {
        const activeSession = sessions.get(camera.stream_name);
        if (activeSession) activeSession.lastRawEventAt = Date.now();
        let payload = normalize(camera, event);
        if (cfg().rawEventLog) {
          console.log('[onvif-events:legacy-fallback] raw event', {
            stream_name: camera.stream_name,
            event_type: payload.event_type,
            event_state: payload.event_state,
            operation: payload.data?.operation ?? null,
            occurred_at: payload.occurred_at
          });
        }`
);

source = source.replace(
  `        await postEvent(payload);
        console.log('[onvif-events:legacy-fallback] stored event', {`,
  `        await postEvent(payload);
        const storedSession = sessions.get(camera.stream_name);
        if (storedSession) storedSession.lastStoredAt = Date.now();
        console.log('[onvif-events:legacy-fallback] stored event', {`
);

source = source.replace(
  `    if (!session || session.fingerprint !== fingerprint || sessionExpired) {
      startSession(camera);
    }`,
  `    const lastActivityAt = session?.lastRawEventAt || session?.readyAt;
    const sessionIdle = Boolean(
      session &&
      lastActivityAt &&
      config.idleReconnectMs > 0 &&
      Date.now() - lastActivityAt >= config.idleReconnectMs
    );
    if (session) logSessionStatus(camera.stream_name, session);
    if (!session || session.fingerprint !== fingerprint || sessionExpired || sessionIdle) {
      if (sessionIdle) {
        console.warn('[onvif-events:legacy-fallback] idle session reconnect', {
          stream_name: camera.stream_name,
          readyAgeMs: ageMs(session?.readyAt),
          lastRawEventAgeMs: ageMs(session?.lastRawEventAt),
          idleReconnectMs: config.idleReconnectMs
        });
      }
      startSession(camera);
    }`
);

source = source.replace(
  `    streams: Array.from(config.streams),
    sessionTtlMs: config.sessionTtlMs
  });`,
  `    streams: Array.from(config.streams),
    sessionTtlMs: config.sessionTtlMs,
    idleReconnectMs: config.idleReconnectMs,
    statusLogMs: config.statusLogMs,
    rawEventLog: config.rawEventLog
  });`
);
}

if (!source.includes("v141-legacy-fallback-visibility-watchdog") || !source.includes("idle session reconnect")) {
  throw new Error('Failed to patch legacy ONVIF fallback collector to v141');
}

fs.writeFileSync(file, source);
NODE

node - "$ENV_FILE" "$TARGET_STREAM" <<'NODE'
const fs = require('fs');

const file = process.argv[2];
const stream = process.argv[3];
let source = fs.existsSync(file) ? fs.readFileSync(file, 'utf8') : '';

function escapeRegExp(value) {
  return value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

function setCsv(key, value) {
  const re = new RegExp(`^${escapeRegExp(key)}=(.*)$`, 'm');
  const match = source.match(re);
  if (!match) {
    source = `${source.replace(/\s*$/, '')}\n${key}=${value}\n`;
    return;
  }

  const current = match[1]
    .split(',')
    .map((item) => item.trim())
    .filter(Boolean);
  if (!current.includes(value)) current.push(value);
  source = source.replace(re, `${key}=${current.join(',')}`);
}

function removeCsv(key, value) {
  const re = new RegExp(`^${escapeRegExp(key)}=(.*)$`, 'm');
  const match = source.match(re);
  if (!match) return;

  const next = match[1]
    .split(',')
    .map((item) => item.trim())
    .filter((item) => item && item !== value);

  if (next.length) {
    source = source.replace(re, `${key}=${next.join(',')}`);
  } else {
    source = source.replace(new RegExp(`^${escapeRegExp(key)}=.*\\n?`, 'm'), '');
  }
}

function setValue(key, value) {
  const re = new RegExp(`^${escapeRegExp(key)}=.*$`, 'm');
  if (re.test(source)) {
    source = source.replace(re, `${key}=${value}`);
    return;
  }
  source = `${source.replace(/\s*$/, '')}\n${key}=${value}\n`;
}

function deleteValue(key) {
  const re = new RegExp(`^${escapeRegExp(key)}=.*\\n?`, 'm');
  source = source.replace(re, '');
}

if (stream) {
  setCsv('ONVIF_LEGACY_FALLBACK_STREAMS', stream);
  removeCsv('ONVIF_V2_SKIP_STREAMS', stream);
  setValue('ONVIF_LEGACY_IGNORE_INITIALIZED', 'true');
  setValue('ONVIF_LEGACY_INITIALIZED_STATE_EVENTS', 'true');
  setValue('ONVIF_LEGACY_SESSION_TTL_MS', process.env.ONVIF_LEGACY_SESSION_TTL_MS || '0');
  setValue('ONVIF_LEGACY_IDLE_RECONNECT_MS', process.env.ONVIF_LEGACY_IDLE_RECONNECT_MS || '120000');
  setValue('ONVIF_LEGACY_STATUS_LOG_MS', process.env.ONVIF_LEGACY_STATUS_LOG_MS || '60000');
  setValue('ONVIF_LEGACY_RAW_EVENT_LOG', process.env.ONVIF_LEGACY_RAW_EVENT_LOG || 'true');
} else {
  deleteValue('ONVIF_V2_SKIP_STREAMS');
  deleteValue('ONVIF_EVENTS_V2_SKIP_STREAMS');
}
setValue('ONVIF_EVENT_POLL_INTERVAL_MS', process.env.ONVIF_EVENT_POLL_INTERVAL_MS || '2000');
setValue('ONVIF_EVENT_CONCURRENCY', process.env.ONVIF_EVENT_CONCURRENCY || '8');
setValue('ONVIF_SYNC_LOG_MS', process.env.ONVIF_SYNC_LOG_MS || '60000');
deleteValue('ONVIF_LEGACY_RECONNECT_MS');

fs.writeFileSync(file, source);
NODE

echo "Updated event collector env:"
grep -E '^(ONVIF_EVENT_POLL_INTERVAL_MS|ONVIF_EVENT_CONCURRENCY|ONVIF_SYNC_LOG_MS|ONVIF_LEGACY_FALLBACK_STREAMS|ONVIF_V2_SKIP_STREAMS|ONVIF_EVENTS_V2_SKIP_STREAMS|ONVIF_LEGACY_IGNORE_INITIALIZED|ONVIF_LEGACY_INITIALIZED_STATE_EVENTS|ONVIF_LEGACY_SESSION_TTL_MS|ONVIF_LEGACY_IDLE_RECONNECT_MS|ONVIF_LEGACY_STATUS_LOG_MS|ONVIF_LEGACY_RAW_EVENT_LOG|ONVIF_LEGACY_RECONNECT_MS)=' "$ENV_FILE" || true

pushd "$PROJECT_DIR/dvr-engine" >/dev/null
echo "Installing DVR build dependencies with dev packages..."
export NODE_ENV=
export NPM_CONFIG_PRODUCTION=false
if [[ -f package-lock.json ]]; then
  npm ci --include=dev || npm install --include=dev
else
  npm install --include=dev
fi

if [[ ! -x ./node_modules/.bin/tsc ]]; then
  echo "typescript compiler is still missing: ./node_modules/.bin/tsc" >&2
  exit 4
fi

./node_modules/.bin/tsc --version
npm run build
popd >/dev/null

systemctl restart newdomofon-video-dvr.service

echo
curl -fsS -m 5 -i http://127.0.0.1:3010/health | sed -n '1,30p' || true

echo
systemctl status newdomofon-video-dvr.service --no-pager -l | sed -n '1,40p' || true

echo
journalctl -u newdomofon-video-dvr -n 180 --no-pager -l \
  | grep -E "onvif-events:(v2|legacy-fallback)|${TARGET_STREAM:-ONVIF_EVENT_CONCURRENCY}|CreatePullPoint|poll failed|stored event|ignored initialized" || true

echo
echo "ONVIF events fallback fix v2 applied. Backup: $BACKUP_DIR"
