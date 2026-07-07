#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="${PROJECT_DIR:-/opt/newdomofon-video}"
SERVER_FILE="${SERVER_FILE:-$PROJECT_DIR/smartyard-compat-proxy/server.js}"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="$PROJECT_DIR/backups/smartyard-token-stream-fix-$STAMP"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run as root: sudo bash scripts/apply-smartyard-token-stream-fix.sh" >&2
  exit 1
fi

if [[ ! -f "$SERVER_FILE" ]]; then
  echo "Missing SmartYard compat server: $SERVER_FILE" >&2
  exit 2
fi

install -d -m 0750 "$BACKUP_DIR"
cp -a "$SERVER_FILE" "$BACKUP_DIR/server.js.bak"

node - "$SERVER_FILE" <<'NODE'
const fs = require('fs');

const file = process.argv[2];
let source = fs.readFileSync(file, 'utf8');

const tokenHelperMarker = `function isAcceptedToken(token) {
  if (__ndAcceptPermanentCameraToken(token)) return true;
  return acceptedTokens().includes(String(token || ''));
}
`;

const tokenHelperReplacement = `${tokenHelperMarker}
function __ndDecodePermanentCameraToken(token) {
  try {
    const secret = process.env.DVR_NODE_MEDIA_SECRET || process.env.NODE_MEDIA_SECRET || '';
    if (!secret || typeof token !== 'string') return null;
    const parts = token.split('.');
    if (parts.length !== 2 || !parts[0] || !parts[1]) return null;

    const [payloadSegment, signatureSegment] = parts;
    const expected = __ndCrypto
      .createHmac('sha256', secret)
      .update(payloadSegment)
      .digest('base64url');

    if (!__ndSafeEqualB64url(signatureSegment, expected)) return null;

    const payload = JSON.parse(Buffer.from(payloadSegment, 'base64url').toString('utf8'));
    if (!payload || typeof payload !== 'object') return null;
    if (!payload.camera_id || !payload.stream_name) return null;
    if (!['camera', 'live', 'archive'].includes(payload.scope)) return null;
    if (payload.exp && Number(payload.exp) < Math.floor(Date.now() / 1000)) return null;

    return payload;
  } catch {
    return null;
  }
}
`;

if (!source.includes('function __ndDecodePermanentCameraToken(token)')) {
  if (!source.includes(tokenHelperMarker)) {
    throw new Error('Could not find isAcceptedToken marker');
  }
  source = source.replace(tokenHelperMarker, tokenHelperReplacement);
}

const oldResolver = `function resolveStreamName(rawStream, req, reqUrl) {
  const cameras = cameraMap();
  const aliases = aliasMap();
  const raw = String(rawStream || '').trim();
  const candidates = [];

  if (raw && raw !== 'undefined' && raw !== 'null') candidates.push(raw);

  const fromQuery = firstQuery(reqUrl, ['camera_id', 'cameraId', 'camera_uuid', 'cameraUuid', 'id', 'route_id', 'routeId']);
  if (fromQuery) candidates.push(fromQuery);

  const fromReferer = refererCameraId(req);
  if (fromReferer) candidates.push(fromReferer);

  for (const candidate of candidates) {
    if (aliases[candidate]) return String(aliases[candidate]);
    if (cameras[candidate]) return String(cameras[candidate]);
    if (!isBadStream(candidate)) return candidate;
  }

  return raw;
}
`;

const newResolver = `function resolveStreamName(rawStream, req, reqUrl, actualToken = '') {
  const cameras = cameraMap();
  const aliases = aliasMap();
  const raw = String(rawStream || '').trim();
  const candidates = [];

  if (raw && raw !== 'undefined' && raw !== 'null') candidates.push(raw);

  const fromQuery = firstQuery(reqUrl, ['camera_id', 'cameraId', 'camera_uuid', 'cameraUuid', 'id', 'route_id', 'routeId']);
  if (fromQuery) candidates.push(fromQuery);

  const fromReferer = refererCameraId(req);
  if (fromReferer) candidates.push(fromReferer);

  for (const candidate of candidates) {
    if (aliases[candidate]) return String(aliases[candidate]);
    if (cameras[candidate]) return String(cameras[candidate]);
  }

  const tokenPayload = __ndDecodePermanentCameraToken(actualToken);
  if (tokenPayload && tokenPayload.stream_name && !isBadStream(String(tokenPayload.stream_name))) {
    const tokenCameraId = String(tokenPayload.camera_id || '').trim();
    if (tokenCameraId && candidates.includes(tokenCameraId)) return String(tokenPayload.stream_name);
  }

  for (const candidate of candidates) {
    if (!isBadStream(candidate)) return candidate;
  }

  return raw;
}
`;

if (source.includes(oldResolver)) {
  source = source.replace(oldResolver, newResolver);
} else if (!source.includes('function resolveStreamName(rawStream, req, reqUrl, actualToken = \'\')')) {
  throw new Error('Could not find resolveStreamName marker');
}

const oldHandle = `    const { rawStream, mediaPath } = parseRequestPath(reqUrl);
    const stream = resolveStreamName(rawStream, req, reqUrl);

    if (isBadStream(stream)) {`;

const newHandle = `    const { rawStream, mediaPath } = parseRequestPath(reqUrl);
    const actualToken = extractToken(req, reqUrl);
    const stream = resolveStreamName(rawStream, req, reqUrl, actualToken);

    if (isBadStream(stream)) {`;

if (source.includes(oldHandle)) {
  source = source.replace(oldHandle, newHandle);
}

const duplicateActualToken = `
    const actualToken = extractToken(req, reqUrl);
    if (!isAcceptedToken(actualToken)) {`;

if (source.includes(duplicateActualToken)) {
  source = source.replace(duplicateActualToken, `
    if (!isAcceptedToken(actualToken)) {`);
}

fs.writeFileSync(file, source);
NODE

node --check "$SERVER_FILE"
systemctl restart newdomofon-smartyard-compat.service

deadline=$((SECONDS + 15))
until curl -fsS -m 2 http://127.0.0.1:3082/health >/dev/null 2>&1; do
  if (( SECONDS >= deadline )); then
    echo "WARN: smartyard-compat health is not ready yet" >&2
    break
  fi
  sleep 0.5
done

echo
echo "== smartyard-compat health =="
curl -fsS -m 5 -i http://127.0.0.1:3082/health | sed -n '1,40p' || true

if [[ -n "${TEST_STREAM:-}" && -n "${TEST_TOKEN:-}" ]]; then
  echo
  echo "== token stream resolution test =="
  curl -fsS -m 10 -i "http://127.0.0.1:3082/${TEST_STREAM}/index.m3u8?token=${TEST_TOKEN}" | sed -n '1,80p' || true
fi

echo
echo "SmartYard token stream fix applied. Backup: $BACKUP_DIR"
