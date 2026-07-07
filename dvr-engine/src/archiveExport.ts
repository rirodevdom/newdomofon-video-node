import { createReadStream } from 'node:fs';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { spawn } from 'node:child_process';
import type { Express, Request, Response } from 'express';
import { requireMediaToken } from './mediaAuth.js';

function dvrRoot() {
  return process.env.DVR_ROOT || process.env.DVR_DIR || '/var/lib/newdomofon-video/dvr';
}

function safeName(value: string) {
  return String(value || '').replace(/[^a-zA-Z0-9_.-]/g, '_').slice(0, 120);
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

async function runFfmpegConcat(listFile: string, outputFile: string) {
  return new Promise<void>((resolve, reject) => {
    const child = spawn('ffmpeg', [
      '-hide_banner',
      '-loglevel',
      'error',
      '-y',
      '-f',
      'concat',
      '-safe',
      '0',
      '-i',
      listFile,
      '-c',
      'copy',
      '-movflags',
      '+faststart',
      outputFile
    ]);

    let stderr = '';

    child.stderr.on('data', (chunk) => {
      stderr += String(chunk);
    });

    child.on('error', reject);

    child.on('close', (code) => {
      if (code === 0) resolve();
      else reject(new Error(stderr || `ffmpeg exited with code ${code}`));
    });
  });
}

async function cleanup(paths: string[]) {
  await Promise.all(paths.map(async (filePath) => {
    try {
      await fs.rm(filePath, { force: true, recursive: true });
    } catch {
      // ignore cleanup failures
    }
  }));
}

export function registerArchiveExportRoute(app: Express) {
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
