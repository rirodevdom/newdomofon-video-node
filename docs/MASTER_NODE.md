# Master / video node deployment

This project can run in two modes:

- **master**: backend, frontend, PostgreSQL, users, RBAC, camera groups, node registry, playback token issuing, audit, events.
- **video node**: DVR engine, FFmpeg recording, local archive storage, HLS/archive/export endpoints, heartbeat to master.

The master owns all management. A node connects to the master with an agent token, pulls only its assigned cameras, records them locally, and serves media with short-lived signed media tokens issued by the master.

## 1. Ports

Master:

- `3000/tcp` backend, usually only behind nginx `/api/`
- `80/443` nginx public entrypoint
- `5432/tcp` PostgreSQL local/private only

Node:

- `3010/tcp` DVR engine, normally behind nginx on `443`
- `80/443` nginx public media entrypoint
- no PostgreSQL access required in node mode

## 2. Master env

Start from:

```txt
deploy/env/master.env.example
```

Required production values:

```txt
DATABASE_URL=...
JWT_SECRET=...
ADMIN_PASSWORD=...
CORS_ORIGIN=https://video-master.example.com
NODE_REGISTRATION_TOKEN=...
INTERNAL_DVR_SECRET=...
```

Copy to:

```bash
sudo install -d -m 0750 /etc/newdomofon-video
sudo cp deploy/env/master.env.example /etc/newdomofon-video/app.env
sudo editor /etc/newdomofon-video/app.env
```

Install/build on master:

Create PostgreSQL role/database if they do not exist yet:

```bash
sudo -u postgres createuser newdomofon || true
sudo -u postgres createdb -O newdomofon newdomofon_video || true
sudo -u postgres psql -c "ALTER USER newdomofon WITH PASSWORD 'CHANGE_DB_PASSWORD';"
```

```bash
cd /opt/newdomofon-video/backend
npm ci --include=dev
npm run build
npm run migrate
npm run seed
npm prune --omit=dev

cd /opt/newdomofon-video/frontend
npm ci --include=dev
npm run build
sudo rsync -a dist/ /var/www/newdomofon-video/
```

Install services:

```bash
sudo cp deploy/systemd/newdomofon-video-backend.service /etc/systemd/system/
sudo cp deploy/nginx/newdomofon-video.conf /etc/nginx/sites-available/newdomofon-video.conf
sudo ln -sf /etc/nginx/sites-available/newdomofon-video.conf /etc/nginx/sites-enabled/newdomofon-video.conf
sudo systemctl daemon-reload
sudo systemctl enable --now newdomofon-video-backend
sudo nginx -t && sudo systemctl reload nginx
```

## 3. Create a node on master

Option A: admin UI.

Open `Admin -> Video nodes`, enter:

- node name
- public base URL, for example `https://video-node-1.example.com`
- internal URL, for example `http://10.0.10.11:3010` or empty

After creation the UI shows `DVR_NODE_ID`, `DVR_NODE_TOKEN`, `DVR_NODE_MEDIA_SECRET`. Save them immediately; the token is not shown again.

Option B: node self-registration.

On the node:

```bash
curl -fsS -X POST https://video-master.example.com/api/node-agent/register \
  -H 'content-type: application/json' \
  -d '{
    "registration_token": "CHANGE_TO_RANDOM_NODE_REGISTRATION_TOKEN",
    "name": "Node 1",
    "public_base_url": "https://video-node-1.example.com",
    "internal_url": "http://127.0.0.1:3010",
    "capabilities": { "hls": true, "archive": true, "export": true }
  }'
```

The response contains:

```json
{
  "node_id": "...",
  "agent_token": "...",
  "media_secret": "..."
}
```

## 4. Node env

Start from:

```txt
deploy/env/node.env.example
```

Copy to the node:

```bash
sudo install -d -m 0750 /etc/newdomofon-video
sudo cp deploy/env/node.env.example /etc/newdomofon-video/app.env
sudo editor /etc/newdomofon-video/app.env
```

Required values:

```txt
DVR_MASTER_URL=https://video-master.example.com
DVR_NODE_ID=...
DVR_NODE_TOKEN=...
DVR_NODE_PUBLIC_BASE_URL=https://video-node-1.example.com
DVR_REQUIRE_MEDIA_TOKEN=true
BACKEND_INTERNAL_URL=https://video-master.example.com
INTERNAL_DVR_SECRET=...
```

Install/build on node:

```bash
cd /opt/newdomofon-video/dvr-engine
npm ci --include=dev
npm run build
npm prune --omit=dev
```

Install service:

```bash
sudo install -d -o newdomofon -g newdomofon /var/lib/newdomofon-video/dvr /var/log/newdomofon-video
sudo cp deploy/systemd/newdomofon-video-dvr.service /etc/systemd/system/
sudo cp deploy/nginx/newdomofon-video-node.conf /etc/nginx/sites-available/newdomofon-video-node.conf
sudo ln -sf /etc/nginx/sites-available/newdomofon-video-node.conf /etc/nginx/sites-enabled/newdomofon-video-node.conf
sudo systemctl daemon-reload
sudo systemctl enable --now newdomofon-video-dvr
sudo nginx -t && sudo systemctl reload nginx
```

Healthcheck:

```bash
curl -fsS http://127.0.0.1:3010/health
```

Expected:

```json
{
  "ok": true,
  "service": "dvr-engine",
  "mode": "node",
  "node_id": "..."
}
```

## 5. Assign cameras

In the admin UI create or edit a camera and select `Video node`.

Or call:

```bash
curl -fsS -X POST https://video-master.example.com/api/dvr-servers/NODE_ID/assign-cameras \
  -H "authorization: Bearer ADMIN_JWT" \
  -H "content-type: application/json" \
  -d '{"camera_ids":["CAMERA_UUID"]}'
```

The master increments node config generation and enqueues a `reload_cameras` command. The node polls commands and reloads assigned cameras.

## 6. Playback flow

When a user opens a camera:

1. frontend calls `/api/player/:cameraId/live`;
2. master checks RBAC with `canAccessCamera`;
3. master finds the camera node via `cameras.dvr_server_id`;
4. master signs a short-lived media token with the node media secret;
5. master returns a URL like:

```txt
https://video-node-1.example.com/cameras/cam_1/live.m3u8?token=...
```

The node validates the token for:

- stream name;
- scope: `live`, `archive`, `export`, `file`;
- expiration time;
- HMAC signature.

Playlist segment URLs are automatically rewritten to keep the token on segment requests.

## 7. Events

Nodes post ONVIF events back to master through:

```txt
POST /api/internal/events/onvif
```

The request includes:

```txt
X-Internal-Secret: INTERNAL_DVR_SECRET
X-Node-ID: DVR_NODE_ID
```

The master stores events centrally in `camera_events`.

## 8. Fallback standalone mode

If `DVR_MASTER_URL`, `DVR_NODE_ID`, and `DVR_NODE_TOKEN` are empty, `dvr-engine` stays in old standalone mode and reads cameras from PostgreSQL directly.

This is useful for single-server installs and local development.

## 9. Security checklist

- Do not expose PostgreSQL on public interfaces.
- Keep `DVR_NODE_TOKEN`, `DVR_NODE_MEDIA_SECRET`, `INTERNAL_DVR_SECRET`, and `JWT_SECRET` out of git and archives.
- Use HTTPS for master and node public URLs.
- Keep `DVR_REQUIRE_MEDIA_TOKEN=true` on every public node.
- Rotate node token from `Admin -> Video nodes` if a node server or env file is leaked.
- Remove old global `RESTREAM_PUBLIC_TOKEN` use from frontend deployments.
