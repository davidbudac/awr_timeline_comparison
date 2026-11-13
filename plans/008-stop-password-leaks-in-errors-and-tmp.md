# Plan 008: Connect-string passwords no longer appear in error messages, masked displays, or leftover temp files

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**:
> `git diff --stat e755b97..HEAD -- run_awr_fleet.sh run_awr_trend.sh server/app/fleetconf.py server/app/runner.py server/tests/test_fleetconf.py server/tests/test_runner.py`
> If any of these changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P2
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none (touches `server/tests/test_runner.py`, also edited by plans 001 and 010 — rebase if they landed)
- **Category**: security
- **Planned at**: commit `e755b97`, 2026-11-13

## Why this matters

`fleet.conf` holds one line per database, `alias|connect[|detail]`, and the
connect string is often `user/password@service`. The project's stated rule
is that the password is masked (`user/***@service`) everywhere it is
displayed and never written to reports or work directories. Four paths
break that rule:

1. A `fleet.conf` line without a `|` (a common typo: the alias was
   forgotten) is echoed **verbatim** in the error — by the bash wrapper on
   stderr and by the server in its web UI, JSON API and redirect URL.
2. `mask_conn` stops at the **first** `@`, so a password that itself
   contains `@` is only half masked (`user/***@rest-of-password@service`).
3. When a connect string contains a single quote or tab, the validation
   error prints the whole connect string unmasked.
4. The server writes a one-line temporary conf (with the real connect
   string) for a per-DB detail run and deletes it when the run ends — but
   if the server is killed mid-run the file stays on disk indefinitely.

**Handling rule for you:** never paste a real connect string, a real
`fleet.conf` line, or anything from `fleet.conf` / `server/server.conf` /
`server/data/` into code, tests, commit messages or your report. Do not
open those files. Tests use obviously fake values such as `scott/tiger@ORCL`.

## Current state

### Bash wrapper — `run_awr_fleet.sh`

Error helper and validator (`:328-333`):

```bash
_pos_die() { echo "error: argument '$1' = $(printf %q "$2") is invalid -- $3" >&2; exit 2; }
_pos_clean() {  # reject newline / single-quote / tab in a heredoc-bound string arg
    case "$2" in *"'"*) _pos_die "$1" "$2" "must not contain a single quote";; esac
    case "$2" in *$'\n'*) _pos_die "$1" "$2" "must not contain a newline";; esac
    case "$2" in *$'\t'*) _pos_die "$1" "$2" "must not contain a tab";; esac
}
```

Masking (`:350-362`):

```bash
mask_conn() {
    local c="$1"
    [[ "$c" == /* ]] && { printf '%s' "$c"; return; }
    if [[ "$c" =~ ^([^/]+)/[^@]*@(.*)$ ]]; then
        printf '%s/***@%s' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
        return
    fi
    if [[ "$c" =~ ^([^/]+)/.+$ ]]; then
        printf '%s/***' "${BASH_REMATCH[1]}"
        return
    fi
    printf '%s' "$c"
}
```

In `parse_conf` (`:669-672` and `:694-695`):

```bash
        if [[ "$line" != *'|'* ]]; then
            echo "error: fleet.conf '$conf' line $lineno: expected 'alias|connect[|detail]', got: $line" >&2
            exit 2
        fi
...
        [[ -n "$conn" ]] || { echo "error: fleet.conf '$conf' line $lineno: empty connect string for alias '$alias'" >&2; exit 2; }
        _pos_clean "connect (alias $alias, line $lineno)" "$conn"
```

### Single-DB wrapper — `run_awr_trend.sh`

It has the same `_pos_die` / `_pos_clean` pair (`:899-903`, without the tab
check) and no `mask_conn`. The connect string goes through it (`:904`):

```bash
_pos_clean connect     "$CONN"
```

### Server — `server/app/fleetconf.py`

Python port of the masking (`:43-51`):

```python
    if conn.startswith("/"):
        return conn
    m = re.match(r"^([^/]+)/[^@]*@(.*)$", conn)
    if m:
        return "%s/***@%s" % (m.group(1), m.group(2))
    m = re.match(r"^([^/]+)/.+$", conn)
    if m:
        return "%s/***" % (m.group(1),)
    return conn
```

The raw-line error (`:89-94`):

```python
        if "|" not in line:
            raise FleetConfError(
                "fleet.conf '%s' line %d: expected 'alias|connect[|detail]', got: %s"
                % (path, lineno, line),
                lineno,
            )
```

That exception text reaches the browser through
`server/app/views.py:404-406` (error banner), `server/app/runner.py:138-140`
(`NotFoundError("cannot read fleet.conf: %s" % exc)` → JSON body and the
`/?error=` redirect URL) and `runner.py:407-409` (stored in the run record).

