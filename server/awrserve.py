#!/usr/bin/env python3
"""AWR Fleet Server entrypoint.

Pure stdlib, Python 3.9-compatible. Wires up config -> RunManager ->
Scheduler -> HTTP server and blocks in serve_forever(). See
server/README.md for deployment notes and server/server.conf.example for
every knob.

Usage:
    python3 server/awrserve.py -c server/server.conf
"""

import argparse
import fcntl
import os
import signal
import sys
import threading
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from app import config as config_mod  # noqa: E402
from app import paths  # noqa: E402
from app import runner  # noqa: E402
from app import scheduler as scheduler_mod  # noqa: E402
from app import webapp  # noqa: E402


def parse_args(argv=None):
    p = argparse.ArgumentParser(description="AWR Fleet Server")
    p.add_argument("-c", "--config", required=True, help="path to server.conf")
    return p.parse_args(argv)


def acquire_single_instance_lock():
    """fcntl.flock on server/data/server.lock -- refuses to start a second
    instance against the same data dir (two workers would double-run the
    scheduler and race the job queue)."""
    paths.ensure_data_dirs()
    lock_fd = os.open(str(paths.LOCK_FILE), os.O_CREAT | os.O_RDWR, 0o600)
    try:
        fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        os.close(lock_fd)
        print(
            "error: another awrserve instance already holds the lock at %s" % paths.LOCK_FILE,
            file=sys.stderr,
        )
        sys.exit(1)
    return lock_fd  # keep the fd open for the life of the process


def main(argv=None):
    args = parse_args(argv)

    try:
        cfg = config_mod.load_config(args.config)
    except config_mod.ConfigError as exc:
        print("error: %s" % exc, file=sys.stderr)
        return 2

    lock_fd = acquire_single_instance_lock()

    run_manager = runner.RunManager(cfg)
    recovered = run_manager.start()
    if recovered:
        print(
            "recovered %d run(s) stuck in 'running' from a previous crash -> marked 'failed'"
            % len(recovered),
            flush=True,
        )

    sched = scheduler_mod.Scheduler(cfg, run_manager)
    sched.start()

    ctx = webapp.AppContext(cfg, run_manager, scheduler=sched)
    httpd = webapp.create_server(ctx)

    def _shutdown(signum, frame):
        # httpd.shutdown() blocks until serve_forever()'s loop notices and
        # exits -- calling it directly from this signal handler would
        # deadlock, since the handler runs synchronously on the SAME thread
        # that is blocked inside serve_forever(). Do it from a throwaway
        # thread instead.
        print("shutting down...", flush=True)
        threading.Thread(target=httpd.shutdown, daemon=True).start()

    signal.signal(signal.SIGINT, _shutdown)
    signal.signal(signal.SIGTERM, _shutdown)

    print("AWR Fleet Server listening on http://%s:%d" % (cfg.bind_host, cfg.port), flush=True)
    try:
        httpd.serve_forever()
    finally:
        httpd.server_close()
        sched.stop()
        run_manager.stop()
        try:
            os.close(lock_fd)
        except OSError:
            pass

    return 0


if __name__ == "__main__":
    sys.exit(main())
