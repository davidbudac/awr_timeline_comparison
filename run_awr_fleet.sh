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
#
# Examples:
#   ./run_awr_fleet.sh fleet.conf
#   ./run_awr_fleet.sh fleet.conf AUTO 1 4 10 1 h
#   FLEET_PAR=8 FLEET_TIMEOUT=300 ./run_awr_fleet.sh fleet.conf
#   ./run_awr_fleet.sh --assemble reports/fleet_work_20260714120000123
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
FLEET_VERSION='0.2.0'

# ---- fleet-specific env vars ------------------------------------------------
FLEET_PAR="${FLEET_PAR:-4}"
FLEET_TIMEOUT="${FLEET_TIMEOUT:-900}"
FLEET_TEMPLATE="${FLEET_TEMPLATE:-fleet}"
FLEET_KEEP_WORK="${FLEET_KEEP_WORK:-0}"

# ---- fleet-wide timeline markers (wrapper-owned; the extract SQL never sees
#      them). MARKER_FILE (a file of "WHEN|LABEL" lines) wins over MARKERS
#      (an inline "WHEN|LABEL;;WHEN|LABEL" list, same format as the single-DB
#      `markers` var). Parsed + sanitized by parse_markers into MK_WHEN[] /
#      MK_LABEL[], persisted to the workdir, emitted at assembly time as
#      window.FLEET_MARKERS + the masthead marker legend, and positioned in
#      each DB's 24h ASH span by js_fleet_charts.plsql.
MARKERS="${MARKERS:-}"
MARKER_FILE="${MARKER_FILE:-}"

[[ "$FLEET_PAR" =~ ^[1-9][0-9]*$ ]] || {
    echo "error: FLEET_PAR must be a positive integer (got '$FLEET_PAR')" >&2; exit 2; }
[[ "$FLEET_TIMEOUT" =~ ^[1-9][0-9]*$ ]] || {
    echo "error: FLEET_TIMEOUT must be a positive integer (got '$FLEET_TIMEOUT')" >&2; exit 2; }
[[ "$FLEET_KEEP_WORK" =~ ^[01]$ ]] || {
    echo "error: FLEET_KEEP_WORK must be 0 or 1 (got '$FLEET_KEEP_WORK')" >&2; exit 2; }

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
  fleet.conf    "alias|connect" per line -- see fleet.conf.example  (required)
  target_end    AUTO = prior full hour, or 'YYYY-MM-DD HH24:MI'  [${DEF_TARGET_END}]
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
                   (WHEN = 'YYYY-MM-DD HH:MM'); drawn on every DB's 24h
                   ASH chart within span, and in the masthead legend
  MARKER_FILE      a file of "WHEN|LABEL" lines; wins over MARKERS

