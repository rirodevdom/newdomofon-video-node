import type { LocalCameraEvent } from './localEventStore.js';

export type LocalCameraEventWithInterval = LocalCameraEvent & {
  start_at?: string;
  end_at?: string;
  duration_ms?: number;
};

function stateKind(value: string | null): boolean | null {
  if (value === null) return null;
  const normalized = String(value).trim().toLowerCase();
  if (['1', 'true', 'yes', 'on', 'active', 'start', 'started', 'detected'].includes(normalized)) return true;
  if (['0', 'false', 'no', 'off', 'inactive', 'idle', 'clear', 'stop', 'end', 'ended'].includes(normalized)) return false;
  return null;
}

function intervalKey(event: LocalCameraEvent): string {
  return [
    String(event.event_type || '').toLowerCase(),
    event.source_name || '',
    event.topic || ''
  ].join('|');
}

export function attachEventIntervals(items: LocalCameraEvent[]): LocalCameraEventWithInterval[] {
  const output: LocalCameraEventWithInterval[] = items.map((event) => ({
    ...event,
    data: event.data && typeof event.data === 'object' ? { ...event.data } : {}
  }));
  const active = new Map<string, LocalCameraEventWithInterval>();

  for (const event of output) {
    const state = stateKind(event.event_state);
    if (state === null) continue;

    const key = intervalKey(event);
    if (state) {
      if (!active.has(key)) active.set(key, event);
      continue;
    }

    const start = active.get(key);
    if (!start) continue;
    active.delete(key);

    const startMs = Date.parse(start.occurred_at);
    const endMs = Date.parse(event.occurred_at);
    if (!Number.isFinite(startMs) || !Number.isFinite(endMs) || endMs <= startMs) continue;

    start.start_at = start.occurred_at;
    start.end_at = event.occurred_at;
    start.duration_ms = endMs - startMs;
    start.data = {
      ...start.data,
      interval: {
        complete: true,
        start_at: start.occurred_at,
        end_at: event.occurred_at,
        duration_ms: endMs - startMs,
        start_event_id: start.id,
        end_event_id: event.id
      }
    };
  }

  return output;
}
