# Развёртывание video node на Debian 12

Этот документ описывает **отдельный сервер video node**. На нём не запускаются master backend, PostgreSQL master или frontend.

Актуальная схема регистрации:

1. node разворачивается первой;
2. оператор вручную задаёт UUID, agent token и media secret;
3. node создаёт `/root/newdomofon-node-master-registration.env`;
4. те же значения вводятся в форме создания node на master;
5. после успешного heartbeat node становится `online`.

Подробности регистрации: [MANUAL_NODE_BOOTSTRAP.md](MANUAL_NODE_BOOTSTRAP.md).

Справочник `.env`: [ENVIRONMENT.md](ENVIRONMENT.md).

## 1. Требования

```text
Debian 12 x86_64
Node.js 22
FFmpeg
Nginx
rsync, curl, jq, openssl, uuid-runtime
4 CPU cores и 4–8 GB RAM — рекомендуемый минимум
отдельный диск под /var/lib/newdomofon-video/dvr — рекомендуется
Europe/Moscow на master и всех node
```

Открытые порты:

```text
22/tcp    SSH только с административных адресов
3010/tcp  DVR engine только для master/private network
80/443    только если node публикуется через собственный Nginx/TLS
```

## 2. Подготовка Debian

Команды выполняются от `root`:

```bash
apt-get update
apt-get dist-upgrade -y
apt-get install -y \
  git ca-certificates curl openssl jq rsync uuid-runtime \
  nginx ffmpeg sqlite3

timedatectl set-timezone Europe/Moscow
systemctl enable --now systemd-timesyncd

timedatectl status
date '+%Y-%m-%d %H:%M:%S %Z %z'
```

Установка Node.js и остальных prerequisites из репозитория:

```bash
cd /opt/newdomofon-video-node
bash scripts/install-debian12-prereqs.sh
```

## 3. Подготовка archive filesystem

Рекомендуемый путь:

```text
/var/lib/newdomofon-video/dvr
```

Сначала определите правильный диск:

```bash
lsblk -o NAME,SIZE,FSTYPE,UUID,MOUNTPOINTS,MODEL,SERIAL
```

Следующий пример форматирует новый пустой раздел `/dev/sdb1`. Не выполняйте `mkfs`, если на диске есть данные:

```bash
mkfs.ext4 -L NEWDOMOFON_DVR /dev/sdb1
install -d -m 0750 /var/lib/newdomofon-video/dvr

DVR_UUID="$(blkid -s UUID -o value /dev/sdb1)"
test -n "$DVR_UUID"

echo "UUID=${DVR_UUID} /var/lib/newdomofon-video/dvr ext4 defaults,noatime 0 2" \
  >>/etc/fstab

mount -a
findmnt /var/lib/newdomofon-video/dvr
df -hT /var/lib/newdomofon-video/dvr
df -ih /var/lib/newdomofon-video/dvr
```

При обязательном отдельном диске используйте:

```text
DVR_DISK_REQUIRE_MOUNTPOINT=true
```

## 4. Получение проекта

```bash
install -d -m 0755 /opt
git clone \
  https://github.com/rirodevdom/newdomofon-video-node.git \
  /opt/newdomofon-video-node

cd /opt/newdomofon-video-node
git switch main
git pull --ff-only origin main
```

При тестировании feature branch используйте явно зафиксированный commit и не смешивайте его с локальными изменениями.

## 5. Выбор credentials на node

Сгенерируйте значения локально:

```bash
NODE_ID="$(uuidgen)"
NODE_TOKEN="$(openssl rand -hex 32)"
NODE_MEDIA_SECRET="$(openssl rand -hex 32)"
```

Не публикуйте значения в истории тикетов или общих логах.

## 6. Первый deploy

### Интерактивно

```bash
cd /opt/newdomofon-video-node
bash scripts/deploy-node.sh
```

Установщик запросит:

```text
DVR_MASTER_URL
DVR_NODE_ID
DVR_NODE_TOKEN
DVR_NODE_MEDIA_SECRET
DVR_NODE_PUBLIC_BASE_URL
DVR_NODE_INTERNAL_URL
```

Master может быть выключен или ещё не развёрнут.

### Неинтерактивно

Передавайте секреты через защищённую shell session, а после запуска удалите переменные:

