#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="${PROJECT_DIR:-/opt/newdomofon-video}"
SITE_URL="${SITE_URL:-https://new-video.domofon-37.ru}"
STREAM_NAME="${STREAM_NAME:-cam_10_130_1_219}"
TOKEN="${TOKEN:-}"
APPLY="${APPLY:-0}"
RANGE_GAP_SECONDS="${RANGE_GAP_SECONDS:-12}"
ARCHIVE_SERVICE="${ARCHIVE_SERVICE:-newdomofon-dvr-archive-proxy.service}"
BACKUP_DIR="$PROJECT_DIR/backups/v131-archive-metadata-single-source-$(date +%Y%m%d-%H%M%S)"

ARCHIVE_PROXY="$PROJECT_DIR/dvr-archive-proxy/server.js"

echo "===== v131 archive metadata single source ====="
echo "project:           $PROJECT_DIR"
echo "site:              $SITE_URL"
echo "stream:            $STREAM_NAME"
echo "apply:             $APPLY"
echo "range_gap_seconds: $RANGE_GAP_SECONDS"
echo "archive_proxy:     $ARCHIVE_PROXY"
echo "backup:            $BACKUP_DIR"

test -d "$PROJECT_DIR"
test -f "$ARCHIVE_PROXY"
mkdir -p "$BACKUP_DIR"

echo
echo "===== Load env ====="
set +u
for envf in /etc/newdomofon-video/app.env "$PROJECT_DIR/backend/.env" "$PROJECT_DIR/.env"; do
  if [ -f "$envf" ]; then
    echo "load: $envf"
    set -a
    . "$envf"
    set +a
  fi
done
set -u

ARCHIVE_PORT="${ARCHIVE_PROXY_PORT:-3046}"
echo "archive_port: $ARCHIVE_PORT"

TOKEN_Q=""
if [ -n "$TOKEN" ]; then TOKEN_Q="?token=$TOKEN"; fi

echo
echo "===== Backup ====="
for f in "$ARCHIVE_PROXY" /etc/systemd/system/"$ARCHIVE_SERVICE"; do
  if [ -f "$f" ]; then
    mkdir -p "$BACKUP_DIR$(dirname "$f")"
    cp -a "$f" "$BACKUP_DIR$f"
    echo "backup: $f"
  fi
done

check_url() {
  local label="$1"
  local url="$2"
  echo "--- $label"
  echo "$url"
  curl -k -sS --max-time 20 -D "$BACKUP_DIR/headers-$(echo "$label" | sed 's#[^A-Za-z0-9_.-]#_#g').txt" "$url" \
    | tee "$BACKUP_DIR/body-$(echo "$label" | sed 's#[^A-Za-z0-9_.-]#_#g').json" \
    | jq 'if type=="array" then .[0] else . end | {
      stream,
      version,
      from,
      to,
      from_iso,
      to_iso,
      ranges_count: (.ranges|length?),
      gaps_count: (.gaps|length?),
      ranges,
      gaps,
      last_range: .ranges[-1]?
    }' 2>/dev/null || true
  grep -Ei '^(HTTP/|x-nd-archive-meta-source:|x-nd-recording-status-source:|content-type:)' "$BACKUP_DIR/headers-$(echo "$label" | sed 's#[^A-Za-z0-9_.-]#_#g').txt" || true
  echo
}

echo
echo "===== Before ====="
for ep in recording_status.json coverage.json ranges.json; do
  check_url "local-$ep-before" "http://127.0.0.1:$ARCHIVE_PORT/dvr-archive/$STREAM_NAME/$ep$TOKEN_Q"
  check_url "public-$ep-before" "$SITE_URL/dvr-archive/$STREAM_NAME/$ep$TOKEN_Q"
done

if [ "$APPLY" != "1" ]; then
  cat <<EOF

DRY-RUN only. Nothing changed.

Current problem:
  recording_status.json already shows the correct split archive ranges.
  coverage.json and ranges.json still use the old v93 coverage code and merge the outage into one range.

v131 fix:
  - makes recording_status.json, coverage.json, and ranges.json use one single range builder;
  - adds explicit gaps[];
  - keeps all endpoints compatible with old player code.

To apply:
  sudo PROJECT_DIR=$PROJECT_DIR \\
    SITE_URL=$SITE_URL \\
    STREAM_NAME=$STREAM_NAME \\
    TOKEN='...' \\
    APPLY=1 \\
    bash scripts/v131-archive-metadata-single-source.sh
