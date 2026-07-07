#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="${PROJECT_DIR:-/opt/newdomofon-video}"
STREAM_NAME="${STREAM_NAME:-cam_10_130_1_219}"
CAMERA_ID="${CAMERA_ID:-f0486587-8a79-4cc2-b257-0671f874c08b}"
SINCE="${SINCE:-2 hours ago}"
OUT_DIR="${OUT_DIR:-/tmp/newdomofon-events-diagnostics-$(date +%Y%m%d-%H%M%S)}"

echo "===== v125 events ingest diagnostics ====="
echo "project: $PROJECT_DIR"
echo "stream:  $STREAM_NAME"
echo "camera:  $CAMERA_ID"
echo "since:   $SINCE"
echo "out:     $OUT_DIR"

mkdir -p "$OUT_DIR"

echo
echo "===== Systemd units ====="
systemctl list-units --all --type=service --type=timer \
  | grep -Ei 'event|onvif|camera|newdomofon|dvr|restream' \
  | tee "$OUT_DIR/systemd-units.txt" || true

echo
echo "===== Unit status ====="
for svc in \
  newdomofon-video-backend.service \
  newdomofon-public-events-proxy.service \
  newdomofon-events-public-proxy.service \
  newdomofon-video-dvr.service \
  newdomofon-restreamer.service \
  mediamtx.service
do
  if systemctl list-unit-files "$svc" >/dev/null 2>&1; then
    echo "--- $svc ---" | tee -a "$OUT_DIR/status.txt"
    systemctl status "$svc" --no-pager -l | tee -a "$OUT_DIR/status.txt" || true
  fi
done

echo
echo "===== Recent logs with event/onvif/errors ====="
journalctl --since "$SINCE" --no-pager \
  -u newdomofon-video-backend.service \
  -u newdomofon-public-events-proxy.service \
  -u newdomofon-events-public-proxy.service \
  -u newdomofon-video-dvr.service \
  -u newdomofon-restreamer.service \
  -u mediamtx.service 2>/dev/null \
  | grep -Ei 'event|onvif|motion|camera|error|warn|fail|listen|subscribe|notify|webhook' \
  | tail -n 500 \
  | tee "$OUT_DIR/recent-event-logs.txt" || true

echo
echo "===== Load env and inspect DB ====="
set +u
for envf in \
  /etc/newdomofon-video/app.env \
  "$PROJECT_DIR/backend/.env" \
  "$PROJECT_DIR/.env"
do
  if [ -f "$envf" ]; then
    echo "load env: $envf"
    set -a
    . "$envf"
    set +a
  fi
done
set -u

node <<'NODE' | tee "$OUT_DIR/db-events.txt"
const fs = require('fs');
const path = require('path');

function requirePg() {
  const candidates = [
    process.cwd() + '/backend/node_modules/pg',
    '/opt/newdomofon-video/backend/node_modules/pg',
    '/opt/newdomofon-video/node_modules/pg',
    'pg',
  ];
  for (const c of candidates) {
    try { return require(c); } catch (_) {}
  }
  throw new Error('pg module not found');
}

(async () => {
  try {
    const { Client } = requirePg();
    const cfg = process.env.DATABASE_URL
      ? { connectionString: process.env.DATABASE_URL }
      : {
          host: process.env.PGHOST || process.env.DB_HOST || '127.0.0.1',
          port: Number(process.env.PGPORT || process.env.DB_PORT || 5432),
          user: process.env.PGUSER || process.env.DB_USER || process.env.POSTGRES_USER,
          password: process.env.PGPASSWORD || process.env.DB_PASSWORD || process.env.POSTGRES_PASSWORD,
          database: process.env.PGDATABASE || process.env.DB_NAME || process.env.POSTGRES_DB,
        };
    const client = new Client(cfg);
    await client.connect();

    console.log('db connected');

    const tables = await client.query(`
      select table_schema, table_name
      from information_schema.tables
      where table_schema not in ('pg_catalog','information_schema')
        and (table_name ilike '%event%' or table_name ilike '%camera%' or table_name ilike '%motion%')
      order by table_schema, table_name
    `);
    console.log('candidate tables:', JSON.stringify(tables.rows, null, 2));

    const exists = await client.query(`select to_regclass('public.camera_events') as camera_events`);
    console.log('to_regclass camera_events:', exists.rows[0]);

    if (exists.rows[0].camera_events) {
      const cols = await client.query(`
        select column_name, data_type
        from information_schema.columns
        where table_schema='public' and table_name='camera_events'
        order by ordinal_position
      `);
      console.log('camera_events columns:', JSON.stringify(cols.rows, null, 2));

      const count = await client.query(`
        select
          count(*)::int as total,
          max(occurred_at) as max_occurred_at,
          min(occurred_at) as min_occurred_at
        from public.camera_events
      `);
      console.log('camera_events totals:', JSON.stringify(count.rows[0], null, 2));

      const recent = await client.query(`
        select
          count(*)::int as count_2h,
          max(occurred_at) as max_2h
        from public.camera_events
        where occurred_at >= now() - interval '2 hours'
      `);
      console.log('camera_events last 2h:', JSON.stringify(recent.rows[0], null, 2));

      const stream = process.env.STREAM_NAME || 'cam_10_130_1_219';
      const camera = process.env.CAMERA_ID || 'f0486587-8a79-4cc2-b257-0671f874c08b';

      const scoped = await client.query(`
        select
          count(*)::int as count_stream_day,
          max(occurred_at) as max_stream_day
        from public.camera_events
        where occurred_at >= now() - interval '24 hours'
          and (
            stream_name = $1
            or camera_id::text = $2
          )
      `, [stream, camera]);
      console.log('camera_events stream/camera last 24h:', JSON.stringify(scoped.rows[0], null, 2));

      const lastRows = await client.query(`
        select *
        from public.camera_events
        where stream_name = $1 or camera_id::text = $2
        order by occurred_at desc
        limit 10
      `, [stream, camera]);
      console.log('last 10 scoped events:', JSON.stringify(lastRows.rows, null, 2));
    }

    await client.end();
  } catch (err) {
    console.error('DB diagnostics failed:', err && err.stack ? err.stack : String(err));
    process.exitCode = 0;
  }
})();
NODE

echo
echo "===== Public events endpoint smoke ====="
TOKEN="${TOKEN:-}"
if [ -n "$TOKEN" ]; then
  curl -k -sS \
    "https://new-video.domofon-37.ru/public-events/$CAMERA_ID/events?start=$(date -u -d '24 hours ago' +%Y-%m-%dT%H:%M:%SZ)&end=$(date -u +%Y-%m-%dT%H:%M:%SZ)&stream=$STREAM_NAME&limit=20&token=$TOKEN" \
    | jq '{ok, count, first: .items[0]}' \
    | tee "$OUT_DIR/public-events-smoke.json" || true
else
  echo "TOKEN not set, skip public-events curl"
fi

echo
echo "===== Result archive ====="
tar -C "$(dirname "$OUT_DIR")" -czf "$OUT_DIR.tar.gz" "$(basename "$OUT_DIR")"
echo "diagnostics dir: $OUT_DIR"
echo "diagnostics tgz: $OUT_DIR.tar.gz"
