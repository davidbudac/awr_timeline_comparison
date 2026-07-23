# Running the AWR Fleet Server in Docker

The image bundles the whole toolkit — Oracle Instant Client (`sqlplus`),
bash, python3, and the repo's generator scripts — and runs
`server/awrserve.py`, which drives `run_awr_fleet.sh` exactly as a human
would from the CLI. Nothing in the container edits the SQL/bash generators;
it only orchestrates them.

Files in this directory:

| File | Purpose |
|------|---------|
| `Dockerfile` | The image: Oracle Linux 8 slim + Instant Client + bash + python3. |
| `docker-entrypoint.sh` | Container bootstrap (config seeding + bind-host fix). |
| `docker-compose.yml` | One-command run with the right mounts and port binding. |
| `awr-fleet-server.service` | systemd unit, for a non-Docker Linux host. |
| `run-nohup.sh` | POSIX/AIX nohup wrapper, for hosts without systemd. |

---

## Prerequisites

- Docker (with Compose v2 — `docker compose`, not the legacy
  `docker-compose`).
- A real **`fleet.conf`** at the repo root. Copy the template and fill in
  your database aliases + connect strings:

  ```bash
  cp fleet.conf.example fleet.conf
  # edit fleet.conf
  ```

  This is the one file you *must* provide; the server is useless without it.

- If your connect strings use an Oracle **wallet** or **TNS aliases**, have
  that directory ready to mount. Bare `user/pw@host:port/service` strings
  need nothing extra.

> **Build from the repo root.** The image needs `run_awr_fleet.sh`, `sql/`,
> `vendor/`, … alongside `server/`, so the build context is the whole repo.
> All commands below are run from the repo root.

---

## Quick start (Compose — recommended)

```bash
# build + start in the background
docker compose -f server/deploy/docker-compose.yml up -d --build

# follow the log
docker compose -f server/deploy/docker-compose.yml logs -f

# stop (data + reports persist on the host)
docker compose -f server/deploy/docker-compose.yml down
```

Then open **http://127.0.0.1:8765/** and click **Run fleet now**.

