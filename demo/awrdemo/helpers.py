"""
Python twins of the report's shared PL/SQL helpers (sql/lib/*.plsql) plus
a few Oracle formatting primitives, so the demo generator emits the SAME
markup / number strings the real report does.

Everything here is pure and deterministic.  Keep the rules in lockstep
with the PL/SQL originals named in each docstring.
"""
from __future__ import annotations

import math
import os
import re
from decimal import Decimal, ROUND_HALF_UP

# ---------------------------------------------------------------------
# Oracle number formatting primitives
# ---------------------------------------------------------------------

def _rnd(x: float, dec: int) -> Decimal:
    """Oracle ROUND(): half away from zero (Decimal ROUND_HALF_UP)."""
    q = Decimal(1).scaleb(-dec)
    return Decimal(repr(float(x))).quantize(q, rounding=ROUND_HALF_UP)


def ora_round(x: float, dec: int = 0) -> float:
    return float(_rnd(x, dec))


def _group(int_part: str) -> str:
    neg = int_part.startswith("-")
    if neg:
        int_part = int_part[1:]
    out = []
    while len(int_part) > 3:
        out.insert(0, int_part[-3:])
        int_part = int_part[:-3]
    out.insert(0, int_part)
    return ("-" if neg else "") + ",".join(out)


def to_char_fixed(x: float, dec: int, group: bool = False, plus: bool = False) -> str:
    """TO_CHAR(x, 'FM[S]999[G]990D000') with `dec` zero-padded decimals.
    Trailing zeros are KEPT (the report's masks use D000000)."""
    if x is None:
        return ""
    d = _rnd(x, dec)
    s = f"{d:.{dec}f}" if dec > 0 else f"{d:.0f}"
    neg = s.startswith("-")
    if neg:
        s = s[1:]
    if s.startswith("."):
        s = "0" + s
    if dec == 0 and float(d) == 0:
        neg = False
    ip, _, fp = s.partition(".")
    if group:
        ip = _group(ip)
    s = ip + ("." + fp if dec > 0 else "")
    if neg and float(d) != 0:
        return "-" + s
    if plus:
        return "+" + s
    return s


def to_char_trim(x: float, dec: int, group: bool = False, plus: bool = False,
                 min_dec: int = 0) -> str:
    """TO_CHAR(x, 'FM...990D0999') -- optional 9s after D are trimmed when
    zero, the first `min_dec` (the 0s) are mandatory; a bare trailing '.'
    is dropped (Oracle FM behaviour)."""
    s = to_char_fixed(x, dec, group, plus)
    if "." in s:
        ip, _, fp = s.partition(".")
        fp = fp.rstrip("0")
        if len(fp) < min_dec:
            fp = fp + "0" * (min_dec - len(fp))
        s = ip + ("." + fp if fp else "")
    return s


def num6(x: float | None) -> str:
    """TO_CHAR(x, 'FM99999999990D000000', NLS='.,') -- the JSON/CSV number
    contract used by every data-spark / AWR_DATA payload.  None -> ''."""
    if x is None:
        return ""
    return to_char_fixed(x, 6)


def num6_or_null(x: float | None) -> str:
    return "null" if x is None else num6(x)


def to_char_int(x: float | None) -> str:
    """TO_CHAR(n) for an integer-valued number."""
    if x is None:
        return ""
    return str(int(_rnd(x, 0)))


# ---------------------------------------------------------------------
# sql/lib/fmt_num.plsql
# ---------------------------------------------------------------------

def fmt_num(p: float | None) -> str:
    if p is None:
        return "&mdash;"
    if p == 0:
        return "0"
    sign = "-" if p < 0 else ""
    a = abs(p)
    suf = ""
    if a >= 1e9:
        v, suf = a / 1e9, " G"
    elif a >= 1e6:
        v, suf = a / 1e6, " M"
    elif a >= 1e4:
        v, suf = a / 1e3, " k"
    else:
        v = a
    if v >= 1000:
        txt = to_char_fixed(ora_round(v, 0), 0, group=True)
    elif v >= 100:
        txt = to_char_fixed(v, 1, group=True)
    elif v >= 10:
        txt = to_char_fixed(v, 2, group=True)
    elif v >= 1:
        txt = to_char_fixed(v, 3)
    else:
        dec = min(6, 3 - math.floor(math.log10(v)))
        if ora_round(v, 6) == 0:
            return sign + "<0.000001"
        txt = to_char_trim(ora_round(v, dec), 6)
        if txt.startswith("."):
            txt = "0" + txt
    return sign + txt + suf


def fmt_num_title(p: float | None) -> str:
    if p is None:
        return ""
    return ' title="' + to_char_trim(p, 4, group=True, min_dec=1) + '"'


def fmt_int(p: float | None) -> str:
    if p is None:
        return "&mdash;"
    return to_char_fixed(ora_round(p, 0), 0, group=True)


# ---------------------------------------------------------------------
# sql/lib/score_cells.plsql  (+ the raw z / bucket math sections reuse)
# ---------------------------------------------------------------------

def mean_sd(vals):
    """AVG / STDDEV (sample, n-1) / COUNT over non-None values -- Oracle
    STDDEV returns NULL for n<2 and 0 for identical values."""
    v = [x for x in vals if x is not None]
    n = len(v)
    if n == 0:
        return None, None, 0
    mu = sum(v) / n
    if n < 2:
        return mu, None, n
    var = sum((x - mu) ** 2 for x in v) / (n - 1)
    sd = math.sqrt(var)
    # Oracle's decimal arithmetic yields STDDEV = 0 for identical values;
    # binary floats leave ~1e-16 residue that would blow z up to 1e15.
    if sd <= 1e-9 * abs(mu):
        sd = 0.0
    return mu, sd, n


