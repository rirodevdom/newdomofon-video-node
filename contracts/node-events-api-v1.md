# NewDomofon Video Node Events API v1

Этот контракт разделяет control plane и data plane.

- Master хранит пользователей, RBAC, камеры, назначение камер node и node credentials.
- Node является владельцем видеоархива и событий.
- Master не сохраняет payload событий и не использует `camera_events` для timeline.
- Frontend обращается к прежнему master API, а master после RBAC-проверки проксирует запрос к назначенной node.

## Node storage

По умолчанию:

```text
/var/lib/newdomofon-video/events/events.sqlite3
```

Переменные:

```text
DVR_EVENT_DB=/var/lib/newdomofon-video/events/events.sqlite3
DVR_EVENT_RETENTION_DAYS=30
DVR_EVENT_CLEANUP_INTERVAL_MINUTES=60
DVR_EVENT_QUERY_MAX_SECONDS=2678400
```

SQLite использует WAL, `synchronous=NORMAL` и `busy_timeout=5000`.

## Node authorization

Master подписывает короткоживущий HMAC token с payload:

```json
{
  "camera_id": "uuid",
  "stream_name": "camera_stream",
  "user_id": "uuid",
  "scope": "events",
  "exp": 1783698000
}
```

Постоянный token без `exp` не разрешен для scope `events`.

## Node endpoints

### `GET /cameras/:streamName/events`

Query:

- `start` — ISO 8601;
- `end` — ISO 8601;
- `type` — опционально;
- `limit` — 1..5000;
- `token` — HMAC token scope `events`.

Response:

```json
{
  "items": [
    {
      "id": "uuid",
      "camera_id": "uuid",
      "stream_name": "camera_stream",
      "event_type": "motion",
      "event_state": "true",
      "topic": "RuleEngine/CellMotionDetector/Motion",
      "source_name": "VideoSource_1",
      "occurred_at": "2026-07-10T12:32:15.250Z",
      "created_at": "2026-07-10T12:32:15.310Z",
      "data": {}
    }
  ]
}
```

### `GET /cameras/:streamName/events/summary`

Query: `start`, `end`, `token`.

Response:

```json
{
  "items": [
    {
      "bucket": "2026-07-10T12:32:00.000Z",
      "count": 4,
      "types": ["motion"]
    }
  ]
}
```

### `GET /cameras/:streamName/events/health`

Response содержит состояние локальной SQLite, количество событий и retention.

## Master endpoints

Frontend продолжает использовать:

```text
GET /api/cameras/:cameraId/events
GET /api/cameras/:cameraId/events/summary
```

Master:

1. проверяет JWT и RBAC;
2. определяет назначенную node;
3. создает короткий `scope=events` token;
4. обращается к internal URL node, затем к public URL как fallback;
5. возвращает ответ без записи в PostgreSQL.

Если node недоступна, master возвращает `503 Node event storage is unavailable`.

## Legacy ingest

Следующие маршруты считаются устаревшими и возвращают `410 Gone` после переключения master:

```text
POST /api/internal/events/onvif
```

Collector node не должен отправлять event payload на master.
