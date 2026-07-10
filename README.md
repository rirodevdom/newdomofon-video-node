# NewDomofon Video Node

Самостоятельный **data plane** NewDomofon Video: запись камер, live, архив, экспорт и локальное хранение событий.

Node управляется master через versioned HTTP API, но не использует PostgreSQL master и не импортирует его код.

## Архитектура и границы ответственности

Node отвечает за:

- подключение к назначенным камерам;
- запись RTSP-потоков через FFmpeg;
- live HLS;
- локальный DVR-архив;
- archive ranges и MP4 export;
- ONVIF PullPoint events;
- Hikvision alertStream events;
- опциональный FFmpeg video-motion detector;
- локальное SQLite/WAL-хранилище событий;
- event retention;
- выполнение команд master;
- heartbeat и диагностику storage/recorders/events.

Node **не должна**:

- подключаться к PostgreSQL master;
- хранить пользователей и RBAC;
- выдавать пользовательские права самостоятельно;
- отправлять payload событий на master;
- использовать общий checkout с master;
- зависеть от `newdomofon-video-backend.service` или `postgresql.service`.

Master хранит только управляющие данные и назначение камер. При запросе timeline master проверяет права пользователя, выпускает короткоживущий `scope=events` token и проксирует запрос на node.

Контракты:

```text
contracts/node-agent-api-v1.md
contracts/node-events-api-v1.md
```

## Runtime-данные

По умолчанию:

```text
/var/lib/newdomofon-video/
├── dvr/                         видеоархив и live-файлы
└── events/
    ├── events.sqlite3           основная event database
    ├── events.sqlite3-wal       SQLite WAL
    └── events.sqlite3-shm       SQLite shared memory
```

Конфигурация и секреты:

```text
/etc/newdomofon-video/app.env
```

Логи:

```text
journalctl -u newdomofon-video-dvr.service
/var/log/newdomofon-video/
```

Не добавляйте runtime-данные, архив или секреты в Git.

## Состав репозитория

```text
dvr-engine/            recorder, media API, node agent, event collectors
dvr-archive-proxy/     archive compatibility helpers
restreamer/             restream helper
restream-gateway/       restream gateway
live-only-engine/       live-only helper
contracts/              versioned master/node API contracts
deploy/                 systemd, nginx and env examples
scripts/                install, deploy, repair and diagnostics
```

## Поддерживаемая платформа

Рекомендуется:

- Debian 12 x86_64;
- Node.js 22.12 или новее;
- FFmpeg из Debian 12 или совместимая новая версия;
- nginx;
- минимум 4 CPU и 4 GB RAM;
- отдельный быстрый диск под `/var/lib/newdomofon-video/dvr`;
- DNS-адрес, например `video-node1.example.com`;
- синхронизация времени через systemd-timesyncd или chrony.

Размер диска рассчитывайте по суммарному bitrate камер и retention.

Пример:

```text
8 Mbit/s ≈ 86.4 GB в сутки на одну камеру
4 Mbit/s ≈ 43.2 GB в сутки на одну камеру
```

Добавляйте запас минимум 15–20% для live, WAL, export и служебных файлов.

## Сетевые требования

Node должна иметь:

- исходящий HTTPS к master;
- доступ к RTSP/ONVIF/Hikvision адресам камер;
- синхронизированное время;
- публичный или внутренний адрес, доступный master;
- публичный HTTPS URL, если клиенты получают media непосредственно с node.

Порты:

```text
22/tcp     SSH, только с административных адресов
80/tcp     nginx HTTP
443/tcp    nginx HTTPS
3010/tcp   DVR engine; разрешать только master/private network
```

Через nginx публикуются:

```text
/health
/cameras/
/files/
/device-archive/
```

# Полное развёртывание на чистом Debian 12

Ниже команды выполняются от `root`.

## 1. Подготовьте DNS и переменные

```bash
export NODE_NAME="video-node1"
export NODE_DOMAIN="video-node1.example.com"
export NODE_PRIVATE_IP="10.0.0.31"
export MASTER_DOMAIN="video.example.com"
export NODE_REPO="https://github.com/rirodevdom/newdomofon-video-node.git"
export NODE_DIR="/opt/newdomofon-video-node"
```

