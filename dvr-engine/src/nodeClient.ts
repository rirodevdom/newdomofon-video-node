import os from 'node:os';
import fs from 'node:fs/promises';
import { config } from './config.js';
import type { CameraConfig } from './types.js';

let cachedCameras: CameraConfig[] = [];
let mediaSecret = process.env.DVR_NODE_MEDIA_SECRET || process.env.NODE_MEDIA_SECRET || '';
let configGeneration = '';

export function isNodeMode(): boolean {
  return Boolean(config.masterUrl && config.nodeId && config.nodeToken);
}

export function getNodeMediaSecret(): string {
  return mediaSecret;
}

function headers(): Record<string, string> {
  return {
    authorization: `Bearer ${config.nodeToken}`,
    'x-node-id': config.nodeId,
    'content-type': 'application/json'
  };
}

async function requestJson<T>(path: string, init: RequestInit = {}): Promise<T> {
  const response = await fetch(`${config.masterUrl}${path}`, {
    ...init,
    headers: headers()
  });
  if (!response.ok) {
    const text = await response.text().catch(() => '');
    throw new Error(`Master request ${path} failed: ${response.status} ${text.slice(0, 500)}`);
  }
  return await response.json() as T;
}

async function storageStatus() {
  try {
    const stat = await fs.statfs(config.dvrRoot);
    return {
      root: config.dvrRoot,
      total_bytes: stat.blocks * stat.bsize,
      free_bytes: stat.bfree * stat.bsize,
      available_bytes: stat.bavail * stat.bsize
    };
  } catch (error) {
    return { root: config.dvrRoot, error: error instanceof Error ? error.message : String(error) };
  }
}

export async function heartbeat(): Promise<void> {
  if (!isNodeMode()) return;
  const body = {
    public_base_url: config.nodePublicBaseUrl || undefined,
    internal_url: config.nodeInternalUrl || undefined,
    version: process.env.npm_package_version || '1.0.0',
    capabilities: {
      hostname: os.hostname(),
      hls: true,
      archive: true,
      export: true,
      onvif_events: Boolean(process.env.INTERNAL_DVR_SECRET),
      video_motion: ['1', 'true', 'yes', 'on'].includes(String(process.env.VIDEO_MOTION_ENABLED || process.env.DVR_VIDEO_MOTION_ENABLED || '').toLowerCase())
    },
    storage: await storageStatus()
  };
  const response = await requestJson<{ config_generation?: string }>('/api/node-agent/heartbeat', {
    method: 'POST',
    body: JSON.stringify(body)
  });
  if (response.config_generation) configGeneration = String(response.config_generation);
}

export async function loadAssignedCameras(): Promise<CameraConfig[]> {
  if (!isNodeMode()) return cachedCameras;
  const data = await requestJson<{
    media_secret?: string;
    config_generation?: string;
    cameras?: CameraConfig[];
  }>('/api/node-agent/config');

  mediaSecret = data.media_secret || mediaSecret;
  configGeneration = String(data.config_generation || configGeneration || '');
  cachedCameras = Array.isArray(data.cameras) ? data.cameras : [];
  return cachedCameras;
}

export async function pollCommands(onReload: () => Promise<void>, onRestartRecordings?: () => Promise<void>): Promise<void> {
  if (!isNodeMode()) return;
  const data = await requestJson<{ items?: Array<{ id: string; type: string; payload: unknown }> }>('/api/node-agent/commands');
  for (const command of data.items || []) {
    try {
      if (command.type === 'reload_cameras') await onReload();
      if (command.type === 'restart_recordings') {
        if (onRestartRecordings) await onRestartRecordings();
        else await onReload();
      }
      await requestJson(`/api/node-agent/commands/${encodeURIComponent(command.id)}/result`, {
        method: 'POST',
        body: JSON.stringify({
          status: 'done',
          result: { ok: true, type: command.type, config_generation: configGeneration, storage: await storageStatus() }
        })
      });
    } catch (error) {
      await requestJson(`/api/node-agent/commands/${encodeURIComponent(command.id)}/result`, {
        method: 'POST',
        body: JSON.stringify({ status: 'failed', result: { error: error instanceof Error ? error.message : String(error) } })
      }).catch(() => undefined);
    }
  }
}
