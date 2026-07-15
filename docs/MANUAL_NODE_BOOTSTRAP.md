# Ручное подключение video node к master

Video node можно установить и запустить, даже если master в этот момент выключен или недоступен по сети.

Автоматический pairing не используется. Все значения подключения вводятся вручную во время установки node.

## 1. Заранее создайте node на master

Пока master доступен, откройте:

```text
Администрирование → Ноды → Создать node вручную
```

Сохраните четыре значения:

```text
DVR_MASTER_URL
DVR_NODE_ID
DVR_NODE_TOKEN
DVR_NODE_MEDIA_SECRET
```

Также заранее определите адреса самой node:

```text
DVR_NODE_PUBLIC_BASE_URL
DVR_NODE_INTERNAL_URL
```

После сохранения этих значений master можно выключить. Для установки и первого запуска node он не требуется.

## 2. Интерактивная установка

На node:

```bash
cd /opt/newdomofon-video-node
sudo bash scripts/deploy-node.sh
```

Установщик запросит:

```text
Master URL
Node ID created on master
Node agent token created on master
Node media secret created on master
Public node URL
Internal node URL
```

Секреты вводятся без отображения на экране.

## 3. Неинтерактивный запуск

```bash
cd /opt/newdomofon-video-node

sudo bash scripts/deploy-node.sh \
  --master-url https://new-video.domofon-37.ru \
  --node-id UUID_FROM_MASTER \
  --node-token AGENT_TOKEN_FROM_MASTER \
  --media-secret MEDIA_SECRET_FROM_MASTER \
  --public-url http://10.106.1.31 \
  --internal-url http://10.106.1.31:3010 \
  --non-interactive
```

Не вставляйте реальные секреты в общие журналы, тикеты или сообщения. Для production безопаснее использовать интерактивный ввод либо заранее подготовленный root-only `app.env`.

## 4. Что происходит при выключенном master

Node успешно запускает:

- DVR HTTP service;
- nginx;
- disk guard;
- локальную SQLite событий;
- локальное архивное хранилище.

Попытки heartbeat и загрузки конфигурации камер будут завершаться ошибкой соединения, но процесс DVR не остановится. После появления master node автоматически:

1. отправит heartbeat;
2. получит назначенные устройства и камеры;
3. запустит соответствующие FFmpeg recorder-процессы;
4. начнёт получать команды master.

Дополнительная ручная привязка или pairing token не нужны.

## 5. Проверка node без master

```bash
systemctl is-active newdomofon-video-dvr.service
curl -fsS http://127.0.0.1:3010/health
journalctl -u newdomofon-video-dvr.service -n 100 --no-pager
```

Health должен отвечать локально, даже если в журнале временно присутствуют ошибки соединения с master.

## 6. Проверка после запуска master

```bash
journalctl -u newdomofon-video-dvr.service -f --no-pager
```

После восстановления связи должны появиться успешные heartbeat/config-запросы, а на master node должна перейти в состояние `online`.

Проверьте recorder-процессы:

```bash
curl -fsS http://127.0.0.1:3010/recorders
```

## 7. Где хранятся значения

```text
/etc/newdomofon-video/app.env
```

Рекомендуемые права:

```bash
chown root:newdomofon /etc/newdomofon-video/app.env
chmod 0640 /etc/newdomofon-video/app.env
```

В файле должны присутствовать:

```text
DVR_ENGINE_ROLE=node
DVR_MASTER_URL=...
DVR_NODE_ID=...
DVR_NODE_TOKEN=...
DVR_NODE_MEDIA_SECRET=...
DVR_NODE_PUBLIC_BASE_URL=...
DVR_NODE_INTERNAL_URL=...
DVR_REQUIRE_MEDIA_TOKEN=true
```
