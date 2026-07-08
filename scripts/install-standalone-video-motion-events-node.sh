#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="${PROJECT_DIR:-/opt/newdomofon-video}"
ENV_FILE="${ENV_FILE:-/etc/newdomofon-video/app.env}"
SERVICE="${SERVICE:-newdomofon-video-motion-events.service}"
SCRIPT_PATH="$PROJECT_DIR/video-motion-events-service.js"
STREAMS="${EVENT_STREAMS:-${VIDEO_MOTION_STREAMS:-onvif2,onf}}"
BACKUP_DIR="$PROJECT_DIR/backups/standalone-video-motion-events-node-$(date +%Y%m%d-%H%M%S)"

mkdir -p "$BACKUP_DIR"
[ -f "$SCRIPT_PATH" ] && cp -a "$SCRIPT_PATH" "$BACKUP_DIR/video-motion-events-service.js.bak" || true
[ -f "$ENV_FILE" ] && cp -a "$ENV_FILE" "$BACKUP_DIR/app.env.bak" || true

set -a
[ -f "$ENV_FILE" ] && . "$ENV_FILE"
set +a

if [ -z "${INTERNAL_DVR_SECRET:-}" ]; then
  echo "ERROR: INTERNAL_DVR_SECRET is empty on node. It must match master." >&2
  exit 1
fi

if [ -z "${BACKEND_INTERNAL_URL:-${BACKEND_URL:-}}" ]; then
  sudo sed -i -E '/^(BACKEND_INTERNAL_URL|BACKEND_URL)=/d' "$ENV_FILE" 2>/dev/null || true
  echo 'BACKEND_INTERNAL_URL=http://10.106.1.30:3000' | sudo tee -a "$ENV_FILE" >/dev/null
fi

cat > "$SCRIPT_PATH" <<'JS'
'use strict';

const fs = require('node:fs');
const path = require('node:path');
const { spawn } = require('node:child_process');

const VERSION = 'v1-standalone-video-motion-events';

function flag(name, fallback = false) {
  const raw = process.env[name];
  if (raw === undefined || raw === null || raw === '') return fallback;
  return ['1', 'true', 'yes', 'on'].includes(String(raw).trim().toLowerCase());
}

function num(name, fallback, min, max = Number.POSITIVE_INFINITY) {
  const raw = Number(process.env[name] || fallback);
  if (!Number.isFinite(raw)) return fallback;
  return Math.max(min, Math.min(max, raw));
}

function csv(name, fallback = '') {
  return String(process.env[name] || fallback)
    .split(',')
    .map((item) => item.trim())
    .filter(Boolean);
}

function cfg() {
  const streams = new Set(csv('VIDEO_MOTION_STREAMS', process.env.DVR_VIDEO_MOTION_STREAMS || ''));
  return {
    enabled: flag('VIDEO_MOTION_ENABLED', streams.size > 0),
    backendUrl: String(process.env.BACKEND_INTERNAL_URL || process.env.BACKEND_URL || process.env.API_BASE_URL || 'http://10.106.1.30:3000').replace(/\/+$/, ''),
    secret: process.env.INTERNAL_DVR_SECRET || '',
    nodeId: process.env.DVR_NODE_ID || process.env.NODE_ID || '3348ffdf-2455-472f-a941-4eb456fb1df6',
    streams,
    allStreams: streams.has('*'),
    roots: csv('DVR_ROOTS', process.env.DVR_ROOT || '/var/lib/newdomofon-video/dvr,/var/dvr'),
    ffmpeg: process.env.FFMPEG_PATH || process.env.DVR_FFMPEG_PATH || 'ffmpeg',
    fps: num('VIDEO_MOTION_FPS', 2, 0.2, 15),
    width: Math.round(num('VIDEO_MOTION_SCALE_WIDTH', 320, 80, 1920)),
    threshold: num('VIDEO_MOTION_SCENE_THRESHOLD', 0.004, 0.000001, 1),
    endIdleMs: Math.round(num('VIDEO_MOTION_END_IDLE_MS', 8000, 1000, 120000)),
    cooldownMs: Math.round(num('VIDEO_MOTION_COOLDOWN_MS', 3000, 0, 120000)),
    reloadMs: Math.round(num('VIDEO_MOTION_RELOAD_MS', 15000, 5000, 300000)),
    restartMinMs: Math.round(num('VIDEO_MOTION_RESTART_MIN_MS', 5000, 1000, 300000)),
    maxDetectors: Math.round(num('VIDEO_MOTION_MAX_DETECTORS', 4, 1, 128)),
    eventType: process.env.VIDEO_MOTION_EVENT_TYPE || 'video.motion',
    sourceMode: String(process.env.VIDEO_MOTION_SOURCE || process.env.DVR_VIDEO_MOTION_SOURCE || 'hls').toLowerCase() === 'rtsp' ? 'rtsp' : 'hls',
    logScores: flag('VIDEO_MOTION_LOG_SCORES', false),
    logScoreEveryMs: Math.round(num('VIDEO_MOTION_SCORE_LOG_MS', 30000, 5000, 300000))
  };
}

