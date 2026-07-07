#!/usr/bin/env bash
set -Eeuo pipefail

# NewDomofon Video: v89 player stability, no user-facing feature change
#
# Scope: embedded DVR player frontend only.
#
# Goals:
#   - keep the current visible functions/UI behavior that already exists after v81/v84/v85/v88;
#   - make timeline overlays deterministic and less jumpy;
#   - reduce duplicated/stale overlay state;
#   - stop archive gap rendering from using stale async fetch results;
#   - keep exact player timeline bridge for state.ws/state.we.
#
# Preserved features:
#   - live minimal controls from v84;
#   - archive date picker from v85;
#   - isolated event markers from v81;
#   - screenshot camera icon, selected MP4 download, thin events, linked events, archive gap layer from v88.

PROJECT_DIR="${PROJECT_DIR:-/opt/newdomofon-video}"
WEB_ROOT="${WEB_ROOT:-/var/www/newdomofon-video}"
PLAYER_DIR="${PLAYER_DIR:-$WEB_ROOT/newdomofon-player}"
PLAYER_JS="$PLAYER_DIR/player.js"
PLAYER_CSS="$PLAYER_DIR/player.css"
EMBED_HTML="$PLAYER_DIR/embed.html"
V89_JS="$PLAYER_DIR/player-stability-v89.js"
V87_JS="$PLAYER_DIR/player-ui-timeline-v87.js"
V88_JS="$PLAYER_DIR/player-ui-timeline-v88.js"

[[ "$(id -u)" -eq 0 ]] || { echo "Run as root with sudo." >&2; exit 1; }
command -v python3 >/dev/null || { echo "python3 not found" >&2; exit 1; }
command -v node >/dev/null || { echo "node not found" >&2; exit 1; }
[[ -d "$PLAYER_DIR" ]] || { echo "Player dir not found: $PLAYER_DIR" >&2; exit 1; }
[[ -f "$PLAYER_JS" ]] || { echo "player.js not found: $PLAYER_JS" >&2; exit 1; }
[[ -f "$PLAYER_CSS" ]] || { echo "player.css not found: $PLAYER_CSS" >&2; exit 1; }
[[ -f "$EMBED_HTML" ]] || { echo "embed.html not found: $EMBED_HTML" >&2; exit 1; }

TS="$(date +%Y%m%d-%H%M%S)"
BACKUP="$PROJECT_DIR/backups/v89-player-stability-no-feature-change-$TS"
mkdir -p "$BACKUP"

