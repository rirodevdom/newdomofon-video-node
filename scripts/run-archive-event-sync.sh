#!/usr/bin/env bash
set -Eeuo pipefail

MODE="--dry-run"
case "${DVR_ARCHIVE_EVENT_SYNC_APPLY:-false}" in
  1|true|TRUE|yes|YES|on|ON)
    MODE="--apply"
    ;;
esac

exec /usr/bin/node \
  /usr/local/lib/newdomofon-video/reconcile-archive-events.mjs \
  "$MODE"
