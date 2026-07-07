import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { spawn } from 'node:child_process';
import { createReadStream } from 'node:fs';
import type { Response } from 'express';
import { config } from './config.js';
import { listSegments } from './storage.js';

export async function exportMp4(res: Response, streamName: string, start: Date, end: Date): Promise<void> {
  const segments = await listSegments(streamName, start, end);
  if (!segments.length) {
    res.status(404).json({ error: 'No archive segments in selected range' });
    return;
  }

  const dir = await fs.mkdtemp(path.join(os.tmpdir(), `newdomofon-export-${streamName}-`));
  const listFile = path.join(dir, 'segments.txt');
  const output = path.join(dir, 'export.mp4');
  await fs.writeFile(listFile, segments.map((s) => `file '${s.absolutePath.replace(/'/g, "'\\''")}'`).join('\n'));

  await new Promise<void>((resolve, reject) => {
    const child = spawn(config.ffmpegPath, ['-hide_banner', '-loglevel', 'error', '-f', 'concat', '-safe', '0', '-i', listFile, '-c', 'copy', '-movflags', '+faststart', output]);
    child.on('error', reject);
    child.on('exit', (code) => code === 0 ? resolve() : reject(new Error(`ffmpeg export failed with code ${code}`)));
  });

  res.type('video/mp4');
  createReadStream(output)
    .on('close', () => fs.rm(dir, { recursive: true, force: true }).catch(console.error))
    .pipe(res);
}
