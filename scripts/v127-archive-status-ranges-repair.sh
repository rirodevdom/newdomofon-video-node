#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="${PROJECT_DIR:-/opt/newdomofon-video}"
SITE_URL="${SITE_URL:-https://new-video.domofon-37.ru}"
STREAM_NAME="${STREAM_NAME:-cam_10_130_1_219}"
TOKEN="${TOKEN:-}"
APPLY="${APPLY:-0}"
APPLY_OFFSET="${APPLY_OFFSET:-0}"
RANGE_GAP_SECONDS="${RANGE_GAP_SECONDS:-12}"
BACKUP_DIR="$PROJECT_DIR/backups/v127-archive-status-ranges-repair-$(date +%Y%m%d-%H%M%S)"

ARCHIVE_PROXY="$PROJECT_DIR/dvr-archive-proxy/server.js"
APP_ENV="/etc/newdomofon-video/app.env"

echo "===== v127 archive status/ranges repair ====="
echo "project:           $PROJECT_DIR"
echo "site:              $SITE_URL"
echo "stream:            $STREAM_NAME"
echo "apply:             $APPLY"
echo "apply_offset:      $APPLY_OFFSET"
echo "range_gap_seconds: $RANGE_GAP_SECONDS"
echo "backup:            $BACKUP_DIR"

test -d "$PROJECT_DIR"
test -f "$ARCHIVE_PROXY"

mkdir -p "$BACKUP_DIR"

echo
echo "===== Load env ====="
set +u
for envf in "$APP_ENV" "$PROJECT_DIR/backend/.env" "$PROJECT_DIR/.env"; do
  if [ -f "$envf" ]; then
    echo "load: $envf"
    set -a
    . "$envf"
    set +a
  fi
done
set -u

DVR_ROOTS="${DVR_ROOTS:-${DVR_ROOT:-/var/lib/newdomofon-video/dvr,/var/dvr}}"
CURRENT_OFFSET="${DVR_FILENAME_TZ_OFFSET_MINUTES:-180}"

echo "dvr_roots:      $DVR_ROOTS"
echo "current_offset: $CURRENT_OFFSET"

echo
echo "===== Backup ====="
for f in \
  "$ARCHIVE_PROXY" \
  "$APP_ENV" \
  /etc/systemd/system/newdomofon-dvr-archive-proxy.service \
  /etc/systemd/system/newdomofon-smartyard-compat.service
do
  if [ -f "$f" ]; then
    mkdir -p "$BACKUP_DIR$(dirname "$f")"
    cp -a "$f" "$BACKUP_DIR$f"
    echo "backup: $f"
  fi
done

echo
echo "===== Current HTTP status ====="
TOKEN_Q=""
if [ -n "$TOKEN" ]; then TOKEN_Q="?token=$TOKEN"; fi

for url in \
  "$SITE_URL/dvr-archive/$STREAM_NAME/recording_status.json$TOKEN_Q" \
  "$SITE_URL/$STREAM_NAME/recording_status.json$TOKEN_Q"
do
  echo "--- $url"
  curl -k -sS --max-time 20 "$url" | tee "$BACKUP_DIR/$(echo "$url" | sed 's#[^A-Za-z0-9_.-]#_#g').json" | jq '{stream, name, recording, from, to, from_iso, to_iso, segments, ranges_count: (.ranges|length?)}' 2>/dev/null || true
  echo
done

echo
echo "===== Local segment diagnostics ====="
CURRENT_OFFSET="$CURRENT_OFFSET" DVR_ROOTS="$DVR_ROOTS" STREAM_NAME="$STREAM_NAME" RANGE_GAP_SECONDS="$RANGE_GAP_SECONDS" node <<'NODE' | tee "$BACKUP_DIR/archive-local-diagnostics.json"
const fs = require('fs');
const path = require('path');

const stream = process.env.STREAM_NAME || 'cam_10_130_1_219';
const roots = String(process.env.DVR_ROOTS || process.env.DVR_ROOT || '/var/lib/newdomofon-video/dvr,/var/dvr')
  .split(',')
  .map(s => s.trim())
  .filter(Boolean);
const currentOffset = Number(process.env.CURRENT_OFFSET || process.env.DVR_FILENAME_TZ_OFFSET_MINUTES || 180);
const gapSeconds = Number(process.env.RANGE_GAP_SECONDS || 12);

function parseLocalMs(filePath, offsetMinutes) {
  const base = path.basename(filePath);
  const m = /^(\d{4})(\d{2})(\d{2})_(\d{2})(\d{2})(\d{2})\.(ts|m4s|mp4)$/i.exec(base);
  if (!m) return NaN;
  const utcAssumingNameIsUtc = Date.UTC(+m[1], +m[2] - 1, +m[3], +m[4], +m[5], +m[6]);
  return utcAssumingNameIsUtc - offsetMinutes * 60 * 1000;
}

