import { spawn, type ChildProcess } from 'node:child_process';
import path from 'node:path';
import fs from 'node:fs/promises';
import { config } from './config.js';
import { query } from './db.js';
import { isNodeMode, loadAssignedCameras } from './nodeClient.js';
import { ensureStreamDirs, streamRoot } from './storage.js';
import {
  recorderConfigFingerprint,
  recorderCredentialsInjected,
  recorderInputUrl,
  sanitizeRecorderMessage
} from './recorderInput.js';
import type { CameraConfig } from './types.js';

interface RecorderState {
  camera: CameraConfig;
  process: ChildProcess;
  startedAt: Date;
  restarts: number;
  configFingerprint: string;
}

interface RecorderDiagnostic {
  recording: boolean;
  state: 'starting' | 'recording' | 'retrying' | 'stopped' | 'failed';
  stream_name: string;
  camera_id?: string;
  restarts: number;
  credentials_injected: boolean;
  last_attempt_at?: string;
  next_retry_at?: string | null;
  last_exit_at?: string;
  last_exit_code?: number | null;
  last_exit_signal?: string | null;
  last_error?: string | null;
}

const recorders = new Map<string, RecorderState>();
const recorderDiagnostics = new Map<string, RecorderDiagnostic>();
const restartTimers = new Map<string, NodeJS.Timeout>();
let reloadPromise: Promise<void> | null = null;

function updateDiagnostic(streamName: string, patch: Partial<RecorderDiagnostic>): RecorderDiagnostic {
  const current = recorderDiagnostics.get(streamName);
  const next: RecorderDiagnostic = {
    recording: patch.recording ?? current?.recording ?? false,
    state: patch.state ?? current?.state ?? 'stopped',
    stream_name: streamName,
    camera_id: patch.camera_id ?? current?.camera_id,
    restarts: patch.restarts ?? current?.restarts ?? 0,
    credentials_injected: patch.credentials_injected ?? current?.credentials_injected ?? false,
    last_attempt_at: patch.last_attempt_at ?? current?.last_attempt_at,
    next_retry_at: patch.next_retry_at !== undefined ? patch.next_retry_at : current?.next_retry_at,
    last_exit_at: patch.last_exit_at ?? current?.last_exit_at,
    last_exit_code: patch.last_exit_code !== undefined ? patch.last_exit_code : current?.last_exit_code,
    last_exit_signal: patch.last_exit_signal !== undefined ? patch.last_exit_signal : current?.last_exit_signal,
    last_error: patch.last_error !== undefined ? patch.last_error : current?.last_error
  };
  recorderDiagnostics.set(streamName, next);
  return next;
}

function clearRestartTimer(streamName: string) {
  const timer = restartTimers.get(streamName);
  if (!timer) return;
  clearTimeout(timer);
  restartTimers.delete(streamName);
}

function scheduleRecorderRestart(camera: CameraConfig, nextRestartCount: number) {
  clearRestartTimer(camera.stream_name);

  const delay = Math.min(30_000, 2000 + nextRestartCount * 1000);
  updateDiagnostic(camera.stream_name, {
    recording: false,
    state: 'retrying',
    camera_id: camera.id,
    restarts: nextRestartCount,
    credentials_injected: recorderCredentialsInjected(camera),
    next_retry_at: new Date(Date.now() + delay).toISOString()
  });

  const timer = setTimeout(() => {
    restartTimers.delete(camera.stream_name);
    if (recorders.has(camera.stream_name)) return;
    startRecorder(camera, nextRestartCount).catch((error) => {
      const message = sanitizeRecorderMessage(error instanceof Error ? error.message : String(error), camera);
      updateDiagnostic(camera.stream_name, {
        recording: false,
        state: 'failed',
        last_error: message,
        next_retry_at: null
      });
      console.error(`[recorder:${camera.stream_name}] restart failed: ${message}`);
    });
  }, delay);

  timer.unref?.();
  restartTimers.set(camera.stream_name, timer);
}

export function getRecorderStatus(streamName: string) {
  const state = recorders.get(streamName);
  const diagnostic = recorderDiagnostics.get(streamName);
  if (!state) {
    return diagnostic || {
      recording: false,
      state: 'stopped',
      stream_name: streamName,
      restarts: 0,
      credentials_injected: false
    };
  }
  return {
    ...(diagnostic || {}),
    recording: true,
    state: diagnostic?.state === 'starting' ? 'starting' : 'recording',
    stream_name: streamName,
    pid: state.process.pid,
    startedAt: state.startedAt,
    restarts: state.restarts,
    camera: {
      id: state.camera.id,
      name: state.camera.name,
      stream_name: state.camera.stream_name,
      archive_storage: state.camera.archive_storage || 'node',
      retention_days: state.camera.retention_days
    }
  };
}

