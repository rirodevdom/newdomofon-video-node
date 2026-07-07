#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="${PROJECT_DIR:-/opt/newdomofon-video}"
STREAM_NAME="${STREAM_NAME:-}"
CAMERA_ID="${CAMERA_ID:-}"
SITE_URL="${SITE_URL:-https://new-video.domofon-37.ru}"
TOKEN="${TOKEN:-}"
APPLY="${APPLY:-0}"
ARCHIVE_START="${ARCHIVE_START:-}"
BATCH_SIZE="${BATCH_SIZE:-5000}"

log(){ printf '\n===== %s =====\n' "$*"; }
fail(){ echo "ERROR: $*" >&2; exit 1; }

[ -n "$STREAM_NAME" ] || fail "STREAM_NAME is required"
[ -d "$PROJECT_DIR" ] || fail "PROJECT_DIR not found: $PROJECT_DIR"

BACKUP_DIR="$PROJECT_DIR/backups/v1153-events-archive-retention-repair-node-args-fix-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BACKUP_DIR"

log "Validate"
echo "project: $PROJECT_DIR"
echo "stream:  $STREAM_NAME"
echo "camera:  ${CAMERA_ID:-<empty>}"
echo "apply:   $APPLY"
echo "backup:  $BACKUP_DIR"

log "Load environment"
for f in "/etc/newdomofon-video/app.env" "$PROJECT_DIR/backend/.env" "$PROJECT_DIR/.env"; do
  if [ -f "$f" ]; then
    cp -a "$f" "$BACKUP_DIR/$(echo "$f" | sed 's#/#_#g')" 2>/dev/null || true
    set -a
    # shellcheck disable=SC1090
    source "$f"
    set +a
    echo "loaded: $f"
  fi
done

if [ -z "${DATABASE_URL:-}" ] && [ -n "${POSTGRES_URL:-}" ]; then
  export DATABASE_URL="$POSTGRES_URL"
fi
[ -n "${DATABASE_URL:-}" ] || fail "DATABASE_URL/POSTGRES_URL not found in env"

log "Backup retention related files"
for f in \
  "/etc/newdomofon-video/archive-start-overrides.json" \
  "/etc/systemd/system/newdomofon-events-retention.timer" \
  "/etc/systemd/system/newdomofon-events-retention.service" \
  "/etc/systemd/system/newdomofon-events-archive-retention.timer" \
  "/etc/systemd/system/newdomofon-events-archive-retention.service" \
  "/etc/systemd/system/newdomofon-events-archive-retention-v1151.timer" \
  "/etc/systemd/system/newdomofon-events-archive-retention-v1151.service" \
  "/etc/systemd/system/newdomofon-events-archive-retention-v1152.timer" \
  "/etc/systemd/system/newdomofon-events-archive-retention-v1152.service" \
  "/etc/systemd/system/newdomofon-events-archive-retention-v1153.timer" \
  "/etc/systemd/system/newdomofon-events-archive-retention-v1153.service"; do
  if [ -f "$f" ]; then
    mkdir -p "$BACKUP_DIR/$(dirname "$f")"
    cp -a "$f" "$BACKUP_DIR/$f"
    echo "backup: $f"
  fi
done

log "Resolve current archive start"
RS_FILE="$BACKUP_DIR/recording_status.json"
ARCHIVE_START_ISO=""
if [ -n "$ARCHIVE_START" ]; then
  ARCHIVE_START_ISO="$(node -e "const d=new Date(process.argv[1]); if(!Number.isFinite(d.getTime())) process.exit(2); console.log(d.toISOString())" "$ARCHIVE_START")" || fail "cannot parse ARCHIVE_START=$ARCHIVE_START"
  echo "manual archive start: $ARCHIVE_START -> $ARCHIVE_START_ISO"