def z_and_pct(cur, mu, sd):
    """z over the floored sigma max(sd, 2% of |mu|) (v1.5.0), % delta."""
    if cur is None or mu is None or sd is None:
        z = None
    else:
        den = max(sd, 0.02 * abs(mu))
        z = None if den == 0 else (cur - mu) / den
    pct = None if (cur is None or mu is None or mu == 0) else (cur - mu) / abs(mu) * 100
    return z, pct


def bucket_of(cur, n, sd, z, pct=None, share=None, dir="-", demote=False, mu=None,
              domain="SQL", name=None, cls=None):
    """Compatibility shim over policy_bucket() (sql/lib/metric_policy.plsql);
    `dir` is ignored -- the policy decides the direction."""
    return policy_bucket(domain, name, cls, cur, mu, sd, n, share, demote)


BUCKET_CLS = {"large": "crit", "moderate": "warn", "typical": "ok", "improved": "imp",
              "noted": "note"}


def bucket_cls(bucket: str) -> str:
    return BUCKET_CLS.get(bucket, "skip")


def sigma_flag(mu, sd) -> bool:
    if mu is None or sd is None:
        return False
    return (mu == 0 and sd == 0) or (mu != 0 and sd < 0.01 * abs(mu))


def z_txt(z, dec=2) -> str:
    """FMS99990D00 (dec=2) or FMS99990D0 (dec=1) with the >99 clamp."""
    if z is None:
        return "&mdash;"
    if z > 99:
        return "&gt;+99"
    if z < -99:
        return "&lt;&minus;99"
    return to_char_fixed(z, dec, plus=True)


def pct_txt(pct) -> str:
    """F5 direction-glyph rendering of a % delta (FM99990D0)."""
    if pct is None:
        return "&mdash;"
    if pct < 0:
        return "&#9660; " + to_char_fixed(abs(pct), 1) + "%"
    return "&#9650; " + to_char_fixed(pct, 1) + "%"


SIG_BADGE = (' <span class="badge sig" title="baseline barely moved: '
             '&sigma; below 1% of mean (floored to 2% for z); read the % delta instead">'
             '&sigma;&approx;0</span>')

IMM_BADGE = (' <span class="badge sig" title="|z| above 2 but the move is below this '
             'metric&#39;s materiality floor (sql/lib/metric_policy.plsql)">'
             'immaterial</span>')

# 07's variant of the immaterial badge (different wording of the title)
IMM_BADGE_07 = (' <span class="badge sig" title="|z| above 2 but the move is below '
                'this metric&#39;s materiality floor (sql/lib/metric_policy.plsql)">'
                'immaterial</span>')


def score_cells(cur, mu, sd, n, share=None, domain="SQL", name=None, cls=None,
                demote=False) -> str:
    """sql/lib/score_cells.plsql score_cells(): the four band cells (v1.6.0)."""
    bucket = policy_bucket(domain, name, cls, cur, mu, sd, n, share, demote)
    note = ('<span class="imm" title="part of a table-wide shift; '
            'see the note above the table">table-wide shift</span>'
            if demote and bucket == "moderate" else "")
    return band_cells(cur, mu, sd, n, bucket, "N", note)


# ---------------------------------------------------------------------
# sql/lib/band_glyph.plsql  (the baseline band, the Delta rule)
# ---------------------------------------------------------------------

def band_z(cur, mu, sd):
    if cur is None or mu is None or sd is None:
        return None
    den = max(sd, 0.02 * abs(mu))
    return None if den == 0 else (cur - mu) / den


def band_ztxt(z) -> str:
    if z is None:
        return "&mdash;"
    if z > 99:
        return "&gt;+99&sigma;"
    if z < -99:
        return "&lt;&minus;99&sigma;"
    if ora_round(z, 1) < 0:
        return "&minus;" + to_char_fixed(abs(z), 1) + "&sigma;"
    return "+" + to_char_fixed(abs(z), 1) + "&sigma;"


def band_sev(bucket) -> str:
    return {"large": "s-large", "moderate": "s-moderate",
            "improved": "s-improved"}.get(bucket, "s-typical")


_BAND_LAB = {"large": "large finding", "moderate": "moderate finding", "improved": "improved",
             "noted": "noted", "typical": "normal"}


def band_span(z, bucket, size=None, twin="N") -> str:
    sz = (" " + size) if size else ""
    if bucket == "flat baseline":
        return ('<span class="bd s-flat' + sz + '" role="img"'
                ' aria-label="flat baseline, prior sigma is zero">'
                '<b class="ov">flat, &sigma; = 0</b></span>')
    if z is None or bucket in ("insufficient history", "n/a"):
        lab = {"insufficient history": "too little history",
               "n/a": "no current value"}.get(bucket, "not scored")
        return ('<span class="bd na' + sz + '" role="img" aria-label="' + lab
                + '"><b class="ov">' + lab + '</b></span>')
    x = (z + 4) / 12
    pin, ov = "", ""
    if x > 1:
        x, pin, ov = 1, " po", '<b class="ov">' + band_ztxt(z) + '</b>'
    elif x < 0:
        x, pin, ov = 0, " pu", '<b class="ov">' + band_ztxt(z) + '</b>'
    lab = _BAND_LAB.get(bucket, "not scored")
    return ('<span class="bd ' + band_sev(bucket) + sz + pin + (" twn" if twin == "Y" else "")
            + '" style="--x:' + to_char_fixed(x, 3) + '" role="img" aria-label="' + lab
            + ', z ' + band_ztxt(z) + '"><i></i>' + ov + '</span>')


