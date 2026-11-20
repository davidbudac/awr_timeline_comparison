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
 *   - the Activity charts (section#activity, v1.6.0): the first section in
 *     Timeline / All sections, right under the verdict in Summary (compact
 *     there: one chart; "Show by wait event" brings back the second,
 *     remembered in awr-ax; the dashboard design keeps its own tabs
 *     instead), both drawn elsewhere (by wait class, by wait event);
 *     on each chart: hover crosshair + tooltip (mirrored on the other),
 *     legend toggle + restore (restack / rescale), brush zoom (zooms both),
 *     the 1-minute detail (payload vs ashx.win, zoom into Current -> 1-min)
 *     + Reset, double-click reset, a window click pinning its grid column
 *     (ruler aria-pressed, gutter "vs <date>", amber stripe on both
 *     charts); Current unpinning + flashing, Enter / Esc; "Other events"
 *     in the event legend (required for the demo, which has > 14 events);
 *   - the visualization sections (20-28): each present once, drawn (or
 *     a note) in All sections and in its opened Summary row, a table of
 *     its numbers, inside its box at 1440 and 390 px; the instance map
 *     agrees with the finding cards; the window-similarity what-if's JS
 *     rule gives the PL/SQL buckets (skipped on an older report);
 *   - the series highlight (v1.6.1): ashe.ecls present; a class legend
 *     hover re-bases that class (band on the axis, the rest faded, the
 *     note) and its events in the event chart; an event lights its class
 *     in place; nothing left on after the pointer leaves; keyboard focus;
 *     Shift+click sticky, the tooltip leads with it, Esc clears it before
 *     unpinning; a click on a band keeps it, the same click clears it;
 *   - the Activity charts' Windows side by side mode (plan 024): one panel
 *     per window, hover / crosshair, no zoom, cap click pins, legend,
 *     markers, the switch remembered in awr-axlayout;
 *   - the Day profile metric picker (v1.6.1, profile_days > 0; required
 *     for the demo): one role=tab button per stat with its indicator, a
 *     click / arrows / Home / End switch the line chart;
 *   - the rail: no link state (active / hover) draws a left border or an
 *     inset shadow;
 *   - the Timeline view (v1.6.0): every lane source template was moved in,
 *     every "Timeline ->" (data-tl) target exists and a click lands on it,
 *     every grid label (a.ent) resolves; ruler pin (it survives a view
 *     switch), grid tooltip;
 *   - the Timeline rows (plan 031): broken Current bars only in #tl, the
 *     priors under one at least 30 % of its height, Flagged only / All / a
 *     jump to a hidden row, Biggest change first (wait classes first,
 *     sorted) and Report order restoring the ids' order;
 *   - phase 4 (v1.6.0): every plan-change card sits in "What changed
 *     around it" with its bars, plan step line and links; every evidence
 *     library row (section.lib) shows in Summary with its one-line status,
 *     opens / shuts on a click and opens for a jump into it; one rail
 *     sub-link per finding card; All sections shows every library section
 *     in full; the Trend cells are micro strips (svg.mw), no line left;
 *     v1.7: cards ordered by data-impact, chip present, Summary z capped
 *     at 10; the DB-time breakdown under the verdict (#att-slot) shown
 *     (required for the demo), #att-src gone, every part coloured from
 *     AWR_WAIT_COLORS; v1.7 one count: the rail's Findings pills add up
 *     to the finding cards, no other rail link has a count pill, no
 *     "metrics moved" verdict pill, the Summary Findings header counts
 *     the cards, J in Summary flashes a large card (when there is one),
 *     the card sub-links' text / data-label carry no share (CSS ::after
 *     only); plan 025: the triage list (one row per card), all but one
 *     card folded, a row click opens its card, card charts show prior
 *     values on hover only and one release label; plan 026: the Physical
 *     I/O card's SQL row; a plan-change card that explains a card sits
 *     right under it (dashboard: in What changed around it, beside the
 *     findings); plan 032: Checked and normal starts folded (one line) and
 *     a jump to it opens it; in the dashboard its Normal tab shows it open;
 *     plan 033: card hints (rule id, line, copyable read-only query with
 *     no unfilled placeholder; the plan card keeps its footer links; the
 *     dashboard side column does not overflow);
 *   - pattern tags (plan 027): every chip has text and a title, none on a
 *     plan / config card, a triage row and a dashboard findings row show
 *     their card's chips, the demo Physical I/O card reads "jump after
 *     Release 4.2" + "step up at Release 4.1";
 *   - the design (window.AWR_DESIGN, design=quiet|dashboard; none =
 *     classic): quiet and dashboard -- "How to read" opens / closes the
 *     Activity help, a table's copy menu holds CSV + Markdown; dashboard --
 *     no rail (its checks are skipped), the Summary puts the verdict and
 *     the KPI cards above Activity, one KPI per finding card + DB time
 *     with bars, every finding card inside a row of the findings table
 *     (count = the Moved tab), a row opens to its bars / its card, the
 *     Normal tab shows #s-normal and a jump into it switches the tab, the
 *     Activity tabs show one chart (x labels + release flags on it) or
 *     both, Ctrl+K opens the palette (not the row filter), a search +
 *     Enter lands on the row, Esc closes it without unpinning; the
 *     Activity interaction checks run with both charts shown;
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
  let DESIGN = 'classic';

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
    await page.evaluate(() => { try { localStorage.removeItem('awr-view'); localStorage.removeItem('awr-theme'); localStorage.removeItem('awr-ax'); localStorage.removeItem('awr-axlayout'); } catch (e) {} });
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
    DESIGN = await page.evaluate(() => window.AWR_DESIGN || 'classic');
    console.log('design: ' + DESIGN);
    // the default = the early view script's literal (the demo opens All sections)
    const dm = /<script>\(function\(\)\{var v="(summary|timeline|all)"/.exec(fs.readFileSync(file, 'utf8'));
    const defView = dm ? dm[1] : 'summary';
    if (info.view !== defView) fail('default view is ' + info.view + ', expected ' + defView);
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
            // Summary puts the verdict above it (plan 023; the dashboard by its CSS order, with its KPI cards)
            const summary = cls === 'vs';
            const secs = [...document.querySelectorAll('main > section')].filter(x => x !== a && vis(x) && !(summary && x.id === 'verdict'));
            const top = a.getBoundingClientRect().top;
            const above = secs.filter(x => x.getBoundingClientRect().top < top).map(x => x.id);
            if (above.length) return 'below ' + above.slice(0, 3).join(',');
            const has = !!(window.AWR_DATA && AWR_DATA.ashx && AWR_DATA.ashx.classes && AWR_DATA.ashx.classes.length);
            const two = !!(window.AWR_DATA && AWR_DATA.ashe && AWR_DATA.ashe.classes && AWR_DATA.ashe.classes.length);
            // every chart shown is drawn (the dashboard shows one at a time; Summary opens compact)
            const c1 = vis(document.querySelector('#ax-cls .axp')), c2 = vis(document.querySelector('#ax-ev .axp'));
            const n1 = document.querySelectorAll('#ax-cls .axsvg path.xa').length, n2 = document.querySelectorAll('#ax-ev .axsvg path.xa').length;
            if (has && (!(c1 || c2) || (c1 && !n1) || (c2 && !n2))) return 'not drawn (' + n1 + '/' + n2 + ')';
            // compact in Summary (plan 023), except in the dashboard design (its tabs show one chart)
            if (summary && has && two && window.AWR_DESIGN !== 'dashboard') {
              if (!a.classList.contains('ax-cmp') || c2) return 'not compact in Summary';
              const h = +document.querySelector('#ax-cls .axsvg').getAttribute('height');
              if (!(h > 0 && h <= 175)) return 'compact chart ' + h + ' px high';
            }
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

  // ---- 2b. Summary: the Activity charts open compact; "Show by wait
  // event" shows the second chart and is remembered (awr-ax) -- plan 023
  // (the dashboard design keeps its own Activity tabs: #ax-more stays hidden)
  {
    const { page, errors } = await openPage('#view=summary', 'light');
    const has2 = await page.evaluate(() => !!(window.AWR_DATA && AWR_DATA.ashe && AWR_DATA.ashe.classes && AWR_DATA.ashe.classes.length));
    if (has2 && DESIGN === 'dashboard') {
      const off = await page.evaluate(() => { const b = document.getElementById('ax-more'); return (!b || b.hidden) && !document.getElementById('activity').classList.contains('ax-cmp'); });
      console.log('activity compact (Summary): ' + (off ? 'off in the dashboard, ok' : 'FAIL on in the dashboard'));
      if (!off) fail('activity: compact mode / #ax-more must stay off in the dashboard design');
    } else if (has2) {
      const st = () => page.evaluate(() => {
        const vis = el => !!el && el.getClientRects().length > 0;
        const b = document.getElementById('ax-more');
        let saved = null; try { saved = localStorage.getItem('awr-ax'); } catch (e) {}
        return { cmp: document.getElementById('activity').classList.contains('ax-cmp'), ev: vis(document.getElementById('ax-ev')),
                 evDrawn: document.querySelectorAll('#ax-ev .axsvg path.xa').length, btn: b && vis(b) ? b.textContent : null,
                 exp: b ? b.getAttribute('aria-expanded') : null, saved };
      });
      const s0 = await st();
      await page.click('#ax-more'); await page.waitForTimeout(250);
      const s1 = await st();
      await page.reload({ waitUntil: 'load' }); await page.waitForTimeout(1200);
      const s2 = await st();
      await page.click('#ax-more'); await page.waitForTimeout(250);
      const s3 = await st();
      const ok = s0.cmp && !s0.ev && s0.btn === 'Show by wait event' && s0.exp === 'false'
        && !s1.cmp && s1.ev && s1.evDrawn > 0 && s1.saved === 'full' && s1.exp === 'true'
        && !s2.cmp && s2.ev && s3.cmp && !s3.ev && s3.saved === 'compact';
      console.log('activity compact (Summary): ' + (ok ? 'ok' : 'FAIL ' + JSON.stringify([s0, s1, s2, s3])));
      if (!ok) fail('activity: Summary compact / Show by wait event ' + JSON.stringify([s0, s1, s2, s3]));
      await page.evaluate(() => { try { localStorage.removeItem('awr-ax'); } catch (e) {} });
    }
    if (errors.length) fail('activity compact: ' + errors.slice(0, 5).join(' | '));
    await page.close();
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
    // rail: a dimmed link switches view on click (no rail in the dashboard)
    const rail = DESIGN === 'dashboard' ? 'none (dashboard)' : await page.evaluate(async () => {
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
    const tab = await page.$('.tabs:not(.dtabs) [data-t]:nth-child(2)');
    if (tab) {
      await tab.click(); await page.waitForTimeout(200);
      toggles.tabs = await page.evaluate(() => {
        const t = document.querySelector('.tabs:not(.dtabs) [data-t]:nth-child(2)');
        const g = t.closest('.tabs').getAttribute('data-tabs');
        const p = document.querySelector(`.tabpanel[data-tabs="${g}"][data-t="${t.getAttribute('data-t')}"]`);
        if (!p || getComputedStyle(p).display === 'none') return 'FAIL';
        // plan 029 review: a non-default Top SQL tab is kept in the hash
        // (a shared link reopens on it, not on the first tab)
        if (g === 'topsql' && !new RegExp('[!&]tab=' + t.getAttribute('data-t') + '(&|$)').test(location.hash)) return 'FAIL (hash ' + location.hash + ')';
        return 'ok';
      });
      if (toggles.tabs !== 'ok') fail('tabs: ' + toggles.tabs);
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
    if (DESIGN === 'dashboard') toggles.railMarker = 'none (dashboard)';
    else {
      await page.evaluate(() => { const a = document.querySelector('nav.toc a[href="#activity"]'); if (a && !document.querySelector('nav.toc a.on')) a.classList.add('on'); });
      const rOn = await railMark('nav.toc a.on');
      await page.hover('nav.toc a[href="#findings"]'); await page.waitForTimeout(200);
      const rHov = await railMark('nav.toc a[href="#findings"]');
      toggles.railMarker = rOn + ' / ' + rHov;
    }
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
    // the dashboard shows one Activity chart at a time: these checks need both
    if (DESIGN === 'dashboard') { await page.evaluate(() => window.AWR_axMode && window.AWR_axMode('both')); await page.waitForTimeout(250); }
    if (inv.chart && inv.ash) {
      await page.evaluate(() => { if (window.AWR_TL && AWR_TL.axLayout) AWR_TL.axLayout('span', false); }); await page.waitForTimeout(200);
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
        await page.mouse.move(2, box.y + box.height + 40); await page.waitForTimeout(80);
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
        // off the legend: hovering an entry highlights (and re-scales) its series
        await page.mouse.move(2, box.y + box.height + 40);
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
          && !document.body.hasAttribute('data-pw') && !document.querySelector('.ashx .axsvg g.xfd') ? 'ok' : 'FAIL', r0);
        if (tl['dblclick_' + k] !== 'ok') fail('activity ' + k + ': double-click reset');
        await page.mouse.move(2, box.y + box.height + 40); await page.waitForTimeout(80);
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
      // v1.6.1 series highlight: a legend hover re-bases the series (drawn
      // from zero: its band's lower edge on the axis) and fades the rest; a
      // class lights its events (ashe.ecls) in the event chart, re-based
      // too; an event lights its class in place; Shift+click keeps it, the
      // tooltip leads with it, Esc clears it first and unpins second; a
      // click on a band keeps it, the same click again clears it
      {
        const hl = {};
        const state = () => page.evaluate(() => {
          const one = (id) => {
            const s = document.querySelector('#' + id + ' .axsvg'); if (!s) return null;
            const ax = s.querySelector('line.ax'), y0 = ax ? +ax.getAttribute('y1') : NaN;
            const bands = [...s.querySelectorAll('path.xah')];
            const onAxis = bands.length > 0 && bands.some(b => { const m = /([\d.]+) ([\d.]+)Z$/.exec(b.getAttribute('d')); return m && Math.abs(+m[2] - y0) < 0.6; });
            return { fd: !!s.querySelector('g.xfd'), n: bands.length, onAxis, note: !!s.querySelector('text.xhn'),
                     lit: document.querySelectorAll('#' + id + ' .axlg .axc.hl').length,
                     y: [...s.querySelectorAll('text.at')].map(t => t.textContent).join('|') };
          };
          return { c: one('ax-cls'), e: one('ax-ev') };
        });
        const ecls = await page.evaluate(() => (window.AWR_DATA.ashe || {}).ecls || null);
        const cls = await page.evaluate(() => window.AWR_DATA.ashx.classes);
        hl.ecls = ecls ? 'ok (' + ecls.length + ')' : 'FAIL missing';
        if (!ecls) fail('activity: ashe.ecls missing');
        // the class with the most events in the event chart
        let ci = 0, best = -1;
        cls.forEach((c, i) => { const n = ecls ? ecls.filter(x => x === c).length : 0; if (n > best) { best = n; ci = i; } });
        const s0 = await state();
        await page.hover('#ax-cls .axlg .axc[data-c="' + ci + '"]'); await page.waitForTimeout(150);
        const s1 = await state();
        const okC = s1.c.fd && s1.c.n === 1 && s1.c.onAxis && s1.c.note && s1.c.lit === 1
          && (!ecls || !best || (s1.e.fd && s1.e.n === best && s1.e.onAxis && s1.e.lit === best));
        hl.cls = okC ? 'ok (' + cls[ci] + ' -> ' + best + ' events' + (s1.c.y !== s0.c.y ? ', axis fitted' : '') + ')' : 'FAIL ' + JSON.stringify(s1);
        if (!/^ok/.test(hl.cls)) fail('activity: class legend highlight ' + hl.cls);
        // an event lights its class, in place (no note, not re-based)
        const ei = ecls ? ecls.findIndex(x => x && x !== 'CPU' && cls.includes(x)) : -1;
        if (ei >= 0) {
          await page.hover('#ax-ev .axlg .axc[data-c="' + ei + '"]'); await page.waitForTimeout(150);
          const s2 = await state();
          hl.ev = (s2.e.fd && s2.e.n === 1 && s2.e.onAxis && s2.e.note && s2.c.n === 1 && !s2.c.note && s2.c.lit === 1) ? 'ok (' + ecls[ei] + ' lit)' : 'FAIL ' + JSON.stringify(s2);
          if (!/^ok/.test(hl.ev)) fail('activity: event legend highlight ' + hl.ev);
        }
        await page.mouse.move(10, 10); await page.waitForTimeout(120);
        const s3 = await state();
        hl.leave = (!s3.c.fd && !s3.e.fd && !s3.c.lit && s3.c.y === s0.c.y) ? 'ok' : 'FAIL ' + JSON.stringify(s3);
        if (hl.leave !== 'ok') fail('activity: highlight left on after the pointer left ' + hl.leave);
        // keyboard focus highlights too
        await page.focus('#ax-cls .axlg .axc[data-c="' + ci + '"]');
        await page.keyboard.press('Shift+Tab'); await page.keyboard.press('Tab'); await page.waitForTimeout(80);
        const sk = await state();
        await page.evaluate(() => document.activeElement && document.activeElement.blur()); await page.waitForTimeout(80);
        hl.focus = sk.c.n === 1 ? 'ok' : 'FAIL';
        if (hl.focus !== 'ok') fail('activity: keyboard focus on a legend entry does not highlight');
        // sticky: Shift+click, the tooltip leads with it, Esc clears it first
        await page.click('#ax-cls .axlg .axc[data-c="' + ci + '"]', { modifiers: ['Shift'] }); await page.waitForTimeout(120);
        const cb = await (await page.$('#ax-cls .axsvg')).boundingBox();
        await page.mouse.move(cb.x + cb.width * 0.5, cb.y + cb.height * 0.6); await page.waitForTimeout(150);
        const s4 = await state();
        const tipLead = await page.evaluate((nm) => { const t = document.getElementById('tip'); const l = t && !t.hidden && t.querySelector('.thlb .thl'); return !!l && l.textContent.indexOf(nm) === 0; }, cls[ci]);
        await page.mouse.move(10, 10); await page.waitForTimeout(100);
        const s5 = await state();
        await page.evaluate(() => { const h = document.querySelector('#tl .ruler .h:not(.cur)'); if (h) h.click(); });
        await page.keyboard.press('Escape'); await page.waitForTimeout(100);
        const s6 = await state(); const pw6 = await page.evaluate(() => document.body.hasAttribute('data-pw'));
        await page.keyboard.press('Escape'); await page.waitForTimeout(100);
        const pw7 = await page.evaluate(() => document.body.hasAttribute('data-pw'));
        hl.sticky = (s4.c.n === 1 && tipLead && s5.c.n === 1 && s5.c.note && !s6.c.fd && pw6 && !pw7) ? 'ok (tooltip leads, Esc clears it, then unpins)'
          : 'FAIL ' + JSON.stringify([s4.c.n, tipLead, s5.c.n, s6.c.fd, pw6, pw7]);
        if (!/^ok/.test(hl.sticky)) fail('activity: sticky highlight / Esc ' + hl.sticky);
        // a click on the bottom band keeps it; the same click clears it
        const px = await page.evaluate(() => { const s = document.querySelector('#ax-cls .axsvg'), r = s.getBoundingClientRect(), ax = s.querySelector('line.ax'), sc = r.width / s.viewBox.baseVal.width;
          const y = r.top + (+ax.getAttribute('y1') - 1.5) * sc;
          for (let f = 0.3; f < 0.97; f += 0.005) { const e = document.elementFromPoint(r.left + r.width * f, y); if (e && e.matches('path.xa')) return { x: r.left + r.width * f, y }; }
          return { x: r.left + r.width * 0.5, y }; });
        await page.mouse.click(px.x, px.y); await page.waitForTimeout(150);
        await page.mouse.move(10, 10); await page.waitForTimeout(100);
        const s8 = await state();
        await page.mouse.click(px.x, px.y); await page.waitForTimeout(150);
        await page.mouse.move(10, 10); await page.waitForTimeout(100);
        const s9 = await state();
        hl.click = (s8.c.n === 1 && s8.c.onAxis && !s9.c.fd) ? 'ok' : 'FAIL ' + JSON.stringify([s8.c, s9.c.fd]);
        if (!/^ok/.test(hl.click)) fail('activity: click-to-keep highlight ' + hl.click);
        tl.highlight = hl;
        if (shots) {
          await page.evaluate(() => window.scrollTo(0, 0));
          await page.hover('#ax-cls .axlg .axc[data-c="' + ci + '"]'); await page.waitForTimeout(150);
          const a = await page.$('#activity'); if (a) await a.screenshot({ path: path.join(shots, 'activity-highlight.png') });
          await page.mouse.move(10, 10); await page.waitForTimeout(80);
        }
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
      // a ruler date pins too; the pin survives a view switch (the charts in
      // every view show it) and Esc clears it
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

  // ---- 5c. the Activity charts' "Windows side by side" mode (plan 024):
  // panels = windows, hover + mirrored crosshair, no zoom, cap click pins,
  // legend toggle per panel, markers in the gaps, the switch remembered
  {
    const { page, errors } = await openPage('#view=timeline', 'light');
    const sb = {};
    const isDemo = /demo_busy_db(_quiet|_dashboard)?\.html$/.test(file);
    if (DESIGN === 'dashboard') { await page.evaluate(() => window.AWR_axMode && window.AWR_axMode('both')); await page.waitForTimeout(250); }
    const can = await page.evaluate(() => !!(window.AWR_TL && AWR_TL.axLayout && document.querySelector('#activity .axlayout:not([hidden])')));
    if (!can) { sb.mode = 'unavailable'; if (isDemo) fail('side by side: mode switch missing on the demo'); }
    else {
      await page.evaluate(() => AWR_TL.axLayout('win', false)); await page.waitForTimeout(250);
      sb.panels = await page.evaluate(() => {
        const n = window.AWR_WIN.w.length, out = [];
        for (const id of ['ax-cls', 'ax-ev']) {
          const s = document.querySelector('#' + id + ' .axsvg'); if (!s || !s.getClientRects().length) continue;
          const caps = s.querySelectorAll('.xwh').length, pans = s.querySelectorAll('.xw.xpn').length, cur = s.querySelectorAll('.xw.xpn.cur').length, xa = s.querySelectorAll('path.xa').length;
          out.push(id + ' ' + caps + '/' + pans + ' panels, cur ' + cur + ', ' + xa + ' paths' + (caps === pans && caps >= 2 && caps <= n && cur === 1 && xa > 0 ? '' : ' FAIL'));
        }
        const r = document.getElementById('ax-range').textContent;
        return out.join('; ') + '; range "' + r + '"' + (/side by side/.test(r) && document.getElementById('ax-reset').hidden ? '' : ' FAIL');
      });
      if (/FAIL/.test(sb.panels)) fail('side by side: ' + sb.panels);
      const cp = await page.evaluate(() => { const c = document.querySelector('#ax-cls .axsvg .xw.xpn.cur').getBoundingClientRect(); return { x: c.left + c.width / 2, y: c.top + c.height * 0.6 }; });
      await page.mouse.move(cp.x, cp.y); await page.waitForTimeout(150);
      sb.hover = await page.evaluate(() => {
        const t = document.getElementById('tip'); if (!t || t.hidden || !/AAS/.test(t.textContent)) return 'FAIL tooltip';
        const chs = [...document.querySelectorAll('.ashx .axsvg')].filter(s => s.getClientRects().length).map(s => s.querySelector('.xch'));
        const on = chs.filter(c => c && c.getAttribute('visibility') === 'visible');
        if (on.length !== chs.length) return 'FAIL crosshair on ' + on.length + '/' + chs.length;
        return new Set(on.map(c => c.getAttribute('x1'))).size === 1 ? 'ok' + (/1-min average/.test(t.textContent) ? ' (1-min)' : '') : 'FAIL crosshair x differs';
      });
      if (!/^ok/.test(sb.hover)) fail('side by side: hover ' + sb.hover);
      if (isDemo && !/1-min/.test(sb.hover)) fail('side by side: the demo has 1-minute data for every window');
      const r0 = await page.evaluate(() => document.getElementById('ax-range').textContent);
      const bb = await (await page.$('#ax-cls .axsvg')).boundingBox();
      await page.mouse.move(bb.x + bb.width * 0.3, bb.y + bb.height * 0.6); await page.mouse.down();
      await page.mouse.move(bb.x + bb.width * 0.7, bb.y + bb.height * 0.6, { steps: 6 }); await page.mouse.up(); await page.waitForTimeout(200);
      sb.noZoom = await page.evaluate((r0) => document.getElementById('ax-range').textContent === r0 && document.getElementById('ax-reset').hidden ? 'ok' : 'FAIL', r0);
      if (sb.noZoom !== 'ok') fail('side by side: a drag zoomed');
      const hw = await page.evaluate(() => { const h = [...document.querySelectorAll('#ax-cls .axsvg .xwh')].find(x => x.getAttribute('data-w') !== '0'); if (!h) return null; const r = h.getBoundingClientRect(); return { x: r.left + r.width / 2, y: r.top + r.height / 2, w: h.getAttribute('data-w') }; });
      if (hw) {
        await page.mouse.click(hw.x, hw.y); await page.waitForTimeout(200);
        const a = await page.evaluate((w) => document.body.getAttribute('data-pw') === w && [...document.querySelectorAll('.ashx .axsvg')].filter(s => s.getClientRects().length).every(s => s.querySelector('.xw.xpn.on')), hw.w);
        await page.mouse.move(2, bb.y + bb.height + 40);
        await page.keyboard.press('Escape'); await page.waitForTimeout(150);
        const b = await page.evaluate(() => !document.body.hasAttribute('data-pw'));
        sb.pin = a && b ? 'ok' : 'FAIL ' + JSON.stringify([a, b]);
        if (sb.pin !== 'ok') fail('side by side: panel pin / Esc ' + sb.pin);
      }
      const nx = () => page.evaluate(() => document.querySelectorAll('#ax-cls .axsvg path.xa').length);
      const caps = await page.evaluate(() => document.querySelectorAll('#ax-cls .axsvg .xwh').length);
      const n0 = await nx(); await page.click('#ax-cls .axlg .axc[data-c="0"]'); await page.waitForTimeout(150);
      const n1 = await nx(); await page.click('#ax-cls .axlg .axc[data-c="0"]'); await page.mouse.move(2, bb.y + bb.height + 40); await page.waitForTimeout(150);
      const n2 = await nx();
      sb.legend = n1 === n0 - caps && n2 === n0 ? 'ok' : 'FAIL ' + [n0, n1, n2, caps].join('/');
      if (sb.legend !== 'ok') fail('side by side: legend toggle ' + sb.legend);
      sb.markers = await page.evaluate(() => (window.AWR_MARKERS || []).length ? document.querySelectorAll('#ax-cls .axsvg .cfl').length : -1);
      if (sb.markers === 0) fail('side by side: release markers missing');
      await page.click('#activity .axlayout [data-m="span"]'); await page.waitForTimeout(200);
      const s1 = await page.evaluate(() => { let v = null; try { v = localStorage.getItem('awr-axlayout'); } catch (e) {} return { v, r: document.getElementById('ax-range').textContent, n: document.querySelectorAll('#ax-cls .axsvg .xw.xpn').length }; });
      await page.click('#activity .axlayout [data-m="win"]'); await page.waitForTimeout(200);
      await page.reload({ waitUntil: 'load' }); await page.waitForTimeout(1200);
      const s2 = await page.evaluate(() => { let v = null; try { v = localStorage.getItem('awr-axlayout'); } catch (e) {} return { v, r: document.getElementById('ax-range').textContent }; });
      sb.persist = s1.v === 'span' && !/side by side/.test(s1.r) && s1.n === 0 && s2.v === 'win' && /side by side/.test(s2.r) ? 'ok' : 'FAIL ' + JSON.stringify([s1, s2]);
      if (sb.persist !== 'ok') fail('side by side: switch / persistence ' + sb.persist);
      await page.evaluate(() => { try { localStorage.removeItem('awr-axlayout'); } catch (e) {} });
    }
    console.log('side by side', JSON.stringify(sb));
    if (errors.length) fail('side by side: ' + errors.slice(0, 5).join(' | '));
    await page.close();
  }

  // ---- 5b. v1.6.1 Day profile metric picker (profile_days > 0): one button
  // per stat drives the line chart (a click, the arrow keys, Home / End;
  // roving tabindex), each with its severity indicator
  {
    const { page, errors } = await openPage('#view=all', 'light');
    const dp = await page.evaluate(async () => {
      const pk = document.getElementById('day-profile-pick'); if (!pk) return 'none';
      if (!window.echarts) return 'no charts';
      const wait = ms => new Promise(r => setTimeout(r, ms));
      const bs = [...pk.querySelectorAll('.dpb')], d = AWR_DATA.dayProfile, n = bs.length;
      const line = echarts.getInstanceByDom(document.getElementById('day-profile-line'));
      if (!line) return 'FAIL no line chart';
      const cur = () => { const o = line.getOption(); return { name: o.yAxis[0].name, sel: bs.findIndex(b => b.getAttribute('aria-selected') === 'true'),
        tab: bs.filter(b => b.tabIndex === 0).length, data: JSON.stringify(o.series[o.series.length - 1].data) }; };
      if (n !== d.stats.length) return 'FAIL ' + n + ' buttons for ' + d.stats.length + ' stats';
      const c0 = cur();
      if (c0.sel !== 0 || c0.name !== d.stats[0].name || c0.tab !== 1) return 'FAIL initial ' + JSON.stringify(c0);
      const j = Math.min(3, n - 1);
      bs[j].click(); await wait(80);
      const c3 = cur();
      if (c3.sel !== j || c3.name !== d.stats[j].name || c3.tab !== 1 || (n > 1 && c3.data === c0.data && d.stats[j].name === d.stats[0].name)) return 'FAIL click ' + JSON.stringify([c3.sel, c3.name]);
      const key = (k) => document.activeElement.dispatchEvent(new KeyboardEvent('keydown', { key: k, bubbles: true, cancelable: true }));
      const seq = [];
      bs[j].focus();
      for (const k of ['ArrowRight', 'ArrowDown', 'End', 'ArrowRight', 'ArrowLeft', 'Home', 'ArrowUp']) { key(k); await wait(40); seq.push(cur().sel); }
      const want = [(j + 1) % n, (j + 2) % n, n - 1, 0, n - 1, 0, n - 1];
      const okK = seq.every((v, i) => v === want[i]) && document.activeElement === bs[n - 1] && cur().name === d.stats[n - 1].name;
      const ind = bs.every(b => b.querySelector('.dpd') && b.querySelector('.dpz') && b.getAttribute('role') === 'tab');
      bs[0].click();
      return okK && ind ? 'ok (' + n + ' metrics; click, arrows, Home / End)' : 'FAIL keys ' + JSON.stringify([seq, want, ind]);
    });
    console.log('day profile picker', dp);
    if (/^FAIL/.test(dp)) fail('day profile picker: ' + dp);
    if (/demo_busy_db\.html$/.test(file) && dp === 'none') fail('day profile picker: the demo must have it');
    if (shots && /^ok/.test(dp)) { const el = await page.$('#day-profile'); await el.scrollIntoViewIfNeeded(); await page.waitForTimeout(200); await el.screenshot({ path: path.join(shots, 'day-profile.png') }); }
    if (errors.length) fail('day profile: ' + errors.slice(0, 5).join(' | '));
    await page.close();
  }

  // ---- 5d. plan 031: Timeline rows scale to the prior windows (broken
  // Current bar), the Rows / Order toolbar, a jump to a filtered row
  {
    const { page, errors } = await openPage('#view=timeline', 'light');
    const t31 = await page.evaluate(async () => {
      const wait = ms => new Promise(r => setTimeout(r, ms));
      const vis = el => !!el && el.getClientRects().length > 0;
      const out = {};
      if (!document.getElementById('tl-tools')) return { err: 'no #tl-tools' };
      out.brk = document.querySelectorAll('#tl i.b.brk').length;
      out.brkOutside = document.querySelectorAll('i.b.brk').length - out.brk;
      out.lowPrior = [...document.querySelectorAll('#tl i.b.brk')].filter(b => {
        const row = b.closest('.r'), cur = parseFloat(b.style.height);
        const pri = Math.max(0, ...[...row.querySelectorAll(':scope > .c:not(.cur) i.b')].map(x => parseFloat(x.style.height)));
        return pri < 0.3 * cur;
      }).map(b => b.closest('.r').id);
      const lanes = () => [...document.querySelectorAll('#tl .lane[data-kind="scored"]')].filter(l => !l.hidden);
      const shown = () => lanes().map(l => [...l.querySelectorAll('.lrows > .r.bars')].filter(vis).length).join(',');
      const before = shown();
      document.querySelector('#tl-tools button[data-tlf="flagged"]').click(); await wait(80);
      out.unflaggedShown = lanes().flatMap(l => [...l.querySelectorAll('.lrows > .r.bars')].filter(vis))
        .filter(r => !/^(large|moderate)$/.test(r.getAttribute('data-sev') || '')).map(r => r.id);
      out.flaggedHidden = lanes().flatMap(l => [...l.querySelectorAll('.lrows > .r.bars')].filter(r => !vis(r)))
        .filter(r => /^(large|moderate)$/.test(r.getAttribute('data-sev') || '')).map(r => r.id);
      const typ = document.querySelector('#tl .lane[data-kind="scored"] .lrows > .r.bars[data-sev="typical"]');
      if (typ) { window.AWR_goTo(typ, true, false); await wait(300);
        out.reveal = vis(typ) && !document.getElementById('tl').classList.contains('flagonly') ? 'ok' : 'FAIL ' + typ.id; } else out.reveal = 'none';
      document.querySelector('#tl-tools button[data-tlf="all"]').click(); await wait(80);
      out.restored = shown() === before ? 'ok' : 'FAIL ' + before + ' -> ' + shown();
      const waits = document.getElementById('lane-waits');
      if (waits && !waits.hidden) {
        const ids = () => [...waits.querySelectorAll('.lrows > .r.bars')].map(r => r.id).join(' ');
        const orig = ids();
        document.querySelector('#tl-tools button[data-tlo="change"]').click(); await wait(80);
        out.note = (document.querySelector('#tl-tools .tlt-n') || {}).textContent || '';
        const all = [...waits.querySelectorAll('.lrows > .r.bars')], aas = all.every(r => r.getAttribute('data-unit') === 'AAS');
        const nums = s => String(s || '').split(',').map(x => x === '' ? null : +x);
        const ev = all.filter(r => !/^tl-fr-w-/.test(r.id));
        const k = ev.map(r => window.AWR_WG.changeKey(nums(r.getAttribute('data-v')), +r.getAttribute('data-mu'), +r.getAttribute('data-sd'), aas));
        out.sorted = k.every((x, i) => i === 0 || x == null || k[i - 1] == null || k[i - 1] >= x) ? 'ok' : 'FAIL ' + JSON.stringify(k);
        const fe = all.findIndex(r => !/^tl-fr-w-/.test(r.id));
        out.classesFirst = fe < 0 || all.slice(fe).every(r => !/^tl-fr-w-/.test(r.id));
        document.querySelector('#tl-tools button[data-tlo="report"]').click(); await wait(80);
        out.order = ids() === orig ? 'ok' : 'FAIL order not restored';
      } else out.order = 'none';
      try { localStorage.removeItem('awr-tl-rows'); localStorage.removeItem('awr-tl-order'); } catch (e) { /* ignore */ }
      return out;
    });
    console.log('timeline rows (031)', JSON.stringify(t31));
    if (t31.err) fail('timeline rows: ' + t31.err);
    else {
      if (t31.brkOutside) fail('timeline rows: ' + t31.brkOutside + ' broken bar(s) outside the Timeline grid');
      if (t31.lowPrior.length) fail('timeline rows: priors still squashed under a broken bar: ' + t31.lowPrior.join(', '));
      if (t31.unflaggedShown.length) fail('timeline rows: Flagged only shows ' + t31.unflaggedShown.join(', '));
      if (t31.flaggedHidden.length) fail('timeline rows: Flagged only hides flagged ' + t31.flaggedHidden.join(', '));
      if (/^FAIL/.test(t31.reveal)) fail('timeline rows: jump to a filtered row ' + t31.reveal);
      if (/^FAIL/.test(t31.restored)) fail('timeline rows: All did not restore ' + t31.restored);
      if (/^FAIL/.test(t31.sorted || '') || t31.classesFirst === false) fail('timeline rows: Biggest change first ' + t31.sorted);
      if (/^FAIL/.test(t31.order)) fail('timeline rows: ' + t31.order);
      if (/demo_busy_db\.html$/.test(file) && t31.brk < 5) fail('timeline rows: the demo should draw broken Current bars (got ' + t31.brk + ')');
    }
    if (errors.length) fail('timeline rows: ' + errors.slice(0, 5).join(' | '));
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
      out.planOk = pcs.every(c => (c.closest('#changes-slot')
          || (c.getAttribute('data-explains') && c.previousElementSibling
              && c.previousElementSibling.id === c.getAttribute('data-explains'))) && vis(c)
        && c.querySelector('.wg .r.bars') && c.querySelector('.wg .r.p .pv')
        && c.querySelector('a.ent[href^="#sm-"]') && c.querySelector('a.jump[data-tl]'));
      // plan 030: durations on the plan card, AAS on Timeline event rows
      out.durOk = [...document.querySelectorAll('article.fc[id^="f-plan-"] .big .v')]
        .every(v => /^-?\d+(\.\d)? (ms|s|m|h|d)( \d+ (s|m|h))?$/.test(v.textContent.trim()));
      out.aasOk = [...document.querySelectorAll('[id^="tl-we-"]')].every(r => r.getAttribute('data-unit') === 'AAS');
      // plan 029: SQL Monitor lists flagged statements first; Top SQL opens on Biggest change
      const sk = [...document.querySelectorAll('#sqlmon-pool > tbody > tr[data-sk]')].map(r => +r.getAttribute('data-sk'));
      out.smOrder = sk.every((k, i) => i === 0 || sk[i - 1] <= k) &&
        [...document.querySelectorAll('#sqlmon-pool > tbody > tr[data-sk]')].every(r => (r.nextElementSibling || {}).className === 'sqlmon-detail');
      const t0 = document.querySelector('.tabs[data-tabs="topsql"] [data-t]:not([hidden])');
      const tp = t0 && document.querySelector('.tabpanel.on[data-tabs="topsql"]');
      // (a report without any Top SQL row has no panel at all: nothing to agree on)
      out.topsqlTab = !document.querySelector('.tabpanel[data-tabs="topsql"]') ||
        !!(t0 && tp && t0.classList.contains('on') && t0.getAttribute('data-t') === tp.getAttribute('data-t'));
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
      const cards = [...document.querySelectorAll('#findings article.fc:not(.chg)')];
      out.subs = subs.length + '/' + cards.length;
      out.subsOk = subs.length === cards.length && subs.every((a, i) => a.getAttribute('href') === '#' + cards[i].id);
      // plan 025: the triage list (one row per card, in card order, with a
      // micro strip and a filled impact cell), every card but one folded, a
      // row click opens its card, quiet card charts.  The dashboard design
      // has its own findings table: there #triage is hidden and no card is
      // folded (js_design opens each card it moves into a row).
      const dash = document.body.classList.contains('d-dash');
      const tri = document.getElementById('triage');
      const trows = tri ? [...tri.querySelectorAll('.tri-row[data-card]')] : [];
      // no finding card -> 07 emits no list at all; past 91 windows the
      // micro strip draws nothing (js_microstrip), so the strip is optional
      const triWin = (window.AWR_WIN && window.AWR_WIN.w) ? window.AWR_WIN.w.length : 0;
      out.triage = trows.length + '/' + cards.length + (dash ? ' (dashboard)' : '');
      out.triageOk = trows.length === cards.length
        && trows.every((r, i) => r.getAttribute('data-card') === cards[i].id
          && (dash || ((triWin > 91 || r.querySelector('.tri-spark svg.mw')) && r.querySelector('.tri-imp').textContent.trim() !== '')))
        && (!cards.length ? !tri : dash ? !vis(tri) : !!tri && vis(tri));
      const folded = cards.filter(c => c.classList.contains('fold'));
      out.folded = folded.length;
      out.foldOk = dash ? folded.length === 0 : (cards.length < 2 || folded.length === cards.length - 1);
      if (folded.length && !dash) {
        const fr = trows.find(r => r.getAttribute('data-card') === folded[0].id);
        if (fr) fr.click();
        await wait(350);
        out.unfold = !folded[0].classList.contains('fold') && vis(folded[0].querySelector('.fc-b')) ? 'ok' : 'FAIL ' + folded[0].id;
      } else out.unfold = 'none';
      const open = cards.find(c => !c.classList.contains('fold'));
      const pv = open ? open.querySelector('.wg .c:not(.cur) .v:not(.nil)') : null;
      out.quietV = !pv || getComputedStyle(pv).opacity === '0';
      out.quietFlags = cards.every(c => c.querySelectorAll('.wg.qf .flags .flag').length <= 1);
      // plan 026: the I/O card names its top statement by physical reads, and a
      // plan-change card that explains it sits right under it with its chip.
      // The dashboard design keeps it in "What changed around it" instead
      // (a column beside its findings table), chip and all.
      const dashX = document.body.classList.contains('d-dash');
      const io = document.getElementById('f-io');
      out.ioSql = io ? [...io.querySelectorAll('dl.ev .evr > dt')].some(dt => dt.textContent.trim() === 'SQL') : null;
      const ex = [...document.querySelectorAll('article.fc[data-explains]')];
      out.explains = ex.length;
      out.explainsOk = ex.every(p => (dashX ? !!p.closest('#changes-slot')
          : p.previousElementSibling && p.previousElementSibling.id === p.getAttribute('data-explains'))
        && p.querySelector('.fc-k .xpl a[href="#' + p.getAttribute('data-explains') + '"]'));
      const sl = document.getElementById('changes-slot'), sc = document.getElementById('s-changes');
      out.changesOk = !sl || !sc || (sl.children.length > 0) === !sc.hidden;
      // v1.7: cards ordered by impact; chip; Summary z capped at 10
      // (#findings article.fc:not(.chg): the dashboard moves the cards into
      // its findings table, and the plan / config cards carry .chg)
      const fc = [...document.querySelectorAll('#findings article.fc:not(.chg)')];
      const imp = fc.filter(c => c.id !== 'f-dbtime').map(c => parseFloat(c.getAttribute('data-impact')))
        .filter(v => v > 0);
      out.impOrder = imp.every((v, i) => i === 0 || imp[i - 1] >= v);
      out.impAttrs = fc.every(c => c.hasAttribute('data-impact') && c.hasAttribute('data-share'));
      out.impChips = fc.filter(c => parseFloat(c.getAttribute('data-impact')) > 0).every(c => c.querySelector('.fc-k .fc-imp'));
      // v1.7: the DB-time breakdown under the verdict
      const att = document.getElementById('att-slot');
      out.att = (att && !att.hidden && vis(att)) ? att.querySelectorAll('.att-s').length : 0;
      out.attSrcGone = !document.getElementById('att-src');
      const wcs = window.AWR_WAIT_COLORS || {};
      out.attColors = [...document.querySelectorAll('#att-slot [data-wc]')]
        .every(e => !wcs[e.getAttribute('data-wc')] || !!e.style.getPropertyValue('--c'));
      // the related-metrics fold (details.rel) is a table and keeps the exact z
      out.zcap = [...document.querySelectorAll('#findings article.fc .fc-h .bd .ov, #findings article.fc dl.ev .bd .ov, '
        + '#changes-slot article.fc .fc-h .bd .ov, #changes-slot dl.ev .bd .ov, #s-normal .nr .bd .ov, #overview .bd .ov, '
        + '.dft .drow .dbd .bd .ov')]
        .map(b => b.textContent).filter(t => /\u03c3/.test(t))
        // a capped text reads >+10 / <-10 (= 10, passes); an uncapped >+99 fails
        .filter(t => Math.abs(parseFloat(t.replace(/^[<>]/, '').replace('\u2212', '-'))) > 10);
      // v1.7 one count: the rail's Findings pills count the cards; no other rail link counts rows
      const fl = document.querySelector('nav.toc a[href="#findings"]');
      out.railFind = (fl ? [...fl.querySelectorAll('.cnt')].reduce((s, x) => s + (parseInt(x.textContent, 10) || 0), 0) : -1) + '/' + cards.length;
      out.railOther = [...document.querySelectorAll('nav.toc a .cnt')].filter(x => x.closest('a') !== fl).length;
      out.pillMoved = [...document.querySelectorAll('#pills li')].some(li => /metrics? moved/.test(li.textContent));
      const fm = document.querySelector('#findings-heading .meta.in-s');
      out.findMeta = fm ? (fm.textContent.match(/\d+/g) || []).reduce((s, x) => s + +x, 0) + '/' + cards.length : 'none';
      // J in Summary lands on a large card (a report with no large card --
      // a quiet window, only moderate findings -- walks table rows instead)
      if (document.querySelector('#findings article.fc.f-large:not(.chg)')) {
        document.dispatchEvent(new KeyboardEvent('keydown', { key: 'j', bubbles: true }));
        await wait(200);
        const fl1 = document.querySelector('#findings article.fc.flash:not(.chg)');
        out.jk = fl1 ? (fl1.classList.contains('f-large') ? 'ok' : 'FAIL not large') : 'FAIL no card flashed';
      } else out.jk = 'none (no large card)';
      // the rail sub-link names stay clean (the share is CSS ::after only)
      out.subNames = [...document.querySelectorAll('nav.toc a.sub')].every(a => !/%/.test(a.textContent) && !/%/.test(a.getAttribute('data-label') || ''));
      // plan 027: pattern tags on the finding cards (and the triage rows)
      const fcs = [...document.querySelectorAll('#findings article.fc:not(.chg)')];
      out.tagCards = fcs.length;
      out.tagNoTitle = [...document.querySelectorAll('#findings .ptag')].filter(t => !t.title || !t.textContent).length;
      out.tagChg = document.querySelectorAll('article.fc.chg .ptag').length;
      out.tagIo = [...document.querySelectorAll('#f-io .fc-tags .ptag')].map(t => t.textContent).join('|');
      out.tagTri = [...document.querySelectorAll('#triage .tri-row[data-card]')].filter(r => {
        const c = document.getElementById(r.getAttribute('data-card'));
        const a = c ? [...c.querySelectorAll('.fc-tags .ptag')].map(t => t.textContent).join('|') : '';
        const b = [...r.querySelectorAll('.tri-tags .ptag')].map(t => t.textContent).join('|');
        return a !== b;
      }).map(r => r.getAttribute('data-card'));
      // dashboard design: each lead row shows its card's tags (step 6b)
      out.tagRows = [...document.querySelectorAll('details.drow.lead')].filter(r => {
        const c = r.querySelector('article.fc');
        const a = c ? [...c.querySelectorAll('.fc-tags .ptag')].map(t => t.textContent).join('|') : '';
        const b = [...r.querySelectorAll(':scope > summary .dtags .ptag')].map(t => t.textContent).join('|');
        return a !== b;
      }).map(r => r.id);
      // plan 032: "Checked and normal" folds to one summary line; a jump to
      // #s-normal (pill, rail) opens it.  The dashboard design shows it in
      // its Normal tab with the fold open (js_design).
      const sn = document.getElementById('s-normal'), cf = sn ? sn.querySelector('details.calm-fold') : null;
      out.calm = !sn ? 'none' : !cf ? 'nofold' : (cf.open ? 'open' : 'closed');
      if (cf && !cf.open) {
        window.AWR_goTo(sn, false, false); await wait(250);
        out.calmReveal = cf.open && vis(sn.querySelector('.ngrid')) ? 'ok' : 'FAIL';
        cf.open = false;
      } else out.calmReveal = 'skip';
      // plan 033: rule-based hints; a next-step query is a copyable SELECT
      const hints = [...document.querySelectorAll('article.fc .fc-hint[data-hint]')];
      out.hints = hints.map(x => x.closest('article.fc').id + ':' + x.getAttribute('data-hint')).join(',');
      out.hintsOk = hints.every(x => {
        const pre = x.querySelector('pre.sql'), btn = x.querySelector('.copy-btn[data-copy]');
        return x.querySelector('p b') && (!pre || (btn && document.querySelector(btn.getAttribute('data-copy')) === pre
          && /^SELECT /.test(pre.textContent) && !/#[A-Z0-9]+#/.test(pre.textContent)));
      });
      // the plan card keeps section 23's "Plan shape" link in its footer
      out.hintPfl = [...document.querySelectorAll('article.fc.chg[id^="f-plan-"]')].every(c => c.querySelector('.fc-f .evl a[href="#topsql"]'));
      // dashboard design: the plan card's query never widens the side column
      const side = document.querySelector('aside.dside');
      out.hintSide = side ? side.scrollWidth <= side.clientWidth + 1 : true;
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
    if (/demo_busy_db(_quiet|_dashboard)?\.html$/.test(file) && !p4.att) fail('DB-time breakdown: not shown under the verdict');
    if (!p4.attSrcGone) fail('DB-time breakdown: #att-src left in the page');
    if (!p4.attColors) fail('DB-time breakdown: a part has no wait-class colour');
    if (!p4.impAttrs) fail('finding cards: data-impact / data-share missing');
    if (!p4.impOrder) fail('finding cards: not ordered by impact');
    if (!p4.impChips) fail('finding cards: impact chip missing');
    if (p4.zcap.length) fail('Summary glyphs print z past 10: ' + p4.zcap.join(', '));
    if (!p4.planOk) fail('plan-change card incomplete, or neither in #changes-slot nor right under the card it explains');
    if (!p4.durOk) fail('plan card: elapsed not shown as a duration');
    if (!p4.aasOk) fail('Timeline: a wait-event row is not in AAS');
    if (!p4.smOrder) fail('SQL Monitor table: flagged statements not first, or a detail row lost its statement');
    if (!p4.topsqlTab) fail('Top SQL: the selected tab and the open panel disagree');
    if (p4.ioSql === false && /demo_busy_db(_quiet|_dashboard)?\.html$/.test(file)) fail('demo: the Physical I/O card has no SQL evidence row');
    if (!p4.explainsOk) fail('an explaining plan-change card is not right under its card (dashboard: not in #changes-slot) or lacks its chip');
    if (/demo_busy_db(_quiet|_dashboard)?\.html$/.test(file) && p4.explains !== 1) fail('demo: expected the plan card of 7k2m9dx4qp1zb to explain the Physical I/O card, got ' + p4.explains);
    if (!p4.changesOk) fail('"What changed around it" visible while empty, or hidden while it holds a card');
    if (!p4.lib || p4.libVisible !== p4.lib) fail('evidence library: ' + p4.libVisible + '/' + p4.lib + ' rows visible in Summary');
    if (p4.libNoLs.length) fail('evidence library rows without a one-line status: ' + p4.libNoLs.join(', '));
    if (!p4.libHead) fail('evidence library heading #s-lib not visible');
    if (!p4.edges) fail('evidence library: first / last row edges');
    if (/^FAIL/.test(p4.toggle)) fail('evidence library row toggle ' + p4.toggle);
    if (/^FAIL/.test(p4.reveal)) fail('evidence library reveal ' + p4.reveal);
    if (!p4.subsOk) fail('rail card sub-links ' + p4.subs);
    if (!p4.hintsOk) fail('card hints: a hint without its line, or a next-step query not copyable / with an unfilled placeholder: ' + p4.hints);
    if (!p4.hintPfl) fail('card hints: a plan card lost its footer links (section 23 adds "Plan shape" there)');
    if (!p4.hintSide) fail('card hints: the dashboard side column is wider than its box');
    if (/demo_busy_db(_quiet|_dashboard)?\.html$/.test(file) && !/f-io:IO_SCANS/.test(p4.hints)) fail('demo: the Physical I/O card should carry the IO_SCANS hint, got ' + p4.hints);
    if (/demo_busy_db(_quiet|_dashboard)?\.html$/.test(file) && !/f-plan-[a-z0-9]+:PLAN/.test(p4.hints)) fail('demo: the plan-change card should carry the PLAN hint, got ' + p4.hints);
    if (p4.tagNoTitle) fail('pattern tags: ' + p4.tagNoTitle + ' chip(s) without text / title');
    if (p4.tagChg) fail('pattern tags: ' + p4.tagChg + ' chip(s) on a plan / config card');
    if (p4.tagTri.length) fail('pattern tags: triage row differs from its card: ' + p4.tagTri.join(', '));
    if (p4.tagRows.length) fail('pattern tags: dashboard row differs from its card: ' + p4.tagRows.join(', '));
    if (/demo_busy_db(_quiet|_dashboard)?\.html$/.test(file) && p4.tagIo !== 'jump after Release 4.2|step up at Release 4.1')
      fail('pattern tags: the demo Physical I/O card shows "' + p4.tagIo + '"');
    if (!p4.triageOk) fail('triage list: ' + p4.triage + ' rows (expected one per card, in card order, micro strip + impact cell)');
    if (!p4.foldOk) fail('folded cards: ' + p4.folded + ' start folded (expected all but one)');
    if (/^FAIL/.test(p4.unfold)) fail('a triage row click did not open its card: ' + p4.unfold);
    if (!p4.quietV) fail('card chart: a prior value is visible without hover');
    if (!p4.quietFlags) fail('card charts: more than one release label on a card');
    if (/demo_busy_db(_quiet)?\.html$/.test(file) && p4.calm !== 'closed') fail('demo: "Checked and normal" should start folded, got ' + p4.calm);
    if (/demo_busy_db_dashboard\.html$/.test(file) && p4.calm !== 'open') fail('dashboard demo: the Normal tab should show "Checked and normal" open, got ' + p4.calm);
    if (p4.calmReveal === 'FAIL') fail('a jump to #s-normal did not open its fold');
    const [rf, rc] = p4.railFind.split('/');
    if (rf !== rc) fail('rail Findings pills count ' + rf + ', cards ' + rc);
    if (p4.railOther) fail('rail: ' + p4.railOther + ' count pill(s) outside the Findings link');
    if (p4.pillMoved) fail('verdict: a "metrics moved" pill is back');
    if (p4.findMeta !== 'none' && p4.findMeta.split('/')[0] !== p4.findMeta.split('/')[1]) fail('Findings header (Summary) does not count the cards: ' + p4.findMeta);
    if (/^FAIL/.test(p4.jk)) fail('J in Summary: ' + p4.jk);
    if (!p4.subNames) fail('rail card sub-link text / data-label carries the share');
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

  // ---- 7. the design (quiet / dashboard): the shared pieces, then the
  // dashboard's KPI cards, findings table, Activity tabs and palette
  if (DESIGN !== 'classic') {
    const { page, errors } = await openPage('#view=summary', 'light');
    const dz = {};
    dz.how = await page.evaluate(async () => {
      const b = document.querySelector('#ashx .axhow'), p = document.querySelector('#ashx .axn2');
      if (!b || !p) return 'FAIL missing';
      const vis = el => el.getClientRects().length > 0;
      if (vis(p)) return 'FAIL open before the click';
      b.click(); await new Promise(r => setTimeout(r, 80));
      const open = vis(p) && b.getAttribute('aria-expanded') === 'true';
      document.body.click(); await new Promise(r => setTimeout(r, 80));
      return open && !vis(p) ? 'ok' : 'FAIL ' + open;
    });
    if (!/^ok/.test(dz.how)) fail('design: How to read ' + dz.how);
    dz.menu = await page.evaluate(async () => {
      window.AWR_setView('all', false); await new Promise(r => setTimeout(r, 200));
      const bars = [...document.querySelectorAll('.tbl-tools')], raw = bars.filter(b => b.querySelector(':scope > .tool-btn')).length;
      const m = bars.map(b => b.querySelector('details.tmenu')).find(d => d && d.getClientRects().length);
      if (!m) return bars.length ? 'FAIL no visible menu' : 'none';
      m.querySelector('summary').click(); await new Promise(r => setTimeout(r, 60));
      const n = m.open ? m.querySelectorAll('.tool-btn').length : 0;
      document.body.click(); await new Promise(r => setTimeout(r, 60));
      window.AWR_setView('summary', false);
      return n === 2 && !m.open && !raw ? 'ok (' + bars.length + ' menus)' : 'FAIL ' + JSON.stringify([n, m.open, raw]);
    });
    if (/^FAIL/.test(dz.menu)) fail('design: table copy menu ' + dz.menu);
    if (DESIGN === 'dashboard') {
      await page.waitForTimeout(200);
      const lay = await page.evaluate(() => {
        const vis = el => !!el && el.getClientRects().length > 0;
        const kp = [...document.querySelectorAll('.dkpis .dkpi')];
        const cards = [...document.querySelectorAll('#findings article.fc:not(.chg)')];
        const rows = [...document.querySelectorAll('.dft details.drow')];
        const tab = document.querySelector('.dtabs [data-t="moved"] .n');
        const top = id => { const e = document.getElementById(id); return e ? e.getBoundingClientRect().top : NaN; };
        return { dash: document.body.classList.contains('d-dash'), rail: vis(document.querySelector('nav.toc')), search: vis(document.querySelector('.dsearch')),
          kpis: kp.length, kpiBars: kp.filter(k => k.querySelector('svg.dwb rect.dbc')).length, cards: cards.length,
          dbtCard: !!document.getElementById('f-dbtime'), hero: !!document.getElementById('hero-dbt'),
          inRows: cards.filter(c => c.parentElement.closest('details.drow.lead')).length, rows: rows.length, tabN: tab ? +tab.textContent : 0,
          trends: rows.filter(r => r.querySelector('.dtr svg')).length,
          order: top('verdict') < top('activity') && document.querySelector('.dkpis').getBoundingClientRect().top < top('activity') && top('activity') < top('findings') };
      });
      dz.layout = lay;
      const nk = (lay.hero ? 1 : 0) + lay.cards - (lay.dbtCard && lay.hero ? 1 : 0);
      if (!lay.dash || lay.rail || !lay.search) fail('dashboard: body.d-dash / rail hidden / Jump to button ' + JSON.stringify(lay));
      if (lay.kpis !== nk || lay.kpiBars !== lay.kpis) fail('dashboard: KPI cards ' + lay.kpis + ' (expected ' + nk + '), ' + lay.kpiBars + ' with bars');
      if (lay.inRows !== lay.cards || lay.rows !== lay.tabN || lay.trends !== lay.rows) fail('dashboard: findings table ' + JSON.stringify(lay));
      if (!lay.order) fail('dashboard: Summary order (verdict, KPI cards, Activity, findings)');
      // rows open: a lead row shows its card, another row draws its bars
      dz.rows = await page.evaluate(async () => {
        const vis = el => !!el && el.getClientRects().length > 0;
        const lead = document.querySelector('details.drow.lead'), other = document.querySelector('details.drow:not(.lead)');
        if (!lead) return 'none';
        lead.querySelector('summary').click(); await new Promise(r => setTimeout(r, 120));
        const a = lead.open && vis(lead.querySelector('article.fc .wg'));
        let b = true;
        if (other) { other.querySelector('summary').click(); await new Promise(r => setTimeout(r, 120)); b = other.open && other.querySelectorAll('.dbars svg.dwb rect.dbc').length === 1; other.open = false; }
        lead.open = false;
        return a && b ? 'ok' : 'FAIL ' + JSON.stringify([a, b]);
      });
      if (/^FAIL/.test(dz.rows)) fail('dashboard: row expansion ' + dz.rows);
      // the Normal tab, and a jump into it switches the tab
      dz.tabs = await page.evaluate(async () => {
        const vis = el => !!el && el.getClientRects().length > 0;
        const sn = document.getElementById('s-normal'); if (!sn) return 'none';
        const n = document.querySelector('.dtabs [data-t="normal"]'), m = document.querySelector('.dtabs [data-t="moved"]');
        if (vis(sn)) return 'FAIL normal shown under Moved';
        n.click(); await new Promise(r => setTimeout(r, 80)); const a = vis(sn);
        m.click(); await new Promise(r => setTimeout(r, 80));
        window.AWR_goTo(sn, false, false); await new Promise(r => setTimeout(r, 200));
        const b = vis(sn) && n.classList.contains('on');
        m.click();
        return a && b ? 'ok' : 'FAIL ' + JSON.stringify([a, b]);
      });
      if (/^FAIL/.test(dz.tabs)) fail('dashboard: findings tabs ' + dz.tabs);
      // the Activity tabs: one chart (x labels + flags on it) or both
      dz.ax = await page.evaluate(async () => {
        const vis = el => !!el && el.getClientRects().length > 0;
        const wait = ms => new Promise(r => setTimeout(r, ms));
        const mk = (window.AWR_WG && AWR_WG.markers ? AWR_WG.markers() : []).length;
        const st = id => ({ v: vis(document.querySelector('#' + id + ' .axp')), xa: document.querySelectorAll('#' + id + ' .axsvg path.xa').length,
          x: document.querySelectorAll('#' + id + ' .axsvg text.at[text-anchor="middle"]').length, f: document.querySelectorAll('#' + id + ' .axsvg text.cft').length });
        const out = [];
        for (const m of ['ev', 'cls', 'both']) {
          document.querySelector('.axseg [data-ax="' + m + '"]').click(); await wait(250);
          const c = st('ax-cls'), e = st('ax-ev');
          const ok = m === 'both' ? c.v && e.v && c.xa && e.xa && !c.x && e.x && (!mk || (c.f && !e.f))
            : (m === 'cls' ? c.v && !e.v && c.xa && c.x && (!mk || c.f) : e.v && !c.v && e.xa && e.x && (!mk || e.f));
          out.push(m + (ok ? ' ok' : ' FAIL ' + JSON.stringify([c, e])));
        }
        document.querySelector('.axseg [data-ax="cls"]').click(); await wait(150);
        return out.join(', ');
      });
      if (/FAIL/.test(dz.ax)) fail('dashboard: Activity tabs ' + dz.ax);
      // the palette: Ctrl+K opens it (not the row filter), a search + Enter
      // lands on the row, Esc closes it and leaves a pinned window pinned
      const q = await page.evaluate(() => { const r = document.querySelector('details.drow:not(.lead) .dnm b') || document.querySelector('details.drow .dnm b'); return r ? r.textContent : 'Load profile'; });
      await page.keyboard.press('Control+k'); await page.waitForTimeout(150);
      const o1 = await page.evaluate(() => ({ open: document.querySelector('dialog.dpal').open, fi: document.activeElement && document.activeElement.id === 'row-filter' }));
      await page.keyboard.type(q); await page.waitForTimeout(150);
      const pick = await page.evaluate(() => { const li = document.querySelector('dialog.dpal li[aria-selected="true"]'); return li ? li.textContent : ''; });
      await page.keyboard.press('Enter'); await page.waitForTimeout(500);
      const o2 = await page.evaluate(() => { const h = (location.hash || '').slice(1), t = h && document.getElementById(h);
        const r = t && t.getBoundingClientRect(); return { open: document.querySelector('dialog.dpal').open, id: h, shown: !!t && t.getClientRects().length > 0 && r.top < innerHeight && r.bottom > 0 }; });
      await page.evaluate(() => { const w = (window.AWR_WIN && AWR_WIN.w) || []; if (w.length > 1 && window.AWR_WG && AWR_WG.pin) AWR_WG.pin(w[0].o); });
      await page.keyboard.press('Control+k'); await page.waitForTimeout(120);
      await page.keyboard.press('Escape'); await page.waitForTimeout(120);
      const o3 = await page.evaluate(() => ({ open: document.querySelector('dialog.dpal').open, pinned: document.body.hasAttribute('data-pw') }));
      dz.palette = (o1.open && !o1.fi && pick && !o2.open && o2.shown && !o3.open && o3.pinned) ? 'ok ("' + q + '" -> #' + o2.id + ')' : 'FAIL ' + JSON.stringify([o1, pick, o2, o3]);
      if (!/^ok/.test(dz.palette)) fail('dashboard: palette ' + dz.palette);
      await page.keyboard.press('Escape');
      if (shots) { await page.evaluate(() => window.scrollTo(0, 0)); await page.waitForTimeout(150); await page.screenshot({ path: path.join(shots, 'dashboard-top.png') }); }
    }
    console.log('design ' + DESIGN + ': ' + JSON.stringify(dz));
    if (errors.length) fail('design: ' + errors.slice(0, 5).join(' | '));
    await page.close();
  }

  // ---- 8. the visualization sections (20-28): each one is there once,
  // draws (or says why not) in All sections and in an opened library row,
  // keeps its numbers in a table, stays inside the page at phone width;
  // the instance map agrees with the finding cards.  A report from before
  // these sections (none of the ids present) skips the block.
  {
    const VIZ = ['instance-map', 'load-response', 'release-delta', 'win-sim', 'onset', 'wait-hist', 'blocking', 'volume-cost', 'plan-flame'];
    const { page, errors } = await openPage('#view=all', 'light');
    const have = await page.evaluate(ids => ids.filter(id => document.querySelectorAll('[id="' + id + '"]').length), VIZ);
    if (have.length) {
      const probe = () => page.evaluate(ids => {
        const vis = el => !!el && el.getClientRects().length > 0;
        const out = {};
        ids.forEach(id => {
          const n = document.querySelectorAll('[id="' + id + '"]').length;
          const s = document.getElementById(id);
          if (n !== 1 || !s) { out[id] = 'FAIL ' + n + ' elements'; return; }
          const drawn = [...s.querySelectorAll('svg, canvas')].filter(g => vis(g) && g.getBoundingClientRect().width > 40
            && (g.tagName.toLowerCase() === 'canvas' || g.childElementCount > 2)).length;
          const note = [...s.querySelectorAll('p.note')].filter(vis).length;
          const html = [...s.querySelectorAll('[class]')].filter(e => vis(e) && e.children.length > 3).length;
          const tables = s.querySelectorAll('table').length;
          const wide = s.scrollWidth > s.clientWidth + 2;
          const body = [...s.children].filter(c => c.tagName !== 'H2' && vis(c)).length;
          out[id] = (!vis(s) ? 'FAIL hidden' : !body ? 'FAIL empty' : (!drawn && !note && !html) ? 'FAIL nothing drawn and no note'
            : (!tables && !note) ? 'FAIL no table of the numbers' : wide ? 'FAIL wider than its box' : 'ok')
            + ' (' + drawn + ' drawn, ' + tables + ' tables' + (note ? ', note' : '') + ')';
        });
        return out;
      }, have);
      const all = await probe();
      console.log('viz sections, All sections: ' + JSON.stringify(all));
      VIZ.forEach(id => { if (!all[id]) fail('viz: section #' + id + ' missing'); else if (/^FAIL/.test(all[id])) fail('viz (All sections) #' + id + ': ' + all[id]); });
      // Summary: every row opened by a click on its h2 draws too
      await page.evaluate(() => window.AWR_setView('summary', false)); await page.waitForTimeout(300);
      await page.evaluate(async ids => {
        for (const id of ids) {
          const s = document.getElementById(id);
          if (s && s.classList.contains('lib') && !s.classList.contains('lopen')) s.querySelector('h2').click();
        }
        await new Promise(r => setTimeout(r, 900));
      }, have);
      const sm = await probe();
      console.log('viz sections, Summary rows opened: ' + JSON.stringify(sm));
      have.forEach(id => { if (/^FAIL/.test(sm[id])) fail('viz (Summary, row opened) #' + id + ': ' + sm[id]); });
      // the instance map never disagrees with the cards: a flagged area
      // links to a card that exists, and every card is behind some area
      const im = await page.evaluate(() => {
        const s = document.getElementById('instance-map');
        if (!s) return 'none';
        const areas = [...s.querySelectorAll('[data-sev]')];
        const flagged = areas.filter(a => /large|moderate/.test(a.getAttribute('data-sev')));
        const behind = {};
        areas.forEach(a => (a.getAttribute('data-cards') || '').split(/[ ,]+/).filter(Boolean).forEach(c => { behind[c] = 1; }));
        const cards = [...document.querySelectorAll('#findings article.fc:not(.chg)')].map(c => c.id);
        const lost = cards.filter(c => !behind[c]);
        const dead = flagged.filter(a => { const h = (a.getAttribute('href') || a.getAttribute('xlink:href') || '').replace('#', ''); return !h || !document.getElementById(h); }).length;
        if (!areas.length) return 'ok (not measured)';
        return (lost.length || dead) ? 'FAIL cards without an area: ' + lost.join(',') + '; flagged areas without a card: ' + dead
          : 'ok (' + flagged.length + ' flagged areas, ' + cards.length + ' cards)';
      });
      console.log('viz instance map vs cards: ' + im);
      if (/^FAIL/.test(im)) fail('viz: instance map ' + im);
      // the window-similarity what-if re-scores with the report's own rule
      const ws = await page.evaluate(() => {
        const api = window.AWR_WINSIM, sec = document.getElementById('win-sim');
        if (!api || !Array.isArray(api.check)) return (sec && sec.querySelector('p.note')) ? 'none (too few windows)' : 'FAIL no AWR_WINSIM.check';
        return api.check.length ? 'FAIL ' + api.check.length + ' mismatches: ' + api.check.slice(0, 3).join('; ') : 'ok (' + (sec.getAttribute('data-winsim-check') || '') + ')';
      });
      console.log('viz window similarity, JS rule vs PL/SQL buckets: ' + ws);
      if (/^FAIL/.test(ws)) fail('viz: window similarity ' + ws);
      // phone width: no section pushes the page sideways
      await page.setViewportSize({ width: 390, height: 844 }); await page.waitForTimeout(500);
      const ph = await page.evaluate(ids => ids.filter(id => { const s = document.getElementById(id); return s && s.getBoundingClientRect().width > 0 && s.scrollWidth > s.clientWidth + 2; }), have);
      console.log('viz sections at 390 px: ' + (ph.length ? 'FAIL ' + ph.join(', ') : 'ok'));
      if (ph.length) fail('viz: wider than its box at 390 px: ' + ph.join(', '));
      if (errors.length) fail('viz: ' + errors.slice(0, 5).join(' | '));
    } else console.log('viz sections: none in this report (older report), skipped');
    await page.close();
  }

  await browser.close();
  if (failures.length) { console.log('FAILURES:'); failures.forEach(f => console.log('  ' + f)); }
  else console.log('verify: OK');
  process.exit(failures.length ? 1 : 0);
})();
