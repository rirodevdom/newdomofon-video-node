#!/usr/bin/env bash
set -Eeuo pipefail

# NewDomofon Video: v85 live archive date picker
#
# Goal:
#   Keep v84 minimal LIVE controls, but change the LIVE "Архив" button:
#     - it no longer jumps to DVR immediately;
#     - it opens a date/time range picker;
#     - after confirmation it uses the original player range controls:
#         .range-start, .range-end, [data-action="apply-range"]
#       so archive loading remains the same as before v84.
#
# Scope:
#   frontend player only. No backend/DVR/SmartYard changes.

PROJECT_DIR="${PROJECT_DIR:-/opt/newdomofon-video}"
WEB_ROOT="${WEB_ROOT:-/var/www/newdomofon-video}"
PLAYER_DIR="${PLAYER_DIR:-$WEB_ROOT/newdomofon-player}"
PLAYER_CSS="$PLAYER_DIR/player.css"
EMBED_HTML="$PLAYER_DIR/embed.html"
V85_JS="$PLAYER_DIR/live-archive-date-picker-v85.js"

[[ "$(id -u)" -eq 0 ]] || { echo "Run as root with sudo." >&2; exit 1; }
command -v python3 >/dev/null || { echo "python3 not found" >&2; exit 1; }
command -v node >/dev/null || { echo "node not found" >&2; exit 1; }
[[ -d "$PLAYER_DIR" ]] || { echo "Player dir not found: $PLAYER_DIR" >&2; exit 1; }
[[ -f "$PLAYER_CSS" ]] || { echo "player.css not found: $PLAYER_CSS" >&2; exit 1; }
[[ -f "$EMBED_HTML" ]] || { echo "embed.html not found: $EMBED_HTML" >&2; exit 1; }

TS="$(date +%Y%m%d-%H%M%S)"
BACKUP="$PROJECT_DIR/backups/v85-live-archive-date-picker-$TS"
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
backup "$V85_JS"

