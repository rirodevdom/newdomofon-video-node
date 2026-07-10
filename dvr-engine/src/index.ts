import express from 'express';
import helmet from 'helmet';
import morgan from 'morgan';
import path from 'node:path';
import fs from 'node:fs/promises';
import { createReadStream } from 'node:fs';
import { config } from './config.js';
import { pool } from './db.js';
import { reloadCameras, getRecorderStatus, getAllRecorderStatuses, stopAllRecorders } from './recorder.js';
import { buildArchivePlaylist } from './playlist.js';
import { listArchiveRanges, listSegments, serveSafeFile, streamRoot, safeStreamName } from './storage.js';
import { exportMp4 } from './exporter.js';
import { cleanupArchives } from './cleanup.js';
import { connectOnvifCamera } from './onvif.js';
import { startOnvifEventCollectorV2 } from './onvifEventsV2.js';
import { startHikvisionEventCollector } from './hikvisionEvents.js';
import { startDeviceArchiveIndexer } from './deviceArchiveIndexer.js';
import { startVideoMotionDetector, stopAllVideoMotionDetectors } from './videoMotionDetector.js';
import { registerArchiveExportRoute } from './archiveExport.js';
import { requireMediaToken, rewritePlaylistForNode } from './mediaAuth.js';
import { heartbeat, isNodeMode, pollCommands } from './nodeClient.js';
import {
  closeLocalEventStore,
  getLocalEventStoreHealth,
  initializeLocalEventStore,
  startLocalEventRetention
} from './localEventStore.js';
import { registerLocalEventRoutes } from './localEventsApi.js';
import { cleanupDeviceArchiveSessions, createDeviceArchivePlaylist, deviceArchiveFile, listDeviceArchiveRanges, prepareDeviceArchiveSession } from './deviceArchive.js';

const app = express();
app.use(express.json({ limit: '1mb' }));
app.disable('x-powered-by');
app.use(helmet({ crossOriginResourcePolicy: false }));
app.use((req, res, next) => {
  res.setHeader('access-control-allow-origin', config.corsOrigin);
  res.setHeader('access-control-allow-methods', 'GET,HEAD,OPTIONS');
  res.setHeader('access-control-allow-headers', 'authorization,content-type,range,cache-control,pragma,accept,origin,x-requested-with');
  res.setHeader('access-control-expose-headers', 'content-length,content-range,accept-ranges,cache-control,content-type');
  res.setHeader('access-control-max-age', '600');
  res.setHeader('vary', 'Origin, Access-Control-Request-Headers');
  if (req.method === 'OPTIONS') return res.status(204).end();
  return next();
});
app.use(morgan('combined'));
registerArchiveExportRoute(app);
initializeLocalEventStore();
registerLocalEventRoutes(app);

const maxArchiveRangesSeconds = Math.max(config.maxExportSeconds, Number(process.env.DVR_ARCHIVE_RANGES_MAX_SECONDS || 31 * 24 * 60 * 60));
const maxDeviceArchiveRangesSeconds = Math.max(config.maxExportSeconds, Number(process.env.DVR_DEVICE_ARCHIVE_RANGES_MAX_SECONDS || 31 * 24 * 60 * 60));
const livePlaylistWaitMs = Math.max(0, Number(process.env.DVR_LIVE_PLAYLIST_WAIT_MS || 3000));

async function sleep(ms: number): Promise<void> {
  await new Promise((resolve) => setTimeout(resolve, ms));
}

async function waitForFile(file: string, timeoutMs: number): Promise<boolean> {
  const deadline = Date.now() + timeoutMs;
  do {
    try {
      await fs.access(file);
      return true;
    } catch {
      if (Date.now() >= deadline) return false;
      await sleep(200);
    }
  } while (Date.now() <= deadline);
  return false;
}

function parseRange(req: express.Request, res: express.Response, maxSeconds = config.maxExportSeconds): { start: Date; end: Date } | null {
  const start = new Date(String(req.query.start || ''));
  const end = new Date(String(req.query.end || ''));
  if (!Number.isFinite(start.getTime()) || !Number.isFinite(end.getTime()) || start >= end) {
    res.status(400).json({ error: 'Invalid start/end' });
    return null;
  }
  const durationSeconds = Math.ceil((end.getTime() - start.getTime()) / 1000);
  if (durationSeconds > maxSeconds) {
    res.status(413).json({ error: `Requested range is too large. Max ${maxSeconds} seconds.` });
    return null;
  }
  return { start, end };
}

