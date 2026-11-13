# Plan 014: A stale demo report or policy page fails the check instead of deploying silently

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**:
> `git diff --stat e755b97..HEAD -- demo/gen_demo_report.py docs/gen_policy_doc.py tools/check.sh docs/examples/demo_busy_db.html docs/metric_policy.html`
> `tools/check.sh` is expected to be new (created by plan 003). If either
> generator changed since this plan was written, compare the "Current
> state" excerpts against the live code before proceeding; on a mismatch,
> treat it as a STOP condition.

## Status

- **Priority**: P3
- **Effort**: S
- **Risk**: LOW
- **Depends on**: plans/003-ci-run-all-db-free-checks.md (adds `tools/check.sh`, which this plan extends)
- **Category**: tests
- **Planned at**: commit `e755b97`, 2026-11-13

## Why this matters

Two published pages are generated from the SQL sources by Python scripts:
`docs/examples/demo_busy_db.html` (the public demo report, which lifts CSS
and JavaScript literally out of the `sql/` files) and
`docs/metric_policy.html` (the scoring reference, generated from
`sql/lib/metric_policy.plsql`). The project rule is "when a section's
markup/JS or the policy changes, regenerate in the same commit" — but
nothing checks it, and `docs/` deploys to GitHub Pages on every push. A
forgotten regeneration ships a demo that no longer matches the code. Both
generators are deterministic, so a `--check` mode that compares the
generator's output with the committed file is cheap (about 3 seconds) and
turns the rule into a gate. It also gives every SQL change a database-free
signal that the client JavaScript still assembles.

## Current state

### `demo/gen_demo_report.py` (157 lines)

Entry point (`:134-157`):

```python
def main(argv):
    args = [a for a in argv if not a.startswith("--")]
    flags = {a for a in argv if a.startswith("--")}
    out_path = args[0] if args else DEFAULT_OUT
    w = world()
    if "--cdn" in flags:
        src = "https://cdn.jsdelivr.net/npm/echarts@5/dist/echarts.min.js"
    else:
        src = w.echarts
    only = None
    for f in flags:
        if f.startswith("--only="):
            only = set(f[len("--only="):].split(","))
    html = render(w, src, only)
    if "--cdn" not in flags and "--no-inline" not in flags:
        html = inline_echarts(html, src)
    os.makedirs(os.path.dirname(out_path) or ".", exist_ok=True)
    with open(out_path, "w", encoding="utf-8") as fh:
        fh.write(html)
    print(f"wrote {out_path} ({len(html.encode('utf-8'))/1024:.0f} KB)")


if __name__ == "__main__":
    main(sys.argv[1:])
```

`DEFAULT_OUT` is `<repo>/docs/examples/demo_busy_db.html`. Verified at the
planned-at commit: running the generator into a scratch file produces
exactly the committed file (same md5), in about 3 seconds.

### `docs/gen_policy_doc.py` (389 lines)

It imports the demo's policy parser (`sys.path.insert(0, <repo>/demo)`;
`from awrdemo import helpers as h`). `main()` takes no arguments
(`:278`: `def main() -> None:`), builds a list `parts`, and stamps
**today's date** into the page (`:305-310`):

```python
    gen = _dt.datetime.now().strftime("%Y-%m-%d")
    parts = [f"""<!DOCTYPE html>
...
<p class="sub">Generated {gen} from <code>sql/lib/metric_policy.plsql</code> by <code>docs/gen_policy_doc.py</code>.
```

and ends (`:384-389`):

```python
    with open(OUT, "w", encoding="utf-8") as fh:
        fh.write("\n".join(parts))
    print(f"wrote {OUT} ({len(load)} load, {len(metric)} metric, {len(wclass)} wait classes, {len(wevent)} event overrides)")


if __name__ == "__main__":
    main()
```

The committed page contains `Generated 2026-09-26 from …`. Verified at the
planned-at commit: generating with that date substituted reproduces the
committed file byte for byte. So the date is the only non-deterministic
part, and a check must compare "as if generated on the date already in the
file".

### `tools/check.sh` (from plan 003)

A bash script that runs four steps (`lint.sh`, `bash -n`, a strict Python
parse, the server unit tests), each introduced by `step "<title>"`, sets
`fail=1` on failure and ends with:

```bash
echo
if [ "$fail" -eq 0 ]; then echo "check.sh: all checks passed"; else echo "check.sh: FAILED"; fi
exit "$fail"
```

CI (`.github/workflows/lint.yml`) runs `./tools/check.sh`.

### Conventions

