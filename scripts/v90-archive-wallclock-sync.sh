#!/usr/bin/env bash
set -Eeuo pipefail

# NewDomofon Video: v90 archive wall-clock sync stabilization
# Scope: embedded DVR player frontend only.
# Goal: do not add/remove user-visible functions; fix archive time mismatch when archive HLS contains gaps.
# Why: HTMLMediaElement.currentTime is media timeline seconds, not absolute wall-clock time.
#      When archive segments have missing periods, media timeline collapses gaps while CCTV OSD shows real time.
#      v90 maps currentTime <-> wall-clock using #EXT-X-PROGRAM-DATE-TIME / #EXTINF from the archive playlist.

PROJECT_DIR="${PROJECT_DIR:-/opt/newdomofon-video}"
WEB_ROOT="${WEB_ROOT:-/var/www/newdomofon-video}"
PLAYER_DIR="${PLAYER_DIR:-$WEB_ROOT/newdomofon-player}"
PLAYER_JS="$PLAYER_DIR/player.js"
EMBED_HTML="$PLAYER_DIR/embed.html"
PLAYER_CSS="$PLAYER_DIR/player.css"

[[ "$(id -u)" -eq 0 ]] || { echo "Run as root with sudo." >&2; exit 1; }
command -v python3 >/dev/null || { echo "python3 not found" >&2; exit 1; }
command -v node >/dev/null || { echo "node not found" >&2; exit 1; }
[[ -f "$PLAYER_JS" ]] || { echo "player.js not found: $PLAYER_JS" >&2; exit 1; }

