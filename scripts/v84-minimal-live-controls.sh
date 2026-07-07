#!/usr/bin/env bash
set -Eeuo pipefail

# NewDomofon Video: v84 minimal live controls
#
# Goal:
#   In LIVE mode keep only:
#     - Play/Pause
#     - Stop
#     - Volume
#     - Archive transition
#   DVR/archive mode is left unchanged.
#
# Implementation:
#   - no backend/DVR changes;
#   - adds a small JS enhancer live-minimal-controls-v84.js;
#   - appends scoped CSS to player.css;
#   - injects the JS into embed.html after player.js/overlays;
#   - uses the existing [data-proto="dvr"] action for archive transition.

PROJECT_DIR="${PROJECT_DIR:-/opt/newdomofon-video}"
WEB_ROOT="${WEB_ROOT:-/var/www/newdomofon-video}"
PLAYER_DIR="${PLAYER_DIR:-$WEB_ROOT/newdomofon-player}"
PLAYER_CSS="$PLAYER_DIR/player.css"
EMBED_HTML="$PLAYER_DIR/embed.html"
V84_JS="$PLAYER_DIR/live-minimal-controls-v84.js"

[[ "$(id -u)" -eq 0 ]] || { echo "Run as root with sudo." >&2; exit 1; }
command -v python3 >/dev/null || { echo "python3 not found" >&2; exit 1; }
command -v node >/dev/null || { echo "node not found" >&2; exit 1; }
[[ -d "$PLAYER_DIR" ]] || { echo "Player dir not found: $PLAYER_DIR" >&2; exit 1; }
[[ -f "$PLAYER_CSS" ]] || { echo "player.css not found: $PLAYER_CSS" >&2; exit 1; }
[[ -f "$EMBED_HTML" ]] || { echo "embed.html not found: $EMBED_HTML" >&2; exit 1; }

TS="$(date +%Y%m%d-%H%M%S)"
BACKUP="$PROJECT_DIR/backups/v84-minimal-live-controls-$TS"
mkdir -p "$BACKUP"

