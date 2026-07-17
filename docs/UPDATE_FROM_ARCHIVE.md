# Обновление Node из распакованного архива

Используйте этот способ, когда ZIP/TAR node-проекта скачивается из GitHub вручную и распаковывается непосредственно на сервере.

> При совместном обновлении системы сначала обновляются все video node, затем master.

## 1. Скачать и распаковать архив

Пример для GitHub ZIP:

```bash
cd /root
unzip newdomofon-video-node-main.zip
cd /root/newdomofon-video-node-main
```

Имя распакованной папки может отличаться. Главное — запускать файл из корня распакованного node-проекта.

## 2. Предварительная проверка

```bash
bash update-installed-project.sh --dry-run
```

Dry-run показывает, какие файлы будут синхронизированы в:

```text
/opt/newdomofon-video-node
```

Сервис DVR, архив и SQLite при этом не изменяются.

## 3. Обновление

```bash
sudo bash update-installed-project.sh
```

Скрипт автоматически:

- использует исходники из текущей распакованной папки;
- сохраняет `/etc/newdomofon-video/app.env`;
- сохраняет `/root/newdomofon-node-master-registration.env`;
- создаёт backup SQLite событий и проверяет её целостность;
- сохраняет действующий Nginx и systemd unit;
- сохраняет текущие исходники установленного проекта;
- синхронизирует новую версию без `.git`, `node_modules`, `dist` и env-файлов;
- запускает `deploy-node.sh --non-interactive` с существующими credentials;
- не трогает `/var/lib/newdomofon-video/dvr` и записанный архив;
- проверяет DVR health и состояние сервиса.

Backup и полный журнал создаются в:

```text
/opt/newdomofon-video-migration-backups/node-archive-update-ДАТА-ВРЕМЯ/
```

## 4. Проверка

```bash
curl -fsS http://127.0.0.1:3010/health | jq
curl -fsS http://127.0.0.1:3010/recorders | jq
systemctl is-active newdomofon-video-dvr.service
journalctl -u newdomofon-video-dvr.service -n 100 --no-pager
```

## Production Nginx

По умолчанию действующий Nginx сохраняется.

Только для намеренной замены конфигурации версией из архива:

```bash
sudo bash update-installed-project.sh --use-archive-nginx
```

## Важные ограничения

- Не распаковывайте архив внутрь `/opt/newdomofon-video-node`.
- Не запускайте updater из самого установленного каталога.
- Не удаляйте backup до проверки health, recorders, heartbeat, live и archive.
- При ошибке SQLite автоматически не откатывается: это защищает события, появившиеся после начала обновления.
