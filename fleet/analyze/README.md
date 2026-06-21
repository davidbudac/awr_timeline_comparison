# analyze/ — the headless analyzer + notifier

**Implemented and validated on live 19c.**

- **`awrw_score.sql`** — the single numeric source of truth for the z-score model
  (`zscore` / `pct` / `bucket`), DETERMINISTIC and SQL-callable. De-duplicates the
  formula currently copied in `sql/lib/score_cells.plsql` (HTML) and inline in
  `sql/07_summary.sql` / `sql/08_overview.sql`.

- **`awrw_analyze.pks/.pkb`** — scores each unscored Period once (per-Target
  analysis high-water mark). `score_period` runs all three Detectors over one
  Period in one transaction, sharing a single window derivation: the pipelined
  **`windows()`** function (begin/end pairing + restart / DBID-straddle
  invalidation), the warehouse equivalent of the report's `windows_cte.sql`,
  SQL-callable via `TABLE(awrw_analyze.windows(...))`. Scoped to a Target by its
  DBID set; seasonality cadence is `profile.step_days` (7 = same hour-of-week).
  - **SEASONAL** — section 07's LOAD/METRIC/WAIT z-score recompute, gated by the
    Metric Profile (abs floor, pct floor, polarity) → `AWRW_FINDINGS`
    (`subject_type='metric'`) + `AWRW_ALERT_STATE` (edge + hysteresis).
  - **REGRESSION** — the top SQL / wait event / segment movers whose current
    Period impact regressed vs their own Baseline (`cur > mu`, `|z|` breach,
    above a per-domain floor), ranked by impact, capped at `profile.reg_top_n`.
    SQL plan flips (dominant plan differs from a prior window) are flagged in
    `plan_changed`. Findings carry `impact` and `subject_type` in
    (`sql`,`wait`,`segment`); each drives Alert State, with a clear sweep so a
    subject that stops regressing clears.
  - **HEADLINE** — the marquee hero-six (the `headline='Y'` Profile rows) as an
    executive snapshot: a CRITICAL/WARN Finding per marquee metric
    (`subject_type='headline'`), ungated. Informational — it does not drive Alert
    State (seasonal already owns those metrics' firing lifecycle).
  - `score_period(target_id, period_end)` — one Period (all Detectors).
  - `analyze_target(target_id)` — march the analysis HWM to the latest hour.
  - `analyze_all` — every enabled Target.

- **`awrw_notify.sql`** — `build_digest` renders the read-only HTML fleet Digest
  (interesting Targets with subject type + plan-flip badge / headline movers /
  recovered / coverage) from Alert State + Findings + Target Health;
  `mark_notified` stamps what a Digest carried.

## Still to build

- **Delivery** — UTL_SMTP/UTL_MAIL or external mailer; DBMS_SCHEDULER jobs for
  collect → analyze → notify.

See [`../../docs/fleet-architecture.md`](../../docs/fleet-architecture.md) and
[`../../CONTEXT.md`](../../CONTEXT.md).
