import { spawn } from 'node:child_process';
import fs from 'node:fs/promises';
import path from 'node:path';
import type express from 'express';
import { config } from './config.js';
import { requireMediaToken } from './mediaAuth.js';
import { listSegments, safeStreamName, streamRoot } from './storage.js';

const SNAPSHOT_TIMEOUT_MS = Math.max(3000, Number(process.env.DVR_SNAPSHOT_TIMEOUT_MS || 15000));
const SNAPSHOT_LOCAL_TIMEOUT_MS = Math.max(1000, Math.min(SNAPSHOT_TIMEOUT_MS, Number(process.env.DVR_SNAPSHOT_LOCAL_TIMEOUT_MS || 5000)));
const SNAPSHOT_MAX_BYTES = Math.max(256 * 1024, Number(process.env.DVR_SNAPSHOT_MAX_BYTES || 8 * 1024 * 1024));
const SNAPSHOT_WIDTH = Math.max(320, Math.min(1920, Number(process.env.DVR_SNAPSHOT_WIDTH || 1280)));
const SNAPSHOT_CACHE_TTL_MS = Math.max(1000, Number(process.env.DVR_SNAPSHOT_CACHE_TTL_MS || 10000));
const SNAPSHOT_STALE_MAX_AGE_MS = Math.max(SNAPSHOT_CACHE_TTL_MS, Number(process.env.DVR_SNAPSHOT_STALE_MAX_AGE_MS || 300000));

type SnapshotSource = 'live-segment' | 'archive' | 'live-playlist';
type SnapshotCacheMode = 'fresh' | 'stale' | 'miss';

interface SnapshotInput {
  file: string;
  cwd: string;
  source: SnapshotSource;
}

interface CachedSnapshot {
  image: Buffer;
  ageMs: number;
}

interface GeneratedSnapshot {
  image: Buffer;
  source: SnapshotSource;
}

const snapshotJobs = new Map<string, Promise<GeneratedSnapshot>>();

async function readable(file: string): Promise<boolean> {
  try {
    await fs.access(file);
    return true;
  } catch {
    return false;
  }
}

