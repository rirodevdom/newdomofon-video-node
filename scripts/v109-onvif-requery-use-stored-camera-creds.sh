#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="${PROJECT_DIR:-/opt/newdomofon-video}"
BACKEND_DIR="$PROJECT_DIR/backend"
FRONTEND_DIR="$PROJECT_DIR/frontend"
TS_ONVIF="$BACKEND_DIR/src/routes/onvif.ts"
VUE_CAMERAS="$FRONTEND_DIR/src/views/CamerasView.vue"
BACKUP_DIR="$PROJECT_DIR/backups/v109-onvif-requery-use-stored-camera-creds-$(date +%Y%m%d-%H%M%S)"

log(){ printf '\n===== %s =====\n' "$*"; }
backup(){ local f="$1"; if [ -f "$f" ]; then mkdir -p "$BACKUP_DIR$(dirname "$f")"; cp -a "$f" "$BACKUP_DIR$f"; echo "backup: $f"; fi; }

log "Validate paths"
[ -f "$TS_ONVIF" ] || { echo "missing: $TS_ONVIF" >&2; exit 1; }
[ -f "$VUE_CAMERAS" ] || { echo "missing: $VUE_CAMERAS" >&2; exit 1; }
mkdir -p "$BACKUP_DIR"

log "Backup"
backup "$TS_ONVIF"
backup "$VUE_CAMERAS"
[ -f "$BACKEND_DIR/dist/routes/onvif.js" ] && backup "$BACKEND_DIR/dist/routes/onvif.js"

log "Patch backend /onvif/stream-uri to use stored camera credentials on requery"
cat > "$TS_ONVIF" <<'TS'
import { Router } from 'express';
import { z } from 'zod';
import { query } from '../db.js';
import { requireAuth, requireRole } from '../middleware/auth.js';
import { asyncHandler } from '../utils/asyncHandler.js';

export const onvifRouter = Router();
onvifRouter.use(requireAuth, requireRole('super_admin', 'operator'));

const connectSchema = z.object({
  ip: z.string().min(1),
  port: z.coerce.number().int().min(1).max(65535).default(80),
  username: z.string().optional(),
  password: z.string().optional()
});

const streamUriSchema = z.object({
  camera_id: z.string().uuid().optional(),
  cameraId: z.string().uuid().optional(),
  id: z.string().uuid().optional(),
  ip: z.string().optional(),
  host: z.string().optional(),
  xaddr: z.string().optional(),
  port: z.coerce.number().int().min(1).max(65535).optional(),
  username: z.string().optional(),
  password: z.string().optional()
});

type ConnectBody = z.infer<typeof connectSchema>;

function dvrBaseUrl() {
  return process.env.DVR_ENGINE_URL || process.env.DVR_URL || 'http://127.0.0.1:3010';
}

function cleanHostFromXaddr(input: string | null | undefined) {
  return String(input || '')
    .trim()
    .replace(/^https?:\/\//i, '')
    .replace(/\/onvif\/device_service.*$/i, '')
    .replace(/:\d+$/i, '')
    .replace(/\/+$/g, '');
}

function parseRtspCredentials(sourceUrl: string | null | undefined) {
  if (!sourceUrl) return { username: '', password: '' };

  try {
    const url = new URL(sourceUrl);
    if (url.protocol !== 'rtsp:') return { username: '', password: '' };

    return {
      username: url.username ? decodeURIComponent(url.username) : '',
      password: url.password ? decodeURIComponent(url.password) : ''
    };
  } catch {
    return { username: '', password: '' };
  }
}

async function cameraStoredConnectBody(cameraId: string): Promise<ConnectBody> {
  const result = await query(
    `SELECT id, source_url, onvif_xaddr, onvif_port, onvif_username, onvif_password
       FROM public.cameras
      WHERE id = $1`,
    [cameraId]
  );

  if (!result.rowCount) {
    throw new Error('Camera not found');
  }

  const camera = result.rows[0] as any;
  const rtspCreds = parseRtspCredentials(camera.source_url);
  const ip = cleanHostFromXaddr(camera.onvif_xaddr);

  if (!ip) {
    throw new Error('Camera has no ONVIF address saved');
  }

  const username = camera.onvif_username || rtspCreds.username || '';
  const password = camera.onvif_password || rtspCreds.password || '';

  if (!username || !password) {
    throw new Error('Camera ONVIF credentials are not saved. Re-enter camera credentials once and save the camera.');
  }

  return {
    ip,
    port: Number(camera.onvif_port || 80),
    username,
    password
  };
}

async function connectViaDvr(body: ConnectBody) {
  const response = await fetch(`${dvrBaseUrl().replace(/\/+$/, '')}/onvif/connect`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify(body)
  });

  const text = await response.text();
  let payload: any;
  try { payload = text ? JSON.parse(text) : {}; } catch { payload = { error: text }; }

  if (!response.ok) throw new Error(payload?.error || `DVR ONVIF failed with HTTP ${response.status}`);
  return payload;
}

