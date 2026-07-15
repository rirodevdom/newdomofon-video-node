#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

PROJECT_DIR="${PROJECT_DIR:-/opt/newdomofon-video-node}"
ENV_FILE="${ENV_FILE:-/etc/newdomofon-video/app.env}"
REGISTRATION_FILE="${REGISTRATION_FILE:-/root/newdomofon-node-master-registration.env}"
INSTALL_DISK_GUARD="${INSTALL_DISK_GUARD:-1}"
INSTALL_JOURNAL_LIMITS="${INSTALL_JOURNAL_LIMITS:-1}"
INSTALL_ARCHIVE_EVENT_SYNC="${INSTALL_ARCHIVE_EVENT_SYNC:-1}"

MASTER_URL="${MASTER_URL:-}"
NODE_ID="${NODE_ID:-}"
NODE_TOKEN="${NODE_TOKEN:-}"
NODE_MEDIA_SECRET="${NODE_MEDIA_SECRET:-}"
NODE_PUBLIC_BASE_URL="${NODE_PUBLIC_BASE_URL:-}"
NODE_INTERNAL_URL="${NODE_INTERNAL_URL:-}"
NON_INTERACTIVE=false

usage() {
  cat <<'EOF'
NewDomofon Video Node deployment with operator-defined credentials

The node ID, agent token and media secret are chosen during node deployment.
The master does not have to exist or be online yet. After deployment, create a
matching node record on master and enter exactly the same values.

Usage:
  sudo bash scripts/deploy-node.sh [options]

Options:
  --master-url URL          DVR_MASTER_URL that this node will use later
  --node-id UUID            operator-defined DVR_NODE_ID
  --node-token TOKEN        operator-defined DVR_NODE_TOKEN
  --media-secret SECRET     operator-defined DVR_NODE_MEDIA_SECRET
  --public-url URL          DVR_NODE_PUBLIC_BASE_URL
  --internal-url URL        DVR_NODE_INTERNAL_URL
  --registration-file PATH  root-only file for values copied into master
  --non-interactive         fail instead of prompting for missing values
  -h, --help                show this help

Example:
  sudo bash scripts/deploy-node.sh \
    --master-url https://new-video.domofon-37.ru \
    --node-id 11111111-2222-4333-8444-555555555555 \
    --node-token NODE_TOKEN_CHOSEN_BY_OPERATOR_32 \
    --media-secret MEDIA_SECRET_CHOSEN_BY_OPERATOR_32 \
    --public-url http://10.106.1.31 \
    --internal-url http://10.106.1.31:3010

Generate suitable values manually when needed:
  uuidgen
  openssl rand -hex 32
  openssl rand -hex 32
EOF
}

while (($#)); do
  case "$1" in
    --master-url) MASTER_URL="${2:-}"; shift 2 ;;
    --node-id) NODE_ID="${2:-}"; shift 2 ;;
    --node-token) NODE_TOKEN="${2:-}"; shift 2 ;;
    --media-secret) NODE_MEDIA_SECRET="${2:-}"; shift 2 ;;
    --public-url) NODE_PUBLIC_BASE_URL="${2:-}"; shift 2 ;;
    --internal-url) NODE_INTERNAL_URL="${2:-}"; shift 2 ;;
    --registration-file) REGISTRATION_FILE="${2:-}"; shift 2 ;;
    --non-interactive) NON_INTERACTIVE=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 64 ;;
  esac
done

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

env_value() {
  local key="$1"
  [[ -r "$ENV_FILE" ]] || return 0
  sed -n "s/^${key}=//p" "$ENV_FILE" | tail -1
}

set_env_value() {
  local key="$1"
  local value="$2"
  python3 - "$ENV_FILE" "$key" "$value" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
key = sys.argv[2]
value = sys.argv[3]
lines = path.read_text(encoding="utf-8").splitlines() if path.exists() else []
out = []
written = False
for line in lines:
    if line.startswith(key + "="):
        if not written:
            out.append(f"{key}={value}")
            written = True
    else:
        out.append(line)
if not written:
    out.append(f"{key}={value}")
path.write_text("\n".join(out) + "\n", encoding="utf-8")
PY
}