- These generators are docs tooling in Python (f-strings and type hints are
  used here, unlike `server/app`). Nothing under `sql/`, `awr_trend.sql` or
  the wrappers may depend on them.
- Normal (non-check) behaviour and output of both generators must not
  change at all.
- `demo/README.md` documents the generator's flags; `CLAUDE.md` section
  "Demo report (`demo/`, docs-only)" states the regenerate rule.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Demo check | `python3 demo/gen_demo_report.py --check` | `up to date: …`, exit 0 |
| Policy check | `python3 docs/gen_policy_doc.py --check` | `up to date: …`, exit 0 |
| Everything | `./tools/check.sh` | `check.sh: all checks passed` |
| Strict parse | `python3 -W error -c "import ast,sys; [ast.parse(open(f).read(), f) for f in sys.argv[1:]]" demo/gen_demo_report.py docs/gen_policy_doc.py` | exit 0 |

## Scope

**In scope** (the only files you should modify):
- `demo/gen_demo_report.py`
- `docs/gen_policy_doc.py`
- `tools/check.sh`
- `demo/README.md` (document `--check`)
- `CLAUDE.md` (one sentence in the "Demo report" section)

**Out of scope** (do NOT touch):
- `docs/examples/demo_busy_db.html`, `docs/metric_policy.html` — they are in
  sync at the planned-at commit; this plan must not change them. If a check
  says they are stale, see STOP conditions.
- `demo/awrdemo/**` (the model and the section twins).
- `demo/verify_report.js` / Playwright in CI — needs Node and a browser;
  recorded as a direction option in `plans/README.md`.
- `.github/workflows/*` — CI already runs `tools/check.sh`.

## Git workflow

- Branch: `advisor/014-generators-check-mode` from `main` (after plan 003).
- Commit style: conventional commits with scope. Suggested:
  `test(docs): --check mode for the demo and policy generators, run in check.sh`.
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Confirm the baseline is in sync

Run `python3 demo/gen_demo_report.py` (this rewrites the tracked demo file
with identical content).

**Verify**: `git status --short docs/examples/demo_busy_db.html` → no
output. If the file shows as modified, another change landed without
regenerating — STOP and report (do not commit the regenerated file as part
of this plan).

### Step 2: `--check` for the demo generator

In `demo/gen_demo_report.py`, replace the last five lines of `main` (from
`os.makedirs(` through the `print(f"wrote …")`) with:

```python
    if "--check" in flags:
        try:
            with open(out_path, encoding="utf-8") as fh:
                current = fh.read()
        except OSError:
            current = None
        if current != html:
            print(f"STALE: {out_path} is not what the generator produces now. "
                  "Run: python3 demo/gen_demo_report.py  and commit the result.")
            return 1
        print(f"up to date: {out_path}")
        return 0
    os.makedirs(os.path.dirname(out_path) or ".", exist_ok=True)
    with open(out_path, "w", encoding="utf-8") as fh:
        fh.write(html)
    print(f"wrote {out_path} ({len(html.encode('utf-8'))/1024:.0f} KB)")
    return 0
```

and change the last line of the file to:

```python
    sys.exit(main(sys.argv[1:]))
```

If the module docstring at the top lists the flags, add
`--check   compare with the existing file, write nothing, exit 1 if stale`.

**Verify**:
- `python3 demo/gen_demo_report.py --check; echo rc=$?` → `up to date: …` and `rc=0`.
- `git status --short` → the HTML is not modified.
- Negative test: `cp docs/examples/demo_busy_db.html /tmp/demo_backup.html && printf '\n' >> docs/examples/demo_busy_db.html && python3 demo/gen_demo_report.py --check; echo rc=$?`
  → `STALE: …` and `rc=1`; then restore:
  `cp /tmp/demo_backup.html docs/examples/demo_busy_db.html && git status --short docs/examples/` → no output.
- `python3 demo/gen_demo_report.py; echo rc=$?` → `wrote …`, `rc=0`, file still unmodified in `git status`.

### Step 3: `--check` for the policy generator

In `docs/gen_policy_doc.py`:

1. Change the signature `def main() -> None:` to
   `def main(argv=None) -> int:` and add as the first line of the body:
   `check = "--check" in (argv or [])`.
2. Replace the single line `gen = _dt.datetime.now().strftime("%Y-%m-%d")` with:

```python
    gen = _dt.datetime.now().strftime("%Y-%m-%d")
    existing = None
    if check:
        # The page stamps its generation date; compare as if generated on
        # the date already in the committed file.
        try:
            with open(OUT, encoding="utf-8") as fh:
                existing = fh.read()
        except OSError:
            existing = None
        m = re.search(r"Generated (\d{4}-\d{2}-\d{2}) from", existing or "")
        if m:
            gen = m.group(1)
```

   (`re` is already imported at the top of the file.)