That's the whole happy path. No `server.conf` needed to start — the
entrypoint seeds one from `server.conf.example` (on-demand-only defaults)
the first time. Add a tuned config later (see [Configuration](#configuration)).

### Change the host port

```bash
AWRSERVE_PORT=9000 docker compose -f server/deploy/docker-compose.yml up -d
# now on http://127.0.0.1:9000/  (still container port 8765 internally)
```

---

## Quick start (plain `docker run`)

```bash
docker build -f server/deploy/Dockerfile -t awr-fleet-server .

docker run -d --name awr-fleet-server \
  -p 127.0.0.1:8765:8765 \
  -v "$PWD/fleet.conf":/app/fleet.conf:ro \
  -v "$PWD/reports":/app/reports \
  -v "$PWD/server/data":/app/server/data \
  awr-fleet-server
```

---

## What gets mounted

| Host path | Container path | Mode | Why |
|-----------|----------------|------|-----|
| `fleet.conf` | `/app/fleet.conf` | ro | Your fleet's aliases + connect strings. **Required.** |
| `reports/` | `/app/reports` | rw | Generated HTML reports — persisted across restarts. |
| `server/data/` | `/app/server/data` | rw | Run history, logs, scheduler state, single-instance lock. |
| `server/server.conf` *(optional)* | `/app/server/server.conf` | ro | A hand-tuned config (schedule, retention, window params). |
| a wallet dir *(optional)* | `/app/wallet` | ro | Oracle wallet / `tnsnames.ora`; pair with `TNS_ADMIN`. |

The two optional mounts are commented out in `docker-compose.yml` — uncomment
and adjust the host paths to use them.

---

## Configuration

### Zero-config default

With no `server.conf` mounted, the container runs **on-demand only** (no
schedule) with the defaults from `server.conf.example`: window `AUTO`, 1h
windows, 4 weeks back, weekly cadence. You trigger runs from the web UI or
`POST /api/fleet/run`.

### Tuned config

For a schedule, retention policy, custom window/cadence, or `[env]` knobs,
provide your own config:

```bash
cp server/server.conf.example server/server.conf
# edit server/server.conf
```

Then uncomment the `server.conf` line in `docker-compose.yml`:

```yaml
      - ../server.conf:/app/server/server.conf:ro
```

See `server/server.conf.example` for every knob (schedule modes, retention,
the whitelisted `[env]` passthrough like `FLEET_PAR`, `FLEET_DETAIL`,
`MARKERS`, …).

> **`bind_host` is handled for you.** `server.conf` defaults to
> `127.0.0.1`, which inside a container binds the *container's* loopback and
> makes the port unreachable. The entrypoint always renders an effective
> config with `bind_host = 0.0.0.0` — it never edits your mounted file. Your
> loopback safety comes from the **host publish** (see Security below), not
> from `bind_host`.

### Wallet / TNS connect strings

Uncomment both in `docker-compose.yml` and set the wallet host path:

```yaml
      - /path/to/wallet:/app/wallet:ro
# and under environment:
      TNS_ADMIN: /app/wallet
```

`TNS_ADMIN` already defaults to `/app/wallet` in the image, so mounting the
wallet there is enough for most setups.

---

## Security

The server has **no built-in authentication**. Reports and run-history pages
can expose SQL text, hostnames, and (masked) usernames from every database
in your fleet.

- The published port is bound to the **host's `127.0.0.1`** only
  (`docker-compose.yml` and the `docker run` example both do this). That is
  the security boundary — *not* the in-container `bind_host`.
- To reach it from another machine, use an **SSH tunnel** or put a **reverse
  proxy with auth** (nginx basic-auth, an SSO proxy, …) in front. Do not
  publish it on `0.0.0.0` on an untrusted network.
- Database **passwords are never baked into the image or written to
  `server/data/`** — `fleet.conf` is a read-only runtime mount, and
  `.dockerignore` keeps it (and `server.conf`, `server/data/`) out of the
  build context.

---

## Operations

```bash
# status / logs
docker compose -f server/deploy/docker-compose.yml ps
docker compose -f server/deploy/docker-compose.yml logs -f

# restart (picks up an edited server.conf)
docker compose -f server/deploy/docker-compose.yml restart

# rebuild after pulling new repo code
docker compose -f server/deploy/docker-compose.yml up -d --build

# open a shell in the running container
docker compose -f server/deploy/docker-compose.yml exec awr-fleet-server bash

# run the test suite inside the image
docker compose -f server/deploy/docker-compose.yml run --rm --no-deps \
  awr-fleet-server python3 -m unittest discover server/tests
```

The server runs **one job at a time** (single worker), so a container
restart mid-run is safe: on startup any run left `running` is flipped to
`failed` ("server restarted mid-run"). Reports and history live on the host
mounts, so they survive `down`/`up`.

---

## Troubleshooting

**`ORA-12154` / `TNS:could not resolve` or `ORA-12514`.** The container
can't resolve your connect string. For TNS aliases/wallets, confirm the
wallet is mounted and `TNS_ADMIN` points at it. For `host:port/service`
strings, confirm the container can reach the DB host (Docker's default
bridge network; use `--network host` or a proper network if the DB is only
reachable on the host's network).

**The page won't load / connection refused.** Check the port mapping
(`docker compose ps`) and that you're hitting the host port you published
(`AWRSERVE_PORT`, default 8765). The in-container bind is always `0.0.0.0`,
so a refused connection is a publish/port issue, not a bind issue.

**`error: config not found`.** Only happens if you set `AWRSERVE_CONFIG` to a
path that isn't mounted. Leave it unset to use the auto-seeded default, or
mount your `server.conf` at `/app/server/server.conf`.

**No databases / empty fleet.** Confirm `fleet.conf` is mounted read-only at
`/app/fleet.conf` and is non-empty; the entrypoint won't invent one.

**Build fails fetching Instant Client.** The build pulls Instant Client from
Oracle's public yum repo, which requires outbound network during `docker
build`. Behind a proxy, pass it through with `--build-arg` /
`HTTP_PROXY`/`HTTPS_PROXY` build args as your environment requires.

---

## Image notes

- Base: `oraclelinux:8-slim`. Instant Client (`basiclite` + `sqlplus`) is
  installed from Oracle's own yum repo — by building, you accept Oracle's
  Instant Client license.
- `sqlplus` is located by glob (not a hardcoded version) and symlinked onto
  `PATH`; `sqlplus -V` runs at build time as a smoke test, so a broken client
  fails the build rather than the first fleet run.
- The wrappers use bash + `timeout`/`stat`/`date` (coreutils), `find`
  (findutils), `grep`, `sed` — all installed. No `awk` is used.
