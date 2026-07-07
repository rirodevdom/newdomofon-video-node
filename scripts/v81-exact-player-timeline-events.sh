#!/usr/bin/env bash
set -Eeuo pipefail

# NewDomofon Video: v81 exact player timeline events overlay
#
# Problem fixed:
#   v79 fixed disappearing events by isolating the overlay from base player.js.
#
# New problem fixed in v81:
#   v80 still calculated event marker positions from .range-start/.range-end.
#   The original player keeps the exact timeline window in private state.ws/state.we,
#   while datetime-local inputs are rounded to minutes and can lag behind zoom/pan.
#
# v81 fix:
#   - minimally patch player.js to publish exact state.ws/state.we to .bar dataset;
#   - keep the isolated overlay from v79/v80;
#   - calculate marker positions from the same timeline source as the base ruler/cursor;
#   - listen to a nd-player-timeline-change browser event for immediate repaint.

PROJECT_DIR="${PROJECT_DIR:-/opt/newdomofon-video}"
SITE_URL="${SITE_URL:-https://new-video.domofon-37.ru}"
IP_SITE_URL="${IP_SITE_URL:-https://10.106.1.28}"
WEB_ROOT="${WEB_ROOT:-/var/www/newdomofon-video}"
PLAYER_DIR="${PLAYER_DIR:-$WEB_ROOT/newdomofon-player}"
PLAYER_JS="$PLAYER_DIR/player.js"
PLAYER_CSS="$PLAYER_DIR/player.css"
EMBED_HTML="$PLAYER_DIR/embed.html"
OVERLAY_JS="$PLAYER_DIR/events-overlay-v81.js"

ENV_FILE="${ENV_FILE:-/etc/newdomofon-video/app.env}"
BACKEND_ENV="${BACKEND_ENV:-$PROJECT_DIR/backend/.env}"
FRONTEND_ENV="${FRONTEND_ENV:-$PROJECT_DIR/frontend/.env.production}"
CAMERA_STREAM_MAP="${CAMERA_STREAM_MAP:-/etc/newdomofon-video/camera-stream-map.json}"

[[ "$(id -u)" -eq 0 ]] || { echo "Run as root with sudo." >&2; exit 1; }
for c in python3 node curl grep awk; do command -v "$c" >/dev/null || { echo "$c not found" >&2; exit 1; }; done
[[ -f "$PLAYER_JS" ]] || { echo "player.js not found: $PLAYER_JS" >&2; exit 1; }
[[ -f "$PLAYER_CSS" ]] || { echo "player.css not found: $PLAYER_CSS" >&2; exit 1; }
[[ -f "$EMBED_HTML" ]] || { echo "embed.html not found: $EMBED_HTML" >&2; exit 1; }

TS="$(date +%Y%m%d-%H%M%S)"
BACKUP="$PROJECT_DIR/backups/v81-exact-player-timeline-events-$TS"
mkdir -p "$BACKUP"

