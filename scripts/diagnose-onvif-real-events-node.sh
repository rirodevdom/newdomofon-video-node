#!/usr/bin/env bash
set -Eeuo pipefail

ENV_FILE="${ENV_FILE:-/etc/newdomofon-video/app.env}"
BACKEND_URL="${BACKEND_INTERNAL_URL:-${BACKEND_URL:-http://10.106.1.30:3000}}"
NODE_ID="${DVR_NODE_ID:-${NODE_ID:-3348ffdf-2455-472f-a941-4eb456fb1df6}}"
OUT_DIR="${OUT_DIR:-/tmp/newdomofon-onvif-event-diag-$(date +%Y%m%d-%H%M%S)}"

set -a
[ -f "$ENV_FILE" ] && . "$ENV_FILE"
set +a

if [ -z "${INTERNAL_DVR_SECRET:-}" ]; then
  echo "ERROR: INTERNAL_DVR_SECRET is empty" >&2
  exit 1
fi

mkdir -p "$OUT_DIR"
CAMERAS_JSON="$OUT_DIR/cameras.json"

curl -fsS \
  -H "x-internal-secret: ${INTERNAL_DVR_SECRET}" \
  -H "x-node-id: ${NODE_ID}" \
  "${BACKEND_URL%/}/api/internal/cameras/onvif" > "$CAMERAS_JSON"

node - "$CAMERAS_JSON" "$OUT_DIR" <<'JS'
'use strict';
const fs = require('node:fs');
const crypto = require('node:crypto');

const camerasFile = process.argv[2];
const outDir = process.argv[3];
const cameras = JSON.parse(fs.readFileSync(camerasFile, 'utf8')).items || [];

function esc(v) {
  return String(v || '')
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&apos;');
}

function wsse(username, password) {
  if (!username || !password) return '';
  const nonceRaw = crypto.randomBytes(16);
  const nonce = nonceRaw.toString('base64');
  const created = new Date().toISOString();
  const digest = crypto.createHash('sha1').update(Buffer.concat([nonceRaw, Buffer.from(created), Buffer.from(password)])).digest('base64');
  return `<wsse:Security s:mustUnderstand="1" xmlns:wsse="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-secext-1.0.xsd" xmlns:wsu="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-utility-1.0.xsd"><wsse:UsernameToken><wsse:Username>${esc(username)}</wsse:Username><wsse:Password Type="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-username-token-profile-1.0#PasswordDigest">${digest}</wsse:Password><wsse:Nonce EncodingType="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-soap-message-security-1.0#Base64Binary">${nonce}</wsse:Nonce><wsu:Created>${created}</wsu:Created></wsse:UsernameToken></wsse:Security>`;
}

function envelope12(url, action, body, user, pass, addressing) {
  const wsa = addressing ? `<wsa5:Action>${esc(action)}</wsa5:Action><wsa5:To>${esc(url)}</wsa5:To><wsa5:MessageID>urn:uuid:${crypto.randomUUID()}</wsa5:MessageID>` : '';
  return `<?xml version="1.0" encoding="UTF-8"?><s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope" xmlns:tds="http://www.onvif.org/ver10/device/wsdl" xmlns:tev="http://www.onvif.org/ver10/events/wsdl" xmlns:wsnt="http://docs.oasis-open.org/wsn/b-2" xmlns:wsa5="http://www.w3.org/2005/08/addressing"><s:Header>${wsa}${wsse(user, pass)}</s:Header><s:Body>${body}</s:Body></s:Envelope>`;
}

function envelope11(url, action, body, user, pass, addressing) {
  const wsa = addressing ? `<wsa:Action>${esc(action)}</wsa:Action><wsa:To>${esc(url)}</wsa:To><wsa:MessageID>urn:uuid:${crypto.randomUUID()}</wsa:MessageID>` : '';
  return `<?xml version="1.0" encoding="UTF-8"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" xmlns:tds="http://www.onvif.org/ver10/device/wsdl" xmlns:tev="http://www.onvif.org/ver10/events/wsdl" xmlns:wsnt="http://docs.oasis-open.org/wsn/b-2" xmlns:wsa="http://schemas.xmlsoap.org/ws/2004/08/addressing"><s:Header>${wsa}${wsse(user, pass)}</s:Header><s:Body>${body}</s:Body></s:Envelope>`;
}

async function post(name, cam, url, action, body, mode, addressing) {
  const user = cam.onvif_username || '';
  const pass = cam.onvif_password || '';
  const soap = mode === 'soap11'
    ? envelope11(url, action, body, user, pass, addressing)
    : envelope12(url, action, body, user, pass, addressing);
  const headers = mode === 'soap11'
    ? { 'content-type': 'text/xml; charset=utf-8', 'soapaction': `"${action}"` }
    : { 'content-type': `application/soap+xml; charset=utf-8; action="${action}"`, 'soapaction': action };
  const started = Date.now();
  try {
    const r = await fetch(url, { method: 'POST', headers, body: soap, signal: AbortSignal.timeout(12000) });
    const text = await r.text();
    const safe = text.replace(new RegExp(pass, 'g'), '[REDACTED]');
    const file = `${outDir}/${cam.stream_name}-${name}-${mode}${addressing ? '-wsa' : ''}.xml`;
    fs.writeFileSync(file, safe);
    console.log(JSON.stringify({ stream: cam.stream_name, test: name, mode, addressing, status: r.status, ms: Date.now() - started, file, head: safe.slice(0, 220).replace(/\s+/g, ' ') }));
    return { ok: r.ok, status: r.status, text: safe };
  } catch (e) {
    console.log(JSON.stringify({ stream: cam.stream_name, test: name, mode, addressing, error: String(e.message || e), ms: Date.now() - started }));
    return { ok: false, error: String(e.message || e) };
  }
}

async function run() {
  for (const cam of cameras) {
    const url = cam.onvif_xaddr;
    const tests = [
      ['get-event-properties', 'http://www.onvif.org/ver10/events/wsdl/EventPortType/GetEventPropertiesRequest', '<tev:GetEventProperties/>'],
      ['create-pullpoint-empty', 'http://www.onvif.org/ver10/events/wsdl/EventPortType/CreatePullPointSubscriptionRequest', '<tev:CreatePullPointSubscription/>'],
      ['create-pullpoint-initial-termination', 'http://www.onvif.org/ver10/events/wsdl/EventPortType/CreatePullPointSubscriptionRequest', '<tev:CreatePullPointSubscription><tev:InitialTerminationTime>PT10M</tev:InitialTerminationTime></tev:CreatePullPointSubscription>'],
      ['create-pullpoint-filter-motion', 'http://www.onvif.org/ver10/events/wsdl/EventPortType/CreatePullPointSubscriptionRequest', '<tev:CreatePullPointSubscription><tev:Filter><wsnt:TopicExpression Dialect="http://www.onvif.org/ver10/tev/topicExpression/ConcreteSet">tns1:VideoSource/MotionAlarm</wsnt:TopicExpression></tev:Filter></tev:CreatePullPointSubscription>']
    ];
    console.log(JSON.stringify({ camera: cam.stream_name, xaddr: url, username: cam.onvif_username || '' }));
    for (const [name, action, body] of tests) {
      await post(name, cam, url, action, body, 'soap12', false);
      await post(name, cam, url, action, body, 'soap12', true);
      await post(name, cam, url, action, body, 'soap11', false);
      await post(name, cam, url, action, body, 'soap11', true);
    }
  }
}
run().catch((e) => { console.error(e); process.exit(1); });
JS

echo "OUT_DIR=$OUT_DIR"
echo "Inspect files: ls -lah $OUT_DIR"
