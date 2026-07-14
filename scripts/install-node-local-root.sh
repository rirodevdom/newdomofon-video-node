#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

INSTALLER_VERSION="2026.07-node-local-root-v1"

SOURCE_DIR="${SOURCE_DIR:-}"
PROJECT_DIR="${PROJECT_DIR:-/opt/newdomofon-video-node}"
ENV_FILE="${ENV_FILE:-/etc/newdomofon-video/app.env}"
MASTER_URL="${MASTER_URL:-}"
MASTER_ACCESS_IP="${MASTER_ACCESS_IP:-}"
NODE_ID="${NODE_ID:-}"
NODE_TOKEN="${NODE_TOKEN:-}"
NODE_MEDIA_SECRET="${NODE_MEDIA_SECRET:-}"
NODE_HOST="${NODE_HOST:-}"
NODE_INTERNAL_URL="${NODE_INTERNAL_URL:-}"
NODE_PUBLIC_BASE_URL="${NODE_PUBLIC_BASE_URL:-}"
NODE_PUBLIC_DOMAIN="${NODE_PUBLIC_DOMAIN:-}"
CERTBOT_EMAIL="${CERTBOT_EMAIL:-}"
DVR_ROOT="${DVR_ROOT:-}"
BOOTSTRAP_JSON="${BOOTSTRAP_JSON:-}"
TIMEZONE="${TIMEZONE:-Europe/Moscow}"
TLS_MODE="${TLS_MODE:-auto}"
REQUIRE_MOUNTPOINT="${REQUIRE_MOUNTPOINT:-}"
ARCHIVE_EVENT_SYNC_APPLY="${ARCHIVE_EVENT_SYNC_APPLY:-}"
REGENERATE_LOCAL_CONFIG="${REGENERATE_LOCAL_CONFIG:-false}"

STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="${BACKUP_DIR:-/opt/newdomofon-video-migration-backups/local-root-node-${STAMP}}"
LOG_FILE="${LOG_FILE:-/root/newdomofon-node-local-root-${STAMP}.log}"
SUMMARY_FILE="${SUMMARY_FILE:-/root/newdomofon-node-access.txt}"
JSON_FILE="${JSON_FILE:-/root/newdomofon-node-access.json}"
CURRENT_STEP="initialization"
OLD_PROJECT_BACKUP=""

usage() {
  cat <<'EOF'
NewDomofon Video Node local root installer

Usage:
  bash scripts/install-node-local-root.sh [options]

The extracted project must be inside /root. No git commands are used.
No custom Linux users are created. NewDomofon node services run as root.
Nginx keeps its standard Debian package worker account.

Required node credentials can be entered interactively, provided through options,
or read from a bootstrap JSON file with node_id, agent_token and media_secret.

Options:
  --source-dir PATH              Extracted node project directory.
  --master-url URL               Master base URL, for example https://video.example.ru.
  --master-ip IP                 Source IP allowed to reach private port 3010.
  --node-id UUID                 Node ID issued by master.
  --node-token TOKEN             Node agent token issued by master.
  --media-secret SECRET          Node media secret issued by master.
  --bootstrap-json PATH          JSON file containing node credentials.
  --node-host HOST_OR_IP         Private node IP/hostname.
  --internal-url URL             URL master uses to reach DVR engine.
  --public-url URL               Public/base URL stored for this node.
  --node-domain DOMAIN           Optional Nginx/TLS domain for this node.
  --email EMAIL                  Let's Encrypt contact email.
  --dvr-root PATH                Archive root. Default /var/lib/newdomofon-video/dvr.
  --require-mountpoint           Require DVR_ROOT to be a dedicated mountpoint.
  --allow-root-filesystem        Allow DVR_ROOT on the operating-system filesystem.
  --archive-event-sync-apply     Enable automatic orphan-event deletion.
  --archive-event-sync-dry-run   Keep archive/event sync in dry-run mode.
  --no-tls                       Do not request a node certificate.
  --tls                          Attempt/request a certificate for --node-domain.
  --regenerate-local-config      Replace local non-master settings with defaults.
  -h, --help                     Show this help.

Examples:
  cd /root/newdomofon-video-node-main
  bash scripts/install-node-local-root.sh

  bash /root/newdomofon-video-node-main/scripts/install-node-local-root.sh \
    --source-dir /root/newdomofon-video-node-main \
    --master-url https://new-video.domofon-37.ru \
    --bootstrap-json /root/video-node1-bootstrap.json \
    --node-host 10.106.1.31 \
    --dvr-root /var/lib/newdomofon-video/dvr \
    --require-mountpoint

Private node without TLS:
  bash scripts/install-node-local-root.sh \
    --master-url https://new-video.domofon-37.ru \
    --node-host 10.106.1.31 \
    --no-tls
EOF
}

while (($#)); do
  case "$1" in
    --source-dir)
      SOURCE_DIR="${2:-}"
      shift 2
      ;;
    --master-url)
      MASTER_URL="${2:-}"
      shift 2
      ;;
    --master-ip)
      MASTER_ACCESS_IP="${2:-}"
      shift 2
      ;;
    --node-id)
      NODE_ID="${2:-}"
      shift 2
      ;;
    --node-token)
      NODE_TOKEN="${2:-}"
      shift 2
      ;;
    --media-secret)
      NODE_MEDIA_SECRET="${2:-}"
      shift 2
      ;;
    --bootstrap-json)
      BOOTSTRAP_JSON="${2:-}"
      shift 2
      ;;
    --node-host)
      NODE_HOST="${2:-}"
      shift 2
      ;;
    --internal-url)
      NODE_INTERNAL_URL="${2:-}"
      shift 2
      ;;
    --public-url)
      NODE_PUBLIC_BASE_URL="${2:-}"
      shift 2
      ;;
    --node-domain)
      NODE_PUBLIC_DOMAIN="${2:-}"
      shift 2
      ;;
    --email)
      CERTBOT_EMAIL="${2:-}"
      shift 2
      ;;
    --dvr-root)
      DVR_ROOT="${2:-}"
      shift 2
      ;;
    --require-mountpoint)
      REQUIRE_MOUNTPOINT=true
      shift
      ;;
    --allow-root-filesystem)
      REQUIRE_MOUNTPOINT=false
      shift
      ;;
    --archive-event-sync-apply)
      ARCHIVE_EVENT_SYNC_APPLY=true
      shift
      ;;
    --archive-event-sync-dry-run)
      ARCHIVE_EVENT_SYNC_APPLY=false
      shift
      ;;
    --no-tls)
      TLS_MODE=no
      shift
      ;;
    --tls)
      TLS_MODE=yes
      shift
      ;;
    --regenerate-local-config)
      REGENERATE_LOCAL_CONFIG=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 64
      ;;
  esac
