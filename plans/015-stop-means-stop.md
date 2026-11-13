# Plan 015: Stopping a run really stops it — no orphaned `sqlplus` sessions after a timeout, Ctrl-C or server shutdown

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**:
> `git diff --stat e755b97..HEAD -- run_awr_fleet.sh server/app/runner.py server/tests/test_runner.py`
> Plans 001, 008 and 010 add tests to `server/tests/test_runner.py` and
> plans 008 / 010 touch `RunManager.start()` — additions there are expected.
> If `run_awr_fleet.sh`'s `resolve_timeout_bin` / `run_one_db` /
> `run_one_detail` or `RunManager.stop` / `_run_subprocess` differ from the
> "Current state" excerpts, treat it as a STOP condition.

## Status

- **Priority**: P3
- **Effort**: M
- **Risk**: MED (process-control code; the wrapper half can only be fully proven with a real `sqlplus`)
- **Depends on**: none
- **Category**: bug
- **Planned at**: commit `e755b97`, 2026-11-13

## Why this matters

The fleet wrapper runs one `sqlplus` per database, each wrapped in
`timeout`. GNU `timeout` puts itself and its command into a **new process
group**. Three ways of stopping a run therefore miss the `sqlplus`
processes:

- The server's `max_run_minutes` clamp sends SIGTERM/SIGKILL to the
  wrapper's process group — the wrapper dies, every `timeout`+`sqlplus` pair
  keeps running its queries against the databases (measured at the
  planned-at commit with a stand-in script: both `timeout` children and
  their commands survived the group kill).
- Ctrl-C on the wrapper in a terminal: same.
- Server shutdown (`RunManager.stop()`) does not signal the wrapper at
  all: the wrapper outlives the server, its run record stays `running`, the
  next server start marks it `failed` and is free to start a second fleet
  run next to the first one.

The orphans end only when `FLEET_TIMEOUT` (default 900 s per DB) or
`FLEET_DETAIL_TIMEOUT` (default 3600 s) expires — up to an hour of AWR
queries nobody is waiting for, on production databases.

## Current state

### Wrapper — `run_awr_fleet.sh`

`resolve_timeout_bin` (`:625-640`):

```bash
# ---------------------------------------------------------------------------
# resolve_timeout_bin -- sets TIMEOUT_BIN to 'timeout' or 'gtimeout' if
# either is on PATH, else '' with a one-time warning.  A missing timeout
# binary must never be fatal (FLEET_TIMEOUT just stops being enforced).
# ---------------------------------------------------------------------------
resolve_timeout_bin() {
    if command -v timeout >/dev/null 2>&1; then
        TIMEOUT_BIN=timeout
    elif command -v gtimeout >/dev/null 2>&1; then
        TIMEOUT_BIN=gtimeout
    else
        TIMEOUT_BIN=''
        echo "warning: neither 'timeout' nor 'gtimeout' found on PATH;" \
             "FLEET_TIMEOUT=${FLEET_TIMEOUT}s will not be enforced (runs unbounded)." >&2
    fi
}
```

The two places that build the command (`:781-782` in `run_one_db`,
`:858-859` in `run_one_detail`):

```bash
    local -a cmd=(sqlplus -S -L "$conn")
    [[ -n "$TIMEOUT_BIN" ]] && cmd=("$TIMEOUT_BIN" "$FLEET_TIMEOUT" "${cmd[@]}")
...
    local -a cmd=(sqlplus -S -L "$conn")
    [[ -n "$TIMEOUT_BIN" && "$FLEET_DETAIL_TIMEOUT" -gt 0 ]] && cmd=("$TIMEOUT_BIN" "$FLEET_DETAIL_TIMEOUT" "${cmd[@]}")
```

`run_one_db` is started as a background job per database
(`run_one_db … &`, `:1681`); a background function in a non-interactive
bash stays in the wrapper's own process group. Only `timeout` leaves it.

