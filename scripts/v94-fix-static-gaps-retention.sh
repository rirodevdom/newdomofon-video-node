#!/usr/bin/env bash
set -Eeuo pipefail

# NewDomofon Video: v94 fix false-full red gaps + keep event retention
# Scope:
#   - fix v93 coverage parsing when backend returns Flussonic-like ranges {from,duration};
#   - do not paint the whole timeline red when coverage format is unknown/empty;
#   - keep red gaps static: load once, render from cache during pan/zoom;
#   - keep archive events list hidden, but preserve timeline event dots;
#   - verify/enable events retention timer if v93 installed it.

VERSION="v94-fix-static-gaps-retention"
PROJECT_DIR="${PROJECT_DIR:-/opt/newdomofon-video}"
WEB_ROOT="${WEB_ROOT:-/var/www/newdomofon-video}"
PLAYER_DIR="${PLAYER_DIR:-$WEB_ROOT/newdomofon-player}"
PLAYER_JS="$PLAYER_DIR/player.js"
PLAYER_CSS="$PLAYER_DIR/player.css"
EMBED_HTML="$PLAYER_DIR/embed.html"
V94_JS="$PLAYER_DIR/player-stability-v94.js"
EVENTS_V81_JS="$PLAYER_DIR/events-overlay-v81.js"

RETENTION_JS="$PROJECT_DIR/scripts/events-retention-cleanup.js"
RETENTION_SERVICE="/etc/systemd/system/newdomofon-events-retention.service"
RETENTION_TIMER="/etc/systemd/system/newdomofon-events-retention.timer"
RETENTION_FALLBACK_DAYS="${EVENTS_RETENTION_FALLBACK_DAYS:-7}"
RETENTION_BATCH="${EVENTS_RETENTION_BATCH:-50000}"

TS="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="$PROJECT_DIR/backups/${VERSION}-${TS}"

require_file() {
  if [[ ! -f "$1" ]]; then
    echo "ERROR: required file not found: $1" >&2
    exit 1
  fi
}

backup_file() {
  local f="$1"
  [[ -e "$f" ]] || return 0
  local rel="${f#/}"
  mkdir -p "$BACKUP_DIR/$(dirname "$rel")"
  cp -a "$f" "$BACKUP_DIR/$rel"
  echo "backup: $f"
}

[[ "$(id -u)" -eq 0 ]] || { echo "Run as root with sudo." >&2; exit 1; }
command -v python3 >/dev/null || { echo "python3 not found" >&2; exit 1; }
command -v node >/dev/null || { echo "node not found" >&2; exit 1; }

require_file "$PLAYER_JS"
require_file "$PLAYER_CSS"
require_file "$EMBED_HTML"
mkdir -p "$BACKUP_DIR"

printf '===== Backup =====\n'
backup_file "$PLAYER_JS"
backup_file "$PLAYER_CSS"
backup_file "$EMBED_HTML"
backup_file "$V94_JS"
backup_file "$PLAYER_DIR/player-stability-v93.js"
backup_file "$PLAYER_DIR/player-stability-v92.js"
backup_file "$RETENTION_JS"
backup_file "$RETENTION_SERVICE"
backup_file "$RETENTION_TIMER"

printf '\n===== Patch event overlay wide limit if present =====\n'
if [[ -f "$EVENTS_V81_JS" ]]; then
  backup_file "$EVENTS_V81_JS"
  python3 - "$EVENTS_V81_JS" <<'PY'
import pathlib, re, sys
p = pathlib.Path(sys.argv[1])
s = p.read_text()
orig = s
s = re.sub(r'visibleLimit:\s*\d+', 'visibleLimit: 20000', s, count=1)
s = re.sub(r'maxWindowMs:\s*[^,\n]+', 'maxWindowMs: 31 * 24 * 3600000', s, count=1)
s = re.sub(r"\+\s*'&limit=\d+'", "+ '&limit=20000'", s)
if '&limit=20000' not in s:
    s = s.replace("'&stream=' + encodeURIComponent(streamName())", "'&stream=' + encodeURIComponent(streamName()) + '&limit=20000'")
