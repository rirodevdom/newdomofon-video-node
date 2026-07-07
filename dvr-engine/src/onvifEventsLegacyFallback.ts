import { createRequire } from 'node:module';
import { config as dvrConfig } from './config.js';

const require = createRequire(import.meta.url);
const { Cam } = require('onvif');
const VERSION = 'v139-milesight-onvif-fallback';

interface OnvifCamera {
  id: string;
  stream_name: string;
  source_url?: string | null;
  onvif_xaddr: string;
  onvif_port?: number | null;
  onvif_username?: string | null;
  onvif_password?: string | null;
}

interface LegacySession {
  cam: any;
  startedAt: number;
}

const sessions = new Map<string, LegacySession>();
const snapshotStates = new Map<string, string>();
let timer: NodeJS.Timeout | null = null;
let lastIgnoredSnapshotLogAt = 0;

function cfg() {
  return {
    backendUrl: (
      process.env.BACKEND_INTERNAL_URL ||
      process.env.BACKEND_URL ||
      process.env.API_BASE_URL ||
      'http://127.0.0.1:3000'
    ).replace(/\/+$/, ''),
    secret: process.env.INTERNAL_DVR_SECRET || '',
    streams: new Set(
      String(
        process.env.ONVIF_LEGACY_FALLBACK_STREAMS ||
        'cam_10_130_1_219'
      ).split(',').map((value) => value.trim()).filter(Boolean)
    ),
    syncMs: Math.max(
      Number(process.env.ONVIF_LEGACY_SYNC_MS || 10_000),
      5_000
    ),
    reconnectMs: Math.max(
      Number(process.env.ONVIF_LEGACY_RECONNECT_MS || 60_000),
      5_000
    ),
    ignoreInitialized: String(process.env.ONVIF_LEGACY_IGNORE_INITIALIZED || 'true').toLowerCase() !== 'false',
    initializedStateEvents: String(process.env.ONVIF_LEGACY_INITIALIZED_STATE_EVENTS || 'false').toLowerCase() === 'true',
    quietLogMs: Math.max(Number(process.env.ONVIF_LEGACY_QUIET_LOG_MS || 120_000), 30_000)
  };
}

