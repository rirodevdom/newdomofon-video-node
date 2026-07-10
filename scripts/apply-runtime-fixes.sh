#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="${PROJECT_DIR:-/opt/newdomofon-video-node}"
ENV_FILE="${ENV_FILE:-/etc/newdomofon-video/app.env}"
NGINX_SITE="${NGINX_SITE:-/etc/nginx/sites-available/newdomofon-video.conf}"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="$PROJECT_DIR/backups/runtime-fixes-$STAMP"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run as root: sudo PROJECT_DIR=$PROJECT_DIR bash scripts/apply-runtime-fixes.sh" >&2
  exit 1
fi

need_file() {
  if [[ ! -e "$1" ]]; then
    echo "Missing required path: $1" >&2
    exit 2
  fi
}

append_env_default() {
  local key="$1"
  local value="$2"
  if [[ ! -f "$ENV_FILE" ]] || ! grep -qE "^${key}=" "$ENV_FILE"; then
    install -d -m 0750 "$(dirname "$ENV_FILE")"
    printf '%s=%s\n' "$key" "$value" >>"$ENV_FILE"
  fi
}

install_node_deps() {
  local dir="$1"
  [[ -d "$dir" ]] || return 0
  pushd "$dir" >/dev/null
  if [[ -f package-lock.json ]]; then
    npm ci --omit=dev
  elif [[ -f package.json ]]; then
    npm install --omit=dev
  fi
  popd >/dev/null
}

prepare_runtime_dirs() {
  install -d -o newdomofon -g newdomofon -m 0755 \
    /var/lib/newdomofon-video \
    /var/cache/newdomofon-video \
    /var/cache/newdomofon-video/smartyard-preview \
    /var/log/newdomofon-video
}

write_service_units() {
  cat >/etc/systemd/system/newdomofon-public-events-proxy.service <<'UNIT'
[Unit]
Description=NewDomofon Public Events Proxy
Documentation=file:/opt/newdomofon-video-node/docs/BAREMETAL_DEBIAN12.md
After=network-online.target postgresql.service newdomofon-video-backend.service
Wants=network-online.target
Requires=postgresql.service

[Service]
Type=simple
User=newdomofon
Group=newdomofon
WorkingDirectory=/opt/newdomofon-video-node/public-events-proxy
EnvironmentFile=/etc/newdomofon-video/app.env
Environment=NODE_ENV=production
Environment=PUBLIC_EVENTS_PORT=3057
ExecStart=/usr/bin/node /opt/newdomofon-video-node/public-events-proxy/server.js
Restart=always
RestartSec=3
TimeoutStopSec=20
KillSignal=SIGTERM
SyslogIdentifier=newdomofon-public-events
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=full
ReadWritePaths=/var/log/newdomofon-video /tmp
LogsDirectory=newdomofon-video
CapabilityBoundingSet=
AmbientCapabilities=
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
UNIT

  cat >/etc/systemd/system/newdomofon-smartyard-compat.service <<'UNIT'
[Unit]
Description=NewDomofon SmartYard Compatibility Proxy
Documentation=file:/opt/newdomofon-video-node/docs/BAREMETAL_DEBIAN12.md
After=network-online.target newdomofon-video-dvr.service
Wants=network-online.target

[Service]
Type=simple
User=newdomofon
Group=newdomofon
WorkingDirectory=/opt/newdomofon-video-node/smartyard-compat-proxy
EnvironmentFile=/etc/newdomofon-video/app.env
Environment=NODE_ENV=production
Environment=SMARTYARD_COMPAT_PORT=3082
Environment=DVR_ENGINE_URL=http://127.0.0.1:3010
ExecStart=/usr/bin/node /opt/newdomofon-video-node/smartyard-compat-proxy/server.js
Restart=always
RestartSec=3
TimeoutStopSec=20
KillSignal=SIGTERM
SyslogIdentifier=newdomofon-smartyard-compat
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=full
ReadWritePaths=/var/lib/newdomofon-video /var/cache/newdomofon-video /var/log/newdomofon-video /tmp
StateDirectory=newdomofon-video
CacheDirectory=newdomofon-video
LogsDirectory=newdomofon-video
CapabilityBoundingSet=
AmbientCapabilities=
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
UNIT
}

