#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LEGACY_INSTALLER="$SCRIPT_DIR/install-node-local-root.sh"
ENV_FILE="${ENV_FILE:-/etc/newdomofon-video/app.env}"
REGISTRATION_FILE="${REGISTRATION_FILE:-/root/newdomofon-node-master-registration.env}"

MASTER_URL="${MASTER_URL:-}"
NODE_ID="${NODE_ID:-}"
NODE_TOKEN="${NODE_TOKEN:-}"
NODE_MEDIA_SECRET="${NODE_MEDIA_SECRET:-}"
PASSTHROUGH=()

usage() {
  cat <<'EOF'
NewDomofon Video Node root-only installer with operator-defined credentials

The node is deployed first. DVR_NODE_ID, DVR_NODE_TOKEN and
DVR_NODE_MEDIA_SECRET are selected by the operator on this node. The master
must not generate them. After installation copy the generated registration
file into Administration -> Nodes -> Create node on master.

Usage:
  bash scripts/install-node-manual-local-root.sh [options accepted by install-node-local-root.sh]

Credential options:
  --master-url URL       DVR_MASTER_URL that the node will use later
  --node-id UUID         operator-defined DVR_NODE_ID
  --node-token TOKEN     operator-defined DVR_NODE_TOKEN
  --media-secret SECRET  operator-defined DVR_NODE_MEDIA_SECRET

The wrapper rejects --bootstrap-json because master-generated bootstrap files
are not part of the current deployment model.

Generate values when needed:
  uuidgen
  openssl rand -hex 32
  openssl rand -hex 32
EOF
}

while (($#)); do
  case "$1" in
    --master-url)
      MASTER_URL="${2:-}"
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
      echo "ERROR: --bootstrap-json is obsolete for new installations." >&2
      echo "Choose credentials on the node and pass --node-id/--node-token/--media-secret." >&2
      exit 64
      ;;
    -h|--help)
      usage
      echo
      echo "Additional local-root options:"
      bash "$LEGACY_INSTALLER" --help | sed -n '/Options:/,$p'
      exit 0
      ;;
    *)
      PASSTHROUGH+=("$1")
      shift
      ;;
  esac
done

[[ -f "$LEGACY_INSTALLER" ]] || {
  echo "ERROR: installer not found: $LEGACY_INSTALLER" >&2
  exit 66
}

if [[ -z "$MASTER_URL" ]]; then
  read -r -p "Choose DVR_MASTER_URL: " MASTER_URL
fi
if [[ -z "$NODE_ID" ]]; then
  read -r -p "Choose DVR_NODE_ID (UUID): " NODE_ID
fi
if [[ -z "$NODE_TOKEN" ]]; then
  read -r -s -p "Choose DVR_NODE_TOKEN: " NODE_TOKEN
  echo
fi
if [[ -z "$NODE_MEDIA_SECRET" ]]; then
  read -r -s -p "Choose DVR_NODE_MEDIA_SECRET: " NODE_MEDIA_SECRET
  echo
fi

python3 - "$MASTER_URL" "$NODE_ID" "$NODE_TOKEN" "$NODE_MEDIA_SECRET" <<'PY'
import re
import sys
import uuid
from urllib.parse import urlparse

master_url, node_id, node_token, media_secret = sys.argv[1:]
parsed = urlparse(master_url)
if parsed.scheme not in {"http", "https"} or not parsed.hostname:
    raise SystemExit("Invalid DVR_MASTER_URL")
uuid.UUID(node_id)
safe = re.compile(r"^[A-Za-z0-9._~-]{16,512}$")
if not safe.fullmatch(node_token):
    raise SystemExit("Invalid DVR_NODE_TOKEN: use 16-512 characters A-Z a-z 0-9 . _ ~ -")
if not safe.fullmatch(media_secret):
    raise SystemExit("Invalid DVR_NODE_MEDIA_SECRET: use 16-512 characters A-Z a-z 0-9 . _ ~ -")
PY

bash "$LEGACY_INSTALLER" \
  --master-url "$MASTER_URL" \
  --node-id "$NODE_ID" \
  --node-token "$NODE_TOKEN" \
  --media-secret "$NODE_MEDIA_SECRET" \
  "${PASSTHROUGH[@]}"

[[ -r "$ENV_FILE" ]] || {
  echo "ERROR: node environment was not created: $ENV_FILE" >&2
  exit 1
}

install -d -m 0700 "$(dirname "$REGISTRATION_FILE")"

python3 - "$ENV_FILE" "$REGISTRATION_FILE" <<'PY'
from pathlib import Path
import sys

env_path = Path(sys.argv[1])
out_path = Path(sys.argv[2])
required = [
    "DVR_MASTER_URL",
    "DVR_NODE_ID",
    "DVR_NODE_TOKEN",
    "DVR_NODE_MEDIA_SECRET",
    "DVR_NODE_PUBLIC_BASE_URL",
    "DVR_NODE_INTERNAL_URL",
]
values = {}
for raw in env_path.read_text(encoding="utf-8").splitlines():
    if not raw or raw.lstrip().startswith("#") or "=" not in raw:
        continue
    key, value = raw.split("=", 1)
    values[key.strip()] = value.strip()
missing = [key for key in required if not values.get(key)]
if missing:
    raise SystemExit("Missing values after install: " + ", ".join(missing))
body = [
    "# Copy these exact values into Administration -> Nodes -> Create node on master.",
    *[f"{key}={values[key]}" for key in required],
    "",
]
out_path.write_text("\n".join(body), encoding="utf-8")
PY

chown root:root "$REGISTRATION_FILE"
chmod 0600 "$REGISTRATION_FILE"

echo
echo "Root-only node installation completed."
echo "Master registration file: $REGISTRATION_FILE"
echo "The master must accept these exact operator-defined values; it must not generate replacements."
