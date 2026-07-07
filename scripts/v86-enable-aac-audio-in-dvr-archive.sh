#!/usr/bin/env bash
set -euo pipefail

VERSION="v86-enable-aac-audio-in-dvr-archive"
PROJECT_DIR="${PROJECT_DIR:-/opt/newdomofon-video}"
DVR_ENGINE_DIR="${DVR_ENGINE_DIR:-$PROJECT_DIR/dvr-engine}"
DVR_ROOT="${DVR_ROOT:-/var/lib/newdomofon-video/dvr}"
STREAM_NAME="${STREAM_NAME:-cam_10_130_1_219}"
AUDIO_BITRATE="${DVR_AUDIO_BITRATE:-64k}"
AUDIO_CHANNELS="${DVR_AUDIO_CHANNELS:-1}"
AUDIO_RATE="${DVR_AUDIO_RATE:-44100}"
BACKUP_DIR="$PROJECT_DIR/backups/$VERSION-$(date +%Y%m%d-%H%M%S)"
REPORT_DIR="$PROJECT_DIR/diagnostics"
REPORT="$REPORT_DIR/$VERSION-$(date +%Y%m%d-%H%M%S).txt"

mkdir -p "$BACKUP_DIR" "$REPORT_DIR"
exec > >(tee -a "$REPORT") 2>&1

echo "== $VERSION =="
echo "project: $PROJECT_DIR"
echo "dvr-engine: $DVR_ENGINE_DIR"
echo "dvr-root: $DVR_ROOT"
echo "stream: $STREAM_NAME"
echo "audio: aac bitrate=$AUDIO_BITRATE channels=$AUDIO_CHANNELS rate=$AUDIO_RATE"
echo "backup: $BACKUP_DIR"
echo "report: $REPORT"

for c in python3 systemctl ffmpeg ffprobe; do
  command -v "$c" >/dev/null || { echo "ERROR: $c not found" >&2; exit 1; }
done

if [[ ! -d "$DVR_ENGINE_DIR" ]]; then
  echo "ERROR: DVR engine dir not found: $DVR_ENGINE_DIR" >&2
  exit 1
fi

backup_file() {
  local f="$1"
  if [[ -e "$f" ]]; then
    local rel="${f#/}"
    mkdir -p "$BACKUP_DIR/$(dirname "$rel")"
    cp -a "$f" "$BACKUP_DIR/$rel"
    echo "backup: $f"
  fi
}

backup_file "$DVR_ENGINE_DIR/src/recorder.ts"
backup_file "$DVR_ENGINE_DIR/dist/recorder.js"
backup_file "/etc/systemd/system/newdomofon-dvr-engine.service"
backup_file "/etc/systemd/system/newdomofon-video-dvr.service"
backup_file "/etc/systemd/system/newdomofon-dvr.service"

echo
 echo "--- Current latest segment audio probe, before patch ---"
latest_seg="$(find "$DVR_ROOT/$STREAM_NAME" -type f -name '*.ts' 2>/dev/null | sort | tail -1 || true)"
if [[ -n "$latest_seg" ]]; then
  echo "latest segment: $latest_seg"
  ffprobe -hide_banner -v error -select_streams a -show_entries stream=index,codec_name,codec_type,channels,sample_rate -of compact=p=0:nk=0 "$latest_seg" || true
else
  echo "No segment found for stream $STREAM_NAME"
fi

python3 - "$DVR_ENGINE_DIR" <<'PY'
from pathlib import Path
import sys

root = Path(sys.argv[1])
files = [root / 'src' / 'recorder.ts', root / 'dist' / 'recorder.js']

old_ts = """    '-map', '0:v:0',\n    '-c:v', 'copy',\n    '-an'"""
new_ts = """    '-map', '0:v:0',\n    '-map', '0:a?',\n    '-c:v', 'copy',\n    '-c:a', 'aac',\n    '-b:a', process.env.DVR_AUDIO_BITRATE || '64k',\n    '-ac', process.env.DVR_AUDIO_CHANNELS || '1',\n    '-ar', process.env.DVR_AUDIO_RATE || '44100',\n    '-af', 'aresample=async=1:first_pts=0'"""

old_js = """        '-map', '0:v:0',\n        '-c:v', 'copy',\n        '-an'"""
new_js = """        '-map', '0:v:0',\n        '-map', '0:a?',\n        '-c:v', 'copy',\n        '-c:a', 'aac',\n        '-b:a', process.env.DVR_AUDIO_BITRATE || '64k',\n        '-ac', process.env.DVR_AUDIO_CHANNELS || '1',\n        '-ar', process.env.DVR_AUDIO_RATE || '44100',\n        '-af', 'aresample=async=1:first_pts=0'"""

