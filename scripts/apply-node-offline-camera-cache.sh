#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="${PROJECT_DIR:-/opt/newdomofon-video}"
TARGET="$PROJECT_DIR/dvr-engine/src/nodeClient.ts"
ENV_FILE="${ENV_FILE:-/etc/newdomofon-video/app.env}"
SERVICE="${SERVICE:-newdomofon-video-dvr.service}"
BACKUP_DIR="$PROJECT_DIR/backups/node-offline-camera-cache-$(date +%Y%m%d-%H%M%S)"

mkdir -p "$BACKUP_DIR"
cp -a "$TARGET" "$BACKUP_DIR/nodeClient.ts.bak"
[ -f "$ENV_FILE" ] && cp -a "$ENV_FILE" "$BACKUP_DIR/app.env.bak" || true

cd "$PROJECT_DIR"

python3 - <<'PY'
from pathlib import Path
import re

p = Path('dvr-engine/src/nodeClient.ts')
s = p.read_text()

if "const NODE_CAMERA_CONFIG_CACHE_FILE" not in s:
    s = s.replace(
"let cachedCameras: CameraConfig[] = [];\n",
"let cachedCameras: CameraConfig[] = [];\nconst NODE_CAMERA_CONFIG_CACHE_FILE = process.env.NODE_CAMERA_CONFIG_CACHE_FILE || '/var/lib/newdomofon-video/node-camera-config-cache.json';\n",
1)

helpers = r'''
async function saveCameraConfigCache(data: {
  media_secret?: string;
  config_generation?: string;
  cameras?: CameraConfig[];
}): Promise<void> {
  try {
    await fs.mkdir(NODE_CAMERA_CONFIG_CACHE_FILE.replace(/\/[^/]+$/, ''), { recursive: true });
    await fs.writeFile(NODE_CAMERA_CONFIG_CACHE_FILE, JSON.stringify({
      saved_at: new Date().toISOString(),
      media_secret: data.media_secret || mediaSecret || '',
      config_generation: data.config_generation || configGeneration || '',
      cameras: Array.isArray(data.cameras) ? data.cameras : []
    }, null, 2));
  } catch (error) {
    console.warn('[node-client] failed to save camera config cache', error instanceof Error ? error.message : error);
  }
}

async function loadCameraConfigCache(): Promise<{
  media_secret?: string;
  config_generation?: string;
  cameras?: CameraConfig[];
} | null> {
  try {
    const raw = await fs.readFile(NODE_CAMERA_CONFIG_CACHE_FILE, 'utf8');
    const parsed = JSON.parse(raw);
    if (!parsed || !Array.isArray(parsed.cameras)) return null;
    console.warn('[node-client] using cached camera config', {
      file: NODE_CAMERA_CONFIG_CACHE_FILE,
      saved_at: parsed.saved_at || null,
      cameras: parsed.cameras.length
    });
    return parsed;
  } catch {
    return null;
  }
}
'''
if 'async function saveCameraConfigCache' not in s:
    s = s.replace('async function storageStatus() {', helpers + '\nasync function storageStatus() {', 1)

pattern = re.compile(r"export async function loadAssignedCameras\(\): Promise<CameraConfig\[]> \{.*?\n\}", re.S)
new_fn = r'''export async function loadAssignedCameras(): Promise<CameraConfig[]> {
  if (!isNodeMode()) return cachedCameras;

  try {
    const data = await requestJson<{
      media_secret?: string;
      config_generation?: string;
      cameras?: CameraConfig[];
    }>('/api/node-agent/config');

    mediaSecret = data.media_secret || mediaSecret;
    configGeneration = String(data.config_generation || configGeneration || '');
    cachedCameras = Array.isArray(data.cameras) ? data.cameras : [];
    await saveCameraConfigCache(data);
    return cachedCameras;
  } catch (error) {
    const cached = await loadCameraConfigCache();
    if (cached) {
      mediaSecret = cached.media_secret || mediaSecret;
      configGeneration = String(cached.config_generation || configGeneration || '');
      cachedCameras = Array.isArray(cached.cameras) ? cached.cameras : [];
      return cachedCameras;
    }
    throw error;
  }
}'''

s2, n = pattern.subn(new_fn, s, count=1)
if n != 1:
    raise SystemExit('loadAssignedCameras function not found')
p.write_text(s2)
PY

sudo sed -i -E '/^NODE_CAMERA_CONFIG_CACHE_FILE=/d' "$ENV_FILE" 2>/dev/null || true
echo 'NODE_CAMERA_CONFIG_CACHE_FILE=/var/lib/newdomofon-video/node-camera-config-cache.json' | sudo tee -a "$ENV_FILE" >/dev/null

cd "$PROJECT_DIR/dvr-engine"
npm install --include=dev
npm run build
sudo systemctl restart "$SERVICE"
sleep 4

echo "---- cache file ----"
ls -lah /var/lib/newdomofon-video/node-camera-config-cache.json 2>/dev/null || true

echo "---- health ----"
curl -fsS http://127.0.0.1:3010/health || true
echo

echo "OK: node camera config will survive master outage/restart"
echo "backup_dir=$BACKUP_DIR"
