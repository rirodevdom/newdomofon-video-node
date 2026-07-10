# Disk pressure protection

The regular DVR cleanup removes archive days only after each camera retention period expires. That policy alone cannot prevent a full filesystem when bitrate, camera count, exports, or the configured retention exceed capacity.

`newdomofon-video-node-disk-guard.timer` adds an independent root-owned safety loop that continues to work even when the DVR process is unhealthy.

## Default watermarks

- emergency cleanup starts below `10 GiB` or `10%` free on `DVR_ROOT`, whichever is larger;
- normal recording resumes above `15 GiB` and `15%` free;
- DVR is stopped below `5%` free inodes;
- the filesystem containing the event SQLite database must keep at least `2 GiB` or `5%` free;
- completed archive hour directories younger than 60 minutes and the current UTC hour are never deleted;
- stale export/device-archive temporary directories older than 60 minutes are removed;
- if cleanup cannot restore the start watermark, `newdomofon-video-dvr.service` is stopped;
- after the resume watermark is restored, the timer starts the DVR automatically.

The guard never deletes `events.sqlite3`, camera configuration, secrets, or the current recording hour.

## Installation

```bash
cd /opt/newdomofon-video-node
bash scripts/install-node-disk-guard.sh
```

The installer also applies bounded journald storage. Disable that part only when the host already has a stricter central journald policy:

```bash
INSTALL_JOURNAL_LIMITS=0 bash scripts/install-node-disk-guard.sh
```

## Recommended production environment

Add to `/etc/newdomofon-video/app.env`:

```text
DVR_DISK_MIN_FREE_BYTES=10737418240
DVR_DISK_MIN_FREE_PERCENT=10
DVR_DISK_RESUME_FREE_BYTES=16106127360
DVR_DISK_RESUME_FREE_PERCENT=15
DVR_DISK_MIN_FREE_INODES_PERCENT=5
DVR_DISK_RESUME_FREE_INODES_PERCENT=8
DVR_SYSTEM_MIN_FREE_BYTES=2147483648
DVR_SYSTEM_MIN_FREE_PERCENT=5
DVR_SYSTEM_RESUME_FREE_BYTES=4294967296
DVR_SYSTEM_RESUME_FREE_PERCENT=10
DVR_DISK_MIN_ARCHIVE_AGE_MINUTES=60
DVR_DISK_MAX_DELETE_DIRS_PER_RUN=500
DVR_DISK_STALE_TMP_MINUTES=60
```

When `/var/lib/newdomofon-video/dvr` must be a dedicated mount, also set:

```text
DVR_DISK_REQUIRE_MOUNTPOINT=true
```

This prevents recording into the root filesystem after an archive disk fails to mount.

## Status and logs

```bash
systemctl status newdomofon-video-node-disk-guard.timer --no-pager
systemctl status newdomofon-video-node-disk-guard.service --no-pager
journalctl -u newdomofon-video-node-disk-guard.service -n 200 --no-pager
cat /run/newdomofon-video/node-disk-state.json | jq .
```

A paused node has:

```text
/run/newdomofon-video/node-disk-paused
```

## Safe verification

Do not fill a production filesystem with test data. Temporarily set a start watermark slightly above the current free space and a resume watermark below it, run the oneshot service, verify that the DVR pauses, then restore the real values and run the service again.

```bash
df -h /var/lib/newdomofon-video/dvr
systemctl start newdomofon-video-node-disk-guard.service
cat /run/newdomofon-video/node-disk-state.json | jq .
```

## Removal

```bash
systemctl disable --now newdomofon-video-node-disk-guard.timer
rm -f /etc/systemd/system/newdomofon-video-node-disk-guard.timer
rm -f /etc/systemd/system/newdomofon-video-node-disk-guard.service
rm -f /usr/local/sbin/newdomofon-node-disk-guard
rm -f /etc/systemd/journald.conf.d/99-newdomofon-video.conf
systemctl daemon-reload
systemctl try-restart systemd-journald.service || true
```
