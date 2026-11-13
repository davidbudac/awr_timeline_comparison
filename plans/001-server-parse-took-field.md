# Plan 001: The fleet server parses the wrapper's per-DB summary lines again (`took=` field)

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**:
> `git diff --stat e755b97..HEAD -- server/app/records.py server/tests/test_records.py server/tests/test_runner.py server/tests/fake_bin/run_awr_fleet.sh run_awr_fleet.sh`
> If any of these changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P1
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none
- **Category**: bug
- **Planned at**: commit `e755b97`, 2026-11-13

## Why this matters

`server/` runs `run_awr_fleet.sh` and learns the per-database outcome by
regex-matching the wrapper's stdout. The wrapper added a `took=<duration>`
field to both summary lines; the server's two regexes were never updated, so
since then they match **nothing**. Consequences today: a fleet run in which
some databases failed is recorded `success` instead of `partial` (the
"unreachable" signal is lost), every server-triggered detail regeneration is
recorded `failed` even when the report was produced, and the UI shows no
per-DB rows. The test double still prints the old format, so all 137 tests
pass while production is broken. This plan fixes the parser, brings the test
double in line, and adds a contract test that reads the real wrapper so the
two can not drift silently again.

## Current state

Files:

- `run_awr_fleet.sh` — the real wrapper (bash). **Read-only for this plan.**
  Its assembler prints one summary line per database, then `Report: <path>`.
- `server/app/records.py` — run records + `parse_fleet_summary()` (the parser).
- `server/app/runner.py` — consumes the parse result (read-only here).
- `server/tests/fake_bin/run_awr_fleet.sh` — test double for the wrapper.
- `server/tests/test_records.py`, `server/tests/test_runner.py` — tests.

The wrapper's lines (`run_awr_fleet.sh:1550-1553`):

```bash
        if [[ "${IS_ERR[$alias]}" == 1 ]]; then
            printf '%-24s ERROR  rc=%-5s took=%-7s detail=%-7s %s\n' "$alias" "${RCV[$alias]}" "$took" "$dstat" "${REASON[$alias]}"
        else
            printf '%-24s OK     score=%-4s crit=%s warn=%s suppressed=%s topsql_n=%s topsql_pts=%s took=%s detail=%s\n' \
                "$alias" "${SCORE[$alias]}" "${CRIT[$alias]}" "${WARN[$alias]}" "${SUPP[$alias]}" "${NTOP[$alias]}" "${PTS[$alias]}" "$took" "$dstat"
        fi
```

`took` comes from `fmt_dur` (`run_awr_fleet.sh:224-229`): `"7s"` under a
minute, **`"1m 05s"` (contains a space)** from one minute up, or the literal
`?` for an old workdir. So the value is NOT a single `\S+` token.

The parser (`server/app/records.py:152-159`) — no `took=`:

```python
_ERROR_RE = re.compile(
    r"^(?P<alias>\S+)\s+ERROR\s+rc=(?P<rc>\S+)\s+detail=(?P<detail>\S+)\s+(?P<reason>.*)$"
)
_OK_RE = re.compile(
    r"^(?P<alias>\S+)\s+OK\s+score=(?P<score>\S+)\s+crit=(?P<crit>\S+)\s+warn=(?P<warn>\S+)"
    r"\s+suppressed=(?P<suppressed>\S+)\s+topsql_n=(?P<topsql_n>\S+)\s+topsql_pts=(?P<topsql_pts>\S+)"
    r"\s+detail=(?P<detail>\S+)$"
)
```

The comment block above it (`records.py:135-150`) documents the old format
and cites stale line numbers (`run_awr_fleet.sh:1053-1059`).

How the result is used (`server/app/runner.py:344-346` and `:373-379`):

```python
        if summary["report_path"] and exit_code == 0:
            any_error = any(d.get("status") == "ERROR" for d in summary["databases"])
            rec["state"] = records.STATE_PARTIAL if any_error else records.STATE_SUCCESS
...
        ok = (
            exit_code == 0
            and entry is not None
            and entry.get("status") == "OK"
            and entry.get("detail") == "ok"
            and detail_path_str is not None
        )
```

