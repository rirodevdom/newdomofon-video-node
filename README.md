# NewDomofon Video Node

Отдельный **data plane** NewDomofon Video: FFmpeg recorder, live HLS/MPEG-TS/DASH/JPEG, локальный архив, MP4 export, archive ranges, ONVIF events, SQLite/WAL и disk guard.

Этот репозиторий устанавливается **только на video node**. Master backend, PostgreSQL, пользователи, RBAC, устройства, камеры и внешние managed tokens находятся в проекте `newdomofon-video-master`.

> Production: Debian 12, Node.js 22, FFmpeg, Nginx и systemd. PostgreSQL для runtime node не требуется.

## Граница ответственности

Video node работает только с универсальными протоколами и потоками:

- RTSP recording через FFmpeg;
- live HLS, MPEG-TS, DASH и JPEG snapshot;
- локальный архив, ranges и MP4 export;
- ONVIF discovery и PullPoint events;
- программное обнаружение движения;
- локальная SQLite событий;
- multi-disk storage и disk guard.

В репозитории **нет** Hikvision ISAPI, `alertStream`, поиска записей на NVR и воспроизведения архива устройства. Эти функции должны находиться в отдельной специализированной Hikvision-node и взаимодействовать с master через отдельный контракт.

## Серверы без доступа к GitHub

Установка и обновление production node выполняются только из ZIP/TAR, который скачан на другом компьютере, передан на сервер и распакован в отдельную папку, например:

```text
/root/newdomofon-video-node-main
```

Git на production-сервере не требуется.

## Регистрация node

Во время установки оператор задаёт:

```text
DVR_MASTER_URL
DVR_NODE_ID
DVR_NODE_TOKEN
DVR_NODE_MEDIA_SECRET
DVR_NODE_PUBLIC_BASE_URL
DVR_NODE_INTERNAL_URL
```

После установки создаётся root-only файл:

```text
/root/newdomofon-node-master-registration.env
```

Значения из него вводятся в `Администрирование → Ноды → Создать node`.

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
| ONVIF events / SQLite / disk guard            |
+-----------------------------------------------+
              |
              | RTSP / ONVIF
              v
           Камеры / NVR
```

## Установка из распакованного архива

```bash
cd /root/newdomofon-video-node-main
bash scripts/install-node-manual-local-root.sh
```

Неинтерактивный deploy:

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

## Обновление node

Сначала обновляются video node, затем master.

```bash
cd /root/newdomofon-video-node-main
bash update-installed-project.sh --dry-run
bash update-installed-project.sh
```

Updater сохраняет `app.env`, registration env, SQLite событий, Nginx, systemd unit и локальный архив. Во время сборки автоматически удаляются устаревшие Hikvision-переменные, старые скомпилированные ISAPI-модули и временные device-archive каталоги.

Подробно: [docs/UPDATE_FROM_ARCHIVE.md](docs/UPDATE_FROM_ARCHIVE.md).

## Production-пути

```text
/opt/newdomofon-video-node/
/etc/newdomofon-video/app.env
/root/newdomofon-node-master-registration.env
/var/lib/newdomofon-video/dvr/
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
