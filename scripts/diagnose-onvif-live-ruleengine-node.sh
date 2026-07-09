#!/usr/bin/env bash
set -Eeuo pipefail

ENV_FILE="${ENV_FILE:-/etc/newdomofon-video/app.env}"
BACKEND_URL="${BACKEND_INTERNAL_URL:-${BACKEND_URL:-https://new-video.domofon-37.ru}}"
NODE_ID="${DVR_NODE_ID:-3348ffdf-2455-472f-a941-4eb456fb1df6}"
STREAMS="${EVENT_STREAMS:-onvif2,onf}"
SECONDS="${SECONDS:-120}"
OUT_DIR="${OUT_DIR:-/tmp/newdomofon-onvif-live-ruleengine-$(date +%Y%m%d-%H%M%S)}"
JS_FILE="$OUT_DIR/live-ruleengine.js"

set -a
[ -f "$ENV_FILE" ] && . "$ENV_FILE"
set +a

BACKEND_URL="${BACKEND_INTERNAL_URL:-${BACKEND_URL:-$BACKEND_URL}}"
NODE_ID="${DVR_NODE_ID:-$NODE_ID}"

if [ -z "${INTERNAL_DVR_SECRET:-}" ]; then
  echo "ERROR: INTERNAL_DVR_SECRET is empty" >&2
  exit 1
fi

mkdir -p "$OUT_DIR"

curl -k -fsS \
  -H "x-internal-secret: ${INTERNAL_DVR_SECRET}" \
  -H "x-node-id: ${NODE_ID}" \
  "${BACKEND_URL%/}/api/internal/cameras/onvif" \
  -o "$OUT_DIR/cameras.json"

cat > "$JS_FILE" <<'JS'
'use strict';
const fs = require('fs');
const crypto = require('crypto');
const { XMLParser } = require('/opt/newdomofon-video/dvr-engine/node_modules/fast-xml-parser');
const parser = new XMLParser({ ignoreAttributes:false, attributeNamePrefix:'@_', textNodeName:'#text', removeNSPrefix:true, parseTagValue:false, parseAttributeValue:false });
const camerasFile = process.argv[2];
const outDir = process.argv[3];
const streams = new Set(String(process.argv[4] || '').split(',').map(s => s.trim()).filter(Boolean));
const seconds = Number(process.argv[5] || 120);
const until = Date.now() + seconds * 1000;
const cameras = (JSON.parse(fs.readFileSync(camerasFile, 'utf8')).items || []).filter(c => streams.has(c.stream_name));

