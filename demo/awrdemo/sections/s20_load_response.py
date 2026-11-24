"""Twin of sql/20_load_response.sql (Load vs response time).

The scatter's points come from the model's hourly SYSMETRIC values
(w.hours over the full span), the window dots from w.window_metrics, so
the demo reads "load is normal, each call slower" after Release 4.2.
The model carries no 'Database Time Per Sec' SYSMETRIC: it is derived
here as the time model's DB time (centiseconds) per second of the
interval, the unit SYSMETRIC reports.  Single instance: the SUM / AVG
roll-up across instances is a no-op.  Mirrors the SQL's PUT_LINEs in
order; the arithmetic (bins, medians, two-pass sd, the verdict) is the
PL/SQL's, line for line."""
from __future__ import annotations

import math
from datetime import timedelta

from awrdemo import chrome
from awrdemo.sections.s10_db_time_summary import put_clob_chunked
from awrdemo.helpers import (anchor_id, band_z, band_ztxt, delta_span, esc, fmt_num,
                             json_escape, lib_ls, ora_round, policy_bucket, range_txt,
                             to_char_fixed, to_char_trim, wg_date, wg_off, wg_title)


# ---- the PL/SQL helper functions ------------------------------------------
def jn(v):
    if v is None:
        return "null"
    return to_char_trim(ora_round(v, 3), 3)


def lr_xi(p):
    return p % 3


def lr_yi(p):
    return p // 3


def lr_xv(p, m):
    v = m[lr_xi(p)]
    if v is None or v <= 0:
        return None
    return v


def lr_yv(p, m):
    x = lr_xv(p, m)
    if x is None:
        return None
    if lr_yi(p) == 0:
        return m[3]
    if m[4] is None:
        return None
    return m[4] * 10 / x * (1000 if lr_xi(p) == 2 else 1)


XNAME = ("User Calls Per Sec", "Executions Per Sec", "Logical Reads Per Sec")
XLAB = ("User calls per second", "Executions per second", "Logical reads per second")
XUNIT = ("calls/s", "executions/s", "logical reads/s")


def lr_noun(p):
    if lr_yi(p) == 0:
        return "call"
    return ("call", "execution", "logical read")[lr_xi(p)]


def lr_yunit(p):
    if lr_yi(p) == 0:
        return "ms per call"
    return ("ms per call", "ms per execution", "ms per 1,000 logical reads")[lr_xi(p)]


def lr_ylab(p):
    if lr_yi(p) == 0:
        return "SQL service response time (ms per call)"
    return "DB time per " + ("call", "execution", "1,000 logical reads")[lr_xi(p)] + " (ms)"


def lr_q(q):
    return to_char_fixed(q, 1) + "&times;"


def lr_chg(c, m):
    if c is None or m is None or m == 0:
        return None
    if c / m >= 2:
        return lr_q(c / m)
    return ("+" if c >= m else "&minus;") + to_char_fixed(abs(c - m) / m * 100, 0) + "%"


def _pctl(sorted_vals, q):
    """PERCENTILE_CONT(q) WITHIN GROUP (ORDER BY v) (MEDIAN = 0.5)."""
    n = len(sorted_vals)
    rn = q * (n - 1)
    lo, hi = math.floor(rn), math.ceil(rn)
    if lo == hi:
        return sorted_vals[lo]
    return sorted_vals[lo] + (rn - lo) * (sorted_vals[hi] - sorted_vals[lo])


def _metrics(m):
    """[uc, ex, lr, srt ms, dbt cs/s] of one HourMetrics (or window aggregate)."""
    sm = m.sysmetric
    db_time = m.time_model.get("DB time")
    return [sm.get("User Calls Per Sec"), sm.get("Executions Per Sec"),
            sm.get("Logical Reads Per Sec"),
            None if sm.get("SQL Service Response Time") is None else sm["SQL Service Response Time"] * 10,
            None if db_time is None else db_time / 1e4 / m.dur_sec]


def _mean_sd(vals):
    """the PL/SQL's two passes: mean, then sample sd (n > 1)."""
    n = len(vals)
    mu = sd = None
    if n > 0:
        mu = sum(vals) / n
    if n > 1:
        sd = math.sqrt(math.fsum((v - mu) * (v - mu) for v in vals) / (n - 1))
    return mu, sd


