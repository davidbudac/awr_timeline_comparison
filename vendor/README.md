# vendor/

Third-party assets bundled with this repo so the report can render charts
**fully offline** — no CDN, no internet — out of a fresh clone.

## echarts.min.js

- **What:** Apache ECharts, the charting library the HTML report uses for its
  larger charts (hero strip, wait-class bars, findings heatmap, top-SQL bump
  chart, ASH timeline). Sparklines and marker lines are inline SVG/JS and do
  **not** depend on it.
- **Version:** 5.6.0 (pinned).
- **License:** Apache License 2.0. The full license text is in
  [`echarts-LICENSE.txt`](echarts-LICENSE.txt) and the attribution NOTICE in
  [`echarts-NOTICE.txt`](echarts-NOTICE.txt); the minified file also carries the
  Apache banner in its first comment. Redistribution here complies with
  Apache-2.0 §4 (license + NOTICE retained, banner intact, file unmodified).
- **Source:** `https://cdn.jsdelivr.net/npm/echarts@5.6.0/dist/echarts.min.js`
  (unmodified).

### Using it

Point the `echarts` var at this file; the shell wrapper inlines its bytes into
the finished report for a single self-contained HTML file:

```bash
ECHARTS=vendor/echarts.min.js ./run_awr_trend.sh user/pw@svc
```

Leaving `echarts` empty keeps the default public CDN (smaller report, needs
network). See the `echarts` section in `CHEATSHEET.md` / `CLAUDE.md` for the
full behaviour matrix.

### Updating the pinned version

```bash
ver=5.6.0   # bump as needed
curl -fsSL "https://cdn.jsdelivr.net/npm/echarts@${ver}/dist/echarts.min.js" -o vendor/echarts.min.js
curl -fsSL "https://cdn.jsdelivr.net/npm/echarts@${ver}/LICENSE"             -o vendor/echarts-LICENSE.txt
curl -fsSL "https://cdn.jsdelivr.net/npm/echarts@${ver}/NOTICE"              -o vendor/echarts-NOTICE.txt
```

Then update the version number above. Keep the report's CDN URL (in
`awr_trend.sql`) on the same major (`echarts@5`) so the default and the
vendored copy stay API-compatible.
