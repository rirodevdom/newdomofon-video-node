
// v27-restreamer-global-token-start
function restreamPublicToken() {
  return String(process.env.RESTREAM_PUBLIC_TOKEN || 'ваш_токен');
}
// v27-restreamer-global-token-end

const http = require('http');
const { spawn } = require('child_process');
const { URL } = require('url');
const { Client } = require('pg');

const DATABASE_URL = process.env.DATABASE_URL;
const PORT = Number(process.env.RESTREAM_PORT || 3020);
const PUBLIC_HOST = process.env.PUBLIC_HOST || process.env.RESTREAM_PUBLIC_HOST || '';
const RTSP_BASE = process.env.RESTREAM_MEDIAMTX_RTSP_BASE || 'rtsp://127.0.0.1:8554';
const HLS_PORT = Number(process.env.RESTREAM_HLS_PORT || 8888);
const WEBRTC_PORT = Number(process.env.RESTREAM_WEBRTC_PORT || 8889);
const RTSP_PORT = Number(process.env.RESTREAM_RTSP_PORT || 8554);
const TRANSCODE_H264 = String(process.env.RESTREAM_TRANSCODE_H264 || '0') === '1';
const MJPEG_FPS = Number(process.env.RESTREAM_MJPEG_FPS || 5);
const MJPEG_WIDTH = Number(process.env.RESTREAM_MJPEG_WIDTH || 640);
const SYNC_MS = Number(process.env.RESTREAM_SYNC_INTERVAL_MS || 15000);

const publishers = new Map();
let cameras = [];

function safe(v) {
  return String(v || '').trim().replace(/[^a-zA-Z0-9_.-]/g, '_').slice(0, 120);
}

function sendJson(res, status, body) {
  const data = Buffer.from(JSON.stringify(body, null, 2));
  res.writeHead(status, {'content-type':'application/json; charset=utf-8','content-length':data.length,'cache-control':'no-store'});
  res.end(data);
}

function host(req) {
  const h = req.headers['x-forwarded-host'] || req.headers.host || PUBLIC_HOST || '127.0.0.1';
  return String(Array.isArray(h) ? h[0] : h).split(':')[0];
}


function publicWebOrigin(req) {
  const forced = process.env.RESTREAM_WEB_ORIGIN || '';
  if (forced) return forced.replace(/\/$/, '');

  const proto = String(req.headers['x-forwarded-proto'] || '').split(',')[0] || 'http';
  const h = host(req);
  return `${proto}://${h}`;
}

function urls(req, stream) {
  const base = typeof publicWebOrigin === 'function'
    ? publicWebOrigin(req)
    : `${String(req.headers['x-forwarded-proto'] || 'http').split(',')[0]}://${host(req)}`;

  const token = encodeURIComponent(restreamPublicToken());

  return {
    stream_name: stream,
    webrtc_embed: `${base}/${stream}/embed.html?proto=webrtc&token=${token}`,
    hls_m3u8: `${base}/${stream}/index.m3u8?token=${token}`,
    hls_video_m3u8: `${base}/${stream}/video.m3u8?token=${token}`,
    rtsp: `rtsp://${host(req)}:${process.env.RESTREAM_RTSP_PUBLIC_PORT || 554}/${stream}`,
    hls_page: `${base}/${stream}/index.m3u8?token=${token}`,
    hls_video_page: `${base}/${stream}/video.m3u8?token=${token}`,
    webrtc_page: `${base}/${stream}/embed.html?proto=webrtc&token=${token}`,
    whep: `${base}/whep/${stream}`,
    mjpeg: `${base}/mjpeg/${stream}`
  };
}

async function loadCameras() {
  const client = new Client({connectionString: DATABASE_URL});
  await client.connect();
  try {
    const cols = new Set((await client.query(`
      SELECT column_name FROM information_schema.columns
      WHERE table_schema='public' AND table_name='cameras'
    `)).rows.map(r => r.column_name));

    const where = cols.has('is_enabled') ? 'WHERE is_enabled = true' : '';
    const rows = (await client.query(`SELECT * FROM public.cameras ${where} ORDER BY created_at NULLS LAST, id`)).rows;

    const sourceCols = ['rtsp_url','source_url','source','stream_url','url','onvif_rtsp_uri','rtsp','input_url','camera_url'].filter(c => cols.has(c));
    const nameCols = ['stream_name','slug','code','name'].filter(c => cols.has(c));

    return rows.map(row => {
      const src = sourceCols.map(c => row[c]).find(v => typeof v === 'string' && v.trim());
      const nm = nameCols.map(c => row[c]).find(v => typeof v === 'string' && v.trim()) || row.id;
      return { id: String(row.id), name: row.name || nm, stream_name: safe(nm), source_url: src ? String(src).trim() : '' };
    }).filter(c => c.stream_name && c.source_url);
  } finally {
    await client.end();
  }
}

function argsFor(cam) {
  const out = `${RTSP_BASE.replace(/\/+$/, '')}/${encodeURIComponent(cam.stream_name)}`;
  const args = ['-hide_banner','-loglevel','warning','-nostdin','-rtsp_transport','tcp','-i',cam.source_url,'-map','0:v:0','-map','0:a?'];

  if (TRANSCODE_H264) {
    args.push('-c:v','libx264','-preset','veryfast','-tune','zerolatency','-profile:v','baseline','-pix_fmt','yuv420p','-g','50','-bf','0');
  } else {
    args.push('-c:v','copy');
  }

  args.push('-c:a','aac','-b:a','96k','-ac','1','-ar','48000','-f','rtsp','-rtsp_transport','tcp',out);
  return args;
}

