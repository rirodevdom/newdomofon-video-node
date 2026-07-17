#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

# Обновляет установленный NewDomofon Video Node только файлами из
# распакованного архива, в корне которого находится этот скрипт.
# Доступ к репозиторию и команда git на сервере не требуются.

SOURCE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="${PROJECT_DIR:-/opt/newdomofon-video-node}"
ENV_FILE="${ENV_FILE:-/etc/newdomofon-video/app.env}"
REGISTRATION_FILE="${REGISTRATION_FILE:-/root/newdomofon-node-master-registration.env}"
BACKUP_ROOT="${BACKUP_ROOT:-/opt/newdomofon-video-migration-backups}"
PRESERVE_NGINX=true
DRY_RUN=false
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR=""
UPDATE_LOG=""
SOURCE_FINGERPRINT=""

usage() {
  cat <<'EOF'
Безопасное обновление NewDomofon Video Node из текущей распакованной папки.

Git и доступ к репозиторию на сервере не используются.

Использование:
  sudo bash update-installed-project.sh [опции]

Опции:
  --project-dir PATH       Установленный node.
                           По умолчанию: /opt/newdomofon-video-node
  --env-file PATH          Runtime env.
                           По умолчанию: /etc/newdomofon-video/app.env
  --registration-file PATH Root-only файл данных регистрации node.
                           По умолчанию:
                           /root/newdomofon-node-master-registration.env
  --backup-root PATH       Каталог резервных копий.
                           По умолчанию: /opt/newdomofon-video-migration-backups
  --use-archive-nginx      Установить Nginx-конфиг из архива вместо сохранения
                           действующего production-конфига.
  --dry-run                Показать изменения файлов без обновления сервера.
  -h, --help               Показать справку.

Пример:
  cd /root/newdomofon-video-node-main
  bash update-installed-project.sh --dry-run
  sudo bash update-installed-project.sh
EOF
}

log() {
  printf '[%s] %s\n' "$(date '+%F %T')" "$*"
}

warn() {
  printf '[%s] WARNING: %s\n' "$(date '+%F %T')" "$*" >&2
}

fail() {
  printf '[%s] ERROR: %s\n' "$(date '+%F %T')" "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "Не найдена обязательная команда: $1"
}

canonical_path() {
  python3 - "$1" <<'PY'
from pathlib import Path
import sys
print(Path(sys.argv[1]).expanduser().resolve(strict=False))
PY
}

copy_if_exists() {
  local source="$1"
  local destination="$2"
  if [[ -e "$source" || -L "$source" ]]; then
    cp -aL "$source" "$destination"
  fi
}

calculate_source_fingerprint() {
  python3 - "$SOURCE_ROOT" <<'PY'
from pathlib import Path
import hashlib
import sys

root = Path(sys.argv[1]).resolve()
excluded = {".git", "node_modules", "dist", "__pycache__"}
digest = hashlib.sha256()

for path in sorted(root.rglob("*"), key=lambda item: item.as_posix()):
    if not path.is_file():
        continue
    relative = path.relative_to(root)
    if any(part in excluded for part in relative.parts):
        continue
    digest.update(relative.as_posix().encode("utf-8", errors="surrogateescape"))
    digest.update(b"\0")
    with path.open("rb") as handle:
        while chunk := handle.read(1024 * 1024):
            digest.update(chunk)
    digest.update(b"\0")

print(digest.hexdigest())
PY
}

validate_source() {
  local required
  for required in \
    dvr-engine/package.json \
    scripts/deploy-node.sh; do
    [[ -f "$SOURCE_ROOT/$required" ]] ||
      fail "Архив не содержит node-файл: $required"
  done
}

validate_installed_project() {
  [[ -d "$PROJECT_DIR" ]] ||
    fail "Установленный node не найден: $PROJECT_DIR"
  [[ -f "$PROJECT_DIR/scripts/deploy-node.sh" ]] ||
    fail "Каталог не похож на установленный node: $PROJECT_DIR"
}

rsync_source() {
  local -a args=(
    -a
    --delete-delay
    --itemize-changes
    --exclude=.git/
    --exclude=node_modules/
    --exclude=dist/
    --exclude=.env
    --exclude='*.env'
    --exclude=.installed-from-extracted-source
    --exclude='*.log'
  )

  if [[ "$DRY_RUN" == true ]]; then
    args+=(--dry-run)
  fi

  log "Синхронизация файлов архива: $SOURCE_ROOT -> $PROJECT_DIR"
  rsync "${args[@]}" "$SOURCE_ROOT/" "$PROJECT_DIR/"
}

