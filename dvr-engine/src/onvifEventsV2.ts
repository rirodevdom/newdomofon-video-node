import crypto from 'node:crypto';
import { XMLParser } from 'fast-xml-parser';
import { config as dvrConfig } from './config.js';

const VERSION = 'v142-auto-node-onvif-events-concurrency';

interface OnvifCamera {
  id: string;
  name: string;
  stream_name: string;
  source_url?: string;
  onvif_xaddr: string;
  onvif_port?: number | null;
  onvif_username?: string | null;
  onvif_password?: string | null;
}

interface CameraSession {
  fingerprint?: string;
  eventXaddr?: string;
  pullPoint?: string;
  pullPointCreatedAt?: number;
  failedUntil?: number;
  consecutiveFailures: number;
  lastOkAt?: number;
  lastPullAt?: number;
  lastEventAt?: string;
  lastLogAt?: number;
  inFlight?: boolean;
}

const parser = new XMLParser({
  ignoreAttributes: false,
  attributeNamePrefix: '@_',
  textNodeName: '#text',
  removeNSPrefix: true,
  parseTagValue: false,
  parseAttributeValue: false
});

const sessions = new Map<string, CameraSession>();
let timer: NodeJS.Timeout | null = null;
let running = false;
let lastSkipLogAt = 0;
let lastSyncLogAt = 0;

function cfg() {
  return {
    enabled: String(process.env.EVENTS_ENABLED || process.env.ONVIF_EVENTS_ENABLED || 'true').toLowerCase() !== 'false',
    backendUrl: (process.env.BACKEND_INTERNAL_URL || process.env.BACKEND_URL || process.env.API_BASE_URL || 'http://127.0.0.1:3000').replace(/\/+$/, ''),
    secret: process.env.INTERNAL_DVR_SECRET || '',
    intervalMs: Math.max(Number(process.env.ONVIF_EVENT_POLL_INTERVAL_MS || process.env.EVENT_POLL_INTERVAL_MS || 5000), 2000),
    pullTimeout: process.env.ONVIF_PULL_TIMEOUT || 'PT5S',
    pullLimit: Math.max(Number(process.env.ONVIF_PULL_LIMIT || 50), 1),
    subscribeTtlMs: Math.max(Number(process.env.ONVIF_SUBSCRIBE_TTL_MS || 5 * 60_000), 60_000),
    failRetryMinMs: Math.max(Number(process.env.ONVIF_FAIL_RETRY_MIN_MS || 10_000), 2000),
    failRetryMaxMs: Math.max(Number(process.env.ONVIF_FAIL_RETRY_MAX_MS || 60_000), 10_000),
    quietLogMs: Math.max(Number(process.env.ONVIF_QUIET_LOG_MS || 120_000), 30_000),
    syncLogMs: Math.max(Number(process.env.ONVIF_SYNC_LOG_MS || process.env.ONVIF_QUIET_LOG_MS || 120_000), 15_000),
    concurrency: Math.max(Number(process.env.ONVIF_EVENT_CONCURRENCY || 8), 1),
    skipStreams: new Set(
      String(process.env.ONVIF_V2_SKIP_STREAMS || process.env.ONVIF_EVENTS_V2_SKIP_STREAMS || '')
        .split(',')
        .map((value) => value.trim())
        .filter(Boolean)
    )
  };
}

function nowIso() {
  return new Date().toISOString();
}

function escapeXml(value: string) {
  return String(value)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&apos;');
}

function credentialsFromRtsp(uri?: string | null) {
  if (!uri) return { username: '', password: '[REDACTED]' };
  try {
    const url = new URL(uri);
    if (url.protocol !== 'rtsp:') return { username: '', password: '[REDACTED]' };
    return {
      username: decodeURIComponent(url.username || ''),
      password: decodeURIComponent(url.password || '')
    };
  } catch {
    return { username: '', password: '[REDACTED]' };
  }
}

function cameraCredentials(camera: OnvifCamera) {
  const rtsp = credentialsFromRtsp(camera.source_url || '');
  return {
    username: String(camera.onvif_username || rtsp.username || ''),
    password: String(camera.onvif_password || rtsp.password || '')
  };
}

