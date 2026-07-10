import crypto from 'node:crypto';
import { XMLParser } from 'fast-xml-parser';
import { appendLocalEvent } from './localEventStore.js';
import { loadAssignedCameras } from './nodeClient.js';
import type { CameraConfig } from './types.js';

interface HikCamera {
  id: string;
  name: string;
  stream_name: string;
  source_url: string;
}

interface HikDevice {
  id: string;
  name: string;
  host: string;
  port: number;
  username: string;
  password: string;
  cameras: HikCamera[];
}

interface DeviceSession {
  abort: AbortController;
  key: string;
}

const parser = new XMLParser({ ignoreAttributes: false, attributeNamePrefix: '@_' });
const sessions = new Map<string, DeviceSession>();

function enabled(): boolean {
  return ['1', 'true', 'yes', 'on'].includes(String(process.env.DVR_HIKVISION_EVENTS_ENABLED || '').toLowerCase());
}

function md5(value: string) {
  return crypto.createHash('md5').update(value).digest('hex');
}

function parseDigest(header: string) {
  const out: Record<string, string> = {};
  for (const part of header.replace(/^Digest\s+/i, '').split(',')) {
    const idx = part.indexOf('=');
    if (idx <= 0) continue;
    const key = part.slice(0, idx).trim();
    out[key] = part.slice(idx + 1).trim().replace(/^"|"$/g, '');
  }
  return out;
}

function digestHeader(method: string, uri: string, wwwAuth: string, username: string, password: string) {
  const challenge = parseDigest(wwwAuth);
  const realm = challenge.realm || '';
  const nonce = challenge.nonce || '';
  const qop = (challenge.qop || '').split(',').map((item) => item.trim()).find((item) => item === 'auth');
  const nc = '00000001';
  const cnonce = crypto.randomBytes(8).toString('hex');
  const ha1 = md5(`${username}:${realm}:${password}`);
  const ha2 = md5(`${method}:${uri}`);
  const response = qop ? md5(`${ha1}:${nonce}:${nc}:${cnonce}:${qop}:${ha2}`) : md5(`${ha1}:${nonce}:${ha2}`);
  const parts = [
    `username="${username}"`,
    `realm="${realm}"`,
    `nonce="${nonce}"`,
    `uri="${uri}"`,
    `response="${response}"`,
    challenge.algorithm ? `algorithm=${challenge.algorithm}` : 'algorithm=MD5'
  ];
  if (qop) parts.push(`qop=${qop}`, `nc=${nc}`, `cnonce="${cnonce}"`);
  return `Digest ${parts.join(', ')}`;
}

