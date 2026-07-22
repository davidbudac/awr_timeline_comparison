#!/usr/bin/env bash
#
# Fleet report: one lean, offline-complete HTML report across many databases.
#
# Runs sql/fleet's lean per-DB extract (awr_fleet_extract.sql) against every
# alias in a fleet.conf file, in parallel, then stitches the per-DB HTML
# fragments it spools into a single combined report — worst database first.
# Companion to run_awr_trend.sh (the single-DB, full-detail tool); see
# CLAUDE.md for the fragment/sentinel/FLEET-COUNTS contract this script and
# sql/fleet/*.sql agree on.
#
# Usage:
#   ./run_awr_fleet.sh <fleet.conf> [target_end] [win_hours] [weeks_back] \
#                      [top_n] [step] [step_unit]
#   ./run_awr_fleet.sh --assemble <workdir>   # re-run just the assembler
#                                              # (debugging: sentinel/
#                                              # truncation/score checks
#                                              # without re-querying any DB)
#   ./run_awr_fleet.sh --help
#
# inst_num is not a fleet parameter: every DB is queried with inst_num=0
# (aggregate across RAC) — a fleet triage pass has no business drilling into
# one instance.
#
# Optional per-DB detailed reports: a fleet.conf line may carry a third field,
# "alias|connect|detail", flagging that DB for a FULL single-DB report
# (awr_trend.sql) generated in the same run and linked from that DB's row in
# the fleet report (see FLEET_DETAIL* below to force/disable this fleet-wide,
# or to tune the detailed run).
#
# Environment variables:
#   FLEET_PAR        max concurrent per-DB sqlplus runs           [4]
#   FLEET_TIMEOUT    per-DB wall-clock limit in seconds, enforced  [900]
#                    via `timeout`/`gtimeout` if either is on PATH;
#                    otherwise a one-time warning is printed and
#                    runs are unbounded.
#   FLEET_TEMPLATE   sql/lib/templates/<name> to use per DB        [fleet]
#   FLEET_KEEP_WORK  1 = never delete the per-run workdir under
#                    reports/fleet_work_<run_id>/, even when every
#                    DB succeeded                                  [0]
#   MARKERS          inline fleet-wide timeline markers, one string,
#                    "WHEN|LABEL;;WHEN|LABEL" (WHEN='YYYY-MM-DD HH:MM')
#   MARKER_FILE      a file of "WHEN|LABEL" lines; wins over MARKERS
#   FLEET_DETAIL     all = force a detailed report for every DB, none =
#                    disable detailed reports fleet-wide, empty = honor
#                    each fleet.conf line's own |detail flag           []
#   FLEET_DETAIL_TIMEOUT   per-DB wall-clock limit (seconds) for the
#                          detailed run, same timeout/gtimeout mechanism
#                          as FLEET_TIMEOUT; 0 = no limit            [3600]
#   FLEET_DETAIL_TEMPLATE  awr_trend.sql template for the detailed run
#                                                            [comprehensive]
#   FLEET_DETAIL_ECHARTS   passed to the single-DB report's `echarts` var;
#                          empty = public CDN, http(s) URL = internal
#                          mirror, local file path = inlined into the
#                          detailed report for a fully offline file    []
#
# Examples:
#   ./run_awr_fleet.sh fleet.conf
#   ./run_awr_fleet.sh fleet.conf AUTO 1 4 10 1 h
#   FLEET_PAR=8 FLEET_TIMEOUT=300 ./run_awr_fleet.sh fleet.conf
#   ./run_awr_fleet.sh --assemble reports/fleet_work_20260714120000123
#   # Force a detailed report for every DB, using the app-developer template:
#   FLEET_DETAIL=all FLEET_DETAIL_TEMPLATE=dev ./run_awr_fleet.sh fleet.conf
#
# Exit codes:
#   0   report written, at least one DB reported OK
#   2   usage error or a bad fleet.conf / argument (nothing run)
#   3   report written, but every DB failed (unreachable/truncated/error)
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# ---- canonical defaults (kept in sync with sql/fleet/defaults.sql) ---------
DEF_TARGET_END='AUTO'
DEF_WIN_HOURS='1'
DEF_WEEKS_BACK='4'
DEF_TOP_N='10'
DEF_STEP='1'
DEF_STEP_UNIT='w'

# ---- fleet report version ---------------------------------------------------
FLEET_VERSION='0.3.0'

# ---- fleet-specific env vars ------------------------------------------------
FLEET_PAR="${FLEET_PAR:-4}"
FLEET_TIMEOUT="${FLEET_TIMEOUT:-900}"
FLEET_TEMPLATE="${FLEET_TEMPLATE:-fleet}"
FLEET_KEEP_WORK="${FLEET_KEEP_WORK:-0}"

# ---- optional per-DB detailed (full single-DB) report -----------------------
# FLEET_DETAIL: '' = honor each fleet.conf line's own "|detail" flag (default),
# 'all' forces a detailed run for every alias, 'none' disables it fleet-wide.
# Applied to the parsed per-alias DETAILS[] array in parse_conf() so every
# downstream consumer (manifest, run_one_db, the assembler) sees only the
# effective flag.
FLEET_DETAIL="${FLEET_DETAIL:-}"
FLEET_DETAIL_TIMEOUT="${FLEET_DETAIL_TIMEOUT:-3600}"
FLEET_DETAIL_TEMPLATE="${FLEET_DETAIL_TEMPLATE:-comprehensive}"
FLEET_DETAIL_ECHARTS="${FLEET_DETAIL_ECHARTS:-}"

# ---- fleet-wide timeline markers (wrapper-owned; the extract SQL never sees
#      them). MARKER_FILE (a file of "WHEN|LABEL" lines) wins over MARKERS
#      (an inline "WHEN|LABEL;;WHEN|LABEL" list, same format as the single-DB
#      `markers` var). Parsed + sanitized by parse_markers into MK_WHEN[] /
#      MK_LABEL[], persisted to the workdir, emitted at assembly time as
#      window.FLEET_MARKERS + the masthead marker legend, and positioned in
#      each DB's report-span ASH timeline by js_fleet_charts.plsql.
MARKERS="${MARKERS:-}"
MARKER_FILE="${MARKER_FILE:-}"

[[ "$FLEET_PAR" =~ ^[1-9][0-9]*$ ]] || {
    echo "error: FLEET_PAR must be a positive integer (got '$FLEET_PAR')" >&2; exit 2; }
[[ "$FLEET_TIMEOUT" =~ ^[1-9][0-9]*$ ]] || {
    echo "error: FLEET_TIMEOUT must be a positive integer (got '$FLEET_TIMEOUT')" >&2; exit 2; }
[[ "$FLEET_KEEP_WORK" =~ ^[01]$ ]] || {
    echo "error: FLEET_KEEP_WORK must be 0 or 1 (got '$FLEET_KEEP_WORK')" >&2; exit 2; }
case "${FLEET_DETAIL,,}" in
    ''|all|none) : ;;
    *) echo "error: FLEET_DETAIL must be 'all', 'none', or empty (got '$FLEET_DETAIL')" >&2; exit 2 ;;
esac
[[ "$FLEET_DETAIL_TIMEOUT" =~ ^[0-9]+$ ]] || {
    echo "error: FLEET_DETAIL_TIMEOUT must be a non-negative integer, 0 = no limit (got '$FLEET_DETAIL_TIMEOUT')" >&2; exit 2; }
# FLEET_DETAIL_TEMPLATE rides into a single-quoted DEFINE in run_one_detail's
# heredoc (same footgun as FLEET_TEMPLATE / _pos_clean elsewhere in this file).
case "$FLEET_DETAIL_TEMPLATE" in
    *"'"*|*$'\n'*|*$'\t'*)
        echo "error: FLEET_DETAIL_TEMPLATE must not contain a single quote, newline, or tab (got '$FLEET_DETAIL_TEMPLATE')" >&2
        exit 2 ;;
esac
# FLEET_DETAIL_ECHARTS rides into a double-quoted <script src> AND a single-
# quoted DEFINE (see run_awr_trend.sh's ECHARTS validation for the <script
# src> half of this); either quote character would break one of the two.
case "$FLEET_DETAIL_ECHARTS" in
    *'"'*|*"'"*)
        echo "error: FLEET_DETAIL_ECHARTS must not contain a double quote (\") or single quote (') (got '$FLEET_DETAIL_ECHARTS')" >&2
        exit 2 ;;
esac

# ---- optional terminal styling (degrades to plain text) --------------------
# Same guarded pattern as run_awr_trend.sh: a missing terminfo cap (e.g. `tput
# dim` on some AIX types) must never be fatal under set -e -- see that
# script's header comment for the full rationale.
if [[ -t 1 ]] && command -v tput >/dev/null 2>&1 && tput sgr0 >/dev/null 2>&1; then
    BOLD="$(tput bold 2>/dev/null || true)"
    RST="$(tput sgr0 2>/dev/null || true)"
else
    BOLD=''; RST=''
fi