def delta_span(cur, mu, bucket, plain="N") -> str:
    if bucket == "flat baseline":
        return '<span class="d s-flat">&mdash;</span>'
    if cur is None or mu is None or mu == 0:
        return '<span class="d s-na">&mdash;</span>'
    q = cur / mu
    if mu > 0 and q >= 2:
        txt = "&#9650; &times;" + (to_char_fixed(q, 1) if q < 100
                                    else to_char_fixed(ora_round(q, 0), 0))
    else:
        pct = (cur - mu) / abs(mu) * 100
        txt = ("&#9650; " if pct >= 0 else "&#9660; ") + to_char_fixed(abs(pct), 1) + "%"
    return ('<span class="d ' + ("s-plain" if plain == "Y" else band_sev(bucket)) + '">'
            + txt + '</span>')


def lib_ls(sec_id: str, html: str) -> str:
    """sql/lib/band_glyph.plsql lib_ls: the evidence library row text."""
    return ('<script>if(window.AWR_ls)AWR_ls("' + sec_id + '","'
            + html.replace("\\", "\\\\").replace('"', '\\"') + '");</script>')


def range_txt(mu, sd) -> str:
    if mu is None or sd is None:
        return "&mdash;"
    den = max(sd, 0.02 * abs(mu))
    return fmt_num(max(0, mu - 2 * den)) + "&ndash;" + fmt_num(mu + 2 * den)


BAND_HEAD = (
    '<th class="num c-rng" title="prior mean &plusmn; 2&sigma;, in the row&#39;s own unit">Normal range</th>'
    '<th class="c-band" title="Current, in &sigma; from the prior mean. Shaded = normal (&plusmn;1&sigma;, &plusmn;2&sigma;); ticks at &plusmn;2&sigma; and &plusmn;3&sigma;.">'
    'vs normal, in &sigma;<span class="bd-ax" aria-hidden="true">'
    '<em style="--x:.167">&minus;2</em><em style="--x:.333">0</em>'
    '<em style="--x:.500">+2</em><em style="--x:.583">+3</em>'
    '<em class="end" style="--x:1">+8&sigma;</em></span></th>'
    '<th class="num c-z">z</th>'
    '<th class="num c-d">&Delta; vs mean</th>')


def band_head() -> str:
    return BAND_HEAD


def band_cells(cur, mu, sd, n, bucket, twin="N", note="", plain="N") -> str:
    z = band_z(cur, mu, sd)
    nt = ""
    if bucket == "typical" and z is not None and abs(z) > 2:
        nt += ('<span class="imm" title="|z| above 2 but the move is below this '
               'metric&#39;s materiality floor (sql/lib/metric_policy.plsql)">immaterial</span>')
    elif bucket in ("improved", "noted"):
        nt += '<span class="imm">' + bucket + '</span>'
    elif bucket == "insufficient history":
        nt += '<span class="imm" title="fewer than 3 prior valid windows">n &lt; 3</span>'
    if sigma_flag(mu, sd):
        nt += ('<span class="imm" title="baseline barely moved: &sigma; below 1% '
               'of mean (floored to 2% for z); read the &Delta; instead">&sigma;&approx;0</span>')
    return ('<td class="num c-rng">' + range_txt(mu, sd) + '</td>'
            '<td class="c-band">' + band_span(z, bucket, None, twin) + '</td>'
            '<td class="num c-z">' + band_ztxt(z) + '</td>'
            '<td class="num c-d">' + delta_span(cur, mu, bucket, plain) + nt + (note or "") + '</td>')


# ---------------------------------------------------------------------
# sql/lib/metric_policy.plsql -- parsed from the SQL include itself, so the
# demo can never drift from the report's per-metric policy table.
# ---------------------------------------------------------------------

_POLICY_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..",
                            "sql", "lib", "metric_policy.plsql")
_POL_RE = re.compile(r"WHEN\s+'([^']*)'\s+THEN\s+RETURN\s+pol\('([^']*)',\s*'([YN])',\s*'(\w+)',"
                     r"\s*([\d.]+|NULL),\s*([\d.]+|NULL)\)")
_WPOL_RE = re.compile(r"(?:WHEN\s+'([^']*)'\s+THEN|ELSE)\s+RETURN\s+wpol\(v_class,\s*'(\w+)',"
                      r"\s*([\d.]+),\s*([\d.]+)\)")
_DEF_RE = re.compile(r"RETURN\s+pol\((?:'([^']*)'|p_domain),\s*'([YN])',\s*'(\w+)',\s*([\d.]+|NULL),\s*([\d.]+|NULL)\)")


def _num(t):
    return None if t == "NULL" else float(t)


