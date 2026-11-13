# Plan 011: The scheduler catches up a missed daily run, does not drift, and survives a failed state write

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**:
> `git diff --stat e755b97..HEAD -- server/app/scheduler.py server/tests/test_scheduler.py server/server.conf.example`
> If any of these changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P2
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none
- **Category**: bug
- **Planned at**: commit `e755b97`, 2026-11-13

## Why this matters

The fleet server's scheduler starts fleet runs either at fixed times
(`mode = daily`, `daily_at = 02:00`) or on an interval (`mode = every`).
Three defects:

1. **`catchup` does nothing in daily mode.** The option promises that a run
   missed while the server was down is fired at startup. But the daily
   computation only ever looks forward from "now", so the result is never
   overdue and the catch-up branch can not trigger. A host reboot across
   the nightly slot silently skips that night's report.
2. **Interval mode drifts.** After firing, the next occurrence is computed
   from the moment the loop *noticed* the due time (it wakes every 30 s),
   not from the scheduled time, so the cadence slips by up to 30 s per
   cycle, always later.
3. **A failed state write kills the scheduler.** `_save_state()` runs
   outside the loop's `try`; a full disk or a permissions problem raises
   inside the thread, the thread dies, and no scheduled run ever fires
   again while the web UI keeps looking healthy.

## Current state

File `server/app/scheduler.py` (155 lines). Module docstring says state
persists "so a 'daily_at' schedule can tell whether today's slot was
already missed" — the intent that defect 1 breaks.

The pure functions (`:25-75`):

```python
def next_fire_daily(daily_at, now):
    """Earliest datetime strictly after `now` matching one of the 'HH:MM'
    strings in daily_at (today if still ahead, else a following day)."""
    ...

def next_fire_every(every_hours, now, last_fire):
    """'every' mode is anchored to last_fire (persisted); with no prior
    fire recorded, the very first occurrence is 'now' (fire immediately)."""
    if last_fire is None:
        return now
    return last_fire + datetime.timedelta(hours=every_hours)


def compute_next_fire(schedule_cfg, now, last_fire):
    if schedule_cfg.mode == "daily":
        return next_fire_daily(schedule_cfg.daily_at, now)
    return next_fire_every(schedule_cfg.every_hours, now, last_fire)


def apply_catchup(next_fire_dt, now, catchup, schedule_cfg):
    """If the computed next_fire is already due (<= now):
      - catchup=True:  leave it as-is, so the caller fires it right away.
      - catchup=False: advance past every missed occurrence so the overdue
        one is silently skipped (never fired).
    """
    if next_fire_dt is None or next_fire_dt > now:
        return next_fire_dt
    if catchup:
        return next_fire_dt
    if schedule_cfg.mode == "daily":
        return next_fire_daily(schedule_cfg.daily_at, now)
    ...
```

Startup and loop (`:120-129`, `:144-155`):

```python
    def start(self):
        if not self.config.schedule.enabled:
            return
        self._last_fire = self._load_last_fire()
        now = self._clock()
        nf = compute_next_fire(self.config.schedule, now, self._last_fire)
        self._next_fire = apply_catchup(nf, now, self.config.schedule.catchup, self.config.schedule)
        self._save_state()
        self._thread = threading.Thread(target=self._loop, name="awrserve-scheduler", daemon=True)
        self._thread.start()
...
    def _loop(self):
        while not self._stop.is_set():
            now = self._clock()
            if self._next_fire and now >= self._next_fire:
                try:
                    self.run_manager.enqueue_fleet("schedule")
                except Exception:
                    pass  # a scheduler tick must never crash the thread
                self._last_fire = now
                self._next_fire = compute_next_fire(self.config.schedule, now, self._last_fire)
                self._save_state()
            self._stop.wait(self.sleep_slice)
```

Other facts:

- `Scheduler.__init__(self, config, run_manager, data_dir=None,
  sleep_slice=30, clock=None)` — `clock` is injectable (tests use it),
  `self._state_path()` is `<data_dir>/state.json`, and `_load_last_fire()`
  reads `{"last_fire": "<isoformat>", ...}` from it.