p.write_text(s)
print('changed:', s != orig)
print('limit_20000:', '20000' in s)
PY
  node --check "$EVENTS_V81_JS"
else
  echo "skip: events overlay not found: $EVENTS_V81_JS"
fi

printf '\n===== Write v94 stable static gaps layer =====\n'
cat > "$V94_JS" <<'JS'
(function () {
  'use strict';

  var VERSION = 'v94-fix-static-gaps-retention';
  if (window.__ND_PLAYER_STABILITY_V94_INSTALLED__) return;
  window.__ND_PLAYER_STABILITY_V94_INSTALLED__ = true;

  var state = {
    coverageLoaded: false,
    coverageLoading: false,
    coverageError: '',
    coverageSource: '',
    coverageRawShape: '',
    ranges: [],
    gaps: [],
    knownEmptyArchive: false,
    renderRaf: 0,
    hiddenPanels: 0,
    lastGapCount: 0,
    lastRender: ''
  };

  function $(sel, root) { return (root || document).querySelector(sel); }
  function $all(sel, root) { return Array.from((root || document).querySelectorAll(sel)); }
  function clamp(v, a, b) { return Math.min(b, Math.max(a, v)); }
  function enc(v) { return encodeURIComponent(String(v == null ? '' : v)); }
  function qs() { try { return new URLSearchParams(location.search || ''); } catch (_) { return new URLSearchParams(); } }
  function token() { return qs().get('token') || ''; }
  function addToken(path) {
    var u = new URL(path, location.origin);
    if (token() && !u.searchParams.get('token')) u.searchParams.set('token', token());
    return u.pathname + u.search;
  }
  function parts() { return String(location.pathname || '').split('/').filter(Boolean); }
  function streamName() {
    var p = parts();
    var i = p.indexOf('embed.html');
    if (i > 0) return decodeURIComponent(p[i - 1]);
    if (p.length >= 2 && p[p.length - 1] === 'embed.html') return decodeURIComponent(p[p.length - 2]);
    return qs().get('stream') || '';
  }
  function parseMs(v) { var t = Date.parse(v || ''); return Number.isFinite(t) ? t : NaN; }
  function epochMs(v) {
    var n = Number(v);
    if (!Number.isFinite(n) || n <= 0) return NaN;
    return n > 1000000000000 ? n : n * 1000;
  }
  function durationMs(v) {
    var n = Number(v);
    if (!Number.isFinite(n) || n <= 0) return NaN;
    return n > 86400000 ? n : n * 1000;
  }

  function timelineWindow() {
    var nt = window.ND_PLAYER_TIMELINE;
    if (nt && Number.isFinite(Number(nt.ws)) && Number.isFinite(Number(nt.we)) && Number(nt.we) > Number(nt.ws)) {
      return { start: Number(nt.ws), end: Number(nt.we), cursor: Number(nt.cursor), mode: nt.mode || '', source: 'ND_PLAYER_TIMELINE' };
    }
    var bar = $('.bar');
    if (bar && bar.dataset) {
      var a = Number(bar.dataset.ndWindowStartMs);
      var b = Number(bar.dataset.ndWindowEndMs);
      if (Number.isFinite(a) && Number.isFinite(b) && b > a) return { start: a, end: b, cursor: Number(bar.dataset.ndCursorMs), mode: bar.dataset.ndMode || '', source: 'bar-dataset' };
    }
    var s = parseMs($('.range-start') && $('.range-start').value);
    var e = parseMs($('.range-end') && $('.range-end').value);
    if (Number.isFinite(s) && Number.isFinite(e) && e > s) return { start: s, end: e, cursor: NaN, mode: '', source: 'inputs' };
    var n = Date.now();
    return { start: n - 3600000, end: n, cursor: n, mode: '', source: 'fallback' };
  }

  function intervalFromItem(x) {
    if (!x || typeof x !== 'object') return null;
    var start = NaN;
    var end = NaN;

    if (x.start_iso || x.from_iso) start = parseMs(x.start_iso || x.from_iso);
    if (x.end_iso || x.to_iso) end = parseMs(x.end_iso || x.to_iso);

    if (!Number.isFinite(start)) {
      if (x.start != null) start = epochMs(x.start);
      else if (x.from != null) start = epochMs(x.from);
      else if (x.ms != null) start = epochMs(x.ms);
      else if (x.time != null) start = epochMs(x.time);
    }

    if (!Number.isFinite(end)) {
      if (x.end != null) end = epochMs(x.end);
      else if (x.to != null) end = epochMs(x.to);
    }

    // Flussonic/SmartYard-compatible shape: { from: unix_seconds, duration: seconds }
    if (Number.isFinite(start) && !Number.isFinite(end) && x.duration != null) {
      var d = durationMs(x.duration);
      if (Number.isFinite(d)) end = start + d;
    }

    // Some backends use len/duration_ms.
    if (Number.isFinite(start) && !Number.isFinite(end) && x.duration_ms != null) {
      var dm = Number(x.duration_ms);
      if (Number.isFinite(dm) && dm > 0) end = start + dm;
    }

    if (!Number.isFinite(start) || !Number.isFinite(end) || end <= start) return null;
    return { start: start, end: end };
  }

  function normalizeIntervals(items) {
    var arr = Array.isArray(items) ? items : [];
    return arr.map(intervalFromItem).filter(Boolean).sort(function (a, b) { return a.start - b.start || a.end - b.end; });
  }

  function mergeIntervals(items) {
    var sorted = normalizeIntervals(items);
    var out = [];
    sorted.forEach(function (r) {
      if (!out.length || r.start > out[out.length - 1].end + 12000) out.push({ start: r.start, end: r.end });
      else out[out.length - 1].end = Math.max(out[out.length - 1].end, r.end);
    });
    return out;
  }

  function extractRanges(data) {
    state.coverageRawShape = Object.prototype.toString.call(data);

    // recording_status.json often returns: [{ stream, ranges: [{ from, duration }] }]
    if (Array.isArray(data)) {
      var combined = [];
      data.forEach(function (item) {
        if (item && Array.isArray(item.ranges)) combined = combined.concat(item.ranges);
        else if (item && typeof item === 'object') combined.push(item);
      });
      return combined;
    }

    if (!data || typeof data !== 'object') return [];

    if (Array.isArray(data.ranges)) return data.ranges;
    if (Array.isArray(data.coverage)) return data.coverage;
    if (Array.isArray(data.segments)) return data.segments;

    // Last-resort from/to object.
    if ((data.from != null || data.from_iso) && (data.to != null || data.to_iso || data.duration != null)) return [data];

    return [];
  }

  function applyCoverage(data, url) {
    var rawRanges = extractRanges(data || {});
    var ranges = mergeIntervals(rawRanges);

    state.ranges = ranges;
    state.gaps = normalizeIntervals((data && data.gaps) || []);
    state.coverageSource = url;
    state.coverageError = '';
    state.coverageLoaded = true;

    var segCount = data && Number(data.segments);
    var explicitEmpty = data && (data.recording === false || data.dvr === false || segCount === 0);
    state.knownEmptyArchive = ranges.length === 0 && Boolean(explicitEmpty);

    // Critical v94 guard: unknown/unsupported coverage format must not paint the whole timeline red.
    if (!ranges.length && !state.knownEmptyArchive) {
      state.coverageLoaded = false;
      state.coverageError = 'coverage has no usable ranges; raw shape=' + state.coverageRawShape;
    }
  }

  function missingInsideWindow(winStart, winEnd) {
    if (state.knownEmptyArchive) return [{ start: winStart, end: winEnd }];
    var ranges = mergeIntervals(state.ranges);
    if (!ranges.length) return [];

    var gaps = [];
    var cursor = winStart;
    var minGap = 12000;

    ranges.forEach(function (r) {
      if (r.end <= winStart || r.start >= winEnd) return;
      var s = Math.max(r.start, winStart);
      var e = Math.min(r.end, winEnd);
      if (s > cursor + minGap) gaps.push({ start: cursor, end: s });
      if (e > cursor) cursor = e;
    });

    if (cursor < winEnd - minGap) gaps.push({ start: cursor, end: winEnd });
    return gaps;
  }

  function hardHideArchiveEventsPanel() {
    var hidden = 0;
    var selectors = [
      'aside.events',
      '.main > .events',
      '.stage + .events',
      '[data-nd-v93-hidden-events-panel]',
      '[data-nd-v94-hidden-events-panel]'
    ];

    selectors.forEach(function (sel) {
      $all(sel).forEach(function (el) {
        if (!el || el.closest('.timeline, .bar, #nd-events-v81-layer, #nd-events-v80-layer, #nd-events-v79-layer')) return;
        el.setAttribute('data-nd-v94-hidden-events-panel', '1');
        el.setAttribute('hidden', 'hidden');
        el.style.setProperty('display', 'none', 'important');
        el.style.setProperty('visibility', 'hidden', 'important');
        el.style.setProperty('width', '0', 'important');
        el.style.setProperty('min-width', '0', 'important');
        el.style.setProperty('max-width', '0', 'important');
        el.style.setProperty('flex', '0 0 0', 'important');
        hidden++;
      });
    });

    $all('body *').forEach(function (el) {
      if (!el || el.nodeType !== 1 || el.hasAttribute('data-nd-v94-hidden-events-panel')) return;
      if (el.closest('.timeline, .bar, .controls, .range-panel, video, #nd-events-v81-layer, #nd-events-v80-layer, #nd-events-v79-layer')) return;
      var txt = String(el.innerText || el.textContent || '').replace(/\s+/g, ' ').trim();
      if (!txt) return;
      var signature = (/События\s+архива/i.test(txt) || /\bEvents\b/i.test(txt)) && /(CellMotionDetector|RuleEngine|Motion\/IsMotion|tns1:|События\s+архива)/i.test(txt);
      if (!signature) return;
      var candidate = el.closest('aside') || el.closest('.events') || el;
      if (!candidate || candidate.closest('.timeline, .bar')) return;
      var r = candidate.getBoundingClientRect ? candidate.getBoundingClientRect() : { width: 0, height: 0 };
      if (r.width > 120 && r.height > 80) {
        candidate.setAttribute('data-nd-v94-hidden-events-panel', '1');
        candidate.setAttribute('hidden', 'hidden');
        candidate.style.setProperty('display', 'none', 'important');
        candidate.style.setProperty('visibility', 'hidden', 'important');
        candidate.style.setProperty('width', '0', 'important');
        candidate.style.setProperty('min-width', '0', 'important');
        candidate.style.setProperty('max-width', '0', 'important');
        hidden++;
      }
    });

    var main = $('.main');
    if (main) main.classList.add('nd-v94-main-no-events-panel');
    state.hiddenPanels = hidden;
    return hidden;
  }

  function ensureGapsLayer() {
    var bar = $('.bar');
    if (!bar) return null;
    ['#nd-v93-archive-gaps', '#nd-v92-archive-gaps', '#nd-v89-archive-gaps', '#nd-v88-archive-gaps', '#nd-v87-archive-gaps'].forEach(function (sel) {
      var old = $(sel);
      if (old && old.parentElement) old.parentElement.removeChild(old);
    });
    var layer = $('#nd-v94-archive-gaps');
    if (layer && layer.parentElement === bar) return layer;
    if (layer && layer.parentElement) layer.parentElement.removeChild(layer);
    layer = document.createElement('div');
    layer.id = 'nd-v94-archive-gaps';
    layer.className = 'nd-v94-archive-gaps';
    bar.insertBefore(layer, bar.firstChild || null);
    return layer;
  }

  function drawStaticGaps() {
    var layer = ensureGapsLayer();
    if (!layer) return;
    var w = timelineWindow();
    if (!state.coverageLoaded && !state.knownEmptyArchive) {
      layer.innerHTML = '';
      layer.dataset.state = state.coverageLoading ? 'loading' : 'unknown';
      state.lastGapCount = 0;
      return;
    }

    var span = Math.max(1, w.end - w.start);
    var gaps = missingInsideWindow(w.start, w.end);
    state.lastGapCount = gaps.length;
    var html = [];
    gaps.forEach(function (g) {
      var s = Math.max(g.start, w.start);
      var e = Math.min(g.end, w.end);
      if (e <= s || e - s < 12000) return;
      var l = (s - w.start) / span * 100;
      var r = (e - w.start) / span * 100;
      var left = clamp(l, 0, 100);
      var width = clamp(r - l, 0, 100 - left);
      if (width <= 0.01) return;
      var title = 'Архив отсутствует: ' + new Date(s).toLocaleString('ru-RU') + ' — ' + new Date(e).toLocaleString('ru-RU');
      html.push('<span class="nd-v94-gap" style="left:' + left.toFixed(4) + '%;width:' + width.toFixed(4) + '%" title="' + title.replace(/"/g, '&quot;') + '"></span>');
    });
    layer.innerHTML = html.join('');
    layer.dataset.state = 'static';
  }

  function fixRulerLabels() {
    var w = timelineWindow();
    var span = Math.max(1, w.end - w.start);
    if (span < 18 * 3600000) return;
    $all('.ruler .tick-label').forEach(function (el) {
      var left = parseFloat((el.style && el.style.left) || '');
      if (!Number.isFinite(left)) return;
      var ms = w.start + span * clamp(left / 100, 0, 1);
      var d = new Date(ms);
      if (!Number.isFinite(d.getTime())) return;
      var dd = String(d.getDate()).padStart(2, '0');
      var mm = String(d.getMonth() + 1).padStart(2, '0');
      var hh = String(d.getHours()).padStart(2, '0');
      var mi = String(d.getMinutes()).padStart(2, '0');
      if (span >= 3 * 86400000) el.textContent = dd + '.' + mm;
      else if (d.getHours() === 0 && d.getMinutes() === 0) el.textContent = dd + '.' + mm;
      else el.textContent = hh + ':' + mi;
    });
  }

  async function loadCoverage(force) {
    if (state.coverageLoading) return;
    if (state.coverageLoaded && !force) return;
    state.coverageLoading = true;
    state.coverageError = '';
    state.knownEmptyArchive = false;
    var stream = streamName();
    var urls = [
      addToken('/dvr-archive/' + enc(stream) + '/coverage.json'),
      addToken('/' + enc(stream) + '/coverage.json'),
      addToken('/dvr-archive/' + enc(stream) + '/ranges.json'),
      addToken('/dvr-archive/' + enc(stream) + '/recording_status.json'),
      addToken('/' + enc(stream) + '/recording_status.json')
    ];
    var errors = [];
    try {
      for (var i = 0; i < urls.length; i += 1) {
        var url = urls[i];
        try {
          var res = await fetch(url, { cache: 'no-store' });
          if (!res.ok) throw new Error('HTTP ' + res.status);
          var data = await res.json();
          applyCoverage(data || {}, url);
          if (state.coverageLoaded || state.knownEmptyArchive) {
            render('coverage-loaded');
            return;
          }
          errors.push(url + ': ' + state.coverageError);
        } catch (e) {
          errors.push(url + ': ' + String(e && (e.message || e) || e));
        }
      }
      throw new Error(errors.join(' | '));
    } catch (e) {
      state.coverageLoaded = false;
      state.knownEmptyArchive = false;
      state.ranges = [];
      state.coverageError = String(e && (e.message || e) || 'unknown');
      render('coverage-error');
    } finally {
      state.coverageLoading = false;
    }
  }

  function render(reason) {
    state.lastRender = reason || '';
    if (state.renderRaf) return;
    state.renderRaf = (window.requestAnimationFrame || window.setTimeout)(function () {
      state.renderRaf = 0;
      document.documentElement.classList.add('nd-v94-installed');
      var root = $('.ndp');
      if (root) root.classList.add('nd-v94-hide-events-panel');
      hardHideArchiveEventsPanel();
      fixRulerLabels();
      drawStaticGaps();
    }, 16);
  }

  function install() {
    document.documentElement.classList.add('nd-v94-installed');
    render('boot');
    loadCoverage(false);
    window.addEventListener('nd-player-timeline-change', function () { render('timeline-change'); }, { passive: true });
    window.addEventListener('resize', function () { render('resize'); }, { passive: true });
    ['click', 'input', 'change', 'wheel', 'pointermove', 'pointerup'].forEach(function (type) {
      document.addEventListener(type, function () { render(type); }, { capture: true, passive: type === 'wheel' });
    });
    try { new MutationObserver(function () { render('mutation'); }).observe(document.documentElement, { childList: true, subtree: true }); } catch (_) {}
    setInterval(function () { hardHideArchiveEventsPanel(); render('watchdog'); }, 1000);
    console.info('[NewDomofon v94]', VERSION + ' installed');
  }

  window.ND_PLAYER_STABILITY_V94 = {
    version: VERSION,
    state: state,
    timelineWindow: timelineWindow,
    hideArchiveEventsPanel: hardHideArchiveEventsPanel,
    loadCoverage: function () { return loadCoverage(true); },
    render: function () { return render('manual'); },
    missingInsideWindow: function () { var w = timelineWindow(); return missingInsideWindow(w.start, w.end); },
    normalizeIntervals: normalizeIntervals,
    intervalFromItem: intervalFromItem
  };

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', install, { once: true });
  else install();
})();
JS
chown root:root "$V94_JS"
chmod 0644 "$V94_JS"
node --check "$V94_JS"

printf '\n===== Patch CSS =====\n'
python3 - "$PLAYER_CSS" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
s = p.read_text()
block = r'''

/* v94: static archive gaps, no false full-red on unsupported coverage; hide archive event list only */
html.nd-v94-installed aside.events,
html.nd-v94-installed .main > .events,
html.nd-v94-installed .stage + .events,
.ndp.nd-v94-hide-events-panel aside.events,
.ndp.nd-v94-hide-events-panel .main > .events,
.ndp.nd-v94-hide-events-panel .stage + .events,
[data-nd-v94-hidden-events-panel="1"] {
  display: none !important;
  visibility: hidden !important;
  width: 0 !important;
  min-width: 0 !important;
  max-width: 0 !important;
  flex: 0 0 0 !important;
  overflow: hidden !important;
}
html.nd-v94-installed .main,
.ndp.nd-v94-hide-events-panel .main,
.nd-v94-main-no-events-panel {
  grid-template-columns: minmax(0, 1fr) !important;
}
html.nd-v94-installed .stage,
.ndp.nd-v94-hide-events-panel .stage {
  grid-column: 1 / -1 !important;
}
.bar { position: relative; }
#nd-v94-archive-gaps.nd-v94-archive-gaps {
  position: absolute;
  inset: 0;
  z-index: 7;
  pointer-events: none;
  contain: layout paint;
}
#nd-v94-archive-gaps .nd-v94-gap {
  position: absolute;
  top: 0;
  bottom: 0;
  background: repeating-linear-gradient(135deg, rgba(239,68,68,.42) 0 6px, rgba(127,29,29,.42) 6px 12px) !important;
  border-left: 1px solid rgba(248,113,113,.75);
  border-right: 1px solid rgba(248,113,113,.55);
}
#nd-v93-archive-gaps,
#nd-v92-archive-gaps,
#nd-v89-archive-gaps,
#nd-v88-archive-gaps,
#nd-v87-archive-gaps {
  display: none !important;
}
'''
if 'v94: static archive gaps' not in s:
    s += block
p.write_text(s)
print('css_has_v94:', 'v94: static archive gaps' in s)
PY

printf '\n===== Patch embed.html script order =====\n'
python3 - "$EMBED_HTML" "$TS" <<'PY'
import pathlib, re, sys
p = pathlib.Path(sys.argv[1])
ts = sys.argv[2]
s = p.read_text()
orig = s
for name in [
    'player-stability-v92.js',
    'player-stability-v93.js',
    'player-stability-v94.js',
    'hide-archive-events-list-v91.js',
    'hide-archive-events-list-v91.1.js',
]:
    s = re.sub(r'\s*<script\s+src="/newdomofon-player/' + re.escape(name) + r'(?:\?v=[^"]*)?"></script>\s*', '\n', s, flags=re.I)
tag = f'<script src="/newdomofon-player/player-stability-v94.js?v={ts}"></script>'
if re.search(r'</body>', s, re.I):
    s = re.sub(r'</body>', '  ' + tag + '\n</body>', s, count=1, flags=re.I)
else:
    s += '\n' + tag + '\n'
s = re.sub(r'\n{3,}', '\n\n', s)
p.write_text(s)
print('changed:', s != orig)
print('has_v94:', 'player-stability-v94.js' in s)
print('has_v93:', 'player-stability-v93.js' in s)
PY

printf '\n===== Ensure events retention timer if script exists =====\n'
if [[ -f "$RETENTION_JS" ]]; then
  node --check "$RETENTION_JS"
  if [[ ! -f "$RETENTION_SERVICE" ]]; then
    cat > "$RETENTION_SERVICE" <<EOF2
[Unit]
Description=NewDomofon camera events retention cleanup
After=network-online.target postgresql.service
Wants=network-online.target

[Service]
Type=oneshot
Environment=PROJECT_DIR=$PROJECT_DIR
Environment=EVENTS_RETENTION_FALLBACK_DAYS=$RETENTION_FALLBACK_DAYS
Environment=EVENTS_RETENTION_BATCH=$RETENTION_BATCH
EnvironmentFile=-/etc/newdomofon-video/app.env
WorkingDirectory=$PROJECT_DIR
ExecStart=/usr/bin/node $RETENTION_JS
Nice=10
IOSchedulingClass=best-effort
IOSchedulingPriority=7
EOF2
  fi
  if [[ ! -f "$RETENTION_TIMER" ]]; then
    cat > "$RETENTION_TIMER" <<'EOF2'
[Unit]
Description=Run NewDomofon camera events retention cleanup hourly

[Timer]
OnBootSec=10min
OnUnitActiveSec=1h
AccuracySec=5min
Persistent=true

[Install]
WantedBy=timers.target
EOF2
  fi
  systemctl daemon-reload
  systemctl enable --now newdomofon-events-retention.timer >/dev/null || true
  echo "retention timer enabled: newdomofon-events-retention.timer"
else
  echo "WARNING: retention script not found: $RETENTION_JS"
  echo "         If v93 was not applied successfully, re-run v93 or ask for a standalone retention installer."
fi

printf '\n===== Final static checks =====\n'
node --check "$PLAYER_JS"
node --check "$V94_JS"
[[ -f "$EVENTS_V81_JS" ]] && node --check "$EVENTS_V81_JS" || true

printf '\ninstalled: %s\n' "$V94_JS"
printf 'backup:    %s\n\n' "$BACKUP_DIR"
cat <<'OUT'
Browser iframe console checks:
  window.ND_PLAYER_STABILITY_V94
  window.ND_PLAYER_STABILITY_V94.state
  window.ND_PLAYER_STABILITY_V94.loadCoverage()
  window.ND_PLAYER_STABILITY_V94.missingInsideWindow()

Coverage diagnostics:
  curl -k 'https://new-video.domofon-37.ru/dvr-archive/cam_10_130_1_219/coverage.json?token=<token>' | head -c 2000
  curl -k 'https://new-video.domofon-37.ru/cam_10_130_1_219/recording_status.json?token=<token>' | head -c 2000

Expected:
  - no full red overlay when archive coverage exists;
  - red appears only outside loaded coverage ranges or inside real gaps;
  - if coverage format is unsupported, red layer is hidden instead of painting everything;
  - Events / События архива panel remains hidden;
  - timeline event dots remain;
  - existing events retention timer remains active.
OUT