With an empty `databases` list, `any_error` is always False and `entry` is
always None.

The test double (`server/tests/fake_bin/run_awr_fleet.sh:77` and `:92`)
still prints the pre-`took` format:

```bash
        SUMMARY_LINES+=("$(printf '%-24s ERROR  rc=%-5s detail=%-7s %s' "$db_alias" "1" "$dstat" "simulated failure for $db_alias")")
...
    SUMMARY_LINES+=("$(printf '%-24s OK     score=%-4s crit=%s warn=%s suppressed=%s topsql_n=%s topsql_pts=%s detail=%s' "$db_alias" "3" "0" "1" "0" "2" "3" "$dstat")")
```

Conventions that apply:

- `server/` is pure Python stdlib, `unittest` only, no third-party packages.
- Hard project rule: nothing under `server/` may edit `run_awr_fleet.sh`,
  `run_awr_trend.sh`, `awr_trend.sql`, `awr_fleet_extract.sql` or anything
  under `sql/`. The server adapts to the wrapper, never the reverse.
- Old run logs and old tests use the pre-`took` format; the parser must keep
  accepting it (the `took` group is optional).
- Test files start with a 6-line `sys.path` preamble and use plain
  `unittest.TestCase` classes — copy the style of
  `server/tests/test_records.py` (`ParseFleetSummaryTest`).

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Server tests | `python3 -m unittest discover -s server/tests -t .` | `OK` (137 tests before this plan) |
| One test file | `python3 -m unittest server.tests.test_records -v` | all pass |
| Shell syntax | `bash -n server/tests/fake_bin/run_awr_fleet.sh` | exit 0, no output |
| Repo lint | `./lint.sh` | exit 0 |

## Scope

**In scope** (the only files you should modify):
- `server/app/records.py`
- `server/tests/fake_bin/run_awr_fleet.sh`
- `server/tests/test_records.py`
- `server/tests/test_runner.py` (only if an assertion needs the new `took` key; see step 4)

**Out of scope** (do NOT touch, even though they look related):
- `run_awr_fleet.sh` — the wrapper's output format is the contract; do not "simplify" it.
- `server/app/runner.py`, `server/app/views.py` — showing `took` in the UI is a possible follow-up, not this plan.
- Replacing stdout scraping with a machine-readable summary file — recorded as a direction option in `plans/README.md`.

## Git workflow

- Branch: `advisor/001-server-parse-took-field` from `main`.
- Commit style: conventional commits with a scope, as in `git log`
  (`fix(wrappers): fail fast when sqlplus is not on PATH`). Suggested:
  `fix(server): parse the wrapper's took= summary field`.
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Write the failing contract test

Add a new test class to `server/tests/test_records.py` (after
`ParseFleetSummaryTest`). It reads the **real** wrapper from the repo root,
extracts the two `printf` format strings, renders them with `bash`, and
asserts the parser understands the result. Add `import re` and
`import subprocess` to the imports.

