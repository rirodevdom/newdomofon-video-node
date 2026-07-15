# NewDomofon Video Node

Отдельный **data plane** NewDomofon Video: FFmpeg recorder, live HLS/MPEG-TS/DASH/JPEG, локальный архив, MP4 export, archive ranges, ONVIF/Hikvision events, SQLite/WAL и disk guard.

Этот репозиторий устанавливается **только на video node**. Master backend, PostgreSQL, пользователи, RBAC, устройства, камеры и внешние managed tokens находятся в `rirodevdom/newdomofon-video-master`.

> Production: Debian 12, Node.js 22, FFmpeg, Nginx и systemd. PostgreSQL для runtime node не требуется.

## Главное изменение регистрации

Node разворачивается **до** создания записи на master.

Во время установки оператор самостоятельно задаёт:

```text
DVR_MASTER_URL
DVR_NODE_ID
DVR_NODE_TOKEN
DVR_NODE_MEDIA_SECRET
DVR_NODE_PUBLIC_BASE_URL
DVR_NODE_INTERNAL_URL
```

После установки node создаёт root-only файл:

```text
/root/newdomofon-node-master-registration.env
```

Затем все значения из него вводятся в:

```text
Администрирование → Ноды → Создать node
```

Master не генерирует UUID, agent token или media secret.

Подробно: [docs/MANUAL_NODE_BOOTSTRAP.md](docs/MANUAL_NODE_BOOTSTRAP.md).

## Документация

- [Развёртывание на Debian 12](docs/BAREMETAL_DEBIAN12.md)
- [Ручная регистрация на master](docs/MANUAL_NODE_BOOTSTRAP.md)
- [Все переменные `.env`](docs/ENVIRONMENT.md)
- [Disk guard](docs/DISK_PROTECTION.md)
- [Синхронизация событий с архивом](docs/ARCHIVE_EVENT_LIFECYCLE.md)

## Архитектура

```text
Пользователь / SmartYard / VLC
              |
              | HTTPS / RTSP к master
              v
+-----------------------------------------------+
| MASTER                                        |
| PostgreSQL, UI, RBAC, managed tokens          |
| HTTPS media gateway, MediaMTX                 |
+-----------------------------------------------+
              |
              | heartbeat/config/commands
              | short-lived internal tokens
              v
+-----------------------------------------------+
| VIDEO NODE                                    |
| DVR engine :3010                              |
| FFmpeg recorder                               |
| HLS / MPEG-TS / DASH / JPEG                   |
| local archive / export / ranges               |
| SQLite events / disk guard                    |
+-----------------------------------------------+
              |
              | RTSP / ONVIF / Hikvision
              v
           Камеры / NVR
```

Node отвечает за:

- получение назначенных камер с master;
- heartbeat и команды;
- запись RTSP через FFmpeg;
- live и локальный архив;
- device archive playback для Hikvision/NVR;
- события и локальную SQLite;
- аварийную защиту диска.

Node не должна:

- подключаться к PostgreSQL master;
- хранить пользователей/RBAC;
- принимать внешний managed token напрямую;
- публиковать `DVR_NODE_TOKEN` или `DVR_NODE_MEDIA_SECRET`;
- запускать backend/frontend master.

## Production-пути

```text
/opt/newdomofon-video-node/                    Git checkout
/etc/newdomofon-video/app.env                  runtime config и secrets
/root/newdomofon-node-master-registration.env  значения для формы master
/var/lib/newdomofon-video/dvr/                 live и архив
/var/lib/newdomofon-video/events/events.sqlite3
/var/log/newdomofon-video/
/run/newdomofon-video/node-disk-state.json
/etc/nginx/sites-available/newdomofon-video-node.conf
/etc/systemd/system/newdomofon-video-dvr.service
```

## Требования

Рекомендуемый минимум:

```text
Debian 12 x86_64
4 CPU cores
4–8 GB RAM
20–40 GB system SSD
отдельный HDD/SSD/NVMe под DVR_ROOT
Node.js 22
FFmpeg
Nginx
Europe/Moscow на master и всех node
```

Приблизительный расход архива:

```text
GB/day ≈ bitrate_Mbit × 10.8
```

Добавляйте 15–20% запаса для live window, текущего часа, SQLite WAL, export и filesystem metadata.

## Сеть

Входящие:

```text
22/tcp    SSH только администраторам
3010/tcp  DVR engine только master/private network
80/443    опциональный Nginx endpoint node
```

Исходящие:

- HTTPS к master;
- DNS/NTP;
- RTSP/ONVIF/Hikvision к камерам/NVR;
- GitHub/npm только во время установки и обновления.

## Быстрое развёртывание

Полный вариант: [docs/BAREMETAL_DEBIAN12.md](docs/BAREMETAL_DEBIAN12.md).

### 1. Подготовьте Debian

```bash
apt-get update
apt-get dist-upgrade -y
apt-get install -y git ca-certificates curl openssl jq rsync uuid-runtime

timedatectl set-timezone Europe/Moscow
systemctl enable --now systemd-timesyncd
```

### 2. Клонируйте node-репозиторий

```bash
git clone \
  https://github.com/rirodevdom/newdomofon-video-node.git \
  /opt/newdomofon-video-node

cd /opt/newdomofon-video-node
bash scripts/install-debian12-prereqs.sh
```

### 3. Подготовьте значения

```bash
uuidgen
openssl rand -hex 32
openssl rand -hex 32
```

Используйте результаты как:

```text
DVR_NODE_ID
DVR_NODE_TOKEN
DVR_NODE_MEDIA_SECRET
```

### 4. Запустите установщик

Интерактивно:

```bash
cd /opt/newdomofon-video-node
bash scripts/deploy-node.sh
```

Неинтерактивно:

```bash
PROJECT_DIR=/opt/newdomofon-video-node \
ENV_FILE=/etc/newdomofon-video/app.env \
  bash scripts/deploy-node.sh \
    --master-url https://video.example.com \
    --node-id 11111111-2222-4333-8444-555555555555 \
    --node-token NODE_TOKEN_CHOSEN_BY_OPERATOR_32 \
    --media-secret MEDIA_SECRET_CHOSEN_BY_OPERATOR_32 \
    --public-url http://10.0.0.31 \
    --internal-url http://10.0.0.31:3010 \
    --non-interactive
```

Master не обязан быть доступен при установке. До создания записи на master heartbeat может получать `401/404`, но локальный DVR должен работать.

### 5. Проверьте node

```bash
systemctl is-active newdomofon-video-dvr.service
curl -fsS http://127.0.0.1:3010/health | jq
journalctl -u newdomofon-video-dvr.service -n 200 --no-pager

stat -c '%A %U:%G %n' \
  /root/newdomofon-node-master-registration.env
```

### 6. Создайте запись на master

```bash
cat /root/newdomofon-node-master-registration.env
```

В UI master введите все шесть значений посимвольно. После следующего heartbeat node станет `online` и получит назначенные камеры.

## `.env`

Шаблон:

```text
deploy/env/node.env.example
```

Рабочий файл:

```text
/etc/newdomofon-video/app.env
```

Каждая переменная подробно описана в [docs/ENVIRONMENT.md](docs/ENVIRONMENT.md). В самом `node.env.example` также добавлен комментарий перед каждым параметром.

Рекомендуемые права:

```bash
chown root:newdomofon /etc/newdomofon-video/app.env
chmod 0640 /etc/newdomofon-video/app.env
```

После изменений:

```bash
systemctl restart newdomofon-video-dvr.service
```

Не выводите `app.env` в общие логи и чаты.

## Archive disk и disk guard

Рекомендуется монтировать отдельный filesystem прямо в:

```text
/var/lib/newdomofon-video/dvr
```

Если диск обязателен:

```text
DVR_DISK_REQUIRE_MOUNTPOINT=true
```

Guard начинает аварийную очистку ниже `max(10 GiB, 10%)` и возобновляет запись после `max(15 GiB, 15%)`.

Проверка:

```bash
cat /run/newdomofon-video/node-disk-state.json | jq
systemctl status newdomofon-video-node-disk-guard.timer --no-pager
journalctl -u newdomofon-video-node-disk-guard.service -n 200 --no-pager
```

## События

SQLite:

```text
/var/lib/newdomofon-video/events/events.sqlite3
```

Проверка:

```bash
sqlite3 /var/lib/newdomofon-video/events/events.sqlite3 \
  'PRAGMA integrity_check;'
```

Archive/event sync по умолчанию работает в dry-run:

```text
DVR_ARCHIVE_EVENT_SYNC_APPLY=false
```