def _load_policy():
    """{('LOAD', name): (family, canonical, dir, min_pct, min_abs), ...} plus
    ('WAIT:event', name), ('WAIT:class', cls), ('WAIT:default', None),
    ('DEFAULT', domain) and ('DEFAULT', None)."""
    pol = {}
    domain = None
    wait_block = None          # 'event' / 'class'
    with open(_POLICY_PATH, encoding="utf-8") as fh:
        for line in fh:
            if line.strip() == "END IF;":
                domain, wait_block = None, None
                continue
            m = re.search(r"p_domain\s*(?:=\s*'(\w+)'|IN\s*\(([^)]*)\))", line)
            if m and "IF" in line:
                domain = m.group(1) or [x.strip(" '") for x in m.group(2).split(",")]
                wait_block = None
                continue
            if domain == "WAIT":
                if re.search(r"CASE\s+p_name", line):
                    wait_block = "event"
                    continue
                if re.search(r"CASE\s+v_class", line):
                    wait_block = "class"
                    continue
                m = _WPOL_RE.search(line)
                if m:
                    name, d, mp, ms = m.groups()
                    val = (None, "Y", d, float(mp), float(ms))
                    if name is None:
                        pol[("WAIT:default", None)] = val
                    else:
                        pol[("WAIT:" + wait_block, name)] = val
                continue
            m = _POL_RE.search(line)
            if m and domain in ("LOAD", "METRIC"):
                name, fam, can, d, mp, ma = m.groups()
                pol[(domain, name)] = (fam, can, d, _num(mp), _num(ma))
                continue
            m = _DEF_RE.search(line)
            if m and "WHEN" not in line:
                fam, can, d, mp, ma = m.groups()
                val = (fam, can, d, _num(mp), _num(ma))
                if isinstance(domain, list):
                    for dom in domain:
                        pol[("DEFAULT", dom)] = (dom, can, d, _num(mp), _num(ma))
                elif domain is not None and domain not in ("LOAD", "METRIC", "WAIT"):
                    pol[("DEFAULT", domain)] = val
                else:
                    pol[("DEFAULT", None)] = val
    return pol


_POLICY = _load_policy()


def metric_policy(domain, name, cls=None):
    """(family, canonical, dir, min_pct, min_abs) -- metric_policy()."""
    if domain == "WAIT":
        c = cls or (name[len("Wait class: "):] if name and name.startswith("Wait class: ") else None) or "Other"
        v = _POLICY.get(("WAIT:event", name)) or _POLICY.get(("WAIT:class", c)) \
            or _POLICY[("WAIT:default", None)]
        return ("WAIT:" + c,) + v[1:]
    v = _POLICY.get((domain, name)) or _POLICY.get(("DEFAULT", domain)) or _POLICY[("DEFAULT", None)]
    return v


def policy_bucket(domain, name, cls, cur, mu, sd, n, share=None, demote=False):
    """policy_bucket() of sql/lib/metric_policy.plsql."""
    if cur is None:
        return "n/a"
    if (n or 0) < 3:
        return "insufficient history"
    if mu is None or sd is None:
        return "flat baseline"
    den = max(sd, 0.02 * abs(mu))
    if den == 0:
        return "flat baseline"
    z = (cur - mu) / den
    if abs(z) <= 2:
        return "typical"
    fam, canon, d, min_pct, min_abs = metric_policy(domain, name, cls)
    pct = None if mu == 0 else (cur - mu) / abs(mu) * 100
    if pct is not None and abs(pct) < (10 if min_pct is None else min_pct):
        return "typical"
    if min_abs is not None:
        if domain == "WAIT":
            if share is not None and share < min_abs:
                return "typical"
        elif max(abs(cur), abs(mu)) < min_abs:
            return "typical"
    elif domain == "WAIT" and share is not None and share < 0.02:
        return "typical"
    if d == "INFO":
        return "noted"
    if (d == "UP" and cur < mu) or (d == "DOWN" and cur > mu):
        return "improved"
    raw = "large" if abs(z) > 3 else "moderate"
    if demote and raw == "large":
        return "moderate"
    return raw


def finding_family(domain, name, cls=None) -> str:
    fam = metric_policy(domain, name, cls)[0]
    return ("OTHER:" + name)[:64] if fam == "OTHER" else fam


def is_canonical(domain, name) -> str:
    return metric_policy(domain, name)[1]


def higher_is_worse(domain, name) -> str:
    """Legacy view of the policy direction: 'Y' for UP, '-' otherwise."""
    return "Y" if metric_policy(domain, name)[2] == "UP" else "-"


# ---------------------------------------------------------------------
# DBMS_XMLGEN.CONVERT / json_escape.plsql
# ---------------------------------------------------------------------

def esc(s) -> str:
    """DBMS_XMLGEN.CONVERT(s): & < > " ' escaped."""
    if s is None:
        return ""
    return (str(s).replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
            .replace('"', "&quot;").replace("'", "&apos;"))


def json_escape(s) -> str:
    if s is None:
        return ""
    return (str(s).replace("\\", "\\\\").replace('"', '\\"')
            .replace("\r", " ").replace("\n", " "))


# ---------------------------------------------------------------------
# sql/lib/is_essential.plsql / is_oracle_schema.plsql
# ---------------------------------------------------------------------

_ESS = {
    "LOAD": {"DB time", "DB CPU", "redo size", "session logical reads",
             "physical reads", "physical writes", "execute count",
             "user commits", "parse count (hard)"},
    "METRIC": {"Average Active Sessions", "SQL Service Response Time",
               "Database CPU Time Ratio", "Database Wait Time Ratio",
               "Host CPU Utilization (%)",
               "Average Synchronous Single-Block Read Latency",
               "Executions Per Sec", "User Calls Per Sec",
               "User Commits Per Sec", "Logical Reads Per Sec",
               "Hard Parse Count Per Sec"},
    "WAIT": {"db file sequential read", "db file scattered read",
             "direct path read", "direct path read temp",
             "direct path write temp", "log file sync",
             "log file parallel write", "buffer busy waits",
             "read by other session", "free buffer waits",
             "enq: TX - row lock contention", "library cache: mutex X",
             "cursor: pin S wait on X", "latch: cache buffers chains",
             "latch: shared pool", "resmgr:cpu quantum",
             "log file switch (checkpoint incomplete)",
             "db file parallel write", "db file async I/O submit",
             "gc buffer busy acquire", "gc buffer busy release",
             "gc cr block busy", "gc current block busy"},
}


