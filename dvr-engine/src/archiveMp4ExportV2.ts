import { createReadStream } from 'node:fs';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { spawn } from 'node:child_process';
import type { Express, Request, Response } from 'express';
import { requireMediaToken } from './mediaAuth.js';
import { listSegments, safeStreamName } from './storage.js';

const maxExportSeconds = Math.max(
  1,
  Number(process.env.DVR_MP4_EXPORT_MAX_SECONDS || 6 * 60 * 60)
);

function parseDate(value: unknown): Date | null {
  const date = new Date(String(value || ''));
  return Number.isFinite(date.getTime()) ? date : null;
}

function escapeConcatPath(filePath: string): string {
  return filePath.replace(/'/g, "'\\''");
}

async function runFfmpeg(listFile: string, outputFile: string): Promise<void> {
  const ffmpeg = process.env.DVR_FFMPEG_PATH || process.env.FFMPEG_PATH || 'ffmpeg';

  await new Promise<void>((resolve, reject) => {
    const child = spawn(ffmpeg, [
      '-hide_banner',
      '-loglevel', 'error',
      '-nostdin',
      '-y',
      '-f', 'concat',
      '-safe', '0',
      '-i', listFile,
      '-c', 'copy',
      '-movflags', '+faststart',
      outputFile
    ], { stdio: ['ignore', 'ignore', 'pipe'] });

    let stderr = '';
    child.stderr.on('data', (chunk) => {
      stderr = `${stderr}${String(chunk)}`.slice(-12_000);
    });
    child.once('error', reject);
    child.once('close', (code) => {
      if (code === 0) resolve();
      else reject(new Error(stderr.trim() || `ffmpeg exited with code ${code}`));
    });
  });
}

function cleanFilePart(value: string): string {
  return String(value || 'archive').replace(/[^a-zA-Z0-9_.-]+/g, '_').slice(0, 120) || 'archive';
}

export function registerArchiveMp4ExportV2Route(app: Express): void {
  // Register this route before the legacy formats route. The legacy route
  // interprets local HLS filenames as UTC and only scans DVR_ROOT, which breaks
  // Moscow-time archives and multi-disk storage. listSegments() is the canonical
  // storage-pool and local-time-aware archive index used by archive playback.
  app.get('/cameras/:streamName/export.mp4', requireMediaToken(['export']), async (req: Request, res: Response) => {
    const streamName = String(req.params.streamName || '').trim();
    const start = parseDate(req.query.start);
    const end = parseDate(req.query.end);

    if (!safeStreamName(streamName)) return res.status(400).json({ error: 'Invalid stream name' });
    if (!start || !end || start >= end) return res.status(400).json({ error: 'Invalid start/end' });

    const durationSeconds = Math.ceil((end.getTime() - start.getTime()) / 1000);
    if (durationSeconds > maxExportSeconds) {
      return res.status(413).json({
        error: `Requested export range is too large. Max ${maxExportSeconds} seconds.`
      });
    }

    const segmentInfos = await listSegments(streamName, start, end);
    if (!segmentInfos.length) {
      return res.status(404).json({ error: 'No archive segments in selected range' });
    }

    if (segmentInfos.length > 6000) {
      return res.status(413).json({ error: 'Too many segments for export. Reduce the selected range.' });
    }

    const tmpDir = await fs.mkdtemp(path.join(os.tmpdir(), `newdomofon-export-v2-${cleanFilePart(streamName)}-`));
    const listFile = path.join(tmpDir, 'segments.ffconcat');
    const outputFile = path.join(tmpDir, 'archive.mp4');
    let cleaned = false;

    const cleanup = async () => {
      if (cleaned) return;
      cleaned = true;
      await fs.rm(tmpDir, { recursive: true, force: true }).catch(() => undefined);
    };

    try {
      const body = [
        'ffconcat version 1.0',
        ...segmentInfos.map((segment) => `file '${escapeConcatPath(segment.absolutePath)}'`)
      ].join('\n');
      await fs.writeFile(listFile, body, 'utf8');
      await runFfmpeg(listFile, outputFile);

      const stat = await fs.stat(outputFile);
      const fileName = [
        cleanFilePart(streamName),
        start.toISOString().replace(/[:.]/g, '-'),
        end.toISOString().replace(/[:.]/g, '-')
      ].join('_') + '.mp4';

      res.setHeader('content-type', 'video/mp4');
      res.setHeader('content-length', String(stat.size));
      res.setHeader('content-disposition', `attachment; filename="${fileName}"`);
      res.setHeader('cache-control', 'no-store');
      res.setHeader('x-newdomofon-export-route', 'storage-v2');

      console.log('[dvr-export-v2] ready', {
        streamName,
        start: start.toISOString(),
        end: end.toISOString(),
        segments: segmentInfos.length,
        first: segmentInfos[0]?.timestamp.toISOString(),
        last: segmentInfos.at(-1)?.timestamp.toISOString(),
        bytes: stat.size
      });

      const file = createReadStream(outputFile);
      file.once('error', async (error) => {
        console.error('[dvr-export-v2] stream failed', error);
        if (!res.headersSent) res.status(500).json({ error: 'Export stream failed' });
        else res.end();
        await cleanup();
      });
      res.once('finish', () => void cleanup());
      res.once('close', () => void cleanup());
      file.pipe(res);
    } catch (error) {
      await cleanup();
      console.error('[dvr-export-v2] failed', {
        streamName,
        start: start.toISOString(),
        end: end.toISOString(),
        segments: segmentInfos.length,
        error: error instanceof Error ? error.message : String(error)
      });
      if (!res.headersSent) {
        return res.status(500).json({
          error: 'Export failed',
          detail: error instanceof Error ? error.message : String(error)
        });
      }
      return res.end();
    }
  });
}
