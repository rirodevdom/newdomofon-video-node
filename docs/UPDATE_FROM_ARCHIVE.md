# Обновление Node из распакованного архива

Этот способ предназначен для серверов без доступа к репозиторию. На сервере не требуется установленный Git и не выполняются `clone`, `fetch`, `pull` или другие Git-команды.

Источник обновления — только содержимое ZIP/TAR, заранее скачанного на другом компьютере и распакованного на сервере.

> При совместном обновлении системы сначала обновляются все video node, затем master.

## 1. Скачать и распаковать архив

Архив скачивается вне сервера. После передачи файла на node:

```bash
cd /root
unzip newdomofon-video-node-main.zip
cd /root/newdomofon-video-node-main
```

Имя распакованной папки может отличаться. Запускайте updater из корня распакованного node-проекта.

## 2. Предварительная проверка

```bash
bash update-installed-project.sh --dry-run
```

Dry-run показывает, какие файлы будут синхронизированы в:

```text
/opt/newdomofon-video-node
```

Сервис DVR, архив и SQLite при этом не изменяются. Скрипт также вычисляет SHA-256 отпечаток содержимого архива.

## 3. Обновление

```bash
sudo bash update-installed-project.sh
```

Скрипт автоматически:

- использует исходники из текущей распакованной папки;
- не обращается к репозиторию и не требует Git;
- сохраняет `/etc/newdomofon-video/app.env`;
- сохраняет `/root/newdomofon-node-master-registration.env`;
- создаёт backup SQLite событий и проверяет её целостность;
- сохраняет действующий Nginx и systemd unit;
- сохраняет текущие исходники установленного проекта;
- синхронизирует новую версию без `node_modules`, `dist` и env-файлов;
- запускает `deploy-node.sh --non-interactive` с существующими credentials;
- не трогает `/var/lib/newdomofon-video/dvr` и записанный архив;
- проверяет DVR health и состояние сервиса;
- записывает SHA-256 архива в `source-info.txt` и `.installed-from-extracted-source`.

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
- Не используйте на production-сервере Git-команды для установки или обновления.
- Не удаляйте backup до проверки health, recorders, heartbeat, live и archive.
- При ошибке SQLite автоматически не откатывается: это защищает события, появившиеся после начала обновления.