EOF
  exit 0
fi

echo
echo "===== Patch dvr-archive-proxy/server.js ====="
python3 - "$ARCHIVE_PROXY" "$RANGE_GAP_SECONDS" <<'PY'
from pathlib import Path
import sys
import re

p = Path(sys.argv[1])
range_gap_seconds = sys.argv[2]
s = p.read_text(encoding='utf-8', errors='ignore')

def matching_brace(text: str, open_pos: int) -> int:
    depth = 0
    quote = None
    esc = False
    line_comment = False
    block_comment = False
    i = open_pos
    while i < len(text):
        ch = text[i]
        nxt = text[i+1] if i + 1 < len(text) else ''
        if line_comment:
            if ch == '\n':
                line_comment = False
            i += 1
            continue
        if block_comment:
            if ch == '*' and nxt == '/':
                block_comment = False
                i += 2
            else:
                i += 1
            continue
        if quote:
            if esc:
                esc = False
            elif ch == '\\':
                esc = True
            elif ch == quote:
                quote = None
            i += 1
            continue
        if ch == '/' and nxt == '/':
            line_comment = True
            i += 2
            continue
        if ch == '/' and nxt == '*':
            block_comment = True
            i += 2
            continue
        if ch in ("'", '"', '`'):
            quote = ch
            i += 1
            continue
        if ch == '{':
            depth += 1
        elif ch == '}':
            depth -= 1
            if depth == 0:
                return i
        i += 1
    return -1

needle = 'async function recordingStatus(stream, res)'
start = s.find(needle)
if start < 0:
    raise SystemExit('ERROR: recordingStatus function not found')
open_pos = s.find('{', start)
end = matching_brace(s, open_pos)
if end < 0:
    raise SystemExit('ERROR: recordingStatus closing brace not found')

new_func = f'''async function recordingStatus(stream, res) {{
  const segments = await scanSegments(stream, 0, Number.MAX_SAFE_INTEGER);
  const first = segments[0];
  const last = segments[segments.length - 1];

  const segmentSeconds = Number(process.env.SEGMENT_DURATION || process.env.DVR_SEGMENT_DURATION || 4);
  const configuredGapSeconds = Number(process.env.DVR_RANGE_GAP_SECONDS || {range_gap_seconds});
  const gapSeconds = Math.max(configuredGapSeconds, segmentSeconds * 2 + 2);
  const gapMs = gapSeconds * 1000;

  const rangesRaw = [];
  for (const segment of segments) {{
    const segStart = segment.ms;
    const segEnd = segment.ms + Math.max(1, segmentSeconds) * 1000;
    const range = rangesRaw[rangesRaw.length - 1];

    if (!range || segStart > range.endMs + gapMs) {{
      rangesRaw.push({{
        startMs: segStart,
        endMs: segEnd,
        segments: 1
      }});
    }} else {{
      range.endMs = Math.max(range.endMs, segEnd);
      range.segments += 1;
    }}
  }}

  const ranges = rangesRaw.map((range) => ({{
    from: Math.floor(range.startMs / 1000),
    duration: Math.max(1, Math.ceil((range.endMs - range.startMs) / 1000)),
    start: Math.floor(range.startMs / 1000),
    end: Math.floor(range.endMs / 1000),
    to: Math.floor(range.endMs / 1000),
    from_iso: iso(range.startMs),
    to_iso: iso(range.endMs),
    start_iso: iso(range.startMs),
    end_iso: iso(range.endMs),
    segments: range.segments
  }}));

  const gaps = [];
  for (let i = 0; i < rangesRaw.length - 1; i += 1) {{
    const a = rangesRaw[i];
    const b = rangesRaw[i + 1];
    if (b.startMs > a.endMs) {{
      gaps.push({{
        from: Math.floor(a.endMs / 1000),
        to: Math.floor(b.startMs / 1000),
        start: Math.floor(a.endMs / 1000),
        end: Math.floor(b.startMs / 1000),
        duration: Math.max(1, Math.ceil((b.startMs - a.endMs) / 1000)),
        from_iso: iso(a.endMs),
        to_iso: iso(b.startMs),
        start_iso: iso(a.endMs),
        end_iso: iso(b.startMs)
      }});
    }}
  }}

  sendJson(res, 200, {{
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
    gaps,
    range_gap_seconds: gapSeconds,
    version: 'v131-archive-metadata-single-source'
  }}, {{
    'x-newdomofon-resolved-stream': stream,
    'x-newdomofon-archive-coverage': 'v131',
    'x-nd-archive-meta-source': 'v131-single-source'
  }});
}}'''