function hostFromXaddr(xaddr: string) {
  try {
    return new URL(xaddr).hostname;
  } catch {
    return xaddr
      .replace(/^https?:\/\//i, '')
      .replace(/:\d+\/.*$/i, '')
      .replace(/\/.*$/i, '');
  }
}

function credentialsFromRtsp(uri?: string | null) {
  try {
    const url = new URL(String(uri || ''));
    return {
      username: decodeURIComponent(url.username || ''),
      password: decodeURIComponent(url.password || '')
    };
  } catch {
    return { username: '', password: '' };
  }
}

function credentials(camera: OnvifCamera) {
  const rtsp = credentialsFromRtsp(camera.source_url);
  return {
    username: String(camera.onvif_username || rtsp.username || ''),
    password: String(camera.onvif_password || rtsp.password || '')
  };
}

function findFirst(value: any, keys: string[]): any {
  if (!value || typeof value !== 'object') return undefined;
  for (const key of keys) {
    if (Object.prototype.hasOwnProperty.call(value, key)) return value[key];
  }
  for (const item of Array.isArray(value) ? value : Object.values(value)) {
    const found = findFirst(item, keys);
    if (found !== undefined) return found;
  }
  return undefined;
}

function collectSimple(value: any, out: Record<string, string> = {}) {
  if (!value || typeof value !== 'object') return out;
  if (Array.isArray(value)) {
    for (const item of value) collectSimple(item, out);
    return out;
  }
  const name = value.Name ?? value.name ?? value.$?.Name ?? value.$?.name;
  const item = value.Value ?? value.value ?? value.$?.Value ?? value.$?.value;
  if (name !== undefined && item !== undefined) out[String(name)] = String(item);
  for (const child of Object.values(value)) collectSimple(child, out);
  return out;
}

function normalize(camera: OnvifCamera, event: any) {
  const simple = collectSimple(event);
  const topicRaw = findFirst(event, ['topic', 'Topic']);
  const topic = typeof topicRaw === 'string'
    ? topicRaw
    : String(topicRaw?._ || topicRaw?.__text || 'onvif.event');
  const operation = findFirst(event, [
    'PropertyOperation',
    'propertyOperation'
  ]);
  const stateKey = [
    'IsMotion',
    'isMotion',
    'Motion',
    'motion',
    'State',
    'LogicalState',
    'Active',
    'Value'
  ].find((key) => simple[key] !== undefined);
  const rawTime = findFirst(event, ['UtcTime', 'utcTime', 'time']);
  const parsedTime = rawTime ? new Date(String(rawTime)) : new Date();

  return {
    camera_id: camera.id,
    stream_name: camera.stream_name,
    event_type: stateKey ? `${topic}/${stateKey}` : topic,
    event_state: stateKey
      ? String(simple[stateKey])
      : operation === undefined || operation === null
        ? null
        : String(operation),
    occurred_at: Number.isNaN(parsedTime.getTime())
      ? new Date().toISOString()
      : parsedTime.toISOString(),
    data: {
      collector: VERSION,
      topic,
      operation: operation ?? null,
      simple,
      raw: event
    }
  };
}

function shouldIgnoreSnapshot(payload: any) {
  const config = cfg();
  if (!config.ignoreInitialized) return false;

  const operation = String(payload?.data?.operation ?? '').trim().toLowerCase();
  return operation === 'initialized';
}

function initializedSnapshotStateChange(payload: any) {
  const config = cfg();
  const operation = String(payload?.data?.operation ?? '').trim().toLowerCase();
  if (!config.initializedStateEvents || operation !== 'initialized') return null;

  const state = payload.event_state === undefined || payload.event_state === null
    ? ''
    : String(payload.event_state);
  const key = `${payload.stream_name}|${payload.event_type}`;
  const previous = snapshotStates.get(key);
  snapshotStates.set(key, state);

  if (previous === undefined || previous === state) return null;

  return {
    ...payload,
    occurred_at: new Date().toISOString(),
    data: {
      ...(payload.data || {}),
      operation: 'Changed',
      _newdomofon_initialized_state_change: true,
      _newdomofon_previous_state: previous,
      _newdomofon_current_state: state
    }
  };
}

function logIgnoredSnapshot(payload: any) {
  const config = cfg();
  const now = Date.now();
  if (now - lastIgnoredSnapshotLogAt < config.quietLogMs) return;
  lastIgnoredSnapshotLogAt = now;
  console.log('[onvif-events:legacy-fallback] ignored initialized snapshot', {
    stream_name: payload.stream_name,
    event_type: payload.event_type,
    event_state: payload.event_state,
    occurred_at: payload.occurred_at
  });
}

async function backendGet(path: string) {
  const config = cfg();
  const response = await fetch(`${config.backendUrl}${path}`, {
    headers: { 'x-internal-secret': config.secret, 'x-node-id': dvrConfig.nodeId }
  });
  if (!response.ok) {
    throw new Error(`Backend GET ${path} HTTP ${response.status}`);
  }
  return response.json();
}

async function postEvent(payload: any) {
  const config = cfg();
  const response = await fetch(
    `${config.backendUrl}/api/internal/events/onvif`,
    {
      method: 'POST',
      headers: {
        'content-type': 'application/json',
        'x-internal-secret': config.secret,
        'x-node-id': dvrConfig.nodeId
      },
      body: JSON.stringify(payload)
    }
  );
  if (!response.ok) {
    throw new Error(
      `Backend POST event HTTP ${response.status}: ${(await response.text()).slice(0, 200)}`
    );
  }
}

function stopSession(streamName: string) {
  const session = sessions.get(streamName);
  if (!session) return;
  try {
    session.cam?.removeAllListeners?.('event');
    session.cam?.removeAllListeners?.('error');
  } catch {}
  sessions.delete(streamName);
}

function startSession(camera: OnvifCamera) {
  stopSession(camera.stream_name);
  const auth = credentials(camera);
  const options: any = {
    hostname: hostFromXaddr(camera.onvif_xaddr),
    port: Number(camera.onvif_port || 80),
    timeout: 12_000
  };
  if (auth.username) options.username = auth.username;
  if (auth.password) options.password = auth.password;

  console.log('[onvif-events:legacy-fallback] session start', {
    version: VERSION,
    stream_name: camera.stream_name,
    hostname: options.hostname,
    port: options.port,
    auth: Boolean(auth.username && auth.password)
  });

  const cam = new Cam(options, function onInit(this: any, error: Error | null) {
    if (error) {
      console.warn('[onvif-events:legacy-fallback] init failed', {
        stream_name: camera.stream_name,
        error: error.message
      });
      setTimeout(() => stopSession(camera.stream_name), 0);
      return;
    }

    console.log('[onvif-events:legacy-fallback] ready', {
      stream_name: camera.stream_name
    });

    this.on('event', async (event: any) => {
      try {
        let payload = normalize(camera, event);
        const stateChangePayload = initializedSnapshotStateChange(payload);
        if (stateChangePayload) {
          payload = stateChangePayload;
        }
        if (shouldIgnoreSnapshot(payload)) {
          logIgnoredSnapshot(payload);
          return;
        }
        await postEvent(payload);
        console.log('[onvif-events:legacy-fallback] stored event', {
          stream_name: camera.stream_name,
          event_type: payload.event_type,
          event_state: payload.event_state,
          occurred_at: payload.occurred_at
        });
      } catch (eventError) {
        console.warn('[onvif-events:legacy-fallback] store failed', {
          stream_name: camera.stream_name,
          error: eventError instanceof Error
            ? eventError.message
            : String(eventError)
        });
      }
    });
  });

  sessions.set(camera.stream_name, { cam, startedAt: Date.now() });
  cam.on?.('error', (error: Error) => {
    console.warn('[onvif-events:legacy-fallback] session error', {
      stream_name: camera.stream_name,
      error: error?.message || String(error)
    });
    stopSession(camera.stream_name);
  });
}

async function sync() {
  const config = cfg();
  if (!config.secret) {
    console.warn('[onvif-events:legacy-fallback] INTERNAL_DVR_SECRET empty');
    return;
  }

  const data = await backendGet('/api/internal/cameras/onvif') as {
    items?: OnvifCamera[];
  };
  const cameras = (data.items || []).filter((camera) =>
    config.streams.has(camera.stream_name)
  );
  const activeNames = new Set(cameras.map((camera) => camera.stream_name));

  for (const streamName of Array.from(sessions.keys())) {
    if (!activeNames.has(streamName)) stopSession(streamName);
  }

  for (const camera of cameras) {
    const session = sessions.get(camera.stream_name);
    if (!session || Date.now() - session.startedAt >= config.reconnectMs) {
      startSession(camera);
    }
  }
}

export function startOnvifLegacyFallbackCollector() {
  if (timer) return;
  const config = cfg();
  console.log('[onvif-events:legacy-fallback] enabled', {
    version: VERSION,
    streams: Array.from(config.streams),
    reconnectMs: config.reconnectMs
  });
  void sync().catch((error) =>
    console.error('[onvif-events:legacy-fallback] sync failed', error)
  );
  timer = setInterval(
    () => void sync().catch((error) =>
      console.error('[onvif-events:legacy-fallback] sync failed', error)
    ),
    config.syncMs
  );
}
