#!/usr/bin/env node
/*
 * Headless smoke test for a generated report (demo or real).
 *
 *   node demo/verify_report.js docs/examples/demo_busy_db.html [shots_dir]
 *
 * Playwright is resolved portably: require('playwright') (set NODE_PATH to
 * a node_modules that has it, e.g. `T=$(mktemp -d); (cd $T && npm i
 * playwright@1.55); NODE_PATH=$T/node_modules node demo/verify_report.js`),
 * falling back to the old /opt/node22 global install.  The browser is the
 * bundled Chromium when installed, else system Chrome (channel 'chrome').
 *
 * Checks (exit code 1 on any failure):
 *   - 0 page / console errors on load, in every view x theme below;
 *   - the three views (Summary / Timeline / All sections, v1.6.0): the
 *     top-bar switch flips body.vs / .vt / .va, All sections shows the
 *     most sections, Timeline shows #timeline, the guide (#guide) and the
 *     About fold (#about) show in every view, #view= hash wins on load;
 *   - light and dark (the theme toggle) in each view;
 *   - every href="#..." resolves to exactly one id (a target-less .xlink
 *     the chrome hid is skipped), and no id is duplicated;
 *   - an entity-style jump: clicking an in-page link whose target is out
 *     of the current view switches view and shows the target;
 *   - tabs / click-to-sort / an expander still work (in All sections);
 *   - every a.ent (entity link, v1.6.0) has a target, and clicking each
 *     one visible in Summary switches view as needed and brings its
 *     target (row, card, section) into the viewport;
 *   - the Timeline view (v1.6.0): every lane source template was moved in,
 *     every "Timeline ->" (data-tl) target exists and a click lands on it,
 *     every grid label (a.ent) resolves; the full-span ASH chart's hover
 *     tooltip, legend toggle + restore, brush zoom + Reset, double-click
 *     reset, a window click pinning its grid column (ruler aria-pressed,
 *     gutter "vs <date>", amber stripe), Current unpinning + flashing,
 *     Enter / Esc, ruler pin + unpin on leaving the view, grid tooltip;
 * and writes screenshots per view x theme when shots_dir is given.
 */
const path = require('path');
const fs = require('fs');

function loadPlaywright() {
  const tries = ['playwright', 'playwright-core', '/opt/node22/lib/node_modules/playwright'];
  for (const t of tries) { try { return require(t); } catch (e) { /* next */ } }
  console.error('playwright not found: set NODE_PATH to a node_modules containing it');
  process.exit(2);
}
const { chromium } = loadPlaywright();

async function launch() {
  const opts = [
    { executablePath: '/opt/pw-browsers/chromium' },
    {},
    { channel: 'chrome' },
  ];
  for (const o of opts) {
    if (o.executablePath && !fs.existsSync(o.executablePath)) continue;
    try { return await chromium.launch(o); } catch (e) { /* next */ }
  }
  throw new Error('no Chromium / Chrome available for Playwright');
}

const VIEWS = { summary: 'vs', timeline: 'vt', all: 'va' };

