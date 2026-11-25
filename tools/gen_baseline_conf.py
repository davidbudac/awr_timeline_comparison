#!/usr/bin/env python3
"""Plan 039: the "how often does an unchanged metric look changed" table.

The report scores Current against n prior windows: z = (Current - mean) /
max(sd, 2 % of |mean|), mean and SAMPLE sd from the n prior values.  For a
normally distributed metric that did not change, z / sqrt(1 + 1/n) follows
Student's t with n - 1 degrees of freedom, so the nominal chance of
|z| > c is 2 * (1 - T(c / sqrt(1 + 1/n))).  c = 2 (moderate) and c = 3
(large), per metric, before the size floors and the direction rule.

  python3 tools/gen_baseline_conf.py            print the table (n = 3 .. 60)
  python3 tools/gen_baseline_conf.py --emit     the WHEN lines for
                                                sql/lib/baseline_conf.plsql
  python3 tools/gen_baseline_conf.py --check    fail when that file differs
                                                (tolerance 0.01 percentage points)

Stdlib only; the integration is Simpson's rule on the t density over
(0, 1] (t = x + (1 - s) / s), accurate to well under 1e-6.
"""
import math
import os
import re
import sys

NMIN, NMAX = 3, 60


def t_pdf(x, v):
    c = math.exp(math.lgamma((v + 1) / 2) - math.lgamma(v / 2)) / math.sqrt(v * math.pi)
    return c * (1 + x * x / v) ** (-(v + 1) / 2)


def t_sf(x, v, steps=20000):
    h = 1.0 / steps
    tot = 0.0
    for i in range(steps + 1):
        s = i * h
        f = 0.0 if i == 0 else t_pdf(x + (1 - s) / s, v) / (s * s)
        w = 1 if i in (0, steps) else (4 if i % 2 else 2)
        tot += w * f
    return tot * h / 3


def rates(n):
    """(percent outside +/-2 sigma, percent outside +/-3 sigma) for n priors."""
    r = math.sqrt(1 + 1.0 / n)
    return 200 * t_sf(2 / r, n - 1), 200 * t_sf(3 / r, n - 1)


def emit():
    lines = {"mod": [], "large": []}
    for n in range(NMIN, NMAX + 1):
        pm, pl = rates(n)
        lines["mod"].append("            WHEN %d THEN RETURN %.2f;" % (n, pm))
        lines["large"].append("            WHEN %d THEN RETURN %.2f;" % (n, pl))
    return lines


def parse_plsql(path):
    """{'mod': {n: pct}, 'large': {n: pct}} from the two CASE blocks."""
    out, cur = {"mod": {}, "large": {}}, None
    with open(path, encoding="ascii") as fh:
        for ln in fh:
            m = re.match(r"\s*FUNCTION conf_(mod|large)\b", ln)
            if m:
                cur = m.group(1)
            m = re.match(r"\s*WHEN (\d+) THEN RETURN ([0-9.]+);", ln)
            if m and cur:
                out[cur][int(m.group(1))] = float(m.group(2))
    return out


def main(argv):
    if "--emit" in argv:
        e = emit()
        print("-- conf_mod\n" + "\n".join(e["mod"]) + "\n-- conf_large\n" + "\n".join(e["large"]))
        return 0
    if "--check" in argv:
        root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
        got = parse_plsql(os.path.join(root, "sql", "lib", "baseline_conf.plsql"))
        bad = []
        for n in range(NMIN, NMAX + 1):
            pm, pl = rates(n)
            if abs(got["mod"].get(n, -1) - pm) > 0.01:
                bad.append("conf_mod(%d): %s vs %.2f" % (n, got["mod"].get(n), pm))
            if abs(got["large"].get(n, -1) - pl) > 0.01:
                bad.append("conf_large(%d): %s vs %.2f" % (n, got["large"].get(n), pl))
        if bad:
            print("baseline_conf.plsql differs from the t distribution:\n  " + "\n  ".join(bad))
            return 1
        print("baseline_conf.plsql matches the t distribution for n = %d .. %d" % (NMIN, NMAX))
        return 0
    print("n   |z|>2 %   |z|>3 %   1 in   1 in")
    for n in range(NMIN, NMAX + 1):
        pm, pl = rates(n)
        print("%-3d %6.2f   %6.2f   %5.1f  %6.1f" % (n, pm, pl, 100 / pm, 100 / pl))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
