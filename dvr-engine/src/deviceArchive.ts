import crypto from 'node:crypto';
import { spawn, type ChildProcess } from 'node:child_process';
import path from 'node:path';
import fs from 'node:fs/promises';
import { config } from './config.js';
import { loadAssignedCameras } from './nodeClient.js';
import { safeStreamName } from './storage.js';
import { DeviceArchiveRangeError, playbackUrlsForRange, searchHikvisionArchive, type HikvisionPlaybackCandidate } from './hikvisionArchive.js';
import type { CameraConfig } from './types.js';

interface Session {
  id: string;
  dir: string;
  playlist: string;
  process: ChildProcess | null;
  status: 'preparing' | 'ready' | 'error';
  startedAt: number;
  lastAccessAt: number;
  start: Date;
  end: Date;
  streamName: string;
  deviceKey: string;
  promise?: Promise<void>;
  error?: string;
  errorStatusCode?: number;
  lastError?: string;
}

const sessions = new Map<string, Session>();

function boolEnv(name: string, fallback = false): boolean {
  const raw = process.env[name];
  if (!raw) return fallback;
  return ['1', 'true', 'yes', 'on'].includes(raw.toLowerCase());
}

const archiveRoot = process.env.DVR_DEVICE_ARCHIVE_ROOT || '/tmp/newdomofon-video-device-archive';
const maxRangeSeconds = Math.max(30, Number(process.env.DVR_DEVICE_ARCHIVE_MAX_RANGE_SECONDS || 300));
const minPlaybackSeconds = Math.max(2, Number(process.env.DVR_DEVICE_ARCHIVE_MIN_PLAYBACK_SECONDS || 30));
const firstSegmentTimeoutMs = Math.max(1000, Number(process.env.DVR_DEVICE_ARCHIVE_FIRST_SEGMENT_TIMEOUT_MS || 15_000));
const transcode = (process.env.DVR_DEVICE_ARCHIVE_MODE || 'transcode') === 'transcode';
const keepSessionMs = Math.max(60_000, Number(process.env.DVR_DEVICE_ARCHIVE_KEEP_MS || 15 * 60_000));
const useWallclockAsTimestamps = boolEnv('DVR_DEVICE_ARCHIVE_WALLCLOCK_TIMESTAMPS', false);
const sessionWindowSeconds = Math.max(minPlaybackSeconds, Number(process.env.DVR_DEVICE_ARCHIVE_SESSION_WINDOW_SECONDS || maxRangeSeconds));
const sessionAlignSeconds = Math.max(1, Number(process.env.DVR_DEVICE_ARCHIVE_SESSION_ALIGN_SECONDS || 30));
const maxDeviceSessions = Math.max(1, Number(process.env.DVR_DEVICE_ARCHIVE_MAX_SESSIONS_PER_DEVICE || 1));

function sessionId(streamName: string, start: Date, end: Date): string {
  return crypto.createHash('sha256').update(`${streamName}|${start.toISOString()}|${end.toISOString()}`).digest('hex').slice(0, 24);
}

function normalizeSessionRange(start: Date, requestedEnd: Date): { start: Date; end: Date } {
  const alignMs = sessionAlignSeconds * 1000;
  const sessionStart = new Date(Math.floor(start.getTime() / alignMs) * alignMs);
  const minEnd = new Date(start.getTime() + minPlaybackSeconds * 1000);
  const requestedEndWithMin = requestedEnd < minEnd ? minEnd : requestedEnd;
  const sessionEnd = new Date(sessionStart.getTime() + sessionWindowSeconds * 1000);
  const maxEnd = new Date(sessionStart.getTime() + maxRangeSeconds * 1000);
  const wantedEnd = requestedEndWithMin > sessionEnd ? requestedEndWithMin : sessionEnd;
  const end = wantedEnd > maxEnd ? maxEnd : wantedEnd;
  return { start: sessionStart, end };
}

function deviceKeyFromCamera(camera: CameraConfig): string {
  if (camera.device_id) return `device:${camera.device_id}`;
  if (camera.device_host) return `host:${String(camera.device_host).toLowerCase()}`;
  try {
    const parsed = new URL(camera.source_url);
    return `rtsp:${parsed.hostname}:${parsed.port || '554'}`;
  } catch {
    return `stream:${camera.stream_name}`;
  }
}

async function findCamera(streamName: string) {
  const cameras = await loadAssignedCameras();
  return cameras.find((camera) => camera.stream_name === streamName) || null;
}

async function fileExists(file: string): Promise<boolean> {
  try {
    await fs.access(file);
    return true;
  } catch {
    return false;
  }
}

async function hasReadySegments(dir: string): Promise<boolean> {
  try {
    const files = await fs.readdir(dir);
    return files.some((file) => /^seg_\d+\.ts$/.test(file));
  } catch {
    return false;
  }
}