backup() {
  [[ -e "$1" ]] || return 0
  mkdir -p "$BACKUP/$(dirname "${1#/}")"
  cp -a "$1" "$BACKUP/${1#/}"
  echo "backup: $1"
}

read_env_value() {
  local file="$1" key="$2"
  [[ -f "$file" ]] || return 0
  grep -E "^${key}=" "$file" | tail -1 | cut -d= -f2- || true
}

echo "===== Backup ====="
backup "$EMBED_HTML"
backup "$PLAYER_JS"
backup "$PLAYER_CSS"
backup "$PLAYER_DIR/events-overlay-v71.js"
backup "$PLAYER_DIR/events-overlay-v72.js"
backup "$PLAYER_DIR/events-overlay-v79.js"
backup "$PLAYER_DIR/events-overlay-v80.js"
backup "$OVERLAY_JS"

echo
echo "===== Safety check: current player.js syntax ====="
node --check "$PLAYER_JS"

echo
echo "===== Resolve token/camera for smoke URLs ====="
TOKEN="${RESTREAM_PUBLIC_TOKEN:-}"
[[ -z "$TOKEN" ]] && TOKEN="$(read_env_value "$ENV_FILE" RESTREAM_PUBLIC_TOKEN)"
[[ -z "$TOKEN" ]] && TOKEN="$(read_env_value "$BACKEND_ENV" RESTREAM_PUBLIC_TOKEN)"
[[ -z "$TOKEN" ]] && TOKEN="$(read_env_value "$FRONTEND_ENV" VITE_RESTREAM_PUBLIC_TOKEN)"
TOKEN="${TOKEN:-}"
[[ -n "$TOKEN" ]] && echo "token prefix: ${TOKEN:0:8}, len=${#TOKEN}" || echo "WARNING: token not found; overlay will use token from iframe URL."

CAMERA_ID="f0486587-8a79-4cc2-b257-0671f874c08b"
STREAM_NAME="cam_10_130_1_219"
if [[ -s "$CAMERA_STREAM_MAP" ]]; then
  CAMERA_ID="$(node -e "const m=require(process.argv[1]); const e=Object.entries(m).find(([k,v])=>v==='cam_10_130_1_219') || Object.entries(m)[0]; console.log(e ? e[0] : '')" "$CAMERA_STREAM_MAP" || true)"
  STREAM_NAME="$(node -e "const m=require(process.argv[1]); const e=Object.entries(m).find(([k,v])=>v==='cam_10_130_1_219') || Object.entries(m)[0]; console.log(e ? e[1] : 'cam_10_130_1_219')" "$CAMERA_STREAM_MAP" || true)"
fi
CAMERA_ID="${CAMERA_ID:-f0486587-8a79-4cc2-b257-0671f874c08b}"
STREAM_NAME="${STREAM_NAME:-cam_10_130_1_219}"
echo "verify camera: $CAMERA_ID -> $STREAM_NAME"



echo
echo "===== Patch player.js: expose exact internal timeline window ====="
python3 - "$PLAYER_JS" <<'PY'
import pathlib, sys
path = pathlib.Path(sys.argv[1])
s = path.read_text()
orig = s

if 'function ndPublishTimelineWindowV81()' not in s:
    # This function is inserted into original player.js scope, so it can read private `state.ws/state.we`.
    helper = """function ndPublishTimelineWindowV81(){try{var b=document.querySelector('.bar');var d={mode:state.mode,stream:state.stream,cameraId:state.cameraId,ws:Math.floor(state.ws),we:Math.floor(state.we),cursor:Math.floor(state.cursor),winDur:Math.floor(Math.max(1,state.we-state.ws)),updatedAt:Date.now()};if(b){b.dataset.ndWindowStartMs=String(d.ws);b.dataset.ndWindowEndMs=String(d.we);b.dataset.ndCursorMs=String(d.cursor);b.dataset.ndMode=String(d.mode||'');b.dataset.ndTimelineVersion='v81';}var k=[d.mode,d.ws,d.we,d.cursor].join(':');if(window.__ndTimelineV81Key!==k){window.__ndTimelineV81Key=k;window.ND_PLAYER_TIMELINE=d;try{window.dispatchEvent(new CustomEvent('nd-player-timeline-change',{detail:d}));}catch(_){}}else{window.ND_PLAYER_TIMELINE=d;}}catch(_){}}"""
    marker = 'function uiTimeline(){'
    if marker not in s:
        raise SystemExit('Cannot patch player.js: function uiTimeline() marker not found')
    s = s.replace(marker, helper + marker, 1)

if 'ndPublishTimelineWindowV81();renderRuler();renderOverview();renderSelection();renderEventDots()}' not in s:
    old = 'renderRuler();renderOverview();renderSelection();renderEventDots()}'
    if old not in s:
        raise SystemExit('Cannot patch player.js: render timeline tail not found')
    s = s.replace(old, 'ndPublishTimelineWindowV81();' + old, 1)

path.write_text(s)
print('changed:', s != orig)
print('has_ndPublishTimelineWindowV81:', 'function ndPublishTimelineWindowV81()' in s)
print('publish_call_count:', s.count('ndPublishTimelineWindowV81();'))
PY
node --check "$PLAYER_JS"


echo
echo "===== Write isolated overlay v81 ====="
cat > "$OVERLAY_JS" <<'JS'
(function () {
  'use strict';

  var VERSION = 'v81-exact-player-timeline-events';
  var CFG = {
    fetchDebounceMs: 450,
    renderDebounceMs: 40,
    pollMs: 15000,
    cacheTtlMs: 60000,
    visibleLimit: 500,
    maxWindowMs: 48 * 3600000,
    fallbackWindowMs: 3600000
  };

  var state = {
    events: [],
    visible: [],
    cache: Object.create(null),
    controller: null,
    seq: 0,
    fetchTimer: 0,
    renderTimer: 0,
    lastHash: '',
    lastKey: '',
    lastEndpoint: '',
    lastError: '',
    lastReason: '',
    lastScanKey: '',
    renderRaf: 0,
    scanTimer: 0,
    resizeObserver: null,
    observedBar: null,
    installedAt: Date.now()
  };

  function log() {
    var a = Array.prototype.slice.call(arguments);
    a.unshift('[NewDomofon events-v81]');
    console.info.apply(console, a);
  }

  function warn() {
    var a = Array.prototype.slice.call(arguments);
    a.unshift('[NewDomofon events-v81]');
    console.warn.apply(console, a);
  }

  function qs() {
    try { return new URLSearchParams(location.search || ''); }
    catch (_) { return new URLSearchParams(); }
  }

  function token() { return qs().get('token') || ''; }

  function mask(v) {
    return String(v || '').replace(/token=([^&\s]+)/g, function (_, t) {
      return 'token=' + t.slice(0, 8) + '...len' + t.length;
    });
  }

  function parts() { return String(location.pathname || '').split('/').filter(Boolean); }

  function streamName() {
    var p = parts();
    var i = p.indexOf('embed.html');
    if (i > 0) return decodeURIComponent(p[i - 1]);
    if (p.length >= 2 && p[p.length - 1] === 'embed.html') return decodeURIComponent(p[p.length - 2]);
    return qs().get('stream') || '';
  }

  function cameraId() {
    return qs().get('camera_id') || qs().get('cameraId') || qs().get('camera') || streamName();
  }

  function addToken(url) {
    var u = new URL(url, location.origin);
    if (token() && !u.searchParams.get('token')) u.searchParams.set('token', token());
    return u.pathname + u.search;
  }

  function html(v) {
    return String(v == null ? '' : v)
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;');
  }

  function parseTime(v) {
    if (typeof v === 'number') return v > 1000000000000 ? v : v * 1000;
    if (typeof v === 'string' && /^\d+(\.\d+)?$/.test(v.trim())) {
      var n = Number(v);
      return n > 1000000000000 ? n : n * 1000;
    }
    var t = Date.parse(v || '');
    return Number.isFinite(t) ? t : NaN;
  }

  function msOf(ev) {
    return parseTime(ev && (
      ev.occurred_at || ev.event_time || ev.time || ev.ts || ev.timestamp ||
      ev.started_at || ev.created_at || ev.date_time || ev.datetime || ev.date
    ));
  }

  function evType(ev) { return String((ev && (ev.event_type || ev.type || ev.kind || ev.topic || ev.title || ev.name || ev.code)) || 'event'); }
  function evState(ev) { return String((ev && (ev.event_state || ev.state || ev.status || ev.value || '')) || ''); }

  function fmt(ms) {
    try { return new Date(ms).toLocaleString('ru-RU', { hour12: false }); }
    catch (_) { return String(ms); }
  }

  function inputValue(ms) {
    var d = new Date(ms);
    if (!Number.isFinite(d.getTime())) return '';
    function p(n) { return String(n).padStart(2, '0'); }
    return d.getFullYear() + '-' + p(d.getMonth() + 1) + '-' + p(d.getDate()) + 'T' + p(d.getHours()) + ':' + p(d.getMinutes());
  }

  function parseInput(v) {
    var t = Date.parse(v || '');
    return Number.isFinite(t) ? t : NaN;
  }

  function getDateInputs() {
    var preferred = [
      document.querySelector('.range-start'),
      document.querySelector('.range-end')
    ].filter(Boolean);
    if (preferred.length >= 2) return preferred;

    var all = Array.from(document.querySelectorAll('input[type="datetime-local"], input[type="datetime"], input[data-role*="from"], input[data-role*="to"]'));
    if (all.length >= 2) return [all[0], all[1]];
    return [];
  }

  function isArchiveMode() {
    var q = qs();
    if ((q.get('proto') || '').toLowerCase() === 'dvr') return true;
    if (q.get('from') || q.get('start') || q.get('to') || q.get('end')) return true;
    if (document.querySelector('.ndp.dvr')) return true;
    var mode = document.querySelector('.pill.mode');
    if (mode && /dvr|архив/i.test(mode.textContent || '')) return true;
    return getDateInputs().length >= 2;
  }

  function timelineFromPlayerTruth() {
    var bar = document.querySelector('.bar');
    var sources = [];
    if (bar && bar.dataset) {
      sources.push({
        start: Number(bar.dataset.ndWindowStartMs),
        end: Number(bar.dataset.ndWindowEndMs),
        cursor: Number(bar.dataset.ndCursorMs),
        mode: bar.dataset.ndMode || '',
        source: 'player-bar-dataset'
      });
    }
    if (window.ND_PLAYER_TIMELINE) {
      sources.push({
        start: Number(window.ND_PLAYER_TIMELINE.ws),
        end: Number(window.ND_PLAYER_TIMELINE.we),
        cursor: Number(window.ND_PLAYER_TIMELINE.cursor),
        mode: window.ND_PLAYER_TIMELINE.mode || '',
        source: 'player-global-state'
      });
    }
    for (var i = 0; i < sources.length; i++) {
      var w = sources[i];
      if (Number.isFinite(w.start) && Number.isFinite(w.end) && w.end > w.start) {
        return clampWindow(w);
      }
    }
    return null;
  }

  function windowFromDom() {
    var playerTruth = timelineFromPlayerTruth();
    if (playerTruth) return playerTruth;

    var inputs = getDateInputs();
    if (inputs.length >= 2) {
      var a = parseInput(inputs[0].value);
      var b = parseInput(inputs[1].value);
      if (Number.isFinite(a) && Number.isFinite(b) && b > a) {
        return clampWindow({ start: a, end: b, source: 'inputs' });
      }
    }

    var q = qs();
    var fromRaw = q.get('from') || q.get('start') || '';
    var toRaw = q.get('to') || q.get('end') || '';
    var from = parseTime(fromRaw);
    var to = parseTime(toRaw);
    if (Number.isFinite(from) && Number.isFinite(to) && to > from) {
      return clampWindow({ start: from, end: to, source: 'query' });
    }

    var now = Date.now();
    return { start: now - CFG.fallbackWindowMs, end: now, source: 'fallback-last-hour' };
  }

  function clampWindow(w) {
    if (!w || !Number.isFinite(w.start) || !Number.isFinite(w.end) || w.end <= w.start) return w;
    if (w.end - w.start <= CFG.maxWindowMs) return w;
    return { start: w.end - CFG.maxWindowMs, end: w.end, source: w.source + '-clamped' };
  }

  function keyOf(w) {
    return [cameraId(), streamName(), Math.floor(w.start / 1000), Math.floor(w.end / 1000)].join(':');
  }

  function layoutSig() {
    var bar = document.querySelector('.bar');
    if (!bar) return 'no-bar';
    var r = bar.getBoundingClientRect ? bar.getBoundingClientRect() : { width: bar.clientWidth || 0, height: bar.clientHeight || 0 };
    var scale = document.querySelector('.scale-label');
    return [Math.round(r.width || 0), Math.round(r.height || 0), scale ? String(scale.textContent || '') : ''].join('x');
  }

  function urls(w) {
    var query = '?start=' + encodeURIComponent(new Date(w.start).toISOString()) +
      '&end=' + encodeURIComponent(new Date(w.end).toISOString()) +
      '&stream=' + encodeURIComponent(streamName());
    return [
      addToken('/public-events/' + encodeURIComponent(cameraId()) + '/events' + query),
      addToken('/nd-events/' + encodeURIComponent(cameraId()) + '/events' + query)
    ];
  }

  function normalize(data) {
    var items = Array.isArray(data) ? data : (data && (data.items || data.events || data.rows || data.data)) || [];
    if (!Array.isArray(items)) items = [];
    return items.map(function (ev) {
      var copy = Object.assign({}, ev);
      copy.__ms = msOf(ev);
      return copy;
    }).filter(function (ev) {
      return Number.isFinite(ev.__ms);
    }).sort(function (a, b) { return a.__ms - b.__ms; });
  }

  function visibleEvents(events, w) {
    return (events || []).filter(function (ev) { return ev.__ms >= w.start && ev.__ms <= w.end; });
  }

  function eventId(ev) {
    return [ev.id || ev.event_hash || '', Math.floor(ev.__ms || 0), evType(ev), evState(ev)].join('|');
  }

  function hashOf(list, w) {
    return [
      keyOf(w),
      layoutSig(),
      list.length,
      list.map(eventId).join('~')
    ].join('::');
  }

  function ensureLayer() {
    var bar = document.querySelector('.bar');
    if (!bar) return null;

    var layer = document.getElementById('nd-events-v81-layer');
    if (layer && layer.parentElement === bar) return layer;
    if (layer && layer.parentElement) layer.parentElement.removeChild(layer);

    layer = document.createElement('div');
    layer.id = 'nd-events-v81-layer';
    layer.className = 'nd-events-v81-layer';
    layer.setAttribute('data-owner', VERSION);
    bar.appendChild(layer);
    return layer;
  }

  function ensurePanel() {
    var eventsBox = document.querySelector('.events');
    if (!eventsBox) return null;

    var panel = document.getElementById('nd-events-v81-panel');
    if (panel && panel.parentElement === eventsBox) return panel;
    if (panel && panel.parentElement) panel.parentElement.removeChild(panel);

    panel = document.createElement('div');
    panel.id = 'nd-events-v81-panel';
    panel.className = 'nd-events-v81-panel';

    var head = eventsBox.querySelector('.events-head');
    if (head && head.nextSibling) eventsBox.insertBefore(panel, head.nextSibling);
    else eventsBox.appendChild(panel);
    return panel;
  }

  function needsDomRepair() {
    var layer = document.getElementById('nd-events-v81-layer');
    var panel = document.getElementById('nd-events-v81-panel');
    if (!layer || !document.querySelector('.bar') || layer.parentElement !== document.querySelector('.bar')) return true;
    if (document.querySelector('.events') && (!panel || panel.parentElement !== document.querySelector('.events'))) return true;
    if (state.visible.length && layer.querySelectorAll('.nd-events-v81-dot').length !== state.visible.length) return true;
    return false;
  }

  function render(reason) {
    if (!isArchiveMode()) return;

    var w = windowFromDom();
    var visible = visibleEvents(state.events, w);
    var nextHash = hashOf(visible, w);

    if (nextHash === state.lastHash && state.lastKey === keyOf(w) && !needsDomRepair()) return;

    state.lastHash = nextHash;
    state.lastKey = keyOf(w);
    state.visible = visible;

    ensureResizeObserver();

    var layer = ensureLayer();
    if (layer) {
      layer.innerHTML = visible.map(function (ev, i) {
        var left = ((ev.__ms - w.start) / Math.max(1, w.end - w.start)) * 100;
        left = Math.max(0, Math.min(100, left));
        var title = fmt(ev.__ms) + ' · ' + evType(ev) + (evState(ev) ? ' · ' + evState(ev) : '');
        return '<button type="button" class="nd-events-v81-dot" data-ms="' + Math.floor(ev.__ms) + '" data-i="' + i + '" style="left:' + left.toFixed(3) + '%" title="' + html(title) + '"></button>';
      }).join('');

      layer.querySelectorAll('.nd-events-v81-dot').forEach(function (btn) {
        btn.addEventListener('click', function (ev) {
          ev.preventDefault();
          ev.stopPropagation();
          jumpToEvent(Number(btn.getAttribute('data-ms')));
        });
      });
    }

    var panel = ensurePanel();
    if (panel) {
      var header = '<div class="nd-events-v81-head"><strong>События архива</strong><span>' + visible.length + '</span></div>';
      if (!visible.length) {
        panel.innerHTML = header + '<div class="nd-events-v81-empty">' + html(state.lastError ? 'События временно недоступны' : 'Нет событий в текущем диапазоне') + '</div>';
      } else {
        panel.innerHTML = header + '<div class="nd-events-v81-list">' + visible.slice(0, CFG.visibleLimit).map(function (ev, i) {
          return '<button type="button" class="nd-events-v81-row" data-i="' + i + '" data-ms="' + Math.floor(ev.__ms) + '">' +
            '<span class="nd-events-v81-time">' + html(fmt(ev.__ms)) + '</span>' +
            '<span class="nd-events-v81-type">' + html(evType(ev)) + '</span>' +
            '<span class="nd-events-v81-state">' + html(evState(ev)) + '</span>' +
            '</button>';
        }).join('') + '</div>';

        panel.querySelectorAll('.nd-events-v81-row').forEach(function (btn) {
          btn.addEventListener('click', function (ev) {
            ev.preventDefault();
            ev.stopPropagation();
            jumpToEvent(Number(btn.getAttribute('data-ms')));
          });
        });
      }
    }

    log('render', { reason: reason, visible: visible.length, total: state.events.length, window: { start: new Date(w.start).toISOString(), end: new Date(w.end).toISOString(), source: w.source } });
  }

  function renderOnFrame(reason) {
    if (state.renderRaf) return;
    state.renderRaf = window.requestAnimationFrame ? requestAnimationFrame(function () {
      state.renderRaf = 0;
      render(reason || 'raf-render');
    }) : 0;
    if (!window.requestAnimationFrame) {
      state.renderRaf = 0;
      render(reason || 'direct-render');
    }
  }

  function scheduleRender(reason, delay) {
    clearTimeout(state.renderTimer);
    var d = delay == null ? CFG.renderDebounceMs : delay;
    if (d <= 16) {
      renderOnFrame(reason || 'scheduled-render');
      return;
    }
    state.renderTimer = setTimeout(function () { renderOnFrame(reason || 'scheduled-render'); }, d);
  }

  function scheduleFetch(reason, delay) {
    clearTimeout(state.fetchTimer);
    state.fetchTimer = setTimeout(function () { fetchEvents(reason || 'scheduled-fetch'); }, delay == null ? CFG.fetchDebounceMs : delay);
  }

  async function fetchEvents(reason) {
    if (!isArchiveMode()) return;

    var w = windowFromDom();
    var key = keyOf(w);
    var cached = state.cache[key];
    var now = Date.now();

    if (cached && now - cached.at < CFG.cacheTtlMs) {
      state.events = cached.events;
      state.lastError = '';
      render('cache:' + reason);
      return;
    }

    if (state.controller && state.controller.abort) {
      try { state.controller.abort(); } catch (_) {}
    }

    var controller = window.AbortController ? new AbortController() : null;
    state.controller = controller;
    state.seq += 1;
    var seq = state.seq;
    var candidates = urls(w);
    var lastErr = '';

    for (var i = 0; i < candidates.length; i++) {
      var url = candidates[i];
      try {
        log('fetch start', { seq: seq, reason: reason, url: mask(url) });
        var res = await fetch(url, { cache: 'no-store', signal: controller ? controller.signal : undefined });
        var text = await res.text();

        if (seq !== state.seq) {
          log('stale response ignored', { seq: seq });
          return;
        }

        if (!res.ok) {
          lastErr = 'HTTP ' + res.status + ' ' + text.slice(0, 200);
          warn('fetch non-ok', { status: res.status, url: mask(url), body: text.slice(0, 240) });
          continue;
        }

        var data = JSON.parse(text || '{}');
        var normalized = normalize(data);
        state.events = normalized;
        state.cache[key] = { at: Date.now(), events: normalized };
        state.lastEndpoint = url.indexOf('/public-events/') >= 0 ? 'public-events' : 'nd-events';
        state.lastError = '';
        state.lastReason = reason;
        render('fetch-ok:' + reason);
        log('events loaded', { endpoint: state.lastEndpoint, count: normalized.length, key: key });
        return;
      } catch (e) {
        if (e && e.name === 'AbortError') {
          log('request aborted', { seq: seq });
          return;
        }
        lastErr = e && (e.message || String(e));
        warn('fetch failed', { error: lastErr, url: mask(url) });
      }
    }

    state.lastError = lastErr || 'unknown error';
    render('fetch-failed-keep-current:' + reason);
  }

  function setInput(input, value) {
    if (!input) return;
    input.value = value;
    input.dispatchEvent(new Event('input', { bubbles: true }));
    input.dispatchEvent(new Event('change', { bubbles: true }));
  }

  function clickArchiveControl() {
    var buttons = Array.from(document.querySelectorAll('button, [role="button"], input[type="button"], input[type="submit"]'));
    var preferred = buttons.find(function (b) {
      var text = String((b.textContent || b.value || b.getAttribute('aria-label') || b.title || '')).toLowerCase();
      var action = String(b.getAttribute('data-action') || '').toLowerCase();
      return action === 'load-selection' || action === 'jump' || /загрузить|перейти|диапазон|архив|archive|dvr/.test(text);
    });
    if (!preferred) return false;
    preferred.click();
    return true;
  }

  function jumpByReload(ms) {
    var url = new URL(location.href);
    url.searchParams.set('proto', 'dvr');
    url.searchParams.set('dvr', 'true');
    url.searchParams.set('from', String(Math.floor((ms - 30000) / 1000)));
    url.searchParams.set('to', String(Math.floor((ms + 600000) / 1000)));
    url.searchParams.set('at', String(Math.floor(ms / 1000)));
    url.searchParams.set('deploy', 'v81-jump-' + Date.now());
    location.href = url.href;
  }

  function jumpToEvent(ms) {
    if (!Number.isFinite(ms)) return;
    var inputs = getDateInputs();
    if (inputs.length >= 2) {
      setInput(inputs[0], inputValue(ms - 30000));
      setInput(inputs[1], inputValue(ms + 600000));
      scheduleFetch('jump-to-event', 150);
      setTimeout(function () { if (!clickArchiveControl()) jumpByReload(ms); }, 120);
      return;
    }
    if (!clickArchiveControl()) jumpByReload(ms);
  }

  function scanWindow(reason, fetchDelay) {
    if (!isArchiveMode()) return;
    var w = windowFromDom();
    var key = keyOf(w);
    if (key !== state.lastScanKey) {
      state.lastScanKey = key;
      scheduleRender('window-change:' + (reason || 'scan'), 0);
      scheduleFetch('window-change:' + (reason || 'scan'), fetchDelay == null ? 180 : fetchDelay);
    } else {
      scheduleRender('layout-change:' + (reason || 'scan'), 0);
    }
  }

  function afterPlayerUpdate(reason, fetchDelay) {
    clearTimeout(state.scanTimer);
    state.scanTimer = setTimeout(function () { scanWindow(reason || 'after-player-update', fetchDelay); }, 0);
    if (window.requestAnimationFrame) {
      requestAnimationFrame(function () { scanWindow((reason || 'after-player-update') + ':raf', fetchDelay); });
    }
  }

  function ensureResizeObserver() {
    if (!window.ResizeObserver) return;
    var bar = document.querySelector('.bar');
    if (!bar) return;
    if (state.resizeObserver && state.observedBar === bar) return;
    try {
      if (state.resizeObserver) state.resizeObserver.disconnect();
      state.resizeObserver = new ResizeObserver(function () {
        scheduleRender('bar-resize-observer', 0);
      });
      state.resizeObserver.observe(bar);
      state.observedBar = bar;
    } catch (_) {}
  }

  function installObservers() {
    window.addEventListener('nd-player-timeline-change', function () {
      scheduleRender('player-timeline-change', 0);
      scheduleFetch('player-timeline-change', 120);
    }, { passive: true });

    document.addEventListener('wheel', function (ev) {
      var target = ev.target && ev.target.closest ? ev.target.closest('.bar, .timeline, .bottom') : null;
      if (target) afterPlayerUpdate('timeline-wheel', 220);
    }, { capture: true, passive: true });

    document.addEventListener('pointerdown', function (ev) {
      if (ev.target && ev.target.closest && ev.target.closest('.bar, .overview, .timeline')) afterPlayerUpdate('timeline-pointerdown', 220);
    }, true);

    document.addEventListener('pointermove', function (ev) {
      if (ev.target && ev.target.closest && ev.target.closest('.bar, .overview, .timeline')) afterPlayerUpdate('timeline-pointermove', 260);
    }, true);

    document.addEventListener('pointerup', function (ev) {
      if (ev.target && ev.target.closest && ev.target.closest('.bar, .overview, .timeline')) afterPlayerUpdate('timeline-pointerup', 160);
    }, true);

    document.addEventListener('click', function (ev) {
      if (ev.target && ev.target.closest && ev.target.closest('#nd-events-v81-layer, #nd-events-v81-panel')) return;
      var target = ev.target && ev.target.closest ? ev.target.closest('button, [role="button"], input, select, a') : null;
      if (!target) return;
      var text = String((target.textContent || target.value || target.title || target.getAttribute('aria-label') || '')).toLowerCase();
      var action = String(target.getAttribute('data-action') || '').toLowerCase();
      var preset = String(target.getAttribute('data-preset') || '').toLowerCase();
      if (/архив|dvr|archive|диапазон|загрузить|перейти|15м|1ч|6ч|24ч|\+|−|-/.test(text) || action || preset || target.closest('.timeline, .range-panel, .bottom')) {
        afterPlayerUpdate('ui-click', 180);
      } else {
        scheduleRender('generic-click', 0);
      }
    }, true);

    document.addEventListener('input', function (ev) {
      if (ev.target && ev.target.matches && ev.target.matches('input')) {
        scheduleRender('input-change-immediate', 0);
        scheduleFetch('input-change', 180);
      }
    }, true);

    document.addEventListener('change', function (ev) {
      if (ev.target && ev.target.matches && ev.target.matches('input, select')) {
        scheduleRender('form-change-immediate', 0);
        scheduleFetch('form-change', 180);
      }
    }, true);

    try {
      new MutationObserver(function (mutations) {
        var repair = needsDomRepair();
        var timelineChanged = false;
        for (var i = 0; i < mutations.length; i++) {
          var t = mutations[i].target;
          if (t && t.closest && t.closest('#nd-events-v81-layer, #nd-events-v81-panel')) continue;
          if (t && t.closest && t.closest('.timeline, .range-panel, .scale-label, .window-start, .window-mid, .window-end, .bar')) {
            timelineChanged = true;
            break;
          }
          if (mutations[i].type === 'childList') {
            var nodes = Array.prototype.slice.call(mutations[i].addedNodes || []).concat(Array.prototype.slice.call(mutations[i].removedNodes || []));
            if (nodes.some(function (n) { return n && n.nodeType === 1 && n.matches && n.matches('.bar, .timeline, .range-panel'); })) {
              timelineChanged = true;
              break;
            }
          }
        }
        if (repair) scheduleRender('dom-repair', 0);
        if (timelineChanged) afterPlayerUpdate('timeline-mutation', 180);
        ensureResizeObserver();
      }).observe(document.documentElement, { childList: true, subtree: true, characterData: true });
    } catch (_) {}

    window.addEventListener('resize', function () {
      scheduleRender('window-resize', 0);
    }, { passive: true });

    ensureResizeObserver();
    setInterval(function () { scanWindow('window-watchdog', 350); }, 250);
  }

  function boot() {
    log(VERSION + ' installed', { href: mask(location.href), camera_id: cameraId(), stream: streamName(), token: Boolean(token()) });
    installObservers();
    ensureResizeObserver();
    scanWindow('initial-scan', 250);
    scheduleFetch('initial', 300);
    setInterval(function () { scheduleFetch('poll'); }, CFG.pollMs);
  }

  window.ND_EVENTS_V81 = {
    version: VERSION,
    state: state,
    fetch: function () { return fetchEvents('manual'); },
    render: function () { return render('manual'); },
    scan: function () { return scanWindow('manual', 0); },
    window: windowFromDom,
    jumpToEvent: jumpToEvent,
    config: CFG
  };

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', boot);
  else boot();
})();
JS

chown root:root "$OVERLAY_JS"
chmod 0644 "$OVERLAY_JS"
node --check "$OVERLAY_JS"

echo
echo "===== Patch embed.html: use v81 overlay only ====="
python3 - "$EMBED_HTML" "$TS" <<'PY'
import pathlib, re, sys
path = pathlib.Path(sys.argv[1])
ts = sys.argv[2]
s = path.read_text()
orig = s

# Remove only events overlay scripts; keep base player/HLS/compat scripts untouched.
for name in ["events-overlay-v81", "events-overlay-v80", "events-overlay-v79", "events-overlay-v72", "events-overlay-v71"]:
    s = re.sub(rf'\s*<script\s+src="/newdomofon-player/{re.escape(name)}\.js(?:\?v=[^"]*)?"></script>\s*', "\n", s, flags=re.I)

# Ensure player.js has cache-busting but do not alter its code.
s = re.sub(
    r'<script\s+src="/newdomofon-player/player\.js(?:\?v=[^"]*)?"></script>',
    f'<script src="/newdomofon-player/player.js?v={ts}"></script>',
    s,
    count=1,
    flags=re.I,
)

player_tag = f'<script src="/newdomofon-player/player.js?v={ts}"></script>'
overlay_tag = f'<script src="/newdomofon-player/events-overlay-v81.js?v={ts}"></script>'

if player_tag in s and overlay_tag not in s:
    s = s.replace(player_tag, player_tag + "\n  " + overlay_tag, 1)

s = re.sub(r'\n{3,}', '\n\n', s)
path.write_text(s)

print("changed:", s != orig)
print("has_v81_overlay:", "events-overlay-v81" in s)
print("has_old_overlays:", bool(re.search(r'events-overlay-v7[129]', s)))
print("player_before_v81:", s.find("player.js") < s.find("events-overlay-v81") if "events-overlay-v81" in s else "unknown")
PY

echo
echo "===== Patch CSS: isolated overlay styles ====="
if ! grep -q "v81 exact player timeline events overlay" "$PLAYER_CSS"; then
cat >> "$PLAYER_CSS" <<'CSS'

/* v81 exact player timeline events overlay */
.bar { position: relative; }
#nd-events-v81-layer.nd-events-v81-layer {
  position: absolute;
  left: 0;
  right: 0;
  top: 16px;
  height: 28px;
  z-index: 60;
  pointer-events: none;
  contain: layout paint;
}
#nd-events-v81-layer .nd-events-v81-dot {
  pointer-events: auto;
  position: absolute;
  top: 0;
  width: 11px;
  height: 26px;
  margin-left: -5.5px;
  border: 0;
  border-radius: 999px;
  background: #ffcc00;
  box-shadow: 0 0 0 2px rgba(0,0,0,.70), 0 0 16px rgba(255,204,0,.95);
  cursor: pointer;
  padding: 0;
  z-index: 61;
}
#nd-events-v81-layer .nd-events-v81-dot:hover,
#nd-events-v81-layer .nd-events-v81-dot:focus {
  transform: scale(1.22);
  outline: 2px solid rgba(255,255,255,.9);
}
#nd-events-v81-panel.nd-events-v81-panel {
  display: flex;
  flex-direction: column;
  min-height: 0;
  max-height: 430px;
  overflow: hidden;
  border-bottom: 1px solid rgba(255,255,255,.08);
  background: rgba(255,204,0,.025);
  contain: layout paint;
}
#nd-events-v81-panel .nd-events-v81-head {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 8px;
  padding: 8px 10px;
  border-bottom: 1px solid rgba(255,255,255,.08);
  font-size: 13px;
}
#nd-events-v81-panel .nd-events-v81-list {
  overflow-y: auto;
  padding: 8px;
}
#nd-events-v81-panel .nd-events-v81-row {
  display: grid;
  grid-template-columns: 1fr;
  gap: 3px;
  width: 100%;
  text-align: left;
  border: 1px solid rgba(255,255,255,.12);
  border-radius: 10px;
  background: #101720;
  color: inherit;
  padding: 8px;
  margin-bottom: 8px;
  cursor: pointer;
}
#nd-events-v81-panel .nd-events-v81-row:hover,
#nd-events-v81-panel .nd-events-v81-row:focus {
  border-color: #ffcc00;
  background: rgba(255,204,0,.10);
  outline: none;
}
#nd-events-v81-panel .nd-events-v81-time {
  color: var(--muted, #9aa9b8);
  font-size: 12px;
}
#nd-events-v81-panel .nd-events-v81-type {
  font-weight: 800;
  font-size: 13px;
  overflow-wrap: anywhere;
}
#nd-events-v81-panel .nd-events-v81-state {
  color: #fbbf24;
  font-size: 12px;
}
#nd-events-v81-panel .nd-events-v81-empty {
  padding: 10px;
  color: var(--muted, #9aa9b8);
  font-size: 12px;
}
#nd-events-v81-panel ~ .events-list {
  display: none !important;
}
CSS
fi