```python
class WrapperSummaryContractTest(unittest.TestCase):
    """The parser must understand whatever the REAL run_awr_fleet.sh prints.
    The format strings are read from the wrapper itself, so a change there
    that the parser cannot read fails this test instead of production."""

    WRAPPER = Path(__file__).resolve().parents[2] / "run_awr_fleet.sh"

    def _formats(self):
        src = self.WRAPPER.read_text(encoding="utf-8")
        err = re.findall(r"printf '([^']*ERROR  rc=[^']*)'", src)
        ok = re.findall(r"printf '([^']*OK     score=[^']*)'", src)
        self.assertEqual(len(err), 1, "expected exactly one ERROR summary printf in the wrapper")
        self.assertEqual(len(ok), 1, "expected exactly one OK summary printf in the wrapper")
        return err[0], ok[0]

    @staticmethod
    def _render(fmt, *args):
        out = subprocess.run(
            ["bash", "-c", 'printf "$1" "${@:2}"', "_", fmt] + list(args),
            stdout=subprocess.PIPE,
            check=True,
        ).stdout
        return out.decode("utf-8")

    def test_real_wrapper_lines_parse(self):
        err_fmt, ok_fmt = self._formats()
        for took in ("7s", "1m 05s", "?"):
            text = (
                self._render(err_fmt, "deadbox", "1", took, "skipped", "ORA-12541: TNS:no listener")
                + self._render(ok_fmt, "prod_east", "16", "1", "2", "0", "3", "25", took, "ok")
                + "Report: reports/awr_fleet_202607221200_run20260722120005123/index.html\n"
            )
            r = records.parse_fleet_summary(text)
            self.assertEqual(len(r["databases"]), 2, "took=%r: %r" % (took, text))
            self.assertEqual(r["databases"][0]["status"], "ERROR")
            self.assertEqual(r["databases"][0]["rc"], "1")
            self.assertEqual(r["databases"][0]["detail"], "skipped")
            self.assertEqual(r["databases"][0]["reason"], "ORA-12541: TNS:no listener")
            self.assertEqual(r["databases"][0]["took"], took)
            self.assertEqual(r["databases"][1]["status"], "OK")
            self.assertEqual(r["databases"][1]["score"], "16")
            self.assertEqual(r["databases"][1]["detail"], "ok")
            self.assertEqual(r["databases"][1]["took"], took)
```

The argument order in `_render` mirrors the wrapper's `printf` arguments
(ERROR: alias, rc, took, detail, reason; OK: alias, score, crit, warn,
suppressed, topsql_n, topsql_pts, took, detail). If the wrapper's format has
a different number of `%` placeholders than that, STOP (see STOP conditions).

**Verify**: `python3 -m unittest server.tests.test_records.WrapperSummaryContractTest -v`
→ **fails** (`AssertionError: 0 != 2`). A failure here is the expected result of this step.

### Step 2: Fix the regexes

In `server/app/records.py`, replace the two regex definitions with:

```python
_ERROR_RE = re.compile(
    r"^(?P<alias>\S+)\s+ERROR\s+rc=(?P<rc>\S+)"
    r"(?:\s+took=(?P<took>.*?))?"
    r"\s+detail=(?P<detail>\S+)\s+(?P<reason>.*)$"
)
_OK_RE = re.compile(
    r"^(?P<alias>\S+)\s+OK\s+score=(?P<score>\S+)\s+crit=(?P<crit>\S+)\s+warn=(?P<warn>\S+)"
    r"\s+suppressed=(?P<suppressed>\S+)\s+topsql_n=(?P<topsql_n>\S+)\s+topsql_pts=(?P<topsql_pts>\S+)"
    r"(?:\s+took=(?P<took>.*?))?"
    r"\s+detail=(?P<detail>\S+)$"
)
```

`took` is lazy (`.*?`) because the value may contain a space (`1m 05s`), and
the whole group is optional so pre-`took` logs still parse.

In `parse_fleet_summary()`, add `"took": m.group("took"),` to **both**
dicts appended to `databases` (value is `None` for an old-format line).

Update the comment block above the regexes (`records.py:135-150`): show the
two current format strings with `took=`, say that `took` is `fmt_dur`
output and may contain a space, say the field is optional for old logs, and
replace the stale `run_awr_fleet.sh:1053-1059` reference with "the summary
loop at the end of `do_assemble` in `run_awr_fleet.sh`" (no line numbers).

**Verify**: `python3 -m unittest server.tests.test_records -v` → all pass,
including `WrapperSummaryContractTest` and every pre-existing test (they use
the old format and prove back-compat).

### Step 3: Bring the test double in line with the real wrapper

In `server/tests/fake_bin/run_awr_fleet.sh`:

1. Near the other test knobs, add: `TOOK="${FAKE_TOOK:-1m 05s}"` and document
   `FAKE_TOOK` in the header comment's knob list ("per-DB duration text
   printed as took=; default has a space on purpose").