app.get('/health', (_req, res) => res.json({
  ok: true,
  service: 'dvr-engine',
  mode: config.role,
  node_id: config.nodeId || null,
  recording_enabled: config.role !== 'master',
  events: getLocalEventStoreHealth()
}));
app.get('/recorders', (_req, res) => res.json({ items: getAllRecorderStatuses() }));

app.get('/cameras/:streamName/status', (req, res) => {
  res.json(getRecorderStatus(req.params.streamName));
});

app.get('/cameras/:streamName/live.m3u8', requireMediaToken(['live']), async (req, res, next) => {
  try {
    const streamName = req.params.streamName;

    if (!safeStreamName(streamName)) {
      return res.status(400).json({ error: 'Invalid stream name' });
    }

    const file = path.join(streamRoot(streamName), 'live.m3u8');

    if (!(await waitForFile(file, livePlaylistWaitMs))) {
      return res.status(404).json({
        error: 'Live playlist is not ready',
        streamName,
        status: getRecorderStatus(streamName)
      });
    }

    res.setHeader('cache-control', 'no-store');
    res.type('application/vnd.apple.mpegurl');
    res.send(rewritePlaylistForNode(await fs.readFile(file, 'utf8'), streamName, String(req.query.token || '')));
  } catch (error) {
    next(error);
  }
});

app.get('/cameras/:streamName/archive.m3u8', requireMediaToken(['archive']), async (req, res, next) => {
  try {
    const range = parseRange(req, res);
    if (!range) return;
    const segments = await listSegments(req.params.streamName, range.start, range.end);
    if (!segments.length) return res.status(404).json({ error: 'No archive segments in selected range' });
    res.setHeader('cache-control', 'no-store');
    res.type('application/vnd.apple.mpegurl').send(rewritePlaylistForNode(buildArchivePlaylist(segments), req.params.streamName, String(req.query.token || '')));
  } catch (error) {
    next(error);
  }
});

app.get('/cameras/:streamName/archive/ranges', requireMediaToken(['archive']), async (req, res, next) => {
  try {
    const range = parseRange(req, res, maxArchiveRangesSeconds);
    if (!range) return;
    const maxGapMs = Math.max(config.segmentDuration * 2500, Number(req.query.max_gap_ms || 15_000));
    const ranges = await listArchiveRanges(req.params.streamName, range.start, range.end, maxGapMs);
    res.setHeader('cache-control', 'no-store');
    res.json({ items: ranges });
  } catch (error) {
    next(error);
  }
});

app.get('/cameras/:streamName/device-archive.m3u8', requireMediaToken(['archive']), async (req, res, next) => {
  try {
    const range = parseRange(req, res);
    if (!range) return;
    const playlist = await createDeviceArchivePlaylist(req.params.streamName, range.start, range.end, String(req.query.token || ''));
    res.setHeader('cache-control', 'no-store');
    res.type('application/vnd.apple.mpegurl').send(playlist);
  } catch (error) {
    next(error);
  }
});

app.get('/cameras/:streamName/device-archive/session', requireMediaToken(['archive']), async (req, res, next) => {
  try {
    const range = parseRange(req, res);
    if (!range) return;
    const rawWaitMs = Number(req.query.wait_ms || process.env.DVR_DEVICE_ARCHIVE_PREPARE_WAIT_MS || 0);
    const waitMs = Number.isFinite(rawWaitMs) ? Math.max(0, Math.min(60_000, rawWaitMs)) : 0;
    const payload = await prepareDeviceArchiveSession(req.params.streamName, range.start, range.end, String(req.query.token || ''), waitMs);
    res.setHeader('cache-control', 'no-store');
    res.status(payload.ready ? 200 : payload.status === 'error' ? Number(payload.error_status_code || 502) : 202).json(payload);
  } catch (error) {
    next(error);
  }
});