def anchor_id(prefix: str, name) -> str:
    """sql/lib/anchor_id.plsql: lower-case, non [a-z0-9] runs -> '-', trimmed, 64 max."""
    v = re.sub(r"[^a-z0-9]+", "-", (name or "").lower())
    v = re.sub(r"^-+|-+$", "", v)
    return prefix + "-" + v[:64]


def finding_anchor(domain: str, name) -> str:
    """sql/lib/anchor_id.plsql finding_anchor(): the 07 findings row id."""
    return anchor_id("fr-" + domain[:1].lower(), name)


def is_essential(domain: str, name: str) -> str:
    if not name:
        return "N"
    return "Y" if name in _ESS.get(domain, ()) else "N"


_ORA_SCHEMAS = {
    'SYS', 'SYSTEM', 'SYSAUX', 'SYSBACKUP', 'SYSDG', 'SYSKM', 'SYSRAC',
    'SYS$UMF', 'DBSNMP', 'DBSFWUSER', 'APPQOSSYS', 'AUDSYS',
    'GSMADMIN_INTERNAL', 'GSMCATUSER', 'GSMUSER', 'GGSYS',
    'XDB', 'ANONYMOUS', 'XS$NULL', 'CTXSYS', 'MDSYS', 'MDDATA',
    'ORDSYS', 'ORDDATA', 'ORDPLUGINS', 'SI_INFORMTN_SCHEMA',
    'WMSYS', 'OLAPSYS', 'EXFSYS', 'OUTLN', 'DVSYS', 'DVF', 'LBACSYS',
    'OJVMSYS', 'ORACLE_OCM', 'REMOTE_SCHEDULER_AGENT', 'DGPDB_INT',
    'SPATIAL_CSW_ADMIN_USR', 'SPATIAL_WFS_ADMIN_USR',
    'FLOWS_FILES', 'APEX_PUBLIC_USER'}


def is_oracle_schema(schema) -> str:
    if not schema:
        return "N"
    s = str(schema).strip().upper()
    if s in _ORA_SCHEMAS or s.startswith("APEX_") or s.startswith("FLOWS_"):
        return "Y"
    return "N"


# ---------------------------------------------------------------------
# Date formatting twins of the TO_CHAR masks the sections use
# ---------------------------------------------------------------------

_DY = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
_DAY = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]
_MON = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]


def ts_min(dt) -> str:          # 'YYYY-MM-DD HH24:MI'
    return dt.strftime("%Y-%m-%d %H:%M")


def ts_sec(dt) -> str:          # 'YYYY-MM-DD HH24:MI:SS'
    return dt.strftime("%Y-%m-%d %H:%M:%S")


def ts_dy_min(dt) -> str:       # 'YYYY-MM-DD Dy HH24:MI'
    return f"{dt:%Y-%m-%d} {_DY[dt.weekday()]} {dt:%H:%M}"


def mon_dd(dt) -> str:          # 'Mon DD'
    return f"{_MON[dt.month-1]} {dt:%d}"


def mon_dd_hm(dt) -> str:       # 'Mon DD HH24:MI'
    return f"{_MON[dt.month-1]} {dt:%d} {dt:%H:%M}"


def dy(dt) -> str:
    return _DY[dt.weekday()]


def day_name(dt) -> str:        # TRIM(TO_CHAR(d,'Day'))
    return _DAY[dt.weekday()]


def hh24(dt) -> str:
    return dt.strftime("%H:%M")


# ---------------------------------------------------------------------
# LISTAGG-style positional CSV helpers (sql/lib/nth_csv.plsql contract)
# ---------------------------------------------------------------------

def csv_num6(vals, null_token="") -> str:
    """','-joined num6 values, None -> null_token (positional slots kept)."""
    return ",".join(null_token if v is None else num6(v) for v in vals)


# ---------------------------------------------------------------------
# sql/lib/finding_cards.plsql  (Summary vocabulary: names, units, cards)
# ---------------------------------------------------------------------

def card_group(family: str) -> str:
    if family in ("READ_IO", "SCANS", "LOGICAL_IO", "WAIT:User I/O"):
        return "IO"
    if family in ("DB_TIME", "CPU_WAIT_RATIO", "RESPONSE"):
        return "DBTIME"
    if family in ("WAIT:Network", "NETWORK"):
        return "NET"
    if family in ("WAIT:Commit", "COMMIT"):
        return "COMMIT"
    if family in ("PARSE", "HARD_PARSE", "CURSORS"):
        return "PARSE"
    if family in ("WRITE_IO", "REDO", "WAIT:System I/O"):
        return "WRITE"
    return family


_CARD_PRIMARY = {"IO": "READ_IO", "DBTIME": "DB_TIME", "NET": "WAIT:Network",
                 "COMMIT": "WAIT:Commit", "PARSE": "HARD_PARSE", "WRITE": "WRITE_IO"}


def card_primary(group: str) -> str:
    return _CARD_PRIMARY.get(group, group)


def card_label(group: str) -> str:
    fixed = {"IO": "Physical I/O", "DBTIME": "DB time", "NET": "Network", "COMMIT": "Commit",
             "PARSE": "Parsing", "WRITE": "Writes and redo"}
    if group in fixed:
        return fixed[group]
    if group.startswith("WAIT:"):
        return group[5:] + " waits"
    if group.startswith("OTHER:"):
        return group[6:]
    return " ".join(w.capitalize() for w in group.replace("_", " ").split(" "))


def card_id(group: str) -> str:
    v = re.sub(r"[^a-z0-9]+", "-", group.lower())
    return "f-" + re.sub(r"^-+|-+$", "", v)[:48]


