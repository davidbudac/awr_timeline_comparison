"""
Shared core of the two wait-event sections (sql/04_waits_fg.sql and
sql/05_waits_bg.sql).  Both SQL emitters share the same
pairs -> bounds -> deltas -> ranked -> top_n_events -> grid shape, the
same ECharts stacked-bar script and the same two per-event tables; the
few places they differ (headings, chart-class ordering, the FG-only
wait-class rollup table) are parameters / extra calls in s04 / s05.

Not a section itself (no emit()).
"""
from __future__ import annotations

from datetime import timedelta

from awrdemo import helpers as h

PALETTE = ('["#2563eb","#a855f7","#14b8a6","#f59e0b","#ef4444","#ec4899","#6366f1",'
           '"#84cc16","#f97316","#0ea5e9","#d946ef","#64748b"]')


# ---------------------------------------------------------------------
# deltas per window: {event: (wait_class, total_waits, time_waited_us)}
# ---------------------------------------------------------------------

def window_deltas(w, getter, other_for_null_class=False):
    """[dict-or-None] indexed by week_offset: the non-Idle event deltas of
    each VALID window (None = skipped window -> no `deltas` rows at all,
    i.e. NULL measures in the SQL's grid)."""
    out = []
    for win in w.windows:
        m = w.window_metrics(win)
        if m is None:
            out.append(None)
            continue
        d = {}
        for ev, (cls, waits, us) in getter(m).items():
            cls = cls or ("Other" if other_for_null_class else None)
            if cls == "Idle":
                continue
            d[ev] = (cls, float(waits), float(us))
        out.append(d)
    return out


def _rank_desc(vals):
    """Oracle RANK() OVER (ORDER BY v DESC): 1 + number of strictly greater."""
    return {k: 1 + sum(1 for x in vals.values() if x > v) for k, v in vals.items()}


def event_rows(w, deltas):
    """The v_evts collection: one record per event that ranked <= top_n
    (time_waited_us > 0) in ANY window, in the SQL's ORDER BY."""
    n_win = len(deltas)
    ranks = []                       # per window: {event: rnk} for the top_n
    for d in deltas:
        if not d:
            ranks.append({})
            continue
        pos = {ev: t[2] for ev, t in d.items() if t[2] > 0}
        r = _rank_desc(pos)
        ranks.append({ev: rk for ev, rk in r.items() if rk <= w.top_n})
    events = {}
    for k in range(n_win):
        for ev in ranks[k]:
            events[ev] = deltas[k][ev][0]
    rows = []
    for ev, cls in events.items():
        us = [None] * n_win
        waits = [None] * n_win
        rnk = [None] * n_win
        for k in range(n_win):
            d = deltas[k]
            if d is not None and ev in d:
                us[k] = d[ev][2]
                waits[k] = d[ev][1]
            rnk[k] = ranks[k].get(ev)

        def ms(k):
            if us[k] is None or not waits[k]:
                return None
            return us[k] / waits[k] / 1000

        cur_us = us[0]
        cur_ms = ms(0)
        cur_rnk = rnk[0]
        prior_us = [us[k] for k in range(1, n_win)]
        prior_ms = [ms(k) for k in range(1, n_win) if us[k] is not None]
        mu_us, sd_us, n_us = h.mean_sd(prior_us)
        mu_ms, sd_ms, n_ms = h.mean_sd(prior_ms)
        sec = [None if v is None else v / 1e6 for v in us]
        msv = [ms(k) for k in range(n_win)]
        rows.append({
            "event_name": ev, "wait_class": cls,
            "cur_us": cur_us, "cur_ms": cur_ms, "cur_rnk": cur_rnk,
            "mu_us": mu_us, "sd_us": sd_us, "n_us": n_us,
            "mu_ms": mu_ms, "sd_ms": sd_ms, "n_ms": n_ms,
            "spark_vals": h.csv_num6(reversed(sec)),
            "spark_ms_vals": h.csv_num6(reversed(msv)),
            "week_us_vals": h.csv_num6(sec),
            "week_ms_vals": h.csv_num6(msv),
            "week_rnk_vals": ",".join("" if r is None else str(r) for r in rnk),
            "max_us": max(v for v in us if v is not None),
        })
    rows.sort(key=lambda r: (0 if r["cur_rnk"] is not None else 1,
                             r["cur_rnk"] if r["cur_rnk"] is not None else 0,
                             -r["max_us"]))
    return rows


