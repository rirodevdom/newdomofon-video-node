import crypto from 'node:crypto';
import { XMLParser } from 'fast-xml-parser';
import type { CameraConfig } from './types.js';

export type HikvisionArchiveItem = {
  start: string;
  end: string;
  playbackUri: string;
  trackId: string;
  source: 'hikvision-isapi';
};

export type HikvisionPlaybackCandidate = {
  url: string;
  source: 'hikvision-isapi' | 'fallback-rtsp';
  trackId: string | null;
};

const parser = new XMLParser({
  ignoreAttributes: false,
  attributeNamePrefix: '@_',
  removeNSPrefix: true,
  trimValues: true
});

const searchCache = new Map<string, {
  expiresAt: number;
  cameraId: string;
  trackIdsKey: string;
  startMs: number;
  endMs: number;
  items: HikvisionArchiveItem[];
}>();
const inFlightSearches = new Map<string, Promise<HikvisionArchiveItem[]>>();
const cacheTtlMs = Math.max(5_000, Number(process.env.DVR_HIKVISION_ARCHIVE_SEARCH_CACHE_MS || 2 * 60 * 60_000));
const searchTimeoutMs = Math.max(2_000, Number(process.env.DVR_HIKVISION_ARCHIVE_SEARCH_TIMEOUT_MS || 10_000));
const searchPageSize = Math.max(1, Math.min(256, Number(process.env.DVR_HIKVISION_ARCHIVE_SEARCH_PAGE_SIZE || 64)));
const searchMaxPages = Math.max(1, Math.min(200, Number(process.env.DVR_HIKVISION_ARCHIVE_SEARCH_MAX_PAGES || 80)));
const futureSkewMs = Math.max(0, Number(process.env.DVR_DEVICE_ARCHIVE_FUTURE_SKEW_SECONDS || 60) * 1000);
const allowRtspFallback = !['0', 'false', 'no', 'off'].includes(String(process.env.DVR_HIKVISION_ARCHIVE_RTSP_FALLBACK || '1').toLowerCase());
const preferRtspFallback = ['1', 'true', 'yes', 'on'].includes(String(process.env.DVR_HIKVISION_ARCHIVE_PREFER_FALLBACK_RTSP || '1').toLowerCase());
const fallbackOnEmptyRange = ['1', 'true', 'yes', 'on'].includes(String(process.env.DVR_HIKVISION_ARCHIVE_FALLBACK_ON_EMPTY || '').toLowerCase());

export class DeviceArchiveRangeError extends Error {
  statusCode = 404;
  code = 'DEVICE_ARCHIVE_RANGE_NOT_FOUND';
}

function md5(input: string): string {
  return crypto.createHash('md5').update(input).digest('hex');
}

