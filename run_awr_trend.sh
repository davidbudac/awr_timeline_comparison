#!/usr/bin/env bash
#
# Convenience wrapper around awr_trend.sql.
#
# Usage:
#   ./run_awr_trend.sh <connect_string> [target_end] [win_hours] [weeks_back] \
#                      [top_n] [inst_num] [step] [step_unit] [template] [debug] \
#                      [marker_file]
#   ./run_awr_trend.sh --configure        # interactive configurator (see below)
#   ./run_awr_trend.sh --help
#
# step / step_unit set the cadence between comparison windows.  Defaults
# step=1, step_unit=w reproduce the original "same hour-of-week, N prior
# weeks" behaviour.  step_unit is one of: h (hours), d (days), w (weeks).
#
# template selects which set of metrics + wait events to display.
# Defaults to 'comprehensive' (the full curated lists, identical to the
# pre-template behaviour).  'simple' shows a small triage-friendly
# subset.  'dev' is an application-developer's view (SQL/throughput/
# contention, no host/OS/storage-engine internals).  See
# sql/lib/templates/<name>/ for the metric/wait lists.
#
# debug = Y prints one-line timestamped progress markers to standard
# output as each section begins (helpful on large DBs where some sections
# take minutes).  The HTML report is unaffected.  Default: N.
#
# marker_file is an optional path to a timeline-marker config file
# (datetime + label milestones drawn as vertical lines on the dated
# charts).  Default: empty (no markers).  See markers.example.sql.
#
# --configure / -c / --interactive / -i  drops into an interactive
# "configurator": it walks you through every option (with explanations,
# sensible defaults and input validation), then prints a ready-to-paste
# ./run_awr_trend.sh command AND the equivalent pure-SQL*Plus block, and
# offers to run the report straight away.  Running it with no arguments
# at an interactive terminal offers the same thing.
#
# Examples:
#   ./run_awr_trend.sh user/pw@svc
#   ./run_awr_trend.sh user/pw@svc '2026-04-15 09:00' 1 4 10 0
#   ./run_awr_trend.sh / '2026-04-15 09:00'                   # connect / as sysdba
#   # Last 4 consecutive 1-hour windows ending at the prior full hour:
#   ./run_awr_trend.sh user/pw@svc AUTO 1 4 10 0 1 h
#   # Every other day for the past 7 days:
#   ./run_awr_trend.sh user/pw@svc AUTO 1 7 10 0 2 d
#   # Lean triage report for the prior hour:
#   ./run_awr_trend.sh user/pw@svc AUTO 1 4 10 0 1 w simple
#   # Same as defaults but with progress markers on stdout:
#   ./run_awr_trend.sh user/pw@svc AUTO 1 4 10 0 1 w comprehensive Y
#   # With user-defined milestone markers on the timeline charts:
#   ./run_awr_trend.sh user/pw@svc AUTO 1 4 10 0 1 w comprehensive N my_markers.sql
#   # Don't remember the argument order?  Let the configurator drive:
#   ./run_awr_trend.sh --configure
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---- canonical defaults (kept in sync with sql/defaults.sql) ----------------
DEF_TARGET_END='AUTO'
DEF_WIN_HOURS='1'
DEF_WEEKS_BACK='4'
DEF_TOP_N='10'
DEF_INST_NUM='0'
DEF_STEP='1'
DEF_STEP_UNIT='w'
DEF_TEMPLATE='comprehensive'
DEF_DEBUG='N'
DEF_MARKER_FILE=''

# ---- optional terminal styling (degrades to plain text) --------------------
if [[ -t 1 ]] && command -v tput >/dev/null 2>&1 && tput sgr0 >/dev/null 2>&1; then
    BOLD="$(tput bold)"; DIM="$(tput dim)"; RST="$(tput sgr0)"
else
    BOLD=''; DIM=''; RST=''
fi

