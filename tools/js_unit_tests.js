#!/usr/bin/env node
/* tools/js_unit_tests.js -- unit tests of the pure helpers in the
 * generated client scripts (sql/lib/src/*.js), run with plain node: each
 * script is evaluated with a stub window / document, no browser.
 * Dev / CI only (tools/check.sh runs it when node is on PATH); nothing in
 * the report path depends on it.  No dependencies beyond node itself. */
'use strict';
const fs = require('fs');
const path = require('path');
const assert = require('assert');
const ROOT = path.join(__dirname, '..');
function load(name, win) {
  win = win || {};
  win.addEventListener = win.addEventListener || function () {};
  const doc = { body: null, readyState: 'complete', addEventListener: function () {},
                querySelectorAll: function () { return []; } };
  const src = fs.readFileSync(path.join(ROOT, 'sql/lib/src', name + '.js'), 'utf8');
  new Function('window', 'document', src)(win, doc);
  return win;
}
let passed = 0;
function test(name, fn) { fn(); passed++; console.log('ok - ' + name); }
function mean(a) { return a.reduce((s, v) => s + v, 0) / a.length; }
function sd(a) { const m = mean(a); return Math.sqrt(a.reduce((s, v) => s + (v - m) * (v - m), 0) / (a.length - 1)); }

/* ---- tests go here ---- */

