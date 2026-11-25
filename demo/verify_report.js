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
 *     unpinning; a click on a band keeps it, the same click clears it
 *     (at a band point under no stripe's hit area: zoomed into the busiest
 *     window first when the stripes tile the span, e.g. 169 hourly
 *     windows; the demo needs no zoom);
 *   - the Activity charts' Windows side by side mode (plan 024): one panel
 *     per window, hover / crosshair, no zoom, cap click pins, legend,
 *     markers, the switch remembered in awr-axlayout; Enter on a focused
 *     stripe / cap keeps the focus through the redraw (both layouts); the
 *     flag band only while a flag is drawn side by side; three markers in
 *     one gap all named (a "+n" flag lists the rest, block 5d), every flag
 *     inside its SVG;
 *   - the Activity charts at 390 px (R3, block 5e): the SVG keeps a 480-px
 *     viewBox there, scaled down and centred vertically, so a hover over a
 *     band lights exactly that band (soft highlight, both charts, both
 *     layouts) and the brush covers the plot's height;
 *   - direct labels on the Activity bands (plan 036, fitted per band): name
 *     a series, inside the plot and inside the band they name, no overlap,
 *     at most 6, gone when the series is hidden; inside one panel side by
 *     side; never over the highlight note; the demo labels both charts in
 *     both layouts;
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
 *     in full (its first chart / table holding a number; section 28 with
 *     no release marker shows its reason note and its all-priors table
 *     instead of the empty split view; the demo opens on a split); the
 *     Trend cells are micro strips (svg.mw), no line left;
 *     plan 040 (block 6c): Top SQL / Foreground waits (data-news) start
 *     shut exactly when everything their status names is on a card (open
 *     when there is no finding card); a click / a jump opens them; and
 *     script#awr-findings parses, with one entry per finding card equal to
 *     the card's id / severity / data-impact / data-share, counts equal to
 *     the verdict pill, no raw "<";
 *     v1.7: cards ordered by data-impact (rises of 0.01 AAS or more
 *     first, largest first), chip present, Summary z capped
 *     at 10; R4: a flagged card whose time measure rose under 0.01 AAS
 *     (a background-only wait class, scored on all sessions) has no chip
 *     or share, follows every tier-1 card, reads "under 0.01 AAS" in the
 *     triage list and is no breakdown part without a rise (required on
 *     the demo: Queueing waits, impact 0); the DB-time breakdown under the
 *     verdict (#att-slot) shown
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
 *     right under it, folded exactly when that card is (dashboard: in
 *     What changed around it, beside the findings, open); plan 032: Checked and normal starts folded (one line) and
 *     a jump to it opens it; in the dashboard its Normal tab shows it open;
 *     G4: beforeprint opens every folded card, that fold and (dashboard)
 *     every lead row, afterprint restores the screen state;
 *     plan 033: card hints (rule id, line, copyable read-only query with
 *     no unfilled placeholder; R2: a rule with a query in
 *     sql/lib/finding_hints.plsql shows it, every query is read-only
 *     "SELECT ... ;" statements; the plan card keeps its footer links; the
 *     dashboard side column does not overflow); R2: a plan card that
 *     explains a card shows the transition that card cites, and no card
 *     links a plan card citing another one;
 *   - pattern tags (plan 027): every chip has text and a title, is
 *     focusable and named by its text, keyboard focus shows its sentence
 *     (#ptip) and Esc hides it without swallowing the unpin (G4); none on a
 *     plan / config card, a triage row and a dashboard findings row show
 *     their card's chips, the demo Physical I/O card reads "jump after
 *     Release 4.2" + "step up at Release 4.1";
 *   - the design (window.AWR_DESIGN, design=quiet|dashboard; none =
 *     classic): quiet and dashboard -- "How to read" opens / closes the
 *     Activity help, a table's copy menu holds CSV + Markdown; dashboard --
 *     no rail (its checks are skipped), the Summary puts the verdict and
 *     the KPI cards above Activity, one KPI per finding card + DB time
 *     with bars, every finding card inside a row of the findings table
 *     (count = the Moved tab), each lead row shows its card's impact
 *     chip (.dimp; required on the demo, and a lead row without it: the
 *     background-only card), a row opens to its bars / its card, the
 *     Normal tab shows #s-normal and a jump into it switches the tab, the
 *     Activity tabs show one chart (x labels + release flags on it) or
 *     both, Ctrl+K opens the palette (not the row filter), a search +
 *     Enter lands on the row, Esc closes it without unpinning; the
 *     Activity interaction checks run with both charts shown;
 *   - Top SQL "Values: Total | Per execution | Top per execution" (block 10):
 *     the switch in EVERY panel (own data attribute, never the chart
 *     toggle's hooks; three buttons, mode values total / perexec / pe-rank),
 *     one shared state set before the panels are parsed, saved on a click
 *     only (each of the three values) and read on load.  Per execution = a
 *     client-side swap inside the Total view of the four metric tabs: the
 *     same statements, order and # ranks (the badges stay visible, a note
 *     says so), every value read per execution (data-pe / data-pt, the
 *     header unit, the chart's ...Pe arrays and unit), restored exactly;
 *     the Current s/exec is elapsed / executions of the Compared windows
 *     table; a no-completed-execution window is a dash with its title; the
 *     payload's Pe arrays line up one-directionally.  Top per execution =
 *     the separate ranking (ELAPSED_PE ...: own # badges, order, chart,
 *     Break down by, detail table; ranks 1..n descending, a window with no
 *     completed execution never ranked, the chart drawn with a width);
 *     the notes of Biggest change / Executions / Per-exec regression in
 *     each mode; a link to a row the mode hides shows its view without
 *     saving, a Total row in per execution mode changes nothing; the
 *     Per-SQL pool has the P chip; JS off = no switch, both views stacked;
 *     three buttons fit at 390 px; works without ECharts;
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

// plan 033 / review follow-up R2: the hint rules that have a "Next step"
// query, read from the hint_sql table of sql/lib/finding_hints.plsql (one
// WHEN line per rule, like demo/awrdemo/helpers.py); null when the file is
// not there (the check then only looks at the queries it finds)
const HINT_SQL_RULES = (() => {
  try {
    const t = fs.readFileSync(path.join(__dirname, '..', 'sql', 'lib', 'finding_hints.plsql'), 'utf8');
    const a = t.indexOf('FUNCTION hint_sql'), b = t.indexOf('FUNCTION', a + 10);
    if (a < 0) return null;
    return [...t.slice(a, b < 0 ? undefined : b).matchAll(/WHEN\s+'([A-Z0-9_]+)'\s+THEN\s+'/g)].map(m => m[1]);
  } catch (e) { return null; }
})();

// plan 036 (fitted per band): defines window.__awrLabelBand(id, key) in the
// page = the number of band labels of chart #id (payload AWR_DATA[key])
// not inside the band they name: at three points along the label (both
// ends and the middle) the topmost band under it must be its series (the
// bands paint top of the stack first, each from the axis up, so the
// topmost one at a point is the band holding it); a cut name ("...") whose
// stem starts two series is ambiguous and counts too (G3 review)
const LABEL_BAND = () => {
  window.__awrLabelBand = (id, key) => {
    const s = document.querySelector('#' + id + ' .axsvg'); if (!s || !s.getClientRects().length) return 0;
    const names = ((window.AWR_DATA || {})[key] || {}).classes || [];
    let bad = 0;
    s.scrollIntoView({ block: 'center' });
    for (const t of s.querySelectorAll('text.xdl')) {
      const n = t.textContent, ex = names.indexOf(n), pm = names.map((x, q) => n.endsWith('...') && x.startsWith(n.slice(0, -3)) ? q : -1).filter(q => q >= 0);
      const k = ex >= 0 ? ex : pm.length === 1 ? pm[0] : -1;
      const sw = document.querySelector('#' + id + ' .axlg .axc[data-c="' + k + '"] .sw');
      const col = sw ? sw.style.getPropertyValue('--sw').trim() : '';
      const b = t.getBoundingClientRect(), y = b.top + b.height * 0.55;
      if (!col || [b.left + 4, (b.left + b.right) / 2, b.right - 4].some(x => {
        const p = document.elementsFromPoint(x, y).find(e => e.matches && e.matches('path.xa'));
        return !p || p.getAttribute('fill') !== col;
      })) bad++;
    }
    return bad;
  };
};

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
        // keyboard: Enter on a focused stripe pins, Esc clears; the focus
        // stays on that stripe through both redraws (G3: it was lost)
        const kb = await page.evaluate((id) => {
          const hs = [...document.querySelectorAll('#' + id + ' .axsvg .xwh')].filter(x => x.getAttribute('data-w') !== '0');
          if (!hs.length) return 'none';
          const hwin = hs[0], di = hwin.getAttribute('data-i'); hwin.focus();
          const kept = () => { const a = document.activeElement; return !!a && a.getAttribute('class') === 'xwh' && a.getAttribute('data-i') === di && !!a.closest('#' + id); };
          hwin.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', bubbles: true }));
          const pinned = document.body.getAttribute('data-pw') === hwin.getAttribute('data-w'), f1 = kept();
          document.activeElement.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true }));
          const f2 = kept();
          return pinned && !document.body.hasAttribute('data-pw') ? (f1 && f2 ? 'ok' : 'FAIL focus lost ' + JSON.stringify([f1, f2])) : 'FAIL';
        }, id);
        tl['keys_' + k] = kb;
        if (/^FAIL/.test(kb)) fail('activity ' + k + ': Enter / Esc ' + kb);
      }
      // direct labels (plan 036): each label names a series, sits inside the
      // plot, no two overlap, at most 6 a chart; hiding the first labelled
      // series removes its label, showing it again restores it (key
      // bandLabels: tl.labels holds the grid label links above)
      await page.evaluate(LABEL_BAND);
      tl.bandLabels = await page.evaluate(() => {
        const out = [];
        for (const [id, key] of [['ax-cls', 'ashx'], ['ax-ev', 'ashe']]) {
          const s = document.querySelector('#' + id + ' .axsvg'); if (!s || !s.getClientRects().length) continue;
          const names = ((window.AWR_DATA || {})[key] || {}).classes || [];
          const L = [...s.querySelectorAll('text.xdl')], ax = s.querySelector('line.ax').getBoundingClientRect();
          const bad = L.filter(t => { const n = t.textContent; return !names.some(x => x === n || (n.endsWith('...') && x.startsWith(n.slice(0, -3)))); }).length;
          const B = L.map(t => t.getBoundingClientRect());
          let ov = 0; for (let i = 0; i < B.length; i++) for (let j = i + 1; j < B.length; j++) if (B[i].left < B[j].right && B[j].left < B[i].right && B[i].top < B[j].bottom && B[j].top < B[i].bottom) ov++;
          const outside = B.filter(b => b.left < ax.left - 1 || b.right > ax.right + 1 || b.bottom > ax.top + 1).length;
          const band = window.__awrLabelBand(id, key);
          out.push(id + ' ' + L.length + (bad || ov || outside || band || L.length > 6 ? ' FAIL bad=' + bad + ' overlap=' + ov + ' outside=' + outside + ' offband=' + band : ''));
        }
        return out.join('; ');
      });
      if (/FAIL/.test(tl.bandLabels)) fail('activity: direct labels ' + tl.bandLabels);
      if (/demo_busy_db(_quiet|_dashboard)?\.html$/.test(file) && !/ax-cls [1-6]; ax-ev [1-6]$/.test(tl.bandLabels)) fail('activity: the demo must label at least one band on each chart: ' + tl.bandLabels);
      {
        const first = await page.evaluate(() => { const t = document.querySelector('#ax-ev .axsvg text.xdl'); if (!t) return null; const nm = t.textContent; const i = AWR_DATA.ashe.classes.indexOf(nm); return i < 0 ? null : { nm, i }; });
        if (first) {
          const has = () => page.evaluate((nm) => [...document.querySelectorAll('#ax-ev .axsvg text.xdl')].some(t => t.textContent === nm), first.nm);
          await page.click('#ax-ev .axlg .axc[data-c="' + first.i + '"]'); await page.waitForTimeout(150);
          const gone = !(await has());
          await page.click('#ax-ev .axlg .axc[data-c="' + first.i + '"]'); await page.mouse.move(2, 2); await page.waitForTimeout(200);
          const back = await has();
          tl.labelHide = gone && back ? 'ok' : 'FAIL ' + JSON.stringify([first.nm, gone, back]);
          if (tl.labelHide !== 'ok') fail('activity: hiding a labelled series ' + tl.labelHide);
        }
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
            // plan 036 review: a band label never covers the highlight note
            const nt = s.querySelector('text.xhn'), nb = nt && nt.getBoundingClientRect();
            const xov = nb ? [...s.querySelectorAll('text.xdl')].filter(t => { const b = t.getBoundingClientRect(); return b.left < nb.right && nb.left < b.right && b.top < nb.bottom && nb.top < b.bottom; }).length : 0;
            return { fd: !!s.querySelector('g.xfd'), n: bands.length, onAxis, note: !!s.querySelector('text.xhn'), xov,
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
        if (s1.c.xov || s1.e.xov) fail('activity: a band label covers the highlight note (class legend hover)');
        // an event lights its class, in place (no note, not re-based)
        const ei = ecls ? ecls.findIndex(x => x && x !== 'CPU' && cls.includes(x)) : -1;
        if (ei >= 0) {
          await page.hover('#ax-ev .axlg .axc[data-c="' + ei + '"]'); await page.waitForTimeout(150);
          const s2 = await state();
          hl.ev = (s2.e.fd && s2.e.n === 1 && s2.e.onAxis && s2.e.note && s2.c.n === 1 && !s2.c.note && s2.c.lit === 1) ? 'ok (' + ecls[ei] + ' lit)' : 'FAIL ' + JSON.stringify(s2);
          if (!/^ok/.test(hl.ev)) fail('activity: event legend highlight ' + hl.ev);
          if (s2.c.xov || s2.e.xov) fail('activity: a band label covers the highlight note (event legend hover)');
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
        // a click on the bottom band keeps it; the same click clears it.  The
        // point is a band under no window stripe's hit area: a stripe narrower
        // than 24 px is hit-tested on its full height (a click there pins the
        // window), a wider one on its cap only (its faded body may lie over the
        // band: the click still reaches it).  When the compared windows tile
        // the span (169 hourly windows: every x is a stripe) the chart is first
        // zoomed into the busiest window and its neighbours, where the stripes
        // are wide -- the designed way to reach the buckets under dense
        // stripes.  The demo's stripes leave a band point without zooming
        // (required).
        const bandPt = () => page.evaluate(() => { const s = document.querySelector('#ax-cls .axsvg'), r = s.getBoundingClientRect(), ax = s.querySelector('line.ax'), sc = r.width / s.viewBox.baseVal.width;
          const y = r.top + (+ax.getAttribute('y1') - 1.5) * sc;
          for (let f = 0.3; f < 0.97; f += 0.005) {
            // the first hit below any stripe body / label must be a band fill:
            // a band edge (path.xe) on top means the stack is about zero there,
            // so the click is off the stack (weekly report on the test DB)
            const es = document.elementsFromPoint(r.left + r.width * f, y), i = es.findIndex(e => !e.matches('rect.xw, rect.xwc, text.xdl'));
            if (i >= 0 && es[i].matches('path.xa')) return { x: r.left + r.width * f, y };
          }
          return null; });
        let px = await bandPt(), zoomed = false, s8 = null, s9 = null;
        if (!px) {
          const zx = await page.evaluate(() => { const W = (AWR_DATA.ashx || {}).win || [], n = W.length ? W[0].length : 0; let bi = -1, bv = -1;
            for (let i = 0; i < n; i++) { let t = 0; W.forEach(a => { t += +a[i] || 0; }); if (t > bv) { bv = t; bi = i; } }
            const h = document.querySelector('#ax-cls .axsvg .xwh[data-i="' + bi + '"]'); if (!h) return null;
            const r = h.getBoundingClientRect(); return { x: r.left + r.width / 2, y: r.top + r.height / 2 }; });
          if (zx) {
            await page.mouse.move(zx.x - 16, zx.y);
            await page.mouse.down(); await page.mouse.move(zx.x + 16, zx.y, { steps: 6 }); await page.mouse.up();
          }
          await page.waitForTimeout(200); await page.mouse.move(10, 10); await page.waitForTimeout(100);
          zoomed = await page.evaluate(() => !document.getElementById('ax-reset').hidden);
          if (zoomed) px = await bandPt();
        }
        if (px) {
          await page.mouse.click(px.x, px.y); await page.waitForTimeout(150);
          await page.mouse.move(10, 10); await page.waitForTimeout(100);
          s8 = await state();
          await page.mouse.click(px.x, px.y); await page.waitForTimeout(150);
          await page.mouse.move(10, 10); await page.waitForTimeout(100);
          s9 = await state();
        }
        hl.click = !px ? 'FAIL no band point off the window stripes' + (zoomed ? ' (not even zoomed in)' : ' (zoom failed)')
          : (s8.c.n === 1 && s8.c.onAxis && !s9.c.fd) ? 'ok' + (zoomed ? ' (zoomed in: the window stripes tile the span)' : '')
          : 'FAIL ' + JSON.stringify([s8.c, s9.c.fd]) + (zoomed ? ' (zoomed in)' : '');
        if (!/^ok/.test(hl.click)) fail('activity: click-to-keep highlight ' + hl.click);
        if (zoomed && /demo_busy_db(_quiet|_dashboard)?\.html$/.test(file)) fail('activity: the demo must leave a band point off the window stripes without zooming');
        if (zoomed) { await page.click('#ax-reset'); await page.waitForTimeout(150); }
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
      // direct labels (plan 036): each one inside one panel (1 px slack)
      // and inside the band it names; the demo labels both charts
      await page.evaluate(LABEL_BAND);
      sb.labels = await page.evaluate(() => {
        let n = 0, bad = 0, off = 0; const per = [];
        for (const [id, key] of [['ax-cls', 'ashx'], ['ax-ev', 'ashe']]) {
          const s = document.querySelector('#' + id + ' .axsvg'); if (!s || !s.getClientRects().length) continue;
          off += window.__awrLabelBand(id, key);
          const P = [...s.querySelectorAll('rect.xw.xpn')].map(r => r.getBoundingClientRect()), L = s.querySelectorAll('text.xdl');
          per.push(L.length);
          for (const t of L) { n++; const b = t.getBoundingClientRect(); if (!P.some(p => b.left >= p.left - 1 && b.right <= p.right + 1)) bad++; }
        }
        return n + ' labels (' + per.join('/') + ')' + (bad ? ' FAIL ' + bad + ' cross a panel edge' : '') + (off ? ' FAIL ' + off + ' outside their band' : '');
      });
      if (/FAIL/.test(sb.labels)) fail('side by side: labels ' + sb.labels);
      if (isDemo && !/\(([1-6])\/([1-6])\)/.test(sb.labels)) fail('side by side: the demo must label at least one band on each chart: ' + sb.labels);
      // the flag band (G3): the flags chart reserves it only while a flag is
      // drawn (markers all cropped away: no empty band)
      sb.flagBand = await page.evaluate(() => {
        const s = [...document.querySelectorAll('.ashx .axsvg')].find(x => x.getClientRects().length); if (!s) return 'none';
        const y = +s.querySelector('rect.xw.xpn').getAttribute('y'), f = s.querySelectorAll('text.cft').length;
        return (y > 22) === (f > 0) ? 'ok (' + f + ' flags, top ' + y + ')' : 'FAIL ' + f + ' flags, top ' + y;
      });
      if (/^FAIL/.test(sb.flagBand)) fail('side by side: flag band ' + sb.flagBand);
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
      // a marker is drawn side by side only in the gap before a SHOWN panel
      // (G3): -1 = no marker in the span, -2 = every marker's panel cropped
      sb.markers = await page.evaluate(() => {
        const ms = window.AWR_WG && AWR_WG.markers ? AWR_WG.markers() : [];
        if (!ms.length) return -1;
        const shown = new Set([...document.querySelectorAll('#ax-cls .axsvg .xwh')].map(h => h.getAttribute('data-w')));
        if (!ms.some(m => shown.has(String(m.o)))) return -2;
        return document.querySelectorAll('#ax-cls .axsvg .cfl').length;
      });
      if (sb.markers === 0) fail('side by side: release markers missing');
      // keyboard (G3): Enter on a focused cap pins and the focus stays on
      // that cap through the redraw; Esc unpins, the focus stays (last: the
      // pin scrolls the page smoothly to the Timeline grid)
      sb.keys = await (async () => {
        const di = await page.evaluate(() => { const h = [...document.querySelectorAll('#ax-cls .axsvg .xwh')].find(x => x.getAttribute('data-w') !== '0'); if (!h) return null; h.focus(); return { i: h.getAttribute('data-i'), w: h.getAttribute('data-w') }; });
        if (!di) return 'none';
        const kept = () => page.evaluate((i) => { const a = document.activeElement; return !!a && a.getAttribute('class') === 'xwh' && a.getAttribute('data-i') === i && !!a.closest('#ax-cls'); }, di.i);
        await page.keyboard.press('Enter'); await page.waitForTimeout(150);
        const p1 = await page.evaluate((w) => document.body.getAttribute('data-pw') === w, di.w), f1 = await kept();
        await page.keyboard.press('Escape'); await page.waitForTimeout(150);
        const p2 = await page.evaluate(() => !document.body.hasAttribute('data-pw')), f2 = await kept();
        return p1 && f1 && p2 && f2 ? 'ok' : 'FAIL ' + JSON.stringify({ pinned: p1, focus: f1, unpinned: p2, focus2: f2 });
      })();
      if (/^FAIL/.test(sb.keys)) fail('side by side: keyboard pin / focus ' + sb.keys);
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

  // ---- 5d. markers sharing a gap (G3): two extra markers are injected one
  // and two minutes after the report's first one (so three share one gap
  // side by side, and one spot in Full span); in both layouts every marker
  // is named on the flags chart (a flag of its own, or the tooltip of a
  // "+n" flag, or a line's tooltip), no two flags overlap, and on the demo
  // the gap carries a "+n" flag. Before G3 the third lost its flag.
  {
    const page = await browser.newPage({ viewport: { width: 1440, height: 1000 }, colorScheme: 'light' });
    const errors = [];
    page.on('pageerror', e => errors.push('pageerror: ' + e.message));
    page.on('console', m => { if (m.type() === 'error') errors.push('console.error: ' + m.text()); });
    await page.addInitScript(() => {
      const a = []; let added = false;
      a.push = function (...ms) {
        for (const m of ms) {
          Array.prototype.push.call(this, m);
          if (!added && m && /^\d{4}-\d\d-\d\d \d\d:\d\d$/.test(String(m.t))) {
            added = true;
            const d = Date.parse(m.t.replace(' ', 'T') + ':00Z'), f = k => new Date(d + k * 60000).toISOString().slice(0, 16).replace('T', ' ');
            Array.prototype.push.call(this, { t: f(1), label: 'Extra marker A' }, { t: f(2), label: 'Extra marker B' });
          }
        }
        return this.length;
      };
      window.AWR_MARKERS = a;
    });
    await page.goto('file://' + file + '#view=timeline', { waitUntil: 'load' }); await page.waitForTimeout(1200);
    const isDemo = /demo_busy_db(_quiet|_dashboard)?\.html$/.test(file), mg = {};
    if (DESIGN === 'dashboard') { await page.evaluate(() => window.AWR_axMode && window.AWR_axMode('both')); await page.waitForTimeout(250); }
    const named = (mode) => page.evaluate((mode) => {
      const all = (window.AWR_WG && AWR_WG.markers ? AWR_WG.markers() : []);
      if (!all.some(m => m.l === 'Extra marker B')) return 'skipped';
      const s = [...document.querySelectorAll('.ashx .axsvg')].find(x => x.getClientRects().length); if (!s) return 'none';
      // side by side names only the markers in the gap before a shown panel
      const shown = new Set([...s.querySelectorAll('.xwh')].map(h => h.getAttribute('data-w')));
      const ms = mode === 'win' ? all.filter(m => shown.has(String(m.o))) : all;
      const crop = ms.length < all.length ? (all.length - ms.length) + ' cropped, ' : '';
      const txt = [...s.querySelectorAll('text.cft')].map(t => t.textContent).join('\n') + '\n' + [...s.querySelectorAll('title')].map(t => t.textContent).join('\n');
      const miss = ms.filter(m => txt.indexOf(m.l) < 0).map(m => m.l);
      const R = [...s.querySelectorAll('rect.cfh')].map(r => r.getBoundingClientRect());
      let ov = 0; for (let i = 0; i < R.length; i++) for (let j = i + 1; j < R.length; j++) if (R[i].left < R[j].right && R[j].left < R[i].right && R[i].top < R[j].bottom && R[j].top < R[i].bottom) ov++;
      const plus = [...s.querySelectorAll('text.cft')].filter(t => / \+\d+$/.test(t.lastChild ? t.lastChild.textContent : '')).length;
      // every flag inside the SVG (R3: a long label flipped left of a marker
      // near the left edge sat mostly outside it)
      const sb = s.getBoundingClientRect(), out = R.filter(r => r.left < sb.left - 0.5 || r.right > sb.right + 0.5).length;
      return (miss.length || ov || out ? 'FAIL missing ' + JSON.stringify(miss) + ' overlap ' + ov + ' outside the SVG ' + out : 'ok') + ' (' + crop + ms.length + ' markers, ' + R.length + ' flags, ' + plus + ' +n)';
    }, mode);
    for (const m of ['win', 'span']) {
      const can = await page.evaluate((m) => { if (!window.AWR_TL || !AWR_TL.axLayout) return false; if (m === 'win' && !document.querySelector('#activity .axlayout:not([hidden])')) return false; AWR_TL.axLayout(m, false); return true; }, m);
      if (!can) { mg[m] = 'unavailable'; continue; }
      await page.waitForTimeout(250);
      mg[m] = await named(m);
      if (/^FAIL/.test(mg[m])) fail('markers sharing a gap (' + m + '): ' + mg[m]);
      if (isDemo && !/ [1-9]\d* \+n\)$/.test(mg[m])) fail('markers sharing a gap (' + m + '): the demo must show a "+n" flag: ' + mg[m]);
    }
    await page.evaluate(() => { try { localStorage.removeItem('awr-axlayout'); } catch (e) {} });
    console.log('markers sharing a gap', JSON.stringify(mg));
    if (errors.length) fail('markers sharing a gap: ' + errors.slice(0, 5).join(' | '));
    await page.close();
  }

  // ---- 5e. the Activity charts at phone width (review follow-up R3): under
  // 480 px the SVG keeps its 480-px viewBox, scaled down and centred
  // vertically (preserveAspectRatio), so the pointer maps through the
  // SVG's screen CTM.  At points well inside one band (the topmost fill
  // there and 3 px above / below, 1 px aside, under no window stripe's hit area) a hover
  // must light exactly that band in the legend (the soft highlight follows
  // the band as drawn), in both charts and both layouts; a brush in Full
  // span covers the plot's height.  Before R3 the 390-px hover lit nothing
  // or the wrong band (clientY scaled without the letterbox).
  {
    const page = await browser.newPage({ viewport: { width: 390, height: 844 }, colorScheme: 'light' });
    const errors = [];
    page.on('pageerror', e => errors.push('pageerror: ' + e.message));
    page.on('console', m => { if (m.type() === 'error') errors.push('console.error: ' + m.text()); });
    await page.goto('file://' + file + '#view=timeline', { waitUntil: 'load' }); await page.waitForTimeout(1200);
    if (DESIGN === 'dashboard') { await page.evaluate(() => window.AWR_axMode && window.AWR_axMode('both')); await page.waitForTimeout(250); }
    const isDemo = /demo_busy_db(_quiet|_dashboard)?\.html$/.test(file), nw = {};
    // integer client points (mouse events carry whole pixels)
    const pts = (id) => page.evaluate((id) => {
      const s = document.querySelector('#' + id + ' .axsvg'); if (!s || !s.getClientRects().length || !s.getScreenCTM) return null;
      s.scrollIntoView({ block: 'center' });
      const r = s.getBoundingClientRect(), m = s.getScreenCTM(), cp = s.querySelector('clipPath rect');
      if (!m || !cp) return null;
      const yt = m.d * (+cp.getAttribute('y') + 6) + m.f, yb = m.d * (+cp.getAttribute('y') + +cp.getAttribute('height')) + m.f;
      const band = (x, y) => { const es = document.elementsFromPoint(x, y), i = es.findIndex(q => !q.matches('rect.xw, rect.xwc, text.xdl, line.xch, rect.xbk')); return i >= 0 && es[i].matches('path.xa') ? es[i] : null; };
      const out = [], per = {};
      for (let fy = 0.1; fy < 0.97 && out.length < 10; fy += 0.06) {
        for (let fx = 0.12; fx < 0.97 && out.length < 10; fx += 0.03) {
          const x = Math.round(r.left + r.width * fx), y = Math.round(yt + (yb - yt) * fy), a = band(x, y);
          if (!a || [[0, -3], [0, 3], [-1, 0], [1, 0]].some(d => band(x + d[0], y + d[1]) !== a)) continue;
          const f = a.getAttribute('fill'); if ((per[f] = (per[f] || 0) + 1) > 2) continue;
          out.push({ x, y, f });
        }
      }
      return { scale: m.a, off: m.f - r.top, out };
    }, id);
    const lit = (id) => page.evaluate((id) => [...document.querySelectorAll('#' + id + ' .axlg .axc.hl .sw')].map(s => s.style.getPropertyValue('--sw').trim()), id);
    for (const mode of ['span', 'win']) {
      const can = await page.evaluate((m) => { if (!window.AWR_TL || !AWR_TL.axLayout) return false; if (m === 'win' && !document.querySelector('#activity .axlayout:not([hidden])')) return false; AWR_TL.axLayout(m, false); return true; }, mode);
      if (!can) { nw[mode] = 'unavailable'; continue; }
      await page.waitForTimeout(250);
      for (const id of ['ax-cls', 'ax-ev']) {
        await pts(id); await page.waitForTimeout(150);
        const P = await pts(id);
        if (!P) { nw[mode + ' ' + id] = 'not shown'; continue; }
        let good = 0; const bad = [];
        for (const q of P.out) {
          await page.mouse.move(q.x, q.y); await page.waitForTimeout(100);
          const l = await lit(id);
          if (l.length === 1 && l[0] === q.f) good++; else bad.push(q.f + ' lit ' + (l.join(',') || 'nothing'));
          await page.mouse.move(2, 2); await page.waitForTimeout(50);
        }
        nw[mode + ' ' + id] = (bad.length ? 'FAIL ' + bad.slice(0, 3).join('; ') + ' ' : '') + good + '/' + P.out.length + ' points (scale ' + P.scale.toFixed(2) + ', offset ' + P.off.toFixed(1) + ' px)';
        if (bad.length) fail('Activity at 390 px (' + mode + ', ' + id + '): a hover lit another band: ' + nw[mode + ' ' + id]);
        if (isDemo && !P.out.length) fail('Activity at 390 px (' + mode + ', ' + id + '): no band point found on the demo');
      }
    }
    // the brush (Full span) covers the plot's height, letterbox included
    if (nw.span !== 'unavailable') {
      await page.evaluate(() => AWR_TL.axLayout('span', false)); await page.waitForTimeout(250);
      const g = await page.evaluate(() => { const s = document.querySelector('#ax-cls .axsvg'); if (!s || !s.getClientRects().length) return null; s.scrollIntoView({ block: 'center' });
        const r = s.getBoundingClientRect(), m = s.getScreenCTM(), cp = s.querySelector('clipPath rect');
        return { x: Math.round(r.left + r.width * 0.4), y: Math.round(r.top + r.height / 2), t: m.d * (+cp.getAttribute('y') + 6) + m.f, b: m.d * (+cp.getAttribute('y') + +cp.getAttribute('height')) + m.f }; });
      if (g) {
        await page.mouse.move(g.x, g.y); await page.mouse.down(); await page.mouse.move(g.x + 40, g.y, { steps: 5 });
        const br = await page.evaluate(() => { const b = document.querySelector('#ax-cls .axbr'); if (!b || b.hidden) return null; const r = b.getBoundingClientRect(); return { t: r.top, b: r.bottom }; });
        await page.mouse.up(); await page.waitForTimeout(200);
        await page.evaluate(() => { const b = document.getElementById('ax-reset'); if (b && !b.hidden) b.click(); }); await page.waitForTimeout(150);
        nw.brush = !br ? 'FAIL no brush' : (Math.abs(br.t - g.t) <= 1 && Math.abs(br.b - g.b) <= 1) ? 'ok' : 'FAIL brush ' + br.t.toFixed(1) + '..' + br.b.toFixed(1) + ', plot ' + g.t.toFixed(1) + '..' + g.b.toFixed(1);
        if (/^FAIL/.test(nw.brush)) fail('Activity at 390 px: ' + nw.brush);
      }
    }
    await page.evaluate(() => { try { localStorage.removeItem('awr-axlayout'); } catch (e) {} });
    console.log('activity at 390 px', JSON.stringify(nw));
    if (errors.length) fail('activity at 390 px: ' + errors.slice(0, 5).join(' | '));
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
        // the sort key, computed here, not by the report's changeKey:
        // Current minus the prior mean in an AAS lane, else |z| (sigma
        // floored at 2% of the mean).  An empty data-mu / data-sd is "no
        // prior mean", not 0: in an AAS lane such a row (new in Current)
        // ranks by Current minus the mean of its VALID prior windows, a
        // missing value there counting 0 and a skipped window left out
        // (owner decision 2026-11-20); no valid prior window or a z lane:
        // null, sorted last.
        const num1 = s => (s == null || s === '') ? null : +s;
        const valid = ((window.AWR_WIN || {}).w || []).map(w => w.v !== 'N');
        const key = r => {
          const v = nums(r.getAttribute('data-v')), n = v.length, c = n ? v[n - 1] : null;
          const mu = num1(r.getAttribute('data-mu')), sd = num1(r.getAttribute('data-sd'));
          if (c == null) return null;
          if (mu == null) {
            if (!aas || valid.length !== n) return null;
            const p = []; for (let i = 0; i < n - 1; i++) if (valid[i]) p.push(v[i] == null ? 0 : v[i]);
            return p.length ? c - p.reduce((s, x) => s + x, 0) / p.length : null;
          }
          if (aas) return c - mu;
          const den = Math.max(sd || 0, 0.02 * Math.abs(mu));
          return den > 0 ? Math.abs((c - mu) / den) : null;
        };
        const k = ev.map(key);
        const k2 = ev.map(r => window.AWR_WG.changeKey(nums(r.getAttribute('data-v')), num1(r.getAttribute('data-mu')), num1(r.getAttribute('data-sd')), aas, valid));
        const same = (a, b) => (a == null && b == null) || (a != null && b != null && Math.abs(a - b) <= 1e-9 * Math.max(1, Math.abs(a)));
        const n0 = k.findIndex(x => x == null), known = n0 < 0 ? k : k.slice(0, n0);
        out.sorted = !k.every((x, i) => same(x, k2[i])) ? 'FAIL key: page ' + JSON.stringify(k2) + ' vs ' + JSON.stringify(k)
          : known.every((x, i) => i === 0 || known[i - 1] >= x) && (n0 < 0 || k.slice(n0).every(x => x == null)) ? 'ok'
          : 'FAIL ' + JSON.stringify(k);
        out.newRows = ev.filter(r => num1(r.getAttribute('data-mu')) == null && key(r) != null).map(r => r.id);
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
    const p4 = await page.evaluate(async (HQ) => {
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
      // plan 037: scatter marks <= 12 px, x-axis = the compared span.
      // R3: its times are the DB's wall clock read as UTC (useUTC on), so
      // the bounds are the same instant in any browser zone; an older
      // report (useUTC off) parsed them as local time
      {
        const sc = window.echarts && document.getElementById('sqlmon-scatter');
        const si = sc && echarts.getInstanceByDom(sc);
        if (si) {
          const o = si.getOption(), s0 = o.series[0], d = window.AWR_DATA.sqlmon;
          const big = typeof s0.symbolSize === 'function' ? s0.symbolSize(null, { data: { dop: 64 } }) : s0.symbolSize;
          const z = o.useUTC === true, ts = s => Date.parse(String(s).replace(' ', 'T') + (z ? 'Z' : ''));
          out.scatter = (big <= 12 && o.xAxis[0].min === ts(d.spanStart) && o.xAxis[0].max === ts(d.spanEnd))
            ? 'ok' + (z ? '' : ' (local time: an older report)') : 'FAIL size=' + big + ' x=' + o.xAxis[0].min + '..' + o.xAxis[0].max + (z ? ' (UTC)' : ' (local)');
        } else out.scatter = sc ? 'FAIL no ECharts instance on #sqlmon-scatter' : 'skipped';
      }
      // plan 034: Copy summary builds Markdown from the verdict and the cards
      const sbtn = document.getElementById('sum-btn');
      if (sbtn && !sbtn.hidden) {
        sbtn.click(); await wait(150);
        const ta = document.querySelector('#sum-pop textarea');
        const md = ta ? ta.value : '';
        const h1 = (document.querySelector('#verdict h1') || {}).textContent || '';
        const nCards = document.querySelectorAll('#findings article.fc:not(.chg)').length;
        const nLines = (md.match(/^\d+\. \[/gm) || []).length;
        out.sumOk = md.indexOf(h1.replace(/\s+/g, ' ').trim()) >= 0 && nLines === nCards && !/undefined|null|NaN/.test(md);
        document.querySelector('#sum-pop .sum-x').click(); await wait(60);
        out.sumClosed = document.getElementById('sum-pop').hidden;
        // plan 034 review: Escape on the close button closes the popover,
        // gives focus back to the button and keeps a pinned window
        const pw = ((window.AWR_WIN && AWR_WIN.w) || []).filter(w => w.o !== 0 && w.v === 'Y').map(w => String(w.o))[0];
        if (pw !== undefined && window.AWR_WG && AWR_WG.pin) AWR_WG.pin(+pw);
        sbtn.click(); await wait(150);
        const sx = document.querySelector('#sum-pop .sum-x'); sx.focus();
        sx.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true })); await wait(60);
        out.sumEsc = document.getElementById('sum-pop').hidden && document.activeElement === sbtn
          && !document.getElementById('topbar').classList.contains('sum-open')
          && (pw === undefined || document.body.getAttribute('data-pw') === pw);
        if (pw !== undefined) AWR_WG.pin(null);
        // ... and nothing paints over it in the Timeline view (the sticky ruler did)
        if (window.AWR_setView && document.getElementById('tl')) {
          AWR_setView('timeline', false); await wait(300);
          const tl = document.getElementById('tl');
          window.scrollTo(0, tl.getBoundingClientRect().top + window.scrollY + 300); await wait(200);
          sbtn.click(); await wait(150);
          const pop = document.getElementById('sum-pop');
          out.sumOnTop = [pop.querySelector('.sum-x'), pop.querySelector('textarea')].every(el => {
            const r = el.getBoundingClientRect(), h = document.elementFromPoint(r.left + r.width / 2, r.top + Math.min(8, r.height / 2));
            return !!h && pop.contains(h);
          });
          pop.querySelector('.sum-x').click(); await wait(60);
          AWR_setView('summary', false); window.scrollTo(0, 0); await wait(300);
        } else out.sumOnTop = true;
      } else out.sumOk = out.sumClosed = out.sumEsc = out.sumOnTop = false;
      // plan 030: durations on the plan card, AAS on Timeline event rows
      out.durOk = [...document.querySelectorAll('article.fc[id^="f-plan-"] .big .v')]
        .every(v => /^-?\d+(\.\d)? (ms|s|m|h|d)( \d+ (s|m|h))?$/.test(v.textContent.trim()));
      out.aasOk = [...document.querySelectorAll('[id^="tl-we-"]')].every(r => r.getAttribute('data-unit') === 'AAS');
      // dbmint follow-up: an event row never reads above its own wait-class
      // row in any window -- both are AAS over that window's real snapshot
      // span, and the class sums its events (same view, same wait list)
      {
        const slug = s => String(s).toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '');
        const nv = s => String(s || '').split(',').map(x => x === '' ? null : +x);
        out.evOverClass = [...document.querySelectorAll('[id^="tl-we-"]')].filter(r => {
          const sw = r.querySelector('.sw[data-wc]');
          const cr = sw && document.getElementById('tl-fr-w-wait-class-' + slug(sw.getAttribute('data-wc')));
          if (!cr) return false;
          const a = nv(r.getAttribute('data-v')), b = nv(cr.getAttribute('data-v'));
          return a.some((x, i) => x != null && b[i] != null && x > b[i] * (1 + 1e-5) + 1e-6);
        }).map(r => r.id);
        out.evClassPairs = [...document.querySelectorAll('[id^="tl-we-"] .sw[data-wc]')]
          .filter(sw => document.getElementById('tl-fr-w-wait-class-' + slug(sw.getAttribute('data-wc')))).length;
      }
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
      // no finding card -> 07 emits no list at all; the strip draws at any
      // window count (data-spark-dense: one silhouette past about 45 windows)
      out.triage = trows.length + '/' + cards.length + (dash ? ' (dashboard)' : '');
      out.triageOk = trows.length === cards.length
        && trows.every((r, i) => r.getAttribute('data-card') === cards[i].id
          && (dash || (r.querySelector('.tri-spark svg.mw') && r.querySelector('.tri-imp').textContent.trim() !== '')))
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
      // G4: it is folded exactly when the card it explains is (dashboard: open, no toggle)
      // review follow-up R2: a card that explains cites, through a link to
      // it, exactly the transition it shows (data-ph0 / data-ph1 = the
      // plan line's title); and no finding card links a plan card while
      // citing another transition (17 unwraps such a link)
      const phOf = p => [p.getAttribute('data-ph0'), p.getAttribute('data-ph1')];
      const cited = a => { const m = /new plan (\d+)\D+?(\d+)/.exec(a.textContent); return m ? [m[1], m[2]] : null; };
      out.explainsPh = ex.filter(p => {
        const c = document.getElementById(p.getAttribute('data-explains')), ph = phOf(p);
        const wl = p.querySelector('.whereln'), sh = wl ? /plan (\d+)\D+?(\d+)/.exec(wl.getAttribute('title') || '') : null;
        const ls = c ? [...c.querySelectorAll('a.ent[href="#' + p.id + '"]')] : [];
        return !ph[0] || !ph[1] || !sh || sh[1] !== ph[0] || sh[2] !== ph[1] || !ls.length
          || ls.some(a => { const q = cited(a); return !q || q[0] !== ph[0] || q[1] !== ph[1]; });
      }).map(p => p.id);
      out.planLinkPh = [...document.querySelectorAll('article.fc:not(.chg) a.ent[href^="#f-plan-"]')].filter(a => {
        const t = document.getElementById(a.getAttribute('href').slice(1)), q = cited(a);
        return t && q && (q[0] !== t.getAttribute('data-ph0') || q[1] !== t.getAttribute('data-ph1'));
      }).map(a => a.closest('article.fc').id + '->' + a.getAttribute('href'));
      out.explainsFold = ex.every(p => { const c = document.getElementById(p.getAttribute('data-explains'));
        return dashX ? !p.classList.contains('fold') && !p.querySelector('.fc-tg') : !!c && c.classList.contains('fold') === p.classList.contains('fold'); });
      const sl = document.getElementById('changes-slot'), sc = document.getElementById('s-changes');
      out.changesOk = !sl || !sc || (sl.children.length > 0) === !sc.hidden;
      // v1.7: cards ordered by impact; chip; Summary z capped at 10
      // (#findings article.fc:not(.chg): the dashboard moves the cards into
      // its findings table, and the plan / config cards carry .chg)
      const fc = [...document.querySelectorAll('#findings article.fc:not(.chg)')];
      // tier 1 = a rise of at least 0.01 AAS (owner decision 2026-11-20):
      // those cards lead (DB time aside), largest first; a smaller rise,
      // none or a fall follows with the cards without a time measure (the
      // floor reads the impact rounded like its 3-decimal token, imp_on)
      const imp = fc.filter(c => c.id !== 'f-dbtime').map(c => {
        const a = c.getAttribute('data-impact');
        return a === null || a === '' ? null : parseFloat(a);
      });
      const t1 = v => v !== null && v >= 0.01;
      const nt1 = imp.findIndex(v => !t1(v));
      const imp1 = imp.filter(t1);
      out.impOrder = imp.every((v, i) => !t1(v) || nt1 < 0 || i < nt1)
        && imp1.every((v, i) => i === 0 || imp1[i - 1] >= v);
      out.impAttrs = fc.every(c => c.hasAttribute('data-impact') && c.hasAttribute('data-share'));
      // a chip exactly when the card added 0.01 AAS or more (owner decision
      // 2026-11-21: a smaller rise shows no chip and no share)
      out.impChips = fc.every(c => { const v = parseFloat(c.getAttribute('data-impact')), ch = c.querySelector('.fc-k .fc-imp');
        return v >= 0.01 ? !!ch : !ch && (c.getAttribute('data-share') || '') === ''; });
      // plan 039: every finding card says its n (the lead row's number of prior
      // windows, read from the same row in the Findings tables) as data-n on
      // .nrm and .fc-sum, with the two rates for that n in the .nrm title;
      // the qualifier is generated content, so no text read of the card
      // ("normal ..." in Copy summary, the dashboard) carries it; the verdict
      // note li.hn-conf is there exactly when the report has 3 to 5 valid
      // prior windows, with the rates of that n (the known values below come
      // from tools/gen_baseline_conf.py, an independent integration)
      const CONF = { 3: [22.54, 12.17], 4: [17.16, 7.48], 5: [14.19, 5.20], 6: [12.33, 3.90], 8: [10.13, 2.55],
                     12: [8.09, 1.49], 26: [6.09, 0.69], 52: [5.30, 0.45] };
      const near = (got, want) => Math.abs(got - want) <= (want >= 10 ? 0.5 : want >= 1 ? 0.051 : 0.0051);
      const nOfRow = id => {
        const tr = document.getElementById(id); if (!tr || tr.tagName !== 'TR') return null;
        const tb = tr.closest('table'); if (!tb) return null;
        const hs = [...tb.querySelectorAll('thead th')].map(h => h.textContent.trim());
        const ix = hs.indexOf('n'); if (ix < 0) return null;
        const v = parseInt((tr.children[ix] || {}).textContent, 10); return isNaN(v) ? null : v;
      };
      out.confCards = fc.map(c => {
        const nrm = c.querySelector('.big .nrm'), sum = c.querySelector('.fc-k .fc-sum');
        if (!nrm) return null; // the dashboard hides nothing: the element stays in the DOM
        const bad = [], n = parseInt(nrm.getAttribute('data-n'), 10);
        if (!(n >= 3)) bad.push('no data-n');
        if (!sum || parseInt(sum.getAttribute('data-n'), 10) !== n) bad.push('fc-sum n differs');
        if (/\bn\s*=\s*\d/.test(nrm.textContent) || (sum && /\bn\s*=\s*\d/.test(sum.textContent))) bad.push('n leaked into the text');
        const t = nrm.getAttribute('title') || '', m = t.match(/Scored against (\d+) prior windows.*about ([0-9.]+)% of the time \(1 in (\d+)\).*about ([0-9.]+)% \(1 in (\d+)\)/);
        if (!m) bad.push('title lacks the two rates');
        else {
          if (+m[1] !== n) bad.push('title n ' + m[1]);
          if (CONF[n] && (!near(+m[2], CONF[n][0]) || !near(+m[4], CONF[n][1]))) bad.push('rates ' + m[2] + '/' + m[4] + ' for n ' + n);
          // "1 in k" is the exact quotient rounded once; the printed percent is itself rounded
          const tk = pp => 0.51 + 100 * (pp >= 10 ? 0.5 : pp >= 1 ? 0.051 : 0.0051) / (pp * pp) + (100 / pp >= 100 ? 0.05 * 100 / pp : 0);
          if (Math.abs(+m[3] - 100 / +m[2]) > tk(+m[2]) || Math.abs(+m[5] - 100 / +m[4]) > tk(+m[4])) bad.push('1 in k');
        }
        const a = c.querySelector('h3 a.ent'), rn = a ? nOfRow((a.getAttribute('href') || '').slice(1)) : null;
        if (rn !== null && rn !== n) bad.push('row n ' + rn + ' vs ' + n);
        return bad.length ? c.id + ': ' + bad.join(', ') : 'ok';
      }).filter(x => x !== null);
      const nv = (window.AWR_WIN ? window.AWR_WIN.w : []).filter(x => x.o > 0 && x.v === 'Y').length;
      const cn = document.querySelector('#narrative-slot li.hn-conf'), hero = document.getElementById('verdict');
      const usable = !!hero && !/Too little history/.test(hero.textContent);
      out.confNote = (() => {
        const want = usable && nv >= 3 && nv <= 5;
        if (!want) return cn ? 'FAIL a note with ' + nv + ' valid prior windows' : 'ok (none for ' + nv + ')';
        if (!cn) return 'FAIL no note for ' + nv + ' valid prior windows';
        const t = cn.textContent, bad = [], ns = cn.parentNode;
        if (+cn.getAttribute('data-n') !== nv) bad.push('data-n');
        if (t.indexOf(nv + ' prior windows') < 0) bad.push('text lacks n');
        const k1 = Math.round(100 / CONF[nv][0]), k2 = Math.round(100 / CONF[nv][1]);
        if (t.indexOf('about 1 time in ' + k1 + ' ') < 0 || t.indexOf('about 1 in ' + k2 + ' ') < 0) bad.push('rates (want 1 in ' + k1 + ' / 1 in ' + k2 + ')');
        if (ns.id !== 'narrative-slot' || ns.hidden) bad.push('slot hidden');
        const lis = [...ns.children], bi = lis.indexOf(cn), bn = lis.findIndex(x => x.classList.contains('hn-base'));
        if (bn >= 0 && bi > bn) bad.push('after the baseline check');
        if (lis.some((x, i) => i > bi && !x.classList.contains('hn-base'))) bad.push('not after the other notes');
        const a = cn.querySelector('a.go');
        if (!a || a.getAttribute('href') !== '#about' || !document.getElementById('about')) bad.push('link');
        return bad.length ? 'FAIL ' + bad.join('; ') : 'ok (n = ' + nv + ')';
      })();
      // R4: a flagged card whose time measure rose less than 0.01 AAS (a
      // background-only wait class: scored on all sessions, its foreground
      // time flat) has no chip and no share, sits after every tier-1 card,
      // reads "under 0.01 AAS" in the triage list and is no breakdown part
      // (required on the demo: its Queueing waits card, impact 0). A part
      // needs the same 0.01 AAS floor (imp_on), so such a card is at most
      // inside "+ n smaller".
      const last1 = fc.reduce((m, c, i) => (c.id !== 'f-dbtime' && t1(parseFloat(c.getAttribute('data-impact')))) ? i : m, -1);
      const triL = document.getElementById('triage');
      out.lowImp = fc.filter(c => c.id !== 'f-dbtime' && /\bf-(large|moderate)\b/.test(c.className)
          && (c.getAttribute('data-impact') || '') !== '' && Math.abs(parseFloat(c.getAttribute('data-impact'))) < 0.01)
        .map(c => {
          const bad = [], tr = document.querySelector('#triage .tri-row[data-card="' + c.id + '"] .tri-imp');
          if (c.querySelector('.fc-k .fc-imp')) bad.push('chip');
          if ((c.getAttribute('data-share') || '') !== '') bad.push('share');
          if (fc.indexOf(c) < last1) bad.push('before a tier-1 card');
          if (triL && !tr) bad.push('no triage row');
          if (tr && !/^under 0\.01 AAS$/.test(tr.textContent.trim())) bad.push('triage "' + tr.textContent.trim() + '"');
          const ap = document.querySelector('#att-slot a[href="#' + c.id + '"]'), apv = ap && ap.parentNode.querySelector('b');
          if (ap) bad.push('a breakdown part');
          return c.id + (bad.length ? ' FAIL ' + bad.join(', ') : '');
        });
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
      // plan 033: rule-based hints; a next-step query is a copyable SELECT.
      // Review follow-up R2: a rule with a query in finding_hints.plsql
      // (HQ) shows it, a rule without one shows none; a query has no
      // placeholder left and is one or more read-only "SELECT ... ;"
      // statements (string literals left out of the keyword test: the
      // ROW_LOCK query names "row lock contention")
      const roSql = t => {
        const u = t.replace(/'(?:[^']|'')*'/g, "''"), st = u.split(';').map(x => x.trim());
        return st.length > 1 && st.pop() === '' && st.every(x => /^SELECT\s/i.test(x))
          && !/\b(INSERT|UPDATE|DELETE|MERGE|UPSERT|ALTER|CREATE|DROP|GRANT|REVOKE|TRUNCATE|RENAME|COMMENT|BEGIN|DECLARE|EXEC|EXECUTE|CALL|COMMIT|ROLLBACK|LOCK)\b/i.test(u);
      };
      const hints = [...document.querySelectorAll('article.fc .fc-hint[data-hint]')];
      out.hints = hints.map(x => x.closest('article.fc').id + ':' + x.getAttribute('data-hint')).join(',');
      out.hintBad = hints.filter(x => {
        const pre = x.querySelector('pre.sql'), btn = x.querySelector('.copy-btn[data-copy]'), r = x.getAttribute('data-hint');
        if (!x.querySelector('p b')) return true;
        if (HQ && (HQ.indexOf(r) >= 0) !== !!pre) return true;
        return !!pre && !(btn && document.querySelector(btn.getAttribute('data-copy')) === pre
          && !/#[A-Z0-9]+#/.test(pre.textContent) && roSql(pre.textContent));
      }).map(x => x.closest('article.fc').id + ':' + x.getAttribute('data-hint'));
      out.hintsOk = out.hintBad.length === 0;
      out.hintRules = HQ ? HQ.length : 'n/a';
      // the plan card keeps section 23's "Plan shape" link in its footer
      out.hintPfl = [...document.querySelectorAll('article.fc.chg[id^="f-plan-"]')].every(c => c.querySelector('.fc-f .evl a[href="#topsql"]'));
      // dashboard design: the plan card's query never widens the side column
      const side = document.querySelector('aside.dside');
      out.hintSide = side ? side.scrollWidth <= side.clientWidth + 1 : true;
      // All sections: every library section shows in full, row state or not:
      // its first chart or table that holds a number (a table without a data
      // row holds none: section 28's split table stays empty, hidden with
      // the rest of the split view, until a release marker or a boundary
      // gives a split; its Current-vs-all-priors table shows every number)
      window.AWR_setView('all', false); await wait(250);
      const hasNum = t => !t.matches('table') || [...t.rows].some(r => r.querySelector('td'));
      out.allFull = libs.filter(x => { const t = [...x.querySelectorAll('table, .chart-wrap')].find(hasNum); return t && !vis(t); }).map(x => x.id);
      // section 28 with no usable split (no release marker): the reason note
      // shows instead of the split view, and the all-priors table is there
      {
        const rd = document.getElementById('release-delta'), app = rd && rd.querySelector('.rd-app');
        const why = app && app.querySelector('.rd-why'), tall = rd && rd.querySelector('table.rd-tall');
        // (the section emits .rd-app only with a payload and 3+ valid
        // windows, where the script always shows it: still hidden = it bailed)
        out.rdSplit = !app ? 'none' : !vis(app) ? 'FAIL: the split view never showed (script bailed out)'
          : vis(app.querySelector('.rd-body')) ? 'split'
          : (vis(why) && why.textContent.trim() && tall && vis(tall) && hasNum(tall)) ? 'no split (reason note, all-priors table)'
          : 'FAIL: no split shown, but no reason note or no all-priors table';
      }
      // plan 035: section 11's charts are drawn on demand
      const a11 = [...document.querySelectorAll('#topsql-ash .chart-ash-sql')];
      if (window.echarts && a11.length > 2) {
        window.scrollTo(0, 0); await wait(300);
        const last = a11[a11.length - 1];
        if (last.getBoundingClientRect().top > innerHeight + 700) {
          const before = echarts.getInstanceByDom(last) ? 1 : 0;
          last.scrollIntoView({ block: 'center' }); await wait(500);
          const after = echarts.getInstanceByDom(last) ? 1 : 0;
          out.lazy11 = (before === 0 && after === 1) ? 'ok' : 'FAIL before=' + before + ' after=' + after;
        } else out.lazy11 = 'skipped (too close)';
      } else out.lazy11 = 'skipped (' + (window.echarts ? a11.length + ' charts' : 'no ECharts') + ')';
      // G4: print opens every folded card, the closed "Checked and normal"
      // fold and (dashboard) every closed lead row; afterprint restores them
      {
        const st = () => ({ f: [...document.querySelectorAll('article.fc.fold')].map(c => c.id).join(','),
          n: (document.querySelector('#s-normal details.calm-fold') || {}).open,
          r: [...document.querySelectorAll('details.drow.lead')].map(d => d.open ? 1 : 0).join('') });
        const b0 = st();
        window.dispatchEvent(new Event('beforeprint'));
        const b1 = st();
        window.dispatchEvent(new Event('afterprint'));
        const b2 = st();
        const open1 = b1.f === '' && b1.n !== false && !/0/.test(b1.r);
        out.print = open1 && JSON.stringify(b0) === JSON.stringify(b2) ? 'ok' : 'FAIL ' + JSON.stringify([b0, b1, b2]);
        await wait(80);
      }
      out.strips = document.querySelectorAll('td.trend svg.mw').length;
      out.lines = document.querySelectorAll('td.trend svg.spark').length;
      // js_microstrip draws nothing past 91 windows (no pixel per bar left)
      out.nwin = (window.AWR_WIN && window.AWR_WIN.w) ? window.AWR_WIN.w.length : 0;
      window.AWR_setView('summary', false);
      return out;
    }, HINT_SQL_RULES);
    console.log('phase 4', JSON.stringify(p4));
    if (/demo_busy_db(_quiet|_dashboard)?\.html$/.test(file) && !p4.att) fail('DB-time breakdown: not shown under the verdict');
    if (!p4.attSrcGone) fail('DB-time breakdown: #att-src left in the page');
    if (!p4.attColors) fail('DB-time breakdown: a part has no wait-class colour');
    if (!p4.impAttrs) fail('finding cards: data-impact / data-share missing');
    if (!p4.impOrder) fail('finding cards: not ordered by impact');
    if (!p4.impChips) fail('finding cards: impact chip missing, or shown below 0.01 AAS');
    if (p4.confCards.some(x => x !== 'ok')) fail('finding cards: the n qualifier ' + p4.confCards.filter(x => x !== 'ok').join('; '));
    if (/^FAIL/.test(p4.confNote)) fail('verdict: thin-baseline note ' + p4.confNote);
    if (p4.lowImp.some(x => / FAIL /.test(x))) fail('finding cards under 0.01 AAS: ' + p4.lowImp.join('; '));
    if (/demo_busy_db(_quiet|_dashboard)?\.html$/.test(file) && !p4.lowImp.includes('f-wait-queueing'))
      fail('demo: expected the flagged background-only Queueing waits card (impact under 0.01 AAS), got ' + JSON.stringify(p4.lowImp));
    if (p4.zcap.length) fail('Summary glyphs print z past 10: ' + p4.zcap.join(', '));
    if (!p4.planOk) fail('plan-change card incomplete, or neither in #changes-slot nor right under the card it explains');
    if (/^FAIL/.test(p4.scatter)) fail('SQL Monitor scatter ' + p4.scatter);
    if (/demo_busy_db(_quiet|_dashboard)?\.html$/.test(file) && /local time/.test(p4.scatter)) fail('SQL Monitor scatter: the demo must read its times as UTC (useUTC)');
    if (!p4.sumOk) fail('Copy summary: Markdown missing the verdict, a card line, or contains undefined/null');
    if (!p4.sumClosed) fail('Copy summary: the popover did not close');
    if (!p4.sumEsc) fail('Copy summary: Escape on the close button did not close the popover, or it unpinned the window');
    if (!p4.sumOnTop) fail('Copy summary: something paints over the popover in the Timeline view');
    if (!p4.durOk) fail('plan card: elapsed not shown as a duration');
    if (!p4.aasOk) fail('Timeline: a wait-event row is not in AAS');
    if (p4.evOverClass.length) fail('Timeline: wait-event row(s) above their own wait-class row: ' + p4.evOverClass.join(', '));
    if (!p4.smOrder) fail('SQL Monitor table: flagged statements not first, or a detail row lost its statement');
    if (!p4.topsqlTab) fail('Top SQL: the selected tab and the open panel disagree');
    if (p4.ioSql === false && /demo_busy_db(_quiet|_dashboard)?\.html$/.test(file)) fail('demo: the Physical I/O card has no SQL evidence row');
    if (!p4.explainsOk) fail('an explaining plan-change card is not right under its card (dashboard: not in #changes-slot) or lacks its chip');
    if (!/^ok/.test(p4.print)) fail('print: folded cards / Checked and normal / dashboard rows not opened for print or not restored after: ' + p4.print);
    if (p4.explainsPh.length) fail('an explaining plan-change card shows another transition than the one its card cites (or has no link to it): ' + p4.explainsPh.join(', '));
    if (p4.planLinkPh.length) fail('a finding card links a plan-change card while citing another transition: ' + p4.planLinkPh.join(', '));
    if (!p4.explainsFold) fail('an explaining plan-change card is not folded with the card it explains (dashboard: folded or with a toggle)');
    if (/demo_busy_db(_quiet|_dashboard)?\.html$/.test(file) && p4.explains !== 1) fail('demo: expected the plan card of 7k2m9dx4qp1zb to explain the Physical I/O card, got ' + p4.explains);
    if (!p4.changesOk) fail('"What changed around it" visible while empty, or hidden while it holds a card');
    if (!p4.lib || p4.libVisible !== p4.lib) fail('evidence library: ' + p4.libVisible + '/' + p4.lib + ' rows visible in Summary');
    if (p4.libNoLs.length) fail('evidence library rows without a one-line status: ' + p4.libNoLs.join(', '));
    if (!p4.libHead) fail('evidence library heading #s-lib not visible');
    if (!p4.edges) fail('evidence library: first / last row edges');
    if (/^FAIL/.test(p4.toggle)) fail('evidence library row toggle ' + p4.toggle);
    if (/^FAIL/.test(p4.reveal)) fail('evidence library reveal ' + p4.reveal);
    if (!p4.subsOk) fail('rail card sub-links ' + p4.subs);
    if (!p4.hintsOk) fail('card hints: a hint without its line, a rule with a query that shows none (or the reverse), or a next-step query not copyable / with an unfilled placeholder / not read-only SELECTs: ' + p4.hintBad.join(', '));
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
    if (/^FAIL/.test(p4.rdSplit)) fail('release-delta: ' + p4.rdSplit);
    if (/demo_busy_db(_quiet|_dashboard)?\.html$/.test(file) && p4.rdSplit !== 'split') fail('demo: release-delta should open on a split at its release marker, got ' + p4.rdSplit);
    if (/^FAIL/.test(p4.lazy11)) fail('section 11 lazy charts ' + p4.lazy11);
    if ((!p4.strips && p4.nwin <= 91) || p4.lines) fail('micro strips: ' + p4.strips + ' svg.mw, ' + p4.lines + ' line sparklines left');
    // G4: pattern chips are focusable (tabindex 0, named by their text, the
    // sentence as title); keyboard focus shows the sentence in #ptip under
    // the chip; Esc hides it and is not swallowed (a pinned window unpins)
    const tagKb = await page.evaluate(async () => {
      const vis = el => !!el && el.getClientRects().length > 0;
      const all = [...document.querySelectorAll('.ptag')];
      const bad = all.filter(t => t.getAttribute('tabindex') !== '0' || t.getAttribute('aria-label') !== t.textContent || !t.title).length;
      const c = all.find(vis);
      if (!c) return { n: all.length, bad, tip: 'none' };
      const w = (window.AWR_WIN && AWR_WIN.w) || [];
      if (w.length > 1 && window.AWR_WG && AWR_WG.pin) AWR_WG.pin(w[0].o);
      c.focus(); await new Promise(r => setTimeout(r, 80));
      const p = document.getElementById('ptip'), r = c.getBoundingClientRect(), q = p && p.getBoundingClientRect();
      const ok = vis(p) && p.textContent === c.title && q.top >= r.bottom && q.top - r.bottom < 20;
      return { n: all.length, bad, tip: ok ? 'ok' : 'FAIL ' + JSON.stringify([!!p, p && p.textContent, r.bottom, q && q.top]), pinned: document.body.hasAttribute('data-pw') };
    });
    if (tagKb.tip !== 'none') { await page.keyboard.press('Escape'); await page.waitForTimeout(150); }
    tagKb.esc = tagKb.tip === 'none' ? 'none' : await page.evaluate(() => {
      const p = document.getElementById('ptip');
      return (!p || p.hidden) ? (document.body.hasAttribute('data-pw') ? 'FAIL still pinned' : 'ok') : 'FAIL tip shown';
    });
    console.log('pattern chips (keyboard): ' + JSON.stringify(tagKb));
    if (tagKb.bad) fail('pattern tags: ' + tagKb.bad + ' chip(s) not focusable / unnamed / without a title');
    if (/^FAIL/.test(tagKb.tip)) fail('pattern tags: keyboard focus does not show the sentence: ' + tagKb.tip);
    if (tagKb.pinned && /^FAIL/.test(tagKb.esc)) fail('pattern tags: Esc on a focused chip ' + tagKb.esc);
    if (/demo_busy_db(_quiet|_dashboard)?\.html$/.test(file) && tagKb.tip !== 'ok') fail('demo: no pattern chip to focus');
    if (errors.length) fail('phase 4: ' + errors.slice(0, 5).join(' | '));
    if (shots) {
      const pc = await page.$('#s-changes');
      if (pc && await pc.isVisible()) await pc.screenshot({ path: path.join(shots, 'changes.png') });
      const lh = await page.$('#s-lib');
      if (lh) { await lh.scrollIntoViewIfNeeded(); await page.waitForTimeout(200); await page.screenshot({ path: path.join(shots, 'library.png') }); }
    }
    await page.close();
  }

  // ---- 6c. plan 040: (a) a library row that starts open (Top SQL,
  // Foreground waits: they carry data-news) is closed exactly when what its
  // status line is about is already on a finding / plan-change card, and
  // stays as marked when the report has no finding card; a click on its
  // header opens it, a jump to a row inside it opens it.  (b) the
  // machine-readable result: script#awr-findings parses, one entry per
  // finding card, with the card's own attributes.  Read on a fresh load,
  // before any interaction.
  {
    const { page, errors } = await openPage('#view=summary', 'light');
    const r40 = await page.evaluate(async () => {
      const vis = el => !!el && el.getClientRects().length > 0;
      const wait = ms => new Promise(r => setTimeout(r, ms));
      const out = {};
      const cards = [...document.querySelectorAll('#findings article.fc:not(.chg)')];
      const rows = [...document.querySelectorAll('main > section.lib[data-news]')];
      const href = [...document.querySelectorAll('article.fc a[href]')].map(a => a.getAttribute('href'));
      const on = t => {
        const i = t.indexOf(':'), k = t.slice(0, i), v = t.slice(i + 1);
        if (k === 'card') return cards.some(c => c.id === v);
        if (k === 'sql') return !!document.getElementById('f-plan-' + v) || href.some(h => h.endsWith('-' + v));
        return false;
      };
      out.rows = rows.map(s => s.id);
      out.rule = rows.map(s => {
        const toks = s.getAttribute('data-news').split(' ').filter(Boolean);
        const wantShut = cards.length > 0 && toks.every(on);
        const open = s.classList.contains('lopen');
        return (open === !wantShut ? 'ok ' : 'FAIL ') + s.id + ' news=[' + toks.join(',') + '] open=' + open;
      });
      // the two rows the rule is about carry the attribute
      out.hasBoth = ['topsql', 'waits-fg'].every(id => !document.getElementById(id) || rows.some(s => s.id === id));
      // a click opens a shut one and shuts it again; a jump to a row inside opens it
      const shut = rows.find(s => !s.classList.contains('lopen'));
      if (shut) {
        const h = shut.querySelector('h2');
        const body = () => [...shut.children].filter(c => c !== h && vis(c)).length;
        const b0 = body();
        h.click(); await wait(150);
        const o1 = shut.classList.contains('lopen') && body() > 0 && h.getAttribute('aria-expanded') === 'true';
        h.click(); await wait(80);
        const row = shut.querySelector('tbody tr[id]');
        let j = 'no row';
        if (row) {
          window.AWR_goTo(row, true, false); await wait(250);
          j = shut.classList.contains('lopen') && vis(row) ? 'ok' : 'FAIL';
          h.click(); await wait(60);
        }
        out.shut = (!b0 && o1 && !body() && j !== 'FAIL' ? 'ok ' : 'FAIL ') + shut.id + ' ' + JSON.stringify([b0, o1, body(), j]);
      } else out.shut = 'none';
      // (b) the machine-readable result
      const el = document.getElementById('awr-findings');
      if (!el) { out.json = 'FAIL missing'; return out; }
      const bad = [];
      let d = null;
      try { d = JSON.parse(el.textContent); } catch (e) { bad.push('not JSON: ' + e.message); }
      if (el.getAttribute('type') !== 'application/json') bad.push('type');
      if (document.querySelectorAll('#awr-findings').length !== 1) bad.push('id not unique');
      if (/</.test(el.textContent)) bad.push('raw < inside the block');
      if (d) {
        if (d.schema !== 1) bad.push('schema ' + d.schema);
        const rp = d.report || {};
        for (const k of ['version', 'run_id', 'db_name', 'dbid', 'host', 'target_end', 'win_hours', 'step_hours', 'weeks_back', 'valid_prior_windows', 'template', 'inst_num'])
          if (!(k in rp)) bad.push('report.' + k);
        const wins = (window.AWR_WIN && AWR_WIN.w) || [];
        if (wins.length && rp.valid_prior_windows !== wins.filter(x => x.o > 0 && x.v === 'Y').length) bad.push('valid_prior_windows ' + rp.valid_prior_windows);
        if (rp.weeks_back !== undefined && wins.length && rp.weeks_back + 1 !== wins.length) bad.push('weeks_back ' + rp.weeks_back + ' vs ' + wins.length + ' windows');
        const cs = d.cards || [];
        if (cs.length !== cards.length) bad.push('cards ' + cs.length + ' vs ' + cards.length + ' in the page');
        if (d.counts.cards !== cs.length) bad.push('counts.cards');
        const nl = cards.filter(c => c.classList.contains('f-large')).length, nm = cards.filter(c => c.classList.contains('f-moderate')).length;
        if (d.counts.large !== nl || d.counts.moderate !== nm) bad.push('counts ' + d.counts.large + '/' + d.counts.moderate + ' vs ' + nl + '/' + nm);
        const pill = document.querySelector('#verdict li.pl-find');
        if (pill) {
          const pn = +(pill.querySelector('b') || {}).textContent, ps = pill.querySelector('.pl-sev') ? pill.querySelector('.pl-sev').textContent : '';
          const pl = (/(\d+) large/.exec(ps) || [0, 0])[1], pm = (/(\d+) moderate/.exec(ps) || [0, 0])[1];
          if (pn !== d.counts.cards || +pl !== d.counts.large || +pm !== d.counts.moderate) bad.push('verdict pill ' + pn + '/' + pl + '/' + pm);
        } else if (d.counts.cards !== 0) bad.push('no verdict pill but ' + d.counts.cards + ' cards');
        cs.forEach((c, i) => {
          const e = document.getElementById(c.id);
          if (!e || !e.matches('#findings article.fc:not(.chg)')) { bad.push('card ' + c.id + ' not in the page'); return; }
          if (cards[i] !== e) bad.push('card order at ' + i);
          if (!e.classList.contains('f-' + c.severity)) bad.push(c.id + ' severity');
          const im = e.getAttribute('data-impact'), sh = e.getAttribute('data-share');
          if ((im === '' ? null : +im) !== c.impact_aas) bad.push(c.id + ' impact ' + im + ' vs ' + c.impact_aas);
          if ((sh === '' ? null : +sh) !== c.share_pct) bad.push(c.id + ' share ' + sh + ' vs ' + c.share_pct);
          for (const k of ['id', 'group', 'label', 'severity', 'domain', 'metric', 'unit', 'current', 'mean', 'sd', 'n', 'z', 'impact_aas', 'share_pct'])
            if (!(k in c)) bad.push(c.id + '.' + k);
          if (typeof c.current !== 'number' || typeof c.n !== 'number') bad.push(c.id + ' current / n not numbers');
        });
      }
      out.json = bad.length ? 'FAIL ' + bad.join('; ') : 'ok (' + (d ? d.cards.length : 0) + ' cards, ' + (d ? d.report.valid_prior_windows : '?') + ' valid prior windows)';
      out.nCards = cards.length;
      return out;
    });
    console.log('plan 040', JSON.stringify(r40));
    if (r40.rule.some(x => /^FAIL/.test(x))) fail('library rows: open / shut does not follow "news all on cards": ' + r40.rule.filter(x => /^FAIL/.test(x)).join('; '));
    if (!r40.hasBoth) fail('library rows: Top SQL / Foreground waits lost their data-news');
    if (/^FAIL/.test(r40.shut)) fail('library rows: a shut row ' + r40.shut);
    if (/^FAIL/.test(r40.json)) fail('findings JSON: ' + r40.json);
    if (/demo_busy_db(_quiet|_dashboard)?\.html$/.test(file)) {
      if (!r40.rule.length || r40.rule.some(x => !/ open=false$/.test(x))) fail('demo: Top SQL and Foreground waits should both start shut (their news is on cards): ' + JSON.stringify(r40.rule));
      if (r40.shut === 'none') fail('demo: no shut row to open');
      if (r40.nCards !== 5) fail('demo: expected 5 finding cards, got ' + r40.nCards);
    }
    if (errors.length) fail('plan 040: ' + errors.slice(0, 5).join(' | '));
    await page.close();
  }

  // ---- 6d. plan 041: the peak inside the window.  (a) AWR_DATA.ashx.pk:
  // one entry per window, oldest first, null for a skipped window; its
  // Current value = the busiest minute of the Current window recomputed
  // from ashx.fine (every class summed per minute, / 6).  (b) 09's table
  // "Busiest minute per window" agrees with it.  (c) the DB time card's
  // "Peak" evidence row exists exactly when the card and a Current value
  // do, with no severity.  (d) 03's Peak (1 min) is never below the Current
  // average (rows labelled "max per instance" excepted: RAC).  (e) a window
  // stripe's tooltip names its busiest minute.  A report from before the
  // plan (no pk, no peak cells) skips each part.
  {
    const { page, errors } = await openPage('#view=all', 'light');
    const r41 = await page.evaluate(() => {
      const out = {}, bad = [];
      const P = (window.AWR_DATA || {}).ashx, W = (window.AWR_WIN || {}).w || [];
      const pk = P && P.pk;
      if (!P) out.pk = 'no ashx';
      else if (!pk) out.pk = 'no pk (report before plan 041)';
      else {
        if (pk.length !== W.length) bad.push('pk has ' + pk.length + ' entries for ' + W.length + ' windows');
        pk.forEach((e, i) => {
          if (!W[i] || e[0] !== W[i].o) bad.push('pk[' + i + '] is window ' + e[0]);
          else if (W[i].v === 'N' && e[1] != null) bad.push('skipped window ' + e[0] + ' has a peak');
          if (e[1] != null && !(e[1] >= 0 && /^\d{4}-\d\d-\d\d \d\d:\d\d$/.test(e[2]))) bad.push('pk[' + i + '] ' + JSON.stringify(e));
        });
        const cur = pk[pk.length - 1], f = P.fine;
        if (cur && cur[1] != null && f) {
          const n = f.segs.reduce((a, g) => a + g[1], 0), tot = new Array(n).fill(0);
          P.classes.forEach((c, k) => { let j = 0; f.vals[k].forEach(x => { if (x < 0) j += -x; else tot[j++] += x; }); });
          const t0 = Date.parse(P.t0.replace(' ', 'T') + ':00Z'), cw = W[W.length - 1];
          const cs = Date.parse(cw.s.replace(' ', 'T') + ':00Z'), ce = Date.parse(cw.e.replace(' ', 'T') + ':00Z');
          let best = -1, at = null, j = 0;
          f.segs.forEach(g => { for (let q = 0; q < g[1]; q++, j++) { const t = t0 + (g[0] + q) * 6e4; if (t >= cs && t < ce && tot[j] > best) { best = tot[j]; at = t; } } });
          const want = best / 6, atS = at == null ? null : new Date(at).toISOString().slice(0, 16).replace('T', ' ');
          if (Math.abs(want - cur[1]) > 6e-4 || atS !== cur[2]) bad.push('Current pk ' + JSON.stringify(cur) + ' vs fine ' + want.toFixed(3) + ' at ' + atS);
          out.cur = cur[1] + ' at ' + cur[2] + ' (fine ' + want.toFixed(3) + ')';
        }
        const tb = document.querySelector('#ash-timeline table#ash-peaks');
        if (!tb) bad.push('no #ash-peaks table');
        else {
          const rows = [...tb.tBodies[0].rows];
          if (rows.length !== W.length) bad.push('#ash-peaks has ' + rows.length + ' rows');
          const c0 = rows[0] && rows[0].querySelector('td[data-pk]');
          if (cur && cur[1] != null && (!c0 || Math.abs(+c0.getAttribute('data-pk') - cur[1]) > 1e-9)) bad.push('#ash-peaks Current ' + (c0 && c0.getAttribute('data-pk')));
          if (tb.querySelector('tr.crit, tr.warn, .bd')) bad.push('#ash-peaks carries a severity');
        }
        out.pk = bad.length ? 'FAIL ' + bad.join('; ') : 'ok (' + pk.filter(e => e[1] != null).length + ' of ' + pk.length + ' known)';
      }
      // (c) the DB time card row
      const card = document.getElementById('f-dbtime'), row = document.querySelector('#f-dbtime .evr.ev-pk');
      const want = !!(card && pk && pk.length && pk[pk.length - 1][1] != null);
      if (want !== !!row) out.card = 'FAIL row ' + (row ? 'present' : 'missing') + ' (card ' + !!card + ', Current pk ' + !!want + ')';
      else if (row) {
        const v = pk[pk.length - 1][1], txt = row.textContent, s = v >= 100 ? String(Math.round(v)) : v.toFixed(1);
        out.card = (txt.indexOf(s + ' active sessions at ') >= 0 && !row.querySelector('.bd, .d:not(.s-plain)') && /10 s/.test(row.title))
          ? 'ok (' + txt.replace(/^Peak/, '').trim().slice(0, 90) + ')' : 'FAIL ' + txt.slice(0, 120);
      } else out.card = 'none (no card or no Current value)';
      // (d) 03's peaks
      const pr = [...document.querySelectorAll('#sysmetric tbody tr')].filter(r => r.querySelector('td.pk'));
      if (!pr.length) out.sm = 'no peak cells (report before plan 041)';
      else {
        const b2 = []; let n = 0;
        if (!document.querySelector('#sysmetric thead th.pk')) b2.push('no header');
        pr.forEach(r => {
          const c = r.querySelector('td.pk[data-pk]'), sp = r.querySelector('td.trend[data-spark]');
          if (!c || !sp || c.hasAttribute('data-pkinst')) return;
          const a = sp.getAttribute('data-spark').split(','), avg = a[a.length - 1] === '' ? null : +a[a.length - 1];
          if (avg == null) return;
          n++;
          if (+c.getAttribute('data-pk') < avg - 1e-6) b2.push(r.id + ' peak ' + c.getAttribute('data-pk') + ' < average ' + avg);
        });
        if (document.querySelector('#sysmetric td.pkd .d:not(.s-plain):not(.s-na)')) b2.push('a peak delta carries a severity');
        out.sm = b2.length ? 'FAIL ' + b2.join('; ') : 'ok (' + n + ' rows peak >= average)';
      }
      return out;
    });
    // (e) the Current window stripe's tooltip (the first chart shown)
    r41.tip = 'skipped';
    if (r41.pk && /^ok/.test(r41.pk) && /^ok/.test(r41.card || 'ok')) {
      const box = await page.evaluate(() => {
        window.scrollTo(0, 0);
        const s = [...document.querySelectorAll('.ashx .axsvg')].find(x => x.getClientRects().length); if (!s) return null;
        const hs = [...s.querySelectorAll('.xwh[data-i]')].sort((a, b) => +a.getAttribute('data-i') - +b.getAttribute('data-i'));
        const h = hs[hs.length - 1]; if (!h) return null;
        h.scrollIntoView({ block: 'center' });
        const r = h.getBoundingClientRect(); return { x: r.left + r.width / 2, y: r.top + Math.min(8, r.height / 2) };
      });
      if (box) {
        await page.mouse.move(box.x, box.y); await page.waitForTimeout(150);
        const tt = await page.evaluate(() => { const t = document.getElementById('tip'); return t && !t.hidden ? t.textContent : ''; });
        const P = await page.evaluate(() => { const p = window.AWR_DATA.ashx.pk; return p[p.length - 1]; });
        r41.tip = (P[1] == null ? !/Busiest minute/.test(tt) : /Busiest minute, all sessions/.test(tt)) ? 'ok' : 'FAIL ' + tt.slice(0, 160);
        await page.mouse.move(5, 5);
      }
    }
    console.log('plan 041', JSON.stringify(r41));
    for (const k of ['pk', 'card', 'sm', 'tip']) if (/^FAIL/.test(r41[k] || '')) fail('peaks (plan 041) ' + k + ': ' + r41[k]);
    if (/demo_busy_db(_quiet|_dashboard)?\.html$/.test(file)) {
      if (!/^ok/.test(r41.pk) || !/^ok/.test(r41.card) || !/^ok/.test(r41.sm) || r41.tip !== 'ok') fail('demo: every plan 041 part should run: ' + JSON.stringify(r41));
    }
    if (errors.length) fail('plan 041: ' + errors.slice(0, 5).join(' | '));
    await page.close();
  }

  // ---- 6e. plan 042: CPU capacity.  (a) AWR_DATA.ashx.cpu: n / used one
  // entry per window, null for a skipped window, cur = the last entries.
  // (b) 09's table "CPU capacity per window": one row per window, its
  // Current cells = cur, no severity.  (c) the DB time card's "CPU" row
  // exists exactly when the card, cur.n and cur.used do; its numbers are
  // cur's.  (d) the class chart's cpu_count line is drawn exactly when
  // cur.n lies inside the y range (read from the axis labels), the
  // header's "above this scale" note exactly when it does not: after load
  // and again after hiding the largest classes from the legend (which
  // rescales the axis).  A report without ashx.cpu skips every part.
  {
    const { page, errors } = await openPage('#view=all', 'light');
    const r42 = await page.evaluate(() => {
      const out = {}, bad = [];
      const P = (window.AWR_DATA || {}).ashx, W = (window.AWR_WIN || {}).w || [], C = P && P.cpu;
      if (!C) { out.pay = 'no ashx.cpu (report before plan 042)'; return out; }
      ['n', 'used'].forEach(k => {
        const a = C[k] || [];
        if (a.length !== W.length) bad.push(k + ' has ' + a.length + ' entries for ' + W.length + ' windows');
        a.forEach((v, i) => { if (W[i] && W[i].v === 'N' && v != null) bad.push(k + ': skipped window ' + W[i].o + ' has ' + v);
          if (v != null && !(v >= 0)) bad.push(k + '[' + i + '] = ' + v); });
      });
      const cu = C.cur || {}, L = W.length - 1;
      if ((C.n || [])[L] !== cu.n || (C.used || [])[L] !== cu.used) bad.push('cur ' + JSON.stringify(cu) + ' is not the last entries');
      if (cu.n != null && cu.used != null && Math.abs(cu.pct - cu.used / cu.n * 100) > 2e-3) bad.push('cur.pct ' + cu.pct);
      const tb = document.querySelector('#ash-timeline table#ash-cpu');
      if (!tb) bad.push('no #ash-cpu table');
      else {
        const rows = [...tb.tBodies[0].rows];
        if (rows.length !== W.length) bad.push('#ash-cpu has ' + rows.length + ' rows for ' + W.length + ' windows');
        const c0 = rows[0], cn = c0 && c0.querySelector('td[data-cpu-n]'), cd = c0 && c0.querySelector('td[data-cpu-used]');
        if (c0 && c0.cells[0].getAttribute('data-w') !== '0') bad.push('#ash-cpu first row is not Current');
        if ((cu.n != null) !== !!cn || (cn && +cn.getAttribute('data-cpu-n') !== cu.n)) bad.push('#ash-cpu Current cpu_count ' + (cn && cn.getAttribute('data-cpu-n')));
        if ((cu.used != null) !== !!cd || (cd && Math.abs(+cd.getAttribute('data-cpu-used') - cu.used) > 1e-9)) bad.push('#ash-cpu Current DB CPU ' + (cd && cd.getAttribute('data-cpu-used')));
        if (tb.querySelector('tr.crit, tr.warn, .bd, .badge')) bad.push('#ash-cpu carries a severity');
        if (!tb.hasAttribute('data-nocount')) bad.push('#ash-cpu lacks data-nocount');
      }
      out.pay = bad.length ? 'FAIL ' + bad.join('; ') : 'ok (' + (C.n || []).filter(v => v != null).length + ' of ' + W.length + ' known, Current ' + cu.n + ' / ' + cu.used + ')';
      // (c) the card row: the numbers of cur, the rule of cpuInfo
      const card = document.getElementById('f-dbtime'), row = document.querySelector('#f-dbtime .evr.ev-cpu');
      const want = !!(card && cu.n > 0 && cu.used != null);
      if (want !== !!row) out.card = 'FAIL row ' + (row ? 'present' : 'missing') + ' (card ' + !!card + ', cur ' + JSON.stringify(cu) + ')';
      else if (row) {
        const f = v => v >= 100 ? String(Math.round(v)) : v >= 0.1 ? v.toFixed(1) : v.toFixed(2), p = cu.used / cu.n * 100, pr = Math.round(p);
        const head = 'DB CPU ' + f(cu.used) + ' of cpu_count ' + cu.n + ' (' + (pr < 1 && p > 0 ? '<1' : pr) + '%)', txt = row.querySelector('.de').textContent;
        const d = cu.ash == null ? null : cu.ash - cu.used, q = d != null && d >= 0.1 * cu.used && d >= 0.5;
        const ok = txt.indexOf(head) === 0 && q === /waiting for a CPU/.test(txt) && (cu.used >= 0.9 * cu.n) === /CPU-bound/.test(txt)
          && !row.querySelector('.bd, .d, .badge');
        out.card = ok ? 'ok (' + txt + ')' : 'FAIL "' + txt + '" want "' + head + '"' + (q ? ' + queue' : '');
      } else out.card = 'none (no card or no Current cpu_count / DB CPU)';
      return out;
    });
    // (d) the line vs the y range, after load and after the legend rescales
    if (/^ok/.test(r42.pay || '')) {
      const state = async () => {
        await page.mouse.move(2, 2); await page.waitForTimeout(150);
        return page.evaluate(() => {
          const sv = document.querySelector('#ax-cls .axsvg'), cu = window.AWR_DATA.ashx.cpu.cur, n = cu.n;
          if (!sv || !sv.getClientRects().length || !(n > 0) || cu.used == null) return null;
          const ys = [...sv.querySelectorAll('text.at')].map(t => t.textContent).filter(t => /^\d+(\.\d+)?$/.test(t)).map(Number);
          const ymax = Math.max(...ys), line = !!sv.querySelector('line.xcpu'), lab = sv.querySelector('text.xcpt');
          const hd = document.querySelector('#ashx .axcpu'), note = !!(hd && !hd.hidden && hd.getClientRects().length);
          return { n, ymax, line, note, lab: lab ? lab.textContent : null, in: n <= ymax + 1e-9 };
        });
      };
      const s0 = await state();
      const ok1 = s => s && s.line === s.in && s.note === !s.in && (!s.line || /^cpu_count \d+/.test(s.lab || 'cpu_count 0'));
      if (!s0) r42.line = 'skipped (class chart not shown or no Current cpu_count)';
      else {
        // hide classes, largest Current share first, until the axis falls below cpu_count (or one is left)
        const hid = await page.evaluate(() => {
          const P = window.AWR_DATA.ashx, L = P.win[0].length - 1, bs = [...document.querySelectorAll('#ax-cls .axc')];
          const ord = P.classes.map((c, k) => [k, P.win[k][L]]).sort((a, b) => b[1] - a[1]).map(x => x[0]);
          return { ord, n: bs.length };
        });
        const clicked = [];
        let s1 = s0;
        for (const k of hid.ord.slice(0, hid.n - 1)) {
          if (!s1.in) break;
          await page.evaluate(k => document.querySelector('#ax-cls .axc[data-c="' + k + '"]').click(), k);
          clicked.push(k);
          s1 = await state();
        }
        for (const k of clicked) await page.evaluate(k => document.querySelector('#ax-cls .axc[data-c="' + k + '"]').click(), k);
        const s2 = await state();
        r42.line = (ok1(s0) && ok1(s1) && ok1(s2) && s2.line === s0.line)
          ? 'ok (load: ' + (s0.in ? 'line at ' + s0.n + ' of ' + s0.ymax : 'note, ' + s0.n + ' over ' + s0.ymax) + '; ' + clicked.length + ' hidden: '
            + (s1.in ? 'line, ' + s1.n + ' of ' + s1.ymax : 'note, ' + s1.n + ' over ' + s1.ymax) + ')'
          : 'FAIL ' + JSON.stringify({ s0, s1, s2 });
        r42.both = s0.in !== s1.in;
      }
    }
    console.log('plan 042', JSON.stringify(r42));
    for (const k of ['pay', 'card', 'line']) if (/^FAIL/.test(r42[k] || '')) fail('CPU capacity (plan 042) ' + k + ': ' + r42[k]);
    if (/demo_busy_db(_quiet|_dashboard)?\.html$/.test(file)) {
      if (!/^ok/.test(r42.pay) || !/^ok/.test(r42.card) || !/^ok/.test(r42.line || '') || !r42.both)
        fail('demo: every plan 042 part should run, the line in range at load and the note after hiding: ' + JSON.stringify(r42));
    }
    if (errors.length) fail('plan 042: ' + errors.slice(0, 5).join(' | '));
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
          // the card's impact chip on its lead row (the row hides the card's header)
          imps: rows.filter(r => r.classList.contains('lead')).map(r => {
            const c = r.querySelector('article.fc'), im = c ? parseFloat(c.getAttribute('data-impact')) : NaN;
            const ch = r.querySelector(':scope > summary .dnm .dimp');
            return im >= 0.01 ? (vis(ch) && /^\+[0-9.]+ AAS/.test(ch.textContent) && !!ch.title ? 'y' : 'FAIL ' + (c && c.id)) : (ch ? 'FAIL ' + (c && c.id) : 'n ' + (c && c.id));
          }),
          order: top('verdict') < top('activity') && document.querySelector('.dkpis').getBoundingClientRect().top < top('activity') && top('activity') < top('findings') };
      });
      dz.layout = lay;
      const nk = (lay.hero ? 1 : 0) + lay.cards - (lay.dbtCard && lay.hero ? 1 : 0);
      if (!lay.dash || lay.rail || !lay.search) fail('dashboard: body.d-dash / rail hidden / Jump to button ' + JSON.stringify(lay));
      if (lay.kpis !== nk || lay.kpiBars !== lay.kpis) fail('dashboard: KPI cards ' + lay.kpis + ' (expected ' + nk + '), ' + lay.kpiBars + ' with bars');
      if (lay.inRows !== lay.cards || lay.rows !== lay.tabN || lay.trends !== lay.rows) fail('dashboard: findings table ' + JSON.stringify(lay));
      if (!lay.order) fail('dashboard: Summary order (verdict, KPI cards, Activity, findings)');
      if (lay.imps.some(x => /^FAIL/.test(x))) fail('dashboard: impact chip on the lead rows ' + lay.imps.join(','));
      if (/demo_busy_db_dashboard\.html$/.test(file) && !lay.imps.includes('y')) fail('dashboard demo: no lead row shows its impact chip');
      if (/demo_busy_db_dashboard\.html$/.test(file) && !lay.imps.includes('n f-wait-queueing')) fail('dashboard demo: the background-only card\'s lead row (f-wait-queueing) not shown without the chip: ' + lay.imps.join(','));
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
      // plan 038: the verdict's "Baseline check" note <=> a suggestion with chg > 0 and its numbers
      const bn = await page.evaluate(() => {
        const sec = document.getElementById('win-sim'), D = window.AWR_DATA && window.AWR_DATA.winsim;
        const li = document.querySelector('#narrative-slot li.hn-base');
        const sug = (D && D.sug) || [];
        let best = null;
        sug.forEach((s, i) => { if (s.chg > 0 && D.w && (D.w.filter(x => x.o > 0 && x.v === 'Y').length - s.drop.length) >= 3 && (best === null || s.chg > sug[best].chg)) best = i; });
        if (!D || !sec) return 'none (no window similarity data)';
        if (best === null) return li ? 'FAIL a note without a suggestion that changes something' : 'ok (no note, no suggestion changes anything)';
        if (!li) return 'FAIL no note for suggestion ' + best;
        const bad = [];
        if (+li.getAttribute('data-sug') !== best) bad.push('data-sug ' + li.getAttribute('data-sug') + ' vs ' + best);
        if (+li.getAttribute('data-chg') !== sug[best].chg) bad.push('chg');
        if (+li.getAttribute('data-ca') !== sug[best].ca) bad.push('ca');
        if (+li.getAttribute('data-cb') !== D.cb) bad.push('cb');
        const t = li.textContent;
        if (t.indexOf('from ' + D.cb + ' to ' + sug[best].ca) < 0 && t.indexOf('stay at ' + D.cb) < 0) bad.push('text lacks the counts');
        if (t.indexOf(sug[best].chg + ' metric') < 0) bad.push('text lacks the metric count');
        const ns = li.parentNode;
        if (ns.id !== 'narrative-slot' || ns.hidden) bad.push('slot hidden');
        if (ns.lastElementChild !== li) bad.push('not the last note');
        if (document.getElementById('base-src')) bad.push('source left in the page');
        const a = li.querySelector('a.go');
        if (!a || a.getAttribute('href') !== '#win-sim') bad.push('link');
        return bad.length ? 'FAIL ' + bad.join('; ') : 'ok (suggestion ' + best + ', ' + sug[best].chg + ' metrics, ' + D.cb + ' -> ' + sug[best].ca + ')';
      });
      console.log('viz baseline note on the verdict: ' + bn);
      if (/^FAIL/.test(bn)) fail('viz: baseline note ' + bn);
      // phone width: no section pushes the page sideways
      await page.setViewportSize({ width: 390, height: 844 }); await page.waitForTimeout(500);
      const ph = await page.evaluate(ids => ids.filter(id => { const s = document.getElementById(id); return s && s.getBoundingClientRect().width > 0 && s.scrollWidth > s.clientWidth + 2; }), have);
      console.log('viz sections at 390 px: ' + (ph.length ? 'FAIL ' + ph.join(', ') : 'ok'));
      if (ph.length) fail('viz: wider than its box at 390 px: ' + ph.join(', '));
      if (errors.length) fail('viz: ' + errors.slice(0, 5).join(' | '));
    } else console.log('viz sections: none in this report (older report), skipped');
    await page.close();
  }

  // ---- 9. the Per-SQL detail of the SQL pool (06): an opened row has the
  // "Compared windows" table (a Current row, or its "not captured" state)
  // and, for a statement with SQLSTAT rows, a timeline chart that has
  // series, points and the compared windows' marks; a statement without a
  // plan hash (a PL/SQL call) draws one grey "no plan" series.  Looks at the
  // first pool row and, when the report has one, a plan-less row; a report
  // from before the pool (no #sql-pool) skips the block, and the chart
  // checks are skipped when ECharts did not load (offline, CDN blocked).
  {
    const { page, errors } = await openPage('#view=all', 'light');
    const ids = await page.evaluate(() => {
      const rows = [...document.querySelectorAll('#sql-pool tr.sql-row')];
      const sd = (window.AWR_DATA && AWR_DATA.sqlDetails) || {};
      const idOf = r => (r.id || '').replace(/^sql-/, '');
      const planless = rows.map(idOf).find(id => sd[id] && (sd[id].phv || []).length === 1 && sd[id].phv[0] === '0');
      return { first: rows.length ? idOf(rows[0]) : null, planless: planless || null, n: rows.length };
    });
    if (!ids.first) console.log('per-SQL detail: no SQL pool in this report, skipped');
    else {
      const check = async (id, wantPlanless) => {
        const r = await page.evaluate(async id => {
          const row = document.getElementById('sql-' + id);
          row.hidden = false;
          if (window.AWR_openSqlRow) window.AWR_openSqlRow(row);
          await new Promise(res => setTimeout(res, 700));
          const det = row.nextElementSibling;
          const out = { open: !!det && !det.hidden };
          const t = det && det.querySelector('table.sqd-win');
          out.table = !!t;
          const first = t && t.tBodies[0] && t.tBodies[0].rows[0];   // not querySelector('tbody tr'): the pool's own tbody is an ancestor, so a header row matches
          out.current = !!first && /^\s*Current/.test(first.textContent) && (first.classList.contains('cur') || first.classList.contains('sqd-nocap') || first.classList.contains('skip'));
          out.curRow = !!first && first.classList.contains('cur');
          out.tfoot = !!(t && t.tFoot && t.tFoot.rows.length);
          // the plan badge sits on a CHANGE: compared with the nearest older
          // DISPLAYED row that has a numeric plan hash (rows are newest first);
          // skipped when no such row is displayed (it may be one of the
          // windows past the 30 shown)
          out.badges = 0; out.badBadge = [];
          if (t && t.tBodies[0]) {
            const rows = [...t.tBodies[0].rows];
            const ph = r => { const c = r.querySelector('td.mono'); const m = c && /^\s*(\d+)/.exec(c.textContent); return m ? m[1] : null; };
            // a run of 2+ "not captured" windows is ONE row (a single one has data-w on its first cell)
            const single = r => r.classList.contains('sqd-nocap') && !!r.cells[0] && r.cells[0].hasAttribute('data-w');
            rows.forEach((r, i) => { if (i && single(r) && single(rows[i - 1])) out.badBadge.push('rows ' + (i - 1) + ' and ' + i + ': two adjacent single "not captured" rows (a run was not collapsed)'); });
            rows.forEach((r, i) => {
              const b = r.querySelector('.badge.sqd-pc'); if (!b) return;
              out.badges++;
              const mine = ph(r); if (!mine) { out.badBadge.push('row ' + i + ': badge without a numeric plan hash'); return; }
              for (let j = i + 1; j < rows.length; j++) {
                const o = ph(rows[j]); if (!o) continue;
                if (o === mine) out.badBadge.push('row ' + i + ': badge but the older row ' + j + ' ran the same plan ' + o);
                else { const tm = /ran (\d+)/.exec(b.getAttribute('title') || ''); if (!tm || tm[1] !== o) out.badBadge.push('row ' + i + ': badge title names ' + (tm ? tm[1] : '?') + ', the older row ran ' + o); }
                break;
              }
            });
          }
          const sd = ((window.AWR_DATA || {}).sqlDetails || {})[id];
          out.hasRows = !!(sd && (sd.p || []).length);
          out.hasChartDiv = !!document.getElementById('sqltl-' + id);
          out.echarts = !!window.echarts;
          if (out.hasRows && window.echarts) {
            const el = document.getElementById('sqltl-' + id);
            const ch = el && echarts.getInstanceByDom(el);
            out.chart = !!ch;
            if (ch) {
              const o = ch.getOption(), ser = o.series || [];
              out.series = ser.length;
              out.points = ser.reduce((a, q) => a + (q.data || []).length, 0);
              out.name0 = ser[0] && ser[0].name;
              const mks = ser.find(q => q.markArea && (q.markArea.data || []).length) || ser.find(q => q.id === 'winmarks') || {};
              out.markId = mks.id || '';
              out.hidesWithPlan0 = ser[0] === mks;
              out.xtype = (o.xAxis && o.xAxis[0] && o.xAxis[0].type) || '';
              const win = ((window.AWR_WIN || {}).w || []).filter(w => w.v === 'Y').length;
              out.validWin = win;
              out.areas = mks.markArea && (mks.markArea.data || []).length || 0;
              out.lines = mks.markLine && (mks.markLine.data || []).length || 0;
            }
          }
          return out;
        }, id);
        const tag = (wantPlanless ? 'plan-less ' : '') + id;
        console.log('per-SQL detail ' + tag + ': ' + JSON.stringify(r));
        if (!r.open) fail('per-SQL detail ' + tag + ': the row did not open');
        (r.badBadge || []).forEach(m => fail('per-SQL detail ' + tag + ': plan badge ' + m));
        if (!r.table) fail('per-SQL detail ' + tag + ': no table.sqd-win');
        else {
          if (!r.current) fail('per-SQL detail ' + tag + ': the Compared windows table has no Current row');
          if (!r.tfoot) fail('per-SQL detail ' + tag + ': no prior-mean row');
        }
        if (r.hasRows && !r.hasChartDiv) fail('per-SQL detail ' + tag + ': rows but no #sqltl- chart box');
        if (r.hasRows && r.echarts) {
          if (!r.chart) fail('per-SQL detail ' + tag + ': no ECharts instance in #sqltl-' + id);
          else {
            if (!r.series || !r.points) fail('per-SQL detail ' + tag + ': the chart has ' + (r.series || 0) + ' series / ' + (r.points || 0) + ' points');
            if (r.xtype !== 'time') fail('per-SQL detail ' + tag + ': x axis is "' + r.xtype + '", expected a time axis');
            if (r.validWin && !r.areas) fail('per-SQL detail ' + tag + ': AWR_WIN has ' + r.validWin + ' valid windows but no series of the chart has markArea data');
            if (r.validWin && r.hidesWithPlan0) fail('per-SQL detail ' + tag + ': the window marks sit on the first plan series (they vanish when it is hidden in the legend)');
            if (wantPlanless && r.name0 !== 'no plan') fail('per-SQL detail ' + tag + ': series[0] is "' + r.name0 + '", expected "no plan"');
          }
        }
      };
      await check(ids.first, false);
      if (ids.planless) await check(ids.planless, true);
      else console.log('per-SQL detail: no plan-less statement in this report (' + ids.n + ' pool rows), that case not exercised');
      if (errors.length) fail('per-SQL detail: ' + errors.slice(0, 5).join(' | '));
    }
    await page.close();
  }

  // ---- 10. Top SQL: "Values: Total | Per execution | Top per execution".  EVERY
  // panel carries the switch (one shared state, mode values total / perexec /
  // pe-rank).  Per execution = a client-side SWAP inside the Total view of the
  // four metric tabs (Elapsed, CPU, Buffer gets, Physical reads): the same
  // statements, row order and ranks (the #n badges STAY visible), every value
  // divided by its executions (the cells' data-pe / data-pt, the Current
  // header unit, the chart's "...Pe" arrays), restored exactly on the way
  // back.  Top per execution = a separate ranking (ELAPSED_PE ...: each
  // window's top N by value per completed execution: own # badges, order,
  // chart, Break down by, detail table), the second view of the panel.  The
  // other three tabs carry a note saying what they show in the other modes.
  // The state is set before the panels are parsed; localStorage
  // awr-topsql-val is written on a click only; a link to a row the current
  // mode hides shows its view (never saved), a Total row in per execution mode
  // changes nothing.  A report without the switch (no Top SQL, or older) skips
  // the block; a panel or ranking the report does not have is skipped.
  {
    const KEY = 'awr-topsql-val';
    const METRICS = ['ELAPSED', 'CPU', 'GETS', 'PREADS'];
    const UNIT = { ELAPSED: 's/exec', CPU: 's/exec', GETS: 'gets/exec', PREADS: 'reads/exec' };
    const TOTU = { ELAPSED: 's', CPU: 's', GETS: 'gets', PREADS: 'reads' };
    const MODES = ['total', 'perexec', 'pe-rank'];
    const LABEL = { total: 'Total', perexec: 'Per execution', 'pe-rank': 'Top per execution' };
    const lsGet = page => page.evaluate(k => { try { return localStorage.getItem(k); } catch (e) { return 'ERR'; } }, KEY);
    const lsSet = (page, v) => page.evaluate(([k, v]) => { try { localStorage.setItem(k, v); } catch (e) {} }, [KEY, v]);
    const lsClear = page => page.evaluate(k => { try { localStorage.removeItem(k); } catch (e) {} }, KEY);
    // what the page shows: the mode and its classes, per panel the displayed view(s), the switch, the notes
    const state = page => page.evaluate(() => {
      const root = document.getElementById('topsql');
      const disp = el => getComputedStyle(el).display;
      const out = { js: root.classList.contains('tsv-js'), pe: root.classList.contains('tsv-pe'), rank: root.classList.contains('tsv-rank'),
        mode: window.AWR_topsqlVal ? window.AWR_topsqlVal() : null, panels: {} };
      root.querySelectorAll('.tabpanel[data-tabs="topsql"]').forEach(p => {
        const d = p.getAttribute('data-t'), sw = p.querySelector(':scope > div[data-tsv]');
        const tv = p.querySelector(':scope > .tsv-view[data-val="total"]'), sn = tv && tv.querySelector(':scope > p.tsv-swap-note');
        out.panels[d] = {
          views: [...p.querySelectorAll(':scope > .tsv-view')].map(v => v.getAttribute('data-val') + ':' + (disp(v) === 'none' ? 'off' : 'on')).join(),
          sw: sw ? disp(sw) !== 'none' : null,
          active: sw ? (sw.querySelector('button.active') || {}).textContent : null,
          pressed: sw ? [...sw.querySelectorAll('button')].map(b => b.getAttribute('aria-pressed')).join() : null,
          notes: [...p.querySelectorAll(':scope > .tsv-note')].map(n => ({ cls: n.className, shown: disp(n) !== 'none', txt: n.textContent })),
          swapNote: sn ? disp(sn) !== 'none' : null,
        };
      });
      return out;
    });
    // the four total tables, every cell's text and title (a swap must restore both exactly)
    const snapTables = page => page.evaluate((METRICS) => {
      const o = {};
      METRICS.forEach(d => {
        const t = document.getElementById('topsql-detail-' + d);
        o[d] = t ? [...t.querySelectorAll('th, td')].map(e => e.textContent + '\u0001' + (e.getAttribute('title') || '\u0002')) : null;
      });
      return o;
    }, METRICS);
    // badges of the four total tables: how many exist and how many are displayed
    const badges = page => page.evaluate(() => {
      const f = sel => { const l = [...document.querySelectorAll(sel)]; return { n: l.length, shown: l.filter(b => getComputedStyle(b).display !== 'none').length }; };
      return { rank: f('#topsql table.tsv-tbl .badge.info, #topsql table.tsv-tbl .badge.skip'), plan: f('#topsql table.tsv-tbl .badge.warn'),
        other: f('#topsql table:not(.tsv-tbl) .badge.info, #topsql table:not(.tsv-tbl) .badge.skip') };
    });
    const chartOf = (page, dim) => page.evaluate(dim => {
      if (!window.echarts) return null;
      const el = document.getElementById('topsql-chart-' + dim), ch = el && echarts.getInstanceByDom(el);
      if (!ch) return { none: true };
      const o = ch.getOption();
      let tip = null;
      try {
        const f = (o.tooltip && o.tooltip[0] || {}).formatter;
        if (typeof f === 'function') tip = f([{ axisValue: 'w', marker: '', seriesName: 'S', value: 0.00123 }]);
      } catch (e) { tip = 'ERR ' + e.message; }
      return { w: ch.getWidth(), yname: (o.yAxis && o.yAxis[0] || {}).name, n: (o.series || []).length,
        data0: JSON.stringify(((o.series || [])[0] || {}).data), tip };
    }, dim);
    const payloadOf = (page, dim, g) => page.evaluate(([dim, g]) => { const a = (((AWR_DATA.topSql.dims[dim] || {})[g]) || [])[0]; return a ? JSON.stringify(Array.isArray(a) ? a : a.vals) : null; }, [dim, g]);
    const { page, errors } = await openPage('#view=all', 'light');
    await lsClear(page);
    await page.reload({ waitUntil: 'load' }); await page.waitForTimeout(1200);
    const present = await page.evaluate(() => !!document.querySelector('#topsql .tabpanel[data-tabs="topsql"] div[data-tsv]'));
    if (!present) console.log('top SQL values switch: not in this report, skipped');
    else {
      const bad = m => fail('top SQL values switch: ' + m);
      // the state a mode must show, checked in every panel the report has
      const checkState = (st, mode, where) => {
        const w = '(' + where + ') ';
        if (!st.js || st.mode !== mode || st.pe !== (mode === 'perexec') || st.rank !== (mode === 'pe-rank')) bad(w + 'state is mode ' + st.mode + ', classes js ' + st.js + ' pe ' + st.pe + ' rank ' + st.rank + ', expected ' + mode);
        Object.keys(st.panels).forEach(d => {
          const p = st.panels[d];
          if (!p.sw || p.active !== LABEL[mode] || p.pressed !== MODES.map(m => m === mode).join()) bad(w + d + ': switch hidden or not on "' + LABEL[mode] + '": ' + JSON.stringify(p));
          if (METRICS.includes(d)) {
            if (p.views !== (mode === 'pe-rank' ? 'total:off,pe-rank:on' : 'total:on,pe-rank:off')) bad(w + d + ': views are ' + p.views);
            if (p.swapNote !== (mode === 'perexec')) bad(w + d + ': the Total view\'s swap note is ' + (p.swapNote ? 'shown' : 'hidden'));
          }
          p.notes.forEach(n => {
            const want = /tsv-n-other/.test(n.cls) ? mode !== 'total' : /tsv-n-total/.test(n.cls) ? mode === 'total' : null;
            if (want === null) bad(w + d + ': a note of class "' + n.cls + '"');
            else if (n.shown !== want) bad(w + d + ': the note "' + n.cls + '" is ' + (n.shown ? 'shown' : 'hidden'));
          });
        });
      };
      // click a mode in the (visible) panel of `dim`
      const clickMode = async (dim, mode) => {
        const t = await page.$('#tab-topsql-' + dim); if (t) await t.click();
        await page.click('.tabpanel[data-t="' + dim + '"] div[data-tsv] button[data-val="' + mode + '"]');
        await page.waitForTimeout(450);
      };
      const vis = id => page.evaluate(id => { const e = document.getElementById(id); return !!e && e.getClientRects().length > 0; }, id);
      // ---- markup contract, every panel the report has
      const mk = await page.evaluate(({ METRICS, UNIT, TOTU }) => {
        const root = document.getElementById('topsql'), o = { bad: [], panels: [], rankings: [] };
        const D = ((window.AWR_DATA || {}).topSql || {}).dims || {};
        const sc = [...root.children].find(c => c.tagName === 'SCRIPT' && /Values switch/.test(c.textContent));
        const firstPanel = root.querySelector('.tabpanel');
        if (!sc || !firstPanel || !(sc.compareDocumentPosition(firstPanel) & Node.DOCUMENT_POSITION_FOLLOWING)) o.bad.push('the state script does not come before the first panel (the wrong view could paint first)');
        root.querySelectorAll('.tabpanel[data-tabs="topsql"]').forEach(p => {
          const d = p.getAttribute('data-t'); o.panels.push(d);
          const sws = [...p.children].filter(c => c.matches('div.topsql-toggle.topsql-val[data-tsv]'));
          if (sws.length !== 1 || sws[0].getAttribute('data-tsv') !== d) { o.bad.push(d + ': not exactly one switch of its own'); return; }
          const sw = sws[0], bs = [...sw.querySelectorAll('button')];
          if (sw.hasAttribute('data-topsql-target') || sw.querySelector('[data-mode]')) o.bad.push(d + ': the switch carries the breakdown toggle\'s hooks');
          if (bs.map(b => b.getAttribute('data-val')).join() !== 'total,perexec,pe-rank') o.bad.push(d + ': the switch buttons are not total, perexec, pe-rank');
          if (bs.map(b => b.textContent).join('|') !== 'Total|Per execution|Top per execution') o.bad.push(d + ': the switch button labels are "' + bs.map(b => b.textContent).join('|') + '"');
          if (!/^Values:/.test(sw.textContent)) o.bad.push(d + ': the switch has no "Values:" label');
          if (bs.some(b => b.getAttribute('aria-pressed') === null || b.hasAttribute('data-mode') || b.hasAttribute('data-topsql-target'))) o.bad.push(d + ': a switch button lacks aria-pressed or carries the breakdown hooks');
          const views = [...p.children].filter(c => c.classList.contains('tsv-view'));
          const tsvIn = p.querySelectorAll('.tsv-tbl, [data-pe], span.tsv, .tsv-swap-note');
          if (!METRICS.includes(d)) {
            if (views.length) o.bad.push(d + ': a tab with no per-execution form has views');
            if (tsvIn.length) o.bad.push(d + ': carries swap markup (' + tsvIn.length + ' elements)');
            const notes = [...p.children].filter(c => c.classList.contains('tsv-note'));
            if (notes.length !== 1) o.bad.push(d + ': needs exactly one note, has ' + notes.length);
            else if (!notes[0].classList.contains(d === 'PEREXEC' ? 'tsv-n-total' : 'tsv-n-other')) o.bad.push(d + ': the note is "' + notes[0].className + '"');
            return;
          }
          if (views.map(v => v.getAttribute('data-val')).join() !== 'total,pe-rank') { o.bad.push(d + ': views are "' + views.map(v => v.getAttribute('data-val')).join() + '", expected total,pe-rank'); return; }
          if ([...p.children].some(c => c.classList.contains('tsv-note'))) o.bad.push(d + ': a metric tab carries an other-tab note');
          [['total', d], ['pe-rank', d + '_PE']].forEach(([val, dim]) => {
            const v = views.find(x => x.getAttribute('data-val') === val), t = v.querySelector('table[id^="topsql-detail-"]');
            if (!v.querySelector('h3')) o.bad.push(dim + ': the view has no heading (JS off: which ranking is it?)');
            if (!t) {
              if (val === 'total') o.bad.push(dim + ': the total view has no table');
              else if (!v.querySelector('p.note') || v.querySelector('.chart-wrap') || v.querySelector('.tsv-tbl, [data-pe]')) o.bad.push(dim + ': an empty Top per execution view needs a p.note and no chart / swap markup');
              else o.rankings.push({ dim, empty: true });
              return;
            }
            if (t.id !== 'topsql-detail-' + dim) o.bad.push(dim + ': table id ' + t.id);
            if (!v.querySelector('#topsql-chart-' + dim)) o.bad.push(dim + ': no chart container');
            if (!v.querySelector('[data-topsql-target="' + dim + '"]')) o.bad.push(dim + ': no Break down by toggle of its own');
            const th = t.querySelector('thead th[data-w="0"]');
            if (val === 'pe-rank') {
              if (!v.querySelector('p.tsv-rank-note') || !/different statement set/.test(v.querySelector('p.tsv-rank-note').textContent)) o.bad.push(dim + ': no rank note saying it is a different statement set');
              if (v.querySelector('p.tsv-swap-note')) o.bad.push(dim + ': the ranking view carries the swap note');
              if (t.classList.contains('tsv-tbl') || t.querySelector('[data-pe], span.tsv')) o.bad.push(dim + ': the ranking table carries swap markup');
              if (!t.hasAttribute('data-nocount')) o.bad.push(dim + ': the ranking table lacks data-nocount');
              if (!th || th.textContent !== 'Current (' + UNIT[d] + ')') o.bad.push(dim + ': header "' + (th && th.textContent) + '"');
            } else {
              const sn = v.querySelectorAll('p.tsv-swap-note');
              if (sn.length !== 1 || !/still picked and ordered by the window total/.test(sn[0].textContent) || !/#n badges are ranks by total/.test(sn[0].textContent) || !/dash/.test(sn[0].textContent) || !/^[\x20-\x7e]*$/.test(sn[0].textContent)) o.bad.push(dim + ': the swap note is missing or says the wrong thing');
              if (v.querySelector('p.tsv-rank-note')) o.bad.push(dim + ': the total view carries the rank note');
              if (!t.classList.contains('tsv-tbl')) o.bad.push(dim + ': the total table is not table.tsv-tbl');
              if (t.hasAttribute('data-nocount')) o.bad.push(dim + ': the total table is data-nocount');
              if (!th || th.textContent !== 'Current (' + TOTU[d] + ')' || th.getAttribute('data-pe') !== 'Current (' + UNIT[d] + ')') o.bad.push(dim + ': header "' + (th && th.textContent) + '" / data-pe "' + (th && th.getAttribute('data-pe')) + '"');
              // every value cell is span.tsv with its data-pe; a dash cell has none; titled only when the swap carries one
              const spans = t.querySelectorAll('span.tsv[data-pe]');
              if (!spans.length) o.bad.push(dim + ': no span.tsv value cell');
              if (t.querySelectorAll('span.tsv:not([data-pe])').length) o.bad.push(dim + ': a span.tsv without data-pe');
              if (t.querySelectorAll('[data-po], [data-ptm]').length) o.bad.push(dim + ': an unswapped table carries restore attributes');
              // the sync script right after the view (no flash of totals under a saved perexec)
              const nx = v.nextElementSibling;
              if (!nx || nx.tagName !== 'SCRIPT' || nx.textContent.indexOf('AWR_topsqlSync(document.getElementById("topsql-detail-' + dim + '"))') < 0) o.bad.push(dim + ': no sync script right after the total view');
            }
            o.rankings.push({ dim, rows: t.querySelectorAll('tbody tr').length, payload: !!D[dim] });
          });
        });
        // every view is a direct child of a tabpanel; the Per-SQL pool is in none of them
        root.querySelectorAll('.tsv-view').forEach(v => { if (!v.parentElement.classList.contains('tabpanel')) o.bad.push('a .tsv-view outside its tabpanel'); });
        const pool = document.getElementById('sql-pool');
        if (pool && pool.closest('.tabpanel, .tsv-view')) o.bad.push('the Per-SQL pool sits inside a panel / view (a div is unbalanced)');
        // the ranking rows: ids from anchor_id (sq-<metric>pe-<sql_id>), none reaching a sq-elapsed- prefix match
        root.querySelectorAll('table[id^="topsql-detail-"][id$="_PE"] tbody tr[id]').forEach(tr => { if (!/^sq-(elapsed|cpu|gets|preads)pe-[a-z0-9]+$/.test(tr.id)) o.bad.push('ranking row id ' + tr.id); });
        // swap markup only in the four total tables: no other table, no span.tsv outside them
        root.querySelectorAll('table[id^="topsql-detail-"]').forEach(t => {
          const d = t.id.replace('topsql-detail-', '');
          if (!METRICS.includes(d) && (t.classList.contains('tsv-tbl') || t.querySelector('[data-pe], span.tsv'))) o.bad.push(d + ': a table that is not a total metric table carries swap markup');
        });
        // payload: the four total dims carry unitPe and the parallel Pe arrays (element i = entry i), nothing else does.  One direction:
        // never a per-execution value where the total is null; a null per-execution value under a total is a window with no completed execution
        const PEKEYS = ['unitPe', 'sqlsPe', 'schemasPe', 'modulesPe', 'actionsPe'];
        o.pay = { swapDims: 0, entries: 0, nullPe: 0 };
        Object.keys(D).forEach(k => {
          const d = D[k];
          if (!METRICS.includes(k)) { PEKEYS.forEach(key => { if (key in d) o.bad.push('payload ' + k + ' carries ' + key); }); return; }
          o.pay.swapDims++;
          if (d.unitPe !== UNIT[k]) o.bad.push('payload ' + k + '.unitPe is "' + d.unitPe + '"');
          ['sqls', 'schemas', 'modules', 'actions'].forEach(g => {
            const a = d[g] || [], b = d[g + 'Pe'];
            if (!b || b.length !== a.length) { o.bad.push('payload ' + k + '.' + g + 'Pe has ' + (b ? b.length : 'none') + ' entries, ' + g + ' has ' + a.length); return; }
            a.forEach((e, i) => {
              o.pay.entries++;
              if (!Array.isArray(b[i]) || b[i].length !== e.vals.length) o.bad.push('payload ' + k + '.' + g + '[' + i + '] length');
              else e.vals.forEach((v, j) => {
                if (v === null && b[i][j] !== null) o.bad.push('payload ' + k + '.' + g + '[' + i + '][' + j + '] has a per-execution value where the total is null');
                if (v !== null && b[i][j] === null) o.pay.nullPe++;
              });
            });
          });
        });
        return o;
      }, { METRICS, UNIT, TOTU });
      mk.bad.slice(0, 8).forEach(bad);
      if (!mk.rankings.some(r => r.dim.endsWith('_PE') && !r.empty)) console.log('top SQL values switch: no ranking of Top per execution has a row in this report (the empty view): the table checks are skipped');
      console.log('top SQL values switch: panels ' + mk.panels.join('/') + '; views ' + mk.rankings.map(r => r.dim + (r.empty ? ' (empty)' : ' ' + r.rows)).join(', ') + '; payload ' + mk.pay.swapDims + ' swap dims, ' + mk.pay.entries + ' entries with a Pe twin, ' + mk.pay.nullPe + ' null per-execution values under a total');
      const peDims = mk.rankings.filter(r => r.dim.endsWith('_PE') && !r.empty).map(r => r.dim);
      const dim = mk.panels.includes('ELAPSED') ? 'ELAPSED' : METRICS.find(d => mk.panels.includes(d));
      const other = METRICS.find(d => d !== dim && mk.panels.includes(d));
      if (!dim) { console.log('top SQL values switch: no metric panel in this report, the mode checks are skipped'); }
      else {
      // ---- default: Total, nothing saved, the switch shown, the ranking views hidden, the notes of the total mode
      let st = await state(page);
      checkState(st, 'total', 'at load');
      if (await lsGet(page) !== null) bad('localStorage ' + KEY + ' written without a click');
      const before = await snapTables(page), bB = await badges(page);
      if (!bB.rank.n) bad('no rank badge in the total tables');
      // the rows of the four total tables with their rank badges, in order: Per execution must keep exactly these
      const orderOf = () => page.evaluate(METRICS => METRICS.map(d => [...document.querySelectorAll('#topsql-detail-' + d + ' tbody tr')].map(tr => tr.id + ':' + [...tr.querySelectorAll('.badge.info, .badge.skip')].map(b => b.textContent).join('/')).join()), METRICS);
      const ordTotal = await orderOf();
      // ---- JS off (the classes the script sets removed: the CSS of a page whose script did not run): no switch, no notes, the cells read totals, both views stacked, each with a heading
      const off = await page.evaluate(() => {
        const root = document.getElementById('topsql'), disp = el => getComputedStyle(el).display;
        root.classList.remove('tsv-js', 'tsv-pe', 'tsv-rank');
        const o = { views: [], sw: 0, notes: 0, swapNotes: 0, head: [] };
        root.querySelectorAll('.tsv-view').forEach(v => o.views.push(v.getAttribute('data-val') + ':' + (disp(v) === 'none' ? 'off' : 'on') + ':' + (v.querySelector('h3') && v.querySelector('h3').textContent.trim().length > 0)));
        root.querySelectorAll('div[data-tsv]').forEach(s => { if (disp(s) !== 'none') o.sw++; });
        root.querySelectorAll('.tsv-note').forEach(n => { if (disp(n) !== 'none') o.notes++; });
        root.querySelectorAll('.tsv-swap-note').forEach(n => { if (disp(n) !== 'none') o.swapNotes++; });
        root.querySelectorAll('table.tsv-tbl thead th[data-w="0"]').forEach(th => o.head.push(th.textContent));
        root.classList.add('tsv-js');
        return o;
      });
      if (off.views.some(v => !v.startsWith('total:on:true') && !v.startsWith('pe-rank:on:true'))) bad('without the script a view is hidden or has no heading: ' + off.views.join());
      if (off.sw || off.notes || off.swapNotes) bad('without the script ' + off.sw + ' switch(es), ' + off.notes + ' note(s) and ' + off.swapNotes + ' swap note(s) still show');
      if (off.head.some(h => !/^Current \((s|gets|reads)\)$/.test(h))) bad('without the script a total table header reads ' + off.head.join(' | '));
      // ---- Per execution (the swap): click in one panel
      await clickMode(dim, 'perexec');
      if (!(await page.isVisible('.tabpanel[data-t="' + dim + '"] div[data-tsv]'))) bad('the switch is not visible in the ' + dim + ' panel');
      st = await state(page);
      checkState(st, 'perexec', 'after the click');
      if (await lsGet(page) !== 'perexec') bad('localStorage ' + KEY + ' is not "perexec" after the click');
      // the Total view's cells: headers, text from data-pe, titles from data-pt; the table really changed; the rank badges STAY (and the plan badges, and every other table's)
      const cells = await page.evaluate(({ METRICS, UNIT }) => {
        const o = { spans: 0, wrong: [], titleBad: [], dash: 0, head: {} };
        METRICS.forEach(d => {
          const th = document.querySelector('#topsql-detail-' + d + ' thead th[data-w="0"]'); o.head[d] = th ? th.textContent : null;
          document.querySelectorAll('#topsql-detail-' + d + ' .tsv').forEach(sp => {
            o.spans++;
            const pe = sp.getAttribute('data-pe');
            if (sp.textContent !== pe) o.wrong.push(d + ': "' + sp.textContent + '" vs data-pe "' + pe + '"');
            if (pe === '—') o.dash++;
            const td = sp.closest('td'), pt = sp.getAttribute('data-pt');
            if (pt !== null && td.getAttribute('title') !== pt) o.titleBad.push(d + ': title "' + td.getAttribute('title') + '" vs data-pt "' + pt + '"');
          });
        });
        return o;
      }, { METRICS, UNIT });
      METRICS.filter(d => mk.panels.includes(d)).forEach(d => { if (cells.head[d] !== 'Current (' + UNIT[d] + ')') bad(d + ' header reads "' + cells.head[d] + '", expected "Current (' + UNIT[d] + ')"'); });
      if (!cells.spans) bad('no .tsv value span in the four detail tables');
      if (cells.wrong.length) bad('a value cell does not show its per-execution text: ' + cells.wrong.slice(0, 3).join(' | '));
      if (cells.titleBad.length) bad('a cell title is not its per-execution title: ' + cells.titleBad.slice(0, 3).join(' | '));
      const mid = await snapTables(page);
      if (JSON.stringify(mid[dim]) === JSON.stringify(before[dim])) bad(dim + ' table is unchanged in per execution mode');
      const bP = await badges(page);
      if (bP.rank.n !== bB.rank.n || bP.rank.shown !== bB.rank.shown || bP.rank.shown !== bP.rank.n) bad('the #n rank badges changed in per execution mode (' + bP.rank.shown + ' of ' + bP.rank.n + ' shown, ' + bB.rank.shown + ' of ' + bB.rank.n + ' in Total): they must STAY visible');
      if (bP.plan.n !== bB.plan.n || bP.plan.shown !== bP.plan.n) bad('the plan change badges are hidden in per execution mode');
      if (bP.other.shown !== bP.other.n) bad('rank badges of the other tabs / the ranking were hidden');
      // the rows, their order and their ranks are those of the total: same ids in the same order, same badge texts
      const ordPe = await orderOf();
      if (JSON.stringify(ordPe) !== JSON.stringify(ordTotal)) bad('the statements, their order or their # ranks changed in per execution mode');
      if (!(await page.isVisible('.tabpanel[data-t="' + dim + '"] .tsv-swap-note'))) bad('the swap note is not visible in per execution mode');
      // the number is right: the Current cell vs elapsed / executions of the Compared windows table of the Per-SQL pool (same data)
      const xc = await page.evaluate(() => {
        const num = s => { const t = String(s).replace(/,/g, '').trim(); if (/^<0\.0+1$/.test(t)) return 0; const m = /^(-?\d*\.?\d+)\s*([kMG])?$/.exec(t); return m ? parseFloat(m[1]) * ({ k: 1e3, M: 1e6, G: 1e9 }[m[2]] || 1) : null; };
        const out = [];
        document.querySelectorAll('#topsql-detail-ELAPSED tbody tr[id^="sq-elapsed-"]').forEach(tr => {
          const sid = tr.id.replace('sq-elapsed-', ''), sp = tr.querySelector('td[data-w="0"] .tsv'), win = document.getElementById('win-' + sid);
          const cur = win && win.tBodies[0] && win.tBodies[0].rows[0];
          if (!sp || !cur || !cur.classList.contains('cur')) return;
          const ex = num((cur.cells[1].getAttribute('title') || cur.cells[1].textContent).replace(/ .*/, '')), el = num((cur.cells[2].getAttribute('title') || cur.cells[2].textContent).replace(/ .*/, ''));
          const got = num(sp.getAttribute('data-pe'));
          if (ex > 0 && el !== null && got !== null) { const want = el / ex; out.push({ sid, want, got, ok: Math.abs(got - want) <= Math.abs(got) * 6e-4 + 5.1e-7 + 5.1e-5 / ex + 1e-9 }); }
        });
        return out;
      });
      if (xc.some(x => !x.ok)) bad('per-execution Current cell is not elapsed / executions of the Compared windows table: ' + JSON.stringify(xc.filter(x => !x.ok).slice(0, 3)));
      else console.log('top SQL values switch: per execution (swap): ' + cells.spans + ' value cells swapped (' + cells.dash + ' dash), ' + xc.length + ' Elapsed Current cells = elapsed / executions of the Compared windows table, ' + bP.rank.n + ' rank badges kept');
      // the Total view's chart (ECharts loaded): axis name, series data = the Pe array, tooltip unit and 4 significant digits; the breakdown toggle, the window highlight and the theme keep it
      const chP = await chartOf(page, dim);
      if (chP && !chP.none) {
        if (chP.yname !== UNIT[dim]) bad('chart y axis is "' + chP.yname + '" in per execution mode, expected "' + UNIT[dim] + '"');
        if (!(chP.w > 0)) bad('the Total chart is ' + chP.w + ' px wide in per execution mode');
        if (!/\/exec/.test(chP.tip || '') || !/0\.00123/.test(chP.tip || '')) bad('chart tooltip lacks the per-execution unit / 4 significant digits: ' + chP.tip);
        const want = await payloadOf(page, dim, 'sqlsPe');
        if (chP.data0 !== want) bad('chart series[0] is not sqlsPe[0]');
        const g = await page.$('.tabpanel[data-t="' + dim + '"] [data-topsql-target="' + dim + '"] button[data-mode="schemas"]');
        if (g && await g.isVisible()) {
          await g.click(); await page.waitForTimeout(300);
          const c2 = await chartOf(page, dim), w2 = await payloadOf(page, dim, 'schemasPe');
          if (c2.yname !== UNIT[dim] || c2.data0 !== w2) bad('Break down by Schema lost the per-execution values');
          await page.evaluate(() => document.dispatchEvent(new CustomEvent('awr:window', { detail: { w: 1 } }))); await page.waitForTimeout(200);
          const c3 = await chartOf(page, dim);
          if (c3.yname !== UNIT[dim] || c3.data0 !== w2) bad('the window highlight re-render lost the per-execution values');
          await page.evaluate(() => document.dispatchEvent(new CustomEvent('awr:window', { detail: null })));
          await page.evaluate(() => document.dispatchEvent(new CustomEvent('awr:theme')));
          await page.waitForTimeout(150);
          const c4 = await chartOf(page, dim);
          if (c4.yname !== UNIT[dim] || c4.data0 !== w2) bad('the theme re-style lost the per-execution values');
          const g0 = await page.$('.tabpanel[data-t="' + dim + '"] [data-topsql-target="' + dim + '"] button[data-mode="sqls"]');
          if (g0) await g0.click();
          await page.waitForTimeout(200);
          // a real theme flip, then redraws (a mode change and a Break down click): they must read the NEW colours, not those of the first paint
          const colOf = () => page.evaluate(dim => { const o = echarts.getInstanceByDom(document.getElementById('topsql-chart-' + dim)).getOption();
            return { x: ((o.xAxis[0] || {}).axisLabel || {}).color, y: ((o.yAxis[0] || {}).axisLabel || {}).color, leg: ((o.legend[0] || {}).textStyle || {}).color,
              fg: getComputedStyle(document.body).getPropertyValue('--fg').trim(), mu: getComputedStyle(document.body).getPropertyValue('--muted').trim() }; }, dim);
          const tt = await page.$('#theme-toggle');
          if (tt) {
            const c0 = await colOf();
            await tt.click(); await page.waitForTimeout(350);
            const c1 = await colOf();
            if (c1.fg === c0.fg) console.log('top SQL values switch: the theme toggle did not change --fg, the colour checks are weak');
            if (c1.x !== c1.fg || c1.leg !== c1.fg || c1.y !== c1.mu) bad('after a theme flip the chart is not on the new colours: ' + JSON.stringify(c1));
            await clickMode(dim, 'pe-rank'); await clickMode(dim, 'perexec');
            const c2 = await colOf();
            if (c2.x !== c2.fg || c2.leg !== c2.fg || c2.y !== c2.mu) bad('a mode change after a theme flip redrew the chart with the old colours: ' + JSON.stringify(c2));
            const g2 = await page.$('.tabpanel[data-t="' + dim + '"] [data-topsql-target="' + dim + '"] button[data-mode="schemas"]');
            if (g2 && await g2.isVisible()) {
              await g2.click(); await page.waitForTimeout(250);
              const c3 = await colOf();
              if (c3.x !== c3.fg || c3.leg !== c3.fg) bad('Break down by after a theme flip redrew the chart with the old colours: ' + JSON.stringify(c3));
              const g3 = await page.$('.tabpanel[data-t="' + dim + '"] [data-topsql-target="' + dim + '"] button[data-mode="sqls"]'); if (g3) await g3.click();
            }
            await tt.click(); await page.waitForTimeout(350);
            await page.evaluate(() => { try { localStorage.removeItem('awr-theme'); } catch (e) {} });
          }
        } else console.log('top SQL values switch: no Schema breakdown on ' + dim + ' in this report, that step skipped');
      } else console.log('top SQL values switch: ' + (chP ? 'no chart on ' + dim : 'ECharts not loaded') + ', the chart checks of the swap are skipped');
      // a window with no completed execution reads a dash with its reason (the demo has none: force one, then put it back)
      const zx = await page.evaluate(() => {
        const nat = [...document.querySelectorAll('#topsql table.tsv-tbl .tsv[data-pt^="no completed"]')];
        const sp = document.querySelector('#topsql table.tsv-tbl td[data-w="1"] .tsv:not([data-pt])');
        return { natural: nat.length, natBad: nat.filter(e => e.textContent !== '—' || e.closest('td').getAttribute('title') !== e.getAttribute('data-pt')).length, hasSpan: !!sp };
      });
      if (zx.natBad) bad(zx.natBad + ' of ' + zx.natural + ' no-completed-execution cells do not read a dash with their title');
      console.log('top SQL values switch: ' + zx.natural + ' no-completed-execution cell(s) in this report');
      // the other panels show the same mode (the state is shared): its Total view, its swap note
      if (other) {
        const t2 = await page.$('#tab-topsql-' + other); if (t2) await t2.click(); await page.waitForTimeout(300);
        if (!(await page.isVisible('.tabpanel[data-t="' + other + '"] .tsv-view[data-val="total"]')) || !(await page.isVisible('.tabpanel[data-t="' + other + '"] .tsv-swap-note'))) bad(other + ': its Total view / swap note is not visible after switching in ' + dim);
        const hd = await page.evaluate(d => document.querySelector('#topsql-detail-' + d + ' thead th[data-w="0"]').textContent, other);
        if (hd !== 'Current (' + UNIT[other] + ')') bad(other + ': header "' + hd + '" after switching in ' + dim);
      }
      // ---- the notes of the tabs with no per-execution form (per execution mode: Biggest change, Executions)
      const nt = await page.evaluate(() => {
        const g = d => { const p = document.querySelector('#topsql .tabpanel[data-t="' + d + '"]'), n = p && p.querySelector(':scope > .tsv-note'); return n ? { txt: n.textContent, go: [...n.querySelectorAll('button[data-tsv-goto]')].map(b => b.getAttribute('data-tsv-goto')).join(), ascii: /^[\x20-\x7e]*$/.test(n.textContent) } : null; };
        return { CHANGE: g('CHANGE'), EXEC: g('EXEC'), PEREXEC: g('PEREXEC') };
      });
      if (nt.CHANGE && (!/total elapsed/.test(nt.CHANGE.txt) || !/Per-exec regression/.test(nt.CHANGE.txt) || nt.CHANGE.go !== (st.panels.PEREXEC ? 'PEREXEC' : '') || !nt.CHANGE.ascii)) bad('the Biggest change note says the wrong thing: ' + JSON.stringify(nt.CHANGE));
      if (nt.EXEC && (!/count/.test(nt.EXEC.txt) || !/every mode/.test(nt.EXEC.txt) || !nt.EXEC.ascii)) bad('the Executions note says the wrong thing: ' + JSON.stringify(nt.EXEC));
      if (nt.PEREXEC && (!/per execution/i.test(nt.PEREXEC.txt) || !/Biggest change/.test(nt.PEREXEC.txt) || !nt.PEREXEC.ascii || (st.panels.CHANGE ? nt.PEREXEC.go !== 'CHANGE' : nt.PEREXEC.go !== ''))) bad('the Per-exec regression note says the wrong thing: ' + JSON.stringify(nt.PEREXEC));
      if (st.panels.CHANGE && nt.CHANGE) {
        await page.click('#tab-topsql-CHANGE'); await page.waitForTimeout(200);
        if (!(await page.isVisible('.tabpanel[data-t="CHANGE"] .tsv-note'))) bad('the Biggest change note is not visible in per execution mode');
        if (st.panels.PEREXEC) {
          await page.click('.tabpanel[data-t="CHANGE"] .tsv-note button[data-tsv-goto="PEREXEC"]'); await page.waitForTimeout(200);
          if (!(await page.isVisible('.tabpanel[data-t="PEREXEC"]'))) bad('the Biggest change note\'s link did not open the Per-exec regression tab');
        }
      }
      // ---- Top per execution (the separate ranking): the swap is undone in the Total view, the ranking view shows
      await clickMode(dim, 'pe-rank');
      st = await state(page);
      checkState(st, 'pe-rank', 'after the click');
      if (await lsGet(page) !== 'pe-rank') bad('localStorage ' + KEY + ' is not "pe-rank" after the click');
      const afterRank = await snapTables(page);
      METRICS.filter(d => before[d]).forEach(d => { if (JSON.stringify(afterRank[d]) !== JSON.stringify(before[d])) bad(d + ' table is not restored exactly (text and titles) in Top per execution mode'); });
      // the notes of the other tabs in this mode
      if (st.panels.CHANGE) { await page.click('#tab-topsql-CHANGE'); await page.waitForTimeout(200); if (!(await page.isVisible('.tabpanel[data-t="CHANGE"] .tsv-note'))) bad('the Biggest change note is not visible in Top per execution mode'); }
      if (st.panels.EXEC) { await page.click('#tab-topsql-EXEC'); await page.waitForTimeout(200); if (!(await page.isVisible('.tabpanel[data-t="EXEC"] .tsv-note'))) bad('the Executions note is not visible in Top per execution mode'); }
      if (st.panels.PEREXEC) { await page.click('#tab-topsql-PEREXEC'); await page.waitForTimeout(200); if (await page.isVisible('.tabpanel[data-t="PEREXEC"] .tsv-note')) bad('the Per-exec regression note is visible in Top per execution mode'); }
      const tabBtn = await page.$('#tab-topsql-' + dim);
      if (tabBtn) await tabBtn.click();
      await page.waitForTimeout(300);
      if (other) {
        const t2 = await page.$('#tab-topsql-' + other); if (t2) await t2.click(); await page.waitForTimeout(300);
        if (!(await page.isVisible('.tabpanel[data-t="' + other + '"] .tsv-view[data-val="pe-rank"]'))) bad(other + ': the Top per execution view is not visible after switching in ' + dim);
        if (tabBtn) await tabBtn.click();
        await page.waitForTimeout(300);
      }
      // ---- the ranking tables: ranks, zero executions, the numbers
      const tb = await page.evaluate((peDims) => {
        const num = s => { const t = String(s).replace(/,/g, '').trim(); if (/^<0\.0+1$/.test(t)) return 0; const m = /^(-?\d*\.?\d+)\s*([kMG])?$/.exec(t); return m ? parseFloat(m[1]) * ({ k: 1e3, M: 1e6, G: 1e9 }[m[2]] || 1) : null; };
        const cellVal = td => { const c = td.cloneNode(true); c.querySelectorAll('.badge, .d').forEach(e => e.remove()); return c.textContent.trim(); };
        const o = { rankBad: [], zeroBad: [], zeroSeen: 0, cmpBad: [], cmpN: 0, chipBad: [], cols: 0, titleBad: [] };
        peDims.forEach(dim => {
          const t = document.getElementById('topsql-detail-' + dim), nW = t.querySelectorAll('thead th[data-w]').length;
          const rows = [...t.querySelectorAll('tbody tr')];
          for (let k = 0; k < nW; k++) {
            const items = [];
            rows.forEach(tr => {
              const td = tr.querySelector('td[data-w="' + k + '"]'); if (!td) return;
              const b = td.querySelector('.badge.info, .badge.skip');
              if (b) items.push({ r: +b.textContent.replace('#', ''), v: num(cellVal(td)) });
              // a value without a rank, or a rank without a value, would be a different ranking
              else if (num(cellVal(td)) !== null) o.rankBad.push(dim + ' w' + k + ': a value with no # badge');
            });
            if (!items.length) continue;
            o.cols++;
            items.sort((a, b) => a.r - b.r);
            if (items.some((x, i) => x.r !== i + 1)) o.rankBad.push(dim + ' w' + k + ': ranks ' + items.map(x => x.r).join(',') + ' are not 1..' + items.length);
            for (let i = 1; i < items.length; i++) if (items[i].v === null || items[i - 1].v === null || items[i].v > items[i - 1].v * (1 + 1e-3) + 1e-9) o.rankBad.push(dim + ' w' + k + ': #' + items[i].r + ' (' + items[i].v + ') is above #' + items[i - 1].r + ' (' + items[i - 1].v + ')');
          }
          // the Current cell's title carries the full precision
          rows.slice(0, 3).forEach(tr => { const td = tr.querySelector('td[data-w="0"]'); if (td && num(cellVal(td)) !== null && !td.getAttribute('title')) o.titleBad.push(dim + ' ' + tr.id); });
          // a window in which the statement completed no execution is not ranked there: a dash in the ranking table
          rows.forEach(tr => {
            const sid = tr.id.replace(/^sq-[a-z]+pe-/, ''), win = document.getElementById('win-' + sid);
            if (!win || !win.tBodies[0]) return;
            [...win.tBodies[0].rows].forEach(wr => {
              const c = wr.cells[1]; if (!c || c.getAttribute('data-w') === null) return;
              const k = c.getAttribute('data-w'), ex = num((c.getAttribute('title') || c.textContent).replace(/ .*/, ''));
              if (ex === 0) {
                o.zeroSeen++;
                const td = tr.querySelector('td[data-w="' + k + '"]');
                if (td && num(cellVal(td)) !== null) o.zeroBad.push(dim + ' ' + sid + ' w' + k);
              }
            });
          });
          // the Per-SQL pool has a row for every statement of the ranking, with the P chip
          rows.forEach(tr => {
            const sid = tr.id.replace(/^sq-[a-z]+pe-/, ''), pr = document.getElementById('sql-' + sid);
            if (!pr) { o.chipBad.push(dim + ' ' + sid + ': no pool row'); return; }
            const chip = [...pr.querySelectorAll('.chip')].find(c => c.textContent === 'P');
            if (!chip || !/^in a per-execution ranking: /.test(chip.getAttribute('title') || '')) o.chipBad.push(dim + ' ' + sid + ': no P chip with its title');
          });
        });
        // Elapsed per execution, Current cell = elapsed / executions of the Compared windows table (same data, rounded to 4 significant digits / 4 decimals of a second)
        const el = document.getElementById('topsql-detail-ELAPSED_PE');
        if (el) [...el.querySelectorAll('tbody tr')].slice(0, 12).forEach(tr => {
          const sid = tr.id.replace('sq-elapsedpe-', ''), td = tr.querySelector('td[data-w="0"]'), win = document.getElementById('win-' + sid);
          const cur = win && win.tBodies[0] && win.tBodies[0].rows[0];
          if (!td || !cur || !cur.classList.contains('cur') || !tr.querySelector('td[data-w="0"] .badge.info')) return;
          const ex = num((cur.cells[1].getAttribute('title') || cur.cells[1].textContent).replace(/ .*/, '')), ela = num((cur.cells[2].getAttribute('title') || cur.cells[2].textContent).replace(/ .*/, ''));
          const got = num(cellVal(td));
          if (!(ex > 0) || ela === null || got === null) return;
          o.cmpN++;
          const want = ela / ex, tol = Math.abs(got) * 6e-4 + 5.1e-7 + 5.1e-5 / ex + 1e-9;
          if (Math.abs(got - want) > tol) o.cmpBad.push(sid + ': ' + got + ' vs ' + ela + ' / ' + ex + ' = ' + want);
        });
        return o;
      }, peDims);
      tb.rankBad.slice(0, 4).forEach(m => bad('rank order: ' + m));
      tb.zeroBad.slice(0, 4).forEach(m => bad('a window with no completed execution is ranked: ' + m));
      tb.cmpBad.slice(0, 3).forEach(m => bad('Top per execution Current cell is not elapsed / executions of the Compared windows table: ' + m));
      tb.chipBad.slice(0, 3).forEach(m => bad('Per-SQL pool: ' + m));
      tb.titleBad.slice(0, 2).forEach(m => bad('no full-precision title on a Current cell: ' + m));
      if (peDims.length) console.log('top SQL values switch: Top per execution: ' + tb.cols + ' window columns ranked 1..n, ' + tb.cmpN + ' Elapsed Current cells = elapsed / executions of the Compared windows table, ' + tb.zeroSeen + ' zero-execution windows of ranked statements (none ranked there)');
      // ---- the chart of the ranking view: drawn with a width, the per-execution unit, its own payload, 4 significant digits; the Total chart is back to totals
      const chR = await chartOf(page, dim + '_PE');
      if (!peDims.includes(dim + '_PE')) console.log('top SQL values switch: no ' + dim + ' ranking, its chart checks skipped');
      else if (!chR) console.log('top SQL values switch: ECharts not loaded, the ranking chart checks skipped');
      else {
        if (chR.none) bad(dim + '_PE has no chart');
        else {
          if (!(chR.w > 0)) bad('the ranking chart is ' + chR.w + ' px wide after the switch (a chart in a hidden view measures 0)');
          if (chR.yname !== UNIT[dim]) bad('ranking chart y axis is "' + chR.yname + '", expected "' + UNIT[dim] + '"');
          if (!chR.n) bad('the ranking chart has no series');
          if (!/\/exec/.test(chR.tip || '') || !/0\.00123/.test(chR.tip || '')) bad('ranking chart tooltip lacks the per-execution unit / 4 significant digits: ' + chR.tip);
          const want = await payloadOf(page, dim + '_PE', 'sqls');
          if (chR.data0 !== want) bad('ranking chart series[0] is not the payload of ' + dim + '_PE');
          const g = await page.$('.tabpanel[data-t="' + dim + '"] [data-topsql-target="' + dim + '_PE"] button[data-mode="schemas"]');
          if (g && await g.isVisible()) {
            await g.click(); await page.waitForTimeout(300);
            const c2 = await chartOf(page, dim + '_PE'), w2 = await payloadOf(page, dim + '_PE', 'schemas');
            if (c2.yname !== UNIT[dim] || c2.data0 !== w2) bad('Break down by Schema of the ranking view lost its own values');
            await page.evaluate(() => document.dispatchEvent(new CustomEvent('awr:window', { detail: { w: 1 } }))); await page.waitForTimeout(200);
            const c3 = await chartOf(page, dim + '_PE');
            if (c3.yname !== UNIT[dim] || c3.data0 !== w2) bad('the window highlight re-render of the ranking chart lost its values');
            await page.evaluate(() => document.dispatchEvent(new CustomEvent('awr:window', { detail: null })));
            const g0 = await page.$('.tabpanel[data-t="' + dim + '"] [data-topsql-target="' + dim + '_PE"] button[data-mode="sqls"]');
            if (g0) await g0.click();
            await page.waitForTimeout(200);
          } else console.log('top SQL values switch: no Schema breakdown on ' + dim + '_PE in this report, that step skipped');
        }
        const chTot = await chartOf(page, dim);
        if (chTot && !chTot.none) {
          if (chTot.yname !== TOTU[dim]) bad('the Total chart reads "' + chTot.yname + '" in Top per execution mode, expected the total unit "' + TOTU[dim] + '"');
          const wantT = await payloadOf(page, dim, 'sqls');
          if (chTot.data0 !== wantT) bad('the Total chart is not on the totals in Top per execution mode');
        }
      }
      // ---- links: a row of the view the mode hides is revealed through the chrome's goTo (never saved); a Total row in per execution mode changes nothing
      const sidP = await page.evaluate(() => { const r = document.querySelector('#topsql-detail-ELAPSED_PE tbody tr[id^="sq-elapsedpe-"]'); return r ? r.id : null; });
      const sidT = await page.evaluate(() => { const r = document.querySelector('#topsql-detail-ELAPSED tbody tr[id^="sq-elapsed-"]'); return r ? r.id : null; });
      if (sidT && sidP) {
        const goto = async (id) => { await page.evaluate(id => window.AWR_goTo(document.getElementById(id), false, false), id); await page.waitForTimeout(350); return page.evaluate(() => window.AWR_topsqlVal()); };
        const hashClick = async (id) => {
          await page.evaluate(id => { const a = document.createElement('a'); a.href = '#' + id; a.id = '__tsvlink'; a.textContent = 'x'; document.body.appendChild(a); }, id);
          await page.evaluate(() => document.getElementById('__tsvlink').click()); await page.waitForTimeout(400);
          await page.evaluate(() => document.getElementById('__tsvlink').remove());
          return page.evaluate(() => window.AWR_topsqlVal());
        };
        await lsClear(page);
        // in Top per execution mode (set above): a Total row needs the Total view -> Total (never saved)
        let m = await goto(sidT);
        if (m !== 'total' || !(await vis(sidT))) bad('a link to a Total row from Top per execution mode did not show it (mode ' + m + ')');
        if (await lsGet(page) !== null) bad('the reveal wrote localStorage (' + await lsGet(page) + ')');
        // in Total mode: a Total row changes nothing, a ranking row shows its view
        m = await goto(sidT);
        if (m !== 'total' || !(await vis(sidT))) bad('a link to a Total row in Total mode changed the mode (' + m + ')');
        m = await goto(sidP);
        if (m !== 'pe-rank' || !(await vis(sidP))) bad('a link to a ranking row from Total mode did not show it (mode ' + m + ')');
        if (await lsGet(page) !== null) bad('the reveal wrote localStorage (' + await lsGet(page) + ')');
        // in per execution mode (a click: saved, then cleared): a Total row stays per execution, a ranking row shows its view
        await clickMode(dim, 'perexec'); await lsClear(page);
        m = await goto(sidT);
        if (m !== 'perexec' || !(await vis(sidT))) bad('a link to a Total row from per execution mode changed the mode or did not show it (mode ' + m + ')');
        const hs = await page.evaluate(() => document.querySelector('#topsql table.tsv-tbl .tsv') && document.querySelector('#topsql table.tsv-tbl .tsv').textContent === document.querySelector('#topsql table.tsv-tbl .tsv').getAttribute('data-pe'));
        if (!hs) bad('the cells lost their per-execution text after a link to a Total row');
        m = await goto(sidP);
        if (m !== 'pe-rank' || !(await vis(sidP))) bad('a link to a ranking row from per execution mode did not show it (mode ' + m + ')');
        if (await lsGet(page) !== null) bad('the reveal wrote localStorage (' + await lsGet(page) + ')');
        // an in-page link click (the hash route) does the same
        m = await hashClick(sidT);
        if (m !== 'total') bad('an in-page link to a Total row from Top per execution mode did not switch to Total (mode ' + m + ')');
        m = await hashClick(sidP);
        if (m !== 'pe-rank') bad('an in-page link to a ranking row from Total mode did not switch to Top per execution (mode ' + m + ')');
        if (await lsGet(page) !== null) bad('an in-page link wrote localStorage (' + await lsGet(page) + ')');
      } else console.log('top SQL values switch: no Elapsed row in both rankings, the link checks skipped');
      // the link checks left a #sq-... hash: a reload with it would reveal that row (its view wins over the saved choice, by design)
      await page.evaluate(() => { try { history.replaceState(null, '', location.pathname + location.search + '#view=all'); } catch (e) {} });
      // ---- a click saves its value, for each of the three; Total from another panel restores the views, the cells and the chart exactly
      const tp = other || dim;
      for (const m of ['perexec', 'pe-rank', 'total']) {
        await clickMode(tp, m);
        if (await lsGet(page) !== m) bad('localStorage ' + KEY + ' is "' + await lsGet(page) + '" after a click on ' + LABEL[m] + ', expected "' + m + '"');
      }
      st = await state(page);
      checkState(st, 'total', 'back on Total');
      const after = await snapTables(page);
      METRICS.filter(d => before[d]).forEach(d => { if (JSON.stringify(after[d]) !== JSON.stringify(before[d])) bad(d + ' table is not restored exactly (text and titles) after Total'); });
      const bT = await badges(page);
      if (bT.rank.shown !== bB.rank.shown) bad('rank badges are not as in the first Total state');
      const chB = await chartOf(page, dim);
      if (chB && !chB.none && (chB.yname !== TOTU[dim] || chB.data0 !== (await payloadOf(page, dim, 'sqls')))) bad('the Total chart did not return to the totals (y axis "' + chB.yname + '")');
      // a synthetic zero-execution cell: the script shows a dash and the reason, and puts the original back
      if (zx.hasSpan) {
        await page.click('#tab-topsql-' + dim); await page.waitForTimeout(150);
        const z = await page.evaluate(async () => {
          const sp = document.querySelector('#topsql table.tsv-tbl td[data-w="1"] .tsv:not([data-pt])'), td = sp.closest('td');
          const o = { t0: sp.textContent, ti0: td.getAttribute('title') };
          sp.setAttribute('data-pe', '—'); sp.setAttribute('data-pt', 'no completed execution in this window');
          const clk = v => [...document.querySelectorAll('#topsql div[data-tsv] button[data-val="' + v + '"]')].find(b => b.getClientRects().length).click();
          clk('perexec'); o.t1 = sp.textContent; o.ti1 = td.getAttribute('title');
          clk('total'); o.t2 = sp.textContent; o.ti2 = td.getAttribute('title');
          sp.removeAttribute('data-pt');
          return o;
        });
        if (z.t1 !== '—' || z.ti1 !== 'no completed execution in this window') bad('a no-completed-execution cell reads "' + z.t1 + '" / title "' + z.ti1 + '"');
        if (z.t2 !== z.t0 || z.ti2 !== z.ti0) bad('a no-completed-execution cell was not restored: "' + z.t2 + '" / ' + z.ti2 + ' vs "' + z.t0 + '" / ' + z.ti0);
        await lsClear(page);
      }
      // ---- read on load: a saved "perexec" opens with the cells swapped (every panel's header, the chart per execution); "pe-rank" opens the ranking view with its chart drawn; garbage = Total
      await lsSet(page, 'perexec');
      await page.reload({ waitUntil: 'load' }); await page.waitForTimeout(1200);
      st = await state(page);
      checkState(st, 'perexec', 'perexec saved, after a reload');
      const hl = await page.evaluate(METRICS => METRICS.map(d => { const th = document.querySelector('#topsql-detail-' + d + ' thead th[data-w="0"]'); return th ? th.textContent : null; }), METRICS);
      METRICS.forEach((d, i) => { if (hl[i] !== null && hl[i] !== 'Current (' + UNIT[d] + ')') bad('a saved "perexec" left the ' + d + ' header on "' + hl[i] + '"'); });
      const unsw = await page.evaluate(() => [...document.querySelectorAll('#topsql table.tsv-tbl .tsv')].filter(sp => sp.textContent !== sp.getAttribute('data-pe')).length);
      if (unsw) bad('a saved "perexec" left ' + unsw + ' value cells on their totals after load');
      {
        const t4 = await page.$('#tab-topsql-' + dim); if (t4) await t4.click(); await page.waitForTimeout(400);
        const chL = await chartOf(page, dim);
        if (chL && !chL.none && chL.yname !== UNIT[dim]) bad('the Total chart did not draw per execution on load with "perexec" saved (y axis "' + chL.yname + '")');
      }
      await lsSet(page, 'pe-rank');
      await page.reload({ waitUntil: 'load' }); await page.waitForTimeout(1200);
      st = await state(page);
      checkState(st, 'pe-rank', 'pe-rank saved, after a reload');
      if (peDims.includes(dim + '_PE')) {
        const t4 = await page.$('#tab-topsql-' + dim); if (t4) await t4.click(); await page.waitForTimeout(500);
        const chL = await chartOf(page, dim + '_PE');
        if (chL && !chL.none && (!(chL.w > 0) || chL.yname !== UNIT[dim])) bad('the ranking chart did not draw on load with "pe-rank" saved (width ' + chL.w + ', y axis "' + chL.yname + '")');
      }
      // a shared link to a row of the view the saved choice hides wins on load and does not change what is saved; a Total row never leaves per execution
      if (sidP && sidT) {
        for (const [hash, saved, want] of [[sidP, 'total', 'pe-rank'], [sidP, 'perexec', 'pe-rank'], [sidT, 'pe-rank', 'total'], [sidT, 'perexec', 'perexec'], [sidT, 'total', 'total']]) {
          await page.evaluate(([k, v, h]) => { try { localStorage.setItem(k, v); history.replaceState(null, '', location.pathname + location.search + '#' + h); } catch (e) {} }, [KEY, saved, hash]);
          await page.reload({ waitUntil: 'load' }); await page.waitForTimeout(1500);
          const m2 = await page.evaluate(() => window.AWR_topsqlVal());
          if (m2 !== want || await lsGet(page) !== saved) bad('opening #' + hash + ' with "' + saved + '" saved gives mode ' + m2 + ' and saved "' + await lsGet(page) + '", expected ' + want + ' and "' + saved + '"');
        }
        await page.evaluate(() => { try { history.replaceState(null, '', location.pathname + location.search + '#view=all'); } catch (e) {} });
      }
      await lsSet(page, 'garbage');
      await page.reload({ waitUntil: 'load' }); await page.waitForTimeout(1200);
      st = await state(page);
      if (st.pe || st.rank || st.mode !== 'total') bad('an unknown saved value did not fall back to Total');
      await lsClear(page);
      }
    }
    if (errors.length) fail('top SQL values switch: ' + errors.slice(0, 5).join(' | '));
    await page.close();

    // phone width (390 px): the label and the three buttons wrap, every button is on screen and clickable, and the row adds no horizontal page scroll
    if (present) {
      const pg = await browser.newPage({ viewport: { width: 390, height: 844 }, colorScheme: 'light' });
      const errs = [];
      pg.on('pageerror', e => errs.push('pageerror: ' + e.message));
      pg.on('console', m => { if (m.type() === 'error') errs.push('console.error: ' + m.text()); });
      await pg.goto('file://' + file + '#view=all', { waitUntil: 'load' }); await pg.waitForTimeout(1200);
      const tabB = await pg.$('#tab-topsql-ELAPSED'); if (tabB) await tabB.click(); await pg.waitForTimeout(300);
      const ph = await pg.evaluate(() => {
        const sw = document.querySelector('#topsql .tabpanel.on div[data-tsv]') || document.querySelector('#topsql div[data-tsv]');
        if (!sw) return null;
        sw.scrollIntoView({ block: 'center' });
        const W = document.documentElement.clientWidth, bs = [...sw.querySelectorAll('button')].map(b => b.getBoundingClientRect());
        const w1 = document.documentElement.scrollWidth;
        const all = [...document.querySelectorAll('#topsql div[data-tsv]')];
        all.forEach(s => { s.dataset.dd = s.style.display; s.style.display = 'none'; });
        const w2 = document.documentElement.scrollWidth;
        all.forEach(s => { s.style.display = s.dataset.dd; delete s.dataset.dd; });
        const r = sw.getBoundingClientRect();
        return { W, n: bs.length, inside: bs.every(b => b.left >= 0 && b.right <= W + 0.5 && b.width > 0), rowInside: r.left >= 0 && r.right <= W + 0.5, rowOverflow: sw.scrollWidth > sw.clientWidth + 1,
          lines: new Set(bs.map(b => Math.round(b.top))).size, w1, w2 };
      });
      if (!ph) fail('top SQL values switch at 390 px: no switch');
      else {
        if (ph.n !== 3 || !ph.inside || !ph.rowInside || ph.rowOverflow) fail('top SQL values switch at 390 px: the three buttons do not fit (' + JSON.stringify(ph) + ')');
        if (ph.w1 > ph.w2 + 1) fail('top SQL values switch at 390 px: the switch row adds horizontal page scroll (' + ph.w1 + ' vs ' + ph.w2 + ' px without it)');
        console.log('top SQL values switch at 390 px: ' + ph.lines + ' line(s) of buttons, all inside the ' + ph.W + ' px screen, page width ' + ph.w1 + ' (' + ph.w2 + ' without the switches)');
      }
      for (const m of ['perexec', 'pe-rank', 'total']) {
        await pg.click('#topsql .tabpanel.on div[data-tsv] button[data-val="' + m + '"]'); await pg.waitForTimeout(250);
        const got = await pg.evaluate(() => window.AWR_topsqlVal());
        if (got !== m) fail('top SQL values switch at 390 px: a click on "' + m + '" gave mode ' + got);
      }
      await pg.evaluate(k => { try { localStorage.removeItem(k); } catch (e) {} }, KEY);
      if (errs.length) fail('top SQL values switch at 390 px: ' + errs.slice(0, 3).join(' | '));
      await pg.close();
    }

    // without ECharts the tables and the switch still work (the state script is not the chart script, the swap is not either)
    if (present) {
      const pg = await browser.newPage({ viewport: { width: 1440, height: 1000 } });
      const errs = [];
      pg.on('pageerror', e => errs.push('pageerror: ' + e.message));
      await pg.addInitScript(() => { try { Object.defineProperty(window, 'echarts', { get() { return undefined; }, set() {}, configurable: true }); } catch (e) {} });
      await pg.goto('file://' + file + '#view=all', { waitUntil: 'load' });
      await pg.waitForTimeout(1200);
      const r = await pg.evaluate(async (METRICS) => {
        const dim = METRICS.find(d => document.querySelector('#topsql .tabpanel[data-t="' + d + '"] > .tsv-view')) || 'ELAPSED';
        const noEc = !window.echarts, root = document.getElementById('topsql');
        const on = (d, v) => { const e = root.querySelector('.tabpanel[data-t="' + d + '"] > .tsv-view[data-val="' + v + '"]'); return e ? getComputedStyle(e).display !== 'none' : null; };
        const th = () => root.querySelector('#topsql-detail-' + dim + ' thead th[data-w="0"]').textContent;
        const clk = v => root.querySelector('.tabpanel[data-t="' + dim + '"] div[data-tsv] button[data-val="' + v + '"]').click();
        const out = { noEc, dim, t0: [on(dim, 'total'), on(dim, 'pe-rank'), th()] };
        clk('perexec'); const sp = root.querySelector('#topsql-detail-' + dim + ' .tsv');
        out.t1 = [on(dim, 'total'), on(dim, 'pe-rank'), th(), !!sp && sp.textContent === sp.getAttribute('data-pe')];
        clk('pe-rank'); out.t2 = [on(dim, 'total'), on(dim, 'pe-rank'), th()];
        clk('total'); out.t3 = [on(dim, 'total'), on(dim, 'pe-rank'), th()];
        try { localStorage.removeItem('awr-topsql-val'); } catch (e) {}
        return out;
      }, METRICS);
      const u = { ELAPSED: 's/exec', CPU: 's/exec', GETS: 'gets/exec', PREADS: 'reads/exec' };
      const tu = { ELAPSED: 's', CPU: 's', GETS: 'gets', PREADS: 'reads' };
      const dk = r.dim || 'ELAPSED';
      if (!r.noEc) console.log('top SQL values switch: could not hide ECharts, offline check skipped');
      else if (r.t0.slice(0, 2).join() !== 'true,false' || r.t1.slice(0, 2).join() !== 'true,false' || r.t1[2] !== 'Current (' + u[dk] + ')' || !r.t1[3]
        || r.t2.slice(0, 2).join() !== 'false,true' || r.t2[2] !== 'Current (' + tu[dk] + ')' || r.t3.slice(0, 2).join() !== 'true,false' || r.t3[2] !== r.t0[2]) fail('top SQL values switch without ECharts: ' + JSON.stringify(r));
      else console.log('top SQL values switch: works without ECharts');
      if (errs.length) fail('top SQL values switch without ECharts: ' + errs.slice(0, 3).join(' | '));
      await pg.close();
    }
  }

  await browser.close();
  if (failures.length) { console.log('FAILURES:'); failures.forEach(f => console.log('  ' + f)); }
  else console.log('verify: OK');
  process.exit(failures.length ? 1 : 0);
})();