usage() {
    cat <<USAGE
${BOLD}AWR fleet report${RST} v${FLEET_VERSION} — one combined report across many databases

Usage:
  ./run_awr_fleet.sh <fleet.conf> [target_end] [win_hours] [weeks_back] \\
                     [top_n] [step] [step_unit]
  ./run_awr_fleet.sh --assemble <workdir>   re-run just the assembler
  ./run_awr_fleet.sh --help                 this help

Positional arguments (all but <fleet.conf> are optional, left to right):
  fleet.conf    "alias|connect[|detail]" per line -- see fleet.conf.example
                                                                   (required)
  target_end    AUTO = prior full hour, or 'YYYY-MM-DD HH24:MI'  [${DEF_TARGET_END}]
                (per DB, snapped back to its last snapshot at/before it if
                none exists within 15 min)
  win_hours     width of each compared window, in hours          [${DEF_WIN_HOURS}]
  weeks_back    number of prior windows to compare against       [${DEF_WEEKS_BACK}]
  top_n         Top-N rows per Top-SQL ranking                   [${DEF_TOP_N}]
  step          cadence count between adjacent windows           [${DEF_STEP}]
  step_unit     cadence unit: h (hours), d (days), w (weeks)     [${DEF_STEP_UNIT}]

Environment variables:
  FLEET_PAR        max concurrent per-DB sqlplus runs                    [4]
  FLEET_TIMEOUT    per-DB wall-clock limit in seconds (needs timeout/
                   gtimeout on PATH; otherwise unbounded, warned once)  [900]
  FLEET_TEMPLATE   sql/lib/templates/<name> to use per DB           [fleet]
  FLEET_KEEP_WORK  1 = keep the workdir even when every DB succeeded   [0]
  MARKERS          inline timeline markers "WHEN|LABEL;;WHEN|LABEL"
                   (WHEN = 'YYYY-MM-DD HH:MM'); drawn on every DB's
                   report-span ASH timeline, and in the masthead legend
  MARKER_FILE      a file of "WHEN|LABEL" lines; wins over MARKERS
  FLEET_DETAIL     all|none|'' -- force/disable/honor-per-line the
                   optional full single-DB detailed report              []
  FLEET_DETAIL_TIMEOUT   per-DB detailed-run wall-clock limit, seconds;
                         0 = no limit                               [3600]
  FLEET_DETAIL_TEMPLATE  awr_trend.sql template for the detailed run
                                                          [comprehensive]
  FLEET_DETAIL_ECHARTS   echarts source for the detailed report; empty =
                         CDN, http(s) URL = mirror, local path = inlined []

Score shown per DB in the report: 10*critical + 3*warning + min(25, top-SQL
points); an unreachable/truncated DB scores as an error row (sorts first).
Rows are collapsed by default -- click a row to expand its detail panel.
A DB flagged "|detail" in fleet.conf (or forced via FLEET_DETAIL=all) also
gets a full single-DB report (awr_trend.sql) generated alongside the fleet
report and linked from that DB's row.
USAGE
}

# ---------------------------------------------------------------------------
# Validators / sanitizers copied from run_awr_trend.sh (that file dispatches
# at parse time so it cannot be `source`d) -- see run_awr_trend.sh:289-313 for
# v_target_end/v_posdec/v_posint/v_step_unit, and run_awr_trend.sh:662-688 for
# the _pos_clean/_pos_die pattern.  Kept byte-for-byte identical in behaviour
# except _pos_clean here also rejects a literal tab, because a conf field
# flows into this script's own tab-delimited manifest.tsv (run_awr_trend.sh
# has no equivalent file, so it never needed that check).
# ---------------------------------------------------------------------------
v_nonempty()  { [[ -n "$1" ]] && return 0; echo "  -> a value is required." >&2; return 1; }
v_posint()    { [[ "$1" =~ ^[1-9][0-9]*$ ]] && return 0; echo "  -> enter a positive whole number." >&2; return 1; }
v_posdec()    { { [[ "$1" =~ ^([0-9]+|[0-9]*\.[0-9]+|[0-9]+\.[0-9]*)$ ]] && [[ "$1" =~ [1-9] ]]; } \
                  && return 0; echo "  -> enter a positive number (e.g. 1, or 0.25 for 15 min)." >&2; return 1; }
v_step_unit() { case "$1" in h|d|w) return 0;; esac; echo "  -> enter h, d or w." >&2; return 1; }
v_target_end() {
    [[ "$1" =~ ^[Aa][Uu][Tt][Oo]$ ]] && return 0
    if [[ "$1" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}$ ]]; then
        if date -d "2000-01-01 00:00" >/dev/null 2>&1 && ! date -d "$1" >/dev/null 2>&1; then
            echo "  -> '$1' is not a real calendar date/time." >&2
            return 1
        fi
        return 0
    fi
    echo "  -> enter AUTO, or a quoted instant like 2026-04-15 09:00." >&2
    return 1
}

_pos_die() { echo "error: argument '$1' = $(printf %q "$2") is invalid -- $3" >&2; exit 2; }
_pos_clean() {  # reject newline / single-quote / tab in a heredoc-bound string arg
    case "$2" in *"'"*) _pos_die "$1" "$2" "must not contain a single quote";; esac
    case "$2" in *$'\n'*) _pos_die "$1" "$2" "must not contain a newline";; esac
    case "$2" in *$'\t'*) _pos_die "$1" "$2" "must not contain a tab";; esac
}

# html_escape -- pipe filter, bash-side equivalent of the SQL side's
# DBMS_XMLGEN.CONVERT(...) convention (CLAUDE.md "HTML emission"): every
# string that came from outside this script (alias, masked connect, log
# tail) must be escaped before landing in the assembled HTML.  & first, so
# the entities inserted by the later substitutions are not themselves
# re-escaped.
html_escape() {
    sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g'
}

