'use strict';
// dom/__tests__/epitaxy-surface.test.js — the CLAUDE CODE surface gap (§6).
//
// Claude Code inside Claude Desktop does not use the classic chat classes. It renders
// assistant markdown into `.epitaxy-markdown` and the user's own turn into
// `.epitaxy-user-turn`, neither of which was in the surface map — so that whole panel got
// no treatment at all: a Hebrew answer kept its list gutter and quote bar on the left, and
// a Hebrew user message inherited base LTR and came out with its runs scrambled.
//
// Same shape of fix as the progressive-markdown gap: the engine is untouched, the surface
// is simply reached now. These pin that, so a future refactor cannot silently drop it.

const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { loadInternals, el } = require('./harness.js');

const I = loadInternals();

const markdownHost = (children) => el('div', { class: 'epitaxy-markdown' }, children);
const userTurnHost = (children) => el('div', { class: 'epitaxy-user-turn' }, children);

// ---------------------------------------------------------------------------
// 1. The surface map reaches both roots.
// ---------------------------------------------------------------------------

test('SELECTORS.messageRoot matches an .epitaxy-markdown root', () => {
  assert.equal(markdownHost([]).matches(I.SELECTORS.messageRoot), true);
});

test('SELECTORS.messageRoot matches an .epitaxy-user-turn root', () => {
  assert.equal(userTurnHost([]).matches(I.SELECTORS.messageRoot), true);
});

// ---------------------------------------------------------------------------
// 2. The stylesheet anchors carry it too — CSS is the sole base-direction
//    mechanism for prose (§3.2), so a JS-only fix would leave the surface bare.
// ---------------------------------------------------------------------------

test('apply.css: every :where() anchor list with .standard-markdown also carries the epitaxy roots', () => {
  const css = fs.readFileSync(path.join(__dirname, '..', 'apply.css'), 'utf8');
  const groups = [...css.matchAll(/:where\(([^)]*)\)/g)].map((m) => m[1]);
  const anchored = groups.filter((g) => g.includes('.standard-markdown'));
  assert.ok(anchored.length >= 6, `expected the anchor groups, found ${anchored.length}`);
  for (const g of anchored) {
    const shown = g.replace(/\s+/g, ' ').trim();
    assert.ok(g.includes('.epitaxy-markdown'), `anchor group missing .epitaxy-markdown: ${shown}`);
    assert.ok(g.includes('.epitaxy-user-turn'), `anchor group missing .epitaxy-user-turn: ${shown}`);
  }
});

test('apply.css: the user turn holds its text in a div, so it needs its own leaf rule', () => {
  // `.epitaxy-user-turn` wraps its message in `.whitespace-pre-wrap`, not a <p>, so the
  // tag-listed leaf rule never reaches it and the anchor alone is not enough.
  const css = fs.readFileSync(path.join(__dirname, '..', 'apply.css'), 'utf8');
  assert.ok(
    /\.epitaxy-user-turn\s+\.whitespace-pre-wrap\s*\{[^}]*unicode-bidi:\s*plaintext/.test(css),
    'expected a plaintext rule for .epitaxy-user-turn .whitespace-pre-wrap'
  );
});

// ---------------------------------------------------------------------------
// 3. The Latin-opener override (§3.2/§8.K) now applies here as well — in both
//    directions, which is what separates it from "any RTL character wins".
// ---------------------------------------------------------------------------

test('a Latin-opening, majority-Hebrew paragraph under epitaxy gets the override', () => {
  // The case first-strong gets wrong in practice: the block opens with a Latin token, so
  // plaintext would render the whole Hebrew paragraph base-LTR and strand its full stop.
  const p = el('p', null, ['PR #7749 נסגר בלי מיזוג, צריך לפתוח מחדש.']);
  markdownHost([p]);
  I.processProseDir(p);
  assert.equal(p.getAttribute('dir'), 'rtl', 'majority-RTL block is corrected to rtl');
});

test('a majority-English paragraph quoting Hebrew under epitaxy is left alone', () => {
  const p = el('p', null, ['The word שלום means peace in Hebrew.']);
  markdownHost([p]);
  I.processProseDir(p);
  assert.equal(p.getAttribute('dir'), null, 'majority-LTR English must not flip');
});

test('a Hebrew-first paragraph under epitaxy is left to CSS plaintext', () => {
  const p = el('p', null, ['שלום, בדקתי את הקוד והכול תקין.']);
  markdownHost([p]);
  I.processProseDir(p);
  assert.equal(p.getAttribute('dir'), null, 'first-strong already resolves this one');
});