function walk(root, dir, out = []) {
  let entries;
  try { entries = fs.readdirSync(dir, { withFileTypes: true }); } catch { return out; }
  for (const e of entries) {
    const p = path.join(dir, e.name);
    if (e.isDirectory()) walk(root, p, out);
    else if (e.isFile() && /\.(ts|m4s|mp4)$/i.test(e.name)) {
      const ms = parseLocalMs(p, currentOffset);
      if (Number.isFinite(ms)) {
        let st = null;
        try { st = fs.statSync(p); } catch {}
        out.push({ path: p, relative: path.relative(root, p).split(path.sep).join('/'), name: e.name, ms, mtimeMs: st?.mtimeMs || null, size: st?.size || null });
      }
    }
  }
  return out;
}

let files = [];
for (const root of roots) {
  const streamRoot = path.join(root, stream);
  files.push(...walk(streamRoot, streamRoot).map(x => ({...x, root, streamRoot})));
}
files.sort((a,b) => a.ms - b.ms || a.path.localeCompare(b.path));

function iso(ms) { return Number.isFinite(ms) ? new Date(ms).toISOString() : null; }

function rangesFor(offset) {
  const arr = files.map(f => ({...f, ms: parseLocalMs(f.path, offset)})).filter(f => Number.isFinite(f.ms)).sort((a,b) => a.ms-b.ms);
  const ranges = [];
  const gapMs = Math.max(1000, gapSeconds * 1000);
  for (const f of arr) {
    const endMs = f.ms + 4000;
    const last = ranges[ranges.length - 1];
    if (!last || f.ms > last.endMs + gapMs) {
      ranges.push({ startMs: f.ms, endMs, segments: 1, first: f.path, last: f.path });
    } else {
      last.endMs = Math.max(last.endMs, endMs);
      last.segments += 1;
      last.last = f.path;
    }
  }
  return ranges;
}

const newest = files[files.length - 1] || null;
const offsets = [-180, 0, 60, 120, 180, 240, 300];
const offsetScores = offsets.map(offset => {
  if (!newest || !newest.mtimeMs) return { offset, diffToNewestMtimeSec: null };
  const parsed = parseLocalMs(newest.path, offset);
  return {
    offset,
    parsed_iso: iso(parsed),
    diffToNewestMtimeSec: Number.isFinite(parsed) ? Math.round(Math.abs(parsed - newest.mtimeMs) / 1000) : null
  };
}).sort((a,b) => (a.diffToNewestMtimeSec ?? 1e18) - (b.diffToNewestMtimeSec ?? 1e18));

const currentRanges = rangesFor(currentOffset);
const recommendedOffset = offsetScores[0]?.offset ?? currentOffset;

const result = {
  stream,
  roots,
  currentOffset,
  recommendedOffset,
  filesCount: files.length,
  first: files[0] ? {
    path: files[0].path,
    parsed_iso_current_offset: iso(files[0].ms),
    mtime_iso: iso(files[0].mtimeMs),
    size: files[0].size
  } : null,
  newest: newest ? {
    path: newest.path,
    parsed_iso_current_offset: iso(newest.ms),
    mtime_iso: iso(newest.mtimeMs),
    size: newest.size
  } : null,
  offsetScores,
  currentRangesCount: currentRanges.length,
  currentRanges: currentRanges.slice(-10).map(r => ({
    from: Math.floor(r.startMs / 1000),
    duration: Math.max(1, Math.ceil((r.endMs - r.startMs) / 1000)),
    from_iso: iso(r.startMs),
    to_iso: iso(r.endMs),
    segments: r.segments,
    first: r.first,
    last: r.last
  }))
};

console.log(JSON.stringify(result, null, 2));
NODE

echo
echo "===== Patch dvr-archive-proxy recording_status to expose real ranges ====="
if [ "$APPLY" != "1" ]; then
  echo "DRY-RUN: no files changed."
  echo "To apply range-status patch:"
  echo "  sudo PROJECT_DIR=$PROJECT_DIR STREAM_NAME=$STREAM_NAME TOKEN='...' APPLY=1 bash scripts/v127-archive-status-ranges-repair.sh"
else
  python3 - "$ARCHIVE_PROXY" <<'PY'
from pathlib import Path
import sys

p = Path(sys.argv[1])
s = p.read_text(encoding='utf-8')
needle = 'async function recordingStatus(stream, res)'
start = s.find(needle)
if start < 0:
    raise SystemExit('ERROR: recordingStatus function not found')

open_pos = s.find('{', start)
if open_pos < 0:
    raise SystemExit('ERROR: recordingStatus opening brace not found')

depth = 0
end = -1
for i in range(open_pos, len(s)):
    ch = s[i]
    if ch == '{':
        depth += 1
    elif ch == '}':
        depth -= 1
        if depth == 0:
            end = i + 1
            break
if end < 0:
    raise SystemExit('ERROR: recordingStatus closing brace not found')

