#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="${PROJECT_DIR:-/opt/newdomofon-video}"
SITE_URL="${SITE_URL:-https://new-video.domofon-37.ru}"
STREAM_NAME="${STREAM_NAME:-cam_10_130_1_219}"
TOKEN="${TOKEN:-}"
APPLY="${APPLY:-0}"
RANGE_GAP_SECONDS="${RANGE_GAP_SECONDS:-12}"
BACKUP_DIR="$PROJECT_DIR/backups/v128-recording-status-public-ranges-router-$(date +%Y%m%d-%H%M%S)"

SMARTY_SERVICE="${SMARTY_SERVICE:-newdomofon-smartyard-compat.service}"
ARCHIVE_SERVICE="${ARCHIVE_SERVICE:-newdomofon-dvr-archive-proxy.service}"
NGINX_SITE="${NGINX_SITE:-/etc/nginx/sites-enabled/newdomofon-video.conf}"

echo "===== v128 public recording_status real ranges router ====="
echo "project:           $PROJECT_DIR"
echo "site:              $SITE_URL"
echo "stream:            $STREAM_NAME"
echo "apply:             $APPLY"
echo "range_gap_seconds: $RANGE_GAP_SECONDS"
echo "nginx_site:        $NGINX_SITE"
echo "backup:            $BACKUP_DIR"

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
SMARTY_PORT="${SMARTYARD_COMPAT_PORT:-3082}"

echo "archive_port: $ARCHIVE_PORT"
echo "smarty_port:  $SMARTY_PORT"

TOKEN_Q=""
if [ -n "$TOKEN" ]; then TOKEN_Q="?token=$TOKEN"; fi

echo
echo "===== Backup configs ====="
for f in \
  "$NGINX_SITE" \
  "$(readlink -f "$NGINX_SITE" 2>/dev/null || true)" \
  /etc/nginx/sites-available/newdomofon-video.conf \
  /etc/nginx/conf.d/newdomofon-restream-8445-http-gateway.conf \
  "$PROJECT_DIR/dvr-archive-proxy/server.js" \
  "$PROJECT_DIR/smartyard-compat-proxy/server.js" \
  /etc/systemd/system/"$SMARTY_SERVICE" \
  /etc/systemd/system/"$ARCHIVE_SERVICE"
do
  [ -n "$f" ] || continue
  if [ -f "$f" ]; then
    mkdir -p "$BACKUP_DIR$(dirname "$f")"
    cp -a "$f" "$BACKUP_DIR$f"
    echo "backup: $f"
  fi
done

echo
echo "===== Current endpoint comparison ====="
check_url() {
  local label="$1"
  local url="$2"
  echo "--- $label"
  echo "$url"
  curl -sS -k --max-time 15 "$url" \
    | jq 'if type=="array" then .[0] else . end | {
        stream,
        version,
        from,
        to,
        from_iso,
        to_iso,
        ranges_count: (.ranges|length?),
        ranges,
        last_range: .ranges[-1]?
      }' 2>/dev/null || true
  echo
}

check_url "public direct" "$SITE_URL/$STREAM_NAME/recording_status.json$TOKEN_Q"
check_url "public dvr-archive" "$SITE_URL/dvr-archive/$STREAM_NAME/recording_status.json$TOKEN_Q"
check_url "local archive proxy direct" "http://127.0.0.1:$ARCHIVE_PORT/$STREAM_NAME/recording_status.json$TOKEN_Q"
check_url "local archive proxy dvr-archive" "http://127.0.0.1:$ARCHIVE_PORT/dvr-archive/$STREAM_NAME/recording_status.json$TOKEN_Q"
check_url "local smartyard direct" "http://127.0.0.1:$SMARTY_PORT/$STREAM_NAME/recording_status.json$TOKEN_Q"

echo
echo "===== Ensure dvr-archive-proxy has v127 recording_status ranges ====="
if ! grep -q "v127-archive-status-ranges-repair" "$PROJECT_DIR/dvr-archive-proxy/server.js" 2>/dev/null; then
  echo "WARNING: dvr-archive-proxy/server.js does not contain v127 marker."
  echo "Run v127 first, then v128."
else
  echo "v127 marker: OK"
fi

if [ "$APPLY" != "1" ]; then
  cat <<EOF

DRY-RUN only. Nothing changed.

What is happening:
  Public /$STREAM_NAME/recording_status.json is still served by SmartYard-compatible route,
  not by the v127-patched dvr-archive-proxy recording_status.
  That is why public response is:
    [{ stream, ranges: [{ from, duration }] }]
  while v127 local disk diagnostics sees 2 real ranges.

To apply:
  sudo PROJECT_DIR=$PROJECT_DIR \\
    SITE_URL=$SITE_URL \\
    STREAM_NAME=$STREAM_NAME \\
    TOKEN='...' \\
    APPLY=1 \\
    bash scripts/v128-recording-status-public-ranges-router.sh
