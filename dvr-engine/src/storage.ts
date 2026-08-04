import path from 'node:path';
import fs from 'node:fs/promises';
import { createReadStream } from 'node:fs';
import type { Response } from 'express';
import { config } from './config.js';
import {
  assignStorageRoot,
  selectStorageRoot,
  storageRootsForStream
} from './storagePool.js';
import type { SegmentInfo } from './types.js';

export function streamRoot(streamName: string): string {
  return path.join(selectStorageRoot(streamName), streamName);
}

export function streamRoots(streamName: string): string[] {
  return storageRootsForStream(streamName).map((root) => path.join(root, streamName));
}

export function safeStreamName(streamName: string): boolean {
  return /^[a-zA-Z0-9_-]+$/.test(streamName);
}

export async function ensureStreamDirs(streamName: string): Promise<void> {
  const root = await assignStorageRoot(streamName);
  await fs.mkdir(path.join(root, streamName), { recursive: true });
}

function pad2(value: number): string {
  return String(value).padStart(2, '0');
}

function archiveHourDirectory(date: Date): string {
  return `${date.getFullYear()}-${pad2(date.getMonth() + 1)}-${pad2(date.getDate())}/${pad2(date.getHours())}`;
}

function archiveHourDirectories(start: Date, end: Date): string[] {
  if (!Number.isFinite(start.getTime()) || !Number.isFinite(end.getTime()) || end < start) return [];

  const first = new Date(start);
  first.setMinutes(0, 0, 0);
  const last = new Date(end);
  last.setMinutes(0, 0, 0);

  const directories: string[] = [];
  let cursor = first;
  let guard = 0;
  while (cursor <= last && guard < 24 * 370) {
    directories.push(archiveHourDirectory(cursor));
    const next = new Date(cursor);
    next.setHours(next.getHours() + 1);
    // A timezone transition must never make the iterator stall.
    cursor = next.getTime() > cursor.getTime()
      ? next
      : new Date(cursor.getTime() + 60 * 60 * 1000);
    guard += 1;
  }
  return [...new Set(directories)];
}

async function listSegmentsFromRoot(
  root: string,
  hourDirectories: string[],
  start: Date,
  end: Date,
  segments: Map<string, SegmentInfo>
): Promise<void> {
  for (const relativeHour of hourDirectories) {
    const dir = path.join(root, relativeHour);
    let entries: import('node:fs').Dirent[];
    try {
      entries = await fs.readdir(dir, { withFileTypes: true });
    } catch {
      continue;
    }

    for (const entry of entries) {
      if (entry.isDirectory() || !entry.name.endsWith('.ts')) continue;
      const ts = parseTimestampFromSegment(entry.name);
      if (!ts || ts < start || ts > end) continue;
      const abs = path.join(dir, entry.name);
      const relativePath = path.relative(root, abs).split(path.sep).join('/');
      const key = `${ts.getTime()}\0${relativePath}`;
      if (!segments.has(key)) {
        segments.set(key, {
          absolutePath: abs,
          relativePath,
          timestamp: ts
        });
      }
    }
  }
}

export async function listSegments(streamName: string, start: Date, end: Date): Promise<SegmentInfo[]> {
  if (!safeStreamName(streamName)) return [];
  const segments = new Map<string, SegmentInfo>();
  const hourDirectories = archiveHourDirectories(start, end);
  if (!hourDirectories.length) return [];

  // Recorder segments are stored as YYYY-MM-DD/HH/YYYYMMDD_HHMMSS.ts. The old
  // implementation recursively traversed every retained day for every archive
  // request and only filtered timestamps afterwards. With a 14-day retention
  // this means reading tens or hundreds of thousands of directory entries even
  // when SmartYard asks for only a few minutes or hours. Read only the hour
  // directories intersecting the requested interval, while still checking all
  // storage roots so archives survive disk-pool changes.
  await Promise.all(
    streamRoots(streamName).map((root) => listSegmentsFromRoot(root, hourDirectories, start, end, segments))
  );

  return [...segments.values()].sort((a, b) => a.timestamp.getTime() - b.timestamp.getTime());
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

function safeCandidate(root: string, normalized: string): string | null {
  const abs = path.resolve(path.join(root, normalized));
  const rootResolved = path.resolve(root);
  if (abs !== rootResolved && !abs.startsWith(rootResolved + path.sep)) return null;
  return abs;
}

export async function serveSafeFile(res: Response, streamName: string, filePath: string): Promise<void> {
  if (!safeStreamName(streamName)) {
    res.status(400).json({ error: 'Invalid stream name' });
    return;
  }

  const normalized = path.normalize(filePath).replace(/^([.][.][/\\])+/, '');
  let resolved: string | null = null;

  for (const root of streamRoots(streamName)) {
    const candidate = safeCandidate(root, normalized);
    if (!candidate) {
      res.status(400).json({ error: 'Invalid file path' });
      return;
    }
    try {
      await fs.access(candidate);
      resolved = candidate;
      break;
    } catch {
      // Continue through the storage pool. Old archive segments may remain on a
      // previous disk after adding, removing or recovering a storage device.
    }

    const liveFallback = !normalized.includes('/') && normalized.endsWith('.ts')
      ? safeCandidate(root, path.join('live', normalized))
      : null;
    if (liveFallback) {
      try {
        await fs.access(liveFallback);
        resolved = liveFallback;
        break;
      } catch {
        // Try the next storage root.
      }
    }
  }

  if (!resolved) {
    res.status(404).json({ error: 'File not found' });
    return;
  }

  res.setHeader('cache-control', 'no-store');
  if (resolved.endsWith('.m3u8')) res.type('application/vnd.apple.mpegurl');
  else if (resolved.endsWith('.ts')) res.type('video/mp2t');
  else if (resolved.endsWith('.mp4')) res.type('video/mp4');
  createReadStream(resolved).pipe(res);
}
