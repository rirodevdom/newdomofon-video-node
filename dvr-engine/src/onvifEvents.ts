import crypto from 'node:crypto';
import { XMLParser } from 'fast-xml-parser';

interface OnvifCamera {
  id: string;
  name: string;
  stream_name: string;
  source_url: string;
  onvif_xaddr: string;
  onvif_port?: number | null;
  onvif_username?: string | null;
}

interface CameraSession {
  eventXaddr?: string;
  pullPoint?: string;
  failedUntil?: number;
  lastEventAt?: string;
}

const parser = new XMLParser({
  ignoreAttributes: false,
  attributeNamePrefix: '@_',
  textNodeName: '#text',
  removeNSPrefix: true
});

const sessions = new Map<string, CameraSession>();
let running = false;

function cfg() {
  return {
    enabled: String(process.env.EVENTS_ENABLED || 'true').toLowerCase() !== 'false',
    backendUrl: (process.env.BACKEND_INTERNAL_URL || 'http://127.0.0.1:3000').replace(/\/+$/, ''),
    secret: process.env.INTERNAL_DVR_SECRET || '',
    intervalMs: Math.max(Number(process.env.EVENT_POLL_INTERVAL_MS || 5000), 2000),
    pullTimeout: process.env.ONVIF_PULL_TIMEOUT || 'PT5S',
    pullLimit: Math.max(Number(process.env.ONVIF_PULL_LIMIT || 20), 1)
  };
}

function nowIso() {
  return new Date().toISOString();
}

