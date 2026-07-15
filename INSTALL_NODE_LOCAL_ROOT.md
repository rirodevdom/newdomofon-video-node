# Установка Video Node из локального архива от root

Этот сценарий предназначен для Debian 12, когда source archive уже распакован внутри `/root` и Git недоступен или не используется.

Рекомендуемый запускаемый файл:

```text
scripts/install-node-manual-local-root.sh
```

Он оборачивает монолитный root-only installer и принудительно использует актуальную модель:

- node разворачивается первой;
- UUID/token/media secret выбираются оператором на node;
- master ничего не генерирует;
- старый `--bootstrap-json` отклоняется;
- после установки создаётся `/root/newdomofon-node-master-registration.env`.

Обычная production-установка через пользователя `newdomofon` предпочтительнее. Root-only вариант используйте только когда это осознанное требование.

## 1. Пользователи и границы

Root-only installer не создаёт Linux-пользователя `newdomofon`. От root запускаются:

```text
newdomofon-video-dvr.service
newdomofon-video-node-disk-guard.service
newdomofon-video-archive-event-sync.service
```

Nginx worker остаётся `www-data`. PostgreSQL на node не устанавливается и не используется.

## 2. Подготовьте archive disk

```bash
lsblk -o NAME,SIZE,FSTYPE,LABEL,UUID,MOUNTPOINTS,MODEL,SERIAL
```

Для уже подготовленного раздела:

```bash
DVR_PARTITION=/dev/sdb1
DVR_ROOT=/var/lib/newdomofon-video/dvr

install -d -m 0750 "$DVR_ROOT"
DVR_UUID="$(blkid -s UUID -o value "$DVR_PARTITION")"
test -n "$DVR_UUID"

grep -qF "UUID=$DVR_UUID " /etc/fstab || \
  echo "UUID=$DVR_UUID $DVR_ROOT ext4 defaults,noatime 0 2" >>/etc/fstab

mount -a
findmnt "$DVR_ROOT"
df -hT "$DVR_ROOT"
df -ih "$DVR_ROOT"
```

`mkfs.ext4` выполняйте только для нового пустого раздела: команда уничтожает существующие данные.

Используйте:

```text
--require-mountpoint
```

если архивный диск обязателен. `--allow-root-filesystem` допустим только при осознанном хранении архива на system disk.

## 3. Распакуйте source

Пример:

```text
/root/newdomofon-video-node-main/
```

Проверка:

```bash
SOURCE_DIR=/root/newdomofon-video-node-main

test -f "$SOURCE_DIR/dvr-engine/package.json"
test -f "$SOURCE_DIR/scripts/install-node-manual-local-root.sh"
test -f "$SOURCE_DIR/scripts/install-node-local-root.sh"
test -f "$SOURCE_DIR/scripts/node-disk-guard.sh"
```

## 4. Подготовьте operator-defined credentials

```bash
NODE_ID="$(uuidgen)"
NODE_TOKEN="$(openssl rand -hex 32)"
NODE_MEDIA_SECRET="$(openssl rand -hex 32)"
```

Значения используются как:

```text
DVR_NODE_ID
DVR_NODE_TOKEN
DVR_NODE_MEDIA_SECRET
```

Token и media secret: `16–512` символов `A-Z a-z 0-9 . _ ~ -`.

## 5. Интерактивная установка

```bash
cd /root/newdomofon-video-node-main

bash scripts/install-node-manual-local-root.sh \
  --node-host 10.106.1.31 \
  --master-ip 10.106.1.30 \
  --dvr-root /var/lib/newdomofon-video/dvr \
  --require-mountpoint \
  --no-tls
```

Wrapper запросит:

```text
DVR_MASTER_URL
DVR_NODE_ID
DVR_NODE_TOKEN
DVR_NODE_MEDIA_SECRET
```

## 6. Неинтерактивная установка

```bash
cd /root/newdomofon-video-node-main

bash scripts/install-node-manual-local-root.sh \
  --source-dir /root/newdomofon-video-node-main \
  --master-url https://new-video.domofon-37.ru \
  --master-ip 10.106.1.30 \
  --node-id "$NODE_ID" \
  --node-token "$NODE_TOKEN" \
  --media-secret "$NODE_MEDIA_SECRET" \
  --node-host 10.106.1.31 \
  --internal-url http://10.106.1.31:3010 \
  --public-url http://10.106.1.31 \
  --dvr-root /var/lib/newdomofon-video/dvr \
  --require-mountpoint \
  --archive-event-sync-dry-run \
  --no-tls

unset NODE_ID NODE_TOKEN NODE_MEDIA_SECRET
```

Для node с собственным DNS/TLS добавьте:

```text
--node-domain video-node1.example.ru
--email admin@example.ru
--tls
```

## 7. Что делает installer

- устанавливает Debian packages и Node.js 22;
- задаёт `Europe/Moscow`;
- сохраняет старый `app.env` и SQLite backup;
- копирует source из `/root` в `/opt/newdomofon-video-node` без Git metadata;
- создаёт `root:root 0600` runtime env;
- собирает DVR engine;
- устанавливает root systemd units;
- устанавливает Nginx, disk guard и archive/event sync;
- проверяет mount/free space;
- запускает локальный health;
- настраивает firewall/TLS при необходимости;
- создаёт registration file для master.

Master может быть выключен. Недоступность master не должна останавливать локальный DVR.

## 8. Файлы после установки

```text
/etc/newdomofon-video/app.env
/root/newdomofon-node-master-registration.env
/root/newdomofon-node-access.txt
/root/newdomofon-node-access.json
/root/newdomofon-node-local-root-*.log
/opt/newdomofon-video-migration-backups/local-root-node-*
```

Все access/config files содержат secrets и должны иметь `0600`.

## 9. Создайте запись на master

```bash
cat /root/newdomofon-node-master-registration.env
```

В master откройте:

```text
Администрирование → Ноды → Создать node
```

Введите посимвольно:

```text
DVR_MASTER_URL
DVR_NODE_ID
DVR_NODE_TOKEN
DVR_NODE_MEDIA_SECRET
DVR_NODE_PUBLIC_BASE_URL
DVR_NODE_INTERNAL_URL
```

## 10. Проверка

```bash
systemctl is-active newdomofon-video-dvr.service
systemctl is-active newdomofon-video-node-disk-guard.timer
systemctl is-active newdomofon-video-archive-event-sync.timer
systemctl is-active nginx.service

curl -fsS http://127.0.0.1:3010/health | jq
curl -fsS http://127.0.0.1:3010/recorders | jq

journalctl -u newdomofon-video-dvr.service -n 300 --no-pager
cat /run/newdomofon-video/node-disk-state.json | jq
```

После создания записи master node должна стать `online`.

## 11. Повторный запуск

Существующий `app.env` сохраняется по умолчанию. Не меняйте ID/token/media secret действующей node без одновременного изменения записи master.

Installer не удаляет DVR archive.

## 12. `.env`

Root-only installation использует тот же набор параметров, что обычная node, плюс marker:

```text
NODE_APPLICATION_RUNTIME_USER=root
```

Полное объяснение каждой переменной: [docs/ENVIRONMENT.md](docs/ENVIRONMENT.md).

## 13. Устаревший сценарий

Не используйте для новых установок:

```text
--bootstrap-json
UUID_FROM_MASTER
AGENT_TOKEN_FROM_MASTER
MEDIA_SECRET_FROM_MASTER
```

Wrapper намеренно отклоняет `--bootstrap-json`. Master больше не является источником node credentials.
