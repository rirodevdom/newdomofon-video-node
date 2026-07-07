#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="${PROJECT_DIR:-/opt/newdomofon-video}"
PLAYER_DIR="${PLAYER_DIR:-/var/www/newdomofon-video/newdomofon-player}"
BACKUP_DIR="$PROJECT_DIR/backups/v123-event-bars-light-v81-native-$(date +%Y%m%d-%H%M%S)"

EMBED="$PLAYER_DIR/embed.html"
CSS="$PLAYER_DIR/player.css"
JS="$PLAYER_DIR/event-bars-light-v123.js"

echo "===== Validate paths ====="
echo "project: $PROJECT_DIR"
echo "player:  $PLAYER_DIR"
echo "backup:  $BACKUP_DIR"

test -d "$PROJECT_DIR"
test -d "$PLAYER_DIR"
test -f "$EMBED"
test -f "$CSS"

echo
echo "===== Backup ====="
mkdir -p "$BACKUP_DIR$PLAYER_DIR"
for f in \
  "$EMBED" \
  "$CSS" \
  "$PLAYER_DIR/event-bars-light-v123.js" \
  "$PLAYER_DIR/player-event-bars-v116.js" \
  "$PLAYER_DIR/player-event-bars-v116.1.js" \
  "$PLAYER_DIR/player-event-bars-v116.2.js" \
  "$PLAYER_DIR/player-event-bars-v117.js" \
  "$PLAYER_DIR/player-event-bars-v118.js" \
  "$PLAYER_DIR/player-event-bars-v119.js" \
  "$PLAYER_DIR/player-event-bars-v120.js" \
  "$PLAYER_DIR/archive-gaps-live-status-v121.js"
do
  if [ -f "$f" ]; then
    mkdir -p "$BACKUP_DIR$(dirname "$f")"
    cp -a "$f" "$BACKUP_DIR$f"
    echo "backup: $f"
  fi
done