# ---------------------------------------------------------------------
# chart payload
# ---------------------------------------------------------------------

def weeks_json(w):
    labels = []
    for k in range(w.weeks_back, -1, -1):
        labels.append('"' + h.mon_dd(w.target_end - timedelta(hours=w.step_hours * k)) + '"')
    return "[" + ",".join(labels) + "]"


def class_json(w, class_grid, order_key):
    """class_grid: {wait_class: [us-or-None per week_offset]} (already
    filtered to the SQL's `classes`); vals CSV oldest -> newest with the
    literal null token; HAVING SUM(NVL(..,0)) > 0."""
    items = [(cls, vals) for cls, vals in class_grid.items()
             if sum(v or 0 for v in vals) > 0]
    items.sort(key=lambda cv: (order_key(cv[1]), cv[0]))
    parts = []
    for cls, vals in items:
        csv = ",".join("null" if v is None else h.num6(v / 1e6) for v in reversed(vals))
        parts.append('{"name":"' + cls.replace('"', '\\"') + '","vals":[' + csv + "]}")
    return ",".join(parts)


def desc_nulls_last(v):
    return (1, 0) if v is None else (0, -v)


def chart_script(var, el_id, weeks, classes):
    L = []
    L.append("<script>")
    L.append("(function(){")
    L.append("AWR_DATA." + var + " = {weeks:" + weeks + ",classes:[" + classes + "]};")
    L.append("if(!window.echarts) return;")
    L.append('var el=document.getElementById("' + el_id + '"); if(!el) return;')
    L.append("var d=AWR_DATA." + var + ", palette=" + PALETTE + ";")
    L.append("var cs=getComputedStyle(document.body);")
    L.append('var fg=cs.getPropertyValue("--fg").trim()||"#333";')
    L.append('var mu=cs.getPropertyValue("--muted").trim()||"#888";')
    L.append('var gr=cs.getPropertyValue("--border").trim()||"#e0e0e0";')
    L.append("var chart=echarts.init(el);")
    L.append("chart.setOption({")
    L.append('  tooltip:{trigger:"axis",axisPointer:{type:"shadow"},valueFormatter:function(v){return v==null?"\\u2014":(+v).toFixed(2)+"s";}},')
    L.append("  legend:{bottom:0,textStyle:{color:fg,fontSize:11},itemWidth:12,itemHeight:8},")
    L.append("  grid:{left:60,right:16,top:10,bottom:42,containLabel:true},")
    L.append('  xAxis:{type:"value",axisLabel:{color:mu,formatter:"{value}s"},splitLine:{lineStyle:{color:gr}}},')
    L.append('  yAxis:{type:"category",data:d.weeks,axisLabel:{color:fg,fontWeight:600}},')
    L.append('  series:d.classes.map(function(c,i){var color=(window.AWR_WAIT_COLORS||{})[c.name]||palette[i%palette.length];return {name:c.name,type:"bar",stack:"total",barWidth:"55%",emphasis:{focus:"series"},itemStyle:{color:color},data:c.vals.map(function(v){return v==null?0:v;})};})')
    L.append("});")
    L.append("new ResizeObserver(function(){chart.resize();}).observe(el);")
    L.append('document.addEventListener("awr:theme",function(){var c2=getComputedStyle(document.body),fg2=c2.getPropertyValue("--fg").trim()||"#333",mu2=c2.getPropertyValue("--muted").trim()||"#888",gr2=c2.getPropertyValue("--border").trim()||"#e0e0e0";')
    L.append('chart.setOption({legend:{textStyle:{color:fg2}},xAxis:{axisLabel:{color:mu2},splitLine:{lineStyle:{color:gr2}}},yAxis:{axisLabel:{color:fg2}}});});')
    L.append('document.addEventListener("awr:window",function(e){')
    L.append("  var w=e.detail?e.detail.w:null, n=d.weeks.length;")
    L.append('  chart.dispatchAction({type:"downplay"});')
    L.append("  if(w===null||w===undefined||!n) return;")
    L.append('  chart.dispatchAction({type:"highlight",dataIndex:n-1-w});')
    L.append("});")
    L.append("})();")
    L.append("</script>")
    return L


