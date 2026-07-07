#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="${PROJECT_DIR:-/opt/newdomofon-video}"
SITE_URL="${SITE_URL:-https://new-video.domofon-37.ru}"
BACKUP_DIR="$PROJECT_DIR/backups/v1241-public-events-cors-single-origin-$(date +%Y%m%d-%H%M%S)"

echo "===== v124.1 public-events CORS single-origin fix ====="
echo "project: $PROJECT_DIR"
echo "site:    $SITE_URL"
echo "backup:  $BACKUP_DIR"

test -d "$PROJECT_DIR"
test -d /etc/nginx

mkdir -p "$BACKUP_DIR"

echo
echo "===== Locate nginx configs for public-events ====="
mapfile -t NGINX_FILES < <(
  grep -RIlE 'public-events|events-public|3057|3058' \
    /etc/nginx/sites-enabled \
    /etc/nginx/sites-available \
    /etc/nginx/conf.d 2>/dev/null || true
)

if [ "${#NGINX_FILES[@]}" -eq 0 ]; then
  echo "ERROR: cannot find nginx config containing public-events / 3057 / 3058"
  echo "Run manually:"
  echo "  sudo grep -RInE 'public-events|3057|3058|Access-Control-Allow-Origin' /etc/nginx"
  exit 1
fi

for f in "${NGINX_FILES[@]}"; do
  echo "nginx config: $f"
done

echo
echo "===== Backup nginx configs ====="
for f in "${NGINX_FILES[@]}"; do
  mkdir -p "$BACKUP_DIR$(dirname "$f")"
  cp -a "$f" "$BACKUP_DIR$f"
  echo "backup: $f"
done

echo
echo "===== Patch nginx public-events locations ====="
python3 - "$BACKUP_DIR" "${NGINX_FILES[@]}" <<'PY'
from pathlib import Path
import re
import sys

files = [Path(x) for x in sys.argv[2:]]

CORS_LINES = [
    'proxy_hide_header Access-Control-Allow-Origin;',
    'proxy_hide_header Access-Control-Allow-Methods;',
    'proxy_hide_header Access-Control-Allow-Headers;',
    'proxy_hide_header Access-Control-Expose-Headers;',
    'proxy_hide_header Access-Control-Allow-Credentials;',
    'add_header Access-Control-Allow-Origin "*" always;',
    'add_header Access-Control-Allow-Methods "GET, HEAD, OPTIONS" always;',
    'add_header Access-Control-Allow-Headers "Origin, Accept, Content-Type, Authorization, Range, Cache-Control, Pragma, X-Requested-With" always;',
    'add_header Access-Control-Expose-Headers "Content-Length, Content-Type" always;',
    'if ($request_method = OPTIONS) { return 204; }',
]

remove_re = re.compile(
    r'^\s*(?:'
    r'add_header\s+Access-Control-Allow-(?:Origin|Methods|Headers|Expose-Headers|Credentials|Max-Age)\b.*;|'
    r'proxy_hide_header\s+Access-Control-Allow-(?:Origin|Methods|Headers|Expose-Headers|Credentials|Max-Age)\b.*;'
    r')\s*$',
    re.I
)

def find_matching_brace(text: str, open_pos: int) -> int:
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

def patch_block(block: str) -> str:
    lines = block.splitlines()
    if not lines:
        return block
    cleaned = [lines[0]]
    for line in lines[1:]:
        if remove_re.match(line):
            continue
        cleaned.append(line)
    indent = '        '
    for line in cleaned[1:]:
        if line.strip() and not line.lstrip().startswith('#') and not line.strip().startswith('}'):
            indent = line[:len(line) - len(line.lstrip())]
            break
    insert = [indent + x for x in CORS_LINES]
    return '\n'.join([cleaned[0]] + insert + cleaned[1:]) + ('\n' if block.endswith('\n') else '')

