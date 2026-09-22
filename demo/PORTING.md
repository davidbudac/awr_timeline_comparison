# Porting a report section to the demo generator

The demo generator (`demo/gen_demo_report.py`) renders the same HTML the
real `awr_trend.sql` run spools, but from a synthetic in-memory model
instead of `DBA_HIST_*`.  Each `sql/NN_*.sql` section gets a Python twin
in `demo/awrdemo/sections/sNN_<name>.py` exposing:

```python
def emit(w) -> str:
    """Return the section's full text: from its
    '<!-- AWR-SECTION: NN_name BEGIN -->' line to its
    '<!-- AWR-SECTION: NN_name END -->' line (inclusive), newline-separated
    exactly like the DBMS_OUTPUT.PUT_LINE calls of the original."""
```

`w` is `awrdemo.model.World` (see that file's module docstring and the
`HourMetrics` docstring -- READ THEM FIRST).

## The one rule: mirror the SQL emitter, do not redesign

Open the original `sql/NN_*.sql` and walk its `DBMS_OUTPUT.PUT_LINE`
calls top to bottom.  Reproduce every element, attribute, class, id,
`data-*` hook, inline `<script>`, `<p>` caption, and `AWR_DATA.<x>` JSON
payload with the same names and the same shape.  The page chrome
(`sql/_style.sql` CSS, `sql/00_params.sql` JS) selects on those hooks
(`data-w`, `data-imp`, `data-sys`, `data-spark`, `data-tail`,
`data-nosort`, `.tabs[data-tabs]`, `id="..."` anchors the nav links to,
etc.), so a missing hook silently breaks a toggle, a sort, a chart, or a
count pill.

* Copy JavaScript verbatim.  `awrdemo.chrome.put_lines(path)` returns
  every PUT_LINE's literal text (with `''` unescaped) in order, flagged
  `literal_only=False` when the call also had a dynamic part -- use it
  to lift long `<script>` stretches instead of retyping them, and port
  only the dynamic calls by hand.  Substitution vars (`~weeks_back`,
  `~target_end_resolved`, ...) map to `World` attributes.
* Number strings must be Oracle-faithful: use `awrdemo.helpers`
  (`fmt_num`, `fmt_int`, `fmt_num_title`, `score_cells`, `dev_attr`,
  `num6`, `to_char_fixed/trim`, `z_txt`, `pct_txt`, `esc` =
  `DBMS_XMLGEN.CONVERT`, `json_escape`, `is_essential`,
  `is_oracle_schema`, date masks `ts_min/ts_sec/ts_dy_min/mon_dd/...`).
  Add a helper there only if it is a twin of something in `sql/lib/`.
* Scoring: `helpers.mean_sd` (Oracle STDDEV = sample sd, NULL for n<2)
  + `z_and_pct` + `bucket_of` reproduce every section's z/bucket CASE.
  Priors are the VALID prior windows only (`w.valid_windows`, offset > 0).
* Positional CSVs: `LISTAGG(','||token)` keeps empty slots for NULLs;
  emit `''` for a missing window in `data-spark`, the literal `null`
  where the SQL used `THEN 'null'`.  Oldest -> newest unless the SQL's
  ORDER BY says otherwise (read it -- 02 uses DESC for spark_vals and ASC
  for week_vals).
* Every ECharts init in the SQL reads CSS vars, registers an `awr:theme`
  listener, and often an `awr:window` one -- copy those blocks verbatim.
* Where the SQL emits nothing (a `CASE ... ELSE ''`, a section that is
  silent at a default), emit nothing.  Where it renders "no data" prose,
  render that prose only if the model really has no data -- the demo DB
  is busy, so almost every section has data.

## The model

`w.windows` (13 windows, `week_offset` 0..12, all valid on this demo),
`w.window_metrics(win)` -> `HourMetrics` for one window (1 h),
`w.hours(start, end)` -> `[HourMetrics]` for a time-range scan (09/10/
masthead/day-profile), `w.hour(ts)` -> the interval ending at `ts`,
`w.snaps` / `w.snap_at(ts)` -> `dba_hist_snapshot` rows.  Catalogs:
`w.sqls` / `w.sql_by_id` (text, schema, module, action), `w.fg_events`,
`w.bg_events`, `w.segments`, `w.files`, `w.filetypes`, `w.param_changes`
+ `w.param_value(name, ts)`, `w.monexecs()` (SQL Monitor reports).
Run params: `w.weeks_back`,
`w.win_hours`, `w.step_hours`, `w.top_n`, `w.target_end`,
`w.offset_labels` (list, index k-1 = `REGEXP_SUBSTR('~offset_labels',
'[^,]+', 1, k)`), `w.period_axis_fmt` = `'Mon DD'` (-> `helpers.mon_dd`),
`w.period_unit_title` = `'Week'`, `w.bucket_hours` = 1, `w.markers`.

Per-hour quantities are TOTALS for the hour (deltas); `/ m.dur_sec`
gives the per-second rate the sections print.  `DB time` / `DB CPU` in
`m.load` are centiseconds (like `DBA_HIST_SYSSTAT`); `m.time_model` is
microseconds (like `DBA_HIST_SYS_TIME_MODEL`); wait `time_waited_us` is
microseconds (`DBA_HIST_SYSTEM_EVENT.time_waited_micro` delta).

Do NOT edit `model.py` / `helpers.py` / `chrome.py` / `gen_demo_report.py`
(other agents are working against them concurrently).  If the model
genuinely lacks something your section needs, derive it locally in your
section module from what is there (use `w.rng(<stable key>)` for any
randomness so output is deterministic), and say so in your final report.

## Checking your work

```sh
cd demo && python3 gen_demo_report.py --only=NN_name /tmp/x.html   # your section only
python3 - <<'EOF'
import sys; sys.path.insert(0,'.')
from awrdemo.model import world; from awrdemo.sections import sNN_name as s
html = s.emit(world()); print(len(html)); print(html[:3000])
EOF
```

Then compare the tag/attribute vocabulary of your output against the
original SQL (`grep -o 'class="[^"]*"' ... | sort -u`, ids, data-*),
and validate the HTML nests (no unclosed `<tr>`/`<table>`/`<section>`).
JSON payloads must parse (`json.loads` on the emitted literal).  Long
sections: keep the number of rows realistic (top_n = 10, 13 windows).