for p in files:
    if not p.exists():
        print(f'skip missing: {p}')
        continue
    text = p.read_text()
    original = text
    if old_ts in text:
        text = text.replace(old_ts, new_ts, 1)
    elif old_js in text:
        text = text.replace(old_js, new_js, 1)
    elif "'-map', '0:a?'" in text and "'-c:a', 'aac'" in text:
        print(f'already patched: {p}')
    else:
        raise SystemExit(f'ERROR: expected video-only ffmpeg args not found in {p}')
    if text != original:
        p.write_text(text)
        print(f'patched: {p}')
PY

# If TypeScript sources are present, build dist. If build fails, keep the direct dist patch above as fallback.
if [[ -f "$DVR_ENGINE_DIR/package.json" && -f "$DVR_ENGINE_DIR/src/recorder.ts" ]]; then
  echo
  echo "--- npm build dvr-engine ---"
  (
    cd "$DVR_ENGINE_DIR"
    if [[ ! -d node_modules ]]; then
      npm ci
    fi
    npm run build
  ) || {
    echo "WARNING: npm build failed. dist/recorder.js was patched directly; continuing with existing dist." >&2
  }
fi

# Re-apply dist patch after build in case TypeScript build overwrote it.
python3 - "$DVR_ENGINE_DIR/dist/recorder.js" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
if not p.exists():
    print(f'skip missing dist file: {p}')
    raise SystemExit(0)
text = p.read_text()
old = """        '-map', '0:v:0',\n        '-c:v', 'copy',\n        '-an'"""
new = """        '-map', '0:v:0',\n        '-map', '0:a?',\n        '-c:v', 'copy',\n        '-c:a', 'aac',\n        '-b:a', process.env.DVR_AUDIO_BITRATE || '64k',\n        '-ac', process.env.DVR_AUDIO_CHANNELS || '1',\n        '-ar', process.env.DVR_AUDIO_RATE || '44100',\n        '-af', 'aresample=async=1:first_pts=0'"""
if old in text:
    p.write_text(text.replace(old, new, 1))
    print(f'patched after build: {p}')
elif "'-map', '0:a?'" in text and "'-c:a', 'aac'" in text:
    print(f'dist audio patch OK: {p}')
else:
    raise SystemExit(f'ERROR: cannot verify audio patch in {p}')
PY

echo
 echo "--- Restart DVR services ---"
restarted=0
for svc in newdomofon-dvr-engine newdomofon-video-dvr newdomofon-dvr; do
  if systemctl list-unit-files "$svc.service" >/dev/null 2>&1 || systemctl status "$svc.service" >/dev/null 2>&1; then
    echo "restart: $svc"
    systemctl restart "$svc" || true
    sleep 2
    systemctl --no-pager --full status "$svc" | sed -n '1,35p' || true
    restarted=1
  fi
done
if [[ "$restarted" != "1" ]]; then
  echo "WARNING: no known DVR recorder service found. Restart the recorder service manually." >&2
fi

echo
 echo "--- Wait for new HLS segments ---"
sleep 16
new_seg="$(find "$DVR_ROOT/$STREAM_NAME" -type f -name '*.ts' -mmin -5 2>/dev/null | sort | tail -1 || true)"
if [[ -z "$new_seg" ]]; then
  new_seg="$(find "$DVR_ROOT/$STREAM_NAME" -type f -name '*.ts' 2>/dev/null | sort | tail -1 || true)"
fi
if [[ -n "$new_seg" ]]; then
  echo "new/latest segment: $new_seg"
  echo "audio streams:"
  ffprobe -hide_banner -v error -select_streams a -show_entries stream=index,codec_name,codec_type,channels,sample_rate -of compact=p=0:nk=0 "$new_seg" || true
  echo "all streams:"
  ffprobe -hide_banner -v error -show_entries stream=index,codec_name,codec_type,channels,sample_rate -of compact=p=0:nk=0 "$new_seg" || true
else
  echo "No segment found after restart for stream $STREAM_NAME"
fi

echo
 echo "DONE: $VERSION"
echo "Important: old archive segments remain without audio if they were recorded with -an. Audio will appear only in new archive fragments recorded after this patch and recorder restart."
echo "Report: $REPORT"
echo "Rollback example:"
echo "  sudo cp '$BACKUP_DIR/${DVR_ENGINE_DIR#/}/src/recorder.ts' '$DVR_ENGINE_DIR/src/recorder.ts' 2>/dev/null || true"
echo "  sudo cp '$BACKUP_DIR/${DVR_ENGINE_DIR#/}/dist/recorder.js' '$DVR_ENGINE_DIR/dist/recorder.js' 2>/dev/null || true"
echo "  sudo systemctl restart newdomofon-dvr-engine 2>/dev/null || sudo systemctl restart newdomofon-video-dvr 2>/dev/null || sudo systemctl restart newdomofon-dvr 2>/dev/null || true"
