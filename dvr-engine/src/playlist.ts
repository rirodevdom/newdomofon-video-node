import { config } from './config.js';
import type { SegmentInfo } from './types.js';

function segmentDurations(segments: SegmentInfo[]) {
  const fallback = Math.max(1, config.segmentDuration);
  const maxContinuousGapSeconds = Math.max(fallback * 4, 30);

  return segments.map((segment, index) => {
    const next = segments[index + 1];
    if (!next) return fallback;

    const deltaSeconds = (next.timestamp.getTime() - segment.timestamp.getTime()) / 1000;
    if (!Number.isFinite(deltaSeconds) || deltaSeconds <= 0 || deltaSeconds > maxContinuousGapSeconds) {
      return fallback;
    }
    return Math.max(0.2, deltaSeconds);
  });
}

export function buildArchivePlaylist(segments: SegmentInfo[]): string {
  const durations = segmentDurations(segments);
  const targetDuration = Math.max(
    Math.ceil(config.segmentDuration + 1),
    Math.ceil(Math.max(...durations, config.segmentDuration))
  );
  const lines = [
    '#EXTM3U',
    '#EXT-X-VERSION:3',
    `#EXT-X-TARGETDURATION:${targetDuration}`,
    '#EXT-X-MEDIA-SEQUENCE:0',
    '#EXT-X-PLAYLIST-TYPE:VOD'
  ];

  for (const [index, segment] of segments.entries()) {
    lines.push(`#EXT-X-PROGRAM-DATE-TIME:${segment.timestamp.toISOString()}`);
    lines.push(`#EXTINF:${durations[index].toFixed(3)},`);
    lines.push(segment.relativePath);
  }
  lines.push('#EXT-X-ENDLIST');
  return `${lines.join('\n')}\n`;
}
