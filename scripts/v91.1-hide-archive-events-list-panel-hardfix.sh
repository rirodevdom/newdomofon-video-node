#!/usr/bin/env bash
set -euo pipefail

VERSION="v91.1-hide-archive-events-list-panel-hardfix"
PROJECT_DIR="${PROJECT_DIR:-/opt/newdomofon-video}"
PLAYER_DIR="${PLAYER_DIR:-/var/www/newdomofon-video/newdomofon-player}"
BACKUP_DIR="$PROJECT_DIR/backups/${VERSION}-$(date +%Y%m%d-%H%M%S)"

EMBED="$PLAYER_DIR/embed.html"
CSS="$PLAYER_DIR/player.css"
JS="$PLAYER_DIR/hide-archive-events-list-v91.1.js"
OLD_JS="$PLAYER_DIR/hide-archive-events-list-v91.js"

require_file() {
  if [[ ! -f "$1" ]]; then
    echo "ERROR: required file not found: $1" >&2
    exit 1
  fi
}

backup_file() {
  local f="$1"
  if [[ -f "$f" ]]; then
    local rel="${f#/}"
    mkdir -p "$BACKUP_DIR/$(dirname "$rel")"
    cp -a "$f" "$BACKUP_DIR/$rel"
    echo "backup: $f"
  fi
}

echo "===== Validate paths ====="
require_file "$EMBED"
require_file "$CSS"
mkdir -p "$BACKUP_DIR"

echo "===== Backup ====="
backup_file "$EMBED"
backup_file "$CSS"
backup_file "$JS"
backup_file "$OLD_JS"

