import crypto from 'node:crypto';
import type { CameraConfig } from './types.js';

function nonEmpty(...values: Array<string | null | undefined>): string {
  for (const value of values) {
    const normalized = String(value ?? '').trim();
    if (normalized) return normalized;
  }
  return '';
}

function storedUsername(camera: CameraConfig): string {
  return nonEmpty(camera.onvif_username, camera.device_username);
}

function storedPassword(camera: CameraConfig): string {
  return nonEmpty(camera.onvif_password, camera.device_password);
}

/**
 * Build the private FFmpeg input URL without modifying the public camera source_url.
 *
 * Many ONVIF devices return an RTSP URI without userinfo even though the same
 * credentials are required for RTSP. Master already delivers the encrypted-at-rest
 * camera/device credentials to the assigned node, so the node can merge them only
 * in memory immediately before spawning FFmpeg.
 */
export function recorderInputUrl(camera: CameraConfig): string {
  const source = String(camera.source_url || '').trim();
  if (!source) return source;

  let parsed: URL;
  try {
    parsed = new URL(source);
  } catch {
    return source;
  }

  if (parsed.protocol.toLowerCase() !== 'rtsp:') return source;

  const fallbackUsername = storedUsername(camera);
  const fallbackPassword = storedPassword(camera);
  const existingUsername = parsed.username ? decodeURIComponent(parsed.username) : '';
  const existingPassword = parsed.password ? decodeURIComponent(parsed.password) : '';

  const username = existingUsername || fallbackUsername;
  const password = existingPassword || fallbackPassword;

  if (!username && !password) return source;

  if (!parsed.username && username) parsed.username = username;
  if (!parsed.password && password) parsed.password = password;

  return parsed.toString();
}

export function recorderCredentialsInjected(camera: CameraConfig): boolean {
  return recorderInputUrl(camera) !== String(camera.source_url || '').trim();
}

export function recorderConfigFingerprint(camera: CameraConfig): string {
  return crypto
    .createHash('sha256')
    .update([
      recorderInputUrl(camera),
      camera.rtmp_push_url || '',
      camera.archive_storage || 'node'
    ].join('|'))
    .digest('hex');
}

function escapeRegExp(value: string): string {
  return value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

export function sanitizeRecorderMessage(message: string, camera: CameraConfig): string {
  let sanitized = String(message || '')
    .replace(/rtsp:\/\/[^\s/@]+(?::[^\s/@]*)?@/gi, 'rtsp://***:***@');

  for (const secret of [camera.onvif_password, camera.device_password]) {
    const value = String(secret ?? '');
    if (!value) continue;
    sanitized = sanitized.replace(new RegExp(escapeRegExp(value), 'g'), '***');
  }

  return sanitized.slice(-4000);
}