Включайте apply только после проверки `candidate_events`.

## Recorder и media

```bash
curl -fsS http://127.0.0.1:3010/recorders | jq
pgrep -af ffmpeg || true

find /var/lib/newdomofon-video/dvr \
  -type f \( -name '*.ts' -o -name '*.m3u8' \) \
  -printf '%TY-%Tm-%Td %TH:%TM:%TS %p\n' \
  | sort | tail -30
```

Node media endpoints требуют внутренний token master, если:

```text
DVR_REQUIRE_MEDIA_TOKEN=true
```

Публичные managed tokens проверяются только на master.

## Безопасное обновление

Сначала обновляются все node, затем master.

```bash
cd /opt/newdomofon-video-node

STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="/opt/newdomofon-video-migration-backups/node-update-$STAMP"
install -d -m 0750 "$BACKUP"

cp -a /etc/newdomofon-video/app.env "$BACKUP/app.env"
git status --short >"$BACKUP/git-status.txt"
git diff --binary >"$BACKUP/worktree.patch"
git stash push -u -m "before-node-update-$STAMP" || true

git fetch --prune origin
git switch main
git reset --hard origin/main

PROJECT_DIR=/opt/newdomofon-video-node \
ENV_FILE=/etc/newdomofon-video/app.env \
  bash scripts/deploy-node.sh --non-interactive
```

Старый stash не восстанавливайте автоматически.

После обновления:

```bash
curl -fsS http://127.0.0.1:3010/health | jq
curl -fsS http://127.0.0.1:3010/recorders | jq
systemctl is-active newdomofon-video-dvr.service
```

## Backup

```bash
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="/opt/newdomofon-video-backups/node-$STAMP"
install -d -m 0750 "$BACKUP"

cp -a /etc/newdomofon-video "$BACKUP/"
cp -a /root/newdomofon-node-master-registration.env "$BACKUP/" 2>/dev/null || true

sqlite3 /var/lib/newdomofon-video/events/events.sqlite3 \
  ".backup '$BACKUP/events.sqlite3'"

git -C /opt/newdomofon-video-node rev-parse HEAD \
  >"$BACKUP/git-commit.txt"
```

Backup содержит secrets и должен храниться с ограниченными правами.

## Диагностика

### Node offline/warning на master

```bash
systemctl status newdomofon-video-dvr.service --no-pager
curl -fsS http://127.0.0.1:3010/health | jq
journalctl -u newdomofon-video-dvr.service --since '-15 minutes' --no-pager
```

Проверьте совпадение `DVR_MASTER_URL`, `DVR_NODE_ID`, `DVR_NODE_TOKEN`, URLs и синхронизацию времени.

### DVR падает с `ERR_MODULE_NOT_FOUND`

```bash
cd /opt/newdomofon-video-node
PROJECT_DIR=/opt/newdomofon-video-node \
ENV_FILE=/etc/newdomofon-video/app.env \
INSTALL_DISK_GUARD=0 \
INSTALL_ARCHIVE_EVENT_SYNC=0 \
  bash scripts/deploy-node.sh --non-interactive
```

Актуальный deploy отдельно проверяет runtime import `express` и права `node_modules` для пользователя `newdomofon`.

### Архив удаляется раньше retention

```bash
cat /run/newdomofon-video/node-disk-state.json | jq
journalctl -u newdomofon-video-node-disk-guard.service --since '-24 hours' --no-pager
```

Disk guard имеет приоритет над retention при нехватке места.

## Root-only installer из архива

`scripts/install-node-local-root.sh` — специальный сценарий установки из source tree внутри `/root`, где сервис работает от root. Для новых установок credentials всё равно выбираются оператором и передаются через:

```text
--node-id
--node-token
--media-secret
```

Не используйте старый master-generated bootstrap JSON как обязательную часть новой схемы.

## Безопасность

- не публикуйте `app.env` и registration file;
- разрешайте `3010/tcp` только master;
- используйте private network/VPN;
- оставляйте `DVR_REQUIRE_MEDIA_TOKEN=true`;
- не храните camera credentials в shell history;
- не запускайте `npm audit fix` автоматически на production;
- используйте `DVR_DISK_REQUIRE_MOUNTPOINT=true`, если archive disk обязателен;
- при утечке вручную задайте одинаковые новые token/media secret на node и master.
