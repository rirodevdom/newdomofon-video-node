#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="${PROJECT_DIR:-/opt/newdomofon-video-node}"
ENV_FILE="${ENV_FILE:-/etc/newdomofon-video/app.env}"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run as root" >&2
  exit 1
fi

if ! id newdomofon >/dev/null 2>&1; then
  echo "User newdomofon does not exist" >&2
  exit 1
fi

# The systemd worker runs as newdomofon and must be able to traverse the
# configuration directory and read app.env without exposing it to other users.
install -d -o root -g newdomofon -m 0750 "$(dirname "$ENV_FILE")"
if [[ -f "$ENV_FILE" ]]; then
  chown root:newdomofon "$ENV_FILE"
  chmod 0640 "$ENV_FILE"
fi

install -d -m 0755 /usr/local/lib/newdomofon-video
install -m 0755 \
  "$PROJECT_DIR/scripts/reconcile-archive-events.mjs" \
  /usr/local/lib/newdomofon-video/reconcile-archive-events.mjs
install -m 0755 \
  "$PROJECT_DIR/scripts/run-archive-event-sync.sh" \
  /usr/local/lib/newdomofon-video/run-archive-event-sync.sh

install -m 0644 \
  "$PROJECT_DIR/deploy/systemd/newdomofon-video-archive-event-sync.service" \
  /etc/systemd/system/newdomofon-video-archive-event-sync.service

install -m 0644 \
  "$PROJECT_DIR/deploy/systemd/newdomofon-video-archive-event-sync.timer" \
  /etc/systemd/system/newdomofon-video-archive-event-sync.timer

install -d -o newdomofon -g newdomofon -m 0750 \
  /var/lib/newdomofon-video/events

systemctl daemon-reload
systemctl enable --now newdomofon-video-archive-event-sync.timer

# The launcher defaults to dry-run. Actual deletion is enabled only when
# DVR_ARCHIVE_EVENT_SYNC_APPLY=true is explicitly present in app.env.
if ! systemctl start newdomofon-video-archive-event-sync.service; then
  echo "Archive/event initial reconciliation failed; timer will retry." >&2
  systemctl --no-pager --full status newdomofon-video-archive-event-sync.service || true
fi

systemctl --no-pager --full status newdomofon-video-archive-event-sync.timer || true
cat /var/lib/newdomofon-video/events/archive-event-sync-state.json 2>/dev/null || true
