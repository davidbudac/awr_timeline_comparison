# Plan 003: CI runs every DB-free check (lint, shell syntax, strict Python parse, server tests) on every push and PR

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**:
> `git diff --stat e755b97..HEAD -- .github/workflows/lint.yml tools/ CLAUDE.md`
> If `.github/workflows/lint.yml` changed since this plan was written,
> compare the "Current state" excerpt against the live file before
> proceeding; on a mismatch, treat it as a STOP condition.

## Status

- **Priority**: P1
- **Effort**: S
- **Risk**: LOW
- **Depends on**: plans/001-server-parse-took-field.md, plans/002-server-views-raw-strings.md
- **Category**: dx
- **Planned at**: commit `e755b97`, 2026-11-13

## Why this matters

The only CI job runs `./lint.sh`, and on pushes to `main` only when
`awr_trend.sql`, `sql/**` or `lint.sh` changed. The repo also has 137 server
unit tests, two large bash wrappers and ~50 Python files that nothing runs
automatically. A wrapper change broke the server's parser months ago and no
check noticed (plan 001); a Python escape bug sat as a warning (plan 002).
After this plan one script, `tools/check.sh`, runs every check that needs no
database, and CI runs that script on every push to `main` and every PR.

## Current state

`.github/workflows/lint.yml` in full:

```yaml
name: Lint SQL sources

on:
  push:
    branches: [main]
    paths:
      - 'awr_trend.sql'
      - 'sql/**'
      - 'lint.sh'
      - '.github/workflows/lint.yml'
  pull_request:
  workflow_dispatch:

permissions:
  contents: read

jobs:
  lint:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout
        uses: actions/checkout@v6

      - name: Run lint.sh
        run: ./lint.sh
```

(The file also has a 5-line `#` header comment above `name:`.)

Other facts, verified at the planned-at commit:

- `./lint.sh` → `lint: clean (76 files checked)`, about 3 s.
- `python3 -m unittest discover -s server/tests -t .` → 137 tests, `OK`,
  about 2 s, standard library only. The tests execute a bash test double
  (`server/tests/fake_bin/run_awr_fleet.sh`), so `bash` must exist (it does
  on `ubuntu-latest`).
- `bash -n` passes for all 8 tracked `*.sh` files.
- A strict parse of all 53 tracked `*.py` files passes **except**
  `server/app/views.py` (`invalid escape sequence '\s'`) — fixed by plan 002.
  This is why this plan depends on 002.
- `tools/` currently holds one file, `tools/js2plsql.sh` (a dev-time
  generator; `lint.sh` already calls its `--check` mode).
- There is a second workflow, `.github/workflows/pages.yml`, that deploys
  `docs/` — not touched here.
- `CLAUDE.md` is the agent/contributor guide (`AGENTS.md` is a symlink to
  it). Its "Verification & testing" section starts with the bullet
  "**`./lint.sh` first** (also runs in CI): …".

Conventions:

- Shell scripts in this repo must avoid GNU-only flags (they run on AIX /
  Solaris DB hosts). `tools/check.sh` is dev/CI tooling, but keep it plain:
  no `grep -o`, no `sed -E`, no `find -maxdepth`.
- Nothing under `sql/`, `awr_trend.sql` or the wrappers may depend on Python;
  this script is tooling only and nothing may call it from the report path.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| New all-in-one check | `./tools/check.sh` | last line `check.sh: all checks passed`, exit 0 |
| Lint only | `./lint.sh` | `lint: clean (N files checked)`, exit 0 |
| Shell syntax of the new script | `bash -n tools/check.sh` | exit 0 |
| YAML sanity | `python3 -c "import yaml,sys; yaml.safe_load(open('.github/workflows/lint.yml'))"` | exit 0 (skip if PyYAML is not installed; do not install it) |

## Scope

**In scope** (the only files you should modify):
- `tools/check.sh` (create, executable)
- `.github/workflows/lint.yml`
- `CLAUDE.md` (one bullet in "Verification & testing")

**Out of scope** (do NOT touch):
- `lint.sh` — its checks stay as they are; `check.sh` only calls it.
- `.github/workflows/pages.yml`.
- Adding Node/Playwright (`demo/verify_report.js`) or generator freshness
  checks to CI — that is plan 014.
- Installing any package in CI. Everything used here ships with the runner.

## Git workflow

- Branch: `advisor/003-ci-run-all-db-free-checks` from `main` (after 001 and 002 are merged, or stacked on them).
- Commit style: conventional commits with scope. Suggested:
  `ci: run shell syntax, strict Python parse and server tests on every push`.
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Confirm the prerequisites landed

**Verify**:
- `python3 -W error -c "import ast; ast.parse(open('server/app/views.py').read())"` → exit 0 (plan 002 done). If it fails → STOP.
- `python3 -m unittest discover -s server/tests -t .` → `OK`.

### Step 2: Create `tools/check.sh`

Create the file with exactly this content, then `chmod +x tools/check.sh`:

```bash
#!/usr/bin/env bash
# tools/check.sh -- every DB-free check in one command (CI runs exactly this).
#   1. ./lint.sh                      static lint of the SQL*Plus sources
#   2. bash -n                        syntax of every tracked *.sh
#   3. strict Python parse            any SyntaxWarning in a tracked *.py is an error
#   4. server unit tests              python3 -m unittest (stdlib only)
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

echo
if [ "$fail" -eq 0 ]; then echo "check.sh: all checks passed"; else echo "check.sh: FAILED"; fi
exit "$fail"
```

