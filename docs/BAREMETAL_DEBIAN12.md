# Debian 12 bare-metal deployment

## 1. Подготовка сервера

```bash
sudo bash scripts/install-debian12-baremetal.sh
```

Скрипт устанавливает:

```txt
Node.js 22
PostgreSQL
nginx
FFmpeg
nftables
build tools
rsync/jq/openssl/git/unzip
```

## 2. Размещение проекта

Рекомендуемый путь:

```txt
/opt/newdomofon-video
```

```bash
sudo mkdir -p /opt/newdomofon-video
sudo chown -R "$USER:$USER" /opt/newdomofon-video
```

## 3. Первый деплой

```bash
cd /opt/newdomofon-video
sudo PROJECT_DIR=/opt/newdomofon-video bash scripts/deploy-debian12-baremetal.sh
```

Что делает deploy:

```txt
1. создаёт /etc/newdomofon-video/app.env;
2. генерирует JWT_SECRET, POSTGRES_PASSWORD, ADMIN_PASSWORD;
3. создаёт PostgreSQL роль newdomofon;
4. создаёт БД newdomofon_video;
5. ставит npm-зависимости через npm ci;
6. собирает backend, dvr-engine и frontend;
7. применяет миграции;
8. создаёт admin-пользователя;
9. копирует frontend/dist в /var/www/newdomofon-video;
10. ставит systemd units;
11. ставит nginx site;
12. запускает backend и dvr services.
```

## 4. Конфигурация

Основной runtime env:

```txt
/etc/newdomofon-video/app.env
```

После изменений в env:

```bash
sudo systemctl restart newdomofon-video-backend
sudo systemctl restart newdomofon-video-dvr
```

## 5. systemd services

```txt
newdomofon-video-backend.service
newdomofon-video-dvr.service
newdomofon-video-srs.service optional
```

Команды:

```bash
sudo systemctl status newdomofon-video-backend
sudo systemctl status newdomofon-video-dvr
sudo journalctl -u newdomofon-video-backend -f
sudo journalctl -u newdomofon-video-dvr -f
```

## 6. nginx

Конфиг:

```txt
/etc/nginx/sites-available/newdomofon-video.conf
```

Проверка:

```bash
sudo nginx -t
sudo systemctl reload nginx
```

Frontend directory:

```txt
/var/www/newdomofon-video
```

## 7. Firewall

Пример nftables:

```txt
deploy/nftables/newdomofon-video.nft
```

Минимально наружу нужны:

```txt
22/tcp
80/tcp
443/tcp
```

SRS/WebRTC порты открывать только если реально используешь SRS:

```txt
1935/tcp RTMP
1985/tcp SRS API
8088/tcp SRS HTTP
8000/udp WebRTC
```

Применение примера:

```bash
sudo cp deploy/nftables/newdomofon-video.nft /etc/nftables.conf
sudo nft -c -f /etc/nftables.conf
sudo systemctl reload nftables
```

## 8. Backup

```bash
sudo bash scripts/backup-postgres.sh
```

Файлы:

```txt
/var/backups/newdomofon-video/newdomofon_video-YYYYMMDD-HHMMSS.sql.gz
```

## 9. Диагностика

```bash
bash scripts/doctor-baremetal.sh
```

Проверяются:

```txt
Node.js
npm
FFmpeg
PostgreSQL service
nginx service
backend service
dvr service
backend /api/health
dvr /health
frontend через nginx
```

## 10. Отдельный диск под архив

Лучший вариант — смонтировать диск прямо в:

```txt
/var/lib/newdomofon-video/dvr
```

Пример:

```bash
sudo systemctl stop newdomofon-video-dvr
sudo rsync -a /var/lib/newdomofon-video/dvr/ /mnt/new-disk/dvr/
sudo mount /dev/sdX1 /var/lib/newdomofon-video/dvr
sudo chown -R newdomofon:newdomofon /var/lib/newdomofon-video/dvr
sudo systemctl start newdomofon-video-dvr
```

## 11. Обновление

```bash
cd /opt/newdomofon-video
sudo PROJECT_DIR=/opt/newdomofon-video bash scripts/update-baremetal.sh
```

## 12. Удаление

Осторожно: команды ниже не удаляют PostgreSQL package, но останавливают сервисы проекта.

```bash
sudo systemctl disable --now newdomofon-video-backend newdomofon-video-dvr
sudo rm -f /etc/systemd/system/newdomofon-video-backend.service
sudo rm -f /etc/systemd/system/newdomofon-video-dvr.service
sudo rm -f /etc/nginx/sites-enabled/newdomofon-video.conf
sudo systemctl daemon-reload
sudo systemctl reload nginx
```

## Если deploy завис на `Building backend`

Скрипт на этом этапе выполняет `npm ci` в каталоге `backend`. На слабом сервере или при проблемах с доступом к `registry.npmjs.org` это может выглядеть как зависание.

В исправленной версии deploy-скрипт:

- проверяет доступность npm registry до сборки;
- пишет подробные логи в `/var/log/newdomofon-video/build-*.log`;
- запускает `npm ci` с `--foreground-scripts`, чтобы были видны postinstall/build scripts;
- ограничивает `npm ci` таймаутом 45 минут, а `npm run build` — 30 минут;
- показывает понятную ошибку вместо бесконечного ожидания.

Ручная диагностика:

```bash
cd /opt/newdomofon-video
sudo PROJECT_DIR=/opt/newdomofon-video bash scripts/build-debug.sh backend
```

Проверка сети до npm registry:

```bash
curl -I https://registry.npmjs.org/
npm ping --registry=https://registry.npmjs.org/ --loglevel=info
```

## Fix: npm ci uses non-public registry URLs

If deploy logs contain `packages.applied-caas-gateway...` or another internal registry inside `npm http cache`, run:

```bash
cd /opt/newdomofon-video
sudo PROJECT_DIR=/opt/newdomofon-video bash scripts/fix-npm-locks.sh
sudo PROJECT_DIR=/opt/newdomofon-video bash scripts/deploy-debian12-baremetal.sh
```

The deploy script also performs this sanitation automatically before `npm ci`.