_METRIC_LABEL = {
    "physical reads": "Physical reads", "physical read total bytes": "Physical read bytes",
    "Physical Read Total IO Requests Per Sec": "Read I/O requests",
    "Physical Write Total IO Requests Per Sec": "Write I/O requests",
    "session logical reads": "Logical reads", "table scans (long tables)": "Table scans (long tables)",
    "table fetch by rowid": "Rowid fetches", "DB time": "DB time", "DB CPU": "DB CPU",
    "CPU used by this session": "CPU used", "Database Wait Time Ratio": "Wait time ratio",
    "Database CPU Time Ratio": "CPU time ratio", "SQL Service Response Time": "SQL response time",
    "Average Active Sessions": "Average active sessions", "Host CPU Utilization (%)": "Host CPU",
    "Average Synchronous Single-Block Read Latency": "Single-block read latency",
    "execute count": "Executions", "user calls": "User calls", "user commits": "User commits",
    "user rollbacks": "User rollbacks", "redo size": "Redo generated", "redo writes": "Redo writes",
    "physical writes": "Physical writes", "physical write total bytes": "Write volume",
    "parse count (hard)": "Hard parses", "parse count (total)": "Parses (total)",
    "parse count (failures)": "Parse failures", "Session Count": "Sessions",
    "logons cumulative": "Logons", "opened cursors cumulative": "Cursors opened",
    "sorts (disk)": "Sorts (disk)", "sorts (memory)": "Sorts (memory)", "sorts (rows)": "Sorted rows",
    "bytes sent via SQL*Net to client": "Bytes to clients",
    "bytes received via SQL*Net from client": "Bytes from clients",
    "Network Traffic Volume Per Sec": "Network volume",
    "redo size for lost write detection": "Lost-write redo",
}


def metric_label(domain: str, name: str) -> str:
    if domain == "WAIT":
        return re.sub(r"^Wait class: ", "", name) + " waits"
    if name in _METRIC_LABEL:
        return _METRIC_LABEL[name]
    return name[:1].upper() + name[1:]


def metric_unit(domain: str, name: str) -> str:
    if domain == "WAIT":
        return "AAS"
    if domain == "LOAD":
        if name in ("DB time", "DB CPU", "CPU used by this session"):
            return "AAS"
        if "bytes" in name or name.startswith("redo size"):
            return "B/s"
        return "/s"
    if name == "SQL Service Response Time":
        return "ms/call"
    if name == "Session Count":
        return "sessions"
    if name == "Average Active Sessions":
        return "AAS"
    if "Latency" in name:
        return "ms"
    if "(%)" in name or "Ratio" in name:
        return "%"
    if name.endswith("Bytes Per Sec") or name == "Network Traffic Volume Per Sec":
        return "B/s"
    return "/s"


def metric_scale(domain: str, name: str) -> float:
    if domain == "LOAD" and name in ("DB time", "DB CPU", "CPU used by this session"):
        return 0.01
    if domain == "METRIC" and name == "SQL Service Response Time":
        return 10
    return 1


def _mul(v, s):
    return None if v is None else v * s


def fv_num(v, unit) -> str:
    if unit == "B/s" and v is not None:
        a = abs(v)
        return fmt_num(v / 1e9 if a >= 1e9 else v / 1e6 if a >= 1e6 else v / 1e3 if a >= 1e3 else v)
    return fmt_num(v)


def fv_unit(v, unit) -> str:
    if unit == "B/s" and v is not None:
        a = abs(v)
        return "GB/s" if a >= 1e9 else "MB/s" if a >= 1e6 else "kB/s" if a >= 1e3 else "B/s"
    return unit


def fv(v, unit) -> str:
    if v is None:
        return "&mdash;"
    u = fv_unit(v, unit)
    return fv_num(v, unit) + ("" if not u else u if u.startswith("/") else " " + u)


def fv_range(mu, sd, unit) -> str:
    if mu is None or sd is None:
        return "&mdash;"
    den = max(sd, 0.02 * abs(mu))
    hi = mu + 2 * den
    lo = max(0, mu - 2 * den)
    if unit == "B/s":
        a = abs(hi)
        div = 1e9 if a >= 1e9 else 1e6 if a >= 1e6 else 1e3 if a >= 1e3 else 1
        return fmt_num(lo / div) + "&ndash;" + fv(hi, "B/s")
    return fmt_num(lo) + "&ndash;" + fv(hi, unit)


def time_split(dbt_cur, dbt_mu, cpu_cur, cpu_mu):
    if None in (dbt_cur, dbt_mu, cpu_cur, cpu_mu):
        return None
    x = dbt_cur - dbt_mu
    if x <= 0:
        return None
    c = (cpu_cur - cpu_mu) / x
    return "W" if c <= 0.1 else "w" if c <= 0.4 else "c" if c >= 0.6 else "m"


def move_txt(cur, mu, bucket) -> str:
    cls = band_sev(bucket)
    if cur is None or mu is None or mu == 0:
        return "moved"
    q = cur / mu
    if mu > 0 and q >= 2:
        return ('<span class="d ' + cls + '">'
                + (to_char_fixed(q, 1) if q < 100 else to_char_fixed(ora_round(q, 0), 0))
                + '&times;</span> normal')
    pct = (cur - mu) / abs(mu) * 100
    return (("up " if pct >= 0 else "down ") + '<span class="d ' + cls + '">'
            + to_char_fixed(abs(pct), 1) + '%</span>')


def ent(html: str, aid: str, kind: str) -> str:
    return '<a class="ent" href="#' + aid + '" data-ent="' + kind + '">' + html + '</a>'