2. Change the ERROR line (currently line 77) to the real format:
   `printf '%-24s ERROR  rc=%-5s took=%-7s detail=%-7s %s' "$db_alias" "1" "$TOOK" "$dstat" "simulated failure for $db_alias"`
3. Change the OK line (currently line 92) to the real format:
   `printf '%-24s OK     score=%-4s crit=%s warn=%s suppressed=%s topsql_n=%s topsql_pts=%s took=%s detail=%s' "$db_alias" "3" "0" "1" "0" "2" "3" "$TOOK" "$dstat"`
4. Fix the header comment's stale reference `run_awr_fleet.sh:1053-1059`
   (same wording as in step 2).

**Verify**: `bash -n server/tests/fake_bin/run_awr_fleet.sh` → exit 0; then
`python3 -m unittest discover -s server/tests -t .` → `OK`.

### Step 4: Assert the runner states that were silently wrong

Open `server/tests/test_runner.py`. Confirm these existing tests assert the
record state, and strengthen them if they do not:

- `FleetRunLifecycleTest.test_partial_run_has_error_rows` must assert
  `rec["state"] == records.STATE_PARTIAL` and that
  `rec["databases"]` contains an entry with `status == "ERROR"`.
- `FleetRunLifecycleTest.test_success_run` must assert
  `len(rec["databases"]) == 2` (the fixture `fleet.conf` has `good1` and
  `good2`).
- `DetailRunTest.test_detail_regen_success_and_cleanup` must assert
  `rec["state"] == records.STATE_SUCCESS`.

Only add assertions that are missing; do not rewrite the tests.

**Verify**: `python3 -m unittest discover -s server/tests -t .` → `OK`,
138 tests or more.

### Step 5: Prove the double-and-parser pair would have caught the bug

Temporarily revert step 2 only (`git stash push server/app/records.py`), run
`python3 -m unittest discover -s server/tests -t .` → it must now **fail**
(contract test and runner tests). Then `git stash pop` and re-run → `OK`.

**Verify**: after `git stash pop`, `python3 -m unittest discover -s server/tests -t .` → `OK`; `git stash list` → empty.

## Test plan

- New: `WrapperSummaryContractTest.test_real_wrapper_lines_parse` in
  `server/tests/test_records.py` — real wrapper format, three `took` shapes
  (`7s`, `1m 05s`, `?`), ERROR + OK rows.
- Existing old-format tests in `ParseFleetSummaryTest` stay untouched and
  prove back-compat.
- Strengthened runner assertions (step 4).
- Verification: `python3 -m unittest discover -s server/tests -t .` → `OK`.

## Done criteria

- [ ] `python3 -m unittest discover -s server/tests -t .` exits 0 with at least 138 tests
- [ ] `grep -c 'took=' server/app/records.py` ≥ 2 and `grep -c 'took=' server/tests/fake_bin/run_awr_fleet.sh` ≥ 2
- [ ] `grep -n '1053-1059' server/` returns no matches
- [ ] `./lint.sh` exits 0
- [ ] `git status --short` shows only the in-scope files
- [ ] `git diff --stat e755b97..HEAD -- run_awr_fleet.sh` is empty
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- `run_awr_fleet.sh` no longer contains exactly one `printf '…ERROR  rc=…'`
  and one `printf '…OK     score=…'` line, or their placeholder counts differ
  from 5 and 9 (the wrapper format changed again — the regexes in step 2
  must be re-derived from the new format, not guessed).
- Any pre-existing test in `ParseFleetSummaryTest` fails after step 2
  (back-compat is broken).
- A fix appears to require editing `run_awr_fleet.sh`.

## Maintenance notes

- Any future change to the wrapper's summary `printf` lines must be made
  together with `server/app/records.py`; the contract test now enforces it,
  provided CI runs the server tests (plan 003).
- Reviewer: check that `took` is optional in both regexes and that the
  ERROR `reason` group still captures the full remainder of the line.
- Deferred: showing `took` in the run page (`server/app/views.py`), and the
  structural fix of having the wrapper write a `summary.tsv` the server
  reads instead of scraping stdout (see `plans/README.md`, direction).
