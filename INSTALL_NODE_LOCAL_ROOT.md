# Установка NewDomofon Video Node одним локальным root-скриптом

Эта инструкция предназначена для Debian 12, когда архив `newdomofon-video-node`
уже скачан на другом компьютере и распакован в каталог внутри `/root`.

Используется только один запускаемый файл:

```text
scripts/install-node-local-root.sh
```

Он не выполняет `git clone`, `git fetch`, `git pull` и другие Git-команды.
Он не вызывает `deploy-node.sh`, `install-node-disk-guard.sh`,
`install-archive-event-sync.sh` или другие установщики.

## Пользователи

Установщик не выполняет `useradd` или `groupadd` и не создаёт Linux-пользователя
`newdomofon`.

Все компоненты NewDomofon Video Node запускаются как `root`:

```text
newdomofon-video-dvr.service
newdomofon-video-node-disk-guard.service
newdomofon-video-archive-event-sync.service
```

Nginx сохраняет стандартного Debian worker-пользователя `www-data`. Этот аккаунт
создаётся пакетом Nginx, а не самим установщиком.

Node не устанавливает и не использует PostgreSQL.

---

# 1. Подготовьте node на master

На master откройте:

```text
Администрирование → Nodes → Добавить node
```

Сохраните:

```text
node_id
agent_token
media_secret
```

Можно создать файл:

```bash
cat >/root/video-node1-bootstrap.json <<'JSON'
{
  "node_id": "ВСТАВЬТЕ_NODE_ID",
  "agent_token": "ВСТАВЬТЕ_AGENT_TOKEN",
  "media_secret": "ВСТАВЬТЕ_MEDIA_SECRET"
}
JSON

chmod 600 /root/video-node1-bootstrap.json
```

Монолитный установщик автоматически найдёт файл с `bootstrap` в имени либо
использует путь, переданный через `--bootstrap-json`.

---

# 2. Подготовьте DVR-диск

Установщик **не форматирует диски автоматически**, потому что это может уничтожить
данные.

Проверьте диски:

```bash
lsblk -o NAME,SIZE,FSTYPE,LABEL,UUID,MOUNTPOINTS,MODEL,SERIAL
```

Если используется отдельный уже подготовленный раздел:

```bash
DVR_PARTITION=/dev/sdb1
DVR_ROOT=/var/lib/newdomofon-video/dvr

install -d -m 0750 "$DVR_ROOT"

DVR_UUID="$(blkid -s UUID -o value "$DVR_PARTITION")"
test -n "$DVR_UUID"

grep -qF "UUID=$DVR_UUID " /etc/fstab || \
  echo "UUID=$DVR_UUID $DVR_ROOT ext4 defaults,noatime 0 2" >>/etc/fstab

mount -a
findmnt "$DVR_ROOT"
df -hT "$DVR_ROOT"
df -ih "$DVR_ROOT"
```

Если раздел новый и пустой, его форматирование выполняется отдельно и осознанно:

```bash
mkfs.ext4 -L NEWDOMOFON_DVR /dev/sdb1
```

Эта команда уничтожает существующие данные на разделе.

Для обязательного отдельного mount запускайте installer с:

```text
--require-mountpoint
```

Если архив намеренно хранится на системном диске:

```text
--allow-root-filesystem
```

---

# 3. Распакуйте архив node

Пример:

```text
/root/newdomofon-video-node-main/
```

Проверка:

```bash
SOURCE_DIR=/root/newdomofon-video-node-main

test -f "$SOURCE_DIR/dvr-engine/package.json"
test -f "$SOURCE_DIR/dvr-engine/package-lock.json"
test -f "$SOURCE_DIR/scripts/install-node-local-root.sh"
test -f "$SOURCE_DIR/scripts/node-disk-guard.sh"

echo "Source is ready: $SOURCE_DIR"
```

Имя папки не имеет значения.

---

# 4. Запустите один файл

```bash
cd /root/newdomofon-video-node-main

chmod 700 scripts/install-node-local-root.sh

bash scripts/install-node-local-root.sh
```

Сценарий запросит недостающие параметры:

```text
Master URL
node_id
agent_token
media_secret
private node IP/hostname
```

Если `app.env` уже существует или найден bootstrap JSON, соответствующие вопросы
не задаются.

## Рекомендуемый неинтерактивный запуск

