#!/usr/bin/env node
import fs from 'node:fs';
import path from 'node:path';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const { DatabaseSync } = require('node:sqlite');

function boolEnv(name, fallback) {
  const raw = process.env[name];
  if (raw === undefined || raw === null || raw === '') return fallback;
  return ['1', 'true', 'yes', 'on'].includes(String(raw).toLowerCase());
}

function intEnv(name, fallback, min, max) {
  const parsed = Number(process.env[name] ?? fallback);
  if (!Number.isFinite(parsed)) return fallback;
  return Math.max(min, Math.min(max, Math.trunc(parsed)));
}

function parseArgs(argv) {
  const result = { apply: false, stream: '', help: false };
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === '--apply') result.apply = true;
    else if (arg === '--dry-run') result.apply = false;
    else if (arg === '--stream') result.stream = String(argv[++index] || '').trim();
    else if (arg === '--help' || arg === '-h') result.help = true;
    else throw new Error(`Unknown argument: ${arg}`);
  }
  return result;
}

function storageRoots() {
  const fallback = String(process.env.DVR_ROOT || '/var/lib/newdomofon-video/dvr').trim();
  const raw = String(process.env.DVR_STORAGE_ROOTS || fallback).trim();
  const roots = [];
  for (const item of raw.split(',')) {
    const value = item.trim();
    if (!value) continue;
    if (!path.isAbsolute(value)) throw new Error(`Archive root must be absolute: ${value}`);
    const normalized = path.resolve(value);
    if (!roots.includes(normalized)) roots.push(normalized);
  }
  if (!roots.length) throw new Error('No archive storage roots configured');
  return roots;
}

function eventDbPath(roots = storageRoots()) {
  const configured = String(process.env.DVR_EVENT_DB || process.env.EVENT_DB_PATH || '').trim();
  if (configured) return configured;
  return path.join(path.dirname(roots[0]), 'events', 'events.sqlite3');
}

function stateFilePath(dbPath) {
  return String(
    process.env.DVR_ARCHIVE_EVENT_SYNC_STATE_FILE
      || path.join(path.dirname(dbPath), 'archive-event-sync-state.json')
  );
}

function readJsonFile(file) {
  try {
    const parsed = JSON.parse(fs.readFileSync(file, 'utf8'));
    return parsed && typeof parsed === 'object' ? parsed : null;
  } catch {
    return null;
  }
}

function writeState(file, payload) {
  fs.mkdirSync(path.dirname(file), { recursive: true, mode: 0o750 });
  const temp = `${file}.tmp.${process.pid}`;
  fs.writeFileSync(temp, `${JSON.stringify(payload)}\n`, { mode: 0o640 });
  fs.renameSync(temp, file);
}

function localHour(timestampMs) {
  const date = new Date(timestampMs);
  const year = date.getFullYear();
  const month = String(date.getMonth() + 1).padStart(2, '0');
  const day = String(date.getDate()).padStart(2, '0');
  const hour = String(date.getHours()).padStart(2, '0');
  const startMs = new Date(year, date.getMonth(), date.getDate(), date.getHours(), 0, 0, 0).getTime();
  const endMs = new Date(year, date.getMonth(), date.getDate(), date.getHours() + 1, 0, 0, 0).getTime();
  return { dateDir: `${year}-${month}-${day}`, hourDir: hour, startMs, endMs };
}

function hasArchiveSegments(directory) {
  try {
    return fs.readdirSync(directory, { withFileTypes: true }).some((entry) => (
      entry.isFile()
      && !entry.name.endsWith('.tmp')
      && /\.(?:ts|m4s)$/.test(entry.name)
    ));
  } catch {
    return false;
  }
}

function mountedExactly(target) {
  let resolved;
  try {
    resolved = fs.realpathSync(target);
  } catch {
    return false;
  }

  try {
    const lines = fs.readFileSync('/proc/self/mountinfo', 'utf8').split('\n');
    return lines.some((line) => {
      if (!line) return false;
      const fields = line.split(' ');
      if (fields.length < 5) return false;
      const mountPoint = fields[4]
        .replace(/\\040/g, ' ')
        .replace(/\\011/g, '\t')
        .replace(/\\012/g, '\n')
        .replace(/\\134/g, '\\');
      try {
        return fs.realpathSync(mountPoint) === resolved;
      } catch {
        return false;
      }
    });
  } catch {
    return false;
  }
}

