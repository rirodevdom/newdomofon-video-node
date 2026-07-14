# NewDomofon Video Node

Самостоятельный **data plane** системы NewDomofon Video: подключение к камерам, FFmpeg recorder, live HLS, MPEG-TS, DASH, JPEG snapshot, локальный архив, MP4 export и локальное SQLite/WAL-хранилище событий.

Этот репозиторий устанавливается **только на video node**. Пользователи, RBAC, устройства, камеры, назначения node и управляемые внешние токены хранятся на master из репозитория `rirodevdom/newdomofon-video-master`.

> Production: Debian 12, Node.js 22, FFmpeg, Nginx и systemd. Docker и PostgreSQL для runtime node не требуются.

---

## Содержание

1. [Текущая архитектура](#текущая-архитектура)
2. [Что выполняет node](#что-выполняет-node)
3. [Runtime-пути и структура архива](#runtime-пути-и-структура-архива)
4. [Требования и расчёт диска](#требования-и-расчёт-диска)
5. [Порты и сеть](#порты-и-сеть)
6. [Подготовка node на master](#подготовка-node-на-master)
7. [Полная установка node на Debian 12](#полная-установка-node-на-debian-12)
8. [Проверка recorder и media](#проверка-recorder-и-media)
9. [Роль node в автоматическом RTSP](#роль-node-в-автоматическом-rtsp)
10. [События и SQLite](#события-и-sqlite)
11. [Синхронизация событий с архивом](#синхронизация-событий-с-архивом)
12. [Disk guard](#disk-guard)
13. [Безопасное обновление](#безопасное-обновление)
14. [Backup и перенос диска](#backup-и-перенос-диска)
15. [Диагностика](#диагностика)
16. [Безопасность](#безопасность)

---

# Текущая архитектура

```text
Пользователь / SmartYard / VLC
              |
              | HTTPS / RTSP к master
              v
+-----------------------------------------------+
| MASTER                                        |
| PostgreSQL, UI, RBAC, managed tokens          |
| HTTPS media gateway                           |
| MediaMTX RTSP gateway                         |
+-----------------------------------------------+
              |
              | node-agent config/commands
              | short-lived HMAC media tokens
              | private HTTP 3010
              v
+-----------------------------------------------+
| VIDEO NODE                                    |
| DVR engine :3010                              |
| FFmpeg recorder                               |
| HLS / MPEG-TS / DASH / JPEG                   |
| archive / ranges / MP4 export                 |
| SQLite/WAL events                             |
| disk guard                                    |
| archive/event synchronizer                    |
+-----------------------------------------------+
              |
              | RTSP / ONVIF / Hikvision
              v
           Камеры / NVR
```

Node не принимает решения о пользовательском доступе. Master проверяет RBAC или managed token и выдаёт короткоживущий внутренний node token с нужным scope.

---

# Что выполняет node

Node отвечает за:

- получение назначенных камер с master;
- heartbeat и выполнение `reload_cameras`;
- безопасную подстановку device credentials в RTSP URL в памяти;
- FFmpeg recorder без транскодирования при совместимом source;
- live HLS playlist;
- непрерывный MPEG-TS endpoint;
- on-demand DASH;
- JPEG snapshot с коротким cache;
- локальный архив и archive ranges;
- MP4 export и preview source;
- защищённый RTSP relay source для MediaMTX на master;
- ONVIF PullPoint, Hikvision и video-motion events;
- SQLite/WAL event store;
- очистку старых событий;
- синхронизацию событий с реально существующим архивом;
- аварийную защиту archive и system filesystem.

Node не должна:

- подключаться к PostgreSQL master;
- хранить пользователей и RBAC;
- публиковать `media_secret`;
- принимать внешний managed token напрямую;
- запускать master backend;
- использовать checkout master;
- запускать MediaMTX, если RTSP gateway установлен на master.

---

# Runtime-пути и структура архива

## Production-пути

```text
/opt/newdomofon-video-node/                    Git checkout
/etc/newdomofon-video/app.env                  secrets/runtime config
/var/lib/newdomofon-video/dvr/                 live и архив
/var/lib/newdomofon-video/events/events.sqlite3
/var/lib/newdomofon-video/events/events.sqlite3-wal
/var/lib/newdomofon-video/events/events.sqlite3-shm
/var/lib/newdomofon-video/events/archive-event-sync-state.json
/run/newdomofon-video/node-disk-state.json
/run/newdomofon-video/node-disk-paused
/var/log/newdomofon-video/
/etc/nginx/sites-available/newdomofon-video-node.conf
/etc/systemd/system/newdomofon-video-dvr.service
```

## Структура live и архива

```text
/var/lib/newdomofon-video/dvr/
└── entrance_main/
    ├── live.m3u8
    ├── live-000001.ts
    ├── dash/
    │   ├── live.mpd
    │   └── *.m4s
    ├── .formats/
    │   └── snapshot.jpg
    └── 2026-07-14/
        ├── 10/
        │   ├── 20260714_100001.ts
        │   └── ...
        └── 11/
            └── ...
```

Disk guard удаляет только завершённые каталоги:

```text
<stream>/<YYYY-MM-DD>/<HH>
```

Текущий час и live files не удаляются.

---

# Требования и расчёт диска

## Рекомендуемый минимум

```text
Debian 12 x86_64
4 CPU cores
4–8 GB RAM
20–40 GB system SSD
отдельный HDD/SSD/NVMe под DVR_ROOT
Node.js 22
FFmpeg
Nginx
московское время Europe/Moscow на master и всех node
```

## Расчёт архива

Приблизительно:

```text
GB/day ≈ bitrate_Mbit × 10.8
```

| Bitrate камеры | Сутки | 7 суток | 30 суток |
|---:|---:|---:|---:|
| 2 Mbit/s | 21.6 GB | 151 GB | 648 GB |
| 4 Mbit/s | 43.2 GB | 302 GB | 1.30 TB |
| 8 Mbit/s | 86.4 GB | 605 GB | 2.59 TB |
| 12 Mbit/s | 129.6 GB | 907 GB | 3.89 TB |

Для нескольких камер:

```text
required ≈ Σ(camera_GB_per_day × retention_days) + 15–20% reserve
```

Запас нужен для live window, текущего часа, SQLite WAL, DASH, export и filesystem metadata.

---

# Порты и сеть

## Входящие

```text
22/tcp    SSH, только администраторы
3010/tcp  DVR engine, только master/private network
80/443    опциональный Nginx endpoint node
```

Если master использует `DVR_NODE_INTERNAL_URL=http://10.0.0.31:3010`, порт `3010` не должен быть доступен из интернета.

## Исходящие

Node должна иметь доступ:

- к master по HTTPS;
- к DNS и NTP;
- к RTSP камер, обычно `554/tcp`;
- к ONVIF HTTP/HTTPS ports;
- к Hikvision ISAPI/alertStream;
- к GitHub/NodeSource только во время установки и обновления.

Пример UFW:

```bash
ufw allow from 10.0.0.30 to any port 3010 proto tcp comment 'NewDomofon master'
ufw allow from ADMIN_IP to any port 22 proto tcp
ufw enable
```

---

# Подготовка node на master

Перед установкой node создайте её на master:

```text
Администрирование → Nodes → Добавить node
```

Сохраните bootstrap credentials:

```text
node_id
agent_token
media_secret
```

Рекомендуемый файл:

```text
/root/video-node1-bootstrap.json
```

Пример структуры:

```json
{
  "node_id": "UUID",
  "agent_token": "SECRET",
  "media_secret": "SECRET"
}
```

Передавайте файл только через защищённый канал и установите:

```bash
chmod 600 /root/video-node1-bootstrap.json
```

---

# Полная установка node на Debian 12

Все команды выполняются от `root`.

Ниже приведены два сетевых варианта:

```text
Вариант A: master использует private HTTP 3010 — рекомендуется.
Вариант B: node имеет отдельный DNS/TLS и master использует HTTPS.
```

## 1. Задайте переменные

Пример для private node:

```bash
export NODE_NAME="video-node1"
export NODE_PRIVATE_IP="10.0.0.31"
export MASTER_DOMAIN="video.example.com"
export NODE_REPO="https://github.com/rirodevdom/newdomofon-video-node.git"
export NODE_DIR="/opt/newdomofon-video-node"
export DVR_ROOT="/var/lib/newdomofon-video/dvr"
export BOOTSTRAP_FILE="/root/video-node1-bootstrap.json"
```

Для текущего production домена можно использовать:

```bash
export MASTER_DOMAIN="new-video.domofon-37.ru"
```

## 2. Обновите Debian и установите московское время

```bash
apt-get update
apt-get dist-upgrade -y
apt-get install -y git ca-certificates curl openssl jq rsync
reboot
```

После повторного подключения:

```bash
cat /etc/debian_version
uname -a

timedatectl set-timezone Europe/Moscow
systemctl enable --now systemd-timesyncd
timedatectl status
date '+%Y-%m-%d %H:%M:%S %Z %z'
```

Ожидаемая временная зона:

```text
Time zone: Europe/Moscow
MSK +0300
```

Master и все video node должны использовать московское время (`Europe/Moscow`), чтобы временные метки архивных каталогов, событий и журналов совпадали. После изменения временной зоны перезапуск DVR service не требуется.

## 3. Подготовьте отдельный DVR-диск

Сначала определите диск:

```bash
lsblk -o NAME,SIZE,FSTYPE,UUID,MOUNTPOINTS,MODEL,SERIAL
```

> Следующий пример форматирует `/dev/sdb1`. Не выполняйте `mkfs`, если диск содержит данные.

```bash
mkfs.ext4 -L NEWDOMOFON_DVR /dev/sdb1

install -d -m 0750 "$DVR_ROOT"
DVR_UUID="$(blkid -s UUID -o value /dev/sdb1)"
test -n "$DVR_UUID"

echo "UUID=${DVR_UUID} ${DVR_ROOT} ext4 defaults,noatime 0 2" \
  >>/etc/fstab

mount -a
findmnt "$DVR_ROOT"
df -hT "$DVR_ROOT"
df -ih "$DVR_ROOT"
```

Используйте UUID, а не `/dev/sdX`.

Если архив хранится на root filesystem, позже установите:

```text
DVR_DISK_REQUIRE_MOUNTPOINT=false
```

Если `DVR_ROOT` обязан быть отдельным mount:

```text
DVR_DISK_REQUIRE_MOUNTPOINT=true
```

## 4. Клонируйте repository

```bash
install -d -m 0755 /opt
git clone "$NODE_REPO" "$NODE_DIR"
cd "$NODE_DIR"
git switch main
git pull --ff-only origin main

git log -1 --oneline
git status --short
```

Не используйте master repository на node.

## 5. Установите зависимости

```bash
cd "$NODE_DIR"
bash scripts/install-debian12-prereqs.sh
```

Проверка:

```bash
node --version
npm --version
ffmpeg -version | head -1
nginx -v
id newdomofon
```

Prerquisites script может установить PostgreSQL packages для совместимости старых helper scripts, но runtime node PostgreSQL не использует.

## 6. Проверьте bootstrap JSON

```bash
chmod 600 "$BOOTSTRAP_FILE"

jq '{
  node_id,
  has_agent_token:(.agent_token|type=="string" and length>0),
  has_media_secret:(.media_secret|type=="string" and length>0)
}' "$BOOTSTRAP_FILE"
```

Ожидается:

```json
{
  "has_agent_token": true,
  "has_media_secret": true
}
```

## 7. Создайте production environment

```bash
NODE_ID="$(jq -r '.node_id' "$BOOTSTRAP_FILE")"
NODE_TOKEN="$(jq -r '.agent_token' "$BOOTSTRAP_FILE")"
NODE_MEDIA_SECRET="$(jq -r '.media_secret' "$BOOTSTRAP_FILE")"

for value in "$NODE_ID" "$NODE_TOKEN" "$NODE_MEDIA_SECRET"; do
  test -n "$value"
  test "$value" != null
done

install -d -o root -g newdomofon -m 0750 /etc/newdomofon-video

cat >/etc/newdomofon-video/app.env <<EOF
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

DVR_MASTER_URL=https://${MASTER_DOMAIN}
DVR_NODE_ID=${NODE_ID}
DVR_NODE_TOKEN=${NODE_TOKEN}
DVR_NODE_MEDIA_SECRET=${NODE_MEDIA_SECRET}
DVR_NODE_INTERNAL_URL=http://${NODE_PRIVATE_IP}:3010
DVR_NODE_PUBLIC_BASE_URL=http://${NODE_PRIVATE_IP}:3010
DVR_REQUIRE_MEDIA_TOKEN=true
DVR_CORS_ORIGIN=https://${MASTER_DOMAIN}

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
DVR_ARCHIVE_EVENT_SYNC_APPLY=false
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
DVR_DISK_REQUIRE_MOUNTPOINT=true

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
EOF

chown root:newdomofon /etc/newdomofon-video/app.env
chmod 0640 /etc/newdomofon-video/app.env
```

Проверьте файл без вывода секретов:

```bash
namei -l /etc/newdomofon-video/app.env
sudo -u newdomofon test -r /etc/newdomofon-video/app.env
```

## 8. Подготовьте runtime-каталоги

```bash
install -d -o newdomofon -g newdomofon -m 0750 \
  /var/lib/newdomofon-video/dvr \
  /var/lib/newdomofon-video/events

install -d -o newdomofon -g newdomofon -m 0755 \
  /var/log/newdomofon-video

chown -R newdomofon:newdomofon \
  /var/lib/newdomofon-video/dvr \
  /var/lib/newdomofon-video/events

findmnt "$DVR_ROOT"
df -hT "$DVR_ROOT"
df -ih "$DVR_ROOT"
```

## 9. Первый deploy

```bash
cd "$NODE_DIR"

PROJECT_DIR="$NODE_DIR" \
ENV_FILE=/etc/newdomofon-video/app.env \
INSTALL_DISK_GUARD=1 \
INSTALL_JOURNAL_LIMITS=1 \
INSTALL_ARCHIVE_EVENT_SYNC=1 \
  bash scripts/deploy-node.sh
```

Deploy выполняет:

1. disk preflight;
2. `npm ci --include=dev`;
3. TypeScript build;
4. `npm prune --omit=dev`;
5. установку DVR systemd unit;
6. установку Nginx template;
7. установку disk guard timer;
8. установку journald limits;
9. установку archive/event sync timer;
10. initial sync в безопасном режиме;
11. запуск DVR service;
12. проверку Nginx config.

## 10. Проверка service

```bash
systemctl is-enabled newdomofon-video-dvr.service
systemctl is-active newdomofon-video-dvr.service

curl -fsS http://127.0.0.1:3010/health | jq
curl -fsS http://127.0.0.1:3010/recorders | jq

journalctl -u newdomofon-video-dvr.service -n 200 --no-pager
```

Ожидается:

```text
service=dvr-engine
mode=node
recording_enabled=true
```

## 11. Private-only node

Если master обращается к `10.0.0.31:3010`, отдельный node domain и TLS не обязательны. Ограничьте порт firewall-правилом и не публикуйте его наружу.

## 12. Node с отдельным DNS/TLS

```bash
export NODE_DOMAIN="video-node1.example.com"

sed -i \
  "s/server_name _;/server_name ${NODE_DOMAIN};/" \
  /etc/nginx/sites-available/newdomofon-video-node.conf

nginx -t
systemctl reload nginx

apt-get install -y certbot python3-certbot-nginx
certbot --nginx -d "$NODE_DOMAIN"
certbot renew --dry-run
```

После этого измените:

```text
DVR_NODE_PUBLIC_BASE_URL=https://video-node1.example.com
```

и при необходимости `internal_url` node на master.

---

# Проверка recorder и media

## Heartbeat на master

В UI node должна стать `online`, а `last_seen_at` должен обновляться.

## Recorder

```bash
curl -fsS http://127.0.0.1:3010/recorders \
  | jq '.items[] | {stream_name,recording,restarts,last_error}'
```

Для конкретной камеры:

```bash
curl -fsS http://127.0.0.1:3010/cameras/entrance_main/status | jq
```

## Live filesystem

```bash
find /var/lib/newdomofon-video/dvr/entrance_main \
  -maxdepth 2 -type f -printf '%TY-%Tm-%Td %TH:%TM:%TS %s %p\n' \
  | sort | tail -30
```

## Защищённые endpoints

Node принимает только внутренний media token, выпущенный master:

```text
GET /cameras/<stream>/live.m3u8
GET /cameras/<stream>/live.ts
GET /cameras/<stream>/rtsp-relay.ts
GET /cameras/<stream>/live.mpd
GET /cameras/<stream>/dash/<segment>.m4s
GET /cameras/<stream>/snapshot.jpg
GET /cameras/<stream>/archive.m3u8
GET /cameras/<stream>/archive/ranges
GET /cameras/<stream>/export.mp4
GET /files/<stream>/<file>
```

Публичные managed tokens проверяются на master, а не на node.

## Проверка MPEG-TS через master

Скопируйте URL из `Администрирование → Ссылки`:

```bash
timeout 8 curl -ksS "$MPEG_TS_URL" -o /tmp/live.ts || true
file /tmp/live.ts
ls -lh /tmp/live.ts
```

## Проверка DASH

```bash
curl -ksS "$DASH_URL" -o /tmp/live.mpd
grep -m1 '<MPD' /tmp/live.mpd
```

## Проверка JPEG

```bash
curl -ksS "$JPEG_URL" -o /tmp/snapshot.jpg
file /tmp/snapshot.jpg
```

---

# Роль node в автоматическом RTSP

MediaMTX устанавливается на master. Node предоставляет только стабильный внутренний источник:

```text
/cameras/<stream>/rtsp-relay.ts
```

Цепочка:

```text
RTSP client
→ MediaMTX on master
→ backend auth token↔camera
→ runOnDemand
→ master source resolver
→ node rtsp-relay.ts
→ FFmpeg stream copy
→ MediaMTX
→ client
```

Endpoint читает локальный `live.m3u8`, поэтому не создаёт дополнительное RTSP-подключение непосредственно к камере.

FFmpeg relay завершается только при реальном disconnect клиента. Если процесс не завершается по `SIGTERM`, выполняется `SIGKILL`.

При обновлении автоматического RTSP всегда соблюдайте порядок:

```text
1. Node
2. Master
3. Проверка RTSP из вкладки «Ссылки»
```

Проверка RTSP:

```bash
timeout 30 ffprobe \
  -v error \
  -rtsp_transport tcp \
  -show_entries stream=index,codec_type,codec_name,width,height \
  -of json \
  "$RTSP_URL" | jq
```

Во время подключения на node:

```bash
ps auxww | grep -E 'rtsp-relay\.ts|ffmpeg' | grep -v grep
```

---

# События и SQLite

Основная база:

```text
/var/lib/newdomofon-video/events/events.sqlite3
```

Режим:

```text
SQLite WAL
```

Проверка файлов:

```bash
ls -lh /var/lib/newdomofon-video/events/
```

Проверка базы:

```bash
sqlite3 /var/lib/newdomofon-video/events/events.sqlite3 \
  'PRAGMA integrity_check;'
```

События остаются на node. Master получает timeline через защищённый Event API и не копирует payload в PostgreSQL.

Источники:

- ONVIF PullPoint;
- Hikvision alertStream;
- FFmpeg video-motion;
- device archive indexer.

---

# Синхронизация событий с архивом

Сервис:

```text
newdomofon-video-archive-event-sync.service
newdomofon-video-archive-event-sync.timer
```

Он удаляет event markers только для завершённых local-archive часов, в которых больше нет ни одного playable segment.

Fail-closed условия:

- master config недоступен;
- DVR mount отсутствует;
- disk guard critical;
- node paused;
- camera использует `archive_storage=device`;
- проверяемый час слишком свежий.

## Dry-run

```bash
sudo -u newdomofon bash -lc '
set -a
. /etc/newdomofon-video/app.env
set +a
/usr/bin/node /usr/local/lib/newdomofon-video/reconcile-archive-events.mjs --dry-run
' | jq
```

Для одного stream:

```bash
sudo -u newdomofon bash -lc '
set -a
. /etc/newdomofon-video/app.env
set +a
/usr/bin/node /usr/local/lib/newdomofon-video/reconcile-archive-events.mjs \
  --dry-run --stream entrance_main
' | jq
```

## Apply после проверки

```bash
sudo -u newdomofon bash -lc '
set -a
. /etc/newdomofon-video/app.env
set +a
/usr/bin/node /usr/local/lib/newdomofon-video/reconcile-archive-events.mjs --apply
' | jq
```

Для постоянного apply:

```text
DVR_ARCHIVE_EVENT_SYNC_APPLY=true
```

После изменения environment:

```bash
systemctl restart newdomofon-video-archive-event-sync.timer
systemctl start newdomofon-video-archive-event-sync.service
```

Состояние:

```bash
cat /var/lib/newdomofon-video/events/archive-event-sync-state.json | jq
journalctl -u newdomofon-video-archive-event-sync.service -n 200 --no-pager
```

---

# Disk guard

Сервисы:

```text
newdomofon-video-node-disk-guard.service
newdomofon-video-node-disk-guard.timer
```

Default emergency policy:

```text
critical при free < max(10 GiB, 10%)
cleanup до free >= max(15 GiB, 15%)
```

Guard:

- удаляет oldest completed archive-hour directories;
- не удаляет текущий час;
- не удаляет live playlist;
- удаляет не более `DVR_DISK_MAX_DELETE_DIRS_PER_RUN` каталогов;
- останавливает DVR, если безопасно восстановить запас невозможно;
- создаёт `/run/newdomofon-video/node-disk-paused`;
- автоматически возобновляет service после восстановления диска.

Проверка:

```bash
cat /run/newdomofon-video/node-disk-state.json | jq
systemctl list-timers '*node-disk*' --no-pager
journalctl -u newdomofon-video-node-disk-guard.service -n 200 --no-pager
```

Не удаляйте pause marker вручную до устранения причины заполнения.

---

# Безопасное обновление

## Полное обновление node

```bash
set +e
set +u
set +E
set +o pipefail

PROJECT="/opt/newdomofon-video-node"
SERVICE="newdomofon-video-dvr.service"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="/opt/newdomofon-video-migration-backups/node-update-$STAMP"

install -d -m 0750 "$BACKUP"

git -C "$PROJECT" status --short >"$BACKUP/git-status-before.txt" || true
git -C "$PROJECT" diff --binary >"$BACKUP/worktree-before.patch" || true
git -C "$PROJECT" rev-parse HEAD >"$BACKUP/commit-before.txt"
cp -a /etc/newdomofon-video/app.env "$BACKUP/app.env.before"

if [ -d "$PROJECT/dvr-engine/dist" ]; then
  cp -a "$PROJECT/dvr-engine/dist" "$BACKUP/dist-before"
fi

git -C "$PROJECT" stash push -u \
  -m "before-node-update-$STAMP" || true

git -C "$PROJECT" fetch origin main
git -C "$PROJECT" switch main
git -C "$PROJECT" reset --hard origin/main

cd "$PROJECT/dvr-engine"
npm ci --include=dev
npm run build
npm prune --omit=dev

systemctl restart "$SERVICE"

for _ in $(seq 1 60); do
  curl -fsS --max-time 3 http://127.0.0.1:3010/health && break
  sleep 1
done

git -C "$PROJECT" log -1 --oneline
git -C "$PROJECT" status --short
systemctl is-active "$SERVICE"

echo "Backup: $BACKUP"
```

Ошибка внутри этого дочернего shell не должна закрывать SSH session.

## После обновления

```bash
curl -fsS http://127.0.0.1:3010/health | jq
curl -fsS http://127.0.0.1:3010/recorders | jq
systemctl is-active newdomofon-video-dvr.service
systemctl is-active newdomofon-video-node-disk-guard.timer
systemctl is-active newdomofon-video-archive-event-sync.timer
```

---

# Backup и перенос диска

## Конфигурация

```bash
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="/opt/newdomofon-video-backups/node-$STAMP"
install -d -m 0750 "$BACKUP"

cp -a /etc/newdomofon-video "$BACKUP/"
cp -a /etc/nginx/sites-available/newdomofon-video-node.conf "$BACKUP/" 2>/dev/null || true
cp -a /etc/systemd/system/newdomofon-video-*.service "$BACKUP/" 2>/dev/null || true
cp -a /etc/systemd/system/newdomofon-video-*.timer "$BACKUP/" 2>/dev/null || true

git -C /opt/newdomofon-video-node rev-parse HEAD \
  >"$BACKUP/git-commit.txt"
```

## SQLite online backup

```bash
sqlite3 /var/lib/newdomofon-video/events/events.sqlite3 \
  ".backup '$BACKUP/events.sqlite3'"
```

## Перенос DVR-диска

1. остановите DVR;
2. остановите disk guard timer;
3. скопируйте архив с сохранением прав;
4. измените `/etc/fstab`;
5. смонтируйте новый filesystem;
6. проверьте ownership;
7. запустите guard;
8. запустите DVR.

```bash
systemctl stop newdomofon-video-dvr.service
systemctl stop newdomofon-video-node-disk-guard.timer

rsync -aHAX --numeric-ids --info=progress2 \
  /var/lib/newdomofon-video/dvr/ \
  /mnt/new-dvr/

findmnt /var/lib/newdomofon-video/dvr
df -hT /var/lib/newdomofon-video/dvr
chown -R newdomofon:newdomofon /var/lib/newdomofon-video/dvr

systemctl start newdomofon-video-node-disk-guard.timer
systemctl start newdomofon-video-node-disk-guard.service
systemctl start newdomofon-video-dvr.service
```

---

# Диагностика

## Node offline на master

```bash
set -a
. /etc/newdomofon-video/app.env
set +a

curl -vk "$DVR_MASTER_URL/api/health"
journalctl -u newdomofon-video-dvr.service --since "15 minutes ago" --no-pager
```

Проверьте `DVR_NODE_ID`, `DVR_NODE_TOKEN`, DNS, московское время и TLS.

## Recorder не запускается

```bash
curl -fsS http://127.0.0.1:3010/recorders | jq
journalctl -u newdomofon-video-dvr.service -n 400 --no-pager \
  | grep -Ei 'ffmpeg|rtsp|401|403|timeout|error'
```

Проверьте source URL и credentials внутри устройства на master.

## Live playlist отсутствует

```bash
find /var/lib/newdomofon-video/dvr -maxdepth 2 \
  -name live.m3u8 -printf '%TY-%Tm-%Td %TH:%TM:%TS %p\n'
```

## MPEG-TS/RTSP relay обрывается

```bash
journalctl -u newdomofon-video-dvr.service --since "15 minutes ago" --no-pager \
  | grep -Ei 'live-ts|rtsp-relay|ffmpeg|error'

ps auxww | grep -E 'rtsp-relay\.ts|ffmpeg' | grep -v grep
```

## Архив исчезает быстрее retention

```bash
cat /run/newdomofon-video/node-disk-state.json | jq
journalctl -u newdomofon-video-node-disk-guard.service --since "24 hours ago" --no-pager
```

Disk guard имеет приоритет над retention при аварийном заполнении.

## События остаются без архива

```bash
systemctl start newdomofon-video-archive-event-sync.service
cat /var/lib/newdomofon-video/events/archive-event-sync-state.json | jq
journalctl -u newdomofon-video-archive-event-sync.service -n 200 --no-pager
```

---

# Безопасность

- не публикуйте bootstrap JSON и `app.env`;
- разрешайте `3010/tcp` только master;
- используйте private network или VPN между master и node;
- используйте `Europe/Moscow` на master и всех node и синхронизируйте время;
- после утечки выполните rotation node credentials на master;
- не храните credentials камер в shell history;
- `DVR_DISK_REQUIRE_MOUNTPOINT=true` защищает root filesystem при пропавшем DVR mount;
- не отключайте media token verification;
- не запускайте `npm audit fix` автоматически на production;
- делайте backup SQLite перед ручным event cleanup;
- обновляйте node перед master при изменениях media/RTSP.

---

## Актуальные возможности node

```text
Master-controlled camera configuration
Device-owned node/archive placement
FFmpeg recorder
HLS live and archive
Continuous MPEG-TS
On-demand DASH
Cached JPEG snapshot
MP4 export and preview source
Stable rtsp-relay.ts source for master MediaMTX
ONVIF/Hikvision/video-motion events
SQLite/WAL event storage
Archive/event lifecycle synchronization
Emergency disk guard
Heartbeat and remote reload commands
```
