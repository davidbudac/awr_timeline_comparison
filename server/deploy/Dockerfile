# Dockerfile -- turnkey AWR Fleet Server image.
#
# Oracle Linux 8 slim + Oracle Instant Client (basiclite + sqlplus) + bash +
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
# call (bash, timeout/stat/date via coreutils, find via findutils, grep,
# sed). No awk is used by the wrappers.
RUN microdnf install -y oracle-instantclient-release-el8 \
    && microdnf install -y \
        oracle-instantclient-basiclite \
        oracle-instantclient-sqlplus \
        bash python3 findutils grep sed \
    && microdnf clean all \
    && rm -rf /var/cache/dnf /var/cache/yum

# Put sqlplus on PATH and make the client libs resolvable regardless of the
# Instant Client version the repo currently ships (don't hardcode "21").
RUN set -eux; \
    bindir="$(dirname "$(find /usr/lib/oracle -type f -name sqlplus | head -n1)")"; \
    ln -sf "$bindir/sqlplus" /usr/local/bin/sqlplus; \
    ldconfig; \
    sqlplus -V

WORKDIR /app
COPY . /app

RUN chmod +x server/deploy/docker-entrypoint.sh \
    && mkdir -p /app/server/data /app/reports

# server/data (run history, logs, scheduler state) and reports (generated
# HTML) are meant to be bind-mounted so they survive a container restart.
VOLUME ["/app/server/data", "/app/reports"]

EXPOSE 8765

# TNS_ADMIN is where a mounted wallet / tnsnames lives; override at runtime
# (`-e TNS_ADMIN=/app/wallet -v /path/to/wallet:/app/wallet:ro`) when your
# fleet.conf uses wallet or TNS-alias connect strings rather than bare
# user/pw@host:port/service.
ENV TNS_ADMIN=/app/wallet

ENTRYPOINT ["server/deploy/docker-entrypoint.sh"]
