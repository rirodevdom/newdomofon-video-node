const http = require('node:http');

// v67-raw-http-archive-endlist.
// This service is plain node:http, not Express. Wrap http.createServer and
// append EXT-X-ENDLIST to finite archive VOD playlists when the generator
// omits it. This prevents archive playlist refresh loops in HLS clients.
if (!http.__newdomofonV67ArchiveEndlist) {
  http.__newdomofonV67ArchiveEndlist = true;
  const __newdomofonCreateServer = http.createServer.bind(http);

  http.createServer = function patchedCreateServer(...args) {
    const listenerIndex = args.length && typeof args[args.length - 1] === 'function'
      ? args.length - 1
      : -1;

    if (listenerIndex >= 0) {
      const originalListener = args[listenerIndex];

      args[listenerIndex] = function patchedArchiveListener(req, res) {
        try {
          const requestUrl = new URL(String(req.url || '/'), 'http://127.0.0.1');
          const isArchivePlaylist = /\/archive-\d+-\d+\.m3u8$/i.test(requestUrl.pathname);

          if (isArchivePlaylist && !res.__newdomofonV67EndlistWrapped) {
            res.__newdomofonV67EndlistWrapped = true;
            const originalEnd = res.end.bind(res);

            res.end = function patchedArchiveEnd(chunk, encoding, cb) {
              try {
                let text = null;

                if (Buffer.isBuffer(chunk)) {
                  text = chunk.toString(typeof encoding === 'string' ? encoding : 'utf8');
                } else if (typeof chunk === 'string') {
                  text = chunk;
                }

                if (text && text.includes('#EXTM3U') && !text.includes('#EXT-X-ENDLIST')) {
                  text = text.replace(/\s*$/u, '\n#EXT-X-ENDLIST\n');
                  try { res.removeHeader('Content-Length'); } catch (_) {}
                  try { res.setHeader('Cache-Control', 'no-store'); } catch (_) {}
                  try { res.setHeader('X-Newdomofon-Archive-Endlist', 'v67'); } catch (_) {}
                  return originalEnd(text, encoding, cb);
                }
              } catch (error) {
                try { console.error('[dvr-archive-proxy] v67 ENDLIST patch failed', error); } catch (_) {}
              }

              return originalEnd(chunk, encoding, cb);
            };
          }
        } catch (error) {
          try { console.error('[dvr-archive-proxy] v67 createServer patch failed', error); } catch (_) {}
        }

        return originalListener.call(this, req, res);
      };
    }

    return __newdomofonCreateServer(...args);
  };
}

const fs = require('node:fs');
const fsp = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const { spawn } = require('node:child_process');
const { URL } = require('node:url');

const PORT = Number(process.env.ARCHIVE_PROXY_PORT || 3046);
const HOST = process.env.ARCHIVE_PROXY_HOST || '127.0.0.1';
const DVR_ROOTS = String(process.env.DVR_ROOTS || '/var/lib/newdomofon-video/dvr,/var/dvr')
  .split(',')
  .map((item) => item.trim())
  .filter(Boolean);

const CAMERA_STREAM_MAP = process.env.CAMERA_STREAM_MAP || '/etc/newdomofon-video/camera-stream-map.json';
const STREAM_ALIASES_FILE = process.env.STREAM_ALIASES_FILE || '/etc/newdomofon-video/stream-aliases.json';
const ACCEPTED_TOKENS_FILE = process.env.ACCEPTED_TOKENS_FILE || '/etc/newdomofon-video/restream-accepted-tokens.json';
const PRIMARY_TOKEN = String(process.env.RESTREAM_PUBLIC_TOKEN || process.env.VITE_RESTREAM_PUBLIC_TOKEN || '');
const DVR_FILENAME_TZ_OFFSET_MINUTES = Number(process.env.DVR_FILENAME_TZ_OFFSET_MINUTES || 180);

