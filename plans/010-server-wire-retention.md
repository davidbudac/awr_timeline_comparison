# Plan 010: The fleet server's `[retention]` settings are actually applied, safely

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**:
> `git diff --stat e755b97..HEAD -- server/app/retention.py server/app/runner.py server/tests/test_retention.py server/tests/test_runner.py server/server.conf.example server/README.md`
> If any of these changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition. (Plans 001 and 008 also add tests
> to `server/tests/test_runner.py`; additions there are expected.)

## Status

- **Priority**: P2
- **Effort**: M
- **Risk**: MED (this code deletes files; the guard and its tests come first)
- **Depends on**: plans/001-server-parse-took-field.md (run records must be correct before anything is pruned by them)
- **Category**: bug
- **Planned at**: commit `e755b97`, 2026-11-13

## Why this matters

`server.conf` documents a `[retention]` section (keep the newest N fleet
runs, keep D days, keep R run records) and `server/app/retention.py`
implements `prune_runs()` with tests — but **nothing ever calls it**. A
scheduled server therefore fills `reports/` and `server/data/runs/` without
bound (a fleet run folder is tens of MB), and the operator's retention
settings silently do nothing. Wiring it in is not enough on its own,
because three defects would then become live:

1. A record whose `report_path` is `reports/` (or whose `workdir` is `.`)
   resolves to the reports directory itself, which passes the "inside
   reports/" check and would be deleted **whole**, including reports the
   server never created.
2. When the record-count limit drops a record, its report files are left
   behind forever (nothing references them any more).
3. Per-DB detail runs' reports are never pruned at all.

Also, the two tests that claim to prove path-traversal safety assert on a
file that is never created, so they pass no matter what the code does.

## Current state

### `server/app/retention.py`

