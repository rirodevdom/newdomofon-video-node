# Ручное подключение video node к master

Video node можно полностью установить и запустить до создания записи на master.

Автоматический pairing не используется. UUID, agent token и media secret выбирает администратор во время развёртывания node. Позже эти же значения вручную заносятся в форму создания node на master.

## 1. Сначала разверните node

Подготовьте значения:

```bash
uuidgen
openssl rand -hex 32
openssl rand -hex 32
```

Первый результат используйте как `DVR_NODE_ID`, второй как `DVR_NODE_TOKEN`, третий как `DVR_NODE_MEDIA_SECRET`.

Допустимы только:

```text
A-Z a-z 0-9 . _ ~ -
```

Token и media secret должны иметь длину от 16 до 512 символов.

Интерактивный запуск:

```bash
cd /opt/newdomofon-video-node
sudo bash scripts/deploy-node.sh
```

Установщик запросит:

```text
DVR_MASTER_URL to use when master becomes available
Choose DVR_NODE_ID (UUID)
Choose DVR_NODE_TOKEN
Choose DVR_NODE_MEDIA_SECRET
DVR_NODE_PUBLIC_BASE_URL
DVR_NODE_INTERNAL_URL
```

Секреты вводятся без отображения на экране.

Неинтерактивный запуск:

```bash
cd /opt/newdomofon-video-node

sudo bash scripts/deploy-node.sh \
  --master-url https://new-video.domofon-37.ru \
  --node-id 11111111-2222-4333-8444-555555555555 \
  --node-token NODE_TOKEN_CHOSEN_BY_OPERATOR_32 \
  --media-secret MEDIA_SECRET_CHOSEN_BY_OPERATOR_32 \
  --public-url http://10.106.1.31 \
  --internal-url http://10.106.1.31:3010 \
  --non-interactive
```

Не передавайте реальные секреты в тикетах, общих журналах и сообщениях. Для production безопаснее интерактивный ввод.

## 2. Файл для регистрации на master

После установки node создаётся root-only файл:

```text
/root/newdomofon-node-master-registration.env
```

Права:

```text
root:root 0600
```

Он содержит:

```text
DVR_MASTER_URL=...
DVR_NODE_ID=...
DVR_NODE_TOKEN=...
DVR_NODE_MEDIA_SECRET=...
DVR_NODE_PUBLIC_BASE_URL=...
DVR_NODE_INTERNAL_URL=...
```

Посмотреть его может только root:

```bash
sudo cat /root/newdomofon-node-master-registration.env
```

## 3. Затем создайте запись на master

Когда master будет доступен, откройте:

```text
Администрирование → Ноды → Создать node
```

Введите все значения из файла регистрации node:

```text
DVR_MASTER_URL
DVR_NODE_ID
DVR_NODE_TOKEN
DVR_NODE_MEDIA_SECRET
DVR_NODE_PUBLIC_BASE_URL
DVR_NODE_INTERNAL_URL
```

Также задайте понятное название node и включите переключатель «Активна».

Поле `DVR_MASTER_URL` предварительно заполняется текущим адресом master, но его можно изменить так, чтобы оно посимвольно совпадало со значением в `app.env` node.

Master:

- не генерирует UUID;
- не генерирует agent token;
- не генерирует media secret;
- сохраняет введённый UUID как `dvr_servers.id`;
- хранит только SHA-256 хеш agent token;
- хранит media secret для выпуска внутренних media tokens;
- сохраняет введённый `DVR_MASTER_URL` в metadata записи node.

После создания записи node при следующем heartbeat станет `online`.

## 4. Что происходит до создания записи на master

Node успешно запускает:

- DVR HTTP service;
- nginx;
- disk guard;
- локальную SQLite событий;
- локальное архивное хранилище.

Пока на master нет записи с совпадающими `DVR_NODE_ID` и `DVR_NODE_TOKEN`, heartbeat может получать `401` или `404`. Это временное состояние и не должно останавливать DVR-процесс.

После создания совпадающей записи node автоматически:

1. отправит heartbeat;
2. получит назначенные устройства и камеры;
3. запустит соответствующие FFmpeg recorder-процессы;
4. начнёт получать команды master.

## 5. Проверка node до master

```bash
systemctl is-active newdomofon-video-dvr.service
curl -fsS http://127.0.0.1:3010/health
journalctl -u newdomofon-video-dvr.service -n 100 --no-pager
```

Health должен отвечать локально независимо от наличия записи на master.

## 6. Проверка после создания записи на master

```bash
journalctl -u newdomofon-video-dvr.service -f --no-pager
```

На master node должна перейти в состояние `online` после успешного heartbeat.

Проверьте recorder-процессы:

```bash
curl -fsS http://127.0.0.1:3010/recorders
```

## 7. Где хранятся значения

Рабочий env node:

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

## 8. Ручная смена credentials

При смене token или media secret:

1. задайте новые значения в `/etc/newdomofon-video/app.env` на node;
2. внесите те же значения через действие «Задать новые credentials» на master;
3. перезапустите DVR:

```bash
systemctl restart newdomofon-video-dvr.service
```

Значения на обеих сторонах должны совпадать полностью.