Пример для текущей сети:

```bash
bash /root/newdomofon-video-node-main/scripts/install-node-local-root.sh \
  --source-dir /root/newdomofon-video-node-main \
  --master-url https://new-video.domofon-37.ru \
  --master-ip 10.106.1.30 \
  --bootstrap-json /root/video-node1-bootstrap.json \
  --node-host 10.106.1.31 \
  --dvr-root /var/lib/newdomofon-video/dvr \
  --require-mountpoint \
  --no-tls
```

Здесь:

```text
master       https://new-video.domofon-37.ru
master IP    10.106.1.30
node IP      10.106.1.31
internal URL http://10.106.1.31:3010
public URL   http://10.106.1.31
```

## Без bootstrap JSON

```bash
bash /root/newdomofon-video-node-main/scripts/install-node-local-root.sh \
  --source-dir /root/newdomofon-video-node-main \
  --master-url https://new-video.domofon-37.ru \
  --master-ip 10.106.1.30 \
  --node-id 'UUID_FROM_MASTER' \
  --node-token 'AGENT_TOKEN_FROM_MASTER' \
  --media-secret 'MEDIA_SECRET_FROM_MASTER' \
  --node-host 10.106.1.31 \
  --dvr-root /var/lib/newdomofon-video/dvr \
  --require-mountpoint \
  --no-tls
```

Не добавляйте секреты в общедоступные журналы и сообщения.

## Node с отдельным DNS и TLS

```bash
bash /root/newdomofon-video-node-main/scripts/install-node-local-root.sh \
  --source-dir /root/newdomofon-video-node-main \
  --master-url https://new-video.domofon-37.ru \
  --master-ip 10.106.1.30 \
  --bootstrap-json /root/video-node1-bootstrap.json \
  --node-host 10.106.1.31 \
  --node-domain video-node1.example.ru \
  --email admin@example.ru \
  --dvr-root /var/lib/newdomofon-video/dvr \
  --require-mountpoint \
  --tls
```

Для private node отдельный DNS/TLS не обязателен.

---

# Что самостоятельно делает один файл

Сценарий:

1. проверяет запуск от `root`;
2. автоматически находит распакованный проект внутри `/root`;
3. не выполняет ни одной Git-команды;
4. не создаёт собственного Linux-пользователя;
5. устанавливает системные пакеты;
6. устанавливает Node.js 22.12+, если он отсутствует;
7. устанавливает `Europe/Moscow`;
8. запускает Nginx;
9. сохраняет старый `app.env`;
10. выполняет online backup SQLite events;
11. читает credentials из существующего env, bootstrap JSON, параметров или prompt;
12. проверяет DVR filesystem и обязательный mount;
13. проверяет свободное место системного диска;
14. сохраняет предыдущую production-папку;
15. копирует source из `/root` в `/opt/newdomofon-video-node` через `rsync`;
16. исключает `.git`, `.github`, `node_modules` и старый `dist`;
17. создаёт `/etc/newdomofon-video/app.env` с `root:root 0600`;
18. собирает DVR engine;
19. устанавливает DVR systemd unit с `User=root`;
20. устанавливает disk guard service/timer с `User=root`;
21. устанавливает archive/event sync service/timer с `User=root`;
22. устанавливает локальные runtime scripts;
23. устанавливает Nginx-конфигурацию;
24. запускает disk guard до DVR;
25. останавливает установку, если disk guard обнаружил критическое состояние;
26. запускает DVR и ждёт `/health`;
27. проверяет доступность master;
28. запускает archive/event sync в dry-run или apply режиме;
29. настраивает firewall, если UFW/firewalld уже активен;
30. при необходимости выпускает node TLS certificate;
31. проверяет runtime-пользователей;
32. сохраняет credentials, URLs, mount и backup-информацию;
33. выводит итоговый отчёт в терминал.

---

# Повторный запуск

По умолчанию повторный запуск сохраняет из существующего `app.env`:

```text
DVR_MASTER_URL
DVR_NODE_ID
DVR_NODE_TOKEN
DVR_NODE_MEDIA_SECRET
DVR_NODE_INTERNAL_URL
DVR_NODE_PUBLIC_BASE_URL
DVR_ROOT
DVR_DISK_REQUIRE_MOUNTPOINT
DVR_ARCHIVE_EVENT_SYNC_APPLY
```