### Server — `server/app/runner.py`

Temp conf creation (`:268-286`): `_make_detail_conf` writes
`<data_dir>/tmp/detail_<alias>_<random>.conf` (mode 0600, directory 0700)
containing the verbatim `fleet.conf` line. It is removed only in the
worker's `finally` (`:452-456`). `RunManager.start()` (`:65-73`):

```python
    def start(self):
        paths.ensure_data_dirs(self.data_dir)
        self.reports_dir.mkdir(parents=True, exist_ok=True)
        recovered = records.recover_stuck_running(self.data_dir)
        self._worker_thread = threading.Thread(
            target=self._worker_loop, name="awrserve-worker", daemon=True
        )
        self._worker_thread.start()
        return recovered
```

### Tests

`server/tests/test_fleetconf.py` has `MaskConnParityTest` with a `CASES`
list of `(input, expected)` pairs checked by `test_parity_table`, and
`ParseFleetConfTest` with a `_write(text)` helper returning a temp
`fleet.conf` path (see `test_missing_pipe_errors`). `server/tests/test_runner.py`
has `RunnerTestBase` (temp `cwd`, temp `data_dir`, a fake wrapper) — its
`setUp` creates and starts `self.rm`.

### Conventions

- The wrappers run on AIX / Solaris: bash built-ins only, no GNU-only flags
  (`./lint.sh` check 10).
- `mask_conn` exists twice on purpose (bash + Python port) and the two must
  behave identically — change both in the same commit.
- `server/` is stdlib-only Python with `unittest`.
- Wallet / OS-auth connects (starting with `/`) have no password and must
  keep passing through untouched.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Shell syntax | `bash -n run_awr_fleet.sh && bash -n run_awr_trend.sh` | exit 0 |
| Lint | `./lint.sh` | `lint: clean`, exit 0 |
| Server tests | `python3 -m unittest discover -s server/tests -t .` | `OK` |
| Bash `mask_conn` in isolation | `bash -c "$(sed -n '/^mask_conn() {/,/^}/p' run_awr_fleet.sh); mask_conn 'scott/ti@ger@ORCL'; echo"` | see step 1 |

## Scope

**In scope** (the only files you should modify):
- `run_awr_fleet.sh` (`mask_conn`, a new `_pos_clean_conn`, two lines in `parse_conf`)
- `run_awr_trend.sh` (the single `_pos_clean connect "$CONN"` call)
- `server/app/fleetconf.py` (`mask_conn`, the missing-pipe error text)
- `server/app/runner.py` (`start()` — stale temp conf cleanup)
- `server/tests/test_fleetconf.py`, `server/tests/test_runner.py` (new tests)

**Out of scope** (do NOT touch):
- `fleet.conf`, `fleet.conf.example`, `server/server.conf*`, `server/data/`.
- Any SQL file.

## Git workflow

- Branch: `advisor/008-stop-password-leaks` from `main`.
- Commit style: conventional commits with scope. Suggested:
  `fix(security): never echo raw connect strings; mask passwords containing @`.
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: `mask_conn` masks up to the LAST `@` (bash + Python)

In `run_awr_fleet.sh`, change the first regex in `mask_conn` from
`^([^/]+)/[^@]*@(.*)$` to `^([^/]+)/.*@([^@]*)$` and add a comment above
it: "greedy up to the LAST @: a password may itself contain @".

In `server/app/fleetconf.py`, make the same change:
`re.match(r"^([^/]+)/.*@([^@]*)$", conn)`.

Add to `MaskConnParityTest.CASES` in `server/tests/test_fleetconf.py`:

```python
        # a password that itself contains '@' -- mask through the LAST '@'
        ("scott/ti@ger@ORCL", "scott/***@ORCL"),
        ("scott/a@b@c@host:1521/svc", "scott/***@host:1521/svc"),
        # a password containing '/'
        ("scott/ti/ger@ORCL", "scott/***@ORCL"),
```

**Verify**:
- `python3 -m unittest server.tests.test_fleetconf -v` → all pass (the
  pre-existing `CASES` entries must still pass unchanged).
- Bash parity for every case in the table:

```bash
for c in '/' '/@prod_east_tns' '/ as sysdba' 'user/pw@svc' 'user/pw' 'bare_tns_alias' \
         'user/pw@svc|extra' 'user/pw|extra' 'user/@svc' \
         'scott/ti@ger@ORCL' 'scott/a@b@c@host:1521/svc' 'scott/ti/ger@ORCL'; do
  bash -c "$(sed -n '/^mask_conn() {/,/^}/p' run_awr_fleet.sh); mask_conn \"\$1\"; echo" _ "$c"
done
```

  Expected, line by line: `/`, `/@prod_east_tns`, `/ as sysdba`,
  `user/***@svc`, `user/***`, `bare_tns_alias`, `user/***@svc|extra`,
  `user/***`, `user/***@svc`, `scott/***@ORCL`, `scott/***@host:1521/svc`,
  `scott/***@ORCL`.

