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

# ---- fleet-specific env vars ------------------------------------------------
FLEET_PAR="${FLEET_PAR:-4}"
FLEET_TIMEOUT="${FLEET_TIMEOUT:-900}"
FLEET_TEMPLATE="${FLEET_TEMPLATE:-fleet}"
FLEET_KEEP_WORK="${FLEET_KEEP_WORK:-0}"

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
${BOLD}AWR fleet report${RST} — one combined report across many databases

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

Score shown per DB in the report: 10*critical + 3*warning + min(25, top-SQL
points); an unreachable/truncated DB scores as an error card (sorts first).
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

    {
        if [[ -n "$chrome_alias" ]]; then
            cat "$work/$chrome_alias.chrome.html"
        else
            # No DB succeeded -- hardcoded minimal chrome so the report is
            # still a valid, readable HTML page (coverage principle: every
            # conf entry appears as a card even when the whole fleet is dark).
            cat <<'FALLBACK_CHROME'
<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<title>AWR Fleet Report</title>
<style>
  body{font-family:system-ui,-apple-system,sans-serif;margin:0;padding:1.5rem;
       background:#fff;color:#222;}
  h1{font-size:1.4rem;margin:0 0 .5rem;}
  .badge{display:inline-block;padding:.15rem .55rem;border-radius:.3rem;
         font-size:.85rem;margin-right:.4rem;color:#fff;}
  .badge.crit{background:#b3261e;} .badge.warn{background:#b26a00;}
  .badge.quiet{background:#4a5568;} .badge.err{background:#6b1414;}
  section.db-card{border:1px solid #ccc;border-radius:.4rem;padding:1rem;margin:1rem 0;}
  section.db-card-error{border-color:#b3261e;background:#fff5f5;}
  pre{white-space:pre-wrap;background:#f5f5f5;padding:.5rem;overflow-x:auto;}
  code.drill{font-family:monospace;background:#f0f0f0;padding:.1rem .3rem;}
  footer{margin-top:2rem;font-size:.8rem;color:#666;}
</style>
</head>
<body>
FALLBACK_CHROME
        fi

        printf '<section class="fleet-masthead">\n'
        printf '<h1>AWR Fleet Report</h1>\n'
        printf '<p>%s databases &mdash; ' "${#A_ALIAS[@]}"
        printf '<span class="badge crit">%s critical</span> ' "$n_crit"
        printf '<span class="badge warn">%s warning</span> ' "$n_warn"
        printf '<span class="badge quiet">%s quiet</span> ' "$n_quiet"
        printf '<span class="badge err">%s unreachable</span></p>\n' "$n_err"
        printf '<p>Window: %sh ending %s, %s prior window(s), cadence %s%s, top_n=%s, template=%s</p>\n' \
            "$(printf '%s' "$WIN_HOURS" | html_escape)" "$(printf '%s' "$TARGET_END" | html_escape)" \
            "$(printf '%s' "$WEEKS_BACK" | html_escape)" "$(printf '%s' "$STEP" | html_escape)" \
            "$(printf '%s' "$STEP_UNIT" | html_escape)" "$(printf '%s' "$TOP_N" | html_escape)" \
            "$(printf '%s' "$FLEET_TEMPLATE" | html_escape)"
        printf '<p>Generated: %s &nbsp; Run: %s</p>\n' "$generated_at" "$(printf '%s' "$RUN_ID" | html_escape)"
        printf '</section>\n'

        for i in "${!A_ALIAS[@]}"; do
            alias="${A_ALIAS[$i]}"
            [[ "${IS_ERR[$alias]}" == 1 ]] || continue
            printf '<section class="db-card db-card-error">\n'
            printf '<h2>%s</h2>\n' "$(printf '%s' "$alias" | html_escape)"
            printf '<p>connect: <code>%s</code></p>\n' "$(printf '%s' "${DISP[$alias]}" | html_escape)"
            printf '<p>rc=%s &mdash; %s</p>\n' "$(printf '%s' "${RCV[$alias]}" | html_escape)" \
                "$(printf '%s' "${REASON[$alias]}" | html_escape)"
            if [[ -f "$work/$alias.log" ]]; then
                printf '<p>Last 15 log lines:</p>\n<pre>%s</pre>\n' "$(tail -n 15 "$work/$alias.log" | html_escape)"
            fi
            printf '</section>\n'
        done

        for alias in "${sorted_ok[@]}"; do
            cat "$work/$alias.frag.html"
        done

        printf '<footer>Generated by run_awr_fleet.sh &mdash; score = 10&times;critical + 3&times;warning + min(25, top-SQL points); error cards score as unreachable.</footer>\n'
        printf '</body>\n</html>\n'
    } > "$report.tmp" && mv "$report.tmp" "$report"

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