onvifRouter.post('/connect', asyncHandler(async (req, res) => {
  // Initial/manual ONVIF connect: credentials are intentionally taken from the submitted camera form.
  const body = connectSchema.parse(req.body || {});
  res.json(await connectViaDvr(body));
}));

onvifRouter.post('/stream-uri', asyncHandler(async (req, res) => {
  const raw = streamUriSchema.parse(req.body || {});
  const cameraId = raw.camera_id || raw.cameraId || raw.id;

  // Existing camera RTSP requery: never trust username/password coming from the browser.
  // Password managers can autofill the current web-account password into the camera password field.
  // The backend must use only credentials already stored for this camera.
  if (cameraId) {
    const body = await cameraStoredConnectBody(cameraId);
    return res.json(await connectViaDvr(body));
  }

  // Backward-compatible manual mode for new cameras or explicit tests.
  const body = connectSchema.parse({
    ip: raw.ip || raw.host || cleanHostFromXaddr(raw.xaddr),
    port: raw.port || 80,
    username: raw.username,
    password: raw.password
  });

  res.json(await connectViaDvr(body));
}));
TS

log "Patch frontend requery button to send camera_id only"
python3 - <<'PY' "$VUE_CAMERAS"
from pathlib import Path
import sys
p = Path(sys.argv[1])
s = p.read_text()
old = """async function connectOnvif() {
  connecting.value = true;
  try {
    const { data } = await api.post('/onvif/connect', {
      ip: form.onvif_ip,
      port: Number(form.onvif_port || 80),
      username: form.username || undefined,
      password: form.password || undefined
    });

    form.onvif_ip = data.ip || form.onvif_ip;
"""
new = """async function connectOnvif() {
  connecting.value = true;
  try {
    const isExistingOnvifRequery = Boolean(editingId.value && originalProtocol.value === 'ONVIF');
    const endpoint = isExistingOnvifRequery ? '/onvif/stream-uri' : '/onvif/connect';
    const requestBody = isExistingOnvifRequery
      ? { camera_id: editingId.value }
      : {
          ip: form.onvif_ip,
          port: Number(form.onvif_port || 80),
          username: form.username || undefined,
          password: form.password || undefined
        };

    const { data } = await api.post(endpoint, requestBody);

    form.onvif_ip = data.ip || form.onvif_ip;
"""
if old not in s:
    raise SystemExit('connectOnvif block not found; aborting safe patch')
s = s.replace(old, new, 1)

s = s.replace(
"""              <v-text-field
                v-model=\"form.username\"
                label=\"Имя пользователя\"
                density=\"compact\"
                :disabled=\"form.protocol === 'ONVIF' && Boolean(editingId)\"
              />""",
"""              <v-text-field
                v-model=\"form.username\"
                label=\"Имя пользователя\"
                density=\"compact\"
                name=\"camera-onvif-username\"
                autocomplete=\"off\"
                :disabled=\"form.protocol === 'ONVIF' && Boolean(editingId)\"
              />""",
1)