GNU `timeout --foreground` (coreutils 8.13, 2011, and later) keeps the
command in the caller's process group. Its documented trade-off —
"children of COMMAND will not be timed out" — does not matter here:
`sqlplus` spawns no children in this tool. Measured with the same stand-in
script: with `--foreground`, a group SIGTERM leaves **no** survivors.
Not every `timeout` has the flag (BusyBox does not; AIX has no `timeout`
at all, in which case `TIMEOUT_BIN` is empty and `sqlplus` already stays in
the wrapper's group), so it must be **probed**, never assumed.

### Server — `server/app/runner.py`

`__init__` ends with (`:59-60`):

```python
        self._worker_thread = None
        self._stop = threading.Event()
```

`stop` (`:75-79`):

```python
    def stop(self, timeout=5):
        self._stop.set()
        self._queue.put(None)
        if self._worker_thread:
            self._worker_thread.join(timeout=timeout)
```

The worker loop's sentinel handling (`:238-244`):

```python
        while True:
            job = self._queue.get()
            if job is None:
                self._queue.task_done()
                if self._stop.is_set():
                    return
                continue
```

`_run_subprocess` (`:288-313`) starts the wrapper with
`start_new_session=True` (so the wrapper leads its own process group) and
on `max_run_minutes` calls `self._killpg(proc.pid, "SIGTERM")`, waits 30 s,
then `SIGKILL`. `_killpg(pid, signame)` is an existing static method that
ignores "no such process".

In `_run_job`, right after the subprocess returns (`:417-425`):

```python
            argv = self._fleet_argv(conf_path)
            exit_code, timed_out = self._run_subprocess(
                argv, env, str(log_path_), self.config.fleet.max_run_minutes
            )

            try:
                log_text = log_path_.read_text(encoding="utf-8", errors="replace")
            except OSError:
                log_text = ""
```

Every record has a `warnings` list (`records.new_record`).

Tests: `server/tests/test_runner.py` defines `make_config`, `wait_until`,
`FAKE_WRAPPER`; the fake wrapper sleeps `FAKE_SLEEP` seconds when that env
var is set (see `ClampAndRestartRecoveryTest`).

### Conventions

- The wrapper runs on AIX / Solaris: bash built-ins and POSIX tools only;
  `./lint.sh` check 10 rejects GNU-only flags of `grep`/`sed`/`find`/`date`/
  `tar`. A **probed** `timeout --foreground` is fine (lint does not match
  it), but never pass the flag unprobed.
- `run_awr_trend.sh` (single-DB) does not use `timeout`; out of scope.
- `server/` is stdlib-only Python with `unittest`; `%`-formatting.
- The server half of this plan was prototyped against the planned-at
  commit: 137 existing tests pass with it, the new test passes with it and
  errors without it.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Shell syntax | `bash -n run_awr_fleet.sh` | exit 0 |
| Lint | `./lint.sh` | `lint: clean`, exit 0 |
| Server tests | `python3 -m unittest discover -s server/tests -t .` | `OK` |
| Probe function in isolation | see step 1 | prints the resolved values |

## Scope

**In scope** (the only files you should modify):
- `run_awr_fleet.sh` (`resolve_timeout_bin`, the two `cmd=(…)` lines)
- `server/app/runner.py` (`__init__`, `stop`, `_worker_loop`, `_run_subprocess`, one line in `_run_job`)
- `server/tests/test_runner.py` (one new test class)

**Out of scope** (do NOT touch):
- Adding `trap` handlers to the wrapper. With the children back in the
  wrapper's process group, the terminal's Ctrl-C and the server's group
  kill reach them without any trap; a trap that rewrites the run's cleanup
  path is a larger change.
- `run_awr_trend.sh`, every SQL file.
- What happens to jobs still **queued** at shutdown (their records stay
  `queued`); noted under "Maintenance notes".

## Git workflow

- Branch: `advisor/015-stop-means-stop` from `main`.
- Two commits are natural: `fix(fleet): keep sqlplus in the wrapper's process group (timeout --foreground)`
  and `fix(server): stop() terminates a running wrapper`.
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Probe `--foreground` in the wrapper

In `run_awr_fleet.sh`, replace `resolve_timeout_bin` and its comment with:

```bash
# ---------------------------------------------------------------------------
# resolve_timeout_bin -- sets TIMEOUT_BIN to 'timeout' or 'gtimeout' if
# either is on PATH, else '' with a one-time warning.  A missing timeout
# binary must never be fatal (FLEET_TIMEOUT just stops being enforced).
#
# TIMEOUT_FG is '--foreground' when that timeout supports it (GNU coreutils
# 8.13+), else ''.  Without it GNU timeout moves sqlplus into a NEW process
# group, so Ctrl-C on this script, or a caller that signals this script's
# process group (the fleet server does), kills the wrapper but leaves every
# sqlplus running until its own timeout expires.  Probed, never assumed:
# BusyBox timeout has no such flag.
# ---------------------------------------------------------------------------
resolve_timeout_bin() {
    TIMEOUT_FG=''
    if command -v timeout >/dev/null 2>&1; then
        TIMEOUT_BIN=timeout
    elif command -v gtimeout >/dev/null 2>&1; then
        TIMEOUT_BIN=gtimeout
    else
        TIMEOUT_BIN=''
        echo "warning: neither 'timeout' nor 'gtimeout' found on PATH;" \
             "FLEET_TIMEOUT=${FLEET_TIMEOUT}s will not be enforced (runs unbounded)." >&2
    fi
    if [[ -n "$TIMEOUT_BIN" ]] && "$TIMEOUT_BIN" --foreground 5 true >/dev/null 2>&1; then
        TIMEOUT_FG='--foreground'
    fi
}
```

At the planned-at commit `TIMEOUT_BIN` is assigned only inside this
function (`grep -n "TIMEOUT_BIN=" run_awr_fleet.sh` → three lines, all in
it), and the function runs before the fan-out, so setting `TIMEOUT_FG`
here is sufficient under `set -u`. If that grep now shows a global default
assignment elsewhere, add `TIMEOUT_FG=''` next to it as well.

**Verify**:

- `bash -n run_awr_fleet.sh` → exit 0.
- Save the function to a scratch file and run it with the real `timeout`:

```bash
d="$(mktemp -d)"
sed -n '/^resolve_timeout_bin() {/,/^}/p' run_awr_fleet.sh > "$d/fn.sh"
bash -c 'set -u; FLEET_TIMEOUT=900; . "$1"; resolve_timeout_bin; echo "bin=[$TIMEOUT_BIN] fg=[$TIMEOUT_FG]"' _ "$d/fn.sh"
```

  → on a GNU/Linux machine: `bin=[timeout] fg=[--foreground]`.

- Then simulate a `timeout` that has no such flag (same `$d`):

```bash
printf '#!/bin/sh\ncase "$1" in --*) exit 1;; esac\nshift; exec "$@"\n' > "$d/timeout"; chmod +x "$d/timeout"
PATH="$d:$PATH" bash -c 'set -u; FLEET_TIMEOUT=900; . "$1"; resolve_timeout_bin; echo "bin=[$TIMEOUT_BIN] fg=[$TIMEOUT_FG]"' _ "$d/fn.sh"
rm -rf "$d"
```

  → `bin=[timeout] fg=[]`.

### Step 2: Use the flag in both command lines

In `run_one_db` change

```bash
    [[ -n "$TIMEOUT_BIN" ]] && cmd=("$TIMEOUT_BIN" "$FLEET_TIMEOUT" "${cmd[@]}")
```

to

```bash
    [[ -n "$TIMEOUT_BIN" ]] && cmd=("$TIMEOUT_BIN" ${TIMEOUT_FG:+"$TIMEOUT_FG"} "$FLEET_TIMEOUT" "${cmd[@]}")
```

and in `run_one_detail` change

```bash
    [[ -n "$TIMEOUT_BIN" && "$FLEET_DETAIL_TIMEOUT" -gt 0 ]] && cmd=("$TIMEOUT_BIN" "$FLEET_DETAIL_TIMEOUT" "${cmd[@]}")
```

to

```bash
    [[ -n "$TIMEOUT_BIN" && "$FLEET_DETAIL_TIMEOUT" -gt 0 ]] && cmd=("$TIMEOUT_BIN" ${TIMEOUT_FG:+"$TIMEOUT_FG"} "$FLEET_DETAIL_TIMEOUT" "${cmd[@]}")
```

(`${TIMEOUT_FG:+"$TIMEOUT_FG"}` expands to nothing when the variable is
empty, so no empty argument is passed.)

**Verify**:

- `bash -n run_awr_fleet.sh` → exit 0; `./lint.sh` → clean.
- `grep -c 'TIMEOUT_FG:+' run_awr_fleet.sh` → `2`.
- Array construction in isolation:

```bash
bash -c 'TIMEOUT_BIN=timeout; FLEET_TIMEOUT=900; for TIMEOUT_FG in "" --foreground; do cmd=(sqlplus -S -L x); cmd=("$TIMEOUT_BIN" ${TIMEOUT_FG:+"$TIMEOUT_FG"} "$FLEET_TIMEOUT" "${cmd[@]}"); echo "${#cmd[@]}: ${cmd[*]}"; done'
```

  → `6: timeout 900 sqlplus -S -L x` then `7: timeout --foreground 900 sqlplus -S -L x`.

### Step 3: Prove the process-group effect with a stand-in

Create two throwaway files **outside the repository** (in a `mktemp -d`
directory).

`pg.sh`:

```bash
#!/usr/bin/env bash
# stand-in for the wrapper's fan-out: background function running `timeout N cmd`
FG="${1:-}"
one() { local -a cmd=(sleep 8); cmd=(timeout $FG 20 "${cmd[@]}"); "${cmd[@]}" > /dev/null 2>&1 || true; }
one & one &
wait
```

`pg_test.py`:

```python
import os, signal, subprocess, sys, time

for flag in ("", "--foreground"):
    p = subprocess.Popen(["bash", sys.argv[1]] + ([flag] if flag else []), start_new_session=True)
    time.sleep(1.0)
    os.killpg(p.pid, signal.SIGTERM)
    p.wait()
    time.sleep(0.3)
    left = subprocess.run(["pgrep", "-s", str(p.pid)], stdout=subprocess.PIPE).stdout.split()
    print("flag=%r survivors=%d" % (flag, len(left)))
    subprocess.run(["pkill", "-s", str(p.pid)])
```

Run `python3 pg_test.py pg.sh` from that directory.

**Verify**: it prints a line for the empty flag with `survivors=4` (today's
behaviour: two `timeout` and two `sleep` outlive the group kill) and a line
for `--foreground` with `survivors=0`. Delete the throwaway directory
afterwards. (Requires GNU `timeout` and `pgrep`; if either is missing on
your machine, skip this step and say so in your report.)

### Step 4: Add the failing server test

Append to `server/tests/test_runner.py`:

```python
class ShutdownTerminatesWrapperTest(unittest.TestCase):
    """stop() must not leave the wrapper running after the server is gone."""

    def setUp(self):
        self.cwd = Path(tempfile.mkdtemp())
        (self.cwd / "reports").mkdir()
        self.data_dir = Path(tempfile.mkdtemp())
        self.conf_path = self.cwd / "fleet.conf"
        self.conf_path.write_text("good1|/@x\n", encoding="utf-8")

    def test_stop_kills_a_running_wrapper_and_records_it(self):
        import os

        rm = runner.RunManager(
            make_config(self.conf_path), data_dir=self.data_dir, cwd=self.cwd, wrapper_path=FAKE_WRAPPER
        )
        rm.start()
        os.environ["FAKE_SLEEP"] = "30"
        try:
            rec = rm.enqueue_fleet("manual")
            queued = rm.enqueue_detail("good1", "manual")
            self.assertTrue(wait_until(lambda: rm._current_proc is not None), "wrapper never started")
            pid = rm._current_proc.pid
            started = time.time()
            rm.stop(timeout=5)
            self.assertLess(time.time() - started, 8, "stop() did not return promptly")
        finally:
            del os.environ["FAKE_SLEEP"]

        # the whole process group is gone (wrapper + its sleep child)
        def group_gone():
            try:
                os.killpg(pid, 0)
            except ProcessLookupError:
                return True
            except PermissionError:
                return False
            return False

        self.assertTrue(wait_until(group_gone, timeout=5), "wrapper process group still alive after stop()")
        done = records.load_record(self.data_dir, rec["run_id"])
        self.assertEqual(done["state"], records.STATE_FAILED)
        self.assertTrue(any("shutting down" in w for w in done["warnings"]))
        # the job queued behind it was not started
        self.assertEqual(records.load_record(self.data_dir, queued["run_id"])["state"], records.STATE_QUEUED)
```

**Verify**: `python3 -m unittest server.tests.test_runner.ShutdownTerminatesWrapperTest -v`
→ **errors** with `AttributeError: 'RunManager' object has no attribute
'_current_proc'`. Expected at this step.

### Step 5: Make `stop()` terminate the running wrapper

In `server/app/runner.py`:

1. In `__init__`, after `self._stop = threading.Event()`, add
   `self._current_proc = None`.
2. Replace `stop` with:

```python
    def stop(self, timeout=5):
        """Shut down: terminate a wrapper that is still running (its whole
        process group -- the wrapper, its per-DB jobs and their sqlplus
        children), then stop the worker. Without this the wrapper would
        outlive the server and a restarted server could start a second run
        next to it."""
        self._stop.set()
        proc = self._current_proc
        if proc is not None and proc.poll() is None:
            self._killpg(proc.pid, "SIGTERM")
            try:
                proc.wait(timeout=timeout)
            except subprocess.TimeoutExpired:
                self._killpg(proc.pid, "SIGKILL")
        self._queue.put(None)
        if self._worker_thread:
            self._worker_thread.join(timeout=timeout)
```

3. In `_worker_loop`, right after the `if job is None:` block, add:

```python
            if self._stop.is_set():
                # shutting down: do not start another wrapper
                self._queue.task_done()
                continue
```

4. Replace `_run_subprocess` with (the only changes: remember the process
   while it runs, clear it in a `finally`):

```python
    def _run_subprocess(self, argv, env, log_path, max_run_minutes):
        """Run argv, capturing combined stdout+stderr to log_path. Enforces
        max_run_minutes: SIGTERM the process group, wait 30s, SIGKILL."""
        timed_out = False
        with open(log_path, "wb") as logf:
            proc = self._popen(
                argv,
                cwd=self.cwd,
                env=env,
                stdout=logf,
                stderr=subprocess.STDOUT,
                stdin=subprocess.DEVNULL,
                start_new_session=True,
            )
            self._current_proc = proc
            timeout_s = max_run_minutes * 60 if max_run_minutes else None
            try:
                try:
                    exit_code = proc.wait(timeout=timeout_s)
                except subprocess.TimeoutExpired:
                    timed_out = True
                    self._killpg(proc.pid, "SIGTERM")
                    try:
                        exit_code = proc.wait(timeout=30)
                    except subprocess.TimeoutExpired:
                        self._killpg(proc.pid, "SIGKILL")
                        exit_code = proc.wait()
            finally:
                self._current_proc = None
        return exit_code, timed_out
```

5. In `_run_job`, immediately after the
   `exit_code, timed_out = self._run_subprocess(…)` statement, add:

```python
            if self._stop.is_set():
                rec["warnings"].append("run terminated: the server was shutting down")
```

**Verify**:

- `python3 -m unittest server.tests.test_runner.ShutdownTerminatesWrapperTest -v` → passes.
- `python3 -m unittest discover -s server/tests -t .` → `OK`.
- `ps -eo pid,args | grep "[f]ake_bin/run_awr_fleet.sh"` → no output (no
  fake wrapper left running by the test suite).

### Step 6: Final checks

**Verify**: `./lint.sh` → clean; `bash -n run_awr_fleet.sh` → exit 0;
`git status --short` → only the three in-scope files.

## Test plan

- New `ShutdownTerminatesWrapperTest` in `server/tests/test_runner.py`:
  `stop()` returns promptly, the wrapper's process group is gone, the run is
  recorded `failed` with a "shutting down" warning, and the job queued
  behind it is not started.
- Wrapper: the probe (step 1, both branches), the argument array (step 2)
  and the process-group effect (step 3) are verified by command; no bash
  test framework exists.
- Verification: `python3 -m unittest discover -s server/tests -t .` → `OK`.

## Done criteria

- [ ] `python3 -m unittest discover -s server/tests -t .` exits 0, new test included
- [ ] `grep -c 'TIMEOUT_FG' run_awr_fleet.sh` ≥ 4
- [ ] `bash -n run_awr_fleet.sh` exits 0; `./lint.sh` exits 0
- [ ] Step 1 prints `fg=[--foreground]` with GNU timeout and `fg=[]` with the flag-less stand-in
- [ ] No `fake_bin/run_awr_fleet.sh` process is left running after the test suite
- [ ] `git status --short` shows only in-scope files
- [ ] `plans/README.md` status row updated with "needs owner fleet run"

## STOP conditions

- `./lint.sh` flags `--foreground` as a GNU-only construct — report; do not
  remove the probe or silence lint.
- An existing runner test becomes flaky or fails after step 5 (for example
  a `tearDown` that calls `stop()` on a still-running fake wrapper now gets a
  `failed` record it did not expect) — report the test name and output.
- Step 3 shows survivors even with `--foreground` on your machine.
- `RunManager` has grown a second worker thread or a process pool.

## Maintenance notes

- **Owner verification with a real fleet (not possible for the executor):**
  1. Start a fleet run, press Ctrl-C after the first "extract started"
     lines, then list processes → no `sqlplus` from this run remains.
  2. A per-DB timeout still works: `FLEET_TIMEOUT=5` against a slow DB →
     that row is an error row with rc 124, as before.
  3. Under the server: start a run, stop the server (SIGTERM) → no
     `run_awr_fleet.sh` / `sqlplus` left; the run page shows `failed` with
     the shutdown warning.
- Jobs still queued at shutdown keep a `queued` record forever (the queue is
  in memory). A follow-up could mark them `skipped` at shutdown or re-queue
  them at startup.
- If a platform's `timeout` lacks `--foreground`, behaviour is exactly as
  before this plan (orphans possible); the header comment says so.
- Reviewer: check that `TIMEOUT_FG` is set before any use under `set -u`,
  and that `stop()` cannot block longer than about `2 × timeout`.
