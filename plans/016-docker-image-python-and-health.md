# Plan 016: The Docker image is guaranteed to carry a Python the server can run, and reports its health

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**:
> `git diff --stat e755b97..HEAD -- server/deploy/Dockerfile server/deploy/docker-compose.yml server/deploy/README.md server/README.md`
> If any of these changed since this plan was written, compare the
> "Current state" excerpts against the live files before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P3
- **Effort**: S
- **Risk**: MED (the finding is from reading, not from a build; step 1 confirms or refutes it before anything is changed)
- **Depends on**: none
- **Category**: migration
- **Planned at**: commit `e755b97`, 2026-11-13

## Why this matters

`server/deploy/Dockerfile` builds the "turnkey" fleet-server image from
`oraclelinux:8-slim` and installs the distribution's `python3` package. On
Oracle Linux 8 that package is the platform Python, **3.6**. The server
needs 3.7 at the very least — it imports `dataclasses`, uses
`datetime.fromisoformat` and `http.server.ThreadingHTTPServer` — and its
README promises "Python 3.9+". If the audit's reading is right, the
container exits on its first import and the documented one-command
`docker compose up` path has never worked from a clean build. This could
not be confirmed during the audit (no image build was run), so the first
step of this plan is to find out. Two smaller gaps are fixed on the way: the
image has no `HEALTHCHECK` although the server exposes `/healthz`, and the
Dockerfile's claim that the wrappers use no `awk` is no longer true.

## Current state

`server/deploy/Dockerfile` (65 lines). The relevant parts (`:26-37`, `:47-65`):

```dockerfile
FROM oraclelinux:8-slim

# Instant Client (sqlplus + client libs) + the POSIX toolbox the wrappers
# call (bash, timeout/stat/date via coreutils, find via findutils, grep,
# sed). No awk is used by the wrappers.
RUN microdnf install -y oracle-instantclient-release-el8 \
    && microdnf install -y \
        oracle-instantclient-basiclite \
        oracle-instantclient-sqlplus \
        bash python3 findutils grep sed \
    && microdnf clean all \
    && rm -rf /var/cache/dnf /var/cache/yum
...
WORKDIR /app
COPY . /app

RUN chmod +x server/deploy/docker-entrypoint.sh \
    && mkdir -p /app/server/data /app/reports

VOLUME ["/app/server/data", "/app/reports"]

EXPOSE 8765

ENV TNS_ADMIN=/app/wallet

ENTRYPOINT ["server/deploy/docker-entrypoint.sh"]
```

A second `RUN` (`:41-45`) symlinks `sqlplus` into `/usr/local/bin` and runs
`sqlplus -V` as a build-time proof — the pattern to copy for Python.

Facts about the code the image must run:

- `server/app/config.py:12` — `from dataclasses import dataclass, field`
  (module added in Python 3.7).
- `server/app/scheduler.py:104` — `datetime.datetime.fromisoformat(raw)` (3.7).
- `server/app/webapp.py:280` — `http.server.ThreadingHTTPServer` (3.7).
- `server/awrserve.py` docstring: "Pure stdlib, Python 3.9-compatible";
  `server/README.md:5`: "Pure Python 3.9+ stdlib".
- `server/deploy/docker-entrypoint.sh` invokes `python3` twice (a config
  rewrite, then `exec python3 server/awrserve.py -c …`). With no arguments
  it starts the server; with arguments it `exec`s them (so
  `docker run … awr-fleet-server python3 -m unittest …` works).
- The server answers `GET /healthz` with `200` and body `ok` on the
  configured port (8765 in the image; the entrypoint forces `bind_host` to
  `0.0.0.0`).
