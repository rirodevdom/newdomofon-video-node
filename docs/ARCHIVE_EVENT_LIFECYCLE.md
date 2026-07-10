# Archive and event lifecycle synchronization

Camera events are stored in the node SQLite database independently from video archive files. Without synchronization, deleting an archive hour can leave event markers at times where playback is no longer possible.

`newdomofon-video-archive-event-sync.timer` runs every five minutes and starts a one-shot reconciler.

The reconciler:

- obtains the current assigned camera configuration from master;
- processes only cameras whose `archive_storage` is not `device`;
- ignores recent hours to avoid racing the active recorder;
- checks whether the local archive hour contains a completed `.ts` or `.m4s` segment;
- removes SQLite events only for completed hours whose local archive is absent;
- never modifies events for Hikvision/NVR device archive cameras;
- uses SQLite WAL with a busy timeout and a passive checkpoint;
- writes machine-readable state to `archive-event-sync-state.json` beside the event database.

Default settings:

```env
DVR_ARCHIVE_EVENT_SYNC_ENABLED=true
DVR_ARCHIVE_EVENT_SYNC_MIN_AGE_MINUTES=120
DVR_ARCHIVE_EVENT_SYNC_MAX_HOURS_PER_RUN=1000
DVR_ARCHIVE_EVENT_SYNC_MASTER_TIMEOUT_MS=15000
```

## Dry-run

Dry-run does not delete anything:

```bash
sudo -u newdomofon \
  /usr/bin/node /usr/local/lib/newdomofon-video/reconcile-archive-events.mjs \
  --dry-run
```

For one camera:

```bash
sudo -u newdomofon \
  /usr/bin/node /usr/local/lib/newdomofon-video/reconcile-archive-events.mjs \
  --dry-run --stream OnvifP
```

Inspect `candidate_events`, `missing_archive_hours` and `examples` before applying.

## Apply

```bash
sudo -u newdomofon \
  /usr/bin/node /usr/local/lib/newdomofon-video/reconcile-archive-events.mjs \
  --apply
```

The operation is idempotent. Repeating it does not remove additional events while matching archive segments remain.

## Status

```bash
systemctl status newdomofon-video-archive-event-sync.timer --no-pager
systemctl status newdomofon-video-archive-event-sync.service --no-pager
journalctl -u newdomofon-video-archive-event-sync.service -n 100 --no-pager
cat /var/lib/newdomofon-video/events/archive-event-sync-state.json | jq .
```

Important fields:

- `archive_hours_checked` — completed local archive hours inspected;
- `missing_archive_hours` — hours without playable local segments;
- `candidate_events` — events that would be deleted in dry-run;
- `deleted_events` — events actually deleted in apply mode.

## Safety boundaries

The synchronizer deliberately works at hour granularity because emergency archive cleanup deletes hour directories. If at least one completed media segment remains in an hour, all event markers for that hour are retained.

The synchronizer fails closed when master configuration cannot be obtained: no events are deleted because the worker cannot safely distinguish local archive cameras from device archive cameras.
