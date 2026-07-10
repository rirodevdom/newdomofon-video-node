#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="${PROJECT_DIR:-/opt/newdomofon-video-node}"
BACKUP_DIR="$PROJECT_DIR/backups/single-smartyard-link-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BACKUP_DIR"

cd "$PROJECT_DIR"

cp -a backend/src/services/nodeMediaToken.ts "$BACKUP_DIR/nodeMediaToken.ts.bak"
cp -a backend/src/routes/tokens.ts "$BACKUP_DIR/tokens.ts.bak"
cp -a frontend/src/views/AdminView.vue "$BACKUP_DIR/AdminView.vue.bak"
cp -a smartyard-compat-proxy/server.js "$BACKUP_DIR/smartyard-compat-server.js.bak"

python3 - <<'PY'
from pathlib import Path
import re

# 1) Backend token type: add camera-wide media scope.
p = Path('backend/src/services/nodeMediaToken.ts')
s = p.read_text()
s = s.replace("export type NodeMediaScope = 'live' | 'archive' | 'export' | 'file' | 'status';", "export type NodeMediaScope = 'camera' | 'live' | 'archive' | 'export' | 'file' | 'status';")
p.write_text(s)

# 2) Backend camera-links route: generate one camera_token/smartyard_url in addition to technical links.
p = Path('backend/src/routes/tokens.ts')
s = p.read_text()
old = """  const live = nodeCameraUrl(camera, authReq.user.id, 'live', 'live.m3u8', ttlSeconds);
  const archive = nodeCameraUrl(camera, authReq.user.id, 'archive', archivePath, ttlSeconds, startEndHint);

  if (live && archive) {
    return res.json({
      camera: { id: camera.id, name: camera.name, stream_name: camera.stream_name },
      mode: 'node-direct',
      ttl_seconds: NEWD_PERMANENT_MEDIA_EXP,
      expires_at: expiresAt.toISOString(),
      live_url: live.url,
      archive_url_template: readableTemplate(archive.url),
      live_token: live.token,
      archive_token: archive.token,
      archive_source: archivePath === 'device-archive.m3u8' ? 'device' : 'node',
      permanent: true, note: 'Node media links are signed for this camera and expire automatically.'
    });
  }
"""
new = """  const live = nodeCameraUrl(camera, authReq.user.id, 'live', 'live.m3u8', ttlSeconds);
  const archive = nodeCameraUrl(camera, authReq.user.id, 'archive', archivePath, ttlSeconds, startEndHint);
  const cameraWideLive = nodeCameraUrl(camera, authReq.user.id, 'camera', 'live.m3u8', ttlSeconds);
  const cameraWideArchive = nodeCameraUrl(camera, authReq.user.id, 'camera', archivePath, ttlSeconds, startEndHint);

  if (live && archive) {
    const singleToken = cameraWideLive?.token || live.token;
    const singleUrl = cameraWideLive?.url || live.url;
    const singleArchiveTemplate = readableTemplate(cameraWideArchive?.url || archive.url);
    const base = camera.node_public_base_url ? camera.node_public_base_url.replace(/\/+$/, '') : '';
    const compatSmartYardUrl = base && singleToken
      ? `${base}/${encodeURIComponent(camera.id)}/index.m3u8?token=${encodeURIComponent(singleToken)}`
      : singleUrl;

    return res.json({
      camera: { id: camera.id, name: camera.name, stream_name: camera.stream_name },
      mode: cameraWideLive ? 'single-camera' : 'node-direct',
      link_mode: cameraWideLive ? 'single-camera' : 'node-direct',
      ttl_seconds: NEWD_PERMANENT_MEDIA_EXP,
      expires_at: expiresAt.toISOString(),
      primary_url: compatSmartYardUrl,
      camera_url: singleUrl,
      smartyard_url: compatSmartYardUrl,
      single_url: singleUrl,
      single_archive_url_template: singleArchiveTemplate,
      camera_token: cameraWideLive?.token || null,
      single_token: singleToken,
      live_url: singleUrl,
      archive_url_template: singleArchiveTemplate,
      live_token: singleToken,
      archive_token: singleToken,
      technical_live_url: live.url,
      technical_archive_url_template: readableTemplate(archive.url),
      technical_live_token: live.token,
      technical_archive_token: archive.token,
      archive_source: archivePath === 'device-archive.m3u8' ? 'device' : 'node',
      permanent: true,
      note: cameraWideLive
        ? 'Use smartyard_url as the single SmartYard link. The same camera_token is valid for live, archive and media segments.'
        : 'Node media links are signed for this camera and expire automatically.'
    });
  }
"""
if old not in s:
    raise SystemExit('tokens.ts: expected node-direct response block not found')
s = s.replace(old, new)
p.write_text(s)

