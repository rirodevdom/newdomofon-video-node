import { createHash, randomBytes } from 'node:crypto';

export type HikvisionDiscoverInput = {
  host: string;
  port?: number;
  username?: string;
  password?: string;
  rtspPort?: number;
  rtsp_port?: number;
};

export type HikvisionDiscoveredChannel = {
  id: string;
  channel_number: number;
  channel_name: string;
  name: string;
  source_url: string;
  source_protocol: 'HIKVISION_ISAPI';
  is_auto_discovered: true;
  stream_kind: 'main' | 'sub' | 'other';
  enabled: boolean | null;
};

type DeviceInfo = {
  deviceName?: string | null;
  deviceID?: string | null;
  model?: string | null;
  serialNumber?: string | null;
  firmwareVersion?: string | null;
  macAddress?: string | null;
};

type DigestChallenge = Record<string, string>;

function md5(value: string) {
  return createHash('md5').update(value).digest('hex');
}

function parseDigestChallenge(header: string): DigestChallenge {
  const value = header.replace(/^Digest\s+/i, '');
  const result: DigestChallenge = {};
  const regex = /([a-zA-Z0-9_-]+)=(?:"([^"]*)"|([^,]*))/g;
  let match: RegExpExecArray | null;
  while ((match = regex.exec(value))) {
    result[match[1].toLowerCase()] = match[2] ?? match[3] ?? '';
  }
  return result;
}

function buildDigestAuthorization(challenge: DigestChallenge, method: string, url: URL, username: string, password: string) {
  const realm = challenge.realm || '';
  const nonce = challenge.nonce || '';
  const qop = (challenge.qop || '').split(',').map((item) => item.trim()).filter(Boolean).includes('auth') ? 'auth' : '';
  const opaque = challenge.opaque;
  const algorithm = challenge.algorithm || 'MD5';
  const uri = `${url.pathname}${url.search}`;
  const nc = '00000001';
  const cnonce = randomBytes(8).toString('hex');

  if (!nonce || !realm) throw new Error('Invalid digest authentication challenge from Hikvision device');
  if (!/^MD5$/i.test(algorithm)) throw new Error(`Unsupported Hikvision digest algorithm: ${algorithm}`);

  const ha1 = md5(`${username}:${realm}:${password}`);
  const ha2 = md5(`${method}:${uri}`);
  const response = qop ? md5(`${ha1}:${nonce}:${nc}:${cnonce}:${qop}:${ha2}`) : md5(`${ha1}:${nonce}:${ha2}`);

  const parts = [
    `username="${username.replace(/"/g, '\\"')}"`,
    `realm="${realm.replace(/"/g, '\\"')}"`,
    `nonce="${nonce.replace(/"/g, '\\"')}"`,
    `uri="${uri}"`,
    `response="${response}"`,
    `algorithm=${algorithm}`
  ];
  if (opaque) parts.push(`opaque="${opaque.replace(/"/g, '\\"')}"`);
  if (qop) parts.push(`qop=${qop}`, `nc=${nc}`, `cnonce="${cnonce}"`);
  return `Digest ${parts.join(', ')}`;
}

function basicAuthorization(username?: string, password?: string) {
  if (!username) return null;
  return `Basic ${Buffer.from(`${username}:${password || ''}`).toString('base64')}`;
}

function normalizeBaseUrls(input: HikvisionDiscoverInput) {
  const rawHost = String(input.host || '').trim().replace(/\/+$/, '');
  if (!rawHost) throw new Error('Hikvision host is not configured');

  const result: URL[] = [];
  const seen = new Set<string>();
  const add = (value: string) => {
    try {
      const url = new URL(value.replace(/\/+$/, ''));
      const key = `${url.protocol}//${url.hostname}:${url.port || (url.protocol === 'https:' ? '443' : '80')}`;
      if (!seen.has(key)) {
        seen.add(key);
        result.push(url);
      }
    } catch {
      // ignore malformed fallback variants; a final empty list will be handled below
    }
  };

  if (/^https?:\/\//i.test(rawHost)) {
    add(rawHost);
    return result;
  }

  const port = input.port ? Number(input.port) : 0;
  if (port > 0) {
    if (port === 443) {
      add(`https://${rawHost}:443`);
      add(`http://${rawHost}:80`);
    } else {
      add(`http://${rawHost}:${port}`);
      if (port !== 80) add(`http://${rawHost}:80`);
      add(`https://${rawHost}:443`);
    }
  } else {
    add(`http://${rawHost}:80`);
    add(`https://${rawHost}:443`);
  }

  if (!result.length) throw new Error('Unable to build Hikvision ISAPI base URL');
  return result;
}

function normalizeBaseUrl(input: HikvisionDiscoverInput) {
  return normalizeBaseUrls(input)[0];
}

