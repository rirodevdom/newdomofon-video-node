import crypto from 'node:crypto';
import { XMLParser } from 'fast-xml-parser';
import { appendLocalEvents } from './localEventStore.js';
import { loadAssignedCameras } from './nodeClient.js';
import type { CameraConfig } from './types.js';

const VERSION = 'v301-node-local-pullpoint';
type SoapVersion = '1.2' | '1.1';
type AuthMode = 'digest' | 'text' | 'none';
type Profile = { soap: SoapVersion; auth: AuthMode; wsa: boolean };
type Credentials = { username: string; password: string };
type Session = {
  camera: CameraConfig;
  fingerprint: string;
  stopped: boolean;
  profile?: Profile;
  eventUrl?: string;
  pullUrl?: string;
  expiresAt?: number;
  failures: number;
  lastOkAt?: string;
  lastEventAt?: string;
  lastError?: string;
  received: number;
  inserted: number;
  duplicates: number;
  states: Map<string, string>;
  seen: Map<string, number>;
};

const parser = new XMLParser({
  ignoreAttributes: false,
  attributeNamePrefix: '@_',
  textNodeName: '#text',
  removeNSPrefix: true,
  parseTagValue: false,
  parseAttributeValue: false,
  trimValues: true
});
const sessions = new Map<string, Session>();
let syncTimer: NodeJS.Timeout | null = null;
let syncing = false;