# 3) Frontend: show one SmartYard URL as primary, technical URLs collapsed below as plain fields.
p = Path('frontend/src/views/AdminView.vue')
s = p.read_text()
old = """                    <v-textarea :model-value=\"generatedCameraLinks[camera.id].live_url\" label=\"Live HLS URL\" rows=\"2\" readonly density=\"compact\" />
                    <v-textarea :model-value=\"generatedCameraLinks[camera.id].archive_url_template\" label=\"Archive HLS URL template\" rows=\"2\" readonly density=\"compact\" />
                    <div class=\"d-flex flex-wrap\" style=\"gap: 8px\">
                      <v-btn size=\"small\" variant=\"tonal\" @click=\"copyText(generatedCameraLinks[camera.id].live_url)\">Копировать live</v-btn>
                      <v-btn size=\"small\" variant=\"tonal\" @click=\"copyText(generatedCameraLinks[camera.id].archive_url_template)\">Копировать archive</v-btn>
                      <v-btn size=\"small\" variant=\"tonal\" @click=\"copyText(generatedCameraLinks[camera.id].live_token)\">Копировать live token</v-btn>
                      <v-btn size=\"small\" variant=\"tonal\" @click=\"copyText(generatedCameraLinks[camera.id].archive_token)\">Копировать archive token</v-btn>
                    </div>
"""
new = """                    <v-alert type=\"success\" variant=\"tonal\" density=\"compact\" class=\"mb-2\">
                      Для SmartYard используйте одну ссылку ниже. Один camera token подходит для live, archive и .ts сегментов.
                    </v-alert>
                    <v-textarea :model-value=\"generatedCameraLinks[camera.id].smartyard_url || generatedCameraLinks[camera.id].primary_url || generatedCameraLinks[camera.id].single_url || generatedCameraLinks[camera.id].live_url\" label=\"Единая SmartYard URL\" rows=\"2\" readonly density=\"compact\" />
                    <v-textarea :model-value=\"generatedCameraLinks[camera.id].camera_token || generatedCameraLinks[camera.id].single_token || generatedCameraLinks[camera.id].live_token\" label=\"Единый camera token\" rows=\"2\" readonly density=\"compact\" />
                    <v-textarea :model-value=\"generatedCameraLinks[camera.id].single_archive_url_template || generatedCameraLinks[camera.id].archive_url_template\" label=\"Технический archive template с тем же token\" rows=\"2\" readonly density=\"compact\" />
                    <div class=\"d-flex flex-wrap\" style=\"gap: 8px\">
                      <v-btn size=\"small\" color=\"primary\" variant=\"tonal\" @click=\"copyText(generatedCameraLinks[camera.id].smartyard_url || generatedCameraLinks[camera.id].primary_url || generatedCameraLinks[camera.id].single_url || generatedCameraLinks[camera.id].live_url)\">Копировать SmartYard URL</v-btn>
                      <v-btn size=\"small\" variant=\"tonal\" @click=\"copyText(generatedCameraLinks[camera.id].camera_token || generatedCameraLinks[camera.id].single_token || generatedCameraLinks[camera.id].live_token)\">Копировать camera token</v-btn>
                      <v-btn size=\"small\" variant=\"tonal\" @click=\"copyText(generatedCameraLinks[camera.id].single_archive_url_template || generatedCameraLinks[camera.id].archive_url_template)\">Копировать archive template</v-btn>
                    </div>
"""
if old not in s:
    raise SystemExit('AdminView.vue: expected camera link textarea block not found')
s = s.replace(old, new)
p.write_text(s)

# 4) SmartYard compat proxy: pass token to DVR node and optionally defer camera token auth to node.
p = Path('smartyard-compat-proxy/server.js')
s = p.read_text()

if 'function __ndDecodeCameraTokenPayload' not in s:
    marker = "/* END newdomofon-accept-permanent-camera-token */"
    insert = r'''
function __ndDecodeCameraTokenPayload(token) {
  try {
    const raw = String(token || '').trim();
    const parts = raw.split('.');
    const payloadPart = parts.length === 3 ? parts[1] : parts[0];
    if (!payloadPart) return null;
    const payload = JSON.parse(Buffer.from(payloadPart, 'base64url').toString('utf8'));
    if (!payload || typeof payload !== 'object') return null;
    if (String(payload.scope || '') !== 'camera') return null;
    if (!payload.stream_name) return null;
    if (payload.exp && Number(payload.exp) < Math.floor(Date.now() / 1000)) return null;
    return payload;
  } catch {
    return null;
  }
}

function __ndAllowDeferCameraTokenToDvr(token, stream) {
  if (!['1', 'true', 'yes', 'on'].includes(String(process.env.SMARTYARD_COMPAT_DEFER_CAMERA_TOKEN_AUTH_TO_DVR || '').toLowerCase())) return false;
  const payload = __ndDecodeCameraTokenPayload(token);
  return Boolean(payload && String(payload.stream_name || '') === String(stream || ''));
}
'''
    s = s.replace(marker, insert + '\n' + marker)