3. Replace the final write block (`with open(OUT, "w" …` through the
   `print(f"wrote …")`) with:

```python
    text = "\n".join(parts)
    if check:
        if existing != text:
            print(f"STALE: {OUT} is not what the generator produces now. "
                  "Run: python3 docs/gen_policy_doc.py  and commit the result.")
            return 1
        print(f"up to date: {OUT}")
        return 0
    with open(OUT, "w", encoding="utf-8") as fh:
        fh.write(text)
    print(f"wrote {OUT} ({len(load)} load, {len(metric)} metric, {len(wclass)} wait classes, {len(wevent)} event overrides)")
    return 0
```

4. Change the last line of the file to `sys.exit(main(sys.argv[1:]))`.
5. In the module docstring add the line
   `    python3 docs/gen_policy_doc.py --check  # exit 1 if the page is stale`.

**Verify**:
- `python3 docs/gen_policy_doc.py --check; echo rc=$?` → `up to date: …`, `rc=0`.
- `git status --short docs/metric_policy.html` → no output.
- Negative test: `cp docs/metric_policy.html /tmp/policy_backup.html && printf '\n' >> docs/metric_policy.html && python3 docs/gen_policy_doc.py --check; echo rc=$?`
  → `STALE: …`, `rc=1`; restore with
  `cp /tmp/policy_backup.html docs/metric_policy.html`.
- Do **not** run the generator without `--check` in this plan: it would
  stamp today's date into the page and modify it.

### Step 4: Add both checks to `tools/check.sh`

Insert a new step after the "server unit tests" step and before the final
`echo`:

```bash
step "generated docs are fresh (demo report, policy page)"
python3 demo/gen_demo_report.py --check || fail=1
python3 docs/gen_policy_doc.py --check || fail=1
```

Add a line `#   5. generated docs        demo report + policy page match their generators`
to the numbered list in the script's header comment.

**Verify**:
- `bash -n tools/check.sh` → exit 0.
- `./tools/check.sh; echo rc=$?` → both `up to date:` lines appear, last
  line `check.sh: all checks passed`, `rc=0`.
- `git status --short` → no `.html` file modified.

### Step 5: Document

1. `demo/README.md`: next to the existing usage lines for
   `gen_demo_report.py`, add: `python3 demo/gen_demo_report.py --check   # CI gate: exit 1 if docs/examples/demo_busy_db.html is stale`.
2. `CLAUDE.md`, section "### Demo report (`demo/`, docs-only)": after the
   sentence "**When a section's markup/JS changes, re-port its twin in the
   same commit and regenerate**; generation is deterministic (two runs, same
   md5)." add: "`tools/check.sh` (CI) fails when either generated page is
   stale (`gen_demo_report.py --check`, `gen_policy_doc.py --check`)."

**Verify**: `grep -c -- "--check" demo/README.md CLAUDE.md` → each ≥ 1.

## Test plan

- The negative tests in steps 2 and 3 (a one-byte change makes `--check`
  exit 1) and the positive runs are the tests; no unit-test framework
  exists for the generators.
- `./tools/check.sh` → `check.sh: all checks passed`.

## Done criteria

- [ ] `python3 demo/gen_demo_report.py --check` exits 0; `python3 docs/gen_policy_doc.py --check` exits 0
- [ ] Both negative tests exit 1 and the files are restored
- [ ] `./tools/check.sh` exits 0 and runs the new step
- [ ] `git status --short` shows only the five in-scope files (no `.html`)
- [ ] `plans/README.md` status row updated

## STOP conditions

- Step 1 shows the committed demo is already stale, or
  `python3 docs/gen_policy_doc.py --check` reports STALE on an unmodified
  tree — report which file; regenerating is a separate decision because it
  changes published pages.
- `tools/check.sh` does not exist (plan 003 not applied).
- The generators' `main` functions differ from the excerpts.
- `--check` takes much longer than ~10 seconds on your machine (it would
  slow every CI run; report the timing).

## Maintenance notes

- After this lands, any change to `sql/_style.sql`, `sql/lib/js_*.plsql`,
  a section's lifted script lines, or `sql/lib/metric_policy.plsql` fails CI
  until the corresponding page is regenerated and committed — that is the
  intent. The fix is always the command printed in the `STALE:` message.
- A regenerated policy page gets today's date; the check tolerates any date.
- Deferred: a headless browser smoke test of the demo (`demo/verify_report.js`,
  about 3 minutes, needs Node + Playwright) as a separate, slower CI job.
