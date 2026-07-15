# Переменные окружения video node

Основной production-файл:

```text
/etc/newdomofon-video/app.env
```

Шаблон:

```text
deploy/env/node.env.example
```

После изменения параметров перезапустите DVR:

```bash
systemctl restart newdomofon-video-dvr.service
```

Для параметров archive/event sync дополнительно можно перезапустить timer:

```bash
systemctl restart newdomofon-video-archive-event-sync.timer
```

Файл содержит секреты. Рекомендуемые права для обычной установки:

```bash
chown root:newdomofon /etc/newdomofon-video/app.env
chmod 0640 /etc/newdomofon-video/app.env
```

При root-only установке сервис работает от root, поэтому используются `root:root 0600`.

## 1. Основной runtime

| Переменная | Назначение |
|---|---|
| `NODE_ENV` | Режим Node.js. В production должно быть `production`. |
| `DVR_ENGINE_ROLE` | Роль DVR-процесса. На отдельной video node всегда `node`. Не используйте `standalone`. |
| `DVR_ENGINE_PORT` | Локальный HTTP-порт DVR engine. Стандартное значение `3010`. |
| `DVR_ROOT` | Корень live-файлов и локального архива. Рекомендуется отдельный смонтированный диск. |
| `FFMPEG_PATH` | Полный путь к бинарнику FFmpeg. Обычно `/usr/bin/ffmpeg`. |
| `SEGMENT_DURATION` | Целевая длительность HLS/архивного сегмента в секундах. |
| `LIVE_WINDOW` | Количество сегментов в live playlist. |
| `CAMERA_RELOAD_SECONDS` | Интервал повторного получения конфигурации камер с master. |
| `CLEANUP_INTERVAL_MINUTES` | Интервал штатной очистки архива по retention. Disk guard работает отдельно. |
| `MAX_EXPORT_SECONDS` | Максимальная длительность одного MP4 export в секундах. |
| `DVR_LIVE_PLAYLIST_WAIT_MS` | Сколько ждать появления live playlist перед возвратом ошибки. |

## 2. Ручная регистрация на master

Эти значения **выбираются при развёртывании node** и затем посимвольно переносятся в форму создания node на master.

| Переменная | Назначение |
|---|---|
| `DVR_MASTER_URL` | Базовый URL master, к которому node отправляет heartbeat, config и commands. Без завершающего `/`. |
| `DVR_NODE_ID` | UUID node. Выбирается оператором, например через `uuidgen`. На master сохраняется как `dvr_servers.id`. |
| `DVR_NODE_TOKEN` | Agent token для авторизации heartbeat/config/commands. Master хранит только SHA-256 хеш. |
| `DVR_NODE_MEDIA_SECRET` | Общий секрет master и этой node для внутренних короткоживущих media/event tokens. |
| `DVR_NODE_PUBLIC_BASE_URL` | URL node, который может использоваться для внешних/публичных media-ссылок. |
| `DVR_NODE_INTERNAL_URL` | URL, по которому master напрямую обращается к DVR engine, обычно private `http://IP:3010`. |
| `DVR_REQUIRE_MEDIA_TOKEN` | При `true` media/event endpoints требуют внутренний token. В production оставлять `true`. |
| `DVR_CORS_ORIGIN` | Разрешённый browser origin. Обычно равен `DVR_MASTER_URL`; `*` для production не рекомендуется. |

Допустимые символы `DVR_NODE_TOKEN` и `DVR_NODE_MEDIA_SECRET`:

```text
A-Z a-z 0-9 . _ ~ -
```

Длина каждого секрета: `16–512` символов. Рекомендуемая генерация:

```bash
uuidgen
openssl rand -hex 32
openssl rand -hex 32
```

После установки `scripts/deploy-node.sh` создаёт root-only копию значений:

```text
/root/newdomofon-node-master-registration.env
```

## 3. DASH и snapshot

