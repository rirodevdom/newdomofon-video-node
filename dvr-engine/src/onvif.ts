import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const onvif: any = require('node-onvif');

export interface ConnectOnvifInput {
  ip: string;
  port?: number;
  username?: string;
  password?: string;
}

function cleanHost(value: string): string {
  const raw = String(value || '').trim();
  if (!raw) throw new Error('Camera IP is required');
  if (/^https?:\/\//i.test(raw)) return new URL(raw).hostname;
  return raw.replace(/^\/+/, '').replace(/\/onvif\/device_service.*$/i, '').replace(/:\d+$/, '').replace(/\/+$/, '');
}

function cleanPort(value: unknown): number {
  const port = Number(value || 80);
  if (!Number.isInteger(port) || port < 1 || port > 65535) throw new Error('Invalid ONVIF port');
  return port;
}

function xaddr(ip: string, port: number): string {
  return `http://${cleanHost(ip)}:${cleanPort(port)}/onvif/device_service`;
}

function findRtsp(value: unknown): string | null {
  if (!value || typeof value !== 'object') return null;
  if (Array.isArray(value)) {
    for (const item of value) {
      const found = findRtsp(item);
      if (found) return found;
    }
    return null;
  }
  for (const [key, item] of Object.entries(value as Record<string, unknown>)) {
    if (key.toLowerCase() === 'uri' && typeof item === 'string' && /^rtsp:\/\//i.test(item)) return item;
    const found = findRtsp(item);
    if (found) return found;
  }
  return null;
}

function addCreds(uri: string, username?: string, password?: string): string {
  if (!username || !password) return uri;
  try {
    const url = new URL(uri);
    if (url.protocol !== 'rtsp:' || url.username || url.password) return uri;
    url.username = username;
    url.password = password;
    return url.toString();
  } catch {
    return uri;
  }
}

function profileToken(profile: any): string {
  return profile?.token || profile?.Token || profile?.$.token || '';
}

export async function connectOnvifCamera(input: ConnectOnvifInput) {
  const ip = cleanHost(input.ip);
  const port = cleanPort(input.port);
  const deviceXaddr = xaddr(ip, port);

  const device = new onvif.OnvifDevice({
    xaddr: deviceXaddr,
    user: input.username || '',
    pass: input.password || ''
  });

  await device.init();

  let information: unknown = null;
  try { information = await device.getInformation(); } catch { information = null; }

  const profiles = typeof device.getProfileList === 'function' ? (device.getProfileList() || []) : [];
  if (!profiles.length) throw new Error('ONVIF camera returned no media profiles');

  const token = profileToken(profiles[0]);
  if (token && typeof device.changeProfile === 'function') device.changeProfile(token);

  let streamUri = '';
  if (device.services?.media?.getStreamUri) {
    try {
      const result = await device.services.media.getStreamUri({ ProfileToken: token, Protocol: 'RTSP' });
      streamUri = findRtsp(result?.data) || findRtsp(result) || '';
    } catch {
      streamUri = '';
    }
  }
  if (!streamUri && typeof device.getUdpStreamUrl === 'function') streamUri = device.getUdpStreamUrl() || '';
  if (!streamUri) throw new Error('ONVIF camera did not return RTSP stream URI');

  return {
    ip,
    port,
    xaddr: deviceXaddr,
    streamUri: addCreds(streamUri, input.username, input.password),
    selectedProfileToken: token || null,
    information
  };
}
