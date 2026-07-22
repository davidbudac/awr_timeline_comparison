# AWR Fleet Server

A small hosted wrapper around `run_awr_fleet.sh`: it runs the fleet report
on a schedule and on demand, serves the generated HTML, and keeps a run
history with live log tails. Pure Python 3.9+ stdlib -- nothing to `pip
install`, no build step. It is **orchestration only**: it never edits or
reimplements any of the SQL/bash generator code at the repo root (see
CLAUDE.md's "Fleet report" section for the cardinal rule this tree
respects).

## Quick start

```bash
cp server/server.conf.example server/server.conf
# edit server/server.conf: point [fleet] conf_path at your real fleet.conf,
# set the window/cadence params, optionally enable [schedule].
python3 server/awrserve.py -c server/server.conf
```

Then open `http://127.0.0.1:8765/` (or whatever `[server] port` you set).

## What it does

- **On demand**: the "Run fleet now" button (or `POST /api/fleet/run`)
  enqueues a fleet run; a "Regenerate detail" button per database enqueues
  a single-DB detailed report for that alias.
- **On a schedule**: `[schedule]` in `server.conf` can fire a fleet run
  daily at fixed times, or every N hours.
- **History**: every run (fleet or per-DB detail) gets a record with
  state, timing, per-database rows parsed from the wrapper's own summary
  output, and a captured log. `/runs` lists them; `/runs/<id>` shows one,
  with a live tail while it's running.
- **Serving reports**: `/reports/<file>` serves anything already inside
  `reports/` under a strict filename allowlist -- it never generates or
  modifies report content itself.

## How it runs the wrapper

Exactly one job runs at a time (a single worker thread pulling off a
queue), so it never launches two `sqlplus` fleets concurrently against your
databases. A second manual request while one is already queued/running is
rejected (409); a scheduled tick that lands on a busy queue is recorded as
a visible "skipped" run instead of erroring.

Every run's combined stdout+stderr is captured to
`server/data/runs/<run_id>.log`; the server parses the wrapper's own
per-database summary lines and `Report:` line out of that (never re-derives
scores or facts itself -- exactly what the wrapper printed is what gets
shown). If the server process dies mid-run, the next startup flips any
record stuck in `running` to `failed` ("server restarted mid-run") so
nothing looks perpetually in-flight.

A per-DB detail regen copies that DB's `fleet.conf` line into a throwaway
single-line, 0600 temp conf (appending `|detail` if not already flagged),
runs the same wrapper against just it, then deletes the incidental 1-row
fleet HTML byproduct and the temp conf -- only the canonical
`awr_fleet_detail_<alias>_run<id>.html` is kept.

## Data & security

- `server/data/` (gitignored, created 0700) holds run records/logs, a
  `server.lock` single-instance guard, and scheduler state. Nothing here is
  a database credential -- connect strings are never stored, logged, or
  displayed by the server itself (only aliases; the wrapper's own
  `mask_conn` masking is defense-in-depth on top of that).
- **No authentication.** Default bind is `127.0.0.1`. If you need remote
  access, put a reverse proxy with auth (or an SSH tunnel) in front --
  do not bind a non-loopback address without one. See the warning at the
  top of `server.conf.example`.
- Report files are served only if the filename fullmatches
  `[A-Za-z0-9._-]+\.html` **and** the resolved path still lives under
  `reports/` -- both checks run on every request, independent of each
  other.

## Retention

`[retention]` in `server.conf` prunes only artifacts the server itself
generated and recorded -- it never glob-deletes `reports/awr_*`, so ad-hoc
CLI-run reports are untouched. See the comments in
`server.conf.example` for the three knobs.

## Deploying

See `server/deploy/`:

- `awr-fleet-server.service` -- a systemd unit (Linux).
- `Dockerfile.example` -- an Oracle Linux 8 slim image with Instant Client
  + bash + python3.
- `run-nohup.sh` -- a POSIX/AIX-friendly nohup wrapper for hosts without
  systemd.

## Tests

```bash
python3 -m unittest discover server/tests
```

Stdlib `unittest` only, no network required -- `tests/fake_bin/run_awr_fleet.sh`
stands in for the real wrapper so the run lifecycle, summary parsing, and
route matrix are all exercised without touching a database.
