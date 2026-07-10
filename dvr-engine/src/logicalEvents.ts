import type { LocalCameraEvent } from './localEventStore.js';

export type LogicalEventOptions = {
  includeInactive?: boolean;
  dedupMs?: number;
};

function activeState(value: unknown): boolean {
  return ['1', 'true', 'on', 'active', 'start', 'started'].includes(
    String(value ?? '').trim().toLowerCase()
  );
}

function logicalKey(event: LocalCameraEvent): string {
  const type = String(event.event_type || 'unknown').toLowerCase();
  if (type === 'motion') return 'motion';
  return [type, event.source_name || '', event.topic || ''].join('|');
}

/**
 * Convert raw ONVIF/Hikvision transitions into user-facing timeline points.
 *
 * Raw storage is intentionally preserved. Logical mode:
 * - hides inactive/end transitions by default;
 * - merges equivalent ONVIF motion topics emitted at the same moment;
 * - suppresses repeated copies inside a small configurable window.
 */
export function toLogicalEvents(
  rawItems: LocalCameraEvent[],
  options: LogicalEventOptions = {}
): LocalCameraEvent[] {
  const includeInactive = options.includeInactive === true;
  const dedupMs = Math.max(100, Math.min(10_000, Math.trunc(options.dedupMs ?? 2000)));
  const lastByKey = new Map<string, number>();
  const items: LocalCameraEvent[] = [];

  for (const event of rawItems) {
    const timestamp = Date.parse(event.occurred_at);
    if (!Number.isFinite(timestamp)) continue;

    if (!includeInactive && event.event_state !== null && !activeState(event.event_state)) {
      continue;
    }

    const key = logicalKey(event);
    const previous = lastByKey.get(key);
    if (previous !== undefined && timestamp - previous <= dedupMs) continue;
    lastByKey.set(key, timestamp);

    items.push(event);
  }

  return items;
}
