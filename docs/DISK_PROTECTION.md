# Защита video node от заполнения диска

Обычная retention-очистка удаляет архив только после истечения срока хранения камеры. Этого недостаточно, если bitrate, число камер, exports или retention превышают ёмкость диска.

`newdomofon-video-node-disk-guard.timer` запускает независимую root-owned проверку, которая работает даже при неисправном DVR process.

Полный справочник переменных: [ENVIRONMENT.md](ENVIRONMENT.md#6-disk-guard).

## Пороги по умолчанию

- аварийная очистка начинается ниже `max(10 GiB, 10%)` свободного места на filesystem `DVR_ROOT`;
- запись возобновляется только после `max(15 GiB, 15%)`;
- DVR останавливается ниже `5%` свободных inode;
- system filesystem с SQLite/logs/tmp должна иметь минимум `max(2 GiB, 5%)`;
- текущий час и archive-hour каталоги моложе 60 минут не удаляются;
- stale export/device-archive temporary files старше 60 минут удаляются;
- если безопасно восстановить запас не удалось, `newdomofon-video-dvr.service` останавливается;
- после достижения resume thresholds timer автоматически запускает DVR.

Guard не удаляет:

- `events.sqlite3`;
- `app.env`;
- camera config;
- текущий recording hour;
- live playlist.

## Установка

Обычно guard устанавливает основной deploy:

```bash
cd /opt/newdomofon-video-node
PROJECT_DIR=/opt/newdomofon-video-node \
ENV_FILE=/etc/newdomofon-video/app.env \
  bash scripts/deploy-node.sh --non-interactive
```

Отдельная установка:

```bash
cd /opt/newdomofon-video-node
bash scripts/install-node-disk-guard.sh
```

Отключить изменение journald limits, если на сервере уже есть более строгая политика:

```bash
INSTALL_JOURNAL_LIMITS=0 \
  bash scripts/install-node-disk-guard.sh
```

## Переменные

```env
# Аварийная очистка ниже max(bytes, percent).
DVR_DISK_MIN_FREE_BYTES=10737418240
DVR_DISK_MIN_FREE_PERCENT=10

# Возобновление записи после max(bytes, percent).
DVR_DISK_RESUME_FREE_BYTES=16106127360
DVR_DISK_RESUME_FREE_PERCENT=15

# Inode thresholds.
DVR_DISK_MIN_FREE_INODES_PERCENT=5
DVR_DISK_RESUME_FREE_INODES_PERCENT=8

# Пороги system filesystem с SQLite/logs/tmp.
DVR_SYSTEM_MIN_FREE_BYTES=2147483648
DVR_SYSTEM_MIN_FREE_PERCENT=5
DVR_SYSTEM_RESUME_FREE_BYTES=4294967296
DVR_SYSTEM_RESUME_FREE_PERCENT=10

# Ограничения аварийного удаления.
DVR_DISK_MIN_ARCHIVE_AGE_MINUTES=60
DVR_DISK_MAX_DELETE_DIRS_PER_RUN=500
DVR_DISK_STALE_TMP_MINUTES=60

# true запрещает запись на root filesystem при пропавшем archive mount.
DVR_DISK_REQUIRE_MOUNTPOINT=true
```

Изменения вступают в силу при следующем запуске oneshot guard. Для немедленной проверки:

```bash
systemctl start newdomofon-video-node-disk-guard.service
```

## Проверка mountpoint

```bash
findmnt /var/lib/newdomofon-video/dvr
df -hT /var/lib/newdomofon-video/dvr
df -ih /var/lib/newdomofon-video/dvr
```

Если `DVR_DISK_REQUIRE_MOUNTPOINT=true`, а диск не смонтирован, DVR должен оставаться остановленным. Не меняйте значение на `false`, пока не убедились, что запись на system disk допустима.

## Статус и журналы

```bash
systemctl status newdomofon-video-node-disk-guard.timer --no-pager
systemctl status newdomofon-video-node-disk-guard.service --no-pager
journalctl -u newdomofon-video-node-disk-guard.service -n 200 --no-pager
cat /run/newdomofon-video/node-disk-state.json | jq
```

Paused marker:

```text
/run/newdomofon-video/node-disk-paused
```

Не удаляйте marker вручную до устранения причины.

## Безопасная проверка

Не заполняйте production filesystem тестовыми файлами. Для проверки используйте временный threshold чуть выше текущего свободного места, запустите oneshot, проверьте pause, затем восстановите production значения и запустите oneshot ещё раз.

```bash
df -h /var/lib/newdomofon-video/dvr
systemctl start newdomofon-video-node-disk-guard.service
cat /run/newdomofon-video/node-disk-state.json | jq
```

## Удаление guard

```bash
systemctl disable --now newdomofon-video-node-disk-guard.timer
rm -f /etc/systemd/system/newdomofon-video-node-disk-guard.timer
rm -f /etc/systemd/system/newdomofon-video-node-disk-guard.service
rm -f /usr/local/sbin/newdomofon-node-disk-guard
rm -f /etc/systemd/journald.conf.d/99-newdomofon-video.conf
systemctl daemon-reload
systemctl try-restart systemd-journald.service || true
```

Удаление guard на production не рекомендуется.