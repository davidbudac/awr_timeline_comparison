"""Twin of sql/30_host_memory.sql (Host and memory, plan 046): host CPU and
paging (DBA_HIST_OSSTAT), memory (DBA_HIST_MEM_DYNAMIC_COMP, PGASTAT,
MEMORY_RESIZE_OPS), undo (DBA_HIST_UNDOSTAT) and temp / PGA by statement
(ASH), each a section-13-style table, the "Reads as:" sentence, the library
row text and the two card pointers (none fire in the demo).

The model has no OS, memory or undo statistics, so this twin derives the
RAW values the SQL reads (counter deltas, end-of-window gauges, 10-minute
undo totals, per-statement ASH maxima) deterministically from the model's
own numbers and w.rng, then runs the SQL's arithmetic on them:

  * the host: 16 CPUs (s09's CPU_COUNT), 8 cores, 1 socket, 256 GB; busy
    = the model's DB CPU + background CPU + a few points of OS / other
    software, so host busy sits a little above the database's share; user
    / system / nice split busy exactly (integer hundredths); I/O wait
    follows the User I/O waits; no paging, no Resource Manager wait;
  * memory follows the configuration card's parameter changes:
    sga_target 48 -> 64 GB at "RU 19.28 patch" (buffer cache and shared
    pool grow with it), pga_aggregate_target 8 -> 12 GB at "Release 4.1";
    no over-allocation, no resize operation in the Current window;
  * undo: blocks from the redo volume, transactions from the commits, the
    longest query the reporting statement's; one ORA-01555 in the window
    of 25 Jun (the oldest but one), none since;
  * temp: led by the reporting statement (9wz2ke6yq4tn1, PARALLEL 8: one
    sum over its sessions) and, in the Current window only, by
    7k2m9dx4qp1zb's new plan (a hash join of ORDER_LINES after Release 4.2).
"""
from __future__ import annotations

import math

from awrdemo.helpers import (anchor_id, band_cells, band_head, band_span, band_z, delta_span, ent, esc,
                             fmt_int, fmt_num, fmt_num_title, lib_ls, mean_sd, nbu, num6, ora_round)
from awrdemo.sections.s09_ash_timeline import CPU_COUNT

GB = 1073741824
MB = 1048576
GRAN = 268435456                       # a 256 MB SGA granule
C_BUSY, C_BCDROP = 90, 0.9
C_SWAP = 0.01        # MB/s paged out in the Current window: swapping (the SQL's c_swap)
C_TOP = 5
PHYS_GB = 256
REPORT_SQL, ORDER_SQL = "9wz2ke6yq4tn1", "7k2m9dx4qp1zb"

# per statement: (temp GB, PGA GB) of its largest sample (the sum over its
# sessions); ORDER_SQL's values switch with its plan (order_lookup_bad)
_TEMP = {REPORT_SQL: 2.6, "q8w4t2ve6ju3y": 0.45, "d8s3n5tw2xk7f": 0.12, "n7t3q5xc1yj4g": 0.05,
         "h5x1c9pa7rd3s": 0.6}
_PGA = {REPORT_SQL: 0.9, "q8w4t2ve6ju3y": 0.21, "d8s3n5tw2xk7f": 0.08, "n7t3q5xc1yj4g": 0.05,
        "2yq9jv7c5hm3d": 0.03, "u9d5p3fw2hs8x": 0.03, "f1p7r4mz8vb2c": 0.02, "t3h6u1zr9nb8w": 0.02}

