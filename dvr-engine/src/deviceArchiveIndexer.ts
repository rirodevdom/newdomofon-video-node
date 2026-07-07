import { config } from './config.js';
import { loadAssignedCameras } from './nodeClient.js';
import { searchHikvisionArchive } from './hikvisionArchive.js';
import type { CameraConfig } from './types.js';

const enabled = !['0', 'false', 'no', 'off'].includes(String(process.env.DVR_HIKVISION_ARCHIVE_INDEX_ENABLED || '1').toLowerCase());
const intervalMs = Math.max(60_000, Number(process.env.DVR_HIKVISION_ARCHIVE_INDEX_INTERVAL_MS || 60 * 60_000));
const initialDelayMs = Math.max(5_000, Number(process.env.DVR_HIKVISION_ARCHIVE_INDEX_INITIAL_DELAY_MS || 30_000));
const days = Math.max(1, Math.min(90, Number(process.env.DVR_HIKVISION_ARCHIVE_INDEX_DAYS || 7)));
const chunkHours = Math.max(1, Math.min(24, Number(process.env.DVR_HIKVISION_ARCHIVE_INDEX_CHUNK_HOURS || 24)));
const perCameraPauseMs = Math.max(0, Number(process.env.DVR_HIKVISION_ARCHIVE_INDEX_CAMERA_PAUSE_MS || 1000));

let running = false;

function shouldIndex(camera: CameraConfig): boolean {
  if (camera.device_connection_type !== 'HIKVISION') return false;
  const storage = camera.archive_storage || camera.device_archive_storage || 'node';
  const deviceStorage = camera.device_archive_storage || storage;
  return storage === 'device' || storage === 'both' || deviceStorage === 'device' || deviceStorage === 'both';
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function postArchiveIndex(payload: Record<string, unknown>) {
  const secret = process.env.INTERNAL_DVR_SECRET || '';
  if (!secret) throw new Error('INTERNAL_DVR_SECRET is not configured');
  const response = await fetch(`${config.masterUrl}/api/internal/device-archive/ranges`, {
    method: 'POST',
    headers: {
      'content-type': 'application/json',
      'x-internal-secret': secret,
      'x-node-id': config.nodeId
    },
    body: JSON.stringify(payload)
  });
  if (!response.ok) {
    const text = await response.text().catch(() => '');
    throw new Error(`Master archive index upsert failed: ${response.status} ${text.slice(0, 500)}`);
  }
  return await response.json() as { upserted?: number; skipped?: number };
}

function chunks(start: Date, end: Date): Array<{ start: Date; end: Date }> {
  const result: Array<{ start: Date; end: Date }> = [];
  const stepMs = chunkHours * 60 * 60_000;
  for (let cursor = start.getTime(); cursor < end.getTime(); cursor += stepMs) {
    result.push({ start: new Date(cursor), end: new Date(Math.min(end.getTime(), cursor + stepMs)) });
  }
  return result;
}

async function syncCamera(camera: CameraConfig, syncStart: Date, syncEnd: Date) {
  const startedAt = new Date();
  const errors: string[] = [];
  let totalItems = 0;

  for (const chunk of chunks(syncStart, syncEnd)) {
    try {
      const archiveItems = await searchHikvisionArchive(camera, chunk.start, chunk.end);
      totalItems += archiveItems.length;
      if (!archiveItems.length) continue;

      const result = await postArchiveIndex({
        started_at: startedAt.toISOString(),
        finished_at: new Date().toISOString(),
        sync_start: syncStart.toISOString(),
        sync_end: syncEnd.toISOString(),
        cameras: [{ camera_id: camera.id, device_id: camera.device_id || null }],
        items: archiveItems.map((item) => ({
          camera_id: camera.id,
          stream_name: camera.stream_name,
          device_id: camera.device_id || null,
          source: item.source,
          track_id: item.trackId,
          start: item.start,
          end: item.end,
          playback_uri: item.playbackUri,
          raw: {
            track_id: item.trackId,
            playback_uri: item.playbackUri,
            indexed_chunk_start: chunk.start.toISOString(),
            indexed_chunk_end: chunk.end.toISOString()
          }
        })),
        errors
      });
      console.log(`[hikvision-archive-index] ${camera.stream_name} ${chunk.start.toISOString()}..${chunk.end.toISOString()} items=${archiveItems.length} upserted=${result.upserted ?? 0}`);
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      errors.push(`${camera.stream_name} ${chunk.start.toISOString()} ${message}`);
      console.warn('[hikvision-archive-index] camera chunk failed', camera.stream_name, message);
    }
  }

  await postArchiveIndex({
    started_at: startedAt.toISOString(),
    finished_at: new Date().toISOString(),
    sync_start: syncStart.toISOString(),
    sync_end: syncEnd.toISOString(),
    item_count: totalItems,
    cameras: [{ camera_id: camera.id, device_id: camera.device_id || null }],
    items: [],
    errors
  }).catch((error) => console.warn('[hikvision-archive-index] state update failed', camera.stream_name, error instanceof Error ? error.message : error));

  console.log(`[hikvision-archive-index] ${camera.stream_name} done items=${totalItems} errors=${errors.length}`);
}

async function runOnce() {
  if (running) return;
  running = true;
  try {
    const cameras = (await loadAssignedCameras()).filter(shouldIndex);
    if (!cameras.length) return;
    const syncEnd = new Date();
    const syncStart = new Date(syncEnd.getTime() - days * 24 * 60 * 60_000);
    console.log(`[hikvision-archive-index] sync start cameras=${cameras.length} days=${days} chunkHours=${chunkHours}`);
    for (const camera of cameras) {
      await syncCamera(camera, syncStart, syncEnd);
      if (perCameraPauseMs) await sleep(perCameraPauseMs);
    }
  } finally {
    running = false;
  }
}

export function startDeviceArchiveIndexer() {
  if (!enabled) {
    console.log('[hikvision-archive-index] disabled');
    return;
  }
  if (!config.masterUrl || !config.nodeId) return;
  console.log(`[hikvision-archive-index] enabled intervalMs=${intervalMs} days=${days}`);
  setTimeout(() => runOnce().catch((error) => console.warn('[hikvision-archive-index] sync failed', error instanceof Error ? error.message : error)), initialDelayMs);
  setInterval(() => runOnce().catch((error) => console.warn('[hikvision-archive-index] sync failed', error instanceof Error ? error.message : error)), intervalMs);
}
