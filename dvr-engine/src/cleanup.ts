import fs from 'node:fs/promises';
import path from 'node:path';
import { query } from './db.js';
import { isNodeMode, loadAssignedCameras } from './nodeClient.js';
import { streamRoots } from './storage.js';
import type { CameraConfig } from './types.js';

export async function cleanupArchives(): Promise<void> {
  const cameras = isNodeMode()
    ? await loadAssignedCameras()
    : (await query<CameraConfig>('SELECT stream_name, retention_days FROM cameras WHERE is_enabled = true')).rows;
  const now = Date.now();

  for (const camera of cameras) {
    for (const root of streamRoots(camera.stream_name)) {
      let dates: string[];
      try {
        dates = await fs.readdir(root);
      } catch {
        continue;
      }
      for (const dateDir of dates) {
        if (!/^\d{4}-\d{2}-\d{2}$/.test(dateDir)) continue;
        const dirDate = new Date(`${dateDir}T00:00:00Z`).getTime();
        const ageDays = (now - dirDate) / 86_400_000;
        if (ageDays > camera.retention_days) {
          const full = path.join(root, dateDir);
          await fs.rm(full, { recursive: true, force: true });
          console.log(`Cleanup removed ${full}`);
        }
      }
    }
  }
}