- `config.schedule` is a `ScheduleConfig(enabled, mode, daily_at,
  every_hours, catchup)` dataclass (`server/app/config.py`), `catchup`
  defaults to `True`.
- Imports at the top of the file: `datetime`, `json`, `os`, `threading`,
  `pathlib.Path`, `from . import paths`. (`sys` is not imported yet.)
- Tests: `server/tests/test_scheduler.py` has a helper
  `dt(y, mo, d, h, mi)` and classes `NextFireDailyTest`, `NextFireEveryTest`,
  `ComputeNextFireTest`, `ApplyCatchupTest`, `SchedulerThreadTest`.
  `ComputeNextFireTest.test_daily_mode` calls
  `compute_next_fire(cfg, now, None)` — with no last fire the result must
  stay "the next slot after now".
- Style in `server/app`: stdlib only, `%`-formatting, no f-strings.

The design of the fix:

- **Daily catch-up**: compute the next daily slot after the **last fire**
  (when one is recorded) instead of after now. If the server was down
  across a slot, that slot is ≤ now, and the existing `apply_catchup()`
  does the rest (fire it, or skip to the next future slot when
  `catchup = false`). With no recorded fire — a brand-new install — nothing
  is overdue, so starting the server never triggers a surprise run.
  However many days were missed, exactly one catch-up run fires.
- **No drift**: after an interval-mode fire, record the *scheduled* time as
  the anchor (unless the fire was a full period or more late — then
  re-anchor on now, the existing behaviour for long outages).