function parseDigestHeader(header: string): Record<string, string> {
  const source = header.replace(/^Digest\s+/i, '');
  const result: Record<string, string> = {};
  for (const part of source.match(/(?:[^,"]+|"[^"]*")+/g) || []) {
    const idx = part.indexOf('=');
    if (idx < 0) continue;
    const key = part.slice(0, idx).trim();
    const value = part.slice(idx + 1).trim().replace(/^"|"$/g, '');
    result[key] = value;
  }
  return result;
}

function digestAuthHeader(params: Record<string, string>, method: string, uri: string, username: string, password: string): string {
  const realm = params.realm || '';
  const nonce = params.nonce || '';
  const qop = (params.qop || 'auth').split(',').map((item) => item.trim()).find((item) => item === 'auth') || '';
  const opaque = params.opaque;
  const algorithm = (params.algorithm || 'MD5').toUpperCase();
  const cnonce = crypto.randomBytes(8).toString('hex');
  const nc = '00000001';
  const ha1 = algorithm === 'MD5-SESS'
    ? md5(`${md5(`${username}:${realm}:${password}`)}:${nonce}:${cnonce}`)
    : md5(`${username}:${realm}:${password}`);
  const ha2 = md5(`${method}:${uri}`);
  const response = qop ? md5(`${ha1}:${nonce}:${nc}:${cnonce}:${qop}:${ha2}`) : md5(`${ha1}:${nonce}:${ha2}`);
  const parts = [
    `username="${username}"`,
    `realm="${realm}"`,
    `nonce="${nonce}"`,
    `uri="${uri}"`,
    `response="${response}"`,
    `algorithm=${algorithm}`
  ];
  if (opaque) parts.push(`opaque="${opaque}"`);
  if (qop) parts.push(`qop=${qop}`, `nc=${nc}`, `cnonce="${cnonce}"`);
  return `Digest ${parts.join(', ')}`;
}

function formatHikvisionTime(date: Date): string {
  return date.toISOString().replace(/[-:]/g, '').replace(/\.\d{3}Z$/, 'Z');
}

function formatIsapiTime(date: Date): string {
  return date.toISOString().replace(/\.\d{3}Z$/, 'Z');
}

export function hikvisionTrackIdFromCamera(camera: CameraConfig): string | null {
  return hikvisionTrackIdCandidates(camera)[0] || null;
}

function hikvisionTrackIdCandidates(camera: CameraConfig): string[] {
  const candidates = [camera.source_url, camera.device_rtsp_url, camera.stream_name, camera.name].filter(Boolean).map(String);
  const result: string[] = [];
  const add = (value: string | number | null | undefined) => {
    const trackId = String(value || '').trim();
    if (trackId && !result.includes(trackId)) result.push(trackId);
  };

  for (const candidate of candidates) {
    const matches = [
      ...candidate.matchAll(/\/Streaming\/(?:channels|tracks)\/(\d+)/gi),
      ...candidate.matchAll(/\b(\d{3,4})\b/g)
    ];

    for (const match of matches) {
      const numeric = Number(match[1]);
      add(match[1]);
      if (Number.isInteger(numeric) && numeric >= 100) add(Math.floor(numeric / 100));
      if (Number.isInteger(numeric) && numeric > 0 && numeric < 100) add(`${numeric}01`);
    }
  }

  return result;
}

function credentialsFromUrl(raw: string | null | undefined) {
  if (!raw) return { username: '', password: '' };
  try {
    const url = new URL(raw);
    return {
      username: decodeURIComponent(url.username || ''),
      password: decodeURIComponent(url.password || '')
    };
  } catch {
    return { username: '', password: '' };
  }
}

function cleanHost(raw: string | null | undefined): { scheme: string; host: string } {
  const input = String(raw || '').trim();
  const scheme = /^https:\/\//i.test(input) ? 'https' : (process.env.DVR_HIKVISION_ISAPI_SCHEME || 'http');
  return {
    scheme,
    host: input.replace(/^https?:\/\//i, '').replace(/\/.*$/, '').replace(/:\d+$/, '')
  };
}

function hostFromCamera(camera: CameraConfig): string {
  if (camera.device_host) return cleanHost(camera.device_host).host;
  try {
    return new URL(camera.source_url).hostname;
  } catch {
    return '';
  }
}

function rtspPortFromCamera(camera: CameraConfig): number {
  try {
    const url = new URL(camera.source_url);
    if (url.port) return Number(url.port);
  } catch {
    // ignore
  }
  return Number(process.env.DVR_HIKVISION_RTSP_PORT || 554);
}

function isapiBasesFromCamera(camera: CameraConfig): string[] {
  const hostInfo = cleanHost(camera.device_host || '');
  const host = hostInfo.host || hostFromCamera(camera);
  if (!host) throw new Error(`Cannot determine Hikvision host for ${camera.stream_name}`);
  const port = Number(camera.device_port || process.env.DVR_HIKVISION_ISAPI_PORT || 80);
  const bases: string[] = [];
  const addBase = (scheme: string, basePort: number) => {
    const base = `${scheme}://${host}:${basePort}`;
    if (!bases.includes(base)) bases.push(base);
  };

  addBase(hostInfo.scheme, port);

  const fallbackPorts = String(process.env.DVR_HIKVISION_ISAPI_FALLBACK_PORTS || '80')
    .split(',')
    .map((item) => Number(item.trim()))
    .filter((item) => Number.isInteger(item) && item > 0 && item <= 65535);

  for (const fallbackPort of fallbackPorts) {
    addBase(fallbackPort === 443 ? 'https' : hostInfo.scheme, fallbackPort);
  }

  return bases;
}

export function buildFallbackPlaybackUrl(camera: CameraConfig, start: Date, end: Date): string {
  const trackId = hikvisionTrackIdFromCamera(camera);
  if (!trackId) throw new Error(`Cannot determine Hikvision track id for ${camera.stream_name}`);

  const host = hostFromCamera(camera);
  if (!host) throw new Error(`Cannot determine Hikvision host for ${camera.stream_name}`);

  const rtspCreds = credentialsFromUrl(camera.source_url);
  const username = camera.device_username || rtspCreds.username;
  const password = camera.device_password || rtspCreds.password;
  const auth = username ? `${encodeURIComponent(username)}${password ? `:${encodeURIComponent(password)}` : ''}@` : '';
  const port = rtspPortFromCamera(camera);
  return `rtsp://${auth}${host}:${port}/Streaming/tracks/${trackId}?starttime=${formatHikvisionTime(start)}&endtime=${formatHikvisionTime(end)}`;
}

function addRtspCredentials(rawUri: string, camera: CameraConfig): string {
  try {
    const parsed = new URL(rawUri);
    if (parsed.protocol !== 'rtsp:' || parsed.username) return rawUri;
    const rtspCreds = credentialsFromUrl(camera.source_url);
    const username = camera.device_username || rtspCreds.username;
    const password = camera.device_password || rtspCreds.password;
    if (!username) return rawUri;
    parsed.username = username;
    if (password) parsed.password = password;
    return parsed.toString();
  } catch {
    return rawUri;
  }
}

function normalizePlaybackUri(rawUri: string, camera: CameraConfig, start: Date, end: Date, trackId: string): string {
  let uri = rawUri;
  try {
    const parsed = new URL(rawUri);
    if (parsed.protocol !== 'rtsp:') return buildFallbackPlaybackUrl(camera, start, end);

    const deviceHost = hostFromCamera(camera);
    if (deviceHost && ['0.0.0.0', '127.0.0.1', 'localhost'].includes(parsed.hostname.toLowerCase())) {
      parsed.hostname = deviceHost;
    }

    if (!parsed.searchParams.has('starttime')) parsed.searchParams.set('starttime', formatHikvisionTime(start));
    if (!parsed.searchParams.has('endtime')) parsed.searchParams.set('endtime', formatHikvisionTime(end));
    uri = parsed.toString();
  } catch {
    uri = buildFallbackPlaybackUrl(camera, start, end);
  }

  if (!/\/Streaming\/(?:tracks|channels)\//i.test(uri)) {
    uri = buildFallbackPlaybackUrl(camera, start, end).replace(/\/Streaming\/tracks\/[^?]+/i, `/Streaming/tracks/${encodeURIComponent(trackId)}`);
  }

  return addRtspCredentials(uri, camera);
}

async function hikvisionPost(camera: CameraConfig, path: string, body: string): Promise<string> {
  const bases = isapiBasesFromCamera(camera);
  const username = camera.device_username || credentialsFromUrl(camera.source_url).username;
  const password = camera.device_password || credentialsFromUrl(camera.source_url).password;
  const errors: string[] = [];

  for (const base of bases) {
    const url = new URL(`${base}${path}`);
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), searchTimeoutMs);
    const headers: Record<string, string> = {
      accept: 'application/xml,text/xml,*/*',
      'content-type': 'application/xml; charset=UTF-8',
      'user-agent': 'NewDomofon-Video/1.0'
    };
    if (username) headers.authorization = `Basic ${Buffer.from(`${username}:${password}`).toString('base64')}`;

    try {
      let response = await fetch(url, { method: 'POST', signal: controller.signal, headers, body });
      const authHeader = response.headers.get('www-authenticate') || '';
      if (response.status === 401 && /^Digest/i.test(authHeader) && username) {
        response = await fetch(url, {
          method: 'POST',
          signal: controller.signal,
          headers: {
            accept: 'application/xml,text/xml,*/*',
            'content-type': 'application/xml; charset=UTF-8',
            'user-agent': 'NewDomofon-Video/1.0',
            authorization: digestAuthHeader(parseDigestHeader(authHeader), 'POST', url.pathname + url.search, username, password)
          },
          body
        });
      }

      const text = await response.text();
      if (!response.ok) throw new Error(`HTTP ${response.status}: ${text.slice(0, 300)}`);
      return text;
    } catch (error) {
      const cause = error && typeof error === 'object' && 'cause' in error
        ? (error as { cause?: unknown }).cause
        : undefined;
      const causeText = cause && typeof cause === 'object'
        ? `${'code' in cause ? String((cause as { code?: unknown }).code) : ''} ${'message' in cause ? String((cause as { message?: unknown }).message) : ''}`.trim()
        : '';
      const message = error instanceof Error ? error.message : String(error);
      errors.push(`${url.toString()} ${causeText || message}`);
    } finally {
      clearTimeout(timer);
    }
  }

  throw new Error(`Hikvision ISAPI ${path} failed: ${errors.join(' | ')}`);
}

function asArray<T>(value: T | T[] | undefined | null): T[] {
  if (value == null) return [];
  return Array.isArray(value) ? value : [value];
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

function collectObjects(value: unknown, key: string): Record<string, unknown>[] {
  if (!value || typeof value !== 'object') return [];
  if (Array.isArray(value)) return value.flatMap((item) => collectObjects(item, key));
  const obj = value as Record<string, unknown>;
  const direct = asArray(obj[key] as Record<string, unknown> | Record<string, unknown>[]).filter((item) => item && typeof item === 'object');
  return [...direct, ...Object.values(obj).flatMap((item) => collectObjects(item, key))];
}

function parseDate(raw: string): Date | null {
  const parsed = new Date(raw);
  return Number.isFinite(parsed.getTime()) ? parsed : null;
}

function searchRequestXml(searchId: string, trackId: string, start: Date, end: Date, position: number, maxResults: number): string {
  return `<?xml version="1.0" encoding="UTF-8"?>
<CMSearchDescription>
  <searchID>${searchId}</searchID>
  <trackList>
    <trackID>${trackId}</trackID>
  </trackList>
  <timeSpanList>
    <timeSpan>
      <startTime>${formatIsapiTime(start)}</startTime>
      <endTime>${formatIsapiTime(end)}</endTime>
    </timeSpan>
  </timeSpanList>
  <maxResults>${maxResults}</maxResults>
  <searchResultPosition>${position}</searchResultPosition>
  <metadataList>
    <metadataDescriptor>//recordType.meta.std-cgi.com</metadataDescriptor>
  </metadataList>
</CMSearchDescription>`;
}

function parseSearchResponse(xml: string, camera: CameraConfig, fallbackTrackId: string): HikvisionArchiveItem[] {
  const parsed = parser.parse(xml);
  const blocks = collectObjects(parsed, 'searchMatchItem');
  const candidates = blocks.length ? blocks : collectObjects(parsed, 'playbackURI').map((playbackURI) => ({ playbackURI }));
  const items: HikvisionArchiveItem[] = [];

  for (const block of candidates) {
    const playbackUri = findText(block, ['playbackURI']);
    const startRaw = findText(block, ['startTime']);
    const endRaw = findText(block, ['endTime']);
    const start = parseDate(startRaw);
    const end = parseDate(endRaw);
    if (!playbackUri || !start || !end || end <= start) continue;
    const trackId = findText(block, ['trackID']) || fallbackTrackId;
    items.push({
      start: start.toISOString(),
      end: end.toISOString(),
      playbackUri: normalizePlaybackUri(playbackUri, camera, start, end, trackId),
      trackId,
      source: 'hikvision-isapi'
    });
  }

  return items.sort((a, b) => new Date(a.start).getTime() - new Date(b.start).getTime());
}

function cacheKey(camera: CameraConfig, trackId: string, start: Date, end: Date): string {
  const from = Math.floor(start.getTime() / 60_000);
  const to = Math.floor(end.getTime() / 60_000);
  return `${camera.id}|${trackId}|${from}|${to}`;
}

function overlappingItems(items: HikvisionArchiveItem[], start: Date, end: Date): HikvisionArchiveItem[] {
  const requestedStart = start.getTime();
  const requestedEnd = end.getTime();
  return items.filter((item) => {
    const itemStart = new Date(item.start).getTime();
    const itemEnd = new Date(item.end).getTime();
    return Number.isFinite(itemStart) && Number.isFinite(itemEnd) && itemEnd >= requestedStart && itemStart <= requestedEnd;
  });
}

function findCoveringCachedSearch(camera: CameraConfig, trackIdsKey: string, start: Date, end: Date): HikvisionArchiveItem[] | null {
  const now = Date.now();
  const requestedStart = start.getTime();
  const requestedEnd = end.getTime();
  for (const [key, cached] of searchCache) {
    if (cached.expiresAt <= now) {
      searchCache.delete(key);
      continue;
    }
    if (cached.cameraId !== camera.id || cached.trackIdsKey !== trackIdsKey) continue;
    if (cached.startMs <= requestedStart && cached.endMs >= requestedEnd) {
      return overlappingItems(cached.items, start, end);
    }
  }
  return null;
}

async function hikvisionSearchPage(camera: CameraConfig, searchId: string, trackId: string, start: Date, end: Date, position: number): Promise<HikvisionArchiveItem[]> {
  const body = searchRequestXml(searchId, trackId, start, end, position, searchPageSize);
  let xml: string;
  try {
    xml = await hikvisionPost(camera, '/ISAPI/ContentMgmt/search', body);
  } catch (firstError) {
    try {
      xml = await hikvisionPost(camera, '/ISAPI/ContentMgmt/search/', body);
    } catch (secondError) {
      throw new Error(`${firstError instanceof Error ? firstError.message : String(firstError)} | ${secondError instanceof Error ? secondError.message : String(secondError)}`);
    }
  }
  return parseSearchResponse(xml, camera, trackId);
}

function uniqItems(items: HikvisionArchiveItem[]): HikvisionArchiveItem[] {
  const seen = new Set<string>();
  const result: HikvisionArchiveItem[] = [];
  for (const item of items) {
    const key = `${item.trackId}|${item.start}|${item.end}|${item.playbackUri}`;
    if (seen.has(key)) continue;
    seen.add(key);
    result.push(item);
  }
  return result.sort((a, b) => new Date(a.start).getTime() - new Date(b.start).getTime());
}

export async function searchHikvisionArchive(camera: CameraConfig, start: Date, end: Date): Promise<HikvisionArchiveItem[]> {
  const trackIds = hikvisionTrackIdCandidates(camera);
  if (!trackIds.length) throw new Error(`Cannot determine Hikvision track id for ${camera.stream_name}`);
  const trackIdsKey = trackIds.join(',');
  const key = cacheKey(camera, trackIdsKey, start, end);
  const cached = searchCache.get(key);
  if (cached && cached.expiresAt > Date.now()) return overlappingItems(cached.items, start, end);
  const coveringCached = findCoveringCachedSearch(camera, trackIdsKey, start, end);
  if (coveringCached) return coveringCached;
  const inFlight = inFlightSearches.get(key);
  if (inFlight) return inFlight;

  const searchPromise = (async () => {
    const allItems: HikvisionArchiveItem[] = [];
    const pagesByTrack: string[] = [];

    for (const trackId of trackIds) {
      const searchId = crypto.randomUUID();
      let position = 0;
      let pagesUsed = 0;

      for (let page = 0; page < searchMaxPages; page += 1) {
        const pageItems = await hikvisionSearchPage(camera, searchId, trackId, start, end, position);
        if (!pageItems.length) break;
        pagesUsed += 1;
        allItems.push(...pageItems);
        if (pageItems.length < searchPageSize) break;
        position += searchPageSize;
      }

      pagesByTrack.push(`${trackId}:${pagesUsed}`);
      if (allItems.length && !['1', 'true', 'yes', 'on'].includes(String(process.env.DVR_HIKVISION_ARCHIVE_SEARCH_ALL_TRACK_CANDIDATES || '').toLowerCase())) {
        break;
      }
    }

    const items = uniqItems(allItems);
    console.log(`[hikvision-archive] search ${camera.stream_name} tracks=${trackIds.join(',')} start=${start.toISOString()} end=${end.toISOString()} items=${items.length} pages=${pagesByTrack.join('|')}/${searchMaxPages}`);
    searchCache.set(key, {
      expiresAt: Date.now() + cacheTtlMs,
      cameraId: camera.id,
      trackIdsKey,
      startMs: start.getTime(),
      endMs: end.getTime(),
      items
    });
    return items;
  })();

  inFlightSearches.set(key, searchPromise);
  try {
    return await searchPromise;
  } finally {
    inFlightSearches.delete(key);
  }
}

function sortPlaybackItems(items: HikvisionArchiveItem[], start: Date, end: Date): HikvisionArchiveItem[] {
  const requestedStart = start.getTime();
  const requestedEnd = end.getTime();
  return items
    .filter((item) => new Date(item.start).getTime() <= requestedEnd && new Date(item.end).getTime() >= requestedStart)
    .sort((a, b) => {
      const distanceA = Math.abs(new Date(a.start).getTime() - requestedStart);
      const distanceB = Math.abs(new Date(b.start).getTime() - requestedStart);
      return distanceA - distanceB;
    });
}

export async function playbackUrlsForRange(camera: CameraConfig, start: Date, end: Date): Promise<HikvisionPlaybackCandidate[]> {
  const trackId = hikvisionTrackIdFromCamera(camera);
  if (start.getTime() > Date.now() + futureSkewMs) {
    throw new DeviceArchiveRangeError(`No device archive in future range ${start.toISOString()} - ${end.toISOString()}`);
  }

  try {
    const items = await searchHikvisionArchive(camera, start, end);
    const candidates: HikvisionPlaybackCandidate[] = sortPlaybackItems(items, start, end)
      .map((item) => ({ url: item.playbackUri, source: 'hikvision-isapi' as const, trackId: item.trackId }))
      .filter((item) => Boolean(item.url));
    if (candidates.length) {
      if (allowRtspFallback && trackId) {
        const fallback = { url: buildFallbackPlaybackUrl(camera, start, end), source: 'fallback-rtsp' as const, trackId };
        if (preferRtspFallback) candidates.unshift(fallback);
        else candidates.push(fallback);
      }
      return candidates;
    }
    throw new DeviceArchiveRangeError(`No Hikvision archive item in selected range ${start.toISOString()} - ${end.toISOString()}`);
  } catch (error) {
    if (error instanceof DeviceArchiveRangeError) {
      if (allowRtspFallback && fallbackOnEmptyRange && trackId) {
        console.warn('[hikvision-archive] no ISAPI item, trying direct RTSP playback', camera.stream_name, error.message);
        return [{ url: buildFallbackPlaybackUrl(camera, start, end), source: 'fallback-rtsp', trackId }];
      }
      throw error;
    }
    console.warn('[hikvision-archive] search failed, using fallback RTSP', camera.stream_name, error instanceof Error ? error.message : error);
  }
  if (!allowRtspFallback) {
    throw new DeviceArchiveRangeError(`Hikvision ISAPI archive search failed and RTSP fallback is disabled for ${camera.stream_name}`);
  }
  return [{ url: buildFallbackPlaybackUrl(camera, start, end), source: 'fallback-rtsp', trackId }];
}

export async function playbackUrlForRange(camera: CameraConfig, start: Date, end: Date): Promise<HikvisionPlaybackCandidate> {
  const candidates = await playbackUrlsForRange(camera, start, end);
  const first = candidates[0];
  if (!first) throw new DeviceArchiveRangeError(`No Hikvision archive playback URL for ${camera.stream_name}`);
  return first;
}
