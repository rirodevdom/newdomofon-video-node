# NewDomofon Video Node

Самостоятельный сервер записи и выдачи media NewDomofon Video, управляемый через master.

## Назначение

Node отвечает за:

- локальную запись камер через FFmpeg;
- live HLS, локальный архив, ranges и MP4 export;
- локальное хранение архива и retention;
- ONVIF/Hikvision-события;
- локальное durable-состояние конфигурации;
- локальную очередь событий и результатов команд;
- диагностику диска, камер и рекордеров.

Node не использует PostgreSQL master и не импортирует код master. Связь выполняется только через версионируемый HTTP API.

## Обязательная активация

Node не активируется только по наличию локальной конфигурации или архива.

При запуске она должна получить у master действующий activation lease. При кратковременном обрыве связи разрешена работа до окончания lease. После его окончания запись останавливается, а media API возвращает `503 Node inactive`.

Контракт:

```text
contracts/node-agent-api-v1.md
```

## Состав

```text
dvr-engine/            recorder, media API, node agent and event collectors
dvr-archive-proxy/     archive compatibility helpers
restreamer/             restream helper
restream-gateway/       restream gateway
live-only-engine/       live-only helper
contracts/              versioned master/node API contracts
deploy/                 node deployment examples
scripts/                install, deploy, repair and diagnostics
```

## Быстрое развертывание

```bash
sudo apt-get update
sudo apt-get install -y git unzip
sudo mkdir -p /opt/newdomofon-video-node
sudo chown -R "$USER:$USER" /opt/newdomofon-video-node

cd /opt/newdomofon-video-node
sudo bash scripts/install-debian12-prereqs.sh
sudo PROJECT_DIR=/opt/newdomofon-video-node bash scripts/deploy-node.sh
```

Сохраните полученные от master значения в `/etc/newdomofon-video/app.env`:

```text
DVR_MASTER_URL=...
DVR_NODE_ID=...
DVR_NODE_TOKEN=...
DVR_NODE_MEDIA_SECRET=...
DVR_NODE_PUBLIC_BASE_URL=...
DVR_REQUIRE_MEDIA_TOKEN=true
```

## Обновление существующей node

При переносе с монорепозитория нельзя удалять:

- `/etc/newdomofon-video/app.env`;
- `/var/lib/newdomofon-video/dvr`;
- локальный конфигурационный store и event spool;
- nginx/systemd production-настройки до проверки новой версии.

Рекомендуемый путь нового checkout:

```text
/opt/newdomofon-video-node
```

Старый `/opt/newdomofon-video` остается rollback-копией до проверки live, archive, events и heartbeat.

## Runtime-данные

Не добавлять в Git:

- agent token, media secret и internal secret;
- RTSP/ONVIF пароли;
- локальную конфигурационную базу/cache;
- event spool;
- содержимое DVR archive;
- TLS private keys.
