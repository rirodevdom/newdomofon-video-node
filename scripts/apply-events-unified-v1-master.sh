#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="${PROJECT_DIR:-/opt/newdomofon-video}"
ENV_FILE="${ENV_FILE:-/etc/newdomofon-video/app.env}"
PUBLIC_EVENTS_SERVICE="${PUBLIC_EVENTS_SERVICE:-newdomofon-public-events.service}"
BACKEND_SERVICE="${BACKEND_SERVICE:-newdomofon-video-backend.service}"
BACKUP_DIR="$PROJECT_DIR/backups/events-unified-v1-master-$(date +%Y%m%d-%H%M%S)"

mkdir -p "$BACKUP_DIR"
cd "$PROJECT_DIR"

set -a
[ -f "$ENV_FILE" ] && . "$ENV_FILE"
[ -f "$PROJECT_DIR/backend/.env" ] && . "$PROJECT_DIR/backend/.env"
set +a

if [ -z "${DATABASE_URL:-}" ]; then
  echo "ERROR: DATABASE_URL is not set in $ENV_FILE or backend/.env" >&2
  exit 1
fi

cp -a public-events-proxy/server.js "$BACKUP_DIR/public-events-server.js.bak" 2>/dev/null || true
cp -a backend/src/routes/events.ts "$BACKUP_DIR/backend-events.ts.bak" 2>/dev/null || true
[ -f "$ENV_FILE" ] && cp -a "$ENV_FILE" "$BACKUP_DIR/app.env.bak" || true

cat > /tmp/newdomofon-events-schema.sql <<'SQL'
CREATE TABLE IF NOT EXISTS public.camera_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  camera_id uuid NOT NULL,
  stream_name text NOT NULL,
  event_type text NOT NULL DEFAULT 'event',
  event_state text NULL,
  topic text NULL,
  source_name text NULL,
  event_hash text NOT NULL,
  data jsonb NOT NULL DEFAULT '{}'::jsonb,
  occurred_at timestamptz NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.camera_events ADD COLUMN IF NOT EXISTS topic text;
ALTER TABLE public.camera_events ADD COLUMN IF NOT EXISTS source_name text;
ALTER TABLE public.camera_events ADD COLUMN IF NOT EXISTS data jsonb NOT NULL DEFAULT '{}'::jsonb;
ALTER TABLE public.camera_events ADD COLUMN IF NOT EXISTS created_at timestamptz NOT NULL DEFAULT now();
ALTER TABLE public.camera_events ADD COLUMN IF NOT EXISTS event_hash text;

UPDATE public.camera_events
   SET event_hash = md5(camera_id::text || '|' || stream_name || '|' || event_type || '|' || coalesce(event_state,'') || '|' || occurred_at::text || '|' || coalesce(data::text,''))
 WHERE event_hash IS NULL OR event_hash = '';

ALTER TABLE public.camera_events ALTER COLUMN event_hash SET NOT NULL;

CREATE UNIQUE INDEX IF NOT EXISTS camera_events_camera_hash_uq
  ON public.camera_events(camera_id, event_hash);

CREATE INDEX IF NOT EXISTS camera_events_camera_time_idx
  ON public.camera_events(camera_id, occurred_at DESC);

CREATE INDEX IF NOT EXISTS camera_events_stream_time_idx
  ON public.camera_events(stream_name, occurred_at DESC);

CREATE INDEX IF NOT EXISTS camera_events_type_time_idx
  ON public.camera_events(event_type, occurred_at DESC);
SQL

psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f /tmp/newdomofon-events-schema.sql

python3 - <<'PY'
from pathlib import Path
import re

p = Path('public-events-proxy/server.js')
s = p.read_text()

s = re.sub(r"const VERSION = '[^']+';", "const VERSION = 'v126-unified-events-camera-token';", s, count=1)

if "const crypto = require('crypto');" not in s:
    s = s.replace("const fs = require('fs');", "const fs = require('fs');\nconst crypto = require('crypto');", 1)

helper = r'''
function decodeCameraMediaToken(token) {
  try {
    const raw = String(token || '').trim();
    const parts = raw.split('.');
    if (parts.length !== 2 || !parts[0] || !parts[1]) return null;
    const payload = JSON.parse(Buffer.from(parts[0], 'base64url').toString('utf8'));
    if (!payload || typeof payload !== 'object') return null;
    if (!payload.camera_id || !payload.stream_name) return null;
    if (!['camera', 'live', 'archive', 'events'].includes(String(payload.scope || ''))) return null;
    if (payload.exp && Number(payload.exp) < Math.floor(Date.now() / 1000)) return null;
    return { payload, body: parts[0], sig: parts[1] };
  } catch (_) {
    return null;
  }
}

function safeEqualString(a, b) {
  const ab = Buffer.from(String(a || ''));
  const bb = Buffer.from(String(b || ''));
  return ab.length === bb.length && crypto.timingSafeEqual(ab, bb);
}

async function verifyCameraMediaToken(token, requestedCameraId, requestedStreamName) {
  const decoded = decodeCameraMediaToken(token);
  if (!decoded || !pool) return false;

  const payload = decoded.payload;
  const streamName = String(requestedStreamName || '').trim();
  const cameraId = String(requestedCameraId || '').trim();

  if (streamName && payload.stream_name && String(payload.stream_name) !== streamName) return false;

  const result = await pool.query(
    `SELECT c.id::text AS camera_id, c.stream_name, ds.media_secret
       FROM public.cameras c
       LEFT JOIN public.dvr_servers ds ON ds.id = c.dvr_server_id
      WHERE c.id::text = $1 OR c.stream_name = $2
      ORDER BY CASE WHEN c.id::text = $1 THEN 0 ELSE 1 END
      LIMIT 1`,
    [String(payload.camera_id || cameraId || ''), String(payload.stream_name || streamName || '')]
  );

  const row = result.rows[0];
  if (!row || !row.media_secret) return false;
  if (String(row.stream_name) !== String(payload.stream_name)) return false;
  if (String(row.camera_id) !== String(payload.camera_id)) return false;

  const expected = crypto.createHmac('sha256', row.media_secret).update(decoded.body).digest('base64url');
  return safeEqualString(decoded.sig, expected);
}
'''

