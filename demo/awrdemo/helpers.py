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
    """sql/lib/score_cells.plsql score_cells(cur, mu, sd, n, share, domain, name, class, demote)."""
    z, pct = z_and_pct(cur, mu, sd)
    bucket = policy_bucket(domain, name, cls, cur, mu, sd, n, share, demote)
    cls = bucket_cls(bucket)
    sig = sigma_flag(mu, sd)
    imm = bucket == "typical" and z is not None and abs(z) > 2
    zt = z_txt(z, 2)
    pt = pct_txt(pct)
    title = (' title="part of a table-wide shift; see the note above the table"'
             if demote and bucket == "moderate" else "")
    return ('<td><span class="badge ' + cls + '"' + title + '>' + bucket + '</span></td>'
            '<td class="num">' + zt + (SIG_BADGE if sig else "") + (IMM_BADGE if imm else "") + '</td>'
            '<td class="num">' + ("<b>" + pt + "</b>" if sig else pt) + '</td>')


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
# sql/lib/dev_bucket.plsql
# ---------------------------------------------------------------------

def dev_attr(cur, prior) -> str:
    if prior is None:
        return ""
    if cur is None or cur == 0:
        return "" if prior == 0 else ' data-dev="3"'
    r = abs(prior - cur) / abs(cur)
    if r < 0.10:
        return ""
    if r < 0.25:
        return ' data-dev="1"'
    if r < 0.50:
        return ' data-dev="2"'
    return ' data-dev="3"'


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
