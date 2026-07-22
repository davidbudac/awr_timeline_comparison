"""Scheduler thread: computes next_fire and enqueues fleet runs.

Naive local time throughout (no tz-awareness) -- documented DST caveat, not
solved: a 'daily_at' fire can shift by an hour across a DST transition.
State (last_fire/next_fire) persists to server/data/state.json so an
'every_hours' cadence survives a server restart without refiring
immediately, and so a 'daily_at' schedule can tell whether today's slot
was already missed.
"""

import datetime
import json
import os
import threading
from pathlib import Path

from . import paths


# ---------------------------------------------------------------------------
# Pure math -- unit-testable without any thread/clock mocking gymnastics.
# ---------------------------------------------------------------------------


def next_fire_daily(daily_at, now):
    """Earliest datetime strictly after `now` matching one of the 'HH:MM'
    strings in daily_at (today if still ahead, else a following day)."""
    if not daily_at:
        return None
    for offset_days in range(0, 8):
        day = (now + datetime.timedelta(days=offset_days)).date()
        candidates = []
        for hhmm in daily_at:
            hh, mm = hhmm.split(":")
            dt = datetime.datetime(day.year, day.month, day.day, int(hh), int(mm))
            if dt > now:
                candidates.append(dt)
        if candidates:
            return min(candidates)
    return None  # pragma: no cover -- unreachable with a non-empty daily_at


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
    step = datetime.timedelta(hours=schedule_cfg.every_hours)
    if step.total_seconds() <= 0:  # pragma: no cover -- config validates > 0
        return now
    dt = next_fire_dt
    while dt <= now:
        dt += step
    return dt


# ---------------------------------------------------------------------------
# Thread
# ---------------------------------------------------------------------------


class Scheduler:
    def __init__(self, config, run_manager, data_dir=None, sleep_slice=30, clock=None):
        self.config = config
        self.run_manager = run_manager
        self.data_dir = Path(data_dir) if data_dir else paths.DATA_DIR
        self.sleep_slice = sleep_slice
        self._clock = clock or datetime.datetime.now
        self._stop = threading.Event()
        self._thread = None
        self._next_fire = None
        self._last_fire = None

    def _state_path(self):
        return self.data_dir / "state.json"

    def _load_last_fire(self):
        p = self._state_path()
        try:
            with open(p, "r", encoding="utf-8") as f:
                data = json.load(f)
            raw = data.get("last_fire")
            return datetime.datetime.fromisoformat(raw) if raw else None
        except (OSError, ValueError, KeyError, json.JSONDecodeError):
            return None

    def _save_state(self):
        p = self._state_path()
        p.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        tmp = str(p) + ".tmp"
        data = {
            "last_fire": self._last_fire.isoformat() if self._last_fire else None,
            "next_fire": self._next_fire.isoformat() if self._next_fire else None,
        }
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(data, f)
        os.replace(tmp, str(p))

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

    def stop(self, timeout=5):
        self._stop.set()
        if self._thread:
            self._thread.join(timeout=timeout)

    def status(self):
        return {
            "enabled": self.config.schedule.enabled,
            "mode": self.config.schedule.mode,
            "next_fire": self._next_fire.isoformat() if self._next_fire else None,
            "last_fire": self._last_fire.isoformat() if self._last_fire else None,
        }

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
