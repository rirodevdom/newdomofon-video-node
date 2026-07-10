#!/usr/bin/env bash
set -Eeuo pipefail

ENV_FILE="${ENV_FILE:-/etc/newdomofon-video/app.env}"
BACKEND_URL="${BACKEND_INTERNAL_URL:-${BACKEND_URL:-https://new-video.domofon-37.ru}}"
NODE_ID="${DVR_NODE_ID:-3348ffdf-2455-472f-a941-4eb456fb1df6}"
STREAMS="${EVENT_STREAMS:-onvif2,onf}"
OUT_DIR="${OUT_DIR:-/tmp/newdomofon-onvif-camera-event-config-$(date +%Y%m%d-%H%M%S)}"
JS_FILE="$OUT_DIR/diagnose-onvif-camera-event-config.js"

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
const { XMLParser } = require('/opt/newdomofon-video-node/dvr-engine/node_modules/fast-xml-parser');
const parser = new XMLParser({ ignoreAttributes:false, attributeNamePrefix:'@_', textNodeName:'#text', removeNSPrefix:true, parseTagValue:false, parseAttributeValue:false });
const camerasFile = process.argv[2];
const outDir = process.argv[3];
const streams = new Set(String(process.argv[4] || '').split(',').map(s => s.trim()).filter(Boolean));
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
  return `<wsse:Security s:mustUnderstand="1" xmlns:wsse="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wsswssecurity-secext-1.0.xsd" xmlns:wsu="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-utility-1.0.xsd"><wsse:UsernameToken><wsse:Username>${esc(user)}</wsse:Username><wsse:Password Type="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-username-token-profile-1.0#PasswordDigest">${digest}</wsse:Password><wsse:Nonce>${nonce}</wsse:Nonce><wsu:Created>${created}</wsu:Created></wsse:UsernameToken></wsse:Security>`;
}
function envelope(body, user, pass){
  return `<?xml version="1.0" encoding="UTF-8"?><s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope" xmlns:tds="http://www.onvif.org/ver10/device/wsdl" xmlns:trt="http://www.onvif.org/ver10/media/wsdl" xmlns:tad="http://www.onvif.org/ver10/analytics/wsdl" xmlns:tev="http://www.onvif.org/ver10/events/wsdl" xmlns:tt="http://www.onvif.org/ver10/schema"><s:Header>${wsse(user, pass)}</s:Header><s:Body>${body}</s:Body></s:Envelope>`;
}
async function soap(url, action, body, user, pass, tag){
  const r = await fetch(url, { method:'POST', headers:{ 'content-type':'application/soap+xml; charset=utf-8', 'soapaction': action }, body: envelope(body, user, pass), signal: AbortSignal.timeout(20000) });
  const text = await r.text();
  fs.writeFileSync(`${outDir}/${tag}.xml`, text);
  if(!r.ok) return { ok:false, status:r.status, text, json:null };
  return { ok:true, status:r.status, text, json: parser.parse(text) };
}
function walk(v, cb){ if(!v || typeof v !== 'object') return; if(Array.isArray(v)){ for(const x of v) walk(x,cb); return; } for(const [k,x] of Object.entries(v)){ cb(k,x); walk(x,cb); } }
function all(root, key){ const out=[]; walk(root,(k,v)=>{ if(k===key) out.push(v); }); return out.flatMap(x => Array.isArray(x) ? x : [x]); }
function textOf(v){ if(v == null) return null; if(typeof v !== 'object') return String(v); return v['#text'] ?? v._ ?? null; }
function first(root, keys){ let found=null; walk(root,(k,v)=>{ if(found==null && keys.includes(k)){ const t=textOf(v); if(t!=null) found=String(t); }}); return found; }
function getXaddr(root, serviceName){
  let out='';
  walk(root,(k,v)=>{
    if(out || !v || typeof v !== 'object') return;
    const ns = String(v.Namespace || v['Namespace'] || '');
    if(ns.includes(serviceName)) out = String(v.XAddr || v['XAddr'] || '');
  });
  return out;
}
function summarizeTopics(root){
  const topics=[];
  walk(root,(k,v)=>{
    if(k === 'TopicSet' && v && typeof v === 'object') topics.push(Object.keys(v));
  });
  return topics.flat();
}
async function one(cam){
  const c = creds(cam);
  const prefix = `${cam.stream_name}`;
  console.log(JSON.stringify({stream:cam.stream_name, xaddr:cam.onvif_xaddr, phase:'start'}));
  const info = await soap(cam.onvif_xaddr, 'http://www.onvif.org/ver10/device/wsdl/GetDeviceInformation', '<tds:GetDeviceInformation/>', c.username, c.password, `${prefix}-device-info`);
  console.log(JSON.stringify({stream:cam.stream_name, phase:'device-info', ok:info.ok, manufacturer:first(info.json,['Manufacturer']), model:first(info.json,['Model']), firmware:first(info.json,['FirmwareVersion'])}));
  const services = await soap(cam.onvif_xaddr, 'http://www.onvif.org/ver10/device/wsdl/GetServices', '<tds:GetServices><tds:IncludeCapability>true</tds:IncludeCapability></tds:GetServices>', c.username, c.password, `${prefix}-services`);
  const eventX = getXaddr(services.json, '/events/') || cam.onvif_xaddr;
  const analyticsX = getXaddr(services.json, '/analytics/') || '';
  const mediaX = getXaddr(services.json, '/media/') || cam.onvif_xaddr;
  console.log(JSON.stringify({stream:cam.stream_name, phase:'services', ok:services.ok, eventXaddr:eventX, analyticsXaddr:analyticsX, mediaXaddr:mediaX}));
  const caps = await soap(cam.onvif_xaddr, 'http://www.onvif.org/ver10/device/wsdl/GetCapabilities', '<tds:GetCapabilities><tds:Category>All</tds:Category></tds:GetCapabilities>', c.username, c.password, `${prefix}-capabilities`);
  console.log(JSON.stringify({stream:cam.stream_name, phase:'capabilities', ok:caps.ok}));
  const props = await soap(eventX, 'http://www.onvif.org/ver10/events/wsdl/EventPortType/GetEventPropertiesRequest', '<tev:GetEventProperties/>', c.username, c.password, `${prefix}-event-properties`);
  console.log(JSON.stringify({stream:cam.stream_name, phase:'event-properties', ok:props.ok, status:props.status, topicKeys:summarizeTopics(props.json).slice(0,50)}));
  const profiles = await soap(mediaX, 'http://www.onvif.org/ver10/media/wsdl/GetProfiles', '<trt:GetProfiles/>', c.username, c.password, `${prefix}-profiles`);
  const profileTokens=[];
  for(const p of all(profiles.json, 'Profiles')) if(p && typeof p === 'object' && p['@_token']) profileTokens.push(p['@_token']);
  console.log(JSON.stringify({stream:cam.stream_name, phase:'profiles', ok:profiles.ok, tokens:profileTokens}));
  if(analyticsX){
    const modules = await soap(analyticsX, 'http://www.onvif.org/ver20/analytics/wsdl/GetSupportedAnalyticsModules', '<tad:GetSupportedAnalyticsModules/>', c.username, c.password, `${prefix}-supported-analytics-modules`);
    console.log(JSON.stringify({stream:cam.stream_name, phase:'supported-analytics-modules', ok:modules.ok, status:modules.status}));
    const rules = await soap(analyticsX, 'http://www.onvif.org/ver20/analytics/wsdl/GetSupportedRules', '<tad:GetSupportedRules/>', c.username, c.password, `${prefix}-supported-rules`);
    console.log(JSON.stringify({stream:cam.stream_name, phase:'supported-rules', ok:rules.ok, status:rules.status}));
  }
  console.log(JSON.stringify({stream:cam.stream_name, phase:'done'}));
}
(async()=>{
  if(!cameras.length) throw new Error('no cameras selected');
  for(const cam of cameras) await one(cam);
  console.log(JSON.stringify({phase:'done', outDir}));
})();
JS

node "$JS_FILE" "$OUT_DIR/cameras.json" "$OUT_DIR" "$STREAMS" | tee "$OUT_DIR/config.log"

echo "OUT_DIR=$OUT_DIR"
echo "grep -RniE 'RuleEngine|Motion|IsMotion|Analytics|CellMotion|Rule|Topic|XAddr|GetSupported' $OUT_DIR | head -300"