const detectors = new Map();
const cooldownUntil = new Map();
let syncing = false;
let lastScoreLogAt = new Map();

function redactUri(uri) {
  try {
    const u = new URL(uri);
    if (u.username) u.username = '***';
    if (u.password) u.password = '***';
    return u.toString();
  } catch (_) {
    return '<invalid-url>';
  }
}

function livePlaylistFor(stream, roots) {
  for (const root of roots) {
    const file = path.join(root, stream, 'live.m3u8');
    if (fs.existsSync(file)) return file;
  }
  return path.join(roots[0] || '/var/lib/newdomofon-video/dvr', stream, 'live.m3u8');
}

async function fetchJson(url, options = {}, timeoutMs = 15000) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    const response = await fetch(url, { ...options, signal: controller.signal });
    const text = await response.text();
    if (!response.ok) throw new Error(`HTTP ${response.status}: ${text.slice(0, 300)}`);
    return text ? JSON.parse(text) : {};
  } finally {
    clearTimeout(timer);
  }
}

async function loadCameras() {
  const config = cfg();
  const data = await fetchJson(`${config.backendUrl}/api/internal/cameras/onvif`, {
    headers: {
      'x-internal-secret': config.secret,
      'x-node-id': config.nodeId
    }
  });
  return Array.isArray(data.items) ? data.items : [];
}

async function postEvent(camera, active, score, frame) {
  const config = cfg();
  const occurredAt = new Date().toISOString();
  const payload = {
    camera_id: camera.id,
    stream_name: camera.stream_name,
    event_type: config.eventType,
    event_state: active ? 'true' : 'false',
    topic: config.eventType,
    source_name: 'ffmpeg-scene-standalone',
    occurred_at: occurredAt,
    data: {
      simple: {
        IsMotion: active ? 'true' : 'false',
        SceneScore: String(score),
        Threshold: String(config.threshold)
      },
      detector: 'ffmpeg-scene-standalone',
      version: VERSION,
      source_name: 'ffmpeg-scene-standalone',
      score,
      threshold: config.threshold,
      fps: config.fps,
      scale_width: config.width,
      end_idle_ms: config.endIdleMs,
      source: config.sourceMode,
      frame
    }
  };

  return fetchJson(`${config.backendUrl}/api/internal/events/onvif`, {
    method: 'POST',
    headers: {
      'content-type': 'application/json',
      'x-internal-secret': config.secret,
      'x-node-id': config.nodeId
    },
    body: JSON.stringify(payload)
  });
}

function parseScoreLine(line, frame) {
  const frameMatch = String(line).match(/^frame:(\d+)\s+pts:([^\s]+)\s+pts_time:([^\s]+)/);
  if (frameMatch) {
    frame.frame = frameMatch[1];
    frame.pts = frameMatch[2];
    frame.pts_time = frameMatch[3];
    return null;
  }
  const scoreMatch = String(line).match(/lavfi\.scene_score=([0-9.eE+-]+)/);
  if (!scoreMatch) return null;
  const score = Number(scoreMatch[1]);
  return Number.isFinite(score) ? score : null;
}

async function handleScore(state, score) {
  const config = cfg();
  const now = Date.now();
  state.maxScore = Math.max(state.maxScore, score);
  state.lastScoreAt = now;

  const lastLog = lastScoreLogAt.get(state.camera.stream_name) || 0;
  if (config.logScores && now - lastLog >= config.logScoreEveryMs) {
    lastScoreLogAt.set(state.camera.stream_name, now);
    console.log('[video-motion-standalone] score', {
      stream_name: state.camera.stream_name,
      score,
      maxScore: state.maxScore,
      threshold: config.threshold,
      active: state.active,
      frame: state.frame
    });
  }

  if (score >= config.threshold) {
    state.lastAboveAt = now;
    if (!state.active && now >= (cooldownUntil.get(state.camera.stream_name) || 0)) {
      state.active = true;
      const result = await postEvent(state.camera, true, score, state.frame);
      console.log('[video-motion-standalone] motion start', {
        stream_name: state.camera.stream_name,
        score,
        threshold: config.threshold,
        inserted: Boolean(result.inserted),
        occurred_at: new Date().toISOString(),
        frame: state.frame
      });
    }
    return;
  }

  if (state.active && state.lastAboveAt && now - state.lastAboveAt >= config.endIdleMs) {
    state.active = false;
    cooldownUntil.set(state.camera.stream_name, now + config.cooldownMs);
    const result = await postEvent(state.camera, false, score, state.frame);
    console.log('[video-motion-standalone] motion end', {
      stream_name: state.camera.stream_name,
      score,
      threshold: config.threshold,
      inserted: Boolean(result.inserted),
      idleMs: now - state.lastAboveAt,
      occurred_at: new Date().toISOString(),
      frame: state.frame
    });
  }
}