/* ---- plan 027: W.patterns / W.patternText (js_wingrid) ---- */
{
  const W = load('js_wingrid').AWR_WG;
  const MARKS = [{ i: 2, l: 'Release 4.0' }, { i: 3, l: 'Hotfix 4.0.1' }, { i: 5, l: 'RU 19.28 patch' },
                 { i: 8, l: 'Release 4.1' }, { i: 12, l: 'Release 4.2' }];
  const ALL = new Array(13).fill(true);
  function tags(vals, valid, marks) {
    const p = vals.slice(0, -1).filter((v, i) => v != null && valid[i] !== false);
    return W.patterns(vals, valid, mean(p), sd(p), marks).map(t => t.k + (t.dir > 0 ? '+' : '-')
      + (t.at != null ? '@' + t.at : '') + (t.n != null ? '#' + t.n : '') + (t.m ? '[' + t.m + ']' : '') + (t.d ? '{' + t.d + '}' : '')).join(' ');
  }
  const PR = [3837.399, 3767.106, 3890.696, 3773.923, 3866.55, 3526.601, 3687.419, 3767.599,
              4850.898, 5072.253, 4809.715, 4868.913, 22240.52];
  test('demo physical reads: jump after 4.2, step at 4.1', () =>
    assert.strictEqual(tags(PR, ALL, MARKS), 'jump+[Release 4.2] step+@8[Release 4.1]'));
  /* dbmint follow-up: a step on Current's side explains the spike, so no
     "Current only" (a jump names its marker and stays, above) */
  test('no markers: the step explains the spike', () => assert.strictEqual(tags(PR, ALL, []), 'step+@8'));
  test('test DB: two high windows before Current, step not spike', () =>
    assert.strictEqual(tags([0.1882, 0.1869, 0.1903, 0.2073, 2.9832, 0.3781, 3.2446, 4.4893, 6.4895],
      new Array(9).fill(true), []), 'step+@6'));
  test('spike against a step the other way stays', () =>
    assert.strictEqual(tags([200, 205, 198, 202, 201, 199, 203, 200, 150, 148, 152, 149, 260], ALL, []), 'spike+ step-@8'));
  const SK = PR.slice(); SK[3] = null; SK[9] = null;
  const SKV = ALL.slice(); SKV[3] = false; SKV[9] = false;
  test('skipped windows are unknown, not absent', () =>
    assert.strictEqual(tags(SK, SKV, MARKS), 'jump+[Release 4.2] step+@8[Release 4.1]'));
  test('flat: nothing', () => assert.strictEqual(tags([100, 101, 99, 100, 102, 98, 100, 101, 99, 100, 100, 101, 100], ALL, []), ''));
  test('noisy flat: nothing', () => assert.strictEqual(tags([100, 90, 110, 95, 105, 100, 92, 108, 97, 103, 99, 101, 104], ALL, []), ''));
  test('linear rise: trend, not step', () =>
    assert.strictEqual(tags([100, 110, 120, 130, 140, 150, 160, 170, 180, 190, 200, 210, 300], ALL, []), 'spike+ trend+#12'));
  test('falling trend, Current inside band', () =>
    assert.strictEqual(tags([300, 290, 280, 270, 260, 250, 240, 230, 220, 210, 200, 190, 185], ALL, []), 'trend-#12'));
  test('run of 2 + step', () =>
    assert.strictEqual(tags([100, 101, 99, 100, 102, 98, 100, 101, 99, 100, 150, 160, 170], ALL, []), 'run+#2 step+@10'));
  test('drop + step down: the step explains it', () =>
    assert.strictEqual(tags([200, 205, 198, 202, 201, 199, 203, 200, 150, 148, 152, 149, 100], ALL, []), 'step-@8'));
  test('just below the floored band: dip', () =>
    assert.strictEqual(tags([100, 101, 99, 100, 102, 98, 100, 101, 99, 100, 100, 101, 96], ALL, []), 'spike-'));
  test('fewer than 4 valid priors: nothing', () =>
    assert.strictEqual(tags([null, null, null, null, null, null, null, null, null, 3, 4, 5, 9], ALL, []), ''));
  test('no Current value: nothing', () => assert.strictEqual(tags([1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, null], ALL, []), ''));
  /* plan 027 review: "Current only" must hold -- an earlier valid window
     outside the band on the same side means no spike / jump tag */
  test('recurring spike: no "Current only"', () =>
    assert.strictEqual(tags([100, 101, 99, 100, 102, 98, 100, 300, 99, 100, 100, 101, 320], ALL, MARKS), ''));
  const SB = [100, 101, 99, 100, 102, 98, 100, 101, 99, 100, 300, null, 320];
  const SBV = ALL.slice(); SBV[11] = false;
  test('skipped window before Current does not hide a high one before it', () =>
    assert.strictEqual(tags(SB, SBV, []), ''));
  const S8 = PR.slice(); S8[8] = null;
  const S8V = ALL.slice(); S8V[8] = false;
  test('step at a skipped window: the split with the marker wins', () =>
    assert.strictEqual(tags(S8, S8V, MARKS), 'jump+[Release 4.2] step+@8[Release 4.1]'));
  test('text', () => {
    const D = ['18 Jun', '25 Jun', '2 Jul', '9 Jul', '16 Jul', '23 Jul', '30 Jul', '6 Aug', '13 Aug', '20 Aug', '27 Aug', '3 Sep', '10 Sep'];
    assert.strictEqual(W.patternText({ k: 'jump', dir: 1, m: 'Release 4.2' }, D).text, 'jump after Release 4.2');
    assert.strictEqual(W.patternText({ k: 'step', dir: 1, at: 8, m: 'Release 4.1' }, D).text, 'step up at Release 4.1');
    assert.strictEqual(W.patternText({ k: 'step', dir: -1, at: 8, m: null }, D).text, 'step down on 13 Aug');
    assert.strictEqual(W.patternText({ k: 'spike', dir: -1, m: null }, D).text, 'dip: Current only');
    assert.strictEqual(W.patternText({ k: 'run', dir: 1, n: 3 }, D).text, 'high for 3 windows');
    assert.strictEqual(W.patternText({ k: 'trend', dir: -1, n: 12 }, D).text, 'falling across 12 windows');
    assert.strictEqual(W.patternText({ k: 'jump', dir: 1, m: 'A very long release name indeed' }, D).text, 'jump after A very long release nam...');
  });
  /* review follow-up R3: a "jump after" names only a marker at or before the
     start of the Current window; one inside Current (09:55 in a 09:00-10:00
     window) may follow the spike: a plain spike, its sentence says so */
  const FLAT = [100, 101, 99, 100, 102, 98, 100, 101, 99, 100, 100, 101, 300];
  test('a marker inside Current: plain spike, no "after"', () => {
    assert.strictEqual(tags(FLAT, ALL, [{ i: 12, l: 'Release 4.2', inw: true }]), 'spike+{Release 4.2}');
    assert.strictEqual(tags(FLAT, ALL, [{ i: 12, l: 'Release 4.2' }]), 'jump+[Release 4.2]');
    // one before the start and one inside: the one before is named
    assert.strictEqual(tags(FLAT, ALL, [{ i: 12, l: 'Early', inw: false }, { i: 12, l: 'Late', inw: true }]), 'jump+[Early]');
    // a step the same way still drops the spike (the jump stays: it names its marker)
    assert.strictEqual(tags(PR, ALL, [{ i: 8, l: 'Release 4.1' }, { i: 12, l: 'Release 4.2', inw: true }]), 'step+@8[Release 4.1]');
    const D = ['18 Jun', '25 Jun', '2 Jul', '9 Jul', '16 Jul', '23 Jul', '30 Jul', '6 Aug', '13 Aug', '20 Aug', '27 Aug', '3 Sep', '10 Sep'];
    const p = W.patternText({ k: 'spike', dir: 1, m: null, d: 'Release 4.2' }, D);
    assert.strictEqual(p.text, 'spike: Current only');
    assert.ok(/Release 4\.2 falls inside the Current window/.test(p.title) && !/before it/.test(p.title), p.title);
    assert.ok(!/inside/.test(W.patternText({ k: 'spike', dir: 1, m: null }, D).title));
  });
  test('markers(): a marker inside Current is flagged inw, on its left edge', () => {
    const win = { np: 2, w: [
      { o: 2, s: '2026-11-08 07:00', e: '2026-11-08 08:00' },
      { o: 1, s: '2026-11-08 08:00', e: '2026-11-08 09:00' },
      { o: 0, s: '2026-11-08 09:00', e: '2026-11-08 10:00' }] };
    const M = load('js_wingrid', { AWR_WIN: win, AWR_MARKERS: [
      { t: '2026-11-08 07:30', label: 'In -2' }, { t: '2026-11-08 08:55', label: 'Before' },
      { t: '2026-11-08 09:00', label: 'At start' }, { t: '2026-11-08 09:55', label: 'During' },
      { t: '2026-11-08 10:30', label: 'After the span' }] }).AWR_WG;
    const ms = M.markers().map(m => m.l + ':' + m.o + (m.inw ? '*' : '')).join(' ');
    assert.strictEqual(ms, 'In -2:1 Before:0 At start:0 During:0*');
    // the flag / icon slot takes any marker on the edge, an "after" text only one at or before the start
    assert.strictEqual(M.markerAt(0).l, 'During');
    assert.strictEqual(M.markerAt(0, true).l, 'At start');
    assert.strictEqual(M.markerAt(1, true).l, 'In -2');
    const only = load('js_wingrid', { AWR_WIN: win, AWR_MARKERS: [{ t: '2026-11-08 09:55', label: 'During' }] }).AWR_WG;
    assert.strictEqual(only.markerAt(0).l, 'During');
    assert.strictEqual(only.markerAt(0, true), null);
  });
}

