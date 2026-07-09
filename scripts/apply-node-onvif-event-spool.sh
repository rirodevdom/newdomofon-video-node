#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="${PROJECT_DIR:-/opt/newdomofon-video}"
TARGET="$PROJECT_DIR/dvr-engine/src/onvifEventsLegacyFallback.ts"
ENV_FILE="${ENV_FILE:-/etc/newdomofon-video/app.env}"
SERVICE="${SERVICE:-newdomofon-video-dvr.service}"
BACKUP_DIR="$PROJECT_DIR/backups/node-onvif-event-spool-$(date +%Y%m%d-%H%M%S)"

mkdir -p "$BACKUP_DIR"
cp -a "$TARGET" "$BACKUP_DIR/onvifEventsLegacyFallback.ts.bak"
[ -f "$ENV_FILE" ] && cp -a "$ENV_FILE" "$BACKUP_DIR/app.env.bak" || true

cd "$PROJECT_DIR"

python3 - <<'PY'
from pathlib import Path
import re

p = Path('dvr-engine/src/onvifEventsLegacyFallback.ts')
s = p.read_text()

if "import fs from 'node:fs/promises';" not in s:
    s = s.replace("import crypto from 'node:crypto';", "import crypto from 'node:crypto';\nimport fs from 'node:fs/promises';", 1)

if "eventSpoolFile" not in s:
    s = s.replace(
"    quietLogMs: Math.max(Number(process.env.ONVIF_LEGACY_QUIET_LOG_MS || 120_000), 30_000)\n",
"    quietLogMs: Math.max(Number(process.env.ONVIF_LEGACY_QUIET_LOG_MS || 120_000), 30_000),\n    eventSpoolFile: process.env.ONVIF_EVENT_SPOOL_FILE || '/var/lib/newdomofon-video/onvif-event-spool.jsonl'\n",
1)

helpers = r'''
async function postEventDirect(payload: any) {
  const config = cfg();
  const response = await fetch(
    `${config.backendUrl}/api/internal/events/onvif`,
    {
      method: 'POST',
      headers: {
        'content-type': 'application/json',
        'x-internal-secret': config.secret,
        'x-node-id': dvrConfig.nodeId
      },
      body: JSON.stringify(payload)
    }
  );
  if (!response.ok) {
    throw new Error(
      `Backend POST event HTTP ${response.status}: ${(await response.text()).slice(0, 200)}`
    );
  }
}

async function appendEventSpool(payload: any, reason: unknown) {
  const config = cfg();
  try {
    await fs.mkdir(config.eventSpoolFile.replace(/\/[^/]+$/, ''), { recursive: true });
    await fs.appendFile(config.eventSpoolFile, JSON.stringify({
      queued_at: new Date().toISOString(),
      reason: reason instanceof Error ? reason.message : String(reason),
      payload
    }) + '\n');
    console.warn('[onvif-events:legacy-fallback] queued event locally', {
      stream_name: payload.stream_name,
      event_type: payload.event_type,
      event_state: payload.event_state,
      file: config.eventSpoolFile
    });
  } catch (spoolError) {
    console.error('[onvif-events:legacy-fallback] failed to queue event locally', spoolError instanceof Error ? spoolError.message : spoolError);
  }
}

async function syncEventSpool() {
  const config = cfg();
  let raw = '';
  try {
    raw = await fs.readFile(config.eventSpoolFile, 'utf8');
  } catch {
    return;
  }

  const lines = raw.split(/\r?\n/).filter(Boolean);
  if (!lines.length) return;

  const keep: string[] = [];
  let synced = 0;
  for (const line of lines) {
    try {
      const item = JSON.parse(line);
      if (!item || !item.payload) continue;
      await postEventDirect(item.payload);
      synced += 1;
    } catch {
      keep.push(line);
    }
  }

  if (keep.length) {
    await fs.writeFile(config.eventSpoolFile, keep.join('\n') + '\n');
  } else {
    await fs.unlink(config.eventSpoolFile).catch(() => undefined);
  }

  if (synced) {
    console.log('[onvif-events:legacy-fallback] synced queued events', {
      synced,
      remaining: keep.length,
      file: config.eventSpoolFile
    });
  }
}
'''

if 'async function postEventDirect' not in s:
    s = s.replace('async function postEvent(payload: any) {', helpers + '\nasync function postEvent(payload: any) {', 1)

post_pattern = re.compile(r"async function postEvent\(payload: any\) \{.*?\n\}", re.S)
post_new = r'''async function postEvent(payload: any) {
  try {
    await postEventDirect(payload);
    await syncEventSpool();
  } catch (error) {
    await appendEventSpool(payload, error);
    throw error;
  }
}'''
s2, n = post_pattern.subn(post_new, s, count=1)
if n != 1:
    raise SystemExit('postEvent function not found')
s = s2

# Try to sync old queued events during every sync cycle, even when no new events arrive.
if "await syncEventSpool();" in s and "void syncEventSpool().catch" not in s:
    s = s.replace("async function sync() {\n  const config = cfg();", "async function sync() {\n  void syncEventSpool().catch(() => undefined);\n  const config = cfg();", 1)

p.write_text(s)
PY

sudo sed -i -E '/^ONVIF_EVENT_SPOOL_FILE=/d' "$ENV_FILE" 2>/dev/null || true
echo 'ONVIF_EVENT_SPOOL_FILE=/var/lib/newdomofon-video/onvif-event-spool.jsonl' | sudo tee -a "$ENV_FILE" >/dev/null

cd "$PROJECT_DIR/dvr-engine"
npm install --include=dev
npm run build
sudo systemctl restart "$SERVICE"
sleep 4

echo "---- spool file ----"
ls -lah /var/lib/newdomofon-video/onvif-event-spool.jsonl 2>/dev/null || true

echo "---- recent logs ----"
sudo journalctl -u "$SERVICE" --since "2 minutes ago" --no-pager -l | grep -E 'onvif-events:legacy-fallback|queued event locally|synced queued events|stored event|store failed|ready' || true

echo "OK: ONVIF legacy events are spooled locally when master is unavailable"
echo "backup_dir=$BACKUP_DIR"
