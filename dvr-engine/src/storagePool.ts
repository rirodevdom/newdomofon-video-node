import crypto from 'node:crypto';
import fs, { constants as fsConstants } from 'node:fs';
import fsp from 'node:fs/promises';
import path from 'node:path';
import { config } from './config.js';

export type StorageRootState = 'healthy' | 'warning' | 'critical';

export interface StorageRootStatus {
  root: string;
  state: StorageRootState;
  reason: string;
  mounted: boolean;
  writable: boolean;
  total_bytes: number;
  free_bytes: number;
  available_bytes: number;
  used_bytes: number;
  used_percent: number;
  inode_free_percent: number;
  required_start_bytes: number;
  required_resume_bytes: number;
}

const assignments = new Map<string, string>();
let mountInfoCache: { loadedAt: number; mountpoints: Set<string> } | null = null;

function normalizeRoot(value: string): string {
  const resolved = path.resolve(value.trim());
  return resolved === path.parse(resolved).root ? resolved : resolved.replace(/[\\/]+$/, '');
}

function requiredBytes(total: number, absolute: number, percent: number): number {
  return Math.max(absolute, Math.floor(total * percent / 100));
}

function decodeMountPath(value: string): string {
  return value
    .replace(/\\040/g, ' ')
    .replace(/\\011/g, '\t')
    .replace(/\\012/g, '\n')
    .replace(/\\134/g, '\\');
}

function mountedPaths(): Set<string> {
  const now = Date.now();
  if (mountInfoCache && now - mountInfoCache.loadedAt < 5_000) return mountInfoCache.mountpoints;

  const mountpoints = new Set<string>();
  try {
    const data = fs.readFileSync('/proc/self/mountinfo', 'utf8');
    for (const line of data.split('\n')) {
      if (!line) continue;
      const fields = line.split(' ');
      if (fields.length < 5) continue;
      try {
        mountpoints.add(normalizeRoot(fs.realpathSync(decodeMountPath(fields[4]))));
      } catch {
        mountpoints.add(normalizeRoot(decodeMountPath(fields[4])));
      }
    }
  } catch {
    // Non-Linux development environments use the configured paths without an
    // exact mountpoint assertion unless DVR_DISK_REQUIRE_MOUNTPOINT is enabled.
  }

  mountInfoCache = { loadedAt: now, mountpoints };
  return mountpoints;
}

export function isExactMountpoint(root: string): boolean {
  const normalized = normalizeRoot(root);
  let real = normalized;
  try {
    real = normalizeRoot(fs.realpathSync(normalized));
  } catch {
    return false;
  }
  return mountedPaths().has(real);
}

export function inspectStorageRoot(rootValue: string): StorageRootStatus {
  const root = normalizeRoot(rootValue);
  const mounted = isExactMountpoint(root);
  let writable = false;

  try {
    fs.accessSync(root, fsConstants.R_OK | fsConstants.W_OK | fsConstants.X_OK);
    writable = true;
  } catch {
    writable = false;
  }

  let total = 0;
  let free = 0;
  let available = 0;
  let inodeFreePercent = 0;

  try {
    const stat = fs.statfsSync(root);
    total = Number(stat.blocks) * Number(stat.bsize);
    free = Number(stat.bfree) * Number(stat.bsize);
    available = Number(stat.bavail) * Number(stat.bsize);
    const files = Number(stat.files);
    inodeFreePercent = files > 0 ? Math.floor(Number(stat.ffree) * 100 / files) : 100;
  } catch {
    return {
      root,
      state: 'critical',
      reason: 'statfs_failed',
      mounted,
      writable,
      total_bytes: 0,
      free_bytes: 0,
      available_bytes: 0,
      used_bytes: 0,
      used_percent: 100,
      inode_free_percent: 0,
      required_start_bytes: 0,
      required_resume_bytes: 0
    };
  }

  const requiredStart = requiredBytes(total, config.diskMinFreeBytes, config.diskMinFreePercent);
  const requiredResume = requiredBytes(total, config.diskResumeFreeBytes, config.diskResumeFreePercent);
  const used = Math.max(0, total - free);
  const usedPercent = total > 0 ? Math.floor(used * 100 / total) : 100;

  let state: StorageRootState = 'healthy';
  let reason = 'healthy';

  if (config.requireStorageMountpoints && !mounted) {
    state = 'critical';
    reason = 'mount_missing';
  } else if (!writable) {
    state = 'critical';
    reason = 'not_writable';
  } else if (available < requiredStart || inodeFreePercent < config.diskMinFreeInodesPercent) {
    state = 'critical';
    reason = available < requiredStart ? 'low_space' : 'low_inodes';
  } else if (available < requiredResume || inodeFreePercent < config.diskResumeFreeInodesPercent) {
    state = 'warning';
    reason = 'below_resume_watermark';
  }

  return {
    root,
    state,
    reason,
    mounted,
    writable,
    total_bytes: total,
    free_bytes: free,
    available_bytes: available,
    used_bytes: used,
    used_percent: usedPercent,
    inode_free_percent: inodeFreePercent,
    required_start_bytes: requiredStart,
    required_resume_bytes: requiredResume
  };
}

