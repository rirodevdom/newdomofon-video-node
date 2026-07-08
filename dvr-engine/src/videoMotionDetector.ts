import { spawn, type ChildProcess } from 'node:child_process';
import path from 'node:path';
import { config } from './config.js';
import { query } from './db.js';
import { isNodeMode, loadAssignedCameras } from './nodeClient.js';
import { streamRoot } from './storage.js';
import type { CameraConfig } from './types.js';

const VERSION = 'v2-hls-scene-motion';

type VideoMotionSource = 'hls' | 'rtsp';

interface DetectorState {
  camera: CameraConfig;
  process: ChildProcess;
  startedAt: Date;
  restarts: number;
  active: boolean;
  lastAboveAt: number | null;
  lastScoreAt: number | null;
  lastFrame: Record<string, string>;
  maxScore: number;
  stopping: boolean;
}

interface DetectorConfig {
  enabled: boolean;
  backendUrl: string;
  secret: string;
  nodeId: string;
  streams: Set<string>;
  allStreams: boolean;
  fps: number;
  scaleWidth: number;
  threshold: number;
  endIdleMs: number;
  cooldownMs: number;
  reloadMs: number;
  restartMinMs: number;
  restartMaxMs: number;
  maxDetectors: number;
  ffmpegLog: boolean;
  eventType: string;
  source: VideoMotionSource;
}

const detectors = new Map<string, DetectorState>();
const desiredCameras = new Map<string, CameraConfig>();
const cooldownUntil = new Map<string, number>();
let timer: NodeJS.Timeout | null = null;
let syncing = false;

function boolEnv(name: string, fallback = false) {
  const raw = process.env[name];
  if (raw === undefined || raw === null || raw === '') return fallback;
  return ['1', 'true', 'yes', 'on'].includes(String(raw).toLowerCase());
}

function numEnv(name: string, fallback: number, min: number, max = Number.POSITIVE_INFINITY) {
  const raw = Number(process.env[name] || fallback);
  if (!Number.isFinite(raw)) return fallback;
  return Math.max(min, Math.min(max, raw));
}

function cfg(): DetectorConfig {
  const streamsRaw = String(process.env.VIDEO_MOTION_STREAMS || process.env.DVR_VIDEO_MOTION_STREAMS || '').trim();
  const streams = new Set(streamsRaw.split(',').map((value) => value.trim()).filter(Boolean));
  const allStreams = streams.has('*');
  const sourceRaw = String(process.env.VIDEO_MOTION_SOURCE || process.env.DVR_VIDEO_MOTION_SOURCE || 'hls').toLowerCase();

  return {
    enabled: boolEnv('VIDEO_MOTION_ENABLED', streams.size > 0),
    backendUrl: (process.env.BACKEND_INTERNAL_URL || process.env.BACKEND_URL || process.env.API_BASE_URL || 'http://127.0.0.1:3000').replace(/\/+$/, ''),
    secret: process.env.INTERNAL_DVR_SECRET || '',
    nodeId: config.nodeId,
    streams,
    allStreams,
    fps: numEnv('VIDEO_MOTION_FPS', 3, 0.2, 15),
    scaleWidth: Math.round(numEnv('VIDEO_MOTION_SCALE_WIDTH', 320, 80, 1920)),
    threshold: numEnv('VIDEO_MOTION_SCENE_THRESHOLD', 0.010, 0.000001, 1),
    endIdleMs: Math.round(numEnv('VIDEO_MOTION_END_IDLE_MS', 7000, 1000, 120000)),
    cooldownMs: Math.round(numEnv('VIDEO_MOTION_COOLDOWN_MS', 2000, 0, 120000)),
    reloadMs: Math.round(numEnv('VIDEO_MOTION_RELOAD_MS', 20000, 5000, 300000)),
    restartMinMs: Math.round(numEnv('VIDEO_MOTION_RESTART_MIN_MS', 5000, 1000, 300000)),
    restartMaxMs: Math.round(numEnv('VIDEO_MOTION_RESTART_MAX_MS', 60000, 5000, 600000)),
    maxDetectors: Math.round(numEnv('VIDEO_MOTION_MAX_DETECTORS', 8, 1, 10000)),
    ffmpegLog: boolEnv('VIDEO_MOTION_FFMPEG_LOG', false),
    eventType: String(process.env.VIDEO_MOTION_EVENT_TYPE || 'video.motion'),
    source: sourceRaw === 'rtsp' ? 'rtsp' : 'hls'
  };
}