Проверьте DNS:

```bash
getent ahosts "$NODE_DOMAIN"
getent ahosts "$MASTER_DOMAIN"
```

## 2. Подготовьте отдельный архивный диск

Лучший вариант — смонтировать раздел непосредственно в:

```text
/var/lib/newdomofon-video/dvr
```

Посмотрите диски:

```bash
lsblk -o NAME,SIZE,FSTYPE,UUID,MOUNTPOINTS,MODEL
```

**Не форматируйте диск, если на нём уже есть данные.** Следующий пример только для нового пустого раздела `/dev/sdb1`:

```bash
mkfs.ext4 -L NEWDOMOFON_DVR /dev/sdb1

install -d -m 0750 /var/lib/newdomofon-video/dvr

UUID="$(blkid -s UUID -o value /dev/sdb1)"
echo "UUID=${UUID} /var/lib/newdomofon-video/dvr ext4 defaults,noatime 0 2" \
  >> /etc/fstab

mount -a
findmnt /var/lib/newdomofon-video/dvr
```

Не используйте `/dev/sdX` в `fstab`; используйте UUID.

Если архив уже существует, сначала остановите DVR и перенесите данные через `rsync -aHAX`.

## 3. Клонируйте отдельный node-репозиторий

```bash
apt-get update
apt-get upgrade -y
apt-get install -y git ca-certificates curl

rm -rf "$NODE_DIR.new"
git clone "$NODE_REPO" "$NODE_DIR.new"

install -d -m 0755 /opt
mv "$NODE_DIR.new" "$NODE_DIR"

cd "$NODE_DIR"
git switch main
git pull --ff-only origin main
```

Node устанавливается только из:

```text
https://github.com/rirodevdom/newdomofon-video-node
```

Старый объединённый monorepo не используется.

## 4. Установите зависимости

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

Helper может установить пакет PostgreSQL для совместимости старых scripts, но runtime node к PostgreSQL не подключается, а systemd unit не зависит от `postgresql.service`.

## 5. Получите credentials node на master

Сначала создайте node на master через UI или API. Ответ master должен содержать:

```text
node_id
agent_token
media_secret
```

Рекомендуется сохранить ответ master в файл:

```text
/root/video-node1-bootstrap.json
```

Пример содержимого:

```json
{
  "node_id": "UUID",
  "agent_token": "SECRET",
  "media_secret": "SECRET"
}
```

Передайте файл на node через защищённый канал и удалите лишние копии после настройки.

Проверка:

```bash
jq . /root/video-node1-bootstrap.json
chmod 600 /root/video-node1-bootstrap.json
```

## 6. Создайте production env

