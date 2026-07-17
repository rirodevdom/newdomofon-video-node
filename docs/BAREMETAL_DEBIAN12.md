# Развёртывание video node на Debian 12 без Git

Этот документ описывает отдельный сервер video node. На нём не запускаются master backend, PostgreSQL master или frontend.

Production-сервер не должен иметь доступ к репозиторию. Установка выполняется только из ZIP/TAR, заранее скачанного на другом компьютере и переданного на сервер.

## 1. Актуальная схема регистрации

1. Node разворачивается первой.
2. Оператор вручную задаёт UUID, agent token и media secret.
3. Node создаёт `/root/newdomofon-node-master-registration.env`.
4. Те же значения вводятся в форме создания node на master.
5. После успешного heartbeat node становится `online`.

Подробности: [MANUAL_NODE_BOOTSTRAP.md](MANUAL_NODE_BOOTSTRAP.md).

## 2. Требования

```text
Debian 12 x86_64
4 CPU cores и 4–8 GB RAM
Node.js 22
FFmpeg
Nginx
rsync, curl, jq, openssl, uuid-runtime
отдельный диск под /var/lib/newdomofon-video/dvr — рекомендуется
Europe/Moscow на master и всех node
```

Открытые порты:

```text
22/tcp    SSH только с административных адресов
3010/tcp  DVR engine только для master/private network
80/443    только если node публикуется через собственный Nginx
```

## 3. Подготовка Debian

Команды выполняются от `root`:

```bash
apt-get update
apt-get dist-upgrade -y
apt-get install -y \
  ca-certificates curl openssl jq rsync unzip tar \
  python3 uuid-runtime nginx ffmpeg sqlite3

timedatectl set-timezone Europe/Moscow
systemctl enable --now systemd-timesyncd
```

Git устанавливать не требуется.

## 4. Передать и распаковать архив

Скачайте ZIP node-проекта вне сервера, затем передайте его в `/root`.

```bash
cd /root
unzip newdomofon-video-node-main.zip
cd /root/newdomofon-video-node-main
```

Не распаковывайте архив внутрь `/opt/newdomofon-video-node`.

## 5. Запустить локальный установщик

Интерактивно:

```bash
bash scripts/install-node-manual-local-root.sh
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

Можно использовать штатный deploy напрямую:

```bash
PROJECT_DIR=/opt/newdomofon-video-node \
ENV_FILE=/etc/newdomofon-video/app.env \
  bash scripts/deploy-node.sh \
    --master-url http://10.106.1.30 \
    --node-id 11111111-2222-4333-8444-555555555555 \
    --node-token NODE_TOKEN_CHOSEN_BY_OPERATOR_32 \
    --media-secret MEDIA_SECRET_CHOSEN_BY_OPERATOR_32 \
    --public-url http://10.106.1.31 \
    --internal-url http://10.106.1.31:3010 \
    --non-interactive
```

Оба варианта используют только локальные файлы распакованного архива и не обращаются к репозиторию.

## 6. Runtime-конфигурация

Рабочий файл:

```text
/etc/newdomofon-video/app.env
```

Root-only файл значений для master:

```text
/root/newdomofon-node-master-registration.env
```

Справочник: [ENVIRONMENT.md](ENVIRONMENT.md).

## 7. Проверка

```bash
systemctl is-active newdomofon-video-dvr.service
curl -fsS http://127.0.0.1:3010/health | jq
curl -fsS http://127.0.0.1:3010/recorders | jq
journalctl -u newdomofon-video-dvr.service -n 200 --no-pager
```

Проверьте права registration-файла:

```bash
stat -c '%A %U:%G %n' \
  /root/newdomofon-node-master-registration.env
```

## 8. Диск архива

Рекомендуется монтировать отдельный filesystem в:

```text
/var/lib/newdomofon-video/dvr
```

Если mountpoint обязателен:

```text
DVR_DISK_REQUIRE_MOUNTPOINT=true
```

Проверка:

```bash
cat /run/newdomofon-video/node-disk-state.json | jq
systemctl status newdomofon-video-node-disk-guard.timer --no-pager
```

## 9. Обновление

Сначала обновляются все video node, затем master.

```bash
cd /root/newdomofon-video-node-main
bash update-installed-project.sh --dry-run
sudo bash update-installed-project.sh
```

Подробно: [UPDATE_FROM_ARCHIVE.md](UPDATE_FROM_ARCHIVE.md).

## 10. Production-пути

```text
/opt/newdomofon-video-node/                    установленная копия проекта
/etc/newdomofon-video/app.env                  runtime config и secrets
/root/newdomofon-node-master-registration.env  значения для формы master
/var/lib/newdomofon-video/dvr/                 live и архив
/var/lib/newdomofon-video/events/events.sqlite3
/var/log/newdomofon-video/
/etc/nginx/sites-available/newdomofon-video-node.conf
/etc/systemd/system/newdomofon-video-dvr.service
```

## 11. Безопасность

- не используйте Git-команды на production-сервере;
- не публикуйте `app.env` и registration env;
- разрешайте node `3010` только master/private network;
- не публикуйте `DVR_NODE_TOKEN` или `DVR_NODE_MEDIA_SECRET`;
- не запускайте `npm audit fix` автоматически на production.