backup_project_source() {
  install -d -m 0700 "$BACKUP_DIR/project-source-before"
  rsync -a \
    --exclude=.git/ \
    --exclude=node_modules/ \
    --exclude=dist/ \
    --exclude='*.log' \
    "$PROJECT_DIR/" \
    "$BACKUP_DIR/project-source-before/"
}

backup_events_database() {
  local database=/var/lib/newdomofon-video/events/events.sqlite3
  [[ -f "$database" ]] || return 0

  if command -v sqlite3 >/dev/null 2>&1; then
    sqlite3 "$database" ".backup '$BACKUP_DIR/events-before.sqlite3'"
    sqlite3 "$database" 'PRAGMA integrity_check;' \
      >"$BACKUP_DIR/events-integrity-before.txt"
  else
    warn "sqlite3 не установлен; копирую SQLite вместе с WAL/SHM"
    copy_if_exists "$database" "$BACKUP_DIR/events.sqlite3.before"
    copy_if_exists "${database}-wal" "$BACKUP_DIR/events.sqlite3-wal.before"
    copy_if_exists "${database}-shm" "$BACKUP_DIR/events.sqlite3-shm.before"
  fi
}

backup_node() {
  log "Создание резервной копии node"

  [[ -f "$ENV_FILE" ]] || fail "Не найден env: $ENV_FILE"
  copy_if_exists "$ENV_FILE" "$BACKUP_DIR/app.env.before"
  copy_if_exists "$REGISTRATION_FILE" "$BACKUP_DIR/node-registration.before.env"
  copy_if_exists \
    /etc/nginx/sites-available/newdomofon-video-node.conf \
    "$BACKUP_DIR/newdomofon-video-node.conf.before"
  copy_if_exists \
    /etc/systemd/system/newdomofon-video-dvr.service \
    "$BACKUP_DIR/newdomofon-video-dvr.service.before"

  backup_events_database
}

restore_production_nginx() {
  local backup="$BACKUP_DIR/newdomofon-video-node.conf.before"
  [[ "$PRESERVE_NGINX" == true ]] || return 0
  [[ -f "$backup" ]] || return 0

  log "Восстановление действующего production-конфига Nginx"
  cp -a "$backup" /etc/nginx/sites-available/newdomofon-video-node.conf
  ln -sfn \
    /etc/nginx/sites-available/newdomofon-video-node.conf \
    /etc/nginx/sites-enabled/newdomofon-video-node.conf
  nginx -t
  systemctl reload nginx
}

run_deploy() {
  log "Запуск штатного deploy-node.sh"

  set +e
  PROJECT_DIR="$PROJECT_DIR" \
  ENV_FILE="$ENV_FILE" \
  REGISTRATION_FILE="$REGISTRATION_FILE" \
  INSTALL_DISK_GUARD=1 \
  INSTALL_JOURNAL_LIMITS=1 \
  INSTALL_ARCHIVE_EVENT_SYNC=1 \
    bash "$PROJECT_DIR/scripts/deploy-node.sh" --non-interactive
  local rc=$?
  set -e

  restore_production_nginx
  ((rc == 0)) || return "$rc"
}

write_marker() {
  cat >"$PROJECT_DIR/.installed-from-extracted-source" <<EOF
project_type=node
updated_at=$(date --iso-8601=seconds)
source_root=$SOURCE_ROOT
source_fingerprint_sha256=$SOURCE_FINGERPRINT
backup_dir=$BACKUP_DIR
repository_access_used=false
EOF
  chmod 0600 "$PROJECT_DIR/.installed-from-extracted-source"
}

verify_result() {
  curl -fsS --max-time 5 \
    http://127.0.0.1:3010/health \
    >"$BACKUP_DIR/node-health-after.json"

  curl -fsS --max-time 10 \
    http://127.0.0.1:3010/recorders \
    >"$BACKUP_DIR/node-recorders-after.json" || true

  systemctl is-active --quiet newdomofon-video-dvr.service ||
    fail "newdomofon-video-dvr.service не активен"

  nginx -t
}

