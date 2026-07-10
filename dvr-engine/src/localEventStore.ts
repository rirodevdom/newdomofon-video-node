import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { createRequire } from 'node:module';
import { config } from './config.js';

const require = createRequire(import.meta.url);

type StatementResult = {
  changes: number | bigint;
  lastInsertRowid: number | bigint;
};

type SQLiteStatement = {
  run(...params: unknown[]): StatementResult;
  get(...params: unknown[]): Record<string, unknown> | undefined;
  all(...params: unknown[]): Array<Record<string, unknown>>;
};

type SQLiteDatabase = {
  exec(sql: string): void;
  prepare(sql: string): SQLiteStatement;
  close(): void;
};

const { DatabaseSync } = require('node:sqlite') as {
  DatabaseSync: new (filename: string) => SQLiteDatabase;
};

export type LocalCameraEventInput = {
  id?: string;
  event_hash?: string;
  camera_id: string;
  stream_name: string;
  event_type: string;
  event_state?: string | number | boolean | null;
  topic?: string | null;
  source_name?: string | null;
  occurred_at?: string | Date | number | null;
  data?: Record<string, unknown> | null;
};

export type LocalCameraEvent = {
  id: string;
  camera_id: string;
  stream_name: string;
  event_type: string;
  event_state: string | null;
  topic: string | null;
  source_name: string | null;
  occurred_at: string;
  created_at: string;
  data: Record<string, unknown>;
};

let db: SQLiteDatabase | null = null;
let dbPath = '';
let initializedAt: string | null = null;
let lastInsertAt: string | null = null;
let lastError: string | null = null;
let healthCache: Record<string, unknown> | null = null;
let healthCacheAt = 0;

function boolEnv(name: string, fallback: boolean): boolean {
  const raw = process.env[name];
  if (raw === undefined || raw === null || raw === '') return fallback;
  return ['1', 'true', 'yes', 'on'].includes(String(raw).toLowerCase());
}

function intEnv(name: string, fallback: number, min: number, max: number): number {
  const parsed = Number(process.env[name] ?? fallback);
  if (!Number.isFinite(parsed)) return fallback;
  return Math.max(min, Math.min(max, Math.trunc(parsed)));
}

export function localEventDbPath(): string {
  const configured = String(process.env.DVR_EVENT_DB || process.env.EVENT_DB_PATH || '').trim();
  if (configured) return configured;
  return path.join(path.dirname(config.dvrRoot), 'events', 'events.sqlite3');
}

function stableJson(value: unknown): string {
  if (value === null || value === undefined) return 'null';
  if (Array.isArray(value)) return `[${value.map((item) => stableJson(item)).join(',')}]`;
  if (typeof value === 'object') {
    const object = value as Record<string, unknown>;
    return `{${Object.keys(object).sort().map((key) => `${JSON.stringify(key)}:${stableJson(object[key])}`).join(',')}}`;
  }
  return JSON.stringify(value);
}

function normalizeOccurredAt(value: LocalCameraEventInput['occurred_at']): number {
  if (value instanceof Date) {
    const time = value.getTime();
    return Number.isFinite(time) ? time : Date.now();
  }
  if (typeof value === 'number') return Number.isFinite(value) ? value : Date.now();
  if (typeof value === 'string' && value.trim()) {
    const time = Date.parse(value);
    return Number.isFinite(time) ? time : Date.now();
  }
  return Date.now();
}

function normalizeState(value: LocalCameraEventInput['event_state']): string | null {
  if (value === undefined || value === null) return null;
  if (typeof value === 'boolean') return value ? 'true' : 'false';
  return String(value);
}

function eventHash(input: LocalCameraEventInput, occurredAtMs: number, data: Record<string, unknown>): string {
  if (input.event_hash) return String(input.event_hash);
  return crypto
    .createHash('sha256')
    .update([
      input.camera_id,
      input.stream_name,
      input.event_type,
      normalizeState(input.event_state) ?? '',
      input.topic ?? '',
      input.source_name ?? '',
      new Date(occurredAtMs).toISOString(),
      stableJson(data)
    ].join('|'))
    .digest('hex');
}

function ensureDatabase(): SQLiteDatabase {
  if (db) return db;
  initializeLocalEventStore();
  if (!db) throw new Error('Local event database did not initialize');
  return db;
}