EOF
  exit 0
fi

echo
echo "===== Patch nginx: route recording_status.json to dvr-archive-proxy ====="
python3 - "$NGINX_SITE" "$ARCHIVE_PORT" <<'PY'
from pathlib import Path
import sys
import re

site = Path(sys.argv[1])
port = sys.argv[2]
if not site.exists():
    raise SystemExit(f"ERROR: nginx site not found: {site}")

text = site.read_text(encoding='utf-8', errors='ignore')

block = f'''
    # v128 NewDomofon: serve archive recording_status from dvr-archive-proxy real ranges.
    # Must be above generic /<stream>/ proxy locations.
    location ~ ^/([^/]+)/recording_status\\.json$ {{
        proxy_pass http://127.0.0.1:{port}/$1/recording_status.json$is_args$args;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_no_cache 1;
        proxy_cache_bypass 1;
        add_header Cache-Control "no-store" always;
    }}

    # v128 NewDomofon: also normalize /dvr-archive/<stream>/recording_status.json.
    location ~ ^/dvr-archive/([^/]+)/recording_status\\.json$ {{
        proxy_pass http://127.0.0.1:{port}/$1/recording_status.json$is_args$args;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_no_cache 1;
        proxy_cache_bypass 1;
        add_header Cache-Control "no-store" always;
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

def server_blocks(s):
    pat = re.compile(r'(?m)(^|\n)\s*server\s*\{')
    for m in pat.finditer(s):
        start = m.start() + (1 if s[m.start()] == '\n' else 0)
        open_pos = s.find('{', m.start(), m.end())
        end = matching_brace(s, open_pos)
        if end >= 0:
            yield start, open_pos, end + 1, s[start:end + 1]

def remove_v128_blocks(s):
    ranges = []
    loc_pat = re.compile(r'(?m)(^|\n)[ \t]*# v128 NewDomofon:[^\n]*\n[ \t]*# [^\n]*\n[ \t]*location\s+~\s+\^/(?:\(\[\^/\]\+\)|dvr-archive/\(\[\^/\]\+\))/[^\{]*\{')
    for m in loc_pat.finditer(s):
        start = m.start() + (1 if s[m.start()] == '\n' else 0)
        open_pos = s.find('{', m.start(), m.end())
        end = matching_brace(s, open_pos)
        if end >= 0:
            ranges.append((start, end + 1))
    if not ranges:
        return s
    out = []
    pos = 0
    for a,b in sorted(ranges):
        out.append(s[pos:a])
        out.append('\n')
        pos = b
    out.append(s[pos:])
    return ''.join(out)

text = remove_v128_blocks(text)

best = None
for start, open_pos, end, srv in server_blocks(text):
    score = 0
    low = srv.lower()
    if 'listen' in low and '443' in low:
        score += 100
    if 'new-video.domofon-37.ru' in low:
        score += 500
    if 'ssl' in low:
        score += 100
    if best is None or score > best[0]:
        best = (score, start, end, srv)

if not best:
    raise SystemExit('ERROR: no server block found')

_, start, end, srv = best
insert = text[:end-1] + "\n" + block + text[end-1:]
site.write_text(insert, encoding='utf-8')
print(f"patched nginx site: {site}")
PY

echo
echo "===== Syntax checks ====="
sudo nginx -t

echo
echo "===== Restart services/reload nginx ====="
if systemctl list-unit-files "$ARCHIVE_SERVICE" >/dev/null 2>&1; then
  echo "restart: $ARCHIVE_SERVICE"
  sudo systemctl restart "$ARCHIVE_SERVICE" || true
fi

echo "reload nginx"
sudo systemctl reload nginx

sleep 2

echo
echo "===== New endpoint comparison ====="
check_url "public direct" "$SITE_URL/$STREAM_NAME/recording_status.json$TOKEN_Q"
check_url "public dvr-archive" "$SITE_URL/dvr-archive/$STREAM_NAME/recording_status.json$TOKEN_Q"
check_url "local archive proxy direct" "http://127.0.0.1:$ARCHIVE_PORT/$STREAM_NAME/recording_status.json$TOKEN_Q"

cat <<EOF

installed:
  v128 public recording_status real ranges router

Expected:
  Public /$STREAM_NAME/recording_status.json should now expose the same ranges as dvr-archive-proxy.
  For your current data it should show 2 ranges:
    old archive -> 2026-06-17T10:58:12Z
    new archive from 2026-06-17T10:58:30Z onward

Browser:
  Ctrl+F5 after this patch.
  The timeline should stop treating the new archive as missing.

Rollback:
  LAST_BACKUP="\$(ls -td /opt/newdomofon-video/backups/v128-recording-status-public-ranges-router-* | head -1)"
  sudo cp "\$LAST_BACKUP$NGINX_SITE" "$NGINX_SITE"
  sudo nginx -t && sudo systemctl reload nginx
EOF
