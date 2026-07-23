# Полностью offline-обновление Video Node

Обычный source ZIP и `update-installed-project.sh` не используют Git, но штатный deploy выполняет `npm ci`. Поэтому один source ZIP не гарантирует обновление сервера без доступа к npm registry.

Для изолированных серверов используется специальный **offline bundle**. Он содержит:

- исходники конкретного GitHub commit;
- `package-lock.json` из этого commit;
- полный npm cache для production и build-зависимостей;
- `offline-update.sh`, который принудительно включает `npm_config_offline=true`;
- SHA-256 пакета и внутреннего npm cache;
- manifest с commit, платформой, архитектурой и версиями Node/npm.

## Получение пакета

В GitHub Actions откройте workflow:

```text
Offline node update bundle
```

Запустите `Run workflow` на ветке `main` или скачайте artifact последнего успешного запуска после обновления `main`.

Artifact содержит:

```text
newdomofon-video-node-offline-<commit>.tar.gz
newdomofon-video-node-offline-<commit>.tar.gz.sha256
newdomofon-video-node-offline-<commit>.txt
```

Скачивание выполняется на компьютере с доступом к GitHub. Затем все три файла переносятся на video node через SCP, USB-носитель или внутреннее файловое хранилище.

## Проверка на сервере

```bash
cd /root
sha256sum -c newdomofon-video-node-offline-*.tar.gz.sha256
```

Распаковка:

```bash
tar -xzf newdomofon-video-node-offline-*.tar.gz
cd /root/newdomofon-video-node-offline-*
```

Проверьте commit:

```bash
cat .offline-update/manifest.env
```

## Dry-run

```bash
bash offline-update.sh --dry-run
```

Dry-run не меняет сервис, архив и SQLite. Он проверяет платформу, архитектуру, Node.js, checksum npm cache и показывает rsync-изменения.

## Обновление

```bash
sudo bash offline-update.sh
```

Чтобы намеренно заменить старый Nginx-конфиг текущей версией из пакета:

```bash
sudo bash offline-update.sh --use-archive-nginx
```

По умолчанию production Nginx сохраняется. Исходники, systemd units и runtime-сборка обновляются из пакета; `app.env`, registration file, SQLite событий и видеоархив сохраняются.

## Порядок обновления системы

Сначала обновите все video node и проверьте каждую. Только после этого обновляйте master.

Проверка node:

```bash
systemctl is-active newdomofon-video-dvr.service
curl -fsS http://127.0.0.1:3010/health | jq
curl -fsS http://127.0.0.1:3010/recorders | jq
journalctl -u newdomofon-video-dvr.service -n 100 --no-pager
cat /opt/newdomofon-video-node/.installed-from-extracted-source
```

## Что означает «соответствует GitHub»

Offline bundle фиксирует конкретный `source_commit`. После успешного deploy application source, lockfile, собранный `dist`, production dependencies и systemd units соответствуют этому commit.

Намеренно не заменяются пользовательские и эксплуатационные данные:

- `/etc/newdomofon-video/app.env`;
- node credentials;
- SQLite событий;
- `/var/lib/newdomofon-video/dvr`;
- production Nginx, если не передан `--use-archive-nginx`.

Поэтому сервер функционально приводится к версии указанного commit, но не становится побайтовой копией чистой установки: его идентификаторы, адреса, секреты, архив и события сохраняются.

## Требования

На сервере уже должны быть установлены системные компоненты существующей production-инсталляции:

- Debian 12;
- Node.js не ниже 22.12.0;
- npm;
- FFmpeg;
- Python 3;
- rsync, tar, sha256sum;
- Nginx и systemd.

Сам update не обращается к GitHub, npm registry или другим внешним источникам.
