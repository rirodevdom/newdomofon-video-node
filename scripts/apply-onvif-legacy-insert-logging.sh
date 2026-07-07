#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="${PROJECT_DIR:-/opt/newdomofon-video}"
LEGACY_FILE="$PROJECT_DIR/dvr-engine/src/onvifEventsLegacyFallback.ts"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="$PROJECT_DIR/backups/onvif-legacy-insert-logging-$STAMP"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run as root: sudo bash scripts/apply-onvif-legacy-insert-logging.sh" >&2
  exit 1
fi

if [[ ! -f "$LEGACY_FILE" ]]; then
  echo "Missing legacy fallback source: $LEGACY_FILE" >&2
  exit 2
fi

install -d -m 0750 "$BACKUP_DIR"
cp -a "$LEGACY_FILE" "$BACKUP_DIR/onvifEventsLegacyFallback.ts.bak"

node - "$LEGACY_FILE" <<'NODE'
const fs = require('fs');

const file = process.argv[2];
let source = fs.readFileSync(file, 'utf8');

source = source.replace(
`  if (!response.ok) {
    throw new Error(
      \`Backend POST event HTTP \${response.status}: \${(await response.text()).slice(0, 200)}\`
    );
  }
}`,
`  const text = await response.text();
  if (!response.ok) {
    throw new Error(
      \`Backend POST event HTTP \${response.status}: \${text.slice(0, 200)}\`
    );
  }
  try {
    return JSON.parse(text || '{}');
  } catch {
    return { ok: true, raw: text };
  }
}`
);

source = source.replace(
`        const payload = normalize(camera, event);
        await postEvent(payload);
        console.log('[onvif-events:legacy-fallback] stored event', {
          stream_name: camera.stream_name,
          event_type: payload.event_type,
          occurred_at: payload.occurred_at
        });`,
`        const payload = normalize(camera, event);
        const result = await postEvent(payload);
        const inserted = Number(result?.inserted || 0);
        const logPayload = {
          stream_name: camera.stream_name,
          event_type: payload.event_type,
          event_state: payload.event_state,
          occurred_at: payload.occurred_at,
          inserted,
          simple: payload.data?.simple || {}
        };
        if (inserted > 0) {
          console.log('[onvif-events:legacy-fallback] inserted event', logPayload);
        } else {
          console.log('[onvif-events:legacy-fallback] duplicate event', logPayload);
        }`
);

if (!source.includes('const text = await response.text();') || !source.includes('inserted event') || !source.includes('duplicate event')) {
  throw new Error('Failed to patch legacy fallback logging; source layout was not recognized');
}

fs.writeFileSync(file, source);
NODE

pushd "$PROJECT_DIR/dvr-engine" >/dev/null
export NODE_ENV=
export NPM_CONFIG_PRODUCTION=false
if [[ ! -x ./node_modules/.bin/tsc ]]; then
  if [[ -f package-lock.json ]]; then
    npm ci --include=dev || npm install --include=dev
  else
    npm install --include=dev
  fi
fi
./node_modules/.bin/tsc --version
npm run build
popd >/dev/null

systemctl restart newdomofon-video-dvr.service

echo
sleep 3
curl -fsS -m 5 -i http://127.0.0.1:3010/health | sed -n '1,25p' || true

echo
journalctl -u newdomofon-video-dvr --since "1 minute ago" --no-pager -l \
  | grep -E "legacy-fallback|inserted event|duplicate event|CreatePullPoint|poll failed|skipped streams" || true

echo
echo "ONVIF legacy insert logging applied. Backup: $BACKUP_DIR"