# (code, block, label, unit, title) -- the SQL's add_row calls, in order
ROWS = [
    ('busy', 'H', 'Host CPU busy', '%', 'BUSY_TIME / (BUSY_TIME + IDLE_TIME) over the window (DBA_HIST_OSSTAT, counters, summed over the instances)'),
    ('user', 'H', 'User', '%', 'USER_TIME as a share of BUSY_TIME + IDLE_TIME'),
    ('sys', 'H', 'System', '%', 'SYS_TIME (kernel) as a share of BUSY_TIME + IDLE_TIME'),
    ('nice', 'H', 'Nice', '%', 'NICE_TIME (low-priority user code) as a share of BUSY_TIME + IDLE_TIME'),
    ('iowait', 'H', 'I/O wait', '%', 'IOWAIT_TIME as a share of BUSY_TIME + IDLE_TIME: CPUs idle with I/O outstanding'),
    ('dbshare', 'H', 'DB CPU share of host busy', '%',
     'Foreground DB CPU (DBA_HIST_SYS_TIME_MODEL) divided by the host&#39;s busy CPU time. The rest is background processes, other databases and software on the host, and the OS. It can pass 100 where the host counts CPU differently (virtual machines, SMT).'),
    ('load', 'H', 'Load (end of window)', 'processes', 'LOAD at the window&#39;s end snapshot: processes running or ready to run (on many platforms the one-minute average); the largest instance'),
    ('rsrc', 'H', 'Resource Manager CPU wait', 's/s', 'RSRC_MGR_CPU_WAIT_TIME: Oracle processes ready to run but held back by the resource plan, seconds per second'),
    ('vmin', 'H', 'Paged in', 'MB/s', 'VM_IN_BYTES: bytes paged in through virtual memory paging, per second'),
    ('vmout', 'H', 'Paged out (swap out)', 'MB/s', 'VM_OUT_BYTES: bytes paged out through virtual memory paging, per second'),
    ('cpus', 'H', 'CPUs', 'count', 'NUM_CPUS at the window&#39;s end snapshot (configuration)'),
    ('cores', 'H', 'CPU cores', 'count', 'NUM_CPU_CORES at the window&#39;s end snapshot (configuration)'),
    ('sockets', 'H', 'CPU sockets', 'count', 'NUM_CPU_SOCKETS at the window&#39;s end snapshot (configuration)'),
    ('physmem', 'H', 'Physical memory', 'GB', 'PHYSICAL_MEMORY_BYTES at the window&#39;s end snapshot (configuration)'),
    ('freemem', 'H', 'Free memory (end of window)', 'GB', 'FREE_MEMORY_BYTES at the window&#39;s end snapshot (a gauge; not every platform reports it)'),
    ('bc', 'M', 'Buffer cache', 'GB', 'DEFAULT buffer cache size at the window&#39;s end snapshot (DBA_HIST_MEM_DYNAMIC_COMP)'),
    ('sp', 'M', 'Shared pool', 'GB', 'shared pool size at the window&#39;s end snapshot'),
    ('lp', 'M', 'Large pool', 'GB', 'large pool size at the window&#39;s end snapshot'),
    ('sgat', 'M', 'SGA target (component)', 'GB', 'SGA Target component size at the window&#39;s end snapshot (automatic memory management)'),
    ('pgat', 'M', 'PGA target (component)', 'GB', 'PGA Target component size at the window&#39;s end snapshot (automatic memory management)'),
    ('pgaprm', 'M', 'PGA aggregate target', 'GB', 'aggregate PGA target parameter at the window&#39;s end snapshot (DBA_HIST_PGASTAT, configuration)'),
    ('pgaalloc', 'M', 'PGA allocated (end of window)', 'GB', 'total PGA allocated at the window&#39;s end snapshot (a gauge)'),
    ('pgainuse', 'M', 'PGA in use (end of window)', 'GB', 'total PGA inuse at the window&#39;s end snapshot: PGA consumed by work areas'),
    ('pgaover', 'M', 'PGA over-allocations', 'count', 'over allocation count, end minus begin of the window: PGA allocated beyond pga_aggregate_target'),
    ('ub', 'U', 'Undo blocks', 'blocks/s', 'UNDOBLKS of the 10-minute DBA_HIST_UNDOSTAT rows overlapping the window, per second of the rows&#39; covered time'),
    ('tx', 'U', 'Transactions', 'per s', 'TXNCOUNT of the overlapping 10-minute rows, per second'),
    ('mq', 'U', 'Longest query', 's', 'MAXQUERYLEN: the longest query of the overlapping rows (cursor open to last fetch), seconds'),
    ('mc', 'U', 'Most concurrent transactions', 'count', 'MAXCONCURRENCY: the highest number of transactions running at once'),
    ('e1555', 'U', 'ORA-01555 (snapshot too old)', 'count', 'SSOLDERRCNT summed over the overlapping rows'),
    ('enos', 'U', 'Undo out-of-space errors', 'count', 'NOSPACEERRCNT summed over the overlapping rows: no free space in the undo tablespace'),
    ('tr', 'U', 'Tuned undo retention (lowest)', 's', 'TUNED_UNDORETENTION: the lowest value of the overlapping rows'),
    ('tmppk', 'T', 'Peak temp space (ASH)', 'GB', 'the largest temp space held at one sample instant, summed over the sampled sessions (RAC: per instance, summed)'),
    ('pgapk', 'T', 'Peak PGA of sampled sessions (ASH)', 'GB', 'the largest PGA held at one sample instant, summed over the sampled (active) sessions; idle sessions are not sampled'),
]


