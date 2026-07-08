#!/usr/bin/env bash
set -Eeuo pipefail

NODE_DVR_URL="${NODE_DVR_URL:-http://10.106.1.31:3010}"
SITE_CONF="${SITE_CONF:-/etc/nginx/sites-available/newdomofon-video.conf}"
BACKUP="${SITE_CONF}.lite-repair-$(date +%Y%m%d-%H%M%S).bak"

cp -a "$SITE_CONF" "$BACKUP"
python3 - "$SITE_CONF" "$NODE_DVR_URL" <<'PY'
from pathlib import Path
import re, sys
path = Path(sys.argv[1])
node = sys.argv[2].rstrip('/')
text = path.read_text()
text = re.sub(r'\n?\s*# BEGIN NEWDOMOFON NODE MEDIA PROXY\n[\s\S]*?\n\s*# END NEWDOMOFON NODE MEDIA PROXY\n?', '\n', text)

def cut_blocks(s, starts):
    for pat in starts:
        pos = 0
        out = []
        rx = re.compile(pat, re.M)
        while True:
            m = rx.search(s, pos)
            if not m:
                out.append(s[pos:]); break
            out.append(s[pos:m.start()])
            b = s.find('{', m.end()-1)
            if b < 0:
                out.append(s[m.start():m.end()]); pos = m.end(); continue
            d = 0; i = b
            while i < len(s):
                if s[i] == '{': d += 1
                elif s[i] == '}':
                    d -= 1
                    if d == 0:
                        i += 1
                        while i < len(s) and s[i] in ' \t\r\n': i += 1
                        break
                i += 1
            block = s[m.start():i]
            if '10.106.1.31' in block and 'proxy_pass http' in block:
                pos = i
            else:
                out.append(block); pos = i
        s = ''.join(out)
    return s

text = cut_blocks(text, [
    r'\n\s*location\s+(?:\^~\s+)?/cameras/[^\{]*\{',
    r'\n\s*location\s+~\s+\^/cameras/[^\{]*\{',
    r'\n\s*location\s+(?:\^~\s+)?/files/[^\{]*\{',
    r'\n\s*location\s+~\s+\^/files/[^\{]*\{',
    r'\n\s*location\s+(?:\^~\s+)?/device-archive/[^\{]*\{',
    r'\n\s*location\s+~\s+\^/device-archive/[^\{]*\{',
])

cors='''        add_header Access-Control-Allow-Origin "*" always;\n        add_header Access-Control-Allow-Methods "GET,HEAD,OPTIONS" always;\n        add_header Access-Control-Allow-Headers "authorization,content-type,range,cache-control,pragma,accept,origin,x-requested-with" always;\n        add_header Access-Control-Expose-Headers "content-length,content-range,accept-ranges,cache-control,content-type" always;\n'''
proxy=f'''        proxy_pass {node};\n        proxy_http_version 1.1;\n        proxy_set_header Host $host;\n        proxy_set_header X-Real-IP $remote_addr;\n        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;\n        proxy_set_header X-Forwarded-Proto $scheme;\n        proxy_connect_timeout 10s;\n        proxy_send_timeout 3600s;\n        proxy_read_timeout 3600s;\n        proxy_buffering off;\n'''
block=f'''    # BEGIN NEWDOMOFON NODE MEDIA PROXY\n    location ~ ^/cameras/[^/]+/(?:live\\.m3u8|archive\\.m3u8|device-archive\\.m3u8|export\\.mp4|archive/ranges|device-archive/session|device-archive/ranges)$ {{\n{cors}{proxy}    }}\n\n    location ^~ /files/ {{\n{cors}{proxy}    }}\n\n    location ^~ /device-archive/ {{\n{cors}{proxy}    }}\n    # END NEWDOMOFON NODE MEDIA PROXY\n\n'''
marker='    location /assets/ {'
if marker not in text: marker='    location / {'
text = text.replace(marker, block + marker, 1)
path.write_text(text)
PY

nginx -t
systemctl reload nginx
echo "ok backup=$BACKUP"
grep -nE 'BEGIN NEWDOMOFON NODE MEDIA PROXY|location (~|\^~) /(cameras|files|device-archive)|proxy_pass http' "$SITE_CONF" || true
