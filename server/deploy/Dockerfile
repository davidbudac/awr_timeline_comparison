# Dockerfile -- turnkey AWR Fleet Server image.
#
# Oracle Linux 8 slim + Oracle Instant Client (basic + sqlplus) + bash +
# python3 + the coreutils/findutils the wrappers shell out to. The Instant
# Client comes straight from Oracle's own yum repo (you accept Oracle's
# Instant Client license by using it); no RPM to supply by hand.
#
# Build from the REPO ROOT (the image needs run_awr_fleet.sh, sql/, vendor/,
# ... alongside server/):
#
#   docker build -f server/deploy/Dockerfile -t awr-fleet-server .
#
# Run (see server/deploy/docker-compose.yml for the easy path):
#
#   docker run -d --name awr-fleet-server \
#     -p 127.0.0.1:8765:8765 \
#     -v "$PWD/fleet.conf":/app/fleet.conf:ro \
#     -v "$PWD/reports":/app/reports \
#     -v "$PWD/server/data":/app/server/data \
#     awr-fleet-server
#
# The server has NO built-in auth -- keep the published port on 127.0.0.1
# (as above) or put a reverse proxy with auth in front. The entrypoint binds
# 0.0.0.0 INSIDE the container on purpose; the host publish is the boundary.

FROM oraclelinux:8-slim

# Instant Client (sqlplus + client libs) + the POSIX toolbox the wrappers
# call (bash, timeout/stat/date/du via coreutils, find via findutils, grep,
# sed, awk; tar + gzip for the optional FLEET_ARCHIVE). Python 3.9 from
# AppStream: the distribution's default python3 is 3.6, and the server
# needs dataclasses / fromisoformat / ThreadingHTTPServer (3.7+; the
# project documents 3.9+).
RUN microdnf install -y oracle-instantclient-release-el8 \
    && microdnf install -y \
        oracle-instantclient-basic \
        oracle-instantclient-sqlplus \
        bash python39 findutils grep sed gawk tar gzip \
    && microdnf clean all \
    && rm -rf /var/cache/dnf /var/cache/yum

# Put sqlplus on PATH and make the client libs resolvable regardless of the
# Instant Client version the repo currently ships (don't hardcode "21").
# Make `python3` resolve to the 3.9 interpreter and fail the build if it is
# older than the server needs.
RUN set -eux; \
    bindir="$(dirname "$(find /usr/lib/oracle -type f -name sqlplus | head -n1)")"; \
    ln -sf "$bindir/sqlplus" /usr/local/bin/sqlplus; \
    ldconfig; \
    sqlplus -V; \
    command -v python3 >/dev/null 2>&1 || ln -sf "$(command -v python3.9)" /usr/local/bin/python3; \
    python3 -c "import sys, dataclasses; assert sys.version_info >= (3, 9), sys.version; print(sys.version)"

WORKDIR /app
COPY . /app

RUN chmod +x server/deploy/docker-entrypoint.sh \
    && mkdir -p /app/server/data /app/reports

# server/data (run history, logs, scheduler state) and reports (generated
# HTML) are meant to be bind-mounted so they survive a container restart.
VOLUME ["/app/server/data", "/app/reports"]

EXPOSE 8765

# /healthz answers 200 "ok" once the HTTP server is up. Pure stdlib -- the
# image has no curl. (A long-running fleet job does not block it: the web
# server is threaded and the job runs in a worker thread.)
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
    CMD python3 -c "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:8765/healthz', timeout=4).status == 200 else 1)"

# TNS_ADMIN is where a mounted wallet / tnsnames lives; override at runtime
# (`-e TNS_ADMIN=/app/wallet -v /path/to/wallet:/app/wallet:ro`) when your
# fleet.conf uses wallet or TNS-alias connect strings rather than bare
# user/pw@host:port/service.
ENV TNS_ADMIN=/app/wallet

ENTRYPOINT ["server/deploy/docker-entrypoint.sh"]
