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
  const result = { apply: false, stream: '' };
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

function eventDbPath() {
  const configured = String(process.env.DVR_EVENT_DB || process.env.EVENT_DB_PATH || '').trim();
  if (configured) return configured;
  const dvrRoot = String(process.env.DVR_ROOT || '/var/lib/newdomofon-video/dvr');
  return path.join(path.dirname(dvrRoot), 'events', 'events.sqlite3');
}

function stateFilePath(dbPath) {
  return String(
    process.env.DVR_ARCHIVE_EVENT_SYNC_STATE_FILE
      || path.join(path.dirname(dbPath), 'archive-event-sync-state.json')
  );
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

function writeState(file, payload) {
  fs.mkdirSync(path.dirname(file), { recursive: true, mode: 0o750 });
  const temp = `${file}.tmp.${process.pid}`;
  fs.writeFileSync(temp, `${JSON.stringify(payload)}\n`, { mode: 0o640 });
  fs.renameSync(temp, file);
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

async function main() {
  const args = parseArgs(process.argv.slice(2));
  if (args.help) {
    console.log('Usage: reconcile-archive-events.mjs [--dry-run|--apply] [--stream STREAM_NAME]');
    return;
  }

  const enabled = boolEnv('DVR_ARCHIVE_EVENT_SYNC_ENABLED', true);
  const dbPath = eventDbPath();
  const stateFile = stateFilePath(dbPath);
  const checkedAt = new Date().toISOString();

  if (!enabled) {
    const state = { ok: true, enabled: false, mode: args.apply ? 'apply' : 'dry-run', checked_at: checkedAt };
    writeState(stateFile, state);
    console.log(JSON.stringify(state));
    return;
  }

  if (!fs.existsSync(dbPath)) {
    const state = {
      ok: true,
      enabled: true,
      mode: args.apply ? 'apply' : 'dry-run',
      database: dbPath,
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
      checked_at: checkedAt
    };
    writeState(stateFile, state);
    console.log(JSON.stringify(state));
    return;
  }

  const minAgeMinutes = intEnv('DVR_ARCHIVE_EVENT_SYNC_MIN_AGE_MINUTES', 120, 15, 10080);
  const maxHours = intEnv('DVR_ARCHIVE_EVENT_SYNC_MAX_HOURS_PER_RUN', 1000, 1, 100000);
  const cutoffMs = Date.now() - minAgeMinutes * 60_000;
  const dvrRoot = String(process.env.DVR_ROOT || '/var/lib/newdomofon-video/dvr');
  const database = new DatabaseSync(dbPath);

  database.exec('PRAGMA busy_timeout = 15000;');

  const streams = [...localStreams];
  const placeholders = streams.map(() => '?').join(',');
  const rows = database.prepare(`
    SELECT stream_name,
           CAST(occurred_at_ms / 3600000 AS INTEGER) * 3600000 AS bucket_ms,
           count(*) AS event_count
      FROM camera_events
     WHERE stream_name IN (${placeholders})
       AND occurred_at_ms < ?
     GROUP BY stream_name, bucket_ms
     ORDER BY bucket_ms ASC
     LIMIT ?
  `).all(...streams, cutoffMs, maxHours);

  const groups = new Map();
  for (const row of rows) {
    const stream = String(row.stream_name || '');
    const hour = localHour(Number(row.bucket_ms));
    const key = `${stream}\u0000${hour.startMs}`;
    const current = groups.get(key);
    if (current) {
      current.eventCount += Number(row.event_count || 0);
    } else {
      groups.set(key, { stream, ...hour, eventCount: Number(row.event_count || 0) });
    }
  }

  let archiveHoursChecked = 0;
  let missingArchiveHours = 0;
  let candidateEvents = 0;
  let deletedEvents = 0;
  const examples = [];

  try {
    for (const group of groups.values()) {
      archiveHoursChecked += 1;
      const archiveDir = path.join(dvrRoot, group.stream, group.dateDir, group.hourDir);
      if (hasArchiveSegments(archiveDir)) continue;

      missingArchiveHours += 1;
      candidateEvents += group.eventCount;
      if (examples.length < 20) {
        examples.push({
          stream_name: group.stream,
          start: new Date(group.startMs).toISOString(),
          end: new Date(group.endMs).toISOString(),
          archive_directory: archiveDir,
          event_count: group.eventCount
        });
      }

      if (!args.apply) continue;
      const result = database.prepare(`
        DELETE FROM camera_events
         WHERE stream_name = ?
           AND occurred_at_ms >= ?
           AND occurred_at_ms < ?
      `).run(group.stream, group.startMs, group.endMs);
      deletedEvents += Number(result.changes || 0);
    }

    if (deletedEvents > 0) database.exec('PRAGMA wal_checkpoint(PASSIVE);');
  } finally {
    database.close();
  }

  const state = {
    ok: true,
    enabled: true,
    mode: args.apply ? 'apply' : 'dry-run',
    database: dbPath,
    dvr_root: dvrRoot,
    local_streams: streams.length,
    min_age_minutes: minAgeMinutes,
    archive_hours_checked: archiveHoursChecked,
    missing_archive_hours: missingArchiveHours,
    candidate_events: candidateEvents,
    deleted_events: deletedEvents,
    examples,
    checked_at: new Date().toISOString()
  };

  writeState(stateFile, state);
  console.log(JSON.stringify(state));
}

main().catch((error) => {
  const dbPath = eventDbPath();
  const state = {
    ok: false,
    error: error instanceof Error ? error.message : String(error),
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
