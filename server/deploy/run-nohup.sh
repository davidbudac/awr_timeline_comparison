#!/bin/sh
# run-nohup.sh -- start/stop AWR Fleet Server with plain nohup, for hosts
# without systemd (AIX, minimal containers). POSIX /bin/sh only -- no GNU
# coreutils assumptions (this repo's AIX portability lesson: avoid
# `date -d`, `grep -o`, `sed -E`; none used here).
#
# Usage:
#   server/deploy/run-nohup.sh start
#   server/deploy/run-nohup.sh stop
#   server/deploy/run-nohup.sh status

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)
CONF="${AWRSERVE_CONF:-$REPO_ROOT/server/server.conf}"
PIDFILE="$REPO_ROOT/server/data/awrserve.pid"
LOGFILE="$REPO_ROOT/server/data/awrserve.nohup.log"
PY="${PYTHON_BIN:-python3}"

mkdir -p "$REPO_ROOT/server/data"

is_running() {
    [ -f "$PIDFILE" ] || return 1
    pid=$(cat "$PIDFILE" 2>/dev/null || echo '')
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

case "${1:-}" in
    start)
        if is_running; then
            echo "already running (pid $(cat "$PIDFILE"))"
            exit 0
        fi
        [ -f "$CONF" ] || { echo "error: config not found: $CONF" >&2; exit 2; }
        cd "$REPO_ROOT"
        nohup "$PY" server/awrserve.py -c "$CONF" >>"$LOGFILE" 2>&1 &
        echo $! > "$PIDFILE"
        echo "started (pid $(cat "$PIDFILE")), logging to $LOGFILE"
        ;;
    stop)
        if is_running; then
            pid=$(cat "$PIDFILE")
            kill "$pid"
            echo "sent TERM to pid $pid"
        else
            echo "not running"
        fi
        rm -f "$PIDFILE"
        ;;
    status)
        if is_running; then
            echo "running (pid $(cat "$PIDFILE"))"
        else
            echo "not running"
        fi
        ;;
    *)
        echo "usage: $0 {start|stop|status}" >&2
        exit 2
        ;;
esac