echo
echo "===== Verify served files ====="
PLAYER_URL="${IP_SITE_URL%/}/newdomofon-player/player.js?v=$TS"
OVERLAY_URL="${IP_SITE_URL%/}/newdomofon-player/events-overlay-v81.js?v=$TS"
TMP_PLAYER="/tmp/nd-v81-player-$TS.js"
TMP_OVERLAY="/tmp/nd-v81-overlay-$TS.js"
curl -k -fsS "$PLAYER_URL" -o "$TMP_PLAYER"
curl -k -fsS "$OVERLAY_URL" -o "$TMP_OVERLAY"
node --check "$TMP_PLAYER"
node --check "$TMP_OVERLAY"
rm -f "$TMP_PLAYER" "$TMP_OVERLAY"

echo
echo "===== Verify event endpoints, 6h window ====="
START="$(date -u -d '6 hours ago' +%FT%TZ)"
END="$(date -u +%FT%TZ)"
PUBLIC_URL="${IP_SITE_URL%/}/public-events/${CAMERA_ID}/events?start=${START}&end=${END}&stream=${STREAM_NAME}&token=${TOKEN:-TOKEN}"
ND_URL="${IP_SITE_URL%/}/nd-events/${CAMERA_ID}/events?start=${START}&end=${END}&stream=${STREAM_NAME}&token=${TOKEN:-TOKEN}"