s = s[:start] + new_func + s[end+1:]

patterns = [
    re.compile(r'''if\s*\(\s*mediaPath\s*===\s*['"]coverage\.json['"]\s*\|\|\s*mediaPath\s*===\s*['"]ranges\.json['"]\s*\)\s*\{'''),
    re.compile(r'''if\s*\(\s*mediaPath\s*===\s*['"]ranges\.json['"]\s*\|\|\s*mediaPath\s*===\s*['"]coverage\.json['"]\s*\)\s*\{'''),
]

replaced_route = False
for pat in patterns:
    m = pat.search(s)
    if not m:
        continue
    block_open = s.find('{', m.start(), m.end())
    block_end = matching_brace(s, block_open)
    if block_end < 0:
        raise SystemExit('ERROR: coverage/ranges route block closing brace not found')

    new_block = '''if (mediaPath === 'coverage.json' || mediaPath === 'ranges.json') {
      await recordingStatus(stream, res);
      return;
    }'''
    s = s[:m.start()] + new_block + s[block_end+1:]
    replaced_route = True
    break

if not replaced_route:
    print('WARNING: coverage/ranges if-block not found; trying targeted route injection before recording_status block')
    m2 = re.search(r'''if\s*\(\s*mediaPath\s*===\s*['"]recording_status\.json['"]\s*\)\s*\{''', s)
    if not m2:
        raise SystemExit('ERROR: neither coverage/ranges nor recording_status route block found')
    inject = '''if (mediaPath === 'coverage.json' || mediaPath === 'ranges.json') {
      await recordingStatus(stream, res);
      return;
    }

    '''
    s = s[:m2.start()] + inject + s[m2.start():]

p.write_text(s, encoding='utf-8')
print(f'patched: {p}')
print(f'route_coverage_ranges_to_recording_status: {replaced_route}')
PY

echo
echo "===== Syntax check ====="
node --check "$ARCHIVE_PROXY"

echo
echo "===== Restart archive proxy ====="
if systemctl list-unit-files "$ARCHIVE_SERVICE" >/dev/null 2>&1; then
  sudo systemctl restart "$ARCHIVE_SERVICE"
fi
sleep 2

echo
echo "===== After ====="
for ep in recording_status.json coverage.json ranges.json; do
  check_url "local-$ep-after" "http://127.0.0.1:$ARCHIVE_PORT/dvr-archive/$STREAM_NAME/$ep$TOKEN_Q"
  check_url "public-$ep-after" "$SITE_URL/dvr-archive/$STREAM_NAME/$ep$TOKEN_Q"
done

echo
echo "===== Final assertion ====="
for ep in recording_status.json coverage.json ranges.json; do
  code="$(curl -k -sS --max-time 20 -o "/tmp/v131-$ep.json" -w '%{http_code}' "$SITE_URL/dvr-archive/$STREAM_NAME/$ep$TOKEN_Q")"
  count="$(cat "/tmp/v131-$ep.json" | jq 'if type=="array" then .[0] else . end | (.ranges|length? // 0)' 2>/dev/null || echo 0)"
  gaps="$(cat "/tmp/v131-$ep.json" | jq 'if type=="array" then .[0] else . end | (.gaps|length? // 0)' 2>/dev/null || echo 0)"
  version="$(cat "/tmp/v131-$ep.json" | jq -r 'if type=="array" then .[0] else . end | (.version // "")' 2>/dev/null || true)"
  echo "$ep http_code=$code version=$version ranges_count=$count gaps_count=$gaps"
  if [ "$code" != "200" ] || [ "${count:-0}" -lt 2 ]; then
    echo "ERROR: $ep does not expose split ranges"
    exit 2
  fi
done

cat <<EOF

installed:
  v131 archive metadata single source

Expected:
  recording_status.json, coverage.json, and ranges.json now all return:
    version: v131-archive-metadata-single-source
    ranges_count >= 2
    gaps_count >= 1 when there is an outage between ranges

Browser:
  Ctrl+F5.
  If the old player still reloads HLS repeatedly after this, the next fix should be client-side debounce in player-v67/v94, not archive metadata.
EOF