function fingerprint(camera: OnvifCamera) {
  const creds = cameraCredentials(camera);
  return [
    camera.id,
    camera.stream_name,
    camera.onvif_xaddr,
    camera.onvif_port || 80,
    creds.username,
    crypto.createHash('sha256').update(creds.password || '').digest('hex').slice(0, 12)
  ].join('|');
}

function wsse(username?: string | null, password?: string | null) {
  if (!username || !password) return '';

  const nonceRaw = crypto.randomBytes(16);
  const nonce = nonceRaw.toString('base64');
  const created = nowIso();
  const digest = crypto
    .createHash('sha1')
    .update(Buffer.concat([nonceRaw, Buffer.from(created), Buffer.from(password)]))
    .digest('base64');

  return `
    <wsse:Security s:mustUnderstand="1" xmlns:wsse="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-secext-1.0.xsd" xmlns:wsu="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-utility-1.0.xsd">
      <wsse:UsernameToken>
        <wsse:Username>${escapeXml(username)}</wsse:Username>
        <wsse:Password Type="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-username-token-profile-1.0#PasswordDigest">${digest}</wsse:Password>
        <wsse:Nonce EncodingType="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-soap-message-security-1.0#Base64Binary">${nonce}</wsse:Nonce>
        <wsu:Created>${created}</wsu:Created>
      </wsse:UsernameToken>
    </wsse:Security>`;
}

async function soapRequest(url: string, action: string, body: string, username?: string | null, password?: string | null) {
  const envelope = `<?xml version="1.0" encoding="UTF-8"?>
<s:Envelope
  xmlns:s="http://www.w3.org/2003/05/soap-envelope"
  xmlns:tds="http://www.onvif.org/ver10/device/wsdl"
  xmlns:tev="http://www.onvif.org/ver10/events/wsdl"
  xmlns:wsnt="http://docs.oasis-open.org/wsn/b-2"
  xmlns:wsa5="http://www.w3.org/2005/08/addressing">
  <s:Header>${wsse(username, password)}</s:Header>
  <s:Body>${body}</s:Body>
</s:Envelope>`;

  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 15_000);

  try {
    const response = await fetch(url, {
      method: 'POST',
      headers: {
        'content-type': 'application/soap+xml; charset=utf-8',
        'soapaction': action
      },
      body: envelope,
      signal: controller.signal
    });

    const text = await response.text();
    if (!response.ok) {
      throw new Error(`SOAP ${action} HTTP ${response.status}: ${text.slice(0, 300)}`);
    }

    return {
      text,
      json: parser.parse(text)
    };
  } finally {
    clearTimeout(timeout);
  }
}

function deepValues(value: any, predicate: (key: string, value: any) => boolean): any[] {
  const out: any[] = [];
  if (!value || typeof value !== 'object') return out;

  if (Array.isArray(value)) {
    for (const item of value) out.push(...deepValues(item, predicate));
    return out;
  }

  for (const [key, item] of Object.entries(value)) {
    if (predicate(key, item)) out.push(item);
    if (item && typeof item === 'object') out.push(...deepValues(item, predicate));
  }

  return out;
}

function firstString(value: any, keys: string[]): string | null {
  if (value === null || value === undefined) return null;

  if (typeof value === 'string') {
    return keys.includes('#text') ? value : null;
  }

  if (Array.isArray(value)) {
    for (const item of value) {
      const found = firstString(item, keys);
      if (found) return found;
    }
    return null;
  }

  if (typeof value !== 'object') return null;

  for (const [key, item] of Object.entries(value)) {
    if (keys.includes(key) && item !== null && item !== undefined) {
      if (typeof item === 'string') return item;
      if (typeof item === 'number' || typeof item === 'boolean') return String(item);
      if (typeof item === 'object') {
        const text = (item as any)['#text'] || (item as any)._ || (item as any).__text;
        if (text !== null && text !== undefined) return String(text);
      }
    }

    if (item && typeof item === 'object') {
      const found = firstString(item, keys);
      if (found) return found;
    }
  }

  return null;
}

function findEventXaddr(servicesXml: any): string | null {
  const serviceCandidates = deepValues(servicesXml, (key, value) => key === 'Service' && typeof value === 'object');
  const services = serviceCandidates.flatMap((item) => Array.isArray(item) ? item : [item]);

  for (const service of services) {
    const ns = String(service.Namespace || service.namespace || '');
    const xaddr = String(service.XAddr || service.xaddr || '');
    if (ns.includes('/events/wsdl') && xaddr) return xaddr;
  }

  const xaddrs = deepValues(servicesXml, (key, value) => key === 'XAddr' && typeof value === 'string') as string[];
  return xaddrs.find((x) => /event/i.test(x)) || null;
}

