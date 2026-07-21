import 'dotenv/config';
import path from 'node:path';

function intEnv(name: string, fallback: number): number {
  const raw = process.env[name];
  if (!raw) return fallback;
  const parsed = Number.parseInt(raw, 10);
  if (!Number.isFinite(parsed)) throw new Error(`Invalid integer env ${name}`);
  return parsed;
}

function boolEnv(name: string, fallback = false): boolean {
  const raw = process.env[name];
  if (raw === undefined || raw === null || raw === '') return fallback;
  return ['1', 'true', 'yes', 'on'].includes(String(raw).trim().toLowerCase());
}

function engineRole(): 'master' | 'node' | 'standalone' {
  const raw = String(process.env.DVR_ENGINE_ROLE || process.env.VIDEO_ENGINE_ROLE || '').trim().toLowerCase();
  if (raw === 'master' || raw === 'node' || raw === 'standalone') return raw;
  if (process.env.DVR_MASTER_URL && process.env.DVR_NODE_ID && process.env.DVR_NODE_TOKEN) return 'node';
  return 'standalone';
}

function archiveStorageRoots(): string[] {
  const fallback = String(process.env.DVR_ROOT || '/var/lib/newdomofon-video/dvr').trim();
  const raw = String(process.env.DVR_STORAGE_ROOTS || '').trim();
  const values = raw ? raw.split(',') : [fallback];
  const roots: string[] = [];

  for (const value of values) {
    const trimmed = value.trim();
    if (!trimmed) continue;
    if (!path.isAbsolute(trimmed)) throw new Error(`DVR storage root must be absolute: ${trimmed}`);
    if (trimmed.includes('\n') || trimmed.includes('\r')) throw new Error('DVR storage root contains a newline');
    const normalized = path.resolve(trimmed);
    if (!roots.includes(normalized)) roots.push(normalized);
  }

  if (!roots.length) throw new Error('DVR_STORAGE_ROOTS does not contain any paths');
  return roots;
}

const storageRoots = archiveStorageRoots();

export const config = {
  role: engineRole(),
  port: intEnv('DVR_ENGINE_PORT', 3010),
  databaseUrl: process.env.DATABASE_URL || 'postgres://newdomofon:newdomofon_password@127.0.0.1:5432/newdomofon_video',
  dvrRoot: storageRoots[0],
  storageRoots,
  requireStorageMountpoints: boolEnv('DVR_DISK_REQUIRE_MOUNTPOINT', false),
  diskMinFreeBytes: intEnv('DVR_DISK_MIN_FREE_BYTES', 10_737_418_240),
  diskMinFreePercent: intEnv('DVR_DISK_MIN_FREE_PERCENT', 10),
  diskResumeFreeBytes: intEnv('DVR_DISK_RESUME_FREE_BYTES', 16_106_127_360),
  diskResumeFreePercent: intEnv('DVR_DISK_RESUME_FREE_PERCENT', 15),
  diskMinFreeInodesPercent: intEnv('DVR_DISK_MIN_FREE_INODES_PERCENT', 5),
  diskResumeFreeInodesPercent: intEnv('DVR_DISK_RESUME_FREE_INODES_PERCENT', 8),
  ffmpegPath: process.env.FFMPEG_PATH || '/usr/bin/ffmpeg',
  segmentDuration: intEnv('SEGMENT_DURATION', 4),
  liveWindow: intEnv('LIVE_WINDOW', 8),
  cameraReloadSeconds: intEnv('CAMERA_RELOAD_SECONDS', 20),
  cleanupIntervalMinutes: intEnv('CLEANUP_INTERVAL_MINUTES', 60),
  maxExportSeconds: intEnv('MAX_EXPORT_SECONDS', 3600),
  masterUrl: (process.env.DVR_MASTER_URL || process.env.MASTER_URL || '').replace(/\/+$/, ''),
  nodeId: process.env.DVR_NODE_ID || process.env.NODE_ID || '',
  nodeToken: process.env.DVR_NODE_TOKEN || process.env.NODE_AGENT_TOKEN || '',
  nodePublicBaseUrl: (process.env.DVR_NODE_PUBLIC_BASE_URL || process.env.NODE_PUBLIC_BASE_URL || '').replace(/\/+$/, ''),
  nodeInternalUrl: (process.env.DVR_NODE_INTERNAL_URL || process.env.NODE_INTERNAL_URL || '').replace(/\/+$/, ''),
  requireMediaToken: ['1', 'true', 'yes', 'on'].includes(String(process.env.DVR_REQUIRE_MEDIA_TOKEN || process.env.REQUIRE_NODE_MEDIA_TOKEN || '').toLowerCase()),
  corsOrigin: process.env.DVR_CORS_ORIGIN || '*'
};