s = s.replace(
"""function isAcceptedToken(token) {
  if (__ndAcceptPermanentCameraToken(token)) return true;
  return acceptedTokens().includes(String(token || ''));
}
""",
"""function isAcceptedToken(token, stream = '') {
  if (__ndAcceptPermanentCameraToken(token)) return true;
  if (__ndAllowDeferCameraTokenToDvr(token, stream)) return true;
  return acceptedTokens().includes(String(token || ''));
}
"""
)

if 'function upstreamPathWithToken' not in s:
    s = s.replace(
"""async function fetchUpstream(pathname, timeoutMs = 5000) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    return await fetch(`${DVR_ENGINE_URL}${pathname}`, {
""",
"""function upstreamPathWithToken(pathname, token) {
  if (!token) return pathname;
  try {
    const parsed = new URL(String(pathname), 'http://newdomofon.local');
    parsed.searchParams.set('token', token);
    return `${parsed.pathname}${parsed.search}`;
  } catch {
    const sep = String(pathname).includes('?') ? '&' : '?';
    return `${pathname}${sep}token=${encodeURIComponent(token)}`;
  }
}

async function fetchUpstream(pathname, timeoutMs = 5000, token = '') {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  const upstreamPath = upstreamPathWithToken(pathname, token);
  try {
    return await fetch(`${DVR_ENGINE_URL}${upstreamPath}`, {
"""
    )

s = s.replace(
"""  const upstream = await fetchUpstream(`/cameras/${encodeURIComponent(stream)}/live.m3u8`, 5000);
""",
"""  const upstream = await fetchUpstream(`/cameras/${encodeURIComponent(stream)}/live.m3u8`, 5000, tokenToUse);
"""
)

old = """  if (!segments.length) {
    sendJson(res, 404, {
      error: 'No archive segments in selected range',
      stream_name: stream,
      start: new Date(win.startMs).toISOString(),
      end: new Date(win.endMs).toISOString(),
      source: win.source
    }, { 'x-newdomofon-resolved-stream': stream });
    return;
  }
"""
new = """  if (!segments.length) {
    const tokenToUse = tokenForPlaylist(token);
    const startIso = new Date(win.startMs).toISOString();
    const endIso = new Date(win.endMs).toISOString();
    const upstreamPath = `/cameras/${encodeURIComponent(stream)}/archive.m3u8?start=${encodeURIComponent(startIso)}&end=${encodeURIComponent(endIso)}`;
    const upstream = await fetchUpstream(upstreamPath, 10000, tokenToUse);
    const upstreamBody = await upstream.text();
    if (upstream.ok) {
      sendText(res, upstream.status, upstreamBody, upstream.headers.get('content-type') || 'application/vnd.apple.mpegurl; charset=utf-8', {
        'x-newdomofon-resolved-stream': stream,
        'x-newdomofon-archive-window-source': `dvr-engine-${win.source}`
      });
      return;
    }

    sendJson(res, 404, {
      error: 'No archive segments in selected range',
      stream_name: stream,
      start: startIso,
      end: endIso,
      source: win.source,
      upstream_status: upstream.status,
      upstream_error: upstreamBody.slice(0, 500)
    }, { 'x-newdomofon-resolved-stream': stream });
    return;
  }
"""
if old not in s:
    raise SystemExit('smartyard compat: archive no-segments block not found')
s = s.replace(old, new)

s = s.replace('if (!isAcceptedToken(actualToken)) {', 'if (!isAcceptedToken(actualToken, stream)) {')
p.write_text(s)
PY

# 5) Enable single-link behavior on master.
sudo sed -i -E '/^(SINGLE_CAMERA_LINKS|SMARTYARD_SINGLE_CAMERA_LINKS|SMARTYARD_COMPAT_DEFER_CAMERA_TOKEN_AUTH_TO_DVR)=/d' /etc/newdomofon-video/app.env
cat <<'EOF' | sudo tee -a /etc/newdomofon-video/app.env >/dev/null
SINGLE_CAMERA_LINKS=true
SMARTYARD_SINGLE_CAMERA_LINKS=true
SMARTYARD_COMPAT_DEFER_CAMERA_TOKEN_AUTH_TO_DVR=true
EOF

cd "$PROJECT_DIR/backend"
npm install --include=dev
npm run build
sudo systemctl restart newdomofon-video-backend.service

cd "$PROJECT_DIR/frontend"
npm install --include=dev
npm run build
sudo rsync -a --delete dist/ /var/www/newdomofon-video/

sudo systemctl restart newdomofon-smartyard-compat.service
sudo nginx -t
sudo systemctl reload nginx

echo "OK: single SmartYard link master patch applied"
echo "backup_dir=$BACKUP_DIR"