- **Robust loop**: move the tick body into `_tick()`, advance the in-memory
  schedule before persisting, catch `OSError` from the state write, and
  wrap each tick so no exception can end the thread. Failures are printed
  to stderr (the server's log) instead of being swallowed.

This design was prototyped against the planned-at commit: the 17 existing
scheduler tests pass unchanged, the 11 new tests below pass with it, and 8
of them fail without it.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Scheduler tests | `python3 -m unittest server.tests.test_scheduler -v` | all pass |
| Server tests | `python3 -m unittest discover -s server/tests -t .` | `OK` |
| Lint | `./lint.sh` | exit 0 |

## Scope

**In scope** (the only files you should modify):
- `server/app/scheduler.py`
- `server/tests/test_scheduler.py`
- `server/server.conf.example` (the comment on `catchup`)

**Out of scope** (do NOT touch):
- Time zones / DST handling — documented as a known limitation in the module
  docstring; not this plan.
- `server/app/runner.py` — how a scheduled duplicate is recorded (`skipped`)
  stays as is.
- `apply_catchup()` and `next_fire_daily()` / `next_fire_every()` — unchanged.

## Git workflow

- Branch: `advisor/011-server-scheduler-catchup-drift` from `main`.
- Commit style: conventional commits with scope. Suggested:
  `fix(server): daily catchup, no interval drift, scheduler survives a failed state write`.
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Add the failing tests

In `server/tests/test_scheduler.py`, insert these two classes directly
above `class ApplyCatchupTest(unittest.TestCase):`

```python
class DailyCatchupTest(unittest.TestCase):
    """A daily_at slot missed while the server was down must be detectable."""

    CFG = dict(mode="daily", daily_at=["02:00"])

    def test_missed_slot_is_overdue_and_fires_with_catchup(self):
        cfg = config_mod.ScheduleConfig(catchup=True, **self.CFG)
        last = dt(2026, 7, 21, 2, 0)          # fired yesterday
        now = dt(2026, 7, 22, 9, 0)           # server back up after today's 02:00
        nf = scheduler.compute_next_fire(cfg, now, last)
        self.assertEqual(nf, dt(2026, 7, 22, 2, 0))
        self.assertLessEqual(scheduler.apply_catchup(nf, now, True, cfg), now)

    def test_missed_slot_is_skipped_without_catchup(self):
        cfg = config_mod.ScheduleConfig(catchup=False, **self.CFG)
        last = dt(2026, 7, 21, 2, 0)
        now = dt(2026, 7, 22, 9, 0)
        nf = scheduler.compute_next_fire(cfg, now, last)
        self.assertEqual(scheduler.apply_catchup(nf, now, False, cfg), dt(2026, 7, 23, 2, 0))

    def test_nothing_missed_waits_for_the_next_slot(self):
        cfg = config_mod.ScheduleConfig(catchup=True, **self.CFG)
        last = dt(2026, 7, 22, 2, 0)          # today's slot already fired
        now = dt(2026, 7, 22, 9, 0)
        nf = scheduler.compute_next_fire(cfg, now, last)
        self.assertEqual(scheduler.apply_catchup(nf, now, True, cfg), dt(2026, 7, 23, 2, 0))

    def test_first_ever_start_does_not_fire_a_past_slot(self):
        cfg = config_mod.ScheduleConfig(catchup=True, **self.CFG)
        now = dt(2026, 7, 22, 9, 0)
        nf = scheduler.compute_next_fire(cfg, now, None)
        self.assertEqual(scheduler.apply_catchup(nf, now, True, cfg), dt(2026, 7, 23, 2, 0))

    def test_many_missed_days_fire_once(self):
        cfg = config_mod.ScheduleConfig(catchup=True, **self.CFG)
        last = dt(2026, 7, 1, 2, 0)
        now = dt(2026, 7, 22, 9, 0)
        self.assertLessEqual(scheduler.compute_next_fire(cfg, now, last), now)
        # after the catch-up fire, last_fire is 'now' -> next is tomorrow
        after = scheduler.anchor_after_fire(cfg, now, dt(2026, 7, 2, 2, 0))
        self.assertEqual(after, now)
        self.assertEqual(scheduler.compute_next_fire(cfg, now, after), dt(2026, 7, 23, 2, 0))


class AnchorAfterFireTest(unittest.TestCase):
    def test_every_mode_anchors_on_the_scheduled_time(self):
        cfg = config_mod.ScheduleConfig(mode="every", every_hours=6)
        scheduled = dt(2026, 7, 22, 6, 0)
        now = scheduled + datetime.timedelta(seconds=29)   # tick noticed it late
        last = scheduler.anchor_after_fire(cfg, now, scheduled)
        self.assertEqual(last, scheduled)
        self.assertEqual(scheduler.compute_next_fire(cfg, now, last), dt(2026, 7, 22, 12, 0))

    def test_every_mode_reanchors_when_a_full_period_late(self):
        cfg = config_mod.ScheduleConfig(mode="every", every_hours=6)
        scheduled = dt(2026, 7, 22, 6, 0)
        now = dt(2026, 7, 22, 15, 0)
        self.assertEqual(scheduler.anchor_after_fire(cfg, now, scheduled), now)

    def test_daily_mode_records_now(self):
        cfg = config_mod.ScheduleConfig(mode="daily", daily_at=["02:00"])
        now = dt(2026, 7, 22, 2, 0) + datetime.timedelta(seconds=12)
        self.assertEqual(scheduler.anchor_after_fire(cfg, now, dt(2026, 7, 22, 2, 0)), now)
```

and append this class before the final `if __name__ == "__main__":` line:

```python
class SchedulerRobustnessTest(unittest.TestCase):
    """Driven tick by tick with a fake clock and a fake run manager."""

    class _RM:
        def __init__(self):
            self.calls = 0

        def enqueue_fleet(self, trigger):
            self.calls += 1

    def _sched(self, schedule, now):
        cfg = config_mod.Config()
        cfg.schedule = schedule
        self.clock_now = now
        self.rm = self._RM()
        self.data_dir = Path(tempfile.mkdtemp())
        return scheduler.Scheduler(cfg, self.rm, data_dir=self.data_dir, clock=lambda: self.clock_now)

    def test_state_save_failure_does_not_refire_or_raise(self):
        sched = self._sched(
            config_mod.ScheduleConfig(enabled=True, mode="daily", daily_at=["02:00"]), dt(2026, 7, 22, 1, 0)
        )
        sched._next_fire = dt(2026, 7, 22, 2, 0)

        def boom():
            raise OSError("disk full")

        sched._save_state = boom
        self.clock_now = dt(2026, 7, 22, 2, 0)
        sched._tick()
        sched._tick()
        self.assertEqual(self.rm.calls, 1)
        self.assertEqual(sched._next_fire, dt(2026, 7, 23, 2, 0))

    def test_every_mode_does_not_drift_over_many_cycles(self):
        sched = self._sched(
            config_mod.ScheduleConfig(enabled=True, mode="every", every_hours=1), dt(2026, 7, 22, 0, 0)
        )
        sched._next_fire = dt(2026, 7, 22, 0, 0)
        for hour in range(0, 24):
            # every tick notices the occurrence 29 s late
            self.clock_now = dt(2026, 7, 22, hour, 0) + datetime.timedelta(seconds=29)
            sched._tick()
        self.assertEqual(self.rm.calls, 24)
        self.assertEqual(sched._next_fire, dt(2026, 7, 23, 0, 0))

    def test_daily_catchup_fires_at_start_after_downtime(self):
        sched = self._sched(
            config_mod.ScheduleConfig(enabled=True, mode="daily", daily_at=["02:00"], catchup=True),
            dt(2026, 7, 22, 9, 0),
        )
        (self.data_dir / "state.json").write_text(
            '{"last_fire": "2026-07-21T02:00:05", "next_fire": "2026-07-22T02:00:00"}', encoding="utf-8"
        )
        sched.sleep_slice = 0.02
        sched.start()
        try:
            deadline = time.time() + 5
            while time.time() < deadline and self.rm.calls == 0:
                time.sleep(0.02)
            self.assertEqual(self.rm.calls, 1)
        finally:
            sched.stop()
        self.assertEqual(sched._next_fire, dt(2026, 7, 23, 2, 0))
```

**Verify**: `python3 -m unittest server.tests.test_scheduler` → **fails**
with 8 failing/erroring tests (`AnchorAfterFireTest` ×3,
`DailyCatchupTest` ×2, `SchedulerRobustnessTest` ×3). Expected at this step.
(The last of them waits about 5 seconds before failing.)

### Step 2: Fix `compute_next_fire` and add `anchor_after_fire`

In `server/app/scheduler.py`, replace the `compute_next_fire` function with
the following two functions (`apply_catchup` stays directly below them,
unchanged):

```python
def compute_next_fire(schedule_cfg, now, last_fire):
    """Next occurrence after the last fire. The result may already be due
    (<= now) when the server was down across an occurrence -- the caller
    passes it through apply_catchup() to decide whether to fire it."""
    if schedule_cfg.mode == "daily":
        # Anchor on last_fire when there is one, so a 'daily_at' slot missed
        # while the server was down is seen as overdue (catchup). With no
        # recorded fire (first ever start) nothing is overdue: next slot.
        anchor = last_fire if last_fire is not None else now
        return next_fire_daily(schedule_cfg.daily_at, anchor)
    return next_fire_every(schedule_cfg.every_hours, now, last_fire)


def anchor_after_fire(schedule_cfg, now, fired_for):
    """What to record as last_fire after firing the occurrence `fired_for`
    at wall-clock `now`.

    'every' mode anchors the cadence on the SCHEDULED time, not on the tick
    that noticed it (the loop wakes up to sleep_slice late, and anchoring on
    'now' drifts by that much every cycle). A catch-up fire that is a full
    period or more late re-anchors on 'now', as before. 'daily' mode always
    records 'now' (a catch-up fire must not be followed by another one for
    the same missed day)."""
    if schedule_cfg.mode != "every" or fired_for is None:
        return now
    period = datetime.timedelta(hours=schedule_cfg.every_hours)
    if fired_for <= now and now - fired_for < period:
        return fired_for
    return now
```

**Verify**: `python3 -m unittest server.tests.test_scheduler.DailyCatchupTest server.tests.test_scheduler.AnchorAfterFireTest server.tests.test_scheduler.ComputeNextFireTest -v`
→ all pass.

### Step 3: Make the loop robust

1. Add `import sys` to the imports (alphabetical order: after `import os`).
2. Replace the whole `_loop` method (the last method in the file) with:

```python
    def _tick(self):
        now = self._clock()
        if not (self._next_fire and now >= self._next_fire):
            return
        fired_for = self._next_fire
        try:
            self.run_manager.enqueue_fleet("schedule")
        except Exception as exc:
            print("scheduler: could not enqueue the scheduled run: %s" % exc, file=sys.stderr, flush=True)
        # Advance the in-memory schedule BEFORE persisting it: if the state
        # file cannot be written, the next tick must not fire this
        # occurrence again.
        self._last_fire = anchor_after_fire(self.config.schedule, now, fired_for)
        self._next_fire = compute_next_fire(self.config.schedule, now, self._last_fire)
        try:
            self._save_state()
        except OSError as exc:
            print("scheduler: could not save %s: %s" % (self._state_path(), exc), file=sys.stderr, flush=True)

    def _loop(self):
        while not self._stop.is_set():
            try:
                self._tick()
            except Exception as exc:  # a scheduler tick must never kill the thread
                print("scheduler: tick failed: %s" % exc, file=sys.stderr, flush=True)
            self._stop.wait(self.sleep_slice)
```

**Verify**:
- `python3 -m unittest server.tests.test_scheduler -v` → all 28 pass. (One
  test prints `scheduler: could not save …: disk full` to stderr — that is
  the simulated failure being reported, not an error.)
- `python3 -m unittest discover -s server/tests -t .` → `OK`.

### Step 4: Update the docstring and the example config

1. In the module docstring of `server/app/scheduler.py`, keep the sentence
   about `state.json` and add: "At startup a 'daily_at' occurrence that
   fell between the last recorded fire and now is treated as missed: with
   catchup it fires once, immediately."
2. In `server/server.conf.example`, find the comment above `catchup` in
   `[schedule]` (`grep -n "catchup" server/server.conf.example`) and make
   sure it states: applies to both modes; at startup, if a scheduled time
   passed while the server was down, one run starts immediately (never more
   than one); a first-ever start does not trigger it; `false` skips to the
   next scheduled time. Reword only that comment.

**Verify**: `grep -n -i "catchup" server/server.conf.example` → the comment
mentions both modes; `python3 -m unittest server.tests.test_config` → `OK`
(the example file is parsed by config tests if any reference it).

## Test plan

- New `DailyCatchupTest` (5): missed slot fires with catchup; skipped
  without; nothing missed; first-ever start; many missed days fire once.
- New `AnchorAfterFireTest` (3): interval anchors on the scheduled time;
  re-anchors when a full period late; daily records now.
- New `SchedulerRobustnessTest` (3): state-write failure neither refires
  nor raises; 24 interval cycles noticed 29 s late do not drift; a daily
  catch-up fires at start after downtime (real thread, fake run manager).
- Existing 17 scheduler tests unchanged.
- Verification: `python3 -m unittest discover -s server/tests -t .` → `OK`.

## Done criteria

- [ ] `python3 -m unittest server.tests.test_scheduler` → 28 tests, `OK`
- [ ] `python3 -m unittest discover -s server/tests -t .` exits 0
- [ ] `grep -c "def anchor_after_fire" server/app/scheduler.py` → `1`; `grep -c "def _tick" server/app/scheduler.py` → `1`
- [ ] `./lint.sh` exits 0
- [ ] `git status --short` shows only the three in-scope files
- [ ] `plans/README.md` status row updated

## STOP conditions

- An existing scheduler test fails after step 2 or 3 (most likely
  `ComputeNextFireTest.test_daily_mode` or `SchedulerThreadTest`) — report
  the assertion; do not change the old test to fit.
- `Scheduler.__init__` no longer accepts `clock=` / `data_dir=` (the new
  tests depend on them).
- You find another caller of `compute_next_fire` outside `scheduler.py`
  (`grep -rn "compute_next_fire" server/`) — its expectations must be
  checked first.

## Maintenance notes

- Behaviour change operators will notice: after this lands, restarting a
  server with `mode = daily` and the default `catchup = true` **later than
  a scheduled time that it missed** starts one fleet run immediately. That
  is what the option always claimed. Operators who restart during business
  hours and do not want that should set `catchup = false`.
- Manual runs do not update `last_fire`; a missed slot is caught up even if
  someone ran the fleet by hand in between.
- Reviewer: check the order in `_tick()` — in-memory `_last_fire` /
  `_next_fire` are advanced before `_save_state()`, so a persistently
  failing state file cannot cause a run every 30 seconds.
