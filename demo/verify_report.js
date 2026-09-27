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
 *   - light and dark (the theme toggle) in each view; no visible link left
 *     in the browser's default blue / purple (unreadable in dark);
 *   - every href="#..." resolves to exactly one id (a target-less .xlink
 *     the chrome hid is skipped), and no id is duplicated;
 *   - an entity-style jump: clicking an in-page link whose target is out
 *     of the current view switches view and shows the target;
 *   - tabs / click-to-sort / an expander still work (in All sections);
 *   - every a.ent (entity link, v1.6.0) has a target, and clicking each
 *     one visible in Summary switches view as needed and brings its
 *     target (row, card, section) into the viewport;
 *   - the Activity charts (section#activity, v1.6.0): at the top of every
 *     view, above the verdict, both drawn (by wait class, by wait event);
 *     on each chart: hover crosshair + tooltip (mirrored on the other),
 *     legend toggle + restore (restack / rescale), brush zoom (zooms both),
 *     the 1-minute detail (payload vs ashx.win, zoom into Current -> 1-min)
 *     + Reset, double-click reset, a window click pinning its grid column
 *     (ruler aria-pressed, gutter "vs <date>", amber stripe on both
 *     charts); Current unpinning + flashing, Enter / Esc; "Other events"
 *     in the event legend (required for the demo, which has > 14 events);
 *   - the rail: no link state (active / hover) draws a left border or an
 *     inset shadow;
 *   - the Timeline view (v1.6.0): every lane source template was moved in,
 *     every "Timeline ->" (data-tl) target exists and a click lands on it,
 *     every grid label (a.ent) resolves; ruler pin (it survives a view
 *     switch), grid tooltip;
 *   - phase 4 (v1.6.0): every plan-change card sits in "What changed
 *     around it" with its bars, plan step line and links; every evidence
 *     library row (section.lib) shows in Summary with its one-line status,
 *     opens / shuts on a click and opens for a jump into it; one rail
 *     sub-link per finding card; All sections shows every library section
 *     in full; the Trend cells are micro strips (svg.mw), no line left;
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
          // the Activity charts: first visible section, both drawn
          act: (() => {
            const a = document.getElementById('activity');
            if (!vis(a)) return 'hidden';
            const secs = [...document.querySelectorAll('main > section')].filter(x => x !== a && vis(x));
            const top = a.getBoundingClientRect().top;
            const above = secs.filter(x => x.getBoundingClientRect().top < top).map(x => x.id);
            if (above.length) return 'below ' + above.slice(0, 3).join(',');
            const has = !!(window.AWR_DATA && AWR_DATA.ashx && AWR_DATA.ashx.classes && AWR_DATA.ashx.classes.length);
            const n1 = document.querySelectorAll('#ax-cls .axsvg path.xa').length, n2 = document.querySelectorAll('#ax-ev .axsvg path.xa').length;
            if (has && !(n1 && n2)) return 'not drawn (' + n1 + '/' + n2 + ')';
            if (!has && !vis(document.getElementById('ax-empty'))) return 'no data and no empty note';
            return 'ok';
          })(),
          pressed: (document.querySelector('.topbar .seg [aria-pressed="true"]') || {}).textContent || '',
          hOverflow: document.documentElement.scrollWidth - document.documentElement.clientWidth,
          // a visible link left in the browser's default blue / purple has no
          // report style (unreadable in dark)
          rawLinks: [...document.querySelectorAll('a')].filter(a => vis(a) &&
            /^rgb\((0, 0, 238|85, 26, 139)\)$/.test(getComputedStyle(a).color))
            .map(a => (a.parentElement.tagName + '.' + a.parentElement.className).slice(0, 40)).slice(0, 5),
        };
      }, VIEWS[v]);
      counts[v] = st.sections;
      const tag = v + '/' + scheme;
      if (!st.cls) fail(tag + ': body class ' + VIEWS[v] + ' missing (hash #view= must win)');
      if (st.dark !== (scheme === 'dark')) fail(tag + ': theme toggle did not reach ' + scheme);
      if (!st.guide) fail(tag + ': #guide not visible');
      if (!st.about) fail(tag + ': #about not visible');
      if ((v === 'timeline') !== st.timeline) fail(tag + ': #timeline visible=' + st.timeline);
      if (st.act !== 'ok') fail(tag + ': Activity charts ' + st.act);
      if (st.hOverflow > 1) fail(tag + ': horizontal page overflow ' + st.hOverflow + 'px');
      if (st.rawLinks.length) fail(tag + ': unstyled (browser-default colour) links in ' + st.rawLinks.join(', '));
      if (errors.length) fail(tag + ': ' + errors.slice(0, 5).join(' | '));
      console.log('view ' + tag + ': ' + st.sections + ' sections visible, switch=' + st.pressed.trim() + ', activity ' + st.act + (errors.length ? ', ERRORS' : ', 0 errors'));
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
    // the rail: no link state draws a left border or an inset shadow (the
    // owner's "crescent"): the active link, and a hovered one
    const railMark = async (sel) => page.evaluate((sel) => {
      const a = document.querySelector(sel); if (!a) return 'none';
      const cs = getComputedStyle(a);
      return (parseFloat(cs.borderLeftWidth) || 0) === 0 && cs.boxShadow === 'none' ? 'ok' : 'FAIL ' + cs.borderLeftWidth + ' / ' + cs.boxShadow;
    }, sel);
    await page.evaluate(() => { const a = document.querySelector('nav.toc a[href="#activity"]'); if (a && !document.querySelector('nav.toc a.on')) a.classList.add('on'); });
    const rOn = await railMark('nav.toc a.on');
    await page.hover('nav.toc a[href="#findings"]'); await page.waitForTimeout(200);
    const rHov = await railMark('nav.toc a[href="#findings"]');
    toggles.railMarker = rOn + ' / ' + rHov;
    if (/FAIL/.test(toggles.railMarker)) fail('rail link state marker: ' + toggles.railMarker);
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

  // ---- 5. the Timeline view and the Activity charts (v1.6.0): every
  // "Timeline ->" target (data-tl) and every grid label (a.ent) resolves;
  // on each Activity chart (by wait class, by wait event) hover (crosshair
  // mirrored), legend toggle + restore, brush zoom of both + Reset,
  // double-click reset, a window click pins its grid column (ruler
  // aria-pressed, gutter "vs <date>", amber on both), Current unpins and
  // flashes, Enter / Esc; a ruler pin survives a view switch.
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
      return { ash: vis(document.getElementById('ashx')), grid: vis(document.getElementById('tl')), rows: rows.length, lanes,
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
      const CHS = ['ax-cls', 'ax-ev'];
      const other = await page.evaluate(() => {
        const e = (window.AWR_DATA && AWR_DATA.ashe) || null;
        return { n: e && e.classes ? e.classes.length : 0,
                 last: e && e.classes ? e.classes[e.classes.length - 1] : '',
                 chip: [...document.querySelectorAll('#ax-ev .axlg .axc')].some(b => b.textContent === 'Other events') };
      });
      tl.events = other.n + ' series' + (other.last === 'Other events' ? ', Other events ' + (other.chip ? 'in the legend' : 'NOT in the legend') : '');
      if (other.last === 'Other events' && !other.chip) fail('activity: "Other events" missing from the event legend');
      if (other.n > 15 || (other.n === 15 && other.last !== 'Other events')) fail('activity: more than 14 events without the Other events rollup');
      if (/demo_busy_db\.html$/.test(file) && other.last !== 'Other events') fail('activity: the demo must show the "Other events" rollup');
      for (const id of CHS) {
        const k = id === 'ax-cls' ? 'cls' : 'ev';
        await page.evaluate(() => window.scrollTo(0, 0)); await page.waitForTimeout(150);
        const svg = await page.$('#' + id + ' .axsvg');
        const box = await svg.boundingBox();
        // hover: crosshair + tooltip with per-series AAS -- at a point off every
        // window stripe (when the stripes tile the whole span, step = window,
        // the stripe's own tooltip instead); the crosshair is mirrored on the
        // other chart at the same x
        const hx = await page.evaluate(([b, id]) => {
          for (let f = 0.45; f < 0.95; f += 0.01) {
            const el = document.elementFromPoint(b.x + b.width * f, b.y + b.height * 0.6);
            if (el && el.closest('#' + id) && !el.closest('.xwh')) return f;
          }
          return null;
        }, [box, id]);
        await page.mouse.move(box.x + box.width * (hx || 0.45), box.y + box.height * 0.6); await page.waitForTimeout(150);
        tl['hover_' + k] = await page.evaluate(([stripe, id]) => {
          const t = document.getElementById('tip');
          if (!t || t.hidden || !/AAS/.test(t.textContent)) return 'FAIL tooltip';
          if (stripe) return /window/.test(t.textContent) ? 'ok (stripe)' : 'FAIL';
          const chs = [...document.querySelectorAll('.ashx .axsvg .xch')];
          const on = chs.filter(c => c.getAttribute('visibility') === 'visible');
          if (on.length !== chs.length) return 'FAIL crosshair on ' + on.length + '/' + chs.length + ' charts';
          const xs = new Set(on.map(c => c.getAttribute('x1')));
          return xs.size === 1 ? 'ok (mirrored)' : 'FAIL crosshair x differs ' + [...xs].join(',');
        }, [hx === null, id]);
        if (!/^ok/.test(tl['hover_' + k])) fail('activity ' + k + ': hover ' + tl['hover_' + k]);
        await page.mouse.move(box.x + box.width * 0.5, box.y - 60); await page.waitForTimeout(80);
        // legend: hide the first series -> one layer less; hide every series but
        // the last -> the y axis rescales; show them all again -> restored
        const st = () => page.evaluate((id) => ({ n: document.querySelectorAll('#' + id + ' .axsvg path.xa').length,
          y: [...document.querySelectorAll('#' + id + ' .axsvg text.at')].map(t => t.textContent).join('|'),
          off: document.querySelectorAll('#' + id + ' .axlg .axc[aria-pressed="false"]').length }), id);
        const sel = '#' + id + ' .axlg .axc';
        const s0 = await st();
        const nBtn = await page.$$eval(sel, b => b.length);
        await page.click(sel); await page.waitForTimeout(120);
        const s1 = await st();
        for (let i = 1; i < nBtn - 1; i++) { await page.click(sel + ':nth-child(' + (i + 1) + ')'); await page.waitForTimeout(30); }
        await page.waitForTimeout(120);
        const s2 = await st();
        for (let i = 0; i < nBtn - 1; i++) { await page.click(sel + ':nth-child(' + (i + 1) + ')'); await page.waitForTimeout(30); }
        await page.waitForTimeout(120);
        const s3 = await st();
        const okL = s1.off === 1 && s1.n === s0.n - 1 && (nBtn < 3 || (s2.off === nBtn - 1 && s2.y !== s0.y)) && s3.off === 0 && s3.n === s0.n && s3.y === s0.y;
        tl['legend_' + k] = okL ? 'ok (' + nBtn + ' series)' : 'FAIL ' + JSON.stringify([s0.n, s1.n, s2.off, s2.y === s0.y, s3.n, s3.y === s0.y]);
        if (!/^ok/.test(tl['legend_' + k])) fail('activity ' + k + ': legend toggle ' + tl['legend_' + k]);
        // brush zoom on this chart zooms BOTH, then Reset restores both
        const paths = () => page.evaluate(() => [...document.querySelectorAll('.ashx .axsvg')].map(s => (s.querySelector('path.xa') || {}).getAttribute ? s.querySelector('path.xa').getAttribute('d') : ''));
        const r0 = await page.evaluate(() => document.getElementById('ax-range').textContent);
        const p0 = await paths();
        await page.mouse.move(box.x + box.width * 0.30, box.y + box.height * 0.5);
        await page.mouse.down(); await page.mouse.move(box.x + box.width * 0.40, box.y + box.height * 0.5, { steps: 6 }); await page.mouse.up();
        await page.waitForTimeout(200);
        const z = await page.evaluate(() => ({ r: document.getElementById('ax-range').textContent, reset: !document.getElementById('ax-reset').hidden }));
        const p1 = await paths();
        const both = p1.length === p0.length && p1.every((d, i) => d !== p0[i]);
        tl['zoom_' + k] = (z.reset && /zoomed/.test(z.r) && both) ? 'ok (both charts)' : 'FAIL ' + z.r + ' both=' + both;
        if (!/^ok/.test(tl['zoom_' + k])) fail('activity ' + k + ': brush zoom ' + tl['zoom_' + k]);
        await page.click('#ax-reset'); await page.waitForTimeout(150);
        const rz = await page.evaluate(() => ({ r: document.getElementById('ax-range').textContent, reset: !document.getElementById('ax-reset').hidden }));
        const p2 = await paths();
        tl['reset_' + k] = (!rz.reset && rz.r === r0 && p2.every((d, i) => d === p0[i])) ? 'ok' : 'FAIL';
        if (tl['reset_' + k] !== 'ok') fail('activity ' + k + ': reset zoom');
        // zoom again, double-click resets
        await page.mouse.move(box.x + box.width * 0.50, box.y + box.height * 0.5);
        await page.mouse.down(); await page.mouse.move(box.x + box.width * 0.62, box.y + box.height * 0.5, { steps: 6 }); await page.mouse.up();
        await page.waitForTimeout(150);
        await page.mouse.dblclick(box.x + box.width * 0.55, box.y + box.height * 0.5); await page.waitForTimeout(200);
        tl['dblclick_' + k] = await page.evaluate((r0) => document.getElementById('ax-reset').hidden && document.getElementById('ax-range').textContent === r0
          && !document.body.hasAttribute('data-pw') ? 'ok' : 'FAIL', r0);
        if (tl['dblclick_' + k] !== 'ok') fail('activity ' + k + ': double-click reset');
        // a prior window stripe pins its grid column; the stripe turns amber on BOTH charts
        const pin = await page.evaluate(async (id) => {
          const hs = [...document.querySelectorAll('#' + id + ' .axsvg .xwh')].filter(x => x.getAttribute('data-w') !== '0');
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
          const amber = document.querySelectorAll('.ashx .axsvg .xw.on').length;
          const ok = h.getAttribute('aria-pressed') === 'true' && document.body.getAttribute('data-pw') === w && cells > 0
            && /^vs /.test(gt) && (!d1 || / vs /.test(d1.textContent)) && amber === document.querySelectorAll('.ashx .axsvg').length;
          return ok ? 'ok (w=' + w + ', ' + gt.replace(/\s*clear$/, '') + ', amber on ' + amber + ' charts)' : 'FAIL ' + JSON.stringify([h.getAttribute('aria-pressed'), gt, cells, amber]);
        }, id);
        tl['pin_' + k] = pin;
        if (/^FAIL/.test(pin)) fail('activity ' + k + ': window click pin ' + pin);
        // Current unpins and flashes the Current column
        const unpin = await page.evaluate(async (id) => {
          const c = document.querySelector('#' + id + ' .axsvg .xwh[data-w="0"]');
          if (!c) return 'none';
          const rc = c.getBoundingClientRect();
          const o = { bubbles: true, clientX: rc.left + rc.width / 2, clientY: rc.top + rc.height / 2, button: 0 };
          c.dispatchEvent(new MouseEvent('mousedown', o)); document.dispatchEvent(new MouseEvent('mouseup', o));
          await new Promise(r => setTimeout(r, 120));
          const fl = document.querySelectorAll('#tl .c.colflash[data-w="0"]').length;
          return (!document.body.hasAttribute('data-pw') && !document.querySelector('#tl .ruler .h[aria-pressed="true"]') && fl > 0
            && document.getElementById('tl-gt').textContent === 'vs prior mean' && !document.querySelector('.ashx .axsvg .xw.on')) ? 'ok (' + fl + ' cells flashed)' : 'FAIL';
        }, id);
        tl['unpin_' + k] = unpin;
        if (/^FAIL/.test(unpin)) fail('activity ' + k + ': Current unpin ' + unpin);
        // keyboard: Enter on a focused stripe pins, Esc clears
        const kb = await page.evaluate((id) => {
          const hs = [...document.querySelectorAll('#' + id + ' .axsvg .xwh')].filter(x => x.getAttribute('data-w') !== '0');
          if (!hs.length) return 'none';
          const hwin = hs[0]; hwin.focus();
          hwin.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', bubbles: true }));
          const pinned = document.body.getAttribute('data-pw') === hwin.getAttribute('data-w');
          document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true }));
          return pinned && !document.body.hasAttribute('data-pw') ? 'ok' : 'FAIL';
        }, id);
        tl['keys_' + k] = kb;
        if (/^FAIL/.test(kb)) fail('activity ' + k + ': Enter / Esc ' + kb);
      }
      // the 1-minute detail: the payload agrees with the per-window values
      // (the Current window's minutes summed = ashx.win), and zooming into
      // the Current window switches both charts to it (range label, a
      // one-minute tooltip, the crosshair on both)
      const fine = await page.evaluate(() => {
        const out = [];
        for (const key of ['ashx', 'ashe']) {
          const P = window.AWR_DATA[key], f = P && P.fine;
          if (!f) { out.push(key + ' no fine'); continue; }
          const n = f.segs.reduce((a, g) => a + g[1], 0), W = window.AWR_WIN.w, cur = W[W.length - 1];
          const t0 = Date.parse(P.t0.replace(' ', 'T') + ':00Z'), cs = Date.parse(cur.s.replace(' ', 'T') + ':00Z'), ce = Date.parse(cur.e.replace(' ', 'T') + ':00Z');
          let worst = 0;
          P.classes.forEach((c, k) => {
            const v = []; f.vals[k].forEach(x => { if (x < 0) for (let z = 0; z < -x; z++) v.push(0); else v.push(x); });
            if (v.length !== n) worst = Infinity;
            let sm = 0, j = 0;
            f.segs.forEach(g => { for (let q = 0; q < g[1]; q++, j++) { const t = t0 + (g[0] + q) * 6e4; if (t >= cs && t < ce) sm += v[j]; } });
            const a = sm / 6 / 60 / P.wh, b = P.win[k][P.win[k].length - 1];
            worst = Math.max(worst, Math.abs(a - b));
          });
          out.push(key + ' ' + n + ' min' + (f.capped ? ' (capped)' : '') + ', Current vs win max diff ' + worst.toFixed(4) + (worst <= 0.002 * P.classes.length + 1e-9 ? '' : ' FAIL'));
        }
        return out.join('; ');
      });
      tl.fine = fine;
      if (/FAIL|no fine/.test(fine)) fail('activity: 1-minute payload ' + fine);
      {
        let r = '';
        for (let it = 0; it < 5; it++) {
          await page.evaluate(() => window.scrollTo(0, 0)); await page.waitForTimeout(100);
          const g = await page.evaluate(() => {
            const s = document.querySelector('#ax-cls .axsvg'), c = s.querySelector('.xw.cur'), rs = s.getBoundingClientRect(), rc = c.getBoundingClientRect();
            const sc = rs.width / s.viewBox.baseVal.width;
            return { cx: rc.left + rc.width / 2, w: rc.width, l: rs.left + 40 * sc, r: rs.right - 14 * sc, y: rs.top + rs.height * 0.6 };
          });
          const half = Math.max(40, g.w * 0.4), a = Math.max(g.l + 1, g.cx - half), b = g.cx + half;
          await page.mouse.move(a, g.y); await page.mouse.down(); await page.mouse.move(b, g.y, { steps: 6 }); await page.mouse.up();
          await page.waitForTimeout(200);
          r = await page.evaluate(() => document.getElementById('ax-range').textContent);
          if (/1-min detail/.test(r)) break;
        }
        const hv = await page.evaluate(() => {
          const s = document.querySelector('#ax-cls .axsvg'), c = s.querySelector('.xw.cur').getBoundingClientRect(), rs = s.getBoundingClientRect();
          return { x: c.left + c.width * 0.5, y: rs.top + rs.height * 0.65 };
        });
        await page.mouse.move(hv.x, hv.y); await page.waitForTimeout(150);
        const tt = await page.evaluate(() => {
          const t = document.getElementById('tip'), chs = [...document.querySelectorAll('.ashx .axsvg .xch')];
          const on = chs.filter(c => c.getAttribute('visibility') === 'visible').length;
          const m = /(\d\d):(\d\d)\u2013(\d\d):(\d\d)/.exec(t.textContent || '');
          const mins = m ? ((+m[3] * 60 + +m[4]) - (+m[1] * 60 + +m[2]) + 1440) % 1440 : -1;
          return { ok: !t.hidden && mins === 1 && /1-min average/.test(t.textContent) && on === chs.length, txt: (t.textContent || '').slice(0, 60), on };
        });
        tl.fine_zoom = (/1-min detail/.test(r) && tt.ok) ? 'ok (' + r.replace(/^.*zoomed, /, '') + '; tip ' + tt.txt.replace(/average.*/, 'average') + ')' : 'FAIL ' + r + ' | ' + JSON.stringify(tt);
        if (/^FAIL/.test(tl.fine_zoom)) fail('activity: zoom into the Current window ' + tl.fine_zoom);
        await page.mouse.move(hv.x, hv.y - 400); await page.click('#ax-reset').catch(() => {}); await page.waitForTimeout(150);
      }
      // a ruler date pins too; the pin survives a view switch (the charts at
      // the top of every view show it) and Esc clears it
      const ruler = await page.evaluate(async () => {
        const h = document.querySelector('#tl .ruler .h:not(.cur)'); if (!h) return 'none';
        h.click(); await new Promise(r => setTimeout(r, 80));
        const w = h.getAttribute('data-w');
        const a = document.body.getAttribute('data-pw') === w;
        window.AWR_setView('summary', false); await new Promise(r => setTimeout(r, 120));
        const b = document.body.getAttribute('data-pw') === w && !!document.querySelector('.ashx .axsvg .xw.on');
        document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true }));
        const c = !document.body.hasAttribute('data-pw');
        window.AWR_setView('timeline', false);
        return a && b && c ? 'ok' : 'FAIL ' + JSON.stringify([a, b, c]);
      });
      tl.ruler = ruler;
      if (/^FAIL/.test(ruler)) fail('timeline: ruler pin / survives view / Esc ' + ruler);
    } else tl.chart = 'no ASH payload';
    // grid hover tooltip
    /* the first prior-window cell that is not under a sticky row label (the
       grid opens scrolled to Current, so with a few more windows than fit
       the oldest cells sit under the labels) */
    const cells = await page.$$('#tl .lrows .r.bars .c:not(.cur)');
    const ci = await page.evaluate(() => {
      const cs = [...document.querySelectorAll('#tl .lrows .r.bars .c:not(.cur)')];
      for (let i = 0; i < cs.length; i++) {
        const c = cs[i]; c.scrollIntoView({ block: 'center', inline: 'nearest' });
        const r = c.getBoundingClientRect(), e = document.elementFromPoint(r.left + r.width / 2, r.top + r.height / 2);
        if (e && c.contains(e)) return i;
      }
      return 0;
    });
    const cell = cells[ci];
    if (cell) {
      await cell.hover(); await page.waitForTimeout(120);
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

  // ---- 6. phase 4 (v1.6.0): the plan-change card, the evidence library,
  // the rail's card sub-links and the table micro strips.
  {
    const { page, errors } = await openPage('#view=summary', 'light');
    const p4 = await page.evaluate(async () => {
      const vis = el => !!el && el.getClientRects().length > 0;
      const wait = ms => new Promise(r => setTimeout(r, ms));
      const out = {};
      // plan-change cards: moved into "What changed around it", bars + step line
      const pcs = [...document.querySelectorAll('article.fc[id^="f-plan-"]')];
      out.planCards = pcs.length;
      out.planOk = pcs.every(c => c.closest('#changes-slot') && vis(c)
        && c.querySelector('.wg .r.bars') && c.querySelector('.wg .r.p .pv')
        && c.querySelector('a.ent[href^="#sm-"]') && c.querySelector('a.jump[data-tl]'));
      // the evidence library: every row has its one-line status, one first /
      // one last edge, a closed row opens and shuts on a click
      const libs = [...document.querySelectorAll('main > section.lib')];
      out.lib = libs.length;
      out.libVisible = libs.filter(vis).length;
      out.libNoLs = libs.filter(x => !x.querySelector('h2 > .ls')).map(x => x.id);
      out.libHead = vis(document.getElementById('s-lib'));
      out.edges = document.querySelectorAll('main > section.lib.lib-first').length === 1
        && document.querySelectorAll('main > section.lib.lib-last').length === 1;
      const closed = libs.find(x => !x.classList.contains('lopen'));
      if (closed) {
        const h = closed.querySelector('h2');
        const body = () => [...closed.children].filter(c => c !== h && vis(c)).length;
        const before = body();
        h.click(); await wait(150);
        const opened = closed.classList.contains('lopen') && body() > 0 && h.getAttribute('aria-expanded') === 'true';
        h.click(); await wait(80);
        out.toggle = (!before && opened && !body()) ? 'ok (' + closed.id + ')' : 'FAIL ' + closed.id + ' ' + JSON.stringify([before, opened, body()]);
      } else out.toggle = 'none';
      // a jump to a row inside a closed row opens it (goTo -> reveal)
      const shut = libs.find(x => !x.classList.contains('lopen') && x.querySelector('tbody tr[id]'));
      const row = shut ? shut.querySelector('tbody tr[id]') : null;
      if (row) {
        window.AWR_goTo(row, true, false); await wait(250);
        out.reveal = shut.classList.contains('lopen') && vis(row) && document.body.getAttribute('data-view') === 'summary'
          ? 'ok (' + row.id + ')' : 'FAIL (' + row.id + ')';
        shut.querySelector('h2').click(); await wait(60);
      } else out.reveal = 'none';
      // the rail: one sub-link per finding card, each to its card
      const subs = [...document.querySelectorAll('nav.toc a.sub')];
      const cards = [...document.querySelectorAll('#findings .cards > article.fc')];
      out.subs = subs.length + '/' + cards.length;
      out.subsOk = subs.length === cards.length && subs.every((a, i) => a.getAttribute('href') === '#' + cards[i].id);
      // All sections: every library section shows in full, row state or not
      window.AWR_setView('all', false); await wait(250);
      out.allFull = libs.filter(x => { const t = x.querySelector('table, .chart-wrap'); return t && !vis(t); }).map(x => x.id);
      out.strips = document.querySelectorAll('td.trend svg.mw').length;
      out.lines = document.querySelectorAll('td.trend svg.spark').length;
      // js_microstrip draws nothing past 91 windows (no pixel per bar left)
      out.nwin = (window.AWR_WIN && window.AWR_WIN.w) ? window.AWR_WIN.w.length : 0;
      window.AWR_setView('summary', false);
      return out;
    });
    console.log('phase 4', JSON.stringify(p4));
    if (!p4.planOk) fail('plan-change card incomplete or not in #changes-slot');
    if (!p4.lib || p4.libVisible !== p4.lib) fail('evidence library: ' + p4.libVisible + '/' + p4.lib + ' rows visible in Summary');
    if (p4.libNoLs.length) fail('evidence library rows without a one-line status: ' + p4.libNoLs.join(', '));
    if (!p4.libHead) fail('evidence library heading #s-lib not visible');
    if (!p4.edges) fail('evidence library: first / last row edges');
    if (/^FAIL/.test(p4.toggle)) fail('evidence library row toggle ' + p4.toggle);
    if (/^FAIL/.test(p4.reveal)) fail('evidence library reveal ' + p4.reveal);
    if (!p4.subsOk) fail('rail card sub-links ' + p4.subs);
    if (p4.allFull.length) fail('All sections: library sections not shown in full: ' + p4.allFull.join(', '));
    if ((!p4.strips && p4.nwin <= 91) || p4.lines) fail('micro strips: ' + p4.strips + ' svg.mw, ' + p4.lines + ' line sparklines left');
    if (errors.length) fail('phase 4: ' + errors.slice(0, 5).join(' | '));
    if (shots) {
      const pc = await page.$('#s-changes');
      if (pc && await pc.isVisible()) await pc.screenshot({ path: path.join(shots, 'changes.png') });
      const lh = await page.$('#s-lib');
      if (lh) { await lh.scrollIntoViewIfNeeded(); await page.waitForTimeout(200); await page.screenshot({ path: path.join(shots, 'library.png') }); }
    }
    await page.close();
  }

  await browser.close();
  if (failures.length) { console.log('FAILURES:'); failures.forEach(f => console.log('  ' + f)); }
  else console.log('verify: OK');
  process.exit(failures.length ? 1 : 0);
})();