validate_url() {
  python3 - "$1" <<'PY'
import sys
from urllib.parse import urlparse

value = sys.argv[1].strip()
parsed = urlparse(value)
if parsed.scheme not in {"http", "https"} or not parsed.hostname:
    raise SystemExit(1)
if parsed.username or parsed.password or "\n" in value or "\r" in value:
    raise SystemExit(1)
PY
}

validate_node_id() {
  python3 - "$1" <<'PY'
import sys
import uuid
uuid.UUID(sys.argv[1].strip())
PY
}

valid_secret() {
  local value="$1"
  [[ ${#value} -ge 16 && ${#value} -le 512 && "$value" =~ ^[A-Za-z0-9._~-]+$ ]]
}

prompt_value() {
  local variable_name="$1"
  local prompt="$2"
  local secret="${3:-false}"
  local current="${!variable_name}"
  [[ -n "$current" ]] && return 0
  if [[ "$NON_INTERACTIVE" == true || ! -t 0 ]]; then
    fail "$variable_name is required"
  fi
  if [[ "$secret" == true ]]; then
    read -r -s -p "$prompt: " current
    echo
  else
    read -r -p "$prompt: " current
  fi
  printf -v "$variable_name" '%s' "$current"
}

[[ "$(id -u)" -eq 0 ]] || fail "Run this script as root"
for command in python3 npm rsync nginx systemctl; do
  command -v "$command" >/dev/null || fail "$command is required"
done
[[ -d "$PROJECT_DIR/dvr-engine" ]] || fail "DVR source is missing: $PROJECT_DIR/dvr-engine"

install -d -m 0750 "$(dirname "$ENV_FILE")"
if [[ ! -f "$ENV_FILE" ]]; then
  cp "$PROJECT_DIR/deploy/env/node.env.example" "$ENV_FILE"
fi

[[ -n "$MASTER_URL" ]] || MASTER_URL="$(env_value DVR_MASTER_URL)"
[[ -n "$NODE_ID" ]] || NODE_ID="$(env_value DVR_NODE_ID)"
[[ -n "$NODE_TOKEN" ]] || NODE_TOKEN="$(env_value DVR_NODE_TOKEN)"
[[ -n "$NODE_MEDIA_SECRET" ]] || NODE_MEDIA_SECRET="$(env_value DVR_NODE_MEDIA_SECRET)"
[[ -n "$NODE_PUBLIC_BASE_URL" ]] || NODE_PUBLIC_BASE_URL="$(env_value DVR_NODE_PUBLIC_BASE_URL)"
[[ -n "$NODE_INTERNAL_URL" ]] || NODE_INTERNAL_URL="$(env_value DVR_NODE_INTERNAL_URL)"

case "$NODE_ID" in PASTE_*|CHANGE_*|YOUR_* ) NODE_ID="" ;; esac
case "$NODE_TOKEN" in PASTE_*|CHANGE_*|YOUR_* ) NODE_TOKEN="" ;; esac
case "$NODE_MEDIA_SECRET" in PASTE_*|CHANGE_*|YOUR_* ) NODE_MEDIA_SECRET="" ;; esac
case "$MASTER_URL" in *example.com* ) MASTER_URL="" ;; esac
case "$NODE_PUBLIC_BASE_URL" in *example.com* ) NODE_PUBLIC_BASE_URL="" ;; esac

prompt_value MASTER_URL "DVR_MASTER_URL to use when master becomes available"
prompt_value NODE_ID "Choose DVR_NODE_ID (UUID)"
prompt_value NODE_TOKEN "Choose DVR_NODE_TOKEN" true
prompt_value NODE_MEDIA_SECRET "Choose DVR_NODE_MEDIA_SECRET" true
prompt_value NODE_PUBLIC_BASE_URL "DVR_NODE_PUBLIC_BASE_URL"

