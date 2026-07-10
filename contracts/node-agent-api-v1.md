# NewDomofon Video Node Agent API v1

Этот документ является общим контрактом между проектами `newdomofon-video-master` и `newdomofon-video-node`.

## Общие правила

Base URL задается на node через `DVR_MASTER_URL`.

Каждый запрос после регистрации содержит:

```http
Authorization: Bearer <DVR_NODE_TOKEN>
X-Node-ID: <DVR_NODE_ID>
X-Node-Protocol-Version: 1
Content-Type: application/json
```

Master возвращает:

```json
{
  "protocol_version": 1
}
```

Неизвестные дополнительные поля должны игнорироваться обеими сторонами.

## Регистрация

### `POST /api/node-agent/register`

Регистрация выполняется только при первичной установке или полной ротации учетных данных.

Request:

```json
{
  "registration_token": "...",
  "name": "Node 1",
  "public_base_url": "https://video-node-1.example.com",
  "internal_url": "http://10.0.10.11:3010",
  "version": "1.0.0",
  "protocol_version": 1,
  "capabilities": {
    "hls": true,
    "archive": true,
    "export": true,
    "onvif_events": true
  }
}
```

Response `201`:

```json
{
  "protocol_version": 1,
  "node_id": "uuid",
  "agent_token": "secret",
  "media_secret": "secret",
  "public_base_url": "https://video-node-1.example.com"
}
```

`agent_token` и `media_secret` должны сохраняться node локально с правами не шире `0640` и не должны попадать в Git или диагностические архивы.

## Heartbeat и activation lease

### `POST /api/node-agent/heartbeat`

Request:

```json
{
  "protocol_version": 1,
  "public_base_url": "https://video-node-1.example.com",
  "internal_url": "http://10.0.10.11:3010",
  "version": "1.0.0",
  "capabilities": {
    "hostname": "video-node1",
    "hls": true,
    "archive": true,
    "export": true,
    "onvif_events": true
  },
  "storage": {
    "root": "/var/lib/newdomofon-video/dvr",
    "total_bytes": 1000000000000,
    "free_bytes": 500000000000,
    "available_bytes": 490000000000
  },
  "runtime": {
    "recorders": 12,
    "event_spool_items": 0,
    "config_generation": "42"
  }
}
```

Response `200`:

```json
{
  "protocol_version": 1,
  "ok": true,
  "node_id": "uuid",
  "active": true,
  "activation_lease": {
    "issued_at": "2026-07-10T10:00:00.000Z",
    "expires_at": "2026-07-10T10:02:00.000Z",
    "ttl_seconds": 120
  },
  "config_generation": "43"
}
```

Семантика:

- `active=true` и непросроченный lease разрешают запись и media API;
- `active=false` запрещает запуск рекордеров и обслуживание media API;
- HTTP `401/403` означает отозванные или недействительные учетные данные и переводит node в `revoked`;
- сетевой timeout/`5xx` переводит node в `degraded` до истечения уже полученного lease;
- после истечения lease node обязана перейти в `inactive`;
- node не должна продлевать lease локально самостоятельно.

## Получение конфигурации

### `GET /api/node-agent/config`

Response `200`:

```json
{
  "protocol_version": 1,
  "node_id": "uuid",
  "node_name": "Node 1",
  "config_generation": "43",
  "media_secret": "secret",
  "cameras": [
    {
      "id": "camera-uuid",
      "name": "Entrance 1",
      "stream_name": "cam_entrance_1",
      "source_url": "rtsp://...",
      "archive_storage": "node",
      "retention_days": 14,
      "is_enabled": true,
      "device_id": "device-uuid",
      "device_connection_type": "ONVIF",
      "device_archive_storage": "node",
      "device_host": "10.0.20.10",
      "device_port": 80,
      "device_username": "user",
      "device_password": "password",
      "onvif_xaddr": "http://10.0.20.10/onvif/device_service",
      "onvif_port": 80,
      "onvif_username": "user",
      "onvif_password": "password",
      "onvif_profile_token": "profile_1"
    }
  ]
}
```

Node обязана атомарно сохранять последнюю успешно полученную конфигурацию в локальное durable-хранилище.

Кеш конфигурации разрешено использовать только при действующем activation lease. Наличие кеша без lease не активирует node.

## Команды

### `GET /api/node-agent/commands`

Response:

```json
{
  "protocol_version": 1,
  "items": [
    {
      "id": "command-uuid",
      "type": "reload_cameras",
      "payload": {},
      "created_at": "2026-07-10T10:00:00.000Z"
    }
  ]
}
```

Поддерживаемые команды v1:

- `reload_cameras`;
- `restart_recordings`;
- `sync_events`;
- `rotate_media_secret`;
- `deactivate`.

Неизвестная команда должна завершаться статусом `failed` с понятной причиной, но не должна останавливать poll loop.

### `POST /api/node-agent/commands/:id/result`

Request:

```json
{
  "protocol_version": 1,
  "status": "done",
  "result": {
    "ok": true,
    "config_generation": "43"
  }
}
```

`status` принимает `done` или `failed`.

## События

### `POST /api/internal/events/onvif`

До выделения отдельного event-ingest endpoint сохраняется существующий маршрут.

Headers:

```http
X-Internal-Secret: <INTERNAL_DVR_SECRET>
X-Node-ID: <DVR_NODE_ID>
X-Node-Protocol-Version: 1
```

Request:

```json
{
  "event_id": "stable-unique-id",
  "camera_id": "camera-uuid",
  "stream_name": "cam_entrance_1",
  "event_type": "tns1:RuleEngine/CellMotionDetector/Motion",
  "event_state": "true",
  "occurred_at": "2026-07-10T10:01:10.000Z",
  "data": {}
}
```

Master должен выполнять идемпотентную вставку по `event_id` либо по устойчивому вычисляемому ключу. Повторная отправка из локальной очереди node не должна создавать дубликаты.

Node должна сохранять событие в локальную очередь до подтвержденного `2xx` от master.

## Playback/media

Master после RBAC-проверки выдает клиенту URL node с короткоживущим HMAC token. Node валидирует token локально без обращения к master на каждый сегмент.

Node дополнительно проверяет собственное activation state:

- действующий lease — запрос обрабатывается;
- lease отсутствует или истек — `503` с JSON `{ "error": "Node inactive" }`;
- исключение допускается только для `/health` и локальных административных диагностик, защищенных отдельной локальной авторизацией.

## Health node

### `GET /health`

Response:

```json
{
  "ok": true,
  "service": "newdomofon-video-node",
  "version": "1.0.0",
  "protocol_version": 1,
  "node_id": "uuid",
  "activation": {
    "state": "active",
    "active": true,
    "master_connected": true,
    "lease_expires_at": "2026-07-10T10:02:00.000Z",
    "last_success_at": "2026-07-10T10:00:15.000Z",
    "last_error": null
  },
  "recorders": 12,
  "config_generation": "43"
}
```

`ok` показывает, что процесс и локальные зависимости исправны. Рабочее разрешение определяется только полем `activation.active`.

## Совместимость с текущей реализацией

Текущие endpoint и основные поля сохраняются. Поля `protocol_version`, `active` и `activation_lease` добавляются обратно совместимо. Поэтому master можно обновить первым, а node — после проверки master.
