import path from 'node:path';
import fs from 'node:fs/promises';
import { createReadStream } from 'node:fs';
import type { Response } from 'express';
import { config } from './config.js';
import type { SegmentInfo } from './types.js';

export function streamRoot(streamName: string): string {
  return path.join(config.dvrRoot, streamName);
}

export function safeStreamName(streamName: string): boolean {
  return /^[a-zA-Z0-9_-]+$/.test(streamName);
}

export async function ensureStreamDirs(streamName: string): Promise<void> {
  await fs.mkdir(streamRoot(streamName), { recursive: true });
}

export async function listSegments(streamName: string, start: Date, end: Date): Promise<SegmentInfo[]> {
  if (!safeStreamName(streamName)) return [];
  const root = streamRoot(streamName);
  const segments: SegmentInfo[] = [];

  async function walk(dir: string) {
    let entries: import('node:fs').Dirent[];
    try {
      entries = await fs.readdir(dir, { withFileTypes: true });
    } catch {
      return;
    }
    for (const entry of entries) {
      const abs = path.join(dir, entry.name);
      if (entry.isDirectory()) {
        await walk(abs);
        continue;
      }
      if (!entry.name.endsWith('.ts')) continue;
      const ts = parseTimestampFromSegment(entry.name);
      if (!ts) continue;
      if (ts >= start && ts <= end) {
        segments.push({
          absolutePath: abs,
          relativePath: path.relative(root, abs).split(path.sep).join('/'),
          timestamp: ts
        });
      }
    }
  }

  await walk(root);
  return segments.sort((a, b) => a.timestamp.getTime() - b.timestamp.getTime());
}

export async function listArchiveRanges(streamName: string, start: Date, end: Date, maxGapMs: number): Promise<Array<{ start: string; end: string; segments: number }>> {
  const segments = await listSegments(streamName, start, end);
  const ranges: Array<{ start: Date; end: Date; segments: number }> = [];

  for (const [index, segment] of segments.entries()) {
    const next = segments[index + 1];
    const fallbackDurationMs = config.segmentDuration * 1000;
    const nextDeltaMs = next ? next.timestamp.getTime() - segment.timestamp.getTime() : fallbackDurationMs;
    const durationMs = Number.isFinite(nextDeltaMs) && nextDeltaMs > 0 && nextDeltaMs <= maxGapMs
      ? nextDeltaMs
      : fallbackDurationMs;
    const segmentEnd = new Date(segment.timestamp.getTime() + durationMs);
    const last = ranges[ranges.length - 1];
    if (!last || segment.timestamp.getTime() - last.end.getTime() > maxGapMs) {
      ranges.push({ start: segment.timestamp, end: segmentEnd, segments: 1 });
      continue;
    }
    if (segmentEnd > last.end) last.end = segmentEnd;
    last.segments += 1;
  }

  return ranges.map((range) => ({
    start: range.start.toISOString(),
    end: range.end.toISOString(),
    segments: range.segments
  }));
}

export function parseTimestampFromSegment(filename: string): Date | null {
  const match = filename.match(/^(\d{4})(\d{2})(\d{2})_(\d{2})(\d{2})(\d{2})\.ts$/);
  if (!match) return null;
  const [, y, mo, d, h, mi, s] = match;
  // FFmpeg expands hls_segment_filename with strftime in the DVR server's local
  // timezone. Convert that local filename timestamp back to an absolute Date.
  return new Date(Number(y), Number(mo) - 1, Number(d), Number(h), Number(mi), Number(s));
}

export async function serveSafeFile(res: Response, streamName: string, filePath: string): Promise<void> {
  if (!safeStreamName(streamName)) {
    res.status(400).json({ error: 'Invalid stream name' });
    return;
  }
  const root = streamRoot(streamName);
  const normalized = path.normalize(filePath).replace(/^([.][.][\/\\])+/, '');
  const abs = path.join(root, normalized);
  let resolved = path.resolve(abs);
  const rootResolved = path.resolve(root);
  if (resolved !== rootResolved && !resolved.startsWith(rootResolved + path.sep)) {
    res.status(400).json({ error: 'Invalid file path' });
    return;
  }
  try {
    await fs.access(resolved);
  } catch {
    const liveOnlyFallback = !normalized.includes('/') && normalized.endsWith('.ts')
      ? path.resolve(path.join(root, 'live', normalized))
      : null;
    if (!liveOnlyFallback || !liveOnlyFallback.startsWith(rootResolved + path.sep)) {
      res.status(404).json({ error: 'File not found' });
      return;
    }
    try {
      await fs.access(liveOnlyFallback);
      resolved = liveOnlyFallback;
    } catch {
      res.status(404).json({ error: 'File not found' });
      return;
    }
  }
  res.setHeader('cache-control', 'no-store');
  if (resolved.endsWith('.m3u8')) res.type('application/vnd.apple.mpegurl');
  else if (resolved.endsWith('.ts')) res.type('video/mp2t');
  else if (resolved.endsWith('.mp4')) res.type('video/mp4');
  createReadStream(resolved).pipe(res);
}