usage() {
    cat <<USAGE
${BOLD}AWR timeline comparison${RST} — wrapper around awr_trend.sql

Usage:
  ./run_awr_trend.sh <connect> [target_end] [win_hours] [weeks_back] \\
                     [top_n] [inst_num] [step] [step_unit] [template] \\
                     [debug] [marker_file]
  ./run_awr_trend.sh --configure        interactive configurator
  ./run_awr_trend.sh --help             this help

Positional arguments (all but <connect> are optional, left to right):
  connect       user/pw@svc, /, or any sqlplus connect string   (required)
  target_end    AUTO = prior full hour, or 'YYYY-MM-DD HH24:MI'  [${DEF_TARGET_END}]
  win_hours     width of each compared window, in hours          [${DEF_WIN_HOURS}]
  weeks_back    number of prior windows to compare against       [${DEF_WEEKS_BACK}]
  top_n         Top-N rows per ranking in Top SQL / waits        [${DEF_TOP_N}]
  inst_num      RAC: 0 = aggregate all, >0 = one instance        [${DEF_INST_NUM}]
  step          cadence count between adjacent windows           [${DEF_STEP}]
  step_unit     cadence unit: h (hours), d (days), w (weeks)     [${DEF_STEP_UNIT}]
  template      metric/wait set: $(list_templates | sed 's/ /, /g')   [${DEF_TEMPLATE}]
  debug         Y prints per-section progress markers to stdout  [${DEF_DEBUG}]
  marker_file   optional timeline-marker config file path        [none]

Tip: not sure which arguments you need?  Run  ./run_awr_trend.sh --configure
USAGE
}