check_events() {
  local title="$1" url="$2" body="/tmp/nd-v81-events-body.$$" headers="/tmp/nd-v81-events-headers.$$"
  echo
  echo "$title"
  echo "$url"
  curl -k -sS -D "$headers" -o "$body" --max-time 25 "$url" || true
  awk 'NR==1 || tolower($0) ~ /^content-type:|^cache-control:|^x-newdomofon/' "$headers" | tr -d '\r' || true
  python3 - "$body" <<'PY' || true
import json, pathlib, sys
p = pathlib.Path(sys.argv[1])
try:
    d = json.loads(p.read_text())
    items = d if isinstance(d, list) else (d.get("items") or d.get("events") or d.get("rows") or d.get("data") or [])
    print(json.dumps({
        "ok": d.get("ok") if isinstance(d, dict) else True,
        "count": len(items) if isinstance(items, list) else "not-list",
        "source": d.get("source") if isinstance(d, dict) else "array",
        "first": items[:2] if isinstance(items, list) else None,
        "errors": d.get("errors") if isinstance(d, dict) else None,
    }, ensure_ascii=False, indent=2))
except Exception as e:
    print(p.read_text()[:1600])
    print("parse_error:", e)
PY
  rm -f "$body" "$headers"
}
check_events "Public events endpoint:" "$PUBLIC_URL"
check_events "ND events endpoint fallback:" "$ND_URL"

