#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="${PROJECT_DIR:-/opt/newdomofon-video}"
SITE_URL="${SITE_URL:-https://new-video.domofon-37.ru}"
BACKUP_DIR="$PROJECT_DIR/backups/v1245-public-events-cors-node-only-repair-$(date +%Y%m%d-%H%M%S)"

echo "===== v124.5 public-events CORS node-only repair ====="
echo "project: $PROJECT_DIR"
echo "site:    $SITE_URL"
echo "backup:  $BACKUP_DIR"

test -d "$PROJECT_DIR"
test -d /etc/nginx
mkdir -p "$BACKUP_DIR"

echo
echo "===== Backup active nginx configs and event proxies ====="
mapfile -t ACTIVE_FILES < <(
  find /etc/nginx/sites-enabled /etc/nginx/conf.d \
    \( -type f -o -type l \) 2>/dev/null | sort -u || true
)

declare -A BACKED=()
for f in "${ACTIVE_FILES[@]}"; do
  [ -e "$f" ] || continue
  real="$(readlink -f "$f" 2>/dev/null || echo "$f")"
  for p in "$f" "$real"; do
    [ -e "$p" ] || continue
    if [ -z "${BACKED[$p]:-}" ]; then
      BACKED[$p]=1
      mkdir -p "$BACKUP_DIR$(dirname "$p")"
      cp -a "$p" "$BACKUP_DIR$p"
      echo "backup: $p"
    fi
  done
done

for f in \
  "$PROJECT_DIR/public-events-proxy/server.js" \
  "$PROJECT_DIR/events-public-proxy/server.js"
do
  if [ -f "$f" ]; then
    mkdir -p "$BACKUP_DIR$(dirname "$f")"
    cp -a "$f" "$BACKUP_DIR$f"
    echo "backup: $f"
  fi
done

echo
echo "===== Remove only v124.x inserted public-events location blocks ====="
python3 - "${ACTIVE_FILES[@]}" <<'PY'
from pathlib import Path
import re
import sys

paths = []
seen = set()
for x in sys.argv[1:]:
    p = Path(x)
    if not p.exists():
        continue
    try:
        r = p.resolve()
    except Exception:
        r = p
    if r in seen:
        continue
    seen.add(r)
    paths.append(p)

def matching_brace(text: str, open_pos: int) -> int:
    depth = 0
    quote = None
    esc = False
    comment = False
    i = open_pos
    while i < len(text):
        ch = text[i]
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

for p in paths:
    text = p.read_text(encoding='utf-8', errors='ignore')
    original = text
    ranges = []

    # Remove location blocks that are ours: marker comment immediately before the location
    # or the block itself contains a v124 marker comment.
    loc_re = re.compile(r'(?m)(^|\n)[ \t]*(?:# v124\.[^\n]*\n[ \t]*)?location\s+(?:\^~\s+)?/public-events/[^{}]*\{', re.I)
    for m in loc_re.finditer(text):
        open_pos = text.find('{', m.start(), m.end())
        end = matching_brace(text, open_pos)
        if end < 0:
            continue
        start = m.start() + (1 if text[m.start()] == '\n' else 0)
        prefix = text[max(0, start-250):start].lower()
        block = text[start:end+1].lower()
        if 'v124.' in prefix or 'v124.' in block:
            ranges.append((start, end+1))

    if ranges:
        out = []
        pos = 0
        for start, end in sorted(ranges):
            out.append(text[pos:start])
            out.append('\n')
            pos = end
        out.append(text[pos:])
        text = ''.join(out)
        p.write_text(text, encoding='utf-8')
        print(f"removed v124.x public-events blocks from {p}: {len(ranges)}")
    else:
        print(f"no v124.x public-events block found in {p}")
PY

echo
echo "===== Disable Access-Control-Allow-Origin from Node upstreams, case-insensitive ====="
for f in \
  "$PROJECT_DIR/public-events-proxy/server.js" \
  "$PROJECT_DIR/events-public-proxy/server.js"
do
  if [ -f "$f" ]; then
    python3 - "$f" <<'PY'
from pathlib import Path
import re
import sys

p = Path(sys.argv[1])
s = p.read_text(encoding='utf-8', errors='ignore')
before = s

# Object literal keys: {'Access-Control-Allow-Origin': '*'} or {'access-control-allow-origin': '*'}
s = re.sub(
    r'''(['"])(access-control-allow-origin)\1\s*:''',
    lambda m: m.group(1) + 'X-Upstream-Access-Control-Allow-Origin' + m.group(1) + ':',
    s,
    flags=re.I
)

# setHeader / headers.set / appendHeader style calls.
s = re.sub(
    r'''(setHeader|headers\.set|appendHeader)\(\s*(['"])(access-control-allow-origin)\2\s*,''',
    lambda m: m.group(1) + "('X-Upstream-Access-Control-Allow-Origin',",
    s,
    flags=re.I
)

# Some code keeps CORS headers in arrays: ['Access-Control-Allow-Origin', '*']
s = re.sub(
    r'''(['"])(access-control-allow-origin)\1\s*,''',
    lambda m: m.group(1) + 'X-Upstream-Access-Control-Allow-Origin' + m.group(1) + ',',
    s,
    flags=re.I
)

if s != before:
    p.write_text(s, encoding='utf-8')
    print(f"patched upstream ACAO: {p}")
else:
    print(f"upstream ACAO unchanged: {p}")
PY
  fi
done

echo
echo "===== Syntax checks ====="
sudo nginx -t

for f in "$PROJECT_DIR/public-events-proxy/server.js" "$PROJECT_DIR/events-public-proxy/server.js"; do
  if [ -f "$f" ]; then
    node --check "$f"
  fi
done

echo
echo "===== Restart public-events services and reload nginx ====="
for svc in newdomofon-public-events-proxy.service newdomofon-events-public-proxy.service; do
  if systemctl list-unit-files "$svc" >/dev/null 2>&1; then
    echo "restart: $svc"
    sudo systemctl restart "$svc" || true
  fi
done

echo "reload nginx"
sudo systemctl reload nginx

echo
echo "===== Header verification ====="
curl -k -sS -D - -o /dev/null \
  -H 'Origin: https://example.com' \
  "$SITE_URL/public-events/health" \
  | tr -d '\r' \
  | awk 'BEGIN{IGNORECASE=1} /^access-control-allow-origin:/ {print; c++} END{print "count=" c}'

cat <<EOF

installed:
  v124.5 public-events CORS node-only repair

backup:
  $BACKUP_DIR

Why this script is different:
  - It does not add any new nginx location.
  - It removes only v124.x inserted public-events locations.
  - It leaves your original local-network nginx routing intact.
  - It removes the duplicate ACAO source from Node upstream, so nginx can remain the CORS owner.

Checks:
  curl -k -sS -D - -o /dev/null \\
    -H 'Origin: https://example.com' \\
    '$SITE_URL/public-events/health' \\
    | tr -d '\\r' | grep -i '^access-control-allow-origin'

Rollback:
  LAST_BACKUP="\$(ls -td /opt/newdomofon-video/backups/v1245-public-events-cors-node-only-repair-* | head -1)"
  sudo cp -a "\$LAST_BACKUP/etc/nginx/." /etc/nginx/
  sudo cp -a "\$LAST_BACKUP/opt/newdomofon-video/." /opt/newdomofon-video/
  sudo nginx -t && sudo systemctl reload nginx
EOF
