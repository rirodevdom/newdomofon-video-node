# Ручная регистрация video node на master

Video node можно полностью установить и запустить **до** создания записи на master.

Автоматический pairing не используется. UUID, agent token и media secret выбирает администратор во время развёртывания node. Позже те же значения вручную заносятся в форму master.

Справочник всех параметров: [ENVIRONMENT.md](ENVIRONMENT.md).

## 1. Подготовьте credentials на node

```bash
DVR_NODE_ID="$(uuidgen)"
DVR_NODE_TOKEN="$(openssl rand -hex 32)"
DVR_NODE_MEDIA_SECRET="$(openssl rand -hex 32)"
```

Назначение:

| Значение | Для чего используется |
|---|---|
| `DVR_NODE_ID` | UUID записи node и идентификатор в agent API. |
| `DVR_NODE_TOKEN` | Авторизация heartbeat/config/commands. Master хранит SHA-256 хеш. |
| `DVR_NODE_MEDIA_SECRET` | Подпись внутренних короткоживущих media/event tokens. |

Допустимые символы token и media secret:

```text
A-Z a-z 0-9 . _ ~ -
```

Длина: `16–512` символов.

## 2. Разверните node

Интерактивно:

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

Секреты вводятся без отображения.

Неинтерактивно:

```bash
cd /opt/newdomofon-video-node

PROJECT_DIR=/opt/newdomofon-video-node \
ENV_FILE=/etc/newdomofon-video/app.env \
  bash scripts/deploy-node.sh \
    --master-url https://new-video.domofon-37.ru \
    --node-id "$DVR_NODE_ID" \
    --node-token "$DVR_NODE_TOKEN" \
    --media-secret "$DVR_NODE_MEDIA_SECRET" \
    --public-url http://10.106.1.31 \
    --internal-url http://10.106.1.31:3010 \
    --non-interactive

unset DVR_NODE_ID DVR_NODE_TOKEN DVR_NODE_MEDIA_SECRET
```

Master может быть выключен или ещё не установлен. Deploy проверяет только локальный DVR health.

## 3. Проверьте node до master

```bash
systemctl is-active newdomofon-video-dvr.service
curl -fsS http://127.0.0.1:3010/health | jq
journalctl -u newdomofon-video-dvr.service -n 100 --no-pager
```

До создания совпадающей записи на master heartbeat может получать `401` или `404`. Это временное состояние и не должно останавливать DVR process.

## 4. Файл для регистрации на master

После установки создаётся:

```text
/root/newdomofon-node-master-registration.env
```

Права:

```text
root:root 0600
```

Содержимое:

```text
DVR_MASTER_URL=...
DVR_NODE_ID=...
DVR_NODE_TOKEN=...
DVR_NODE_MEDIA_SECRET=...
DVR_NODE_PUBLIC_BASE_URL=...
DVR_NODE_INTERNAL_URL=...
```

Просмотр разрешён только root:

```bash
cat /root/newdomofon-node-master-registration.env
```

Не отправляйте этот файл в общий чат, тикет или незащищённое хранилище.

## 5. Создайте запись на master

Откройте:

```text
Администрирование → Ноды → Создать node
```

Введите все значения из registration file:

```text
DVR_MASTER_URL
DVR_NODE_ID
DVR_NODE_TOKEN
DVR_NODE_MEDIA_SECRET
DVR_NODE_PUBLIC_BASE_URL
DVR_NODE_INTERNAL_URL
```

Также задайте название и включите «Активна».

`DVR_MASTER_URL` предварительно заполняется текущим origin master, но может быть изменён для точного совпадения с `app.env` node.

Master:

- не генерирует UUID;
- не генерирует agent token;
- не генерирует media secret;
- использует `DVR_NODE_ID` как `dvr_servers.id`;
- хранит только SHA-256 хеш `DVR_NODE_TOKEN`;
- хранит `DVR_NODE_MEDIA_SECRET` для внутренних tokens;
- сохраняет введённый `DVR_MASTER_URL` в metadata записи.

## 6. Проверьте heartbeat

```bash
sleep 25

journalctl \
  -u newdomofon-video-dvr.service \
  --since '-5 minutes' \
  --no-pager

curl -fsS http://127.0.0.1:3010/recorders | jq
```

После успешного heartbeat master обновляет `last_seen_at`, storage/version/capabilities и показывает node как `online`.

## 7. Рабочий `.env`

```text
/etc/newdomofon-video/app.env
```

Обычная установка:

```bash
chown root:newdomofon /etc/newdomofon-video/app.env
chmod 0640 /etc/newdomofon-video/app.env
```

Обязательные значения подключения:

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

Что означает каждая строка и какие есть дополнительные настройки: [ENVIRONMENT.md](ENVIRONMENT.md).

## 8. Ручная смена credentials

Master больше не генерирует credentials при ротации.

Правильный порядок:

1. подготовьте новые token и media secret;
2. внесите их в `/etc/newdomofon-video/app.env` на node;
3. в master выберите «Действия → Задать новые credentials»;
4. введите те же значения;
5. перезапустите DVR:

```bash
systemctl restart newdomofon-video-dvr.service
```

Значения должны совпадать посимвольно.

## 9. Существующая node

При обновлении уже подключённой node **не меняйте** её ID/token/media secret. `deploy-node.sh --non-interactive` читает текущие значения из `app.env` и создаёт registration file из них.

## 10. Root-only installer

`scripts/install-node-local-root.sh` предназначен для специального сценария из распакованного source tree в `/root`, где service работает от root.

Для новых установок передавайте операторские значения через:

```text
--node-id
--node-token
--media-secret
```

Старый bootstrap JSON, сформированный master, больше не является частью основной схемы.