### Step 2: Never echo the raw line or raw connect string (bash, fleet)

In `run_awr_fleet.sh`:

1. Replace the missing-pipe message (line ~670) with one that does not
   print `$line`:

```bash
            echo "error: fleet.conf '$conf' line $lineno: expected 'alias|connect[|detail]' (no '|' found; line content not shown, it may hold a password)" >&2
```

2. Directly below `_pos_clean` (after line ~333) add:

```bash
# _pos_clean_conn -- _pos_clean for a connect string: same three checks, but
# the message shows the MASKED value, never the raw one (it holds a password).
_pos_clean_conn() {
    local what="$1" val="$2" disp
    disp="$(mask_conn "$val")"
    case "$val" in *"'"*) _pos_die "$what" "$disp" "must not contain a single quote";; esac
    case "$val" in *$'\n'*) _pos_die "$what" "$disp" "must not contain a newline";; esac
    case "$val" in *$'\t'*) _pos_die "$what" "$disp" "must not contain a tab";; esac
}
```

   (`mask_conn` is defined further down the file; that is fine — bash
   resolves function names when called.)

3. In `parse_conf` change
   `_pos_clean "connect (alias $alias, line $lineno)" "$conn"` to
   `_pos_clean_conn "connect (alias $alias, line $lineno)" "$conn"`.

**Verify**:
- `bash -n run_awr_fleet.sh` → exit 0.
- `grep -c 'got: \$line' run_awr_fleet.sh` → `0`.
- End-to-end, with fake values only (the wrapper exits in `parse_conf`,
  before it looks for `sqlplus`):

```bash
d="$(mktemp -d)"
printf 'scott/tiger@ORCL\n' > "$d/nopipe.conf"
./run_awr_fleet.sh "$d/nopipe.conf" 2>&1 | grep -c tiger          # expect 0
printf "db1|scott/ti'ger@ORCL\n" > "$d/quote.conf"
./run_awr_fleet.sh "$d/quote.conf" 2>&1 | grep -c "ti'ger"        # expect 0
./run_awr_fleet.sh "$d/quote.conf" 2>&1 | grep -c 'scott/\*\*\*@ORCL'   # expect 1
rm -rf "$d"
```

  If the wrapper prints something about `sqlplus` not being found **before**
  reaching the conf error, STOP (the call order differs from this plan).

### Step 3: Same for the single-DB wrapper

In `run_awr_trend.sh`, replace the line `_pos_clean connect     "$CONN"`
with two explicit checks that never print the value:

```bash
# The connect string holds a password: validate it like _pos_clean does, but
# never echo it.
case "$CONN" in *"'"*)  _pos_die connect '<hidden>' "must not contain a single quote";; esac
case "$CONN" in *$'\n'*) _pos_die connect '<hidden>' "must not contain a newline";; esac
```

Leave the later line
`[[ -n "$CONN" ]] || _pos_die connect "$CONN" "a connect string is required"`
unchanged (it only fires for an empty value).

**Verify**:
- `bash -n run_awr_trend.sh` → exit 0.
- `./run_awr_trend.sh "scott/ti'ger@ORCL" 2>&1 | grep -c "ti'ger"` → `0`, and
  `./run_awr_trend.sh "scott/ti'ger@ORCL" 2>&1 | grep -c "must not contain a single quote"` → `1`.

### Step 4: Server — no raw line in the missing-pipe error

In `server/app/fleetconf.py`, change the message to:

```python
            raise FleetConfError(
                "fleet.conf '%s' line %d: expected 'alias|connect[|detail]' "
                "(no '|' found; line content not shown, it may hold a password)"
                % (path, lineno),
                lineno,
            )
```

In `server/tests/test_fleetconf.py`, extend `test_missing_pipe_errors`:

```python
    def test_missing_pipe_errors(self):
        p = self._write("scott/tiger@ORCL\n")
        with self.assertRaises(fleetconf.FleetConfError) as cm:
            fleetconf.parse_fleet_conf(p)
        self.assertNotIn("tiger", str(cm.exception))
        self.assertIn("line 1", str(cm.exception))
```

Then check the other `FleetConfError` messages in the file: none may
interpolate `line`, `conn` or `raw`. (At the planned-at commit they
interpolate only `path`, `lineno` and `alias`.)