(This exact script was dry-run against the planned-at commit: lint clean,
8 shell files OK, 53 Python files parsed with the single `views.py`
failure that plan 002 removes, 137 tests OK.)

**Verify**:
- `bash -n tools/check.sh` → exit 0.
- `./tools/check.sh; echo "rc=$?"` → ends with `check.sh: all checks passed` and `rc=0`.
- `./lint.sh` → still `lint: clean` (lint scans shell files; the new script must not trip it).

### Step 3: Prove each gate can fail

Run each of these, confirm `./tools/check.sh` exits non-zero and names the
problem, then undo the change:

1. `printf 'x = "\\d"\n' > server/app/_tmp_bad.py && git add -N server/app/_tmp_bad.py`
   → `./tools/check.sh` prints `server/app/_tmp_bad.py: invalid escape sequence` and exits 1.
   Undo: `git reset -q server/app/_tmp_bad.py && rm server/app/_tmp_bad.py`.
2. `printf 'if then\n' > tools/_tmp_bad.sh && git add -N tools/_tmp_bad.sh`
   → `./tools/check.sh` prints `syntax error: tools/_tmp_bad.sh` and exits 1.
   Undo: `git reset -q tools/_tmp_bad.sh && rm tools/_tmp_bad.sh`.

**Verify**: after both undos, `git status --short` lists only
`tools/check.sh` (and the workflow/CLAUDE.md once edited) and
`./tools/check.sh` exits 0.

### Step 4: Point CI at the script and drop the path filter

Edit `.github/workflows/lint.yml`:

1. Replace the header comment with one that says the workflow runs
   `tools/check.sh`: the static SQL lint (`lint.sh`) plus shell syntax, a
   strict Python parse and the server unit tests — none needs a database.
2. Change `name: Lint SQL sources` to `name: Checks`.
3. Remove the whole `paths:` block under `push:` (keep `branches: [main]`),
   so every push to `main` is checked. Keep `pull_request:` and
   `workflow_dispatch:` as they are.
4. Keep the job id `lint` and the `Checkout` step unchanged. Replace the
   last step with:

```yaml
      - name: Run tools/check.sh (lint, shell syntax, Python parse, server tests)
        run: ./tools/check.sh
```

Resulting `on:` block:

```yaml
on:
  push:
    branches: [main]
  pull_request:
  workflow_dispatch:
```

**Verify**:
- `grep -n "paths:" .github/workflows/lint.yml` → no matches.
- `grep -n "tools/check.sh" .github/workflows/lint.yml` → 1 or more matches.
- `git ls-files -s tools/check.sh` after `git add tools/check.sh` shows mode `100755`.

### Step 5: Document the one command

In `CLAUDE.md`, section "## Verification & testing", insert a new first
bullet **before** the existing "**`./lint.sh` first** …" bullet:

```markdown
- **`./tools/check.sh` is the one command** (CI runs exactly this on every
  push to `main` and every PR): `./lint.sh`, `bash -n` on every tracked
  `*.sh`, a strict parse of every tracked `*.py` (a `SyntaxWarning` fails)
  and the server unit tests (`python3 -m unittest discover -s server/tests
  -t .`). No DB needed, about 5 s.
```

Do not edit any other line of `CLAUDE.md`. (`AGENTS.md` is a symlink to it —
do not touch the symlink.)

**Verify**: `git diff --stat -- CLAUDE.md` → 1 file changed, insertions only.

## Test plan

- No unit tests are added; the deliverable is the check script itself.
- Step 3 is the test: each new gate is shown to fail on a seeded defect.
- Verification: `./tools/check.sh` → `check.sh: all checks passed`, exit 0.

## Done criteria

- [ ] `./tools/check.sh` exits 0 and prints `check.sh: all checks passed`
- [ ] `grep -c "paths:" .github/workflows/lint.yml` prints `0`
- [ ] `grep -c "tools/check.sh" .github/workflows/lint.yml` ≥ 1
- [ ] `tools/check.sh` is tracked with mode 100755
- [ ] `git status --short` shows only `tools/check.sh`, `.github/workflows/lint.yml`, `CLAUDE.md`
- [ ] `plans/README.md` status row updated

## STOP conditions

- Step 1 fails (plans 001/002 not applied) — do not paper over it by
  excluding `server/app/views.py` or skipping the tests.
- `./tools/check.sh` fails for a reason other than a seeded defect, e.g. a
  server test that fails only on your machine — report the failing test and
  its output.
- The repository has branch-protection docs or a README badge that names
  the workflow "Lint SQL sources" (`grep -rn "Lint SQL sources" --include='*.md' .`
  finds a match outside `plans/`) — report it instead of renaming.

## Maintenance notes

- New DB-free checks (generator freshness in plan 014, a future JS check)
  go into `tools/check.sh`, not into the workflow file, so local and CI
  runs stay identical.
- The strict parse uses the runner's `python3` (3.12 on `ubuntu-latest` at
  the time of writing); a newer Python may flag new warnings — fix the
  source, do not relax `-W error`.
- Reviewer: confirm the job id is still `lint` (a required-status rule may
  reference it) and that nothing is installed in CI.
