'use strict';

const http = require('node:http');
const fs = require('node:fs');
const path = require('node:path');
const { spawn } = require('node:child_process');

const VERSION = 'v78-live-only-engine';
const PROJECT_DIR = process.env.PROJECT_DIR || '/opt/newdomofon-video';
const HOST = process.env.LIVE_ONLY_HOST || '127.0.0.1';
const PORT = Number(process.env.LIVE_ONLY_PORT || 3063);
const HLS_ROOT = process.env.LIVE_ONLY_ROOT || '/var/lib/newdomofon-video/dvr';
const SEGMENT_SECONDS = Number(process.env.LIVE_ONLY_SEGMENT_SECONDS || 4);
const HLS_LIST_SIZE = Number(process.env.LIVE_ONLY_HLS_LIST_SIZE || 6);
const RECONCILE_SECONDS = Number(process.env.LIVE_ONLY_RECONCILE_SECONDS || 20);
const RTSP_TRANSPORT = process.env.LIVE_ONLY_RTSP_TRANSPORT || 'tcp';
const AUDIO = String(process.env.LIVE_ONLY_AUDIO || 'false') === 'true';
const USE_COPY = String(process.env.LIVE_ONLY_USE_COPY || 'true') === 'true';

const SOURCE_COLUMN_CANDIDATES = [
  'source_url',
  'rtsp_url',
  'stream_url',
  'camera_url',
  'url',
  'source',
  'rtsp',
  'input_url',
  'ffmpeg_source',
];

const processes = new Map();
let lastCameras = [];
let lastError = null;
let sourceColumn = null;
let pool = null;

function log(...args) { console.log('[live-only-engine]', ...args); }
function warn(...args) { console.warn('[live-only-engine]', ...args); }

function readEnvFile(file) {
  const out = {};
  try {
    const text = fs.readFileSync(file, 'utf8');
    for (const line of text.split(/\r?\n/)) {
      const t = line.trim();
      if (!t || t.startsWith('#') || !t.includes('=')) continue;
      const i = t.indexOf('=');
      const k = t.slice(0, i).trim();
      let v = t.slice(i + 1).trim();
      if ((v.startsWith('"') && v.endsWith('"')) || (v.startsWith("'") && v.endsWith("'"))) v = v.slice(1, -1);
      out[k] = v;
    }
  } catch {}
  return out;
}

function mergedEnv() {
  return {
    ...readEnvFile('/etc/newdomofon-video/app.env'),
    ...readEnvFile(path.join(PROJECT_DIR, 'backend/.env')),
    ...process.env,
  };
}

function requirePg() {
  const candidates = [
    'pg',
    path.join(PROJECT_DIR, 'backend/node_modules/pg'),
    path.join(PROJECT_DIR, 'node_modules/pg'),
  ];
  let last = null;
  for (const p of candidates) {
    try { return require(p); } catch (e) { last = e; }
  }
  throw last || new Error('pg module not found');
}

function dbConfig() {
  const e = mergedEnv();
  if (e.DATABASE_URL) return { connectionString: e.DATABASE_URL };
  return {
    host: e.PGHOST || e.POSTGRES_HOST || e.DB_HOST || '127.0.0.1',
    port: Number(e.PGPORT || e.POSTGRES_PORT || e.DB_PORT || 5432),
    database: e.PGDATABASE || e.POSTGRES_DB || e.DB_NAME || e.DB_DATABASE || 'newdomofon_video',
    user: e.PGUSER || e.POSTGRES_USER || e.DB_USER || 'postgres',
    password: e.PGPASSWORD || e.POSTGRES_PASSWORD || e.DB_PASSWORD || undefined,
  };
}

function getPool() {
  if (pool) return pool;
  const { Pool } = requirePg();
  pool = new Pool({ ...dbConfig(), max: 4, idleTimeoutMillis: 30000, connectionTimeoutMillis: 5000 });
  pool.on('error', (e) => warn('pool error', e.message || e));
  return pool;
}

