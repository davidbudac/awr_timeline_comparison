#!/usr/bin/env bash
# docker-entrypoint.sh -- container bootstrap for the AWR Fleet Server.
#
# Two things the plain `python3 server/awrserve.py` invocation can't do on
# its own inside a container, handled here so `docker run` / `docker compose
# up` just works:
#
#   1. Config bootstrap. server.conf is gitignored and normally hand-copied
#      from server.conf.example. If no config is mounted/baked at
#      $AWRSERVE_CONFIG, we seed one from the example so the container starts
#      on-demand-only with zero setup (it still needs a fleet.conf mounted at
#      /app/fleet.conf to actually run anything).
#
#   2. Bind host. server.conf defaults bind_host=127.0.0.1. Inside a
#      container that binds the *container's* loopback, so the published port
#      is unreachable from the host even with `-p`. We render an effective
#      config that forces bind_host=0.0.0.0 (never mutating the user's file,
#      which may be a read-only mount). The loopback security boundary is
#      preserved by publishing the port to the HOST's 127.0.0.1 -- e.g.
#      `-p 127.0.0.1:8765:8765`, or a reverse proxy with auth. See
#      server/server.conf.example's SECURITY WARNING.
set -eu

CONFIG_SRC="${AWRSERVE_CONFIG:-/app/server/server.conf}"
CONFIG_EXAMPLE="/app/server/server.conf.example"
EFFECTIVE_CONFIG="/tmp/awrserve.effective.conf"

if [ ! -f "$CONFIG_SRC" ]; then
    echo "entrypoint: no config at $CONFIG_SRC -- seeding from $CONFIG_EXAMPLE" >&2
    cp "$CONFIG_EXAMPLE" "$CONFIG_SRC" 2>/dev/null || CONFIG_SRC="$CONFIG_EXAMPLE"
fi

# Render the effective config: same file, but bind_host forced to 0.0.0.0 so
# the port is reachable through the container boundary. Emitted to /tmp
# (always writable) so a read-only-mounted source config is left untouched.
python3 - "$CONFIG_SRC" "$EFFECTIVE_CONFIG" <<'PY'
import configparser, sys
src, dst = sys.argv[1], sys.argv[2]
cp = configparser.ConfigParser()
cp.read(src)
if not cp.has_section("server"):
    cp.add_section("server")
orig = cp.get("server", "bind_host", fallback="127.0.0.1")
if orig != "0.0.0.0":
    sys.stderr.write(
        "entrypoint: overriding bind_host %r -> '0.0.0.0' for the container; "
        "keep the security boundary on the host publish (e.g. "
        "-p 127.0.0.1:8765:8765) or a fronting proxy\n" % orig
    )
cp.set("server", "bind_host", "0.0.0.0")
with open(dst, "w") as fh:
    cp.write(fh)
PY

# When no args are given, run the server against the effective config.
# Anything else (e.g. `python3 -m unittest ...`, a shell) runs verbatim.
if [ "$#" -eq 0 ]; then
    exec python3 server/awrserve.py -c "$EFFECTIVE_CONFIG"
fi
exec "$@"