- `run_awr_fleet.sh:539` uses `awk` (to print an archive's size) and the
  optional `FLEET_ARCHIVE` feature shells out to `zip`, or `tar` + `gzip`.
- Build command (from the repo root):
  `docker build -f server/deploy/Dockerfile -t awr-fleet-server .`
- `server/deploy/README.md` documents running the tests in the image:
  `docker compose -f server/deploy/docker-compose.yml run --rm --no-deps awr-fleet-server python3 -m unittest discover server/tests`.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Is Docker usable? | `docker info >/dev/null 2>&1 && echo yes` | `yes` |
| Base image's Python | `docker run --rm oraclelinux:8-slim sh -c 'microdnf install -y python3 >/dev/null 2>&1; python3 -V'` | prints a version |
| Build | `docker build -f server/deploy/Dockerfile -t awr-fleet-server:plan016 .` | exit 0 |
| Python in the image | `docker run --rm --entrypoint python3 awr-fleet-server:plan016 -V` | `Python 3.9.x` or newer |
| Tests in the image | `docker run --rm --entrypoint python3 awr-fleet-server:plan016 -m unittest discover -s server/tests -t .` | `OK` |
| Lint (sanity) | `./lint.sh` | exit 0 |

The build downloads the base image and Oracle Instant Client packages
(several hundred MB) and needs network access. Ask the operator before the
first pull if you were not told that is acceptable.

## Scope

**In scope** (the only files you should modify):
- `server/deploy/Dockerfile`
- `server/deploy/README.md` (a short note on the health check and the Python version)

**Out of scope** (do NOT touch):
- `.dockerignore`, `docker-compose.yml` (compose inherits the image's
  `HEALTHCHECK`), `docker-entrypoint.sh`, `run-nohup.sh`, the systemd unit.
- Anything outside `server/deploy/`.

## Git workflow

- Branch: `advisor/016-docker-image-python-and-health` from `main`.
- Commit style: conventional commits with scope. Suggested:
  `fix(docker): install Python 3.9 and assert it at build time; add HEALTHCHECK`.
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Establish the facts (no file changes)

1. `docker info >/dev/null 2>&1 && echo yes` — if this does not print
   `yes`, go to "If Docker is not available" at the end of the steps.
2. Find out which Python the current recipe yields:
   `docker run --rm oraclelinux:8-slim sh -c 'microdnf install -y python3 >/dev/null 2>&1; python3 -V; python3 -c "import dataclasses" && echo dataclasses-ok'`

**Verify**: record the output in your report.
- If it prints `Python 3.6.x` and an `ImportError`/`ModuleNotFoundError`
  for `dataclasses`: the finding is confirmed — continue with step 2.
- If it prints Python 3.9 or newer and `dataclasses-ok`: the finding is
  **refuted** for the Python version. Skip step 2's package change but keep
  its build-time assertion, and continue.

### Step 2: Install Python 3.9 explicitly and assert it at build time

In `server/deploy/Dockerfile`:

1. In the `microdnf install` list, replace `python3` with `python39` and
   add `gawk tar gzip`:

```dockerfile
        bash python39 findutils grep sed gawk tar gzip \
```

2. Replace the comment above that `RUN` with:

```dockerfile
# Instant Client (sqlplus + client libs) + the POSIX toolbox the wrappers
# call (bash, timeout/stat/date/du via coreutils, find via findutils, grep,
# sed, awk; tar + gzip for the optional FLEET_ARCHIVE). Python 3.9 from
# AppStream: the distribution's default python3 is 3.6, and the server
# needs dataclasses / fromisoformat / ThreadingHTTPServer (3.7+; the
# project documents 3.9+).
```

3. Extend the second `RUN` (the one that symlinks `sqlplus`) so the build
   itself proves the interpreter, exactly like it already proves `sqlplus`:

```dockerfile
RUN set -eux; \
    bindir="$(dirname "$(find /usr/lib/oracle -type f -name sqlplus | head -n1)")"; \
    ln -sf "$bindir/sqlplus" /usr/local/bin/sqlplus; \
    ldconfig; \
    sqlplus -V; \
    command -v python3 >/dev/null 2>&1 || ln -sf "$(command -v python3.9)" /usr/local/bin/python3; \
    python3 -c "import sys, dataclasses; assert sys.version_info >= (3, 9), sys.version; print(sys.version)"
```

   and extend the comment above it with: "Make `python3` resolve to the
   3.9 interpreter and fail the build if it is older than the server needs."

**Verify**:
- `docker build -f server/deploy/Dockerfile -t awr-fleet-server:plan016 .` → exit 0, and the build log shows a `3.9.` (or newer) version line from the assertion.
- `docker run --rm --entrypoint python3 awr-fleet-server:plan016 -V` → `Python 3.9.x` or newer.
- `docker run --rm --entrypoint sh awr-fleet-server:plan016 -c 'command -v awk tar gzip timeout sqlplus bash'` → six paths, exit 0.

If `microdnf install python39` fails with "no package matches" → STOP (see
STOP conditions); do not switch base images on your own.

### Step 3: Run the server's test suite inside the image

**Verify**:
`docker run --rm --entrypoint python3 awr-fleet-server:plan016 -m unittest discover -s server/tests -t .`
→ `OK` (137 tests at the planned-at commit; more if other plans landed).

### Step 4: Add a HEALTHCHECK

In `server/deploy/Dockerfile`, after the `EXPOSE 8765` line add:

```dockerfile
# /healthz answers 200 "ok" once the HTTP server is up. Pure stdlib -- the
# image has no curl. (A long-running fleet job does not block it: the web
# server is threaded and the job runs in a worker thread.)
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
    CMD python3 -c "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:8765/healthz', timeout=4).status == 200 else 1)"
```

**Verify** (needs no database: the server starts without one and only
contacts databases when a run is triggered):

```bash
docker build -f server/deploy/Dockerfile -t awr-fleet-server:plan016 .
d="$(mktemp -d)"; printf 'placeholder|/@nowhere\n' > "$d/fleet.conf"
docker run -d --name awr-plan016 -v "$d/fleet.conf":/app/fleet.conf:ro awr-fleet-server:plan016
sleep 45
docker inspect --format '{{.State.Health.Status}}' awr-plan016      # expect: healthy
docker logs awr-plan016 2>&1 | tail -5                              # expect a "listening on" line, no traceback
docker rm -f awr-plan016; rm -rf "$d"
```

`placeholder|/@nowhere` is a syntactically valid, credential-free
`fleet.conf` line (wallet-style connect); never mount the repository's real
`fleet.conf` for this check.

### Step 5: Document

In `server/deploy/README.md`:

1. In the files table, change the Dockerfile row's description to
   "The image: Oracle Linux 8 slim + Instant Client + bash + Python 3.9."
2. Add a short paragraph near the operations commands: the image defines a
   `HEALTHCHECK` on `/healthz`; `docker ps` shows `healthy` once the server
   is up; the build fails if the interpreter is older than 3.9.

**Verify**: `grep -c -i "healthcheck\|healthy" server/deploy/README.md` → 1 or more.

### Step 6: Clean up and final checks

`docker rmi awr-fleet-server:plan016` (optional), then:

**Verify**: `./lint.sh` → exit 0; `git status --short` → only
`server/deploy/Dockerfile` and `server/deploy/README.md`.

### If Docker is not available

Apply steps 2, 4 and 5 as text edits only, run step 6, and set this plan's
status row in `plans/README.md` to
`BLOCKED (edits applied, image build not verified — needs a machine with Docker)`.
Do not mark it DONE.

## Test plan

- The build-time assertion (step 2) is the regression test for the Python
  version: any future base-image change that brings an older interpreter
  fails `docker build`.
- Step 3 runs the existing unit tests inside the image.
- Step 4 proves the health check against a running container.

## Done criteria

- [ ] `docker build -f server/deploy/Dockerfile …` exits 0
- [ ] `python3 -V` in the image reports 3.9 or newer
- [ ] The unit tests pass inside the image
- [ ] `docker inspect` reports `healthy` for a started container
- [ ] `grep -c "HEALTHCHECK" server/deploy/Dockerfile` → `1`; `grep -c "No awk is used" server/deploy/Dockerfile` → `0`
- [ ] `git status --short` shows only the two in-scope files
- [ ] `plans/README.md` status row updated (DONE, or BLOCKED as described above)

## STOP conditions

- `microdnf install python39` is not available in the base image's
  repositories, or `python3.9` is not on `PATH` after installing it — report
  the exact `microdnf` output. Possible directions (owner's decision, not
  yours): a different AppStream Python package name, or moving the base to
  `oraclelinux:9-slim` (whose default `python3` is 3.9) together with the
  matching `oracle-instantclient-release-el9` package.
- The build fails in the pre-existing Instant Client step (network, repo
  outage, licence prompt) — unrelated to this plan; report.
- The container exits immediately in step 4 with a traceback — capture
  `docker logs` and report; do not edit `docker-entrypoint.sh`.
- You are asked to mount or copy the real `fleet.conf` / `server.conf`.

## Maintenance notes

- Step 1's output answers an open audit question; put it in the PR
  description ("the image did / did not start before this change").
- Reviewer: confirm the health check uses only the standard library and the
  loopback address inside the container.