(async () => {
  const file = path.resolve(process.argv[2] || 'docs/examples/demo_busy_db.html');
  const shots = process.argv[3] ? path.resolve(process.argv[3]) : null;
  if (shots) fs.mkdirSync(shots, { recursive: true });
  const browser = await launch();
  const failures = [];
  const fail = (m) => { failures.push(m); };

  async function openPage(hash, scheme) {
    const page = await browser.newPage({ viewport: { width: 1440, height: 1000 }, colorScheme: scheme || 'light' });
    const errors = [];
    page.on('pageerror', e => errors.push('pageerror: ' + e.message));
    page.on('console', m => { if (m.type() === 'error') errors.push('console.error: ' + m.text()); });
    await page.goto('file://' + file + (hash || ''), { waitUntil: 'load' });
    await page.waitForTimeout(1200);
    return { page, errors };
  }

  // ---- 1. load in the default view: inventory + link integrity --------
  {
    const { page, errors } = await openPage('', 'light');
    await page.evaluate(() => { try { localStorage.removeItem('awr-view'); localStorage.removeItem('awr-theme'); } catch (e) {} });
    await page.reload({ waitUntil: 'load' }); await page.waitForTimeout(1200);
    const info = await page.evaluate(() => {
      const sections = [...document.querySelectorAll('main > section, body > section')].map(s => s.id);
      let charts = 0;
      if (window.echarts) document.querySelectorAll('div').forEach(el => { if (echarts.getInstanceByDom(el)) charts++; });
      return {
        view: document.body.getAttribute('data-view'),
        bodyClass: document.body.className,
        sections, charts,
        bands: document.querySelectorAll('.bd').length,
        tables: document.querySelectorAll('table').length,
        rows: document.querySelectorAll('tbody tr').length,
        verdict: (document.querySelector('#verdict h1') || {}).textContent || '',
        cards: document.querySelectorAll('.fc').length,
        markers: (window.AWR_MARKERS || []).length,
        noCharts: document.body.classList.contains('no-charts'),
      };
    });
    console.log(JSON.stringify(info, null, 1));
    if (info.view !== 'summary') fail('default view is ' + info.view + ', expected summary');
    // every href="#x" resolves to exactly one id; no duplicate ids
    const links = await page.evaluate(() => {
      const ids = {};
      document.querySelectorAll('[id]').forEach(el => { ids[el.id] = (ids[el.id] || 0) + 1; });
      const dup = Object.keys(ids).filter(k => ids[k] > 1);
      const bad = [];
      let n = 0, pruned = 0;
      document.querySelectorAll('a[href^="#"]').forEach(a => {
        const h = a.getAttribute('href').slice(1);
        if (!h || /^view=/.test(h)) return;
        // a cross-link the chrome JS hid because its target was never
        // emitted (06 -> 11 / 18 xlinks; "P3: cross-links") is not a link
        if (a.hidden && a.classList.contains('xlink')) { pruned++; return; }
        n++;
        const id = h.split('!')[0];
        if (ids[id] !== 1) bad.push(h + ' (' + (ids[id] || 0) + ')');
      });
      return { n, dup, bad, pruned };
    });
    console.log('links: ' + links.n + ' in-page hrefs, ' + links.bad.length + ' unresolved, ' + links.dup.length + ' duplicate ids (' + links.pruned + ' target-less xlinks hidden by the chrome)');
    if (links.dup.length) fail('duplicate ids: ' + links.dup.slice(0, 10).join(', '));
    if (links.bad.length) fail('unresolved hrefs: ' + links.bad.slice(0, 10).join(', '));
    if (errors.length) fail('load: ' + errors.slice(0, 5).join(' | '));
    await page.close();
  }

  // ---- 2. every view x theme: 0 errors, the view contract --------------
  const counts = {};
  for (const v of Object.keys(VIEWS)) {
    for (const scheme of ['light', 'dark']) {
      const { page, errors } = await openPage('#view=' + v, scheme);
      // the theme toggle drives body.dark; make the page match the scheme under test
      const isDark = await page.evaluate(() => document.body.classList.contains('dark'));
      if ((scheme === 'dark') !== isDark) {
        await page.click('#theme-toggle'); await page.waitForTimeout(400);
      }
      const st = await page.evaluate((cls) => {
        const vis = el => !!el && el.getClientRects().length > 0;
        return {
          cls: document.body.classList.contains(cls),
          dark: document.body.classList.contains('dark'),
          sections: [...document.querySelectorAll('main > section')].filter(vis).length,
          guide: vis(document.getElementById('guide')),
          about: vis(document.getElementById('about')),
          timeline: vis(document.getElementById('timeline')),
          pressed: (document.querySelector('.topbar .seg [aria-pressed="true"]') || {}).textContent || '',
          hOverflow: document.documentElement.scrollWidth - document.documentElement.clientWidth,
        };
      }, VIEWS[v]);
      counts[v] = st.sections;
      const tag = v + '/' + scheme;
      if (!st.cls) fail(tag + ': body class ' + VIEWS[v] + ' missing (hash #view= must win)');
      if (st.dark !== (scheme === 'dark')) fail(tag + ': theme toggle did not reach ' + scheme);
      if (!st.guide) fail(tag + ': #guide not visible');
      if (!st.about) fail(tag + ': #about not visible');
      if ((v === 'timeline') !== st.timeline) fail(tag + ': #timeline visible=' + st.timeline);
      if (st.hOverflow > 1) fail(tag + ': horizontal page overflow ' + st.hOverflow + 'px');
      if (errors.length) fail(tag + ': ' + errors.slice(0, 5).join(' | '));
      console.log('view ' + tag + ': ' + st.sections + ' sections visible, switch=' + st.pressed.trim() + (errors.length ? ', ERRORS' : ', 0 errors'));
      if (shots) await page.screenshot({ path: path.join(shots, v + '-' + scheme + '.png'), fullPage: v !== 'all' });
      await page.close();
    }
  }
  if (!(counts.all > counts.summary && counts.summary > counts.timeline)) {
    fail('view sizes: expected all > summary > timeline, got ' + JSON.stringify(counts));
  }

  // ---- 3. interactions: the switch, a cross-view jump, tabs / sort / expander
  {
    const { page, errors } = await openPage('', 'light');
    const toggles = {};
    for (const v of ['all', 'timeline', 'summary']) {
      await page.click('.topbar .seg [data-v="' + v + '"]'); await page.waitForTimeout(250);
      const ok = await page.evaluate((c) => document.body.classList.contains(c), VIEWS[v]);
      toggles['switch-' + v] = ok ? 'ok' : 'FAIL';
      if (!ok) fail('switch to ' + v + ' failed');
    }
    const saved = await page.evaluate(() => { try { return localStorage.getItem('awr-view'); } catch (e) { return 'n/a'; } });
    toggles.persist = saved === 'summary' ? 'ok' : 'FAIL (' + saved + ')';
    if (saved !== 'summary') fail('awr-view not persisted on click: ' + saved);
    // cross-view jump: a link whose target is hidden in Summary
    const jumped = await page.evaluate(async () => {
      const vis = el => !!el && el.getClientRects().length > 0;
      const a = [...document.querySelectorAll('main a[href^="#"], header.report a[href^="#"]')].find(x => {
        const t = document.getElementById(x.getAttribute('href').slice(1).split('!')[0]);
        return vis(x) && t && !vis(t);
      });
      if (!a) return 'none';
      const id = a.getAttribute('href').slice(1).split('!')[0];
      a.click();
      await new Promise(r => setTimeout(r, 400));
      return vis(document.getElementById(id)) ? 'ok (' + id + ' -> ' + document.body.getAttribute('data-view') + ')' : 'FAIL (' + id + ')';
    });
    toggles.jump = jumped;
    if (/^FAIL/.test(jumped)) fail('cross-view jump: ' + jumped);
    // rail: a dimmed link switches view on click
    const rail = await page.evaluate(async () => {
      const a = document.querySelector('nav.toc a.vdim[href^="#"]');
      if (!a) return 'none';
      const id = a.getAttribute('href').slice(1);
      a.click();
      await new Promise(r => setTimeout(r, 400));
      const t = document.getElementById(id);
      return t && t.getClientRects().length ? 'ok (' + id + ')' : 'FAIL (' + id + ')';
    });
    toggles.rail = rail;
    if (/^FAIL/.test(rail)) fail('rail dimmed link: ' + rail);
    await page.evaluate(() => window.AWR_setView && window.AWR_setView('all', false));
    await page.waitForTimeout(300);
    const tab = await page.$('.tabs [data-t]:nth-child(2)');
    if (tab) {
      await tab.click(); await page.waitForTimeout(200);
      toggles.tabs = await page.evaluate(() => {
        const t = document.querySelector('.tabs [data-t]:nth-child(2)');
        const g = t.closest('.tabs').getAttribute('data-tabs');
        const p = document.querySelector(`.tabpanel[data-tabs="${g}"][data-t="${t.getAttribute('data-t')}"]`);
        return p && getComputedStyle(p).display !== 'none' ? 'ok' : 'FAIL';
      });
      if (toggles.tabs !== 'ok') fail('tabs');
    } else toggles.tabs = 'none';
    const th = await page.$('table:not([data-nosort]) thead th.num:not(.c-band)');
    if (th) { await th.click(); await page.waitForTimeout(200); toggles.sort = 'clicked'; }
    const exp = await page.$('.expander');
    if (exp) { await exp.click(); await page.waitForTimeout(200); toggles.expander = 'clicked'; }
    console.log('toggles', JSON.stringify(toggles));
    if (errors.length) fail('interactions: ' + errors.slice(0, 5).join(' | '));
    if (shots) await page.screenshot({ path: path.join(shots, 'top.png'), clip: { x: 0, y: 0, width: 1440, height: 1000 } });
    await page.close();
  }

  // ---- 4. entity links (v1.6.0 Summary): click every visible a.ent ------
  // Each must resolve to an emitted row / card (the chrome unwraps a link
  // whose target was never emitted), and the click must switch view if
  // needed, reveal the target and scroll it into the viewport.
  {
    const { page, errors } = await openPage('#view=summary', 'light');
    const inv = await page.evaluate(() => {
      const vis = el => !!el && el.getClientRects().length > 0;
      const all = [...document.querySelectorAll('a.ent')];
      const shown = all.filter(vis);
      shown.forEach((a, i) => a.setAttribute('data-vr', String(i)));
      return {
        total: all.length, visible: shown.length,
        dangling: all.filter(a => !document.getElementById(a.getAttribute('href').slice(1).split('!')[0])).map(a => a.getAttribute('href')),
        unwrapped: document.querySelectorAll('.ent-x').length,
      };
    });
    console.log('entity links: ' + inv.total + ' a.ent (' + inv.visible + ' visible in Summary), '
      + inv.dangling.length + ' dangling, ' + inv.unwrapped + ' unwrapped to text (target never emitted)');
    if (inv.dangling.length) fail('a.ent without a target: ' + inv.dangling.slice(0, 8).join(', '));
    let ok = 0; const bad = [];
    for (let i = 0; i < inv.visible; i++) {
      const r = await page.evaluate(async (i) => {
        if (window.AWR_setView) window.AWR_setView('summary', false);
        await new Promise(res => setTimeout(res, 60));
        const a = document.querySelector('a.ent[data-vr="' + i + '"]');
        if (!a) return { skip: 1 };
        const id = a.getAttribute('href').slice(1).split('!')[0];
        a.scrollIntoView({ block: 'center' });
        a.click();
        await new Promise(res => setTimeout(res, 420));
        const t = document.getElementById(id);
        if (!t) return { id, why: 'no target' };
        if (!t.getClientRects().length) return { id, why: 'target hidden (view ' + document.body.getAttribute('data-view') + ')' };
        const rc = t.getBoundingClientRect();
        if (rc.bottom < 0 || rc.top > window.innerHeight) return { id, why: 'target off screen (top ' + Math.round(rc.top) + ')' };
        return { id, ok: 1, view: document.body.getAttribute('data-view') };
      }, i);
      if (r.skip) continue;
      if (r.ok) ok++; else bad.push(r.id + ': ' + r.why);
    }
    console.log('entity links clicked: ' + ok + ' ok, ' + bad.length + ' failed');
    if (bad.length) fail('entity links: ' + bad.slice(0, 8).join(' | '));
    if (errors.length) fail('entity links: ' + errors.slice(0, 5).join(' | '));
    await page.close();
  }

  // ---- 5. the Timeline view (v1.6.0 phase 3): the full-span ASH chart and
  // the window grid.  Hover tooltip, legend toggle + restore, brush zoom +
  // Reset, double-click reset, a window click pins its grid column (ruler
  // aria-pressed, gutter "vs <date>"), Current unpins and flashes, Esc
  // clears; every "Timeline ->" target (data-tl) and every grid label
  // (a.ent) resolves.
  {
    const { page, errors } = await openPage('#view=timeline', 'light');
    const tl = {};
    const inv = await page.evaluate(() => {
      const vis = el => !!el && el.getClientRects().length > 0;
      const rows = [...document.querySelectorAll('#tl .lrows > .r')];
      const lanes = [...document.querySelectorAll('#tl .lane')].filter(l => !l.hidden).map(l => l.id + ':' + l.querySelectorAll('.lrows > .r').length);
      const dtl = [...document.querySelectorAll('a[data-tl]')].map(a => a.getAttribute('data-tl'));
      const missing = dtl.filter(id => !document.getElementById(id));
      const ent = [...document.querySelectorAll('#tl a.ent')];
      const dangling = ent.filter(a => !document.getElementById(a.getAttribute('href').slice(1).split('!')[0])).map(a => a.getAttribute('href'));
      const leftover = document.querySelectorAll('template.tl-src').length;
      return { ash: vis(document.getElementById('tl-ash')), grid: vis(document.getElementById('tl')), rows: rows.length, lanes,
               dtl: dtl.length, missing, ent: ent.length, dangling, leftover,
               chart: !!(window.AWR_DATA && AWR_DATA.ashx && AWR_DATA.ashx.classes && AWR_DATA.ashx.classes.length) };
    });
    console.log('timeline: ' + inv.rows + ' grid rows in lanes ' + inv.lanes.join(' ') + '; ' + inv.dtl + ' data-tl links (' + inv.missing.length + ' missing), '
      + inv.ent + ' label links (' + inv.dangling.length + ' dangling), ' + inv.leftover + ' unconsumed templates');
    if (!inv.grid) fail('timeline: #tl grid not visible');
    if (inv.missing.length) fail('timeline: data-tl targets missing: ' + inv.missing.slice(0, 8).join(', '));
    if (inv.dangling.length) fail('timeline: a.ent without a target: ' + inv.dangling.slice(0, 8).join(', '));
    if (inv.leftover) fail('timeline: ' + inv.leftover + ' <template class="tl-src"> never moved into a lane');
    // every data-tl link click lands on its row (Summary -> Timeline)
    const jumps = await page.evaluate(async () => {
      const out = { ok: 0, bad: [] };
      const links = [...document.querySelectorAll('a.jump[data-tl]')];
      for (const a of links) {
        window.AWR_setView('summary', false); await new Promise(r => setTimeout(r, 60));
        const id = a.getAttribute('data-tl');
        a.scrollIntoView({ block: 'center' }); a.click();
        await new Promise(r => setTimeout(r, 420));
        const t = document.getElementById(id);
        const rc = t && t.getBoundingClientRect();
        if (t && t.getClientRects().length && document.body.getAttribute('data-view') === 'timeline' && rc.top < innerHeight && rc.bottom > 0) out.ok++;
        else out.bad.push(id);
      }
      window.AWR_setView('timeline', false);
      return out;
    });
    tl.jumps = jumps.ok + ' ok' + (jumps.bad.length ? ', FAIL ' + jumps.bad.join(',') : '');
    if (jumps.bad.length) fail('timeline: data-tl jumps: ' + jumps.bad.join(', '));
    // grid labels: click each a.ent, its target must show
    const labels = await page.evaluate(async () => {
      const out = { ok: 0, bad: [] };
      const ids = [...document.querySelectorAll('#tl a.ent')].map(a => a.getAttribute('href'));
      for (const h of ids) {
        window.AWR_setView('timeline', false); await new Promise(r => setTimeout(r, 50));
        const a = document.querySelector('#tl a.ent[href="' + h + '"]');
        a.scrollIntoView({ block: 'center' }); a.click();
        await new Promise(r => setTimeout(r, 380));
        const t = document.getElementById(h.slice(1));
        if (t && t.getClientRects().length) out.ok++; else out.bad.push(h);
      }
      window.AWR_setView('timeline', false);
      return out;
    });
    tl.labels = labels.ok + ' ok' + (labels.bad.length ? ', FAIL ' + labels.bad.slice(0, 5).join(',') : '');
    if (labels.bad.length) fail('timeline: grid label links: ' + labels.bad.slice(0, 8).join(', '));
    await page.evaluate(() => window.scrollTo(0, 0)); await page.waitForTimeout(300);
    if (inv.chart && inv.ash) {
      const svg = await page.$('#ax-svg');
      const box = await svg.boundingBox();
      // hover: crosshair + tooltip with per-class AAS -- at a point off every
      // window stripe; when the stripes tile the whole span (step = window),
      // the stripe's own tooltip instead
      const hx = await page.evaluate((b) => {
        for (let f = 0.45; f < 0.95; f += 0.01) {
          const el = document.elementFromPoint(b.x + b.width * f, b.y + b.height * 0.6);
          if (el && !el.closest('.xwh')) return f;
        }
        return null;
      }, box);
      await page.mouse.move(box.x + box.width * (hx || 0.45), box.y + box.height * 0.6); await page.waitForTimeout(150);
      tl.hover = await page.evaluate((stripe) => { const t = document.getElementById('tip'); const ch = document.getElementById('ax-ch');
        if (!t || t.hidden || !/AAS/.test(t.textContent)) return 'FAIL';
        if (stripe) return /window/.test(t.textContent) ? 'ok (stripe)' : 'FAIL';
        return ch && ch.getAttribute('visibility') === 'visible' ? 'ok' : 'FAIL'; }, hx === null);
      if (!/^ok/.test(tl.hover)) fail('timeline: chart hover tooltip');
      // legend: hide the first class -> one layer less; hide every class but
      // the last -> the y axis rescales; show them all again -> restored
      const axState = () => page.evaluate(() => ({ n: document.querySelectorAll('#ax-svg path.xa').length,
        y: [...document.querySelectorAll('#ax-svg text.at')].map(t => t.textContent).join('|'),
        off: document.querySelectorAll('#ax-lg .axc[aria-pressed="false"]').length }));
      const s0 = await axState();
      const nBtn = await page.$$eval('#ax-lg .axc', b => b.length);
      await page.click('#ax-lg .axc'); await page.waitForTimeout(120);
      const s1 = await axState();
      for (let i = 1; i < nBtn - 1; i++) { await page.click('#ax-lg .axc:nth-child(' + (i + 1) + ')'); await page.waitForTimeout(40); }
      await page.waitForTimeout(120);
      const s2 = await axState();
      for (let i = 0; i < nBtn - 1; i++) { await page.click('#ax-lg .axc:nth-child(' + (i + 1) + ')'); await page.waitForTimeout(40); }
      await page.waitForTimeout(120);
      const s3 = await axState();
      const okL = s1.off === 1 && s1.n === s0.n - 1 && (nBtn < 3 || (s2.off === nBtn - 1 && s2.y !== s0.y)) && s3.off === 0 && s3.n === s0.n && s3.y === s0.y;
      tl.legend = okL ? 'ok' : 'FAIL ' + JSON.stringify([s0.n, s1.n, s2.off, s2.y === s0.y, s3.n, s3.y === s0.y]);
      if (!/^ok/.test(tl.legend)) fail('timeline: legend toggle ' + tl.legend);
      // brush zoom, then Reset
      const r0 = await page.evaluate(() => document.getElementById('ax-range').textContent);
      await page.mouse.move(box.x + box.width * 0.30, box.y + box.height * 0.5);
      await page.mouse.down(); await page.mouse.move(box.x + box.width * 0.40, box.y + box.height * 0.5, { steps: 6 }); await page.mouse.up();
      await page.waitForTimeout(200);
      const z = await page.evaluate(() => ({ r: document.getElementById('ax-range').textContent, reset: !document.getElementById('ax-reset').hidden }));
      tl.zoom = (z.reset && /zoomed/.test(z.r)) ? 'ok' : 'FAIL ' + z.r;
      if (tl.zoom !== 'ok') fail('timeline: brush zoom ' + tl.zoom);
      await page.click('#ax-reset'); await page.waitForTimeout(150);
      const rz = await page.evaluate(() => ({ r: document.getElementById('ax-range').textContent, reset: !document.getElementById('ax-reset').hidden }));
      tl.reset = (!rz.reset && rz.r === r0) ? 'ok' : 'FAIL';
      if (tl.reset !== 'ok') fail('timeline: reset zoom');
      // zoom again, double-click resets
      await page.mouse.move(box.x + box.width * 0.50, box.y + box.height * 0.5);
      await page.mouse.down(); await page.mouse.move(box.x + box.width * 0.62, box.y + box.height * 0.5, { steps: 6 }); await page.mouse.up();
      await page.waitForTimeout(150);
      await page.mouse.dblclick(box.x + box.width * 0.55, box.y + box.height * 0.5); await page.waitForTimeout(200);
      tl.dblclick = await page.evaluate((r0) => document.getElementById('ax-reset').hidden && document.getElementById('ax-range').textContent === r0
        && !document.body.hasAttribute('data-pw') ? 'ok' : 'FAIL', r0);
      if (tl.dblclick !== 'ok') fail('timeline: double-click reset');
      // a prior window stripe pins its grid column
      const pin = await page.evaluate(async () => {
        const hs = [...document.querySelectorAll('#ax-svg .xwh')].filter(x => x.getAttribute('data-w') !== '0');
        if (!hs.length) return 'none';
        const hwin = hs[Math.floor(hs.length / 2)], w = hwin.getAttribute('data-w');
        const rc = hwin.getBoundingClientRect();
        const o = { bubbles: true, clientX: rc.left + rc.width / 2, clientY: rc.top + rc.height / 2, button: 0 };
        hwin.dispatchEvent(new MouseEvent('mousedown', o)); document.dispatchEvent(new MouseEvent('mouseup', o));
        await new Promise(r => setTimeout(r, 200));
        const h = document.querySelector('#tl .ruler .h[data-w="' + w + '"]');
        const gt = document.getElementById('tl-gt').textContent;
        const cells = document.querySelectorAll('#tl .lrows .c.pc[data-w="' + w + '"]').length;
        const d1 = document.querySelector('#tl .r.bars .g .d1');
        const ok = h.getAttribute('aria-pressed') === 'true' && document.body.getAttribute('data-pw') === w && cells > 0
          && /^vs /.test(gt) && (!d1 || / vs /.test(d1.textContent)) && document.querySelector('#ax-svg .xw.on');
        return ok ? 'ok (w=' + w + ', ' + gt.replace(/\s*clear$/, '') + ')' : 'FAIL ' + JSON.stringify([h.getAttribute('aria-pressed'), gt, cells]);
      });
      tl.pin = pin;
      if (/^FAIL/.test(pin)) fail('timeline: window click pin ' + pin);
      // Current unpins and flashes the Current column
      const unpin = await page.evaluate(async () => {
        const c = document.querySelector('#ax-svg .xwh[data-w="0"]');
        if (!c) return 'none';
        const rc = c.getBoundingClientRect();
        const o = { bubbles: true, clientX: rc.left + rc.width / 2, clientY: rc.top + rc.height / 2, button: 0 };
        c.dispatchEvent(new MouseEvent('mousedown', o)); document.dispatchEvent(new MouseEvent('mouseup', o));
        await new Promise(r => setTimeout(r, 120));
        const fl = document.querySelectorAll('#tl .c.colflash[data-w="0"]').length;
        return (!document.body.hasAttribute('data-pw') && !document.querySelector('#tl .ruler .h[aria-pressed="true"]') && fl > 0
          && document.getElementById('tl-gt').textContent === 'vs prior mean') ? 'ok (' + fl + ' cells flashed)' : 'FAIL';
      });
      tl.unpin = unpin;
      if (/^FAIL/.test(unpin)) fail('timeline: Current unpin ' + unpin);
      // keyboard: Enter on a focused stripe pins, Esc clears
      const kb = await page.evaluate(() => {
        const hs = [...document.querySelectorAll('#ax-svg .xwh')].filter(x => x.getAttribute('data-w') !== '0');
        if (!hs.length) return 'none';
        const hwin = hs[0]; hwin.focus();
        hwin.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', bubbles: true }));
        const pinned = document.body.getAttribute('data-pw') === hwin.getAttribute('data-w');
        document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true }));
        return pinned && !document.body.hasAttribute('data-pw') ? 'ok' : 'FAIL';
      });
      tl.keys = kb;
      if (/^FAIL/.test(kb)) fail('timeline: Enter / Esc ' + kb);
      // a ruler date pins too, and leaving the view unpins
      const ruler = await page.evaluate(async () => {
        const h = document.querySelector('#tl .ruler .h:not(.cur)'); if (!h) return 'none';
        h.click(); await new Promise(r => setTimeout(r, 80));
        const a = document.body.getAttribute('data-pw') === h.getAttribute('data-w');
        window.AWR_setView('summary', false); await new Promise(r => setTimeout(r, 80));
        const b = !document.body.hasAttribute('data-pw');
        window.AWR_setView('timeline', false);
        return a && b ? 'ok' : 'FAIL';
      });
      tl.ruler = ruler;
      if (/^FAIL/.test(ruler)) fail('timeline: ruler pin / view unpin ' + ruler);
    } else tl.chart = 'no ASH payload';
    // grid hover tooltip
    const cell = await page.$('#tl .lrows .r.bars .c:not(.cur)');
    if (cell) {
      await cell.scrollIntoViewIfNeeded(); await cell.hover(); await page.waitForTimeout(120);
      tl.gridTip = await page.evaluate(() => { const t = document.getElementById('tip'); return t && !t.hidden && t.textContent.length > 5 ? 'ok' : 'FAIL'; });
      if (tl.gridTip !== 'ok') fail('timeline: grid hover tooltip');
    }
    console.log('timeline interactions', JSON.stringify(tl));
    if (shots) {
      await page.evaluate(() => window.scrollTo(0, 0)); await page.waitForTimeout(200);
      await page.screenshot({ path: path.join(shots, 'timeline-top.png') });
    }
    if (errors.length) fail('timeline: ' + errors.slice(0, 5).join(' | '));
    await page.close();
  }

  await browser.close();
  if (failures.length) { console.log('FAILURES:'); failures.forEach(f => console.log('  ' + f)); }
  else console.log('verify: OK');
  process.exit(failures.length ? 1 : 0);
})();