| Переменная | Назначение |
|---|---|
| `DVR_DASH_SEGMENT_SECONDS` | Длительность DASH segment. |
| `DVR_DASH_WINDOW_SIZE` | Количество основных сегментов в DASH manifest. |
| `DVR_DASH_EXTRA_WINDOW_SIZE` | Дополнительный запас старых DASH segments. |
| `DVR_DASH_READY_TIMEOUT_MS` | Максимальное ожидание готовности on-demand DASH. |
| `DVR_DASH_IDLE_MS` | Через сколько миллисекунд без клиентов остановить DASH-процесс. |
| `DVR_SNAPSHOT_CACHE_MS` | Время кэширования JPEG snapshot. |
| `DVR_SNAPSHOT_JPEG_QUALITY` | Параметр качества FFmpeg JPEG: меньшее значение означает лучшее качество и больший файл. |

## 4. Локальные события

| Переменная | Назначение |
|---|---|
| `DVR_EVENT_DB` | Путь к SQLite database событий. |
| `DVR_EVENT_RETENTION_DAYS` | Сколько суток хранить локальные события. |
| `DVR_EVENT_CLEANUP_INTERVAL_MINUTES` | Интервал удаления событий старше retention. |
| `DVR_EVENT_QUERY_MAX_SECONDS` | Максимальная длительность временного диапазона одного event query. |
| `DVR_EVENT_STORE_RAW_PAYLOAD` | Сохранять ли исходный payload ONVIF/Hikvision. Обычно `false`, чтобы не раздувать БД. |
| `ONVIF_EVENTS_ENABLED` | Включить ONVIF PullPoint/event collection. |
| `ONVIF_EVENTS_REQUEST_TIMEOUT_MS` | Timeout одного ONVIF event-запроса. |
| `DVR_HIKVISION_EVENTS_ENABLED` | Включить Hikvision alertStream collector там, где он нужен. |
| `VIDEO_MOTION_ENABLED` | Включить FFmpeg software motion detection. Требует дополнительных ресурсов CPU. |

## 5. Синхронизация событий с архивом

| Переменная | Назначение |
|---|---|
| `DVR_ARCHIVE_EVENT_SYNC_ENABLED` | Включить периодический reconciler событий и локального архива. |
| `DVR_ARCHIVE_EVENT_SYNC_APPLY` | `false` — только отчёт; `true` — удалять события часов, архив которых уже отсутствует. Начинайте с `false`. |
| `DVR_ARCHIVE_EVENT_SYNC_MIN_AGE_MINUTES` | Не проверять слишком свежие часы, чтобы не конфликтовать с активной записью. |
| `DVR_ARCHIVE_EVENT_SYNC_MAX_HOURS_PER_RUN` | Максимальное число camera-hour buckets за один запуск. |
| `DVR_ARCHIVE_EVENT_SYNC_MASTER_TIMEOUT_MS` | Timeout получения camera config с master. При недоступном master reconciler работает fail-closed и ничего не удаляет. |

Подробно: [ARCHIVE_EVENT_LIFECYCLE.md](ARCHIVE_EVENT_LIFECYCLE.md).

## 6. Disk guard

Disk guard имеет приоритет над обычным retention, когда filesystem близка к заполнению.

| Переменная | Назначение |
|---|---|
| `DVR_DISK_MIN_FREE_BYTES` | Минимум свободных байт на filesystem архива до аварийной очистки. |
| `DVR_DISK_MIN_FREE_PERCENT` | Минимум свободного места в процентах до аварийной очистки. Используется более строгий из byte/% порогов. |
| `DVR_DISK_RESUME_FREE_BYTES` | Сколько свободных байт требуется для возобновления записи. |
| `DVR_DISK_RESUME_FREE_PERCENT` | Сколько процентов требуется для возобновления записи. |
| `DVR_DISK_MIN_FREE_INODES_PERCENT` | Минимальный процент свободных inode до остановки/очистки. |
| `DVR_DISK_RESUME_FREE_INODES_PERCENT` | Процент свободных inode для возобновления. |
| `DVR_SYSTEM_MIN_FREE_BYTES` | Минимум свободных байт на system filesystem, где находятся SQLite/logs/tmp. |
| `DVR_SYSTEM_MIN_FREE_PERCENT` | Минимальный процент свободного места на system filesystem. |
| `DVR_SYSTEM_RESUME_FREE_BYTES` | Byte-порог восстановления system filesystem. |
| `DVR_SYSTEM_RESUME_FREE_PERCENT` | Процентный порог восстановления system filesystem. |
| `DVR_DISK_MIN_ARCHIVE_AGE_MINUTES` | Минимальный возраст hour-каталога, который разрешено аварийно удалить. |
| `DVR_DISK_MAX_DELETE_DIRS_PER_RUN` | Ограничение числа удаляемых hour-каталогов за один запуск guard. |
| `DVR_DISK_STALE_TMP_MINUTES` | Возраст временных export/device-archive файлов, после которого их можно удалить. |
| `DVR_DISK_REQUIRE_MOUNTPOINT` | При `true` DVR не стартует, если `DVR_ROOT` не является отдельной mountpoint. Защищает root filesystem при пропавшем диске. |

