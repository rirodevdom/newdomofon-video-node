import { spawn } from 'node:child_process';
import fs from 'node:fs/promises';
import path from 'node:path';
import type express from 'express';
import { config } from './config.js';
import { requireMediaToken } from './mediaAuth.js';
import { listSegments, safeStreamName, streamRoot } from './storage.js';

const SNAPSHOT_TIMEOUT_MS = Math.max(3000, Number(process.env.DVR_SNAPSHOT_TIMEOUT_MS || 15000));
const SNAPSHOT_MAX_BYTES = Math.max(256 * 1024, Number(process.env.DVR_SNAPSHOT_MAX_BYTES || 8 * 1024 * 1024));
const SNAPSHOT_WIDTH = Math.max(320, Math.min(1920, Number(process.env.DVR_SNAPSHOT_WIDTH || 1280)));

async function readable(file: string): Promise<boolean> {
  try {
    await fs.access(file);
    return true;
  } catch {
    return false;
  }
}

async function snapshotInput(streamName: string): Promise<{ file: string; cwd: string; source: 'live' | 'archive' } | null> {
  const root = streamRoot(streamName);
  const livePlaylist = path.join(root, 'live.m3u8');
  if (await readable(livePlaylist)) {
    return { file: livePlaylist, cwd: root, source: 'live' };
  }

  const now = new Date();
  let segments = await listSegments(streamName, new Date(now.getTime() - 72 * 3600_000), now);
  if (!segments.length) {
    segments = await listSegments(streamName, new Date(now.getTime() - 31 * 24 * 3600_000), now);
  }
  const latest = segments.at(-1);
  return latest ? { file: latest.absolutePath, cwd: root, source: 'archive' } : null;
}

async function renderJpeg(input: { file: string; cwd: string }): Promise<Buffer> {
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

    const timer = setTimeout(() => {
      child.kill('SIGKILL');
      finish(new Error('Snapshot generation timed out'));
    }, SNAPSHOT_TIMEOUT_MS);

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
        finish(new Error(`Snapshot generation failed (code=${code}): ${stderr.trim().slice(0, 1000)}`));
        return;
      }
      finish(undefined, image);
    });
  });
}

export function registerSnapshotRoute(app: express.Express): void {
  app.get('/cameras/:streamName/snapshot.jpg', requireMediaToken(['live', 'archive']), async (req, res, next) => {
    try {
      const streamName = String(req.params.streamName || '');
      if (!safeStreamName(streamName)) return res.status(400).json({ error: 'Invalid stream name' });

      const input = await snapshotInput(streamName);
      if (!input) return res.status(404).json({ error: 'No live or archive video is available for snapshot' });

      const image = await renderJpeg(input);
      res.setHeader('cache-control', 'private, max-age=5');
      res.setHeader('content-type', 'image/jpeg');
      res.setHeader('content-length', String(image.length));
      res.setHeader('x-newdomofon-snapshot-source', input.source);
      return res.status(200).send(image);
    } catch (error) {
      return next(error);
    }
  });
}
