#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="${PROJECT_DIR:-/opt/newdomofon-video-node}"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run as root" >&2
  exit 1
fi

install -d -m 0755 /usr/local/lib/newdomofon-video
install -m 0755 \
  "$PROJECT_DIR/scripts/reconcile-archive-events.mjs" \
  /usr/local/lib/newdomofon-video/reconcile-archive-events.mjs

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
systemctl start newdomofon-video-archive-event-sync.service

systemctl --no-pager --full status newdomofon-video-archive-event-sync.timer || true
cat /var/lib/newdomofon-video/events/archive-event-sync-state.json 2>/dev/null || true