async function getEventServiceXaddr(camera: OnvifCamera, username: string, password: string) {
  const result = await soapRequest(
    camera.onvif_xaddr,
    'http://www.onvif.org/ver10/device/wsdl/GetServices',
    '<tds:GetServices><tds:IncludeCapability>true</tds:IncludeCapability></tds:GetServices>',
    username,
    password
  );

  return findEventXaddr(result.json) || camera.onvif_xaddr;
}

async function createPullPoint(eventXaddr: string, username: string, password: string) {
  const result = await soapRequest(
    eventXaddr,
    'http://www.onvif.org/ver10/events/wsdl/EventPortType/CreatePullPointSubscriptionRequest',
    '<tev:CreatePullPointSubscription><tev:InitialTerminationTime>PT1H</tev:InitialTerminationTime></tev:CreatePullPointSubscription>',
    username,
    password
  );

  const address = firstString(result.json, ['Address']);
  return address || eventXaddr;
}

async function pullMessages(pullPoint: string, username: string, password: string) {
  const config = cfg();
  const result = await soapRequest(
    pullPoint,
    'http://www.onvif.org/ver10/events/wsdl/PullPointSubscription/PullMessagesRequest',
    `<tev:PullMessages><tev:Timeout>${escapeXml(config.pullTimeout)}</tev:Timeout><tev:MessageLimit>${config.pullLimit}</tev:MessageLimit></tev:PullMessages>`,
    username,
    password
  );

  return result.json;
}

function collectNotifications(xml: any): any[] {
  const values = deepValues(xml, (key, value) => key === 'NotificationMessage' && typeof value === 'object');
  return values.flatMap((item) => Array.isArray(item) ? item : [item]);
}

function collectSimpleItems(value: any): Record<string, string> {
  const items = deepValues(value, (key, item) => key === 'SimpleItem' && typeof item === 'object')
    .flatMap((item) => Array.isArray(item) ? item : [item]);

  const out: Record<string, string> = {};

  for (const item of items) {
    const name = item['@_Name'] || item.Name || item.name || item.$?.Name || item.$?.name;
    const val = item['@_Value'] || item.Value || item.value || item.$?.Value || item.$?.value;
    if (name !== undefined && val !== undefined) out[String(name)] = String(val);
  }

  return out;
}

function topicFromNotification(notification: any): string {
  const topic = firstString(notification, ['Topic']);
  if (topic) return topic.replace(/\s+/g, ' ').trim();
  return 'onvif.event';
}

function topicLeaf(topic: string) {
  const parts = String(topic || '').split(/[/:|]/).filter(Boolean);
  return parts[parts.length - 1] || topic || 'onvif.event';
}

function eventState(items: Record<string, string>) {
  const keys = ['State', 'IsMotion', 'LogicalState', 'Active', 'Motion', 'Value'];
  for (const key of keys) {
    if (items[key] !== undefined) return String(items[key]);
  }
  return null;
}

function stateKey(items: Record<string, string>) {
  const keys = ['IsMotion', 'Motion', 'State', 'LogicalState', 'Active', 'Value'];
  return keys.find((key) => items[key] !== undefined) || null;
}

function occurredAt(notification: any) {
  const utc = firstString(notification, ['@_UtcTime', 'UtcTime']);
  if (utc && !Number.isNaN(Date.parse(utc))) return new Date(utc).toISOString();
  return nowIso();
}

function sourceName(items: Record<string, string>) {
  return items.VideoSourceConfigurationToken || items.VideoSourceToken || items.Source || items.Name || null;
}

function mapEvents(camera: OnvifCamera, xml: any) {
  return collectNotifications(xml).map((notification) => {
    const topic = topicFromNotification(notification);
    const items = collectSimpleItems(notification);
    const key = stateKey(items);
    const state = eventState(items);
    const source = sourceName(items);

    return {
      camera_id: camera.id,
      stream_name: camera.stream_name,
      event_type: topic || topicLeaf(topic),
      event_state: state,
      topic,
      source_name: source,
      occurred_at: occurredAt(notification),
      data: {
        simple: items,
        simpleItems: items,
        state_key: key,
        source_name: source,
        raw: notification
      }
    };
  });
}