app.get('/cameras/:streamName/device-archive/ranges', requireMediaToken(['archive']), async (req, res, next) => {
  try {
    const range = parseRange(req, res, maxDeviceArchiveRangesSeconds);
    if (!range) return;
    const items = await listDeviceArchiveRanges(req.params.streamName, range.start, range.end);
    res.setHeader('cache-control', 'no-store');
    res.json({ items });
  } catch (error) {
    next(error);
  }
});

app.get('/cameras/:streamName/export.mp4', requireMediaToken(['export']), async (req, res, next) => {
  try {
    const range = parseRange(req, res);
    if (!range) return;
    await exportMp4(res, req.params.streamName, range.start, range.end);
  } catch (error) {
    next(error);
  }
});

app.get('/files/:streamName/*', requireMediaToken(['live', 'archive', 'export', 'file']), async (req, res, next) => {
  try {
    const filePath = (req.params as Record<string, string>)['0'] || '';
    await serveSafeFile(res, req.params.streamName, filePath);
  } catch (error) {
    next(error);
  }
});

app.get('/device-archive/:streamName/:sessionId/:filename', requireMediaToken(['archive']), async (req, res, next) => {
  try {
    const file = await deviceArchiveFile(req.params.sessionId, req.params.filename);
    if (!file) return res.status(404).json({ error: 'Device archive file not found' });
    res.setHeader('cache-control', 'no-store');
    res.type('video/mp2t');
    createReadStream(file).pipe(res);
  } catch (error) {
    next(error);
  }
});

app.post('/onvif/connect', async (req, res, next) => {
  try {
    const body = req.body || {};
    const result = await connectOnvifCamera({
      ip: String(body.ip || body.host || '').trim(),
      port: body.port ? Number(body.port) : 80,
      username: body.username ? String(body.username) : undefined,
      password: body.password ? String(body.password) : undefined
    });
    res.json(result);
  } catch (error) {
    next(error);
  }
});

app.use((error: unknown, _req: express.Request, res: express.Response, _next: express.NextFunction) => {
  const statusCode = error && typeof error === 'object' && 'statusCode' in error
    ? Number((error as { statusCode?: unknown }).statusCode)
    : 500;
  if (statusCode >= 500) console.error(error);
  else console.warn(error instanceof Error ? error.message : error);
  const message = error instanceof Error ? error.message : 'Internal server error';
  res.status(Number.isInteger(statusCode) && statusCode >= 400 && statusCode <= 599 ? statusCode : 500).json({ error: message });
});

const server = app.listen(config.port, () => console.log(`DVR engine listening on ${config.port} role=${config.role}`));

if (config.role === 'master') {
  console.warn('[dvr-engine] master role is health-only; recorders and collectors are not started');
} else {
  await fs.mkdir(config.dvrRoot, { recursive: true });
  await reloadCameras().catch(console.error);
  setInterval(() => reloadCameras().catch(console.error), config.cameraReloadSeconds * 1000);
  if (isNodeMode()) {
    heartbeat().catch(console.error);
    setInterval(() => heartbeat().catch(console.error), 15_000);
    setInterval(() => pollCommands(reloadCameras, async () => {
      stopAllRecorders();
      stopAllVideoMotionDetectors();
      await reloadCameras();
      startVideoMotionDetector();
    }).catch(console.error), 10_000);
  }
  setInterval(() => cleanupArchives().catch(console.error), config.cleanupIntervalMinutes * 60_000);
  setInterval(() => cleanupDeviceArchiveSessions(), 60_000);
  cleanupArchives().catch(console.error);
  startLocalEventRetention();
  startOnvifEventCollectorV2();
  startHikvisionEventCollector();
  startDeviceArchiveIndexer();
  startVideoMotionDetector();
}

async function shutdown(signal: string) {
  console.log(`Received ${signal}`);
  stopAllRecorders();
  stopAllVideoMotionDetectors();
  server.close(async () => {
    closeLocalEventStore();
    await pool.end();
    process.exit(0);
  });
}

process.on('SIGTERM', () => shutdown('SIGTERM'));
process.on('SIGINT', () => shutdown('SIGINT'));