TS="$(date +%Y%m%d-%H%M%S)"
BACKUP="$PROJECT_DIR/backups/v90-archive-wallclock-sync-$TS"
mkdir -p "$BACKUP"
backup() {
  [[ -e "$1" ]] || return 0
  mkdir -p "$BACKUP/$(dirname "${1#/}")"
  cp -a "$1" "$BACKUP/${1#/}"
  echo "backup: $1"
}

echo "===== Backup ====="
backup "$PLAYER_JS"
backup "$EMBED_HTML"
backup "$PLAYER_CSS"

if ! node --check "$PLAYER_JS" >/dev/null; then
  echo "WARNING: player.js has syntax issue before patch; trying known safe repair." >&2
fi

echo

echo "===== Patch archive wall-clock mapping ====="
python3 - "$PLAYER_JS" <<'PY'
import pathlib, re, sys
path = pathlib.Path(sys.argv[1])
s = path.read_text()
orig = s

# Known safe repair from earlier script stacking.
s = re.sub(r'\basync\s+async\s+function\b', 'async function', s)

helper = r"""
var ndArchiveMapV90=null;
function ndNormPdtV90(s){return String(s||'').trim().replace(/([+-]\d{2})(\d{2})$/,'$1:$2')}
function ndParsePdtV90(s){var t=Date.parse(ndNormPdtV90(s));return Number.isFinite(t)?t:NaN}
function ndParseUriDateV90(uri){var x=String(uri||''),m=x.match(/(20\d{2})(\d{2})(\d{2})[_-](\d{2})(\d{2})(\d{2})/);if(m){var d=new Date(Number(m[1]),Number(m[2])-1,Number(m[3]),Number(m[4]),Number(m[5]),Number(m[6]));var t=d.getTime();if(Number.isFinite(t))return t}m=x.match(/(20\d{2})-(\d{2})-(\d{2})\/(\d{2})\/.*?(\d{2})(\d{2})(\d{2})/);if(m){var d2=new Date(Number(m[1]),Number(m[2])-1,Number(m[3]),Number(m[4]),Number(m[5]),Number(m[6]),Number(m[7]));var t2=d2.getTime();if(Number.isFinite(t2))return t2}return NaN}
function ndParseArchiveMapV90(url,text,requestedStartMs){var lines=String(text||'').split(/\r?\n/),items=[],dur=NaN,pdt=NaN,media=0,lastWall=Number.isFinite(requestedStartMs)?requestedStartMs:NaN;lines.forEach(function(raw){var line=String(raw||'').trim();if(!line)return;var m=line.match(/^#EXTINF:([0-9.]+)/i);if(m){dur=Math.max(0,Number(m[1]));return}m=line.match(/^#EXT-X-PROGRAM-DATE-TIME:(.+)$/i);if(m){pdt=ndParsePdtV90(m[1]);return}if(line[0]==='#')return;var d=Number.isFinite(dur)?dur:4;var wall=Number.isFinite(pdt)?pdt:ndParseUriDateV90(line);if(!Number.isFinite(wall)&&Number.isFinite(lastWall))wall=lastWall;if(Number.isFinite(wall)&&d>0){items.push({mediaStart:media,mediaEnd:media+d,wallStart:wall,wallEnd:wall+d*1000,uri:line});lastWall=wall+d*1000}media+=d;dur=NaN;pdt=NaN});return {version:'v90',url:url,requestedStartMs:requestedStartMs,totalMediaSec:media,items:items,createdAt:Date.now()}}
function ndMaybeUpdateArchiveMapV90(url,text){try{if(String(url||'').indexOf('/dvr-archive/')<0||String(url||'').indexOf('/archive-')<0)return;var m=String(url||'').match(/archive-(\d+)-(\d+)\.m3u8/);var req=m?Number(m[1])*1000:state.ws;var map=ndParseArchiveMapV90(url,text,req);if(map&&map.items&&map.items.length){ndArchiveMapV90=map;window.ND_PLAYER_ARCHIVE_TIME_V90=map;try{window.dispatchEvent(new CustomEvent('nd-player-archive-map-v90',{detail:{items:map.items.length,start:map.items[0].wallStart,end:map.items[map.items.length-1].wallEnd,totalMediaSec:map.totalMediaSec}}))}catch(_){}}}catch(e){console.warn('[NewDomofon v90] archive map failed',e)}}
function ndArchiveWallTimeV90(mediaSec,fallbackStartMs){var sec=Number(mediaSec);var fallback=(Number.isFinite(fallbackStartMs)?fallbackStartMs:state.activeS)+(Number.isFinite(sec)?sec:0)*1000;var map=ndArchiveMapV90;if(!map||!map.items||!map.items.length||!Number.isFinite(sec))return fallback;for(var i=0;i<map.items.length;i++){var it=map.items[i];if(sec>=it.mediaStart-.25&&sec<=it.mediaEnd+.25){var wall=it.wallStart+(sec-it.mediaStart)*1000;return Number.isFinite(wall)?wall:fallback}}if(sec<map.items[0].mediaStart)return map.items[0].wallStart;var last=map.items[map.items.length-1];if(sec>last.mediaEnd)return last.wallEnd+(sec-last.mediaEnd)*1000;return fallback}
function ndArchiveMediaTimeV90(wallMs,fallbackSec){var wall=Number(wallMs);var fallback=Number.isFinite(fallbackSec)?fallbackSec:0;var map=ndArchiveMapV90;if(!map||!map.items||!map.items.length||!Number.isFinite(wall))return fallback;for(var i=0;i<map.items.length;i++){var it=map.items[i];if(wall>=it.wallStart&&wall<=it.wallEnd){return Math.max(0,it.mediaStart+(wall-it.wallStart)/1000)}}for(var j=0;j<map.items.length;j++){if(wall<map.items[j].wallStart)return Math.max(0,map.items[j].mediaStart)}var last=map.items[map.items.length-1];return Math.max(0,last.mediaEnd)}
"""

if 'function ndArchiveWallTimeV90(' not in s:
    marker = 'async function checkManifest(url)'
    if marker not in s:
        raise SystemExit('Cannot patch: async function checkManifest(url) not found')
    s = s.replace(marker, helper + marker, 1)

# Patch checkManifest so every archive manifest prefetch builds a media->wall-clock map.
old = "if(b.indexOf('#EXTM3U')<0)throw new Error('Ответ не является HLS playlist');return b}"
new = "if(b.indexOf('#EXTM3U')<0)throw new Error('Ответ не является HLS playlist');ndMaybeUpdateArchiveMapV90(url,b);return b}"
if old in s and new not in s:
    s = s.replace(old, new, 1)
elif new in s:
    pass
else:
    raise SystemExit('Cannot patch: checkManifest return marker not found')

# Patch archive seek: wall-clock target -> collapsed media timeline seconds.
old_seek = "v.currentTime=Math.max(0,Math.min(opt.seek,Number.isFinite(v.duration)?v.duration-.5:opt.seek))"
new_seek = "var ndSeek=(state.mode==='dvr'?ndArchiveMediaTimeV90(state.cursor,opt.seek):opt.seek);v.currentTime=Math.max(0,Math.min(ndSeek,Number.isFinite(v.duration)?v.duration-.5:ndSeek))"
if old_seek in s and new_seek not in s:
    s = s.replace(old_seek, new_seek, 1)
elif new_seek in s:
    pass
else:
    raise SystemExit('Cannot patch: currentTime seek marker not found')

# Patch archive timeupdate: collapsed media timeline seconds -> wall-clock timestamp.
old_time = "state.cursor=state.activeS+v.currentTime*1000;uiTimeline()"
new_time = "state.cursor=ndArchiveWallTimeV90(v.currentTime,state.activeS);uiTimeline()"
if old_time in s and new_time not in s:
    s = s.replace(old_time, new_time, 1)
elif new_time in s:
    pass
else:
    raise SystemExit('Cannot patch: timeupdate cursor marker not found')

# Pan should move only the visible timeline window, not the playback cursor.
old_pan = "function pan(delta){state.ws+=delta;state.we+=delta;state.cursor+=delta;keepWin();state.cursor=clamp(state.cursor,state.ws,state.we);uiTimeline();syncInputs();fetchEvents()}"
new_pan = "function pan(delta){state.ws+=delta;state.we+=delta;keepWin();state.cursor=clampArchive(state.cursor);uiTimeline();syncInputs();fetchEvents()}"
if old_pan in s and new_pan not in s:
    s = s.replace(old_pan, new_pan, 1)
elif new_pan in s:
    pass
else:
    raise SystemExit('Cannot patch: pan() marker not found')

# Add a visible diagnostic marker without changing UI.
if "window.ND_PLAYER_TIME_SYNC_V90" not in s:
    marker = "window.ND_PLAYER_STABILITY_SOURCE='v89-audited';"
    diag = "window.ND_PLAYER_TIME_SYNC_V90={version:'v90-archive-wallclock-sync',map:function(){return ndArchiveMapV90},wall:function(sec){return ndArchiveWallTimeV90(sec,state.activeS)},media:function(ms){return ndArchiveMediaTimeV90(ms,0)}};"
    if marker in s:
        s = s.replace(marker, marker + diag, 1)
    else:
        # fallback: place after helper declaration
        s = s.replace('var ndArchiveMapV90=null;', 'var ndArchiveMapV90=null;window.ND_PLAYER_TIME_SYNC_V90={version:\'v90-archive-wallclock-sync\',map:function(){return ndArchiveMapV90},wall:function(sec){return ndArchiveWallTimeV90(sec,state.activeS)},media:function(ms){return ndArchiveMediaTimeV90(ms,0)}};', 1)

path.write_text(s)
print('changed:', s != orig)
print('has_helper:', 'function ndArchiveWallTimeV90(' in s)
print('has_check_manifest_hook:', 'ndMaybeUpdateArchiveMapV90(url,b)' in s)
print('has_timeupdate_map:', 'ndArchiveWallTimeV90(v.currentTime,state.activeS)' in s)
print('has_seek_map:', 'ndArchiveMediaTimeV90(state.cursor,opt.seek)' in s)
print('pan_keeps_cursor:', 'function pan(delta){state.ws+=delta;state.we+=delta;keepWin();state.cursor=clampArchive(state.cursor);' in s)
PY

node --check "$PLAYER_JS"

echo
echo "installed: v90 archive wall-clock sync"
echo "backup:    $BACKUP"
echo
echo "Browser iframe console checks:"
echo "  window.ND_PLAYER_TIME_SYNC_V90"
echo "  window.ND_PLAYER_TIME_SYNC_V90.map()"
echo "  window.ND_PLAYER_ARCHIVE_TIME_V90"
echo
echo "Expected: archive clock/cursor follows real CCTV timestamp even if archive playlist has gaps."