Подробно: [DISK_PROTECTION.md](DISK_PROTECTION.md).

## 7. Архив на Hikvision/NVR

| Переменная | Назначение |
|---|---|
| `DVR_DEVICE_ARCHIVE_MAX_RANGE_SECONDS` | Максимальный диапазон одной device-archive playback-сессии. |
| `DVR_DEVICE_ARCHIVE_MIN_PLAYBACK_SECONDS` | Минимальная запрашиваемая длительность playback. |
| `DVR_DEVICE_ARCHIVE_SESSION_WINDOW_SECONDS` | Размер переиспользуемого окна сессии. |
| `DVR_DEVICE_ARCHIVE_SESSION_ALIGN_SECONDS` | Шаг выравнивания начала сессии для reuse. |
| `DVR_DEVICE_ARCHIVE_MAX_SESSIONS_PER_DEVICE` | Одновременный лимит playback-сессий на устройство. |
| `DVR_DEVICE_ARCHIVE_PREPARE_WAIT_MS` | Сколько ждать подготовки HLS-сессии. |
| `DVR_DEVICE_ARCHIVE_FIRST_SEGMENT_TIMEOUT_MS` | Timeout появления первого segment. |
| `DVR_DEVICE_ARCHIVE_KEEP_MS` | Сколько держать неиспользуемую сессию до удаления. |
| `DVR_HIKVISION_ARCHIVE_SEARCH_CACHE_MS` | Время кэширования результатов archive search. |
| `DVR_HIKVISION_ARCHIVE_SEARCH_TIMEOUT_MS` | Timeout Hikvision archive search. |
| `DVR_HIKVISION_ARCHIVE_SEARCH_PAGE_SIZE` | Число результатов на одну страницу поиска. |
| `DVR_HIKVISION_ARCHIVE_SEARCH_MAX_PAGES` | Предельное число страниц одного поиска. |
| `DVR_HIKVISION_ARCHIVE_FALLBACK_ON_EMPTY` | Включать ли fallback-поиск, если основной Hikvision search вернул пусто. `0` отключает. |

## 8. Параметры установочных скриптов, а не runtime

Эти переменные читаются shell-скриптами и не обязательны для DVR process:

| Переменная | Назначение |
|---|---|
| `PROJECT_DIR` | Каталог checkout node для deploy/install scripts. |
| `ENV_FILE` | Путь к runtime env. |
| `INSTALL_DISK_GUARD` | Устанавливать/обновлять disk guard. |
| `INSTALL_JOURNAL_LIMITS` | Устанавливать journald limits. |
| `INSTALL_ARCHIVE_EVENT_SYNC` | Устанавливать archive/event sync timer. |
| `REGISTRATION_FILE` | Куда `deploy-node.sh` пишет значения для последующего ввода на master. |
| `NODE_APPLICATION_RUNTIME_USER` | Информационный marker root-only installer. Обычная установка запускает сервис от `newdomofon`. |

## 9. Безопасная проверка без вывода секретов

```bash
ENV_FILE=/etc/newdomofon-video/app.env

for key in \
  DVR_MASTER_URL \
  DVR_NODE_ID \
  DVR_NODE_TOKEN \
  DVR_NODE_MEDIA_SECRET \
  DVR_NODE_PUBLIC_BASE_URL \
  DVR_NODE_INTERNAL_URL; do
  if grep -qE "^${key}=.+" "$ENV_FILE"; then
    echo "$key=SET"
  else
    echo "$key=MISSING"
  fi
done
```

Не используйте `cat /etc/newdomofon-video/app.env` в общих логах, чатах или тикетах.