function credentialsFromRtsp(uri: string) {
  try {
    const url = new URL(uri);
    return {
      username: decodeURIComponent(url.username || ''),
      password: decodeURIComponent(url.password || '')
    };
  } catch {
    return { username: '', password: '' };
  }
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

function escapeXml(value: string) {
  return value
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&apos;');
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

  const response = await fetch(url, {
    method: 'POST',
    headers: {
      'content-type': 'application/soap+xml; charset=utf-8',
      'soapaction': action
    },
    body: envelope
  });

  const text = await response.text();

  if (!response.ok) {
    throw new Error(`SOAP ${action} failed HTTP ${response.status}: ${text.slice(0, 300)}`);
  }

  return {
    text,
    json: parser.parse(text)
  };
}

function deepValues(value: any, predicate: (key: string, value: any) => boolean, parentKey = ''): any[] {
  const results: any[] = [];
  if (!value || typeof value !== 'object') return results;

  if (Array.isArray(value)) {
    for (const item of value) results.push(...deepValues(item, predicate, parentKey));
    return results;
  }

  for (const [key, item] of Object.entries(value)) {
    if (predicate(key, item)) results.push(item);
    if (item && typeof item === 'object') results.push(...deepValues(item, predicate, key));
  }

  return results;
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

function firstString(value: any, keys: string[]): string | null {
  if (!value || typeof value !== 'object') return null;

  if (Array.isArray(value)) {
    for (const item of value) {
      const found = firstString(item, keys);
      if (found) return found;
    }
    return null;
  }

  for (const [key, item] of Object.entries(value)) {
    if (keys.includes(key) && typeof item === 'string') return item;
    if (item && typeof item === 'object') {
      const found = firstString(item, keys);
      if (found) return found;
    }
  }

  return null;
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

async function pullMessages(pullPoint: string, username: string, password: string, timeout: string, limit: number) {
  const result = await soapRequest(
    pullPoint,
    'http://www.onvif.org/ver10/events/wsdl/PullPointSubscription/PullMessagesRequest',
    `<tev:PullMessages><tev:Timeout>${escapeXml(timeout)}</tev:Timeout><tev:MessageLimit>${limit}</tev:MessageLimit></tev:PullMessages>`,
    username,
    password
  );

  return result.json;
}

function collectNotifications(xml: any): any[] {
  const values = deepValues(xml, (key, value) => key === 'NotificationMessage' && typeof value === 'object');
  return values.flatMap((item) => Array.isArray(item) ? item : [item]);
}

function simpleItems(value: any): Record<string, string> {
  const items = deepValues(value, (key, item) => key === 'SimpleItem' && typeof item === 'object')
    .flatMap((item) => Array.isArray(item) ? item : [item]);

  const out: Record<string, string> = {};

  for (const item of items) {
    const name = item['@_Name'] || item.Name || item.name;
    const val = item['@_Value'] || item.Value || item.value;
    if (name !== undefined && val !== undefined) out[String(name)] = String(val);
  }

  return out;
}

function topicFromNotification(notification: any): string {
  const topic = firstString(notification, ['Topic']);
  if (topic) return topic.replace(/\s+/g, ' ').trim();
  return 'unknown';
}

function eventTypeFromTopic(topic: string) {
  const parts = topic.split(/[/:|]/).filter(Boolean);
  return parts[parts.length - 1] || topic || 'unknown';
}

function eventState(items: Record<string, string>) {
  const keys = ['State', 'IsMotion', 'LogicalState', 'Active', 'Motion', 'Value'];
  for (const key of keys) {
    if (items[key] !== undefined) return String(items[key]);
  }
  return null;
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
    const items = simpleItems(notification);

    return {
      camera_id: camera.id,
      stream_name: camera.stream_name,
      event_type: eventTypeFromTopic(topic),
      event_state: eventState(items),
      topic,
      source_name: sourceName(items),
      occurred_at: occurredAt(notification),
      data: {
        simpleItems: items,
        raw: notification
      }
    };
  });
}

async function backendGet(path: string) {
  const { backendUrl, secret } = cfg();
  const response = await fetch(`${backendUrl}${path}`, {
    headers: { 'x-internal-secret': secret }
  });

  if (!response.ok) throw new Error(`Backend GET ${path} failed HTTP ${response.status}`);
  return response.json();
}

async function backendPost(path: string, body: unknown) {
  const { backendUrl, secret } = cfg();
  const response = await fetch(`${backendUrl}${path}`, {
    method: 'POST',
    headers: {
      'content-type': 'application/json',
      'x-internal-secret': secret
    },
    body: JSON.stringify(body)
  });

  if (!response.ok) {
    const text = await response.text();
    throw new Error(`Backend POST ${path} failed HTTP ${response.status}: ${text.slice(0, 300)}`);
  }

  return response.json();
}

async function pollCamera(camera: OnvifCamera) {
  const session = sessions.get(camera.id) || {};
  const now = Date.now();

  if (session.failedUntil && session.failedUntil > now) return;

  const rtspCreds = credentialsFromRtsp(camera.source_url || '');
  const username = camera.onvif_username || rtspCreds.username;
  const password = rtspCreds.password;

  if (!camera.onvif_xaddr || !username || !password) {
    session.failedUntil = now + 60_000;
    sessions.set(camera.id, session);
    console.warn(`[onvif-events:${camera.stream_name}] missing onvif_xaddr or credentials`);
    return;
  }

  try {
    if (!session.eventXaddr) {
      session.eventXaddr = await getEventServiceXaddr(camera, username, password);
    }

    if (!session.pullPoint) {
      session.pullPoint = await createPullPoint(session.eventXaddr, username, password);
    }

    const messages = await pullMessages(session.pullPoint, username, password, cfg().pullTimeout, cfg().pullLimit);
    const events = mapEvents(camera, messages);

    if (events.length) {
      await backendPost('/api/internal/events/onvif', { events });
      session.lastEventAt = events[events.length - 1].occurred_at;
      console.log(`[onvif-events:${camera.stream_name}] stored ${events.length} events`);
    }

    sessions.set(camera.id, session);
  } catch (error: any) {
    console.warn(`[onvif-events:${camera.stream_name}] ${error?.message || error}`);
    sessions.set(camera.id, {
      ...session,
      pullPoint: undefined,
      failedUntil: now + 30_000
    });
  }
}

async function tick() {
  if (running) return;
  running = true;

  try {
    const config = cfg();
    if (!config.enabled) return;
    if (!config.secret) {
      console.warn('[onvif-events] INTERNAL_DVR_SECRET is missing');
      return;
    }

    const data = await backendGet('/api/internal/cameras/onvif');
    const cameras = Array.isArray(data.items) ? data.items as OnvifCamera[] : [];

    await Promise.allSettled(cameras.map((camera) => pollCamera(camera)));
  } catch (error: any) {
    console.warn(`[onvif-events] ${error?.message || error}`);
  } finally {
    running = false;
  }
}

export function startOnvifEventCollector() {
  const config = cfg();

  if (!config.enabled) {
    console.log('[onvif-events] disabled');
    return;
  }

  console.log(`[onvif-events] enabled, interval=${config.intervalMs}ms`);
  setTimeout(() => tick().catch(() => undefined), 5000);
  setInterval(() => tick().catch(() => undefined), config.intervalMs);
}