async function openAlertStream(device: HikDevice, signal: AbortSignal) {
  const host = device.host.replace(/^https?:\/\//i, '').replace(/\/.*$/, '');
  const port = Number(device.port || 80);
  const base = `http://${host}:${port}`;
  const uri = '/ISAPI/Event/notification/alertStream';
  const url = `${base}${uri}`;
  const first = await fetch(url, { signal });
  if (first.status !== 401) return first;
  const wwwAuth = first.headers.get('www-authenticate') || '';
  if (/^Digest/i.test(wwwAuth)) {
    return await fetch(url, {
      signal,
      headers: { authorization: digestHeader('GET', uri, wwwAuth, device.username, device.password) }
    });
  }
  const basic = Buffer.from(`${device.username}:${device.password}`).toString('base64');
  return await fetch(url, { signal, headers: { authorization: `Basic ${basic}` } });
}

function trackToChannel(camera: HikCamera): string | null {
  const match = String(camera.source_url || camera.stream_name || camera.name).match(/\/Streaming\/(?:channels|tracks)\/(\d+)/i)
    || String(camera.name || camera.stream_name).match(/\b(\d{3,4})\b/);
  if (!match) return null;
  return String(Math.floor(Number(match[1]) / 100));
}

function findText(value: unknown, keys: string[]): string {
  if (!value || typeof value !== 'object') return '';
  if (Array.isArray(value)) {
    for (const item of value) {
      const found = findText(item, keys);
      if (found) return found;
    }
    return '';
  }
  const obj = value as Record<string, unknown>;
  for (const key of keys) {
    const exact = obj[key];
    if (exact != null && typeof exact !== 'object') return String(exact);
  }
  for (const item of Object.values(obj)) {
    const found = findText(item, keys);
    if (found) return found;
  }
  return '';
}

async function storeEvent(camera: HikCamera, event: Record<string, unknown>) {
  return appendLocalEvent({
    camera_id: camera.id,
    stream_name: camera.stream_name,
    event_type: String(event.eventType || event.topic || 'hikvision.event'),
    event_state: event.eventState ? String(event.eventState) : null,
    topic: String(event.eventType || event.topic || 'hikvision.event'),
    source_name: 'hikvision.alertStream',
    occurred_at: String(event.dateTime || new Date().toISOString()),
    data: event
  });
}

async function runDevice(device: HikDevice, abort: AbortController) {
  const byChannel = new Map<string, HikCamera>();
  for (const camera of device.cameras) {
    const channel = trackToChannel(camera);
    if (channel) byChannel.set(channel, camera);
  }

  while (!abort.signal.aborted) {
    try {
      const response = await openAlertStream(device, abort.signal);
      if (!response.ok || !response.body) throw new Error(`alertStream HTTP ${response.status}`);
      const reader = response.body.getReader();
      const decoder = new TextDecoder();
      let buffer = '';
      while (!abort.signal.aborted) {
        const { done, value } = await reader.read();
        if (done) break;
        buffer += decoder.decode(value, { stream: true });
        let match: RegExpMatchArray | null;
        const regex = /<EventNotificationAlert[\s\S]*?<\/EventNotificationAlert>/;
        while ((match = buffer.match(regex))) {
          buffer = buffer.slice((match.index || 0) + match[0].length);
          const parsed = parser.parse(match[0]);
          const root = parsed.EventNotificationAlert || parsed;
          const channelID = findText(root, ['channelID', 'dynChannelID', 'channel']);
          const camera = byChannel.get(String(Number(channelID || 0))) || byChannel.get(String(channelID || ''));
          if (!camera) continue;
          await storeEvent(camera, {
            source: 'hikvision.alertStream',
            device_id: device.id,
            device_name: device.name,
            channelID,
            eventType: findText(root, ['eventType']) || 'hikvision.event',
            eventState: findText(root, ['eventState']),
            dateTime: findText(root, ['dateTime']) || new Date().toISOString(),
            raw: root
          }).catch((error) => console.warn('[hikvision-events] store failed', error instanceof Error ? error.message : error));
        }
        if (buffer.length > 1024 * 1024) buffer = buffer.slice(-64 * 1024);
      }
    } catch (error) {
      if (!abort.signal.aborted) console.warn('[hikvision-events] stream failed', device.name, error instanceof Error ? error.message : error);
    }
    if (!abort.signal.aborted) await new Promise((resolve) => setTimeout(resolve, 5000));
  }
}

function buildAssignedDevices(cameras: CameraConfig[]): HikDevice[] {
  const devices = new Map<string, HikDevice>();

  for (const camera of cameras) {
    if (camera.is_enabled === false) continue;
    if (String(camera.device_connection_type || '').toUpperCase() !== 'HIKVISION') continue;
    if (!camera.device_id || !camera.device_host) continue;

    let device = devices.get(camera.device_id);
    if (!device) {
      device = {
        id: camera.device_id,
        name: String(camera.device_host),
        host: camera.device_host,
        port: Number(camera.device_port || 80),
        username: String(camera.device_username || ''),
        password: String(camera.device_password || ''),
        cameras: []
      };
      devices.set(camera.device_id, device);
    }

    device.cameras.push({
      id: camera.id,
      name: camera.name,
      stream_name: camera.stream_name,
      source_url: camera.source_url
    });
  }

  return Array.from(devices.values());
}

async function syncDevices() {
  if (!enabled()) return;
  const devices = buildAssignedDevices(await loadAssignedCameras());
  const wanted = new Set(devices.map((device) => device.id));

  for (const [id, session] of sessions) {
    if (!wanted.has(id)) {
      session.abort.abort();
      sessions.delete(id);
    }
  }

  for (const device of devices) {
    const key = JSON.stringify(device);
    const existing = sessions.get(device.id);
    if (existing?.key === key) continue;
    if (existing) existing.abort.abort();
    const abort = new AbortController();
    sessions.set(device.id, { abort, key });
    void runDevice(device, abort);
  }
}

export function startHikvisionEventCollector() {
  if (!enabled()) {
    console.log('[hikvision-events] disabled');
    return;
  }
  console.log('[hikvision-events] enabled');
  syncDevices().catch((error) => console.warn('[hikvision-events] sync failed', error instanceof Error ? error.message : error));
  setInterval(() => syncDevices().catch((error) => console.warn('[hikvision-events] sync failed', error instanceof Error ? error.message : error)), 60_000);
}