function startDetector(camera, restart = 0) {
  const config = cfg();
  if (detectors.has(camera.stream_name)) return;

  const input = config.sourceMode === 'rtsp' ? camera.source_url : livePlaylistFor(camera.stream_name, config.roots);
  if (!input) {
    console.warn('[video-motion-standalone] no input', { stream_name: camera.stream_name });
    return;
  }

  const preInput = config.sourceMode === 'rtsp'
    ? ['-rtsp_transport', process.env.DVR_RTSP_TRANSPORT || 'tcp', '-timeout', String(Number(process.env.DVR_RTSP_TIMEOUT_US || 15000000))]
    : ['-live_start_index', '-3'];

  const filter = `fps=${config.fps},scale=${config.width}:-1,select='gte(scene,0)',metadata=mode=print:key=lavfi.scene_score:file=-`;
  const args = [
    '-hide_banner',
    '-loglevel', 'warning',
    '-nostdin',
    '-fflags', '+genpts+discardcorrupt',
    ...preInput,
    '-i', input,
    '-an',
    '-vf', filter,
    '-f', 'null',
    '/dev/null'
  ];

  const child = spawn(config.ffmpeg, args, { stdio: ['ignore', 'pipe', 'pipe'] });
  const state = {
    camera,
    child,
    active: false,
    lastAboveAt: null,
    lastScoreAt: null,
    maxScore: 0,
    frame: {},
    buffer: '',
    startedAt: Date.now(),
    stopping: false
  };
  detectors.set(camera.stream_name, state);

  console.log('[video-motion-standalone] detector started', {
    version: VERSION,
    stream_name: camera.stream_name,
    pid: child.pid,
    sourceMode: config.sourceMode,
    source: config.sourceMode === 'rtsp' ? redactUri(input) : input,
    fps: config.fps,
    width: config.width,
    threshold: config.threshold,
    endIdleMs: config.endIdleMs
  });

  function onChunk(chunk) {
    state.buffer += String(chunk);
    const lines = state.buffer.split(/\r?\n/);
    state.buffer = lines.pop() || '';
    for (const line of lines) {
      const score = parseScoreLine(line, state.frame);
      if (score === null) continue;
      handleScore(state, score).catch((error) => console.error('[video-motion-standalone] score failed', camera.stream_name, error.message || error));
    }
  }

  child.stdout.on('data', onChunk);
  child.stderr.on('data', (chunk) => {
    const text = String(chunk);
    onChunk(text);
    if (/error|failed|invalid|404|403/i.test(text)) {
      console.warn(`[video-motion-standalone:ffmpeg:${camera.stream_name}] ${text.trim().slice(0, 500)}`);
    }
  });

  child.on('exit', (code, signal) => {
    const current = detectors.get(camera.stream_name);
    if (current && current.child.pid === child.pid) detectors.delete(camera.stream_name);
    console.warn('[video-motion-standalone] detector exited', {
      stream_name: camera.stream_name,
      code,
      signal,
      maxScore: state.maxScore,
      active: state.active
    });
    if (state.active) {
      postEvent(camera, false, state.maxScore, state.frame).catch((error) => console.error('[video-motion-standalone] close event failed', camera.stream_name, error.message || error));
    }
    if (!state.stopping && cfg().enabled) {
      setTimeout(() => startDetector(camera, restart + 1), Math.min(config.restartMinMs + restart * 1000, 60000)).unref?.();
    }
  });
}

function stopDetector(stream, reason) {
  const state = detectors.get(stream);
  if (!state) return;
  console.log('[video-motion-standalone] stopping detector', { stream_name: stream, reason });
  state.stopping = true;
  detectors.delete(stream);
  state.child.kill('SIGTERM');
}