async function backendGet(path: string) {
  const config = cfg();
  const response = await fetch(`${config.backendUrl}${path}`, {
    headers: { 'x-internal-secret': config.secret, 'x-node-id': dvrConfig.nodeId }
  });

  if (!response.ok) {
    throw new Error(`Backend GET ${path} HTTP ${response.status}: ${await response.text()}`);
  }

  return response.json();
}

async function backendPostEvent(event: any) {
  const config = cfg();
  const response = await fetch(`${config.backendUrl}/api/internal/events/onvif`, {
    method: 'POST',
    headers: {
      'content-type': 'application/json',
      'x-internal-secret': config.secret,
      'x-node-id': dvrConfig.nodeId
    },
    body: JSON.stringify(event)
  });

  if (!response.ok) {
    throw new Error(`Backend POST event HTTP ${response.status}: ${(await response.text()).slice(0, 300)}`);
  }

  return response.json() as Promise<{ ok?: boolean; inserted?: boolean }>;
}

function backoffMs(session: CameraSession) {
  const config = cfg();
  const exponent = Math.min(session.consecutiveFailures, 4);
  return Math.min(config.failRetryMaxMs, config.failRetryMinMs * Math.pow(2, exponent));
}

function markFailure(camera: OnvifCamera, session: CameraSession, error: unknown) {
  const now = Date.now();
  session.consecutiveFailures = (session.consecutiveFailures || 0) + 1;
  session.failedUntil = now + backoffMs(session);
  session.eventXaddr = undefined;
  session.pullPoint = undefined;
  session.pullPointCreatedAt = undefined;

  const message = error instanceof Error ? error.message : String(error);
  console.warn('[onvif-events:v2]', camera.stream_name, 'poll failed', {
    error: message,
    consecutiveFailures: session.consecutiveFailures,
    retryInMs: Math.max(0, session.failedUntil - now)
  });
}

function markOk(session: CameraSession) {
  session.consecutiveFailures = 0;
  session.failedUntil = undefined;
  session.lastOkAt = Date.now();
  session.lastPullAt = Date.now();
}

async function pollCamera(camera: OnvifCamera) {
  const config = cfg();
  const now = Date.now();
  const fp = fingerprint(camera);
  let session = sessions.get(camera.id);

  if (!session || session.fingerprint !== fp) {
    session = { fingerprint: fp, consecutiveFailures: 0 };
    sessions.set(camera.id, session);
    console.log('[onvif-events:v2] session start', {
      version: VERSION,
      stream_name: camera.stream_name,
      xaddr: camera.onvif_xaddr,
      username: cameraCredentials(camera).username || '<anonymous>'
    });
  }

  if (session.inFlight) return;
  if (session.failedUntil && session.failedUntil > now) return;

  const creds = cameraCredentials(camera);
  if (!camera.onvif_xaddr) {
    session.failedUntil = now + 60_000;
    console.warn('[onvif-events:v2] missing onvif_xaddr', camera.stream_name);
    return;
  }

  session.inFlight = true;

  try {
    if (!session.eventXaddr) {
      session.eventXaddr = await getEventServiceXaddr(camera, creds.username, creds.password);
      console.log('[onvif-events:v2] event service resolved', {
        stream_name: camera.stream_name,
        eventXaddr: session.eventXaddr
      });
    }

    if (
      !session.pullPoint ||
      !session.pullPointCreatedAt ||
      now - session.pullPointCreatedAt > config.subscribeTtlMs
    ) {
      session.pullPoint = await createPullPoint(session.eventXaddr, creds.username, creds.password);
      session.pullPointCreatedAt = Date.now();
      console.log('[onvif-events:v2] pullpoint created', {
        stream_name: camera.stream_name,
        pullPoint: session.pullPoint,
        ttlMs: config.subscribeTtlMs
      });
    }

    const messages = await pullMessages(session.pullPoint, creds.username, creds.password);
    const events = mapEvents(camera, messages);

    markOk(session);

    if (events.length) {
      let inserted = 0;
      for (const event of events) {
        const result = await backendPostEvent(event);
        if (result.inserted) inserted++;
      }
      session.lastEventAt = events[events.length - 1].occurred_at;
      console.log('[onvif-events:v2] stored events', {
        stream_name: camera.stream_name,
        events: events.length,
        inserted,
        lastEventAt: session.lastEventAt
      });
    } else if (!session.lastLogAt || now - session.lastLogAt > config.quietLogMs) {
      session.lastLogAt = now;
      console.log('[onvif-events:v2] poll ok', {
        stream_name: camera.stream_name,
        lastEventAt: session.lastEventAt || null,
        pullPointAgeMs: session.pullPointCreatedAt ? now - session.pullPointCreatedAt : null
      });
    }
  } catch (error) {
    markFailure(camera, session, error);
  } finally {
    session.inFlight = false;
    sessions.set(camera.id, session);
  }
}