export function initializeLocalEventStore(): void {
  if (db) return;

  dbPath = localEventDbPath();
  fs.mkdirSync(path.dirname(dbPath), { recursive: true, mode: 0o750 });

  try {
    const opened = new DatabaseSync(dbPath);
    opened.exec(`
      PRAGMA journal_mode = WAL;
      PRAGMA synchronous = NORMAL;
      PRAGMA foreign_keys = ON;
      PRAGMA busy_timeout = 5000;

      CREATE TABLE IF NOT EXISTS camera_events (
        id TEXT PRIMARY KEY,
        event_hash TEXT NOT NULL,
        camera_id TEXT NOT NULL,
        stream_name TEXT NOT NULL,
        event_type TEXT NOT NULL,
        event_state TEXT,
        topic TEXT,
        source_name TEXT,
        occurred_at_ms INTEGER NOT NULL,
        created_at_ms INTEGER NOT NULL,
        data_json TEXT NOT NULL
      );

      CREATE UNIQUE INDEX IF NOT EXISTS camera_events_camera_hash
        ON camera_events(camera_id, event_hash);

      CREATE INDEX IF NOT EXISTS camera_events_stream_time
        ON camera_events(stream_name, occurred_at_ms);

      CREATE INDEX IF NOT EXISTS camera_events_camera_time
        ON camera_events(camera_id, occurred_at_ms);

      CREATE INDEX IF NOT EXISTS camera_events_type_time
        ON camera_events(event_type, occurred_at_ms);
    `);
    db = opened;
    initializedAt = new Date().toISOString();
    lastError = null;
    console.log('[event-store] initialized', {
      path: dbPath,
      journal_mode: 'WAL',
      retention_days: intEnv('DVR_EVENT_RETENTION_DAYS', 30, 1, 3650)
    });
  } catch (error) {
    lastError = error instanceof Error ? error.message : String(error);
    throw error;
  }
}

export function appendLocalEvent(input: LocalCameraEventInput): { inserted: boolean; id: string; event_hash: string } {
  const database = ensureDatabase();

  if (!input.camera_id || !input.stream_name || !input.event_type) {
    throw new Error('camera_id, stream_name and event_type are required');
  }

  const data = input.data && typeof input.data === 'object' ? input.data : {};
  const occurredAtMs = normalizeOccurredAt(input.occurred_at);
  const createdAtMs = Date.now();
  const hash = eventHash(input, occurredAtMs, data);
  const id = input.id || crypto.randomUUID();

  try {
    const result = database.prepare(`
      INSERT OR IGNORE INTO camera_events(
        id, event_hash, camera_id, stream_name, event_type, event_state,
        topic, source_name, occurred_at_ms, created_at_ms, data_json
      )
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    `).run(
      id,
      hash,
      input.camera_id,
      input.stream_name,
      input.event_type,
      normalizeState(input.event_state),
      input.topic ?? null,
      input.source_name ?? null,
      occurredAtMs,
      createdAtMs,
      JSON.stringify(data)
    );

    const inserted = Number(result.changes) > 0;
    let actualId = id;
    if (!inserted) {
      const existing = database.prepare(
        'SELECT id FROM camera_events WHERE camera_id = ? AND event_hash = ? LIMIT 1'
      ).get(input.camera_id, hash);
      if (existing?.id) actualId = String(existing.id);
    } else {
      lastInsertAt = new Date(createdAtMs).toISOString();
      healthCache = null;
    }

    lastError = null;
    return { inserted, id: actualId, event_hash: hash };
  } catch (error) {
    lastError = error instanceof Error ? error.message : String(error);
    throw error;
  }
}

export function appendLocalEvents(events: LocalCameraEventInput[]): {
  received: number;
  inserted: number;
  duplicates: number;
} {
  let inserted = 0;
  for (const event of events) {
    if (appendLocalEvent(event).inserted) inserted += 1;
  }
  return {
    received: events.length,
    inserted,
    duplicates: events.length - inserted
  };
}

function rowToEvent(row: Record<string, unknown>): LocalCameraEvent {
  let data: Record<string, unknown> = {};
  try {
    const parsed = JSON.parse(String(row.data_json || '{}'));
    if (parsed && typeof parsed === 'object' && !Array.isArray(parsed)) data = parsed;
  } catch {
    data = { _invalid_json: true };
  }

  return {
    id: String(row.id),
    camera_id: String(row.camera_id),
    stream_name: String(row.stream_name),
    event_type: String(row.event_type),
    event_state: row.event_state === null || row.event_state === undefined ? null : String(row.event_state),
    topic: row.topic === null || row.topic === undefined ? null : String(row.topic),
    source_name: row.source_name === null || row.source_name === undefined ? null : String(row.source_name),
    occurred_at: new Date(Number(row.occurred_at_ms)).toISOString(),
    created_at: new Date(Number(row.created_at_ms)).toISOString(),
    data
  };
}