function envNumber(name: string, fallback: number, min: number) {
  const value = Number(process.env[name] ?? fallback);
  return Number.isFinite(value) ? Math.max(min, value) : fallback;
}
function enabled() {
  return !['0', 'false', 'no', 'off'].includes(String(process.env.ONVIF_EVENTS_ENABLED ?? 'true').toLowerCase());
}
function sleep(ms: number) { return new Promise<void>((resolve) => setTimeout(resolve, ms)); }
function escapeXml(value: unknown) {
  return String(value ?? '').replace(/&/g, '&amp;').replace(/</g, '&lt;')
    .replace(/>/g, '&gt;').replace(/"/g, '&quot;').replace(/'/g, '&apos;');
}
function credentialsFromRtsp(source?: string | null): Credentials {
  try {
    const url = new URL(String(source || ''));
    return { username: decodeURIComponent(url.username || ''), password: decodeURIComponent(url.password || '') };
  } catch { return { username: '', password: '' }; }
}
function credentials(camera: CameraConfig): Credentials {
  const rtsp = credentialsFromRtsp(camera.source_url);
  return {
    username: String(camera.onvif_username || camera.device_username || rtsp.username || ''),
    password: String(camera.onvif_password || camera.device_password || rtsp.password || '')
  };
}
function deviceUrl(camera: CameraConfig) {
  const configured = String(camera.onvif_xaddr || '').trim();
  if (configured) return configured;
  const raw = String(camera.device_host || '').trim();
  if (!raw) return '';
  const parsed = /^https?:\/\//i.test(raw) ? new URL(raw) : new URL(`http://${raw}`);
  const port = Number(camera.onvif_port || camera.device_port || parsed.port || 80);
  return `${parsed.protocol}//${parsed.hostname}:${port}/onvif/device_service`;
}
function fingerprint(camera: CameraConfig) {
  const auth = credentials(camera);
  return [camera.id, camera.stream_name, deviceUrl(camera), auth.username,
    crypto.createHash('sha256').update(auth.password).digest('hex').slice(0, 16)].join('|');
}
function profileKey(profile: Profile) { return `${profile.soap}/${profile.auth}/${profile.wsa ? 'wsa' : 'plain'}`; }
function profiles(auth: Credentials, preferred?: Profile): Profile[] {
  const modes: AuthMode[] = auth.username ? ['digest', 'text'] : ['none'];
  const result: Profile[] = preferred ? [preferred] : [];
  for (const wsa of [true, false]) for (const soap of ['1.2', '1.1'] as SoapVersion[])
    for (const mode of modes) result.push({ soap, auth: mode, wsa });
  const seen = new Set<string>();
  return result.filter((item) => !seen.has(profileKey(item)) && Boolean(seen.add(profileKey(item))));
}
function wsse(auth: Credentials, mode: AuthMode) {
  if (mode === 'none' || !auth.username) return '';
  const created = new Date().toISOString();
  if (mode === 'text') return `<wsse:Security s:mustUnderstand="1" xmlns:wsse="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-secext-1.0.xsd" xmlns:wsu="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-utility-1.0.xsd"><wsse:UsernameToken><wsse:Username>${escapeXml(auth.username)}</wsse:Username><wsse:Password Type="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-username-token-profile-1.0#PasswordText">${escapeXml(auth.password)}</wsse:Password><wsu:Created>${created}</wsu:Created></wsse:UsernameToken></wsse:Security>`;
  const nonceRaw = crypto.randomBytes(16);
  const nonce = nonceRaw.toString('base64');
  const digest = crypto.createHash('sha1').update(Buffer.concat([nonceRaw, Buffer.from(created), Buffer.from(auth.password)])).digest('base64');
  return `<wsse:Security s:mustUnderstand="1" xmlns:wsse="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-secext-1.0.xsd" xmlns:wsu="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-utility-1.0.xsd"><wsse:UsernameToken><wsse:Username>${escapeXml(auth.username)}</wsse:Username><wsse:Password Type="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-username-token-profile-1.0#PasswordDigest">${digest}</wsse:Password><wsse:Nonce EncodingType="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-soap-message-security-1.0#Base64Binary">${nonce}</wsse:Nonce><wsu:Created>${created}</wsu:Created></wsse:UsernameToken></wsse:Security>`;
}
function envelope(url: string, action: string, body: string, auth: Credentials, profile: Profile) {
  const soapNs = profile.soap === '1.2' ? 'http://www.w3.org/2003/05/soap-envelope' : 'http://schemas.xmlsoap.org/soap/envelope/';
  const addressing = profile.wsa ? `<wsa:Action s:mustUnderstand="1">${escapeXml(action)}</wsa:Action><wsa:MessageID>urn:uuid:${crypto.randomUUID()}</wsa:MessageID><wsa:ReplyTo><wsa:Address>http://www.w3.org/2005/08/addressing/anonymous</wsa:Address></wsa:ReplyTo><wsa:To s:mustUnderstand="1">${escapeXml(url)}</wsa:To>` : '';
  return `<?xml version="1.0" encoding="UTF-8"?><s:Envelope xmlns:s="${soapNs}" xmlns:wsa="http://www.w3.org/2005/08/addressing" xmlns:tds="http://www.onvif.org/ver10/device/wsdl" xmlns:tev="http://www.onvif.org/ver10/events/wsdl" xmlns:wsnt="http://docs.oasis-open.org/wsn/b-2"><s:Header>${addressing}${wsse(auth, profile.auth)}</s:Header><s:Body>${body}</s:Body></s:Envelope>`;
}
function findFirst(value: any, key: string): any {
  if (!value || typeof value !== 'object') return undefined;
  if (!Array.isArray(value) && Object.prototype.hasOwnProperty.call(value, key)) return value[key];
  for (const child of Array.isArray(value) ? value : Object.values(value)) {
    const found = findFirst(child, key); if (found !== undefined) return found;
  }
  return undefined;
}
function findAll(value: any, key: string, out: any[] = []): any[] {
  if (!value || typeof value !== 'object') return out;
  if (!Array.isArray(value) && Object.prototype.hasOwnProperty.call(value, key)) {
    const found = value[key]; Array.isArray(found) ? out.push(...found) : out.push(found);
  }
  for (const child of Array.isArray(value) ? value : Object.values(value)) findAll(child, key, out);
  return out;
}
function text(value: any): string | null {
  if (value == null) return null;
  if (['string', 'number', 'boolean'].includes(typeof value)) return String(value);
  if (Array.isArray(value)) for (const item of value) { const found = text(item); if (found != null) return found; }
  if (typeof value === 'object') for (const key of ['#text', '_', '__text', 'Address']) {
    if (value[key] !== undefined) { const found = text(value[key]); if (found != null) return found; }
  }
  return null;
}
async function requestSoap(url: string, action: string, body: string, auth: Credentials, profile: Profile) {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), envNumber('ONVIF_EVENTS_REQUEST_TIMEOUT_MS', 15_000, 5_000));
  try {
    const headers = profile.soap === '1.2'
      ? { 'content-type': `application/soap+xml; charset=utf-8; action="${action}"`, soapaction: action }
      : { 'content-type': 'text/xml; charset=utf-8', soapaction: `"${action}"` };
    const response = await fetch(url, { method: 'POST', headers, body: envelope(url, action, body, auth, profile), signal: controller.signal });
    const raw = await response.text();
    let parsed: any = null; try { parsed = parser.parse(raw); } catch { /* handled below */ }
    if (!response.ok || findFirst(parsed, 'Fault')) throw new Error(`HTTP ${response.status} ${raw.slice(0, 600)}`);
    return { parsed, profile };
  } finally { clearTimeout(timeout); }
}
async function callSoap(url: string, action: string, body: string, auth: Credentials, preferred?: Profile) {
  let last: unknown = null;
  for (const profile of profiles(auth, preferred)) try { return await requestSoap(url, action, body, auth, profile); }
  catch (error) { last = error; }
  throw last || new Error(`SOAP ${action} failed`);
}
function normalizeUrl(candidate: string, baseUrl: string) {
  const base = new URL(baseUrl); const parsed = new URL(candidate, base);
  if (['0.0.0.0', '127.0.0.1', 'localhost', '::'].includes(parsed.hostname)) parsed.hostname = base.hostname;
  return parsed.toString();
}
async function eventCandidates(device: string, auth: Credentials) {
  const candidates: string[] = [];
  try {
    const result = await callSoap(device, 'http://www.onvif.org/ver10/device/wsdl/GetServices', '<tds:GetServices><tds:IncludeCapability>true</tds:IncludeCapability></tds:GetServices>', auth);
    for (const service of findAll(result.parsed, 'Service')) {
      const ns = text(service?.Namespace) || ''; const xaddr = text(service?.XAddr) || '';
      if (xaddr && /events\/wsdl/i.test(ns)) candidates.push(normalizeUrl(xaddr, device));
    }
  } catch (error) { console.warn('[onvif-events:v3] GetServices failed', String(error).slice(0, 500)); }
  const base = new URL(device).origin;
  candidates.push(`${base}/onvif/event_service`, `${base}/onvif/events_service`, `${base}/onvif/EventService`, device);
  return Array.from(new Set(candidates));
}
async function subscribe(session: Session, auth: Credentials, device: string) {
  const action = 'http://www.onvif.org/ver10/events/wsdl/EventPortType/CreatePullPointSubscriptionRequest';
  let last: unknown = null;
  for (const url of await eventCandidates(device, auth)) for (const body of [
    `<tev:CreatePullPointSubscription><tev:InitialTerminationTime>${process.env.ONVIF_EVENTS_SUBSCRIPTION_TTL || 'PT10M'}</tev:InitialTerminationTime></tev:CreatePullPointSubscription>`,
    '<tev:CreatePullPointSubscription/>'
  ]) try {
    const result = await callSoap(url, action, body, auth, session.profile);
    const address = text(findFirst(result.parsed, 'SubscriptionReference')) || text(findFirst(result.parsed, 'Address')) || url;
    session.profile = result.profile; session.eventUrl = url; session.pullUrl = normalizeUrl(address, url);
    const termination = text(findFirst(result.parsed, 'TerminationTime'));
    const parsedExpiry = termination ? Date.parse(termination) : NaN;
    session.expiresAt = Number.isFinite(parsedExpiry) ? parsedExpiry : Date.now() + envNumber('ONVIF_EVENTS_SUBSCRIPTION_FALLBACK_MS', 480_000, 60_000);
    console.log('[onvif-events:v3] subscription ready', { stream_name: session.camera.stream_name, event_url: url, pullpoint_url: session.pullUrl, profile: profileKey(result.profile) });
    return;
  } catch (error) { last = error; }
  throw last || new Error('CreatePullPointSubscription failed');
}
function collectItems(value: any, out: Record<string, string> = {}) {
  if (!value || typeof value !== 'object') return out;
  if (Array.isArray(value)) { for (const item of value) collectItems(item, out); return out; }
  const name = value['@_Name'] ?? value.Name; const item = value['@_Value'] ?? value.Value;
  if (name !== undefined && item !== undefined) out[String(name)] = String(item);
  for (const child of Object.values(value)) collectItems(child, out);
  return out;
}
function canonicalState(value: unknown): string | null {
  if (value == null || String(value).trim() === '') return null;
  const state = String(value).trim().toLowerCase();
  if (['1', 'true', 'yes', 'on', 'active', 'detected', 'start'].includes(state)) return 'true';
  if (['0', 'false', 'no', 'off', 'inactive', 'idle', 'clear', 'end'].includes(state)) return 'false';
  return String(value);
}
function classify(topic: string, items: Record<string, string>) {
  const value = `${topic} ${Object.keys(items).join(' ')}`.toLowerCase();
  if (/(motion|cellmotion|videomotion)/.test(value)) return 'motion';
  if (/(linecross|crossline)/.test(value)) return 'line_crossing';
  if (/(intrusion|fielddetector|regionentrance)/.test(value)) return 'intrusion';
  if (/(tamper|covered|defocus|blur)/.test(value)) return 'tamper';
  if (/(face|human|person)/.test(value)) return 'person';
  if (/(vehicle|car)/.test(value)) return 'vehicle';
  return (topic.split(/[/:|]/).filter(Boolean).pop() || 'onvif.event').replace(/[^a-z0-9_.-]+/gi, '_').toLowerCase();
}
function normalize(session: Session, notification: any) {
  const topic = text(notification?.Topic) || text(findFirst(notification, 'Topic')) || 'onvif.event';
  const message = notification?.Message?.Message || notification?.Message || findFirst(notification, 'Message') || notification;
  const sourceItems = collectItems(message?.Source || findFirst(message, 'Source') || {});
  const dataItems = collectItems(message?.Data || findFirst(message, 'Data') || {});
  const items = { ...sourceItems, ...dataItems };
  const stateKey = ['IsMotion', 'Motion', 'State', 'LogicalState', 'Active', 'Alarm', 'Value'].find((key) => items[key] !== undefined);
  const eventState = canonicalState(stateKey ? items[stateKey] : null);
  const sourceName = items.VideoSourceConfigurationToken || items.VideoSourceToken || items.Source || items.Name || null;
  const operation = String(message?.['@_PropertyOperation'] || '').toLowerCase();
  if (operation === 'initialized' && !['1', 'true', 'yes', 'on'].includes(String(process.env.ONVIF_EVENTS_EMIT_INITIALIZED || '').toLowerCase())) return null;
  const dedupKey = `${topic}|${sourceName || ''}|${stateKey || ''}`;
  if (eventState !== null) {
    if (session.states.get(dedupKey) === eventState) { session.duplicates += 1; return null; }
    session.states.set(dedupKey, eventState);
  }
  const rawTime = String(message?.['@_UtcTime'] || findFirst(message, 'UtcTime') || '');
  const time = Date.parse(rawTime);
  const occurredAt = Number.isFinite(time) ? new Date(time).toISOString() : new Date().toISOString();
  if (eventState === null) {
    const hash = crypto.createHash('sha256').update(JSON.stringify({ topic, sourceName, occurredAt, items })).digest('hex');
    const cutoff = Date.now() - envNumber('ONVIF_EVENTS_SEEN_TTL_MS', 600_000, 60_000);
    for (const [key, at] of session.seen) if (at < cutoff) session.seen.delete(key);
    if (session.seen.has(hash)) { session.duplicates += 1; return null; }
    session.seen.set(hash, Date.now());
  }
  const data: Record<string, unknown> = { collector: VERSION, operation: operation || null, source: sourceItems, values: dataItems, soap_profile: session.profile ? profileKey(session.profile) : null };
  if (['1', 'true', 'yes', 'on'].includes(String(process.env.ONVIF_EVENTS_STORE_RAW || '').toLowerCase())) data.raw = notification;
  return { camera_id: session.camera.id, stream_name: session.camera.stream_name, event_type: classify(topic, items), event_state: eventState, topic, source_name: sourceName, occurred_at: occurredAt, data };
}
async function pull(session: Session, auth: Credentials) {
  if (!session.pullUrl || !session.profile) throw new Error('PullPoint is missing');
  const action = 'http://www.onvif.org/ver10/events/wsdl/PullPointSubscription/PullMessagesRequest';
  const body = `<tev:PullMessages><tev:Timeout>${process.env.ONVIF_EVENTS_PULL_TIMEOUT || 'PT5S'}</tev:Timeout><tev:MessageLimit>${Math.max(1, Number(process.env.ONVIF_EVENTS_MESSAGE_LIMIT || 100))}</tev:MessageLimit></tev:PullMessages>`;
  return (await callSoap(session.pullUrl, action, body, auth, session.profile)).parsed;
}
function backoff(failures: number) { return Math.min(envNumber('ONVIF_EVENTS_RETRY_MAX_MS', 60_000, 10_000), envNumber('ONVIF_EVENTS_RETRY_MIN_MS', 2_000, 1_000) * 2 ** Math.min(6, failures - 1)); }
async function run(session: Session) {
  const auth = credentials(session.camera); const device = deviceUrl(session.camera);
  console.log('[onvif-events:v3] camera loop started', { version: VERSION, camera_id: session.camera.id, stream_name: session.camera.stream_name, device_url: device, username: auth.username || '<anonymous>' });
  while (!session.stopped) try {
    if (!session.pullUrl || !session.expiresAt || session.expiresAt <= Date.now() + 30_000) await subscribe(session, auth, device);
    const parsed = await pull(session, auth);
    const events = findAll(parsed, 'NotificationMessage').map((item) => normalize(session, item)).filter(Boolean) as any[];
    session.failures = 0; session.lastError = undefined; session.lastOkAt = new Date().toISOString(); session.received += events.length;
    if (events.length) {
      const result = appendLocalEvents(events); session.inserted += result.inserted; session.duplicates += result.duplicates;
      session.lastEventAt = events[events.length - 1].occurred_at;
      console.log('[onvif-events:v3] events stored locally', { stream_name: session.camera.stream_name, ...result, last_event_at: session.lastEventAt });
    }
  } catch (error) {
    session.failures += 1; session.lastError = error instanceof Error ? error.message : String(error);
    session.pullUrl = undefined; session.expiresAt = undefined;
    const delay = backoff(session.failures);
    console.warn('[onvif-events:v3] camera loop failed', { stream_name: session.camera.stream_name, failures: session.failures, retry_ms: delay, error: session.lastError.slice(0, 1000) });
    await sleep(delay);
  }
}
async function sync() {
  if (syncing) return; syncing = true;
  try {
    const cameras = (await loadAssignedCameras()).filter((camera) => camera.is_enabled !== false && Boolean(deviceUrl(camera)) && (Boolean(camera.onvif_xaddr) || String(camera.device_connection_type || '').toUpperCase() === 'ONVIF'));
    const wanted = new Set(cameras.map((camera) => camera.id));
    for (const [id, session] of sessions) if (!wanted.has(id)) { session.stopped = true; sessions.delete(id); }
    for (const camera of cameras) {
      const current = sessions.get(camera.id); const next = fingerprint(camera);
      if (current?.fingerprint === next && !current.stopped) { current.camera = camera; continue; }
      if (current) current.stopped = true;
      const session: Session = { camera, fingerprint: next, stopped: false, failures: 0, received: 0, inserted: 0, duplicates: 0, states: new Map(), seen: new Map() };
      sessions.set(camera.id, session); void run(session).catch((error) => console.error('[onvif-events:v3] unhandled loop failure', error));
    }
  } finally { syncing = false; }
}
export function getOnvifEventCollectorStatus() {
  const cameras = Array.from(sessions.values()).map((session) => ({ camera_id: session.camera.id, stream_name: session.camera.stream_name, connected: Boolean(session.lastOkAt && !session.lastError), profile: session.profile ? profileKey(session.profile) : null, event_url: session.eventUrl || null, pullpoint_url: session.pullUrl || null, last_ok_at: session.lastOkAt || null, last_event_at: session.lastEventAt || null, last_error: session.lastError || null, consecutive_failures: session.failures, received: session.received, inserted: session.inserted, duplicates: session.duplicates }));
  return { version: VERSION, storage: 'local-sqlite', cameras, summary: { total: cameras.length, connected: cameras.filter((item) => item.connected).length, failing: cameras.filter((item) => item.last_error).length } };
}
export function startOnvifEventCollectorV2() {
  if (syncTimer) return;
  if (!enabled()) { console.log('[onvif-events:v3] disabled'); return; }
  const syncMs = envNumber('ONVIF_EVENTS_SYNC_MS', 15_000, 5_000);
  console.log('[onvif-events:v3] enabled', { version: VERSION, storage: 'local-sqlite', sync_ms: syncMs });
  void sync().catch((error) => console.error('[onvif-events:v3] initial sync failed', error));
  syncTimer = setInterval(() => void sync().catch((error) => console.error('[onvif-events:v3] sync failed', error)), syncMs);
  syncTimer.unref?.();
}
