#!/usr/bin/env node
/*
 * Headless smoke test for a generated report (demo or real).
 *
 *   node demo/verify_report.js docs/examples/demo_busy_db.html [shots_dir]
 *
 * Loads the file in Chromium, then reports: page/console errors, the
 * number of ECharts instances that rendered, sections present, the
 * rail toggles (theme / essential / app-only / triage) actually flipping
 * the body classes, click-to-sort + tab switching working, and writes
 * full-page screenshots (light + dark) when shots_dir is given.
 * Exit code 1 on any page error or console error.
 */
const path = require('path');
const fs = require('fs');
const { chromium } = require('/opt/node22/lib/node_modules/playwright');

(async () => {
  const file = path.resolve(process.argv[2] || 'docs/examples/demo_busy_db.html');
  const shots = process.argv[3] ? path.resolve(process.argv[3]) : null;
  if (shots) fs.mkdirSync(shots, { recursive: true });
  const browser = await chromium.launch({ executablePath: '/opt/pw-browsers/chromium' }).catch(() => chromium.launch());
  const page = await browser.newPage({ viewport: { width: 1440, height: 1000 } });
  const errors = [];
  const warnings = [];
  page.on('pageerror', e => errors.push('pageerror: ' + e.message));
  page.on('console', m => {
    if (m.type() === 'error') errors.push('console.error: ' + m.text());
    else if (m.type() === 'warning') warnings.push(m.text());
  });
  await page.goto('file://' + file, { waitUntil: 'load' });
  await page.waitForTimeout(1500);

  const info = await page.evaluate(() => {
    const sections = [...document.querySelectorAll('main > section, body > section')].map(s => s.id);
    let charts = 0;
    if (window.echarts) {
      document.querySelectorAll('div, .mini, .windows-chart').forEach(el => { if (echarts.getInstanceByDom(el)) charts++; });
    }
    const sparks = document.querySelectorAll('svg.spark, [data-spark] svg').length;
    const tables = document.querySelectorAll('table').length;
    const rows = document.querySelectorAll('tbody tr').length;
    const narrative = !!document.querySelector('#narrative-slot .narr');
    const verdict = (document.querySelector('header.report .verdict') || {}).textContent || '';
    const nav = [...document.querySelectorAll('nav.toc a')].map(a => a.getAttribute('href'));
    const markers = (window.AWR_MARKERS || []).length;
    const noCharts = document.body.classList.contains('no-charts');
    return { sections, charts, sparks, tables, rows, narrative, verdict: verdict.replace(/\s+/g, ' ').trim().slice(0, 300), nav, markers, noCharts };
  });
  console.log(JSON.stringify(info, null, 1));

  // toggles
  const toggles = {};
  for (const [id, cls] of [['#essential-toggle', 'essential'], ['#app-filter-toggle', 'app-only'], ['#triage-toggle', 'triage']]) {
    const el = await page.$(id);
    if (!el) { toggles[id] = 'MISSING'; continue; }
    await el.click();
    await page.waitForTimeout(200);
    const on = await page.evaluate(c => document.body.classList.contains(c), cls);
    await el.click();
    await page.waitForTimeout(200);
    const off = await page.evaluate(c => document.body.classList.contains(c), cls);
    toggles[id] = on && !off ? 'ok' : `FAIL on=${on} off=${off}`;
  }
  // theme toggle: any button whose id/class mentions theme
  const theme = await page.$('#theme-toggle, .theme-icon-btn, [data-theme-toggle], #themeToggle');
  if (theme) {
    await theme.click(); await page.waitForTimeout(400);
    const dark = await page.evaluate(() => document.body.classList.contains('dark'));
    toggles.theme = dark ? 'ok' : 'FAIL';
    if (shots) await page.screenshot({ path: path.join(shots, 'dark.png'), fullPage: true });
    await theme.click(); await page.waitForTimeout(300);
  } else toggles.theme = 'MISSING';
  // tabs
  const tab = await page.$('.tabs [data-t]:nth-child(2)');
  if (tab) {
    await tab.click(); await page.waitForTimeout(200);
    toggles.tabs = await page.evaluate(() => {
      const t = document.querySelector('.tabs [data-t]:nth-child(2)');
      const g = t.closest('.tabs').getAttribute('data-tabs');
      const p = document.querySelector(`.tabpanel[data-tabs="${g}"][data-t="${t.getAttribute('data-t')}"]`);
      return p && getComputedStyle(p).display !== 'none' ? 'ok' : 'FAIL';
    });
  } else toggles.tabs = 'none';
  // sort a header
  const th = await page.$('table:not([data-nosort]) thead th.num');
  if (th) { await th.click(); await page.waitForTimeout(200); toggles.sort = 'clicked'; }
  // expander
  const exp = await page.$('.expander');
  if (exp) { await exp.click(); await page.waitForTimeout(200); toggles.expander = 'clicked'; }
  console.log('toggles', JSON.stringify(toggles));

  if (shots) {
    await page.screenshot({ path: path.join(shots, 'light.png'), fullPage: true });
    // masthead + overview crop
    await page.screenshot({ path: path.join(shots, 'top.png'), clip: { x: 0, y: 0, width: 1440, height: 1000 } });
  }
  if (warnings.length) console.log('warnings:', warnings.slice(0, 10));
  if (errors.length) { console.log('ERRORS:'); errors.slice(0, 30).forEach(e => console.log('  ' + e)); }
  await browser.close();
  process.exit(errors.length ? 1 : 0);
})();