else
  if [ -n "$TOKEN" ]; then
    RS_URL="${SITE_URL%/}/${STREAM_NAME}/recording_status.json?token=${TOKEN}"
  else
    RS_URL="${SITE_URL%/}/${STREAM_NAME}/recording_status.json"
  fi
  echo "fetch: $RS_URL"
  curl -kfsS --max-time 20 "$RS_URL" -o "$RS_FILE" || fail "cannot fetch recording_status.json"
  # IMPORTANT: use `node - args... <<'NODE'`. Without the dash, Node treats the first
  # argument as the script filename; JSON can then be executed as a no-op JS file and
  # produce an empty archive_start_iso.
  ARCHIVE_START_ISO="$(node - "$RS_FILE" "$STREAM_NAME" <<'NODE'
const fs = require('fs');
const file = process.argv[2];
const streamName = process.argv[3];
const raw = fs.readFileSync(file, 'utf8').trim();
let data;
try { data = JSON.parse(raw); } catch (e) { console.error('bad json:', e.message); process.exit(3); }

function normalizeEpoch(v){
  if (v == null) return null;
  if (typeof v === 'string' && /^\d+(\.\d+)?$/.test(v.trim())) v = Number(v.trim());
  if (typeof v === 'string') {
    const ms = Date.parse(v);
    return Number.isFinite(ms) ? ms : null;
  }
  if (typeof v !== 'number' || !Number.isFinite(v)) return null;
  // seconds vs milliseconds
  return v > 100000000000 ? Math.round(v) : Math.round(v * 1000);
}
function streamMatches(node){
  if (!node || typeof node !== 'object') return true;
  const s = node.stream ?? node.name ?? node.stream_name ?? node.streamName ?? null;
  return !s || String(s) === String(streamName);
}
function collectRanges(node, inheritedMatch = true, out = []){
  if (node == null) return out;
  if (Array.isArray(node)) { for (const n of node) collectRanges(n, inheritedMatch, out); return out; }
  if (typeof node !== 'object') return out;

  const ownMatch = inheritedMatch && streamMatches(node);

  // wrappers: [{stream, ranges:[{from,duration}]}], {ranges:[...]}, {streams:[...]}, etc.
  for (const key of ['ranges','recordings','items','archive','archives','segments']) {
    if (node[key] && ownMatch) collectRanges(node[key], ownMatch, out);
  }
  if (node.streams) collectRanges(node.streams, inheritedMatch, out);
  if (node.data) collectRanges(node.data, inheritedMatch, out);

  const fromRaw = node.from ?? node.start ?? node.start_time ?? node.startTime ?? node.from_ts ?? node.begin ?? node.begin_at;
  const toRaw = node.to ?? node.end ?? node.end_time ?? node.endTime ?? node.to_ts ?? node.finish ?? node.finish_at;
  const durationRaw = node.duration ?? node.duration_sec ?? node.durationSecs ?? node.len ?? node.length;
  const fromMs = normalizeEpoch(fromRaw);
  if (fromMs != null && ownMatch) {
    let toMs = normalizeEpoch(toRaw);
    if (toMs == null && durationRaw != null) {
      const dur = typeof durationRaw === 'string' ? Number(durationRaw) : durationRaw;
      if (Number.isFinite(dur)) toMs = fromMs + Math.round(dur * 1000);
    }
    out.push({fromMs, toMs});
  }
  return out;
}
const ranges = collectRanges(data).filter(r => Number.isFinite(r.fromMs));
if (!ranges.length) {
  console.error('no ranges parsed from recording_status:', raw.slice(0, 1000));
  process.exit(4);
}
ranges.sort((a,b) => a.fromMs - b.fromMs);
console.log(new Date(ranges[0].fromMs).toISOString());
NODE
)" || fail "cannot resolve archive start from recording_status: $(head -c 1000 "$RS_FILE")"
fi

[ -n "$ARCHIVE_START_ISO" ] || fail "resolved ARCHIVE_START_ISO is empty; recording_status saved at $RS_FILE"
export ARCHIVE_START_ISO

echo "archive_start_iso: $ARCHIVE_START_ISO"
echo "archive_start_local_hint: $(TZ=Europe/Moscow date -d "$ARCHIVE_START_ISO" '+%Y-%m-%d %H:%M:%S %Z' 2>/dev/null || true)"

log "Update archive-start override"
OVERRIDE_FILE="/etc/newdomofon-video/archive-start-overrides.json"
mkdir -p /etc/newdomofon-video
if [ "$APPLY" = "1" ]; then
  node - "$OVERRIDE_FILE" "$STREAM_NAME" "$ARCHIVE_START_ISO" <<'NODE'