Старая production-папка сохраняется как:

```text
/opt/newdomofon-video-node.before-local-root-YYYYMMDD-HHMMSS
```

Backup:

```text
/opt/newdomofon-video-migration-backups/local-root-node-YYYYMMDD-HHMMSS
```

Сценарий не удаляет DVR archive.

---

# Данные после установки

Текстовый отчёт:

```bash
cat /root/newdomofon-node-access.txt
```

JSON:

```bash
jq . /root/newdomofon-node-access.json
```

Файлы имеют права `root:root 0600` и содержат:

```text
MASTER_URL
MASTER_ACCESS_IP
NODE_ID
NODE_AGENT_TOKEN
NODE_MEDIA_SECRET
NODE_INTERNAL_URL
NODE_PUBLIC_BASE_URL
NODE_HEALTH_LOCAL
NODE_HEALTH_PUBLIC

DVR_ROOT
DVR_MOUNT_REQUIRED
DVR_MOUNT_SOURCE
DVR_MOUNT_FSTYPE
DVR_TOTAL_BYTES
DVR_AVAILABLE_BYTES
EVENT_DATABASE
ARCHIVE_EVENT_SYNC_APPLY

SOURCE_DIRECTORY
SOURCE_FINGERPRINT
PROJECT_DIRECTORY
PREVIOUS_PROJECT_BACKUP
INSTALL_LOG
INSTALL_BACKUP

SYSTEM_USERS_CREATED_BY_INSTALLER=none
NODE_APPLICATION_RUNTIME_USER=root
```

---

# Проверка

```bash
systemctl is-active newdomofon-video-dvr.service
systemctl is-active newdomofon-video-node-disk-guard.timer
systemctl is-active newdomofon-video-archive-event-sync.timer
systemctl is-active nginx.service
```

Health:

```bash
curl -fsS http://127.0.0.1:3010/health | jq .
curl -fsS http://127.0.0.1/health | jq .
```

Recorder:

```bash
curl -fsS http://127.0.0.1:3010/recorders | jq .
```

Runtime users:

```bash
for service in \
  newdomofon-video-dvr.service \
  newdomofon-video-node-disk-guard.service \
  newdomofon-video-archive-event-sync.service; do
  printf '%-52s user=%s\n' \
    "$service" \
    "$(systemctl show -p User --value "$service")"
done
```

Ожидается:

```text
user=root
```

Timers:

```bash
systemctl list-timers '*newdomofon*' --no-pager
```

Disk guard:

```bash
cat /run/newdomofon-video/node-disk-state.json | jq .
```

Events:

```bash
ls -lh /var/lib/newdomofon-video/events/
cat /var/lib/newdomofon-video/events/archive-event-sync-state.json | jq .
```

---

# После назначения устройства

На master:

```text
Устройства → нужное устройство → Редактировать
```

Выберите установленную node и место хранения архива `node`.

Проверка recorder:

```bash
curl -fsS http://127.0.0.1:3010/recorders \
  | jq '.items[] | {stream_name,recording,restarts,last_error}'
```

Проверка файлов:

```bash
find /var/lib/newdomofon-video/dvr \
  -maxdepth 4 \
  -type f \
  -printf '%TY-%Tm-%Td %TH:%TM:%TS %s %p\n' \
  | sort \
  | tail -50
```

---

# Интернет-зависимости

Исходники проекта не загружаются с GitHub.

На чистом сервере интернет всё ещё может понадобиться для:

- Debian APT repositories;
- NodeSource, если Node.js 22 отсутствует;
- npm registry;
- Let's Encrypt, если нужен TLS.

Для полностью автономной установки нужно подготовить APT/npm cache.

---

# Журнал ошибок

Последний журнал:

```bash
LOG="$(ls -t /root/newdomofon-node-local-root-*.log | head -1)"
echo "$LOG"
tail -300 "$LOG"
```

DVR:

```bash
systemctl --no-pager --full status newdomofon-video-dvr.service
journalctl -u newdomofon-video-dvr.service -n 300 --no-pager
```

Disk guard:

```bash
journalctl -u newdomofon-video-node-disk-guard.service -n 300 --no-pager
```

Archive/event sync:

```bash
journalctl -u newdomofon-video-archive-event-sync.service -n 300 --no-pager
```
