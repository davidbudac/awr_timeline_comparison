#!/usr/bin/env bash
# tools/check.sh -- every DB-free check in one command (CI runs exactly this).
#   1. ./lint.sh                      static lint of the SQL*Plus sources
#   2. bash -n                        syntax of every tracked *.sh
#   3. strict Python parse            any SyntaxWarning in a tracked *.py is an error
#   4. server unit tests              python3 -m unittest (stdlib only)
#   5. generated docs                 demo report + policy page match their generators
# Read-only: writes nothing but Python bytecode caches.  Dev/CI tooling only;
# nothing in the report path may depend on it.
set -u
cd "$(dirname "$0")/.." || exit 2
fail=0
step() { printf '\n== %s\n' "$1"; }

step "lint.sh"
./lint.sh || fail=1

step "bash -n (tracked *.sh)"
for f in $(git ls-files '*.sh'); do
    bash -n "$f" || { echo "syntax error: $f"; fail=1; }
done

step "python strict parse (tracked *.py)"
python3 -W error - <<'PY' || fail=1
import ast
import subprocess
import sys

bad = 0
files = subprocess.check_output(["git", "ls-files", "*.py"]).decode().split()
for path in files:
    with open(path, encoding="utf-8") as fh:
        src = fh.read()
    try:
        ast.parse(src, path)
    except (SyntaxError, Warning) as exc:
        print("%s: %s" % (path, exc))
        bad = 1
print("%d file(s) parsed" % len(files))
sys.exit(bad)
PY

step "server unit tests"
python3 -m unittest discover -s server/tests -t . || fail=1

step "generated docs are fresh (demo report, policy page)"
python3 demo/gen_demo_report.py --check || fail=1
python3 docs/gen_policy_doc.py --check || fail=1

echo
if [ "$fail" -eq 0 ]; then echo "check.sh: all checks passed"; else echo "check.sh: FAILED"; fi
exit "$fail"
