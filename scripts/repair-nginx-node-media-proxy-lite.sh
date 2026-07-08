#!/usr/bin/env bash
set -Eeuo pipefail

NODE_DVR_URL="${NODE_DVR_URL:-http://10.106.1.31:3010}"
SITE_CONF="${SITE_CONF:-/etc/nginx/sites-enabled/newdomofon-video.conf}"
BACKUP="${SITE_CONF}.repair-$(date +%Y%m%d-%H%M%S).bak"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run as root" >&2
  exit 1
fi

if [[ ! -e "$SITE_CONF" ]]; then
  echo "Config not found: $SITE_CONF" >&2
  exit 2
fi

cp -aL "$SITE_CONF" "$BACKUP"

python3 - "$SITE_CONF" "$NODE_DVR_URL" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
node_url = sys.argv[2].rstrip('/')
text = path.read_text()

# Fix malformed snippets left by older nginx camera-route patch attempts.
# Example observed on production master:
#   # Frontend camera pages like /cameras/<uuid> must fall through to the SPA.location /cameras/ {
#       try_files $uri $uri/ /index.html;
#   }# BEGIN newdomofon-smartyard-origin-fix
text = text.replace(
    '# Frontend camera pages like /cameras/<uuid> must fall through to the SPA.location /cameras/ {',
    '# Frontend camera pages like /cameras/<uuid> must fall through to the SPA.\n    location /cameras/ {'
)
text = re.sub(r'}\s*# BEGIN newdomofon-smartyard-origin-fix', '}\n\n    # BEGIN newdomofon-smartyard-origin-fix', text)

# Normalize malformed adjacency created by previous repair attempts.
text = re.sub(r'}\s*location', '}\n    location', text)

# Remove all marked generated media proxy blocks first.
text = re.sub(
    r'\n?\s*# BEGIN NEWDOMOFON NODE MEDIA PROXY\n[\s\S]*?\n\s*# END NEWDOMOFON NODE MEDIA PROXY\n?',
    '\n',
    text,
)

# Remove every explicit media location block we created in previous attempts.
# Keep `location /cameras/ { try_files ... }` for SPA camera pages.
location_start = re.compile(
    r'\n\s*location\s+(?:\^~\s+|~\s+)?(?:\^)?/(?:files|device-archive)(?:/|[^\{]*)\{'
    r'|\n\s*location\s+~\s+\^/cameras/[^\{]*\{',
    re.M,
)

def find_block_end(src: str, brace_pos: int) -> int:
    if brace_pos < 0:
        return -1
    depth = 0
    i = brace_pos
    while i < len(src):
        ch = src[i]
        if ch == '{':
            depth += 1
        elif ch == '}':
            depth -= 1
            if depth == 0:
                i += 1
                while i < len(src) and src[i] in ' \t\r\n':
                    i += 1
                return i
        i += 1
    return len(src)

out = []
pos = 0
while True:
    m = location_start.search(text, pos)
    if not m:
        out.append(text[pos:])
        break
    out.append(text[pos:m.start()])
    brace = text.find('{', m.end() - 1)
    end = find_block_end(text, brace)
    pos = end if end >= 0 else m.end()
text = ''.join(out)
text = re.sub(r'\n{4,}', '\n\n\n', text)

cors = '''        if ($request_method = OPTIONS) {
            add_header Access-Control-Allow-Origin "*" always;
            add_header Access-Control-Allow-Methods "GET,HEAD,OPTIONS" always;
            add_header Access-Control-Allow-Headers "authorization,content-type,range,cache-control,pragma,accept,origin,x-requested-with" always;
            add_header Access-Control-Max-Age "600" always;
            return 204;
        }

        add_header Access-Control-Allow-Origin "*" always;
        add_header Access-Control-Allow-Methods "GET,HEAD,OPTIONS" always;
        add_header Access-Control-Allow-Headers "authorization,content-type,range,cache-control,pragma,accept,origin,x-requested-with" always;
        add_header Access-Control-Expose-Headers "content-length,content-range,accept-ranges,cache-control,content-type" always;
'''

proxy = f'''        proxy_pass {node_url};
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_connect_timeout 10s;
        proxy_send_timeout 3600s;
        proxy_read_timeout 3600s;
        proxy_buffering off;
'''

block = f'''    # BEGIN NEWDOMOFON NODE MEDIA PROXY
    location ~ ^/cameras/[^/]+/(?:live\.m3u8|archive\.m3u8|device-archive\.m3u8|export\.mp4|archive/ranges|device-archive/session|device-archive/ranges)$ {{
{cors}{proxy}    }}

    location ^~ /files/ {{
{cors}{proxy}    }}

    location ^~ /device-archive/ {{
{cors}{proxy}    }}
    # END NEWDOMOFON NODE MEDIA PROXY

'''

marker = '    location /assets/ {'
if marker not in text:
    marker = '    location / {'
if marker not in text:
    raise SystemExit('Cannot find nginx insertion point')
text = text.replace(marker, block + marker, 1)

path.write_text(text)
PY

if nginx -t; then
  systemctl reload nginx
  echo "OK: nginx media proxy repaired"
else
  echo "ERROR: nginx config still invalid, rolling back. Backup: $BACKUP" >&2
  cp -a "$BACKUP" "$SITE_CONF"
  nginx -t || true
  exit 2
fi

echo "backup=$BACKUP"
grep -nE 'BEGIN NEWDOMOFON NODE MEDIA PROXY|location (~|\^~) /(cameras|files|device-archive)|proxy_pass http' "$SITE_CONF" || true
