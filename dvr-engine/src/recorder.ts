import { spawn, type ChildProcess } from 'node:child_process';
import path from 'node:path';
import fs from 'node:fs/promises';
import { config } from './config.js';
import { query } from './db.js';
import { isNodeMode, loadAssignedCameras } from './nodeClient.js';
import { ensureStreamDirs, streamRoot } from './storage.js';
import type { CameraConfig } from './types.js';

interface RecorderState {
  camera: CameraConfig;
  process: ChildProcess;
  startedAt: Date;
  restarts: number;
}

const recorders = new Map<string, RecorderState>();
const restartTimers = new Map<string, NodeJS.Timeout>();

function clearRestartTimer(streamName: string) {
  const timer = restartTimers.get(streamName);
  if (!timer) return;
  clearTimeout(timer);
  restartTimers.delete(streamName);
}

function scheduleRecorderRestart(camera: CameraConfig, restarts: number) {
  clearRestartTimer(camera.stream_name);

  const delay = Math.min(30_000, 2000 + restarts * 1000);
  const timer = setTimeout(() => {
    restartTimers.delete(camera.stream_name);
    if (recorders.has(camera.stream_name)) return;
    startRecorder(camera, restarts + 1).catch(console.error);
  }, delay);

  timer.unref?.();
  restartTimers.set(camera.stream_name, timer);
}

export function getRecorderStatus(streamName: string) {
  const state = recorders.get(streamName);
  if (!state) return { recording: false };
  return {
    recording: true,
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
  return Array.from(recorders.keys()).map(getRecorderStatus);
}

export async function reloadCameras(): Promise<void> {
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

  for (const camera of desired.values()) {
    const current = recorders.get(camera.stream_name);
    if (!current) {
      await startRecorder(camera, 0);
      continue;
    }
    if (
      current.camera.source_url !== camera.source_url ||
      current.camera.rtmp_push_url !== camera.rtmp_push_url ||
      current.camera.archive_storage !== camera.archive_storage
    ) {
      stopRecorder(camera.stream_name, 'configuration changed');
      await startRecorder(camera, current.restarts + 1);
    } else {
      current.camera = camera;
    }
  }
}

export async function startRecorder(camera: CameraConfig, restarts: number): Promise<void> {
  if (recorders.has(camera.stream_name)) return;
  clearRestartTimer(camera.stream_name);

  await ensureStreamDirs(camera.stream_name);
  const root = streamRoot(camera.stream_name);
  const writesNodeArchive = (camera.archive_storage || 'node') !== 'device';
  const segmentPattern = writesNodeArchive ? '%Y-%m-%d/%H/%Y%m%d_%H%M%S.ts' : 'live/%06d.ts';
  const livePlaylist = 'live.m3u8';
  if (!writesNodeArchive) await fs.mkdir(path.join(root, 'live'), { recursive: true });

  const args = [
    '-hide_banner',
    '-loglevel', process.env.DVR_FFMPEG_LOGLEVEL || 'warning',
    '-fflags', '+genpts+discardcorrupt',
    '-rtsp_transport', process.env.DVR_RTSP_TRANSPORT || 'tcp',
    '-timeout', String(Number(process.env.DVR_RTSP_TIMEOUT_US || 15_000_000)),
    '-analyzeduration', String(Number(process.env.DVR_FFMPEG_ANALYZE_DURATION_US || 3_000_000)),
    '-probesize', String(Number(process.env.DVR_FFMPEG_PROBESIZE || 1_000_000)),
    '-i', camera.source_url,
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
      '-hls_flags', writesNodeArchive ? 'temp_file+program_date_time+omit_endlist+independent_segments' : 'temp_file+program_date_time+omitendlist+independent_segments+delete_segments'.replace('omitendlist', 'omit_endlist'),
      ...(writesNodeArchive ? ['-strftime', '1', '-strftime_mkdir', '1'] : ['-hls_delete_threshold', '2']),
      '-hls_segment_filename', segmentPattern,
      livePlaylist
    );
  }

  const child = spawn(config.ffmpegPath, args, { cwd: root, stdio: ['ignore', 'pipe', 'pipe'] });
  const state: RecorderState = { camera, process: child, startedAt: new Date(), restarts };
  recorders.set(camera.stream_name, state);
  console.log(`Started recorder ${camera.stream_name}, pid=${child.pid}`);

  child.stderr.on('data', (chunk) => {
    const msg = String(chunk).trim();
    if (msg) console.warn(`[ffmpeg:${camera.stream_name}] ${msg}`);
  });

  child.on('exit', (code, signal) => {
    const current = recorders.get(camera.stream_name);
    if (current?.process.pid !== child.pid) return;
    recorders.delete(camera.stream_name);
    console.warn(`Recorder ${camera.stream_name} exited code=${code} signal=${signal}`);
    scheduleRecorderRestart(camera, restarts + 1);
  });
}

export function stopRecorder(streamName: string, reason: string): void {
  clearRestartTimer(streamName);
  const state = recorders.get(streamName);
  if (!state) return;
  console.log(`Stopping recorder ${streamName}: ${reason}`);
  recorders.delete(streamName);
  state.process.kill('SIGTERM');
}

export function stopAllRecorders(): void {
  for (const streamName of Array.from(restartTimers.keys())) clearRestartTimer(streamName);
  for (const streamName of Array.from(recorders.keys())) stopRecorder(streamName, 'shutdown');
}