def _mbq(gb):
    """GB -> bytes, whole MB (ASH reports bytes of whole allocations)"""
    return int(ora_round(gb * 1024, 0)) * MB


def _raw(w, win, m):
    """The raw values one window's SQL reads: OSSTAT deltas / gauges, the
    PGASTAT / component gauges, the undo totals, DB CPU (s) and the ASH
    statement maxima {sql_id: (temp bytes, pga bytes)} plus the peaks."""
    r = w.rng("s30", win.week_offset)
    dur = m.dur_sec
    dbcpu = m.time_model["DB CPU"] / 1e6
    bgcpu = m.time_model["background cpu time"] / 1e6
    cap = CPU_COUNT * dur
    other = (0.04 + 0.012 * r.random()) * cap
    busy = int(ora_round((dbcpu + bgcpu + other) * 100, 0))
    idle = int(ora_round(cap * 100, 0)) - busy
    sys_ = int(ora_round(busy * (0.15 + 0.03 * r.random()), 0))
    nice = int(ora_round(busy * 0.003, 0))
    uio = m.ash_class.get("User I/O", 0.0) * 10
    iow = int(ora_round(min(0.5 * idle, uio * 0.02 * 100), 0))
    load = ora_round((dbcpu + bgcpu) / dur + 1.2 + 1.5 * r.random(), 2)
    os_ = {"BUSY_TIME": busy, "IDLE_TIME": idle, "USER_TIME": busy - sys_ - nice, "SYS_TIME": sys_,
           "NICE_TIME": nice, "IOWAIT_TIME": iow, "RSRC_MGR_CPU_WAIT_TIME": 0, "VM_IN_BYTES": 0,
           "VM_OUT_BYTES": 0, "LOAD": load, "NUM_CPUS": CPU_COUNT, "NUM_CPU_CORES": 8,
           "NUM_CPU_SOCKETS": 1, "PHYSICAL_MEMORY_BYTES": PHYS_GB * GB}
    end = win.win_end_ts
    sga = int(w.param_value("sga_target", end))
    pga = int(w.param_value("pga_aggregate_target", end))
    bc = (int(ora_round(sga * 0.69 / GRAN, 0)) + r.choice((-1, 0, 0, 1))) * GRAN
    sp = (int(ora_round(sga * 0.19 / GRAN, 0)) + r.choice((-1, 0, 1))) * GRAN
    alloc = int(ora_round(pga * (0.50 + 0.08 * r.random()) * (1 + 0.08 * m.effects.order_lookup_bad), 0))
    inuse = int(ora_round(alloc * (0.55 + 0.1 * r.random()), 0))
    os_["FREE_MEMORY_BYTES"] = PHYS_GB * GB - sga - alloc - int(ora_round((120 + 2 * r.random()) * GB, 0))
    mc = {"default buffer cache": bc, "shared pool": sp, "large pool": 4 * GRAN,
          "sga target": sga, "pga target": pga}
    pg = {"total PGA allocated": alloc, "total PGA inuse": inuse,
          "aggregate PGA target parameter": pga, "over allocation count": 0}
    ub = int(ora_round(m.load["redo size"] / 8192 * 0.30, 0))
    tx = int(ora_round(m.load["user commits"] * 1.01, 0))
    un = {"ub": ub / dur, "tx": tx / dur, "mq": 600 + int(ora_round(400 * r.random(), 0)),
          "mqs": REPORT_SQL, "mc": 20 + int(ora_round(10 * r.random(), 0)),
          "e1555": 1 if win.week_offset == 11 else 0, "enos": 0,
          "tr": 2700 + int(ora_round(600 * r.random(), 0))}
    # ASH: each sampled statement's largest temp / PGA (its sessions summed)
    st = {}
    for sid in sorted(m.ash_sql):
        rr = w.rng("s30sql", win.week_offset, sid)
        f = 0.85 + 0.3 * rr.random()
        if sid == ORDER_SQL:
            tg, pgb = (2.1, 0.45) if m.effects.order_lookup_bad > 0 else (0.008, 0.06)
        else:
            tg, pgb = _TEMP.get(sid, 0.0), _PGA.get(sid, 0.01)
        st[sid] = (_mbq(tg * f), _mbq(pgb * f))
    tsum = sum(t for t, _p in st.values())
    psum = sum(p for _t, p in st.values())
    tmax = max([t for t, _p in st.values()] + [0])
    aas = math.fsum(m.ash_class.values()) / 360 / w.win_hours
    tpk = max(tmax, int(ora_round(0.75 * tsum, 0)))
    ppk = int(ora_round(aas * 12 * MB + 0.7 * psum, 0))
    return dict(os=os_, mc=mc, pg=pg, un=un, dbcpu=dbcpu, dur=dur, st=st, tpk=tpk, ppk=ppk)


