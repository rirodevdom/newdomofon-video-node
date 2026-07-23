#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

SOURCE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PAYLOAD_DIR="$SOURCE_ROOT/.offline-update"
MANIFEST="$PAYLOAD_DIR/manifest.env"
CACHE_ARCHIVE="$PAYLOAD_DIR/npm-cache.tar.gz"
CACHE_CHECKSUM="$PAYLOAD_DIR/npm-cache.tar.gz.sha256"
STAMP="$(date +%Y%m%d-%H%M%S)"
TEMP_ROOT=""
PAYLOAD_HOLD=""
BUNDLE_COMMIT=""

log() {
  printf '[%s] %s\n' "$(date '+%F %T')" "$*"
}

fail() {
  printf '[%s] ERROR: %s\n' "$(date '+%F %T')" "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "Не найдена обязательная команда: $1"
}

manifest_value() {
  local key="$1"
  sed -n "s/^${key}=//p" "$MANIFEST" | tail -1
}

restore_payload() {
  if [[ -n "$PAYLOAD_HOLD" && -d "$PAYLOAD_HOLD" && ! -e "$PAYLOAD_DIR" ]]; then
    mv "$PAYLOAD_HOLD" "$PAYLOAD_DIR" || true
  fi
  if [[ -n "$TEMP_ROOT" && -d "$TEMP_ROOT" ]]; then
    rm -rf "$TEMP_ROOT" || true
  fi
}

trap restore_payload EXIT

for command in node npm python3 rsync tar sha256sum mktemp; do
  require_command "$command"
done

[[ -f "$SOURCE_ROOT/update-installed-project.sh" ]] ||
  fail "В корне пакета отсутствует update-installed-project.sh"
[[ -f "$MANIFEST" ]] || fail "Отсутствует offline manifest: $MANIFEST"
[[ -f "$CACHE_ARCHIVE" ]] || fail "Отсутствует npm cache: $CACHE_ARCHIVE"
[[ -f "$CACHE_CHECKSUM" ]] || fail "Отсутствует checksum: $CACHE_CHECKSUM"

[[ "$(manifest_value project_type)" == "node" ]] ||
  fail "Пакет предназначен не для video node"

BUNDLE_COMMIT="$(manifest_value source_commit)"
EXPECTED_PLATFORM="$(manifest_value platform)"
EXPECTED_ARCH="$(manifest_value architecture)"
CURRENT_PLATFORM="$(node -p 'process.platform')"
CURRENT_ARCH="$(node -p 'process.arch')"

[[ -n "$BUNDLE_COMMIT" ]] || fail "В manifest отсутствует source_commit"
[[ "$CURRENT_PLATFORM" == "$EXPECTED_PLATFORM" ]] ||
  fail "Платформа пакета $EXPECTED_PLATFORM, сервера $CURRENT_PLATFORM"
[[ "$CURRENT_ARCH" == "$EXPECTED_ARCH" ]] ||
  fail "Архитектура пакета $EXPECTED_ARCH, сервера $CURRENT_ARCH"

node - <<'NODE' || fail "Требуется Node.js не ниже 22.12.0"
const [major, minor, patch] = process.versions.node.split('.').map(Number);
const ok = major > 22 || (major === 22 && (minor > 12 || (minor === 12 && patch >= 0)));
if (!ok) process.exit(1);
NODE

log "Проверка npm cache"
(
  cd "$PAYLOAD_DIR"
  sha256sum -c "$(basename "$CACHE_CHECKSUM")"
)

TEMP_ROOT="$(mktemp -d "/var/tmp/newdomofon-node-offline-${STAMP}-XXXXXX")"
tar -xzf "$CACHE_ARCHIVE" -C "$TEMP_ROOT"
[[ -d "$TEMP_ROOT/npm-cache/_cacache" ]] ||
  fail "В offline-пакете отсутствует npm cache content store"

# Не копируем тяжёлый cache внутрь /opt. На время штатного rsync убираем
# служебный payload из source tree, а npm получает его из /var/tmp.
PAYLOAD_HOLD="$TEMP_ROOT/bundle-metadata"
mv "$PAYLOAD_DIR" "$PAYLOAD_HOLD"

export npm_config_cache="$TEMP_ROOT/npm-cache"
export npm_config_offline=true
export npm_config_audit=false
export npm_config_fund=false
export npm_config_update_notifier=false
export npm_config_prefer_offline=true

log "Offline bundle commit: $BUNDLE_COMMIT"
log "Запуск штатного безопасного updater без сетевого доступа npm"

set +e
bash "$SOURCE_ROOT/update-installed-project.sh" "$@"
RC=$?
set -e

if ((RC != 0)); then
  fail "Offline update завершился с кодом $RC"
fi

log "Offline update node завершён успешно"
