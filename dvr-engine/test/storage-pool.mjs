import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';

const temp = await fs.mkdtemp(path.join(os.tmpdir(), 'newdomofon-storage-pool-'));
const rootA = path.join(temp, 'archive-a');
const rootB = path.join(temp, 'archive-b');
await fs.mkdir(rootA);
await fs.mkdir(rootB);

process.env.DVR_STORAGE_ROOTS = `${rootA},${rootB}`;
process.env.DVR_ROOT = rootA;
process.env.DVR_DISK_REQUIRE_MOUNTPOINT = 'false';
process.env.DVR_DISK_MIN_FREE_BYTES = '1';
process.env.DVR_DISK_MIN_FREE_PERCENT = '0';
process.env.DVR_DISK_RESUME_FREE_BYTES = '1';
process.env.DVR_DISK_RESUME_FREE_PERCENT = '0';
process.env.DVR_DISK_MIN_FREE_INODES_PERCENT = '0';
process.env.DVR_DISK_RESUME_FREE_INODES_PERCENT = '0';

const pool = await import('../dist/storagePool.js');
const storage = await import('../dist/storage.js');

await pool.ensureStoragePool();
const status = pool.storagePoolStatus();
assert.equal(status.pool_size, 2);
assert.equal(status.available_roots, 2);

const assigned = new Set();
for (let index = 0; index < 128; index += 1) {
  assigned.add(await pool.assignStorageRoot(`camera-${index}`));
}
assert.deepEqual(new Set([rootA, rootB]), assigned, 'rendezvous hashing should use both disks');

const stream = 'archive-read-test';
const writeRoot = await pool.assignStorageRoot(stream);
const oldRoot = writeRoot === rootA ? rootB : rootA;
const archiveDir = path.join(oldRoot, stream, '2026-07-20', '12');
await fs.mkdir(archiveDir, { recursive: true });
await fs.writeFile(path.join(archiveDir, '20260720_120000.ts'), 'old-disk-segment');

const segments = await storage.listSegments(
  stream,
  new Date(2026, 6, 20, 11, 59, 0),
  new Date(2026, 6, 20, 12, 1, 0)
);
assert.equal(segments.length, 1);
assert.equal(segments[0].absolutePath, path.join(archiveDir, '20260720_120000.ts'));
assert.equal(segments[0].relativePath, '2026-07-20/12/20260720_120000.ts');

const roots = storage.streamRoots(stream);
assert.equal(roots.length, 2);
assert.equal(roots[0], path.join(writeRoot, stream));
assert(roots.includes(path.join(oldRoot, stream)));

await fs.rm(temp, { recursive: true, force: true });
console.log('multi-disk storage pool test passed');
