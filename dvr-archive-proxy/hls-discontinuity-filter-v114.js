'use strict';

// NewDomofon v114 HLS discontinuity filter.
// Purpose: DVR archive playlists can contain continuous wall-clock PDT but MPEG-TS PTS resets/jumps.
// hls.js can stall on these playlists unless #EXT-X-DISCONTINUITY is inserted before the new timestamp sequence.

const fs = require('fs');
const path = require('path');
const cp = require('child_process');

const VERSION = 'v114-hls-discontinuity-filter';
const DVR_ROOT = process.env.DVR_ROOT || '/var/lib/newdomofon-video/dvr';
const CACHE_MAX = Number(process.env.ND_HLS_DISC_CACHE_MAX || 50000);
const FFPROBE_TIMEOUT_MS = Number(process.env.ND_HLS_DISC_FFPROBE_TIMEOUT_MS || 1200);
const ENABLED = process.env.ND_HLS_DISCONTINUITY_FILTER !== '0';
const DEBUG = process.env.ND_HLS_DISC_DEBUG === '1';

const metaCache = new Map();
let logCount = 0;
function log(...args) {
  if (!DEBUG && logCount > 20) return;
  logCount += 1;
  console.log('[NewDomofon hls-discontinuity-v114]', ...args);
}

function toText(body) {
  if (typeof body === 'string') return body;
  if (Buffer.isBuffer(body)) return body.toString('utf8');
  return null;
}