def patch_text(text: str):
    out = []
    pos = 0
    changed_blocks = 0
    loc_re = re.compile(r'location\s+(?:=|~\*?|@\w+)?\s*[^{}]*\{', re.I)
    for m in loc_re.finditer(text):
        start = m.start()
        open_brace = text.find('{', m.start(), m.end())
        end = find_matching_brace(text, open_brace)
        if end < 0:
            continue
        header = text[m.start():open_brace + 1]
        block = text[m.start():end + 1]
        target = (
            re.search(r'public-events|events-public', header, re.I) or
            re.search(r'public-events|events-public|127\.0\.0\.1:3057|localhost:3057|127\.0\.0\.1:3058|localhost:3058', block, re.I)
        )
        if not target:
            continue
        out.append(text[pos:start])
        out.append(patch_block(block))
        pos = end + 1
        changed_blocks += 1
    if changed_blocks == 0:
        return text, 0
    out.append(text[pos:])
    return ''.join(out), changed_blocks

total = 0
for p in files:
    text = p.read_text(encoding='utf-8', errors='ignore')
    new_text, count = patch_text(text)
    if count:
        p.write_text(new_text, encoding='utf-8')
        print(f"patched: {p} blocks={count}")
        total += count
    else:
        print(f"no public-events location block patched in: {p}")

if total == 0:
    raise SystemExit("ERROR: no nginx location blocks were patched")
PY

echo
echo "===== Optional: patch upstream Node ACAO to avoid duplicate direct headers ====="
for f in \
  "$PROJECT_DIR/public-events-proxy/server.js" \
  "$PROJECT_DIR/events-public-proxy/server.js"
do
  if [ -f "$f" ]; then
    mkdir -p "$BACKUP_DIR$(dirname "$f")"
    cp -a "$f" "$BACKUP_DIR$f.node-cors-backup"
    python3 - "$f" <<'PY'
from pathlib import Path
import re
import sys
p = Path(sys.argv[1])
s = p.read_text(encoding='utf-8', errors='ignore')
before = s
s = re.sub(r"(\s*)['\"]Access-Control-Allow-Origin['\"]\s*:\s*['\"]\*['\"]\s*,?", r"\1// Access-Control-Allow-Origin is emitted by nginx v124.1 only", s)
if s != before:
    p.write_text(s, encoding='utf-8')
    print(f"patched node upstream ACAO: {p}")
else:
    print(f"node upstream ACAO not changed: {p}")
PY
  fi
done

echo
echo "===== Syntax checks ====="
sudo nginx -t

for svc in newdomofon-public-events-proxy.service newdomofon-events-public-proxy.service; do
  if systemctl list-unit-files "$svc" >/dev/null 2>&1; then
    echo "restart: $svc"
    sudo systemctl restart "$svc" || true
  fi
done

echo "reload: nginx"
sudo systemctl reload nginx

echo
echo "===== Header verification ====="
echo "Expected: exactly one Access-Control-Allow-Origin line."
set +e
curl -k -sS -D - -o /dev/null \
  -H 'Origin: https://example.com' \
  "$SITE_URL/public-events/health" \
  | tr -d '\r' \
  | awk 'BEGIN{IGNORECASE=1} /^access-control-allow-origin:/ {print NR ":" $0; c++} END{print "count=" c}'
set -e

cat <<EOF

installed:
  nginx public-events CORS single-origin fix v124.1

backup:
  $BACKUP_DIR

Why:
  Browser saw Access-Control-Allow-Origin as "*, *".
  That means the header was emitted twice, usually once by upstream Node and once by nginx.
  This patch makes nginx hide upstream CORS headers and emit exactly one public-events CORS set.

Checks:
  curl -k -sS -D - -o /dev/null \\
    -H 'Origin: https://example.com' \\
    '$SITE_URL/public-events/health' \\
    | tr -d '\\r' | grep -i '^access-control-allow-origin'

  curl -k '$SITE_URL/public-events/f0486587-8a79-4cc2-b257-0671f874c08b/events?start=2026-06-11T19:48:13.000Z&end=2026-06-11T20:18:12.000Z&stream=cam_10_130_1_219&limit=20&token=TOKEN' \\
    | jq '{ok, count, first: .items[0]}'

Rollback:
  LAST_BACKUP="\$(ls -td /opt/newdomofon-video/backups/v1241-public-events-cors-single-origin-* | head -1)"
  sudo cp -a "\$LAST_BACKUP/etc/nginx/." /etc/nginx/
  sudo nginx -t && sudo systemctl reload nginx
EOF