backup() {
  [[ -e "$1" ]] || return 0
  mkdir -p "$BACKUP/$(dirname "${1#/}")"
  cp -a "$1" "$BACKUP/${1#/}"
  echo "backup: $1"
}

echo "===== Backup ====="
backup "$EMBED_HTML"
backup "$PLAYER_CSS"
backup "$V84_JS"

cat > "$V84_JS" <<'JS'
(function () {
  'use strict';

  var VERSION = 'v84-minimal-live-controls';
  var installTimer = 0;
  var observer = null;

  function log() {
    var a = Array.prototype.slice.call(arguments);
    a.unshift('[NewDomofon live-controls-v84]');
    console.info.apply(console, a);
  }

  function $(sel, root) {
    return (root || document).querySelector(sel);
  }

  function makeButton(cls, text, title) {
    var b = document.createElement('button');
    b.type = 'button';
    b.className = 'btn ' + cls;
    b.textContent = text;
    b.title = title || text;
    b.setAttribute('aria-label', title || text);
    return b;
  }

  function installOnce() {
    var root = $('.ndp');
    var controls = $('.controls', root || document);
    var video = $('.video', root || document);
    var play = $('[data-action="play"]', root || document);
    var dvrTab = $('[data-proto="dvr"]', root || document);

    if (!root || !controls || !video || !play) return false;

    root.classList.add('nd-live-minimal-v84');

    var stop = $('.nd-v84-stop', controls);
    if (!stop) {
      stop = makeButton('nd-v84-stop', '■', 'Стоп');
      play.insertAdjacentElement('afterend', stop);
    }
    stop.onclick = function () {
      try {
        video.pause();
        play.textContent = '▶';
      } catch (err) {
        console.warn('[NewDomofon live-controls-v84] stop failed', err);
      }
    };

    var archive = $('.nd-v84-archive', controls);
    if (!archive) {
      archive = makeButton('btn warn nd-v84-archive', 'Архив', 'Перейти в архив');
      stop.insertAdjacentElement('afterend', archive);
    }
    archive.onclick = function () {
      var btn = $('[data-proto="dvr"]');
      if (btn) {
        btn.click();
        return;
      }
      console.warn('[NewDomofon live-controls-v84] DVR button not found');
    };

    // Mark the original elements used by the minimal LIVE layout.
    play.classList.add('nd-v84-keep-live');
    var volume = $('.volume', controls);
    if (volume) {
      volume.classList.add('nd-v84-keep-live');
      volume.setAttribute('aria-label', 'Громкость');
      volume.title = 'Громкость';
    }

    if (dvrTab) dvrTab.classList.add('nd-v84-dvr-source');
    return true;
  }

  function scheduleInstall() {
    clearTimeout(installTimer);
    installTimer = setTimeout(function () {
      installOnce();
    }, 30);
  }

  function start() {
    scheduleInstall();
    if (observer) return;
    observer = new MutationObserver(scheduleInstall);
    observer.observe(document.documentElement, { childList: true, subtree: true });
    log(VERSION + ' installed');
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', start, { once: true });
  } else {
    start();
  }

  window.ND_LIVE_CONTROLS_V84 = {
    version: VERSION,
    reinstall: installOnce
  };
})();
JS

node --check "$V84_JS"

python3 - "$PLAYER_CSS" <<'PY'
import pathlib, sys, re
path = pathlib.Path(sys.argv[1])
s = path.read_text()
block = r'''

/* v84 minimal LIVE controls: keep only Play, Stop, Volume and Archive. DVR mode is unchanged. */
.ndp.nd-live-minimal-v84:not(.dvr) .top .tabs {
  display: none !important;
}
.ndp.nd-live-minimal-v84:not(.dvr) .main {
  grid-template-columns: minmax(0, 1fr) !important;
}
.ndp.nd-live-minimal-v84:not(.dvr) .events {
  display: none !important;
}
.ndp.nd-live-minimal-v84:not(.dvr) .controls {
  display: flex !important;
  align-items: center !important;
  justify-content: center !important;
  gap: 10px !important;
  padding: 10px !important;
}
.ndp.nd-live-minimal-v84:not(.dvr) .controls > * {
  display: none !important;
}
.ndp.nd-live-minimal-v84:not(.dvr) .controls [data-action="play"],
.ndp.nd-live-minimal-v84:not(.dvr) .controls .nd-v84-stop,
.ndp.nd-live-minimal-v84:not(.dvr) .controls .nd-v84-archive {
  display: inline-flex !important;
  align-items: center !important;
  justify-content: center !important;
}
.ndp.nd-live-minimal-v84:not(.dvr) .controls .volume {
  display: block !important;
  width: min(180px, 34vw) !important;
}
.ndp.nd-live-minimal-v84:not(.dvr) .controls [data-action="play"],
.ndp.nd-live-minimal-v84:not(.dvr) .controls .nd-v84-stop {
  min-width: 44px !important;
  width: 44px !important;
  padding: 0 !important;
  font-size: 18px !important;
}
.ndp.nd-live-minimal-v84:not(.dvr) .controls .nd-v84-archive {
  min-width: 96px !important;
  font-weight: 800 !important;
}
.ndp.nd-live-minimal-v84.dvr .controls .nd-v84-stop,
.ndp.nd-live-minimal-v84.dvr .controls .nd-v84-archive {
  display: none !important;
}
@media(max-width: 640px) {
  .ndp.nd-live-minimal-v84:not(.dvr) .controls {
    gap: 8px !important;
    justify-content: space-around !important;
  }
  .ndp.nd-live-minimal-v84:not(.dvr) .controls .volume {
    width: min(130px, 30vw) !important;
  }
  .ndp.nd-live-minimal-v84:not(.dvr) .controls .nd-v84-archive {
    min-width: 78px !important;
    padding-left: 10px !important;
    padding-right: 10px !important;
  }
}
/* /v84 minimal LIVE controls */
'''
start = '/* v84 minimal LIVE controls:'
end = '/* /v84 minimal LIVE controls */'
if start in s and end in s:
    pattern = re.compile(re.escape(start) + r'.*?' + re.escape(end), re.S)
    s = pattern.sub(block.strip(), s)
else:
    s = s.rstrip() + block
path.write_text(s)
print('css patched:', path)
PY

python3 - "$EMBED_HTML" <<'PY'
import pathlib, sys, re
path = pathlib.Path(sys.argv[1])
s = path.read_text()
script = '<script src="/newdomofon-player/live-minimal-controls-v84.js?v=20260528-084"></script>'
# Remove old duplicate v84 script entries.
s = re.sub(r'\s*<script\s+src="/newdomofon-player/live-minimal-controls-v84\.js\?v=[^"]+"\s*>\s*</script>', '', s)
if '</body>' not in s:
    raise SystemExit('embed.html has no </body>')
s = s.replace('</body>', '  ' + script + '\n</body>', 1)
path.write_text(s)
print('embed patched:', path)
PY

echo
 echo "===== Result ====="
echo "installed: $V84_JS"
echo "backup:    $BACKUP"
echo
 echo "Check in browser iframe console:"
echo "  window.ND_LIVE_CONTROLS_V84"
echo "  document.querySelectorAll('.ndp:not(.dvr) .controls > *').length"
echo
 echo "Expected LIVE controls: Play/Pause, Stop, Volume, Archive."
echo "Expected DVR controls: unchanged."