export function getAllRecorderStatuses() {
  const streams = new Set<string>([
    ...recorders.keys(),
    ...recorderDiagnostics.keys()
  ]);
  return Array.from(streams).sort().map(getRecorderStatus);
}

async function reloadCamerasInternal(): Promise<void> {
  const cameras = isNodeMode()
    ? await loadAssignedCameras()
    : (await query<CameraConfig>(
        `SELECT id, name, stream_name, source_url, archive_storage, rtmp_push_url, retention_days, is_enabled
           FROM cameras
          WHERE is_enabled = true
          ORDER BY stream_name ASC`
      )).rows;
  const desired = new Map(cameras.map((camera) => [camera.stream_name, camera]));

  for (const [streamName] of recorders) {
    if (!desired.has(streamName)) stopRecorder(streamName, 'disabled or deleted');
  }

  for (const streamName of restartTimers.keys()) {
    if (!desired.has(streamName)) {
      clearRestartTimer(streamName);
      updateDiagnostic(streamName, {
        recording: false,
        state: 'stopped',
        next_retry_at: null,
        last_error: 'disabled or deleted'
      });
    }
  }

  for (const camera of desired.values()) {
    const current = recorders.get(camera.stream_name);
    const nextFingerprint = recorderConfigFingerprint(camera);
    if (!current) {
      await startRecorder(camera, recorderDiagnostics.get(camera.stream_name)?.restarts || 0);
      continue;
    }
    if (current.configFingerprint !== nextFingerprint) {
      stopRecorder(camera.stream_name, 'configuration changed');
      await startRecorder(camera, current.restarts + 1);
    } else {
      current.camera = camera;
    }
  }
}

export function reloadCameras(): Promise<void> {
  if (reloadPromise) return reloadPromise;
  reloadPromise = reloadCamerasInternal().finally(() => {
    reloadPromise = null;
  });
  return reloadPromise;
}