s = s.replace(
"""              <v-text-field v-model=\"form.password\" label=\"Пароль\" type=\"password\" density=\"compact\" />""",
"""              <v-text-field
                v-model=\"form.password\"
                label=\"Пароль камеры\"
                type=\"password\"
                density=\"compact\"
                name=\"camera-onvif-password\"
                autocomplete=\"new-password\"
                :disabled=\"form.protocol === 'ONVIF' && Boolean(editingId)\"
              />""",
1)

p.write_text(s)
PY

log "Optional one-time credentials repair"
cat <<'INFO'
This patch fixes future requery calls.
If the camera row already contains wrong credentials inside source_url/onvif_password,
run this separately after the patch with real camera credentials:

  sudo PROJECT_DIR=/opt/newdomofon-video \
    FIX_CAMERA_CREDS=1 \
    STREAM_NAME='cam_10_130_1_219' \
    CAMERA_USERNAME='admin' \
    CAMERA_PASSWORD='<camera password>' \
    bash scripts/v109-onvif-requery-use-stored-camera-creds.sh
INFO

if [ "${FIX_CAMERA_CREDS:-0}" = "1" ]; then
  log "Apply one-time camera credentials repair"
  if [ -f /etc/newdomofon-video/app.env ]; then set -a; . /etc/newdomofon-video/app.env; set +a; fi
  if [ -f "$BACKEND_DIR/.env" ]; then set -a; . "$BACKEND_DIR/.env"; set +a; fi
  export NODE_PATH="$BACKEND_DIR/node_modules"
  node <<'NODE'
const { Client } = require('pg');

const databaseUrl = process.env.DATABASE_URL;
const streamName = process.env.STREAM_NAME || '';
const cameraId = process.env.CAMERA_ID || '';
const username = process.env.CAMERA_USERNAME || '';
const password = process.env.CAMERA_PASSWORD || '';

if (!databaseUrl) throw new Error('DATABASE_URL is not set');
if (!streamName && !cameraId) throw new Error('Set STREAM_NAME or CAMERA_ID');
if (!username || !password) throw new Error('Set CAMERA_USERNAME and CAMERA_PASSWORD');

(async () => {
  const client = new Client({ connectionString: databaseUrl });
  await client.connect();
  const result = await client.query(
    `SELECT id, stream_name, source_url FROM public.cameras WHERE ${cameraId ? 'id = $1' : 'stream_name = $1'} LIMIT 1`,
    [cameraId || streamName]
  );
  if (!result.rowCount) throw new Error('Camera not found');
  const row = result.rows[0];

  let sourceUrl = row.source_url;
  try {
    const parsed = new URL(row.source_url);
    if (parsed.protocol === 'rtsp:') {
      parsed.username = username;
      parsed.password = password;
      sourceUrl = parsed.toString();
    }
  } catch (_) {}

  await client.query(
    `UPDATE public.cameras
        SET onvif_username = $2,
            onvif_password = $3,
            source_url = $4
      WHERE id = $1`,
    [row.id, username, password, sourceUrl]
  );
  await client.end();
  console.log(`updated camera credentials for ${row.stream_name} (${row.id}); source_url userinfo repaired if RTSP`);
})().catch(async (err) => {
  console.error(err.message || err);
  process.exit(1);
});
NODE
fi

log "Build checks"
if [ -f "$BACKEND_DIR/package.json" ]; then
  (cd "$BACKEND_DIR" && npm run build)
fi
if [ "${BUILD_FRONTEND:-1}" = "1" ] && [ -f "$FRONTEND_DIR/package.json" ]; then
  (cd "$FRONTEND_DIR" && npm run build)
else
  echo "frontend build skipped; set BUILD_FRONTEND=1 to force"
fi

log "Done"
cat <<EOF
installed: v109-onvif-requery-use-stored-camera-creds
backup:    $BACKUP_DIR

What changed:
  - existing ONVIF camera requery now calls /onvif/stream-uri with camera_id only;
  - backend loads saved credentials from cameras table/source_url;
  - browser-submitted username/password are ignored for existing camera requery;
  - ONVIF password field is disabled on existing ONVIF camera edit to avoid browser autofill.

Restart backend/frontend services if they are not auto-deployed by your build pipeline.
EOF