done

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run this installer as root." >&2
  exit 77
fi

mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE"
chmod 0600 "$LOG_FILE"
exec > >(tee -a "$LOG_FILE") 2>&1

on_error() {
  local rc=$?
  local line="${BASH_LINENO[0]:-unknown}"
  trap - ERR
  echo
  echo "NODE INSTALLATION FAILED"
  echo "Step: $CURRENT_STEP"
  echo "Line: $line"
  echo "Exit code: $rc"
  echo "Log: $LOG_FILE"
  echo "Backup: $BACKUP_DIR"
  if systemctl list-unit-files newdomofon-video-dvr.service >/dev/null 2>&1; then
    systemctl --no-pager --full status newdomofon-video-dvr.service || true
    journalctl -u newdomofon-video-dvr.service -n 200 --no-pager || true
  fi
  exit "$rc"
}
trap on_error ERR

log_step() {
  CURRENT_STEP="$1"
  echo
  echo "============================================================"
  echo "$CURRENT_STEP"
  echo "============================================================"
}

is_true() {
  case "${1,,}" in
    1|true|yes|on) return 0 ;;
    *) return 1 ;;
  esac
}

trim_trailing_slashes() {
  local value="$1"
  while [[ "$value" == */ ]]; do value="${value%/}"; done
  printf '%s\n' "$value"
}

is_ip_address() {
  python3 - "$1" <<'PY'
import ipaddress
import sys
try:
    ipaddress.ip_address(sys.argv[1].strip("[]"))
except ValueError:
    raise SystemExit(1)
PY
}

url_host() {
  python3 - "$1" <<'PY'
from urllib.parse import urlparse
import sys
value = sys.argv[1].strip()
parsed = urlparse(value if "://" in value else "http://" + value)
if not parsed.hostname:
    raise SystemExit(1)
print(parsed.hostname)
PY
}

env_value() {
  local key="$1"
  local file="$2"
  [[ -r "$file" ]] || return 0
  sed -n "s/^${key}=//p" "$file" | tail -1
}

safe_value() {
  local value="$1"
  [[ -n "$value" && "$value" != null && "$value" != PASTE_* && "$value" != CHANGE_* ]]
}