export function storageRootStatuses(): StorageRootStatus[] {
  return config.storageRoots.map(inspectStorageRoot);
}

export function storagePoolStatus() {
  const roots = storageRootStatuses();
  const availableRoots = roots.filter((item) => item.state !== 'critical');
  const totalBytes = roots.reduce((sum, item) => sum + item.total_bytes, 0);
  const freeBytes = roots.reduce((sum, item) => sum + item.free_bytes, 0);
  const availableBytes = roots.reduce((sum, item) => sum + item.available_bytes, 0);
  const usedBytes = roots.reduce((sum, item) => sum + item.used_bytes, 0);

  return {
    root: config.dvrRoot,
    pool_size: roots.length,
    healthy_roots: roots.filter((item) => item.state === 'healthy').length,
    available_roots: availableRoots.length,
    state: availableRoots.length === 0
      ? 'critical'
      : roots.some((item) => item.state === 'critical')
        ? 'degraded'
        : roots.some((item) => item.state === 'warning')
          ? 'warning'
          : 'healthy',
    total_bytes: totalBytes,
    free_bytes: freeBytes,
    available_bytes: availableBytes,
    used_bytes: usedBytes,
    roots
  };
}

function rendezvousScore(streamName: string, root: string): bigint {
  const digest = crypto.createHash('sha256').update(streamName).update('\0').update(root).digest();
  return digest.readBigUInt64BE(0);
}

function rankedRoots(streamName: string): string[] {
  return [...config.storageRoots].sort((left, right) => {
    const leftScore = rendezvousScore(streamName, left);
    const rightScore = rendezvousScore(streamName, right);
    if (leftScore === rightScore) return left.localeCompare(right);
    return leftScore > rightScore ? -1 : 1;
  });
}

function eligibleRoots(streamName: string): string[] {
  const statuses = new Map(storageRootStatuses().map((status) => [status.root, status]));
  const ranked = rankedRoots(streamName);
  const healthy = ranked.filter((root) => statuses.get(root)?.state === 'healthy');
  if (healthy.length) return healthy;
  return ranked.filter((root) => statuses.get(root)?.state === 'warning');
}

export function assignedStorageRoot(streamName: string): string | null {
  return assignments.get(streamName) || null;
}

export function selectStorageRoot(streamName: string): string {
  const assigned = assignments.get(streamName);
  if (assigned) return assigned;

  const eligible = eligibleRoots(streamName);
  if (!eligible.length) {
    const summary = storageRootStatuses().map((item) => `${item.root}:${item.reason}`).join(', ');
    throw new Error(`No writable archive storage root is available (${summary})`);
  }
  return eligible[0];
}

export async function assignStorageRoot(streamName: string): Promise<string> {
  const current = assignments.get(streamName);
  if (current) return current;

  const candidates = eligibleRoots(streamName);
  const failures: string[] = [];
  for (const root of candidates) {
    try {
      const streamDir = path.join(root, streamName);
      await fsp.mkdir(streamDir, { recursive: true });
      await fsp.access(streamDir, fsConstants.R_OK | fsConstants.W_OK | fsConstants.X_OK);
      assignments.set(streamName, root);
      return root;
    } catch (error) {
      failures.push(`${root}: ${error instanceof Error ? error.message : String(error)}`);
    }
  }

  throw new Error(`Cannot prepare archive storage for ${streamName}: ${failures.join('; ') || 'no eligible roots'}`);
}

export function releaseStorageAssignment(streamName: string): void {
  assignments.delete(streamName);
}

export function storageRootsForStream(streamName: string): string[] {
  const assigned = assignments.get(streamName);
  const roots = assigned
    ? [assigned, ...config.storageRoots.filter((root) => root !== assigned)]
    : rankedRoots(streamName);
  return [...new Set(roots.map(normalizeRoot))];
}

export async function ensureStoragePool(): Promise<void> {
  if (!config.requireStorageMountpoints) {
    await Promise.all(config.storageRoots.map((root) => fsp.mkdir(root, { recursive: true })));
  }

  const status = storagePoolStatus();
  if (status.available_roots === 0) {
    const details = status.roots.map((item) => `${item.root}:${item.reason}`).join(', ');
    throw new Error(`No archive storage root is available: ${details}`);
  }
}