```bash
NODE_ID="$(jq -r '.node_id' /root/video-node1-bootstrap.json)"
NODE_TOKEN="$(jq -r '.agent_token' /root/video-node1-bootstrap.json)"
NODE_MEDIA_SECRET="$(jq -r '.media_secret' /root/video-node1-bootstrap.json)"

for value in "$NODE_ID" "$NODE_TOKEN" "$NODE_MEDIA_SECRET"; do
  test -n "$value" && test "$value" != null
 done

install -d -m 0750 /etc/newdomofon-video

cat > /etc/newdomofon-video/app.env <<EOF
NODE_ENV=production
DVR_ROLE=node
DVR_ENGINE_PORT=3010

DVR_ROOT=/var/lib/newdomofon-video/dvr
FFMPEG_PATH=/usr/bin/ffmpeg
SEGMENT_DURATION=4
LIVE_WINDOW=8
CAMERA_RELOAD_SECONDS=20
CLEANUP_INTERVAL_MINUTES=60
MAX_EXPORT_SECONDS=3600

DVR_MASTER_URL=https://${MASTER_DOMAIN}
DVR_NODE_ID=${NODE_ID}
DVR_NODE_TOKEN=${NODE_TOKEN}
DVR_NODE_MEDIA_SECRET=${NODE_MEDIA_SECRET}

DVR_NODE_PUBLIC_BASE_URL=https://${NODE_DOMAIN}
DVR_NODE_INTERNAL_URL=http://${NODE_PRIVATE_IP}:3010
DVR_REQUIRE_MEDIA_TOKEN=true
DVR_CORS_ORIGIN=https://${MASTER_DOMAIN}

DVR_EVENT_DB=/var/lib/newdomofon-video/events/events.sqlite3
DVR_EVENT_RETENTION_DAYS=30
DVR_EVENT_CLEANUP_INTERVAL_MINUTES=60
DVR_EVENT_QUERY_MAX_SECONDS=2678400
DVR_EVENT_STORE_RAW_PAYLOAD=false

ONVIF_EVENTS_ENABLED=true
ONVIF_EVENTS_REQUEST_TIMEOUT_MS=15000

DVR_HIKVISION_EVENTS_ENABLED=false
VIDEO_MOTION_ENABLED=false

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

События не используют `BACKEND_INTERNAL_URL` и `INTERNAL_DVR_SECRET`. Они сохраняются только локально.

`DVR_EVENT_STORE_RAW_PAYLOAD=false` уменьшает размер event database и риск сохранения лишних данных. Включайте raw payload только для ограниченной диагностики.

## 7. Подготовьте права runtime-каталогов

```bash
install -d -o newdomofon -g newdomofon -m 0750 \
  /var/lib/newdomofon-video/dvr \
  /var/lib/newdomofon-video/events

install -d -o newdomofon -g newdomofon -m 0755 \
  /var/log/newdomofon-video

chown -R newdomofon:newdomofon \
  /var/lib/newdomofon-video/dvr \
  /var/lib/newdomofon-video/events
```

Проверьте mount до запуска DVR:

```bash
findmnt /var/lib/newdomofon-video/dvr
findmnt -no SOURCE,FSTYPE,OPTIONS /var/lib/newdomofon-video/dvr
```

Если отдельный диск должен быть обязательным, не запускайте сервис при отсутствии mount.

## 8. Выполните deploy

```bash
cd "$NODE_DIR"
PROJECT_DIR="$NODE_DIR" \
  ENV_FILE=/etc/newdomofon-video/app.env \
  bash scripts/deploy-node.sh
```

Deploy:

1. устанавливает npm-зависимости DVR engine;
2. собирает TypeScript;
3. удаляет dev dependencies;
4. устанавливает systemd unit;
5. устанавливает nginx site;
6. запускает DVR service;
7. проверяет nginx-конфигурацию.

Не запускайте `npm audit fix` автоматически на production.

## 9. Укажите DNS-имя в nginx

```bash
sed -i \
  "s/server_name _;/server_name ${NODE_DOMAIN};/" \
  /etc/nginx/sites-available/newdomofon-video-node.conf

nginx -t
systemctl reload nginx
```

После каждого повторного deploy проверяйте, что `server_name` не вернулся к `_`.

## 10. Выпустите TLS-сертификат

```bash
apt-get install -y certbot python3-certbot-nginx
certbot --nginx -d "$NODE_DOMAIN"
certbot renew --dry-run
```

## 11. Ограничьте доступ к порту 3010

Публичным клиентам обычно достаточно nginx `80/443`. Порт `3010` разрешайте только master/private network.

Проверьте, что node слушает:

```bash
ss -ltnp | grep ':3010 '
```

Firewall должен разрешать `3010/tcp` только с IP master. Не применяйте готовый firewall-файл вслепую: сначала проверьте текущие nftables rules, чтобы не потерять SSH-доступ.

Master может использовать:

```text
DVR_NODE_INTERNAL_URL=http://NODE_PRIVATE_IP:3010
```

Если прямой private connection невозможен, укажите HTTPS public URL node как fallback.

# Проверка после установки

## 12. Проверка сервиса и health

```bash
systemctl is-enabled newdomofon-video-dvr.service
systemctl is-active newdomofon-video-dvr.service
systemctl status newdomofon-video-dvr.service --no-pager -l | head -40

