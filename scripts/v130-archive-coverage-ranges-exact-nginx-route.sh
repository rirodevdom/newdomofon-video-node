#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="${PROJECT_DIR:-/opt/newdomofon-video}"
SITE_URL="${SITE_URL:-https://new-video.domofon-37.ru}"
STREAM_NAME="${STREAM_NAME:-cam_10_130_1_219}"
TOKEN="${TOKEN:-}"
APPLY="${APPLY:-0}"
ARCHIVE_SERVICE="${ARCHIVE_SERVICE:-newdomofon-dvr-archive-proxy.service}"
BACKUP_DIR="$PROJECT_DIR/backups/v130-archive-coverage-ranges-exact-nginx-route-$(date +%Y%m%d-%H%M%S)"

echo "===== v130 archive coverage/ranges exact nginx route ====="
echo "project: $PROJECT_DIR"
echo "site:    $SITE_URL"
echo "stream:  $STREAM_NAME"
echo "apply:   $APPLY"
echo "backup:  $BACKUP_DIR"

test -d "$PROJECT_DIR"
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
echo "===== Active nginx files ====="
mapfile -t ACTIVE_REAL_FILES < <(
  {
    find /etc/nginx/sites-enabled /etc/nginx/conf.d -maxdepth 1 \( -type f -o -type l \) -print 2>/dev/null || true
  } | while read -r p; do
    [ -e "$p" ] || continue
    readlink -f "$p"
  done | sort -u
)

printf '  %s\n' "${ACTIVE_REAL_FILES[@]}"

echo
echo "===== Backup ====="
for f in "${ACTIVE_REAL_FILES[@]}" "$PROJECT_DIR/dvr-archive-proxy/server.js" /etc/systemd/system/"$ARCHIVE_SERVICE"; do
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
  curl -k -sS --max-time 15 -D "$BACKUP_DIR/headers-$(echo "$label" | sed 's#[^A-Za-z0-9_.-]#_#g').txt" "$url" \
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
      last_range: .ranges[-1]?
    }' 2>/dev/null || true
  grep -Ei '^(HTTP/|x-nd-archive-meta-source:|content-type:)' "$BACKUP_DIR/headers-$(echo "$label" | sed 's#[^A-Za-z0-9_.-]#_#g').txt" || true
  echo
}

echo
echo "===== Current endpoint comparison ====="
for ep in coverage.json ranges.json recording_status.json; do
  check_url "public-$ep-before" "$SITE_URL/dvr-archive/$STREAM_NAME/$ep$TOKEN_Q"
  check_url "local-$ep-before" "http://127.0.0.1:$ARCHIVE_PORT/dvr-archive/$STREAM_NAME/$ep$TOKEN_Q"
done

LOCAL_COVERAGE_OK="$(curl -sS -k --max-time 15 "http://127.0.0.1:$ARCHIVE_PORT/dvr-archive/$STREAM_NAME/coverage.json$TOKEN_Q" | jq 'if type=="array" then .[0] else . end | (.ranges|length? // 0)' 2>/dev/null || echo 0)"
LOCAL_RANGES_OK="$(curl -sS -k --max-time 15 "http://127.0.0.1:$ARCHIVE_PORT/dvr-archive/$STREAM_NAME/ranges.json$TOKEN_Q" | jq 'if type=="array" then .[0] else . end | (.ranges|length? // 0)' 2>/dev/null || echo 0)"

echo "local_coverage_ranges_count: $LOCAL_COVERAGE_OK"
echo "local_ranges_ranges_count:   $LOCAL_RANGES_OK"

if [ "$APPLY" != "1" ]; then
  cat <<EOF

DRY-RUN only. Nothing changed.

Why this is needed:
  Browser logs show:
    /dvr-archive/$STREAM_NAME/coverage.json 404
    /dvr-archive/$STREAM_NAME/ranges.json 404

  v129 fixed recording_status.json.
  v130 routes coverage.json and ranges.json through the same dvr-archive-proxy so the old server embed can read archive coverage/gaps too.

To apply:
  sudo PROJECT_DIR=$PROJECT_DIR \\
    SITE_URL=$SITE_URL \\
    STREAM_NAME=$STREAM_NAME \\
    TOKEN='...' \\
    APPLY=1 \\
    bash scripts/v130-archive-coverage-ranges-exact-nginx-route.sh
EOF
  exit 0
fi

echo
echo "===== Patch nginx: exact routes for coverage.json and ranges.json ====="
python3 - "$STREAM_NAME" "$ARCHIVE_PORT" "${ACTIVE_REAL_FILES[@]}" <<'PY'
from pathlib import Path
import sys
import re

stream = sys.argv[1]
port = sys.argv[2]
paths = [Path(x) for x in sys.argv[3:]]

block = f'''
    # v130 NewDomofon: exact archive metadata routes for {stream}.
    location = /dvr-archive/{stream}/coverage.json {{
        proxy_pass http://127.0.0.1:{port}/dvr-archive/{stream}/coverage.json$is_args$args;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_no_cache 1;
        proxy_cache_bypass 1;
        add_header Cache-Control "no-store" always;
        add_header X-ND-Archive-Meta-Source "v130-exact-dvr-archive-proxy" always;
    }}

    # v130 NewDomofon: exact archive metadata routes for {stream}.
    location = /dvr-archive/{stream}/ranges.json {{
        proxy_pass http://127.0.0.1:{port}/dvr-archive/{stream}/ranges.json$is_args$args;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_no_cache 1;
        proxy_cache_bypass 1;
        add_header Cache-Control "no-store" always;
        add_header X-ND-Archive-Meta-Source "v130-exact-dvr-archive-proxy" always;
    }}

'''