```bash
cd /opt/newdomofon-video-node

PROJECT_DIR=/opt/newdomofon-video-node \
ENV_FILE=/etc/newdomofon-video/app.env \
  bash scripts/deploy-node.sh \
    --master-url https://video.example.com \
    --node-id "$NODE_ID" \
    --node-token "$NODE_TOKEN" \
    --media-secret "$NODE_MEDIA_SECRET" \
    --public-url http://10.0.0.31 \
    --internal-url http://10.0.0.31:3010 \
    --non-interactive

unset NODE_ID NODE_TOKEN NODE_MEDIA_SECRET
```

Deploy:

- сохраняет runtime env;
- устанавливает production dependencies с правами для `newdomofon`;
- собирает TypeScript;
- устанавливает systemd unit и Nginx;
- устанавливает disk guard и archive/event sync;
- проверяет локальный `/health`;
- создаёт root-only файл для регистрации на master.

## 7. Проверка до регистрации на master

```bash
systemctl is-active newdomofon-video-dvr.service
curl -fsS http://127.0.0.1:3010/health | jq
journalctl -u newdomofon-video-dvr.service -n 200 --no-pager

stat -c '%A %U:%G %n' \
  /root/newdomofon-node-master-registration.env
```

До появления совпадающей записи на master heartbeat может возвращать `401` или `404`. Локальный DVR при этом должен оставаться `active (running)`.

## 8. Создание записи на master

На node просмотрите root-only файл:

```bash
cat /root/newdomofon-node-master-registration.env
```

На master откройте:

```text
Администрирование → Ноды → Создать node
```

Введите посимвольно:

```text
DVR_MASTER_URL
DVR_NODE_ID
DVR_NODE_TOKEN
DVR_NODE_MEDIA_SECRET
DVR_NODE_PUBLIC_BASE_URL
DVR_NODE_INTERNAL_URL
```

Master не генерирует эти значения. Он сохраняет UUID, SHA-256 хеш agent token и media secret.

## 9. Проверка после регистрации

```bash
sleep 25

journalctl \
  -u newdomofon-video-dvr.service \
  --since '-5 minutes' \
  --no-pager

curl -fsS http://127.0.0.1:3010/recorders | jq
```

В UI master должны обновляться `status=online` и `last_seen_at`.

## 10. Отдельный DNS/TLS для node

Private-only node может работать без собственного TLS, если порт 3010 доступен только master.

Для собственного domain:

```bash
export NODE_DOMAIN=video-node1.example.com

sed -i \
  "s/server_name _;/server_name ${NODE_DOMAIN};/" \
  /etc/nginx/sites-available/newdomofon-video-node.conf

nginx -t
systemctl reload nginx

apt-get install -y certbot python3-certbot-nginx
certbot --nginx -d "$NODE_DOMAIN"
certbot renew --dry-run
```

После изменения URL обновите одинаковые значения на node и в записи master.

## 11. Безопасное обновление

```bash
cd /opt/newdomofon-video-node

STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="/opt/newdomofon-video-migration-backups/node-update-$STAMP"
install -d -m 0750 "$BACKUP"

cp -a /etc/newdomofon-video/app.env "$BACKUP/app.env"
git status --short >"$BACKUP/git-status.txt"
git diff --binary >"$BACKUP/worktree.patch"
git stash push -u -m "before-node-update-$STAMP" || true

git fetch --prune origin
git switch main
git reset --hard origin/main

PROJECT_DIR=/opt/newdomofon-video-node \
ENV_FILE=/etc/newdomofon-video/app.env \
  bash scripts/deploy-node.sh --non-interactive
```

Старый stash не восстанавливайте автоматически.

## 12. Диагностика

```bash
systemctl --no-pager --full status newdomofon-video-dvr.service
journalctl -u newdomofon-video-dvr.service -n 300 --no-pager
curl -fsS http://127.0.0.1:3010/health | jq
curl -fsS http://127.0.0.1:3010/recorders | jq
cat /run/newdomofon-video/node-disk-state.json | jq
```

Безопасная проверка наличия credentials без их вывода описана в [ENVIRONMENT.md](ENVIRONMENT.md).

## 13. Root-only установка из распакованного архива

Для основного production-сценария рекомендуется обычный `deploy-node.sh` и systemd user `newdomofon`.

`install-node-local-root.sh` предназначен для специальной установки из распакованного source tree в `/root`, где сервисы работают от root. Передавайте ему **выбранные оператором** `--node-id`, `--node-token` и `--media-secret`; не используйте старый master-generated bootstrap JSON для новых установок.
