"""
Python twins of the report's shared PL/SQL helpers (sql/lib/*.plsql) plus
a few Oracle formatting primitives, so the demo generator emits the SAME
markup / number strings the real report does.

Everything here is pure and deterministic.  Keep the rules in lockstep
with the PL/SQL originals named in each docstring.
"""
from __future__ import annotations

import math
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
    return mu, math.sqrt(var), n


def z_and_pct(cur, mu, sd):
    z = None if (cur is None or mu is None or sd is None or sd == 0) else (cur - mu) / sd
    pct = None if (cur is None or mu is None or mu == 0) else (cur - mu) / abs(mu) * 100
    return z, pct


def bucket_of(cur, n, sd, z):
    """The report's change bucket (07/08/score_cells 'scored' CASE)."""
    if cur is None:
        return "n/a"
    if (n or 0) < 3:
        return "insufficient history"
    if sd is None or sd == 0:
        return "flat baseline"
    if abs(z) > 3:
        return "large"
    if abs(z) > 2:
        return "moderate"
    return "typical"


BUCKET_CLS = {"large": "crit", "moderate": "warn", "typical": "ok"}


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
             '&sigma; below 1% of mean; read the % delta instead">'
             '&sigma;&approx;0</span>')


def score_cells(cur, mu, sd, n) -> str:
    z, pct = z_and_pct(cur, mu, sd)
    bucket = bucket_of(cur, n, sd, z)
    cls = bucket_cls(bucket)
    sig = sigma_flag(mu, sd)
    zt = z_txt(z, 2)
    pt = pct_txt(pct)
    return ('<td><span class="badge ' + cls + '">' + bucket + '</span></td>'
            '<td class="num">' + zt + (SIG_BADGE if sig else "") + '</td>'
            '<td class="num">' + ("<b>" + pt + "</b>" if sig else pt) + '</td>')


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