if 'function decodeCameraMediaToken(' not in s:
    marker = 'function tokenRequired(tokens) {'
    if marker not in s:
        raise SystemExit('tokenRequired marker not found')
    s = s.replace(marker, helper + '\n' + marker, 1)

old = r'''    const tokens = acceptedTokens();
    const token = tokenFromRequest(url, req);
    if (tokenRequired(tokens) && !tokens.has(token)) {
      return sendJson(res, 401, {
        ok: false,
        error: 'Invalid public events token',
        version: VERSION,
        token_count: tokens.size,
      });
    }

    const { cameraId, streamName } = resolveRequestIdentity(url, matchPath ? matchPath[1] : '');
'''
new = r'''    const tokens = acceptedTokens();
    const token = tokenFromRequest(url, req);
    const { cameraId, streamName } = resolveRequestIdentity(url, matchPath ? matchPath[1] : '');
    const cameraTokenOk = token ? await verifyCameraMediaToken(token, cameraId, streamName) : false;
    const staticTokenOk = token ? tokens.has(token) : false;

    if (tokenRequired(tokens) && !staticTokenOk && !cameraTokenOk) {
      return sendJson(res, 401, {
        ok: false,
        error: 'Invalid public events token',
        version: VERSION,
        token_count: tokens.size,
        camera_token_checked: Boolean(token)
      });
    }

'''
if old in s:
    s = s.replace(old, new, 1)
elif 'const cameraTokenOk = token ? await verifyCameraMediaToken' not in s:
    raise SystemExit('public-events token block not found')

# Add a clearer shape for both master player and SmartYard player without removing old fields.
s = s.replace(
"""    return sendJson(res, 200, {
      ok: true,
      source: VERSION,
""",
"""    return sendJson(res, 200, {
      ok: true,
      source: VERSION,
      code: 200,
      name: 'Хорошо',
      message: 'Хорошо',
""",
1)

s = s.replace(
"""      items,
      events: items,
""",
"""      data: items,
      items,
      events: items,
""",
1)

p.write_text(s)
PY

node --check public-events-proxy/server.js

# Ensure public-events proxy has a service and the right env.
sudo tee /etc/systemd/system/${PUBLIC_EVENTS_SERVICE} >/dev/null <<EOF
[Unit]
Description=NewDomofon Public Events Proxy
After=network-online.target postgresql.service ${BACKEND_SERVICE}
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=${PROJECT_DIR}
EnvironmentFile=${ENV_FILE}
Environment=NODE_ENV=production
Environment=PUBLIC_EVENTS_PORT=3057
Environment=PUBLIC_EVENTS_REQUIRE_TOKEN=auto
Environment=PUBLIC_EVENTS_INCLUDE_PASSIVE=false
ExecStart=/usr/bin/node ${PROJECT_DIR}/public-events-proxy/server.js
Restart=always
RestartSec=3
User=root

[Install]
WantedBy=multi-user.target
EOF

sudo sed -i -E '/^(PUBLIC_EVENTS_REQUIRE_TOKEN|PUBLIC_EVENTS_INCLUDE_PASSIVE|PUBLIC_EVENTS_DEFAULT_LIMIT|PUBLIC_EVENTS_MAX_LIMIT)=/d' "$ENV_FILE" 2>/dev/null || true
cat <<'EOF' | sudo tee -a "$ENV_FILE" >/dev/null
PUBLIC_EVENTS_REQUIRE_TOKEN=auto
PUBLIC_EVENTS_INCLUDE_PASSIVE=false
PUBLIC_EVENTS_DEFAULT_LIMIT=20000
PUBLIC_EVENTS_MAX_LIMIT=50000
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now "$PUBLIC_EVENTS_SERVICE"
sudo systemctl restart "$PUBLIC_EVENTS_SERVICE"
sudo systemctl restart "$BACKEND_SERVICE" || true
sleep 2

echo "---- public events health ----"
curl -fsS http://127.0.0.1:3057/public-events/health || true
echo

echo "---- recent event counts ----"
psql "$DATABASE_URL" -P pager=off -c "
SELECT c.name, c.stream_name,
       count(e.*) FILTER (WHERE e.occurred_at > now() - interval '1 hour') AS last_hour,
       count(e.*) FILTER (WHERE e.occurred_at > now() - interval '24 hour') AS last_day,
       max(e.occurred_at) AS last_event
FROM cameras c
LEFT JOIN camera_events e ON e.camera_id = c.id
WHERE c.is_enabled = true
GROUP BY c.id, c.name, c.stream_name
ORDER BY last_event DESC NULLS LAST
LIMIT 30;
"

echo "OK: unified events master pipeline installed"
echo "backup_dir=$BACKUP_DIR"