function stop(stream) {
  const st = publishers.get(stream);
  if (!st) return;
  st.stopping = true;
  if (st.timer) clearTimeout(st.timer);
  try { st.child.kill('SIGTERM'); setTimeout(() => { try { st.child.kill('SIGKILL'); } catch {} }, 5000); } catch {}
  publishers.delete(stream);
}

function start(cam) {
  const old = publishers.get(cam.stream_name);
  if (old && old.source_url === cam.source_url && old.child && !old.child.killed) return;
  stop(cam.stream_name);

  console.log('[restream] start', {stream_name: cam.stream_name, source_url: cam.source_url, transcode_h264: TRANSCODE_H264});
  const child = spawn('ffmpeg', argsFor(cam), {stdio:['ignore','ignore','pipe']});
  const st = {child, camera:cam, source_url:cam.source_url, stopping:false, timer:null, last_error:''};

  child.stderr.on('data', b => {
    const text = String(b).trim();
    if (text) { st.last_error = text.slice(-1000); console.warn(`[ffmpeg:${cam.stream_name}] ${text}`); }
  });

  child.on('exit', (code, signal) => {
    console.warn('[restream] exited', {stream_name:cam.stream_name, code, signal, stopping:st.stopping});
    if (!st.stopping) st.timer = setTimeout(() => {
      if (publishers.get(cam.stream_name) === st) start(cam);
    }, 5000);
  });

  publishers.set(cam.stream_name, st);
}

async function sync() {
  try {
    cameras = await loadCameras();
    const wanted = new Set(cameras.map(c => c.stream_name));
    for (const cam of cameras) start(cam);
    for (const stream of [...publishers.keys()]) if (!wanted.has(stream)) stop(stream);
    console.log('[restream] sync', {cameras:cameras.length, publishers:publishers.size});
  } catch (e) {
    console.error('[restream] sync failed', e);
  }
}

function mjpeg(req, res, streamName) {
  const stream = safe(streamName);
  if (!cameras.find(c => c.stream_name === stream)) return sendJson(res, 404, {error:'stream not found', stream_name: stream});

  const input = `${RTSP_BASE.replace(/\/+$/, '')}/${encodeURIComponent(stream)}`;
  const args = ['-hide_banner','-loglevel','error','-nostdin','-rtsp_transport','tcp','-i',input,'-an','-vf',`fps=${MJPEG_FPS},scale=${MJPEG_WIDTH}:-1`,'-q:v','5','-f','mpjpeg','-boundary_tag','mjpegstream','pipe:1'];

  res.writeHead(200, {'content-type':'multipart/x-mixed-replace; boundary=mjpegstream','cache-control':'no-store','connection':'close'});
  const child = spawn('ffmpeg', args, {stdio:['ignore','pipe','pipe']});
  child.stdout.pipe(res);
  child.stderr.on('data', b => { const t = String(b).trim(); if (t) console.warn(`[mjpeg:${stream}] ${t}`); });

  const kill = () => { try { child.kill('SIGTERM'); setTimeout(() => { try { child.kill('SIGKILL'); } catch {} }, 3000); } catch {} };
  req.on('close', kill);
  res.on('close', kill);
  child.on('exit', () => { try { res.end(); } catch {} });
}

const server = http.createServer(async (req, res) => {
  try {
    const u = new URL(req.url || '/', `http://${req.headers.host || 'localhost'}`);
    const p = u.pathname.split('/').filter(Boolean);

    if (u.pathname === '/health') return sendJson(res, 200, {ok:true, service:'newdomofon-restreamer', cameras:cameras.length, publishers:publishers.size});
    if (u.pathname === '/streams') return sendJson(res, 200, {items:cameras.map(c => ({id:c.id, name:c.name, stream_name:c.stream_name, publisher_active:publishers.has(c.stream_name), urls:urls(req, c.stream_name)}))});
    if (p.length === 3 && p[0] === 'streams' && p[2] === 'urls') {
      const stream = safe(decodeURIComponent(p[1]));
      if (!cameras.find(c => c.stream_name === stream)) return sendJson(res, 404, {error:'stream not found', stream_name:stream});
      return sendJson(res, 200, urls(req, stream));
    }
    if (p.length === 3 && p[0] === 'streams' && p[2] === 'mjpeg') return mjpeg(req, res, decodeURIComponent(p[1]));

    return sendJson(res, 404, {error:'not found', routes:['/health','/streams','/streams/:streamName/urls','/streams/:streamName/mjpeg']});
  } catch (e) {
    console.error('[http] failed', e);
    return sendJson(res, 500, {error: e.message || String(e)});
  }
});

function shutdown() {
  for (const stream of [...publishers.keys()]) stop(stream);
  server.close(() => process.exit(0));
}

process.on('SIGTERM', shutdown);
process.on('SIGINT', shutdown);

server.listen(PORT, '0.0.0.0', async () => {
  console.log('[restream] listening', {port:PORT, public_host:PUBLIC_HOST, rtsp_base:RTSP_BASE, transcode_h264:TRANSCODE_H264});
  await sync();
  setInterval(sync, SYNC_MS);
});
