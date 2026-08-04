import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';

test('local archive lookup reads canonical hour directories across storage roots', async () => {
  const temp = await fs.mkdtemp(path.join(os.tmpdir(), 'newdomofon-storage-test-'));
  const rootA = path.join(temp, 'disk-a');
  const rootB = path.join(temp, 'disk-b');
  const stream = 'cam-test';
  await fs.mkdir(rootA, { recursive: true });
  await fs.mkdir(rootB, { recursive: true });

  process.env.DVR_STORAGE_ROOTS = `${rootA},${rootB}`;
  process.env.DVR_ROOT = rootA;
  process.env.DVR_DISK_REQUIRE_MOUNTPOINT = 'false';

  const selected = [
    [rootA, '2026-08-04/10/20260804_101500.ts'],
    [rootB, '2026-08-04/10/20260804_101600.ts'],
    [rootA, '2026-08-04/11/20260804_110000.ts']
  ] as const;
  for (const [root, relative] of selected) {
    const file = path.join(root, stream, relative);
    await fs.mkdir(path.dirname(file), { recursive: true });
    await fs.writeFile(file, 'segment');
  }

  const outside = path.join(rootA, stream, '2026-08-04/09/20260804_095900.ts');
  await fs.mkdir(path.dirname(outside), { recursive: true });
  await fs.writeFile(outside, 'outside');

  try {
    const { listSegments } = await import('../src/storage.js');
    const start = new Date(2026, 7, 4, 10, 14, 0);
    const end = new Date(2026, 7, 4, 11, 1, 0);
    const segments = await listSegments(stream, start, end);

    assert.deepEqual(
      segments.map((item) => item.timestamp.getTime()),
      [
        new Date(2026, 7, 4, 10, 15, 0).getTime(),
        new Date(2026, 7, 4, 10, 16, 0).getTime(),
        new Date(2026, 7, 4, 11, 0, 0).getTime()
      ]
    );
    assert.equal(segments.length, 3);
  } finally {
    await fs.rm(temp, { recursive: true, force: true });
  }
});
