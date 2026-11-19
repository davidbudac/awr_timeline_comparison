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
      + (t.at != null ? '@' + t.at : '') + (t.n != null ? '#' + t.n : '') + (t.m ? '[' + t.m + ']' : '')).join(' ');
  }
  const PR = [3837.399, 3767.106, 3890.696, 3773.923, 3866.55, 3526.601, 3687.419, 3767.599,
              4850.898, 5072.253, 4809.715, 4868.913, 22240.52];
  test('demo physical reads: jump after 4.2, step at 4.1', () =>
    assert.strictEqual(tags(PR, ALL, MARKS), 'jump+[Release 4.2] step+@8[Release 4.1]'));
  test('no markers: spike + step', () => assert.strictEqual(tags(PR, ALL, []), 'spike+ step+@8'));
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
  test('drop + step down', () =>
    assert.strictEqual(tags([200, 205, 198, 202, 201, 199, 203, 200, 150, 148, 152, 149, 100], ALL, []), 'spike- step-@8'));
  test('just below the floored band: dip', () =>
    assert.strictEqual(tags([100, 101, 99, 100, 102, 98, 100, 101, 99, 100, 100, 101, 96], ALL, []), 'spike-'));
  test('fewer than 4 valid priors: nothing', () =>
    assert.strictEqual(tags([null, null, null, null, null, null, null, null, null, 3, 4, 5, 9], ALL, []), ''));
  test('no Current value: nothing', () => assert.strictEqual(tags([1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, null], ALL, []), ''));
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
}

console.log(passed + ' tests passed');