async function waitForPlaylist(session: Session, timeoutMs = firstSegmentTimeoutMs): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (session.error) {
      const details = session.lastError ? `${session.error}: ${session.lastError}` : session.error;
      const error = new Error(details) as Error & { statusCode?: number };
      error.statusCode = session.errorStatusCode || 502;
      throw error;
    }
    if (await fileExists(session.playlist) && await hasReadySegments(session.dir)) {
      session.status = 'ready';
      return;
    }
    await new Promise((resolve) => setTimeout(resolve, 300));
  }
  const error = new Error('Device archive did not produce HLS segments in time') as Error & { statusCode?: number };
  error.statusCode = 504;
  throw error;
}

async function clearSessionOutput(dir: string): Promise<void> {
  try {
    const files = await fs.readdir(dir);
    await Promise.all(files
      .filter((file) => /^index\.m3u8(?:\.tmp)?$/.test(file) || /^seg_\d+\.ts(?:\.tmp)?$/.test(file))
      .map((file) => fs.rm(path.join(dir, file), { force: true })));
  } catch {
    // ignore cleanup errors; the next ffmpeg attempt will surface its own failure if needed.
  }
}

async function destroySession(session: Session, reason: string): Promise<void> {
  if (session.process) {
    session.process.kill('SIGTERM');
    session.process = null;
  }
  sessions.delete(session.id);
  await fs.rm(session.dir, { recursive: true, force: true }).catch(() => undefined);
  console.log(`[device-archive:${session.streamName}] closed session ${session.id}: ${reason}`);
}

async function parkSession(session: Session, reason: string): Promise<void> {
  if (session.process) {
    session.process.kill('SIGTERM');
    session.process = null;
  }
  session.lastAccessAt = Date.now();
  if (await fileExists(session.playlist) && await hasReadySegments(session.dir)) {
    session.status = 'ready';
    session.error = undefined;
    session.errorStatusCode = undefined;
    console.log(`[device-archive:${session.streamName}] parked session ${session.id}: ${reason}`);
    return;
  }
  await destroySession(session, reason);
}

async function enforceDeviceConcurrency(deviceKey: string, keepId: string): Promise<void> {
  const active = [...sessions.values()]
    .filter((session) => session.deviceKey === deviceKey && session.id !== keepId && session.process)
    .sort((a, b) => a.lastAccessAt - b.lastAccessAt);

  while (active.length >= maxDeviceSessions) {
    const victim = active.shift();
    if (!victim) break;
    await parkSession(victim, 'device concurrency limit');
  }
}

function archiveArgs(playback: HikvisionPlaybackCandidate, duration: number): string[] {
  const args = [
    '-hide_banner',
    '-loglevel', 'warning',
    '-rtsp_transport', process.env.DVR_DEVICE_ARCHIVE_RTSP_TRANSPORT || 'tcp',
    '-timeout', String(Number(process.env.DVR_DEVICE_ARCHIVE_TIMEOUT_US || 15_000_000)),
    ...(useWallclockAsTimestamps ? ['-use_wallclock_as_timestamps', '1'] : []),
    '-i', playback.url,
    '-t', String(duration)
  ];

  if (transcode) {
    args.push(
      '-map', '0:v:0',
      '-map', '0:a?',
      '-c:v', 'libx264',
      '-preset', process.env.DVR_DEVICE_ARCHIVE_X264_PRESET || 'veryfast',
      '-tune', 'zerolatency',
      '-g', String(Number(process.env.DVR_DEVICE_ARCHIVE_GOP || 50)),
      '-sc_threshold', '0',
      '-c:a', 'aac',
      '-b:a', process.env.DVR_AUDIO_BITRATE || '64k',
      '-ac', process.env.DVR_AUDIO_CHANNELS || '1',
      '-ar', process.env.DVR_AUDIO_RATE || '44100'
    );
  } else {
    args.push('-map', '0:v:0', '-map', '0:a?', '-c:v', 'copy', '-c:a', 'aac');
  }

  args.push(
    '-f', 'hls',
    '-hls_time', String(Number(process.env.DVR_DEVICE_ARCHIVE_SEGMENT_SECONDS || 2)),
    '-hls_list_size', '0',
    '-hls_flags', 'temp_file+program_date_time+independent_segments',
    '-hls_segment_filename', 'seg_%06d.ts',
    'index.m3u8'
  );

  return args;
}