async function sync() {
  if (syncing) return;
  syncing = true;
  try {
    const config = cfg();
    if (!config.enabled) {
      for (const stream of Array.from(detectors.keys())) stopDetector(stream, 'disabled');
      return;
    }
    if (!config.secret) {
      console.warn('[video-motion-standalone] INTERNAL_DVR_SECRET empty');
      return;
    }

    const cameras = (await loadCameras())
      .filter((camera) => camera && camera.stream_name && camera.source_url)
      .filter((camera) => config.allStreams || config.streams.has(camera.stream_name))
      .slice(0, config.maxDetectors);

    const desired = new Set(cameras.map((camera) => camera.stream_name));
    console.log('[video-motion-standalone] desired cameras', { streams: Array.from(desired), count: cameras.length });

    for (const stream of Array.from(detectors.keys())) {
      if (!desired.has(stream)) stopDetector(stream, 'stream removed');
    }

    for (const camera of cameras) startDetector(camera, 0);
  } catch (error) {
    console.error('[video-motion-standalone] sync failed', error.message || error);
  } finally {
    syncing = false;
  }
}

console.log('[video-motion-standalone] enabled', {
  version: VERSION,
  backendUrl: cfg().backendUrl,
  nodeId: cfg().nodeId,
  streams: Array.from(cfg().streams),
  sourceMode: cfg().sourceMode,
  threshold: cfg().threshold,
  roots: cfg().roots
});

sync().catch(() => undefined);
setInterval(() => sync().catch(() => undefined), cfg().reloadMs);

process.on('SIGTERM', () => {
  for (const stream of Array.from(detectors.keys())) stopDetector(stream, 'SIGTERM');
  setTimeout(() => process.exit(0), 1000).unref?.();
});
JS

chmod 0755 "$SCRIPT_PATH"

sudo sed -i -E '/^(VIDEO_MOTION_ENABLED|VIDEO_MOTION_STREAMS|DVR_VIDEO_MOTION_STREAMS|VIDEO_MOTION_SOURCE|DVR_VIDEO_MOTION_SOURCE|VIDEO_MOTION_FPS|VIDEO_MOTION_SCALE_WIDTH|VIDEO_MOTION_SCENE_THRESHOLD|VIDEO_MOTION_END_IDLE_MS|VIDEO_MOTION_COOLDOWN_MS|VIDEO_MOTION_RELOAD_MS|VIDEO_MOTION_MAX_DETECTORS|VIDEO_MOTION_EVENT_TYPE|VIDEO_MOTION_LOG_SCORES|VIDEO_MOTION_SCORE_LOG_MS)=/d' "$ENV_FILE" 2>/dev/null || true
cat <<EOF | sudo tee -a "$ENV_FILE" >/dev/null
VIDEO_MOTION_ENABLED=true
VIDEO_MOTION_STREAMS=${STREAMS}
DVR_VIDEO_MOTION_STREAMS=${STREAMS}
VIDEO_MOTION_SOURCE=hls
DVR_VIDEO_MOTION_SOURCE=hls
VIDEO_MOTION_FPS=2
VIDEO_MOTION_SCALE_WIDTH=320
VIDEO_MOTION_SCENE_THRESHOLD=${VIDEO_MOTION_SCENE_THRESHOLD_VALUE:-0.004}
VIDEO_MOTION_END_IDLE_MS=8000
VIDEO_MOTION_COOLDOWN_MS=3000
VIDEO_MOTION_RELOAD_MS=15000
VIDEO_MOTION_MAX_DETECTORS=4
VIDEO_MOTION_EVENT_TYPE=video.motion
VIDEO_MOTION_LOG_SCORES=true
VIDEO_MOTION_SCORE_LOG_MS=30000
EOF

sudo tee /etc/systemd/system/${SERVICE} >/dev/null <<EOF
[Unit]
Description=NewDomofon Standalone Video Motion Events
After=network-online.target newdomofon-video-dvr.service
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=${PROJECT_DIR}
EnvironmentFile=${ENV_FILE}
Environment=NODE_ENV=production
ExecStart=/usr/bin/node ${SCRIPT_PATH}
Restart=always
RestartSec=3
User=root

[Install]
WantedBy=multi-user.target
EOF

node --check "$SCRIPT_PATH"
sudo systemctl daemon-reload
sudo systemctl enable --now "$SERVICE"
sudo systemctl restart "$SERVICE"
sleep 8

echo "---- service status ----"
systemctl --no-pager --full status "$SERVICE" | sed -n '1,20p'

echo "---- recent logs ----"
sudo journalctl -u "$SERVICE" --since "2 minutes ago" --no-pager -l | grep -E 'video-motion-standalone|detector started|motion start|motion end|sync failed|ffmpeg' || true

echo "OK: standalone video motion events service installed"
echo "backup_dir=$BACKUP_DIR"