curl -fsS http://127.0.0.1:3010/health | jq
curl -kfsS "https://${NODE_DOMAIN}/health" | jq
```

Health должен содержать:

```json
{
  "ok": true,
  "service": "dvr-engine",
  "mode": "node",
  "recording_enabled": true,
  "events": {
    "ok": true,
    "storage": "sqlite",
    "wal": true
  }
}
```

## 13. Проверка SQLite event store

```bash
ls -lah /var/lib/newdomofon-video/events/

node - <<'NODE'
const { DatabaseSync } = require('node:sqlite');
const db = new DatabaseSync(
  '/var/lib/newdomofon-video/events/events.sqlite3',
  { readOnly: true }
);

const health = db.prepare(`
  SELECT
    count(*) AS total_events,
    min(occurred_at_ms) AS first_event_ms,
    max(occurred_at_ms) AS last_event_ms
  FROM camera_events
`).get();

console.log(health);
db.close();
NODE
```

Предупреждение Node.js о том, что `node:sqlite` experimental, ожидаемо для Node.js 22 и не означает ошибку базы.

## 14. Проверка связи с master

```bash
journalctl -u newdomofon-video-dvr.service \
  --since '10 minutes ago' \
  --no-pager \
  | grep -E 'node-agent|heartbeat|config|commands' \
  | tail -100
```

На master node должна иметь:

```text
status=online
last_seen_at обновляется
camera_count соответствует назначению
```

Если heartbeat отвечает `401`, проверьте `DVR_NODE_ID` и `DVR_NODE_TOKEN`. После ротации token обновите node env и перезапустите сервис.

## 15. Назначьте камеры

Камеры назначаются на master через UI/API. Node получает их через:

```text
GET /api/node-agent/config
```

После назначения можно принудительно перезапустить сервис:

```bash
systemctl restart newdomofon-video-dvr.service
```

Проверьте recorder processes без вывода RTSP credentials:

```bash
pgrep -fc '/usr/bin/ffmpeg'

systemctl status newdomofon-video-dvr.service \
  --no-pager \
  | sed -E 's#(rtsp://)[^ @]+@#\1***:***@#g' \
  | head -80
```

Никогда не публикуйте полный `systemctl status`, если в FFmpeg command line присутствуют пароли камер.

# ONVIF events

Node использует единый PullPoint collector `v301-node-local-pullpoint`.

Он:

- получает только назначенные node камеры;
- пробует SOAP 1.2 и SOAP 1.1;
- пробует WS-Addressing и plain requests;
- поддерживает UsernameToken PasswordDigest и PasswordText;
- сохраняет события локально;
- дедуплицирует повторения;
- фильтрует повторяющиеся state snapshots;
- не отправляет payload на master.

## Требования к камере

На master для камеры должны быть корректны:

```text
onvif_xaddr или device_host/onvif_port
onvif_username
onvif_password
stream_name
назначение dvr_server_id
```

На камере должны быть включены нужные события: motion, line crossing, intrusion и другие.

## Проверка collector

```bash
journalctl -u newdomofon-video-dvr.service \
  --since '10 minutes ago' \
  --no-pager \
  | grep -E '\[onvif-events:v3\]|\[event-store\]' \
  | tail -300
```

Ожидаются:

```text
[event-store] initialized
[onvif-events:v3] enabled
[onvif-events:v3] camera loop started
[onvif-events:v3] subscription ready
[onvif-events:v3] events stored locally
```

После движения перед камерой:

```bash
journalctl -u newdomofon-video-dvr.service \
  --since '3 minutes ago' \
  --no-pager \
  | grep -E 'events stored locally|camera loop failed|subscription ready'
```

Последние события:

```bash
node - <<'NODE'
const { DatabaseSync } = require('node:sqlite');
const db = new DatabaseSync(
  '/var/lib/newdomofon-video/events/events.sqlite3',
  { readOnly: true }
);

const rows = db.prepare(`
  SELECT
    stream_name,
    event_type,
    event_state,
    topic,
    datetime(occurred_at_ms / 1000, 'unixepoch') AS occurred_at
  FROM camera_events
  ORDER BY occurred_at_ms DESC
  LIMIT 50
`).all();