def matching_brace(s: str, open_pos: int) -> int:
    depth = 0
    quote = None
    esc = False
    comment = False
    i = open_pos
    while i < len(s):
        ch = s[i]
        if comment:
            if ch == '\n':
                comment = False
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
        if ch == '#':
            comment = True
            i += 1
            continue
        if ch in ("'", '"'):
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

def find_server_blocks(s: str):
    pat = re.compile(r'(?m)(^|\n)([ \t]*)server\s*\{')
    out = []
    for m in pat.finditer(s):
        start = m.start() + (1 if s[m.start()] == '\n' else 0)
        open_pos = s.find('{', m.start(), m.end())
        end = matching_brace(s, open_pos)
        if end >= 0:
            out.append((start, open_pos, end + 1, s[start:end + 1]))
    return out

def remove_old_v130(s: str):
    marker = f'# v130 NewDomofon: exact archive metadata routes for {stream}.'
    ranges = []
    pos = 0
    while True:
        idx = s.find(marker, pos)
        if idx < 0:
            break
        line_start = s.rfind('\n', 0, idx) + 1
        loc = s.find('location', idx)
        if loc < 0:
            pos = idx + len(marker)
            continue
        open_pos = s.find('{', loc)
        end = matching_brace(s, open_pos)
        if end < 0:
            pos = idx + len(marker)
            continue
        ranges.append((line_start, end + 1))
        pos = end + 1
    if not ranges:
        return s

    out = []
    pos = 0
    for a, b in sorted(ranges):
        if a < pos:
            continue
        out.append(s[pos:a])
        out.append('\n')
        pos = b
    out.append(s[pos:])
    return ''.join(out)

patched_files = 0
patched_servers = 0

for p in paths:
    if not p.exists():
        continue
    s = p.read_text(encoding='utf-8', errors='ignore')
    s = remove_old_v130(s)

    blocks = find_server_blocks(s)
    inserts = []
    for start, open_pos, end, srv in blocks:
        if 'listen' in srv.lower():
            inserts.append(end - 1)

    if not inserts:
        print(f'no listen server block: {p}')
        continue

    for pos in sorted(inserts, reverse=True):
        s = s[:pos] + '\n' + block + s[pos:]

    p.write_text(s, encoding='utf-8')
    patched_files += 1
    patched_servers += len(inserts)
    print(f'patched: {p} server_blocks={len(inserts)}')

print(f'total patched files={patched_files} server_blocks={patched_servers}')
if patched_servers < 1:
    raise SystemExit('ERROR: no server blocks patched')
PY

echo
echo "===== nginx proof and syntax ====="
sudo nginx -T 2>/tmp/v130-nginx-t.err | grep -n "v130 NewDomofon\|X-ND-Archive-Meta-Source\|coverage.json\|ranges.json" | head -120 || true
cat /tmp/v130-nginx-t.err || true
sudo nginx -t

echo
echo "===== Restart archive proxy and reload nginx ====="
if systemctl list-unit-files "$ARCHIVE_SERVICE" >/dev/null 2>&1; then
  echo "restart: $ARCHIVE_SERVICE"
  sudo systemctl restart "$ARCHIVE_SERVICE" || true
fi

echo "reload nginx"
sudo systemctl reload nginx
sleep 2

echo
echo "===== New endpoint comparison ====="
for ep in coverage.json ranges.json recording_status.json; do
  check_url "public-$ep-after" "$SITE_URL/dvr-archive/$STREAM_NAME/$ep$TOKEN_Q"
done

echo
echo "===== Final assertion ====="
for ep in coverage.json ranges.json; do
  code="$(curl -sS -k --max-time 15 -o /tmp/v130-$ep.json -w '%{http_code}' "$SITE_URL/dvr-archive/$STREAM_NAME/$ep$TOKEN_Q")"
  count="$(cat /tmp/v130-$ep.json | jq 'if type=="array" then .[0] else . end | (.ranges|length? // 0)' 2>/dev/null || echo 0)"
  header="$(curl -sS -k --max-time 15 -D - -o /dev/null "$SITE_URL/dvr-archive/$STREAM_NAME/$ep$TOKEN_Q" | tr -d '\r' | awk 'BEGIN{IGNORECASE=1} /^x-nd-archive-meta-source:/ {print $0}' | tail -1 || true)"
  echo "$ep http_code=$code ranges_count=$count header=${header:-<none>}"
  if [ "$code" != "200" ]; then
    echo "ERROR: $ep still not HTTP 200"
    exit 2
  fi
done

cat <<EOF

installed:
  v130 exact nginx routes for coverage.json and ranges.json

Expected:
  Browser should stop showing 404 for:
    /dvr-archive/$STREAM_NAME/coverage.json
    /dvr-archive/$STREAM_NAME/ranges.json

Browser:
  Ctrl+F5.
  Then watch console for old 404 messages disappearing.
EOF