const fs = require('fs');
const [file, stream, iso] = process.argv.slice(2);
let obj = {};
try { if (fs.existsSync(file)) obj = JSON.parse(fs.readFileSync(file, 'utf8') || '{}'); } catch { obj = {}; }
obj[stream] = iso;
fs.writeFileSync(file, JSON.stringify(obj, null, 2) + '\n');
NODE
  echo "set: $OVERRIDE_FILE: $STREAM_NAME -> $ARCHIVE_START_ISO"
else
  echo "DRY-RUN: would set $OVERRIDE_FILE: $STREAM_NAME -> $ARCHIVE_START_ISO"
fi

log "One-time cleanup camera_events older than archive start"
export PROJECT_DIR STREAM_NAME CAMERA_ID APPLY BACKUP_DIR BATCH_SIZE DATABASE_URL ARCHIVE_START_ISO
node <<'NODE'
const fs = require('fs');
const path = require('path');
let Pool;
try { Pool = require(path.join(process.env.PROJECT_DIR, 'backend/node_modules/pg')).Pool; }
catch { Pool = require('pg').Pool; }

const archiveStartIso = process.env.ARCHIVE_START_ISO;
if (!archiveStartIso) throw new Error('ARCHIVE_START_ISO is required');
const cutoff = new Date(archiveStartIso);
if (!Number.isFinite(cutoff.getTime())) throw new Error('bad ARCHIVE_START_ISO=' + archiveStartIso);
const stream = process.env.STREAM_NAME;
const camera = process.env.CAMERA_ID || '';
const apply = process.env.APPLY === '1';
const backupDir = process.env.BACKUP_DIR;
const batchSize = Number(process.env.BATCH_SIZE || 5000);

