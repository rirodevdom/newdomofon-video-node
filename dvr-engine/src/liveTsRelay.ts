import { spawn } from 'node:child_process';
import fs from 'node:fs/promises';
import path from 'node:path';
import type { Express, Request, Response } from 'express';
import { requireMediaToken } from './mediaAuth.js';

function dvrRoot(): string {
  return process.env.DVR_ROOT || process.env.DVR_DIR || '/var/lib/newdomofon-video/dvr';
}

function ffmpegPath(): string {
  return process.env.DVR_FFMPEG_PATH || process.env.FFMPEG_PATH || 'ffmpeg';
}

function validStreamName(value: string): boolean {
  return /^[a-zA-Z0-9_.-]+$/.test(value);
}

async function livePlaylist(streamName: string): Promise<string> {
  const file = path.join(path.resolve(dvrRoot(), streamName), 'live.m3u8');
  try {
    await fs.access(file);
    return file;
  } catch {
    const error = new Error('Live playlist is not ready') as Error & { statusCode?: number };
    error.statusCode = 404;
    throw error;
  }
}

function sendError(res: Response, error: unknown): void {
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

async function handleLiveTs(req: Request, res: Response): Promise<void> {
  const streamName = String(req.params.streamName || '');
  if (!validStreamName(streamName)) {
    res.status(400).json({ error: 'Invalid stream name' });
    return;
  }

  try {
    const playlist = await livePlaylist(streamName);
    const child = spawn(ffmpegPath(), [
      '-hide_banner',
      '-loglevel', process.env.DVR_FFMPEG_LOGLEVEL || 'error',
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
      stderr = `${stderr}${String(chunk)}`.slice(-8000);
    });

    res.status(200);
    res.setHeader('content-type', 'video/mp2t');
    res.setHeader('cache-control', 'no-store');
    res.setHeader('x-accel-buffering', 'no');
    res.setHeader('connection', 'keep-alive');
    child.stdout.pipe(res);

    let stopped = false;
    const stop = () => {
      if (stopped) return;
      stopped = true;
      if (child.exitCode === null) {
        try { child.kill('SIGTERM'); } catch { /* ignored */ }
        setTimeout(() => {
          if (child.exitCode === null) {
            try { child.kill('SIGKILL'); } catch { /* ignored */ }
          }
        }, 3000).unref?.();
      }
    };

    // IncomingMessage "close" can mean that the request was fully consumed,
    // not that the media client disconnected. Stop only on an aborted request
    // or when the response/socket really closes.
    req.once('aborted', stop);
    res.once('close', stop);

    child.once('error', (error) => {
      stop();
      sendError(res, error);
    });
    child.once('exit', (code, signal) => {
      if (!stopped && code && !res.writableEnded) {
        console.warn(`[live-ts:${streamName}] ffmpeg exited code=${code} signal=${signal || '-'}: ${stderr}`);
      }
      if (!res.writableEnded) res.end();
    });
  } catch (error) {
    sendError(res, error);
  }
}

export function registerLiveTsRelayRoutes(app: Express): void {
  const auth = requireMediaToken(['live']);
  // Register before archiveExport routes so this corrected implementation owns
  // the public live.ts path while keeping an explicit internal relay alias.
  app.get('/cameras/:streamName/live.ts', auth, handleLiveTs);
  app.get('/cameras/:streamName/rtsp-relay.ts', auth, handleLiveTs);
}