cat > "$V85_JS" <<'JS'
(function () {
  'use strict';

  var VERSION = 'v85-live-archive-date-picker';
  var installed = false;
  var observer = null;

  function log() {
    var a = Array.prototype.slice.call(arguments);
    a.unshift('[NewDomofon archive-picker-v85]');
    console.info.apply(console, a);
  }

  function $(sel, root) {
    return (root || document).querySelector(sel);
  }

  function pad(n) {
    return String(n).padStart(2, '0');
  }

  function toLocalInput(ms) {
    var d = new Date(ms);
    if (!Number.isFinite(d.getTime())) return '';
    return d.getFullYear() + '-' + pad(d.getMonth() + 1) + '-' + pad(d.getDate()) +
      'T' + pad(d.getHours()) + ':' + pad(d.getMinutes());
  }

  function parseLocalInput(v) {
    if (!v) return NaN;
    var d = new Date(v);
    var t = d.getTime();
    return Number.isFinite(t) ? t : NaN;
  }

  function dispatchEdit(el) {
    if (!el) return;
    try { el.dispatchEvent(new Event('input', { bubbles: true })); } catch (_) {}
    try { el.dispatchEvent(new Event('change', { bubbles: true })); } catch (_) {}
  }

  function getOriginalRange(defaultHours) {
    var sEl = $('.range-start');
    var eEl = $('.range-end');
    var now = Date.now();
    var s = parseLocalInput(sEl && sEl.value);
    var e = parseLocalInput(eEl && eEl.value);

    if (!Number.isFinite(e)) e = now;
    if (!Number.isFinite(s) || s >= e) s = e - defaultHours * 3600000;

    return { start: s, end: e };
  }

  function ensurePicker() {
    var existing = $('.nd-v85-backdrop');
    if (existing) return existing;

    var wrap = document.createElement('div');
    wrap.className = 'nd-v85-backdrop';
    wrap.hidden = true;
    wrap.innerHTML = '' +
      '<div class="nd-v85-dialog" role="dialog" aria-modal="true" aria-label="Выбор архива">' +
        '<div class="nd-v85-head">' +
          '<div>' +
            '<div class="nd-v85-title">Выбор архива</div>' +
            '<div class="nd-v85-sub">Выберите дату и диапазон, затем загрузите архив</div>' +
          '</div>' +
          '<button type="button" class="nd-v85-x" data-v85-close aria-label="Закрыть">×</button>' +
        '</div>' +
        '<div class="nd-v85-grid">' +
          '<label class="nd-v85-field">Начало<input class="nd-v85-start" type="datetime-local"></label>' +
          '<label class="nd-v85-field">Конец<input class="nd-v85-end" type="datetime-local"></label>' +
        '</div>' +
        '<div class="nd-v85-presets">' +
          '<button type="button" class="btn" data-v85-preset="1h">Последний час</button>' +
          '<button type="button" class="btn" data-v85-preset="6h">6 часов</button>' +
          '<button type="button" class="btn" data-v85-preset="24h">24 часа</button>' +
        '</div>' +
        '<div class="nd-v85-actions">' +
          '<button type="button" class="btn" data-v85-close>Отмена</button>' +
          '<button type="button" class="btn primary" data-v85-apply>Загрузить архив</button>' +
        '</div>' +
      '</div>';

    document.body.appendChild(wrap);

    wrap.addEventListener('click', function (ev) {
      if (ev.target === wrap || ev.target.hasAttribute('data-v85-close')) {
        closePicker();
      }
    });

    wrap.querySelectorAll('[data-v85-preset]').forEach(function (btn) {
      btn.addEventListener('click', function () {
        var h = btn.getAttribute('data-v85-preset') === '24h' ? 24 :
          (btn.getAttribute('data-v85-preset') === '6h' ? 6 : 1);
        var endEl = $('.nd-v85-end', wrap);
        var end = parseLocalInput(endEl && endEl.value);
        if (!Number.isFinite(end)) end = Date.now();
        $('.nd-v85-start', wrap).value = toLocalInput(end - h * 3600000);
        $('.nd-v85-end', wrap).value = toLocalInput(end);
      });
    });

    $('[data-v85-apply]', wrap).addEventListener('click', applyPicker);

    document.addEventListener('keydown', function (ev) {
      if (!wrap.hidden && ev.key === 'Escape') closePicker();
    });

    return wrap;
  }

  function openPicker() {
    var wrap = ensurePicker();
    var r = getOriginalRange(1);
    $('.nd-v85-start', wrap).value = toLocalInput(r.start);
    $('.nd-v85-end', wrap).value = toLocalInput(r.end);
    wrap.hidden = false;
    wrap.classList.add('show');
    document.documentElement.classList.add('nd-v85-modal-open');
    setTimeout(function () {
      var x = $('.nd-v85-start', wrap);
      if (x) x.focus();
    }, 0);
  }

  function closePicker() {
    var wrap = $('.nd-v85-backdrop');
    if (!wrap) return;
    wrap.classList.remove('show');
    wrap.hidden = true;
    document.documentElement.classList.remove('nd-v85-modal-open');
  }

  function applyPicker() {
    var wrap = $('.nd-v85-backdrop');
    if (!wrap) return;

    var startInput = $('.nd-v85-start', wrap);
    var endInput = $('.nd-v85-end', wrap);
    var s = parseLocalInput(startInput && startInput.value);
    var e = parseLocalInput(endInput && endInput.value);

    if (!Number.isFinite(s) || !Number.isFinite(e) || e <= s) {
      var title = $('.nd-v85-title', wrap);
      if (title) {
        title.textContent = 'Некорректный диапазон';
        setTimeout(function () { title.textContent = 'Выбор архива'; }, 1800);
      }
      return;
    }

    var originalStart = $('.range-start');
    var originalEnd = $('.range-end');
    var apply = $('[data-action="apply-range"]');

    if (originalStart) {
      originalStart.value = startInput.value;
      dispatchEdit(originalStart);
    }
    if (originalEnd) {
      originalEnd.value = endInput.value;
      dispatchEdit(originalEnd);
    }

    closePicker();

    if (apply) {
      apply.click();
      return;
    }

    var dvr = $('[data-proto="dvr"]');
    if (dvr) dvr.click();
  }

  function bindCapture() {
    if (installed) return;
    installed = true;

    document.addEventListener('click', function (ev) {
      var btn = ev.target && ev.target.closest && ev.target.closest('.nd-v84-archive');
      if (!btn) return;
      ev.preventDefault();
      ev.stopPropagation();
      if (typeof ev.stopImmediatePropagation === 'function') ev.stopImmediatePropagation();
      openPicker();
    }, true);

    log(VERSION + ' installed');
  }

  function markArchiveButton() {
    var btn = $('.nd-v84-archive');
    if (btn) {
      btn.textContent = 'Архив';
      btn.title = 'Выбрать дату архива';
      btn.setAttribute('aria-label', 'Выбрать дату архива');
    }
  }

  function start() {
    bindCapture();
    ensurePicker();
    markArchiveButton();
    if (!observer) {
      observer = new MutationObserver(markArchiveButton);
      observer.observe(document.documentElement, { childList: true, subtree: true });
    }
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', start, { once: true });
  } else {
    start();
  }

  window.ND_ARCHIVE_PICKER_V85 = {
    version: VERSION,
    open: openPicker,
    close: closePicker,
    apply: applyPicker
  };
})();
JS