def _rdiv(a, b):
    if a is None or b is None or b == 0:
        return None
    return a / b


def _label(dt):
    """The SQL's 'Dy DD Mon HH24:MI' of the window's start."""
    return f"{dt:%a} {dt:%d} {dt:%b} {dt:%H}:{dt:%M}"


def emit(w) -> str:
    out = ["<!-- AWR-SECTION: 30_host_memory BEGIN -->"]
    known = {win.week_offset: win.valid for win in w.windows}
    lab = {win.week_offset: _label(win.win_start_ts) for win in w.windows}
    skip = {win.week_offset: win.skip_reason for win in w.windows}
    curok = known.get(0, False)
    np_ = sum(1 for k, v in known.items() if k > 0 and v)
    raw = {}
    for win in w.windows:
        if win.valid:
            raw[win.week_offset] = _raw(w, win, w.window_metrics(win))
    ash_ok = bool(raw)

    # per window: the display values (the SQL's put() calls)
    vv = {}
    for k, x in raw.items():
        o = x["os"]
        to = o["BUSY_TIME"] + o["IDLE_TIME"]
        du = x["dur"]
        vals = {
            "busy": _rdiv(o["BUSY_TIME"] * 100, to), "user": _rdiv(o["USER_TIME"] * 100, to),
            "sys": _rdiv(o["SYS_TIME"] * 100, to), "nice": _rdiv(o["NICE_TIME"] * 100, to),
            "iowait": _rdiv(o["IOWAIT_TIME"] * 100, to),
            "dbshare": _rdiv(x["dbcpu"] * 100 * 100, o["BUSY_TIME"]),
            "load": o["LOAD"], "rsrc": _rdiv(o["RSRC_MGR_CPU_WAIT_TIME"] / 100, du),
            "vmin": _rdiv(o["VM_IN_BYTES"] / MB, du), "vmout": _rdiv(o["VM_OUT_BYTES"] / MB, du),
            "cpus": o["NUM_CPUS"], "cores": o["NUM_CPU_CORES"], "sockets": o["NUM_CPU_SOCKETS"],
            "physmem": o["PHYSICAL_MEMORY_BYTES"] / GB, "freemem": o["FREE_MEMORY_BYTES"] / GB,
            "bc": x["mc"]["default buffer cache"] / GB, "sp": x["mc"]["shared pool"] / GB,
            "lp": x["mc"]["large pool"] / GB, "sgat": x["mc"]["sga target"] / GB,
            "pgat": x["mc"]["pga target"] / GB,
            "pgaprm": x["pg"]["aggregate PGA target parameter"] / GB,
            "pgaalloc": x["pg"]["total PGA allocated"] / GB, "pgainuse": x["pg"]["total PGA inuse"] / GB,
            "pgaover": x["pg"]["over allocation count"],
            "ub": x["un"]["ub"], "tx": x["un"]["tx"], "mq": x["un"]["mq"], "mc": x["un"]["mc"],
            "e1555": x["un"]["e1555"], "enos": x["un"]["enos"], "tr": x["un"]["tr"],
            "tmppk": x["tpk"] / GB, "pgapk": x["ppk"] / GB,
        }
        for c, v in vals.items():
            if v is not None:
                vv[(c, k)] = v

    def v_(c, k):
        return vv.get((c, k))

    on = {}
    for c, *_r in ROWS:
        on[c] = any(v_(c, k) is not None and (c not in ("sgat", "pgat") or v_(c, k) > 0)
                    for k in range(w.weeks_back + 1))
    mu, sd, nn = {}, {}, {}
    for c, *_r in ROWS:
        mu[c], sd[c], nn[c] = mean_sd([v_(c, k) for k in range(1, w.weeks_back + 1)])

    # configuration lines
    def cfg_txt():
        if v_("cpus", 0) is None:
            return None
        s = fmt_int(v_("cpus", 0)) + (" CPU" if v_("cpus", 0) == 1 else " CPUs")
        co, so = v_("cores", 0), v_("sockets", 0)
        if co is not None or so is not None:
            s += " ("
            if co is not None:
                s += fmt_int(co) + (" core" if co == 1 else " cores")
            if co is not None and so is not None:
                s += ", "
            if so is not None:
                s += fmt_int(so) + (" socket" if so == 1 else " sockets")
            s += ")"
        if v_("physmem", 0) is not None:
            s += ", " + fmt_num(v_("physmem", 0)) + "&nbsp;GB memory"
        return s
    cfg = cfg_txt()
    chg = ""
    for ci, (c, word) in enumerate((("cpus", "CPUs"), ("cores", "CPU cores"), ("sockets", "CPU sockets"),
                                    ("physmem", "memory")), 1):
        prev = pwk = None
        for k in range(w.weeks_back, -1, -1):
            v = v_(c, k)
            if v is None:
                continue
            if prev is not None and v != prev:
                chg += ("; " if chg else "") + word + " " + (fmt_num(prev) if ci == 4 else fmt_int(prev)) + " &rarr; " \
                    + (fmt_num(v) + "&nbsp;GB" if ci == 4 else fmt_int(v)) + " between " + lab[pwk] + " and " + lab[k]
            prev, pwk = v, k

    # the Current window's top statements by temp / PGA
    tq = {"T": [], "P": []}
    if curok:
        cur_st = raw[0]["st"]
        for kind, ix in (("T", 0), ("P", 1)):
            cand = [(sid, v[ix]) for sid, v in cur_st.items() if v[ix] > 0]
            cand.sort(key=lambda t: (-t[1], t[0]))
            tq[kind] = [sid for sid, _v in cand[:C_TOP]]

    def by_txt(p):
        if p is None:
            return "&mdash;"
        if p >= GB:
            return fmt_num(p / GB) + "&nbsp;GB"
        if p >= MB:
            return fmt_num(p / MB) + "&nbsp;MB"
        if p >= 1024:
            return fmt_num(p / 1024) + "&nbsp;KB"
        return fmt_num(p) + "&nbsp;B"

    def ev_row(dt, code, name, de, cur, m_, ttl):
        aid = anchor_id("hm", code)
        return ('<div class="evr ev-hm" data-hm="' + aid + '" data-cur="' + num6(cur)
                + '" data-mu="' + num6(m_) + '" title="' + ttl + ' Not scored.">'
                + '<dt>' + dt + '</dt><dd><span class="id txt">' + ent(name, aid, "metric")
                + '</span><span class="de">' + nbu(de) + '</span></dd><div class="m">'
                + delta_span(cur, m_, None, "Y")
                + band_span(band_z(cur, m_, sd.get(code)), None, "sm", "N", 10)
                + '<span class="ns">not scored</span></div></div>')

    # what stands out, the sentence, the card rows
    opn, why, ev_io, ev_dbt = False, "", "", ""
    rs_tot = 0
    if curok:
        cur = v_("busy", 0)
        if cur is not None and cur >= C_BUSY:
            opn, why = True, why + " busy"
            ev_dbt += ev_row("Host", "busy", "host CPU", fmt_int(cur) + "% busy"
                             + (", was " + fmt_int(mu["busy"]) + "%" if mu["busy"] is not None else ""),
                             cur, mu["busy"], "Host and memory: the host&#39;s CPU was at least 90% busy in the Current window.")
        cur = v_("vmout", 0)
        if cur is not None and cur >= C_SWAP:
            opn, why = True, why + " swap"
            ev_dbt += ev_row("Host", "vmout", "swapping", fmt_num(cur) + " MB/s paged out"
                             + (", was " + fmt_num(mu["vmout"]) + " MB/s" if mu["vmout"] is not None else ""),
                             cur, mu["vmout"], "Host and memory: the host paged memory out (VM_OUT_BYTES) in the Current window.")
        if chg:
            opn, why = True, why + " resized"
        cur, m_ = v_("bc", 0), mu["bc"]
        if cur is not None and m_ is not None and m_ > 0 and cur <= C_BCDROP * m_:
            opn, why = True, why + " bc"
            ev_io = ev_row("Memory", "bc", "buffer cache", fmt_num(cur) + " GB, was " + fmt_num(m_) + " GB (prior mean)",
                           cur, m_, "Host and memory: the Current buffer cache is at least 10% below the prior windows&#39; mean; a smaller cache reads more from disk.")
        if (v_("pgaover", 0) or 0) > 0:
            opn, why = True, why + " pgaover"
        if (v_("e1555", 0) or 0) > 0:
            opn, why = True, why + " ora1555"
        if (v_("enos", 0) or 0) > 0:
            opn, why = True, why + " undospace"

        parts_rd, parts_ls = [], []
        cur = v_("busy", 0)
        if cur is not None:
            pts = cur * v_("dbshare", 0) / 100 if v_("dbshare", 0) is not None else None
            parts_rd.append("Host CPU " + fmt_int(cur) + "% busy"
                            + (", the database (foreground DB CPU) about " + fmt_int(pts) + " points of it"
                               if pts is not None else ""))
            parts_ls.append("host CPU " + fmt_int(cur) + "% busy")
        cur = v_("vmout", 0)
        if cur is not None:
            parts_rd.append("swapping, " + fmt_num(cur) + "&nbsp;MB/s paged out" if cur >= C_SWAP
                            else "little paging out (" + fmt_num(cur) + "&nbsp;MB/s)" if cur > 0 else "no swapping")
            if cur >= C_SWAP:
                parts_ls.append("swapping")
        if chg:
            parts_rd.append("host resized (" + chg + ")")
            parts_ls.append("host resized")
        cur, m_ = v_("bc", 0), mu["bc"]
        if cur is not None:
            parts_rd.append("buffer cache " + ("steady at " + fmt_num(cur) + "&nbsp;GB"
                                               if m_ is None or abs(cur - m_) < 0.1 * m_
                                               else fmt_num(cur) + "&nbsp;GB, was " + fmt_num(m_) + "&nbsp;GB on average"))
            parts_ls.append("buffer cache " + fmt_num(cur) + "&nbsp;GB")
        if (v_("pgaover", 0) or 0) > 0:
            n = v_("pgaover", 0)
            parts_rd.append("PGA over-allocated " + fmt_int(n) + (" time" if n == 1 else " times"))
            parts_ls.append("PGA over-allocation")
        if v_("e1555", 0) is not None:
            e = v_("e1555", 0)
            parts_rd.append(("no ORA-01555" if e == 0 else fmt_int(e) + " ORA-01555 (snapshot too old)")
                            + (", " + fmt_int(v_("enos", 0)) + " undo out-of-space" if (v_("enos", 0) or 0) > 0 else ""))
            parts_ls.append("no ORA-01555" if e == 0 else fmt_int(e) + " ORA-01555")
        if ash_ok and v_("tmppk", 0) is not None:
            t = v_("tmppk", 0)
            if t > 0:
                parts_rd.append("peak temp " + by_txt(t * GB)
                                + (" (largest: " + ent(tq["T"][0], anchor_id("sq-elapsed", tq["T"][0]), "sql") + ")" if tq["T"] else ""))
                parts_ls.append("peak temp " + by_txt(t * GB))
            else:
                parts_rd.append("no temp space in the ASH samples")
                parts_ls.append("no temp")
        if parts_rd:
            rd = "; ".join(parts_rd)
            rd = rd[0].upper() + rd[1:] + "."
            ls = "; ".join(parts_ls)
        else:
            rd, ls = "Nothing could be read for the Current window.", "nothing readable"
    else:
        rd = ("The Current window is unknown (" + esc(skip.get(0) or "an instance skipped")
              + "), so its host and memory numbers are too.")
        ls = "Current window skipped"

    hdr = '<thead><tr><th>Metric</th><th>Unit</th><th class="num" data-w="0">Current</th>' + band_head() + '<th class="trend">Trend</th>'
    for k in range(1, w.weeks_back + 1):
        hdr += '<th class="num" data-w="' + str(k) + '">&minus;' + w.offset_labels[k - 1] + '</th>'
    hdr += '</tr></thead>'

    def row_html(c, labl, unit, ttl):
        cv = v_(c, 0)
        sp = ",".join(num6(v_(c, k)) for k in range(w.weeks_back, -1, -1))
        s = ('<tr id="' + anchor_id("hm", c) + '" data-cur="' + num6(cv) + '" data-mu="' + num6(mu[c])
             + '" data-n="' + str(nn[c]) + '"><td><span title="' + ttl + '">' + labl + '</span></td>'
             + '<td>' + unit + '</td>'
             + '<td class="num" data-w="0"' + fmt_num_title(cv) + '><b>' + fmt_num(cv) + '</b></td>'
             + band_cells(cv, mu[c], sd[c], nn[c], None, "N", "", "Y")
             + '<td class="trend" data-spark="' + sp + '" data-spark-title="' + labl + '"></td>')
        for k in range(1, w.weeks_back + 1):
            s += '<td class="num" data-w="' + str(k) + '">' + fmt_num(v_(c, k)) + '</td>'
        return s + '</tr>'

    def put_table(b, tid):
        rows = [r for r in ROWS if r[1] == b and on[r[0]]]
        if not rows:
            return
        out.append('<div class="hm-tw"><table id="' + tid + '" class="hm-tbl" data-nocount>' + hdr + '<tbody>')
        for c, _b, labl, unit, ttl in rows:
            out.append(row_html(c, labl, unit, ttl))
        out.append('</tbody></table></div>')

    def miss_of(b):
        return ", ".join(r[2] for r in ROWS if r[1] == b and not on[r[0]])

    out.append('<section id="host-memory" class="vw in-s in-a lib' + (" lopen" if opn else "")
               + '" style="--os:20" data-open="' + why.strip() + '"><h2>Host and memory'
               '<small class="h2sub">Host CPU and paging, SGA / PGA, undo, temp; not scored</small></h2>')
    out.append(lib_ls("host-memory", ls))
    out.append('<p class="hm-rd"><b>Reads as:</b> ' + rd + '</p>')

    out.append('<div class="hm-blk" id="hm-host"><h3>Host CPU and paging</h3>')
    if cfg:
        out.append('<p class="hm-cfg">Host in the Current window: ' + cfg + '.</p>')
    if chg:
        out.append('<p class="hm-chg"><b>Host resized:</b> ' + chg + '.</p>')
    put_table("H", "hm-t-host")
    if miss_of("H"):
        out.append('<p class="note hm-miss">Not reported for the compared windows (platform or snapshots): ' + miss_of("H") + '.</p>')
    out.append('</div>')

    out.append('<div class="hm-blk" id="hm-mem"><h3>Memory</h3>')
    put_table("M", "hm-t-mem")
    if miss_of("M"):
        out.append('<p class="note hm-miss">Not reported or zero in every compared window: ' + miss_of("M") + '.</p>')
    out.append('<h4>Resize operations in the Current window</h4>')
    if not curok:
        out.append('<p class="note">The Current window is unknown.</p>')
    else:
        out.append('<p class="note hm-rs0">No SGA / PGA grow or shrink operation started in the Current window.</p>')
    out.append('</div>')

    out.append('<div class="hm-blk" id="hm-undo"><h3>Undo</h3>')
    put_table("U", "hm-t-undo")
    if curok and 0 in raw:
        out.append('<p class="hm-mq">Longest query in the Current window: <b>' + fmt_num(raw[0]["un"]["mq"]) + '&nbsp;s</b>, '
                   + ent(esc(raw[0]["un"]["mqs"]), anchor_id("sq-elapsed", raw[0]["un"]["mqs"]), "sql") + '.</p>')
    if miss_of("U"):
        out.append('<p class="note hm-miss">No <code>DBA_HIST_UNDOSTAT</code> rows for: ' + miss_of("U") + '.</p>')
    out.append('</div>')

    out.append('<div class="hm-blk" id="hm-temp"><h3>Temp and PGA by statement</h3>')
    if not ash_ok:
        out.append('<p class="note">No ASH samples in the known compared windows.</p>')
    else:
        put_table("T", "hm-t-temp")
        if curok:
            for kind, ix, head in (("T", 0, "Largest temp space in the Current window"),
                                   ("P", 1, "Largest PGA in the Current window")):
                out.append('<h4>' + head + '</h4>')
                if not tq[kind]:
                    out.append('<p class="note">No statement in the Current window&rsquo;s ASH samples held '
                               + ("temp space" if kind == "T" else "PGA memory") + '.</p>')
                    continue
                out.append('<div class="hm-tw"><table id="hm-sq-' + kind.lower() + '" class="hm-tbl hm-sq" data-nocount>'
                           '<thead><tr><th>#</th><th>SQL_ID</th><th class="num" data-w="0" title="the largest value at one sample instant, summed over the statement&#39;s sessions">Current max</th>'
                           '<th class="num" title="median of the statement&#39;s per-window maxima over the known prior windows in which ASH sampled it">Prior typical max</th>'
                           '<th class="num">&Delta; vs typical</th><th class="num" title="known prior windows in which ASH sampled the statement">Seen in prior windows</th></tr></thead><tbody>')
                for rk, sid in enumerate(tq[kind], 1):
                    c = raw[0]["st"][sid][ix]
                    pv = [raw[k]["st"][sid][ix] for k in range(1, w.weeks_back + 1)
                          if known.get(k) and k in raw and sid in raw[k]["st"]]
                    pv.sort()
                    n2 = len(pv)
                    mm = None if n2 == 0 else (pv[(n2 - 1) // 2] if n2 % 2 == 1 else (pv[n2 // 2 - 1] + pv[n2 // 2]) / 2)
                    out.append('<tr data-sql="' + sid + '" data-cur="' + num6(c) + '" data-mu="' + num6(mm) + '">'
                               + '<td class="num">' + str(rk) + '</td><td>' + ent(sid, anchor_id("sq-elapsed", sid), "sql") + '</td>'
                               + '<td class="num" data-w="0"><b>' + by_txt(c) + '</b></td><td class="num">' + by_txt(mm) + '</td>'
                               + '<td class="num">' + ('<span class="d s-na">new</span>' if n2 == 0 else delta_span(c, mm, None, "Y")) + '</td>'
                               + '<td class="num">' + str(n2) + ' of ' + str(np_) + '</td></tr>')
                out.append('</tbody></table></div>')
    out.append('<p class="note hm-ash">ASH (<code>DBA_HIST_ACTIVE_SESS_HISTORY</code>) keeps one in ten of the in-memory samples: '
               'a 10-second sample of ACTIVE sessions, so a short spill is easily missed and an idle session&rsquo;s PGA is not counted. '
               'A statement&rsquo;s value at one sample = the sum over its sessions (parallel slaves included); its window value = the largest '
               'such sum. Typical = the median of its maxima over the known prior windows in which ASH sampled it.</p>')
    out.append('</div>')

    out.append('<p class="note hm-meth">Counters (CPU times, paging, over-allocations) are end minus begin of the window&rsquo;s snapshots; '
               'gauges (load, sizes, PGA allocated) are read at the window&rsquo;s end snapshot; undo comes in 10-minute rows counted toward every '
               'window they overlap. Host values are summed over the instances. A window is used only when every instance of it is valid. '
               'Evidence, not a finding: nothing here is scored or counted.</p>')
    out.append('</section>')

    if ev_io or ev_dbt:
        out.append('<div id="hm-ev-src" hidden>'
                   + ('<div data-for="f-io">' + ev_io + '</div>' if ev_io else '')
                   + ('<div data-for="f-dbtime">' + ev_dbt + '</div>' if ev_dbt else '')
                   + '</div>')
        out.append('<script>(function(){var d=document,x=d.getElementById("hm-ev-src");if(!x)return;'
                   '[].slice.call(x.children).forEach(function(g){var c=d.getElementById(g.getAttribute("data-for")),'
                   'dl=c?c.querySelector("dl.ev"):null;if(dl){while(g.firstChild)dl.appendChild(g.firstChild);}});'
                   'x.parentNode.removeChild(x);})();</script>')

    out.append("<!-- AWR-SECTION: 30_host_memory END -->")
    return "\n".join(out) + "\n"