async function spawnArchiveAttempt(camera: CameraConfig, playbacks: HikvisionPlaybackCandidate[], start: Date, end: Date, session: Session, attempt: number): Promise<void> {
  const playback = playbacks[attempt];
  if (!playback) {
    session.error = 'Device archive has no playback candidates';
    session.errorStatusCode = 404;
    session.status = 'error';
    return;
  }

  const duration = Math.max(1, Math.ceil((end.getTime() - start.getTime()) / 1000));
  console.log(`[device-archive:${camera.stream_name}] source=${playback.source} attempt=${attempt + 1}/${playbacks.length} track=${playback.trackId || ''} start=${start.toISOString()} end=${end.toISOString()}`);
  const args = archiveArgs(playback, duration);
  const child = spawn(config.ffmpegPath, args, { cwd: session.dir, stdio: ['ignore', 'ignore', 'pipe'] });
  session.process = child;
  session.status = 'preparing';
  let stderrTail = '';
  child.stderr.on('data', (chunk) => {
    const message = String(chunk).trim();
    if (!message) return;
    stderrTail = `${stderrTail}\n${message}`.slice(-4000);
    console.warn(`[device-archive:${camera.stream_name}] ${message}`);
  });
  child.on('exit', async (code, signal) => {
    const ready = await fileExists(session.playlist) && await hasReadySegments(session.dir);
    if (!ready) {
      const exitText = `ffmpeg source=${playback.source} exited code=${code ?? ''} signal=${signal || ''}`.trim();
      session.lastError = stderrTail ? `${exitText}; stderr=${stderrTail}` : exitText;
      if (!ready && attempt + 1 < playbacks.length) {
        console.warn(`[device-archive:${camera.stream_name}] ${exitText}; retrying next playback candidate`);
        await clearSessionOutput(session.dir);
        await spawnArchiveAttempt(camera, playbacks, start, end, session, attempt + 1);
        return;
      }

      session.error = 'Device archive ffmpeg did not produce HLS segments';
      session.errorStatusCode = 502;
      session.status = 'error';
      console.warn(`[device-archive:${camera.stream_name}] ${session.error}: ${session.lastError || ''}`);
    }
    session.process = null;
  });
}

async function spawnArchive(camera: CameraConfig, start: Date, end: Date, session: Session) {
  await enforceDeviceConcurrency(session.deviceKey, session.id);
  const playbacks = await playbackUrlsForRange(camera, start, end);
  await spawnArchiveAttempt(camera, playbacks, start, end, session, 0);
}

function rewritePlaylistTiming(body: string, streamName: string, sessionIdValue: string, start: Date, token: string): string {
  let cursor = start.getTime();
  let lastDurationMs = 0;
  const lines: string[] = [];

  for (const rawLine of body.split(/\r?\n/)) {
    const line = rawLine.trim();
    if (!line) continue;
    if (line.startsWith('#EXT-X-PROGRAM-DATE-TIME:')) continue;
    if (line.startsWith('#EXT-X-PLAYLIST-TYPE:')) continue;
    if (line.startsWith('#EXTINF:')) {
      const duration = Number(line.slice(8).split(',')[0]);
      lastDurationMs = Number.isFinite(duration) ? Math.max(0, duration * 1000) : 0;
      lines.push(`#EXT-X-PROGRAM-DATE-TIME:${new Date(cursor).toISOString()}`);
      lines.push(line);
      continue;
    }
    if (!line.startsWith('#')) {
      const suffix = token ? `?token=${encodeURIComponent(token)}` : '';
      lines.push(`/device-archive/${encodeURIComponent(streamName)}/${sessionIdValue}/${line}${suffix}`);
      cursor += lastDurationMs;
      continue;
    }
    lines.push(line);
  }

  return `${lines.join('\n')}\n`;
}

function findReusableSession(streamName: string, start: Date, end: Date): Session | null {
  for (const session of sessions.values()) {
    if (session.streamName !== streamName) continue;
    if (start.getTime() < session.start.getTime()) continue;
    if (end.getTime() > session.end.getTime()) continue;
    if (session.status === 'error') continue;
    return session;
  }
  return null;
}