# mask_conn <connect> -- password-masked display string for drill-down lines
# and error cards.  Wallet / OS-authenticated connects ('/', '/@tns_alias',
# '/ as sysdba') have no password segment and pass through untouched;
# user/pw@svc becomes user/***@svc; a bare user/pw (no @svc) becomes
# user/***; anything else (a bare TNS alias, external auth) is left as-is.
mask_conn() {
    local c="$1"
    [[ "$c" == /* ]] && { printf '%s' "$c"; return; }
    if [[ "$c" =~ ^([^/]+)/[^@]*@(.*)$ ]]; then
        printf '%s/***@%s' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
        return
    fi
    if [[ "$c" =~ ^([^/]+)/.+$ ]]; then
        printf '%s/***' "${BASH_REMATCH[1]}"
        return
    fi
    printf '%s' "$c"
}

# ---------------------------------------------------------------------------
# is_url <value> / inline_fleet_echarts <html> <libfile> -- fleet-owned copies
# of run_awr_trend.sh's is_url / inline_echarts (CLAUDE.md forbids touching
# that file for a fleet feature, so the mechanism is copied here verbatim
# rather than sourced or shared).  Used only for the optional per-DB detailed
# report's FLEET_DETAIL_ECHARTS var -- see that file's identically-named
# functions for the full rationale.
# ---------------------------------------------------------------------------
is_url() { local v="${1,,}"; [[ "$v" == http://* || "$v" == https://* || "$v" == //* ]]; }

inline_fleet_echarts() {
    local html="$1" lib="$2" marker lineno
    [[ -z "$lib" ]] && return 0
    is_url "$lib" && return 0
    marker="src=\"$lib\""
    lineno="$(grep -nF "$marker" "$html" | head -1 | cut -d: -f1 || true)"
    if [[ -z "$lineno" ]]; then
        echo "warning: could not find the ECharts <script src=\"$lib\"> line in" \
             "$(basename "$html"); left linked, not inlined." >&2
        return 0
    fi
    {
        head -n "$((lineno - 1))" "$html"
        printf '<script>\n'
        cat "$lib"
        printf '\n</script>\n'
        tail -n "+$((lineno + 1))" "$html"
    } > "$html.inlining" && mv "$html.inlining" "$html"
    echo "Inlined ECharts ($lib) into $(basename "$html") -- detailed report is self-contained."
}

# resolve_detail_echarts_path -- when FLEET_DETAIL_ECHARTS is set and is not
# an http(s) URL, it must be a readable local file (relative paths resolved
# against the project root) BEFORE any DB is queried -- a bad path caught only
# after every extract has run would waste the whole run.  Empty / URL values
# need no local file and are left alone (the DEFINE already handles them).
resolve_detail_echarts_path() {
    [[ -z "$FLEET_DETAIL_ECHARTS" ]] && return 0
    is_url "$FLEET_DETAIL_ECHARTS" && return 0
    local p="$FLEET_DETAIL_ECHARTS"
    [[ "$p" == /* ]] || p="$SCRIPT_DIR/$p"
    if [[ ! -r "$p" ]]; then
        echo "error: FLEET_DETAIL_ECHARTS '$FLEET_DETAIL_ECHARTS' does not exist or is not readable." >&2
        exit 2
    fi
}

# ---------------------------------------------------------------------------
# parse_markers -- fills the global arrays MK_WHEN[] / MK_LABEL[] (parallel)
# from MARKER_FILE (a file of "WHEN|LABEL" lines) or, failing that, MARKERS
# (an inline "WHEN|LABEL;;WHEN|LABEL" list -- same format as the single-DB
# `markers` var).  Precedence MARKER_FILE > MARKERS, matching the single-DB
# report.  WHEN must be 'YYYY-MM-DD HH:MM' (whitespace-collapsed); LABEL is
# sanitized of the reserved chars < > & ' " ~ \ so it is safe both in the
# masthead HTML legend and inside the window.FLEET_MARKERS JS string.  A
# malformed marker is warned about and skipped, never fatal.  The extract SQL
# never sees markers -- they are positioned entirely client-side.
# ---------------------------------------------------------------------------
_add_marker() {
    local item="$1" when label
    case "$item" in *'|'*) : ;; *)
        echo "warning: marker '$item' has no WHEN|LABEL separator; skipped." >&2; return ;;
    esac
    when="${item%%|*}"
    label="${item#*|}"
    when="$(printf '%s' "$when" | tr -s '[:space:]' ' ' | sed -e 's/^ //' -e 's/ $//')"
    label="$(printf '%s' "$label" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/[<>&"'\''~\\]//g')"
    if [[ ! "$when" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}$ ]]; then
        echo "warning: marker time '$when' is not 'YYYY-MM-DD HH:MM'; skipped." >&2; return
    fi
    MK_WHEN+=("$when")
    MK_LABEL+=("$label")
}
parse_markers() {
    MK_WHEN=(); MK_LABEL=()
    local line rest chunk
    if [[ -n "$MARKER_FILE" ]]; then
        [[ -r "$MARKER_FILE" ]] || { echo "error: MARKER_FILE '$MARKER_FILE' does not exist or is not readable." >&2; exit 2; }
        while IFS= read -r line || [[ -n "$line" ]]; do
            line="${line%$'\r'}"
            [[ -z "${line//[[:space:]]/}" ]] && continue
            [[ "$line" =~ ^[[:space:]]*# ]] && continue
            _add_marker "$line"
        done < "$MARKER_FILE"
    elif [[ -n "$MARKERS" ]]; then
        rest="$MARKERS"
        while [[ -n "$rest" ]]; do
            if [[ "$rest" == *';;'* ]]; then chunk="${rest%%;;*}"; rest="${rest#*;;}"; else chunk="$rest"; rest=''; fi
            [[ -z "${chunk//[[:space:]]/}" ]] && continue
            _add_marker "$chunk"
        done
    fi
}

# ---------------------------------------------------------------------------
# resolve_timeout_bin -- sets TIMEOUT_BIN to 'timeout' or 'gtimeout' if
# either is on PATH, else '' with a one-time warning.  A missing timeout
# binary must never be fatal (FLEET_TIMEOUT just stops being enforced).
# ---------------------------------------------------------------------------
resolve_timeout_bin() {
    if command -v timeout >/dev/null 2>&1; then
        TIMEOUT_BIN=timeout
    elif command -v gtimeout >/dev/null 2>&1; then
        TIMEOUT_BIN=gtimeout
    else
        TIMEOUT_BIN=''
        echo "warning: neither 'timeout' nor 'gtimeout' found on PATH;" \
             "FLEET_TIMEOUT=${FLEET_TIMEOUT}s will not be enforced (runs unbounded)." >&2
    fi
}

# ---------------------------------------------------------------------------
# parse_conf <fleet.conf> -- fills the global arrays ALIASES / CONNS /
# CONN_DISPS / DETAILS (parallel, conf order).  "alias|connect[|detail]" per
# line; blank lines and lines whose first non-blank char is '#' are ignored.
# Aliases must match [A-Za-z0-9_.-]{1,30} and be unique; connect strings must
# not embed a quote, newline or tab (see _pos_clean).  Any violation dies with
# exit 2 (usage/conf error) and names the offending line.
#
# The optional third field is not a separate '|'-delimited token in the
# strict sense -- it's detected as a trailing "|detail" suffix (case-
# insensitive, whitespace around the token tolerated) on the remainder after
# the alias.  We deliberately do NOT try to detect "an unknown third field":
# a connect string could in principle contain '|', so anything not matching
# this exact suffix is just part of the connect string (documented in
# fleet.conf.example).  FLEET_DETAIL ('all'/'none'/'') overrides every
# per-line flag once parsing is done, so every downstream consumer (manifest,
# run_one_db, the assembler) sees only the effective flag.
# ---------------------------------------------------------------------------
parse_conf() {
    local conf="$1" lineno=0 line alias conn seen=':' detail_flag
    [[ -r "$conf" ]] || { echo "error: fleet.conf '$conf' does not exist or is not readable." >&2; exit 2; }
    ALIASES=(); CONNS=(); CONN_DISPS=(); DETAILS=()
    while IFS= read -r line || [[ -n "$line" ]]; do
        lineno=$((lineno + 1))
        line="${line%$'\r'}"                                  # tolerate CRLF
        [[ -z "${line//[[:space:]]/}" ]] && continue           # blank
        [[ "$line" =~ ^[[:space:]]*# ]] && continue             # comment
        if [[ "$line" != *'|'* ]]; then
            echo "error: fleet.conf '$conf' line $lineno: expected 'alias|connect[|detail]', got: $line" >&2
            exit 2
        fi
        alias="${line%%|*}"
        conn="${line#*|}"
        alias="$(printf '%s' "$alias" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
        if [[ ! "$alias" =~ ^[A-Za-z0-9_.-]{1,30}$ ]]; then
            echo "error: fleet.conf '$conf' line $lineno: alias '$alias' invalid" \
                 "(must match [A-Za-z0-9_.-]{1,30})" >&2
            exit 2
        fi
        case "$seen" in *":$alias:"*)
            echo "error: fleet.conf '$conf' line $lineno: duplicate alias '$alias'" >&2
            exit 2
            ;;
        esac
        seen="${seen}${alias}:"

        detail_flag='N'
        if [[ "$conn" =~ ^(.*)\|[[:space:]]*[Dd][Ee][Tt][Aa][Ii][Ll][[:space:]]*$ ]]; then
            conn="${BASH_REMATCH[1]}"
            detail_flag='Y'
        fi

        [[ -n "$conn" ]] || { echo "error: fleet.conf '$conf' line $lineno: empty connect string for alias '$alias'" >&2; exit 2; }
        _pos_clean "connect (alias $alias, line $lineno)" "$conn"
        ALIASES+=("$alias")
        CONNS+=("$conn")
        CONN_DISPS+=("$(mask_conn "$conn")")
        DETAILS+=("$detail_flag")
    done < "$conf"
    [[ "${#ALIASES[@]}" -gt 0 ]] || { echo "error: fleet.conf '$conf' has no usable entries." >&2; exit 2; }

    case "${FLEET_DETAIL,,}" in
        all)  local k; for k in "${!DETAILS[@]}"; do DETAILS[k]='Y'; done ;;
        none) local k; for k in "${!DETAILS[@]}"; do DETAILS[k]='N'; done ;;
    esac
}

# ---------------------------------------------------------------------------
# write_manifest <workdir> -- ALIASES/CONNS/CONN_DISPS/DETAILS (conf order) ->
# workdir/manifest.tsv (3 columns: alias, masked connect, detail flag Y/N),
# and the window/cadence/run params -> workdir/params.env.  Written up front
# (before any DB is queried) so `--assemble` can reconstruct conf order,
# masked connects, detail flags and the masthead window line from the workdir
# alone -- no need to keep fleet.conf around or re-parse it.  do_assemble
# tolerates a 2-column manifest from an older workdir (defaults the flag to N).
# ---------------------------------------------------------------------------
write_manifest() {
    local work="$1" i
    : > "$work/manifest.tsv"
    for i in "${!ALIASES[@]}"; do
        printf '%s\t%s\t%s\n' "${ALIASES[$i]}" "${CONN_DISPS[$i]}" "${DETAILS[$i]}" >> "$work/manifest.tsv"
    done
    # Persist parsed markers so --assemble can rebuild window.FLEET_MARKERS +
    # the masthead legend from the workdir alone (one "WHEN\tLABEL" per line;
    # empty file when no markers were configured).
    : > "$work/markers.tsv"
    if [[ "${#MK_WHEN[@]}" -gt 0 ]]; then
        for i in "${!MK_WHEN[@]}"; do
            printf '%s\t%s\n' "${MK_WHEN[$i]}" "${MK_LABEL[$i]}" >> "$work/markers.tsv"
        done
    fi
    cat > "$work/params.env" <<EOF
TARGET_END='${TARGET_END}'
WIN_HOURS='${WIN_HOURS}'
WEEKS_BACK='${WEEKS_BACK}'
TOP_N='${TOP_N}'
STEP='${STEP}'
STEP_UNIT='${STEP_UNIT}'
FLEET_TEMPLATE='${FLEET_TEMPLATE}'
RUN_ID='${RUN_ID}'
FLEET_DETAIL_TEMPLATE='${FLEET_DETAIL_TEMPLATE}'
FLEET_DETAIL_TIMEOUT='${FLEET_DETAIL_TIMEOUT}'
FLEET_DETAIL_ECHARTS='${FLEET_DETAIL_ECHARTS}'
EOF
}

# ---------------------------------------------------------------------------
# run_one_db <alias> <conn> <conn_disp> <detail_flag> -- runs the lean fleet
# extract against one DB.  Loads sql/defaults.sql then sql/fleet/defaults.sql
# as safety nets (same "defaults first, explicit DEFINEs override, driver as
# a SEPARATE start command" pattern as run_awr_trend.sh's run_report -- see
# that file's run_report comment for why loading both @files on one line is
# a silent no-op), sets inst_num=0 unconditionally (fleet always aggregates
# RAC), then @@awr_fleet_extract.sql.  stdout+stderr -> workdir/<alias>.log;
# exit status -> workdir/<alias>.rc (numeric only).  Never lets a per-DB
# failure escape as a script-fatal error (set -e is defeated by the
# `|| rc=$?` guard, mirroring run_awr_trend.sh's own idiom).
#
# When detail_flag='Y', also runs the optional full single-DB detailed report
# (run_one_detail) once the extract's rc is known -- inside this SAME
# background job, so FLEET_PAR still caps total concurrency (a detail run
# never adds a second job slot).  extract rc!=0 skips the detail run outright
# (nothing to drill into) and records 'skipped', not a numeric rc.
# ---------------------------------------------------------------------------
run_one_db() {
    local alias="$1" conn="$2" disp="$3" detail_flag="$4"
    local log="$WORK/$alias.log" rcfile="$WORK/$alias.rc"
    local rc=0
    local -a cmd=(sqlplus -S -L "$conn")
    [[ -n "$TIMEOUT_BIN" ]] && cmd=("$TIMEOUT_BIN" "$FLEET_TIMEOUT" "${cmd[@]}")

    "${cmd[@]}" > "$log" 2>&1 <<SQLEOF || rc=$?
@sql/defaults.sql
@sql/fleet/defaults.sql
DEFINE target_end = '${TARGET_END}'
DEFINE win_hours  = ${WIN_HOURS}
DEFINE weeks_back = ${WEEKS_BACK}
DEFINE top_n      = ${TOP_N}
DEFINE inst_num   = 0
DEFINE step       = ${STEP}
DEFINE step_unit  = '${STEP_UNIT}'
DEFINE template   = '${FLEET_TEMPLATE}'
DEFINE fleet_alias     = '${alias}'
DEFINE fleet_workdir   = '${WORK}'
DEFINE fleet_conn_disp = '${disp}'
@@awr_fleet_extract.sql
EXIT
SQLEOF
    printf '%s\n' "$rc" > "$rcfile"

    if [[ "$detail_flag" == 'Y' ]]; then
        if [[ "$rc" -eq 0 ]]; then
            run_one_detail "$alias" "$conn"
        else
            printf 'skipped\n' > "$WORK/$alias.detail.rc"
        fi
    fi
}

# ---------------------------------------------------------------------------
# run_one_detail <alias> <conn> -- generates the FULL single-DB report
# (awr_trend.sql) for one DB flagged "|detail", using the exact same
# window/cadence params as the fleet extract (inst_num pinned to 0, matching
# the fleet-wide "aggregate across RAC" stance).  Runs from an isolated
# per-alias cwd (symlinks to the project's driver + sql/ dir) so:
#   (a) awr_trend.sql's self-named `reports/awr_trend_<db>_<dbid>_<ts>_run<id>
#       .html` output can be captured without knowing its name up front,
#   (b) parallel detail runs under FLEET_PAR>1 never race on a shared
#       reports/ dir or a shared filename,
#   (c) no absolute project paths ever ride into the sqlplus heredoc (a
#       tilde/ampersand substitution hazard per CLAUDE.md's tilde gotcha).
# Two separate @ start commands (defaults, then the driver) mirror
# run_awr_trend.sh's run_report -- see that function's comment for why both
# on one line is a silent no-op.  On success, the single resulting *.html is
# moved to a predictable project-root path the assembler links to; the
# isolated dir is removed.  On failure (or if inlining leaves the isolated
# dir around because of an unexpected *.html count) the dir is LEFT for
# debugging, mirroring the single-DB workdir-on-error convention.  Writes the
# numeric rc (or nothing -- the caller already wrote 'skipped') to
# workdir/<alias>.detail.rc.
# ---------------------------------------------------------------------------
run_one_detail() {
    local alias="$1" conn="$2"
    local ddir="$WORK/detail_$alias"
    local dlog="$WORK/$alias.detail.log"
    local drc="$WORK/$alias.detail.rc"
    local rc=0

    mkdir -p "$ddir/reports"
    ln -s "$SCRIPT_DIR/awr_trend.sql" "$ddir/awr_trend.sql"
    ln -s "$SCRIPT_DIR/sql" "$ddir/sql"

    local -a cmd=(sqlplus -S -L "$conn")
    [[ -n "$TIMEOUT_BIN" && "$FLEET_DETAIL_TIMEOUT" -gt 0 ]] && cmd=("$TIMEOUT_BIN" "$FLEET_DETAIL_TIMEOUT" "${cmd[@]}")

    # The log redirection sits on the SUBSHELL, not the inner command: dlog is
    # a workdir-relative path that must resolve against this function's cwd
    # (the project root), not against ddir after the subshell's cd.
    ( cd "$ddir" && "${cmd[@]}" <<SQLEOF
@sql/defaults.sql
DEFINE target_end = '${TARGET_END}'
DEFINE win_hours  = ${WIN_HOURS}
DEFINE weeks_back = ${WEEKS_BACK}
DEFINE top_n      = ${TOP_N}
DEFINE inst_num   = 0
DEFINE step       = ${STEP}
DEFINE step_unit  = '${STEP_UNIT}'
DEFINE template   = '${FLEET_DETAIL_TEMPLATE}'
DEFINE markers    = '${DETAIL_MARKERS}'
DEFINE echarts    = '${FLEET_DETAIL_ECHARTS}'
@awr_trend.sql
EXIT
SQLEOF
    ) > "$dlog" 2>&1 || rc=$?

    if [[ "$rc" -eq 0 ]]; then
        # Plain glob, not find: AIX find lacks -maxdepth/-print0, and the
        # isolated reports/ dir can only ever hold the driver's single spool.
        local -a htmls=( "$ddir"/reports/*.html )
        [[ -e "${htmls[0]}" ]] || htmls=()
        if [[ "${#htmls[@]}" -eq 1 ]]; then
            local dest="reports/awr_fleet_detail_${alias}_run${RUN_ID}.html"
            mv "${htmls[0]}" "$dest"
            inline_fleet_echarts "$dest" "$FLEET_DETAIL_ECHARTS"
            rm -rf "$ddir"
        else
            rc=1
            echo "error: expected exactly one *.html under $ddir/reports, found ${#htmls[@]}." >> "$dlog"
        fi
    fi

    printf '%s\n' "$rc" > "$drc"
}

# ---------------------------------------------------------------------------
# detail_state <workdir> <alias> -- 'ok' | 'skipped' | 'timeout' | 'failed'.
# Only meaningful when the alias's detail flag is 'Y' (callers check the flag
# first).  Single-sourced by detail_bits (HTML chip/line for the report) and
# detail_status_word (the per-DB stdout summary line) so the two can never
# disagree about success/failure.  Needs RUN_ID in scope (do_assemble sources
# it from params.env before either caller runs).
# ---------------------------------------------------------------------------
detail_state() {
    local work="$1" alias="$2" drc dpath
    drc="$(cat "$work/$alias.detail.rc" 2>/dev/null || true)"
    dpath="reports/awr_fleet_detail_${alias}_run${RUN_ID}.html"
    if [[ "$drc" == '0' && -s "$dpath" ]]; then
        printf 'ok'
    elif [[ "$drc" == 'skipped' ]]; then
        printf 'skipped'
    elif [[ "$drc" == '124' ]]; then
        printf 'timeout'
    else
        printf 'failed'
    fi
}

# ---------------------------------------------------------------------------
# detail_bits <workdir> <alias> <flag> -- sets globals DCHIP / DLINE: the HTML
# snippets that replace the __FLEET_DETAIL_CHIP__ / __FLEET_DETAIL_LINE__
# placeholders 01_row.sql / 06_close.sql emit unconditionally in every OK
# fragment.  flag='N' (no detail requested) -> both empty.  flag='Y' ->
# inspects detail_state to decide the success/skipped/failed rendering.
#
# The success-case chip carries an inline onclick="event.stopPropagation()":
# the chip sits inside a tr.dbrow, whose delegated click handler (in
# js_fleet_charts.plsql, fleet-owned but NOT touched by this feature) toggles
# the row open on any click inside it.  Stopping propagation here keeps the
# click from ever reaching that document-level handler, so clicking the chip
# navigates instead of toggling -- without touching the shared JS file.
# preventDefault() is never called, so the anchor's normal navigation is
# unaffected.
# ---------------------------------------------------------------------------
detail_bits() {
    local work="$1" alias="$2" flag="$3"
    DCHIP=''; DLINE=''
    [[ "$flag" == 'Y' ]] || return 0

    local state href aliasE title ecode last_marker=''
    state="$(detail_state "$work" "$alias")"
    aliasE="$(printf '%s' "$alias" | html_escape)"

    # Last driver progress marker (sql/lib/debug_log.sql format, e.g.
    # "[awr_trend 10:40:31.808] section 07 summary (...)") from the detail
    # run's log -- shown on a timeout/failure so the user sees how far the
    # single-DB driver got.  debug='Y' is sql/defaults.sql's default, but
    # nothing here assumes it's on, so this may legitimately come up empty.
    # Sanitized of the DCHIP/DLINE-forbidden '|', '&', '\' before html_escape.
    if [[ -f "$work/$alias.detail.log" ]]; then
        # `|| true` guards set -e/pipefail when the log has no marker at all
        # (killed before the first section, or debug off) -- same pattern as
        # the ecode grep below.
        last_marker="$({ grep '^\[awr_trend ' "$work/$alias.detail.log" || true; } | tail -1 | tr -d '|&\\' | html_escape)"
    fi

    case "$state" in
        ok)
            href="awr_fleet_detail_${alias}_run${RUN_ID}.html"
            DCHIP="<a class=\"dchip\" href=\"$href\" onclick=\"event.stopPropagation()\" title=\"Open the full single-DB AWR report for $aliasE\">report</a>"
            DLINE="<div class=\"detail-link\">Full single-DB report: <a href=\"$href\">$href</a></div>"
            ;;
        skipped)
            DCHIP='<span class="dchip dfail" title="extract failed before the detail run could start">detail skipped (extract failed)</span>'
            DLINE='<div class="detail-link muted">Detailed report skipped (extract failed).</div>'
            ;;
        timeout)
            DCHIP="<span class=\"dchip dfail\" title=\"timed out after ${FLEET_DETAIL_TIMEOUT}s -- raise FLEET_DETAIL_TIMEOUT (0 = no limit)\">detail timed out</span>"
            DLINE="<div class=\"detail-link muted\">Detailed report timed out after ${FLEET_DETAIL_TIMEOUT}s (FLEET_DETAIL_TIMEOUT; 0 = no limit)."
            [[ -n "$last_marker" ]] && DLINE="$DLINE Last progress: <code>${last_marker}</code>"
            DLINE="$DLINE</div>"
            ;;
        *)
            title="rc=$(cat "$work/$alias.detail.rc" 2>/dev/null || echo N/A)"
            ecode=''
            if [[ -f "$work/$alias.detail.log" ]]; then
                # grep -E (POSIX) finds the first offending line; bash =~ then
                # slices out just the ORA-/TNS- token -- avoids GNU-only grep -o.
                ecode="$(grep -E 'ORA-[0-9]|TNS-[0-9]' "$work/$alias.detail.log" | head -1 || true)"
                if [[ "$ecode" =~ (ORA|TNS)-[0-9]+ ]]; then ecode="${BASH_REMATCH[0]}"; else ecode=''; fi
            fi
            [[ -n "$ecode" ]] && title="$title; $ecode"
            DCHIP="<span class=\"dchip dfail\" title=\"$(printf '%s' "$title" | html_escape)\">detail failed</span>"
            DLINE="<div class=\"detail-link muted\">Full single-DB report failed ($(printf '%s' "$title" | html_escape))."
            [[ -n "$last_marker" ]] && DLINE="$DLINE Last progress: <code>${last_marker}</code>"
            DLINE="$DLINE</div>"
            ;;
    esac
}

# detail_status_word <workdir> <flag> <alias> -- 'ok'|'skipped'|'timeout'|'failed'|'-'
# for the per-DB stdout summary line ('-' = detail not requested).
detail_status_word() {
    local work="$1" flag="$2" alias="$3"
    [[ "$flag" == 'Y' ]] || { printf -- '-'; return 0; }
    detail_state "$work" "$alias"
}

# ---------------------------------------------------------------------------
# do_assemble <workdir> -- classifies every alias in workdir/manifest.tsv,
# scores the OK ones, and writes reports/awr_fleet_<ts>_run<RUN_ID>.html.
# Sets the globals ASSEMBLE_REPORT_PATH / ASSEMBLE_OK_COUNT /
# ASSEMBLE_ERR_COUNT / ASSEMBLE_DETAIL_FAIL_COUNT / ASSEMBLE_DETAIL_TIMEOUT_COUNT
# for the caller (ASSEMBLE_DETAIL_FAIL_COUNT counts requested-but-not-
# successful detail reports -- skipped, timed out, or failed -- so the caller
# can decide to keep the workdir for debugging without touching the exit
# code; ASSEMBLE_DETAIL_TIMEOUT_COUNT is the subset of those that hit
# FLEET_DETAIL_TIMEOUT specifically, so the caller can print a targeted
# hint).  Also
# prints one summary line per DB (conf order) to stdout, now with a trailing
# detail=ok|skipped|timeout|failed|- column.  Pure function of the workdir's contents,
# so it is exactly what `--assemble` re-runs for debugging.
# ---------------------------------------------------------------------------
do_assemble() {
    local work="$1"
    [[ -f "$work/manifest.tsv" ]] || { echo "error: '$work/manifest.tsv' not found -- not a fleet workdir." >&2; exit 2; }
    [[ -f "$work/params.env"  ]] || { echo "error: '$work/params.env' not found -- not a fleet workdir." >&2; exit 2; }
    # shellcheck disable=SC1091
    source "$work/params.env"

    local -a A_ALIAS=() A_DISP=() A_DETAIL=()
    local a d det
    while IFS=$'\t' read -r a d det || [[ -n "$a" ]]; do
        [[ -z "$a" ]] && continue
        A_ALIAS+=("$a"); A_DISP+=("$d"); A_DETAIL+=("${det:-N}")
    done < "$work/manifest.tsv"

    # Rebuild the marker arrays from the workdir so --assemble reproduces the
    # exact window.FLEET_MARKERS + masthead legend without re-parsing env vars.
    MK_WHEN=(); MK_LABEL=()
    if [[ -f "$work/markers.tsv" ]]; then
        local mw ml
        while IFS=$'\t' read -r mw ml || [[ -n "$mw" ]]; do
            [[ -z "$mw" ]] && continue
            MK_WHEN+=("$mw"); MK_LABEL+=("$ml")
        done < "$work/markers.tsv"
    fi

    declare -A DISP IS_ERR REASON RCV SCORE CRIT WARN SUPP NTOP PTS DETAILFLAG
    local i alias frag chrome log rc reason line1 line2 crit warn supp n pts pts_capped score

    # -- "Compared windows" masthead strip: canonical window list (arrays
    # indexed by week_offset) from the FIRST OK fragment that carries any
    # FLEET-WINDOW comment, plus cross-DB validity tallies from every OK
    # fragment. win_mismatch flags a per-DB snap-to-grid divergence (see
    # sql/fleet/01_row.sql's FLEET-WINDOW contract comment).
    declare -A WIN_DOW WIN_BEGIN WIN_END WIN_REASON WIN_VALID WIN_TOTAL
    local win_canon_alias='' win_maxoff=-1 win_mismatch=0

    for i in "${!A_ALIAS[@]}"; do
        alias="${A_ALIAS[$i]}"
        DISP["$alias"]="${A_DISP[$i]}"
        DETAILFLAG["$alias"]="${A_DETAIL[$i]:-N}"
        frag="$work/$alias.frag.html"
        rc="$(cat "$work/$alias.rc" 2>/dev/null || true)"
        reason=''
        RCV["$alias"]="${rc:-N/A}"

        if [[ -z "$rc" || "$rc" != "0" ]]; then
            reason="sqlplus exit ${rc:-N/A}"
        fi
        if [[ ! -s "$frag" ]]; then
            reason="${reason:+$reason; }fragment missing"
        elif ! grep -qF "<!-- AWR-DB: ${alias} OK -->" "$frag"; then
            reason="${reason:+$reason; }sentinel missing (truncated spool)"
        fi

        if [[ -n "$reason" ]]; then
            IS_ERR["$alias"]=1
            REASON["$alias"]="$reason"
            continue
        fi
        IS_ERR["$alias"]=0

        # ---- FLEET-WINDOW comments (Compared-windows masthead strip) -----
        # Same bash-regex parsing approach as FLEET-COUNTS above (grep -F to
        # locate lines, =~ to pull fields -- no grep -o / sed -E). Missing
        # lines are NOT an error: an older workdir re-assembled with
        # --assemble predates this feature, so it simply contributes
        # nothing here and the strip is omitted below.
        # [|] not \| for the literal pipes: backslash-pipe in an ERE is
        # undefined by POSIX (glibc tolerates it, AIX may not); a bracket
        # expression is portable everywhere bash's =~ runs.
        local re_win='off=([0-9]+)[|]dow=([A-Za-z]+)[|]begin=([^|]+)[|]end=([^|]+)[|]valid=([YN])[|]reason=([^|]*) -->'
        local wline woff wdow wbeg wend wvalid wreason
        while IFS= read -r wline; do
            [[ "$wline" =~ $re_win ]] || continue
            woff="${BASH_REMATCH[1]}"; wdow="${BASH_REMATCH[2]}"
            wbeg="${BASH_REMATCH[3]}"; wend="${BASH_REMATCH[4]}"
            wvalid="${BASH_REMATCH[5]}"; wreason="${BASH_REMATCH[6]}"
            if [[ -z "$win_canon_alias" ]]; then
                win_canon_alias="$alias"
            fi
            if [[ "$alias" == "$win_canon_alias" ]]; then
                WIN_DOW["$woff"]="$wdow"; WIN_BEGIN["$woff"]="$wbeg"
                WIN_END["$woff"]="$wend"; WIN_REASON["$woff"]="$wreason"
                [[ "$woff" -gt "$win_maxoff" ]] && win_maxoff=$woff
            elif [[ -n "${WIN_BEGIN[$woff]:-}" ]] \
                 && { [[ "${WIN_BEGIN[$woff]}" != "$wbeg" ]] || [[ "${WIN_END[$woff]}" != "$wend" ]]; }; then
                # A later OK frag resolved a different begin/end instant for
                # the same offset -- per-DB target_end snap-to-grid landed on
                # a different snapshot. Flag it; times shown stay the
                # canonical (first-frag) ones.
                win_mismatch=1
            fi
            WIN_TOTAL["$woff"]=$(( ${WIN_TOTAL[$woff]:-0} + 1 ))
            [[ "$wvalid" == 'Y' ]] && WIN_VALID["$woff"]=$(( ${WIN_VALID[$woff]:-0} + 1 ))
        done < <(grep -F 'FLEET-WINDOW ' "$frag" || true)

        crit=0; warn=0; supp=0; n=0; pts=0
        # Parse the machine-readable FLEET-COUNTS comments with bash's own regex
        # engine (grep -F to locate the line, then =~ to pull the fields) so we
        # depend on neither `grep -o` nor `sed -E` -- both are GNU-only and absent
        # on AIX/Solaris, where -o aborts grep and -E is unrecognized by sed.
        local re_find='crit=([0-9]+) warn=([0-9]+) suppressed=([0-9]+)'
        local re_top='topsql n=([0-9]+) pts=([0-9]+)'
        line1="$(grep -F 'FLEET-COUNTS findings' "$frag" | tail -1 || true)"
        if [[ "$line1" =~ $re_find ]]; then
            crit="${BASH_REMATCH[1]}"; warn="${BASH_REMATCH[2]}"; supp="${BASH_REMATCH[3]}"
        else
            echo "warning: $alias: findings FLEET-COUNTS comment not found in fragment; scoring crit=warn=suppressed=0." >&2
        fi
        line2="$(grep -F 'FLEET-COUNTS topsql' "$frag" | tail -1 || true)"
        if [[ "$line2" =~ $re_top ]]; then
            n="${BASH_REMATCH[1]}"; pts="${BASH_REMATCH[2]}"
        else
            echo "warning: $alias: topsql FLEET-COUNTS comment not found in fragment; scoring n=pts=0." >&2
        fi
        pts_capped=$pts; [[ "$pts_capped" -gt 25 ]] && pts_capped=25
        score=$(( 10 * crit + 3 * warn + pts_capped ))

        CRIT["$alias"]=$crit; WARN["$alias"]=$warn; SUPP["$alias"]=$supp
        NTOP["$alias"]=$n; PTS["$alias"]=$pts; SCORE["$alias"]=$score
    done

    # -- chrome: first successful alias in conf order with a non-empty chrome file
    local chrome_alias='' n_ok=0 n_err=0 n_crit=0 n_warn=0 n_quiet=0
    for i in "${!A_ALIAS[@]}"; do
        alias="${A_ALIAS[$i]}"
        if [[ "${IS_ERR[$alias]}" == 0 ]]; then
            n_ok=$((n_ok + 1))
            if [[ -z "$chrome_alias" && -s "$work/$alias.chrome.html" ]]; then
                chrome_alias="$alias"
            fi
            if   [[ "${SCORE[$alias]}" -ge 10 ]]; then n_crit=$((n_crit + 1))
            elif [[ "${SCORE[$alias]}" -ge 1  ]]; then n_warn=$((n_warn + 1))
            else n_quiet=$((n_quiet + 1))
            fi
        else
            n_err=$((n_err + 1))
        fi
    done

    # -- sort OK aliases by score DESC, ties broken by conf order (stable) --
    local -a sort_keys=()
    for i in "${!A_ALIAS[@]}"; do
        alias="${A_ALIAS[$i]}"
        [[ "${IS_ERR[$alias]}" == 0 ]] && sort_keys+=("$(printf '%06d\t%06d\t%s' "${SCORE[$alias]}" "$i" "$alias")")
    done
    local -a sorted_ok=()
    if [[ "${#sort_keys[@]}" -gt 0 ]]; then
        while IFS=$'\t' read -r _ _ alias; do
            sorted_ok+=("$alias")
        done < <(printf '%s\n' "${sort_keys[@]}" | sort -t $'\t' -k1,1nr -k2,2n)
    fi

    mkdir -p reports
    local generated_at report_ts report
    generated_at="$(date '+%Y-%m-%d %H:%M:%S %z')"
    report_ts="$(date +%Y%m%d%H%M)"
    report="reports/awr_fleet_${report_ts}_run${RUN_ID}.html"

    # Wait-class palette for the masthead legend -- LOCKSTEP with
    # sql/lib/js_wait_colors.plsql and sql/fleet/js_fleet_charts.plsql (keep
    # the hexes identical across all three; do not diverge).
    local -a WC_LEGEND=(
        "CPU:#3FB344" "Scheduler:#88C070" "User I/O:#4A90D9" "System I/O:#1F4E89"
        "Concurrency:#8B0000" "Application:#D62728" "Commit:#E89B40"
        "Configuration:#793C32" "Administrative:#7B6FA8" "Network:#967259"
        "Queueing:#E89BB7" "Cluster:#E5C228" "Other:#C77CB0"
    )

    {
        if [[ -n "$chrome_alias" ]]; then
            cat "$work/$chrome_alias.chrome.html"
        else
            # No DB succeeded -- minimal chrome so the report is still a valid,
            # readable HTML page (coverage principle: every conf entry appears
            # as a row even when the whole fleet is dark).  The ops-console CSS
            # lives only in a successful DB's chrome copy, so error rows here
            # fall back to browser-default table styling -- still legible.
            cat <<'FALLBACK_CHROME'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>AWR Fleet Report</title>
<style>
  body{font-family:system-ui,-apple-system,sans-serif;margin:0;padding:1.25rem;
       max-width:1220px;color:#222;background:#fff;}
  h1{font-size:1.3rem;margin:0 0 .4rem;}
  .masthead{border:1px solid #ccc;border-radius:8px;padding:14px 16px;margin-bottom:14px;}
  table.fleet{width:100%;border-collapse:collapse;font-size:13px;}
  table.fleet th,table.fleet td{padding:6px 9px;border-bottom:1px solid #e0e0e0;text-align:left;}
  tr.detailrow.hidden{display:none;}
  .logtail{white-space:pre-wrap;background:#f6f6f6;border:1px solid #d33;border-radius:5px;
           padding:8px 10px;font-family:ui-monospace,Menlo,monospace;font-size:11px;}
  .stat-badge{display:inline-block;border:1px solid #ccc;border-radius:6px;padding:5px 10px;margin-right:6px;}
  footer.fleet-footer{margin-top:1.5rem;font-size:.75rem;color:#666;text-align:center;}
</style>
</head>
<body>
FALLBACK_CHROME
        fi

        # ---- window.FLEET_MARKERS (positioned client-side by the renderer) --
        # MK_WHEN/MK_LABEL are already sanitized of < > & ' " ~ \, so they are
        # safe both here (double-quoted JS string) and in the HTML legend below.
        printf '<script>window.FLEET_MARKERS=['
        local j sep=''
        if [[ "${#MK_WHEN[@]}" -gt 0 ]]; then
            for j in "${!MK_WHEN[@]}"; do
                printf '%s{"t":"%s","l":"%s"}' "$sep" "${MK_WHEN[$j]}" "${MK_LABEL[$j]}"
                sep=','
            done
        fi
        printf '];</script>\n'

        # ---- masthead ----
        printf '<div class="masthead"><div class="mh-top"><div class="mh-title">\n'
        printf '<h1>AWR Fleet Report</h1>\n'
        printf '<div class="sub">Multi-database health triage &middot; z-score anomaly scan vs %s prior window(s)</div>\n' \
            "$(printf '%s' "$WEEKS_BACK" | html_escape)"
        printf '<div class="run">Window <b>%sh ending %s</b> &middot; cadence %s%s &middot; %s prior window(s) &middot; top_n %s &middot; template %s &middot; generated <span class="tnum">%s</span></div>\n' \
            "$(printf '%s' "$WIN_HOURS" | html_escape)" "$(printf '%s' "$TARGET_END" | html_escape)" \
            "$(printf '%s' "$STEP" | html_escape)" "$(printf '%s' "$STEP_UNIT" | html_escape)" \
            "$(printf '%s' "$WEEKS_BACK" | html_escape)" "$(printf '%s' "$TOP_N" | html_escape)" \
            "$(printf '%s' "$FLEET_TEMPLATE" | html_escape)" "$(printf '%s' "$generated_at" | html_escape)"
        printf '</div>\n'
        # Theme toggle (reuses the shared .theme-icon-btn; icon swap is pure CSS
        # off body.dark). Sun/moon SVGs copied from sql/00_params.sql.
        printf '<button type="button" id="themeToggle" class="theme-icon-btn" aria-pressed="false" aria-label="Toggle dark mode" title="Switch between light and dark color theme">'
        printf '<svg class="icon-sun" viewBox="0 0 24 24" width="15" height="15" aria-hidden="true"><circle cx="12" cy="12" r="4.2" fill="none" stroke="currentColor" stroke-width="2"/><path d="M12 2.5v3M12 18.5v3M4.2 4.2l2.1 2.1M17.7 17.7l2.1 2.1M2.5 12h3M18.5 12h3M4.2 19.8l2.1-2.1M17.7 6.3l2.1-2.1" stroke="currentColor" stroke-width="2" stroke-linecap="round"/></svg>'
        printf '<svg class="icon-moon" viewBox="0 0 24 24" width="15" height="15" aria-hidden="true"><path d="M20.5 14.7A8.5 8.5 0 0 1 9.3 3.5a8.5 8.5 0 1 0 11.2 11.2z" fill="currentColor"/></svg>'
        printf '</button>\n'
        printf '</div>\n'   # .mh-top
        # summary stat badges
        printf '<div class="badges">\n'
        printf '<div class="stat-badge"><div class="n tnum">%s</div><div class="l">Databases</div></div>\n' "${#A_ALIAS[@]}"
        printf '<div class="stat-badge crit"><div class="n tnum">%s</div><div class="l">Crit</div></div>\n' "$n_crit"
        printf '<div class="stat-badge warn"><div class="n tnum">%s</div><div class="l">Warn</div></div>\n' "$n_warn"
        printf '<div class="stat-badge ok"><div class="n tnum">%s</div><div class="l">Quiet</div></div>\n' "$n_quiet"
        printf '<div class="stat-badge dead"><div class="n tnum">%s</div><div class="l">Unreach</div></div>\n' "$n_err"
        printf '</div>\n'   # .badges

        # ---- "Compared windows" strip, built from the FLEET-WINDOW
        # comments parsed above. Omitted entirely when no OK fragment had
        # any (older workdir re-assembled before this feature, or an
        # all-down fleet) -- report stays exactly as before in that case.
        if [[ "$win_maxoff" -ge 0 ]]; then
            printf '<div class="win-strip"><h3>Compared windows</h3><div class="win-chips">\n'
            local woff2 wk label dowv beginv endv datepart endpart v_cnt t_cnt \
                  cls wvtxt tooltip classes
            for (( woff2 = win_maxoff; woff2 >= 0; woff2-- )); do
                [[ -n "${WIN_BEGIN[$woff2]:-}" ]] || continue
                dowv="${WIN_DOW[$woff2]}"; beginv="${WIN_BEGIN[$woff2]}"; endv="${WIN_END[$woff2]}"
                if [[ "$woff2" -eq 0 ]]; then
                    label='current'
                else
                    wk=$(( woff2 * STEP ))
                    label="-${wk}${STEP_UNIT}"
                fi
                datepart="${beginv:0:10}"
                if [[ "${endv:0:10}" == "$datepart" ]]; then
                    endpart="${endv:11:5}"
                else
                    endpart="$endv"
                fi
                v_cnt="${WIN_VALID[$woff2]:-0}"; t_cnt="${WIN_TOTAL[$woff2]:-0}"
                cls=''; wvtxt=''; tooltip=''
                if [[ "$v_cnt" -eq 0 ]]; then
                    cls='skip'; wvtxt='skipped'
                    tooltip="${WIN_REASON[$woff2]:-}"
                elif [[ "$v_cnt" -lt "$t_cnt" ]]; then
                    cls='part'; wvtxt="${v_cnt}/${t_cnt} DBs"
                    tooltip="Valid on ${v_cnt} of ${t_cnt} database(s)"
                fi
                classes="win-chip"
                [[ -n "$cls" ]] && classes="$classes $cls"
                [[ "$woff2" -eq 0 ]] && classes="$classes cur"
                printf '<div class="%s" title="%s"><span class="wo">%s</span> %s <time class="tnum">%s &rarr; %s</time>' \
                    "$classes" "$(printf '%s' "$tooltip" | html_escape)" \
                    "$(printf '%s' "$label" | html_escape)" "$(printf '%s' "$dowv" | html_escape)" \
                    "$(printf '%s' "$beginv" | html_escape)" "$(printf '%s' "$endpart" | html_escape)"
                [[ -n "$wvtxt" ]] && printf '<span class="wv">%s</span>' "$(printf '%s' "$wvtxt" | html_escape)"
                printf '</div>\n'
            done
            printf '</div>\n'   # .win-chips
            if [[ "$win_mismatch" -eq 1 ]]; then
                printf '<div class="win-note">Window instants differ across databases (per-DB snapshot snapping) &mdash; times shown from <b>%s</b>; see each row&#39;s drill panel.</div>\n' \
                    "$(printf '%s' "$win_canon_alias" | html_escape)"
            fi
            printf '</div>\n'   # .win-strip
        fi

        # legends: wait-class palette + timeline markers
        printf '<div class="legends">\n'
        printf '<div class="legend-blk" style="flex:2 1 380px"><h3>Wait-class palette (ASH ribbons)</h3><div class="wc-legend">'
        local wc name hex
        for wc in "${WC_LEGEND[@]}"; do
            name="${wc%%:*}"; hex="${wc#*:}"
            printf '<div class="wc-item"><span class="wc-swatch" style="background:%s"></span>%s</div>' \
                "$hex" "$(printf '%s' "$name" | html_escape)"
        done
        printf '</div></div>\n'
        printf '<div class="legend-blk" style="flex:1 1 220px"><h3>Timeline markers</h3><div class="mk-legend">'
        if [[ "${#MK_WHEN[@]}" -gt 0 ]]; then
            local mcol
            for j in "${!MK_WHEN[@]}"; do
                if [[ $((j % 2)) -eq 0 ]]; then mcol='var(--accent)'; else mcol='var(--warn)'; fi
                printf '<div class="mk-item"><span class="mk-glyph" style="color:%s">|</span> %s <time>%s</time></div>' \
                    "$mcol" "$(printf '%s' "${MK_LABEL[$j]}" | html_escape)" "$(printf '%s' "${MK_WHEN[$j]}" | html_escape)"
            done
        else
            printf '<div class="mk-empty">No timeline markers configured.</div>'
        fi
        printf '</div></div>\n'
        printf '</div>\n'   # .legends
        printf '</div>\n'   # .masthead

        # ---- console table ----
        printf '<div class="console"><table class="fleet"><thead><tr>'
        printf '<th style="width:22px"></th>'
        printf '<th style="width:150px">Database</th>'
        printf '<th class="r" style="width:56px">Score</th>'
        printf '<th class="c" style="width:86px">Crit / Warn</th>'
        printf '<th class="r" style="width:62px">AAS</th>'
        printf '<th style="min-width:220px">Worst finding</th>'
        printf '<th class="c" style="width:122px">DB time trend</th>'
        printf '<th class="c" style="width:186px">ASH by wait class (span)</th>'
        printf '</tr></thead><tbody>\n'

        # error rows first (conf order): a red dbrow + a hidden detail row with
        # the masked connect and last-15 log lines.
        local ecode aliasE dispE reasonE rcvE
        for i in "${!A_ALIAS[@]}"; do
            alias="${A_ALIAS[$i]}"
            [[ "${IS_ERR[$alias]}" == 1 ]] || continue
            aliasE="$(printf '%s' "$alias" | html_escape)"
            dispE="$(printf '%s' "${DISP[$alias]}" | html_escape)"
            reasonE="$(printf '%s' "${REASON[$alias]}" | html_escape)"
            rcvE="$(printf '%s' "${RCV[$alias]}" | html_escape)"
            ecode='ERR'
            if [[ -f "$work/$alias.log" ]]; then
                ecode="$(grep -E 'ORA-[0-9]|TNS-[0-9]' "$work/$alias.log" | head -1 || true)"
                if [[ "$ecode" =~ (ORA|TNS)-[0-9]+ ]]; then ecode="${BASH_REMATCH[0]}"; else ecode='ERR'; fi
            fi
            printf '<tr class="dbrow deadrow" data-db="%s">' "$aliasE"
            printf '<td><svg class="chev" viewBox="0 0 16 16"><path d="M6 4l5 4-5 4" fill="none" stroke="currentColor" stroke-width="1.6"/></svg></td>'
            printf '<td><span class="alias-cell"><span class="dot dead"></span><span class="alias">%s <span class="role">unreachable</span></span></span></td>' "$aliasE"
            printf '<td><span class="score s-dead">ERR</span></td>'
            printf '<td style="text-align:center"><span class="pill z">&mdash;</span></td>'
            printf '<td class="aas" style="color:var(--muted)">&mdash;</td>'
            printf '<td><span class="finding"><span class="zbadge c">%s</span><span class="txt">connect failed &mdash; rc=%s</span></span></td>' \
                "$(printf '%s' "$ecode" | html_escape)" "$rcvE"
            printf '<td style="text-align:center;color:var(--muted);font-size:11px">n/a</td>'
            printf '<td style="text-align:center;color:var(--muted);font-size:11px">no fragment</td>'
            printf '</tr>\n'
            printf '<tr class="detailrow dead hidden"><td colspan="8"><div class="detail">'
            printf '<div class="panel-h" style="color:var(--crit)">Connection error</div>'
            printf '<div class="err-conn">connect: <b>%s</b> &middot; rc=%s &mdash; %s</div>' "$dispE" "$rcvE" "$reasonE"
            if [[ -f "$work/$alias.log" ]]; then
                printf '<div class="logtail">%s</div>' "$(tail -n 15 "$work/$alias.log" | html_escape)"
            fi
            # A detail-flagged alias whose extract failed always lands here
            # (run_one_db only attempts the detail run when the extract's rc
            # is 0) -- detail_state resolves this to 'skipped' via the
            # <alias>.detail.rc sentinel run_one_db wrote unconditionally.
            detail_bits "$work" "$alias" "${DETAILFLAG[$alias]:-N}"
            [[ -n "$DLINE" ]] && printf '%s' "$DLINE"
            printf '</div></td></tr>\n'
        done

        # OK rows, score DESC (conf-order tie-break already applied to
        # sorted_ok).  Substitute the row placeholders the extract emitted --
        # they are single-sourced here so the row pills, color and sort order
        # never disagree.  All substituted values are numeric/alpha (no sed
        # metacharacters) EXCEPT the two detail placeholders, whose HTML can
        # contain '/' (hrefs) -- hence the '|' delimiter and the '&'-free
        # construction in detail_bits (sed's replacement '&' means "whole
        # match", so a literal '&' there would corrupt the substitution).
        local sscore ssev scpill swpill scrit swarn
        for alias in "${sorted_ok[@]}"; do
            sscore="${SCORE[$alias]}"; scrit="${CRIT[$alias]}"; swarn="${WARN[$alias]}"
            if   [[ "$sscore" -ge 10 ]]; then ssev=crit
            elif [[ "$sscore" -ge 1  ]]; then ssev=warn
            else ssev=ok; fi
            if [[ "$scrit" -gt 0 ]]; then scpill=c; else scpill=z; fi
            if [[ "$swarn" -gt 0 ]]; then swpill=w; else swpill=z; fi
            detail_bits "$work" "$alias" "${DETAILFLAG[$alias]:-N}"
            sed -e "s/__FLEET_SCORE__/$sscore/g" \
                -e "s/__FLEET_SEV__/$ssev/g" \
                -e "s/__FLEET_CRIT__/$scrit/g" \
                -e "s/__FLEET_WARN__/$swarn/g" \
                -e "s/__FLEET_CPILL__/$scpill/g" \
                -e "s/__FLEET_WPILL__/$swpill/g" \
                -e "s|__FLEET_DETAIL_CHIP__|${DCHIP}|g" \
                -e "s|__FLEET_DETAIL_LINE__|${DLINE}|g" \
                "$work/$alias.frag.html"
        done

        printf '</tbody></table></div>\n'
        printf '<div class="hint">Click any row to expand its ASH timeline, headline metrics, findings &amp; drill-down. Rows sorted by severity score.</div>\n'
        printf '<footer class="fleet-footer">AWR Fleet Report v%s &middot; self-contained &middot; inline-SVG charts, no external dependencies &middot; score = 10&times;crit + 3&times;warn + min(25, top-SQL points)</footer>\n' \
            "$FLEET_VERSION"
        printf '</body>\n</html>\n'
    } > "$report.tmp" && mv "$report.tmp" "$report"

    # Post-assembly guard: no row placeholder may survive substitution.  A
    # surviving __FLEET_* token means a frag emitted a placeholder the OK-row
    # sed loop above did not cover (or an error frag leaked one) -- a bug.
    if grep -q '__FLEET_' "$report" 2>/dev/null; then
        echo "warning: unresolved __FLEET_* placeholder(s) survived assembly in $report -- this is a bug." >&2
    fi

    local dstat detail_fail_count=0 detail_timeout_count=0
    for i in "${!A_ALIAS[@]}"; do
        alias="${A_ALIAS[$i]}"
        dstat="$(detail_status_word "$work" "${DETAILFLAG[$alias]:-N}" "$alias")"
        if [[ "${DETAILFLAG[$alias]:-N}" == 'Y' && "$dstat" != 'ok' ]]; then
            detail_fail_count=$((detail_fail_count + 1))
            [[ "$dstat" == 'timeout' ]] && detail_timeout_count=$((detail_timeout_count + 1))
        fi
        if [[ "${IS_ERR[$alias]}" == 1 ]]; then
            printf '%-24s ERROR  rc=%-5s detail=%-7s %s\n' "$alias" "${RCV[$alias]}" "$dstat" "${REASON[$alias]}"
        else
            printf '%-24s OK     score=%-4s crit=%s warn=%s suppressed=%s topsql_n=%s topsql_pts=%s detail=%s\n' \
                "$alias" "${SCORE[$alias]}" "${CRIT[$alias]}" "${WARN[$alias]}" "${SUPP[$alias]}" "${NTOP[$alias]}" "${PTS[$alias]}" "$dstat"
        fi
    done
    echo "Report: $report"

    ASSEMBLE_REPORT_PATH="$report"
    ASSEMBLE_OK_COUNT="$n_ok"
    ASSEMBLE_ERR_COUNT="$n_err"
    ASSEMBLE_DETAIL_FAIL_COUNT="$detail_fail_count"
    ASSEMBLE_DETAIL_TIMEOUT_COUNT="$detail_timeout_count"
}

# ===========================================================================
# Dispatch
# ===========================================================================
case "${1:-}" in
    -h|--help)
        usage
        exit 0
        ;;
    --assemble)
        WORK="${2:-}"
        if [[ -z "$WORK" || ! -d "$WORK" ]]; then
            echo "error: --assemble requires an existing workdir (usage: --assemble <workdir>)." >&2
            exit 2
        fi
        do_assemble "$WORK"
        [[ "$ASSEMBLE_OK_COUNT" -ge 1 ]] && exit 0
        exit 3
        ;;
    '')
        usage >&2
        exit 2
        ;;
esac

# ---- positional (non-interactive) path -------------------------------------
CONF_PATH="$1"
TARGET_END="${2:-$DEF_TARGET_END}"
WIN_HOURS="${3:-$DEF_WIN_HOURS}"
WEEKS_BACK="${4:-$DEF_WEEKS_BACK}"
TOP_N="${5:-$DEF_TOP_N}"
STEP="${6:-$DEF_STEP}"
STEP_UNIT="${7:-$DEF_STEP_UNIT}"

_pos_clean target_end "$TARGET_END"
_pos_clean step_unit  "$STEP_UNIT"

v_target_end "$TARGET_END" 2>/dev/null || _pos_die target_end "$TARGET_END" "use AUTO or a real 'YYYY-MM-DD HH24:MI' instant"
v_posdec    "$WIN_HOURS"   2>/dev/null || _pos_die win_hours  "$WIN_HOURS"  "a positive number of hours (e.g. 1 or 0.25)"
v_posint    "$WEEKS_BACK"  2>/dev/null || _pos_die weeks_back "$WEEKS_BACK" "a positive whole number"
v_posint    "$TOP_N"       2>/dev/null || _pos_die top_n      "$TOP_N"      "a positive whole number"
v_posdec    "$STEP"        2>/dev/null || _pos_die step       "$STEP"       "a positive number"
v_step_unit "$STEP_UNIT"   2>/dev/null || _pos_die step_unit  "$STEP_UNIT"  "one of h, d, w"
_pos_clean fleet_template "$FLEET_TEMPLATE"

parse_conf "$CONF_PATH"
parse_markers

# Fail fast on a bad FLEET_DETAIL_ECHARTS local path BEFORE any DB is queried
# (a whole fleet run is expensive to waste on a typo caught only afterwards).
resolve_detail_echarts_path

# DETAIL_MARKERS: the already-sanitized fleet-wide MK_WHEN/MK_LABEL arrays,
# joined once as "WHEN|LABEL;;WHEN|LABEL" -- byte-identical format to the
# single-DB report's inline `markers` var (parse_markers already strips the
# reserved ' " ~ \ < > & chars the single-DB format also forbids), so it is
# safe to embed verbatim into every detail run's DEFINE.  Empty when no
# markers were configured.
DETAIL_MARKERS=''
for i in "${!MK_WHEN[@]}"; do
    DETAIL_MARKERS+="${DETAIL_MARKERS:+;;}${MK_WHEN[$i]}|${MK_LABEL[$i]}"
done

RUN_ID="$(date +%Y%m%d%H%M%S)$$"
WORK="reports/fleet_work_${RUN_ID}"
mkdir -p "$WORK"

write_manifest "$WORK"
resolve_timeout_bin

# ---- parallel fan-out capped at FLEET_PAR ----------------------------------
# Background jobs + `wait -n` (bash 4.3+) cap concurrency without an external
# job-control tool; every wait is `|| true`-guarded so one bad DB (or one
# `wait -n` racing an already-reaped job) never aborts the fleet under
# set -e.  A per-DB failure is captured entirely inside run_one_db's own rc
# file -- nothing here needs to see it.  A requested detail run rides inside
# the SAME background job (run_one_db calls run_one_detail itself), so
# FLEET_PAR still caps total concurrency -- it never spawns a second slot.
running=0
for i in "${!ALIASES[@]}"; do
    run_one_db "${ALIASES[$i]}" "${CONNS[$i]}" "${CONN_DISPS[$i]}" "${DETAILS[$i]}" &
    running=$((running + 1))
    if [[ "$running" -ge "$FLEET_PAR" ]]; then
        wait -n || true
        running=$((running - 1))
    fi
done
wait || true

do_assemble "$WORK"

# Keep the workdir when there's something worth debugging: any DB errored
# (pre-existing behaviour) OR any requested detail report did not complete
# successfully (so its .detail.log survives) -- either way FLEET_KEEP_WORK=1
# always wins regardless.  A detail failure never changes the exit code below
# (still 0 as long as >=1 DB row is OK).
if [[ "$ASSEMBLE_ERR_COUNT" -eq 0 && "${ASSEMBLE_DETAIL_FAIL_COUNT:-0}" -eq 0 && "$FLEET_KEEP_WORK" != 1 ]]; then
    rm -rf "$WORK"
elif [[ "$FLEET_KEEP_WORK" != 1 ]]; then
    echo "Keeping workdir '$WORK' for debugging (${ASSEMBLE_ERR_COUNT} DB error(s), ${ASSEMBLE_DETAIL_FAIL_COUNT:-0} detail failure(s))." >&2
fi

# A timeout is the one detail failure with an obvious, actionable fix (raise
# the limit or lift it), so it gets its own targeted stderr hint on top of the
# generic "Keeping workdir" message above.
if [[ "${ASSEMBLE_DETAIL_TIMEOUT_COUNT:-0}" -gt 0 ]]; then
    echo "Hint: ${ASSEMBLE_DETAIL_TIMEOUT_COUNT} detailed report(s) hit the ${FLEET_DETAIL_TIMEOUT}s FLEET_DETAIL_TIMEOUT. Re-run with a higher limit or FLEET_DETAIL_TIMEOUT=0 (no limit), or generate a single DB manually with the drill command shown in its row." >&2
fi

if [[ "$ASSEMBLE_OK_COUNT" -ge 1 ]]; then
    exit 0
fi
exit 3