insert_before_root_location() {
  local file="$1"
  local marker="$2"
  local block_file="$3"

  if grep -q "$marker" "$file"; then
    return 0
  fi

  local tmp
  tmp="$(mktemp)"
  awk -v block="$(cat "$block_file")" '
    BEGIN { inserted = 0 }
    /^[[:space:]]*location[[:space:]]+\/[[:space:]]*\{/ && inserted == 0 {
      print block
      inserted = 1
    }
    { print }
    END {
      if (inserted == 0) {
        print block
      }
    }
  ' "$file" >"$tmp"
  cat "$tmp" >"$file"
  rm -f "$tmp"
}

patch_nginx_site() {
  need_file "$NGINX_SITE"
  cp -a "$NGINX_SITE" "$BACKUP_DIR/$(basename "$NGINX_SITE").bak"

  local public_block smartyard_block
  public_block="$(mktemp)"
  smartyard_block="$(mktemp)"

  cat >"$public_block" <<'NGINX'
    # BEGIN newdomofon-public-events-proxy
    location ^~ /public-events/ {
        if ($request_method = OPTIONS) {
            add_header Access-Control-Allow-Origin "*" always;
            add_header Access-Control-Allow-Methods "GET,HEAD,OPTIONS" always;
            add_header Access-Control-Allow-Headers "*" always;
            add_header Access-Control-Max-Age "600" always;
            return 204;
        }

        add_header Access-Control-Allow-Origin "*" always;
        add_header Access-Control-Allow-Methods "GET,HEAD,OPTIONS" always;
        add_header Access-Control-Allow-Headers "*" always;
        add_header Access-Control-Expose-Headers "content-length,content-range,accept-ranges,cache-control,content-type,x-newdomofon-public-events" always;

        proxy_pass http://127.0.0.1:3057;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_connect_timeout 10s;
        proxy_send_timeout 3600s;
        proxy_read_timeout 3600s;
        proxy_buffering off;
    }
    # END newdomofon-public-events-proxy

NGINX

  cat >"$smartyard_block" <<'NGINX'
    # BEGIN newdomofon-smartyard-compat-route
    location ~ ^/[^/]+/(?:.*\.(?:m3u8|ts|m4s|mp4)|recording_status\.json|media_info\.json|preview\.mp4|[0-9]+-preview\.mp4)$ {
        if ($request_method = OPTIONS) {
            add_header Access-Control-Allow-Origin "*" always;
            add_header Access-Control-Allow-Methods "GET,HEAD,OPTIONS" always;
            add_header Access-Control-Allow-Headers "*" always;
            add_header Access-Control-Max-Age "600" always;
            return 204;
        }

        add_header Access-Control-Allow-Origin "*" always;
        add_header Access-Control-Allow-Methods "GET,HEAD,OPTIONS" always;
        add_header Access-Control-Allow-Headers "*" always;
        add_header Access-Control-Expose-Headers "content-length,content-range,accept-ranges,cache-control,content-type,x-newdomofon-resolved-stream,x-newdomofon-smartyard-compat" always;

        proxy_pass http://127.0.0.1:3082;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_connect_timeout 10s;
        proxy_send_timeout 3600s;
        proxy_read_timeout 3600s;
        proxy_buffering off;
    }
    # END newdomofon-smartyard-compat-route

NGINX

  insert_before_root_location "$NGINX_SITE" "127.0.0.1:3057" "$public_block"
  insert_before_root_location "$NGINX_SITE" "127.0.0.1:3082" "$smartyard_block"
  rm -f "$public_block" "$smartyard_block"
}

wait_for_http() {
  local name="$1"
  local url="$2"
  local deadline=$((SECONDS + 15))

  until curl -fsS -m 2 "$url" >/dev/null 2>&1; do
    if (( SECONDS >= deadline )); then
      echo "WARN: $name is not ready yet: $url" >&2
      return 1
    fi
    sleep 0.5
  done
}

smoke() {
  local name="$1"
  local url="$2"
  echo
  echo "== $name =="
  curl -fsS -m 5 -i "$url" | sed -n '1,20p' || true
}

need_file "$PROJECT_DIR/public-events-proxy/server.js"
need_file "$PROJECT_DIR/smartyard-compat-proxy/server.js"
need_file "$ENV_FILE"
install -d -m 0750 "$BACKUP_DIR"

append_env_default PUBLIC_EVENTS_PORT 3057
append_env_default SMARTYARD_COMPAT_PORT 3082
append_env_default DVR_ENGINE_URL http://127.0.0.1:3010

node --check "$PROJECT_DIR/public-events-proxy/server.js"
node --check "$PROJECT_DIR/smartyard-compat-proxy/server.js"

install_node_deps "$PROJECT_DIR/public-events-proxy"
prepare_runtime_dirs

write_service_units
patch_nginx_site

systemctl daemon-reload
systemctl enable --now newdomofon-public-events-proxy.service
systemctl enable --now newdomofon-smartyard-compat.service
systemctl restart newdomofon-public-events-proxy.service
systemctl restart newdomofon-smartyard-compat.service

nginx -t
systemctl reload nginx

wait_for_http "backend" "http://127.0.0.1:3000/api/health" || true
wait_for_http "dvr-engine" "http://127.0.0.1:3010/health" || true
wait_for_http "public-events-proxy" "http://127.0.0.1:3057/health" || true
wait_for_http "smartyard-compat" "http://127.0.0.1:3082/health" || true

smoke "backend" "http://127.0.0.1:3000/api/health"
smoke "dvr-engine" "http://127.0.0.1:3010/health"
smoke "public-events-proxy" "http://127.0.0.1:3057/health"
smoke "smartyard-compat" "http://127.0.0.1:3082/health"

if [[ -n "${TEST_STREAM:-}" && -n "${TEST_TOKEN:-}" ]]; then
  smoke "smartyard live playlist" "http://127.0.0.1:3082/${TEST_STREAM}/index.m3u8?token=${TEST_TOKEN}"
  smoke "public events" "http://127.0.0.1:3057/public-events/${TEST_STREAM}/events?limit=1&token=${TEST_TOKEN}"
fi

echo
echo "Runtime fixes applied. Backup: $BACKUP_DIR"
