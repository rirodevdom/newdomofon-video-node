#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="${PROJECT_DIR:-/opt/newdomofon-video}"
SITE_URL="${SITE_URL:-https://new-video.domofon-37.ru}"
EVENTS_PORT="${EVENTS_PORT:-3057}"
BACKUP_DIR="$PROJECT_DIR/backups/v1244-public-events-nginx-active-repair-$(date +%Y%m%d-%H%M%S)"

echo "===== v124.4 public-events nginx ACTIVE config repair ====="
echo "project:     $PROJECT_DIR"
echo "site:        $SITE_URL"
echo "events_port: $EVENTS_PORT"
echo "backup:      $BACKUP_DIR"

test -d "$PROJECT_DIR"
test -d /etc/nginx

HOST="$(python3 - <<'PY' "$SITE_URL"
from urllib.parse import urlparse
import sys
u = urlparse(sys.argv[1])
print(u.hostname or sys.argv[1].replace('https://','').replace('http://','').split('/')[0])
PY
)"
echo "host:        $HOST"

mkdir -p "$BACKUP_DIR"

echo
echo "===== Collect ACTIVE nginx configs only ====="
mapfile -t ACTIVE_FILES < <(
  find /etc/nginx/sites-enabled /etc/nginx/conf.d \
    \( -type f -o -type l \) 2>/dev/null \
  | sort -u
)

if [ "${#ACTIVE_FILES[@]}" -eq 0 ]; then
  echo "ERROR: no active nginx files found in sites-enabled/conf.d"
  exit 1
fi

echo "active files:"
for f in "${ACTIVE_FILES[@]}"; do
  echo "  $f -> $(readlink -f "$f" 2>/dev/null || echo "$f")"
done

echo
echo "===== Backup active configs and symlink targets ====="
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
echo "===== Rewrite active nginx configs: remove ALL public-events locations, insert ONE canonical block ====="
python3 - "$HOST" "$EVENTS_PORT" "${ACTIVE_FILES[@]}" <<'PY'
from pathlib import Path
import re
import sys

host = sys.argv[1]
port = sys.argv[2]
active_paths = [Path(x) for x in sys.argv[3:]]

canonical = f'''
    # v124.4 NewDomofon public-events SDK API CORS fix
    # Single CORS owner for /public-events/.
    location ^~ /public-events/ {{
        proxy_pass http://127.0.0.1:{port};
        proxy_http_version 1.1;

        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;

        proxy_hide_header Access-Control-Allow-Origin;
        proxy_hide_header Access-Control-Allow-Methods;
        proxy_hide_header Access-Control-Allow-Headers;
        proxy_hide_header Access-Control-Expose-Headers;
        proxy_hide_header Access-Control-Allow-Credentials;
        proxy_hide_header Access-Control-Max-Age;

        add_header Access-Control-Allow-Origin "*" always;
        add_header Access-Control-Allow-Methods "GET, HEAD, OPTIONS" always;
        add_header Access-Control-Allow-Headers "Origin, Accept, Content-Type, Authorization, Range, Cache-Control, Pragma, X-Requested-With" always;
        add_header Access-Control-Expose-Headers "Content-Length, Content-Type" always;
        add_header Cache-Control "no-store" always;

        if ($request_method = OPTIONS) {{
            add_header Access-Control-Allow-Origin "*" always;
            add_header Access-Control-Allow-Methods "GET, HEAD, OPTIONS" always;
            add_header Access-Control-Allow-Headers "Origin, Accept, Content-Type, Authorization, Range, Cache-Control, Pragma, X-Requested-With" always;
            add_header Access-Control-Max-Age 86400 always;
            add_header Content-Length 0 always;
            return 204;
        }}
    }}

'''

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

def iter_blocks(text: str, keyword: str):
    pat = re.compile(r'(?m)(^|\n)([ \t]*)' + re.escape(keyword) + r'\b[^{}]*\{', re.I)
    for m in pat.finditer(text):
        start = m.start() + (1 if text[m.start()] == '\n' else 0)
        open_pos = text.find('{', m.start(), m.end())
        end = matching_brace(text, open_pos)
        if end >= 0:
            yield start, open_pos, end + 1, text[start:end + 1]

def remove_locations(text: str):
    ranges = []
    for start, open_pos, end, block in iter_blocks(text, 'location'):
        header = text[start:open_pos + 1].lower()
        body = block.lower()
        if (
            '/public-events' in header
            or ('public-events' in header and 'location' in header)
            or ('127.0.0.1:3057' in body and 'public-events' in body)
            or ('127.0.0.1:3058' in body and 'public-events' in body)
            or ('localhost:3057' in body and 'public-events' in body)
            or ('localhost:3058' in body and 'public-events' in body)
        ):
            ranges.append((start, end, header.strip()))
    if not ranges:
        return text, []

    out = []
    pos = 0
    removed = []
    for start, end, header in sorted(ranges):
        out.append(text[pos:start])
        out.append('\n')
        pos = end
        removed.append(header)
    out.append(text[pos:])
    return ''.join(out), removed

