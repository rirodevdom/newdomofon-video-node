#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="${PROJECT_DIR:-/opt/newdomofon-video}"
SITE_URL="${SITE_URL:-https://new-video.domofon-37.ru}"
EVENTS_PORT="${EVENTS_PORT:-3057}"
BACKUP_DIR="$PROJECT_DIR/backups/v1242-public-events-nginx-location-fix-$(date +%Y%m%d-%H%M%S)"

echo "===== v124.2 public-events nginx explicit location fix ====="
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
echo "===== Locate nginx server configs ====="
mapfile -t NGINX_FILES < <(
  grep -RIlE "server_name|listen .*443|$HOST|public-events|3057|3058" \
    /etc/nginx/sites-enabled \
    /etc/nginx/sites-available \
    /etc/nginx/conf.d 2>/dev/null | sort -u || true
)

if [ "${#NGINX_FILES[@]}" -eq 0 ]; then
  echo "ERROR: nginx configs not found"
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
echo "===== Insert explicit /public-events/ location into the correct server block ====="
python3 - "$HOST" "$EVENTS_PORT" "${NGINX_FILES[@]}" <<'PY'
from pathlib import Path
import re
import sys

host = sys.argv[1]
port = sys.argv[2]
files = [Path(x) for x in sys.argv[3:]]

location_block = f'''
    # v124.2 NewDomofon public-events SDK API CORS fix
    # Keep this block before generic proxy/static locations.
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
        if ch in ('"', "'"):
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

def server_blocks(text: str):
    for m in re.finditer(r'(?m)(^|\n)\s*server\s*\{', text):
        open_pos = text.find('{', m.start())
        end = find_matching_brace(text, open_pos)
        if end >= 0:
            start = m.start() + (1 if text[m.start()] == '\n' else 0)
            yield start, open_pos, end + 1, text[start:end + 1]

def score_block(block: str, path: Path) -> int:
    b = block.lower()
    score = 0
    if host.lower() in b:
        score += 1000
    if re.search(r'server_name\s+[^;]*\b' + re.escape(host.lower()) + r'\b', b):
        score += 2000
    if 'listen' in b and '443' in b:
        score += 200
    if 'ssl' in b:
        score += 100
    if 'newdomofon' in str(path).lower():
        score += 50
    if 'default_server' in b:
        score += 10
    return score

best = None
for p in files:
    try:
        text = p.read_text(encoding='utf-8', errors='ignore')
    except Exception:
        continue
    for start, open_pos, end, block in server_blocks(text):
        sc = score_block(block, p)
        if best is None or sc > best[0]:
            best = (sc, p, text, start, end, block)

if best is None or best[0] <= 0:
    raise SystemExit(f"ERROR: cannot find target server block for host {host}")

score, path, text, start, end, block = best
print(f"target: {path} score={score}")

if re.search(r'location\s+\^~\s+/public-events/', block):
    print("explicit v124.2 public-events location already exists")
    raise SystemExit(0)

insert_pos = end - 1
new_text = text[:insert_pos] + "\n" + location_block + text[insert_pos:]
path.write_text(new_text, encoding='utf-8')
print(f"patched: {path}")
PY

echo
echo "===== Patch upstream public-events services: no Access-Control-Allow-Origin duplication ====="
for f in \
  "$PROJECT_DIR/public-events-proxy/server.js" \
  "$PROJECT_DIR/events-public-proxy/server.js"
do
  if [ -f "$f" ]; then
    mkdir -p "$BACKUP_DIR$(dirname "$f")"
    cp -a "$f" "$BACKUP_DIR$f"
    python3 - "$f" <<'PY'
from pathlib import Path
import re
import sys

p = Path(sys.argv[1])
s = p.read_text(encoding='utf-8', errors='ignore')
before = s

s = re.sub(r"""(['\"])Access-Control-Allow-Origin\1\s*:""", r"""'X-Upstream-Access-Control-Allow-Origin':""", s)
s = re.sub(r"""(["'])Access-Control-Allow-Origin\1\s*,""", r"""'X-Upstream-Access-Control-Allow-Origin',""", s)
s = re.sub(r"""res\.setHeader\(\s*(['\"])Access-Control-Allow-Origin\1\s*,""", r"""res.setHeader('X-Upstream-Access-Control-Allow-Origin',""", s)

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
echo "===== Restart services ====="
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
echo "Expected: exactly one access-control-allow-origin line and count=1"
curl -k -sS -D - -o /dev/null \
  -H 'Origin: https://example.com' \
  "$SITE_URL/public-events/health" \
  | tr -d '\r' \
  | awk 'BEGIN{IGNORECASE=1} /^access-control-allow-origin:/ {print; c++} END{print "count=" c}'

cat <<TXT

installed:
  v124.2 explicit nginx location for /public-events/

backup:
  $BACKUP_DIR

Why v124.1 failed:
  The previous script tried to patch an existing location block.
  Your nginx config had public-events/ports mentions, but not in a simple location block
  that the parser could safely modify.
  v124.2 instead inserts a new explicit:
    location ^~ /public-events/
  into the HTTPS server block for $HOST.

Checks:
  curl -k -sS -D - -o /dev/null \\
    -H 'Origin: https://example.com' \\
    '$SITE_URL/public-events/health' \\
    | tr -d '\\r' | grep -i '^access-control-allow-origin'

  curl -k '$SITE_URL/public-events/f0486587-8a79-4cc2-b257-0671f874c08b/events?start=2026-06-11T19:48:13.000Z&end=2026-06-11T20:18:12.000Z&stream=cam_10_130_1_219&limit=20&token=TOKEN' \\
    | jq '{ok, count, first: .items[0]}'

Rollback:
  LAST_BACKUP="\$(ls -td /opt/newdomofon-video/backups/v1242-public-events-nginx-location-fix-* | head -1)"
  sudo cp -a "\$LAST_BACKUP/etc/nginx/." /etc/nginx/
  sudo cp -a "\$LAST_BACKUP/opt/newdomofon-video/." /opt/newdomofon-video/
  sudo nginx -t && sudo systemctl reload nginx
  sudo systemctl restart newdomofon-public-events-proxy.service newdomofon-events-public-proxy.service
TXT