echo "===== Write v91.1 hard hide archive events list layer ====="
cat > "$JS" <<'JAVASCRIPT'
(function () {
  'use strict';

  var VERSION = 'v91.1-hide-archive-events-list-panel-hardfix';
  var ROOT_CLASS = 'nd-hide-archive-events-list-v911';
  var HIDDEN_CLASS = 'nd-archive-events-list-hidden-v911';
  var PARENT_CLASS = 'nd-archive-events-parent-collapsed-v911';
  var ATTR = 'data-nd-hide-archive-events-list-v911';
  var PARENT_ATTR = 'data-nd-hide-archive-events-parent-v911';
  var scheduled = false;
  var debug = false;

  function log() {
    try { console.log.apply(console, ['[NewDomofon player-ui-v91.1]'].concat([].slice.call(arguments))); } catch (_) {}
  }

  function textOf(el) {
    try { return String(el && (el.innerText || el.textContent) || '').replace(/\s+/g, ' ').trim(); }
    catch (_) { return ''; }
  }

  function rectOf(el) {
    try { return el.getBoundingClientRect(); }
    catch (_) { return { width: 0, height: 0, left: 0, top: 0 }; }
  }

  function hasSelector(el, sel) {
    try { return !!(el && el.querySelector && el.querySelector(sel)); }
    catch (_) { return false; }
  }

  function isCorePlayerSurface(el) {
    if (!el || !el.closest) return false;
    return !!el.closest([
      'video',
      '.video',
      '.viewport',
      '.bar',
      '.timeline',
      '.ruler',
      '.controls',
      '.toolbar',
      '.range-start',
      '.range-end',
      '#nd-events-v79-layer',
      '#nd-events-v80-layer',
      '#nd-events-v81-layer',
      '#nd-events-v89-layer',
      '#nd-events-v90-layer',
      '#nd-events-v91-layer',
      '#nd-events-v911-layer',
      '#nd-archive-gaps-v88-layer',
      '#nd-archive-gaps-v89-layer'
    ].join(','));
  }

  function containsCorePlayer(el) {
    return hasSelector(el, [
      'video',
      '.bar',
      '.timeline',
      '.ruler',
      '.controls',
      '.toolbar',
      '.range-start',
      '.range-end'
    ].join(','));
  }

  function hasArchiveEventsSignature(el) {
    var t = textOf(el);
    if (!t) return false;

    // Main header/card signatures seen in the current player.
    if (/События\s+архива/i.test(t)) return true;
    if (/\bEvents\s*\d+\b/i.test(t) && /(Motion|CellMotionDetector|RuleEngine|tns1:|События)/i.test(t)) return true;

    // Event cards when header text is rendered by another component.
    if (/\d{2}\.\d{2}\.\d{4},\s*\d{1,2}:\d{2}:\d{2}/.test(t) && /(Motion|CellMotionDetector|RuleEngine|tns1:)/i.test(t)) return true;
    return false;
  }

  function isKnownEventListElement(el) {
    if (!el || el.nodeType !== 1 || isCorePlayerSurface(el)) return false;
    try {
      return el.matches([
        '.events',
        '.event-list',
        '.events-list',
        '.events-panel',
        '.event-panel',
        '.archive-events',
        '.archive-events-list',
        '.archive-events-panel',
        '[class*="event-list" i]',
        '[class*="events-list" i]',
        '[class*="archive-events" i]',
        '[id*="event-list" i]',
        '[id*="events-list" i]',
        '[id*="archive-events" i]',
        '#nd-events-v79-panel',
        '#nd-events-v80-panel',
        '#nd-events-v81-panel',
        '#nd-events-v89-panel',
        '#nd-events-v90-panel',
        '#nd-events-v91-panel',
        '#nd-events-v911-panel'
      ].join(','));
    } catch (_) {
      return false;
    }
  }

  function candidateIsPanelLike(el) {
    if (!el || el.nodeType !== 1) return false;
    if (el === document.body || el === document.documentElement) return false;
    if (containsCorePlayer(el)) return false;

    var t = textOf(el);
    if (!t || t.length > 60000) return false;
    if (!hasArchiveEventsSignature(el) && !isKnownEventListElement(el)) return false;

    var r = rectOf(el);
    var cls = String(el.className || '');
    var id = String(el.id || '');
    var named = /(event|events|archive|side|panel|drawer|list)/i.test(cls + ' ' + id);

    // The unwanted block is a side/list panel. It is normally narrow, but after CSS/layout changes
    // may briefly report zero width, so accept zero dimensions only if text/classes are strong.
    if (r.width === 0 && r.height === 0) return named || /События\s+архива/i.test(t);
    if (r.width <= 620 && r.height >= 40) return true;
    if (named && r.width <= 760 && r.height >= 40) return true;
    return false;
  }

  function scorePanel(el) {
    var t = textOf(el);
    var r = rectOf(el);
    var s = 0;
    if (/События\s+архива/i.test(t)) s += 80;
    if (/\bEvents\s*\d+\b/i.test(t)) s += 30;
    if (/(Motion|CellMotionDetector|RuleEngine|tns1:)/i.test(t)) s += 30;
    if (isKnownEventListElement(el)) s += 40;
    if (r.width > 0 && r.width <= 620) s += 30;
    if (r.height > 80) s += 15;
    if (containsCorePlayer(el)) s -= 1000;
    if (el === document.body || el === document.documentElement) s -= 1000;
    return s;
  }

  function chooseRootFromSeed(seed) {
    var best = seed;
    var bestScore = scorePanel(seed);
    var cur = seed;
    var guard = 0;

    while (cur && cur.parentElement && cur.parentElement !== document.body && cur.parentElement !== document.documentElement && guard++ < 12) {
      var p = cur.parentElement;
      if (containsCorePlayer(p)) break;
      var pt = textOf(p);
      if (!pt || pt.length > 60000) break;
      if (!hasArchiveEventsSignature(p) && !isKnownEventListElement(p)) break;

      var pr = rectOf(p);
      var parentScore = scorePanel(p);

      // Ascend while we are still inside the same narrow side panel. Stop before a broad page container.
      if ((pr.width === 0 || pr.width <= 680 || isKnownEventListElement(p)) && parentScore >= bestScore - 15) {
        best = p;
        bestScore = parentScore;
        cur = p;
        continue;
      }
      break;
    }
    return best;
  }

  function forceHide(el) {
    if (!el || el.nodeType !== 1) return false;
    if (el === document.body || el === document.documentElement) return false;
    if (containsCorePlayer(el)) return false;

    el.classList.add(HIDDEN_CLASS);
    el.setAttribute(ATTR, '1');
    el.setAttribute('aria-hidden', 'true');

    [
      ['display', 'none'],
      ['visibility', 'hidden'],
      ['content-visibility', 'hidden'],
      ['contain', 'strict'],
      ['width', '0'],
      ['min-width', '0'],
      ['max-width', '0'],
      ['height', '0'],
      ['min-height', '0'],
      ['max-height', '0'],
      ['flex', '0 0 0'],
      ['grid-column', 'auto'],
      ['overflow', 'hidden'],
      ['padding', '0'],
      ['margin', '0'],
      ['border', '0'],
      ['opacity', '0'],
      ['pointer-events', 'none']
    ].forEach(function (pair) {
      try { el.style.setProperty(pair[0], pair[1], 'important'); } catch (_) {}
    });

    collapseParent(el);
    return true;
  }

  function collapseParent(el) {
    var p = el && el.parentElement;
    if (!p || p === document.body || p === document.documentElement) return;
    if (containsCorePlayer(p)) {
      // Parent may be the main page layout containing player + sidebar. Do not hide it,
      // only remove the empty sidebar column/gap where safe.
      p.classList.add(PARENT_CLASS);
      p.setAttribute(PARENT_ATTR, '1');
      try {
        var cs = getComputedStyle(p);
        if (cs.display === 'grid') {
          p.style.setProperty('grid-template-columns', 'minmax(0, 1fr)', 'important');
          p.style.setProperty('column-gap', '0', 'important');
          p.style.setProperty('gap', '0', 'important');
        }
        if (cs.display === 'flex') {
          p.style.setProperty('column-gap', '0', 'important');
          p.style.setProperty('gap', '0', 'important');
        }
      } catch (_) {}
      return;
    }

    // If there is an intermediate wrapper that only exists for the list, hide it too.
    var t = textOf(p);
    if (hasArchiveEventsSignature(p) && !containsCorePlayer(p) && textOf(el) && t.length <= Math.max(1000, textOf(el).length + 4000)) {
      forceHide(p);
    }
  }

  function scanKnownSelectors() {
    var hidden = 0;
    try {
      document.querySelectorAll([
        '.events', '.event-list', '.events-list', '.events-panel', '.event-panel',
        '.archive-events', '.archive-events-list', '.archive-events-panel',
        '[class*="event-list" i]', '[class*="events-list" i]', '[class*="archive-events" i]',
        '[id*="event-list" i]', '[id*="events-list" i]', '[id*="archive-events" i]',
        '#nd-events-v79-panel', '#nd-events-v80-panel', '#nd-events-v81-panel',
        '#nd-events-v89-panel', '#nd-events-v90-panel', '#nd-events-v91-panel', '#nd-events-v911-panel'
      ].join(',')).forEach(function (el) {
        if (candidateIsPanelLike(el) || isKnownEventListElement(el)) {
          if (forceHide(chooseRootFromSeed(el))) hidden++;
        }
      });
    } catch (_) {}
    return hidden;
  }

  function scanTextSignatures() {
    var hidden = 0;
    var nodes;
    try {
      nodes = document.querySelectorAll('aside,section,nav,main > div,body > div,div,ul,ol');
    } catch (_) {
      return hidden;
    }

    nodes.forEach(function (el) {
      if (!candidateIsPanelLike(el)) return;
      var root = chooseRootFromSeed(el);
      if (forceHide(root)) hidden++;
    });
    return hidden;
  }

  function hideOrphanCards() {
    var hidden = 0;
    try {
      document.querySelectorAll('div,li').forEach(function (el) {
        if (containsCorePlayer(el)) return;
        var t = textOf(el);
        if (/\d{2}\.\d{2}\.\d{4},\s*\d{1,2}:\d{2}:\d{2}/.test(t) && /(Motion|CellMotionDetector|RuleEngine|tns1:)/i.test(t)) {
          if (forceHide(chooseRootFromSeed(el))) hidden++;
        }
      });
    } catch (_) {}
    return hidden;
  }

  function run() {
    scheduled = false;
    try { document.documentElement.classList.add(ROOT_CLASS); } catch (_) {}
    try { document.body && document.body.classList.add(ROOT_CLASS); } catch (_) {}

    var a = scanKnownSelectors();
    var b = scanTextSignatures();
    var c = hideOrphanCards();

    if (debug) log('run hidden:', { known: a, text: b, cards: c, total: hiddenCount() });
    return hiddenCount();
  }

  function schedule() {
    if (scheduled) return;
    scheduled = true;
    requestAnimationFrame(run);
  }

  function startObserver() {
    try {
      var mo = new MutationObserver(function () { schedule(); });
      mo.observe(document.documentElement, { childList: true, subtree: true, characterData: true });
      return mo;
    } catch (_) {
      return null;
    }
  }

  function hiddenCount() {
    try { return document.querySelectorAll('[' + ATTR + '="1"]').length; }
    catch (_) { return 0; }
  }

  function candidates() {
    var out = [];
    try {
      document.querySelectorAll('aside,section,nav,div,ul,ol').forEach(function (el) {
        if (candidateIsPanelLike(el)) {
          var r = rectOf(el);
          out.push({
            tag: el.tagName,
            id: el.id || '',
            className: String(el.className || '').slice(0, 200),
            width: Math.round(r.width),
            height: Math.round(r.height),
            score: scorePanel(el),
            text: textOf(el).slice(0, 300)
          });
        }
      });
    } catch (_) {}
    return out.sort(function (a, b) { return b.score - a.score; }).slice(0, 25);
  }

  window.ND_HIDE_ARCHIVE_EVENTS_LIST_V911 = {
    version: VERSION,
    run: run,
    schedule: schedule,
    hiddenCount: hiddenCount,
    candidates: candidates,
    debug: function (value) { debug = value !== false; return debug; }
  };

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', function () { run(); startObserver(); }, { once: true });
  } else {
    run();
    startObserver();
  }

  setTimeout(run, 100);
  setTimeout(run, 700);
  setTimeout(run, 2000);
  setInterval(schedule, 1500);
  log(VERSION + ' installed');
})();
JAVASCRIPT