function nowIso() {
  return new Date().toISOString();
}

function redactUri(uri: string) {
  try {
    const url = new URL(uri);
    if (url.username) url.username = '***';
    if (url.password) url.password = '***';
    return url.toString();
  } catch {
    return '<invalid-url>';
  }
}

function detectorInput(camera: CameraConfig, configValue: DetectorConfig) {
  if (configValue.source === 'rtsp') {
    return {
      input: camera.source_url,
      display: redactUri(camera.source_url),
      preInputArgs: [
        '-rtsp_transport', process.env.DVR_RTSP_TRANSPORT || 'tcp',
        '-timeout', String(Number(process.env.DVR_RTSP_TIMEOUT_US || 15_000_000))
      ]
    };
  }

  const playlist = path.join(streamRoot(camera.stream_name), 'live.m3u8');
  return {
    input: playlist,
    display: playlist,
    preInputArgs: ['-live_start_index', '-3']
  };
}

function cameraFingerprint(camera: CameraConfig) {
  return [camera.id, camera.stream_name, camera.source_url].join('|');
}

async function loadCameras(): Promise<CameraConfig[]> {
  if (isNodeMode()) return loadAssignedCameras();

  const result = await query<CameraConfig>(
    `SELECT id, name, stream_name, source_url, archive_storage, rtmp_push_url, retention_days, is_enabled
       FROM cameras
      WHERE is_enabled = true
      ORDER BY stream_name ASC`
  );
  return result.rows;
}

async function postEvent(camera: CameraConfig, active: boolean, score: number, frame: Record<string, string>) {
  const configValue = cfg();
  const occurredAt = nowIso();
  const response = await fetch(`${configValue.backendUrl}/api/internal/events/onvif`, {
    method: 'POST',
    headers: {
      'content-type': 'application/json',
      'x-internal-secret': configValue.secret,
      'x-node-id': configValue.nodeId
    },
    body: JSON.stringify({
      camera_id: camera.id,
      stream_name: camera.stream_name,
      event_type: configValue.eventType,
      event_state: active ? 'true' : 'false',
      topic: configValue.eventType,
      source_name: 'ffmpeg-scene',
      occurred_at: occurredAt,
      data: {
        simple: {
          IsMotion: active ? 'true' : 'false',
          SceneScore: String(score),
          Threshold: String(configValue.threshold)
        },
        detector: 'ffmpeg-scene',
        version: VERSION,
        score,
        threshold: configValue.threshold,
        fps: configValue.fps,
        scale_width: configValue.scaleWidth,
        end_idle_ms: configValue.endIdleMs,
        source: configValue.source,
        frame
      }
    })
  });

  if (!response.ok) {
    throw new Error(`Backend POST video motion event HTTP ${response.status}: ${(await response.text()).slice(0, 300)}`);
  }

  return response.json() as Promise<{ ok?: boolean; inserted?: boolean }>;
}

function parseMetadataLine(line: string, frame: Record<string, string>) {
  const trimmed = line.trim();
  if (!trimmed) return null;

  const frameMatch = trimmed.match(/^frame:(\d+)\s+pts:([^\s]+)\s+pts_time:([^\s]+)/);
  if (frameMatch) {
    frame.frame = frameMatch[1];
    frame.pts = frameMatch[2];
    frame.pts_time = frameMatch[3];
    return null;
  }

  const scoreMatch = trimmed.match(/lavfi\.scene_score=([0-9.eE+-]+)/);
  if (!scoreMatch) return null;

  const score = Number(scoreMatch[1]);
  if (!Number.isFinite(score)) return null;
  return score;
}