function archiveStorageSafety(roots) {
  const pauseMarker = String(
    process.env.DVR_DISK_GUARD_PAUSE_MARKER || '/run/newdomofon-video/node-disk-paused'
  );
  if (fs.existsSync(pauseMarker)) {
    return { safe: false, reason: 'node_disk_guard_paused' };
  }

  const diskStateFile = String(
    process.env.DVR_DISK_GUARD_STATE_FILE || '/run/newdomofon-video/node-disk-state.json'
  );
  const diskState = readJsonFile(diskStateFile);
  if (diskState?.state === 'critical') {
    return { safe: false, reason: `node_disk_guard_${String(diskState.reason || 'critical')}` };
  }
  if (Array.isArray(diskState?.roots)) {
    const unsafe = diskState.roots.filter((item) => String(item?.state || '') === 'critical');
    if (unsafe.length) {
      return {
        safe: false,
        reason: 'one_or_more_archive_roots_unavailable',
        roots: unsafe.map((item) => String(item?.root || '')).filter(Boolean)
      };
    }
  }

  for (const root of roots) {
    try {
      if (!fs.statSync(root).isDirectory()) {
        return { safe: false, reason: 'archive_root_is_not_directory', root };
      }
      fs.accessSync(root, fs.constants.R_OK | fs.constants.X_OK);
    } catch {
      return { safe: false, reason: 'archive_root_unavailable', root };
    }

    if (boolEnv('DVR_DISK_REQUIRE_MOUNTPOINT', false) && !mountedExactly(root)) {
      return { safe: false, reason: 'required_archive_mount_missing', root };
    }
  }

  return { safe: true, reason: 'ok' };
}

async function loadAssignedCameras() {
  const masterUrl = String(process.env.DVR_MASTER_URL || '').replace(/\/$/, '');
  const nodeId = String(process.env.DVR_NODE_ID || '');
  const nodeToken = String(process.env.DVR_NODE_TOKEN || '');
  if (!masterUrl || !nodeId || !nodeToken) {
    throw new Error('DVR_MASTER_URL, DVR_NODE_ID and DVR_NODE_TOKEN are required');
  }

  const response = await fetch(`${masterUrl}/api/node-agent/config`, {
    headers: {
      authorization: `Bearer ${nodeToken}`,
      'x-node-id': nodeId,
      'x-node-protocol-version': '1',
      accept: 'application/json'
    },
    signal: AbortSignal.timeout(intEnv('DVR_ARCHIVE_EVENT_SYNC_MASTER_TIMEOUT_MS', 15000, 1000, 120000))
  });

  if (!response.ok) {
    const body = await response.text().catch(() => '');
    throw new Error(`Master config failed: HTTP ${response.status} ${body.slice(0, 300)}`);
  }

  const payload = await response.json();
  return Array.isArray(payload?.cameras) ? payload.cameras : [];
}