function streamFromUrl(reqUrl) {
  const u = String(reqUrl || '').split('?')[0];
  let m = u.match(/\/dvr-archive\/([^/]+)\//);
  if (m) return decodeURIComponent(m[1]);
  m = u.match(/^\/([^/]+)\/(?:index-\d+-\d+|archive-\d+-\d+)\.m3u8$/);
  if (m) return decodeURIComponent(m[1]);
  return null;
}

function isArchivePlaylistRequest(reqUrl) {
  const u = String(reqUrl || '').split('?')[0];
  return /\/dvr-archive\/[^/]+\/archive-\d+-\d+\.m3u8$/.test(u) ||
         /^\/[^/]+\/index-\d+-\d+\.m3u8$/.test(u) ||
         /^\/[^/]+\/archive-\d+-\d+\.m3u8$/.test(u);
}

function safeLocalTsPath(stream, uri) {
  if (!stream || !uri) return null;
  const rel = String(uri).split('?')[0].replace(/^\/+/, '');
  if (!rel || rel.includes('\0') || rel.includes('..') || !rel.endsWith('.ts')) return null;
  const base = path.resolve(DVR_ROOT, stream);
  const full = path.resolve(base, rel);
  if (!full.startsWith(base + path.sep)) return null;
  return full;
}

function cacheSet(key, value) {
  metaCache.set(key, value);
  if (metaCache.size > CACHE_MAX) {
    const first = metaCache.keys().next().value;
    if (first) metaCache.delete(first);
  }
}

function ffprobeMeta(file) {
  try {
    const st = fs.statSync(file);
    const key = file + ':' + st.size + ':' + Math.floor(st.mtimeMs);
    if (metaCache.has(key)) return metaCache.get(key);

    const out = cp.execFileSync('ffprobe', [
      '-v', 'error',
      '-select_streams', 'v:0',
      '-show_entries', 'stream=start_time,duration,codec_name,codec_type',
      '-of', 'json',
      file
    ], { encoding: 'utf8', timeout: FFPROBE_TIMEOUT_MS, maxBuffer: 128 * 1024 });

    const data = JSON.parse(out || '{}');
    const s = Array.isArray(data.streams) ? data.streams.find(x => x.codec_type === 'video') : null;
    const start = s && isFinite(Number(s.start_time)) ? Number(s.start_time) : null;
    const duration = s && isFinite(Number(s.duration)) ? Number(s.duration) : null;
    const meta = { ok: start !== null, start, duration, size: st.size, file };
    cacheSet(key, meta);
    return meta;
  } catch (e) {
    return { ok: false, error: String(e && e.message || e), file };
  }
}

function parseIsoToEpoch(s) {
  if (!s) return null;
  const t = Date.parse(s);
  return Number.isFinite(t) ? t / 1000 : null;
}

function parsePlaylist(text) {
  const lines = text.split(/\r?\n/);
  const segments = [];
  let pendingPdt = null;
  let pendingPdtLine = -1;
  let pendingExtinf = null;
  let pendingExtinfLine = -1;
  let discPending = false;
  let gapPending = false;

  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    const pdt = line.match(/^#EXT-X-PROGRAM-DATE-TIME:(.+)$/);
    if (pdt) {
      pendingPdt = parseIsoToEpoch(pdt[1].trim());
      pendingPdtLine = i;
      continue;
    }
    const extinf = line.match(/^#EXTINF:([0-9.]+)/);
    if (extinf) {
      pendingExtinf = Number(extinf[1]);
      pendingExtinfLine = i;
      continue;
    }
    if (line.startsWith('#EXT-X-DISCONTINUITY')) {
      discPending = true;
      continue;
    }
    if (line.startsWith('#EXT-X-GAP')) {
      gapPending = true;
      continue;
    }
    if (line && !line.startsWith('#') && line.includes('.ts')) {
      segments.push({
        lineIndex: i,
        uri: line.trim(),
        pdt: pendingPdt,
        pdtLine: pendingPdtLine,
        duration: Number.isFinite(pendingExtinf) ? pendingExtinf : null,
        extinfLine: pendingExtinfLine,
        alreadyDisc: discPending,
        gap: gapPending,
      });
      pendingPdt = null;
      pendingPdtLine = -1;
      pendingExtinf = null;
      pendingExtinfLine = -1;
      discPending = false;
      gapPending = false;
    }
  }
  return { lines, segments };
}

function hasDiscontinuityImmediatelyBefore(lines, insertAt) {
  for (let i = Math.max(0, insertAt - 4); i < insertAt; i++) {
    if (String(lines[i] || '').startsWith('#EXT-X-DISCONTINUITY')) return true;
  }
  return false;
}

function shouldDiscontinue(prev, cur) {
  if (!prev || !cur || !prev.meta || !cur.meta || !prev.meta.ok || !cur.meta.ok) return false;
  const actualDelta = cur.meta.start - prev.meta.start;
  const expectedDelta = (cur.pdt !== null && prev.pdt !== null)
    ? (cur.pdt - prev.pdt)
    : (Number.isFinite(prev.duration) ? prev.duration : null);

  if (actualDelta < -0.5) return { yes: true, reason: `PTS reset ${prev.meta.start.toFixed(3)} -> ${cur.meta.start.toFixed(3)}` };
  if (expectedDelta !== null && expectedDelta >= 0) {
    const diff = Math.abs(actualDelta - expectedDelta);
    const threshold = Math.max(1.5, expectedDelta * 0.75);
    if (diff > threshold) {
      return { yes: true, reason: `PTS/PDT delta mismatch actual=${actualDelta.toFixed(3)} expected=${expectedDelta.toFixed(3)}` };
    }
  }
  return false;
}

function filterPlaylist(text, reqUrl) {
  if (!ENABLED || typeof text !== 'string' || !text.includes('#EXTM3U') || !text.includes('.ts')) return text;
  if (!isArchivePlaylistRequest(reqUrl)) return text;

  const stream = streamFromUrl(reqUrl);
  if (!stream) return text;

  const parsed = parsePlaylist(text);
  const { lines, segments } = parsed;
  if (segments.length < 2) return text;

  for (const seg of segments) {
    const file = safeLocalTsPath(stream, seg.uri);
    seg.localFile = file;
    seg.meta = file ? ffprobeMeta(file) : { ok: false };
  }

  const inserts = new Map();
  let prev = null;
  const inserted = [];

  for (const cur of segments) {
    if (cur.gap) { prev = cur; continue; }
    if (prev && !cur.alreadyDisc) {
      const decision = shouldDiscontinue(prev, cur);
      if (decision && decision.yes) {
        const insertAt = cur.pdtLine >= 0 ? cur.pdtLine : (cur.extinfLine >= 0 ? cur.extinfLine : cur.lineIndex);
        if (!hasDiscontinuityImmediatelyBefore(lines, insertAt)) {
          inserts.set(insertAt, '#EXT-X-DISCONTINUITY');
          inserted.push({ before: cur.uri.split('?')[0], reason: decision.reason });
        }
      }
    }
    prev = cur;
  }

  if (!inserts.size) return text;

  const out = [];
  for (let i = 0; i < lines.length; i++) {
    if (inserts.has(i)) out.push(inserts.get(i));
    out.push(lines[i]);
  }
  log('inserted discontinuities', { url: reqUrl, stream, count: inserted.length, inserted: inserted.slice(0, 8) });
  return out.join('\n');
}

function middleware() {
  return function ndHlsDiscontinuityMiddleware(req, res, next) {
    if (!ENABLED || !isArchivePlaylistRequest(req.url)) return next();

    const oldSend = res.send ? res.send.bind(res) : null;
    const oldEnd = res.end.bind(res);
    let filteredBySend = false;

    if (oldSend) {
      res.send = function ndV114Send(body) {
        const text = toText(body);
        if (text && text.includes('#EXTM3U')) {
          filteredBySend = true;
          try {
            const filtered = filterPlaylist(text, req.url);
            res.setHeader('X-Newdomofon-HLS-Discontinuity-Filter', VERSION);
            if (Buffer.isBuffer(body)) return oldSend(Buffer.from(filtered, 'utf8'));
            return oldSend(filtered);
          } catch (e) {
            console.error('[NewDomofon hls-discontinuity-v114] filter failed:', e);
            return oldSend(body);
          }
        }
        return oldSend(body);
      };
    }

    res.end = function ndV114End(chunk, encoding, cb) {
      if (!filteredBySend) {
        const text = toText(chunk);
        if (text && text.includes('#EXTM3U')) {
          try {
            const filtered = filterPlaylist(text, req.url);
            res.setHeader('X-Newdomofon-HLS-Discontinuity-Filter', VERSION);
            return oldEnd(Buffer.from(filtered, 'utf8'), encoding, cb);
          } catch (e) {
            console.error('[NewDomofon hls-discontinuity-v114] end filter failed:', e);
          }
        }
      }
      return oldEnd(chunk, encoding, cb);
    };

    next();
  };
}

module.exports = { VERSION, middleware, filterPlaylist, parsePlaylist };