function scheduleRestart(camera: CameraConfig, restarts: number) {
  const configValue = cfg();
  if (!configValue.enabled) return;
  if (!desiredCameras.has(camera.stream_name)) return;

  const delay = Math.min(configValue.restartMaxMs, configValue.restartMinMs + Math.max(0, restarts) * 1000);
  setTimeout(() => {
    const desired = desiredCameras.get(camera.stream_name);
    if (!desired) return;
    if (!cfg().enabled) return;
    if (detectors.has(camera.stream_name)) return;
    startDetector(desired, restarts + 1).catch((error) => console.error('[video-motion] restart failed', desired.stream_name, error));
  }, delay).unref?.();
}

async function handleScore(state: DetectorState, score: number) {
  const configValue = cfg();
  const now = Date.now();
  state.lastScoreAt = now;
  state.maxScore = Math.max(state.maxScore, score);

  if (score >= configValue.threshold) {
    state.lastAboveAt = now;

    if (!state.active && now >= (cooldownUntil.get(state.camera.stream_name) || 0)) {
      state.active = true;
      const result = await postEvent(state.camera, true, score, state.lastFrame);
      console.log('[video-motion] motion start', {
        stream_name: state.camera.stream_name,
        score,
        threshold: configValue.threshold,
        inserted: Boolean(result.inserted),
        frame: state.lastFrame
      });
    }

    return;
  }

  if (state.active && state.lastAboveAt && now - state.lastAboveAt >= configValue.endIdleMs) {
    state.active = false;
    cooldownUntil.set(state.camera.stream_name, now + configValue.cooldownMs);
    const result = await postEvent(state.camera, false, score, state.lastFrame);
    console.log('[video-motion] motion end', {
      stream_name: state.camera.stream_name,
      score,
      threshold: configValue.threshold,
      idleMs: now - state.lastAboveAt,
      inserted: Boolean(result.inserted),
      frame: state.lastFrame
    });
  }
}

async function startDetector(camera: CameraConfig, restarts: number) {
  const configValue = cfg();
  if (!camera.source_url) return;

  const input = detectorInput(camera, configValue);
  const filter = `fps=${configValue.fps},scale=${configValue.scaleWidth}:-1,select='gte(scene,0)',metadata=mode=print:key=lavfi.scene_score:file=-`;
  const args = [
    '-hide_banner',
    '-loglevel', configValue.ffmpegLog ? 'info' : 'warning',
    '-nostdin',
    '-fflags', '+genpts+discardcorrupt',
    ...input.preInputArgs,
    '-i', input.input,
    '-an',
    '-vf', filter,
    '-f', 'null',
    '/dev/null'
  ];

  const child = spawn(config.ffmpegPath, args, { stdio: ['ignore', 'pipe', 'pipe'] });
  const state: DetectorState = {
    camera,
    process: child,
    startedAt: new Date(),
    restarts,
    active: false,
    lastAboveAt: null,
    lastScoreAt: null,
    lastFrame: {},
    maxScore: 0,
    stopping: false
  };

  detectors.set(camera.stream_name, state);
  console.log('[video-motion] detector started', {
    version: VERSION,
    stream_name: camera.stream_name,
    pid: child.pid,
    sourceMode: configValue.source,
    source: input.display,
    fps: configValue.fps,
    width: configValue.scaleWidth,
    threshold: configValue.threshold,
    endIdleMs: configValue.endIdleMs
  });

  let stdoutBuffer = '';
  child.stdout?.on('data', (chunk) => {
    stdoutBuffer += String(chunk);
    const lines = stdoutBuffer.split(/\r?\n/);
    stdoutBuffer = lines.pop() || '';

    for (const line of lines) {
      const score = parseMetadataLine(line, state.lastFrame);
      if (score === null) continue;
      void handleScore(state, score).catch((error) => {
        console.error('[video-motion] score handling failed', camera.stream_name, error instanceof Error ? error.message : error);
      });
    }
  });

  child.stderr?.on('data', (chunk) => {
    const msg = String(chunk).trim();
    if (msg && configValue.ffmpegLog) console.warn(`[video-motion:ffmpeg:${camera.stream_name}] ${msg}`);
  });

  child.on('exit', (code, signal) => {
    const current = detectors.get(camera.stream_name);
    if (current?.process.pid !== child.pid) return;
    detectors.delete(camera.stream_name);
    console.warn('[video-motion] detector exited', {
      stream_name: camera.stream_name,
      code,
      signal,
      maxScore: state.maxScore,
      active: state.active
    });

    if (state.active) {
      postEvent(camera, false, state.maxScore, state.lastFrame).catch((error) => {
        console.error('[video-motion] failed to close active event after exit', camera.stream_name, error instanceof Error ? error.message : error);
      });
    }

    if (!state.stopping) scheduleRestart(camera, restarts + 1);
  });
}

