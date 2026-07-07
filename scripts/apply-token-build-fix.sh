#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="${PROJECT_DIR:-/opt/newdomofon-video}"
TOKENS_FILE="$PROJECT_DIR/backend/src/routes/tokens.ts"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="$PROJECT_DIR/backups/token-build-fix-$STAMP"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run as root: sudo bash scripts/apply-token-build-fix.sh" >&2
  exit 1
fi

if [[ ! -f "$TOKENS_FILE" ]]; then
  echo "Missing tokens route: $TOKENS_FILE" >&2
  exit 2
fi

install -d -m 0750 "$BACKUP_DIR"
cp -a "$TOKENS_FILE" "$BACKUP_DIR/tokens.ts.bak"

node - "$TOKENS_FILE" <<'NODE'
const fs = require('fs');

const file = process.argv[2];
let source = fs.readFileSync(file, 'utf8');
const to = "Buffer.from(String(chunk), (typeof encoding === 'string' ? encoding : undefined) as BufferEncoding | undefined)";

source = source.replace(
  /Buffer\.from\(String\(chunk\),\s*typeof encoding === 'string' \? encoding : undefined\)/g,
  to
);

fs.writeFileSync(file, source);
NODE

grep -n "Buffer.from(String(chunk)" "$TOKENS_FILE" || true

pushd "$PROJECT_DIR/backend" >/dev/null
npm run build
popd >/dev/null

systemctl restart newdomofon-video-backend.service
systemctl restart newdomofon-public-events-proxy.service

echo
curl -fsS -m 5 -i http://127.0.0.1:3000/api/health | sed -n '1,20p' || true

echo
curl -fsS -m 5 -i http://127.0.0.1:3057/health | sed -n '1,40p' || true

echo
 echo "Token build fix applied. Backup: $BACKUP_DIR"
