#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="${PROJECT_DIR:-/opt/newdomofon-video}"
EVENTS_RETENTION_FALLBACK_DAYS="${EVENTS_RETENTION_FALLBACK_DAYS:-7}"
EVENTS_RETENTION_BATCH="${EVENTS_RETENTION_BATCH:-50000}"

set +u
for envf in /etc/newdomofon-video/app.env "$PROJECT_DIR/backend/.env" "$PROJECT_DIR/.env"; do
  [ -f "$envf" ] && set -a && . "$envf" && set +a
done
set -u

if [ -z "${DATABASE_URL:-}" ]; then
  echo "DATABASE_URL is required" >&2
  exit 1
fi

case "$EVENTS_RETENTION_FALLBACK_DAYS" in
  ''|*[!0-9]*) echo "EVENTS_RETENTION_FALLBACK_DAYS must be integer" >&2; exit 1 ;;
esac
case "$EVENTS_RETENTION_BATCH" in
  ''|*[!0-9]*) echo "EVENTS_RETENTION_BATCH must be integer" >&2; exit 1 ;;
esac

psql "$DATABASE_URL" -v ON_ERROR_STOP=1 \
  -v fallback_days="$EVENTS_RETENTION_FALLBACK_DAYS" \
  -v batch="$EVENTS_RETENTION_BATCH" <<'SQL'
\echo 'events-retention: before'
SELECT
  count(*) AS total_events,
  min(occurred_at) AS first_event,
  max(occurred_at) AS last_event
FROM public.camera_events;

WITH event_scope AS (
  SELECT
    e.id,
    e.stream_name,
    e.occurred_at,
    GREATEST(1, COALESCE(c_by_id.retention_days, c_by_stream.retention_days, :'fallback_days'::int)) AS keep_days
  FROM public.camera_events e
  LEFT JOIN public.cameras c_by_id ON c_by_id.id = e.camera_id
  LEFT JOIN public.cameras c_by_stream
    ON c_by_id.id IS NULL
   AND c_by_stream.stream_name = e.stream_name
),
doomed AS (
  SELECT id
  FROM event_scope
  WHERE occurred_at < now() - make_interval(days => keep_days)
  ORDER BY occurred_at
  LIMIT :'batch'::int
),
deleted AS (
  DELETE FROM public.camera_events e
  USING doomed d
  WHERE e.id = d.id
  RETURNING e.stream_name
)
SELECT stream_name, count(*) AS deleted
FROM deleted
GROUP BY stream_name
ORDER BY stream_name;

VACUUM (ANALYZE) public.camera_events;

\echo 'events-retention: old events still exceeding per-camera retention'
WITH event_scope AS (
  SELECT
    e.stream_name,
    e.occurred_at,
    GREATEST(1, COALESCE(c_by_id.retention_days, c_by_stream.retention_days, :'fallback_days'::int)) AS keep_days
  FROM public.camera_events e
  LEFT JOIN public.cameras c_by_id ON c_by_id.id = e.camera_id
  LEFT JOIN public.cameras c_by_stream
    ON c_by_id.id IS NULL
   AND c_by_stream.stream_name = e.stream_name
)
SELECT stream_name, keep_days, count(*) AS old_events, min(occurred_at) AS oldest_event
FROM event_scope
WHERE occurred_at < now() - make_interval(days => keep_days)
GROUP BY stream_name, keep_days
ORDER BY old_events DESC, stream_name
LIMIT 30;
SQL