find_source_dir() {
  local candidate=""
  local script_dir script_root
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  script_root="$(cd "$script_dir/.." && pwd)"

  if [[ -n "$SOURCE_DIR" ]]; then
    candidate="$(cd "$SOURCE_DIR" 2>/dev/null && pwd)" || return 1
  elif [[ -f "$script_root/dvr-engine/package.json" &&
          -f "$script_root/scripts/node-disk-guard.sh" ]]; then
    candidate="$script_root"
  else
    candidate="$(
      find /root -mindepth 1 -maxdepth 6 -type f \
        -path '*/dvr-engine/package.json' \
        -printf '%T@ %h\n' 2>/dev/null \
        | sort -nr \
        | head -1 \
        | cut -d' ' -f2-
    )"
    [[ -n "$candidate" ]] || return 1
    candidate="$(dirname "$candidate")"
  fi

  [[ "$candidate" == /root || "$candidate" == /root/* ]] || {
    echo "Source directory must be located inside /root: $candidate" >&2
    return 1
  }

  for required in \
    dvr-engine/package.json \
    dvr-engine/package-lock.json \
    dvr-engine/src/index.ts \
    scripts/install-node-local-root.sh \
    scripts/node-disk-guard.sh \
    scripts/node-system-disk-check.sh \
    scripts/reconcile-archive-events.mjs \
    scripts/run-archive-event-sync.sh \
    deploy/nginx/newdomofon-video-node.conf; do
    [[ -f "$candidate/$required" ]] || {
      echo "Required source file is missing: $candidate/$required" >&2
      return 1
    }
  done

  printf '%s\n' "$candidate"
}

find_bootstrap_json() {
  if [[ -n "$BOOTSTRAP_JSON" ]]; then
    [[ -f "$BOOTSTRAP_JSON" ]] || {
      echo "Bootstrap JSON not found: $BOOTSTRAP_JSON" >&2
      return 1
    }
    printf '%s\n' "$BOOTSTRAP_JSON"
    return 0
  fi

  find /root -maxdepth 2 -type f \
    -iname '*bootstrap*.json' \
    -printf '%T@ %p\n' 2>/dev/null \
    | sort -nr \
    | head -1 \
    | cut -d' ' -f2-
}

set_env_value() {
  local key="$1"
  local value="$2"
  local file="$3"
  if grep -qE "^${key}=" "$file"; then
    python3 - "$file" "$key" "$value" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
key = sys.argv[2]
value = sys.argv[3]
lines = path.read_text().splitlines()
out = []
replaced = False
for line in lines:
    if line.startswith(key + "="):
        if not replaced:
            out.append(f"{key}={value}")
            replaced = True
    else:
        out.append(line)
if not replaced:
    out.append(f"{key}={value}")
path.write_text("\n".join(out) + "\n")
PY
  else
    printf '%s=%s\n' "$key" "$value" >>"$file"
  fi
}

wait_http_json_ok() {
  local url="$1"
  local output="$2"
  local timeout_seconds="$3"
  local service="$4"
  local waited=0

  while (( waited < timeout_seconds )); do
    if curl -fsS --max-time 3 "$url" >"$output" 2>/dev/null; then
      if jq -e '.ok == true' "$output" >/dev/null 2>&1; then
        echo "Health check passed after ${waited}s: $url"
        cat "$output" | jq .
        return 0
      fi
    fi
    sleep 1
    ((waited += 1))
  done

  echo "Health check failed: $url" >&2
  systemctl --no-pager --full status "$service" >&2 || true
  journalctl -u "$service" -n 300 --no-pager >&2 || true
  return 1
}

ensure_root_unit() {
  local unit_file="$1"
  python3 - "$unit_file" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
lines = path.read_text().splitlines()
out = []
in_service = False
seen_user = False
seen_group = False
for line in lines:
    if line.startswith("["):
        if in_service:
            if not seen_user:
                out.append("User=root")
            if not seen_group:
                out.append("Group=root")
        in_service = line.strip() == "[Service]"
        seen_user = False
        seen_group = False
        out.append(line)
        continue
    if in_service and line.startswith("User="):
        out.append("User=root")
        seen_user = True
    elif in_service and line.startswith("Group="):
        out.append("Group=root")
        seen_group = True
    else:
        out.append(line)
if in_service:
    if not seen_user:
        out.append("User=root")
    if not seen_group:
        out.append("Group=root")
path.write_text("\n".join(out) + "\n")
PY
}

log_step "1/14 Locating extracted local source"
SOURCE_DIR="$(find_source_dir)"
echo "Source directory: $SOURCE_DIR"

SOURCE_FINGERPRINT="$(
  {
    sha256sum "$SOURCE_DIR/dvr-engine/package-lock.json"
    sha256sum "$SOURCE_DIR/dvr-engine/src/index.ts"
    sha256sum "$SOURCE_DIR/scripts/install-node-local-root.sh"
  } | sha256sum | awk '{print $1}'
)"
echo "Source fingerprint: $SOURCE_FINGERPRINT"

log_step "2/14 Installing Debian packages without creating a project user"
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y \
  ca-certificates \
  curl \
  gnupg \
  jq \
  python3 \
  rsync \
  nginx \
  ffmpeg \
  build-essential \
  sqlite3 \
  xz-utils \
  procps \
  iproute2 \
  util-linux \
  systemd-timesyncd \
  lsof

if ! command -v node >/dev/null 2>&1 ||
   [[ "$(node -p 'Number(process.versions.node.split(".")[0])')" -lt 22 ]]; then
  curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
  apt-get install -y nodejs
fi

node -e '
const [major, minor] = process.versions.node.split(".").map(Number);
if (major < 22 || (major === 22 && minor < 12)) {
  console.error("Node.js 22.12 or newer is required");
  process.exit(1);
}
'
node --version
npm --version
ffmpeg -version | head -1
nginx -v
sqlite3 --version

log_step "3/14 Configuring Moscow time and base services"
timedatectl set-timezone "$TIMEZONE"
systemctl enable --now systemd-timesyncd || true
systemctl enable --now nginx

date '+%Y-%m-%d %H:%M:%S %Z %z'
timedatectl status | sed -n '1,12p'

install -d -o root -g root -m 0750 "$BACKUP_DIR"
install -d -o root -g root -m 0700 "$(dirname "$ENV_FILE")"
install -d -o root -g root -m 0755 \
  /opt/newdomofon-video-migration-backups \
  /var/lib/newdomofon-video \
  /var/lib/newdomofon-video/events \
  /var/log/newdomofon-video \
  /run/newdomofon-video \
  /usr/local/lib/newdomofon-video \
  /usr/local/sbin

EXISTING_ENV=""
if [[ -f "$ENV_FILE" ]]; then
  EXISTING_ENV="$BACKUP_DIR/app.env.before"
  cp -a "$ENV_FILE" "$EXISTING_ENV"
  chmod 0600 "$EXISTING_ENV"
fi

if [[ -f /var/lib/newdomofon-video/events/events.sqlite3 ]]; then
  sqlite3 /var/lib/newdomofon-video/events/events.sqlite3 \
    ".backup '$BACKUP_DIR/events-before.sqlite3'" || true
  chmod 0600 "$BACKUP_DIR/events-before.sqlite3" 2>/dev/null || true
fi

log_step "4/14 Reading node credentials and network settings"
if [[ -n "$EXISTING_ENV" ]] && ! is_true "$REGENERATE_LOCAL_CONFIG"; then
  [[ -n "$MASTER_URL" ]] || MASTER_URL="$(env_value DVR_MASTER_URL "$EXISTING_ENV")"
  [[ -n "$NODE_ID" ]] || NODE_ID="$(env_value DVR_NODE_ID "$EXISTING_ENV")"
  [[ -n "$NODE_TOKEN" ]] || NODE_TOKEN="$(env_value DVR_NODE_TOKEN "$EXISTING_ENV")"
  [[ -n "$NODE_MEDIA_SECRET" ]] || NODE_MEDIA_SECRET="$(env_value DVR_NODE_MEDIA_SECRET "$EXISTING_ENV")"
  [[ -n "$NODE_INTERNAL_URL" ]] || NODE_INTERNAL_URL="$(env_value DVR_NODE_INTERNAL_URL "$EXISTING_ENV")"
  [[ -n "$NODE_PUBLIC_BASE_URL" ]] || NODE_PUBLIC_BASE_URL="$(env_value DVR_NODE_PUBLIC_BASE_URL "$EXISTING_ENV")"
  [[ -n "$DVR_ROOT" ]] || DVR_ROOT="$(env_value DVR_ROOT "$EXISTING_ENV")"
  [[ -n "$REQUIRE_MOUNTPOINT" ]] || REQUIRE_MOUNTPOINT="$(env_value DVR_DISK_REQUIRE_MOUNTPOINT "$EXISTING_ENV")"
  [[ -n "$ARCHIVE_EVENT_SYNC_APPLY" ]] || ARCHIVE_EVENT_SYNC_APPLY="$(env_value DVR_ARCHIVE_EVENT_SYNC_APPLY "$EXISTING_ENV")"
fi

BOOTSTRAP_JSON="$(find_bootstrap_json || true)"
if [[ -n "$BOOTSTRAP_JSON" ]]; then
  echo "Bootstrap JSON: $BOOTSTRAP_JSON"
  [[ -n "$NODE_ID" ]] || NODE_ID="$(jq -r '.node_id // .id // empty' "$BOOTSTRAP_JSON")"
  [[ -n "$NODE_TOKEN" ]] || NODE_TOKEN="$(jq -r '.agent_token // .node_token // .token // empty' "$BOOTSTRAP_JSON")"
  [[ -n "$NODE_MEDIA_SECRET" ]] || NODE_MEDIA_SECRET="$(jq -r '.media_secret // .node_media_secret // empty' "$BOOTSTRAP_JSON")"
fi

if [[ -z "$MASTER_URL" ]]; then
  read -r -p "Master URL [https://new-video.domofon-37.ru]: " MASTER_URL
  MASTER_URL="${MASTER_URL:-https://new-video.domofon-37.ru}"
fi
MASTER_URL="$(trim_trailing_slashes "$MASTER_URL")"

if [[ -z "$MASTER_ACCESS_IP" ]]; then
  MASTER_HOST="$(url_host "$MASTER_URL" || true)"
  if [[ -n "$MASTER_HOST" ]]; then
    MASTER_ACCESS_IP="$(
      getent ahostsv4 "$MASTER_HOST" 2>/dev/null |
      awk 'NR==1 {print $1}'
    )"
  fi
fi
if [[ -n "$MASTER_ACCESS_IP" ]] && ! is_ip_address "$MASTER_ACCESS_IP"; then
  echo "Ignoring invalid --master-ip value: $MASTER_ACCESS_IP" >&2
  MASTER_ACCESS_IP=""
fi

if [[ -z "$NODE_ID" ]]; then
  read -r -p "Node ID from master: " NODE_ID
fi
if [[ -z "$NODE_TOKEN" ]]; then
  read -r -s -p "Node agent token from master: " NODE_TOKEN
  echo
fi
if [[ -z "$NODE_MEDIA_SECRET" ]]; then
  read -r -s -p "Node media secret from master: " NODE_MEDIA_SECRET
  echo
fi

safe_value "$NODE_ID" || { echo "Invalid or empty node ID" >&2; exit 64; }
safe_value "$NODE_TOKEN" || { echo "Invalid or empty node token" >&2; exit 64; }
safe_value "$NODE_MEDIA_SECRET" || { echo "Invalid or empty media secret" >&2; exit 64; }

if [[ -z "$NODE_HOST" ]]; then
  if [[ -n "$NODE_INTERNAL_URL" ]]; then
    NODE_HOST="$(url_host "$NODE_INTERNAL_URL" || true)"
  fi
fi
if [[ -z "$NODE_HOST" ]]; then
  NODE_HOST="$(hostname -I 2>/dev/null | awk '{print $1}')"
fi
if [[ -z "$NODE_HOST" ]]; then
  read -r -p "Private node IP or hostname: " NODE_HOST
fi
[[ -n "$NODE_HOST" ]] || { echo "Node host is required" >&2; exit 64; }

if [[ -z "$NODE_INTERNAL_URL" ]]; then
  NODE_INTERNAL_URL="http://${NODE_HOST}:3010"
fi
NODE_INTERNAL_URL="$(trim_trailing_slashes "$NODE_INTERNAL_URL")"

if [[ -z "$NODE_PUBLIC_BASE_URL" ]]; then
  if [[ -n "$NODE_PUBLIC_DOMAIN" ]]; then
    NODE_PUBLIC_BASE_URL="http://${NODE_PUBLIC_DOMAIN}"
  else
    NODE_PUBLIC_BASE_URL="http://${NODE_HOST}"
  fi
fi
NODE_PUBLIC_BASE_URL="$(trim_trailing_slashes "$NODE_PUBLIC_BASE_URL")"

if [[ -z "$NODE_PUBLIC_DOMAIN" ]]; then
  NODE_PUBLIC_DOMAIN="$(url_host "$NODE_PUBLIC_BASE_URL" || true)"
fi
NODE_PUBLIC_DOMAIN="${NODE_PUBLIC_DOMAIN:-$NODE_HOST}"

DVR_ROOT="${DVR_ROOT:-/var/lib/newdomofon-video/dvr}"
if [[ -z "$REQUIRE_MOUNTPOINT" ]]; then
  if mountpoint -q "$DVR_ROOT" 2>/dev/null; then
    REQUIRE_MOUNTPOINT=true
  else
    REQUIRE_MOUNTPOINT=false
  fi
fi
if [[ -z "$ARCHIVE_EVENT_SYNC_APPLY" ]]; then
  ARCHIVE_EVENT_SYNC_APPLY=false
fi

echo "Master:        $MASTER_URL"
echo "Master IP:     ${MASTER_ACCESS_IP:-not resolved}"
echo "Node ID:       $NODE_ID"
echo "Internal URL:  $NODE_INTERNAL_URL"
echo "Public URL:    $NODE_PUBLIC_BASE_URL"
echo "DVR root:      $DVR_ROOT"
echo "Require mount: $REQUIRE_MOUNTPOINT"
echo "Event apply:   $ARCHIVE_EVENT_SYNC_APPLY"

log_step "5/14 Validating DVR filesystem"
install -d -o root -g root -m 0750 "$DVR_ROOT"
install -d -o root -g root -m 0750 /var/lib/newdomofon-video/events
install -d -o root -g root -m 0755 /var/log/newdomofon-video

if is_true "$REQUIRE_MOUNTPOINT" && ! mountpoint -q "$DVR_ROOT"; then
  echo "DVR_ROOT must be a dedicated mounted filesystem but is not mounted:" >&2
  echo "  $DVR_ROOT" >&2
  echo "Mount the archive disk and rerun, or use --allow-root-filesystem." >&2
  exit 75
fi

findmnt -T "$DVR_ROOT" || true
df -hT "$DVR_ROOT"
df -ih "$DVR_ROOT"
touch "$DVR_ROOT/.newdomofon-write-test"
rm -f "$DVR_ROOT/.newdomofon-write-test"

ROOT_AVAILABLE="$(df -P -B1 / | awk 'NR==2 {print $4}')"
if [[ "$ROOT_AVAILABLE" -lt 2147483648 ]]; then
  echo "Less than 2 GiB is available on the operating-system filesystem." >&2
  exit 75
fi

log_step "6/14 Backing up and copying local project without Git"
for service in \
  newdomofon-video-archive-event-sync.timer \
  newdomofon-video-node-disk-guard.timer \
  newdomofon-video-dvr.service; do
  systemctl stop "$service" 2>/dev/null || true
done

if [[ -d "$PROJECT_DIR" ]]; then
  OLD_PROJECT_BACKUP="${PROJECT_DIR}.before-local-root-${STAMP}"
  mv "$PROJECT_DIR" "$OLD_PROJECT_BACKUP"
  echo "Previous project moved to: $OLD_PROJECT_BACKUP"
fi

install -d -o root -g root -m 0700 "$PROJECT_DIR"
rsync -a --delete \
  --exclude='.git/' \
  --exclude='.github/' \
  --exclude='node_modules/' \
  --exclude='dist/' \
  --exclude='*.log' \
  "$SOURCE_DIR/" "$PROJECT_DIR/"

chown -R root:root "$PROJECT_DIR"
chmod -R u+rwX,go-rwx "$PROJECT_DIR"
chmod 0700 "$PROJECT_DIR"

for required in \
  "$PROJECT_DIR/dvr-engine/package.json" \
  "$PROJECT_DIR/dvr-engine/package-lock.json" \
  "$PROJECT_DIR/scripts/node-disk-guard.sh" \
  "$PROJECT_DIR/scripts/node-system-disk-check.sh" \
  "$PROJECT_DIR/scripts/reconcile-archive-events.mjs"; do
  [[ -f "$required" ]] || { echo "Copied project is incomplete: $required" >&2; exit 66; }
done

log_step "7/14 Writing root-only node environment"
cat >"$ENV_FILE" <<EOF
NODE_ENV=production
DVR_ENGINE_ROLE=node
DVR_ENGINE_PORT=3010

DVR_ROOT=${DVR_ROOT}
FFMPEG_PATH=/usr/bin/ffmpeg
SEGMENT_DURATION=4
LIVE_WINDOW=8
CAMERA_RELOAD_SECONDS=20
CLEANUP_INTERVAL_MINUTES=60
MAX_EXPORT_SECONDS=3600
DVR_LIVE_PLAYLIST_WAIT_MS=10000

DVR_MASTER_URL=${MASTER_URL}
DVR_NODE_ID=${NODE_ID}
DVR_NODE_TOKEN=${NODE_TOKEN}
DVR_NODE_MEDIA_SECRET=${NODE_MEDIA_SECRET}
DVR_NODE_INTERNAL_URL=${NODE_INTERNAL_URL}
DVR_NODE_PUBLIC_BASE_URL=${NODE_PUBLIC_BASE_URL}
DVR_REQUIRE_MEDIA_TOKEN=true
DVR_CORS_ORIGIN=${MASTER_URL}

DVR_DASH_SEGMENT_SECONDS=2
DVR_DASH_WINDOW_SIZE=8
DVR_DASH_EXTRA_WINDOW_SIZE=4
DVR_DASH_READY_TIMEOUT_MS=15000
DVR_DASH_IDLE_MS=300000
DVR_SNAPSHOT_CACHE_MS=3000
DVR_SNAPSHOT_JPEG_QUALITY=3

DVR_EVENT_DB=/var/lib/newdomofon-video/events/events.sqlite3
DVR_EVENT_RETENTION_DAYS=30
DVR_EVENT_CLEANUP_INTERVAL_MINUTES=60
DVR_EVENT_QUERY_MAX_SECONDS=2678400
DVR_EVENT_STORE_RAW_PAYLOAD=false

ONVIF_EVENTS_ENABLED=true
ONVIF_EVENTS_REQUEST_TIMEOUT_MS=15000
DVR_HIKVISION_EVENTS_ENABLED=false
VIDEO_MOTION_ENABLED=false

DVR_ARCHIVE_EVENT_SYNC_ENABLED=true
DVR_ARCHIVE_EVENT_SYNC_APPLY=${ARCHIVE_EVENT_SYNC_APPLY}
DVR_ARCHIVE_EVENT_SYNC_MIN_AGE_MINUTES=120
DVR_ARCHIVE_EVENT_SYNC_MAX_HOURS_PER_RUN=1000
DVR_ARCHIVE_EVENT_SYNC_MASTER_TIMEOUT_MS=15000

DVR_DISK_MIN_FREE_BYTES=10737418240
DVR_DISK_MIN_FREE_PERCENT=10
DVR_DISK_RESUME_FREE_BYTES=16106127360
DVR_DISK_RESUME_FREE_PERCENT=15
DVR_DISK_MIN_FREE_INODES_PERCENT=5
DVR_DISK_RESUME_FREE_INODES_PERCENT=8
DVR_SYSTEM_MIN_FREE_BYTES=2147483648
DVR_SYSTEM_MIN_FREE_PERCENT=5
DVR_SYSTEM_RESUME_FREE_BYTES=4294967296
DVR_SYSTEM_RESUME_FREE_PERCENT=10
DVR_DISK_MIN_ARCHIVE_AGE_MINUTES=60
DVR_DISK_MAX_DELETE_DIRS_PER_RUN=500
DVR_DISK_STALE_TMP_MINUTES=60
DVR_DISK_REQUIRE_MOUNTPOINT=${REQUIRE_MOUNTPOINT}

DVR_DEVICE_ARCHIVE_MAX_RANGE_SECONDS=300
DVR_DEVICE_ARCHIVE_MIN_PLAYBACK_SECONDS=30
DVR_DEVICE_ARCHIVE_SESSION_WINDOW_SECONDS=300
DVR_DEVICE_ARCHIVE_SESSION_ALIGN_SECONDS=30
DVR_DEVICE_ARCHIVE_MAX_SESSIONS_PER_DEVICE=1
DVR_DEVICE_ARCHIVE_PREPARE_WAIT_MS=25000
DVR_DEVICE_ARCHIVE_FIRST_SEGMENT_TIMEOUT_MS=20000
DVR_DEVICE_ARCHIVE_KEEP_MS=900000
DVR_HIKVISION_ARCHIVE_SEARCH_CACHE_MS=60000
DVR_HIKVISION_ARCHIVE_SEARCH_TIMEOUT_MS=15000
DVR_HIKVISION_ARCHIVE_SEARCH_PAGE_SIZE=64
DVR_HIKVISION_ARCHIVE_SEARCH_MAX_PAGES=120
DVR_HIKVISION_ARCHIVE_FALLBACK_ON_EMPTY=0

NODE_APPLICATION_RUNTIME_USER=root
EOF

chown root:root "$ENV_FILE"
chmod 0600 "$ENV_FILE"

set -a
# shellcheck disable=SC1090
. "$ENV_FILE"
set +a

log_step "8/14 Building DVR engine"
cd "$PROJECT_DIR/dvr-engine"
npm ci --include=dev
npm run build
npm prune --omit=dev

[[ -f "$PROJECT_DIR/dvr-engine/dist/index.js" ]]
chown -R root:root "$PROJECT_DIR"
chmod -R u+rwX,go-rwx "$PROJECT_DIR"
chmod 0700 "$PROJECT_DIR"

log_step "9/14 Installing root runtime services and Nginx"
install -m 0755 "$PROJECT_DIR/scripts/node-disk-guard.sh" \
  /usr/local/sbin/newdomofon-node-disk-guard
install -m 0755 "$PROJECT_DIR/scripts/node-system-disk-check.sh" \
  /usr/local/sbin/newdomofon-node-system-disk-check
install -m 0755 "$PROJECT_DIR/scripts/reconcile-archive-events.mjs" \
  /usr/local/lib/newdomofon-video/reconcile-archive-events.mjs
install -m 0755 "$PROJECT_DIR/scripts/run-archive-event-sync.sh" \
  /usr/local/lib/newdomofon-video/run-archive-event-sync.sh

cat >/etc/systemd/system/newdomofon-video-dvr.service <<EOF
[Unit]
Description=NewDomofon Video DVR Engine
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
Group=root
WorkingDirectory=${PROJECT_DIR}/dvr-engine
EnvironmentFile=${ENV_FILE}
Environment=NODE_ENV=production
ExecStart=/usr/bin/node ${PROJECT_DIR}/dvr-engine/dist/index.js
Restart=always
RestartSec=5
TimeoutStopSec=45
KillSignal=SIGTERM
SyslogIdentifier=newdomofon-dvr
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=full
ReadWritePaths=/var/lib/newdomofon-video /var/log/newdomofon-video /tmp
CapabilityBoundingSet=
AmbientCapabilities=
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

cat >/etc/systemd/system/newdomofon-video-node-disk-guard.service <<EOF
[Unit]
Description=NewDomofon Video Node Disk Guard
After=local-fs.target

[Service]
Type=oneshot
User=root
Group=root
EnvironmentFile=-${ENV_FILE}
ExecStartPre=/usr/local/sbin/newdomofon-node-system-disk-check
ExecStart=/usr/local/sbin/newdomofon-node-disk-guard
Nice=10
IOSchedulingClass=idle
IOSchedulingPriority=7
NoNewPrivileges=true
PrivateTmp=false
ProtectHome=true
ProtectSystem=full
ReadWritePaths=/var/lib/newdomofon-video /var/log/newdomofon-video /run/newdomofon-video /run/lock /tmp /var/tmp

[Install]
WantedBy=multi-user.target
EOF

cat >/etc/systemd/system/newdomofon-video-node-disk-guard.timer <<'EOF'
[Unit]
Description=Run NewDomofon Video Node Disk Guard every minute

[Timer]
OnBootSec=30s
OnUnitActiveSec=60s
AccuracySec=10s
Persistent=true
Unit=newdomofon-video-node-disk-guard.service

[Install]
WantedBy=timers.target
EOF

cat >/etc/systemd/system/newdomofon-video-archive-event-sync.service <<EOF
[Unit]
Description=NewDomofon archive and event lifecycle synchronizer
After=network-online.target newdomofon-video-dvr.service
Wants=network-online.target

[Service]
Type=oneshot
User=root
Group=root
EnvironmentFile=${ENV_FILE}
ExecStart=/usr/local/lib/newdomofon-video/run-archive-event-sync.sh
Nice=10
IOSchedulingClass=idle
IOSchedulingPriority=7
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=true
ReadWritePaths=/var/lib/newdomofon-video /var/log/newdomofon-video /tmp
CapabilityBoundingSet=
AmbientCapabilities=

[Install]
WantedBy=multi-user.target
EOF

cat >/etc/systemd/system/newdomofon-video-archive-event-sync.timer <<'EOF'
[Unit]
Description=Run NewDomofon archive/event synchronization periodically

[Timer]
OnBootSec=3min
OnUnitActiveSec=5min
AccuracySec=30s
Persistent=true
Unit=newdomofon-video-archive-event-sync.service

[Install]
WantedBy=timers.target
EOF

install -d -m 0755 /etc/systemd/journald.conf.d
if [[ -f "$PROJECT_DIR/deploy/journald/99-newdomofon-video.conf" ]]; then
  install -m 0644 "$PROJECT_DIR/deploy/journald/99-newdomofon-video.conf" \
    /etc/systemd/journald.conf.d/99-newdomofon-video.conf
  systemctl try-restart systemd-journald.service || true
fi

install -m 0644 "$PROJECT_DIR/deploy/nginx/newdomofon-video-node.conf" \
  /etc/nginx/sites-available/newdomofon-video-node.conf
sed -i \
  "0,/server_name[[:space:]]\\+_[[:space:]]*;/s//server_name ${NODE_PUBLIC_DOMAIN};/" \
  /etc/nginx/sites-available/newdomofon-video-node.conf
ln -sfn /etc/nginx/sites-available/newdomofon-video-node.conf \
  /etc/nginx/sites-enabled/newdomofon-video-node.conf
rm -f /etc/nginx/sites-enabled/default

for unit in \
  /etc/systemd/system/newdomofon-video-dvr.service \
  /etc/systemd/system/newdomofon-video-node-disk-guard.service \
  /etc/systemd/system/newdomofon-video-archive-event-sync.service; do
  ensure_root_unit "$unit"
done

nginx -t
systemctl reload nginx
systemctl daemon-reload

log_step "10/14 Running disk guard before DVR startup"
systemctl enable newdomofon-video-node-disk-guard.timer
systemctl restart newdomofon-video-node-disk-guard.timer
systemctl start newdomofon-video-node-disk-guard.service || true

if [[ -e /run/newdomofon-video/node-disk-paused ]]; then
  echo "Disk guard paused recording:" >&2
  cat /run/newdomofon-video/node-disk-state.json 2>/dev/null | jq . >&2 || true
  exit 75
fi

cat /run/newdomofon-video/node-disk-state.json 2>/dev/null | jq . || true

log_step "11/14 Starting DVR engine and checking master connectivity"
systemctl reset-failed newdomofon-video-dvr.service 2>/dev/null || true
systemctl enable newdomofon-video-dvr.service
systemctl restart newdomofon-video-dvr.service

wait_http_json_ok \
  http://127.0.0.1:3010/health \
  /tmp/newdomofon-node-local-root-health.json \
  90 \
  newdomofon-video-dvr.service

set +e
curl -kfsS --max-time 10 "${MASTER_URL}/api/health" \
  >/tmp/newdomofon-node-master-health.json 2>/dev/null
MASTER_HEALTH_RC=$?
set -e
if [[ "$MASTER_HEALTH_RC" -eq 0 ]]; then
  echo "Master health is reachable:"
  cat /tmp/newdomofon-node-master-health.json | jq . || cat /tmp/newdomofon-node-master-health.json
else
  echo "WARNING: master health is not reachable yet: ${MASTER_URL}/api/health" >&2
fi

log_step "12/14 Enabling archive/event synchronization"
systemctl enable newdomofon-video-archive-event-sync.timer
systemctl restart newdomofon-video-archive-event-sync.timer

set +e
systemctl start newdomofon-video-archive-event-sync.service
SYNC_RC=$?
set -e
if [[ "$SYNC_RC" -ne 0 ]]; then
  echo "WARNING: initial archive/event synchronization failed; timer will retry." >&2
  systemctl --no-pager --full status newdomofon-video-archive-event-sync.service || true
fi

log_step "13/14 Configuring firewall and optional TLS"
if command -v ufw >/dev/null &&
   ufw status 2>/dev/null | grep -q '^Status: active'; then
  ufw allow 'Nginx Full' >/dev/null || true
  if [[ -n "$MASTER_ACCESS_IP" ]]; then
    ufw allow from "$MASTER_ACCESS_IP" to any port 3010 proto tcp \
      comment 'NewDomofon master to node' >/dev/null || true
  else
    echo "WARNING: UFW is active, but master IP was not resolved. Port 3010 was not opened." >&2
  fi
elif command -v firewall-cmd >/dev/null &&
     systemctl is-active --quiet firewalld; then
  firewall-cmd --permanent --add-service=http >/dev/null || true
  firewall-cmd --permanent --add-service=https >/dev/null || true
  if [[ -n "$MASTER_ACCESS_IP" ]]; then
    firewall-cmd --permanent \
      --add-rich-rule="rule family=$([[ "$MASTER_ACCESS_IP" == *:* ]] && echo ipv6 || echo ipv4) source address=${MASTER_ACCESS_IP} port port=3010 protocol=tcp accept" \
      >/dev/null || true
  fi
  firewall-cmd --reload >/dev/null || true
fi

TLS_ACTIVE=false
TLS_STATUS="not requested"
if [[ "$TLS_MODE" != no ]] &&
   [[ -n "$NODE_PUBLIC_DOMAIN" ]] &&
   ! is_ip_address "$NODE_PUBLIC_DOMAIN"; then
  if getent ahosts "$NODE_PUBLIC_DOMAIN" >/dev/null 2>&1; then
    apt-get install -y certbot python3-certbot-nginx
    CERTBOT_ARGS=(
      --nginx
      --non-interactive
      --agree-tos
      --redirect
      --keep-until-expiring
      -d "$NODE_PUBLIC_DOMAIN"
    )
    if [[ -n "$CERTBOT_EMAIL" ]]; then
      CERTBOT_ARGS+=(-m "$CERTBOT_EMAIL")
    else
      CERTBOT_ARGS+=(--register-unsafely-without-email)
    fi

    set +e
    certbot "${CERTBOT_ARGS[@]}"
    CERTBOT_RC=$?
    set -e

    if [[ "$CERTBOT_RC" -eq 0 ]]; then
      TLS_ACTIVE=true
      TLS_STATUS="enabled with Let's Encrypt"
      NODE_PUBLIC_BASE_URL="https://${NODE_PUBLIC_DOMAIN}"
      set_env_value DVR_NODE_PUBLIC_BASE_URL "$NODE_PUBLIC_BASE_URL" "$ENV_FILE"
      chown root:root "$ENV_FILE"
      chmod 0600 "$ENV_FILE"
      systemctl restart newdomofon-video-dvr.service
      wait_http_json_ok \
        http://127.0.0.1:3010/health \
        /tmp/newdomofon-node-after-tls-health.json \
        90 \
        newdomofon-video-dvr.service
    else
      TLS_STATUS="certificate request failed; HTTP remains available"
      echo "WARNING: node TLS certificate request failed." >&2
    fi
  else
    TLS_STATUS="DNS does not resolve; HTTP remains available"
  fi
elif [[ "$TLS_MODE" == yes ]] && is_ip_address "$NODE_PUBLIC_DOMAIN"; then
  TLS_STATUS="Let's Encrypt is not available for the configured IP address"
fi

nginx -t
systemctl reload nginx

log_step "14/14 Final checks and access report"
for service in \
  newdomofon-video-dvr.service \
  newdomofon-video-node-disk-guard.timer \
  newdomofon-video-archive-event-sync.timer \
  nginx.service; do
  systemctl is-active --quiet "$service" || {
    systemctl --no-pager --full status "$service" >&2 || true
    exit 1
  }
done

for service in \
  newdomofon-video-dvr.service \
  newdomofon-video-node-disk-guard.service \
  newdomofon-video-archive-event-sync.service; do
  actual_user="$(systemctl show -p User --value "$service")"
  [[ "$actual_user" == root ]] || {
    echo "$service does not run as root: $actual_user" >&2
    exit 1
  }
done

curl -fsS http://127.0.0.1:3010/health \
  >/tmp/newdomofon-node-final-health.json
jq -e '.ok == true' /tmp/newdomofon-node-final-health.json >/dev/null

if [[ "$TLS_ACTIVE" == true ]]; then
  curl -kfsS --resolve "${NODE_PUBLIC_DOMAIN}:443:127.0.0.1" \
    "https://${NODE_PUBLIC_DOMAIN}/health" \
    >/tmp/newdomofon-node-public-health.json
else
  curl -fsS -H "Host: ${NODE_PUBLIC_DOMAIN}" \
    http://127.0.0.1/health \
    >/tmp/newdomofon-node-public-health.json
fi
jq -e '.ok == true' /tmp/newdomofon-node-public-health.json >/dev/null

MOUNT_SOURCE="$(findmnt -T "$DVR_ROOT" -n -o SOURCE 2>/dev/null || true)"
MOUNT_FSTYPE="$(findmnt -T "$DVR_ROOT" -n -o FSTYPE 2>/dev/null || true)"
DVR_TOTAL_BYTES="$(df -P -B1 "$DVR_ROOT" | awk 'NR==2 {print $2}')"
DVR_AVAILABLE_BYTES="$(df -P -B1 "$DVR_ROOT" | awk 'NR==2 {print $4}')"

cp -a "$ENV_FILE" "$SUMMARY_FILE"
cat >>"$SUMMARY_FILE" <<EOF

INSTALLER_VERSION=${INSTALLER_VERSION}
INSTALL_COMPLETED_AT=$(date '+%Y-%m-%d_%H:%M:%S_%Z_%z')
INSTALL_TIMEZONE=${TIMEZONE}
INSTALL_TLS_STATUS=${TLS_STATUS}
SYSTEM_USERS_CREATED_BY_INSTALLER=none
NODE_APPLICATION_RUNTIME_USER=root
NGINX_WORKER_RUNTIME_USER=www-data

MASTER_URL=${MASTER_URL}
MASTER_ACCESS_IP=${MASTER_ACCESS_IP}
NODE_ID=${NODE_ID}
NODE_AGENT_TOKEN=${NODE_TOKEN}
NODE_MEDIA_SECRET=${NODE_MEDIA_SECRET}
NODE_INTERNAL_URL=${NODE_INTERNAL_URL}
NODE_PUBLIC_BASE_URL=${NODE_PUBLIC_BASE_URL}
NODE_HEALTH_LOCAL=http://127.0.0.1:3010/health
NODE_HEALTH_PUBLIC=${NODE_PUBLIC_BASE_URL}/health

DVR_ROOT=${DVR_ROOT}
DVR_MOUNT_REQUIRED=${REQUIRE_MOUNTPOINT}
DVR_MOUNT_SOURCE=${MOUNT_SOURCE}
DVR_MOUNT_FSTYPE=${MOUNT_FSTYPE}
DVR_TOTAL_BYTES=${DVR_TOTAL_BYTES}
DVR_AVAILABLE_BYTES=${DVR_AVAILABLE_BYTES}
EVENT_DATABASE=/var/lib/newdomofon-video/events/events.sqlite3
ARCHIVE_EVENT_SYNC_APPLY=${ARCHIVE_EVENT_SYNC_APPLY}

SOURCE_DIRECTORY=${SOURCE_DIR}
SOURCE_FINGERPRINT=${SOURCE_FINGERPRINT}
PROJECT_DIRECTORY=${PROJECT_DIR}
PREVIOUS_PROJECT_BACKUP=${OLD_PROJECT_BACKUP}
INSTALL_LOG=${LOG_FILE}
INSTALL_BACKUP=${BACKUP_DIR}
EOF

chown root:root "$SUMMARY_FILE"
chmod 0600 "$SUMMARY_FILE"

jq -Rn '
  reduce inputs as $line ({};
    if ($line | test("^[A-Za-z_][A-Za-z0-9_]*=")) then
      ($line | capture("^(?<key>[^=]+)=(?<value>.*)$")) as $item |
      .[$item.key] = $item.value
    else
      .
    end
  )
' <"$SUMMARY_FILE" >"$JSON_FILE"

chown root:root "$JSON_FILE"
chmod 0600 "$JSON_FILE"

echo
echo "============================================================"
echo "NODE INSTALLATION COMPLETED"
echo "============================================================"
cat "$SUMMARY_FILE"

echo
echo "Services:"
systemctl is-active newdomofon-video-dvr.service
systemctl is-active newdomofon-video-node-disk-guard.timer
systemctl is-active newdomofon-video-archive-event-sync.timer
systemctl is-active nginx.service

echo
echo "Runtime users:"
for service in \
  newdomofon-video-dvr.service \
  newdomofon-video-node-disk-guard.service \
  newdomofon-video-archive-event-sync.service; do
  printf '%-52s user=%s\n' \
    "$service" \
    "$(systemctl show -p User --value "$service")"
done

echo
echo "Health:"
cat /tmp/newdomofon-node-final-health.json | jq .

echo
echo "Disk state:"
cat /run/newdomofon-video/node-disk-state.json 2>/dev/null | jq . || true

echo
echo "Access file: $SUMMARY_FILE"
echo "JSON file:   $JSON_FILE"
echo "Log file:    $LOG_FILE"
echo "Backup:      $BACKUP_DIR"
echo
echo "No custom Linux user was created by this installer."
echo "All NewDomofon Video Node application services run as root."
echo "Nginx workers keep the standard Debian package account 'www-data'."

trap - ERR