console.table(rows);
db.close();
NODE
```

# Event API

Node endpoints:

```text
GET /cameras/:streamName/events
GET /cameras/:streamName/events/summary
GET /cameras/:streamName/events/health
```

Они требуют короткоживущий HMAC token со scope `events`.

Без token ожидается:

```bash
curl -sS -o /tmp/events.json -w 'HTTP %{http_code}\n' \
  "http://127.0.0.1:3010/cameras/test/events"
cat /tmp/events.json
```

Ожидается HTTP `401`. Неверный/истёкший token возвращает `403`.

Постоянные camera/live/archive tokens не дают доступ к event API.

# Hikvision и video motion

Hikvision events по умолчанию отключены:

```text
DVR_HIKVISION_EVENTS_ENABLED=false
```

Включайте после проверки устройства и channel mapping:

```bash
sed -i \
  's/^DVR_HIKVISION_EVENTS_ENABLED=.*/DVR_HIKVISION_EVENTS_ENABLED=true/' \
  /etc/newdomofon-video/app.env
systemctl restart newdomofon-video-dvr.service
```

FFmpeg scene detector также выключен по умолчанию. Для выбранных потоков:

```text
VIDEO_MOTION_ENABLED=true
VIDEO_MOTION_STREAMS=stream1,stream2
VIDEO_MOTION_SOURCE=hls
VIDEO_MOTION_FPS=3
VIDEO_MOTION_SCENE_THRESHOLD=0.010
```

Video-motion потребляет дополнительные CPU. Не включайте `*` на большой node без измерения нагрузки.

# Обновление существующей node

Обновление node не должно изменять master и не должно удалять archive/event database.

```bash
set -Eeuo pipefail

PROJECT="/opt/newdomofon-video-node"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="/opt/newdomofon-video-migration-backups/node-update-$STAMP"

install -d -m 0750 "$BACKUP"

cp -a /etc/newdomofon-video "$BACKUP/etc-newdomofon-video"
git -C "$PROJECT" status --short > "$BACKUP/git-status.txt"
git -C "$PROJECT" rev-parse HEAD > "$BACKUP/git-commit.txt"
git -C "$PROJECT" diff --binary > "$BACKUP/worktree.patch" || true

if [ -d "$PROJECT/dvr-engine/dist" ]; then
  cp -a "$PROJECT/dvr-engine/dist" "$BACKUP/dist-before"
fi

git -C "$PROJECT" stash push -u \
  -m "production-before-node-update-$STAMP" || true

git -C "$PROJECT" fetch origin main
git -C "$PROJECT" switch main
git -C "$PROJECT" pull --ff-only origin main

cd "$PROJECT/dvr-engine"
npm ci --include=dev
npm run build
npm prune --omit=dev

systemctl restart newdomofon-video-dvr.service

for i in $(seq 1 60); do
  curl -fsS http://127.0.0.1:3010/health && break
  sleep 1
done
```

После обновления:

```bash
git -C "$PROJECT" log -1 --oneline
git -C "$PROJECT" status --short
curl -fsS http://127.0.0.1:3010/health | jq
journalctl -u newdomofon-video-dvr.service -n 200 --no-pager
```

Не применяйте старый stash обратно, пока не сравните его с новым `main`.

# Backup

## Конфигурация

```bash
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="/var/backups/newdomofon-video/node-$STAMP"

install -d -m 0700 "$BACKUP"
cp -a /etc/newdomofon-video "$BACKUP/"
git -C /opt/newdomofon-video-node rev-parse HEAD \
  > "$BACKUP/git-commit.txt"
```

## Event database

Для консистентной простой копии остановите DVR на короткое время:

```bash
systemctl stop newdomofon-video-dvr.service

cp -a /var/lib/newdomofon-video/events \
  "$BACKUP/events"

systemctl start newdomofon-video-dvr.service
curl -fsS http://127.0.0.1:3010/health
```

Копируйте вместе `events.sqlite3`, `-wal` и `-shm`, если сервис не остановлен. Предпочтителен backup при остановленном сервисе.

## Видеоархив

Архив обычно слишком велик для полного ежедневного backup. Используйте:

- RAID не как замену backup, а как защиту от отказа диска;
- репликацию критичных камер;
- отдельное объектное/файловое хранилище;
- проверку SMART и свободного места;
- регулярный тест восстановления.

# Перенос архивного диска

```bash
systemctl stop newdomofon-video-dvr.service

