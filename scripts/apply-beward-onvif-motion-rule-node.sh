#!/usr/bin/env bash
set -Eeuo pipefail

ENV_FILE="${ENV_FILE:-/etc/newdomofon-video/app.env}"
BACKEND_URL="${BACKEND_INTERNAL_URL:-${BACKEND_URL:-https://new-video.domofon-37.ru}}"
NODE_ID="${DVR_NODE_ID:-3348ffdf-2455-472f-a941-4eb456fb1df6}"
STREAMS="${EVENT_STREAMS:-onvif2,onf}"
RULE_NAME="${RULE_NAME:-nd_motion}"
ACTION="${ACTION:-add}"        # add | remove | verify
APPLY="${APPLY:-0}"            # set APPLY=1 to actually change camera config
OUT_DIR="${OUT_DIR:-/tmp/newdomofon-beward-onvif-rule-$(date +%Y%m%d-%H%M%S)}"
JS_FILE="$OUT_DIR/apply-beward-onvif-motion-rule.js"

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
const { XMLParser } = require('/opt/newdomofon-video/dvr-engine/node_modules/fast-xml-parser');

const parser = new XMLParser({ ignoreAttributes:false, attributeNamePrefix:'@_', textNodeName:'#text', removeNSPrefix:true, parseTagValue:false, parseAttributeValue:false });
const camerasFile = process.argv[2];
const outDir = process.argv[3];
const streams = new Set(String(process.argv[4] || '').split(',').map(s => s.trim()).filter(Boolean));
const ruleName = String(process.argv[5] || 'nd_motion');
const action = String(process.argv[6] || 'add');
const apply = String(process.argv[7] || '0') === '1';
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
  return `<?xml version="1.0" encoding="UTF-8"?><s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope" xmlns:tds="http://www.onvif.org/ver10/device/wsdl" xmlns:trt="http://www.onvif.org/ver10/media/wsdl" xmlns:tan="http://www.onvif.org/ver20/analytics/wsdl" xmlns:axt="http://www.onvif.org/ver20/analytics" xmlns:tt="http://www.onvif.org/ver10/schema"><s:Header>${wsse(user, pass)}</s:Header><s:Body>${body}</s:Body></s:Envelope>`;
}
async function soap(url, actionName, body, user, pass, tag){
  const r = await fetch(url, { method:'POST', headers:{ 'content-type':'application/soap+xml; charset=utf-8', 'soapaction': actionName }, body: envelope(body, user, pass), signal: AbortSignal.timeout(20000) });
  const text = await r.text();
  fs.writeFileSync(`${outDir}/${tag}.xml`, text);
  let json = null;
  try { json = parser.parse(text); } catch {}
  return { ok:r.ok && !text.includes('<SOAP-ENV:Fault') && !text.includes(':Fault>'), status:r.status, text, json };
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
    rules.push({ name: String(r['@_Name'] || r.Name || ''), type: String(r['@_Type'] || r.Type || ''), keys: Object.keys(r).slice(0,30) });
  }
  return rules;
}
async function getRules(baseUrl, token, user, pass, tagPrefix){
  const body = `<tan:GetRules><tan:ConfigurationToken>${esc(token)}</tan:ConfigurationToken></tan:GetRules>`;
  const res = await soap(baseUrl, 'http://www.onvif.org/ver20/analytics/wsdl/AnalyticsPort/GetRules', body, user, pass, `${tagPrefix}-getrules`);
  return { res, rules: summarizeRules(res.json) };
}
async function removeRule(baseUrl, token, user, pass, tagPrefix){
  const body = `<tan:RemoveRules><tan:ConfigurationToken>${esc(token)}</tan:ConfigurationToken><tan:RuleName>${esc(ruleName)}</tan:RuleName></tan:RemoveRules>`;
  const actions = [
    'http://www.onvif.org/ver20/analytics/wsdl/AnalyticsPort/RemoveRules',
    'http://www.onvif.org/ver20/analytics/wsdl/RemoveRules',
    'http://www.onvif.org/ver20/analytics/wsdl/AnalyticsPort/RemoveRulesRequest'
  ];
  for(let i=0;i<actions.length;i++){
    const res = await soap(baseUrl, actions[i], body, user, pass, `${tagPrefix}-remove-${i}`);
    console.log(JSON.stringify({phase:'remove-try', tag:`${tagPrefix}-remove-${i}`, ok:res.ok, status:res.status, fault:fault(res.json)}));
    if(res.ok) return true;
  }
  return false;
}
function candidatePayloads(token){
  const rn = esc(ruleName);
  const tk = esc(token);
  return [
    {
      name:'minimal-empty-motionregionconfig',
      xml:`<tan:AddRules><tan:ConfigurationToken>${tk}</tan:ConfigurationToken><tan:Rule Name="${rn}" Type="tt:MotionRegionDetector"><tt:Parameters><tt:ElementItem Name="MotionRegion"><axt:MotionRegionConfig/></tt:ElementItem></tt:Parameters></tan:Rule></tan:AddRules>`
    },
    {
      name:'minimal-empty-motionregionconfig-unqualified-type',
      xml:`<tan:AddRules><tan:ConfigurationToken>${tk}</tan:ConfigurationToken><tan:Rule Name="${rn}" Type="MotionRegionDetector"><tt:Parameters><tt:ElementItem Name="MotionRegion"><axt:MotionRegionConfig/></tt:ElementItem></tt:Parameters></tan:Rule></tan:AddRules>`
    },
    {
      name:'simpleitems-notification-and-sensitivity',
      xml:`<tan:AddRules><tan:ConfigurationToken>${tk}</tan:ConfigurationToken><tan:Rule Name="${rn}" Type="tt:MotionRegionDetector"><tt:Parameters><tt:SimpleItem Name="Sensitivity" Value="70"/><tt:SimpleItem Name="RuleNotification" Value="true"/><tt:ElementItem Name="MotionRegion"><axt:MotionRegionConfig/></tt:ElementItem></tt:Parameters></tan:Rule></tan:AddRules>`
    }
  ];
}
async function addRule(baseUrl, token, user, pass, tagPrefix){
  const actions = [
    'http://www.onvif.org/ver20/analytics/wsdl/AnalyticsPort/AddRules',
    'http://www.onvif.org/ver20/analytics/wsdl/AddRules',
    'http://www.onvif.org/ver20/analytics/wsdl/AnalyticsPort/AddRulesRequest'
  ];
  const candidates = candidatePayloads(token);
  if(!apply){
    for (const c of candidates) fs.writeFileSync(`${outDir}/${tagPrefix}-DRYRUN-${c.name}.xml`, envelope(c.xml, '', ''));
    console.log(JSON.stringify({phase:'dry-run', token, ruleName, candidates:candidates.map(c=>c.name), message:'set APPLY=1 to change camera config'}));
    return false;
  }
  for (const candidate of candidates) {
    for(let i=0;i<actions.length;i++){
      const tag = `${tagPrefix}-add-${candidate.name}-${i}`;
      const res = await soap(baseUrl, actions[i], candidate.xml, user, pass, tag);
      console.log(JSON.stringify({phase:'add-try', tag, candidate:candidate.name, action:actions[i], ok:res.ok, status:res.status, fault:fault(res.json)}));
      const after = await getRules(baseUrl, token, user, pass, `${tagPrefix}-after-${candidate.name}-${i}`);
      const found = after.rules.some(r => r.name === ruleName || r.name === `tt:${ruleName}` || r.name.endsWith(ruleName));
      console.log(JSON.stringify({phase:'add-check', candidate:candidate.name, found, rules:after.rules}));
      if(res.ok && found) return true;
    }
  }
  return false;
}
async function one(cam){
  const c = creds(cam);
  const prefix = cam.stream_name;
  console.log(JSON.stringify({stream:cam.stream_name, phase:'start', xaddr:cam.onvif_xaddr, action, apply}));
  const info = await soap(cam.onvif_xaddr, 'http://www.onvif.org/ver10/device/wsdl/GetDeviceInformation', '<tds:GetDeviceInformation/>', c.username, c.password, `${prefix}-device-info`);
  console.log(JSON.stringify({stream:cam.stream_name, phase:'device-info', ok:info.ok, manufacturer:first(info.json,['Manufacturer']), model:first(info.json,['Model']), firmware:first(info.json,['FirmwareVersion'])}));
  const services = await soap(cam.onvif_xaddr, 'http://www.onvif.org/ver10/device/wsdl/GetServices', '<tds:GetServices><tds:IncludeCapability>true</tds:IncludeCapability></tds:GetServices>', c.username, c.password, `${prefix}-services`);
  const analyticsX = serviceXaddr(services.json, 'analytics/wsdl') || cam.onvif_xaddr;
  const mediaX = serviceXaddr(services.json, 'media/wsdl') || cam.onvif_xaddr;
  console.log(JSON.stringify({stream:cam.stream_name, phase:'services', ok:services.ok, analyticsXaddr:analyticsX, mediaXaddr:mediaX}));
  const profiles = await soap(mediaX, 'http://www.onvif.org/ver10/media/wsdl/GetProfiles', '<trt:GetProfiles/>', c.username, c.password, `${prefix}-profiles`);
  const tokens = [...new Set(profileAnalyticsTokens(profiles.json).map(t=>t.analytics))];
  console.log(JSON.stringify({stream:cam.stream_name, phase:'analytics-tokens', tokens}));
  for(const token of tokens){
    const before = await getRules(analyticsX, token, c.username, c.password, `${prefix}-${token}-before`);
    console.log(JSON.stringify({stream:cam.stream_name, phase:'rules-before', token, rules:before.rules}));
    if(action === 'verify') continue;
    if(action === 'remove') {
      if(!apply) {
        console.log(JSON.stringify({stream:cam.stream_name, phase:'dry-run-remove', token, ruleName, message:'set APPLY=1 to remove rule'}));
      } else {
        await removeRule(analyticsX, token, c.username, c.password, `${prefix}-${token}`);
      }
    } else if(action === 'add') {
      if(before.rules.some(r => r.name === ruleName || r.name.endsWith(ruleName))) {
        console.log(JSON.stringify({stream:cam.stream_name, phase:'already-exists', token, ruleName}));
      } else {
        const ok = await addRule(analyticsX, token, c.username, c.password, `${prefix}-${token}`);
        console.log(JSON.stringify({stream:cam.stream_name, phase:'add-result', token, ok}));
      }
    }
    const after = await getRules(analyticsX, token, c.username, c.password, `${prefix}-${token}-final`);
    console.log(JSON.stringify({stream:cam.stream_name, phase:'rules-after', token, rules:after.rules}));
  }
  console.log(JSON.stringify({stream:cam.stream_name, phase:'done'}));
}
(async()=>{
  if(!cameras.length) throw new Error('no cameras selected');
  for(const cam of cameras) await one(cam);
  console.log(JSON.stringify({phase:'done', outDir, apply, action, ruleName}));
})();
JS

node "$JS_FILE" "$OUT_DIR/cameras.json" "$OUT_DIR" "$STREAMS" "$RULE_NAME" "$ACTION" "$APPLY" | tee "$OUT_DIR/apply.log"

echo "OUT_DIR=$OUT_DIR"
echo "---- rule summary ----"
grep -RniE 'GetRulesResponse|AddRulesResponse|RemoveRulesResponse|Fault|MotionRegion|MotionRegionDetector|Rule Name|RuleNotification|dry-run|add-try|add-result|rules-after' "$OUT_DIR" | head -300 || true

echo "Credentials are stored in $OUT_DIR/cameras.json with chmod 600. Remove it after debugging: rm -f '$OUT_DIR/cameras.json'"
