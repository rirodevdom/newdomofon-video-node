# NewDomofon Video Node

Отдельный **data plane** NewDomofon Video: FFmpeg recorder, live HLS/MPEG-TS/DASH/JPEG, локальный архив, MP4 export, archive ranges, ONVIF/Hikvision events, SQLite/WAL и disk guard.

Этот репозиторий устанавливается **только на video node**. Master backend, PostgreSQL, пользователи, RBAC, устройства, камеры и внешние managed tokens находятся в проекте `newdomofon-video-master`.

> Production: Debian 12, Node.js 22, FFmpeg, Nginx и systemd. PostgreSQL для runtime node не требуется.

## Серверы без доступа к репозиторию

Установка и обновление production node выполняются только из ZIP/TAR, который:

1. скачан на другом компьютере;
2. передан на сервер;
3. распакован в отдельную папку, например `/root/newdomofon-video-node-main`.

Git на сервере не требуется и не используется. Нельзя применять `clone`, `fetch`, `pull`, `reset` или другие Git-команды для production-установки и обновления.

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

Затем значения из него вводятся в:

```text
Администрирование → Ноды → Создать node
```

Master не генерирует UUID, agent token или media secret.

Подробно: [docs/MANUAL_NODE_BOOTSTRAP.md](docs/MANUAL_NODE_BOOTSTRAP.md).

## Архитектура

```text
Пользователь / SmartYard / VLC
              |
              | HTTPS / RTSP к master
              v
+-----------------------------------------------+
| MASTER                                        |
| PostgreSQL, UI, RBAC, managed tokens          |
| media/events gateways, MediaMTX               |
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

Node не должна подключаться к PostgreSQL master или проверять внешние managed tokens.

## Установка node из распакованного архива

После передачи и распаковки ZIP:

```bash
cd /root/newdomofon-video-node-main
bash scripts/install-node-manual-local-root.sh
```

Установщик работает с файлами текущей распакованной папки и не обращается к репозиторию.

Во время установки потребуется указать:

```text
DVR_MASTER_URL
DVR_NODE_ID
DVR_NODE_TOKEN
DVR_NODE_MEDIA_SECRET
DVR_NODE_PUBLIC_BASE_URL
DVR_NODE_INTERNAL_URL
```

Неинтерактивный запуск штатного deploy возможен после подготовки значений:

```bash
PROJECT_DIR=/opt/newdomofon-video-node \
ENV_FILE=/etc/newdomofon-video/app.env \
  bash scripts/deploy-node.sh \
    --master-url http://10.106.1.30 \
    --node-id 11111111-2222-4333-8444-555555555555 \
    --node-token NODE_TOKEN_CHOSEN_BY_OPERATOR_32 \
    --media-secret MEDIA_SECRET_CHOSEN_BY_OPERATOR_32 \
    --public-url http://10.106.1.31 \
    --internal-url http://10.106.1.31:3010 \
    --non-interactive
```

Master не обязан быть доступен при установке. До создания записи на master heartbeat может получать `401/404`, но локальный DVR должен работать.

## Обновление node

Сначала обновляются все video node, затем master.

Из корня нового распакованного архива:

```bash
cd /root/newdomofon-video-node-main
bash update-installed-project.sh --dry-run
sudo bash update-installed-project.sh
```

Updater сохраняет `app.env`, registration env, SQLite событий, Nginx, systemd unit и текущие исходники. Архив в `/var/lib/newdomofon-video/dvr` не затрагивается. Версия архива фиксируется SHA-256 отпечатком содержимого.

Подробно: [docs/UPDATE_FROM_ARCHIVE.md](docs/UPDATE_FROM_ARCHIVE.md).

## Production-пути

```text
/opt/newdomofon-video-node/                    установленная копия проекта
/etc/newdomofon-video/app.env                  runtime config и secrets
/root/newdomofon-node-master-registration.env  значения для формы master
/var/lib/newdomofon-video/dvr/                 live и архив
/var/lib/newdomofon-video/events/events.sqlite3
/var/log/newdomofon-video/
/run/newdomofon-video/node-disk-state.json
/etc/nginx/sites-available/newdomofon-video-node.conf
/etc/systemd/system/newdomofon-video-dvr.service
```

## Проверка

```bash
systemctl is-active newdomofon-video-dvr.service
curl -fsS http://127.0.0.1:3010/health | jq
curl -fsS http://127.0.0.1:3010/recorders | jq
journalctl -u newdomofon-video-dvr.service -n 200 --no-pager
```

Проверьте root-only файл регистрации:

```bash
stat -c '%A %U:%G %n' \
  /root/newdomofon-node-master-registration.env
```

## Archive disk и disk guard

Рекомендуется монтировать отдельный filesystem прямо в:

```text
/var/lib/newdomofon-video/dvr
```

Если диск обязателен:

```text
DVR_DISK_REQUIRE_MOUNTPOINT=true
```

Проверка:

```bash
cat /run/newdomofon-video/node-disk-state.json | jq
systemctl status newdomofon-video-node-disk-guard.timer --no-pager
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

## Документация

- [Установка на Debian 12 без Git](docs/BAREMETAL_DEBIAN12.md)
- [Обновление из распакованного архива](docs/UPDATE_FROM_ARCHIVE.md)
- [Ручная регистрация на master](docs/MANUAL_NODE_BOOTSTRAP.md)
- [Все переменные `.env`](docs/ENVIRONMENT.md)
- [Disk guard](docs/DISK_PROTECTION.md)
- [Синхронизация событий с архивом](docs/ARCHIVE_EVENT_LIFECYCLE.md)

## Безопасность

- не публикуйте `app.env` и registration env;
- не распаковывайте архив внутрь `/opt/newdomofon-video-node`;
- не запускайте updater из установленного каталога;
- разрешайте node `3010` только master/private network;
- не публикуйте `DVR_NODE_TOKEN` или `DVR_NODE_MEDIA_SECRET`;
- не запускайте `npm audit fix` автоматически на production.