async function getOrCreateSession(streamName: string, requestedStart: Date, requestedEnd: Date): Promise<{ session: Session; camera: CameraConfig }> {
  if (!safeStreamName(streamName)) throw new Error('Invalid stream name');
  const camera = await findCamera(streamName);
  if (!camera) throw new Error('Camera is not assigned to this node');

  const normalized = normalizeSessionRange(requestedStart, requestedEnd);
  if (normalized.end <= normalized.start) throw new DeviceArchiveRangeError('Invalid device archive playback range');

  const reusable = findReusableSession(streamName, requestedStart, requestedEnd) || sessions.get(sessionId(streamName, normalized.start, normalized.end));
  if (reusable && !reusable.error) {
    reusable.lastAccessAt = Date.now();
    if (!reusable.promise && !reusable.process && reusable.status !== 'ready') {
      reusable.promise = spawnArchive(camera, reusable.start, reusable.end, reusable).catch((error) => {
        reusable.error = error instanceof Error ? error.message : String(error);
        reusable.errorStatusCode = error && typeof error === 'object' && 'statusCode' in error
          ? Number((error as { statusCode?: unknown }).statusCode)
          : 502;
        reusable.status = 'error';
        console.warn(`[device-archive:${camera.stream_name}] session restart failed: ${reusable.error}`);
      });
    }
    return { session: reusable, camera };
  }

  if (reusable?.error) {
    await destroySession(reusable, 'stale error session');
  }

  const id = sessionId(streamName, normalized.start, normalized.end);
  const dir = path.join(archiveRoot, id);
  const playlist = path.join(dir, 'index.m3u8');
  await fs.mkdir(dir, { recursive: true });

  const createdSession: Session = {
    id,
    dir,
    playlist,
    process: null,
    status: 'preparing',
    startedAt: Date.now(),
    lastAccessAt: Date.now(),
    start: normalized.start,
    end: normalized.end,
    streamName,
    deviceKey: deviceKeyFromCamera(camera)
  };
  sessions.set(id, createdSession);
  createdSession.promise = spawnArchive(camera, normalized.start, normalized.end, createdSession).catch((error) => {
    createdSession.error = error instanceof Error ? error.message : String(error);
    createdSession.errorStatusCode = error && typeof error === 'object' && 'statusCode' in error
      ? Number((error as { statusCode?: unknown }).statusCode)
      : 502;
    createdSession.status = 'error';
    console.warn(`[device-archive:${camera.stream_name}] session start failed: ${createdSession.error}`);
  });
  console.log(`[device-archive:${streamName}] session=${id} status=preparing start=${normalized.start.toISOString()} end=${normalized.end.toISOString()} device=${createdSession.deviceKey}`);
  return { session: createdSession, camera };
}

async function sessionPayload(session: Session, streamName: string, token: string) {
  const ready = await fileExists(session.playlist) && await hasReadySegments(session.dir);
  if (ready) session.status = 'ready';
  return {
    session_id: session.id,
    status: session.error ? 'error' : session.status,
    ready: ready && !session.error,
    start: session.start.toISOString(),
    end: session.end.toISOString(),
    playlist_path: `/cameras/${encodeURIComponent(streamName)}/device-archive.m3u8`,
    playlist_url: `/cameras/${encodeURIComponent(streamName)}/device-archive.m3u8?${new URLSearchParams({ start: session.start.toISOString(), end: session.end.toISOString(), token }).toString()}`,
    error: session.error,
    error_status_code: session.errorStatusCode,
    last_error: session.lastError
  };
}

export async function prepareDeviceArchiveSession(streamName: string, start: Date, requestedEnd: Date, token: string, waitMs: number) {
  const { session } = await getOrCreateSession(streamName, start, requestedEnd);
  if (waitMs > 0 && !session.error) {
    try {
      await waitForPlaylist(session, waitMs);
    } catch (error) {
      if (error && typeof error === 'object' && 'statusCode' in error && Number((error as { statusCode?: unknown }).statusCode) !== 504) {
        throw error;
      }
    }
  }
  return sessionPayload(session, streamName, token);
}

export async function createDeviceArchivePlaylist(streamName: string, start: Date, requestedEnd: Date, token: string) {
  const { session } = await getOrCreateSession(streamName, start, requestedEnd);

  await waitForPlaylist(session);
  const body = await fs.readFile(session.playlist, 'utf8');
  return rewritePlaylistTiming(body, streamName, session.id, session.start, token);
}

export async function listDeviceArchiveRanges(streamName: string, start: Date, end: Date) {
  if (!safeStreamName(streamName)) throw new Error('Invalid stream name');
  const camera = await findCamera(streamName);
  if (!camera) throw new Error('Camera is not assigned to this node');
  try {
    const items = await searchHikvisionArchive(camera, start, end);
    return items.map((item) => ({
      start: item.start,
      end: item.end,
      source: 'device',
      track_id: item.trackId
    }));
  } catch (error) {
    console.warn('[device-archive] ranges search failed', streamName, error instanceof Error ? error.message : error);
    return [];
  }
}

export async function deviceArchiveFile(sessionIdValue: string, filename: string) {
  if (!/^[a-f0-9]{24}$/.test(sessionIdValue) || !/^seg_\d+\.ts$/.test(filename)) return null;
  const file = path.join(archiveRoot, sessionIdValue, filename);
  try {
    await fs.access(file);
    return file;
  } catch {
    return null;
  }
}

export function cleanupDeviceArchiveSessions() {
  const now = Date.now();
  for (const [id, session] of sessions) {
    if (now - session.lastAccessAt < keepSessionMs) continue;
    if (session.process) session.process.kill('SIGTERM');
    sessions.delete(id);
    fs.rm(session.dir, { recursive: true, force: true }).catch(() => undefined);
  }
}