**Verify**: `python3 -m unittest server.tests.test_fleetconf -v` → all pass;
`grep -n '% (path, lineno, line)' server/app/fleetconf.py` → no matches.

### Step 5: Server — remove stale temp confs at startup

In `server/app/runner.py`, add a method to `RunManager` and call it from
`start()` right after `paths.ensure_data_dirs(self.data_dir)`:

```python
    def _purge_stale_detail_confs(self):
        """A detail run's temp conf holds a verbatim fleet.conf line (possibly
        a password). The worker deletes it when the run ends; this removes
        any left behind by a server that was killed mid-run. Safe at
        startup: the single-instance lock guarantees no other worker is
        using the directory."""
        tmp_dir = self.data_dir / "tmp"
        try:
            leftovers = list(tmp_dir.glob("detail_*.conf"))
        except OSError:
            return 0
        removed = 0
        for p in leftovers:
            try:
                p.unlink()
                removed += 1
            except OSError:
                pass
        return removed
```

Add a test to `server/tests/test_runner.py` (new class, modelled on
`RunnerTestBase` but creating the leftover **before** `start()`):

```python
class StaleDetailConfCleanupTest(unittest.TestCase):
    def test_start_removes_leftover_detail_confs(self):
        cwd = Path(tempfile.mkdtemp())
        (cwd / "reports").mkdir()
        data_dir = Path(tempfile.mkdtemp())
        conf_path = cwd / "fleet.conf"
        conf_path.write_text("good1|/@x\n", encoding="utf-8")
        tmp_dir = data_dir / "tmp"
        tmp_dir.mkdir(parents=True)
        stale = tmp_dir / "detail_good1_abc123.conf"
        stale.write_text("good1|scott/tiger@ORCL|detail\n", encoding="utf-8")
        other = tmp_dir / "unrelated.txt"
        other.write_text("keep me", encoding="utf-8")

        rm = runner.RunManager(make_config(conf_path), data_dir=data_dir, cwd=cwd, wrapper_path=FAKE_WRAPPER)
        rm.start()
        try:
            self.assertFalse(stale.exists())
            self.assertTrue(other.exists())
        finally:
            rm.stop(timeout=5)
```

**Verify**: `python3 -m unittest discover -s server/tests -t .` → `OK`.

### Step 6: Final checks

**Verify**:
- `./lint.sh` → clean.
- `git status --short` → only in-scope files.
- `git diff | grep -n -i "tiger"` → hits only in test files and only the
  fake values named in this plan.

## Test plan

- `MaskConnParityTest` gains three cases (password with `@`, several `@`, `/`).
- `test_missing_pipe_errors` asserts the line content is absent.
- New `StaleDetailConfCleanupTest`.
- Bash behaviour verified by the command blocks in steps 1–3 (no bash test
  framework exists in this repo).
- Verification: `python3 -m unittest discover -s server/tests -t .` → `OK`.

## Done criteria

- [ ] `python3 -m unittest discover -s server/tests -t .` exits 0
- [ ] `bash -n run_awr_fleet.sh && bash -n run_awr_trend.sh` exits 0; `./lint.sh` exits 0
- [ ] Step 1 bash parity output matches line by line
- [ ] Step 2 and step 3 leak checks print `0` for the password fragment
- [ ] `grep -c 'got: \$line' run_awr_fleet.sh` → `0`
- [ ] `git status --short` shows only in-scope files
- [ ] `plans/README.md` status row updated

## STOP conditions

- A pre-existing `MaskConnParityTest` case changes its expected value after
  the regex change (the greedy regex altered behaviour for a password
  without `@`).
- The wrapper checks for `sqlplus` before parsing `fleet.conf` (step 2's
  end-to-end check cannot run) — report; do not install anything.
- You are about to read or print the real `fleet.conf`, `server/server.conf`
  or anything under `server/data/`.
- `_pos_clean` has other callers that pass a connect string (run
  `grep -n '_pos_clean ' run_awr_fleet.sh run_awr_trend.sh` — at the
  planned-at commit only the two call sites named above pass a connect).

## Maintenance notes

- If any credential ever appeared in a shared log, ticket or screenshot
  through one of these paths, **rotate that database password** — removal
  from code does not un-leak it.
- `mask_conn` is duplicated by design (bash + Python). `MaskConnParityTest`
  only tests the Python side; the bash loop in step 1 is the parity check.
  Keep the two regexes identical.
- Still open (not in this plan): the password on the `sqlplus` argv in both
  wrappers (`run_awr_trend.sh:433`, `run_awr_fleet.sh:781,858`).
- Reviewer: confirm no message in `fleetconf.py` or `parse_conf` prints a
  whole line or an unmasked connect string.