function readJson(file, fallback) {
  try {
    return JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch {
    return fallback;
  }
}

function cameraMap() {
  return readJson(CAMERA_STREAM_MAP, {});
}

function aliasMap() {
  return readJson(STREAM_ALIASES_FILE, {});
}

function acceptedTokens() {
  const fromFile = readJson(ACCEPTED_TOKENS_FILE, []);
  const tokens = Array.isArray(fromFile) ? fromFile.map(String).filter(Boolean) : [];
  if (PRIMARY_TOKEN && !tokens.includes(PRIMARY_TOKEN)) tokens.unshift(PRIMARY_TOKEN);
  return tokens;
}

function extractToken(req, url) {
  const queryToken = url.searchParams.get('token') || '';
  if (queryToken) return queryToken;

  const auth = String(req.headers.authorization || '');

  if (/^Bearer\s+/i.test(auth)) {
    return auth.replace(/^Bearer\s+/i, '').trim();
  }

  if (/^Basic\s+/i.test(auth)) {
    try {
      const decoded = Buffer.from(auth.replace(/^Basic\s+/i, ''), 'base64').toString('utf8');
      const idx = decoded.indexOf(':');
      return idx >= 0 ? decoded.slice(idx + 1) : decoded;
    } catch {
      return '';
    }
  }

  return '';
}

function isAcceptedToken(token) {
  return acceptedTokens().includes(String(token || ''));
}

function publicToken(token) {
  return token || PRIMARY_TOKEN || acceptedTokens()[0] || '';
}

function cors(extra = {}) {
  return {
    'access-control-allow-origin': '*',
    'access-control-allow-methods': 'GET,HEAD,OPTIONS',
    'access-control-allow-headers': '*',
    'access-control-expose-headers': 'Content-Length,Content-Range,Accept-Ranges,X-Newdomofon-Resolved-Stream,X-Newdomofon-Archive-Ranges,X-Newdomofon-Archive-Coverage',
    'cross-origin-resource-policy': 'cross-origin',
    'x-content-type-options': 'nosniff',
    ...extra
  };
}

function sendJson(res, status, body, extra = {}) {
  const text = JSON.stringify(body);
  res.writeHead(status, cors({
    'content-type': 'application/json; charset=utf-8',
    'cache-control': 'no-store',
    'content-length': Buffer.byteLength(text),
    ...extra
  }));
  res.end(text);
}

function sendText(res, status, text, contentType, extra = {}) {
  res.writeHead(status, cors({
    'content-type': contentType,
    'cache-control': 'no-store',
    'content-length': Buffer.byteLength(text),
    ...extra
  }));
  res.end(text);
}

function sendNoContent(res) {
  res.writeHead(204, cors({
    'cache-control': 'no-store',
    'content-length': '0'
  }));
  res.end();
}

function badStream(stream) {
  return !stream || stream === 'undefined' || stream === 'null' || stream.includes('/') || stream.includes('\\') || stream.includes('..');
}

function resolveStream(raw) {
  const value = String(raw || '').trim();
  const aliases = aliasMap();
  const cameras = cameraMap();

  if (aliases[value]) return String(aliases[value]);
  if (cameras[value]) return String(cameras[value]);
  return value;
}

function safeRel(p) {
  const clean = String(p || '').split('?')[0];
  if (!clean || clean.startsWith('/') || clean.includes('..') || clean.includes('\\') || clean.includes('\0')) return '';
  return clean.split('/').filter(Boolean).join('/');
}

function streamRoots(stream) {
  return DVR_ROOTS.map((root) => path.resolve(root, stream));
}

function filenameLocalMs(filePath) {
  const base = path.basename(filePath);
  const match = /^(\d{4})(\d{2})(\d{2})_(\d{2})(\d{2})(\d{2})\.(ts|m4s|mp4)$/i.exec(base);
  if (!match) return NaN;

  // v49:
  // Segment filenames are written in camera/DVR local time, not necessarily
  // in the timezone used by this Node.js systemd process.
  //
  // Example for Moscow/DVR local time UTC+03:00:
  //   20260526_224409.ts -> 2026-05-26T19:44:09Z
  //
  // Formula:
  //   epoch_utc_ms = Date.UTC(file_components) - offset_minutes
  //
  // Default offset is +180 minutes. Override with:
  //   Environment=DVR_FILENAME_TZ_OFFSET_MINUTES=180
  const utcAssumingFilenameIsUtc = Date.UTC(
    Number(match[1]),
    Number(match[2]) - 1,
    Number(match[3]),
    Number(match[4]),
    Number(match[5]),
    Number(match[6])
  );

  return utcAssumingFilenameIsUtc - DVR_FILENAME_TZ_OFFSET_MINUTES * 60 * 1000;
}


async function scanSegments(stream, startMs, endMs) {
  const results = [];

  for (const root of streamRoots(stream)) {
    try {
      const stat = await fsp.stat(root);
      if (!stat.isDirectory()) continue;
    } catch {
      continue;
    }

    const stack = [root];

    while (stack.length) {
      const dir = stack.pop();
      let entries;

      try {
        entries = await fsp.readdir(dir, { withFileTypes: true });
      } catch {
        continue;
      }

      for (const entry of entries) {
        const full = path.join(dir, entry.name);

        if (entry.isDirectory()) {
          stack.push(full);
          continue;
        }

        if (!entry.isFile() || !/\.(ts|m4s|mp4)$/i.test(entry.name)) continue;

        const ms = filenameLocalMs(full);
        if (!Number.isFinite(ms)) continue;
        if (ms < startMs || ms > endMs) continue;

        const relative = path.relative(root, full).split(path.sep).join('/');
        results.push({ filePath: full, relative, ms });
      }
    }
  }

  results.sort((a, b) => a.ms - b.ms || a.relative.localeCompare(b.relative));
  return results;
}

async function findSegment(stream, rel) {
  const safe = safeRel(rel);
  if (!safe) return null;

  for (const root of streamRoots(stream)) {
    const resolvedRoot = path.resolve(root);
    const candidate = path.resolve(resolvedRoot, safe);

    if (!candidate.startsWith(resolvedRoot + path.sep)) continue;

    try {
      const stat = await fsp.stat(candidate);
      if (stat.isFile()) return { filePath: candidate, stat };
    } catch {
      // next
    }
  }

  return null;
}

function iso(ms) {
  return new Date(ms).toISOString();
}

function parseWindow(mediaPath, url) {
  const start = url.searchParams.get('start');
  const end = url.searchParams.get('end');

  if (start && end) {
    const startMs = Date.parse(start);
    const endMs = Date.parse(end);

    if (Number.isFinite(startMs) && Number.isFinite(endMs) && endMs > startMs) {
      return { startMs, endMs, source: 'query-start-end' };
    }
  }

  let match = /^(archive|index|video|mono)-(\d+)-(now|\d+)\.m3u8$/i.exec(mediaPath);
  if (match) {
    const from = Number(match[2]);
    const duration = match[3] === 'now' ? Math.floor(Date.now() / 1000) - from : Number(match[3]);

    if (Number.isFinite(from) && Number.isFinite(duration) && duration > 0) {
      return { startMs: from * 1000, endMs: (from + duration) * 1000, source: `${match[1]}-hls` };
    }
  }

  match = /^(archive|index|video|mono)-(\d+)-(now|\d+)\.mp4$/i.exec(mediaPath);
  if (match) {
    const from = Number(match[2]);
    const duration = match[3] === 'now' ? Math.floor(Date.now() / 1000) - from : Number(match[3]);

    if (Number.isFinite(from) && Number.isFinite(duration) && duration > 0) {
      return { startMs: from * 1000, endMs: (from + duration) * 1000, source: `${match[1]}-mp4` };
    }
  }

  if (mediaPath === 'export.mp4') {
    return null;
  }

  return null;
}

function segmentDuration(current, next) {
  if (!next) return 4;
  return Math.max(1, Math.min(30, (next.ms - current.ms) / 1000));
}

function playlist(segments, token) {
  const target = Math.max(4, ...segments.slice(0, -1).map((s, i) => Math.ceil(segmentDuration(s, segments[i + 1]))));
  const lines = [
    '#EXTM3U',
    '#EXT-X-VERSION:6',
    `#EXT-X-TARGETDURATION:${target}`,
    '#EXT-X-MEDIA-SEQUENCE:0',
    '#EXT-X-INDEPENDENT-SEGMENTS',
    '#EXT-X-PLAYLIST-TYPE:VOD'
  ];

  for (let i = 0; i < segments.length; i += 1) {
    const segment = segments[i];
    const duration = segmentDuration(segment, segments[i + 1]);
    const uri = token ? `${segment.relative}?token=${encodeURIComponent(token)}` : segment.relative;

    lines.push(`#EXT-X-PROGRAM-DATE-TIME:${iso(segment.ms)}`);
    lines.push(`#EXTINF:${duration.toFixed(3)},`);
    lines.push(uri);
  }

  lines.push('#EXT-X-ENDLIST');
  return lines.join('\n') + '\n';
}

function contentType(filePath) {
  const ext = path.extname(filePath).toLowerCase();
  if (ext === '.ts') return 'video/mp2t';
  if (ext === '.m4s') return 'video/iso.segment';
  if (ext === '.mp4') return 'video/mp4';
  return 'application/octet-stream';
}

function sendFile(req, res, filePath, stat, stream, extra = {}) {
  const total = stat.size;
  const headers = {
    'content-type': extra['content-type'] || contentType(filePath),
    'cache-control': 'no-store',
    'accept-ranges': 'bytes',
    'x-newdomofon-resolved-stream': stream,
    ...extra
  };

  const range = String(req.headers.range || '');
  const match = /^bytes=(\d*)-(\d*)$/.exec(range);

  if (match) {
    const start = match[1] ? Number(match[1]) : 0;
    const end = match[2] ? Number(match[2]) : total - 1;

    if (Number.isFinite(start) && Number.isFinite(end) && start <= end && start < total) {
      const finalEnd = Math.min(end, total - 1);
      const size = finalEnd - start + 1;

      res.writeHead(206, cors({
        ...headers,
        'content-range': `bytes ${start}-${finalEnd}/${total}`,
        'content-length': size
      }));

      fs.createReadStream(filePath, { start, end: finalEnd }).pipe(res);
      return;
    }
  }

  res.writeHead(200, cors({ ...headers, 'content-length': total }));
  fs.createReadStream(filePath).pipe(res);
}

function quoteConcat(filePath) {
  return String(filePath).replace(/'/g, "'\\''");
}

async function ffmpegConcat(files, outFile) {
  const listFile = path.join(path.dirname(outFile), 'concat.txt');
  await fsp.writeFile(listFile, files.map((file) => `file '${quoteConcat(file)}'`).join('\n') + '\n', 'utf8');

  const args = [
    '-hide_banner',
    '-loglevel', 'error',
    '-y',
    '-f', 'concat',
    '-safe', '0',
    '-i', listFile,
    '-c', 'copy',
    '-movflags', '+faststart',
    outFile
  ];

  await new Promise((resolve, reject) => {
    const child = spawn('ffmpeg', args, { stdio: ['ignore', 'ignore', 'pipe'] });
    let stderr = '';

    child.stderr.on('data', (chunk) => {
      stderr += chunk.toString();
      if (stderr.length > 12000) stderr = stderr.slice(-12000);
    });

    child.on('error', reject);
    child.on('close', (code) => {
      code === 0 ? resolve() : reject(new Error(stderr || `ffmpeg exited with code ${code}`));
    });
  });
}

function safeName(s) {
  return String(s || 'archive').replace(/[^A-Za-z0-9_.-]+/g, '_').slice(0, 120) || 'archive';
}

function archiveRangePayload(range) {
  const from = Math.floor(range.start / 1000);
  const to = Math.ceil(range.end / 1000);
  const duration = Math.max(1, to - from);

  return {
    from,
    to,
    duration,
    start: from,
    end: to,
    startMs: range.start,
    endMs: range.end,
    from_iso: iso(range.start),
    to_iso: iso(range.end),
    start_iso: iso(range.start),
    end_iso: iso(range.end)
  };
}

function gapPayload(gap) {
  const from = Math.floor(gap.start / 1000);
  const to = Math.ceil(gap.end / 1000);
  return {
    from,
    to,
    duration: Math.max(1, to - from),
    start: from,
    end: to,
    startMs: gap.start,
    endMs: gap.end,
    from_iso: iso(gap.start),
    to_iso: iso(gap.end),
    start_iso: iso(gap.start),
    end_iso: iso(gap.end)
  };
}

function archiveMetadataPayload(stream, segments, ranges, gaps, source) {
  const first = segments[0] || null;
  const last = segments[segments.length - 1] || null;
  const stableRanges = ranges.map(archiveRangePayload);
  const stableGaps = gaps.map(gapPayload);

  return {
    ok: true,
    source,
    stream,
    stream_name: stream,
    name: stream,
    dvr: true,
    recording: Boolean(last),
    from: first ? Math.floor(first.ms / 1000) : null,
    to: last ? Math.floor(last.ms / 1000) : null,
    from_iso: first ? iso(first.ms) : null,
    to_iso: last ? iso(last.ms) : null,
    segments: segments.length,
    ranges: stableRanges,
    recordings: stableRanges,
    items: stableRanges,
    streams: [{ stream, name: stream, ranges: stableRanges }],
    gaps: stableGaps
  };
}

async function latestSegment(stream, targetMs = Date.now()) {
  const segments = await scanSegments(stream, 0, Math.max(Date.now() + 60_000, targetMs + 60_000));
  if (!segments.length) return null;
  let best = segments[segments.length - 1];
  let bestDistance = Math.abs(best.ms - targetMs);

  for (const segment of segments) {
    const distance = Math.abs(segment.ms - targetMs);
    if (distance < bestDistance) {
      best = segment;
      bestDistance = distance;
    }
  }

  return best;
}

async function runFfmpegPreview(inputFile, outputFile) {
  await fsp.mkdir(path.dirname(outputFile), { recursive: true });
  const tmp = `${outputFile}.${process.pid}.${Date.now()}.tmp.mp4`;
  const args = [
    '-hide_banner',
    '-loglevel', 'error',
    '-y',
    '-i', inputFile,
    '-t', '1',
    '-an',
    '-vf', 'scale=640:-2:force_original_aspect_ratio=decrease',
    '-c:v', 'libx264',
    '-preset', 'veryfast',
    '-pix_fmt', 'yuv420p',
    '-movflags', '+faststart',
    '-f', 'mp4',
    tmp
  ];

  await new Promise((resolve, reject) => {
    const child = spawn('ffmpeg', args, { stdio: ['ignore', 'ignore', 'pipe'] });
    let stderr = '';
    const timeout = setTimeout(() => {
      child.kill('SIGKILL');
      reject(new Error('ffmpeg preview timeout'));
    }, Number(process.env.PREVIEW_FFMPEG_TIMEOUT_MS || 8000));

    child.stderr.on('data', (chunk) => {
      stderr += chunk.toString();
      if (stderr.length > 8000) stderr = stderr.slice(-8000);
    });
    child.on('error', (error) => { clearTimeout(timeout); reject(error); });
    child.on('close', (code) => {
      clearTimeout(timeout);
      code === 0 ? resolve() : reject(new Error(stderr || `ffmpeg preview exited with code ${code}`));
    });
  });

  await fsp.rename(tmp, outputFile);
}

async function sendPreviewMp4(req, res, stream, mediaPath) {
  const match = /^(\d+)-preview\.mp4$/i.exec(mediaPath || '');
  const targetMs = match ? Number(match[1]) * 1000 : Date.now();
  const cacheDir = process.env.PREVIEW_CACHE_DIR || '/var/cache/newdomofon-video/previews';
  const cacheFile = path.join(cacheDir, `${safeName(stream)}-${match ? match[1] : 'latest'}.mp4`);

  try {
    const stat = await fsp.stat(cacheFile);
    const maxAgeMs = Number(process.env.PREVIEW_CACHE_MAX_AGE_MS || 30_000);
    if (stat.isFile() && stat.size > 0 && Date.now() - stat.mtimeMs <= maxAgeMs) {
      sendFile(req, res, cacheFile, stat, stream, {
        'content-type': 'video/mp4',
        'content-disposition': 'inline; filename="preview.mp4"',
        'x-newdomofon-preview-source': 'cache'
      });
      return;
    }
  } catch {
    // generate below
  }

  const segment = await latestSegment(stream, targetMs);
  if (!segment) {
    sendNoContent(res);
    return;
  }

  try {
    await runFfmpegPreview(segment.filePath, cacheFile);
    const stat = await fsp.stat(cacheFile);
    sendFile(req, res, cacheFile, stat, stream, {
      'content-type': 'video/mp4',
      'content-disposition': 'inline; filename="preview.mp4"',
      'x-newdomofon-preview-source': 'generated',
      'x-newdomofon-preview-segment': segment.relative
    });
  } catch (error) {
    console.warn('[dvr-archive-proxy] preview generation failed', {
      stream,
      mediaPath,
      error: String(error && error.message || error)
    });
    sendNoContent(res);
  }
}

async function sendArchiveMp4(req, res, stream, mediaPath, window) {
  const segments = await scanSegments(stream, window.startMs, window.endMs);

  if (!segments.length) {
    sendJson(res, 404, {
      error: 'No archive segments in selected range',
      stream_name: stream,
      start: iso(window.startMs),
      end: iso(window.endMs),
      source: window.source
    }, { 'x-newdomofon-resolved-stream': stream });
    return;
  }

  const tmpDir = await fsp.mkdtemp(path.join(os.tmpdir(), 'nd-archive-export-'));
  const outFile = path.join(tmpDir, `${safeName(stream)}-${Date.now()}.mp4`);

  try {
    await ffmpegConcat(segments.map((s) => s.filePath), outFile);
    const stat = await fsp.stat(outFile);

    sendFile(req, res, outFile, stat, stream, {
      'content-type': 'video/mp4',
      'content-disposition': `attachment; filename="${safeName(stream)}-${safeName(iso(window.startMs))}-${safeName(iso(window.endMs))}.mp4"`
    });

    const cleanup = () => fsp.rm(tmpDir, { recursive: true, force: true }).catch(() => {});
    res.on('finish', cleanup);
    res.on('close', cleanup);
  } catch (error) {
    await fsp.rm(tmpDir, { recursive: true, force: true }).catch(() => {});
    sendJson(res, 500, {
      error: 'Export failed',
      message: String(error && error.message || error),
      stream_name: stream
    }, { 'x-newdomofon-resolved-stream': stream });
  }
}


function mergeSegmentsToRangesV92(segments) {
  const sorted = Array.isArray(segments) ? segments.slice().sort((a, b) => a.ms - b.ms) : [];
  const ranges = [];
  const toleranceMs = Number(process.env.ARCHIVE_COVERAGE_GAP_TOLERANCE_MS || 12000);

  for (let i = 0; i < sorted.length; i += 1) {
    const current = sorted[i];
    const next = sorted[i + 1];
    const durationMs = Math.max(1000, Math.min(30000, segmentDuration(current, next) * 1000));
    const start = current.ms;
    const end = current.ms + durationMs;

    if (!ranges.length || start > ranges[ranges.length - 1].end + toleranceMs) {
      ranges.push({ start, end });
    } else {
      ranges[ranges.length - 1].end = Math.max(ranges[ranges.length - 1].end, end);
    }
  }

  return ranges;
}

function gapsFromRangesV92(ranges) {
  const gaps = [];
  const minGapMs = Number(process.env.ARCHIVE_COVERAGE_MIN_GAP_MS || 12000);
  for (let i = 0; i < ranges.length - 1; i += 1) {
    const a = ranges[i];
    const b = ranges[i + 1];
    if (b.start - a.end >= minGapMs) gaps.push({ start: a.end, end: b.start });
  }
  return gaps;
}

async function archiveCoverageV92(stream, res) {
  const segments = await scanSegments(stream, 0, Number.MAX_SAFE_INTEGER);
  const ranges = mergeSegmentsToRangesV92(segments);
  const gaps = gapsFromRangesV92(ranges);
  const first = segments[0] || null;
  const last = segments[segments.length - 1] || null;

  sendJson(res, 200, {
    stream,
    name: stream,
    dvr: true,
    recording: Boolean(last),
    from: first ? Math.floor(first.ms / 1000) : null,
    to: last ? Math.floor(last.ms / 1000) : null,
    from_iso: first ? iso(first.ms) : null,
    to_iso: last ? iso(last.ms) : null,
    segments: segments.length,
    ranges: ranges.map((r) => ({ from: Math.floor(r.start / 1000), to: Math.ceil(r.end / 1000), from_iso: iso(r.start), to_iso: iso(r.end) })),
    gaps: gaps.map((g) => ({ from: Math.floor(g.start / 1000), to: Math.ceil(g.end / 1000), from_iso: iso(g.start), to_iso: iso(g.end) })),
    source: 'archive-coverage-v92'
  }, { 'x-newdomofon-resolved-stream': stream, 'x-newdomofon-archive-coverage': 'v92' });
}


const __v137DurationCache =
  globalThis.__newdomofonV137DurationCache ||
  (globalThis.__newdomofonV137DurationCache = new Map());

async function exactSegmentDurationMsV137(segment, fallbackMs) {
  if (!segment || !segment.filePath) return fallbackMs;

  const cached = __v137DurationCache.get(segment.filePath);
  if (cached && Date.now() - cached.checkedAt < 5 * 60 * 1000) {
    return cached.durationMs;
  }

  const durationMs = await new Promise((resolve) => {
    const { execFile } = require('node:child_process');
    execFile(
      process.env.FFPROBE_PATH || 'ffprobe',
      [
        '-v', 'error',
        '-show_entries', 'format=duration',
        '-of', 'default=noprint_wrappers=1:nokey=1',
        segment.filePath
      ],
      { timeout: 5000, maxBuffer: 64 * 1024 },
      (error, stdout) => {
        const seconds = Number(String(stdout || '').trim());
        if (error || !Number.isFinite(seconds) || seconds <= 0) {
          resolve(fallbackMs);
          return;
        }
        resolve(Math.max(250, Math.min(seconds * 1000, fallbackMs * 4)));
      }
    );
  });

  __v137DurationCache.set(segment.filePath, {
    durationMs,
    checkedAt: Date.now()
  });
  if (__v137DurationCache.size > 2000) {
    const firstKey = __v137DurationCache.keys().next().value;
    if (firstKey) __v137DurationCache.delete(firstKey);
  }
  return durationMs;
}

function mergeSegmentsToRangesV93(segments) {
  const sorted = Array.isArray(segments) ? segments.slice().sort((a, b) => a.ms - b.ms) : [];
  const segmentSeconds = Math.max(1, Number(
    process.env.SEGMENT_DURATION ||
    process.env.DVR_SEGMENT_DURATION ||
    4
  ));
  const nominalMs = segmentSeconds * 1000;
  const toleranceMs = Math.max(
    Number(process.env.ARCHIVE_COVERAGE_GAP_TOLERANCE_MS || 12000),
    nominalMs * 2 + 2000
  );
  const ranges = [];

  for (const current of sorted) {
    const start = current.ms;
    const end = current.ms + nominalMs;
    const previous = ranges[ranges.length - 1];

    if (!previous || start > previous.end + toleranceMs) {
      ranges.push({ start, end, lastSegment: current });
    } else {
      previous.end = Math.max(previous.end, end);
      previous.lastSegment = current;
    }
  }

  return ranges;
}

function gapsFromRangesV93(ranges) {
  const minGapMs = Number(process.env.ARCHIVE_COVERAGE_MIN_GAP_MS || 12000);
  const gaps = [];
  for (let i = 0; i < ranges.length - 1; i += 1) {
    const a = ranges[i];
    const b = ranges[i + 1];
    if (b.start - a.end >= minGapMs) gaps.push({ start: a.end, end: b.start });
  }
  return gaps;
}

async function archiveCoverageV93(stream, res) {
  const segments = await scanSegments(stream, 0, Number.MAX_SAFE_INTEGER);
  const ranges = mergeSegmentsToRangesV93(segments);
  const fallbackMs = Math.max(1000, Number(
    process.env.SEGMENT_DURATION ||
    process.env.DVR_SEGMENT_DURATION ||
    4
  ) * 1000);

  await Promise.all(ranges.map(async (range) => {
    const durationMs = await exactSegmentDurationMsV137(
      range.lastSegment,
      fallbackMs
    );
    range.end = Math.max(
      range.start + 250,
      range.lastSegment.ms + durationMs
    );
  }));

  const internalGaps = gapsFromRangesV93(ranges);

  sendJson(res, 200, archiveMetadataPayload(
    stream,
    segments,
    ranges,
    internalGaps,
    'archive-coverage-v137-exact-gaps'
  ), {
    'x-newdomofon-resolved-stream': stream,
    'x-newdomofon-archive-coverage': 'v137',
    'x-newdomofon-archive-ranges': String(ranges.length),
    'x-newdomofon-archive-gaps': String(internalGaps.length)
  });
}

async function recordingStatus(stream, res) {
  // v137-exact-gaps-events-safety
  // v133-camera-restart-exact-segment-end
  const segments = await scanSegments(stream, 0, Number.MAX_SAFE_INTEGER);
  const first = segments[0];
  const last = segments[segments.length - 1];

  const segmentSeconds = Number(
    process.env.SEGMENT_DURATION ||
    process.env.DVR_SEGMENT_DURATION ||
    4
  );
  const gapSeconds = Math.max(
    Number(process.env.DVR_RANGE_GAP_SECONDS || 12),
    segmentSeconds * 2 + 2
  );
  const gapMs = gapSeconds * 1000;

  const rangesRaw = [];
  for (const segment of segments) {
    const segStart = segment.ms;
    const provisionalEnd =
      segment.ms + Math.max(1, segmentSeconds) * 1000;
    const range = rangesRaw[rangesRaw.length - 1];

    if (!range || segStart > range.provisionalEndMs + gapMs) {
      rangesRaw.push({
        startMs: segStart,
        provisionalEndMs: provisionalEnd,
        endMs: provisionalEnd,
        segments: 1,
        lastSegment: segment
      });
    } else {
      range.provisionalEndMs = Math.max(
        range.provisionalEndMs,
        provisionalEnd
      );
      range.endMs = range.provisionalEndMs;
      range.segments += 1;
      range.lastSegment = segment;
    }
  }

  const durationCache =
    globalThis.__newdomofonSegmentDurationCache ||
    (globalThis.__newdomofonSegmentDurationCache = new Map());

  async function exactDurationMs(segment) {
    const fallbackMs = Math.max(1, segmentSeconds) * 1000;
    if (!segment || !segment.filePath) return fallbackMs;

    const cached = durationCache.get(segment.filePath);
    if (cached && Date.now() - cached.checkedAt < 5 * 60 * 1000) {
      return cached.durationMs;
    }

    const durationMs = await new Promise((resolve) => {
      const { execFile } = require('child_process');
      execFile(
        process.env.FFPROBE_PATH || 'ffprobe',
        [
          '-v', 'error',
          '-show_entries', 'format=duration',
          '-of', 'default=noprint_wrappers=1:nokey=1',
          segment.filePath
        ],
        { timeout: 5000, maxBuffer: 64 * 1024 },
        (error, stdout) => {
          const seconds = Number(String(stdout || '').trim());
          if (error || !Number.isFinite(seconds) || seconds <= 0) {
            resolve(fallbackMs);
            return;
          }
          resolve(Math.max(250, Math.min(seconds * 1000, fallbackMs * 4)));
        }
      );
    });

    durationCache.set(segment.filePath, {
      durationMs,
      checkedAt: Date.now()
    });
    if (durationCache.size > 2000) {
      const firstKey = durationCache.keys().next().value;
      if (firstKey) durationCache.delete(firstKey);
    }
    return durationMs;
  }

  await Promise.all(
    rangesRaw.map(async (range) => {
      const durationMs = await exactDurationMs(range.lastSegment);
      range.endMs = Math.max(
        range.startMs + 250,
        range.lastSegment.ms + durationMs
      );
    })
  );

  const ranges = rangesRaw.map((range) => ({
    from: Math.floor(range.startMs / 1000),
    duration: Math.max(
      1,
      Math.ceil((range.endMs - range.startMs) / 1000)
    ),
    start: Math.floor(range.startMs / 1000),
    end: Math.ceil(range.endMs / 1000),
    startMs: Math.floor(range.startMs),
    endMs: Math.ceil(range.endMs),
    from_iso: iso(range.startMs),
    to_iso: iso(range.endMs),
    start_iso: iso(range.startMs),
    end_iso: iso(range.endMs),
    segments: range.segments
  }));

  const gaps = [];
  for (let i = 0; i < ranges.length - 1; i += 1) {
    const current = ranges[i];
    const next = ranges[i + 1];
    if (next.startMs > current.endMs) {
      gaps.push({
        from: Math.floor(current.endMs / 1000),
        to: Math.ceil(next.startMs / 1000),
        duration: Math.max(1, Math.ceil((next.startMs - current.endMs) / 1000)),
        start: Math.floor(current.endMs / 1000),
        end: Math.ceil(next.startMs / 1000),
        startMs: current.endMs,
        endMs: next.startMs,
        from_iso: iso(current.endMs),
        to_iso: iso(next.startMs),
        start_iso: iso(current.endMs),
        end_iso: iso(next.startMs)
      });
    }
  }

  sendJson(res, 200, {
    stream,
    name: stream,
    dvr: true,
    recording: Boolean(last),
    from: first ? Math.floor(first.ms / 1000) : null,
    to: ranges.length ? ranges[ranges.length - 1].end : null,
    from_iso: first ? iso(first.ms) : null,
    to_iso: ranges.length ? ranges[ranges.length - 1].to_iso : null,
    segments: segments.length,
    ranges,
    recordings: ranges,
    items: ranges,
    streams: [{ stream, name: stream, ranges }],
    gaps,
    range_gap_seconds: gapSeconds,
    exact_range_end: true,
    version: 'v137-exact-gaps-events-safety'
  }, { 'x-newdomofon-resolved-stream': stream });
}

async function handle(req, res) {
  try {
    const url = new URL(req.url || '/', 'http://127.0.0.1');

    if (req.method === 'OPTIONS') {
      sendNoContent(res);
      return;
    }

    if (url.pathname === '/health') {
      sendJson(res, 200, {
        ok: true,
        service: 'newdomofon-dvr-archive-proxy',
        version: 'v137-exact-gaps-events-safety',
        dvr_roots: DVR_ROOTS,
        camera_map: CAMERA_STREAM_MAP,
        aliases: aliasMap(),
        accepted_tokens_count: acceptedTokens().length,
        filename_tz_offset_minutes: DVR_FILENAME_TZ_OFFSET_MINUTES
      });
      return;
    }

    let rest = url.pathname;
    if (rest.startsWith('/dvr-archive/')) rest = rest.slice('/dvr-archive/'.length);
    else if (rest.startsWith('/api/dvr-archive/')) rest = rest.slice('/api/dvr-archive/'.length);
    else if (rest.startsWith('/')) rest = rest.slice(1);

    const parts = rest.split('/').filter(Boolean);
    const rawStream = parts.shift() || '';
    const mediaPath = parts.join('/');
    const stream = resolveStream(rawStream);

    if (badStream(stream)) {
      sendJson(res, 400, { error: 'Invalid stream_name', stream_name: rawStream });
      return;
    }

    const token = extractToken(req, url);
    if (!isAcceptedToken(token)) {
      sendJson(res, 401, {
        error: 'Invalid archive token',
        accepted_count: acceptedTokens().length,
        actual_prefix: token.slice(0, 8)
      }, { 'x-newdomofon-resolved-stream': stream });
      return;
    }

    if (!mediaPath) {
      sendJson(res, 400, { error: 'Missing archive path' }, { 'x-newdomofon-resolved-stream': stream });
      return;
    }

    if (mediaPath === 'coverage.json' || mediaPath === 'ranges.json') {
      await archiveCoverageV93(stream, res);
      return;
    }

    if (mediaPath === 'recording_status.json') {
      await recordingStatus(stream, res);
      return;
    }

    if (mediaPath === 'preview.mp4' || /^\d+-preview\.mp4$/i.test(mediaPath)) {
      await sendPreviewMp4(req, res, stream, mediaPath);
      return;
    }

    const isPlaylist =
      mediaPath === 'archive.m3u8' ||
      /^(archive|index|video|mono)-\d+-(now|\d+)\.m3u8$/i.test(mediaPath) ||
      /^timeshift_rel-\d+\.m3u8$/i.test(mediaPath) ||
      /^timeshift_abs-\d+\.m3u8$/i.test(mediaPath);

    if (isPlaylist) {
      let win = parseWindow(mediaPath, url);

      if (!win) {
        const now = Date.now();
        win = { startMs: now - 3600_000, endMs: now, source: 'default-last-hour' };
      }

      const segments = await scanSegments(stream, win.startMs, win.endMs);

      if (!segments.length) {
        sendJson(res, 404, {
          error: 'No archive segments in selected range',
          stream_name: stream,
          start: iso(win.startMs),
          end: iso(win.endMs),
          source: win.source
        }, { 'x-newdomofon-resolved-stream': stream });
        return;
      }

      sendText(res, 200, playlist(segments, publicToken(token)), 'application/vnd.apple.mpegurl; charset=utf-8', {
        'x-newdomofon-resolved-stream': stream
      });
      return;
    }

    const isMp4Export =
      mediaPath === 'export.mp4' ||
      /^(archive|index|video|mono)-\d+-(now|\d+)\.mp4$/i.test(mediaPath);

    if (isMp4Export) {
      const win = parseWindow(mediaPath, url);

      if (!win) {
        sendJson(res, 400, {
          error: 'Missing archive window',
          supported: [
            'export.mp4?start=<iso>&end=<iso>',
            'archive-<unix>-<duration>.mp4'
          ]
        }, { 'x-newdomofon-resolved-stream': stream });
        return;
      }

      await sendArchiveMp4(req, res, stream, mediaPath, win);
      return;
    }

    const found = await findSegment(stream, mediaPath);
    if (found) {
      sendFile(req, res, found.filePath, found.stat, stream);
      return;
    }

    sendJson(res, 404, {
      error: 'Archive media not found',
      stream_name: stream,
      path: mediaPath
    }, { 'x-newdomofon-resolved-stream': stream });
  } catch (error) {
    console.error('[dvr-archive-proxy] error', error);
    sendJson(res, 502, {
      error: 'archive proxy error',
      message: String(error && error.message || error)
    });
  }
}

http.createServer((req, res) => {
  void handle(req, res);
}).listen(PORT, HOST, () => {
  console.log('[dvr-archive-proxy] listening', {
    host: HOST,
    port: PORT,
    roots: DVR_ROOTS,
    camera_map: CAMERA_STREAM_MAP,
    aliases_file: STREAM_ALIASES_FILE,
    version: 'v135-player-kit-stable'
  });
});
