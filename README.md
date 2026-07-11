# NewDomofon Video Node

Самостоятельный **data plane** системы NewDomofon Video: подключение к камерам, FFmpeg recorder, live HLS, локальный архив, MP4 export и локальное SQLite/WAL-хранилище событий.

Этот репозиторий предназначен только для **video node**. Пользователи, RBAC, устройства, камеры, назначения и управляемые внешние токены хранятся на master из репозитория [`rirodevdom/newdomofon-video-master`](https://github.com/rirodevdom/newdomofon-video-master).

> Production-платформа: Debian 12, Node.js 22, FFmpeg, Nginx, systemd. Docker и PostgreSQL для runtime node не требуются.

---

## Содержание

1. [Архитектура](#архитектура)
2. [Runtime-данные и компоненты](#runtime-данные-и-компоненты)
3. [Требования и расчёт диска](#требования-и-расчёт-диска)
4. [Порты и сетевой доступ](#порты-и-сетевой-доступ)
5. [Быстрый план установки](#быстрый-план-установки)
6. [Полная установка node на чистый Debian 12](#полная-установка-node-на-чистый-debian-12)
7. [Подключение камер и проверка recorder](#подключение-камер-и-проверка-recorder)
8. [Live, архив и MP4 export](#live-архив-и-mp4-export)
9. [ONVIF, Hikvision и video-motion события](#onvif-hikvision-и-video-motion-события)
10. [SQLite event store и Event API](#sqlite-event-store-и-event-api)
11. [Синхронизация событий с существующим архивом](#синхронизация-событий-с-существующим-архивом)
12. [Защита от заполнения диска](#защита-от-заполнения-диска)
13. [Проверка после установки](#проверка-после-установки)
14. [Безопасное обновление production](#безопасное-обновление-production)
15. [Backup, восстановление и перенос диска](#backup-восстановление-и-перенос-диска)
16. [Диагностика](#диагностика)
17. [Безопасность и масштабирование](#безопасность-и-масштабирование)
18. [Разработка и разделение репозиториев](#разработка-и-разделение-репозиториев)

---

# Архитектура

## Общая схема

```text
Браузер / SmartYard-Vue
          |
          | HTTPS к master
          v
+-----------------------------+
| MASTER                      |
| RBAC, PostgreSQL, UI        |
| managed tokens              |
| media/events gateway        |
+-----------------------------+
          |
          | node-agent config/commands
          | short-lived HMAC media/event token
          v
+-----------------------------+
| VIDEO NODE                  |
| DVR engine :3010            |
| FFmpeg recorder             |
| HLS/live/archive/export     |
| SQLite/WAL events           |
| disk guard                  |
| archive/event sync          |
+-----------------------------+
          |
          | RTSP / ONVIF / Hikvision
          v
       Камеры / NVR
```

## Node отвечает за

- получение назначенных камер с master;
- подключение к RTSP-потокам;
- безопасную подстановку device/ONVIF credentials в FFmpeg URL в памяти;
- запись HLS-сегментов через FFmpeg;
- live playlist;
- локальный DVR-архив;
- archive ranges;
- MP4 export и SmartYard preview export;
- ONVIF PullPoint events;
- Hikvision alertStream events;
- опциональный FFmpeg video-motion detector;
- локальную SQLite/WAL database событий;
- event retention;
- синхронизацию событий с реально существующим архивом;
- heartbeat, storage status и recorder diagnostics;
- выполнение команд `reload_cameras` от master;
- аварийную защиту от заполнения диска.

## Node не должна

- подключаться к PostgreSQL master;
- хранить пользователей и RBAC;
- самостоятельно принимать решение о пользовательском доступе;
- хранить master JWT;
- отправлять payload событий в PostgreSQL master;
- использовать общий checkout с master;
- зависеть от `newdomofon-video-backend.service`;
- использовать credentials другой node.

## Авторизация media/event запросов

1. Пользователь или SmartYard обращается к master.
2. Master проверяет managed token/RBAC и назначение камеры.
3. Master подписывает короткоживущий node token с нужным scope.
4. Node проверяет HMAC, stream, scope и срок действия.
5. Node отдаёт live, archive, export, file или events.

Broad `camera` scope разрешает операции воспроизведения, включая короткий MP4 export для preview. Event API принимает отдельный `events` scope.

## Контракты

```text
contracts/node-agent-api-v1.md
contracts/node-events-api-v1.md
```

---

# Runtime-данные и компоненты

## Production-пути

```text
/opt/newdomofon-video-node/                    Git checkout
/etc/newdomofon-video/app.env                  secrets и runtime config
/var/lib/newdomofon-video/dvr/                 live и архив
/var/lib/newdomofon-video/events/events.sqlite3
/var/lib/newdomofon-video/events/events.sqlite3-wal
/var/lib/newdomofon-video/events/events.sqlite3-shm
/var/lib/newdomofon-video/events/archive-event-sync-state.json
/run/newdomofon-video/node-disk-state.json
/run/newdomofon-video/node-disk-paused
/var/log/newdomofon-video/
/etc/nginx/sites-available/newdomofon-video-node.conf
```

## Типичная структура архива

```text
/var/lib/newdomofon-video/dvr/
└── entrance_main/
    ├── live.m3u8
    ├── live-*.ts
    └── 2026-07-11/
        ├── 20/
        │   ├── segment-....ts
        │   └── ...
        └── 21/
            └── ...
```

Аварийный disk guard удаляет только завершённые каталоги вида:

```text
<stream>/<YYYY-MM-DD>/<HH>
```

Текущий UTC-час не удаляется.

## Состав репозитория

```text
dvr-engine/            TypeScript recorder, media API, node agent, events
dvr-archive-proxy/     archive compatibility helpers
restreamer/            restream helper
restream-gateway/      restream gateway
live-only-engine/      live-only helper
contracts/             versioned master/node contracts
deploy/env/            environment example
deploy/nginx/          Nginx template
deploy/systemd/        service/timer units
deploy/journald/       journald limits
scripts/               install, deploy, guard, sync и diagnostics
```

---

# Требования и расчёт диска

## Рекомендуемая конфигурация

Для небольшой node:

```text
OS:       Debian 12 x86_64
CPU:      4 cores
RAM:      4–8 GB
System:   20–40 GB SSD
Archive:  отдельный HDD/SSD/NVMe filesystem
Node.js:  22.12+
FFmpeg:   Debian 12 package или совместимая новая версия
Proxy:    Nginx
Time:     systemd-timesyncd или chrony
```

CPU зависит от режима:

- stream copy HLS почти не транскодирует видео;
- MP4 export создаёт кратковременную нагрузку;
- video-motion detector заметно увеличивает CPU;
- device archive sessions используют дополнительные FFmpeg processes.

## Формула объёма

Приблизительный объём одной камеры:

```text
GB/day ≈ bitrate_Mbit × 10.8
```

Примеры:

| Bitrate | В сутки | 7 суток | 30 суток |
|---:|---:|---:|---:|
| 2 Mbit/s | 21.6 GB | 151 GB | 648 GB |
| 4 Mbit/s | 43.2 GB | 302 GB | 1.30 TB |
| 8 Mbit/s | 86.4 GB | 605 GB | 2.59 TB |
| 12 Mbit/s | 129.6 GB | 907 GB | 3.89 TB |

Для нескольких камер:

```text
required ≈ sum(camera_GB_per_day × retention_days)
```

Добавьте минимум 15–20% запаса для:

- live window;
- незавершённого текущего часа;
- SQLite WAL;
- MP4 export;
- device archive sessions;
- filesystem metadata;
- обновлений и журналов.

## Пример расчёта

16 камер по 4 Mbit/s, retention 14 дней:

```text
43.2 GB × 16 × 14 = 9676.8 GB
+ 20% reserve ≈ 11.6 TB
```

---

# Порты и сетевой доступ

## Публичные порты node

```text
22/tcp   SSH; только административные IP
80/tcp   HTTP/ACME
443/tcp  public node HTTPS, если используется direct media
```

## DVR engine

```text
3010/tcp DVR engine API
```

Порт `3010` разрешайте только master/private network. Публичным клиентам достаточно Nginx `443`.

## Nginx публикует

```text
/health
/cameras/
/files/
/device-archive/
```

## Исходящий доступ node

Node должна иметь:

- HTTPS к master;
- DNS resolution master;
- доступ к RTSP-портам камер, обычно `554/tcp`;
- доступ к ONVIF HTTP/HTTPS ports камер;
- доступ к Hikvision ISAPI/alertStream при использовании;
- NTP/time synchronization.

---

# Быстрый план установки

```text
1. Создать node на master и получить bootstrap JSON.
2. Подготовить Debian 12 и отдельный архивный диск.
3. Клонировать только node repository.
4. Запустить install-debian12-prereqs.sh.
5. Создать /etc/newdomofon-video/app.env.
6. Проверить mount и права.
7. Запустить deploy-node.sh.
8. Настроить Nginx domain и TLS.
9. Ограничить 3010 firewall-правилами.
10. Проверить heartbeat, recorder, live, archive и events.
11. Проверить disk guard.
12. Просмотреть archive-event sync в dry-run и только затем включить apply.
```

---

# Полная установка node на чистый Debian 12

Все команды ниже выполняются от `root`, если не указано иное.

## 1. Подготовьте переменные

```bash
export NODE_NAME="video-node1"
export NODE_DOMAIN="video-node1.example.com"
export NODE_PRIVATE_IP="10.0.0.31"
export MASTER_DOMAIN="video.example.com"
export NODE_REPO="https://github.com/rirodevdom/newdomofon-video-node.git"
export NODE_DIR="/opt/newdomofon-video-node"
export DVR_ROOT="/var/lib/newdomofon-video/dvr"
```

Проверка DNS и сети:

```bash
getent ahosts "$NODE_DOMAIN"
getent ahosts "$MASTER_DOMAIN"
ping -c 2 "$MASTER_DOMAIN" || true
```

## 2. Обновите Debian

```bash
apt-get update
apt-get dist-upgrade -y
apt-get install -y git ca-certificates curl openssl
reboot
```

После повторного подключения:

```bash
cat /etc/debian_version
uname -a
timedatectl set-timezone UTC
systemctl enable --now systemd-timesyncd
timedatectl status
```

## 3. Подготовьте архивный диск

Сначала определите устройство:

```bash
lsblk -o NAME,SIZE,FSTYPE,UUID,MOUNTPOINTS,MODEL,SERIAL
```

> Не форматируйте существующий диск с данными. Следующий пример предназначен только для нового пустого `/dev/sdb1`.

```bash
mkfs.ext4 -L NEWDOMOFON_DVR /dev/sdb1

install -d -m 0750 "$DVR_ROOT"

DVR_UUID="$(blkid -s UUID -o value /dev/sdb1)"
test -n "$DVR_UUID"

echo "UUID=${DVR_UUID} ${DVR_ROOT} ext4 defaults,noatime 0 2" \
  >> /etc/fstab

mount -a
findmnt "$DVR_ROOT"
df -hT "$DVR_ROOT"
```

Используйте UUID, а не `/dev/sdX`, потому что имена устройств могут измениться после reboot.

Если диск уже содержит архив, сначала смонтируйте его во временную точку и проверьте данные. Не выполняйте `mkfs`.

## 4. Клонируйте node repository

```bash
install -d -m 0755 /opt

git clone "$NODE_REPO" "$NODE_DIR"
cd "$NODE_DIR"
git switch main
git pull --ff-only origin main

git log -1 --oneline
git status --short
```

Node устанавливается только из:

```text
https://github.com/rirodevdom/newdomofon-video-node
```

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

Prerequisites script может установить PostgreSQL packages для совместимости старых вспомогательных scripts, но runtime node не подключается к PostgreSQL и не зависит от PostgreSQL service.

## 6. Получите bootstrap JSON с master

На master при создании node выдаются:

```text
node_id
agent_token
media_secret
```

Скопируйте JSON на node:

```text
/root/video-node1-bootstrap.json
```

Проверьте наличие полей без вывода секретов:

```bash
chmod 600 /root/video-node1-bootstrap.json

jq '{
  node_id,
  has_agent_token:(.agent_token|type=="string" and length>0),
  has_media_secret:(.media_secret|type=="string" and length>0)
}' /root/video-node1-bootstrap.json
```

## 7. Создайте production environment

```bash
NODE_ID="$(jq -r '.node_id' /root/video-node1-bootstrap.json)"
NODE_TOKEN="$(jq -r '.agent_token' /root/video-node1-bootstrap.json)"
NODE_MEDIA_SECRET="$(jq -r '.media_secret' /root/video-node1-bootstrap.json)"

for value in "$NODE_ID" "$NODE_TOKEN" "$NODE_MEDIA_SECRET"; do
  test -n "$value"
  test "$value" != null
done

install -d -o root -g newdomofon -m 0750 \
  /etc/newdomofon-video

cat > /etc/newdomofon-video/app.env <<EOF
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
DVR_NODE_PUBLIC_BASE_URL=https://${NODE_DOMAIN}
DVR_NODE_INTERNAL_URL=http://${NODE_PRIVATE_IP}:3010
DVR_REQUIRE_MEDIA_TOKEN=true
DVR_CORS_ORIGIN=https://${MASTER_DOMAIN}

# Local SQLite events.
DVR_EVENT_DB=/var/lib/newdomofon-video/events/events.sqlite3
DVR_EVENT_RETENTION_DAYS=30
DVR_EVENT_CLEANUP_INTERVAL_MINUTES=60
DVR_EVENT_QUERY_MAX_SECONDS=2678400
DVR_EVENT_STORE_RAW_PAYLOAD=false

# ONVIF/Hikvision/video motion.
ONVIF_EVENTS_ENABLED=true
ONVIF_EVENTS_REQUEST_TIMEOUT_MS=15000
DVR_HIKVISION_EVENTS_ENABLED=false
VIDEO_MOTION_ENABLED=false

# Archive/event reconciliation. Safe dry-run by default.
DVR_ARCHIVE_EVENT_SYNC_ENABLED=true
DVR_ARCHIVE_EVENT_SYNC_APPLY=false
DVR_ARCHIVE_EVENT_SYNC_MIN_AGE_MINUTES=120
DVR_ARCHIVE_EVENT_SYNC_MAX_HOURS_PER_RUN=1000
DVR_ARCHIVE_EVENT_SYNC_MASTER_TIMEOUT_MS=15000

# Emergency DVR disk guard defaults.
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

# Hikvision/NVR device archive sessions.
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

### Когда `DVR_DISK_REQUIRE_MOUNTPOINT=true`

Используйте `true`, если `DVR_ROOT` обязан быть отдельным смонтированным filesystem. При пропавшем mount guard остановит DVR и не позволит писать архив в root filesystem.

Если `DVR_ROOT` намеренно расположен на root filesystem, укажите:

```text
DVR_DISK_REQUIRE_MOUNTPOINT=false
```

### Роль node

Актуальная переменная:

```text
DVR_ENGINE_ROLE=node
```

Даже без неё role автоматически определяется по наличию `DVR_MASTER_URL`, `DVR_NODE_ID` и `DVR_NODE_TOKEN`. Старую переменную `DVR_ROLE` использовать не следует.

## 8. Подготовьте runtime-каталоги и права

```bash
install -d -o newdomofon -g newdomofon -m 0750 \
  /var/lib/newdomofon-video/dvr \
  /var/lib/newdomofon-video/events

install -d -o newdomofon -g newdomofon -m 0755 \
  /var/log/newdomofon-video

chown -R newdomofon:newdomofon \
  /var/lib/newdomofon-video/dvr \
  /var/lib/newdomofon-video/events

namei -l /etc/newdomofon-video/app.env
sudo -u newdomofon test -r /etc/newdomofon-video/app.env
echo "app_env_readable_rc=$?"
```

Проверьте mount:

```bash
findmnt /var/lib/newdomofon-video/dvr
findmnt -no SOURCE,FSTYPE,OPTIONS /var/lib/newdomofon-video/dvr
df -hT /var/lib/newdomofon-video/dvr
df -ih /var/lib/newdomofon-video/dvr
```

## 9. Выполните первый deploy

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

1. filesystem/disk preflight;
2. `npm ci` и TypeScript build DVR engine;
3. удаление dev dependencies;
4. установку DVR systemd unit;
5. установку Nginx template;
6. установку disk guard service/timer;
7. установку journald limits;
8. установку archive-event sync service/timer;
9. initial archive-event sync в безопасном dry-run;
10. запуск DVR, если disk guard не находится в critical;
11. проверку Nginx config.

## 10. Укажите production domain в Nginx

```bash
sed -i \
  "s/server_name _;/server_name ${NODE_DOMAIN};/" \
  /etc/nginx/sites-available/newdomofon-video-node.conf

nginx -t
systemctl reload nginx
```

## 11. Выпустите TLS-сертификат

```bash
apt-get install -y certbot python3-certbot-nginx
certbot --nginx -d "$NODE_DOMAIN"
certbot renew --dry-run
```

Сохраните production Nginx config:

```bash
cp -a \
  /etc/nginx/sites-available/newdomofon-video-node.conf \
  /root/newdomofon-video-node.nginx-with-tls.conf
```

> Повторный `deploy-node.sh` копирует Nginx template заново. Для обновления production используйте отдельную процедуру ниже и сравнивайте Nginx diff до замены TLS-файла.

## 12. Ограничьте порт 3010

Не применяйте firewall rules до проверки SSH. Разрешите `3010/tcp` только с private IP master.

Проверка listener:

```bash
ss -ltnp | grep ':3010 '
```

Nginx public routes работают через `80/443`.

---

# Подключение камер и проверка recorder

Камеры создаются и назначаются только на master. Node получает config через node-agent API и команду `reload_cameras`.

## Проверка heartbeat/config

```bash
journalctl \
  -u newdomofon-video-dvr.service \
  --since '10 minutes ago' \
  --no-pager \
  | grep -E 'node-agent|heartbeat|config|commands|reload' \
  | tail -200
```

На master node должна быть `online`, а `last_seen_at` должен обновляться.

## Список recorder

```bash
curl -fsS http://127.0.0.1:3010/recorders | jq
```

Статус конкретного stream:

```bash
STREAM="entrance_main"

curl -fsS \
  "http://127.0.0.1:3010/cameras/${STREAM}/status" \
  | jq
```

Успешный результат содержит:

```json
{
  "recording": true,
  "state": "recording",
  "stream_name": "entrance_main",
  "last_error": null
}
```

При ошибке доступны:

```text
state
last_error
last_exit_code
restarts
next_retry_at
credentials_injected
```

## Credentials в RTSP URI

Если master передал `source_url` без `user:password@`, node использует сохранённые camera/device credentials и подставляет их только в памяти при запуске FFmpeg.

Пароль не должен возвращаться через API и должен маскироваться в diagnostics.

## Проверка FFmpeg processes

```bash
pgrep -fc '/usr/bin/ffmpeg'

ps -eo pid,etimes,%cpu,%mem,cmd \
  | grep '[f]fmpeg' \
  | sed -E 's#(rtsp://)[^ @]+@#\1***:***@#g' \
  | head -100
```

Не публикуйте полный FFmpeg command line без маскирования credentials.

## Принудительная перезагрузка конфигурации

Обычно не требуется:

```bash
systemctl restart newdomofon-video-dvr.service
```

После изменения камеры master сам повышает `config_generation` и ставит `reload_cameras`.

---

# Live, архив и MP4 export

Node endpoints:

```text
GET /cameras/:stream/live.m3u8
GET /cameras/:stream/archive.m3u8?start=...&end=...
GET /cameras/:stream/archive/ranges?start=...&end=...
GET /cameras/:stream/export.mp4?start=...&end=...
GET /files/:stream/*
GET /device-archive/:stream/:session/:file
```

Они требуют HMAC media token. Для пользовательской проверки получайте ссылку через master UI/API, а не подписывайте node token вручную.

## Проверка появления live playlist локально

```bash
STREAM="entrance_main"

ls -lah "/var/lib/newdomofon-video/dvr/${STREAM}/live.m3u8"

sed -n '1,30p' \
  "/var/lib/newdomofon-video/dvr/${STREAM}/live.m3u8"
```

## Последние сегменты

```bash
find "/var/lib/newdomofon-video/dvr/${STREAM}" \
  -type f \
  \( -name '*.ts' -o -name '*.m4s' \) \
  -mmin -5 \
  -printf '%TY-%Tm-%Td %TH:%TM:%TS %s %p\n' \
  | sort \
  | tail -100
```

## Проверка через master

В master UI:

```text
Камеры → открыть камеру
```

или создайте managed camera link:

```text
Администрирование → Токены → Ссылки камер
```

Проверьте:

```text
live/index.m3u8
archive ranges
timeline seek
preview.mp4
```

## Коды ошибок

```text
401 Missing media token
  token не передан

403 Invalid media token
  неверная подпись, scope, stream, generation или срок действия

404 Live playlist is not ready
  recorder не создал live.m3u8

404 No archive segments in selected range
  в диапазоне нет локальных сегментов

413 Requested range is too large
  диапазон export/archive превышает MAX_EXPORT_SECONDS или route limit
```

---

# ONVIF, Hikvision и video-motion события

## ONVIF PullPoint

Node использует локальный PullPoint collector. Он:

- получает только камеры, назначенные этой node;
- пробует SOAP 1.2 и SOAP 1.1;
- поддерживает WS-Addressing и plain requests;
- поддерживает UsernameToken PasswordDigest и PasswordText;
- сохраняет события локально;
- подавляет повторяющиеся same-state snapshots;
- не отправляет event payload на master.

Для камеры на master должны быть корректны:

```text
stream_name
dvr_server_id
onvif_xaddr или device host + onvif_port
onvif_username/onvif_password или device credentials
```

Проверка collector:

```bash
journalctl \
  -u newdomofon-video-dvr.service \
  --since '15 minutes ago' \
  --no-pager \
  | grep -E '\[onvif-events|\[event-store|subscription ready|events stored locally' \
  | tail -300
```

## Эквивалентные motion topics

Одна физическая детекция может создать raw transitions по нескольким topics, например:

```text
tns1:RuleEngine/CellMotionDetector/Motion
tns1:VideoSource/MotionAlarm
```

SQLite сохраняет raw transitions, а пользовательский logical timeline на master:

- показывает активные события;
- скрывает `false/inactive`;
- объединяет близкие эквивалентные topics.

## Hikvision events

По умолчанию:

```text
DVR_HIKVISION_EVENTS_ENABLED=false
```

Включайте после проверки ISAPI/alertStream и channel mapping:

```bash
sed -i \
  's/^DVR_HIKVISION_EVENTS_ENABLED=.*/DVR_HIKVISION_EVENTS_ENABLED=true/' \
  /etc/newdomofon-video/app.env

systemctl restart newdomofon-video-dvr.service
```

## FFmpeg video-motion detector

По умолчанию выключен:

```text
VIDEO_MOTION_ENABLED=false
```

Пример для отдельных stream:

```text
VIDEO_MOTION_ENABLED=true
VIDEO_MOTION_STREAMS=entrance_main,parking_1
VIDEO_MOTION_SOURCE=hls
VIDEO_MOTION_FPS=3
VIDEO_MOTION_SCENE_THRESHOLD=0.010
```

Не включайте `*` на большой node без измерения CPU.

---

# SQLite event store и Event API

## Файлы

```text
/var/lib/newdomofon-video/events/events.sqlite3
/var/lib/newdomofon-video/events/events.sqlite3-wal
/var/lib/newdomofon-video/events/events.sqlite3-shm
```

SQLite работает в WAL mode.

## Health

```bash
curl -fsS http://127.0.0.1:3010/health | jq '.events'
```

Ожидается:

```json
{
  "ok": true,
  "storage": "sqlite",
  "wal": true
}
```

## Количество событий

```bash
node - <<'NODE'
const { DatabaseSync } = require('node:sqlite');
const db = new DatabaseSync(
  '/var/lib/newdomofon-video/events/events.sqlite3',
  { readOnly: true }
);

console.table(db.prepare(`
  SELECT
    stream_name,
    count(*) AS events,
    datetime(min(occurred_at_ms) / 1000, 'unixepoch') AS first_utc,
    datetime(max(occurred_at_ms) / 1000, 'unixepoch') AS last_utc
  FROM camera_events
  GROUP BY stream_name
  ORDER BY stream_name
`).all());

db.close();
NODE
```

Предупреждение Node.js 22 о experimental `node:sqlite` не означает ошибку database.

## Последние raw-события

```bash
node - <<'NODE'
const { DatabaseSync } = require('node:sqlite');
const db = new DatabaseSync(
  '/var/lib/newdomofon-video/events/events.sqlite3',
  { readOnly: true }
);

console.table(db.prepare(`
  SELECT
    stream_name,
    event_type,
    event_state,
    topic,
    datetime(occurred_at_ms / 1000, 'unixepoch') AS occurred_at_utc
  FROM camera_events
  ORDER BY occurred_at_ms DESC
  LIMIT 100
`).all());

db.close();
NODE
```

## Event API

```text
GET /cameras/:stream/events
GET /cameras/:stream/events/summary
GET /cameras/:stream/events/health
```

Без token:

```bash
curl -sS -o /tmp/events.json -w 'HTTP %{http_code}\n' \
  http://127.0.0.1:3010/cameras/test/events

cat /tmp/events.json
```

Ожидается `401`. Неверный или истёкший token возвращает `403`.

## Retention

```text
DVR_EVENT_RETENTION_DAYS=30
DVR_EVENT_CLEANUP_INTERVAL_MINUTES=60
```

Возрастная retention является верхней границей. Дополнительно archive-event synchronizer удаляет события часов, для которых локальный архив уже отсутствует.

---

# Синхронизация событий с существующим архивом

Проблема, которую решает synchronizer:

```text
архивный час удалён
события этого часа остались в SQLite
timeline показывает marker, но видео отсутствует
```

Worker каждые пять минут проверяет завершённые часы локального архива. Если у local/node camera за час нет `.ts` или `.m4s`, события этой камеры за тот же час могут быть удалены.

Камеры с `archive_storage=device` исключаются.

## Безопасность synchronizer

Он не удаляет события, если:

- `DVR_ARCHIVE_EVENT_SYNC_ENABLED=false`;
- `DVR_ARCHIVE_EVENT_SYNC_APPLY=false`;
- master недоступен;
- DVR mount отсутствует при обязательном mount;
- disk guard находится в critical;
- час моложе `DVR_ARCHIVE_EVENT_SYNC_MIN_AGE_MINUTES`;
- в каталоге есть playable segment.

По умолчанию:

```text
DVR_ARCHIVE_EVENT_SYNC_APPLY=false
```

Timer работает в dry-run и только формирует отчёт.

## Состояние

```bash
cat \
  /var/lib/newdomofon-video/events/archive-event-sync-state.json \
  | jq
```

Поля:

```text
mode
authoritative_master
local_streams
archive_hours_checked
missing_archive_hours
candidate_events
deleted_events
examples
```

## Ручной dry-run

```bash
sudo -u newdomofon bash -c '
set -a
. /etc/newdomofon-video/app.env
set +a

exec /usr/bin/node \
  /usr/local/lib/newdomofon-video/reconcile-archive-events.mjs \
  --dry-run
' \
  > /tmp/archive-event-sync-dry-run.json \
  2> /tmp/archive-event-sync-dry-run.err

RC=$?
echo "dry_run_rc=$RC"

if [ "$RC" -eq 0 ]; then
  jq . /tmp/archive-event-sync-dry-run.json
else
  cat /tmp/archive-event-sync-dry-run.err
fi
```

Dry-run должен показывать:

```json
{
  "mode": "dry-run",
  "deleted_events": 0
}
```

## Dry-run одной камеры

```bash
sudo -u newdomofon bash -c '
set -a
. /etc/newdomofon-video/app.env
set +a

exec /usr/bin/node \
  /usr/local/lib/newdomofon-video/reconcile-archive-events.mjs \
  --dry-run \
  --stream entrance_main
' | jq
```

## Проверьте каталоги-кандидаты

```bash
jq -r '.examples[].archive_directory' \
  /tmp/archive-event-sync-dry-run.json \
  | while IFS= read -r dir; do
      if [ -d "$dir" ]; then
        segments="$(find "$dir" -maxdepth 1 -type f \
          \( -name '*.ts' -o -name '*.m4s' \) | wc -l)"
        echo "EXISTS segments=$segments $dir"
      else
        echo "MISSING $dir"
      fi
    done
```

## Backup SQLite перед первым apply

```bash
DB="/var/lib/newdomofon-video/events/events.sqlite3"
BACKUP_DIR="/var/lib/newdomofon-video/events/backups"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DB="$BACKUP_DIR/events-before-archive-sync-$STAMP.sqlite3"

install -d -o newdomofon -g newdomofon -m 0750 \
  "$BACKUP_DIR"

sudo -u newdomofon \
  /usr/bin/node - "$DB" "$BACKUP_DB" <<'NODE'
const { DatabaseSync } = require('node:sqlite');
const source = process.argv[2];
const destination = process.argv[3];
const db = new DatabaseSync(source);
const escaped = destination.replaceAll("'", "''");
db.exec(`VACUUM INTO '${escaped}'`);
db.close();
console.log(destination);
NODE

ls -lh "$BACKUP_DB"
```

## Контролируемый apply одной камеры

```bash
sudo -u newdomofon bash -c '
set -a
. /etc/newdomofon-video/app.env
set +a

exec /usr/bin/node \
  /usr/local/lib/newdomofon-video/reconcile-archive-events.mjs \
  --apply \
  --stream entrance_main
' | tee /tmp/archive-event-sync-apply.json

jq . /tmp/archive-event-sync-apply.json
```

## Включение автоматического apply

Только после проверки dry-run и backup:

```bash
sed -i \
  's/^DVR_ARCHIVE_EVENT_SYNC_APPLY=.*/DVR_ARCHIVE_EVENT_SYNC_APPLY=true/' \
  /etc/newdomofon-video/app.env

systemctl start newdomofon-video-archive-event-sync.service

cat \
  /var/lib/newdomofon-video/events/archive-event-sync-state.json \
  | jq
```

Timer:

```bash
systemctl enable --now \
  newdomofon-video-archive-event-sync.timer

systemctl list-timers \
  newdomofon-video-archive-event-sync.timer \
  --no-pager
```

## Немедленный возврат в dry-run

```bash
sed -i \
  's/^DVR_ARCHIVE_EVENT_SYNC_APPLY=.*/DVR_ARCHIVE_EVENT_SYNC_APPLY=false/' \
  /etc/newdomofon-video/app.env

systemctl start newdomofon-video-archive-event-sync.service
```

---

# Защита от заполнения диска

Node disk guard запускается systemd timer каждую минуту.

## Что проверяется

- filesystem `DVR_ROOT`;
- свободные bytes;
- свободные inode;
- filesystem SQLite/event database;
- root/system filesystem;
- обязательный mountpoint;
- stale export/device-archive temp directories.

## Порог по умолчанию

Аварийная очистка начинается, если свободно меньше:

```text
max(10 GiB, 10% размера DVR filesystem)
```

То есть на крупном диске очистка начинается примерно при **90% заполнения**.

Очистка продолжается до:

```text
max(15 GiB, 15% размера DVR filesystem)
```

То есть целевое заполнение после очистки на крупном диске — примерно **85%**.

Inode:

```text
critical: <5% свободных inode
resume:   >=8%
```

Root/event filesystem:

```text
critical: max(2 GiB, 5%)
resume:   max(4 GiB, 10%)
```

## Что удаляется

1. stale export temp directories;
2. stale device-archive sessions;
3. самые старые завершённые часовые каталоги архива;
4. пустые parent date directories.

Не удаляются:

- текущий UTC-час;
- каталоги моложе `DVR_DISK_MIN_ARCHIVE_AGE_MINUTES`;
- SQLite database;
- `app.env`;
- recorder configuration;
- архив произвольных путей вне ожидаемого шаблона.

За один проход удаляется не больше:

```text
DVR_DISK_MAX_DELETE_DIRS_PER_RUN=500
```

500 каталогов — это не 500 общих часов. При 10 камерах один час может состоять из 10 каталогов.

## Если места освободить не удалось

Guard:

1. останавливает `newdomofon-video-dvr.service`;
2. создаёт `/run/newdomofon-video/node-disk-paused`;
3. оставляет node в critical;
4. автоматически запускает DVR после восстановления resume watermark.

Это предотвращает запись до 100% и повреждение SQLite/root filesystem.

## Состояние guard

```bash
cat /run/newdomofon-video/node-disk-state.json | jq

systemctl status \
  newdomofon-video-node-disk-guard.timer \
  --no-pager -l

journalctl \
  -u newdomofon-video-node-disk-guard.service \
  -n 300 --no-pager
```

Полезные поля:

```text
state
reason
available_bytes
used_percent
inode_free_percent
required_start_bytes
required_resume_bytes
deleted_archive_directories
```

## Какие каталоги были удалены

```bash
journalctl \
  -t newdomofon-node-disk-guard \
  --since '7 days ago' \
  --no-pager \
  | grep -E 'disk pressure|emergency archive cleanup removed|stopping|disk recovered'
```

## Более плотное хранение: 95% / 92%

Если вы осознанно хотите хранить больше архива и принимаете меньший запас:

```text
DVR_DISK_MIN_FREE_BYTES=10737418240
DVR_DISK_MIN_FREE_PERCENT=5
DVR_DISK_RESUME_FREE_BYTES=16106127360
DVR_DISK_RESUME_FREE_PERCENT=8
DVR_DISK_MAX_DELETE_DIRS_PER_RUN=50
DVR_DISK_MIN_ARCHIVE_AGE_MINUTES=180
```

Для крупных дисков это приблизительно:

```text
очистка начинается: 95% заполнения
останавливается:    92% заполнения
```

После изменения:

```bash
systemctl restart newdomofon-video-node-disk-guard.timer
systemctl start newdomofon-video-node-disk-guard.service || true
cat /run/newdomofon-video/node-disk-state.json | jq
```

Не устанавливайте start/resume одинаковыми: hysteresis предотвращает постоянное включение/выключение recorder.

## Проверка mount protection

```bash
mountpoint -q /var/lib/newdomofon-video/dvr
echo "mountpoint_rc=$?"

grep '^DVR_DISK_REQUIRE_MOUNTPOINT=' \
  /etc/newdomofon-video/app.env
```

Если mount обязателен и пропал, DVR должен оставаться остановленным до возврата диска.

---

# Проверка после установки

## Services и timers

```bash
systemctl is-enabled newdomofon-video-dvr.service
systemctl is-active newdomofon-video-dvr.service
systemctl is-active newdomofon-video-node-disk-guard.timer
systemctl is-active newdomofon-video-archive-event-sync.timer

systemctl status newdomofon-video-dvr.service --no-pager -l
systemctl list-timers --no-pager \
  | grep -E 'newdomofon-video-(node-disk-guard|archive-event-sync)'
```

## Health

```bash
curl -fsS http://127.0.0.1:3010/health | jq
curl -kfsS "https://${NODE_DOMAIN}/health" | jq
```

Ожидается:

```json
{
  "ok": true,
  "service": "dvr-engine",
  "mode": "node",
  "recording_enabled": true
}
```

## Порты

```bash
ss -ltnp | grep -E ':(80|443|3010)([[:space:]]|$)'
```

## Диск

```bash
df -hT / /var/lib/newdomofon-video/dvr /var/lib/newdomofon-video/events
df -ih / /var/lib/newdomofon-video/dvr /var/lib/newdomofon-video/events
findmnt /var/lib/newdomofon-video/dvr
journalctl --disk-usage
```

## Heartbeat на master

На master:

```bash
curl -fsS \
  -H "Authorization: Bearer $AUTH_TOKEN" \
  "https://${MASTER_DOMAIN}/api/dvr-servers" \
  | jq '.items[] | {name,status,last_seen_at,camera_count,storage,capabilities}'
```

## Events и archive sync

```bash
cat /run/newdomofon-video/node-disk-state.json | jq

cat \
  /var/lib/newdomofon-video/events/archive-event-sync-state.json \
  | jq
```

---

# Безопасное обновление production

## Важно

Обновление node не должно:

- изменять master;
- удалять `/var/lib/newdomofon-video/dvr`;
- удалять `/var/lib/newdomofon-video/events`;
- перезаписывать `app.env`;
- форматировать archive disk;
- слепо заменять production Nginx config с Certbot TLS.

## 1. Создайте backup

```bash
set +e
set +u
set +E
set +o pipefail

PROJECT="/opt/newdomofon-video-node"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="/opt/newdomofon-video-migration-backups/node-update-$STAMP"

install -d -m 0750 "$BACKUP"

cp -a /etc/newdomofon-video "$BACKUP/etc-newdomofon-video"
cp -a /etc/nginx/sites-available/newdomofon-video-node.conf \
  "$BACKUP/nginx.conf"
cp -a /etc/systemd/system/newdomofon-video-dvr.service \
  "$BACKUP/" 2>/dev/null || true

git -C "$PROJECT" status --short > "$BACKUP/git-status.txt"
git -C "$PROJECT" rev-parse HEAD > "$BACKUP/git-commit.txt"
git -C "$PROJECT" diff --binary > "$BACKUP/worktree.patch" || true

if [ -d "$PROJECT/dvr-engine/dist" ]; then
  cp -a "$PROJECT/dvr-engine/dist" "$BACKUP/dist-before"
fi
```

Создайте SQLite backup через `VACUUM INTO`, если обновление затрагивает event store:

```bash
DB="/var/lib/newdomofon-video/events/events.sqlite3"
BACKUP_DB="$BACKUP/events.sqlite3"

sudo -u newdomofon \
  /usr/bin/node - "$DB" "$BACKUP_DB" <<'NODE'
const { DatabaseSync } = require('node:sqlite');
const source = process.argv[2];
const destination = process.argv[3];
const db = new DatabaseSync(source);
const escaped = destination.replaceAll("'", "''");
db.exec(`VACUUM INTO '${escaped}'`);
db.close();
NODE
```

## 2. Обновите checkout

```bash
git -C "$PROJECT" stash push -u \
  -m "production-before-node-update-$STAMP" || true

git -C "$PROJECT" fetch origin main
git -C "$PROJECT" switch main
git -C "$PROJECT" reset --hard origin/main

git -C "$PROJECT" log -1 --oneline
```

## 3. Disk preflight

```bash
NEWDOMOFON_ENV_FILE=/etc/newdomofon-video/app.env \
  bash "$PROJECT/scripts/node-system-disk-check.sh" || true

if [ ! -e /run/newdomofon-video/node-disk-paused ]; then
  NEWDOMOFON_ENV_FILE=/etc/newdomofon-video/app.env \
    bash "$PROJECT/scripts/node-disk-guard.sh"
fi

cat /run/newdomofon-video/node-disk-state.json | jq

test ! -e /run/newdomofon-video/node-disk-paused
```

## 4. Соберите до restart

```bash
cd "$PROJECT/dvr-engine"
npm ci --include=dev
npm run build
npm prune --omit=dev
```

## 5. Обновите units/helpers

```bash
install -m 0644 \
  "$PROJECT/deploy/systemd/newdomofon-video-dvr.service" \
  /etc/systemd/system/newdomofon-video-dvr.service

PROJECT_DIR="$PROJECT" INSTALL_JOURNAL_LIMITS=1 \
  bash "$PROJECT/scripts/install-node-disk-guard.sh"

PROJECT_DIR="$PROJECT" ENV_FILE=/etc/newdomofon-video/app.env \
  bash "$PROJECT/scripts/install-archive-event-sync.sh"

systemctl daemon-reload
```

## 6. Nginx diff

```bash
diff -u \
  /etc/nginx/sites-available/newdomofon-video-node.conf \
  "$PROJECT/deploy/nginx/newdomofon-video-node.conf" || true
```

Переносите новые `location` вручную либо заново применяйте domain/TLS после backup. Не заменяйте Certbot config вслепую.

## 7. Перезапустите DVR

```bash
if [ ! -e /run/newdomofon-video/node-disk-paused ]; then
  systemctl restart newdomofon-video-dvr.service
else
  echo 'DVR remains stopped because disk guard is critical'
fi

for i in $(seq 1 60); do
  if curl -fsS http://127.0.0.1:3010/health >/tmp/node-health.json; then
    break
  fi
  sleep 1
done

jq . /tmp/node-health.json
journalctl -u newdomofon-video-dvr.service -n 200 --no-pager
```

Не применяйте старый stash автоматически.

---

# Backup, восстановление и перенос диска

## Что сохранять

```text
/etc/newdomofon-video/
/etc/nginx/sites-available/newdomofon-video-node.conf
/etc/systemd/system/newdomofon-*.service
/etc/systemd/system/newdomofon-*.timer
/var/lib/newdomofon-video/events/
текущий Git commit
archive data по отдельной политике
```

## Консистентный backup event database с остановкой

```bash
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="/var/backups/newdomofon-video/node-$STAMP"

install -d -m 0700 "$BACKUP"
cp -a /etc/newdomofon-video "$BACKUP/"
git -C /opt/newdomofon-video-node rev-parse HEAD \
  > "$BACKUP/git-commit.txt"

systemctl stop newdomofon-video-dvr.service
cp -a /var/lib/newdomofon-video/events "$BACKUP/events"
systemctl start newdomofon-video-dvr.service

curl -fsS http://127.0.0.1:3010/health | jq
```

Если копируете без остановки, обязательно копируйте `events.sqlite3`, `-wal` и `-shm` вместе. Предпочтительнее `VACUUM INTO`.

## Видеоархив

Полный ежедневный backup многотерабайтного архива обычно дорог. Используйте:

- RAID как защиту от отказа диска, но не как замену backup;
- репликацию критичных камер;
- объектное/файловое хранилище;
- SMART monitoring;
- spare disk;
- регулярный test restore.

## Перенос архивного диска

```bash
systemctl stop newdomofon-video-dvr.service
systemctl stop newdomofon-video-node-disk-guard.timer

rsync -aHAX --numeric-ids --info=progress2 \
  /var/lib/newdomofon-video/dvr/ \
  /mnt/new-disk/dvr/

# Проверьте destination перед изменением mount.
du -sh /var/lib/newdomofon-video/dvr /mnt/new-disk/dvr

# Смонтируйте новый filesystem в DVR_ROOT.
findmnt /var/lib/newdomofon-video/dvr
chown -R newdomofon:newdomofon /var/lib/newdomofon-video/dvr

systemctl start newdomofon-video-node-disk-guard.timer
systemctl start newdomofon-video-node-disk-guard.service || true

if [ ! -e /run/newdomofon-video/node-disk-paused ]; then
  systemctl start newdomofon-video-dvr.service
fi

curl -fsS http://127.0.0.1:3010/health | jq
```

Не используйте `rsync --delete`, пока source/destination не проверены.

## Rollback к предыдущему commit

```bash
PROJECT="/opt/newdomofon-video-node"
OLD_COMMIT="PASTE_PREVIOUS_COMMIT"

systemctl stop newdomofon-video-dvr.service

git -C "$PROJECT" reset --hard "$OLD_COMMIT"

cd "$PROJECT/dvr-engine"
npm ci --include=dev
npm run build
npm prune --omit=dev

systemctl start newdomofon-video-dvr.service

for i in $(seq 1 60); do
  curl -fsS http://127.0.0.1:3010/health && break
  sleep 1
done
```

Если новая версия изменила SQLite schema, перед rollback восстановите совместимый backup.

---

# Диагностика

## Service и journal

```bash
systemctl status newdomofon-video-dvr.service --no-pager -l
journalctl -u newdomofon-video-dvr.service -n 500 --no-pager
```

## Node offline / heartbeat 401

Проверьте:

```bash
sudo -u newdomofon bash -c '
set -a
. /etc/newdomofon-video/app.env
set +a
printf "MASTER=%s\n" "$DVR_MASTER_URL"
printf "NODE_ID=%s\n" "$DVR_NODE_ID"
printf "NODE_TOKEN_LENGTH=%s\n" "${#DVR_NODE_TOKEN}"
printf "MEDIA_SECRET_LENGTH=%s\n" "${#DVR_NODE_MEDIA_SECRET}"
'

curl -kfsS "https://${MASTER_DOMAIN}/api/health" | jq
getent ahosts "$MASTER_DOMAIN"
timedatectl status
```

После ротации agent token обновите `DVR_NODE_TOKEN` и перезапустите DVR.

## Live 404 / recording=false

```bash
STREAM="entrance_main"

curl -fsS \
  "http://127.0.0.1:3010/cameras/${STREAM}/status" \
  | jq

journalctl \
  -u newdomofon-video-dvr.service \
  --since '15 minutes ago' \
  --no-pager \
  | grep -F "$STREAM" \
  | tail -300
```

Типичные `last_error`:

```text
401 Unauthorized        неверный RTSP/ONVIF password
Connection refused      неправильный RTSP port или RTSP выключен
Connection timed out    нет маршрута/firewall до камеры
404 Not Found           неправильный RTSP path
Invalid data found      повреждённый/неподдерживаемый stream
```

## Preview на master возвращает 502

Если master journal содержит:

```text
Node preview export failed (403): Invalid media token
```

убедитесь, что node обновлена до версии, где broad `camera` scope включает `export`, и пересоберите DVR engine.

Другие причины:

- нет archive range;
- camera recorder не пишет;
- node offline;
- media secret не совпадает.

## Нет событий

```bash
journalctl \
  -u newdomofon-video-dvr.service \
  --since '15 minutes ago' \
  --no-pager \
  | grep -E 'onvif-events|event-store|subscription|PullPoint|401|timeout' \
  | tail -400
```

Проверьте ONVIF port, credentials, время камеры и включённые analytics events.

## Disk guard остановил DVR

```bash
cat /run/newdomofon-video/node-disk-state.json | jq
cat /run/newdomofon-video/node-disk-paused 2>/dev/null || true

df -hT /var/lib/newdomofon-video/dvr
df -ih /var/lib/newdomofon-video/dvr

journalctl \
  -t newdomofon-node-disk-guard \
  --since '24 hours ago' \
  --no-pager
```

Не удаляйте pause marker вручную, пока filesystem не достиг resume watermark. Guard снимет marker и запустит DVR автоматически.

## Архив удалён, events остались

```bash
cat \
  /var/lib/newdomofon-video/events/archive-event-sync-state.json \
  | jq

grep '^DVR_ARCHIVE_EVENT_SYNC_APPLY=' \
  /etc/newdomofon-video/app.env
```

Если `APPLY=false`, synchronizer только сообщает candidates. Проверьте dry-run, создайте SQLite backup и включите apply.

## Проверка дисков и SMART

```bash
lsblk -o NAME,SIZE,FSTYPE,UUID,MOUNTPOINTS,MODEL,SERIAL
df -hT /var/lib/newdomofon-video/dvr
df -ih /var/lib/newdomofon-video/dvr
du -xhd1 /var/lib/newdomofon-video/dvr | sort -h | tail -30
```

Для SMART:

```bash
apt-get install -y smartmontools
smartctl -a /dev/sdb
```

## Nginx

```bash
nginx -t
nginx -T 2>/dev/null \
  | grep -nE 'server_name|3010|/cameras/|/files/|/device-archive/' \
  | head -200

journalctl -u nginx -n 200 --no-pager
```

---

# Безопасность и масштабирование

## Security checklist

- Не публикуйте `3010/tcp` всему интернету.
- Используйте HTTPS для public node URL.
- Ограничьте SSH административными IP и используйте ключи.
- Храните `app.env` с правами `0640 root:newdomofon`.
- Не публикуйте bootstrap JSON, agent token и media secret.
- Не публикуйте RTSP/ONVIF URI и FFmpeg command line без маскирования.
- Используйте уникальные passwords камер.
- Разделите camera VLAN, management VLAN и public access.
- Разрешайте RTSP/ONVIF только нужным node.
- Синхронизируйте время.
- Не включайте raw event payload без необходимости.
- Не удаляйте archive/event storage при Git update.
- Регулярно проверяйте SMART, disk guard и restore.
- После утечки credentials выполните rotation на master и обновите node env.

## Вторая и последующие node

Для каждой node:

1. создайте отдельную запись на master;
2. получите уникальные `node_id`, `agent_token`, `media_secret`;
3. используйте отдельный `app.env`;
4. используйте отдельный private IP;
5. желательно используйте отдельный public DNS;
6. назначьте только её камеры;
7. проверьте heartbeat, recorder, live, archive, events, preview;
8. не копируйте SQLite/archive другой node без плановой миграции;
9. не используйте credentials другой node.

## Миграция камеры между node

Рекомендуемый порядок:

1. проверить доступ новой node к RTSP/ONVIF;
2. назначить камеру новой node на master;
3. дождаться `recording=true` на новой node;
4. проверить live/archive/events;
5. убедиться, что старая node получила reload и остановила recorder;
6. переносить старый архив отдельно, если он нужен.

Смена назначения не переносит физические архивные файлы автоматически.

---

# Разработка и разделение репозиториев

Data plane изменяется только в:

```text
https://github.com/rirodevdom/newdomofon-video-node
```

Control plane изменяется только в:

```text
https://github.com/rirodevdom/newdomofon-video-master
```

Правила:

- не подключать node к PostgreSQL master;
- не копировать master backend в node;
- не создавать общий production checkout;
- общими считать только versioned contracts;
- сначала добавлять backward compatibility на master;
- затем обновлять node;
- выполнять production verification;
- удалять legacy API только отдельным major change.

Старый объединённый monorepo не является источником production-кода.
