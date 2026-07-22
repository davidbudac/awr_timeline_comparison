"""server.conf (INI) loading + validation.

configparser, not tomllib (3.9 floor, tomllib is 3.11+). Validated with the
same grammars run_awr_fleet.sh itself enforces (see run_awr_fleet.sh:209-225
v_posint/v_posdec/v_step_unit/v_target_end) so a bad value is rejected here,
before it ever reaches argv.
"""

import configparser
import datetime
import re
from dataclasses import dataclass, field
from pathlib import Path
from typing import Dict, List

from . import paths

# ---------------------------------------------------------------------------
# Validators -- ports of run_awr_fleet.sh:209-225
# ---------------------------------------------------------------------------

_POSINT_RE = re.compile(r"^[1-9][0-9]*$")
_POSDEC_RE = re.compile(r"^([0-9]+|[0-9]*\.[0-9]+|[0-9]+\.[0-9]*)$")
_HHMM_RE = re.compile(r"^([01][0-9]|2[0-3]):[0-5][0-9]$")
_TARGET_END_DT_RE = re.compile(r"^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}$")


class ConfigError(Exception):
    pass


def v_posint(value):
    return bool(_POSINT_RE.match(value))


def v_posdec(value):
    if not _POSDEC_RE.match(value):
        return False
    return any(c in "123456789" for c in value)


def v_step_unit(value):
    return value in ("h", "d", "w")


def v_target_end(value):
    if value.upper() == "AUTO":
        return True
    if not _TARGET_END_DT_RE.match(value):
        return False
    try:
        datetime.datetime.strptime(value, "%Y-%m-%d %H:%M")
    except ValueError:
        return False
    return True


def v_hhmm(value):
    return bool(_HHMM_RE.match(value))


# Env vars the [env] section may whitelist through to the subprocess --
# anything else in that section is a config error. Mirrors run_awr_fleet.sh's
# documented FLEET_*/MARKERS*/MARKER_FILE knobs (usage() at :172-189).
ENV_WHITELIST_KEYS = frozenset(
    [
        "FLEET_PAR",
        "FLEET_TIMEOUT",
        "FLEET_TEMPLATE",
        "FLEET_KEEP_WORK",
        "MARKERS",
        "MARKER_FILE",
        "FLEET_DETAIL",
        "FLEET_DETAIL_TIMEOUT",
        "FLEET_DETAIL_TEMPLATE",
        "FLEET_DETAIL_ECHARTS",
    ]
)


@dataclass
class FleetParams:
    conf_path: str
    target_end: str = "AUTO"
    win_hours: str = "1"
    weeks_back: str = "4"
    top_n: str = "10"
    step: str = "1"
    step_unit: str = "w"
    max_run_minutes: int = 60

    def argv_tail(self):
        """[target_end, win_hours, weeks_back, top_n, step, step_unit] --
        the positional tail run_awr_fleet.sh expects after fleet.conf."""
        return [
            self.target_end,
            self.win_hours,
            self.weeks_back,
            self.top_n,
            self.step,
            self.step_unit,
        ]


@dataclass
class ScheduleConfig:
    enabled: bool = False
    mode: str = "daily"  # 'daily' | 'every'
    daily_at: List[str] = field(default_factory=list)
    every_hours: float = 24.0
    catchup: bool = True


@dataclass
class RetentionConfig:
    keep_fleet_runs: int = 14
    keep_days: int = 30
    keep_run_records: int = 200


@dataclass
class Config:
    bind_host: str = "127.0.0.1"
    port: int = 8765
    fleet: FleetParams = None
    env: Dict[str, str] = field(default_factory=dict)
    schedule: ScheduleConfig = field(default_factory=ScheduleConfig)
    retention: RetentionConfig = field(default_factory=RetentionConfig)


def _get(cp, section, key, default=None, required=False):
    if cp.has_option(section, key):
        return cp.get(section, key).strip()
    if required:
        raise ConfigError("[%s] %s is required" % (section, key))
    return default


def _getbool(cp, section, key, default):
    if not cp.has_option(section, key):
        return default
    try:
        return cp.getboolean(section, key)
    except ValueError:
        raise ConfigError("[%s] %s must be a boolean (true/false/1/0/yes/no)" % (section, key))


def _getint(cp, section, key, default):
    raw = _get(cp, section, key)
    if raw is None:
        return default
    try:
        return int(raw)
    except ValueError:
        raise ConfigError("[%s] %s must be an integer, got %r" % (section, key, raw))


def _getfloat(cp, section, key, default):
    raw = _get(cp, section, key)
    if raw is None:
        return default
    try:
        return float(raw)
    except ValueError:
        raise ConfigError("[%s] %s must be a number, got %r" % (section, key, raw))


