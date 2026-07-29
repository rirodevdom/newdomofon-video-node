# Переменные окружения video node

Основной production-файл:

```text
/etc/newdomofon-video/app.env
```

Шаблон: `deploy/env/node.env.example`.

После изменения параметров:

```bash
systemctl restart newdomofon-video-dvr.service
```

Файл содержит секреты. Обычная установка использует `root:newdomofon 0640`, root-only установка — `root:root 0600`.

## Основной runtime

| Переменная | Назначение |
|---|---|
| `NODE_ENV` | На production — `production`. |
| `DVR_ENGINE_ROLE` | На отдельной video node — `node`. |
| `DVR_ENGINE_PORT` | HTTP-порт DVR engine, обычно `3010`. |
| `DVR_ROOT` | Первый корень live и локального архива. |
| `DVR_STORAGE_ROOTS` | Список archive mountpoints через запятую. |
| `FFMPEG_PATH` | Путь к FFmpeg. |
| `SEGMENT_DURATION` | Длительность HLS/архивного сегмента. |
| `LIVE_WINDOW` | Размер live playlist. |
| `CAMERA_RELOAD_SECONDS` | Интервал получения camera config с master. |
| `CLEANUP_INTERVAL_MINUTES` | Интервал retention-очистки. |
| `MAX_EXPORT_SECONDS` | Максимальная длительность MP4 export. |
| `DVR_LIVE_PLAYLIST_WAIT_MS` | Ожидание появления live playlist. |

## Регистрация на master

| Переменная | Назначение |
|---|---|
| `DVR_MASTER_URL` | URL master без завершающего `/`. |
| `DVR_NODE_ID` | UUID node. |
| `DVR_NODE_TOKEN` | Agent token для heartbeat/config/commands. |
| `DVR_NODE_MEDIA_SECRET` | Секрет короткоживущих media/event tokens. |
| `DVR_NODE_PUBLIC_BASE_URL` | Публичный URL node. |
| `DVR_NODE_INTERNAL_URL` | Private URL DVR engine. |
| `DVR_REQUIRE_MEDIA_TOKEN` | В production оставлять `true`. |
| `DVR_CORS_ORIGIN` | Разрешённый browser origin. |

## DASH и snapshot

| Переменная | Назначение |
|---|---|
| `DVR_DASH_SEGMENT_SECONDS` | Длительность DASH segment. |
| `DVR_DASH_WINDOW_SIZE` | Размер DASH manifest. |
| `DVR_DASH_EXTRA_WINDOW_SIZE` | Запас старых DASH segments. |
| `DVR_DASH_READY_TIMEOUT_MS` | Ожидание on-demand DASH. |
| `DVR_DASH_IDLE_MS` | Idle timeout DASH-процесса. |
| `DVR_SNAPSHOT_CACHE_MS` | TTL JPEG snapshot. |
| `DVR_SNAPSHOT_JPEG_QUALITY` | FFmpeg JPEG quality. |

## Локальные события

| Переменная | Назначение |
|---|---|
| `DVR_EVENT_DB` | Путь к SQLite событий. |
| `DVR_EVENT_RETENTION_DAYS` | Retention событий. |
| `DVR_EVENT_CLEANUP_INTERVAL_MINUTES` | Интервал очистки SQLite. |
| `DVR_EVENT_QUERY_MAX_SECONDS` | Максимальный диапазон event query. |
| `DVR_EVENT_STORE_RAW_PAYLOAD` | Сохранять исходный ONVIF payload. |
| `ONVIF_EVENTS_ENABLED` | Включить ONVIF PullPoint collector. |
| `ONVIF_EVENTS_REQUEST_TIMEOUT_MS` | Timeout ONVIF event request. |
| `VIDEO_MOTION_ENABLED` | Включить FFmpeg software motion detection. |

Hikvision ISAPI и связанные переменные в этом проекте не поддерживаются. После обновления `scripts/remove-hikvision-runtime.py` удаляет устаревшие ключи `DVR_HIKVISION_*` и `DVR_DEVICE_ARCHIVE_*` из production `app.env`.

## Синхронизация событий с локальным архивом

| Переменная | Назначение |
|---|---|
| `DVR_ARCHIVE_EVENT_SYNC_ENABLED` | Включить reconciler событий и локального архива. |
| `DVR_ARCHIVE_EVENT_SYNC_APPLY` | `false` — отчёт; `true` — удаление orphan events. |
| `DVR_ARCHIVE_EVENT_SYNC_MIN_AGE_MINUTES` | Не проверять слишком свежие часы. |
| `DVR_ARCHIVE_EVENT_SYNC_MAX_HOURS_PER_RUN` | Лимит camera-hour buckets. |
| `DVR_ARCHIVE_EVENT_SYNC_MASTER_TIMEOUT_MS` | Timeout camera config с master. |

## Disk guard

| Переменная | Назначение |
|---|---|
| `DVR_DISK_MIN_FREE_BYTES` | Минимум свободных байт на archive filesystem. |
| `DVR_DISK_MIN_FREE_PERCENT` | Минимум свободного места в процентах. |
| `DVR_DISK_RESUME_FREE_BYTES` | Byte-порог восстановления. |
| `DVR_DISK_RESUME_FREE_PERCENT` | Процентный порог восстановления. |
| `DVR_DISK_MIN_FREE_INODES_PERCENT` | Минимум свободных inode. |
| `DVR_DISK_RESUME_FREE_INODES_PERCENT` | Порог восстановления inode. |
| `DVR_SYSTEM_MIN_FREE_BYTES` | Минимум на system filesystem. |
| `DVR_SYSTEM_MIN_FREE_PERCENT` | Минимум system filesystem в процентах. |
| `DVR_SYSTEM_RESUME_FREE_BYTES` | Byte-порог восстановления system filesystem. |
| `DVR_SYSTEM_RESUME_FREE_PERCENT` | Процентный порог восстановления system filesystem. |
| `DVR_DISK_MIN_ARCHIVE_AGE_MINUTES` | Минимальный возраст удаляемого archive-hour. |
| `DVR_DISK_MAX_DELETE_DIRS_PER_RUN` | Лимит удаления каталогов за запуск. |
| `DVR_DISK_STALE_TMP_MINUTES` | Возраст stale export/tmp файлов. |
| `DVR_DISK_REQUIRE_MOUNTPOINT` | Требовать отдельный mountpoint для archive roots. |

## Установочные параметры

| Переменная | Назначение |
|---|---|
| `PROJECT_DIR` | Каталог проекта. |
| `ENV_FILE` | Путь к runtime env. |
| `INSTALL_DISK_GUARD` | Устанавливать disk guard. |
| `INSTALL_JOURNAL_LIMITS` | Устанавливать journald limits. |
| `INSTALL_ARCHIVE_EVENT_SYNC` | Устанавливать archive/event sync timer. |
| `REGISTRATION_FILE` | Файл данных регистрации для master. |

## Безопасная проверка

```bash
ENV_FILE=/etc/newdomofon-video/app.env
sed -E 's/^(DVR_NODE_TOKEN|DVR_NODE_MEDIA_SECRET)=.*/\1=<redacted>/' "$ENV_FILE"
```