function describeFetchError(error: unknown, url: URL) {
  const err = error as any;
  const cause = err?.cause || err;
  const code = cause?.code || err?.code || err?.name || 'ERROR';
  const message = cause?.message || err?.message || String(error);
  return `${url.toString()} failed: ${code}${message ? ` ${message}` : ''}`;
}

async function fetchOnce(url: URL, headers: Record<string, string>) {
  return await fetch(url, {
    method: 'GET',
    headers: {
      accept: 'application/xml,text/xml,*/*',
      'user-agent': 'NewDomofon-Video-Hikvision-ISAPI/1.0',
      connection: 'close',
      ...headers
    },
    signal: AbortSignal.timeout(Number(process.env.HIKVISION_REQUEST_TIMEOUT_MS || 12000))
  });
}

async function hikvisionGet(base: URL, path: string, username?: string, password?: string): Promise<{ status: number; text: string; url: string }> {
  const url = new URL(path, base);
  let response: Response;

  try {
    // Do not send Basic preemptively. Many Hikvision devices prefer Digest and first answer with WWW-Authenticate.
    response = await fetchOnce(url, {});
  } catch (error) {
    const basic = basicAuthorization(username, password);
    if (!basic) throw new Error(describeFetchError(error, url));

    // Some older devices/proxies reset anonymous requests. Retry once with Basic before moving to the next URL candidate.
    try {
      response = await fetchOnce(url, { authorization: basic });
    } catch (basicError) {
      throw new Error(`${describeFetchError(error, url)}; basic retry: ${describeFetchError(basicError, url)}`);
    }
  }

  if (response.status === 401 && username) {
    const authHeader = response.headers.get('www-authenticate') || '';
    if (/^Digest\s+/i.test(authHeader)) {
      const digest = buildDigestAuthorization(parseDigestChallenge(authHeader), 'GET', url, username, password || '');
      response = await fetchOnce(url, { authorization: digest });
    } else {
      const basic = basicAuthorization(username, password);
      if (basic) response = await fetchOnce(url, { authorization: basic });
    }
  }

  const text = await response.text();
  if (!response.ok) {
    const preview = text.replace(/\s+/g, ' ').slice(0, 300);
    throw new Error(`Hikvision ISAPI ${url.toString()} HTTP ${response.status}${preview ? `: ${preview}` : ''}`);
  }
  return { status: response.status, text, url: url.toString() };
}

function decodeXml(value: string) {
  return value
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&quot;/g, '"')
    .replace(/&apos;/g, "'")
    .replace(/&amp;/g, '&')
    .trim();
}

function tagValue(xml: string, tag: string): string | null {
  const regex = new RegExp(`<(?:\\w+:)?${tag}\\b[^>]*>([\\s\\S]*?)<\\/(?:\\w+:)?${tag}>`, 'i');
  const match = xml.match(regex);
  return match ? decodeXml(match[1]) : null;
}

function tagBlocks(xml: string, tag: string): string[] {
  const regex = new RegExp(`<(?:\\w+:)?${tag}\\b[^>]*>[\\s\\S]*?<\\/(?:\\w+:)?${tag}>`, 'gi');
  return xml.match(regex) || [];
}

function parseBool(value: string | null): boolean | null {
  if (value == null) return null;
  if (/^(true|1|yes)$/i.test(value.trim())) return true;
  if (/^(false|0|no)$/i.test(value.trim())) return false;
  return null;
}

function streamKindFromId(id: string): 'main' | 'sub' | 'other' {
  if (/01$/.test(id)) return 'main';
  if (/02$/.test(id)) return 'sub';
  return 'other';
}

function channelNumberFromId(id: string) {
  const numeric = Number(id);
  if (Number.isFinite(numeric) && numeric >= 100) return Math.max(1, Math.floor(numeric / 100));
  if (Number.isFinite(numeric) && numeric > 0) return numeric;
  return 1;
}

function rtspUrl(input: HikvisionDiscoverInput, channelId: string, discoveredBase?: URL) {
  const base = discoveredBase || normalizeBaseUrl(input);
  const rtspPort = Number(input.rtspPort || input.rtsp_port || process.env.HIKVISION_DEFAULT_RTSP_PORT || 554);
  const username = encodeURIComponent(String(input.username || ''));
  const password = encodeURIComponent(String(input.password || ''));
  const credentials = input.username ? `${username}:${password}@` : '';
  return `rtsp://${credentials}${base.hostname}:${rtspPort}/Streaming/Channels/${channelId}`;
}

