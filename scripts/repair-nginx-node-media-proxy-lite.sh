#!/usr/bin/env bash
set -Eeuo pipefail

SITE_CONF="${SITE_CONF:-/etc/nginx/sites-enabled/newdomofon-video.conf}"
BACKUP_DIR="${BACKUP_DIR:-/var/backups/newdomofon-video/nginx}"
BACKUP="${BACKUP_DIR}/$(basename "$SITE_CONF").conservative-repair-$(date +%Y%m%d-%H%M%S).bak"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run as root" >&2
  exit 1
fi

if [[ ! -e "$SITE_CONF" ]]; then
  echo "Config not found: $SITE_CONF" >&2
  exit 2
fi

mkdir -p "$BACKUP_DIR"

# Nginx parses every file in sites-enabled. Never leave backups there.
find /etc/nginx/sites-enabled -maxdepth 1 -type f \
  \( -name '*.bak' -o -name '*.repair-*' -o -name '*before-spa-location-fix*' \) \
  -exec mv -t "$BACKUP_DIR" {} + 2>/dev/null || true

cp -aL "$SITE_CONF" "$BACKUP"

python3 - "$SITE_CONF" <<'PY'
from pathlib import Path
import re
import sys

p = Path(sys.argv[1])
s = p.read_text()

# Repair one known malformed camera SPA snippet observed on production master.
s = s.replace(
    '# Frontend camera pages like /cameras/<uuid> must fall through to the SPA.location /cameras/ {',
    '# Frontend camera pages like /cameras/<uuid> must fall through to the SPA.\n    location /cameras/ {'
)
s = re.sub(r'}\s*# BEGIN newdomofon-smartyard-origin-fix', '}\n\n    # BEGIN newdomofon-smartyard-origin-fix', s)
s = re.sub(r'}\s*location', '}\n    location', s)

start_marker = '    # BEGIN NEWDOMOFON NODE MEDIA PROXY'
end_marker = '    # END NEWDOMOFON NODE MEDIA PROXY'
if start_marker not in s or end_marker not in s:
    raise SystemExit('NEWDOMOFON NODE MEDIA PROXY block not found; refusing broad rewrite')

start = s.index(start_marker)
end = s.index(end_marker, start)
block = s[start:end]

# Only adjust CORS hiding inside the existing generated media proxy block.
# Do not rewrite unrelated SmartYard/compat locations.
block = re.sub(
    r'\n\s*proxy_hide_header Access-Control-Allow-(?:Origin|Methods|Headers|Credentials|Expose-Headers|Max-Age);',
    '',
    block,
)

hide = '''        proxy_hide_header Access-Control-Allow-Origin;
        proxy_hide_header Access-Control-Allow-Methods;
        proxy_hide_header Access-Control-Allow-Headers;
        proxy_hide_header Access-Control-Allow-Credentials;
        proxy_hide_header Access-Control-Expose-Headers;
        proxy_hide_header Access-Control-Max-Age;
'''

out = []
for line in block.splitlines(True):
    out.append(line)
    if re.match(r'\s*location\s+(?:~\s+\^/cameras/|\^~\s+/files/|\^~\s+/device-archive/)', line):
        out.append(hide)

s = s[:start] + ''.join(out) + s[end:]
p.write_text(s)
PY

if nginx -t; then
  systemctl reload nginx
  echo "OK: nginx media proxy conservative repair complete"
else
  echo "ERROR: nginx config invalid, rolling back. Backup: $BACKUP" >&2
  cp -a "$BACKUP" "$SITE_CONF"
  nginx -t || true
  exit 2
fi

echo "backup=$BACKUP"
grep -nE 'BEGIN NEWDOMOFON NODE MEDIA PROXY|location (~|\^~) /(cameras|files|device-archive)|proxy_hide_header Access-Control-Allow-Origin|proxy_pass http' "$SITE_CONF" || true
