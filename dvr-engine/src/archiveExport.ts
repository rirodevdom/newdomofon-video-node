import { createReadStream } from 'node:fs';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { spawn, type ChildProcess } from 'node:child_process';
import type { Express, Request, Response } from 'express';
import { requireMediaToken } from './mediaAuth.js';

function dvrRoot() {
  return process.env.DVR_ROOT || process.env.DVR_DIR || '/var/lib/newdomofon-video/dvr';
}

function ffmpegPath() {
  return process.env.DVR_FFMPEG_PATH || process.env.FFMPEG_PATH || 'ffmpeg';
}

function safeName(value: string) {
  return String(value || '').replace(/[^a-zA-Z0-9_.-]/g, '_').slice(0, 120);
}

function validStreamName(value: string) {
  return /^[a-zA-Z0-9_.-]+$/.test(value);
}

function parseIso(value: unknown) {
  const date = new Date(String(value || ''));
  if (Number.isNaN(date.getTime())) return null;
  return date;
}

function parseSegmentTimeMs(fileName: string) {
  const match = fileName.match(/^(\d{8})_(\d{6})\.(?:ts|m4s)$/);
  if (!match) return null;

  const d = match[1];
  const t = match[2];

  return Date.UTC(
    Number(d.slice(0, 4)),
    Number(d.slice(4, 6)) - 1,
    Number(d.slice(6, 8)),
    Number(t.slice(0, 2)),
    Number(t.slice(2, 4)),
    Number(t.slice(4, 6))
  );
}

async function fileExists(filePath: string) {
  try {
    await fs.access(filePath);
    return true;
  } catch {
    return false;
  }
}

async function waitForFile(filePath: string, timeoutMs: number) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() <= deadline) {
    if (await fileExists(filePath)) return true;
    await new Promise((resolve) => setTimeout(resolve, 200));
  }
  return false;
}

function streamDirectory(streamName: string) {
  return path.resolve(dvrRoot(), streamName);
}

function livePlaylistPath(streamName: string) {
  return path.join(streamDirectory(streamName), 'live.m3u8');
}

async function requireLivePlaylist(streamName: string) {
  const playlist = livePlaylistPath(streamName);
  if (!(await fileExists(playlist))) {
    const error = new Error('Live playlist is not ready') as Error & { statusCode?: number };
    error.statusCode = 404;
    throw error;
  }
  return playlist;
}

function hoursBetween(start: Date, end: Date) {
  const result: Date[] = [];
  const cursor = new Date(Date.UTC(
    start.getUTCFullYear(),
    start.getUTCMonth(),
    start.getUTCDate(),
    start.getUTCHours(),
    0,
    0,
    0
  ));

  const hardLimit = 24 * 14;
  let guard = 0;

  while (cursor <= end && guard < hardLimit) {
    result.push(new Date(cursor));
    cursor.setUTCHours(cursor.getUTCHours() + 1);
    guard += 1;
  }

  return result;
}

async function collectSegments(streamName: string, start: Date, end: Date) {
  const root = path.resolve(dvrRoot(), streamName);
  const startMs = start.getTime();
  const endMs = end.getTime();
  const files: Array<{ filePath: string; timeMs: number }> = [];

  for (const hour of hoursBetween(start, end)) {
    const dir = path.join(
      root,
      `${hour.getUTCFullYear()}-${String(hour.getUTCMonth() + 1).padStart(2, '0')}-${String(hour.getUTCDate()).padStart(2, '0')}`,
      String(hour.getUTCHours()).padStart(2, '0')
    );

    if (!(await fileExists(dir))) continue;

    const entries = await fs.readdir(dir, { withFileTypes: true });

    for (const entry of entries) {
      if (!entry.isFile()) continue;
      if (!/\.(ts|m4s)$/.test(entry.name)) continue;

      const timeMs = parseSegmentTimeMs(entry.name);
      if (timeMs === null) continue;
      if (timeMs < startMs || timeMs > endMs) continue;

      files.push({ filePath: path.join(dir, entry.name), timeMs });
    }
  }

  files.sort((a, b) => a.timeMs - b.timeMs);
  return files.map((item) => item.filePath);
}