async function fetchCameras(): Promise<OnvifCamera[]> {
  const data = await backendGet('/api/internal/cameras/onvif');
  return Array.isArray(data.items) ? data.items as OnvifCamera[] : [];
}

async function runLimited<T>(items: T[], limit: number, worker: (item: T) => Promise<void>) {
  let nextIndex = 0;
  const workerCount = Math.min(Math.max(limit, 1), items.length);
  const failures: unknown[] = [];

  await Promise.all(Array.from({ length: workerCount }, async () => {
    while (nextIndex < items.length) {
      const item = items[nextIndex++];
      try {
        await worker(item);
      } catch (error) {
        failures.push(error);
      }
    }
  }));

  return failures;
}

async function tick() {
  if (running) return;
  running = true;

  try {
    const config = cfg();
    if (!config.enabled) return;

    if (!config.secret) {
      console.warn('[onvif-events:v2] INTERNAL_DVR_SECRET empty, disabled');
      return;
    }

    const allCameras = await fetchCameras();
    const skippedCameras = allCameras.filter((camera) => config.skipStreams.has(camera.stream_name));
    const cameras = allCameras.filter((camera) => !config.skipStreams.has(camera.stream_name));

    if (skippedCameras.length && Date.now() - lastSkipLogAt > config.quietLogMs) {
      lastSkipLogAt = Date.now();
      console.log('[onvif-events:v2] skipped streams', {
        streams: skippedCameras.map((camera) => camera.stream_name),
        count: skippedCameras.length
      });
    }

    const ids = new Set(cameras.map((camera) => camera.id));

    for (const id of Array.from(sessions.keys())) {
      if (!ids.has(id)) {
        sessions.delete(id);
        console.log('[onvif-events:v2] session removed', { camera_id: id });
      }
    }

    const failures = await runLimited(cameras, config.concurrency, pollCamera);

    if (Date.now() - lastSyncLogAt > config.syncLogMs || failures.length) {
      lastSyncLogAt = Date.now();
      console.log('[onvif-events:v2] sync', {
        version: VERSION,
        nodeId: dvrConfig.nodeId,
        allCameras: allCameras.length,
        cameras: cameras.length,
        skipped: skippedCameras.length,
        sessions: sessions.size,
        ok: Array.from(sessions.values()).filter((s) => s.lastOkAt && (!s.failedUntil || s.failedUntil < Date.now())).length,
        concurrency: config.concurrency,
        failures: failures.length
      });
    }
  } catch (error) {
    console.error('[onvif-events:v2] sync failed', error instanceof Error ? error.message : error);
  } finally {
    running = false;
  }
}

export function startOnvifEventCollectorV2() {
  const config = cfg();

  if (!config.enabled) {
    console.log('[onvif-events:v2] disabled');
    return;
  }

  if (!config.secret) {
    console.warn('[onvif-events:v2] INTERNAL_DVR_SECRET empty, disabled');
    return;
  }

  if (timer) return;

  console.log('[onvif-events:v2] enabled', {
    version: VERSION,
    intervalMs: config.intervalMs,
    pullTimeout: config.pullTimeout,
    pullLimit: config.pullLimit,
    subscribeTtlMs: config.subscribeTtlMs,
    concurrency: config.concurrency,
    skipStreams: Array.from(config.skipStreams)
  });

  setTimeout(() => tick().catch(() => undefined), 1000);
  timer = setInterval(() => tick().catch(() => undefined), config.intervalMs);
}
