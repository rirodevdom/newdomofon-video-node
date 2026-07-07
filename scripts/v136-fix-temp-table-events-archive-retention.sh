#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="${PROJECT_DIR:-/opt/newdomofon-video}"
SCRIPT_DIR="$PROJECT_DIR/scripts"
BACKUP_DIR="$PROJECT_DIR/backups"
STAMP="$(date +%Y%m%d-%H%M%S)"

mkdir -p "$SCRIPT_DIR" "$BACKUP_DIR"

TARGET="$SCRIPT_DIR/events-align-to-archive-cleanup.sh"

if [ -f "$TARGET" ]; then
  cp -a "$TARGET" "$BACKUP_DIR/events-align-to-archive-cleanup.sh.$STAMP.bak"
fi

cat > "$TARGET" <<'EOS'
#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="${PROJECT_DIR:-/opt/newdomofon-video}"

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
EOS

chmod +x "$TARGET"

cat > /etc/systemd/system/newdomofon-events-archive-retention.service <<EOF
[Unit]
Description=NewDomofon align camera events with current DVR archive window
After=postgresql.service

[Service]
Type=oneshot
Environment=PROJECT_DIR=$PROJECT_DIR
EnvironmentFile=-/etc/newdomofon-video/app.env
EnvironmentFile=-$PROJECT_DIR/backend/.env
ExecStart=/usr/bin/bash $TARGET
EOF

cat > /etc/systemd/system/newdomofon-events-archive-retention.timer <<'EOF'
[Unit]
Description=Run NewDomofon archive-aligned camera events retention hourly

[Timer]
OnBootSec=15min
OnUnitActiveSec=1h
AccuracySec=5min
Persistent=true
RandomizedDelaySec=120

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl reset-failed newdomofon-events-archive-retention.service || true
systemctl enable --now newdomofon-events-archive-retention.timer

echo
echo "===== VERIFY SCRIPT ====="
bash -n "$TARGET"
grep -n "CREATE TEMP TABLE\|ON COMMIT\|COPY _archive_cutoffs\|fallback_cutoff" "$TARGET" || true

echo
echo "===== DRY RUN archive-align ====="
APPLY=0 PROJECT_DIR="$PROJECT_DIR" bash "$TARGET"

echo
echo "===== APPLY archive-align ====="
systemctl start newdomofon-events-archive-retention.service

echo
echo "===== STATUS ====="
systemctl status newdomofon-events-archive-retention.service --no-pager -l
systemctl list-timers --all --no-pager | grep 'newdomofon-events.*retention' || true