function qIdent(name) {
  return '"' + String(name).replace(/"/g, '""') + '"';
}

async function detectSourceColumn() {
  if (sourceColumn) return sourceColumn;
  const { rows } = await getPool().query(`
    SELECT column_name
    FROM information_schema.columns
    WHERE table_schema='public' AND table_name='cameras'
  `);
  const set = new Set(rows.map((r) => String(r.column_name)));
  sourceColumn = SOURCE_COLUMN_CANDIDATES.find((c) => set.has(c)) || null;
  if (!sourceColumn) {
    throw new Error('No RTSP/source column found in public.cameras. Tried: ' + SOURCE_COLUMN_CANDIDATES.join(', '));
  }
  log('detected source column', sourceColumn);
  return sourceColumn;
}

async function loadCameras() {
  const srcCol = await detectSourceColumn();
  const sql = `
    SELECT
      id::text AS id,
      name,
      stream_name,
      ${qIdent(srcCol)} AS source_url,
      is_enabled,
      archive_enabled
    FROM public.cameras
    WHERE COALESCE(is_enabled, true) = true
      AND COALESCE(archive_enabled, true) = false
      AND stream_name IS NOT NULL
      AND NULLIF(TRIM(${qIdent(srcCol)}::text), '') IS NOT NULL
    ORDER BY stream_name
  `;
  const { rows } = await getPool().query(sql);
  return rows;
}

function ensureDir(dir) {
  fs.mkdirSync(dir, { recursive: true });
}

function streamDir(stream) {
  return path.join(HLS_ROOT, stream);
}

function ffmpegArgs(camera) {
  const dir = streamDir(camera.stream_name);
  ensureDir(dir);

  const playlist = path.join(dir, 'index.m3u8');
  const segmentPattern = path.join(dir, '%Y-%m-%d', '%H', '%Y%m%d_%H%M%S.ts');

  const args = [
    '-hide_banner',
    '-loglevel', 'warning',
    '-nostdin',
    '-rtsp_transport', RTSP_TRANSPORT,
    '-i', camera.source_url,
    '-map', '0:v:0',
  ];

  if (USE_COPY) args.push('-c:v', 'copy');
  else args.push('-c:v', 'libx264', '-preset', 'veryfast', '-tune', 'zerolatency');

  if (AUDIO) {
    args.push('-map', '0:a?', '-c:a', 'aac', '-b:a', '64k');
  } else {
    args.push('-an');
  }

  args.push(
    '-f', 'hls',
    '-hls_time', String(SEGMENT_SECONDS),
    '-hls_list_size', String(HLS_LIST_SIZE),
    '-hls_delete_threshold', '2',
    '-hls_flags', 'delete_segments+independent_segments+program_date_time',
    '-strftime', '1',
    '-strftime_mkdir', '1',
    '-hls_segment_filename', segmentPattern,
    playlist
  );

  return args;
}

function writeAliases(stream) {
  const dir = streamDir(stream);
  const index = path.join(dir, 'index.m3u8');
  const live = path.join(dir, 'live.m3u8');

  try {
    if (!fs.existsSync(live)) fs.symlinkSync('index.m3u8', live);
  } catch {
    try { fs.copyFileSync(index, live); } catch {}
  }
}

function startCamera(camera) {
  const key = camera.stream_name;
  if (processes.has(key)) return;

  ensureDir(streamDir(key));

  const args = ffmpegArgs(camera);
  log('starting live-only ffmpeg', {
    stream: key,
    id: camera.id,
    name: camera.name,
    playlist: path.join(streamDir(key), 'index.m3u8'),
  });

  const child = spawn('ffmpeg', args, { stdio: ['ignore', 'ignore', 'pipe'] });

  const state = {
    camera,
    child,
    startedAt: new Date().toISOString(),
    restarts: 0,
    lastExit: null,
    stderrTail: [],
    stopping: false,
  };

  child.stderr.on('data', (buf) => {
    const lines = String(buf).split(/\r?\n/).filter(Boolean);
    for (const line of lines) {
      state.stderrTail.push(line);
      while (state.stderrTail.length > 30) state.stderrTail.shift();
      warn(key, line);
    }
  });

  child.on('exit', (code, signal) => {
    state.lastExit = { code, signal, at: new Date().toISOString() };
    processes.delete(key);
    warn('ffmpeg exited', { stream: key, code, signal, stopping: state.stopping });

    if (!state.stopping) {
      setTimeout(() => {
        startCamera(camera);
      }, 3000);
    }
  });

  processes.set(key, state);

  setInterval(() => writeAliases(key), 5000).unref();
}

function stopCamera(stream) {
  const state = processes.get(stream);
  if (!state) return;

  state.stopping = true;
  processes.delete(stream);

  try { state.child.kill('SIGTERM'); } catch {}
  setTimeout(() => {
    try {
      if (!state.child.killed) state.child.kill('SIGKILL');
    } catch {}
  }, 3000).unref();

  log('stopped live-only ffmpeg', { stream });
}

async function reconcile() {
  try {
    const cameras = await loadCameras();
    lastCameras = cameras;
    lastError = null;

    const wanted = new Set(cameras.map((c) => c.stream_name));

    for (const stream of Array.from(processes.keys())) {
      if (!wanted.has(stream)) stopCamera(stream);
    }

    for (const camera of cameras) {
      startCamera(camera);
    }
  } catch (e) {
    lastError = e.message || String(e);
    warn('reconcile failed', lastError);
  }
}

function status() {
  const proc = {};
  for (const [stream, state] of processes.entries()) {
    proc[stream] = {
      pid: state.child.pid,
      started_at: state.startedAt,
      last_exit: state.lastExit,
      stderr_tail: state.stderrTail.slice(-10),
      source_present: Boolean(state.camera.source_url),
      playlist_exists: fs.existsSync(path.join(streamDir(stream), 'index.m3u8')),
      playlist: path.join(streamDir(stream), 'index.m3u8'),
    };
  }

  return {
    ok: !lastError,
    service: 'newdomofon-live-only-engine',
    version: VERSION,
    hls_root: HLS_ROOT,
    source_column: sourceColumn,
    camera_count: lastCameras.length,
    running_count: processes.size,
    cameras: lastCameras.map((c) => ({
      id: c.id,
      name: c.name,
      stream_name: c.stream_name,
      archive_enabled: c.archive_enabled,
      is_enabled: c.is_enabled,
      running: processes.has(c.stream_name),
      playlist_exists: fs.existsSync(path.join(streamDir(c.stream_name), 'index.m3u8')),
    })),
    processes: proc,
    last_error: lastError,
  };
}

http.createServer((req, res) => {
  if ((req.url || '').startsWith('/health') || (req.url || '').startsWith('/status')) {
    const body = JSON.stringify(status(), null, 2);
    res.writeHead(lastError ? 500 : 200, {
      'content-type': 'application/json; charset=utf-8',
      'cache-control': 'no-store',
      'access-control-allow-origin': '*',
    });
    res.end(body);
    return;
  }

  res.writeHead(404, { 'content-type': 'application/json' });
  res.end(JSON.stringify({ error: 'Not found' }));
}).listen(PORT, HOST, () => {
  log('listening', {
    host: HOST,
    port: PORT,
    version: VERSION,
    hls_root: HLS_ROOT,
    segment_seconds: SEGMENT_SECONDS,
    hls_list_size: HLS_LIST_SIZE,
  });
});

process.on('SIGTERM', () => {
  log('SIGTERM');
  for (const stream of Array.from(processes.keys())) stopCamera(stream);
  setTimeout(() => process.exit(0), 1000);
});

reconcile();
setInterval(reconcile, RECONCILE_SECONDS * 1000);