/* ---- plan 031: W.rowScale / W.changeKey (js_wingrid) ---- */
{
  const W = load('js_wingrid').AWR_WG;
  const eq = (a, b) => assert.deepStrictEqual(a, b);
  test('rowScale outside the Timeline: the old rule', () => {
    eq(W.rowScale([1, 2, 3, 10], 4, false), { max: 10, brk: false });
    eq(W.rowScale([0, 0, 0, 0], null, false), { max: 1, brk: false });
  });
  test('rowScale in the Timeline: Current past 1.5 x the prior top is cut', () => {
    eq(W.rowScale([1, 2, 3, 10], 4, true), { max: 6, brk: true });
    eq(W.rowScale([1, 2, 3, 5], 4, true), { max: 5, brk: false });
    eq(W.rowScale([1, 2, 3, null], 4, true), { max: 4, brk: false });
    eq(W.rowScale([null, null, null, 5], null, true), { max: 5, brk: false });
    eq(W.rowScale([0, 0, 0, 0], null, true), { max: 1, brk: false });
    const r = W.rowScale([3837.399, 3767.106, 3890.696, 3773.923, 3866.55, 3526.601, 3687.419, 3767.599,
                          4850.898, 5072.253, 4809.715, 4868.913, 22240.52], 5283.51, true);
    assert.ok(r.brk && Math.abs(r.max - 7925.265) < 0.01, JSON.stringify(r));
  });
  test('changeKey: added AAS or |z|', () => {
    assert.strictEqual(W.changeKey([1, 1, 1, 4], 1, 0.1, true), 3);
    assert.ok(Math.abs(W.changeKey([1, 1, 1, 4], 1, 0.1, false) - 30) < 1e-9);
    assert.strictEqual(W.changeKey([10, 10, 10, 5], 10, 1, true), -5);
    assert.strictEqual(W.changeKey([10, 10, 10, 5], 10, 1, false), 5);
    assert.strictEqual(W.changeKey([1, 1, 1, null], 1, 0.1, true), null);
    assert.strictEqual(W.changeKey([0, 0, 0, 1], 0, 0, false), null);
    assert.strictEqual(W.changeKey([1, 2, 3, 4], null, null, false), null);
  });
  /* owner decision 2026-11-20: a row new in the Current window (no prior
     mean) in an AAS lane ranks by its Current value -- its valid prior
     windows count as 0 for the sort, skipped ones stay unknown */
  test('changeKey: a new row in an AAS lane', () => {
    const V = [true, true, true, true, true, true, true, true, true];
    const ARCH = [null, null, null, null, null, null, null, null, 8.598742];
    assert.strictEqual(W.changeKey(ARCH, null, null, true, V), 8.598742);
    // some skipped: left out of the mean, never 0
    assert.strictEqual(W.changeKey([null, 3, null, 6], null, null, true, [false, true, true, true]), 4.5);
    assert.strictEqual(W.changeKey([null, null, null, 6], null, null, true, [false, true, false, true]), 6);
    // no valid prior window: unknown (sorted last)
    assert.strictEqual(W.changeKey([null, null, null, 8.6], null, null, true, [false, false, false, true]), null);
    assert.strictEqual(W.changeKey([8.6], null, null, true, [true]), null);
    // no Current value, no validity of the row's length, a z lane: as before
    assert.strictEqual(W.changeKey([null, null, null, null], null, null, true, [true, true, true, true]), null);
    assert.strictEqual(W.changeKey(ARCH, null, null, true), null);
    assert.strictEqual(W.changeKey(ARCH, null, null, true, [true, true]), null);
    assert.strictEqual(W.changeKey(ARCH, null, null, false, V), null);
    // a known prior mean keeps Current minus the mean
    assert.strictEqual(W.changeKey([null, 1, 1, 4], 1, 0, true, [false, true, true, true]), 3);
  });
}

