#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="${PROJECT_DIR:-/opt/newdomofon-video-node}"
INSTALL_JOURNAL_LIMITS="${INSTALL_JOURNAL_LIMITS:-1}"

install -d -m 0755 /usr/local/sbin
install -d -m 0755 /etc/systemd/system
install -d -m 0755 /run/newdomofon-video

install -m 0755 \
  "$PROJECT_DIR/scripts/node-disk-guard.sh" \
  /usr/local/sbin/newdomofon-node-disk-guard

install -m 0755 \
  "$PROJECT_DIR/scripts/node-system-disk-check.sh" \
  /usr/local/sbin/newdomofon-node-system-disk-check

install -m 0644 \
  "$PROJECT_DIR/deploy/systemd/newdomofon-video-node-disk-guard.service" \
  /etc/systemd/system/newdomofon-video-node-disk-guard.service

install -m 0644 \
  "$PROJECT_DIR/deploy/systemd/newdomofon-video-node-disk-guard.timer" \
  /etc/systemd/system/newdomofon-video-node-disk-guard.timer

if [[ "$INSTALL_JOURNAL_LIMITS" =~ ^(1|true|yes|on)$ ]]; then
  install -d -m 0755 /etc/systemd/journald.conf.d
  install -m 0644 \
    "$PROJECT_DIR/deploy/journald/99-newdomofon-video.conf" \
    /etc/systemd/journald.conf.d/99-newdomofon-video.conf
  systemctl try-restart systemd-journald.service || true
fi

systemctl daemon-reload
systemctl enable --now newdomofon-video-node-disk-guard.timer
# A critical result intentionally makes the oneshot non-zero; the timer remains active.
systemctl start newdomofon-video-node-disk-guard.service || true

systemctl --no-pager --full status newdomofon-video-node-disk-guard.timer || true
cat /run/newdomofon-video/node-disk-state.json 2>/dev/null || true
