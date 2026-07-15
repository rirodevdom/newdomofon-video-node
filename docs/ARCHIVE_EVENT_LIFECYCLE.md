# Синхронизация событий с локальным архивом

События хранятся в SQLite node независимо от media files. После удаления archive-hour каталога event marker может остаться на timeline, хотя воспроизведение уже невозможно.

`newdomofon-video-archive-event-sync.timer` каждые пять минут запускает reconciler.

Полный справочник параметров: [ENVIRONMENT.md](ENVIRONMENT.md#5-синхронизация-событий-с-архивом).

## Что делает reconciler

- получает актуальную camera configuration с master;
- обрабатывает только камеры, где `archive_storage != device`;
- не трогает свежие часы, чтобы не конфликтовать с recorder;
- проверяет наличие завершённых `.ts`/`.m4s` segment;
- удаляет SQLite events только для завершённых часов, локальный архив которых отсутствует;
- не меняет события Hikvision/NVR device archive cameras;
- использует SQLite WAL, busy timeout и passive checkpoint;
- пишет machine-readable state рядом с event database.

Если master недоступен или конфигурация не получена, reconciler работает **fail-closed** и ничего не удаляет.

## Production-параметры

```env
# Включить timer/reconciler.
DVR_ARCHIVE_EVENT_SYNC_ENABLED=true

# false = только отчёт, true = удаление orphan events.
DVR_ARCHIVE_EVENT_SYNC_APPLY=false

# Не проверять часы моложе двух часов.
DVR_ARCHIVE_EVENT_SYNC_MIN_AGE_MINUTES=120

# Максимум camera-hour buckets за один запуск.
DVR_ARCHIVE_EVENT_SYNC_MAX_HOURS_PER_RUN=1000

# Timeout получения camera config с master.
DVR_ARCHIVE_EVENT_SYNC_MASTER_TIMEOUT_MS=15000
```

`DVR_ARCHIVE_EVENT_SYNC_APPLY=false` — обязательный безопасный режим первого запуска.

## Dry-run

```bash
sudo -u newdomofon bash -c '
set -a
. /etc/newdomofon-video/app.env
set +a
exec /usr/bin/node /usr/local/lib/newdomofon-video/reconcile-archive-events.mjs --dry-run
'
```

Для одного stream:

```bash
sudo -u newdomofon bash -c '
set -a
. /etc/newdomofon-video/app.env
set +a
exec /usr/bin/node /usr/local/lib/newdomofon-video/reconcile-archive-events.mjs \
  --dry-run --stream entrance_main
'
```

Перед apply проверьте:

- `archive_hours_checked`;
- `missing_archive_hours`;
- `candidate_events`;
- `examples`.

## Включение автоматического apply

Измените:

```env
DVR_ARCHIVE_EVENT_SYNC_APPLY=true
```

Запустите один контролируемый проход:

```bash
systemctl start newdomofon-video-archive-event-sync.service
cat /var/lib/newdomofon-video/events/archive-event-sync-state.json | jq
```

Следующие timer runs будут использовать apply mode. Для возврата в report-only установите `false`.

## Разовый manual apply

Без изменения режима timer:

```bash
sudo -u newdomofon bash -c '
set -a
. /etc/newdomofon-video/app.env
set +a
exec /usr/bin/node /usr/local/lib/newdomofon-video/reconcile-archive-events.mjs --apply
'
```

Операция идемпотентна: пока matching media segments существуют, повторный запуск не удаляет соответствующие events.

## Статус

```bash
systemctl status newdomofon-video-archive-event-sync.timer --no-pager
systemctl status newdomofon-video-archive-event-sync.service --no-pager
journalctl -u newdomofon-video-archive-event-sync.service -n 100 --no-pager
cat /var/lib/newdomofon-video/events/archive-event-sync-state.json | jq
```

Ключевые поля:

| Поле | Значение |
|---|---|
| `archive_hours_checked` | Проверенные завершённые local archive hours. |
| `missing_archive_hours` | Часы без playable local segments. |
| `candidate_events` | Сколько events было бы удалено в dry-run. |
| `deleted_events` | Сколько events реально удалено в apply. |
| `examples` | Примеры найденных несоответствий. |

## Границы безопасности

Reconciler работает с точностью до часа, потому что emergency disk cleanup удаляет hour-каталоги. Если в проверяемом часу остаётся хотя бы один completed playable segment, events этого часа сохраняются.

Не включайте apply, пока не проверены dry-run результаты для всех типов камер.