on_error() {
  local rc=$?
  local line="${BASH_LINENO[0]:-unknown}"
  trap - ERR

  if [[ -n "$BACKUP_DIR" && "$PRESERVE_NGINX" == true ]]; then
    restore_production_nginx || true
  fi

  echo >&2
  echo "ОБНОВЛЕНИЕ NODE ЗАВЕРШИЛОСЬ ОШИБКОЙ" >&2
  echo "Код: $rc; строка: $line" >&2
  [[ -n "$BACKUP_DIR" ]] && echo "Backup: $BACKUP_DIR" >&2
  [[ -n "$UPDATE_LOG" ]] && echo "Лог: $UPDATE_LOG" >&2
  echo "Автоматический откат SQLite не выполнялся, чтобы не потерять новые события." >&2
  exit "$rc"
}

while (($#)); do
  case "$1" in
    --project-dir)
      PROJECT_DIR="${2:-}"
      shift 2
      ;;
    --env-file)
      ENV_FILE="${2:-}"
      shift 2
      ;;
    --registration-file)
      REGISTRATION_FILE="${2:-}"
      shift 2
      ;;
    --backup-root)
      BACKUP_ROOT="${2:-}"
      shift 2
      ;;
    --use-archive-nginx)
      PRESERVE_NGINX=false
      shift
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "Неизвестный параметр: $1"
      ;;
  esac
done

for command in python3 rsync curl; do
  require_command "$command"
done

SOURCE_ROOT="$(canonical_path "$SOURCE_ROOT")"
PROJECT_DIR="$(canonical_path "$PROJECT_DIR")"
ENV_FILE="$(canonical_path "$ENV_FILE")"
REGISTRATION_FILE="$(canonical_path "$REGISTRATION_FILE")"
BACKUP_ROOT="$(canonical_path "$BACKUP_ROOT")"

validate_source
validate_installed_project

[[ "$SOURCE_ROOT" != "$PROJECT_DIR" ]] ||
  fail "Нельзя обновлять проект из его установленного каталога"

case "$SOURCE_ROOT/" in
  "$PROJECT_DIR"/*)
    fail "Распакованный архив нельзя размещать внутри $PROJECT_DIR"
    ;;
esac

case "$PROJECT_DIR/" in
  "$SOURCE_ROOT"/*)
    fail "Установленный node не должен находиться внутри распакованного архива"
    ;;
esac

SOURCE_FINGERPRINT="$(calculate_source_fingerprint)"
log "Источник архива: $SOURCE_ROOT"
log "SHA-256 содержимого: $SOURCE_FINGERPRINT"
log "Установленный node: $PROJECT_DIR"

if [[ "$DRY_RUN" == true ]]; then
  log "DRY RUN: сервер изменён не будет"
  rsync_source
  log "DRY RUN завершён"
  exit 0
fi

[[ "$(id -u)" -eq 0 ]] || fail "Запустите скрипт от root"
for command in flock tee systemctl nginx; do
  require_command "$command"
done

install -d -m 0755 /run/lock
exec 9>/run/lock/newdomofon-node-archive-update.lock
flock -n 9 || fail "Уже выполняется другое обновление node"

BACKUP_DIR="$BACKUP_ROOT/node-archive-update-$STAMP"
install -d -m 0700 "$BACKUP_DIR"
UPDATE_LOG="$BACKUP_DIR/update.log"
exec > >(tee -a "$UPDATE_LOG") 2>&1
trap on_error ERR

log "Backup: $BACKUP_DIR"
backup_project_source
backup_node

cat >"$BACKUP_DIR/source-info.txt" <<EOF
project_type=node
source_root=$SOURCE_ROOT
source_fingerprint_sha256=$SOURCE_FINGERPRINT
project_dir=$PROJECT_DIR
env_file=$ENV_FILE
registration_file=$REGISTRATION_FILE
started_at=$(date --iso-8601=seconds)
preserve_nginx=$PRESERVE_NGINX
repository_access_used=false
EOF

rsync_source
run_deploy
verify_result
write_marker

date --iso-8601=seconds >"$BACKUP_DIR/completed-at.txt"
trap - ERR

echo
echo "NODE ОБНОВЛЕНА ИЗ РАСПАКОВАННОГО АРХИВА"
echo "Источник:    $SOURCE_ROOT"
echo "Fingerprint: $SOURCE_FINGERPRINT"
echo "Backup:      $BACKUP_DIR"
echo "Git и сетевой доступ к репозиторию не использовались."