/* ---- plan 036 / owner decision 2026-11-20: AWR_TL.fitLabels (js_timeline),
   the Activity band labels fitted per band ---- */
{
  const F = load('js_timeline').AWR_TL.fitLabels;
  // a band over x 0..200 (a point every 2 px): lower edge y = 200, upper
  // edge from top(x); thickness = 200 - top(x)
  const band = (top, x1) => { const xs = [], yl = [], yh = []; for (let x = 0; x <= (x1 || 200); x += 2) { xs.push(x); yl.push(200); yh.push(top(x)); } return { xs, yl, yh }; };
  const run = (bands, o, groups) => {
    const G = groups || [{ x0: 0, x1: 200 }];
    const xs = bands[0].b.xs;
    return F(G.map(g => ({ xs, x0: g.x0, x1: g.x1 })),
      bands.map((B, k) => ({ k, alts: B.alts, yl: G.map(() => B.b.yl), yh: G.map(() => B.b.yh) })),
      Object.assign({ min: 10, max: 6, th: 12 }, o || {}));
  };
  const one = (w, txt) => [{ txt: txt || 'x', w }];
  test('flat band: centred in the run, thickness as the box', () => {
    const r = run([{ b: band(x => 180), alts: one(60) }]);
    assert.strictEqual(r.length, 1);
    assert.strictEqual(r[0].x, 100); assert.strictEqual(r[0].y, 190); assert.strictEqual(r[0].t, 20);
  });
  test('the thickest stretch as wide as the label, not the thickest point', () => {
    // a 4-px spike 100 px thick at x 30, a 30-px plateau 40 px thick at 140..170
    const r = run([{ b: band(x => (x >= 30 && x <= 32) ? 100 : (x >= 140 && x <= 170 ? 160 : 188)), alts: one(24) }]);
    assert.strictEqual(r.length, 1);
    assert.ok(r[0].x > 140 && r[0].x < 170 && r[0].t >= 30, JSON.stringify(r));
  });
  test('too thin anywhere: no label (and LBH is 10, not 13)', () => {
    assert.strictEqual(run([{ b: band(x => 191), alts: one(40) }]).length, 0);
    assert.strictEqual(run([{ b: band(x => 190), alts: one(40) }]).length, 1);
  });
  test('a shorter cut when the full name fits nowhere', () => {
    const b = band(x => (x >= 100 && x <= 150) ? 150 : 195);
    const r = run([{ b, alts: [{ txt: 'long name', w: 120 }, { txt: 'lo...', w: 40 }] }]);
    assert.strictEqual(r.length, 1); assert.strictEqual(r[0].txt, 'lo...');
    assert.ok(r[0].x - 20 >= 100 && r[0].x + 20 <= 150, JSON.stringify(r));
  });
  test('thickest band first; the next one moves clear of it or is left out', () => {
    // two series stacked: k0 at the bottom (200..170), k1 above it (170..130)
    const xs = [], A = { yl: [], yh: [] }, B = { yl: [], yh: [] };
    for (let x = 0; x <= 200; x += 2) { xs.push(x); A.yl.push(200); A.yh.push(170); B.yl.push(170); B.yh.push(130); }
    const r = F([{ xs, x0: 0, x1: 200 }], [{ k: 0, alts: one(60), yl: [A.yl], yh: [A.yh] }, { k: 1, alts: one(60), yl: [B.yl], yh: [B.yh] }], { min: 10, max: 6, th: 12 });
    assert.deepStrictEqual(r.map(l => l.k), [1, 0]);
    // one 12-px row shared by every candidate: the first takes the middle,
    // the next ones the nearest free places (2 px apart), then none is left
    const C = { yl: [], yh: [] }; for (let x = 0; x <= 200; x += 2) { C.yl.push(200); C.yh.push(188); }
    const r2 = F([{ xs, x0: 0, x1: 200 }], [0, 1, 2, 3].map(k => ({ k, alts: one(60), yl: [C.yl], yh: [C.yh] })), { min: 10, max: 6, th: 12 });
    assert.deepStrictEqual(r2.map(l => l.x), [100, 38, 162]);
    assert.strictEqual(F([{ xs, x0: 0, x1: 200 }], [0, 1].map(k => ({ k, alts: one(80), yl: [C.yl], yh: [C.yh] })), { min: 10, max: 6, th: 12 }).length, 1);
  });
  test('at most max labels', () => {
    const xs = [], S = [];
    for (let x = 0; x <= 200; x += 2) xs.push(x);
    for (let k = 0; k < 8; k++) S.push({ k, alts: one(30), yl: [xs.map(() => 200 - 20 * k)], yh: [xs.map(() => 180 - 20 * k)] });
    assert.strictEqual(F([{ xs, x0: 0, x1: 200 }], S, { min: 10, max: 6, th: 12 }).length, 6);
  });
  test('a label stays inside one group (panel)', () => {
    const b = band(x => 150);
    const G = [{ x0: 0, x1: 50 }, { x0: 56, x1: 106 }];
    const r = run([{ b, alts: one(40) }], {}, G);
    assert.strictEqual(r.length, 1);
    assert.ok(G.some(g => r[0].x - 20 >= g.x0 && r[0].x + 20 <= g.x1), JSON.stringify(r));
    assert.strictEqual(run([{ b, alts: one(60) }], {}, G).length, 0);
  });
  test('clear of the avoid box (the highlight note)', () => {
    const r = run([{ b: band(x => 150), alts: one(60) }], { avoid: [[0, 140, 200, 200]] });
    assert.strictEqual(r.length, 0);
    const r2 = run([{ b: band(x => 150), alts: one(60) }], { avoid: [[0, 140, 120, 200]] });
    assert.strictEqual(r2.length, 1); assert.ok(r2[0].x - 30 >= 122, JSON.stringify(r2));
  });
  test('the box stays above the axis (y1)', () => {
    const r = run([{ b: band(x => 190), alts: one(40) }], { y1: 200 });
    assert.strictEqual(r[0].y, 194);
  });
  test('labelAlts: a cut whose stem starts another series is dropped', () => {
    const L = load('js_timeline').AWR_TL.labelAlts;
    const names = ['log file switch (archiving needed)', 'log file sync', 'log file switch (checkpoint incomplete)', 'CPU'];
    const alts = [{ txt: 'log file switch (archiving ne...', w: 160 }, { txt: 'log file switch (a...', w: 110 },
                  { txt: 'log file swit...', w: 80 }, { txt: 'log file s...', w: 60 }];
    assert.deepStrictEqual(L(alts, names, 0).map(a => a.txt), ['log file switch (archiving ne...', 'log file switch (a...']);
    // an uncut name is always kept, even when it starts another name
    assert.deepStrictEqual(L([{ txt: 'log file sync', w: 70 }], ['log file sync', 'log file sync: SCN ordering'], 0).map(a => a.txt), ['log file sync']);
    assert.deepStrictEqual(L([{ txt: 'CPU', w: 24 }], names, 3).map(a => a.txt), ['CPU']);
  });
  test('no data past the points: no stretch there', () => {
    // points only over x 0..60, the group spans 0..200
    const r = run([{ b: band(x => 150, 60), alts: one(80) }]);
    assert.strictEqual(r.length, 0);
    const r2 = run([{ b: band(x => 150, 60), alts: one(50) }]);
    assert.strictEqual(r2.length, 1); assert.ok(r2[0].x + 25 <= 60, JSON.stringify(r2));
  });
}

