#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="${PROJECT_DIR:-/opt/newdomofon-video-node}"
RAW_BASE="${RAW_BASE:-https://raw.githubusercontent.com/rirodevdom/newdomofon-video/main}"
DVR_FILE="$PROJECT_DIR/dvr-engine/src/onvifEventsV2.ts"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="$PROJECT_DIR/backups/onvif-events-v2-pullpoint-compat-$STAMP"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run as root: sudo bash scripts/apply-onvif-events-v2-pullpoint-compat.sh" >&2
  exit 1
fi

if [[ ! -f "$DVR_FILE" ]]; then
  echo "Missing ONVIF v2 collector source: $DVR_FILE" >&2
  exit 2
fi

install -d -m 0750 "$BACKUP_DIR"
cp -a "$DVR_FILE" "$BACKUP_DIR/onvifEventsV2.ts.bak"

if command -v curl >/dev/null 2>&1; then
  echo "Refreshing ONVIF v2 collector from $RAW_BASE"
  curl -fsSL "$RAW_BASE/dvr-engine/src/onvifEventsV2.ts?$(date +%s%N)" -o "$DVR_FILE"
fi

node - "$DVR_FILE" <<'NODE'
const fs = require('fs');

const file = process.argv[2];
let source = fs.readFileSync(file, 'utf8');

source = source.replace(
  /const VERSION = '[^']*';/,
  "const VERSION = 'v143-pullpoint-compat';"
);

source = source.replace('text.slice(0, 300)', 'text.slice(0, 1200)');
source = source.replace('text.slice(0, 1200)', 'text.slice(0, 1200)');

source = source.replace(
  "console.warn('[onvif-events:v2]', camera.stream_name, 'poll failed', {",
  "console.warn(`[onvif-events:v2] ${camera.stream_name} poll failed: ${message}`, {"
);

const createStart = source.indexOf('async function createPullPoint(');
const pullStart = source.indexOf('async function pullMessages(', createStart);
if (createStart < 0 || pullStart < 0) {
  throw new Error('Could not locate createPullPoint/pullMessages block');
}

const replacement = `function eventServiceCandidates(camera: OnvifCamera, eventXaddr: string) {
  const candidates = [eventXaddr, camera.onvif_xaddr];

  try {
    const url = new URL(camera.onvif_xaddr);
    const base = \`${'${url.protocol}'}//${'${url.host}'}\`;
    candidates.push(
      \`${'${base}'}/onvif/event_service\`,
      \`${'${base}'}/onvif/EventService\`,
      \`${'${base}'}/onvif/events_service\`,
      \`${'${base}'}/onvif/device_service\`
    );
  } catch {
    // Keep the candidates found from ONVIF services.
  }

  return Array.from(new Set(candidates.filter(Boolean)));
}

async function createPullPoint(camera: OnvifCamera, eventXaddrs: string[], username: string, password: string) {
  const variants = [
    {
      name: 'with-ttl',
      action: 'http://www.onvif.org/ver10/events/wsdl/EventPortType/CreatePullPointSubscriptionRequest',
      body: '<tev:CreatePullPointSubscription><tev:InitialTerminationTime>PT1H</tev:InitialTerminationTime></tev:CreatePullPointSubscription>'
    },
    {
      name: 'without-ttl',
      action: 'http://www.onvif.org/ver10/events/wsdl/EventPortType/CreatePullPointSubscriptionRequest',
      body: '<tev:CreatePullPointSubscription/>'
    },
    {
      name: 'bare-action',
      action: 'http://www.onvif.org/ver10/events/wsdl/CreatePullPointSubscription',
      body: '<tev:CreatePullPointSubscription/>'
    }
  ];

  let lastError: unknown = null;

  for (const eventXaddr of eventXaddrs) {
    for (const variant of variants) {
      try {
        const result = await soapRequest(eventXaddr, variant.action, variant.body, username, password);
        const address = firstString(result.json, ['Address']);
        return {
          pullPoint: address || eventXaddr,
          eventXaddr,
          variant: variant.name
        };
      } catch (error) {
        lastError = error;
        const message = error instanceof Error ? error.message : String(error);
        console.warn(\`[onvif-events:v2] ${'${camera.stream_name}'} createPullPoint variant failed: ${'${message.slice(0, 500)}'}\`, {
          eventXaddr,
          variant: variant.name
        });
      }
    }
  }

  throw lastError || new Error('CreatePullPointSubscription failed');
}

`;

source = `${source.slice(0, createStart)}${replacement}${source.slice(pullStart)}`;

source = source.replace(
  `      session.pullPoint = await createPullPoint(session.eventXaddr, creds.username, creds.password);
      session.pullPointCreatedAt = Date.now();
      console.log('[onvif-events:v2] pullpoint created', {
        stream_name: camera.stream_name,
        pullPoint: session.pullPoint,
        ttlMs: config.subscribeTtlMs
      });`,
  `      const created = await createPullPoint(camera, eventServiceCandidates(camera, session.eventXaddr), creds.username, creds.password);
      session.eventXaddr = created.eventXaddr;
      session.pullPoint = created.pullPoint;
      session.pullPointCreatedAt = Date.now();
      console.log('[onvif-events:v2] pullpoint created', {
        stream_name: camera.stream_name,
        pullPoint: session.pullPoint,
        eventXaddr: session.eventXaddr,
        variant: created.variant,
        ttlMs: config.subscribeTtlMs
      });`
);

if (!source.includes("v143-pullpoint-compat") || !source.includes('eventServiceCandidates') || !source.includes('createPullPoint variant failed')) {
  throw new Error('ONVIF v2 PullPoint compatibility patch did not apply cleanly');
}

fs.writeFileSync(file, source);
NODE

echo "Patched collector version:"
grep -m1 "const VERSION" "$DVR_FILE" || true

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

echo
systemctl status newdomofon-video-dvr.service --no-pager -l | sed -n '1,35p' || true

echo
journalctl -u newdomofon-video-dvr -n 120 --no-pager -l \
  | grep -E "onvif-events:v2|createPullPoint variant failed|pullpoint created|poll failed|stored events" || true

echo
echo "ONVIF v2 PullPoint compatibility hotfix applied. Backup: $BACKUP_DIR"