echo "===== Patch CSS ====="
python3 - <<PY
from pathlib import Path
p = Path('$CSS')
s = p.read_text(encoding='utf-8', errors='ignore')
marker = '/* nd-v91.1-hide-archive-events-list-hardfix */'
block = r'''
/* nd-v91.1-hide-archive-events-list-hardfix */
.nd-archive-events-list-hidden-v911,
[data-nd-hide-archive-events-list-v911="1"],
html.nd-hide-archive-events-list-v911 .events:not(.event-band):not(.events-band),
body.nd-hide-archive-events-list-v911 .events:not(.event-band):not(.events-band),
html.nd-hide-archive-events-list-v911 .events-list,
body.nd-hide-archive-events-list-v911 .events-list,
html.nd-hide-archive-events-list-v911 .event-list,
body.nd-hide-archive-events-list-v911 .event-list,
html.nd-hide-archive-events-list-v911 .events-panel,
body.nd-hide-archive-events-list-v911 .events-panel,
html.nd-hide-archive-events-list-v911 .event-panel,
body.nd-hide-archive-events-list-v911 .event-panel,
html.nd-hide-archive-events-list-v911 .archive-events,
body.nd-hide-archive-events-list-v911 .archive-events,
html.nd-hide-archive-events-list-v911 .archive-events-list,
body.nd-hide-archive-events-list-v911 .archive-events-list,
html.nd-hide-archive-events-list-v911 .archive-events-panel,
body.nd-hide-archive-events-list-v911 .archive-events-panel,
html.nd-hide-archive-events-list-v911 #nd-events-v79-panel,
body.nd-hide-archive-events-list-v911 #nd-events-v79-panel,
html.nd-hide-archive-events-list-v911 #nd-events-v80-panel,
body.nd-hide-archive-events-list-v911 #nd-events-v80-panel,
html.nd-hide-archive-events-list-v911 #nd-events-v81-panel,
body.nd-hide-archive-events-list-v911 #nd-events-v81-panel,
html.nd-hide-archive-events-list-v911 #nd-events-v89-panel,
body.nd-hide-archive-events-list-v911 #nd-events-v89-panel,
html.nd-hide-archive-events-list-v911 #nd-events-v90-panel,
body.nd-hide-archive-events-list-v911 #nd-events-v90-panel,
html.nd-hide-archive-events-list-v911 #nd-events-v91-panel,
body.nd-hide-archive-events-list-v911 #nd-events-v91-panel,
html.nd-hide-archive-events-list-v911 #nd-events-v911-panel,
body.nd-hide-archive-events-list-v911 #nd-events-v911-panel {
  display: none !important;
  visibility: hidden !important;
  content-visibility: hidden !important;
  width: 0 !important;
  min-width: 0 !important;
  max-width: 0 !important;
  height: 0 !important;
  min-height: 0 !important;
  max-height: 0 !important;
  flex: 0 0 0 !important;
  overflow: hidden !important;
  padding: 0 !important;
  margin: 0 !important;
  border: 0 !important;
  opacity: 0 !important;
  pointer-events: none !important;
}

[data-nd-hide-archive-events-parent-v911="1"] {
  column-gap: 0 !important;
  gap: 0 !important;
}
'''
if marker in s:
    start = s.index(marker)
    s = s[:start].rstrip() + '\n' + block + '\n'
