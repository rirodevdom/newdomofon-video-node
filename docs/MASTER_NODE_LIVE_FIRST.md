# Master/node live-first rollout

This runbook is the safe order for bringing a distributed installation back to a stable state.

## Goal

The master is the only management point. It runs backend, frontend, PostgreSQL and compatibility services. It must not record cameras in strict master/node production.

A video node runs `newdomofon-video-dvr`, receives assigned cameras from the master through `/api/node-agent/config`, records live/archive locally, and serves signed media URLs.

## Phase 1. Stabilize live

Run diagnostics on both servers:

```bash
cd /opt/newdomofon-video
curl --retry 5 --retry-delay 2 --connect-timeout 20 --max-time 120 -fsSL \
  https://raw.githubusercontent.com/rirodevdom/newdomofon-video/main/scripts/diagnose-master-node.sh \
  -o /tmp/diagnose-master-node.sh
sudo bash /tmp/diagnose-master-node.sh
```

Apply the live-first baseline.

On master:

```bash
cd /opt/newdomofon-video
curl --retry 5 --retry-delay 2 --connect-timeout 20 --max-time 120 -fsSL \
  https://raw.githubusercontent.com/rirodevdom/newdomofon-video/main/scripts/apply-live-first-baseline.sh \
  -o /tmp/apply-live-first-baseline.sh
sudo ROLE=master bash /tmp/apply-live-first-baseline.sh
```

On node:

```bash
cd /opt/newdomofon-video
curl --retry 5 --retry-delay 2 --connect-timeout 20 --max-time 120 -fsSL \
  https://raw.githubusercontent.com/rirodevdom/newdomofon-video/main/scripts/apply-live-first-baseline.sh \
  -o /tmp/apply-live-first-baseline.sh
sudo ROLE=node bash /tmp/apply-live-first-baseline.sh
```

This temporarily disables ONVIF events, Hikvision events, Hikvision archive indexing and video-motion on the node. The purpose is to prove that one FFmpeg recorder per camera can keep live running without recorder exits.

Watch the node:

```bash
journalctl -u newdomofon-video-dvr -f -l \
  | grep -E 'Started recorder|Recorder .* exited|No route|Connection timed out|ffmpeg:'
```

The live phase is healthy when recorders do not exit and `No route to host` or `Connection timed out` no longer appears for the camera subnet.

## Phase 2. Enable events one source at a time

After live is stable, enable only one event source at a time.

For Hikvision devices, prefer ISAPI alertStream:

```bash
sudo sed -i -E '/^DVR_HIKVISION_EVENTS_ENABLED=/d' /etc/newdomofon-video/app.env
echo 'DVR_HIKVISION_EVENTS_ENABLED=true' | sudo tee -a /etc/newdomofon-video/app.env >/dev/null
sudo systemctl restart newdomofon-video-dvr.service
```

For ONVIF cameras, enable PullPoint only after confirming the camera really emits motion state changes and not only initialization snapshots:

```bash
sudo sed -i -E '/^(EVENTS_ENABLED|ONVIF_EVENTS_ENABLED)=/d' /etc/newdomofon-video/app.env
cat <<'EOF' | sudo tee -a /etc/newdomofon-video/app.env >/dev/null
EVENTS_ENABLED=true
ONVIF_EVENTS_ENABLED=true
EOF
sudo systemctl restart newdomofon-video-dvr.service
```

Check stored events on the master:

```bash
set -a
. /etc/newdomofon-video/app.env
set +a
psql "$DATABASE_URL" -c "
select stream_name, event_type, event_state, occurred_at, created_at
from camera_events
order by occurred_at desc
limit 50;"
```

## Phase 3. Device archive indexing

Enable Hikvision archive indexing only after live and events are stable:

```bash
sudo sed -i -E '/^DVR_HIKVISION_ARCHIVE_INDEX_ENABLED=/d' /etc/newdomofon-video/app.env
echo 'DVR_HIKVISION_ARCHIVE_INDEX_ENABLED=true' | sudo tee -a /etc/newdomofon-video/app.env >/dev/null
sudo systemctl restart newdomofon-video-dvr.service
```

Keep `DVR_DEVICE_ARCHIVE_MAX_SESSIONS_PER_DEVICE=1` unless the device/NVR is proven to handle more concurrent playback sessions.

## Do not use video-motion as the primary event source

`VIDEO_MOTION_ENABLED=true` is only a fallback for cameras that do not provide ONVIF or Hikvision motion events. It must read local HLS, not RTSP, and should be enabled only for selected streams.