function parseDeviceInfo(xml: string): DeviceInfo {
  return {
    deviceName: tagValue(xml, 'deviceName') || tagValue(xml, 'DeviceName'),
    deviceID: tagValue(xml, 'deviceID') || tagValue(xml, 'deviceId'),
    model: tagValue(xml, 'model') || tagValue(xml, 'Model'),
    serialNumber: tagValue(xml, 'serialNumber') || tagValue(xml, 'SerialNumber'),
    firmwareVersion: tagValue(xml, 'firmwareVersion') || tagValue(xml, 'FirmwareVersion'),
    macAddress: tagValue(xml, 'macAddress') || tagValue(xml, 'MACAddress')
  };
}

function parseStreamingChannels(xml: string, input: HikvisionDiscoverInput, discoveredBase?: URL): HikvisionDiscoveredChannel[] {
  const blocks = tagBlocks(xml, 'StreamingChannel');
  const channels = blocks.map((block) => {
    const id = tagValue(block, 'id') || tagValue(block, 'ID') || '';
    if (!id) return null;
    const channelNumber = channelNumberFromId(id);
    const name = tagValue(block, 'channelName') || tagValue(block, 'name') || `Channel ${channelNumber}`;
    return {
      id,
      channel_number: channelNumber,
      channel_name: name,
      name,
      source_url: rtspUrl(input, id, discoveredBase),
      source_protocol: 'HIKVISION_ISAPI' as const,
      is_auto_discovered: true as const,
      stream_kind: streamKindFromId(id),
      enabled: parseBool(tagValue(block, 'enabled'))
    };
  }).filter((item): item is HikvisionDiscoveredChannel => Boolean(item));

  const enabled = channels.filter((channel) => channel.enabled !== false);
  const usable = enabled.length ? enabled : channels;
  const main = usable.filter((channel) => channel.stream_kind === 'main');
  return main.length ? main : usable;
}

function parseVideoInputChannels(xml: string, input: HikvisionDiscoverInput, discoveredBase?: URL): HikvisionDiscoveredChannel[] {
  const blocks = tagBlocks(xml, 'VideoInputChannel');
  return blocks.map((block) => {
    const rawId = tagValue(block, 'id') || tagValue(block, 'videoInputChannelID') || tagValue(block, 'ID') || '';
    if (!rawId) return null;
    const channelNumber = channelNumberFromId(rawId);
    const streamingId = Number(rawId) < 100 ? `${Number(rawId)}01` : rawId;
    const name = tagValue(block, 'name') || tagValue(block, 'channelName') || `Channel ${channelNumber}`;
    return {
      id: streamingId,
      channel_number: channelNumber,
      channel_name: name,
      name,
      source_url: rtspUrl(input, streamingId, discoveredBase),
      source_protocol: 'HIKVISION_ISAPI' as const,
      is_auto_discovered: true as const,
      stream_kind: streamKindFromId(streamingId),
      enabled: parseBool(tagValue(block, 'enabled'))
    };
  }).filter((item): item is HikvisionDiscoveredChannel => Boolean(item));
}

export async function discoverHikvisionChannels(input: HikvisionDiscoverInput) {
  const bases = normalizeBaseUrls(input);
  const errors: string[] = [];

  for (const base of bases) {
    let information: DeviceInfo | null = null;
    try {
      information = parseDeviceInfo((await hikvisionGet(base, '/ISAPI/System/deviceInfo', input.username, input.password)).text);
    } catch (error) {
      // Some devices allow channel APIs while deviceInfo is disabled for the user.
      information = { deviceName: null, model: null, serialNumber: null, firmwareVersion: null, macAddress: null };
      errors.push(`deviceInfo via ${base.toString()}: ${(error as Error).message}`);
    }

    let channels: HikvisionDiscoveredChannel[] = [];
    let discoveryPath = '/ISAPI/Streaming/channels';
    try {
      const streaming = await hikvisionGet(base, discoveryPath, input.username, input.password);
      channels = parseStreamingChannels(streaming.text, input, base);
    } catch (streamingError) {
      errors.push(`streamingChannels via ${base.toString()}: ${(streamingError as Error).message}`);
      discoveryPath = '/ISAPI/System/Video/inputs/channels';
      try {
        const inputs = await hikvisionGet(base, discoveryPath, input.username, input.password);
        channels = parseVideoInputChannels(inputs.text, input, base);
      } catch (inputsError) {
        errors.push(`videoInputs via ${base.toString()}: ${(inputsError as Error).message}`);
        continue;
      }
    }

    if (channels.length) {
      return {
        information,
        discoveryBaseUrl: base.toString(),
        discoveryPath,
        channels
      };
    }
    errors.push(`no usable video channels via ${base.toString()}`);
  }

  throw new Error([
    'Hikvision ISAPI discovery failed.',
    'Check that the device port is the HTTP/HTTPS ISAPI port, usually 80 or 443, not RTSP 554 and not SDK 8000.',
    `Tried: ${bases.map((base) => base.toString()).join(', ')}`,
    `Details: ${errors.slice(-6).join(' | ')}`
  ].join(' '));
}
