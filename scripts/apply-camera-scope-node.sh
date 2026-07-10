#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="${PROJECT_DIR:-/opt/newdomofon-video-node}"
BACKUP_DIR="$PROJECT_DIR/backups/camera-scope-node-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BACKUP_DIR"

cd "$PROJECT_DIR"
cp -a dvr-engine/src/mediaAuth.ts "$BACKUP_DIR/mediaAuth.ts.bak"

python3 - <<'PY'
from pathlib import Path

p = Path('dvr-engine/src/mediaAuth.ts')
s = p.read_text()

s = s.replace("type Scope = 'live' | 'archive' | 'export' | 'file' | 'status';", "type Scope = 'camera' | 'live' | 'archive' | 'export' | 'file' | 'status';")

if 'function scopeAllowed(payloadScope:' not in s:
    marker = "function safeEqual(a: string, b: string): boolean {"
    insert = """const cameraScopeTargets: Scope[] = ['live', 'archive', 'file', 'status'];

function scopeAllowed(payloadScope: unknown, allowedScopes: Scope[]): boolean {
  const scope = String(payloadScope || '') as Scope;
  if (allowedScopes.includes(scope)) return true;
  if (scope === 'camera') return allowedScopes.some((allowed) => cameraScopeTargets.includes(allowed));
  return false;
}

"""
    if marker not in s:
        raise SystemExit('mediaAuth.ts: safeEqual marker not found')
    s = s.replace(marker, insert + marker)

s = s.replace("  if (!allowedScopes.includes(payload.scope)) return false;", "  if (!scopeAllowed(payload.scope, allowedScopes)) return false;")

p.write_text(s)
PY

cd "$PROJECT_DIR/dvr-engine"
npm install --include=dev
npm run build
sudo systemctl restart newdomofon-video-dvr.service
sleep 2
curl -fsS http://127.0.0.1:3010/health || true
echo
echo "OK: node camera-wide token scope patch applied"
echo "backup_dir=$BACKUP_DIR"