export function listLocalEvents(params: {
  streamName: string;
  start: Date;
  end: Date;
  type?: string;
  limit?: number;
}): LocalCameraEvent[] {
  const database = ensureDatabase();
  const limit = Math.max(1, Math.min(5000, Math.trunc(params.limit || 5000)));
  const values: unknown[] = [params.streamName, params.start.getTime(), params.end.getTime()];

  let typeFilter = '';
  if (params.type) {
    typeFilter = ' AND event_type = ?';
    values.push(params.type);
  }
  values.push(limit);

  const rows = database.prepare(`
    SELECT id, camera_id, stream_name, event_type, event_state, topic,
           source_name, occurred_at_ms, created_at_ms, data_json
      FROM camera_events
     WHERE stream_name = ?
       AND occurred_at_ms >= ?
       AND occurred_at_ms <= ?
       ${typeFilter}
     ORDER BY occurred_at_ms ASC
     LIMIT ?
  `).all(...values);

  return rows.map(rowToEvent);
}

export function summarizeLocalEvents(params: {
  streamName: string;
  start: Date;
  end: Date;
}): Array<{ bucket: string; count: number; types: string[] }> {
  const database = ensureDatabase();
  const rows = database.prepare(`
    SELECT CAST(occurred_at_ms / 60000 AS INTEGER) * 60000 AS bucket_ms,
           count(*) AS count,
           group_concat(DISTINCT event_type) AS types
      FROM camera_events
     WHERE stream_name = ?
       AND occurred_at_ms >= ?
       AND occurred_at_ms <= ?
     GROUP BY bucket_ms
     ORDER BY bucket_ms ASC
  `).all(params.streamName, params.start.getTime(), params.end.getTime());

  return rows.map((row) => ({
    bucket: new Date(Number(row.bucket_ms)).toISOString(),
    count: Number(row.count || 0),
    types: String(row.types || '')
      .split(',')
      .map((value) => value.trim())
      .filter(Boolean)
      .sort()
  }));
}

export function cleanupLocalEvents(retentionDays = intEnv('DVR_EVENT_RETENTION_DAYS', 30, 1, 3650)): number {
  const database = ensureDatabase();
  const cutoff = Date.now() - retentionDays * 24 * 60 * 60 * 1000;
  const result = database.prepare('DELETE FROM camera_events WHERE occurred_at_ms < ?').run(cutoff);
  const deleted = Number(result.changes);
  if (deleted > 0) {
    healthCache = null;
    database.exec('PRAGMA wal_checkpoint(PASSIVE);');
    console.log('[event-store] retention cleanup', {
      deleted,
      retention_days: retentionDays,
      cutoff: new Date(cutoff).toISOString()
    });
  }
  return deleted;
}

export function startLocalEventRetention(): void {
  const run = () => {
    try {
      cleanupLocalEvents();
    } catch (error) {
      console.error('[event-store] retention failed', error instanceof Error ? error.message : error);
    }
  };
  run();
  const intervalMs = intEnv('DVR_EVENT_CLEANUP_INTERVAL_MINUTES', 60, 5, 24 * 60) * 60_000;
  const timer = setInterval(run, intervalMs);
  timer.unref?.();
}

export function getLocalEventStoreHealth(): Record<string, unknown> {
  if (healthCache && Date.now() - healthCacheAt < 30_000) return healthCache;
  try {
    const database = ensureDatabase();
    const countRow = database.prepare(`
      SELECT count(*) AS total,
             min(occurred_at_ms) AS first_event_ms,
             max(occurred_at_ms) AS last_event_ms
        FROM camera_events
    `).get() || {};

    let sizeBytes: number | null = null;
    try {
      sizeBytes = fs.statSync(dbPath).size;
    } catch {
      sizeBytes = null;
    }

    healthCache = {
      ok: true,
      storage: 'sqlite',
      path: dbPath,
      wal: true,
      total_events: Number(countRow.total || 0),
      first_event_at: countRow.first_event_ms ? new Date(Number(countRow.first_event_ms)).toISOString() : null,
      last_event_at: countRow.last_event_ms ? new Date(Number(countRow.last_event_ms)).toISOString() : null,
      database_size_bytes: sizeBytes,
      initialized_at: initializedAt,
      last_insert_at: lastInsertAt,
      last_error: lastError,
      retention_days: intEnv('DVR_EVENT_RETENTION_DAYS', 30, 1, 3650),
      raw_payload_storage: boolEnv('ONVIF_EVENTS_STORE_RAW', false)
    };
    healthCacheAt = Date.now();
    return healthCache;
  } catch (error) {
    lastError = error instanceof Error ? error.message : String(error);
    return {
      ok: false,
      storage: 'sqlite',
      path: dbPath || localEventDbPath(),
      last_error: lastError
    };
  }
}

export function closeLocalEventStore(): void {
  if (!db) return;
  try {
    db.close();
  } finally {
    db = null;
  }
}