function concatEscape(filePath: string) {
  return filePath.replace(/'/g, "'\\''");
}

async function runProcess(args: string[]) {
  return new Promise<void>((resolve, reject) => {
    const child = spawn(ffmpegPath(), args, { stdio: ['ignore', 'ignore', 'pipe'] });
    let stderr = '';

    child.stderr.on('data', (chunk) => {
      stderr = `${stderr}${String(chunk)}`.slice(-8000);
    });
    child.once('error', reject);
    child.once('close', (code) => {
      if (code === 0) resolve();
      else reject(new Error(stderr.trim() || `ffmpeg exited with code ${code}`));
    });
  });
}

async function runFfmpegConcat(listFile: string, outputFile: string) {
  await runProcess([
    '-hide_banner',
    '-loglevel', 'error',
    '-y',
    '-f', 'concat',
    '-safe', '0',
    '-i', listFile,
    '-c', 'copy',
    '-movflags', '+faststart',
    outputFile
  ]);
}

async function cleanup(paths: string[]) {
  await Promise.all(paths.map(async (filePath) => {
    try {
      await fs.rm(filePath, { force: true, recursive: true });
    } catch {
      // Ignore cleanup failures.
    }
  }));
}

async function sendFile(res: Response, filePath: string, contentType: string, cacheControl = 'no-store') {
  const stat = await fs.stat(filePath);
  res.setHeader('content-type', contentType);
  res.setHeader('content-length', String(stat.size));
  res.setHeader('cache-control', cacheControl);
  createReadStream(filePath).pipe(res);
}

type DashState = {
  child: ChildProcess;
  ready: Promise<void>;
  lastUsedAt: number;
  stderr: string;
};

const dashStates = new Map<string, DashState>();
const snapshotJobs = new Map<string, Promise<string>>();
const dashIdleMs = Math.max(30_000, Number(process.env.DVR_DASH_IDLE_MS || 300_000));
const dashReadyTimeoutMs = Math.max(2_000, Number(process.env.DVR_DASH_READY_TIMEOUT_MS || 15_000));

function dashDirectory(streamName: string) {
  return path.join(streamDirectory(streamName), 'dash');
}

function dashManifestPath(streamName: string) {
  return path.join(dashDirectory(streamName), 'live.mpd');
}

async function startDash(streamName: string): Promise<DashState> {
  const existing = dashStates.get(streamName);
  if (existing && existing.child.exitCode === null && !existing.child.killed) {
    existing.lastUsedAt = Date.now();
    await existing.ready;
    return existing;
  }

  const playlist = await requireLivePlaylist(streamName);
  const outputDir = dashDirectory(streamName);
  const manifest = dashManifestPath(streamName);
  await fs.rm(outputDir, { recursive: true, force: true });
  await fs.mkdir(outputDir, { recursive: true });

  const segmentSeconds = Math.max(1, Number(process.env.DVR_DASH_SEGMENT_SECONDS || 2));
  const windowSize = Math.max(3, Number(process.env.DVR_DASH_WINDOW_SIZE || 8));
  const extraWindowSize = Math.max(1, Number(process.env.DVR_DASH_EXTRA_WINDOW_SIZE || 4));

  const args = [
    '-hide_banner',
    '-loglevel', process.env.DVR_FFMPEG_LOGLEVEL || 'warning',
    '-nostdin',
    '-protocol_whitelist', 'file,crypto,data,tcp,http,https,tls',
    '-live_start_index', '-1',
    '-i', playlist,
    '-map', '0:v:0',
    '-map', '0:a?',
    '-c', 'copy',
    '-f', 'dash',
    '-seg_duration', String(segmentSeconds),
    '-window_size', String(windowSize),
    '-extra_window_size', String(extraWindowSize),
    '-use_template', '1',
    '-use_timeline', '1',
    '-remove_at_exit', '0',
    '-init_seg_name', 'init-$RepresentationID$.m4s',
    '-media_seg_name', 'chunk-$RepresentationID$-$Number%05d$.m4s',
    manifest
  ];

  const child = spawn(ffmpegPath(), args, { cwd: outputDir, stdio: ['ignore', 'ignore', 'pipe'] });
  const state: DashState = {
    child,
    ready: Promise.resolve(),
    lastUsedAt: Date.now(),
    stderr: ''
  };

  state.ready = (async () => {
    const ready = await waitForFile(manifest, dashReadyTimeoutMs);
    if (!ready) {
      try { child.kill('SIGTERM'); } catch { /* ignored */ }
      throw new Error(state.stderr || 'DASH manifest was not created in time');
    }
  })();

  child.stderr?.on('data', (chunk) => {
    state.stderr = `${state.stderr}${String(chunk)}`.slice(-8000);
  });
  child.once('error', (error) => {
    state.stderr = error.message;
  });
  child.once('exit', () => {
    if (dashStates.get(streamName) === state) dashStates.delete(streamName);
  });

  dashStates.set(streamName, state);
  await state.ready;
  return state;
}

function touchDash(streamName: string) {
  const state = dashStates.get(streamName);
  if (state) state.lastUsedAt = Date.now();
}

setInterval(() => {
  const now = Date.now();
  for (const [streamName, state] of dashStates) {
    if (now - state.lastUsedAt <= dashIdleMs) continue;
    dashStates.delete(streamName);
    try { state.child.kill('SIGTERM'); } catch { /* ignored */ }
  }
}, 30_000).unref?.();

function dashUri(raw: string, token: string) {
  const clean = String(raw || '').split('?')[0].replace(/^\/+/, '').replace(/^dash\//, '');
  return `dash/${clean}?token=${encodeURIComponent(token)}`;
}

function rewriteDashManifest(body: string, token: string) {
  return body.replace(/\b(initialization|media)="([^"]+)"/g, (_match, key, uri) => {
    return `${key}="${dashUri(uri, token)}"`;
  });
}