def sev_rank(bucket) -> int:
    return {"large": 2, "moderate": 1}.get(bucket, 0)


def lead_better(group, bkt_a, fam_a, z_a, bkt_b, fam_b, z_b, lab_a=None, lab_b=None) -> bool:
    if sev_rank(bkt_a) != sev_rank(bkt_b):
        return sev_rank(bkt_a) > sev_rank(bkt_b)
    pa, pb = int(fam_a == card_primary(group)), int(fam_b == card_primary(group))
    if pa != pb:
        return pa > pb
    za, zb = round(abs(z_a or 0), 6), round(abs(z_b or 0), 6)
    if za != zb:
        return za > zb
    return len(lab_a or "x" * 999) < len(lab_b or "x" * 999)


def card_before(sev_a, z_a, sev_b, z_b) -> bool:
    if sev_a != sev_b:
        return sev_a > sev_b
    return (z_a or 0) > (z_b or 0)


def card_order(groups: dict) -> list:
    """groups: {group: (sev, maxz)} in PL/SQL associative-array key order
    (sorted keys) -> the card order (insertion sort on card_before, then a
    flagged DBTIME card moves up to second place)."""
    order = []
    for g in sorted(groups):
        j = len(order)
        while j >= 1 and card_before(groups[g][0], groups[g][1], groups[order[j - 1]][0], groups[order[j - 1]][1]):
            j -= 1
        order.insert(j, g)
    if "DBTIME" in order[2:]:
        order.remove("DBTIME")
        order.insert(1, "DBTIME")
    return order


# ---------------------------------------------------------------------
# sql/lib/wingrid.plsql  (the ONE window component, .wg)
# ---------------------------------------------------------------------

def wg_tok(v) -> str:
    if v is None:
        return ""
    if v == 0:
        return "0"
    n = 6 - math.floor(math.log10(abs(v)))
    s = format(_rnd(v, n), "f")
    if "." in s:
        s = s.rstrip("0").rstrip(".")
    if s.startswith("0."):
        s = s[1:]
    elif s.startswith("-0."):
        s = "-" + s[2:]
    return s


def wg_pairs(vals) -> str:
    """{offset: value} (or a list indexed by offset) -> the 'k:v;k:v'
    LISTAGG string (ORDER BY week_offset, non-null values only)."""
    if isinstance(vals, (list, tuple)):
        vals = {k: v for k, v in enumerate(vals)}
    return ";".join(str(k) + ":" + wg_tok(v) for k, v in sorted(vals.items()) if v is not None)


def _wg_vals(vals):
    if isinstance(vals, (list, tuple)):
        return {k: v for k, v in enumerate(vals)}
    return vals


def _wg_start(w, k):
    from datetime import timedelta
    return w.target_end - timedelta(hours=w.step_hours * k) - timedelta(hours=w.win_hours)


def _wg_end(w, k):
    from datetime import timedelta
    return w.target_end - timedelta(hours=w.step_hours * k)


def wg_date(w, k) -> str:
    s = _wg_start(w, k)
    if w.step_hours >= 24:
        return str(s.day) + " " + _MON[s.month - 1]
    return s.strftime("%H:%M")


def wg_off(w, k) -> str:
    return "current" if k == 0 else "&minus;" + w.offset_labels[k - 1]


def wg_title(w, k) -> str:
    s, e = _wg_start(w, k), _wg_end(w, k)
    return (_DY[s.weekday()] + " " + s.strftime("%d") + " " + _MON[s.month - 1] + ", "
            + s.strftime("%H:%M") + "&ndash;" + e.strftime("%H:%M"))


def wg_keep(w, k) -> str:
    return " keep" if k == 0 or (w.weeks_back - k) % 4 == 0 else ""


def wg_attr(w) -> str:
    return ' data-wg style="--np:' + str(w.weeks_back) + '"'


def wg_csv(w, vals, scale=1) -> str:
    v = _wg_vals(vals)
    return ",".join(wg_tok(_mul(v.get(k), scale)) for k in range(w.weeks_back, -1, -1))


def wg_flags(bare=True) -> str:
    if bare:
        return '<div class="r fr t2" aria-hidden="true"><div class="flags"></div></div>'
    return ('<div class="r fr"><div class="l"></div><div class="flags"'
            ' aria-label="Release and patch markers"></div><div class="g"></div></div>')


def wg_dates(w, bare=True) -> str:
    out = '<div class="r dr" aria-hidden="true">'
    if not bare:
        out += '<div class="l"></div>'
    for k in range(w.weeks_back, -1, -1):
        out += ('<div class="h' + (" cur" if k == 0 else "") + wg_keep(w, k)
                + '" data-w="' + str(k) + '"><span class="hd">' + wg_date(w, k) + '</span>'
                + ('' if bare else '<span class="ho">' + wg_off(w, k) + '</span>') + '</div>')
    if not bare:
        out += '<div class="g"></div>'
    return out + '</div>'


def wg_ruler(w, corner: str, gh: str, btn: str = "N") -> str:
    tag = "button" if btn == "Y" else "div"
    out = ('<div class="ruler"><div class="rin" role="row">'
           '<div class="corner" role="columnheader">' + corner + '</div>'
           '<div class="flags" aria-label="Release and patch markers"></div>')
    for k in range(w.weeks_back, -1, -1):
        out += ('<' + tag + ' class="h' + (" cur" if k == 0 else "") + wg_keep(w, k) + '"'
                + (' type="button" aria-pressed="false"' if btn == "Y" else "")
                + ' data-w="' + str(k) + '" role="columnheader" title="' + wg_title(w, k)
                + (('. Click to pin as the comparison target' if k > 0 else '. The Current window')
                   if btn == "Y" else "") + '">'
                + '<span class="hd">' + wg_date(w, k) + '</span>'
                + '<span class="ho">' + wg_off(w, k) + '</span></' + tag + '>')
    return out + '<div class="gh" role="columnheader">' + gh + '</div></div></div>'