else:
    s = s.rstrip() + '\n\n' + block + '\n'
p.write_text(s, encoding='utf-8')
print('css patched:', p)
PY

echo "===== Patch embed.html ====="
python3 - <<PY
from pathlib import Path
import re
p = Path('$EMBED')
s = p.read_text(encoding='utf-8', errors='ignore')
# Remove old v91/v91.1 tags to avoid duplicate hide layers fighting each other.
s = re.sub(r'\s*<script[^>]+hide-archive-events-list-v91(?:\.1)?\.js[^>]*></script>', '', s)
script = '<script src="./hide-archive-events-list-v91.1.js?v=91.1"></script>'
if '</body>' in s:
    s = s.replace('</body>', '  ' + script + '\n</body>', 1)
else:
    s = s.rstrip() + '\n' + script + '\n'
p.write_text(s, encoding='utf-8')
print('embed patched:', p)
PY

echo "===== Static checks ====="
node --check "$JS" >/dev/null

echo
cat <<EOF2
installed: $JS
backup:    $BACKUP_DIR

Browser iframe console checks:
  window.ND_HIDE_ARCHIVE_EVENTS_LIST_V911
  window.ND_HIDE_ARCHIVE_EVENTS_LIST_V911.hiddenCount()
  window.ND_HIDE_ARCHIVE_EVENTS_LIST_V911.candidates()
  window.ND_HIDE_ARCHIVE_EVENTS_LIST_V911.run()

Expected:
  The block with "Events" / "События архива" disappears completely.
  Timeline event markers remain visible.
EOF2
