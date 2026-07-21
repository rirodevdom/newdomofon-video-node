# Несколько дисков для архива video node

Video node поддерживает пул из нескольких уже смонтированных файловых систем.
Каждая камера записывается только на один диск одновременно, но чтение архива,
ranges, export и retention выполняются по всему пулу.

## Основные свойства

- оператор выбирает несколько mountpoints;
- диски не форматируются и не монтируются автоматически;
- камера получает стабильный диск через rendezvous hashing;
- добавление нового диска перераспределяет только часть камер;
- старый архив остаётся доступен на прежнем диске;
- при отказе одного устройства новые recorder-процессы используют оставшиеся;
- disk guard очищает и контролирует каждую filesystem отдельно;
- master получает агрегированный объём и состояние каждого диска через heartbeat.

## Подготовка дисков

Каждый диск нужно заранее:

1. разметить и создать filesystem;
2. добавить в `/etc/fstab` по UUID;
3. смонтировать в постоянный отдельный каталог;
4. проверить автоматическое монтирование после перезагрузки.

Пример:

```text
/srv/newdomofon-archive-a
/srv/newdomofon-archive-b
/srv/newdomofon-archive-c
```

Проверка:

```bash
findmnt /srv/newdomofon-archive-a
findmnt /srv/newdomofon-archive-b
df -hT /srv/newdomofon-archive-a /srv/newdomofon-archive-b
```

Не используйте нестабильные имена устройств `/dev/sdX` в конфигурации
NewDomofon. В `DVR_STORAGE_ROOTS` хранятся постоянные mountpoints, а `/etc/fstab`
должен монтировать их по filesystem UUID.

## Выбор при установке

Интерактивный выбор:

```bash
cd /root/newdomofon-video-node-main
bash scripts/install-node-manual-local-root.sh --select-storage
```

Установщик покажет source device, mountpoint, filesystem, размер и свободное
место. Можно выбрать несколько номеров через запятую.

Неинтерактивно:

```bash
bash scripts/install-node-manual-local-root.sh \
  --storage-root /srv/newdomofon-archive-a \
  --storage-root /srv/newdomofon-archive-b
```

## Настройка уже установленной node

Интерактивно:

```bash
cd /opt/newdomofon-video-node
bash scripts/configure-node-storage-pool.sh --interactive
```

Явно:

```bash
bash /opt/newdomofon-video-node/scripts/configure-node-storage-pool.sh \
  --root /srv/newdomofon-archive-a \
  --root /srv/newdomofon-archive-b
```

Сначала можно выполнить dry-run:

```bash
bash /opt/newdomofon-video-node/scripts/configure-node-storage-pool.sh \
  --root /srv/newdomofon-archive-a \
  --root /srv/newdomofon-archive-b \
  --dry-run
```

Скрипт создаёт backup `app.env`, записывает параметры и перезапускает disk guard
и DVR.

## Конфигурация

```env
DVR_ROOT=/srv/newdomofon-archive-a
DVR_STORAGE_ROOTS=/srv/newdomofon-archive-a,/srv/newdomofon-archive-b
DVR_DISK_REQUIRE_MOUNTPOINT=true
```

`DVR_ROOT` сохраняется как первый/совместимый путь для старых инструментов.
Runtime использует полный список `DVR_STORAGE_ROOTS`.

Пути разделяются запятыми. Запятая внутри имени каталога не поддерживается.

## Распределение камер

Диск выбирается детерминированно по паре:

```text
stream_name + storage root
```

Используется rendezvous hashing. В результате:

- после перезапуска камера возвращается на тот же исправный диск;
- порядок путей в переменной не влияет на назначение;
- при добавлении диска перемещается только часть новых записей;
- архив, уже записанный на другом диске, продолжает находиться при чтении.

Существующие файлы автоматически между дисками не копируются.

## Отказ диска

Если один диск пропал или остался ниже аварийного порога:

1. disk guard очищает старые hour-каталоги только на этом диске;
2. если диск не восстановился, pool получает состояние `degraded`;
3. DVR один раз перезапускается для переназначения камер;
4. исправные диски продолжают запись;
5. отсутствующий диск исключается из новых назначений.

Если не осталось ни одного исправного archive root либо заполнена system
filesystem с SQLite/logs, DVR останавливается полностью.

## Проверка

```bash
systemctl start newdomofon-video-node-disk-guard.service
cat /run/newdomofon-video/node-disk-state.json | jq
curl -fsS http://127.0.0.1:3010/recorders | jq
```

В heartbeat/storage появляются:

```json
{
  "pool_size": 2,
  "available_roots": 2,
  "state": "healthy",
  "roots": [
    {
      "root": "/srv/newdomofon-archive-a",
      "state": "healthy"
    },
    {
      "root": "/srv/newdomofon-archive-b",
      "state": "healthy"
    }
  ]
}
```

## Удаление диска из пула

1. Не размонтируйте диск, пока на него пишут recorder-процессы.
2. Запустите configurator с новым полным списком оставшихся mountpoints.
3. Убедитесь, что DVR перезапустился и камеры пишут на доступные диски.
4. Старый архив на удалённом из списка диске перестанет участвовать в поиске.
5. При необходимости сначала перенесите данные вручную с сохранением структуры
   `<root>/<stream>/<YYYY-MM-DD>/<HH>/...`.