# ---------------------------------------------------------------------
# tables
# ---------------------------------------------------------------------

def nth_csv(csv, k):
    """nth_csv(p_csv, k): 1-based INSTR token walk keeping empty tokens."""
    toks = csv.split(",")
    return toks[k - 1] if 1 <= k <= len(toks) else ""


def header(w, first_th, unit, with_trend=True):
    s = "<thead><tr>" + first_th
    if with_trend:
        s += '<th class="trend">Trend</th>'
    s += '<th class="num" data-w="0">Current (' + unit + ")</th>"
    for k in range(1, w.weeks_back + 1):
        s += ('<th class="num" data-w="' + str(k) + '">&minus;'
              + w.offset_labels[k - 1] + " (" + unit + ")</th>")
    s += '<th>Change</th><th class="num">z-score</th><th class="num">% &Delta;</th></tr></thead>'
    return s


def table_time(w, rows, table_id, heading):
    L = ["<h3>" + heading + "</h3>",
         '<table id="' + table_id + '">' + header(w, "<th>Event</th>", "s") + "<tbody>"]
    for r in rows:
        cur_s = None if r["cur_us"] is None else r["cur_us"] / 1e6
        row = ('<tr data-imp="' + h.is_essential("WAIT", r["event_name"]) + '">'
               + "<td>" + h.esc(r["event_name"]) + "</td>"
               + '<td class="trend" data-spark="' + r["spark_vals"]
               + '" data-spark-title="' + h.esc(r["event_name"]) + '"></td>'
               + '<td class="num" data-w="0"' + h.fmt_num_title(cur_s) + "><b>" + h.fmt_num(cur_s)
               + (' <span class="badge info">#' + str(r["cur_rnk"]) + "</span>"
                  if r["cur_rnk"] is not None else "")
               + "</b></td>")
        for k in range(1, w.weeks_back + 1):
            us_s = nth_csv(r["week_us_vals"], k + 1)
            rank_s = nth_csv(r["week_rnk_vals"], k + 1)
            if us_s == "":
                row += '<td class="num" data-w="' + str(k) + '">&mdash;'
            else:
                us = float(us_s)
                row += ('<td class="num" data-w="' + str(k) + '"' + h.dev_attr(cur_s, us) + ">"
                        + h.fmt_num(us))
            if rank_s != "":
                row += ' <span class="badge skip">#' + rank_s + "</span>"
            row += "</td>"
        row += h.score_cells(r["cur_us"], r["mu_us"], r["sd_us"], r["n_us"])
        row += "</tr>"
        L.append(row)
    L.append("</tbody></table>")
    return L


def table_avg(w, rows, table_id, heading):
    L = ["<h3>" + heading + "</h3>",
         '<table id="' + table_id + '">' + header(w, "<th>Event</th>", "ms") + "<tbody>"]
    for r in rows:
        row = ('<tr data-imp="' + h.is_essential("WAIT", r["event_name"]) + '">'
               + "<td>" + h.esc(r["event_name"]) + "</td>"
               + '<td class="trend" data-spark="' + r["spark_ms_vals"]
               + '" data-spark-title="' + h.esc(r["event_name"]) + '"></td>'
               + '<td class="num" data-w="0"' + h.fmt_num_title(r["cur_ms"]) + "><b>"
               + h.fmt_num(r["cur_ms"]) + "</b></td>")
        for k in range(1, w.weeks_back + 1):
            ms_s = nth_csv(r["week_ms_vals"], k + 1)
            if ms_s == "":
                row += '<td class="num" data-w="' + str(k) + '">&mdash;</td>'
            else:
                ms = float(ms_s)
                row += ('<td class="num" data-w="' + str(k) + '"' + h.dev_attr(r["cur_ms"], ms) + ">"
                        + h.fmt_num(ms) + "</td>")
        row += h.score_cells(r["cur_ms"], r["mu_ms"], r["sd_ms"], r["n_ms"])
        row += "</tr>"
        L.append(row)
    L.append("</tbody></table>")
    return L