echo
echo "===== Verify embed script tags ====="
EMBED_URL="${IP_SITE_URL%/}/${STREAM_NAME}/embed.html?token=${TOKEN:-TOKEN}&autoplay=false&dvr=true&proto=hls&camera_id=${CAMERA_ID}&deploy=v81-${TS}"
curl -k -fsS "$EMBED_URL" | grep -E 'script src|events-overlay-v8|events-overlay-v7|player.js|hls.min.js' || true

echo
echo "DONE."
echo
echo "Open with Ctrl+F5:"
echo "  ${IP_SITE_URL%/}/cameras/${CAMERA_ID}?deploy=v81-${TS}"
echo "  ${SITE_URL%/}/cameras/${CAMERA_ID}?deploy=v81-${TS}"
echo
echo "Expected:"
echo "  - Console: [NewDomofon events-v81] v81-exact-player-timeline-events installed"
echo "  - Yellow event markers stay visible and do not disappear after 10-15 seconds."
echo "  - Event dots reposition immediately when timeline is zoomed/panned/resized.
  - Event list is rendered by #nd-events-v81-panel, not by base .events-list."
echo
echo "Manual browser checks inside iframe console:"
echo "  window.ND_EVENTS_V81.state"
echo "  window.ND_EVENTS_V81.fetch()"
echo "  window.ND_EVENTS_V81.scan()
  document.querySelectorAll('#nd-events-v81-layer .nd-events-v81-dot').length"
echo
echo "Rollback v81:"
echo "  sudo cp '$BACKUP$EMBED_HTML' '$EMBED_HTML'"
echo "  sudo cp '$BACKUP$PLAYER_JS' '$PLAYER_JS'"
echo "  sudo cp '$BACKUP$PLAYER_CSS' '$PLAYER_CSS'"
echo "  sudo rm -f '$OVERLAY_JS'"
