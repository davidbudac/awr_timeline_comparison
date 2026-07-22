"""Python ports of run_awr_fleet.sh's mask_conn / parse_conf.

Kept in behavioral lockstep with the bash originals (see CLAUDE.md /
run_awr_fleet.sh:248 mask_conn, :392 parse_conf) so the server's validation
and display never disagree with what the wrapper itself would do. This file
is read-only tooling -- it never writes fleet.conf, only parses it.
"""

import re
from collections import OrderedDict
from typing import NamedTuple

ALIAS_RE = re.compile(r"^[A-Za-z0-9_.-]{1,30}$")
# Bash: ^(.*)\|[[:space:]]*[Dd][Ee][Tt][Aa][Ii][Ll][[:space:]]*$ applied to
# the connect remainder (everything after the FIRST '|').
_DETAIL_SUFFIX_RE = re.compile(r"^(.*)\|[ \t]*[Dd][Ee][Tt][Aa][Ii][Ll][ \t]*$")


class FleetConfError(Exception):
    """Mirrors a bash parse_conf `exit 2` -- a usage/conf error."""

    def __init__(self, message, lineno=None):
        self.lineno = lineno
        super().__init__(message)


class FleetConfEntry(NamedTuple):
    alias: str
    conn: str  # connect string, detail suffix already stripped
    conn_disp: str  # masked for display
    detail: bool
    lineno: int
    raw_line: str  # original line text (CRLF stripped), for verbatim reuse


def mask_conn(conn):
    """Port of run_awr_fleet.sh:249 mask_conn -- password-masked display.

    '/'-prefixed (wallet/OS-auth) passes through untouched; user/pw@svc ->
    user/***@svc; bare user/pw (no @svc) -> user/***; anything else
    (bare TNS alias, external auth) is left as-is.
    """
    if conn.startswith("/"):
        return conn
    m = re.match(r"^([^/]+)/[^@]*@(.*)$", conn)
    if m:
        return "%s/***@%s" % (m.group(1), m.group(2))
    m = re.match(r"^([^/]+)/.+$", conn)
    if m:
        return "%s/***" % (m.group(1),)
    return conn


def _pos_clean(what, value, lineno):
    """Port of _pos_clean -- reject quote / newline / tab."""
    if "'" in value:
        raise FleetConfError("%s must not contain a single quote" % (what,), lineno)
    if "\n" in value:
        raise FleetConfError("%s must not contain a newline" % (what,), lineno)
    if "\t" in value:
        raise FleetConfError("%s must not contain a tab" % (what,), lineno)


def parse_fleet_conf(path):
    """Parse a fleet.conf file into an OrderedDict[alias] -> FleetConfEntry.

    Raises FleetConfError on anything the bash parser would `exit 2` on:
    missing file, a line with no '|', an invalid/duplicate alias, an empty
    connect string, or a connect string containing a quote/newline/tab.
    """
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            lines = f.read().split("\n")
            # a trailing '' from the final newline is fine to drop
            if lines and lines[-1] == "":
                lines = lines[:-1]
    except OSError as exc:
        raise FleetConfError(
            "fleet.conf '%s' does not exist or is not readable: %s" % (path, exc)
        )

    entries = OrderedDict()
    for lineno, raw in enumerate(lines, start=1):
        line = raw[:-1] if raw.endswith("\r") else raw
        if line.strip() == "":
            continue
        if line.lstrip().startswith("#"):
            continue
        if "|" not in line:
            raise FleetConfError(
                "fleet.conf '%s' line %d: expected 'alias|connect[|detail]', got: %s"
                % (path, lineno, line),
                lineno,
            )
        alias_raw, conn = line.split("|", 1)
        alias = alias_raw.strip()
        if not ALIAS_RE.match(alias):
            raise FleetConfError(
                "fleet.conf '%s' line %d: alias '%s' invalid "
                "(must match [A-Za-z0-9_.-]{1,30})" % (path, lineno, alias),
                lineno,
            )
        if alias in entries:
            raise FleetConfError(
                "fleet.conf '%s' line %d: duplicate alias '%s'" % (path, lineno, alias),
                lineno,
            )

        detail = False
        m = _DETAIL_SUFFIX_RE.match(conn)
        if m:
            conn = m.group(1)
            detail = True

        if conn == "":
            raise FleetConfError(
                "fleet.conf '%s' line %d: empty connect string for alias '%s'"
                % (path, lineno, alias),
                lineno,
            )
        _pos_clean("connect (alias %s, line %d)" % (alias, lineno), conn, lineno)

        entries[alias] = FleetConfEntry(
            alias=alias,
            conn=conn,
            conn_disp=mask_conn(conn),
            detail=detail,
            lineno=lineno,
            raw_line=line,
        )

    if not entries:
        raise FleetConfError("fleet.conf '%s' has no usable entries." % (path,))

    return entries


def detail_conf_line(entry):
    """Verbatim line for a temp single-alias detail conf: append '|detail'
    only if the entry does not already carry it. Used by the on-demand
    detail regen job -- never rewrites the connect string itself.
    """
    if entry.detail:
        return entry.raw_line
    return entry.raw_line + "|detail"
