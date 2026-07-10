#!/usr/bin/env bash
set -Eeuo pipefail

ENV_FILE="${ENV_FILE:-/etc/newdomofon-video/app.env}"
BACKEND_URL="${BACKEND_INTERNAL_URL:-${BACKEND_URL:-https://new-video.domofon-37.ru}}"
NODE_ID="${DVR_NODE_ID:-3348ffdf-2455-472f-a941-4eb456fb1df6}"
STREAMS="${EVENT_STREAMS:-onvif2,onf}"
OUT_DIR="${OUT_DIR:-/tmp/newdomofon-onvif-analytics-rules-$(date +%Y%m%d-%H%M%S)}"
JS_FILE="$OUT_DIR/diagnose-onvif-analytics-rules.js"

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
chmod 700 "$OUT_DIR"

curl -k -fsS \
  -H "x-internal-secret: ${INTERNAL_DVR_SECRET}" \
  -H "x-node-id: ${NODE_ID}" \
  "${BACKEND_URL%/}/api/internal/cameras/onvif" \
  -o "$OUT_DIR/cameras.json"
chmod 600 "$OUT_DIR/cameras.json"

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
  return `<wsse:Security xmlns:wsse="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-secext-1.0.xsd" xmlns:wsu="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-utility-1.0.xsd"><wsse:UsernameToken><wsse:Username>${esc(user)}</wsse:Username><wsse:Password Type="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-username-token-profile-1.0#PasswordDigest">${digest}</wsse:Password><wsse:Nonce EncodingType="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-soap-message-security-1.0#Base64Binary">${nonce}</wsse:Nonce><wsu:Created>${created}</wsu:Created></wsse:UsernameToken></wsse:Security>`;
}
function envelope(body, user, pass){
  return `<?xml version="1.0" encoding="UTF-8"?><s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope" xmlns:tds="http://www.onvif.org/ver10/device/wsdl" xmlns:trt="http://www.onvif.org/ver10/media/wsdl" xmlns:tan="http://www.onvif.org/ver20/analytics/wsdl" xmlns:tt="http://www.onvif.org/ver10/schema"><s:Header>${wsse(user, pass)}</s:Header><s:Body>${body}</s:Body></s:Envelope>`;
}
async function soap(url, action, body, user, pass, tag){
  const r = await fetch(url, { method:'POST', headers:{ 'content-type':'application/soap+xml; charset=utf-8', 'soapaction': action }, body: envelope(body, user, pass), signal: AbortSignal.timeout(20000) });
  const text = await r.text();
  fs.writeFileSync(`${outDir}/${tag}.xml`, text);
  let json = null;
  try { json = parser.parse(text); } catch {}
  return { ok:r.ok, status:r.status, text, json };
}
function walk(v, cb){ if(!v || typeof v !== 'object') return; if(Array.isArray(v)){ for(const x of v) walk(x,cb); return; } for(const [k,x] of Object.entries(v)){ cb(k,x); walk(x,cb); } }
function all(root, key){ const out=[]; walk(root,(k,v)=>{ if(k===key) out.push(v); }); return out.flatMap(x => Array.isArray(x) ? x : [x]); }
function textOf(v){ if(v == null) return null; if(typeof v !== 'object') return String(v); return v['#text'] ?? v._ ?? null; }
function first(root, keys){ let found=null; walk(root,(k,v)=>{ if(found==null && keys.includes(k)){ const t=textOf(v); if(t!=null) found=String(t); }}); return found; }
function fault(root){ return first(root, ['Text','Reason','Subcode','Value']); }
function serviceXaddr(root, namePart){
  let found='';
  walk(root,(k,v)=>{
    if(found || !v || typeof v !== 'object') return;
    const ns = String(v.Namespace || '');
    const xa = String(v.XAddr || '');
    if(ns.includes(namePart) || xa.includes(namePart)) found = xa;
  });
  return found;
}
function profileAnalyticsTokens(root){
  const out=[];
  for (const p of all(root, 'Profiles')) {
    if(!p || typeof p !== 'object') continue;
    const pt = p['@_token'] || p.token || '';
    const vac = p.VideoAnalyticsConfiguration;
    const list = Array.isArray(vac) ? vac : (vac ? [vac] : []);
    for (const v of list) {
      const token = v && typeof v === 'object' ? String(v['@_token'] || v.token || '') : '';
      if(token) out.push({ profile: String(pt), analytics: token });
    }
  }
  return out;
}
function summarizeRules(root){
  const rules = [];
  for (const r of all(root, 'Rule')) {
    if(!r || typeof r !== 'object') continue;
    rules.push({ name: String(r['@_Name'] || r.Name || ''), type: String(r['@_Type'] || r.Type || ''), keys: Object.keys(r).slice(0,20) });
  }
  return rules;
}
function summarizeRuleDescriptions(root){
  const result=[];
  for (const key of ['RuleDescription','SupportedRules','RuleOptions']) {
    for (const r of all(root, key)) {
      if(!r || typeof r !== 'object') continue;
      result.push({ tag:key, name:String(r['@_Name'] || r.Name || ''), type:String(r['@_Type'] || r.Type || ''), keys:Object.keys(r).slice(0,30) });
    }
  }
  return result;
}
async function callVariants(baseUrl, user, pass, bodyName, body, tagPrefix) {
  const actions = [
    `http://www.onvif.org/ver20/analytics/wsdl/AnalyticsPort/${bodyName}`,
    `http://www.onvif.org/ver20/analytics/wsdl/${bodyName}`,
    `http://www.onvif.org/ver20/analytics/wsdl/AnalyticsPort/${bodyName}Request`,
    `http://www.onvif.org/ver20/analytics/wsdl/${bodyName}Request`
  ];
  for (let i=0; i<actions.length; i++) {
    const tag = `${tagPrefix}-${bodyName}-${i}`;
    const res = await soap(baseUrl, actions[i], body, user, pass, tag);
    const f = fault(res.json);
    console.log(JSON.stringify({ phase:'analytics-call', tag, action: actions[i], ok:res.ok, status:res.status, fault:f, rules:summarizeRules(res.json), desc:summarizeRuleDescriptions(res.json).slice(0,10) }));
    if(res.ok && !String(res.text).includes('Fault')) return res;
  }
  return null;
}
async function one(cam){
  const c = creds(cam);
  const prefix = cam.stream_name;
  console.log(JSON.stringify({stream:cam.stream_name, phase:'start', xaddr:cam.onvif_xaddr}));
  const info = await soap(cam.onvif_xaddr, 'http://www.onvif.org/ver10/device/wsdl/GetDeviceInformation', '<tds:GetDeviceInformation/>', c.username, c.password, `${prefix}-device-info`);
  console.log(JSON.stringify({stream:cam.stream_name, phase:'device-info', ok:info.ok, manufacturer:first(info.json,['Manufacturer']), model:first(info.json,['Model']), firmware:first(info.json,['FirmwareVersion'])}));
  const services = await soap(cam.onvif_xaddr, 'http://www.onvif.org/ver10/device/wsdl/GetServices', '<tds:GetServices><tds:IncludeCapability>true</tds:IncludeCapability></tds:GetServices>', c.username, c.password, `${prefix}-services`);
  const analyticsX = serviceXaddr(services.json, 'analytics/wsdl') || cam.onvif_xaddr;
  const mediaX = serviceXaddr(services.json, 'media/wsdl') || cam.onvif_xaddr;
  console.log(JSON.stringify({stream:cam.stream_name, phase:'services', ok:services.ok, analyticsXaddr:analyticsX, mediaXaddr:mediaX}));
  const profiles = await soap(mediaX, 'http://www.onvif.org/ver10/media/wsdl/GetProfiles', '<trt:GetProfiles/>', c.username, c.password, `${prefix}-profiles`);
  const tokens = profileAnalyticsTokens(profiles.json);
  console.log(JSON.stringify({stream:cam.stream_name, phase:'profiles', ok:profiles.ok, analyticsTokens:tokens}));
  if(!tokens.length) console.log(JSON.stringify({stream:cam.stream_name, phase:'no-analytics-tokens'}));
  const uniq = [...new Set(tokens.map(t => t.analytics))];
  for (const token of uniq) {
    console.log(JSON.stringify({stream:cam.stream_name, phase:'analytics-token', token}));
    await callVariants(analyticsX, c.username, c.password, 'GetRules', `<tan:GetRules><tan:ConfigurationToken>${esc(token)}</tan:ConfigurationToken></tan:GetRules>`, `${prefix}-${token}`);
    await callVariants(analyticsX, c.username, c.password, 'GetRuleOptions', `<tan:GetRuleOptions><tan:ConfigurationToken>${esc(token)}</tan:ConfigurationToken></tan:GetRuleOptions>`, `${prefix}-${token}`);
    await callVariants(analyticsX, c.username, c.password, 'GetSupportedRules', `<tan:GetSupportedRules><tan:ConfigurationToken>${esc(token)}</tan:ConfigurationToken></tan:GetSupportedRules>`, `${prefix}-${token}`);
  }
  console.log(JSON.stringify({stream:cam.stream_name, phase:'done'}));
}
(async()=>{
  if(!cameras.length) throw new Error('no cameras selected');
  for(const cam of cameras) await one(cam);
  console.log(JSON.stringify({phase:'done', outDir}));
})();
JS

node "$JS_FILE" "$OUT_DIR/cameras.json" "$OUT_DIR" "$STREAMS" | tee "$OUT_DIR/rules.log"

echo "OUT_DIR=$OUT_DIR"
echo "grep -RniE 'GetRulesResponse|GetRuleOptionsResponse|GetSupportedRulesResponse|Rule|Motion|Region|Cell|Fault|NotSupported|analytics_configuration' $OUT_DIR | head -300"