def server_score(block: str, path: Path) -> int:
    b = block.lower()
    p = str(path).lower()
    score = 0
    if re.search(r'server_name\s+[^;]*' + re.escape(host.lower()), b):
        score += 5000
    if host.lower() in b:
        score += 2000
    if re.search(r'listen\s+[^;]*443', b):
        score += 500
    if 'ssl' in b:
        score += 200
    if 'newdomofon-video' in p:
        score += 100
    if 'sites-enabled' in p:
        score += 50
    return score

records = []
seen_real = set()
for active in active_paths:
    if not active.exists():
        continue
    real = active.resolve()
    if real in seen_real:
        continue
    seen_real.add(real)
    text = active.read_text(encoding='utf-8', errors='ignore')
    new_text, removed = remove_locations(text)
    records.append({'active': active, 'real': real, 'text': new_text, 'removed': removed})
    if removed:
        print(f"removed from {active}: {len(removed)}")
        for h in removed:
            print(f"  - {h}")

best = None
for rec in records:
    for start, open_pos, end, block in iter_blocks(rec['text'], 'server'):
        sc = server_score(block, rec['active'])
        if best is None or sc > best[0]:
            best = (sc, rec, start, end, block)

if best is None:
    raise SystemExit('ERROR: no server block found')

score, rec, start, end, block = best
print(f"target active config: {rec['active']} real={rec['real']} score={score}")

text = rec['text']
insert_pos = end - 1
rec['text'] = text[:insert_pos] + "\n" + canonical + text[insert_pos:]

for rec in records:
    rec['active'].write_text(rec['text'], encoding='utf-8')
    print(f"written active path: {rec['active']}")
PY

echo
echo "===== Patch upstream Node services to avoid direct ACAO emission when possible ====="
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

s = re.sub(r'''(['"])Access-Control-Allow-Origin\1\s*:''', r'''\1X-Upstream-Access-Control-Allow-Origin\1:''', s)
s = re.sub(r'''(["'])Access-Control-Allow-Origin\1\s*,''', r'''\1X-Upstream-Access-Control-Allow-Origin\1,''', s)
s = re.sub(r'''res\.setHeader\(\s*(['"])Access-Control-Allow-Origin\1\s*,''', r'''res.setHeader('X-Upstream-Access-Control-Allow-Origin',''', s)
s = re.sub(r'''headers\.set\(\s*(['"])Access-Control-Allow-Origin\1\s*,''', r'''headers.set('X-Upstream-Access-Control-Allow-Origin',''', s)

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

echo "reload: nginx"
sudo systemctl reload nginx

echo
echo "===== Header verification ====="
echo "Expected: exactly one Access-Control-Allow-Origin and count=1"
curl -k -sS -D - -o /dev/null \
  -H 'Origin: https://example.com' \
  "$SITE_URL/public-events/health" \
  | tr -d '\r' \
  | awk 'BEGIN{IGNORECASE=1} /^access-control-allow-origin:/ {print; c++} END{print "count=" c}'

echo
echo "===== Active nginx public-events locations ====="
sudo nginx -T 2>/dev/null | grep -nE 'location .*public-events|127\.0\.0\.1:3057|127\.0\.0\.1:3058' || true

cat <<EOF

installed:
  v124.4 public-events nginx active config repair

backup:
  $BACKUP_DIR

Checks:
  curl -k -sS -D - -o /dev/null \
    -H 'Origin: https://example.com' \
    '$SITE_URL/public-events/health' \
    | tr -d '\r' | grep -i '^access-control-allow-origin'

  curl -k '$SITE_URL/public-events/f0486587-8a79-4cc2-b257-0671f874c08b/events?start=2026-06-11T00:00:00Z&end=2026-06-11T23:59:59Z&stream=cam_10_130_1_219&limit=20&token=TOKEN' \
    | jq '{ok, count, first: .items[0]}'

Rollback:
  LAST_BACKUP="\$(ls -td /opt/newdomofon-video/backups/v1244-public-events-nginx-active-repair-* | head -1)"
  sudo cp -a "\$LAST_BACKUP/etc/nginx/." /etc/nginx/
  sudo cp -a "\$LAST_BACKUP/opt/newdomofon-video/." /opt/newdomofon-video/
  sudo nginx -t && sudo systemctl reload nginx
EOF