rsync -aHAX --numeric-ids --info=progress2 \
  /var/lib/newdomofon-video/dvr/ \
  /mnt/new-disk/dvr/

# Затем смонтируйте новый диск в /var/lib/newdomofon-video/dvr.
findmnt /var/lib/newdomofon-video/dvr
chown -R newdomofon:newdomofon /var/lib/newdomofon-video/dvr

systemctl start newdomofon-video-dvr.service
curl -fsS http://127.0.0.1:3010/health
```

Не используйте `rsync --delete`, пока не проверена правильность source/destination.

# Rollback

Не удаляйте:

```text
/etc/newdomofon-video/app.env
/var/lib/newdomofon-video/dvr
/var/lib/newdomofon-video/events
```

Откат к предыдущему commit:

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

Если новый код изменил SQLite schema, перед откатом используйте backup event database.

# Диагностика

## Service и journal

```bash
systemctl status newdomofon-video-dvr.service --no-pager -l
journalctl -u newdomofon-video-dvr.service -n 300 --no-pager
```

## Диск

```bash
df -hT /var/lib/newdomofon-video/dvr
df -ih /var/lib/newdomofon-video/dvr
du -sh /var/lib/newdomofon-video/dvr
lsblk -o NAME,SIZE,FSTYPE,UUID,MOUNTPOINTS
```

## FFmpeg

```bash
pgrep -fc '/usr/bin/ffmpeg'
ps -eo pid,etimes,%cpu,%mem,cmd \
  | grep '[f]fmpeg' \
  | sed -E 's#(rtsp://)[^ @]+@#\1***:***@#g' \
  | head -50
```

## Последние записанные сегменты

```bash
find /var/lib/newdomofon-video/dvr \
  -type f \
  -name '*.ts' \
  -mmin -2 \
  -printf '%TY-%Tm-%Td %TH:%TM:%TS %p\n' \
  | tail -50
```

## Сеть до master

```bash
curl -kfsS "https://${MASTER_DOMAIN}/api/health"
getent ahosts "$MASTER_DOMAIN"
timedatectl status
```

## Ошибки media token

- `401 Missing media token` — token не передан;
- `403 Invalid media token` — неверный secret, scope, stream name, version или истёкший token;
- `503 Node inactive` — отсутствует действующая activation lease/config;
- `503 Node event storage is unavailable` на master — master не может подключиться к node event API.

Проверьте совпадение `media_secret` в master и `/etc/newdomofon-video/app.env` node.

# Безопасность

- Не публикуйте RTSP/ONVIF URL и FFmpeg command lines без редактирования credentials.
- Используйте отдельные сложные пароли камер.
- Ограничьте ONVIF/RTSP сети firewall-правилами.
- Не открывайте `3010/tcp` всему интернету.
- Используйте HTTPS для публичного node URL.
- Храните agent token и media secret с правами `0640 root:newdomofon`.
- После ротации credentials перезапускайте node и проверяйте heartbeat.
- Не храните raw event payload без необходимости.
- Не удаляйте archive/event storage при обновлении Git checkout.

# Добавление второй и последующих node

Для каждой node:

1. создайте отдельную запись на master;
2. получите уникальные `node_id`, `agent_token`, `media_secret`;
3. используйте отдельный DNS/public URL;
4. создайте отдельный `app.env`;
5. назначьте только её камеры;
6. проверьте heartbeat, live, archive и events;
7. не копируйте credentials от другой node.

# Правила разработки

Все изменения data plane выполняются только в:

```text
https://github.com/rirodevdom/newdomofon-video-node
```

Master-код не копируется в node. Общими являются только versioned contracts.

Порядок изменения API:

1. обновить contract;
2. обеспечить обратно совместимую поддержку master;
3. обновить node;
4. выполнить production verification;
5. удалить legacy API только отдельным major change.

Старый объединённый monorepo не является источником production-кода.