/* ---- G4 (plan 025 follow-up): the micro strip's dense mode (js_microstrip) ---- */
{
  const strip = load('js_microstrip').AWR_microStrip;
  const csv = n => Array.from({ length: n }, (_, i) => (i === n - 1 ? 30 : 10 + (i % 24))).join(',');
  const count = (s, re) => (s.match(re) || []).length;
  test('13 windows: one bar each, dense or not', () => {
    const a = strip(csv(13), 'x'), b = strip(csv(13), 'x', { dense: true });
    assert.strictEqual(a.svg, b.svg);
    assert.strictEqual(count(a.svg, /<rect class="b/g), 13);
  });
  test('past 91 windows: nothing, unless dense', () => {
    assert.strictEqual(strip(csv(168), 'x'), '');
    const r = strip(csv(168), 'x', { dense: true });
    assert.strictEqual(count(r.svg, /<path class="b"/g), 1);
    assert.strictEqual(count(r.svg, /M[0-9.]+ 21V/g), 167);
    assert.strictEqual(count(r.svg, /<rect class="b cur" x="89"/g), 1);
    assert.ok(/; all 168 windows$/.test(r.title), r.title);
    // the silhouette ends left of the Current bar
    const xs = r.svg.match(/H([0-9.]+)V21Z/g).map(t => +t.slice(1, -4));
    assert.ok(Math.max(...xs) <= 88.0001, String(Math.max(...xs)));
  });
  test('dense: an empty window leaves a gap, an empty Current no bar', () => {
    const v = csv(100).split(','); v[5] = ''; v[99] = '';
    const r = strip(v.join(','), '', { dense: true });
    assert.strictEqual(count(r.svg, /M[0-9.]+ 21V/g), 98);
    assert.strictEqual(count(r.svg, /class="b cur"/g), 0);
  });
  test('60 windows: sub-pixel bars become dense only on request', () => {
    assert.strictEqual(count(strip(csv(60), '').svg, /<rect class="b/g), 60);
    assert.strictEqual(count(strip(csv(60), '', { dense: true }).svg, /<path class="b"/g), 1);
  });
}

console.log(passed + ' tests passed');
