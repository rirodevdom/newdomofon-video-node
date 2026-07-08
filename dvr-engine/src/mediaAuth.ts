import crypto from 'node:crypto';
import type { NextFunction, Request, Response } from 'express';
import { config } from './config.js';
import { getNodeMediaSecret, isNodeMode } from './nodeClient.js';


function allowPermanentNoExpMediaToken(payload: any) {
  if (!['1', 'true', 'yes', 'on'].includes(String(process.env.ACCEPT_PERMANENT_NO_EXP_MEDIA_TOKEN || '').toLowerCase())) return false;
  if (!['1', 'true', 'yes', 'on'].includes(String(process.env.PERMANENT_MEDIA_LINKS || '').toLowerCase())) return false;
  if (!payload || typeof payload !== 'object') return false;
  if (payload.exp !== undefined && payload.exp !== null) return false;
  const version = String(process.env.PERMANENT_MEDIA_LINK_VERSION || '1');
  if (String(payload.link_version || '') !== version) return false;
  return ['camera', 'live', 'archive'].includes(String(payload.scope || ''));
}
function permanentMediaLinksEnabled(): boolean {
  return ['1', 'true', 'yes', 'on'].includes(String(process.env.PERMANENT_MEDIA_LINKS || process.env.PERMANENT_CAMERA_LINKS || '').toLowerCase());
}

function permanentMediaLinkVersion(): string | null {
  const value = String(process.env.PERMANENT_MEDIA_LINK_VERSION || '').trim();
  return value || null;
}

function mediaTokenSecret(): string | null {
  return String(process.env.DVR_NODE_MEDIA_SECRET || process.env.NODE_MEDIA_SECRET || process.env.MEDIA_TOKEN_SECRET || '').trim() || null;
}

function signPermanentMediaPayload(payload: any): string | null {
  const secret = mediaTokenSecret();
  if (!secret) return null;
  const stablePayload = { ...payload };
  delete stablePayload.exp;
  delete stablePayload.iat;
  delete stablePayload.nbf;
  const version = permanentMediaLinkVersion();
  if (version) stablePayload.link_version = version;
  const body = Buffer.from(JSON.stringify(stablePayload)).toString('base64url');
  const sig = crypto.createHmac('sha256', secret).update(body).digest('base64url');
  return `${body}.${sig}`;
}

function rewritePermanentMediaToken(token: any): string | null {
  if (!permanentMediaLinksEnabled()) return null;
  const raw = String(token || '');
  const dot = raw.lastIndexOf('.');
  if (dot <= 0) return null;
  try {
    const payload = JSON.parse(Buffer.from(raw.slice(0, dot), 'base64url').toString('utf8'));
    return signPermanentMediaPayload(payload);
  } catch {
    return null;
  }
}

type Scope = 'camera' | 'live' | 'archive' | 'export' | 'file' | 'status';

const cameraScopeTargets: Scope[] = ['live', 'archive', 'file', 'status'];

function scopeAllowed(payloadScope: unknown, allowedScopes: Scope[]): boolean {
  const scope = String(payloadScope || '') as Scope;
  if (allowedScopes.includes(scope)) return true;
  if (scope === 'camera') return allowedScopes.some((allowed) => cameraScopeTargets.includes(allowed));
  return false;
}

function safeEqual(a: string, b: string): boolean {
  const ab = Buffer.from(a);
  const bb = Buffer.from(b);
  return ab.length === bb.length && crypto.timingSafeEqual(ab, bb);
}

function verifyToken(rawToken: string, streamName: string, allowedScopes: Scope[]): boolean {
  const secret = getNodeMediaSecret();
  if (!secret) return false;

  const [body, sig] = rawToken.split('.');
  if (!body || !sig) return false;

  const expected = crypto.createHmac('sha256', secret).update(body).digest('base64url');
  if (!safeEqual(sig, expected)) return false;

  let payload: any;
  try {
    payload = JSON.parse(Buffer.from(body, 'base64url').toString('utf8'));
  } catch {
    return false;
  }

  if (payload.stream_name !== streamName) return false;
  if (!scopeAllowed(payload.scope, allowedScopes)) return false;
  const exp = Number(payload.exp);
  if (Number.isFinite(exp)) {
    if (exp < Math.floor(Date.now() / 1000)) return false;
  } else if (!permanentMediaLinksEnabled()) {
    return false;
  }
  const requiredVersion = permanentMediaLinkVersion();
  if (permanentMediaLinksEnabled() && requiredVersion && String(payload.link_version || '') !== requiredVersion) return false;
  return true;
}

export function requireMediaToken(scopes: Scope[]) {
  return (req: Request, res: Response, next: NextFunction) => {
    if (!isNodeMode() && !config.requireMediaToken) return next();

    const streamName = String(req.params.streamName || '');
    const token = String(req.query.token || '').trim();
    if (!token) return res.status(401).json({ error: 'Missing media token' });
    if (!verifyToken(token, streamName, scopes)) return res.status(403).json({ error: 'Invalid media token' });
    return next();
  };
}

export function appendTokenToPlaylist(body: string, token: string): string {
  if (!token) return body;
  return body
    .split(/\r?\n/)
    .map((line) => {
      const trimmed = line.trim();
      if (!trimmed || trimmed.startsWith('#') || /[?&]token=/.test(trimmed)) return line;
      const sep = trimmed.includes('?') ? '&' : '?';
      return `${trimmed}${sep}token=${encodeURIComponent(token)}`;
    })
    .join('\n');
}

export function rewritePlaylistForNode(body: string, streamName: string, token: string): string {
  return body
    .split(/\r?\n/)
    .map((line) => {
      const trimmed = line.trim();
      if (!trimmed || trimmed.startsWith('#')) return line;
      if (trimmed.startsWith('http://') || trimmed.startsWith('https://') || trimmed.startsWith('/files/')) {
        const sep = trimmed.includes('?') ? '&' : '?';
        return /[?&]token=/.test(trimmed) || !token ? trimmed : `${trimmed}${sep}token=${encodeURIComponent(token)}`;
      }
      const clean = trimmed.replace(/^\/+/, '');
      const safe = clean.split('/').map(encodeURIComponent).join('/');
      const suffix = token ? `?token=${encodeURIComponent(token)}` : '';
      return `/files/${encodeURIComponent(streamName)}/${safe}${suffix}`;
    })
    .join('\n');
}
