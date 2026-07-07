#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="${PROJECT_DIR:-/opt/newdomofon-video}"

# v137 safety: archive-aligned deletion is disabled by default because file
# mtimes are not reliable archive timestamps after copy, restore or repair.
if [[ "${EVENTS_ARCHIVE_ALIGN_ENABLE:-0}" != "1" ]]; then
  echo "archive-align: disabled by v137 safety guard; set EVENTS_ARCHIVE_ALIGN_ENABLE=1 only for a controlled manual run"
  exit 0
fi

set -a
[ -f /etc/newdomofon-video/app.env ] && . /etc/newdomofon-video/app.env
[ -f "$PROJECT_DIR/backend/.env" ] && . "$PROJECT_DIR/backend/.env"
set +a

DVR_ROOT="${DVR_ROOT:-/var/lib/newdomofon-video/dvr}"
EVENTS_KEEP_DAYS="${EVENTS_KEEP_DAYS:-7}"
APPLY="${APPLY:-1}"

if [ ! -d "$DVR_ROOT" ]; then
  echo "archive-align: DVR_ROOT not found: $DVR_ROOT"
  exit 0
fi

if [ -n "${DATABASE_URL:-}" ]; then
  PSQL=(psql "$DATABASE_URL")
else
  export PGPASSWORD="${POSTGRES_PASSWORD:-${PGPASSWORD:-}}"
  PSQL=(
    psql
    -h "${POSTGRES_HOST:-127.0.0.1}"
    -p "${POSTGRES_PORT:-5432}"
    -U "${POSTGRES_USER:-newdomofon}"
    -d "${POSTGRES_DB:-newdomofon_video}"
  )
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

CUTOFFS="$TMP/archive-cutoffs.tsv"

find "$DVR_ROOT" -mindepth 2 -type f -name '*.ts' -printf '%P\t%T@\n' \
  | awk -F '\t' '
      NF >= 2 {
        split($1, a, "/");
        stream = a[1];
        epoch = $2 + 0;
        if (stream != "" && (!(stream in min) || epoch < min[stream])) {
          min[stream] = epoch;
        }
      }
      END {
        for (stream in min) {
          printf "%s\t%.6f\n", stream, min[stream];
        }
      }
    ' > "$CUTOFFS"

if [ ! -s "$CUTOFFS" ]; then
  echo "archive-align: no .ts files found under $DVR_ROOT; nothing to align"
  exit 0
fi

FALLBACK_CUTOFF="$(date -u -d "$EVENTS_KEEP_DAYS days ago" '+%Y-%m-%dT%H:%M:%SZ')"

echo "archive-align: dvr_root=$DVR_ROOT"
echo "archive-align: streams_with_archive=$(wc -l < "$CUTOFFS")"
echo "archive-align: fallback_cutoff=$FALLBACK_CUTOFF"
echo "archive-align: apply=$APPLY"

if [ "$APPLY" = "0" ]; then
  {
    cat <<'SQL_HEAD'
CREATE TEMP TABLE _archive_cutoffs (
  stream_name text NOT NULL,
  cutoff_epoch double precision NOT NULL
);

COPY _archive_cutoffs(stream_name, cutoff_epoch) FROM STDIN WITH (FORMAT text);
SQL_HEAD
    cat "$CUTOFFS"
    printf "\\.\n"
    cat <<'SQL_TAIL'
WITH effective AS (
  SELECT
    stream_name,
    GREATEST(to_timestamp(cutoff_epoch), :'fallback_cutoff'::timestamptz) AS effective_cutoff
  FROM _archive_cutoffs
)
SELECT count(*) AS would_delete
FROM public.camera_events e
JOIN effective c ON c.stream_name = e.stream_name
WHERE e.occurred_at < c.effective_cutoff;

WITH effective AS (
  SELECT
    stream_name,
    GREATEST(to_timestamp(cutoff_epoch), :'fallback_cutoff'::timestamptz) AS effective_cutoff
  FROM _archive_cutoffs
)
SELECT
  c.stream_name,
  c.effective_cutoff,
  count(e.*) AS would_delete
FROM effective c
LEFT JOIN public.camera_events e
  ON e.stream_name = c.stream_name
 AND e.occurred_at < c.effective_cutoff
GROUP BY c.stream_name, c.effective_cutoff
ORDER BY c.stream_name;
SQL_TAIL
  } | "${PSQL[@]}" -v ON_ERROR_STOP=1 -v fallback_cutoff="$FALLBACK_CUTOFF"
else
  {
    cat <<'SQL_HEAD'
CREATE TEMP TABLE _archive_cutoffs (
  stream_name text NOT NULL,
  cutoff_epoch double precision NOT NULL
);

COPY _archive_cutoffs(stream_name, cutoff_epoch) FROM STDIN WITH (FORMAT text);
SQL_HEAD
    cat "$CUTOFFS"
    printf "\\.\n"
    cat <<'SQL_TAIL'
WITH effective AS (
  SELECT
    stream_name,
    GREATEST(to_timestamp(cutoff_epoch), :'fallback_cutoff'::timestamptz) AS effective_cutoff
  FROM _archive_cutoffs
),
deleted AS (
  DELETE FROM public.camera_events e
  USING effective c
  WHERE e.stream_name = c.stream_name
    AND e.occurred_at < c.effective_cutoff
  RETURNING e.stream_name
)
SELECT stream_name, count(*) AS deleted
FROM deleted
GROUP BY stream_name
ORDER BY stream_name;

VACUUM (ANALYZE) public.camera_events;
SQL_TAIL
  } | "${PSQL[@]}" -v ON_ERROR_STOP=1 -v fallback_cutoff="$FALLBACK_CUTOFF"
fi