function safePlaylistSegment(root: string, value: string): string | null {
  const raw = value.trim().split(/[?#]/, 1)[0];
  if (!raw || !raw.toLowerCase().endsWith('.ts')) return null;

  let decoded = raw;
  try {
    decoded = decodeURIComponent(raw);
  } catch {
    // FFmpeg normally writes plain relative paths. Keep the raw value if a
    // malformed escape somehow appears instead of rejecting the whole playlist.
  }

  if (path.isAbsolute(decoded)) return null;
  const rootResolved = path.resolve(root);
  const candidate = path.resolve(rootResolved, decoded);
  if (candidate !== rootResolved && !candidate.startsWith(rootResolved + path.sep)) return null;
  return candidate;
}

async function latestCompletedLiveSegment(root: string, livePlaylist: string): Promise<string | null> {
  let playlist: string;
  try {
    playlist = await fs.readFile(livePlaylist, 'utf8');
  } catch {
    return null;
  }

  const candidates = playlist
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter((line) => line && !line.startsWith('#'))
    .reverse();

  // The recorder uses hls_flags=temp_file, so a segment referenced by the
  // playlist has already been finalized. Check a few entries backwards to be
  // tolerant of a just-rotated/moved file without ever waiting on live HLS.
  for (const line of candidates.slice(0, 4)) {
    const candidate = safePlaylistSegment(root, line);
    if (!candidate) continue;
    try {
      const stat = await fs.stat(candidate);
      if (stat.isFile() && stat.size > 188) return candidate;
    } catch {
      // Try the previous completed playlist entry.
    }
  }
  return null;
}

async function snapshotInput(streamName: string): Promise<SnapshotInput | null> {
  const root = streamRoot(streamName);
  const livePlaylist = path.join(root, 'live.m3u8');

  // Do not feed FFmpeg the live HLS playlist in the normal path. With some
  // cameras FFmpeg can wait close to DVR_SNAPSHOT_TIMEOUT_MS for a decodable
  // frame/keyframe. The playlist already points at completed local .ts files;
  // decoding the newest one is deterministic and normally completes quickly.
  const liveSegment = await latestCompletedLiveSegment(root, livePlaylist);
  if (liveSegment) {
    return { file: liveSegment, cwd: root, source: 'live-segment' };
  }

  // Preserve the previous archive fallback for stopped/restarting recorders.
  const now = new Date();
  let segments = await listSegments(streamName, new Date(now.getTime() - 72 * 3600_000), now);
  if (!segments.length) {
    segments = await listSegments(streamName, new Date(now.getTime() - 31 * 24 * 3600_000), now);
  }
  const latest = segments.at(-1);
  if (latest) return { file: latest.absolutePath, cwd: root, source: 'archive' };

  // Very new cameras may have live.m3u8 before the first segment is finalized.
  // Keep the former live-playlist behaviour only as a last-resort compatibility
  // path; its longer timeout no longer affects normally recording cameras.
  if (await readable(livePlaylist)) {
    return { file: livePlaylist, cwd: root, source: 'live-playlist' };
  }
  return null;
}

async function renderJpeg(input: SnapshotInput): Promise<Buffer> {
  return new Promise((resolve, reject) => {
    const args = [
      '-hide_banner',
      '-loglevel', process.env.DVR_FFMPEG_LOGLEVEL || 'error',
      '-nostdin',
      '-i', input.file,
      '-map', '0:v:0',
      '-frames:v', '1',
      '-vf', `scale='min(${SNAPSHOT_WIDTH},iw)':-2`,
      '-q:v', '3',
      '-f', 'image2pipe',
      '-vcodec', 'mjpeg',
      'pipe:1'
    ];

    const child = spawn(config.ffmpegPath, args, {
      cwd: input.cwd,
      stdio: ['ignore', 'pipe', 'pipe']
    });
    const chunks: Buffer[] = [];
    let size = 0;
    let stderr = '';
    let settled = false;

    const finish = (error?: Error, value?: Buffer) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      if (error) reject(error);
      else resolve(value || Buffer.alloc(0));
    };

    const timeoutMs = input.source === 'live-playlist' ? SNAPSHOT_TIMEOUT_MS : SNAPSHOT_LOCAL_TIMEOUT_MS;
    const timer = setTimeout(() => {
      child.kill('SIGKILL');
      finish(new Error(`Snapshot generation timed out source=${input.source}`));
    }, timeoutMs);

    child.stdout.on('data', (chunk: Buffer) => {
      size += chunk.length;
      if (size > SNAPSHOT_MAX_BYTES) {
        child.kill('SIGKILL');
        finish(new Error('Snapshot exceeds size limit'));
        return;
      }
      chunks.push(Buffer.from(chunk));
    });

    child.stderr.on('data', (chunk: Buffer) => {
      if (stderr.length < 4000) stderr += chunk.toString('utf8');
    });

    child.once('error', (error) => finish(error));
    child.once('close', (code) => {
      if (settled) return;
      const image = Buffer.concat(chunks);
      if (code !== 0 || image.length < 128) {
        finish(new Error(`Snapshot generation failed source=${input.source} (code=${code}): ${stderr.trim().slice(0, 1000)}`));
        return;
      }
      finish(undefined, image);
    });
  });
}

function snapshotCacheFile(streamName: string): string {
  return path.join(streamRoot(streamName), '.formats', 'snapshot.jpg');
}

async function cachedSnapshot(streamName: string, maxAgeMs: number): Promise<CachedSnapshot | null> {
  const file = snapshotCacheFile(streamName);
  try {
    const stat = await fs.stat(file);
    const ageMs = Math.max(0, Date.now() - stat.mtimeMs);
    if (!stat.isFile() || stat.size < 128 || stat.size > SNAPSHOT_MAX_BYTES || ageMs > maxAgeMs) return null;
    const image = await fs.readFile(file);
    if (image.length < 128 || image.length > SNAPSHOT_MAX_BYTES) return null;
    return { image, ageMs };
  } catch {
    return null;
  }
}

async function writeSnapshotCache(streamName: string, image: Buffer): Promise<void> {
  const file = snapshotCacheFile(streamName);
  const dir = path.dirname(file);
  await fs.mkdir(dir, { recursive: true });
  const tmp = `${file}.tmp-${process.pid}-${Date.now()}`;
  try {
    await fs.writeFile(tmp, image, { mode: 0o640 });
    await fs.rename(tmp, file);
  } finally {
    await fs.unlink(tmp).catch(() => undefined);
  }
}

async function generateSnapshot(streamName: string): Promise<GeneratedSnapshot> {
  const input = await snapshotInput(streamName);
  if (!input) throw new Error('No live or archive video is available for snapshot');
  const image = await renderJpeg(input);
  await writeSnapshotCache(streamName, image);
  return { image, source: input.source };
}

function startSnapshotJob(streamName: string): Promise<GeneratedSnapshot> {
  const existing = snapshotJobs.get(streamName);
  if (existing) return existing;

  const job = generateSnapshot(streamName);
  snapshotJobs.set(streamName, job);
  const cleanup = () => {
    if (snapshotJobs.get(streamName) === job) snapshotJobs.delete(streamName);
  };
  job.then(cleanup, cleanup);
  return job;
}

function sendSnapshot(
  res: express.Response,
  image: Buffer,
  source: string,
  cacheMode: SnapshotCacheMode,
  cacheAgeMs = 0
) {
  res.setHeader('cache-control', 'private, max-age=5');
  res.setHeader('content-type', 'image/jpeg');
  res.setHeader('content-length', String(image.length));
  res.setHeader('x-newdomofon-snapshot-source', source);
  res.setHeader('x-newdomofon-snapshot-cache', cacheMode);
  res.setHeader('x-newdomofon-snapshot-cache-age-ms', String(Math.round(cacheAgeMs)));
  return res.status(200).send(image);
}

export function registerSnapshotRoute(app: express.Express): void {
  app.get('/cameras/:streamName/snapshot.jpg', requireMediaToken(['live', 'archive']), async (req, res, next) => {
    try {
      const streamName = String(req.params.streamName || '');
      if (!safeStreamName(streamName)) return res.status(400).json({ error: 'Invalid stream name' });

      const fresh = await cachedSnapshot(streamName, SNAPSHOT_CACHE_TTL_MS);
      if (fresh) return sendSnapshot(res, fresh.image, 'cache', 'fresh', fresh.ageMs);

      const stale = await cachedSnapshot(streamName, SNAPSHOT_STALE_MAX_AGE_MS);
      const job = startSnapshotJob(streamName);
      if (stale) {
        // Serve the last known-good JPEG immediately. Refresh continues in the
        // background and atomically replaces the cache when it succeeds.
        job.catch((error) => {
          console.warn(`[snapshot:${streamName}] background refresh failed: ${error instanceof Error ? error.message : String(error)}`);
        });
        return sendSnapshot(res, stale.image, 'cache', 'stale', stale.ageMs);
      }

      const generated = await job;
      return sendSnapshot(res, generated.image, generated.source, 'miss');
    } catch (error) {
      return next(error);
    }
  });
}
