#!/usr/bin/env bash
set -Eeuo pipefail
umask 022

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT_DIR="${OUTPUT_DIR:-$ROOT/offline-bundles}"
WORK_ROOT="${WORK_ROOT:-$(mktemp -d /tmp/newdomofon-node-offline-build-XXXXXX)}"
KEEP_WORK="${KEEP_WORK:-false}"
COMMIT="${SOURCE_COMMIT:-${GITHUB_SHA:-}}"

cleanup() {
  if [[ "$KEEP_WORK" != true && -n "$WORK_ROOT" && -d "$WORK_ROOT" ]]; then
    rm -rf "$WORK_ROOT"
  fi
}
trap cleanup EXIT

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

for command in git node npm tar sha256sum; do
  command -v "$command" >/dev/null 2>&1 || fail "$command is required"
done

if [[ -z "$COMMIT" ]]; then
  COMMIT="$(git -C "$ROOT" rev-parse HEAD)"
fi
git -C "$ROOT" cat-file -e "${COMMIT}^{commit}"

SHORT_COMMIT="${COMMIT:0:12}"
BUNDLE_NAME="newdomofon-video-node-offline-${SHORT_COMMIT}"
STAGE_PARENT="$WORK_ROOT/stage"
STAGE="$STAGE_PARENT/$BUNDLE_NAME"
CACHE="$WORK_ROOT/npm-cache"

mkdir -p "$STAGE" "$CACHE" "$OUTPUT_DIR"
git -C "$ROOT" archive --format=tar "$COMMIT" | tar -xf - -C "$STAGE"

export npm_config_cache="$CACHE"
export npm_config_audit=false
export npm_config_fund=false
export npm_config_update_notifier=false

build_once() {
  local offline="$1"
  if [[ "$offline" == true ]]; then
    export npm_config_offline=true
    export npm_config_prefer_offline=true
  else
    unset npm_config_offline || true
    export npm_config_prefer_online=true
  fi

  rm -rf "$STAGE/dvr-engine/node_modules" "$STAGE/dvr-engine/dist"
  (
    cd "$STAGE/dvr-engine"
    npm ci --include=dev
    npm run build
    npm ci --omit=dev
    node -e "import('express').then(() => console.log('express runtime OK'))"
  )
}

echo "Populating npm cache for $COMMIT"
build_once false

echo "Verifying a second build with npm network disabled"
build_once true

rm -rf "$STAGE/dvr-engine/node_modules" "$STAGE/dvr-engine/dist"
mkdir -p "$STAGE/.offline-update"

tar -C "$WORK_ROOT" -czf "$STAGE/.offline-update/npm-cache.tar.gz" npm-cache
(
  cd "$STAGE/.offline-update"
  sha256sum npm-cache.tar.gz > npm-cache.tar.gz.sha256
)

cat >"$STAGE/.offline-update/manifest.env" <<EOF
project_type=node
source_commit=$COMMIT
source_short_commit=$SHORT_COMMIT
created_at=$(date --iso-8601=seconds)
platform=$(node -p 'process.platform')
architecture=$(node -p 'process.arch')
node_version=$(node -p 'process.versions.node')
npm_version=$(npm --version)
cache_format=npm-cacache-tar-gzip-v1
EOF

bash -n "$STAGE/offline-update.sh"
bash -n "$STAGE/update-installed-project.sh"

FINAL_ARCHIVE="$OUTPUT_DIR/${BUNDLE_NAME}.tar.gz"
tar -C "$STAGE_PARENT" -czf "$FINAL_ARCHIVE" "$BUNDLE_NAME"
sha256sum "$FINAL_ARCHIVE" >"$FINAL_ARCHIVE.sha256"

cat >"$OUTPUT_DIR/${BUNDLE_NAME}.txt" <<EOF
project_type=node
source_commit=$COMMIT
archive=$(basename "$FINAL_ARCHIVE")
sha256=$(sha256sum "$FINAL_ARCHIVE" | awk '{print $1}')
platform=$(node -p 'process.platform')
architecture=$(node -p 'process.arch')
node_version=$(node -p 'process.versions.node')
npm_version=$(npm --version)
EOF

printf '\nOffline node bundle created:\n  %s\n  %s\n' \
  "$FINAL_ARCHIVE" "$FINAL_ARCHIVE.sha256"