# Discover the templates that actually ship under sql/lib/templates/ so the
# configurator and help stay in sync if new ones are added.
list_templates() {
    local d found=''
    for d in "$SCRIPT_DIR"/sql/lib/templates/*/; do
        [[ -d "$d" ]] || continue
        found+="$(basename "$d") "
    done
    [[ -n "$found" ]] || found='comprehensive simple dev '
    printf '%s' "${found% }"
}

# ---------------------------------------------------------------------------
# run_report <connect> <target_end> <win_hours> <weeks_back> <top_n>
#            <inst_num> <step> <step_unit> <template> <debug> <marker_file>
#
# Sets every awr_trend.sql substitution variable and runs the driver.
# This is the single place the report is actually generated; both the
# positional path and the configurator call it.
# ---------------------------------------------------------------------------
run_report() {
    local CONN="$1" TARGET_END="$2" WIN_HOURS="$3" WEEKS_BACK="$4" TOP_N="$5" \
          INST_NUM="$6" STEP="$7" STEP_UNIT="$8" TEMPLATE="$9" DEBUG="${10}" \
          MARKER_FILE="${11}"

    cd "$SCRIPT_DIR"
    mkdir -p reports

    # awr_trend.sql does not DEFINE defaults itself; we set them here and the
    # driver inherits them from this sqlplus session.
    sqlplus -S -L "$CONN" <<EOF
DEFINE target_end = '${TARGET_END}'
DEFINE win_hours  = ${WIN_HOURS}
DEFINE weeks_back = ${WEEKS_BACK}
DEFINE top_n      = ${TOP_N}
DEFINE inst_num   = ${INST_NUM}
DEFINE step       = ${STEP}
DEFINE step_unit  = '${STEP_UNIT}'
DEFINE template   = '${TEMPLATE}'
DEFINE debug      = '${DEBUG}'
DEFINE marker_file = '${MARKER_FILE}'
@@awr_trend.sql
EXIT
EOF
}

# ===========================================================================
# Interactive configurator
# ===========================================================================

# shq <value> — render <value> as a single shell token, quoting only when
# necessary, so the printed command is copy-paste-correct.
shq() {
    local s="$1"
    if [[ -z "$s" || "$s" == *[!A-Za-z0-9_@/.:,=+-]* ]]; then
        s="'${s//\'/\'\\\'\'}'"
    fi
    printf '%s' "$s"
}

# Abort cleanly when the user hits Ctrl-D / Ctrl-C at a prompt.
_abort() { printf '\n'; echo 'Configurator aborted; nothing was run.' >&2; exit 130; }

# --- validators: print a hint and return 1 on bad input --------------------
v_nonempty()  { [[ -n "$1" ]] && return 0; echo "  -> a value is required." >&2; return 1; }
v_posint()    { [[ "$1" =~ ^[1-9][0-9]*$ ]] && return 0; echo "  -> enter a positive whole number." >&2; return 1; }
v_nonneg()    { [[ "$1" =~ ^[0-9]+$ ]] && return 0; echo "  -> enter 0 or a positive whole number." >&2; return 1; }
v_step_unit() { case "$1" in h|d|w) return 0;; esac; echo "  -> enter h, d or w." >&2; return 1; }
v_cadence()   { [[ "$1" =~ ^[1-4]$ ]] && return 0; echo "  -> enter 1, 2, 3 or 4." >&2; return 1; }
v_target_end() {
    [[ "$1" =~ ^[Aa][Uu][Tt][Oo]$ ]] && return 0
    [[ "$1" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}$ ]] && return 0
    echo "  -> enter AUTO, or a quoted instant like 2026-04-15 09:00." >&2
    return 1
}

# prompt_value <varname> <prompt> <default> [validator]
# Empty input keeps the default.  Loops until the validator passes.
prompt_value() {
    local __var="$1" __msg="$2" __def="$3" __val="${4:-}" __in
    while true; do
        printf '%s' "$__msg"
        [[ -n "$__def" ]] && printf ' %s[%s]%s' "$DIM" "$__def" "$RST"
        printf ': '
        IFS= read -r __in || _abort
        [[ -z "$__in" ]] && __in="$__def"
        if [[ -n "$__val" ]] && ! "$__val" "$__in"; then
            continue
        fi
        printf -v "$__var" '%s' "$__in"
        return 0
    done
}

# prompt_yesno <varname> <prompt> <default Y|N>  -> stores Y or N
prompt_yesno() {
    local __var="$1" __msg="$2" __def="$3" __in
    while true; do
        printf '%s %s[%s]%s: ' "$__msg" "$DIM" "$__def" "$RST"
        IFS= read -r __in || _abort
        [[ -z "$__in" ]] && __in="$__def"
        case "$__in" in
            [Yy]|[Yy][Ee][Ss]|1|[Oo][Nn]|[Tt]|[Tt][Rr][Uu][Ee]) printf -v "$__var" 'Y'; return 0;;
            [Nn]|[Nn][Oo]|0|[Oo][Ff][Ff]|[Ff]|[Ff][Aa][Ll][Ss][Ee]) printf -v "$__var" 'N'; return 0;;
            *) echo "  -> answer y or n." >&2;;
        esac
    done
}

template_desc() {
    case "$1" in
        comprehensive) echo "full curated lists (27 stats, 23 metrics, all waits)";;
        simple)        echo "triage subset (9 stats, 8 metrics, ~10 waits)";;
        dev)           echo "app-developer view (SQL / throughput / contention)";;
        *)             echo "custom template";;
    esac
}

# Sets STEP and STEP_UNIT from a friendly cadence menu.
choose_cadence() {
    local cur=1
    case "$STEP_UNIT" in w) cur=1;; d) cur=2;; h) cur=3;; esac
    [[ "$STEP" != "1" ]] && cur=4
    echo
    echo "${BOLD}Cadence${RST} — spacing between adjacent comparison windows:"
    echo "  1) Weekly   same clock-hour, N prior weeks   (step 1 w, the default)"
    echo "  2) Daily    same clock-hour, N prior days    (step 1 d)"
    echo "  3) Hourly   consecutive hours, straight back (step 1 h)"
    echo "  4) Custom   choose the step count and unit yourself"
    local choice
    prompt_value choice "Choose 1-4" "$cur" v_cadence
    case "$choice" in
        1) STEP=1; STEP_UNIT=w;;
        2) STEP=1; STEP_UNIT=d;;
        3) STEP=1; STEP_UNIT=h;;
        4) prompt_value STEP      "  Step count between windows" "$STEP"      v_posint
           prompt_value STEP_UNIT "  Step unit (h=hours, d=days, w=weeks)" "$STEP_UNIT" v_step_unit;;
    esac
}

# Sets TEMPLATE from a numbered menu (accepts a number or the name).
choose_template() {
    echo
    echo "${BOLD}Template${RST} — which metric + wait-event set to render:"
    local i t def_idx=1
    for i in "${!TEMPLATES[@]}"; do
        t="${TEMPLATES[$i]}"
        [[ "$t" == "$TEMPLATE" ]] && def_idx=$((i + 1))
        printf '  %d) %-14s %s%s%s\n' "$((i + 1))" "$t" "$DIM" "$(template_desc "$t")" "$RST"
    done
    local choice
    while true; do
        printf 'Choose 1-%d or a name %s[%d]%s: ' "${#TEMPLATES[@]}" "$DIM" "$def_idx" "$RST"
        IFS= read -r choice || _abort
        [[ -z "$choice" ]] && choice="$def_idx"
        if [[ "$choice" =~ ^[0-9]+$ ]] && [[ "$choice" -ge 1 ]] && [[ "$choice" -le "${#TEMPLATES[@]}" ]]; then
            TEMPLATE="${TEMPLATES[$((choice - 1))]}"; return 0
        fi
        for t in "${TEMPLATES[@]}"; do
            [[ "$choice" == "$t" ]] && { TEMPLATE="$t"; return 0; }
        done
        echo "  -> enter 1-${#TEMPLATES[@]} or one of: ${TEMPLATES[*]}" >&2
    done
}

# Optional marker file.  Blank keeps the current value; '-' or 'none' clears it.
prompt_marker() {
    local in
    while true; do
        printf 'Timeline-marker config file (optional)'
        if [[ -n "$MARKER_FILE" ]]; then
            printf ' %s[%s; "-" to clear]%s' "$DIM" "$MARKER_FILE" "$RST"
        else
            printf ' %s[none]%s' "$DIM" "$RST"
        fi
        printf ': '
        IFS= read -r in || _abort
        [[ -z "$in" ]] && return 0                       # keep current
        case "$in" in
            -|[Nn][Oo][Nn][Ee]) MARKER_FILE=''; return 0;;
        esac
        if [[ ! -f "$in" ]]; then
            echo "  -> note: '$in' not found right now; it must exist before you run." >&2
        fi
        MARKER_FILE="$in"
        return 0
    done
}

# Build the minimal copy-paste ./run_awr_trend.sh command: emit positional
# args up to the last one that differs from its default (connect is always
# present).
build_shell_cmd() {
    local -a vals=("$CONN" "$TARGET_END" "$WIN_HOURS" "$WEEKS_BACK" "$TOP_N" \
                   "$INST_NUM" "$STEP" "$STEP_UNIT" "$TEMPLATE" "$DEBUG" "$MARKER_FILE")
    local -a defs=("" "$DEF_TARGET_END" "$DEF_WIN_HOURS" "$DEF_WEEKS_BACK" "$DEF_TOP_N" \
                   "$DEF_INST_NUM" "$DEF_STEP" "$DEF_STEP_UNIT" "$DEF_TEMPLATE" "$DEF_DEBUG" "$DEF_MARKER_FILE")
    local last=0 i
    for (( i = 1; i < ${#vals[@]}; i++ )); do
        [[ "${vals[$i]}" != "${defs[$i]}" ]] && last=$i
    done
    local out='./run_awr_trend.sh'
    for (( i = 0; i <= last; i++ )); do
        out+=" $(shq "${vals[$i]}")"
    done
    printf '%s\n' "$out"
}

# Print the pure-SQL*Plus equivalent (no shell wrapper).
build_sqlplus_block() {
    cat <<SQLBLK
sqlplus -S -L $(shq "$CONN") <<'EOF'
DEFINE target_end = '${TARGET_END}'
DEFINE win_hours  = ${WIN_HOURS}
DEFINE weeks_back = ${WEEKS_BACK}
DEFINE top_n      = ${TOP_N}
DEFINE inst_num   = ${INST_NUM}
DEFINE step       = ${STEP}
DEFINE step_unit  = '${STEP_UNIT}'
DEFINE template   = '${TEMPLATE}'
DEFINE debug      = '${DEBUG}'
DEFINE marker_file = '${MARKER_FILE}'
@@awr_trend.sql
EXIT
EOF
SQLBLK
}

# Human-readable "what windows will I get" + AWR-retention nudge.
print_span_hint() {
    local mult=168
    case "$STEP_UNIT" in h) mult=1;; d) mult=24;; w) mult=168;; esac
    local step_hours=$(( STEP * mult ))
    local span_hours=$(( WEEKS_BACK * step_hours + WIN_HOURS ))
    local span_days=$(( span_hours / 24 ))
    local rem_hours=$(( span_hours % 24 ))
    local span_txt="${span_hours} h"
    [[ "$span_days" -gt 0 ]] && span_txt="${span_days} d ${rem_hours} h (${span_hours} h)"
    echo "Windows:   current window + ${WEEKS_BACK} prior, spaced ${STEP}${STEP_UNIT} apart."
    echo "Span:      reaches back ~${span_txt}; AWR retention must cover it."
    [[ "$span_days" -ge 8 ]] && \
        echo "           ${DIM}(default 19c retention is 8 days — check dba_hist_wr_control.)${RST}"
    return 0
}

print_summary() {
    echo
    echo "${BOLD}========================  Configuration  ========================${RST}"
    printf '  %-14s %s\n' 'connect'     "$CONN"
    printf '  %-14s %s\n' 'target_end'  "$TARGET_END"
    printf '  %-14s %s h\n' 'win_hours'   "$WIN_HOURS"
    printf '  %-14s %s\n' 'weeks_back'  "$WEEKS_BACK"
    printf '  %-14s %s\n' 'top_n'       "$TOP_N"
    printf '  %-14s %s%s\n' 'inst_num'    "$INST_NUM" "$([[ "$INST_NUM" == 0 ]] && echo '  (aggregate across RAC instances)')"
    printf '  %-14s %s %s\n' 'cadence'     "$STEP" "$STEP_UNIT"
    printf '  %-14s %s  %s%s%s\n' 'template'    "$TEMPLATE" "$DIM" "$(template_desc "$TEMPLATE")" "$RST"
    printf '  %-14s %s\n' 'debug'       "$DEBUG"
    printf '  %-14s %s\n' 'marker_file' "${MARKER_FILE:-(none)}"
    echo "${BOLD}=================================================================${RST}"
    print_span_hint
    echo
    echo "${BOLD}A) Shell wrapper${RST} — copy & paste, or re-run later:"
    echo
    echo "    $(build_shell_cmd)"
    echo
    echo "${BOLD}B) Pure SQL*Plus${RST} — no shell wrapper (e.g. a Windows host).  Paste"
    echo "   the whole block, or just the DEFINE lines at a SQL> prompt then @awr_trend.sql:"
    echo
    build_sqlplus_block | sed 's/^/    /'
    echo
}

configure() {
    # Discover templates once.
    IFS=' ' read -r -a TEMPLATES <<< "$(list_templates)"

    # Seed working values from canonical defaults (CONN starts empty / reused).
    CONN="${CONN:-}"
    TARGET_END="$DEF_TARGET_END"; WIN_HOURS="$DEF_WIN_HOURS"; WEEKS_BACK="$DEF_WEEKS_BACK"
    TOP_N="$DEF_TOP_N"; INST_NUM="$DEF_INST_NUM"; STEP="$DEF_STEP"; STEP_UNIT="$DEF_STEP_UNIT"
    TEMPLATE="$DEF_TEMPLATE"; DEBUG="$DEF_DEBUG"; MARKER_FILE="$DEF_MARKER_FILE"

    echo "${BOLD}AWR timeline comparison — interactive configurator${RST}"
    echo "${DIM}Press Enter to accept the [default] shown for each question.  Ctrl-C to abort.${RST}"
    echo

    while true; do
        echo "${BOLD}-- Connection --${RST}"
        echo "${DIM}user/pw@svc, a TNS alias, or / for OS authentication (then run as SYSDBA${RST}"
        echo "${DIM}via your environment).  Note: a password here ends up in the printed command.${RST}"
        prompt_value CONN "Database connect string" "$CONN" v_nonempty

        echo
        echo "${BOLD}-- Comparison windows --${RST}"
        echo "${DIM}AUTO ends each report at the prior full hour.  Or pin an explicit end,${RST}"
        echo "${DIM}e.g. 2026-04-15 09:00 (24-hour clock).${RST}"
        prompt_value TARGET_END "Window end (AUTO or 'YYYY-MM-DD HH24:MI')" "$TARGET_END" v_target_end
        prompt_value WIN_HOURS  "Window width in hours" "$WIN_HOURS" v_posint

        choose_cadence

        echo
        prompt_value WEEKS_BACK "Number of prior windows to compare against" "$WEEKS_BACK" v_posint

        echo
        echo "${BOLD}-- Detail & scope --${RST}"
        prompt_value TOP_N    "Top-N rows per ranking (Top SQL / waits)" "$TOP_N" v_posint
        echo "${DIM}RAC: 0 aggregates across all instances; >0 filters to that instance.${RST}"
        prompt_value INST_NUM "RAC instance number (0 = aggregate)" "$INST_NUM" v_nonneg

        choose_template

        echo
        echo "${BOLD}-- Extras --${RST}"
        prompt_yesno DEBUG "Print per-section progress markers to stdout?" "$DEBUG"
        prompt_marker

        print_summary

        local action
        prompt_value action "${BOLD}Now what?${RST} [r]un it / re-[e]dit / [q]uit (keep the commands above)" "r"
        case "$action" in
            [Rr]|[Rr][Uu][Nn])
                echo
                echo "Running the report${DEBUG:+ }$([[ "$DEBUG" == Y ]] && echo '(progress markers below)')..."
                local rc=0
                if run_report "$CONN" "$TARGET_END" "$WIN_HOURS" "$WEEKS_BACK" "$TOP_N" \
                               "$INST_NUM" "$STEP" "$STEP_UNIT" "$TEMPLATE" "$DEBUG" "$MARKER_FILE"; then
                    rc=0
                else
                    rc=$?
                fi
                if [[ "$rc" -eq 0 ]]; then
                    local newest
                    newest="$(ls -t "$SCRIPT_DIR"/reports/*.html 2>/dev/null | head -1 || true)"
                    if [[ -n "$newest" ]]; then
                        echo "${BOLD}Done.${RST} Newest report: $newest"
                    else
                        echo "${BOLD}Done.${RST} See the reports/ directory."
                    fi
                else
                    echo "sqlplus exited with status $rc — see the messages above." >&2
                fi
                return "$rc"
                ;;
            [Qq]|[Qq][Uu][Ii][Tt])
                echo "Not run.  Re-use either block above whenever you like."
                return 0
                ;;
            *)  # anything else: re-edit (loop), reusing current answers as defaults
                echo
                echo "${DIM}-- editing again; current answers are the new defaults --${RST}"
                ;;
        esac
    done
}

# ===========================================================================
# Dispatch
# ===========================================================================
case "${1:-}" in
    -c|--configure|-i|--interactive|configure)
        configure
        exit $?
        ;;
    -h|--help)
        usage
        exit 0
        ;;
    '')
        # No arguments: offer the configurator at an interactive terminal,
        # otherwise preserve the original "print usage, exit 1" contract.
        if [[ -t 0 && -t 1 ]]; then
            printf 'No arguments given.  Launch the interactive configurator? %s[Y/n]%s: ' "$DIM" "$RST"
            if IFS= read -r _ans && [[ ! "${_ans:-}" =~ ^[Nn] ]]; then
                configure
                exit $?
            fi
        fi
        usage
        exit 1
        ;;
esac

# ---- positional (non-interactive) path -------------------------------------
CONN="$1"
TARGET_END="${2:-$DEF_TARGET_END}"
WIN_HOURS="${3:-$DEF_WIN_HOURS}"
WEEKS_BACK="${4:-$DEF_WEEKS_BACK}"
TOP_N="${5:-$DEF_TOP_N}"
INST_NUM="${6:-$DEF_INST_NUM}"
STEP="${7:-$DEF_STEP}"
STEP_UNIT="${8:-$DEF_STEP_UNIT}"
TEMPLATE="${9:-$DEF_TEMPLATE}"
DEBUG="${10:-$DEF_DEBUG}"
MARKER_FILE="${11:-$DEF_MARKER_FILE}"

run_report "$CONN" "$TARGET_END" "$WIN_HOURS" "$WEEKS_BACK" "$TOP_N" \
           "$INST_NUM" "$STEP" "$STEP_UNIT" "$TEMPLATE" "$DEBUG" "$MARKER_FILE"