node --check "$V85_JS"

python3 - "$PLAYER_CSS" <<'PY'
import pathlib, sys, re
path = pathlib.Path(sys.argv[1])
s = path.read_text()
block = r'''

/* v85 LIVE archive date picker. Works on top of v84 minimal controls. */
.nd-v85-backdrop {
  position: fixed !important;
  inset: 0 !important;
  z-index: 2147483000 !important;
  display: flex !important;
  align-items: center !important;
  justify-content: center !important;
  padding: 18px !important;
  background: rgba(0,0,0,.62) !important;
  backdrop-filter: blur(4px) !important;
}
.nd-v85-backdrop[hidden] {
  display: none !important;
}
.nd-v85-dialog {
  width: min(560px, 96vw) !important;
  color: #eef4ff !important;
  background: #111827 !important;
  border: 1px solid rgba(148,163,184,.35) !important;
  border-radius: 18px !important;
  box-shadow: 0 22px 80px rgba(0,0,0,.45) !important;
  padding: 16px !important;
}
.nd-v85-head {
  display: flex !important;
  align-items: flex-start !important;
  justify-content: space-between !important;
  gap: 12px !important;
  margin-bottom: 14px !important;
}
.nd-v85-title {
  font-size: 18px !important;
  font-weight: 900 !important;
  line-height: 1.2 !important;
}
.nd-v85-sub {
  margin-top: 4px !important;
  color: #aab7cf !important;
  font-size: 13px !important;
}
.nd-v85-x {
  width: 38px !important;
  height: 38px !important;
  border: 0 !important;
  border-radius: 12px !important;
  color: #eef4ff !important;
  background: rgba(255,255,255,.08) !important;
  font-size: 24px !important;
  line-height: 1 !important;
  cursor: pointer !important;
}
.nd-v85-grid {
  display: grid !important;
  grid-template-columns: 1fr 1fr !important;
  gap: 12px !important;
  margin-bottom: 12px !important;
}
.nd-v85-field {
  display: grid !important;
  gap: 6px !important;
  color: #cbd5e1 !important;
  font-size: 13px !important;
  font-weight: 700 !important;
}
.nd-v85-field input {
  width: 100% !important;
  box-sizing: border-box !important;
  border: 1px solid rgba(148,163,184,.35) !important;
  border-radius: 12px !important;
  color: #eef4ff !important;
  background: #0b1220 !important;
  padding: 10px 12px !important;
  font: inherit !important;
}
.nd-v85-presets,
.nd-v85-actions {
  display: flex !important;
  flex-wrap: wrap !important;
  gap: 8px !important;
}
.nd-v85-presets {
  margin: 6px 0 14px !important;
}
.nd-v85-actions {
  justify-content: flex-end !important;
}
.nd-v85-actions .primary {
  min-width: 150px !important;
}
@media(max-width: 640px) {
  .nd-v85-dialog {
    padding: 14px !important;
  }
  .nd-v85-grid {
    grid-template-columns: 1fr !important;
  }
  .nd-v85-actions {
    justify-content: stretch !important;
  }
  .nd-v85-actions .btn {
    flex: 1 1 auto !important;
  }
}
/* /v85 LIVE archive date picker */
'''
start = '/* v85 LIVE archive date picker.'
end = '/* /v85 LIVE archive date picker */'
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
script = '<script src="/newdomofon-player/live-archive-date-picker-v85.js?v=20260528-085"></script>'
# Remove old duplicate v85 script entries.
s = re.sub(r'\s*<script\s+src="/newdomofon-player/live-archive-date-picker-v85\.js\?v=[^"]+"\s*>\s*</script>', '', s)
if '</body>' not in s:
    raise SystemExit('embed.html has no </body>')
s = s.replace('</body>', '  ' + script + '\n</body>', 1)
path.write_text(s)
print('embed patched:', path)
PY

echo
echo "===== Result ====="
echo "installed: $V85_JS"
echo "backup:    $BACKUP"
echo
echo "Check in browser iframe console:"
echo "  window.ND_ARCHIVE_PICKER_V85"
echo "  window.ND_ARCHIVE_PICKER_V85.open()"
echo
echo "Expected LIVE behavior: Play, Stop, Volume, Archive. Archive opens date/time range picker first."
echo "Expected DVR behavior: after selecting dates and clicking 'Загрузить архив', original archive UI loads selected range."