async function generateSnapshot(streamName: string) {
  const existing = snapshotJobs.get(streamName);
  if (existing) return existing;

  const job = (async () => {
    const playlist = await requireLivePlaylist(streamName);
    const dir = path.join(streamDirectory(streamName), '.formats');
    const target = path.join(dir, 'snapshot.jpg');
    const maxAgeMs = Math.max(500, Number(process.env.DVR_SNAPSHOT_CACHE_MS || 3000));

    try {
      const stat = await fs.stat(target);
      if (Date.now() - stat.mtimeMs <= maxAgeMs) return target;
    } catch {
      // Generate the first snapshot.
    }

    await fs.mkdir(dir, { recursive: true });
    const temporary = path.join(dir, `snapshot-${process.pid}-${Date.now()}.jpg`);

    try {
      await runProcess([
        '-hide_banner',
        '-loglevel', 'error',
        '-nostdin',
        '-protocol_whitelist', 'file,crypto,data,tcp,http,https,tls',
        '-live_start_index', '-1',
        '-i', playlist,
        '-map', '0:v:0',
        '-frames:v', '1',
        '-q:v', String(Math.max(2, Number(process.env.DVR_SNAPSHOT_JPEG_QUALITY || 3))),
        '-y',
        temporary
      ]);
      await fs.rename(temporary, target);
      return target;
    } finally {
      await fs.rm(temporary, { force: true }).catch(() => undefined);
    }
  })();

  snapshotJobs.set(streamName, job);
  try {
    return await job;
  } finally {
    snapshotJobs.delete(streamName);
  }
}

function handleRouteError(res: Response, error: unknown) {
  if (res.headersSent) {
    try { res.end(); } catch { /* ignored */ }
    return;
  }
  const status = error && typeof error === 'object' && 'statusCode' in error
    ? Number((error as { statusCode?: unknown }).statusCode)
    : 500;
  const message = error instanceof Error ? error.message : String(error);
  res.status(Number.isInteger(status) && status >= 400 && status <= 599 ? status : 500).json({ error: message });
}

