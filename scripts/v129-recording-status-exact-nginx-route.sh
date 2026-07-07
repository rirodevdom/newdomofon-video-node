#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="${PROJECT_DIR:-/opt/newdomofon-video}"
SITE_URL="${SITE_URL:-https://new-video.domofon-37.ru}"
STREAM_NAME="${STREAM_NAME:-cam_10_130_1_219}"
TOKEN="${TOKEN:-}"
APPLY="${APPLY:-0}"
ARCHIVE_SERVICE="${ARCHIVE_SERVICE:-newdomofon-dvr-archive-proxy.service}"
BACKUP_DIR="$PROJECT_DIR/backups/v129-recording-status-exact-nginx-route-$(date +%Y%m%d-%H%M%S)"

echo "===== v129 recording_status exact nginx route ====="
echo "project:  $PROJECT_DIR"
echo "site:     $SITE_URL"
echo "stream:   $STREAM_NAME"
echo "apply:    $APPLY"
echo "backup:   $BACKUP_DIR"

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

if [ "${#ACTIVE_REAL_FILES[@]}" -eq 0 ]; then
  echo "ERROR: no active nginx files found"
  exit 1
fi

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

echo
echo "===== Current endpoint comparison ====="
check_url() {
  local label="$1"
  local url="$2"
  echo "--- $label"
  echo "$url"
  curl -sS -k --max-time 15 -D "$BACKUP_DIR/headers-$(echo "$label" | sed 's#[^A-Za-z0-9_.-]#_#g').txt" "$url" \
    | tee "$BACKUP_DIR/body-$(echo "$label" | sed 's#[^A-Za-z0-9_.-]#_#g').json" \
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
  grep -i '^x-nd-recording-status-source:' "$BACKUP_DIR/headers-$(echo "$label" | sed 's#[^A-Za-z0-9_.-]#_#g').txt" 2>/dev/null || true
  echo
}

check_url "public-direct-before" "$SITE_URL/$STREAM_NAME/recording_status.json$TOKEN_Q"
check_url "public-dvr-archive-before" "$SITE_URL/dvr-archive/$STREAM_NAME/recording_status.json$TOKEN_Q"
check_url "local-archive-before" "http://127.0.0.1:$ARCHIVE_PORT/$STREAM_NAME/recording_status.json$TOKEN_Q"

echo
echo "===== Validate local archive proxy has real v127 ranges ====="
LOCAL_RANGES_COUNT="$(curl -sS -k --max-time 15 "http://127.0.0.1:$ARCHIVE_PORT/$STREAM_NAME/recording_status.json$TOKEN_Q" | jq 'if type=="array" then .[0] else . end | (.ranges|length)' 2>/dev/null || echo 0)"
LOCAL_VERSION="$(curl -sS -k --max-time 15 "http://127.0.0.1:$ARCHIVE_PORT/$STREAM_NAME/recording_status.json$TOKEN_Q" | jq -r 'if type=="array" then .[0] else . end | (.version // "")' 2>/dev/null || true)"
echo "local_version:      $LOCAL_VERSION"
echo "local_ranges_count: $LOCAL_RANGES_COUNT"

if [ "${LOCAL_RANGES_COUNT:-0}" -lt 2 ]; then
  echo "ERROR: local dvr-archive-proxy does not show at least 2 ranges."
  echo "Run/fix v127 first before v129."
  exit 1
fi

if [ "$APPLY" != "1" ]; then
  cat <<EOF

DRY-RUN only. Nothing changed.

Why v128 did not win:
  v128 inserted regex locations. Your active nginx config still routes recording_status through SmartYard.
  v129 inserts exact locations for this stream into every active server block.
  Exact locations have higher priority and stop location search.

To apply:
  sudo PROJECT_DIR=$PROJECT_DIR \\
    SITE_URL=$SITE_URL \\
    STREAM_NAME=$STREAM_NAME \\
    TOKEN='...' \\
    APPLY=1 \\
    bash scripts/v129-recording-status-exact-nginx-route.sh
EOF
  exit 0
fi

echo
echo "===== Patch nginx: exact locations for this stream in ALL active server blocks ====="
python3 - "$STREAM_NAME" "$ARCHIVE_PORT" "${ACTIVE_REAL_FILES[@]}" <<'PY'
from pathlib import Path
import sys
import re

stream = sys.argv[1]
port = sys.argv[2]
paths = [Path(x) for x in sys.argv[3:]]