export async function startRecorder(camera: CameraConfig, restarts: number): Promise<void> {
  if (recorders.has(camera.stream_name)) return;
  clearRestartTimer(camera.stream_name);

  const inputUrl = recorderInputUrl(camera);
  if (!inputUrl) throw new Error(`Camera ${camera.stream_name} has no RTSP source URL`);

  await ensureStreamDirs(camera.stream_name);
  const root = streamRoot(camera.stream_name);
  const writesNodeArchive = (camera.archive_storage || 'node') !== 'device';
  const segmentPattern = writesNodeArchive ? '%Y-%m-%d/%H/%Y%m%d_%H%M%S.ts' : 'live/%06d.ts';
  const livePlaylist = 'live.m3u8';
  if (!writesNodeArchive) await fs.mkdir(path.join(root, 'live'), { recursive: true });

  const credentialsInjected = inputUrl !== String(camera.source_url || '').trim();
  updateDiagnostic(camera.stream_name, {
    recording: true,
    state: 'starting',
    camera_id: camera.id,
    restarts,
    credentials_injected: credentialsInjected,
    last_attempt_at: new Date().toISOString(),
    next_retry_at: null,
    last_error: null
  });

  const args = [
    '-hide_banner',
    '-loglevel', process.env.DVR_FFMPEG_LOGLEVEL || 'warning',
    '-fflags', '+genpts+discardcorrupt',
    '-rtsp_transport', process.env.DVR_RTSP_TRANSPORT || 'tcp',
    '-timeout', String(Number(process.env.DVR_RTSP_TIMEOUT_US || 15_000_000)),
    '-analyzeduration', String(Number(process.env.DVR_FFMPEG_ANALYZE_DURATION_US || 3_000_000)),
    '-probesize', String(Number(process.env.DVR_FFMPEG_PROBESIZE || 1_000_000)),
    '-i', inputUrl,
    '-map', '0:v:0',
    '-map', '0:a?',
    '-c:v', 'copy',
    '-c:a', 'aac',
    '-b:a', process.env.DVR_AUDIO_BITRATE || '64k',
    '-ac', process.env.DVR_AUDIO_CHANNELS || '1',
    '-ar', process.env.DVR_AUDIO_RATE || '44100',
    '-af', 'aresample=async=1:first_pts=0'
  ];

  if (camera.rtmp_push_url) {
    const hlsOptions = writesNodeArchive
      ? `hls_time=${config.segmentDuration}:hls_list_size=${config.liveWindow}:hls_flags=temp_file+program_date_time+omit_endlist+independent_segments:strftime=1:strftime_mkdir=1:hls_segment_filename=${segmentPattern}`
      : `hls_time=${config.segmentDuration}:hls_list_size=${config.liveWindow}:hls_flags=temp_file+program_date_time+omit_endlist+independent_segments+delete_segments:hls_delete_threshold=2:hls_segment_filename=${segmentPattern}`;
    args.push('-f', 'tee', `[f=hls:${hlsOptions}]${livePlaylist}|[f=flv]${camera.rtmp_push_url}`);
  } else {
    args.push(
      '-f', 'hls',
      '-hls_time', String(config.segmentDuration),
      '-hls_list_size', String(config.liveWindow),
      '-hls_flags', writesNodeArchive ? 'temp_file+program_date_time+omit_endlist+independent_segments' : 'temp_file+program_date_time+omit_endlist+independent_segments+delete_segments',
      ...(writesNodeArchive ? ['-strftime', '1', '-strftime_mkdir', '1'] : ['-hls_delete_threshold', '2']),
      '-hls_segment_filename', segmentPattern,
      livePlaylist
    );
  }

  const child = spawn(config.ffmpegPath, args, { cwd: root, stdio: ['ignore', 'pipe', 'pipe'] });
  const state: RecorderState = {
    camera,
    process: child,
    startedAt: new Date(),
    restarts,
    configFingerprint: recorderConfigFingerprint(camera)
  };
  recorders.set(camera.stream_name, state);
  console.log(`Started recorder ${camera.stream_name}, pid=${child.pid}, credentials_injected=${credentialsInjected}`);

  let lastMessage = '';
  let finished = false;

  child.once('spawn', () => {
    updateDiagnostic(camera.stream_name, {
      recording: true,
      state: 'recording',
      last_error: null
    });
  });

  child.stderr.on('data', (chunk) => {
    const msg = sanitizeRecorderMessage(String(chunk).trim(), camera);
    if (!msg) return;
    lastMessage = msg;
    updateDiagnostic(camera.stream_name, { last_error: msg });
    console.warn(`[ffmpeg:${camera.stream_name}] ${msg}`);
  });

  const finish = (code: number | null, signal: NodeJS.Signals | null, explicitError?: string) => {
    if (finished) return;
    finished = true;

    const current = recorders.get(camera.stream_name);
    if (current?.process.pid !== child.pid) return;
    recorders.delete(camera.stream_name);

    const message = sanitizeRecorderMessage(explicitError || lastMessage || `FFmpeg exited code=${code} signal=${signal}`, camera);
    const nextRestartCount = restarts + 1;
    updateDiagnostic(camera.stream_name, {
      recording: false,
      state: 'retrying',
      camera_id: camera.id,
      restarts: nextRestartCount,
      credentials_injected: credentialsInjected,
      last_exit_at: new Date().toISOString(),
      last_exit_code: code,
      last_exit_signal: signal,
      last_error: message
    });
    console.warn(`Recorder ${camera.stream_name} exited code=${code} signal=${signal}: ${message}`);
    scheduleRecorderRestart(camera, nextRestartCount);
  };

  child.once('error', (error) => finish(null, null, error.message));
  child.once('exit', (code, signal) => finish(code, signal));
}

export function stopRecorder(streamName: string, reason: string): void {
  clearRestartTimer(streamName);
  const state = recorders.get(streamName);
  if (!state) {
    updateDiagnostic(streamName, {
      recording: false,
      state: 'stopped',
      next_retry_at: null,
      last_error: reason
    });
    return;
  }
  console.log(`Stopping recorder ${streamName}: ${reason}`);
  recorders.delete(streamName);
  updateDiagnostic(streamName, {
    recording: false,
    state: 'stopped',
    camera_id: state.camera.id,
    restarts: state.restarts,
    credentials_injected: recorderCredentialsInjected(state.camera),
    next_retry_at: null,
    last_error: reason
  });
  state.process.kill('SIGTERM');
}

export function stopAllRecorders(): void {
  for (const streamName of Array.from(restartTimers.keys())) clearRestartTimer(streamName);
  for (const streamName of Array.from(recorders.keys())) stopRecorder(streamName, 'shutdown');
}
