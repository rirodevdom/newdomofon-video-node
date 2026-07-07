# Security checklist

## Обязательное перед production

- Поменять `JWT_SECRET`, `POSTGRES_PASSWORD`, `DATABASE_URL` и `ADMIN_PASSWORD` в `/etc/newdomofon-video/app.env`.
- Не использовать дефолтные значения из `.env.example`.
- Выставить `CORS_ORIGIN` на реальный домен, например `https://video.example.com`.
- Не публиковать `dvr-engine` наружу. Он должен слушать локальный порт `127.0.0.1:3010` за backend/nginx.
- Не публиковать `/var/lib/newdomofon-video/dvr` как обычную static-директорию без token-check.
- Ограничить доступ к RTSP URL: там часто лежат логины и пароли камер.
- Использовать HTTPS перед frontend/nginx.
- Включить firewall/nftables: наружу нужны только 80/443 и, при необходимости, SRS ports.
- Делать backup PostgreSQL и контролировать свободное место на диске архива.

## Уже включено в bare-metal проект

- Backend и DVR запускаются от системного пользователя `newdomofon`.
- systemd units используют `NoNewPrivileges`, `ProtectSystem`, `ProtectHome`, `PrivateTmp`.
- `JWT_SECRET` и `ADMIN_PASSWORD` валидируются при `NODE_ENV=production`.
- Playback token хранится в БД только в виде SHA-256 hash.
- Playback token имеет короткий TTL.
- Media endpoints выставляют `cache-control: no-store`.
- Express `x-powered-by` отключён.
- Helmet включён.
- Rate limit включён на backend.
- `MAX_EXPORT_SECONDS` ограничивает размер MP4 export.
- nginx проксирует только `/api/*` и отдаёт frontend static.

## Что нужно добавить на следующем этапе

- Отдельный login rate limit с блокировкой brute force по login/IP.
- Audit событий просмотра архива/live/export.
- Шифрование или external secret storage для RTSP URL.
- mTLS или private network между несколькими DVR nodes.
- Автоматизированный мониторинг свободного места на `DVR_ROOT`.
