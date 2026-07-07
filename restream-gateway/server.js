const net = require('node:net');

const LHOST = process.env.RESTREAM_GATEWAY_HOST || '0.0.0.0';
const LPORT = Number(process.env.RESTREAM_GATEWAY_PORT || 8445);
const HPORT = Number(process.env.RESTREAM_HTTP_GATEWAY_PORT || 18045);
const RPORT = Number(process.env.RESTREAM_RTSP_UPSTREAM_PORT || 8554);

const httpMethods = new Set(['GET','POST','PUT','PATCH','DELETE','HEAD','OPTIONS']);
const rtspMethods = new Set(['OPTIONS','DESCRIBE','ANNOUNCE','SETUP','PLAY','PAUSE','TEARDOWN','GET_PARAMETER','SET_PARAMETER','RECORD']);

function kind(chunk) {
  const first = chunk.toString('latin1', 0, Math.min(chunk.length, 512)).split(/\r?\n/, 1)[0] || '';
  const m = (first.split(/\s+/, 1)[0] || '').toUpperCase();
  if (first.includes('RTSP/1.0') || (rtspMethods.has(m) && !first.includes('HTTP/'))) return 'rtsp';
  if (first.includes('HTTP/') || httpMethods.has(m)) return 'http';
  return 'http';
}

function pipe(client, chunk, type) {
  const upstream = net.createConnection({host:'127.0.0.1', port: type === 'rtsp' ? RPORT : HPORT});
  let closed = false;
  const close = () => {
    if (closed) return;
    closed = true;
    client.destroy();
    upstream.destroy();
  };

  upstream.on('connect', () => {
    upstream.write(chunk);
    client.pipe(upstream);
    upstream.pipe(client);
  });
  upstream.on('error', e => {
    console.warn('[gateway] upstream error', {type, message:e.message});
    close();
  });
  client.on('error', close);
  client.on('close', close);
  upstream.on('close', close);
}

const server = net.createServer(client => {
  const timer = setTimeout(() => client.destroy(), 3000);
  client.once('data', chunk => {
    clearTimeout(timer);
    const type = kind(chunk);
    console.log('[gateway] route', {type, remote:`${client.remoteAddress}:${client.remotePort}`});
    pipe(client, chunk, type);
  });
  client.on('close', () => clearTimeout(timer));
  client.on('error', () => clearTimeout(timer));
});

server.on('error', e => {
  console.error('[gateway] server error', e);
  process.exit(1);
});
server.listen(LPORT, LHOST, () => {
  console.log('[gateway] listening', {listen:`${LHOST}:${LPORT}`, http:`127.0.0.1:${HPORT}`, rtsp:`127.0.0.1:${RPORT}`});
});
process.on('SIGTERM', () => server.close(() => process.exit(0)));
process.on('SIGINT', () => server.close(() => process.exit(0)));