function esc(v){ return String(v ?? '').replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;').replace(/'/g,'&apos;'); }
function rtspCreds(uri){ try { const u = new URL(uri || ''); return { username: decodeURIComponent(u.username || ''), password: decodeURIComponent(u.password || '') }; } catch { return { username:'', password:'' }; } }
function creds(cam){ const r=rtspCreds(cam.source_url); return { username: String(cam.onvif_username || r.username || ''), password: String(cam.onvif_password || r.password || '') }; }
function wsse(user, pass){
  if(!user || !pass) return '';
  const nonceRaw = crypto.randomBytes(16);
  const nonce = nonceRaw.toString('base64');
  const created = new Date().toISOString();
  const digest = crypto.createHash('sha1').update(Buffer.concat([nonceRaw, Buffer.from(created), Buffer.from(pass)])).digest('base64');
  return `<wsse:Security s:mustUnderstand="1" xmlns:wsse="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-secext-1.0.xsd" xmlns:wsu="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-utility-1.0.xsd"><wsse:UsernameToken><wsse:Username>${esc(user)}</wsse:Username><wsse:Password Type="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-username-token-profile-1.0#PasswordDigest">${digest}</wsse:Password><wsse:Nonce>${nonce}</wsse:Nonce><wsu:Created>${created}</wsu:Created></wsse:UsernameToken></wsse:Security>`;
}
function envelope(action, body, user, pass){
  return `<?xml version="1.0" encoding="UTF-8"?><s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope" xmlns:tev="http://www.onvif.org/ver10/events/wsdl" xmlns:wsa5="http://www.w3.org/2005/08/addressing"><s:Header>${wsse(user, pass)}</s:Header><s:Body>${body}</s:Body></s:Envelope>`;
}
async function soap(url, action, body, user, pass){
  const r = await fetch(url, { method:'POST', headers:{ 'content-type':'application/soap+xml; charset=utf-8', 'soapaction': action }, body: envelope(action, body, user, pass), signal: AbortSignal.timeout(20000) });
  const text = await r.text();
  if(!r.ok) throw new Error(`HTTP ${r.status}: ${text.slice(0,500)}`);
  return { text, json: parser.parse(text) };
}
function walk(v, cb){ if(!v || typeof v !== 'object') return; if(Array.isArray(v)){ for(const x of v) walk(x,cb); return; } for(const [k,x] of Object.entries(v)){ cb(k,x); walk(x,cb); } }
function values(root, key){ const out=[]; walk(root,(k,v)=>{ if(k===key) out.push(v); }); return out.flatMap(x => Array.isArray(x) ? x : [x]); }
function textOf(v){ if(v == null) return null; if(typeof v !== 'object') return String(v); return v['#text'] ?? v._ ?? null; }
function first(root, keys){ let found=null; walk(root,(k,v)=>{ if(found==null && keys.includes(k)){ const t=textOf(v); if(t!=null) found=String(t); }}); return found; }
function simple(root){ const out={}; for(const item of values(root,'SimpleItem')){ const n=item['@_Name'] ?? item.Name ?? item.$?.Name; const val=item['@_Value'] ?? item.Value ?? item.$?.Value; if(n !== undefined && val !== undefined) out[String(n)] = String(val); } return out; }
function topic(n){ const t = first(n, ['Topic']); return t || 'onvif.event'; }
function op(n){ return first(n, ['@_PropertyOperation','PropertyOperation']) || ''; }
async function oneCamera(cam){
  const c = creds(cam);
  console.log(JSON.stringify({stream:cam.stream_name, phase:'create', xaddr:cam.onvif_xaddr}));
  const sub = await soap(cam.onvif_xaddr, 'http://www.onvif.org/ver10/events/wsdl/EventPortType/CreatePullPointSubscriptionRequest', '<tev:CreatePullPointSubscription/>', c.username, c.password).catch(async e => {
    console.log(JSON.stringify({stream:cam.stream_name, phase:'create-empty-failed', error:String(e.message || e)}));
    return await soap(cam.onvif_xaddr, 'http://www.onvif.org/ver10/events/wsdl/EventPortType/CreatePullPointSubscriptionRequest', '<tev:CreatePullPointSubscription><tev:InitialTerminationTime>PT10M</tev:InitialTerminationTime></tev:CreatePullPointSubscription>', c.username, c.password);
  });
  const addr = first(sub.json, ['Address']) || cam.onvif_xaddr;
  console.log(JSON.stringify({stream:cam.stream_name, phase:'ready', pullPoint:addr}));
  let counter=0;
  while(Date.now() < until){
    const res = await soap(addr, 'http://www.onvif.org/ver10/events/wsdl/PullPointSubscription/PullMessagesRequest', '<tev:PullMessages><tev:Timeout>PT5S</tev:Timeout><tev:MessageLimit>200</tev:MessageLimit></tev:PullMessages>', c.username, c.password).catch(e => ({error:e}));
    if(res.error){ console.log(JSON.stringify({stream:cam.stream_name, phase:'pull-error', error:String(res.error.message || res.error)})); await new Promise(r=>setTimeout(r,1000)); continue; }
    const file = `${outDir}/${cam.stream_name}-${Date.now()}.xml`;
    fs.writeFileSync(file, res.text);
    const notes = values(res.json, 'NotificationMessage');
    for(const n of notes){
      const s = simple(n);
      console.log(JSON.stringify({stream:cam.stream_name, phase:'event', topic:topic(n), operation:op(n), simple:s, hasIsMotion: s.IsMotion !== undefined || s.isMotion !== undefined, file}));
      counter++;
    }
  }
  console.log(JSON.stringify({stream:cam.stream_name, phase:'done', events:counter}));
}
(async()=>{
  if(!cameras.length) throw new Error('no cameras selected');
  console.log(JSON.stringify({phase:'start', seconds, streams:[...streams], cameras:cameras.map(c=>c.stream_name), outDir}));
  await Promise.all(cameras.map(oneCamera));
})();
JS

node "$JS_FILE" "$OUT_DIR/cameras.json" "$OUT_DIR" "$STREAMS" "$SECONDS" | tee "$OUT_DIR/live.log"

echo "OUT_DIR=$OUT_DIR"
echo "Now grep: grep -RniE 'RuleEngine|IsMotion|MyMotion|Motion|Changed|Initialized' $OUT_DIR | head -200"
