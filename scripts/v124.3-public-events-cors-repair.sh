#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="${PROJECT_DIR:-/opt/newdomofon-video}"
SITE_URL="${SITE_URL:-https://new-video.domofon-37.ru}"
EVENTS_PORT="${EVENTS_PORT:-3057}"
BACKUP_DIR="$PROJECT_DIR/backups/v1243-public-events-cors-repair-$(date +%Y%m%d-%H%M%S)"

echo "===== v124.3 public-events CORS repair ====="
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
echo "===== Collect nginx configs by real path ====="
mapfile -t RAW_FILES < <(
  find /etc/nginx/sites-enabled /etc/nginx/sites-available /etc/nginx/conf.d \
    \( -type f -o -type l \) 2>/dev/null \
  | sort -u
)

declare -A SEEN_REAL=()
NGINX_FILES=()
for f in "${RAW_FILES[@]}"; do
  [ -e "$f" ] || continue
  real="$(readlink -f "$f")"
  [ -f "$real" ] || continue
  if [ -z "${SEEN_REAL[$real]:-}" ]; then
    SEEN_REAL[$real]=1
    NGINX_FILES+=("$real")
  fi
done

if [ "${#NGINX_FILES[@]}" -eq 0 ]; then
  echo "ERROR: no nginx config files found"
  exit 1
fi

for f in "${NGINX_FILES[@]}"; do
  echo "nginx real config: $f"
done

echo
echo "===== Backup nginx configs and project proxies ====="
for f in "${NGINX_FILES[@]}"; do
  mkdir -p "$BACKUP_DIR$(dirname "$f")"
  cp -a "$f" "$BACKUP_DIR$f"
  echo "backup: $f"
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
echo "===== Remove duplicate public-events locations and insert one canonical location ====="
python3 - "$HOST" "$EVENTS_PORT" "${NGINX_FILES[@]}" <<'PY'
from pathlib import Path
import re
import sys

host = sys.argv[1]
port = sys.argv[2]
files = [Path(x) for x in sys.argv[3:]]

canonical = f'''
    # v124.3 NewDomofon public-events SDK API CORS fix
    # Single owner of CORS for /public-events/.
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

def blocks(text: str, keyword: str):
    pat = re.compile(r'(?m)(^|\n)\s*' + re.escape(keyword) + r'\b[^{}]*\{', re.I)
    for m in pat.finditer(text):
        start = m.start() + (1 if text[m.start()] == '\n' else 0)
        open_pos = text.find('{', m.start(), m.end())
        end = matching_brace(text, open_pos)
        if end >= 0:
            yield start, open_pos, end + 1, text[start:end + 1]

def remove_public_events_locations(text: str):
    found = []
    for start, open_pos, end, block in blocks(text, 'location'):
        header = text[start:open_pos + 1].lower()
        if '/public-events' in header:
            found.append((start, end))
    if not found:
        return text, 0

    out = []
    pos = 0
    for start, end in sorted(found):
        out.append(text[pos:start])
        out.append('\n')
        pos = end
    out.append(text[pos:])
    return ''.join(out), len(found)

def server_score(block: str, path: Path) -> int:
    b = block.lower()
    score = 0
    if re.search(r'server_name\s+[^;]*' + re.escape(host.lower()), b):
        score += 3000
    if host.lower() in b:
        score += 1000
    if re.search(r'listen\s+[^;]*443', b):
        score += 400
    if 'ssl' in b:
        score += 200
    if 'newdomofon-video' in str(path).lower():
        score += 100
    if 'default_server' in b:
        score += 10
    return score

texts = {}
total_removed = 0
for p in files:
    text = p.read_text(encoding='utf-8', errors='ignore')
    new_text, removed = remove_public_events_locations(text)
    texts[p] = new_text
    total_removed += removed
    if removed:
        print(f"removed public-events locations: {p} count={removed}")

best = None
for p, text in texts.items():
    for start, open_pos, end, block in blocks(text, 'server'):
        score = server_score(block, p)
        if best is None or score > best[0]:
            best = (score, p, start, end, block)

if best is None or best[0] <= 0:
    for p, text in texts.items():
        for start, open_pos, end, block in blocks(text, 'server'):
            score = (100 if 'newdomofon-video' in str(p) else 0) + (50 if '443' in block else 0)
            if best is None or score > best[0]:
                best = (score, p, start, end, block)

if best is None:
    raise SystemExit('ERROR: no server block found for public-events location insertion')

score, target, start, end, block = best
print(f"target server: {target} score={score}")

text = texts[target]
insert_pos = end - 1
texts[target] = text[:insert_pos] + "\n" + canonical + text[insert_pos:]

for p, text in texts.items():
    p.write_text(text, encoding='utf-8')
    print(f"written: {p}")

print(f"total_removed={total_removed}")
PY

echo
echo "===== Patch upstream Node services to not emit Access-Control-Allow-Origin ====="
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
echo "===== Restart public-events and reload nginx ====="
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
echo "===== Nginx public-events locations after patch ====="
sudo nginx -T 2>/dev/null | grep -nE 'location \^~ /public-events/|location .*public-events' || true

cat <<EOF

installed:
  v124.3 public-events CORS repair

backup:
  $BACKUP_DIR

What was fixed:
  - Removed duplicate /public-events/ location blocks from real nginx config files.
  - Inserted exactly one canonical location ^~ /public-events/.
  - nginx now hides upstream CORS headers and emits one Access-Control-Allow-Origin.
  - Restarted public-events services and reloaded nginx.

Checks:
  curl -k -sS -D - -o /dev/null \
    -H 'Origin: https://example.com' \
    '$SITE_URL/public-events/health' \
    | tr -d '\r' | grep -i '^access-control-allow-origin'

  curl -k '$SITE_URL/public-events/f0486587-8a79-4cc2-b257-0671f874c08b/events?start=2026-06-11T00:00:00Z&end=2026-06-11T23:59:59Z&stream=cam_10_130_1_219&limit=20&token=TOKEN' \
    | jq '{ok, count, first: .items[0]}'

Rollback:
  LAST_BACKUP="\$(ls -td /opt/newdomofon-video/backups/v1243-public-events-cors-repair-* | head -1)"
  sudo cp -a "\$LAST_BACKUP/etc/nginx/." /etc/nginx/
  sudo cp -a "\$LAST_BACKUP/opt/newdomofon-video/." /opt/newdomofon-video/
  sudo nginx -t && sudo systemctl reload nginx
  sudo systemctl restart newdomofon-public-events-proxy.service newdomofon-events-public-proxy.service
EOF