export function registerArchiveExportRoute(app: Express) {
  app.get('/cameras/:streamName/live.ts', requireMediaToken(['live']), async (req: Request, res: Response) => {
    const streamName = String(req.params.streamName || '');
    if (!validStreamName(streamName)) return res.status(400).json({ error: 'Invalid stream name' });

    try {
      const playlist = await requireLivePlaylist(streamName);
      const child = spawn(ffmpegPath(), [
        '-hide_banner',
        '-loglevel', 'error',
        '-nostdin',
        '-protocol_whitelist', 'file,crypto,data,tcp,http,https,tls',
        '-live_start_index', '-1',
        '-i', playlist,
        '-map', '0:v:0',
        '-map', '0:a?',
        '-c', 'copy',
        '-f', 'mpegts',
        'pipe:1'
      ], { stdio: ['ignore', 'pipe', 'pipe'] });

      let stderr = '';
      child.stderr.on('data', (chunk) => {
        stderr = `${stderr}${String(chunk)}`.slice(-4000);
      });

      res.setHeader('content-type', 'video/mp2t');
      res.setHeader('cache-control', 'no-store');
      res.setHeader('x-accel-buffering', 'no');
      child.stdout.pipe(res);

      const stop = () => {
        if (child.exitCode !== null || child.killed) return;
        try { child.kill('SIGTERM'); } catch { /* ignored */ }
      };
      req.once('close', stop);
      res.once('close', stop);
      child.once('error', (error) => handleRouteError(res, error));
      child.once('exit', (code) => {
        if (code && !res.writableEnded) {
          console.warn(`[live-ts:${streamName}] ffmpeg exited code=${code}: ${stderr}`);
          res.end();
        }
      });
    } catch (error) {
      handleRouteError(res, error);
    }
  });

  app.get('/cameras/:streamName/live.mpd', requireMediaToken(['live']), async (req: Request, res: Response) => {
    const streamName = String(req.params.streamName || '');
    if (!validStreamName(streamName)) return res.status(400).json({ error: 'Invalid stream name' });

    try {
      await startDash(streamName);
      touchDash(streamName);
      const body = await fs.readFile(dashManifestPath(streamName), 'utf8');
      res.setHeader('content-type', 'application/dash+xml; charset=utf-8');
      res.setHeader('cache-control', 'no-store');
      return res.send(rewriteDashManifest(body, String(req.query.token || '')));
    } catch (error) {
      return handleRouteError(res, error);
    }
  });

  app.get('/cameras/:streamName/dash/:filename', requireMediaToken(['live', 'file']), async (req: Request, res: Response) => {
    const streamName = String(req.params.streamName || '');
    const filename = String(req.params.filename || '');
    if (!validStreamName(streamName) || !/^[a-zA-Z0-9_.%$-]+\.m4s$/.test(filename)) {
      return res.status(400).json({ error: 'Invalid DASH path' });
    }

    try {
      touchDash(streamName);
      const filePath = path.join(dashDirectory(streamName), filename);
      if (!(await fileExists(filePath))) return res.status(404).json({ error: 'DASH segment not found' });
      return sendFile(res, filePath, 'video/iso.segment', 'public, max-age=30');
    } catch (error) {
      return handleRouteError(res, error);
    }
  });

  app.get('/cameras/:streamName/snapshot.jpg', requireMediaToken(['live']), async (req: Request, res: Response) => {
    const streamName = String(req.params.streamName || '');
    if (!validStreamName(streamName)) return res.status(400).json({ error: 'Invalid stream name' });

    try {
      const snapshot = await generateSnapshot(streamName);
      return sendFile(res, snapshot, 'image/jpeg', 'no-cache, max-age=1');
    } catch (error) {
      return handleRouteError(res, error);
    }
  });

  app.get('/cameras/:streamName/export.mp4', requireMediaToken(['export']), async (req: Request, res: Response) => {
    const streamName = safeName(req.params.streamName);
    const start = parseIso(req.query.start);
    const end = parseIso(req.query.end);

    if (!streamName || !start || !end) {
      return res.status(400).json({ error: 'streamName, start and end are required' });
    }

    const durationMs = end.getTime() - start.getTime();
    if (durationMs <= 0) {
      return res.status(400).json({ error: 'Invalid time range' });
    }

    if (durationMs > 6 * 60 * 60 * 1000) {
      return res.status(400).json({ error: 'Export range is too large. Maximum is 6 hours.' });
    }

    const segments = await collectSegments(streamName, start, end);
    if (!segments.length) {
      return res.status(404).json({ error: 'No archive segments in selected range' });
    }

    if (segments.length > 6000) {
      return res.status(400).json({ error: 'Too many segments for export. Reduce the selected range.' });
    }

    const tmpDir = await fs.mkdtemp(path.join(os.tmpdir(), `nd-export-${streamName}-`));
    const listFile = path.join(tmpDir, 'segments.ffconcat');
    const outputFile = path.join(tmpDir, `${streamName}-${start.toISOString()}-${end.toISOString()}.mp4`.replace(/[:]/g, '-'));

    try {
      const list = [
        'ffconcat version 1.0',
        ...segments.map((segment) => `file '${concatEscape(segment)}'`)
      ].join('\n');

      await fs.writeFile(listFile, list, 'utf8');
      await runFfmpegConcat(listFile, outputFile);

      const stat = await fs.stat(outputFile);
      const fileName = `${streamName}_${start.toISOString().replace(/[:.]/g, '-')}_${end.toISOString().replace(/[:.]/g, '-')}.mp4`;

      res.setHeader('content-type', 'video/mp4');
      res.setHeader('content-length', String(stat.size));
      res.setHeader('content-disposition', `attachment; filename="${fileName}"`);

      const stream = createReadStream(outputFile);
      stream.pipe(res);

      res.on('finish', () => {
        void cleanup([tmpDir]);
      });
      res.on('close', () => {
        void cleanup([tmpDir]);
      });
    } catch (error: any) {
      await cleanup([tmpDir]);
      console.error('[dvr-export] failed', {
        streamName,
        start: start.toISOString(),
        end: end.toISOString(),
        segments: segments.length,
        error: error?.message || String(error)
      });

      return res.status(500).json({
        error: 'Export failed',
        detail: error?.message || String(error)
      });
    }
  });
}