Score shown per DB in the report: 10*critical + 3*warning + min(25, top-SQL
points); an unreachable/truncated DB scores as an error row (sorts first).
Rows are collapsed by default -- click a row to expand its detail panel.
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
# CONN_DISPS (parallel, conf order).  "alias|connect" per line; blank lines
# and lines whose first non-blank char is '#' are ignored.  Aliases must
# match [A-Za-z0-9_.-]{1,30} and be unique; connect strings must not embed a
# quote, newline or tab (see _pos_clean).  Any violation dies with exit 2
# (usage/conf error) and names the offending line.
# ---------------------------------------------------------------------------
parse_conf() {
    local conf="$1" lineno=0 line alias conn seen=':'
    [[ -r "$conf" ]] || { echo "error: fleet.conf '$conf' does not exist or is not readable." >&2; exit 2; }
    ALIASES=(); CONNS=(); CONN_DISPS=()
    while IFS= read -r line || [[ -n "$line" ]]; do
        lineno=$((lineno + 1))
        line="${line%$'\r'}"                                  # tolerate CRLF
        [[ -z "${line//[[:space:]]/}" ]] && continue           # blank
        [[ "$line" =~ ^[[:space:]]*# ]] && continue             # comment
        if [[ "$line" != *'|'* ]]; then
            echo "error: fleet.conf '$conf' line $lineno: expected 'alias|connect', got: $line" >&2
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
        [[ -n "$conn" ]] || { echo "error: fleet.conf '$conf' line $lineno: empty connect string for alias '$alias'" >&2; exit 2; }
        _pos_clean "connect (alias $alias, line $lineno)" "$conn"
        ALIASES+=("$alias")
        CONNS+=("$conn")
        CONN_DISPS+=("$(mask_conn "$conn")")
    done < "$conf"
    [[ "${#ALIASES[@]}" -gt 0 ]] || { echo "error: fleet.conf '$conf' has no usable entries." >&2; exit 2; }
}

# ---------------------------------------------------------------------------
# write_manifest <workdir> -- ALIASES/CONNS/CONN_DISPS (conf order) ->
# workdir/manifest.tsv, and the window/cadence/run params -> workdir/
# params.env.  Written up front (before any DB is queried) so `--assemble`
# can reconstruct conf order, masked connects and the masthead window line
# from the workdir alone -- no need to keep fleet.conf around or re-parse it.
# ---------------------------------------------------------------------------
write_manifest() {
    local work="$1" i
    : > "$work/manifest.tsv"
    for i in "${!ALIASES[@]}"; do
        printf '%s\t%s\n' "${ALIASES[$i]}" "${CONN_DISPS[$i]}" >> "$work/manifest.tsv"
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
EOF
}

# ---------------------------------------------------------------------------
# run_one_db <alias> <conn> <conn_disp> -- runs the lean fleet extract
# against one DB.  Loads sql/defaults.sql then sql/fleet/defaults.sql as
# safety nets (same "defaults first, explicit DEFINEs override, driver as a
# SEPARATE start command" pattern as run_awr_trend.sh's run_report -- see
# that file's run_report comment for why loading both @files on one line is
# a silent no-op), sets inst_num=0 unconditionally (fleet always aggregates
# RAC), then @@awr_fleet_extract.sql.  stdout+stderr -> workdir/<alias>.log;
# exit status -> workdir/<alias>.rc (numeric only).  Never lets a per-DB
# failure escape as a script-fatal error (set -e is defeated by the
# `|| rc=$?` guard, mirroring run_awr_trend.sh's own idiom).
# ---------------------------------------------------------------------------
run_one_db() {
    local alias="$1" conn="$2" disp="$3"
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
}

# ---------------------------------------------------------------------------
# do_assemble <workdir> -- classifies every alias in workdir/manifest.tsv,
# scores the OK ones, and writes reports/awr_fleet_<ts>_run<RUN_ID>.html.
# Sets the globals ASSEMBLE_REPORT_PATH / ASSEMBLE_OK_COUNT /
# ASSEMBLE_ERR_COUNT for the caller.  Also prints one summary line per DB
# (conf order) to stdout.  Pure function of the workdir's contents, so it is
# exactly what `--assemble` re-runs for debugging.
# ---------------------------------------------------------------------------
do_assemble() {
    local work="$1"
    [[ -f "$work/manifest.tsv" ]] || { echo "error: '$work/manifest.tsv' not found -- not a fleet workdir." >&2; exit 2; }
    [[ -f "$work/params.env"  ]] || { echo "error: '$work/params.env' not found -- not a fleet workdir." >&2; exit 2; }
    # shellcheck disable=SC1091
    source "$work/params.env"

    local -a A_ALIAS=() A_DISP=()
    local a d
    while IFS=$'\t' read -r a d || [[ -n "$a" ]]; do
        [[ -z "$a" ]] && continue
        A_ALIAS+=("$a"); A_DISP+=("$d")
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

    declare -A DISP IS_ERR REASON RCV SCORE CRIT WARN SUPP NTOP PTS
    local i alias frag chrome log rc reason line1 line2 crit warn supp n pts pts_capped score

    for i in "${!A_ALIAS[@]}"; do
        alias="${A_ALIAS[$i]}"
        DISP["$alias"]="${A_DISP[$i]}"
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

        crit=0; warn=0; supp=0; n=0; pts=0
        line1="$(grep -oE '<!-- FLEET-COUNTS findings crit=[0-9]+ warn=[0-9]+ suppressed=[0-9]+ -->' "$frag" | tail -1 || true)"
        if [[ -n "$line1" ]]; then
            crit="$(sed -E 's/.*crit=([0-9]+).*/\1/' <<<"$line1")"
            warn="$(sed -E 's/.*warn=([0-9]+).*/\1/' <<<"$line1")"
            supp="$(sed -E 's/.*suppressed=([0-9]+).*/\1/' <<<"$line1")"
        else
            echo "warning: $alias: findings FLEET-COUNTS comment not found in fragment; scoring crit=warn=suppressed=0." >&2
        fi
        line2="$(grep -oE '<!-- FLEET-COUNTS topsql n=[0-9]+ pts=[0-9]+ -->' "$frag" | tail -1 || true)"
        if [[ -n "$line2" ]]; then
            n="$(sed -E 's/.*n=([0-9]+).*/\1/' <<<"$line2")"
            pts="$(sed -E 's/.*pts=([0-9]+).*/\1/' <<<"$line2")"
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
        printf '<th class="c" style="width:98px">DB time (24h)</th>'
        printf '<th class="c" style="width:186px">ASH by wait class (24h)</th>'
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
                ecode="$(grep -oE 'ORA-[0-9]{4,5}|TNS-[0-9]{4,5}' "$work/$alias.log" | head -1 || true)"
                [[ -z "$ecode" ]] && ecode='ERR'
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
            printf '</div></td></tr>\n'
        done

        # OK rows, score DESC (conf-order tie-break already applied to
        # sorted_ok).  Substitute the row placeholders the extract emitted --
        # they are single-sourced here so the row pills, color and sort order
        # never disagree.  All substituted values are numeric/alpha (no sed
        # metacharacters).
        local sscore ssev scpill swpill scrit swarn
        for alias in "${sorted_ok[@]}"; do
            sscore="${SCORE[$alias]}"; scrit="${CRIT[$alias]}"; swarn="${WARN[$alias]}"
            if   [[ "$sscore" -ge 10 ]]; then ssev=crit
            elif [[ "$sscore" -ge 1  ]]; then ssev=warn
            else ssev=ok; fi
            if [[ "$scrit" -gt 0 ]]; then scpill=c; else scpill=z; fi
            if [[ "$swarn" -gt 0 ]]; then swpill=w; else swpill=z; fi
            sed -e "s/__FLEET_SCORE__/$sscore/g" \
                -e "s/__FLEET_SEV__/$ssev/g" \
                -e "s/__FLEET_CRIT__/$scrit/g" \
                -e "s/__FLEET_WARN__/$swarn/g" \
                -e "s/__FLEET_CPILL__/$scpill/g" \
                -e "s/__FLEET_WPILL__/$swpill/g" \
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

    for i in "${!A_ALIAS[@]}"; do
        alias="${A_ALIAS[$i]}"
        if [[ "${IS_ERR[$alias]}" == 1 ]]; then
            printf '%-24s ERROR  rc=%-5s %s\n' "$alias" "${RCV[$alias]}" "${REASON[$alias]}"
        else
            printf '%-24s OK     score=%-4s crit=%s warn=%s suppressed=%s topsql_n=%s topsql_pts=%s\n' \
                "$alias" "${SCORE[$alias]}" "${CRIT[$alias]}" "${WARN[$alias]}" "${SUPP[$alias]}" "${NTOP[$alias]}" "${PTS[$alias]}"
        fi
    done
    echo "Report: $report"

    ASSEMBLE_REPORT_PATH="$report"
    ASSEMBLE_OK_COUNT="$n_ok"
    ASSEMBLE_ERR_COUNT="$n_err"
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
# file -- nothing here needs to see it.
running=0
for i in "${!ALIASES[@]}"; do
    run_one_db "${ALIASES[$i]}" "${CONNS[$i]}" "${CONN_DISPS[$i]}" &
    running=$((running + 1))
    if [[ "$running" -ge "$FLEET_PAR" ]]; then
        wait -n || true
        running=$((running - 1))
    fi
done
wait || true

do_assemble "$WORK"

if [[ "$ASSEMBLE_ERR_COUNT" -eq 0 && "$FLEET_KEEP_WORK" != 1 ]]; then
    rm -rf "$WORK"
fi

if [[ "$ASSEMBLE_OK_COUNT" -ge 1 ]]; then
    exit 0
fi
exit 3