function qIdent(s){ return '"' + String(s).replace(/"/g, '""') + '"'; }

(async () => {
  const pool = new Pool({ connectionString: process.env.DATABASE_URL });
  const client = await pool.connect();
  try {
    const tables = await client.query(`
      select table_schema, table_name
      from information_schema.tables
      where table_type='BASE TABLE' and table_name='camera_events'
      order by case when table_schema='public' then 0 else 1 end
      limit 1
    `);
    if (!tables.rowCount) throw new Error('camera_events table not found');
    const schema = tables.rows[0].table_schema;
    const table = tables.rows[0].table_name;
    const fq = `${qIdent(schema)}.${qIdent(table)}`;

    const colRows = await client.query(`
      select column_name
      from information_schema.columns
      where table_schema=$1 and table_name=$2
    `, [schema, table]);
    const cols = new Set(colRows.rows.map(r => r.column_name));
    const timeCol = ['occurred_at','created_at','event_time','timestamp','time'].find(c => cols.has(c));
    if (!timeCol) throw new Error('no timestamp column found in camera_events');
    const hasCamera = cols.has('camera_id');
    const hasStream = cols.has('stream_name');
    if (!hasCamera && !hasStream) throw new Error('camera_events has neither camera_id nor stream_name');

    const idConds = [];
    const idParams = [];
    if (hasCamera && camera) { idParams.push(camera); idConds.push(`${qIdent('camera_id')}::text = $${idParams.length}`); }
    if (hasStream && stream) { idParams.push(stream); idConds.push(`${qIdent('stream_name')}::text = $${idParams.length}`); }
    if (!idConds.length) throw new Error('no camera/stream condition available');
    const idWhere = `(${idConds.join(' OR ')})`;

    const cutoffParamIndex = idParams.length + 1;
    const params = [...idParams, cutoff.toISOString()];
    const where = `${idWhere} AND ${qIdent(timeCol)} < $${cutoffParamIndex}`;

    const stats = await client.query(`
      select
        count(*)::bigint as total_matching,
        count(*) filter (where ${qIdent(timeCol)} < $${cutoffParamIndex})::bigint as old_before_cutoff,
        min(${qIdent(timeCol)}) as min_time,
        max(${qIdent(timeCol)}) as max_time
      from ${fq}
      where ${idWhere}
    `, params);
    console.log(JSON.stringify({ table: `${schema}.${table}`, timeCol, hasCamera, hasStream, cutoff: cutoff.toISOString(), stats: stats.rows[0] }, null, 2));

    const count = await client.query(`select count(*)::bigint as n from ${fq} where ${where}`, params);
    const oldCount = Number(count.rows[0].n || 0);
    console.log(`old_before_cutoff_for_delete: ${oldCount}`);

    const backupPath = path.join(backupDir, `old-events-before-${cutoff.toISOString().replace(/[:.]/g,'-')}.jsonl`);
    if (oldCount > 0) {
      const rows = await client.query(`select * from ${fq} where ${where} order by ${qIdent(timeCol)} asc limit 200000`, params);
      fs.writeFileSync(backupPath, rows.rows.map(r => JSON.stringify(r)).join('\n') + (rows.rows.length ? '\n' : ''));
      console.log(`backup_old_events_sample: ${backupPath}`);
      if (rows.rowCount < oldCount) console.log(`WARNING: backup is capped at ${rows.rowCount}/${oldCount} rows`);
    } else {
      fs.writeFileSync(backupPath, '');
      console.log(`backup_old_events_sample: ${backupPath}`);
    }

    if (!apply) {
      console.log('DRY-RUN: no rows deleted. Re-run with APPLY=1 to delete old events.');
      return;
    }

    let deletedTotal = 0;
    for (;;) {
      const del = await client.query(`
        with doomed as (
          select ctid from ${fq}
          where ${where}
          limit ${Math.max(1, Math.floor(batchSize))}
        )
        delete from ${fq} e
        using doomed d
        where e.ctid = d.ctid
        returning 1
      `, params);
      deletedTotal += del.rowCount;
      console.log(`deleted_batch: ${del.rowCount}, deleted_total: ${deletedTotal}`);
      if (del.rowCount === 0 || del.rowCount < batchSize) break;
    }
    console.log(`deleted_total: ${deletedTotal}`);
  } finally {
    client.release();
    await pool.end();
  }
})().catch(e => { console.error(e.stack || e.message); process.exit(1); });
NODE

log "Install safe v115.3 timer wrapper"
CLEANUP_SCRIPT="$PROJECT_DIR/scripts/events-archive-retention-v1153-run.sh"
if [ "$APPLY" = "1" ]; then
  cat > "$CLEANUP_SCRIPT" <<EOS
#!/usr/bin/env bash
set -euo pipefail
PROJECT_DIR="${PROJECT_DIR}" STREAM_NAME="${STREAM_NAME}" CAMERA_ID="${CAMERA_ID}" SITE_URL="${SITE_URL}" TOKEN="${TOKEN}" APPLY=1 bash "${PROJECT_DIR}/scripts/v115.3-events-archive-retention-repair-node-args-fix.sh"
EOS
  chmod +x "$CLEANUP_SCRIPT"
  cat > /etc/systemd/system/newdomofon-events-archive-retention-v1153.service <<EOS
[Unit]
Description=NewDomofon archive-aligned camera events retention v115.3
After=network-online.target postgresql.service

[Service]
Type=oneshot
ExecStart=$CLEANUP_SCRIPT
EOS
  cat > /etc/systemd/system/newdomofon-events-archive-retention-v1153.timer <<'EOS'
[Unit]
Description=Run NewDomofon archive-aligned camera events retention v115.3 hourly

[Timer]
OnCalendar=hourly
Persistent=true
RandomizedDelaySec=120

[Install]
WantedBy=timers.target
EOS
  systemctl daemon-reload
  systemctl enable --now newdomofon-events-archive-retention-v1153.timer >/dev/null
  echo "enabled: newdomofon-events-archive-retention-v1153.timer"
else
  echo "DRY-RUN: would install/enable newdomofon-events-archive-retention-v1153.timer on APPLY=1"
fi

log "Done"
echo "backup: $BACKUP_DIR"
echo "archive_start_iso: $ARCHIVE_START_ISO"
if [ "$APPLY" != "1" ]; then
  echo "Next: re-run with APPLY=1 if old_before_cutoff_for_delete is correct."
fi