backup() {
  [[ -e "$1" ]] || return 0
  mkdir -p "$BACKUP/$(dirname "${1#/}")"
  cp -a "$1" "$BACKUP/${1#/}"
  echo "backup: $1"
}

echo "===== Backup ====="
backup "$EMBED_HTML"
backup "$PLAYER_JS"
backup "$PLAYER_CSS"
backup "$V87_JS"
backup "$V88_JS"
backup "$V89_JS"
backup "$PLAYER_DIR/events-overlay-v81.js"
backup "$PLAYER_DIR/live-minimal-controls-v84.js"
backup "$PLAYER_DIR/live-archive-date-picker-v85.js"

echo
echo "===== Syntax check before patch ====="
if ! node --check "$PLAYER_JS"; then
  echo "WARNING: player.js had syntax issues before v89 patch; v89 will try safe known repairs." >&2
fi

echo
echo "===== Ensure exact timeline bridge in player.js ====="
python3 - "$PLAYER_JS" <<'PY'
import pathlib, sys, re
path = pathlib.Path(sys.argv[1])
s = path.read_text()
orig = s
# Safe known repair from earlier patched player variants: duplicate async token.
s = re.sub(r'\basync\s+async\s+function\b', 'async function', s)

# v81 already inserts a bridge that publishes private state.ws/state.we.
# v89 only installs its own bridge if neither v81 nor v89 bridge exists.
if 'function ndPublishTimelineWindowV81()' not in s and 'function ndPublishTimelineWindowV89()' not in s:
    helper = """function ndPublishTimelineWindowV89(){try{var b=document.querySelector('.bar');var d={mode:state.mode,stream:state.stream,cameraId:state.cameraId,ws:Math.floor(state.ws),we:Math.floor(state.we),cursor:Math.floor(state.cursor),winDur:Math.floor(Math.max(1,state.we-state.ws)),updatedAt:Date.now()};if(b){b.dataset.ndWindowStartMs=String(d.ws);b.dataset.ndWindowEndMs=String(d.we);b.dataset.ndCursorMs=String(d.cursor);b.dataset.ndMode=String(d.mode||'');b.dataset.ndTimelineVersion='v89';}var k=[d.mode,d.ws,d.we,d.cursor].join(':');window.ND_PLAYER_TIMELINE=d;if(window.__ndTimelineV89Key!==k){window.__ndTimelineV89Key=k;try{window.dispatchEvent(new CustomEvent('nd-player-timeline-change',{detail:d}));}catch(_){}}}catch(_){}}"""
    marker = 'function uiTimeline(){'
    if marker not in s:
        raise SystemExit('Cannot patch player.js: function uiTimeline() marker not found')
    s = s.replace(marker, helper + marker, 1)

    old = 'renderRuler();renderOverview();renderSelection();renderEventDots()}'
    if old not in s:
        raise SystemExit('Cannot patch player.js: uiTimeline render tail not found')
    s = s.replace(old, 'ndPublishTimelineWindowV89();' + old, 1)

# If v81 bridge exists, add a small compatibility marker only once; do not alter behavior.
if 'window.ND_PLAYER_STABILITY_SOURCE' not in s:
    # Insert a harmless assignment near the top-level start so diagnostics can see the base file was audited.
    marker = "console.info('[NewDomofon player-v67] loadSeq self-cancel fixed; HLS.js preferred');"
    if marker in s:
        s = s.replace(marker, marker + "window.ND_PLAYER_STABILITY_SOURCE='v89-audited';", 1)

path.write_text(s)
print('changed:', s != orig)
print('has_v81_bridge:', 'function ndPublishTimelineWindowV81()' in s)
print('has_v89_bridge:', 'function ndPublishTimelineWindowV89()' in s)
print('has_timeline_object:', 'ND_PLAYER_TIMELINE' in s)
PY
node --check "$PLAYER_JS"

echo
echo "===== Write v89 stability layer ====="
cat > "$V89_JS" <<'JS'
(function () {
  'use strict';

  var VERSION = 'v89-player-stability-no-feature-change';

  // If browser cached duplicate script tags, do not double-install timers/listeners.
  if (window.__ND_PLAYER_STABILITY_V89_INSTALLED__) {
    try { console.info('[NewDomofon v89] already installed, skip duplicate'); } catch (_) {}
    return;
  }
  window.__ND_PLAYER_STABILITY_V89_INSTALLED__ = true;

  var CFG = {
    renderFrameMs: 16,
    quickDebounceMs: 180,
    settledDebounceMs: 900,
    wheelSettleMs: 1150,
    pollMs: 60000,
    minGapMs: 14000,
    mergeToleranceMs: 12000,
    cacheSlackMs: 1500,
    minPadMs: 15 * 60000,
    maxPadMs: 90 * 60000,
    maxFetchWindowMs: 7 * 24 * 3600000,
    eventPairGapMs: 10 * 60000,
    repairMs: 1500
  };

  var state = {
    renderRaf: 0,
    fetchTimer: 0,
    repairTimer: 0,
    pollTimer: 0,
    seq: 0,
    abort: null,
    gapCache: null,
    lastFetchKey: '',
    interactionDepth: 0,
    lastInteractionAt: 0,
    installedAt: Date.now(),
    lastRenderReason: '',
    lastFetchReason: '',
    lastError: '',
    stats: { renders: 0, fetches: 0, aborts: 0, staleIgnored: 0 }
  };

  function log() {
    var a = Array.prototype.slice.call(arguments);
    a.unshift('[NewDomofon v89]');
    console.info.apply(console, a);
  }

  function warn() {
    var a = Array.prototype.slice.call(arguments);
    a.unshift('[NewDomofon v89]');
    console.warn.apply(console, a);
  }

  function $(sel, root) { return (root || document).querySelector(sel); }
  function $all(sel, root) { return Array.from((root || document).querySelectorAll(sel)); }

  function qs() {
    try { return new URLSearchParams(location.search || ''); }
    catch (_) { return new URLSearchParams(); }
  }

  function token() { return qs().get('token') || ''; }
  function enc(v) { return encodeURIComponent(String(v == null ? '' : v)); }
  function clamp(v, a, b) { return Math.min(b, Math.max(a, v)); }
  function now() { return Date.now(); }
  function toIso(ms) { return new Date(ms).toISOString(); }

  function addToken(url) {
    var u = new URL(url, location.origin);
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

  function parseInput(v) {
    var t = Date.parse(v || '');
    return Number.isFinite(t) ? t : NaN;
  }

  function rootMode() {
    var root = $('.ndp');
    if (root && root.classList.contains('dvr')) return 'dvr';
    var pill = $('.pill.mode');
    var txt = pill ? String(pill.textContent || '').toLowerCase() : '';
    if (txt.indexOf('dvr') >= 0 || txt.indexOf('арх') >= 0) return 'dvr';
    if (txt.indexOf('live') >= 0) return 'live';
    return '';
  }

  function playerMode() {
    var nt = window.ND_PLAYER_TIMELINE;
    if (nt && nt.mode) return String(nt.mode || '');
    var bar = $('.bar');
    if (bar && bar.dataset && bar.dataset.ndMode) return String(bar.dataset.ndMode || '');
    return rootMode();
  }

  function candidateWindowFromBridge() {
    var nt = window.ND_PLAYER_TIMELINE;
    if (!nt) return null;
    return {
      start: Number(nt.ws),
      end: Number(nt.we),
      cursor: Number(nt.cursor),
      mode: String(nt.mode || ''),
      source: 'ND_PLAYER_TIMELINE',
      updatedAt: Number(nt.updatedAt || 0)
    };
  }

  function candidateWindowFromDataset() {
    var bar = $('.bar');
    if (!bar || !bar.dataset) return null;
    return {
      start: Number(bar.dataset.ndWindowStartMs),
      end: Number(bar.dataset.ndWindowEndMs),
      cursor: Number(bar.dataset.ndCursorMs),
      mode: String(bar.dataset.ndMode || ''),
      source: 'bar-dataset',
      updatedAt: 0
    };
  }

  function candidateWindowFromInputs() {
    var sIn = $('.range-start');
    var eIn = $('.range-end');
    if (!sIn || !eIn) return null;
    return {
      start: parseInput(sIn.value),
      end: parseInput(eIn.value),
      cursor: NaN,
      mode: playerMode(),
      source: 'range-inputs',
      updatedAt: 0
    };
  }

  function validWindow(w) {
    return Boolean(w && Number.isFinite(w.start) && Number.isFinite(w.end) && w.end > w.start && (w.end - w.start) >= 1000);
  }

  function timelineWindow() {
    var list = [candidateWindowFromBridge(), candidateWindowFromDataset(), candidateWindowFromInputs()];
    for (var i = 0; i < list.length; i++) {
      var w = list[i];
      if (validWindow(w)) {
        w.span = w.end - w.start;
        if (!w.mode) w.mode = playerMode();
        return w;
      }
    }
    var t = now();
    return { start: t - 3600000, end: t, cursor: t, mode: playerMode(), source: 'fallback', span: 3600000 };
  }

  function selectedWindow() {
    var w = timelineWindow();
    var sel = $('.selection.show') || $('.selection');
    if (sel) {
      var shown = sel.classList.contains('show') || Number(sel.offsetWidth || 0) > 0;
      var left = parseFloat(sel.style.left || '');
      var width = parseFloat(sel.style.width || '');
      if (shown && Number.isFinite(left) && Number.isFinite(width) && width > 0) {
        var a = w.start + (w.end - w.start) * clamp(left / 100, 0, 1);
        var b = w.start + (w.end - w.start) * clamp((left + width) / 100, 0, 1);
        if (b > a) return { start: a, end: b, source: 'selection' };
      }
    }
    var sIn = $('.range-start');
    var eIn = $('.range-end');
    var s = parseInput(sIn && sIn.value);
    var e = parseInput(eIn && eIn.value);
    if (Number.isFinite(s) && Number.isFinite(e) && e > s) return { start: s, end: e, source: 'range-inputs' };
    return w;
  }

  function exportUrl(win) {
    var s = Math.min(win.start, win.end);
    var e = Math.max(win.start, win.end);
    return addToken('/dvr-archive/' + enc(streamName()) + '/export.mp4?start=' + enc(toIso(s)) + '&end=' + enc(toIso(e)));
  }

  function status(text, timeout) {
    var el = $('.status') || $('.ndp-status');
    if (!el) return;
    el.textContent = text || '';
    if (text) el.classList.add('show'); else el.classList.remove('show');
    if (timeout) {
      clearTimeout(status._t);
      status._t = setTimeout(function () { status(''); }, timeout);
    }
  }

  function downloadSelected() {
    var win = selectedWindow();
    if (!validWindow(win)) {
      status('Выберите корректный диапазон для скачивания.', 3500);
      return;
    }
    if (win.end - win.start > 24 * 3600000) {
      status('Диапазон слишком большой. Уменьшите выбор перед скачиванием.', 5000);
      return;
    }
    status('Подготовка MP4 для скачивания...', 2500);
    window.open(exportUrl(win), '_blank', 'noopener,noreferrer');
  }

  function cameraSvg() {
    return '<svg class="nd-v89-camera" viewBox="0 0 24 24" aria-hidden="true" focusable="false">' +
      '<path d="M8.4 5.2 9.7 3.6c.28-.36.72-.56 1.18-.56h2.24c.46 0 .9.2 1.18.56l1.3 1.6h2.15A2.25 2.25 0 0 1 20 7.45v9.05A2.25 2.25 0 0 1 17.75 18.75H6.25A2.25 2.25 0 0 1 4 16.5V7.45A2.25 2.25 0 0 1 6.25 5.2H8.4Z" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linejoin="round"/>' +
      '<circle cx="12" cy="12" r="3.15" fill="none" stroke="currentColor" stroke-width="1.8"/>' +
      '<circle cx="17" cy="8.3" r=".8" fill="currentColor"/>' +
      '</svg>';
  }

  function patchControls() {
    var root = $('.ndp');
    if (root) {
      root.classList.add('nd-v89-ui');
      root.classList.remove('nd-v87-ui', 'nd-v88-ui');
    }

    ['[data-action="center"]', '[data-action="download"]'].forEach(function (sel) {
      var el = $(sel);
      if (!el) return;
      el.classList.add('nd-v89-hide');
      el.setAttribute('aria-hidden', 'true');
      el.tabIndex = -1;
    });

    var shot = $('[data-action="screenshot"]');
    if (shot && shot.getAttribute('data-v89-camera') !== '1') {
      shot.innerHTML = cameraSvg();
      shot.title = 'Сделать снимок';
      shot.setAttribute('aria-label', 'Сделать снимок');
      shot.setAttribute('data-v89-camera', '1');
    }

    var loadSel = $('[data-action="load-selection"]');
    if (loadSel) {
      loadSel.textContent = 'Скачать выбранное';
      loadSel.title = 'Скачать выбранный отрезок MP4';
      loadSel.setAttribute('aria-label', 'Скачать выбранный отрезок MP4');
      loadSel.classList.add('nd-v89-download-selection');
      loadSel.classList.remove('nd-v87-download-selection', 'nd-v88-download-selection');
    }
  }

  function removeSupersededLayers() {
    ['#nd-v87-archive-gaps', '#nd-v87-event-links', '#nd-v88-archive-gaps', '#nd-v88-event-links'].forEach(function (sel) {
      var el = $(sel);
      if (el && el.parentElement) el.parentElement.removeChild(el);
    });
  }

  function ensureBarLayer(id, cls, beforeEvents) {
    var bar = $('.bar');
    if (!bar) return null;
    var layer = $('#' + id);
    if (layer && layer.parentElement === bar) return layer;
    if (layer && layer.parentElement) layer.parentElement.removeChild(layer);
    layer = document.createElement('div');
    layer.id = id;
    layer.className = cls;
    if (beforeEvents) {
      var eventsLayer = $('#nd-events-v81-layer') || $('.event-band');
      if (eventsLayer && eventsLayer.parentElement === bar) bar.insertBefore(layer, eventsLayer);
      else bar.appendChild(layer);
    } else {
      bar.insertBefore(layer, bar.firstChild || null);
    }
    return layer;
  }

  function ensureGapsLayer() { return ensureBarLayer('nd-v89-archive-gaps', 'nd-v89-archive-gaps', false); }
  function ensureLinksLayer() { return ensureBarLayer('nd-v89-event-links', 'nd-v89-event-links', true); }

  function playlistUrl(w) {
    var start = Math.floor(w.start / 1000);
    var duration = Math.max(1, Math.ceil((w.end - w.start) / 1000));
    return addToken('/dvr-archive/' + enc(streamName()) + '/archive-' + start + '-' + duration + '.m3u8');
  }

  function normalizePdt(s) { return String(s || '').trim().replace(/([+-]\d{2})(\d{2})$/u, '$1:$2'); }
  function parsePdt(s) {
    var t = Date.parse(normalizePdt(s));
    return Number.isFinite(t) ? t : NaN;
  }

  function parseUriDate(uri) {
    var s = String(uri || '');
    var m = s.match(/(20\d{2})(\d{2})(\d{2})[_-](\d{2})(\d{2})(\d{2})/);
    if (m) {
      var d = new Date(Number(m[1]), Number(m[2]) - 1, Number(m[3]), Number(m[4]), Number(m[5]), Number(m[6]));
      var t = d.getTime();
      if (Number.isFinite(t)) return t;
    }
    m = s.match(/(20\d{2})-(\d{2})-(\d{2})\/(\d{2})\/.*?(\d{2})(\d{2})(\d{2})/);
    if (m) {
      var d2 = new Date(Number(m[1]), Number(m[2]) - 1, Number(m[3]), Number(m[4]), Number(m[5]), Number(m[6]), Number(m[7]));
      var t2 = d2.getTime();
      if (Number.isFinite(t2)) return t2;
    }
    return NaN;
  }

  function mergeIntervals(list, toleranceMs) {
    var tol = Number.isFinite(toleranceMs) ? toleranceMs : CFG.mergeToleranceMs;
    var sorted = (list || []).filter(function (x) {
      return x && Number.isFinite(x.start) && Number.isFinite(x.end) && x.end > x.start;
    }).sort(function (a, b) { return a.start - b.start || a.end - b.end; });
    if (!sorted.length) return [];
    var out = [{ start: sorted[0].start, end: sorted[0].end }];
    for (var i = 1; i < sorted.length; i++) {
      var x = sorted[i];
      var last = out[out.length - 1];
      if (x.start <= last.end + tol) last.end = Math.max(last.end, x.end);
      else out.push({ start: x.start, end: x.end });
    }
    return out;
  }

  function parsePlaylist(text) {
    var out = [];
    var lines = String(text || '').split(/\r?\n/);
    var dur = NaN;
    var pdt = NaN;
    var inferred = NaN;
    lines.forEach(function (line) {
      line = String(line || '').trim();
      if (!line) return;
      var m = line.match(/^#EXTINF:([0-9.]+)/i);
      if (m) { dur = Number(m[1]) * 1000; return; }
      m = line.match(/^#EXT-X-PROGRAM-DATE-TIME:(.+)$/i);
      if (m) { pdt = parsePdt(m[1]); return; }
      if (line[0] === '#') return;
      var start = Number.isFinite(pdt) ? pdt : parseUriDate(line);
      if (!Number.isFinite(start) && Number.isFinite(inferred)) start = inferred;
      var d = Number.isFinite(dur) ? dur : 4000;
      if (Number.isFinite(start)) {
        out.push({ start: start, end: start + d });
        inferred = start + d;
      }
      dur = NaN;
      pdt = NaN;
    });
    return mergeIntervals(out, CFG.mergeToleranceMs);
  }

  function subtractCoverage(w, coverage) {
    var gaps = [];
    var cursor = w.start;
    var cov = mergeIntervals(coverage || [], CFG.mergeToleranceMs);
    cov.forEach(function (seg) {
      var s = clamp(seg.start, w.start, w.end);
      var e = clamp(seg.end, w.start, w.end);
      if (e <= w.start || s >= w.end) return;
      if (s > cursor && s - cursor >= CFG.minGapMs) gaps.push({ start: cursor, end: s });
      cursor = Math.max(cursor, e);
    });
    if (w.end > cursor && w.end - cursor >= CFG.minGapMs) gaps.push({ start: cursor, end: w.end });
    return gaps;
  }

  function currentCoveredByCache(w) {
    var c = state.gapCache;
    return Boolean(c && w.start >= c.start - CFG.cacheSlackMs && w.end <= c.end + CFG.cacheSlackMs);
  }

  function rangesOverlap(a1, a2, b1, b2) { return Math.max(a1, b1) < Math.min(a2, b2); }

  function drawGapsForWindow(w) {
    var layer = ensureGapsLayer();
    if (!layer) return;

    if (/live/i.test(String(w.mode || '')) && !/dvr|archive/i.test(String(w.mode || ''))) {
      layer.innerHTML = '';
      layer.dataset.state = 'live-hidden';
      return;
    }

    var c = state.gapCache;
    if (!c || !Array.isArray(c.gaps) || !rangesOverlap(w.start, w.end, c.start, c.end)) {
      layer.innerHTML = '';
      layer.dataset.state = 'no-cache';
      return;
    }

    if (!currentCoveredByCache(w)) {
      // Stability rule: never stretch old gaps onto a new timeline window.
      layer.innerHTML = '';
      layer.dataset.state = 'outside-cache';
      return;
    }

    var html = [];
    c.gaps.forEach(function (g) {
      var gs = Math.max(g.start, w.start);
      var ge = Math.min(g.end, w.end);
      if (ge <= gs || ge - gs < CFG.minGapMs) return;
      var l = ((gs - w.start) / Math.max(1, w.end - w.start)) * 100;
      var r = ((ge - w.start) / Math.max(1, w.end - w.start)) * 100;
      var left = clamp(l, 0, 100);
      var width = clamp(r - l, 0, 100 - left);
      if (width <= 0) return;
      var title = 'Архив отсутствует: ' + new Date(gs).toLocaleString('ru-RU') + ' — ' + new Date(ge).toLocaleString('ru-RU');
      html.push('<span class="nd-v89-gap" style="left:' + left.toFixed(4) + '%;width:' + width.toFixed(4) + '%" title="' + title.replace(/"/g, '&quot;') + '"></span>');
    });
    layer.innerHTML = html.join('');
    layer.dataset.state = 'fresh';
    layer.dataset.cacheStart = String(Math.floor(c.start));
    layer.dataset.cacheEnd = String(Math.floor(c.end));
  }

  function analysisWindow(visible) {
    var span = Math.max(1000, visible.end - visible.start);
    var pad = clamp(span * 0.35, CFG.minPadMs, CFG.maxPadMs);
    var start = visible.start - pad;
    var end = visible.end + pad;
    if (end - start > CFG.maxFetchWindowMs) {
      // For very wide windows, do not invent partial side cache. Fetch exactly what is visible.
      start = visible.start;
      end = visible.end;
    }
    return { start: Math.floor(start), end: Math.ceil(end), source: 'stable-cache-window' };
  }

  async function fetchGaps(reason) {
    var visible = timelineWindow();
    state.lastFetchReason = reason || '';

    if (/live/i.test(String(visible.mode || '')) && !/dvr|archive/i.test(String(visible.mode || ''))) {
      state.gapCache = null;
      drawGapsForWindow(visible);
      return;
    }

    if (currentCoveredByCache(visible) && reason !== 'manual' && reason !== 'poll') {
      drawGapsForWindow(visible);
      return;
    }

    var aw = analysisWindow(visible);
    var key = [streamName(), Math.floor(aw.start / 5000), Math.floor(aw.end / 5000)].join(':');
    if (key === state.lastFetchKey && reason !== 'manual' && reason !== 'poll') {
      drawGapsForWindow(visible);
      return;
    }
    state.lastFetchKey = key;

    if (state.abort && state.abort.abort) {
      try { state.abort.abort(); state.stats.aborts++; } catch (_) {}
    }
    var ctrl = window.AbortController ? new AbortController() : null;
    state.abort = ctrl;
    var seq = ++state.seq;
    state.stats.fetches++;

    try {
      var url = playlistUrl(aw);
      var res = await fetch(url, { cache: 'no-store', signal: ctrl ? ctrl.signal : undefined });
      var text = await res.text();
      if (seq !== state.seq) { state.stats.staleIgnored++; return; }

      var coverage = [];
      if (res.ok && /#EXTM3U/i.test(text)) coverage = parsePlaylist(text);
      else if (!res.ok) coverage = [];
      else warn('unexpected archive playlist response', res.status, text.slice(0, 120));

      state.gapCache = {
        start: aw.start,
        end: aw.end,
        coverage: coverage,
        gaps: subtractCoverage(aw, coverage),
        updatedAt: now(),
        reason: reason,
        url: url
      };
      drawGapsForWindow(timelineWindow());
    } catch (e) {
      if (e && e.name === 'AbortError') return;
      state.lastError = String(e && (e.message || e) || 'unknown');
      warn('archive gap fetch failed', reason, state.lastError);
      // Do not keep showing stale red data after a failed fetch for a new window.
      drawGapsForWindow(timelineWindow());
    }
  }

  function scheduleGapFetch(reason, delay) {
    clearTimeout(state.fetchTimer);
    state.fetchTimer = setTimeout(function () { fetchGaps(reason || 'scheduled'); }, delay == null ? CFG.settledDebounceMs : delay);
  }

  function eventMs(ev) { return Number(ev && ev.__ms); }

  function eventGroupKey(ev) {
    if (!ev) return '';
    return String(ev.event_hash || ev.hash || ev.group_id || ev.groupId || ev.chain_id || ev.chainId || ev.object_id || ev.objectId || ev.track_id || ev.trackId || ev.rule_id || ev.ruleId || ev.topic || ev.event_type || ev.type || ev.kind || '');
  }

  function drawEventLinks() {
    var layer = ensureLinksLayer();
    var eventsState = window.ND_EVENTS_V81 && window.ND_EVENTS_V81.state;
    var w = timelineWindow();
    if (!layer || !eventsState || !Array.isArray(eventsState.visible)) {
      if (layer) layer.innerHTML = '';
      return;
    }

    var visible = eventsState.visible.slice().filter(function (ev) {
      return Number.isFinite(eventMs(ev));
    }).sort(function (a, b) { return eventMs(a) - eventMs(b); });

    var byKey = Object.create(null);
    visible.forEach(function (ev) {
      var k = eventGroupKey(ev);
      if (!k) return;
      (byKey[k] || (byKey[k] = [])).push(ev);
    });

    var links = [];
    Object.keys(byKey).forEach(function (k) {
      var arr = byKey[k].sort(function (a, b) { return eventMs(a) - eventMs(b); });
      for (var i = 0; i < arr.length - 1; i++) {
        var a = eventMs(arr[i]);
        var b = eventMs(arr[i + 1]);
        if (b > a && b - a <= CFG.eventPairGapMs) links.push({ start: a, end: b, key: k });
      }
    });

    if (!links.length) {
      for (var j = 0; j < visible.length - 1; j++) {
        var x = eventMs(visible[j]);
        var y = eventMs(visible[j + 1]);
        var tx = String(visible[j].event_type || visible[j].type || visible[j].topic || '');
        var ty = String(visible[j + 1].event_type || visible[j + 1].type || visible[j + 1].topic || '');
        if (tx && tx === ty && y > x && y - x <= 30000) links.push({ start: x, end: y, key: tx });
      }
    }

    layer.innerHTML = links.map(function (ln) {
      var l = ((ln.start - w.start) / Math.max(1, w.end - w.start)) * 100;
      var r = ((ln.end - w.start) / Math.max(1, w.end - w.start)) * 100;
      var left = clamp(l, 0, 100);
      var width = clamp(r - l, 0, 100 - left);
      if (width <= 0) return '';
      return '<span class="nd-v89-event-link" style="left:' + left.toFixed(4) + '%;width:' + width.toFixed(4) + '%" title="Связанные события: ' + String(ln.key).replace(/"/g, '&quot;') + '"></span>';
    }).join('');
  }

  function render(reason) {
    state.lastRenderReason = reason || '';
    if (state.renderRaf) return;
    var cb = function () {
      state.renderRaf = 0;
      state.stats.renders++;
      removeSupersededLayers();
      patchControls();
      drawEventLinks();
      drawGapsForWindow(timelineWindow());
    };
    state.renderRaf = window.requestAnimationFrame ? requestAnimationFrame(cb) : setTimeout(cb, CFG.renderFrameMs);
  }

  function markInteraction(on) {
    if (on) state.interactionDepth++;
    else state.interactionDepth = Math.max(0, state.interactionDepth - 1);
    state.lastInteractionAt = now();
  }

  function installHandlers() {
    document.addEventListener('click', function (ev) {
      var loadSel = ev.target && ev.target.closest && ev.target.closest('[data-action="load-selection"]');
      if (loadSel) {
        ev.preventDefault();
        ev.stopPropagation();
        if (typeof ev.stopImmediatePropagation === 'function') ev.stopImmediatePropagation();
        downloadSelected();
        return;
      }
      setTimeout(function () {
        render('click');
        scheduleGapFetch('click', CFG.quickDebounceMs);
      }, 0);
    }, true);

    document.addEventListener('pointerdown', function (ev) {
      var t = ev.target;
      if (t && t.closest && t.closest('.timeline, .bar, .overview')) markInteraction(true);
    }, true);

    ['pointerup', 'pointercancel'].forEach(function (type) {
      document.addEventListener(type, function () {
        markInteraction(false);
        render(type);
        scheduleGapFetch(type, CFG.settledDebounceMs);
      }, true);
    });

    ['input', 'change'].forEach(function (type) {
      document.addEventListener(type, function (ev) {
        var t = ev.target;
        if (t && t.closest && t.closest('.timeline, .bar, .overview, .range-panel, .controls, .bottom')) {
          render(type);
          scheduleGapFetch(type, CFG.quickDebounceMs);
        }
      }, true);
    });

    document.addEventListener('pointermove', function (ev) {
      var t = ev.target;
      if (t && t.closest && t.closest('.timeline, .bar, .overview')) {
        render('pointermove');
        // Do not fetch while the user is dragging; fetch only after the drag settles.
        scheduleGapFetch('pointermove-settled', CFG.settledDebounceMs);
      }
    }, true);

    document.addEventListener('wheel', function (ev) {
      var t = ev.target;
      if (t && t.closest && t.closest('.timeline, .bar, .overview')) {
        state.lastInteractionAt = now();
        render('wheel');
        scheduleGapFetch('wheel-settled', CFG.wheelSettleMs);
      }
    }, { capture: true, passive: true });

    window.addEventListener('nd-player-timeline-change', function () {
      render('nd-player-timeline-change');
      scheduleGapFetch('nd-player-timeline-change', CFG.settledDebounceMs);
    }, { passive: true });

    window.addEventListener('resize', function () {
      render('resize');
      scheduleGapFetch('resize', CFG.quickDebounceMs);
    }, { passive: true });

    try {
      var ro = new ResizeObserver(function () {
        render('bar-resize');
        scheduleGapFetch('bar-resize', CFG.quickDebounceMs);
      });
      var bar = $('.bar');
      if (bar) ro.observe(bar);
      state.resizeObserver = ro;
    } catch (_) {}

    try {
      new MutationObserver(function (mutations) {
        var important = false;
        for (var i = 0; i < mutations.length; i++) {
          if (mutations[i].type === 'childList') { important = true; break; }
        }
        if (important) render('mutation-childlist');
      }).observe(document.body || document.documentElement, { childList: true, subtree: true });
    } catch (_) {}

    state.pollTimer = setInterval(function () { scheduleGapFetch('poll', 0); }, CFG.pollMs);
  }

  function repairLoop() {
    clearTimeout(state.repairTimer);
    state.repairTimer = setTimeout(function () {
      render('repair');
      repairLoop();
    }, CFG.repairMs);
  }

  function boot() {
    document.documentElement.classList.add('nd-v89-installed');
    document.documentElement.classList.remove('nd-v87-installed', 'nd-v88-installed');
    removeSupersededLayers();
    patchControls();
    installHandlers();
    render('boot');
    scheduleGapFetch('boot', 700);
    repairLoop();
    log(VERSION + ' installed');
  }

  window.ND_PLAYER_STABILITY_V89 = {
    version: VERSION,
    state: state,
    timelineWindow: timelineWindow,
    selectedWindow: selectedWindow,
    refreshGaps: function () { return fetchGaps('manual'); },
    render: function () { return render('manual'); },
    patchControls: patchControls,
    downloadSelected: downloadSelected,
    clearGapCache: function () { state.gapCache = null; state.lastFetchKey = ''; drawGapsForWindow(timelineWindow()); },
    analysisWindow: analysisWindow
  };

  // Backward-compatible alias for quick console checks after v88.
  window.ND_PLAYER_UI_V89 = window.ND_PLAYER_STABILITY_V89;

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', boot, { once: true });
  else boot();
})();
JS

chown root:root "$V89_JS"
chmod 0644 "$V89_JS"
node --check "$V89_JS"

echo
echo "===== Patch CSS ====="
python3 - "$PLAYER_CSS" <<'PY'
import pathlib, sys, re
path = pathlib.Path(sys.argv[1])
s = path.read_text()
block = r'''

/* v89 player stability, no feature change */
.nd-v89-hide,
.nd-v88-hide,
.nd-v87-hide {
  display: none !important;
}
.nd-v89-ui .controls [data-action="center"],
.nd-v89-ui .controls [data-action="download"],
.nd-v88-ui .controls [data-action="center"],
.nd-v88-ui .controls [data-action="download"],
.nd-v87-ui .controls [data-action="center"],
.nd-v87-ui .controls [data-action="download"] {
  display: none !important;
}
.nd-v89-download-selection,
.nd-v88-download-selection,
.nd-v87-download-selection {
  min-width: 170px !important;
  background: #0f766e !important;
  border-color: rgba(45,212,191,.55) !important;
  color: #ecfeff !important;
  font-weight: 900 !important;
}
.nd-v89-camera,
.nd-v88-camera,
.nd-v87-camera {
  width: 19px !important;
  height: 19px !important;
  display: block !important;
}
.controls [data-action="screenshot"] {
  min-width: 42px !important;
  width: 42px !important;
  padding-left: 0 !important;
  padding-right: 0 !important;
  align-items: center !important;
  justify-content: center !important;
}
#nd-v89-archive-gaps.nd-v89-archive-gaps,
#nd-v89-event-links.nd-v89-event-links {
  position: absolute !important;
  inset: 0 !important;
  pointer-events: none !important;
  overflow: hidden !important;
}
#nd-v89-archive-gaps.nd-v89-archive-gaps {
  z-index: 1 !important;
  transition: opacity .10s linear !important;
}
#nd-v89-archive-gaps[data-state="no-cache"],
#nd-v89-archive-gaps[data-state="outside-cache"],
#nd-v89-archive-gaps[data-state="live-hidden"] {
  opacity: 0 !important;
}
#nd-v89-archive-gaps .nd-v89-gap {
  position: absolute !important;
  top: 0 !important;
  bottom: 0 !important;
  display: block !important;
  background: repeating-linear-gradient(135deg, rgba(239,68,68,.26) 0 5px, rgba(127,29,29,.40) 5px 10px) !important;
  border-left: 1px solid rgba(248,113,113,.70) !important;
  border-right: 1px solid rgba(248,113,113,.45) !important;
  box-shadow: inset 0 0 0 1px rgba(127,29,29,.20) !important;
}
#nd-v89-event-links.nd-v89-event-links {
  z-index: 12 !important;
}
#nd-v89-event-links .nd-v89-event-link {
  position: absolute !important;
  top: 5px !important;
  height: 3px !important;
  display: block !important;
  border-radius: 999px !important;
  background: rgba(250,204,21,.62) !important;
  box-shadow: 0 0 8px rgba(250,204,21,.35) !important;
}
#nd-events-v81-layer .nd-events-v81-dot {
  width: 3px !important;
  min-width: 3px !important;
  max-width: 3px !important;
  height: calc(100% - 10px) !important;
  top: 5px !important;
  margin-left: -1.5px !important;
  border-radius: 4px !important;
  transform: none !important;
  background: #facc15 !important;
  border: 0 !important;
  box-shadow: 0 0 0 1px rgba(0,0,0,.45), 0 0 7px rgba(250,204,21,.55) !important;
}
#nd-events-v81-layer .nd-events-v81-dot:hover,
#nd-events-v81-layer .nd-events-v81-dot:focus {
  width: 5px !important;
  min-width: 5px !important;
  max-width: 5px !important;
  margin-left: -2.5px !important;
  outline: 2px solid rgba(250,204,21,.65) !important;
}
.event-band .event-dot,
.ndp-event-band .ndp-event-dot {
  width: 3px !important;
  height: calc(100% - 10px) !important;
  top: 5px !important;
  margin-left: -1.5px !important;
  border-radius: 4px !important;
}
@media(max-width: 760px) {
  .nd-v89-download-selection,
  .nd-v88-download-selection,
  .nd-v87-download-selection {
    min-width: 140px !important;
  }
}
/* /v89 player stability, no feature change */
'''
start = '/* v89 player stability, no feature change */'
end = '/* /v89 player stability, no feature change */'
pattern = re.compile(re.escape(start) + r'.*?' + re.escape(end), re.S)
if start in s and end in s:
    s = pattern.sub(block.strip(), s)
else:
    s = s.rstrip() + block
path.write_text(s)
print('css patched:', path)
PY

echo
echo "===== Patch embed.html script order ====="
python3 - "$EMBED_HTML" "$TS" <<'PY'
import pathlib, sys, re
path = pathlib.Path(sys.argv[1])
ts = sys.argv[2]
s = path.read_text()
orig = s
# Remove only superseded UI-timeline layers. v89 preserves the same user-facing functions.
for name in ['player-ui-timeline-v87', 'player-ui-timeline-v88', 'player-stability-v89']:
    s = re.sub(rf'\s*<script\s+src="/newdomofon-player/{re.escape(name)}\.js(?:\?v=[^"]*)?"\s*>\s*</script>', '', s, flags=re.I)
script = f'<script src="/newdomofon-player/player-stability-v89.js?v={ts}"></script>'
if '</body>' not in s:
    raise SystemExit('embed.html has no </body>')
s = s.replace('</body>', '  ' + script + '\n</body>', 1)
path.write_text(s)
print('changed:', s != orig)
print('has_v89:', 'player-stability-v89.js' in s)
print('has_v87_or_v88_ui:', bool(re.search(r'player-ui-timeline-v8[78]\.js', s)))
PY

echo
echo "===== Final static checks ====="
node --check "$PLAYER_JS"
node --check "$V89_JS"

echo
echo "installed: $V89_JS"
echo "backup:    $BACKUP"
echo
echo "Browser iframe console checks:"
echo "  window.ND_PLAYER_STABILITY_V89"
echo "  window.ND_PLAYER_STABILITY_V89.timelineWindow()"
echo "  window.ND_PLAYER_STABILITY_V89.state.gapCache"
echo "  window.ND_PLAYER_STABILITY_V89.refreshGaps()"
echo
echo "Expected: same player functions remain, but overlays render through one stable v89 layer;"
echo "          archive red gaps do not jump during pan/zoom; stale async results are ignored."