if [[ -z "$NODE_INTERNAL_URL" ]]; then
  if [[ "$NON_INTERACTIVE" == true || ! -t 0 ]]; then
    fail "NODE_INTERNAL_URL is required"
  fi
  read -r -p "DVR_NODE_INTERNAL_URL [http://127.0.0.1:3010]: " NODE_INTERNAL_URL
  NODE_INTERNAL_URL="${NODE_INTERNAL_URL:-http://127.0.0.1:3010}"
fi

MASTER_URL="${MASTER_URL%/}"
NODE_PUBLIC_BASE_URL="${NODE_PUBLIC_BASE_URL%/}"
NODE_INTERNAL_URL="${NODE_INTERNAL_URL%/}"

validate_url "$MASTER_URL" || fail "Invalid DVR_MASTER_URL"
validate_url "$NODE_PUBLIC_BASE_URL" || fail "Invalid DVR_NODE_PUBLIC_BASE_URL"
validate_url "$NODE_INTERNAL_URL" || fail "Invalid DVR_NODE_INTERNAL_URL"
validate_node_id "$NODE_ID" || fail "DVR_NODE_ID must be a UUID"
valid_secret "$NODE_TOKEN" || fail "DVR_NODE_TOKEN must contain 16-512 safe characters: letters, digits, dot, underscore, tilde or hyphen"
valid_secret "$NODE_MEDIA_SECRET" || fail "DVR_NODE_MEDIA_SECRET must contain 16-512 safe characters: letters, digits, dot, underscore, tilde or hyphen"
[[ -n "$REGISTRATION_FILE" && "$REGISTRATION_FILE" = /* ]] || fail "REGISTRATION_FILE must be an absolute path"

set_env_value NODE_ENV production
set_env_value DVR_ENGINE_ROLE node
set_env_value DVR_MASTER_URL "$MASTER_URL"
set_env_value DVR_NODE_ID "$NODE_ID"
set_env_value DVR_NODE_TOKEN "$NODE_TOKEN"
set_env_value DVR_NODE_MEDIA_SECRET "$NODE_MEDIA_SECRET"
set_env_value DVR_NODE_PUBLIC_BASE_URL "$NODE_PUBLIC_BASE_URL"
set_env_value DVR_NODE_INTERNAL_URL "$NODE_INTERNAL_URL"
set_env_value DVR_REQUIRE_MEDIA_TOKEN true
set_env_value DVR_CORS_ORIGIN "$MASTER_URL"

if id newdomofon >/dev/null 2>&1; then
  chown root:newdomofon "$ENV_FILE"
  chmod 0640 "$ENV_FILE"
else
  chown root:root "$ENV_FILE"
  chmod 0600 "$ENV_FILE"
fi

install -d -m 0700 "$(dirname "$REGISTRATION_FILE")"
cat >"$REGISTRATION_FILE" <<EOF
# Copy these exact values into Administration -> Nodes -> Create node on master.
DVR_MASTER_URL=${MASTER_URL}
DVR_NODE_ID=${NODE_ID}
DVR_NODE_TOKEN=${NODE_TOKEN}
DVR_NODE_MEDIA_SECRET=${NODE_MEDIA_SECRET}
DVR_NODE_PUBLIC_BASE_URL=${NODE_PUBLIC_BASE_URL}
DVR_NODE_INTERNAL_URL=${NODE_INTERNAL_URL}
EOF
chown root:root "$REGISTRATION_FILE"
chmod 0600 "$REGISTRATION_FILE"

if [[ "$INSTALL_DISK_GUARD" =~ ^(1|true|yes|on)$ ]]; then
  NEWDOMOFON_ENV_FILE="$ENV_FILE" bash "$PROJECT_DIR/scripts/node-system-disk-check.sh" || true
  if [[ ! -e /run/newdomofon-video/node-disk-paused ]]; then
    NEWDOMOFON_ENV_FILE="$ENV_FILE" bash "$PROJECT_DIR/scripts/node-disk-guard.sh"
  fi
  if [[ -e /run/newdomofon-video/node-disk-paused ]]; then
    echo "Deployment aborted: node disk guard is critical." >&2
    cat /run/newdomofon-video/node-disk-state.json >&2 2>/dev/null || true
    exit 75
  fi
fi

cd "$PROJECT_DIR/dvr-engine"
(
  # app.env and command-line secrets remain protected by the outer umask 077,
  # but runtime packages must be readable by the systemd user newdomofon.
  umask 022
  npm ci --include=dev
  npm run build
  npm ci --omit=dev
)

[[ -r node_modules/express/index.js ]] || fail "Production dependency express is missing after npm ci --omit=dev"
node -e "import('express').then(() => console.log('Runtime dependency check: express OK'))"

if id newdomofon >/dev/null 2>&1; then
  chown -R root:newdomofon node_modules dist
  chmod -R g+rX,o-rwx node_modules dist
fi

install -d -o newdomofon -g newdomofon /var/lib/newdomofon-video/dvr /var/lib/newdomofon-video/events /var/log/newdomofon-video
cp "$PROJECT_DIR/deploy/systemd/newdomofon-video-dvr.service" /etc/systemd/system/
cp "$PROJECT_DIR/deploy/nginx/newdomofon-video-node.conf" /etc/nginx/sites-available/newdomofon-video-node.conf
ln -sf /etc/nginx/sites-available/newdomofon-video-node.conf /etc/nginx/sites-enabled/newdomofon-video-node.conf

systemctl daemon-reload
systemctl enable newdomofon-video-dvr

if [[ "$INSTALL_DISK_GUARD" =~ ^(1|true|yes|on)$ ]]; then
  PROJECT_DIR="$PROJECT_DIR" INSTALL_JOURNAL_LIMITS="$INSTALL_JOURNAL_LIMITS" \
    bash "$PROJECT_DIR/scripts/install-node-disk-guard.sh"
fi

if [[ "$INSTALL_ARCHIVE_EVENT_SYNC" =~ ^(1|true|yes|on)$ ]]; then
  PROJECT_DIR="$PROJECT_DIR" \
    bash "$PROJECT_DIR/scripts/install-archive-event-sync.sh"
fi

if [[ ! -e /run/newdomofon-video/node-disk-paused ]]; then
  systemctl restart newdomofon-video-dvr
else
  echo "DVR remains stopped because disk guard is critical." >&2
fi

nginx -t
systemctl reload nginx

for _ in $(seq 1 30); do
  if curl -fsS --max-time 2 http://127.0.0.1:3010/health >/tmp/newdomofon-node-health.json 2>/dev/null; then
    break
  fi
  sleep 1
done

curl -fsS --max-time 3 http://127.0.0.1:3010/health || fail "Local DVR health check failed"
echo

echo "Node deployed with operator-defined credentials."
echo "Master availability and an existing master node record were not required during deployment."
echo "Create the matching node record on master later using the exact values in:"
echo "  $REGISTRATION_FILE"
echo "The node will start heartbeat/config polling automatically when the matching master record exists."
echo "Environment: $ENV_FILE"
echo "Local health: http://127.0.0.1:3010/health"
if [[ "$INSTALL_DISK_GUARD" =~ ^(1|true|yes|on)$ ]]; then
  echo "Disk guard: cat /run/newdomofon-video/node-disk-state.json"
fi
if [[ "$INSTALL_ARCHIVE_EVENT_SYNC" =~ ^(1|true|yes|on)$ ]]; then
  echo "Archive/event sync: cat /var/lib/newdomofon-video/events/archive-event-sync-state.json"
fi