`_recorded_artifact_paths(rec, reports_dir)` collects candidate paths from a
record (`report_path`, each database's `detail_report`, `workdir`) and
filters them (`:51-64`):

```python
    base = Path(reports_dir).resolve()
    for c in candidates:
        # report_path is stored as "reports/<file>" (or "reports/<run
        # folder>/<file>"); workdir as "fleet_work_<id>" (bare name,
        # relative to reports/).
        c_str = str(c)
        if c_str.startswith("reports/"):
            c_str = c_str[len("reports/") :]
        p = (Path(reports_dir) / c_str)
        try:
            resolved = p.resolve()
            resolved.relative_to(base)
        except (ValueError, OSError):
            continue
```

`resolved.relative_to(base)` also succeeds when `resolved == base` — that
is defect 1. Further down, a file inside a folder named
`awr_fleet_<digits>_run<digits>` is expanded to the whole folder (the
per-run output folder is the deletable unit).

`prune_runs(data_dir, reports_dir=None, keep_fleet_runs=14, keep_days=30,
keep_run_records=200, now=None)` (`:96-164`) has two passes: pass 1 deletes
the artifacts of terminal `fleet` records beyond the newest
`keep_fleet_runs` and older than `keep_days` (marking them
`artifacts_pruned=True`); pass 2 deletes the `.json` record and `.log` of
every record beyond the newest `keep_run_records` — without touching its
artifacts and without looking at its state (defects 2 and "drops a running
record").

### Nothing calls it

`grep -rn "prune_runs\|retention" server/app server/awrserve.py` finds only
the definition and the config parsing (`server/app/config.py:252-259`,
which fills `cfg.retention` = `RetentionConfig(keep_fleet_runs, keep_days,
keep_run_records)`, all validated `>= 0`).

### `server/app/runner.py` (where it will be called)

Import line (`:21`): `from . import fleetconf, paths, records`

`RunManager.start()` (`:65-73`):

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

    def stop(self, timeout=5):
```

The single worker thread (`:250-255`) — exactly one wrapper process runs at
a time, so "after a job" is a moment when nothing is writing into
`reports/`:

```python
            try:
                self._run_job(job)
            finally:
                with self._lock:
                    self._current_job = None
                self._queue.task_done()
```

### Record facts you need

- Kinds: `records.KIND_FLEET`, `records.KIND_DETAIL`. States:
  `STATE_QUEUED`, `STATE_RUNNING`, and the terminal set
  `records.TERMINAL_STATES` (`success`, `partial`, `failed`, `skipped`).
- A fleet record's `report_path` is `reports/awr_fleet_<ts>_run<id>/index.html`.
- A detail record's `report_path` is
  `reports/awr_fleet_<ts>_run<id>/detail_<alias>.html` (its own run folder;
  the folder's `index.html` by-product is already deleted by the runner).
- The home page links, for each database, the newest **successful** detail
  record's report (`server/app/views.py`, `_latest_detail_report`). That
  report must therefore never be pruned.

### The vacuous tests — `server/tests/test_retention.py:76-85` and `:161-171`

```python
    def test_path_traversal_in_record_is_ignored(self):
        ...
        rec["report_path"] = "reports/../../etc/passwd"
        records.save_record(self.data_dir, rec)
        # must not raise, and must not touch anything outside reports_dir
        outside_target = self.reports_dir.parent / "etc_passwd_sentinel"
        retention.prune_runs(...)
        self.assertFalse(outside_target.exists())
```

`etc_passwd_sentinel` is never created, so `assertFalse(…exists())` is
always true.

### Documentation

`server/server.conf.example:91-101` documents the three knobs;
`server/README.md:83-88` has a "## Retention" section.

### Conventions

- `server/` is stdlib-only Python, `unittest`, 4-space indent, `%`-style
  string formatting (no f-strings in `server/app`).
- Tests build isolated temp directories; never touch the real `reports/` or
  `server/data/`.
- The code in this plan was prototyped against the planned-at commit: all
  137 existing tests still pass with it, and the 9 new tests below pass
  with it and 7 of them fail without it.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Server tests | `python3 -m unittest discover -s server/tests -t .` | `OK` |
| Retention tests only | `python3 -m unittest server.tests.test_retention -v` | all pass |
| Lint | `./lint.sh` | exit 0 |

## Scope

**In scope** (the only files you should modify):
- `server/app/retention.py`
- `server/app/runner.py`
- `server/tests/test_retention.py`
- `server/tests/test_runner.py`
- `server/server.conf.example` (comments in `[retention]`)
- `server/README.md` ("## Retention" section)

**Out of scope** (do NOT touch):
- `server/app/config.py` — the config shape and defaults stay.
- `server/app/views.py` — a run page may link a report that retention has
  removed (HTTP 404 "no such report"); showing "pruned" instead is a
  follow-up.
- Anything outside `server/`. In particular never run this code against the
  repository's real `reports/` directory.

## Git workflow

- Branch: `advisor/010-server-wire-retention` from `main`.
- Commit per step where natural. Style: conventional commits with scope,
  e.g. `fix(server): never treat reports/ itself as a prunable artifact`,
  then `feat(server): apply [retention] at startup and after every run`.
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Replace the vacuous traversal tests and add the reports-dir test

In `server/tests/test_retention.py`, class `PruneRunsTest`:

Replace the whole method `test_path_traversal_in_record_is_ignored` with
these two methods:

```python
    def test_path_traversal_in_record_is_ignored(self):
        # A real file OUTSIDE reports_dir that the recorded path points at.
        outside = Path(tempfile.mkdtemp(dir=str(self.reports_dir.parent)))
        victim = outside / "victim.html"
        victim.write_text("do not delete", encoding="utf-8")
        rec = records.new_record("evil", records.KIND_FLEET, "manual")
        rec["state"] = records.STATE_SUCCESS
        rec["started_at"] = self.now - 100 * 86400
        rec["report_path"] = "reports/../%s/victim.html" % outside.name
        records.save_record(self.data_dir, rec)
        retention.prune_runs(self.data_dir, reports_dir=self.reports_dir, keep_fleet_runs=0, keep_days=0, keep_run_records=999)
        self.assertTrue(victim.exists(), "a path escaping reports_dir must never be deleted")

    def test_reports_dir_itself_is_never_deleted(self):
        stray = self.reports_dir / "adhoc_cli_report.html"
        stray.write_text("<html></html>", encoding="utf-8")
        for i, (report_path, workdir) in enumerate(
            [("reports/", None), ("reports/.", None), ("reports", None), (None, "."), (None, "")]
        ):
            rec = records.new_record("base%d" % i, records.KIND_FLEET, "manual")
            rec["state"] = records.STATE_SUCCESS
            rec["started_at"] = self.now - 100 * 86400
            rec["report_path"] = report_path
            rec["workdir"] = workdir
            records.save_record(self.data_dir, rec)
        retention.prune_runs(self.data_dir, reports_dir=self.reports_dir, keep_fleet_runs=0, keep_days=0, keep_run_records=999)
        self.assertTrue(self.reports_dir.is_dir())
        self.assertTrue(stray.exists(), "reports/ itself must never be treated as an artifact")
```

Replace the whole method `test_run_folder_never_escapes_reports_dir` with:

```python
    def test_run_folder_never_escapes_reports_dir(self):
        # A run-folder-shaped directory OUTSIDE reports_dir: the "delete the
        # whole run folder" expansion must not follow the path out.
        outside = Path(tempfile.mkdtemp(dir=str(self.reports_dir.parent)))
        folder = outside / "awr_fleet_1_run1"
        folder.mkdir()
        victim = folder / "index.html"
        victim.write_text("do not delete", encoding="utf-8")
        rec = records.new_record("evil2", records.KIND_FLEET, "manual")
        rec["state"] = records.STATE_SUCCESS
        rec["started_at"] = self.now - 100 * 86400
        rec["report_path"] = "reports/../%s/awr_fleet_1_run1/index.html" % outside.name
        records.save_record(self.data_dir, rec)
        retention.prune_runs(self.data_dir, reports_dir=self.reports_dir, keep_fleet_runs=0, keep_days=0, keep_run_records=999)
        self.assertTrue(victim.exists())
        self.assertTrue(folder.is_dir())
```

**Verify**: `python3 -m unittest server.tests.test_retention -v` →
`test_reports_dir_itself_is_never_deleted` **fails** (the temp reports
directory gets deleted); the two traversal tests pass. This failure is the
expected result of this step and proves defect 1.

### Step 2: Guard the reports directory

In `server/app/retention.py`, `_recorded_artifact_paths`, directly after the
`try/except` that computes `resolved`, add:

```python
        if resolved == base:
            # "reports/", "reports/." or a workdir of "." resolve to the
            # reports directory itself -- never a deletable artifact.
            continue
```

**Verify**: `python3 -m unittest server.tests.test_retention -v` → all pass.

### Step 3: Add the tests for record thinning and detail reports

Append to `server/tests/test_retention.py`, before the
`if __name__ == "__main__":` line:

```python
class RecordThinningTest(unittest.TestCase):
    """Pass 3 (keep_run_records) and the detail-report rules."""

    def setUp(self):
        self.data_dir = Path(tempfile.mkdtemp())
        self.reports_dir = Path(tempfile.mkdtemp())
        self.now = time.time()

    def _fleet(self, run_id, age_days, wrapper_id, state=records.STATE_SUCCESS):
        rec = records.new_record(run_id, records.KIND_FLEET, "manual")
        started = self.now - age_days * 86400
        rec["started_at"] = started
        rec["queued_at"] = started
        rec["state"] = state
        folder = self.reports_dir / ("awr_fleet_202607230000_run%s" % wrapper_id)
        folder.mkdir(parents=True, exist_ok=True)
        (folder / "index.html").write_text("<html></html>", encoding="utf-8")
        rec["report_path"] = "reports/%s/index.html" % folder.name
        records.save_record(self.data_dir, rec)
        return rec, folder

    def _detail(self, run_id, alias, age_days, wrapper_id, state=records.STATE_SUCCESS):
        rec = records.new_record(run_id, records.KIND_DETAIL, "manual", alias=alias)
        started = self.now - age_days * 86400
        rec["started_at"] = started
        rec["queued_at"] = started
        rec["state"] = state
        folder = self.reports_dir / ("awr_fleet_202607230000_run%s" % wrapper_id)
        folder.mkdir(parents=True, exist_ok=True)
        (folder / ("detail_%s.html" % alias)).write_text("<html></html>", encoding="utf-8")
        rec["report_path"] = "reports/%s/detail_%s.html" % (folder.name, alias)
        records.save_record(self.data_dir, rec)
        return rec, folder

    def _prune(self, **kw):
        args = dict(keep_fleet_runs=999, keep_days=999, keep_run_records=999)
        args.update(kw)
        return retention.prune_runs(self.data_dir, reports_dir=self.reports_dir, **args)

    def test_dropping_a_record_also_deletes_its_artifacts(self):
        # keep_run_records smaller than keep_fleet_runs used to orphan the
        # report folder (record gone, files left forever).
        _, new_folder = self._fleet("new", 1, "1")
        _, old_folder = self._fleet("old", 5, "2")
        self._prune(keep_run_records=1)
        self.assertIsNotNone(records.load_record(self.data_dir, "new"))
        self.assertIsNone(records.load_record(self.data_dir, "old"))
        self.assertTrue(new_folder.is_dir())
        self.assertFalse(old_folder.exists())

    def test_queued_and_running_records_are_never_dropped(self):
        self._fleet("done", 1, "1")
        rec, _ = self._fleet("stuck", 50, "2", state=records.STATE_RUNNING)
        self._prune(keep_run_records=1)
        self.assertIsNotNone(records.load_record(self.data_dir, "stuck"))

    def test_old_detail_reports_are_pruned_but_latest_per_alias_survives(self):
        _, f_old = self._detail("d_old", "prod_east", 100, "10")
        _, f_new = self._detail("d_new", "prod_east", 90, "11")
        _, f_other = self._detail("d_other", "prod_west", 200, "12")
        self._prune(keep_days=30)
        self.assertFalse(f_old.exists(), "superseded detail report older than keep_days is pruned")
        self.assertTrue(f_new.exists(), "newest successful detail per alias is always kept")
        self.assertTrue(f_other.exists(), "the only detail report of an alias is always kept")
        self.assertTrue(records.load_record(self.data_dir, "d_old")["artifacts_pruned"])

    def test_recent_detail_reports_are_kept(self):
        _, f_a = self._detail("d_a", "prod_east", 2, "20")
        _, f_b = self._detail("d_b", "prod_east", 1, "21")
        self._prune(keep_days=30)
        self.assertTrue(f_a.exists())
        self.assertTrue(f_b.exists())

    def test_latest_detail_record_survives_record_thinning(self):
        _, f_detail = self._detail("d_only", "prod_east", 300, "30")
        for i in range(3):
            self._fleet("f%d" % i, i, str(40 + i))
        self._prune(keep_run_records=2)
        self.assertIsNotNone(records.load_record(self.data_dir, "d_only"))
        self.assertTrue(f_detail.exists())
```

**Verify**: `python3 -m unittest server.tests.test_retention.RecordThinningTest -v`
→ 4 of the 5 tests **fail** (`test_recent_detail_reports_are_kept` passes).
Expected at this step.

### Step 4: Rewrite `prune_runs` (three passes, no orphans)

In `server/app/retention.py`, replace everything from the line
`def prune_runs(` to the end of the file with:

```python
def _latest_detail_ids(all_records):
    """run_ids of the newest successful detail record per alias -- the report
    the home page links for that database, so it is never pruned."""
    best = {}
    for r in all_records:
        if (
            r.get("kind") == records.KIND_DETAIL
            and r.get("state") == records.STATE_SUCCESS
            and r.get("report_path")
        ):
            cur = best.get(r.get("alias"))
            if cur is None or _record_sort_key(r) > _record_sort_key(cur):
                best[r.get("alias")] = r
    return set(r["run_id"] for r in best.values())


def _prune_artifacts(data_dir, rec, reports_dir):
    """Delete rec's recorded artifacts and mark it. Returns how many paths
    were deleted (0 when already pruned)."""
    if rec.get("artifacts_pruned"):
        return 0
    n = 0
    for p in _recorded_artifact_paths(rec, reports_dir):
        _delete_path(p)
        n += 1
    rec["artifacts_pruned"] = True
    records.save_record(data_dir, rec)
    return n


def prune_runs(data_dir, reports_dir=None, keep_fleet_runs=14, keep_days=30, keep_run_records=200, now=None):
    """Prune terminal run artifacts + thin old records/logs.

    Three passes:
      1. Among terminal-state 'fleet' records, keep the newest
         `keep_fleet_runs` OR anything younger than `keep_days`; for the
         rest, delete their recorded report/detail-report/workdir paths
         (marking the record `artifacts_pruned=True`, record itself kept).
      2. Among terminal-state 'detail' records, keep the newest successful
         one per alias (the report the home page links) and anything
         younger than `keep_days`; delete the artifacts of the rest.
      3. Across ALL terminal records (any kind), keep only the newest
         `keep_run_records`; anything older loses its artifacts (if not
         pruned yet), its .json record and its .log file. Queued/running
         records and the newest successful detail per alias are never
         dropped.

    Returns a summary dict for tests/observability.
    """
    now = now if now is not None else time.time()
    reports_dir = Path(reports_dir) if reports_dir else paths.REPORTS_DIR
    data_dir = Path(data_dir)

    all_records = records.list_records(data_dir)  # newest first already
    cutoff = now - keep_days * 86400
    latest_detail = _latest_detail_ids(all_records)

    # ---- pass 1: fleet artifact pruning --------------------------------
    fleet_terminal = [
        r
        for r in all_records
        if r.get("kind") == records.KIND_FLEET and r.get("state") in records.TERMINAL_STATES
    ]
    fleet_terminal.sort(key=_record_sort_key, reverse=True)

    keep_ids = set()
    for r in fleet_terminal[:keep_fleet_runs]:
        keep_ids.add(r["run_id"])
    for r in fleet_terminal:
        if _record_sort_key(r) >= cutoff:
            keep_ids.add(r["run_id"])

    pruned_artifacts = 0
    for r in fleet_terminal:
        if r["run_id"] in keep_ids:
            continue
        pruned_artifacts += _prune_artifacts(data_dir, r, reports_dir)

    # ---- pass 2: detail artifact pruning -------------------------------
    for r in all_records:
        if r.get("kind") != records.KIND_DETAIL or r.get("state") not in records.TERMINAL_STATES:
            continue
        if r["run_id"] in latest_detail or _record_sort_key(r) >= cutoff:
            continue
        pruned_artifacts += _prune_artifacts(data_dir, r, reports_dir)

    # ---- pass 3: thin records/logs beyond keep_run_records -------------
    all_records_sorted = sorted(all_records, key=_record_sort_key, reverse=True)
    thinned = 0
    for r in all_records_sorted[keep_run_records:]:
        if r.get("state") not in records.TERMINAL_STATES:
            continue
        if r["run_id"] in latest_detail:
            continue
        pruned_artifacts += _prune_artifacts(data_dir, r, reports_dir)
        rp = records.record_path(data_dir, r["run_id"])
        lp = records.log_path(data_dir, r["run_id"])
        for p in (rp, lp):
            try:
                if p.exists():
                    p.unlink()
                    thinned += 1
            except OSError:
                pass

    return {
        "fleet_terminal_considered": len(fleet_terminal),
        "fleet_kept": len(keep_ids),
        "artifacts_pruned": pruned_artifacts,
        "records_thinned": thinned,
    }
```

Notes on what changed versus the old function: artifact deletion moved into
`_prune_artifacts`; pass 2 is new (detail records); pass 3 is the old
pass 2 plus three rules — skip non-terminal records, skip the newest
successful detail per alias, delete artifacts before dropping the record.
The returned summary keys are unchanged.

Also update the module docstring's first sentence if it still says only
fleet artifacts are pruned: it should say "fleet and detail run artifacts".

**Verify**: `python3 -m unittest server.tests.test_retention -v` → all pass
(old and new tests).

### Step 5: Add the wiring tests

Append to `server/tests/test_runner.py` (it already defines `make_config`,
`wait_until`, `FAKE_WRAPPER` and imports `config_mod`, `records`, `runner`,
`tempfile`, `time`, `Path`):

```python
class RetentionWiringTest(unittest.TestCase):
    """[retention] must actually be applied: at startup and after each job."""

    def _env(self, keep_fleet_runs, keep_days=0):
        cwd = Path(tempfile.mkdtemp())
        (cwd / "reports").mkdir()
        data_dir = Path(tempfile.mkdtemp())
        conf_path = cwd / "fleet.conf"
        conf_path.write_text("good1|/@x\n", encoding="utf-8")
        cfg = make_config(conf_path)
        cfg.retention = config_mod.RetentionConfig(
            keep_fleet_runs=keep_fleet_runs, keep_days=keep_days, keep_run_records=200
        )
        return cwd, data_dir, cfg

    def _old_fleet_record(self, cwd, data_dir, run_id, wrapper_id, age_days):
        folder = cwd / "reports" / ("awr_fleet_202601010000_run%s" % wrapper_id)
        folder.mkdir()
        (folder / "index.html").write_text("<html></html>", encoding="utf-8")
        rec = records.new_record(run_id, records.KIND_FLEET, "schedule")
        rec["state"] = records.STATE_SUCCESS
        rec["started_at"] = time.time() - age_days * 86400
        rec["queued_at"] = rec["started_at"]
        rec["report_path"] = "reports/%s/index.html" % folder.name
        records.save_record(data_dir, rec)
        return folder

    def test_prune_runs_at_startup(self):
        cwd, data_dir, cfg = self._env(keep_fleet_runs=1)
        old = self._old_fleet_record(cwd, data_dir, "old", "1", age_days=20)
        newer = self._old_fleet_record(cwd, data_dir, "newer", "2", age_days=10)
        rm = runner.RunManager(cfg, data_dir=data_dir, cwd=cwd, wrapper_path=FAKE_WRAPPER)
        rm.start()
        try:
            self.assertFalse(old.exists())
            self.assertTrue(newer.exists())
        finally:
            rm.stop(timeout=5)

    def test_prune_runs_after_each_job_and_keeps_the_new_report(self):
        cwd, data_dir, cfg = self._env(keep_fleet_runs=1)
        rm = runner.RunManager(cfg, data_dir=data_dir, cwd=cwd, wrapper_path=FAKE_WRAPPER)
        rm.start()
        try:
            old = self._old_fleet_record(cwd, data_dir, "old", "1", age_days=20)
            rec = rm.enqueue_fleet("manual")
            self.assertTrue(wait_until(lambda: not old.exists()), "old run folder was not pruned after the job")
            done = records.load_record(data_dir, rec["run_id"])
            self.assertEqual(done["state"], records.STATE_SUCCESS)
            self.assertTrue((cwd / done["report_path"]).is_file(), "the run that just finished must keep its report")
        finally:
            rm.stop(timeout=5)

    def test_zero_keep_values_never_delete_the_newest_run(self):
        cwd, data_dir, cfg = self._env(keep_fleet_runs=0, keep_days=0)
        cfg.retention.keep_run_records = 0
        rm = runner.RunManager(cfg, data_dir=data_dir, cwd=cwd, wrapper_path=FAKE_WRAPPER)
        rm.start()
        try:
            rec = rm.enqueue_fleet("manual")
            self.assertTrue(
                wait_until(
                    lambda: (records.load_record(data_dir, rec["run_id"]) or {}).get("state")
                    in records.TERMINAL_STATES
                )
            )
            rm._queue.join()
            done = records.load_record(data_dir, rec["run_id"])
            self.assertIsNotNone(done)
            self.assertTrue((cwd / done["report_path"]).is_file())
        finally:
            rm.stop(timeout=5)
```

**Verify**: `python3 -m unittest server.tests.test_runner.RetentionWiringTest -v`
→ `test_prune_runs_at_startup` and
`test_prune_runs_after_each_job_and_keeps_the_new_report` **fail** (the
second one only after its 10-second wait). Expected at this step.

### Step 6: Call `prune_runs` from the run manager

In `server/app/runner.py`:

1. Change the import to `from . import fleetconf, paths, records, retention`.
2. Add this method to `RunManager`, directly above `def stop(`:

```python
    def _prune(self):
        """Apply [retention] (see retention.prune_runs). Called at startup
        and after every job, always from a point where no wrapper is
        running. Never raises: housekeeping must not fail a run. The newest
        fleet run and the newest record are always kept, whatever the
        configured numbers."""
        ret = getattr(self.config, "retention", None)
        if ret is None:
            return None
        try:
            return retention.prune_runs(
                self.data_dir,
                reports_dir=self.reports_dir,
                keep_fleet_runs=max(1, ret.keep_fleet_runs),
                keep_days=ret.keep_days,
                keep_run_records=max(1, ret.keep_run_records),
            )
        except Exception:
            return None
```

3. In `start()`, add `self._prune()` on the line after
   `recovered = records.recover_stuck_running(self.data_dir)`.
4. In `_worker_loop`, add `self._prune()` as the **first** statement of the
   `finally:` block (before the `with self._lock:` that clears
   `_current_job`), so the job still counts as current while housekeeping
   runs:

```python
            try:
                self._run_job(job)
            finally:
                self._prune()
                with self._lock:
                    self._current_job = None
                self._queue.task_done()
```

**Verify**: `python3 -m unittest discover -s server/tests -t .` → `OK`,
at least 146 tests (137 + 9; more if plans 001/002/008/009 already landed).

### Step 7: Documentation

In `server/server.conf.example`, `[retention]` section, add comment lines
(keep the three settings and their values unchanged):

```
# Applied automatically at server start and after every run.
# Per-DB detail reports follow keep_days too, except that the newest
# successful detail report of each database is always kept.
# The most recent fleet run and the most recent record are never removed,
# even when a value below is 0.
```

and change the comment above `keep_run_records` to say that a record
removed by this limit takes its report files with it.

In `server/README.md`, "## Retention", add one sentence: retention runs at
startup and after each run; the newest fleet run and each database's newest
successful detail report are always kept.

**Verify**: `grep -c "Applied automatically" server/server.conf.example` → `1`.

## Test plan

- `PruneRunsTest`: the two traversal tests now target real files outside
  `reports/`; new `test_reports_dir_itself_is_never_deleted`.
- New `RecordThinningTest` (5 tests): artifacts deleted with a dropped
  record; queued/running records never dropped; old superseded detail
  reports pruned while the newest per alias survives; recent detail reports
  kept; the newest detail record survives record thinning.
- New `RetentionWiringTest` (3 tests) in `test_runner.py`: pruning at
  startup; pruning after a job while the fresh report survives; zero
  settings never delete the newest run.
- Verification: `python3 -m unittest discover -s server/tests -t .` → `OK`.

## Done criteria

- [ ] `python3 -m unittest discover -s server/tests -t .` exits 0 with ≥ 146 tests
- [ ] `grep -c "self._prune()" server/app/runner.py` → `2`
- [ ] `grep -c "resolved == base" server/app/retention.py` → `1`
- [ ] `grep -c "etc_passwd_sentinel" server/tests/test_retention.py` → `0`
- [ ] `./lint.sh` exits 0
- [ ] `git status --short` shows only in-scope files; the repository's own `reports/` directory is untouched (`git status --short reports/` empty and the directory still exists)
- [ ] `plans/README.md` status row updated

## STOP conditions

- After step 2, `test_reports_dir_itself_is_never_deleted` still fails.
- Any pre-existing retention or runner test fails after step 4 or step 6.
- A test you run deletes or modifies anything outside a `tempfile` directory
  (check `ls reports/ | wc -l` before and after the full test run — the
  count must not change).
- `RunManager` no longer has a single worker thread (more than one job could
  run at once) — pruning "after a job" would then race a running wrapper.

## Maintenance notes

- **First start after deploying this**: retention will apply to the whole
  existing history at once. With the defaults (14 runs / 30 days / 200
  records) an old installation may delete many old run folders on first
  start. That is the documented behaviour, but tell the operator before
  upgrading a long-running instance.
- Records written before plan 001 mis-state some runs (partial runs marked
  success, detail runs marked failed). Retention treats `failed` detail
  records like any other terminal record, so their reports age out after
  `keep_days`; the newest *successful* one per alias is what is protected.
- Reviewer: read `_recorded_artifact_paths` and `_prune_artifacts` with the
  question "can this ever delete something the server did not create?" —
  only paths written into a record by the server are candidates, they must
  resolve strictly inside `reports/`, and never to `reports/` itself.
- Deferred: `views.py` showing "report pruned" instead of a dead link for a
  record with `artifacts_pruned`; an allow-list of deletable names
  (`awr_fleet_*_run*`, `fleet_work_*`) as defence in depth.