function selectEventHours(database, streams, cutoffMs, cursorBucketMs, cursorStream, limit) {
  const placeholders = streams.map(() => '?').join(',');
  return database.prepare(`
    WITH event_hours AS (
      SELECT stream_name,
             CAST(occurred_at_ms / 3600000 AS INTEGER) * 3600000 AS bucket_ms,
             count(*) AS event_count
        FROM camera_events
       WHERE stream_name IN (${placeholders})
         AND occurred_at_ms < ?
       GROUP BY stream_name, bucket_ms
    )
    SELECT stream_name, bucket_ms, event_count
      FROM event_hours
     WHERE bucket_ms > ?
        OR (bucket_ms = ? AND stream_name > ?)
     ORDER BY bucket_ms ASC, stream_name ASC
     LIMIT ?
  `).all(...streams, cutoffMs, cursorBucketMs, cursorBucketMs, cursorStream, limit);
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  if (args.help) {
    console.log('Usage: reconcile-archive-events.mjs [--dry-run|--apply] [--stream STREAM_NAME]');
    return;
  }

  const roots = storageRoots();
  const dbPath = eventDbPath(roots);
  const stateFile = stateFilePath(dbPath);
  const checkedAt = new Date().toISOString();
  const enabled = boolEnv('DVR_ARCHIVE_EVENT_SYNC_ENABLED', true);

  if (!enabled) {
    const state = { ok: true, enabled: false, mode: args.apply ? 'apply' : 'dry-run', checked_at: checkedAt };
    writeState(stateFile, state);
    console.log(JSON.stringify(state));
    return;
  }

  const storageSafety = archiveStorageSafety(roots);
  if (!storageSafety.safe) {
    const state = {
      ok: false,
      enabled: true,
      mode: args.apply ? 'apply' : 'dry-run',
      skipped: storageSafety.reason,
      storage_roots: roots,
      unsafe_root: storageSafety.root || null,
      checked_at: checkedAt
    };
    writeState(stateFile, state);
    console.error(JSON.stringify(state));
    process.exitCode = 1;
    return;
  }

  if (!fs.existsSync(dbPath)) {
    const state = {
      ok: true,
      enabled: true,
      mode: args.apply ? 'apply' : 'dry-run',
      database: dbPath,
      storage_roots: roots,
      skipped: 'event_database_missing',
      checked_at: checkedAt
    };
    writeState(stateFile, state);
    console.log(JSON.stringify(state));
    return;
  }

  const cameras = await loadAssignedCameras();
  const localStreams = new Set(
    cameras
      .filter((camera) => String(camera?.archive_storage || 'node').toLowerCase() !== 'device')
      .map((camera) => String(camera?.stream_name || '').trim())
      .filter((stream) => /^[a-zA-Z0-9_-]+$/.test(stream))
  );

  if (args.stream) {
    if (!/^[a-zA-Z0-9_-]+$/.test(args.stream)) throw new Error('Invalid --stream value');
    if (!localStreams.has(args.stream)) {
      const state = {
        ok: true,
        enabled: true,
        mode: args.apply ? 'apply' : 'dry-run',
        stream: args.stream,
        skipped: 'stream_is_not_assigned_local_archive',
        checked_at: checkedAt
      };
      writeState(stateFile, state);
      console.log(JSON.stringify(state));
      return;
    }
    for (const stream of [...localStreams]) {
      if (stream !== args.stream) localStreams.delete(stream);
    }
  }

  if (!localStreams.size) {
    const state = {
      ok: true,
      enabled: true,
      mode: args.apply ? 'apply' : 'dry-run',
      local_streams: 0,
      storage_roots: roots,
      checked_at: checkedAt
    };
    writeState(stateFile, state);
    console.log(JSON.stringify(state));
    return;
  }

  const minAgeMinutes = intEnv('DVR_ARCHIVE_EVENT_SYNC_MIN_AGE_MINUTES', 120, 15, 10080);
  const maxHours = intEnv('DVR_ARCHIVE_EVENT_SYNC_MAX_HOURS_PER_RUN', 1000, 1, 100000);
  const cutoffMs = Date.now() - minAgeMinutes * 60_000;
  const previousState = args.apply ? readJsonFile(stateFile) : null;
  const sameScope = String(previousState?.scope_stream || '') === args.stream;
  let cursorBucketMs = sameScope && Number.isFinite(Number(previousState?.cursor_bucket_ms))
    ? Number(previousState.cursor_bucket_ms)
    : -1;
  let cursorStream = sameScope ? String(previousState?.cursor_stream_name || '') : '';
  const database = new DatabaseSync(dbPath);
  database.exec('PRAGMA busy_timeout = 15000;');

  const streams = [...localStreams].sort();
  if (streams.length > 900) {
    database.close();
    throw new Error(`Too many local archive streams for one reconciliation query: ${streams.length}`);
  }

  let rows = selectEventHours(database, streams, cutoffMs, cursorBucketMs, cursorStream, maxHours);
  let wrapped = false;
  if (!rows.length && (cursorBucketMs >= 0 || cursorStream)) {
    cursorBucketMs = -1;
    cursorStream = '';
    rows = selectEventHours(database, streams, cutoffMs, cursorBucketMs, cursorStream, maxHours);
    wrapped = true;
  }

  let archiveHoursChecked = 0;
  let missingArchiveHours = 0;
  let candidateEvents = 0;
  let deletedEvents = 0;
  const examples = [];

  try {
    for (const row of rows) {
      const stream = String(row.stream_name || '');
      const hour = localHour(Number(row.bucket_ms));
      archiveHoursChecked += 1;
      const directories = roots.map((root) => path.join(root, stream, hour.dateDir, hour.hourDir));
      if (directories.some(hasArchiveSegments)) continue;

      const eventCount = Number(row.event_count || 0);
      missingArchiveHours += 1;
      candidateEvents += eventCount;
      if (examples.length < 20) {
        examples.push({
          stream_name: stream,
          start: new Date(hour.startMs).toISOString(),
          end: new Date(hour.endMs).toISOString(),
          archive_directories: directories,
          event_count: eventCount
        });
      }

      if (!args.apply) continue;
      const result = database.prepare(`
        DELETE FROM camera_events
         WHERE stream_name = ?
           AND occurred_at_ms >= ?
           AND occurred_at_ms < ?
      `).run(stream, hour.startMs, hour.endMs);
      deletedEvents += Number(result.changes || 0);
    }

    if (deletedEvents > 0) database.exec('PRAGMA wal_checkpoint(PASSIVE);');
  } finally {
    database.close();
  }

  const lastRow = rows[rows.length - 1];
  const nextCursorBucketMs = args.apply && lastRow ? Number(lastRow.bucket_ms) : cursorBucketMs;
  const nextCursorStream = args.apply && lastRow ? String(lastRow.stream_name || '') : cursorStream;
  const state = {
    ok: true,
    enabled: true,
    mode: args.apply ? 'apply' : 'dry-run',
    database: dbPath,
    storage_roots: roots,
    scope_stream: args.stream,
    local_streams: streams.length,
    min_age_minutes: minAgeMinutes,
    archive_hours_checked: archiveHoursChecked,
    missing_archive_hours: missingArchiveHours,
    candidate_events: candidateEvents,
    deleted_events: deletedEvents,
    cursor_bucket_ms: nextCursorBucketMs,
    cursor_stream_name: nextCursorStream,
    wrapped,
    examples,
    checked_at: new Date().toISOString()
  };

  writeState(stateFile, state);
  console.log(JSON.stringify(state));
}

main().catch((error) => {
  const roots = storageRoots();
  const dbPath = eventDbPath(roots);
  const state = {
    ok: false,
    error: error instanceof Error ? error.message : String(error),
    storage_roots: roots,
    checked_at: new Date().toISOString()
  };
  try {
    writeState(stateFilePath(dbPath), state);
  } catch {
    // Best effort only. The original error is still emitted below.
  }
  console.error(JSON.stringify(state));
  process.exitCode = 1;
});