def emit(w) -> str:
    out = ['<!-- AWR-SECTION: 20_load_response BEGIN -->']
    wb = w.weeks_back

    # 1. the window averages
    w_v, w_rs, w_m = {}, {}, {}
    for win in w.windows:
        k = win.week_offset
        w_v[k] = win.valid_flag
        w_rs[k] = win.skip_reason
        m = w.window_metrics(win)
        w_m[k] = _metrics(m) if m is not None else [None] * 5

    # 2. every snapshot interval of the span (restart-guarded)
    t_lo = w.span_start
    t_hi = w.target_end + timedelta(minutes=15)
    cur_win = w.windows[0]
    prev = None
    pts = []
    for s in w.snaps:
        ok = prev is not None and prev.startup_time == s.startup_time
        prev = s
        if not ok or not (t_lo < s.end_ts <= t_hi):
            continue
        cur = 1 if (cur_win.valid and cur_win.win_start_ts < s.end_ts <= cur_win.win_end_ts) else 0
        pts.append((round((s.end_ts - t_lo).total_seconds() / 60), cur, _metrics(w.hour(s.end_ts))))
    nb = len(pts)

    p_cnt = {}
    best, dflt = 0, -1
    for p in range(6):
        p_cnt[p] = sum(1 for _, _, m in pts if lr_yv(p, m) is not None)
        if p_cnt[p] > best:
            best, dflt = p_cnt[p], p

    # 3. the normal curve
    curve = {}
    if best >= 12:
        for p in range(6):
            xy = []
            for _, cur, m in pts:
                if cur != 0:
                    continue
                x = lr_xv(p, m)
                if x is None:
                    continue
                y = lr_yv(p, m)
                if y is not None:
                    xy.append((x, y))
            n = len(xy)
            if n < 12:
                continue
            xy.sort()
            nbins = min(8, n // 6)
            bins = {}
            for rn, (x, y) in enumerate(xy, start=1):
                bins.setdefault(math.floor((rn - 1) * nbins / n), []).append((x, y))
            rows = []
            for b in sorted(bins):
                xs = sorted(v[0] for v in bins[b])
                ys = sorted(v[1] for v in bins[b])
                rows.append((_pctl(xs, 0.5), _pctl(ys, 0.5), _pctl(ys, 0.25), _pctl(ys, 0.75)))
            curve[p] = rows

    def lr_exp(p, x):
        c = curve.get(p)
        if x is None or not c or len(c) < 2:
            return None
        if x <= c[0][0]:
            return c[0][1]
        if x >= c[-1][0]:
            return c[-1][1]
        for b in range(1, len(c)):
            if x <= c[b][0]:
                if c[b][0] == c[b - 1][0]:
                    return c[b][1]
                return c[b - 1][1] + (c[b][1] - c[b - 1][1]) * (x - c[b - 1][0]) / (c[b][0] - c[b - 1][0])
        return c[-1][1]

    def priors(p):
        px, py, pr = [], [], []
        for k in range(1, wb + 1):
            if w_v.get(k) == "Y":
                x, y = lr_xv(p, w_m[k]), lr_yv(p, w_m[k])
                if x is not None and y is not None:
                    px.append(x)
                    py.append(y)
                    ec = lr_exp(p, x)
                    if ec is not None and ec > 0:
                        pr.append(y / ec)
        return px, py, pr

    # 4. the verdict per pair
    p_r, p_ls, p_e = {}, {}, {}
    for p in range(6):
        p_e[p] = p_r[p] = p_ls[p] = None
        if p_cnt[p] <= 0:
            continue
        cx = cy = None
        if w_v.get(0) == "Y":
            cx, cy = lr_xv(p, w_m[0]), lr_yv(p, w_m[0])
        p_e[p] = lr_exp(p, cx)
        px, py, pr = priors(p)
        n, nr = len(px), len(pr)
        mux, sdx = _mean_sd(px)
        muy, sdy = _mean_sd(py)
        mur, sdr = _mean_sd(pr)
        d10 = lambda v: None if v is None else v / 10
        bx = policy_bucket("METRIC", XNAME[lr_xi(p)], None, cx, mux, sdx, n)
        by = policy_bucket("METRIC", "SQL Service Response Time", None, d10(cy), d10(muy), d10(sdy), n)
        e = p_e[p]
        if cx is None or cy is None:
            vd = "no Current value: the Current window was skipped or has no system metrics"
        elif n < 3:
            vd = (("no valid prior window" if n == 0 else
                   "only " + str(n) + " valid prior window" + ("" if n == 1 else "s"))
                  + ": too little history to tell more load from slower calls")
        elif bx in ("large", "moderate") and cx > mux:
            if by in ("large", "moderate"):
                if e is not None and e > 0 and mur is not None:
                    bz = policy_bucket("METRIC", "SQL Service Response Time", None, cy / 10, e * mur / 10,
                                       None if sdr is None else e * sdr / 10, nr)
                    if bz in ("large", "moderate"):
                        vd = ("more load (" + lr_chg(cx, mux) + ") <b>and</b> slower than that load explains: each "
                              + lr_noun(p) + " <b>" + lr_q(cy / e) + "</b> the normal for that load")
                    else:
                        vd = "more load (" + lr_chg(cx, mux) + "), response time as expected for that load"
                else:
                    vd = ("more load (" + lr_chg(cx, mux) + ") and each " + lr_noun(p) + " <b>"
                          + lr_q(cy / muy) + "</b> slower (too few intervals to tell what that load explains)")
            else:
                vd = "more load (" + lr_chg(cx, mux) + "), response time as expected for that load"
        elif bx in ("large", "moderate") and cx < mux:
            vd = ("less load (" + lr_chg(cx, mux) + ")"
                  + (", yet each " + lr_noun(p) + " <b>" + lr_q(cy / muy) + "</b> slower"
                     if by in ("large", "moderate") else ""))
        elif by in ("large", "moderate"):
            vd = "load is normal, each " + lr_noun(p) + " <b>" + lr_q(cy / muy) + "</b> slower"
        elif by == "improved":
            vd = "load is normal, each " + lr_noun(p) + " faster than usual"
        else:
            vd = "normal: load and response time both within their usual range"
        if n >= 3 and cy is not None and by in ("large", "moderate") and wb >= 1:
            vd += '<span data-mk-at="0" data-mk-pre=" after " hidden></span>'
        p_ls[p] = vd
        det = ""
        if cx is not None and cy is not None:
            det = (" Current: " + fmt_num(cx) + " " + XUNIT[lr_xi(p)]
                   + (" (normal " + range_txt(mux, sdx) + ")" if n >= 2 else "")
                   + ", " + fmt_num(cy) + " " + lr_yunit(p)
                   + (" (normal " + range_txt(muy, sdy) + ")" if n >= 2 else "")
                   + ("; the curve expects " + fmt_num(e) + " ms at that load" if e is not None else "")
                   + ".")
        p_r[p] = vd[:1].upper() + vd[1:] + "." + det

    # 5. markup
    out.append('<section id="load-response" class="vw in-s in-a lib" style="--os:10"><h2>Load vs response time'
               '<small class="h2sub">More load, or something broken? Each snapshot interval as a dot: '
               'how busy against how long each call took</small></h2>')
    if nb == 0:
        out.append('<p class="note">No system metrics (DBA_HIST_SYSMETRIC_SUMMARY) in the report span, '
                   'so there is nothing to plot.</p>')
        out.append(lib_ls("load-response", "no system metrics in the span") + "</section>")
    elif best < 6:
        out.append('<p class="note">'
                   + ("No load in the span: every snapshot interval had zero user calls, executions and logical reads."
                      if best == 0 else
                      "Only " + str(best) + " snapshot interval" + ("" if best == 1 else "s")
                      + " with load in the span: too few to draw.")
                   + "</p>")
        out.append(lib_ls("load-response", "no load in the span" if best == 0 else "too few intervals with load")
                   + "</section>")
    else:
        line = ('<div class="lr-chart" data-def="' + str(dflt) + '">'
                '<div class="lr-ctl"><span class="lr-seg" role="group" aria-label="Load measure">'
                '<span class="lr-sl">Load</span>')
        for xi in range(3):
            line += ('<button type="button" data-x="' + str(xi) + '" aria-pressed="'
                     + ("true" if xi == lr_xi(dflt) else "false") + '"'
                     + (" disabled" if p_cnt[xi] == 0 and p_cnt[xi + 3] == 0 else "") + ">"
                     + ("User calls", "Executions", "Logical reads")[xi] + "</button>")
        line += ('</span><span class="lr-seg" role="group" aria-label="Response measure">'
                 '<span class="lr-sl">Response</span>'
                 '<button type="button" data-y="0" aria-pressed="' + ("true" if lr_yi(dflt) == 0 else "false")
                 + '" title="SQL Service Response Time: database time per user call, as SYSMETRIC reports it">'
                 'Service time per call</button>'
                 '<button type="button" data-y="1" aria-pressed="' + ("true" if lr_yi(dflt) == 1 else "false")
                 + '" title="Database Time Per Sec divided by the load: DB time per unit of the chosen load">'
                 'DB time per unit</button>'
                 '</span></div>'
                 '<div class="lr-lg"><span><i class="lr-k kc"></i>Current window</span>'
                 '<span><i class="lr-k kp"></i>' + str(wb) + ' prior window' + ("" if wb == 1 else "s") + '</span>'
                 '<span><i class="lr-k kb"></i>every snapshot interval in the span</span>'
                 '<span><i class="lr-k kn"></i>normal for that load</span>'
                 '<span><i class="lr-k kd"></i>middle half (25th&ndash;75th percentile)</span></div>'
                 '<div class="lr-plot"></div></div>')
        out.append(line)
        out.append('<p class="lr-rd"><b>Reads as:</b> <span class="lr-rt">' + p_r[dflt] + '</span></p>')
        stride = math.ceil(nb / 6000) if nb > 6000 else 1

        out.append('<div class="lr-tw"><table id="lr-tbl" class="lr-tbl" data-nosort><caption>Per window, '
                   + XLAB[lr_xi(dflt)] + ' against ' + lr_ylab(dflt)
                   + '. &ldquo;Normal for that load&rdquo; = the dashed curve at the window&#39;s load.</caption>'
                   '<thead><tr><th>Window</th><th>When</th><th class="num">Load (' + XUNIT[lr_xi(dflt)] + ')</th>'
                   '<th class="num">vs normal</th><th class="num">Response (' + lr_yunit(dflt) + ')</th>'
                   '<th class="num">vs normal</th><th class="num">Normal for that load</th></tr></thead><tbody>')
        px, py, _ = priors(dflt)
        n = len(px)
        mux, sdx = _mean_sd(px)
        muy, sdy = _mean_sd(py)
        rows = tail = 0
        bx = by = None
        for k in range(wb + 1):
            rows += 1
            x = y = None
            if w_v.get(k) == "Y":
                x, y = lr_xv(dflt, w_m[k]), lr_yv(dflt, w_m[k])
            line = ('<tr id="' + anchor_id("lr", "w" + str(k)) + '"'
                    + (' class="cur"' if k == 0 else "")
                    + (' data-tail="Y"' if rows > 13 else "") + ">"
                    + '<td data-w="' + str(k) + '">' + ("<b>Current</b>" if k == 0 else wg_off(w, k)) + "</td>"
                    + '<td data-w="' + str(k) + '">' + wg_title(w, k) + "</td>")
            if w_v.get(k) != "Y":
                line += ('<td class="num" data-w="' + str(k) + '" colspan="5"><span class="lr-sk">skipped'
                         + (": " + esc(w_rs[k]) if w_rs.get(k) else "") + "</span></td>")
            else:
                if k == 0:
                    bx = policy_bucket("METRIC", XNAME[lr_xi(dflt)], None, x, mux, sdx, n)
                    by = policy_bucket("METRIC", "SQL Service Response Time", None,
                                       None if y is None else y / 10, None if muy is None else muy / 10,
                                       None if sdy is None else sdy / 10, n)
                ks = str(k)
                if k == 0:
                    dx = (delta_span(x, mux, "moderate" if bx in ("large", "moderate") else None)
                          + ' <span class="lr-z">' + band_ztxt(band_z(x, mux, sdx)) + "</span>")
                    dy = (delta_span(y, muy, by)
                          + ' <span class="lr-z">' + band_ztxt(band_z(y, muy, sdy)) + "</span>")
                else:
                    dx = delta_span(x, mux, None, "Y")
                    dy = delta_span(y, muy, None, "Y")
                line += ('<td class="num" data-w="' + ks + '">' + fmt_num(x) + "</td>"
                         + '<td class="num" data-w="' + ks + '">' + dx + "</td>"
                         + '<td class="num" data-w="' + ks + '">' + fmt_num(y) + "</td>"
                         + '<td class="num" data-w="' + ks + '">' + dy + "</td>"
                         + '<td class="num" data-w="' + ks + '">' + fmt_num(lr_exp(dflt, x)) + "</td>")
            out.append(line + "</tr>")
            if rows > 13:
                tail += 1
        out.append('<tr class="lr-nrm"><td colspan="2">Normal (prior mean, ' + str(n) + " window"
                   + ("" if n == 1 else "s") + ")</td>"
                   + '<td class="num">' + fmt_num(mux) + '</td><td class="num">' + range_txt(mux, sdx) + "</td>"
                   + '<td class="num">' + fmt_num(muy) + '</td><td class="num">' + range_txt(muy, sdy) + "</td>"
                   + "<td></td></tr>")
        out.append("</tbody></table></div>")
        if tail > 0:
            out.append('<span class="expander" data-for="lr-tbl" data-n="' + str(tail)
                       + '" data-noun="older windows">&#9656; Show ' + str(tail) + " older windows</span>")

        out.append('<details class="lr-all"><summary>Every measure, per window</summary>'
                   '<div class="lr-tw"><table class="lr-tbl2" data-nosort><thead><tr><th>Window</th><th class="num">User calls/s</th>'
                   '<th class="num">Executions/s</th><th class="num">Logical reads/s</th>'
                   '<th class="num">SQL service response time (ms per call)</th>'
                   '<th class="num">DB time (average active sessions)</th></tr></thead><tbody>')
        for k in range(wb + 1):
            ks = str(k)
            line = ('<tr><td data-w="' + ks + '">' + ("Current" if k == 0 else wg_off(w, k))
                    + ' <span class="lr-dt">' + wg_date(w, k) + "</span></td>")
            if w_v.get(k) != "Y":
                line += '<td class="num" data-w="' + ks + '" colspan="5"><span class="lr-sk">skipped</span></td>'
            else:
                m = w_m[k]
                line += "".join('<td class="num" data-w="' + ks + '">' + fmt_num(v) + "</td>"
                                for v in (m[0], m[1], m[2], m[3], None if m[4] is None else m[4] / 100))
            out.append(line + "</tr>")
        out.append("</tbody></table></div></details>")

        # 6. the payload
        out.append('<script>(window.AWR_DATA=window.AWR_DATA||{}).loadresp={def:' + str(dflt)
                   + ',t0:"' + t_lo.strftime("%Y-%m-%d %H:%M") + '",n:' + str(nb) + ",stride:" + str(stride) + ",p:[")
        for p in range(6):
            line = ('{n:' + str(p_cnt[p]) + ',xl:"' + XLAB[lr_xi(p)] + '",yl:"' + json_escape(lr_ylab(p))
                    + '",xu:"' + XUNIT[lr_xi(p)] + '",yu:"' + json_escape(lr_yunit(p)) + '",e:' + jn(p_e[p]) + ",c:[")
            c = curve.get(p)
            if c and len(c) >= 2:
                line += ",".join("[" + jn(b[0]) + "," + jn(b[1]) + "," + jn(b[2]) + "," + jn(b[3]) + "]" for b in c)
            line += '],r:"' + json_escape(p_r[p] or "") + '"}' + ("," if p < 5 else "")
            out.append(line)
        out.append("],w:[")
        for k in range(wb, -1, -1):
            line = ('{o:' + str(k) + ',l:"' + ("Current" if k == 0 else json_escape(wg_off(w, k)))
                    + '",t:"' + json_escape(wg_title(w, k)) + '",v:"' + w_v.get(k, "N") + '",m:[')
            if w_v.get(k) == "Y":
                line += ",".join(jn(v) for v in w_m[k])
            out.append(line + "]}" + ("," if k > 0 else ""))
        out.append("],")
        kept = [pt for i, pt in enumerate(pts) if i % stride == 0 or pt[1] == 1]
        for a in range(7):
            if a == 0:
                toks = [str(pt[0]) for pt in kept]
            elif a == 1:
                toks = [str(pt[1]) for pt in kept]
            else:
                toks = [jn(pt[2][a - 2]) for pt in kept]
            out.append(("bt" if a == 0 else "bc" if a == 1 else "b" + str(a - 2)) + ":[")
            out.extend(put_clob_chunked(",".join(toks)))
            out.append("]" + ("," if a < 6 else ""))
        out.append("};</script>")
        out.append(lib_ls("load-response", p_ls[dflt]) + "</section>")

    out.append(chrome.lib_script('js_loadresp.plsql'))
    out.append('<!-- AWR-SECTION: 20_load_response END -->')
    return "\n".join(out)