def load_config(path):
    """Load and validate server.conf. Raises ConfigError on anything bad."""
    cp = configparser.ConfigParser()
    read_ok = cp.read(path, encoding="utf-8")
    if not read_ok:
        raise ConfigError("could not read config file: %s" % (path,))

    cfg = Config()

    # [server]
    cfg.bind_host = _get(cp, "server", "bind_host", default="127.0.0.1")
    cfg.port = _getint(cp, "server", "port", 8765)
    if not (1 <= cfg.port <= 65535):
        raise ConfigError("[server] port must be 1-65535, got %d" % (cfg.port,))

    # [fleet]
    conf_path = _get(cp, "fleet", "conf_path", required=True)
    conf_path_abs = conf_path
    if not Path(conf_path_abs).is_absolute():
        conf_path_abs = str((paths.REPO_ROOT / conf_path_abs).resolve())

    fleet = FleetParams(
        conf_path=conf_path_abs,
        target_end=_get(cp, "fleet", "target_end", "AUTO"),
        win_hours=_get(cp, "fleet", "win_hours", "1"),
        weeks_back=_get(cp, "fleet", "weeks_back", "4"),
        top_n=_get(cp, "fleet", "top_n", "10"),
        step=_get(cp, "fleet", "step", "1"),
        step_unit=_get(cp, "fleet", "step_unit", "w"),
        max_run_minutes=_getint(cp, "fleet", "max_run_minutes", 60),
    )
    if not v_target_end(fleet.target_end):
        raise ConfigError(
            "[fleet] target_end must be AUTO or 'YYYY-MM-DD HH:MM', got %r" % (fleet.target_end,)
        )
    if not v_posdec(fleet.win_hours):
        raise ConfigError("[fleet] win_hours must be a positive number, got %r" % (fleet.win_hours,))
    if not v_posint(fleet.weeks_back):
        raise ConfigError("[fleet] weeks_back must be a positive whole number, got %r" % (fleet.weeks_back,))
    if not v_posint(fleet.top_n):
        raise ConfigError("[fleet] top_n must be a positive whole number, got %r" % (fleet.top_n,))
    if not v_posdec(fleet.step):
        raise ConfigError("[fleet] step must be a positive number, got %r" % (fleet.step,))
    if not v_step_unit(fleet.step_unit):
        raise ConfigError("[fleet] step_unit must be one of h, d, w, got %r" % (fleet.step_unit,))
    if fleet.max_run_minutes <= 0:
        raise ConfigError("[fleet] max_run_minutes must be a positive integer")
    cfg.fleet = fleet

    # [env]
    env = {}
    if cp.has_section("env"):
        for key, value in cp.items("env"):
            upper_key = key.upper()
            if upper_key not in ENV_WHITELIST_KEYS:
                raise ConfigError(
                    "[env] %s is not a recognized whitelisted var (allowed: %s)"
                    % (key, ", ".join(sorted(ENV_WHITELIST_KEYS)))
                )
            if value != "":
                env[upper_key] = value
    cfg.env = env

    # [schedule]
    sched = ScheduleConfig()
    sched.enabled = _getbool(cp, "schedule", "enabled", False)
    sched.mode = _get(cp, "schedule", "mode", "daily")
    if sched.mode not in ("daily", "every"):
        raise ConfigError("[schedule] mode must be 'daily' or 'every', got %r" % (sched.mode,))
    daily_at_raw = _get(cp, "schedule", "daily_at", "")
    sched.daily_at = [t.strip() for t in daily_at_raw.split(",") if t.strip()]
    for t in sched.daily_at:
        if not v_hhmm(t):
            raise ConfigError("[schedule] daily_at entry %r is not HH:MM (24h)" % (t,))
    sched.every_hours = _getfloat(cp, "schedule", "every_hours", 24.0)
    if sched.every_hours <= 0:
        raise ConfigError("[schedule] every_hours must be positive")
    sched.catchup = _getbool(cp, "schedule", "catchup", True)
    if sched.enabled and sched.mode == "daily" and not sched.daily_at:
        raise ConfigError("[schedule] mode=daily requires at least one daily_at entry")
    cfg.schedule = sched

    # [retention]
    ret = RetentionConfig()
    ret.keep_fleet_runs = _getint(cp, "retention", "keep_fleet_runs", 14)
    ret.keep_days = _getint(cp, "retention", "keep_days", 30)
    ret.keep_run_records = _getint(cp, "retention", "keep_run_records", 200)
    if ret.keep_fleet_runs < 0 or ret.keep_days < 0 or ret.keep_run_records < 0:
        raise ConfigError("[retention] values must be >= 0")
    cfg.retention = ret

    return cfg
