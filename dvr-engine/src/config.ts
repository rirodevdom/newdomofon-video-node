import 'dotenv/config';

function intEnv(name: string, fallback: number): number {
  const raw = process.env[name];
  if (!raw) return fallback;
  const parsed = Number.parseInt(raw, 10);
  if (!Number.isFinite(parsed)) throw new Error(`Invalid integer env ${name}`);
  return parsed;
}

export const config = {
  port: intEnv('DVR_ENGINE_PORT', 3010),
  databaseUrl: process.env.DATABASE_URL || 'postgres://newdomofon:newdomofon_password@127.0.0.1:5432/newdomofon_video',
  dvrRoot: process.env.DVR_ROOT || '/var/lib/newdomofon-video/dvr',
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