echo
echo "===== Write lightweight v123 event bars ====="
cat > "$JS" <<'JS'
(function () {
  'use strict';

  const VERSION = 'v123-event-bars-light-v81-native';
  const LOG = '[NewDomofon event-bars-v123]';

  const state = {
    installedAt: new Date().toISOString(),
    lastRunAt: null,
    lastReason: null,
    lastError: null,
    lastEventsCount: 0,
    lastMarkersCount: 0,
    lastPairsCount: 0,
    lastBarsCount: 0,
    lastTicksCount: 0,
    lastLayerSelector: null,
    lastLaneSelector: null,
    lastMapMode: null,
    renderCount: 0,
    active: false,
    pairs: [],
    events: [],
  };

  let capturedEvents = [];
  let renderQueued = false;
  let layerObserver = null;
  let attachTimer = null;

  function debug(...args) {
    try { console.debug(LOG, ...args); } catch (_) {}
  }

  function toMs(v) {
    if (v == null || v === '') return NaN;
    if (v instanceof Date) return v.getTime();
    if (typeof v === 'number') return Number.isFinite(v) ? (v < 100000000000 ? v * 1000 : v) : NaN;
    if (typeof v === 'string') {
      const s = v.trim();
      if (!s) return NaN;
      if (/^\d+(\.\d+)?$/.test(s)) return toMs(Number(s));
      const t = Date.parse(s);
      return Number.isFinite(t) ? t : NaN;
    }
    return NaN;
  }

  function readState(api) {
    try {
      if (!api) return null;
      if (typeof api.state === 'function') return api.state();
      if (api.state && typeof api.state === 'object') return api.state;
    } catch (_) {}
    return null;
  }

  function getV81Events() {
    const s = readState(window.ND_EVENTS_V81);
    if (!s) return [];
    const arrays = [s.visible, s.events, s.items, s.fetched, s.raw, s.all];
    for (const a of arrays) {
      if (Array.isArray(a) && a.length) return a.slice();
    }
    return [];
  }

  function getItems(payload) {
    if (Array.isArray(payload)) return payload;
    if (!payload || typeof payload !== 'object') return [];
    if (Array.isArray(payload.items)) return payload.items;
    if (Array.isArray(payload.events)) return payload.events;
    if (Array.isArray(payload.data)) return payload.data;
    return [];
  }

  function eventMs(e) {
    return toMs(e && (
      e.occurred_at || e.occurredAt || e.time || e.ts || e.timestamp ||
      e.date || e.datetime || e.start || e.from
    ));
  }

  function motionState(e) {
    if (!e || typeof e !== 'object') return null;
    const vals = [
      e.IsMotion, e.is_motion, e.state, e.event_state, e.motion_state,
      e.value, e.active, e.motion,
      e.data && (e.data.IsMotion ?? e.data.is_motion ?? e.data.state ?? e.data.event_state),
      e.payload && (e.payload.IsMotion ?? e.payload.is_motion ?? e.payload.state ?? e.payload.event_state),
      e.metadata && (e.metadata.IsMotion ?? e.metadata.is_motion ?? e.metadata.state ?? e.metadata.event_state),
    ];
    for (const v of vals) {
      if (v === true || v === 1) return true;
      if (v === false || v === 0) return false;
      if (typeof v === 'string') {
        const s = v.trim().toLowerCase();
        if (['true', '1', 'yes', 'on', 'start', 'started', 'active', 'motion'].includes(s)) return true;
        if (['false', '0', 'no', 'off', 'end', 'ended', 'inactive', 'nomotion', 'no_motion'].includes(s)) return false;
      }
    }
    return null;
  }

  function eventKey(e) {
    const qs = new URLSearchParams(location.search);
    const cameraId = qs.get('camera_id') || qs.get('cameraId') || '';
    const m = location.pathname.match(/^\/([^/]+)\//);
    const stream = m && m[1] ? decodeURIComponent(m[1]) : (qs.get('stream') || qs.get('stream_name') || '');
    return [
      e.camera_id || e.cameraId || cameraId || '',
      e.stream_name || e.streamName || stream || '',
      e.event_type || e.topic || e.title || '',
      e.rule || e.rule_id || e.ruleId || '',
      e.video_source || e.videoSource || e.video_source_configuration || '',
      e.analytics_token || e.analyticsToken || '',
      e.source_name || e.source || '',
    ].map(v => String(v || '')).join('|');
  }

  function normalizedEvents() {
    const v81 = getV81Events();
    const source = v81.length ? v81 : capturedEvents;
    return source
      .map((raw, i) => ({ raw, i, ms: eventMs(raw), state: motionState(raw), key: eventKey(raw) }))
      .filter(e => Number.isFinite(e.ms))
      .sort((a, b) => a.ms - b.ms);
  }

  function buildPairs(events) {
    const queues = new Map();
    const pairs = [];
    const unpaired = [];

    for (const e of events) {
      if (e.state === true) {
        const q = queues.get(e.key) || [];
        q.push(e);
        queues.set(e.key, q);
      } else if (e.state === false) {
        const q = queues.get(e.key) || [];
        if (q.length) {
          const start = q.shift();
          if (e.ms >= start.ms) pairs.push({ start, end: e, key: e.key });
          queues.set(e.key, q);
        } else {
          unpaired.push(e);
        }
      } else {
        unpaired.push(e);
      }
    }

    for (const q of queues.values()) {
      for (const e of q) unpaired.push(e);
    }

    state.pairs = pairs;
    state.lastPairsCount = pairs.length;
    return { pairs, unpaired };
  }

  function v81Layer() {
    const selectors = [
      '#nd-events-v81-layer',
      '.nd-events-v81-layer',
      '#nd-v81-events-layer',
      '.timeline-events-layer',
      '[data-nd-events-layer]',
    ];
    for (const sel of selectors) {
      const el = document.querySelector(sel);
      if (el) {
        state.lastLayerSelector = sel;
        return el;
      }
    }
    state.lastLayerSelector = null;
    return null;
  }

  function markerElements() {
    const layer = v81Layer();
    const selectors = [
      '.nd-events-v81-dot',
      '.nd-event-v81-dot',
      '[data-nd-event-dot="1"]',
    ];
    const out = [];
    const seen = new Set();

    function add(el) {
      if (!el || seen.has(el)) return;
      seen.add(el);
      if (el.classList && (
        el.classList.contains('nd-event-bars-v123-layer') ||
        el.classList.contains('nd-event-bars-v123-bar') ||
        el.classList.contains('nd-event-bars-v123-tick')
      )) return;
      const r = el.getBoundingClientRect();
      if (!r || r.width > 40 || r.height > 48 || r.width < 1 || r.height < 1) return;
      if (r.right < 0 || r.left > innerWidth || r.bottom < 0 || r.top > innerHeight) return;
      out.push({
        el,
        rect: r,
        cx: r.left + r.width / 2,
        cy: r.top + r.height / 2,
        ms: toMs(el.dataset && (el.dataset.ms || el.dataset.eventMs || el.dataset.time || el.dataset.ts)),
      });
    }

    for (const sel of selectors) {
      document.querySelectorAll(sel).forEach(add);
    }

    if (layer && !out.length) {
      Array.from(layer.children || []).forEach(add);
    }

    out.sort((a, b) => a.cx - b.cx || a.cy - b.cy);
    state.lastMarkersCount = out.length;
    return out;
  }

  function greenish(color) {
    if (!color || color === 'transparent') return false;
    const m = color.match(/rgba?\((\d+),\s*(\d+),\s*(\d+)/i);
    if (!m) return false;
    const r = Number(m[1]), g = Number(m[2]), b = Number(m[3]);
    return g >= 90 && g > r + 25 && g > b + 15;
  }

  function median(vals) {
    const a = vals.filter(Number.isFinite).sort((x, y) => x - y);
    if (!a.length) return NaN;
    return a[Math.floor(a.length / 2)];
  }

  function tagFor(el) {
    if (!el) return null;
    if (el.id) return '#' + el.id;
    const cls = String(el.className || '').trim().split(/\s+/).filter(Boolean).slice(0, 3).join('.');
    return el.tagName.toLowerCase() + (cls ? '.' + cls : '');
  }

  function archiveLane(markers) {
    const forced = document.querySelector('[data-nd-archive-lane], .nd-archive-lane, .archive-lane, .archive-range, .timeline-archive, .timeline-coverage, .coverage-bar');
    if (forced) {
      const r = forced.getBoundingClientRect();
      if (r && r.width > 240 && r.height >= 2 && r.height <= 32) {
        state.lastLaneSelector = tagFor(forced);
        return { el: forced, rect: r };
      }
    }

    const markerY = markers.length ? median(markers.map(m => m.cy)) : NaN;
    const candidates = [];

    for (const el of Array.from(document.querySelectorAll('body *'))) {
      if (el.classList && el.classList.contains('nd-event-bars-v123-layer')) continue;
      const r = el.getBoundingClientRect();
      if (!r || r.width < 240 || r.height < 2 || r.height > 32) continue;
      if (r.right < 0 || r.left > innerWidth || r.bottom < 0 || r.top > innerHeight) continue;

      const cs = getComputedStyle(el);
      if (!greenish(cs.backgroundColor) && !greenish(cs.borderTopColor) && !greenish(cs.borderBottomColor)) continue;

      const yScore = Number.isFinite(markerY) ? Math.max(0, 500 - Math.abs((r.top + r.height / 2) - markerY) * 12) : 0;
      const score = r.width * 2 + yScore + (r.height >= 4 && r.height <= 14 ? 200 : 0);
      candidates.push({ el, rect: r, score });
    }

    candidates.sort((a, b) => b.score - a.score);
    const best = candidates[0] || null;
    state.lastLaneSelector = best ? tagFor(best.el) : null;
    return best;
  }

  function ensureLayer() {
    let el = document.querySelector('.nd-event-bars-v123-layer');
    if (!el) {
      el = document.createElement('div');
      el.className = 'nd-event-bars-v123-layer';
      el.dataset.version = VERSION;
      document.body.appendChild(el);
    }
    return el;
  }

  function mapEventsToMarkers(events, markers) {
    const map = new Map();
    if (!events.length || !markers.length) return map;

    const withMs = markers.filter(m => Number.isFinite(m.ms));
    if (withMs.length >= Math.min(5, Math.floor(markers.length * 0.5))) {
      for (const e of events) {
        let best = null;
        let bestD = Infinity;
        for (const m of withMs) {
          const d = Math.abs(m.ms - e.ms);
          if (d < bestD) {
            best = m;
            bestD = d;
          }
        }
        if (best && bestD <= 1500) map.set(e, best);
      }
      state.lastMapMode = 'dataset-ms';
      return map;
    }

    const n = Math.min(events.length, markers.length);
    for (let i = 0; i < n; i++) map.set(events[i], markers[i]);
    state.lastMapMode = 'sorted-index';
    return map;
  }

  function draw(layer, laneRect, x1, x2, cls, title) {
    const leftPx = Math.max(0, Math.min(laneRect.width, Math.min(x1, x2) - laneRect.left));
    const rightPx = Math.max(0, Math.min(laneRect.width, Math.max(x1, x2) - laneRect.left));
    const widthPx = Math.max(2, rightPx - leftPx);
    const el = document.createElement('span');
    el.className = cls;
    el.style.left = `${leftPx}px`;
    el.style.width = `${widthPx}px`;
    if (title) el.title = title;
    layer.appendChild(el);
  }

  function render(reason) {
    const events = normalizedEvents();
    const markers = markerElements();
    const lane = archiveLane(markers);
    const layer = ensureLayer();

    state.lastReason = reason;
    state.lastEventsCount = events.length;
    state.events = events.map(e => e.raw);

    if (!events.length || !markers.length || !lane) {
      layer.style.display = 'none';
      layer.replaceChildren();
      document.body.classList.remove('nd-event-bars-v123-active');
      state.active = false;
      state.lastBarsCount = 0;
      state.lastTicksCount = 0;
      state.lastError = !events.length ? 'events not found' : (!markers.length ? 'v81 markers not found' : 'archive lane not found');
      return state;
    }

    const { pairs, unpaired } = buildPairs(events);
    const map = mapEventsToMarkers(events, markers);

    const r = lane.rect;
    layer.style.display = 'block';
    layer.style.left = `${Math.round(r.left)}px`;
    layer.style.top = `${Math.round(r.top)}px`;
    layer.style.width = `${Math.round(r.width)}px`;
    layer.style.height = `${Math.max(3, Math.round(r.height))}px`;
    layer.replaceChildren();

    let bars = 0;
    let ticks = 0;

    for (const p of pairs) {
      const a = map.get(p.start);
      const b = map.get(p.end);
      if (!a || !b) continue;
      draw(layer, r, a.cx, b.cx, 'nd-event-bars-v123-bar', `${new Date(p.start.ms).toLocaleString()} — ${new Date(p.end.ms).toLocaleString()}`);
      bars++;
    }

    for (const e of unpaired) {
      const m = map.get(e);
      if (!m) continue;
      draw(layer, r, m.cx, m.cx + 2, 'nd-event-bars-v123-tick', new Date(e.ms).toLocaleString());
      ticks++;
    }

    state.lastRunAt = new Date().toISOString();
    state.lastError = null;
    state.lastBarsCount = bars;
    state.lastTicksCount = ticks;
    state.renderCount += 1;

    if (bars > 0 || ticks > 0) {
      document.body.classList.add('nd-event-bars-v123-active');
      state.active = true;
    } else {
      document.body.classList.remove('nd-event-bars-v123-active');
      state.active = false;
    }

    if (state.renderCount < 5 || reason === 'manual') {
      debug('rendered', {
        reason,
        events: events.length,
        markers: markers.length,
        pairs: pairs.length,
        bars,
        ticks,
        mapMode: state.lastMapMode,
        lane: state.lastLaneSelector,
      });
    }

    return state;
  }

  function schedule(reason) {
    if (renderQueued) return;
    renderQueued = true;
    requestAnimationFrame(() => {
      renderQueued = false;
      try { render(reason || 'scheduled'); } catch (err) {
        state.lastError = err && err.stack ? err.stack : String(err);
        console.warn(LOG, 'render failed', err);
      }
    });
  }

  function attachV81Observer() {
    const target = v81Layer();
    if (!target) return false;

    if (layerObserver) layerObserver.disconnect();
    layerObserver = new MutationObserver(() => schedule('v81-layer-mutation'));
    layerObserver.observe(target, {
      childList: true,
      attributes: true,
      subtree: true,
      attributeFilter: ['style', 'class', 'data-ms', 'data-event-ms', 'data-time', 'data-ts'],
    });

    schedule('v81-layer-observer-attached');
    debug('observing v81 layer', state.lastLayerSelector);
    return true;
  }

  function patchFetch() {
    const original = window.fetch;
    if (typeof original !== 'function' || original.__ndEventBarsV123Patched) return;

    const patched = function () {
      const args = Array.from(arguments);
      const raw = args && args[0] && (args[0].url || args[0]);
      const url = String(raw || '');
      const p = original.apply(this, args);

      try {
        if (url.includes('/public-events/') && url.includes('/events')) {
          p.then(async res => {
            try {
              const data = await res.clone().json();
              capturedEvents = getItems(data);
              schedule('public-events-fetch');
              setTimeout(() => schedule('public-events-fetch-post'), 120);
            } catch (_) {}
          }).catch(() => {});
        }
      } catch (_) {}

      return p;
    };

    patched.__ndEventBarsV123Patched = true;
    patched.__ndEventBarsV123Original = original;
    window.fetch = patched;
  }

  function install() {
    patchFetch();

    window.addEventListener('resize', () => schedule('resize'), { passive: true });
    window.addEventListener('orientationchange', () => schedule('orientationchange'), { passive: true });

    let attempts = 0;
    attachTimer = setInterval(() => {
      attempts += 1;
      if (attachV81Observer() || attempts > 40) clearInterval(attachTimer);
      schedule('attach-attempt');
    }, 500);

    setTimeout(() => schedule('initial-1'), 300);
    setTimeout(() => schedule('initial-2'), 1000);
    setTimeout(() => schedule('initial-3'), 2500);
  }

  window.ND_EVENT_BARS_V123 = {
    version: VERSION,
    run: () => render('manual'),
    schedule,
    state: () => ({ ...state }),
    events: () => state.events.slice(),
    pairs: () => state.pairs.slice(),
    layer: () => document.querySelector('.nd-event-bars-v123-layer'),
    attachObserver: attachV81Observer,
    clear: () => {
      const el = document.querySelector('.nd-event-bars-v123-layer');
      if (el) el.replaceChildren();
      document.body.classList.remove('nd-event-bars-v123-active');
      state.active = false;
    },
  };

  install();
  debug('installed');
})();
JS

echo
echo "===== Patch CSS ====="
python3 - "$CSS" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
css = path.read_text(encoding='utf-8', errors='ignore')

# Remove old heavy event-bar and gap blocks so they cannot override visibility.
markers = [
    "/* nd-event-bars-v116 */",
    "/* nd-event-bars-v1161 */",
    "/* nd-event-bars-v1162 */",
    "/* nd-event-bars-v117 */",
    "/* nd-event-bars-v118 */",
    "/* nd-event-bars-v119 */",
    "/* nd-event-bars-v120 */",
    "/* nd-archive-gaps-v121 */",
    "/* nd-player-performance-safe-v122 */",
    "/* nd-event-bars-v123 */",
]
for marker in markers:
    while marker in css:
        start = css.find(marker)
        ends = [css.find(m, start + len(marker)) for m in markers if css.find(m, start + len(marker)) != -1]
        end = min(ends) if ends else len(css)
        css = css[:start].rstrip() + "\n\n" + css[end:].lstrip()

block = r'''
/* nd-event-bars-v123 */
.nd-event-bars-v1162-layer,
.nd-event-bars-v117-layer,
.nd-event-bars-v118-layer,
.nd-event-bars-v119-layer,
.nd-event-bars-v120-layer,
.nd-archive-gaps-v121-layer {
  display: none !important;
  visibility: hidden !important;
  pointer-events: none !important;
}

.nd-event-bars-v123-layer {
  position: fixed;
  z-index: 2147483000;
  pointer-events: none;
  overflow: hidden;
  background: transparent !important;
  contain: layout style paint;
}

.nd-event-bars-v123-bar,
.nd-event-bars-v123-tick {
  position: absolute;
  top: 0;
  height: 100%;
  border-radius: 1px;
  background: #f0c018;
  box-shadow: 0 0 4px rgba(240, 192, 24, .75);
  pointer-events: none;
  transition: none !important;
}

.nd-event-bars-v123-tick {
  min-width: 2px;
  opacity: .98;
}

/* v81 dots must stay in DOM and measurable. Hide only visually after v123 successfully drew bars. */
body.nd-event-bars-v123-active .nd-events-v81-dot,
body.nd-event-bars-v123-active .nd-event-v81-dot,
body.nd-event-bars-v123-active [data-nd-event-dot="1"] {
  opacity: 0 !important;
  visibility: hidden !important;
  display: block !important;
}

body:not(.nd-event-bars-v123-active) .nd-events-v81-dot,
body:not(.nd-event-bars-v123-active) .nd-event-v81-dot,
body:not(.nd-event-bars-v123-active) [data-nd-event-dot="1"] {
  opacity: 1 !important;
  visibility: visible !important;
  display: block !important;
}

#nd-v96-event-links,
#nd-v97-event-links,
#nd-v99-event-links,
#nd-v100-event-links,
#nd-v102-event-links,
#nd-v103-event-links,
#nd-v104-event-links,
#nd-v105-event-links,
#nd-v107-event-links,
.nd-v96-event-link,
.nd-v97-event-link,
.nd-v99-event-link,
.nd-v100-event-link,
.nd-v102-event-link,
.nd-v103-event-link,
.nd-v104-event-link,
.nd-v105-event-link,
.nd-v107-event-link {
  display: none !important;
}
'''
css += "\n\n" + block + "\n"
path.write_text(css, encoding='utf-8')
print(f"css patched: {path}")
PY

echo
echo "===== Patch embed.html ====="
python3 - "$EMBED" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
html = path.read_text(encoding='utf-8', errors='ignore')
before = html

# Remove heavy old layers and previous v123.
patterns = [
    r'archive-gaps-live-status-v121\.js',
    r'player-event-bars-v116(?:\.1|\.2)?\.js',
    r'player-event-bars-v117\.js',
    r'player-event-bars-v118\.js',
    r'player-event-bars-v119\.js',
    r'player-event-bars-v120\.js',
    r'event-bars-light-v123\.js',
]
for pat in patterns:
    html = re.sub(r'\s*<script[^>]+%s[^>]*>\s*</script>\s*' % pat, '\n', html, flags=re.I)

script = '<script src="/newdomofon-player/event-bars-light-v123.js?v=123-20260608"></script>'

# Load before events-v81 so we can capture its public-events request, but rendering waits for v81 layer.
m = re.search(r'(<script[^>]+events-overlay-v81\.js[^>]*>\s*</script>)', html, flags=re.I)
if m:
    html = html[:m.start()] + script + "\n" + html[m.start():]
else:
    m = re.search(r'(<script[^>]+player\.js[^>]*>\s*</script>)', html, flags=re.I)
    if m:
        html = html[:m.end()] + "\n" + script + html[m.end():]
    else:
        html = html.replace('</body>', script + '\n</body>') if '</body>' in html else html + "\n" + script + "\n"

path.write_text(html, encoding='utf-8')
print(f"embed patched: {path}")
print("changed:", html != before)
print("has_v123:", "event-bars-light-v123.js" in html)
print("has_old_heavy:", bool(re.search(r'player-event-bars-v11|player-event-bars-v12|archive-gaps-live-status-v121', html)))
PY

echo
echo "===== Remove old generated heavy files ====="
for f in \
  "$PLAYER_DIR/player-event-bars-v116.js" \
  "$PLAYER_DIR/player-event-bars-v116.1.js" \
  "$PLAYER_DIR/player-event-bars-v116.2.js" \
  "$PLAYER_DIR/player-event-bars-v117.js" \
  "$PLAYER_DIR/player-event-bars-v118.js" \
  "$PLAYER_DIR/player-event-bars-v119.js" \
  "$PLAYER_DIR/player-event-bars-v120.js" \
  "$PLAYER_DIR/archive-gaps-live-status-v121.js"
do
  if [ -f "$f" ]; then
    rm -f "$f"
    echo "removed: $f"
  fi
done

echo
echo "===== Final checks ====="
grep -q 'event-bars-light-v123.js' "$EMBED"
test -f "$JS"

echo
echo "installed:"
echo "  frontend layer: $JS"
echo "  embed:          $EMBED"
echo "  css:            $CSS"
echo "backup:"
echo "  $BACKUP_DIR"

cat <<'EOF'

Browser iframe console checks:
  window.ND_EVENT_BARS_V123
  window.ND_EVENT_BARS_V123.run()
  window.ND_EVENT_BARS_V123.state()
  window.ND_EVENT_BARS_V123.pairs().slice(0, 10)
  window.ND_EVENT_BARS_V123.layer()?.children.length

Expected:
  lastEventsCount > 0
  lastMarkersCount > 0
  lastPairsCount > 0
  lastBarsCount > 0
  active: true

Performance design:
  - No archive-gaps polling layer.
  - No full-document hot requestAnimationFrame loop.
  - MutationObserver is attached only to the v81 event layer after it appears.
  - If bars cannot render, native v81 markers remain visible.

Rollback:
  LAST_BACKUP="$(ls -td /opt/newdomofon-video/backups/v123-event-bars-light-v81-native-* | head -1)"
  sudo cp "$LAST_BACKUP/var/www/newdomofon-video/newdomofon-player/embed.html" "/var/www/newdomofon-video/newdomofon-player/embed.html"
  sudo cp "$LAST_BACKUP/var/www/newdomofon-video/newdomofon-player/player.css" "/var/www/newdomofon-video/newdomofon-player/player.css"
  sudo rm -f "/var/www/newdomofon-video/newdomofon-player/event-bars-light-v123.js"
EOF
