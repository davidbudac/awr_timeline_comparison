#!/usr/bin/env bash
#
# Convenience wrapper around awr_trend.sql.
# Usage:
#   ./run_awr_trend.sh <connect_string> [target_end] [win_hours] [weeks_back] \
#                      [top_n] [inst_num] [step] [step_unit] [template] [debug] \
#                      [marker_file]
#
# step / step_unit set the cadence between comparison windows.  Defaults
# step=1, step_unit=w reproduce the original "same hour-of-week, N prior
# weeks" behaviour.  step_unit is one of: h (hours), d (days), w (weeks).
#
# template selects which set of metrics + wait events to display.
# Defaults to 'comprehensive' (the full curated lists, identical to the
# pre-template behaviour).  'simple' shows a small triage-friendly
# subset.  See sql/lib/templates/<name>/ for the metric/wait lists.
#
# debug = Y prints one-line timestamped progress markers to standard
# output as each section begins (helpful on large DBs where some sections
# take minutes).  The HTML report is unaffected.  Default: N.
#
# marker_file is an optional path to a timeline-marker config file
# (datetime + label milestones drawn as vertical lines on the dated
# charts).  Default: empty (no markers).  See markers.example.sql.
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
#
set -euo pipefail

if [[ $# -lt 1 ]]; then
    sed -n '1,30p' "$0"
    exit 1
fi

CONN="$1"
TARGET_END="${2:-AUTO}"
WIN_HOURS="${3:-1}"
WEEKS_BACK="${4:-4}"
TOP_N="${5:-10}"
INST_NUM="${6:-0}"
STEP="${7:-1}"
STEP_UNIT="${8:-w}"
TEMPLATE="${9:-comprehensive}"
DEBUG="${10:-N}"
MARKER_FILE="${11:-}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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