function stopDetector(streamName: string, reason: string) {
  const state = detectors.get(streamName);
  if (!state) return;
  console.log('[video-motion] stopping detector', { stream_name: streamName, reason });
  state.stopping = true;
  detectors.delete(streamName);
  state.process.kill('SIGTERM');
}

async function syncDetectors() {
  if (syncing) return;
  syncing = true;

  try {
    const configValue = cfg();
    if (!configValue.enabled) {
      desiredCameras.clear();
      for (const streamName of Array.from(detectors.keys())) stopDetector(streamName, 'disabled');
      return;
    }

    if (!configValue.secret) {
      console.warn('[video-motion] INTERNAL_DVR_SECRET empty, detector disabled');
      return;
    }

    const cameras = (await loadCameras())
      .filter((camera) => camera.is_enabled !== false)
      .filter((camera) => camera.source_url)
      .filter((camera) => configValue.allStreams || configValue.streams.has(camera.stream_name))
      .slice(0, configValue.maxDetectors);

    const desired = new Map(cameras.map((camera) => [camera.stream_name, camera]));
    desiredCameras.clear();
    for (const [streamName, camera] of desired) desiredCameras.set(streamName, camera);

    for (const [streamName, state] of Array.from(detectors.entries())) {
      const next = desired.get(streamName);
      if (!next) {
        stopDetector(streamName, 'stream disabled or removed');
        continue;
      }

      if (cameraFingerprint(next) !== cameraFingerprint(state.camera)) {
        stopDetector(streamName, 'camera source changed');
      } else {
        state.camera = next;
      }
    }

    for (const camera of desired.values()) {
      if (!detectors.has(camera.stream_name)) await startDetector(camera, 0);
    }
  } catch (error) {
    console.error('[video-motion] sync failed', error instanceof Error ? error.message : error);
  } finally {
    syncing = false;
  }
}

export function startVideoMotionDetector() {
  const configValue = cfg();
  if (!configValue.enabled) {
    console.log('[video-motion] disabled', { version: VERSION });
    return;
  }

  if (!configValue.secret) {
    console.warn('[video-motion] INTERNAL_DVR_SECRET empty, detector disabled');
    return;
  }

  if (timer) return;

  console.log('[video-motion] enabled', {
    version: VERSION,
    source: configValue.source,
    streams: configValue.allStreams ? ['*'] : Array.from(configValue.streams),
    fps: configValue.fps,
    scaleWidth: configValue.scaleWidth,
    threshold: configValue.threshold,
    endIdleMs: configValue.endIdleMs,
    maxDetectors: configValue.maxDetectors
  });

  setTimeout(() => syncDetectors().catch(() => undefined), 1000);
  timer = setInterval(() => syncDetectors().catch(() => undefined), configValue.reloadMs);
}

export function stopAllVideoMotionDetectors() {
  if (timer) {
    clearInterval(timer);
    timer = null;
  }

  desiredCameras.clear();
  for (const streamName of Array.from(detectors.keys())) stopDetector(streamName, 'shutdown');
}