exact_block = f'''
    # v129 NewDomofon: exact route for {stream} recording_status real ranges.
    location = /{stream}/recording_status.json {{
        proxy_pass http://127.0.0.1:{port}/{stream}/recording_status.json$is_args$args;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_no_cache 1;
        proxy_cache_bypass 1;
        add_header Cache-Control "no-store" always;
        add_header X-ND-Recording-Status-Source "v129-exact-dvr-archive-proxy" always;
    }}

    # v129 NewDomofon: exact route for dvr-archive/{stream} recording_status real ranges.
    location = /dvr-archive/{stream}/recording_status.json {{
        proxy_pass http://127.0.0.1:{port}/{stream}/recording_status.json$is_args$args;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_no_cache 1;
        proxy_cache_bypass 1;
        add_header Cache-Control "no-store" always;
        add_header X-ND-Recording-Status-Source "v129-exact-dvr-archive-proxy" always;
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
            out.append((start, open_pos, end + 1, s[start:end+1]))
    return out

def remove_old_v129(s: str):
    markers = [
        f'# v129 NewDomofon: exact route for {stream} recording_status real ranges.',
        f'# v129 NewDomofon: exact route for dvr-archive/{stream} recording_status real ranges.',
    ]
    ranges = []
    for marker in markers:
        pos = 0
        while True:
            idx = s.find(marker, pos)
            if idx < 0:
                break
            # include indentation before marker line
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
    for a,b in sorted(ranges):
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
    s = remove_old_v129(s)
    blocks = find_server_blocks(s)
    if not blocks:
        print(f'no server block: {p}')
        continue

    # Insert into every server block in this active file so both Host: domain and Host: IP/default_server are covered.
    inserts = []
    for start, open_pos, end, block in blocks:
        low = block.lower()
        if 'listen' not in low:
            continue
        inserts.append(end - 1)

    if not inserts:
        print(f'no listen server block: {p}')
        continue

    for pos in sorted(inserts, reverse=True):
        s = s[:pos] + '\n' + exact_block + s[pos:]

    p.write_text(s, encoding='utf-8')
    patched_files += 1
    patched_servers += len(inserts)
    print(f'patched: {p} server_blocks={len(inserts)}')

print(f'total patched files={patched_files} server_blocks={patched_servers}')
if patched_servers < 1:
    raise SystemExit('ERROR: no server blocks patched')
PY

echo
echo "===== nginx config proof ====="
sudo nginx -T 2>/tmp/v129-nginx-t.err | grep -n "v129 NewDomofon\|X-ND-Recording-Status-Source\|location = /$STREAM_NAME/recording_status" | head -80 || true
cat /tmp/v129-nginx-t.err || true

echo
echo "===== Syntax checks ====="
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
check_url "public-direct-after" "$SITE_URL/$STREAM_NAME/recording_status.json$TOKEN_Q"
check_url "public-dvr-archive-after" "$SITE_URL/dvr-archive/$STREAM_NAME/recording_status.json$TOKEN_Q"
check_url "local-archive-after" "http://127.0.0.1:$ARCHIVE_PORT/$STREAM_NAME/recording_status.json$TOKEN_Q"

echo
echo "===== Final assertion ====="
PUBLIC_RANGES_COUNT="$(curl -sS -k --max-time 15 "$SITE_URL/$STREAM_NAME/recording_status.json$TOKEN_Q" | jq 'if type=="array" then .[0] else . end | (.ranges|length)' 2>/dev/null || echo 0)"
PUBLIC_SOURCE_HEADER="$(curl -sS -k --max-time 15 -D - -o /dev/null "$SITE_URL/$STREAM_NAME/recording_status.json$TOKEN_Q" | tr -d '\r' | awk 'BEGIN{IGNORECASE=1} /^x-nd-recording-status-source:/ {print $0}' | tail -1 || true)"
echo "public_ranges_count: $PUBLIC_RANGES_COUNT"
echo "public_source_header: ${PUBLIC_SOURCE_HEADER:-<none>}"

if [ "${PUBLIC_RANGES_COUNT:-0}" -lt 2 ]; then
  echo "ERROR: public endpoint still does not expose real ranges."
  echo "Most likely another nginx server block/file is serving the request or a front proxy is in front."
  echo
  echo "Send this output:"
  echo "  sudo nginx -T | grep -n \"recording_status\\|server_name\\|listen\\|proxy_pass\" | head -250"
  echo "  curl -k -sS -D - -o /tmp/rs.json '$SITE_URL/$STREAM_NAME/recording_status.json$TOKEN_Q'; cat /tmp/rs.json | jq ."
  exit 2
fi

cat <<EOF

installed:
  v129 exact nginx route for $STREAM_NAME recording_status

Expected:
  public /$STREAM_NAME/recording_status.json now returns version v127 and ranges_count >= 2.

Browser:
  Ctrl+F5.
  Ignore moz-extension / contentscript / MetaMask messages during player debugging.

Rollback:
  LAST_BACKUP="\$(ls -td /opt/newdomofon-video/backups/v129-recording-status-exact-nginx-route-* | head -1)"
  sudo cp -a "\$LAST_BACKUP/etc/nginx/." /etc/nginx/
  sudo nginx -t && sudo systemctl reload nginx
EOF