new_func = """async function recordingStatus(stream, res) {
  const segments = await scanSegments(stream, 0, Number.MAX_SAFE_INTEGER);
  const first = segments[0];
  const last = segments[segments.length - 1];

  const segmentSeconds = Number(process.env.SEGMENT_DURATION || process.env.DVR_SEGMENT_DURATION || 4);
  const gapSeconds = Math.max(
    Number(process.env.DVR_RANGE_GAP_SECONDS || 12),
    segmentSeconds * 2 + 2
  );
  const gapMs = gapSeconds * 1000;

  const rangesRaw = [];
  for (const segment of segments) {
    const segStart = segment.ms;
    const segEnd = segment.ms + Math.max(1, segmentSeconds) * 1000;
    const range = rangesRaw[rangesRaw.length - 1];

    if (!range || segStart > range.endMs + gapMs) {
      rangesRaw.push({
        startMs: segStart,
        endMs: segEnd,
        segments: 1
      });
    } else {
      range.endMs = Math.max(range.endMs, segEnd);
      range.segments += 1;
    }
  }

  const ranges = rangesRaw.map((range) => ({
    from: Math.floor(range.startMs / 1000),
    duration: Math.max(1, Math.ceil((range.endMs - range.startMs) / 1000)),
    start: Math.floor(range.startMs / 1000),
    end: Math.floor(range.endMs / 1000),
    from_iso: iso(range.startMs),
    to_iso: iso(range.endMs),
    start_iso: iso(range.startMs),
    end_iso: iso(range.endMs),
    segments: range.segments
  }));

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
    ranges,
    recordings: ranges,
    items: ranges,
    range_gap_seconds: gapSeconds,
    version: 'v127-archive-status-ranges-repair'
  }, { 'x-newdomofon-resolved-stream': stream });
}"""
p.write_text(s[:start] + new_func + s[end:], encoding='utf-8')
print(f'patched: {p}')
PY

  node --check "$ARCHIVE_PROXY"

  if [ "$APPLY_OFFSET" = "1" ]; then
    echo
    echo "===== Optional offset correction ====="
    RECOMMENDED_OFFSET="$(node -e '
const fs=require("fs");
const path=process.argv[1];
const raw=fs.readFileSync(path,"utf8");
const m=raw.match(/"recommendedOffset":\s*(-?\d+)/);
console.log(m?m[1]:"");
' "$BACKUP_DIR/archive-local-diagnostics.json")"

    if [ -n "$RECOMMENDED_OFFSET" ]; then
      echo "recommended_offset: $RECOMMENDED_OFFSET"
      if [ -f "$APP_ENV" ]; then
        if grep -q '^DVR_FILENAME_TZ_OFFSET_MINUTES=' "$APP_ENV"; then
          sudo sed -i "s/^DVR_FILENAME_TZ_OFFSET_MINUTES=.*/DVR_FILENAME_TZ_OFFSET_MINUTES=$RECOMMENDED_OFFSET/" "$APP_ENV"
        else
          echo "DVR_FILENAME_TZ_OFFSET_MINUTES=$RECOMMENDED_OFFSET" | sudo tee -a "$APP_ENV" >/dev/null
        fi
        echo "updated $APP_ENV"
      else
        echo "WARN: $APP_ENV not found, cannot set DVR_FILENAME_TZ_OFFSET_MINUTES"
      fi
    else
      echo "WARN: recommended offset not resolved"
    fi
  fi

  echo
  echo "===== Restart archive-related services ====="
  for svc in newdomofon-dvr-archive-proxy.service newdomofon-smartyard-compat.service; do
    if systemctl list-unit-files "$svc" >/dev/null 2>&1; then
      echo "restart: $svc"
      sudo systemctl restart "$svc" || true
    fi
  done

  sleep 2

  echo
  echo "===== New HTTP status ====="
  for url in \
    "$SITE_URL/dvr-archive/$STREAM_NAME/recording_status.json$TOKEN_Q" \
    "$SITE_URL/$STREAM_NAME/recording_status.json$TOKEN_Q"
  do
    echo "--- $url"
    curl -k -sS --max-time 20 "$url" | jq '{stream, name, recording, from, to, from_iso, to_iso, segments, ranges_count: (.ranges|length?), last_range: (.ranges[-1]?)}' || true
    echo
  done
fi

cat <<EOF

Result:
  diagnostics saved in:
    $BACKUP_DIR

What this script fixes:
  - recording_status.json now returns real archive ranges, not only one from/to.
  - After camera outage, old archive and new archive become separate ranges.
  - Player timeline can show the actual gap instead of treating the new archive as absent/wrong.

If newest file time is shifted by 3 hours:
  run again with:
    APPLY=1 APPLY_OFFSET=1

Rollback:
  LAST_BACKUP="\$(ls -td /opt/newdomofon-video/backups/v127-archive-status-ranges-repair-* | head -1)"
  sudo cp "\$LAST_BACKUP/opt/newdomofon-video/dvr-archive-proxy/server.js" "/opt/newdomofon-video/dvr-archive-proxy/server.js"
  [ -f "\$LAST_BACKUP/etc/newdomofon-video/app.env" ] && sudo cp "\$LAST_BACKUP/etc/newdomofon-video/app.env" "/etc/newdomofon-video/app.env"
  sudo systemctl restart newdomofon-dvr-archive-proxy.service newdomofon-smartyard-compat.service
EOF