def wg_bars(w, vals, scale, mu, sd, sev, lab="", gut="", rid=None, cls=None) -> str:
    v = _wg_vals(vals)
    out = ('<div class="r bars' + ((" " + cls) if cls else "") + '"'
           + ((' id="' + rid + '"') if rid else "")
           + ' data-v="' + wg_csv(w, v, scale) + '"'
           + ' data-mu="' + wg_tok(_mul(mu, scale)) + '"'
           + ' data-sd="' + wg_tok(_mul(sd, scale)) + '"'
           + ' data-sev="' + (sev or "") + '" role="row">' + (lab or ""))
    for k in range(w.weeks_back, -1, -1):
        x = _mul(v.get(k), scale)
        out += ('<div class="c' + (" cur" if k == 0 else "") + '" data-w="' + str(k) + '">'
                + ('<span class="v nil" aria-label="no value">&ndash;</span>' if x is None
                   else '<span class="v">' + fmt_num(x) + '</span>') + '</div>')
    return out + (gut or "") + '</div>'


# ---------------------------------------------------------------------
# sql/lib/timeline.plsql  (the Timeline view's grid rows)
# ---------------------------------------------------------------------

def tl_open(lane: str) -> str:
    return '<template class="tl-src" data-lane="lane-' + lane + '">'


def tl_close() -> str:
    return '</template><script>if(window.AWR_TL)AWR_TL.take();</script>'


def tl_nth(csv, k):
    """Token k (1-based) of a comma list; '' / 'null' / missing -> None."""
    if csv is None:
        return None
    parts = csv.split(",")
    if k < 1 or k > len(parts):
        return None
    t = parts[k - 1]
    return None if t in ("", "null") else t


def tl_csv(w, csv, asc="N", div=1) -> str:
    out = []
    for k in range(w.weeks_back, -1, -1):
        t = tl_nth(csv, k + 1 if asc == "Y" else w.weeks_back - k + 1)
        out.append("" if t is None else wg_tok(float(t) / div))
    return ",".join(out)


def tl_val(w, csv, off):
    t = tl_nth(csv, w.weeks_back - off + 1)
    return None if t is None else float(t)


def tl_mu(w, csv):
    vals = [tl_val(w, csv, k) for k in range(1, w.weeks_back + 1)]
    vals = [v for v in vals if v is not None]
    return sum(vals) / len(vals) if vals else None


def tl_first(w, csv):
    if tl_val(w, csv, w.weeks_back) is not None:
        return None
    for k in range(w.weeks_back - 1, -1, -1):
        if tl_val(w, csv, k) is not None:
            return k
    return None


def tl_lab(nm, sub=None, ttl=None, wc=None) -> str:
    return ('<div class="l" role="rowheader"' + ((' title="' + ttl + '"') if ttl else '') + '>'
            + '<span class="nm">'
            + (('<i class="sw" data-wc="' + esc(wc) + '" aria-hidden="true"></i>') if wc else '')
            + nm + '</span>'
            + (('<span class="sub">' + sub + '</span>') if sub else '')
            + '</div>')


def tl_gut(cur, mu, sd, bucket, note=None, twin="N") -> str:
    z = band_z(cur, mu, sd)
    zpart = ""
    if note:
        zpart = note
    elif z is not None and -4 <= z <= 8 and (bucket or "x") not in (
            "flat baseline", "insufficient history", "n/a"):
        zpart = '<span class="z">z ' + band_ztxt(z) + '</span>'
    return ('<div class="g" role="cell"><div class="gl1">'
            + delta_span(cur, mu, bucket).replace('class="d ', 'class="d d1 ', 1)
            + zpart + '</div>' + band_span(z, bucket, "sm", twin) + '</div>')


def tl_gutp(cur, mu, note) -> str:
    return ('<div class="g" role="cell" title="Ranked, not scored"><div class="gl1">'
            + delta_span(cur, mu, None, "Y").replace('class="d ', 'class="d d1 ', 1)
            + '</div><div class="gx">' + note + '</div></div>')


def tl_bars(w, csv, mu, sd, sev, lab, gut, rid, cls=None, name=None, unit=None,
            gw=None, gl=None, after=None) -> str:
    cur = tl_val(w, csv, 0)
    out = ('<div class="r bars' + ((" " + cls) if cls else "") + '"'
           + ' id="' + rid + '" data-v="' + csv + '"'
           + ' data-mu="' + wg_tok(mu) + '" data-sd="' + wg_tok(sd) + '"'
           + ' data-sev="' + (sev or "") + '"'
           + ((' data-name="' + name + '"') if name else '')
           + ((' data-unit="' + unit + '"') if unit else '')
           + ((' data-after="' + after + '"') if after else '')
           + ' role="row">' + lab)
    for k in range(w.weeks_back, -1, -1):
        out += '<div class="c' + (" cur" if k == 0 else "") + '" data-w="' + str(k) + '">'
        if k == 0:
            out += ('<span class="v nil" aria-label="no value">&ndash;</span>' if cur is None
                    else '<span class="v">' + fmt_num(cur) + '</span>')
        if gw is not None and k == gw:
            out += gl or ""
        out += '</div>'
    return out + gut + '</div>'
