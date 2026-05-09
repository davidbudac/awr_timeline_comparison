#!/usr/bin/env bash
#
# Convenience wrapper around awr_trend.sql.
# Usage:
#   ./run_awr_trend.sh <connect_string> [target_end] [win_hours] [weeks_back] \
#                      [top_n] [inst_num] [step] [step_unit]
#
# step / step_unit set the cadence between comparison windows.  Defaults
# step=1, step_unit=w reproduce the original "same hour-of-week, N prior
# weeks" behaviour.  step_unit is one of: h (hours), d (days), w (weeks).
#
# Examples:
#   ./run_awr_trend.sh user/pw@svc
#   ./run_awr_trend.sh user/pw@svc '2026-04-15 09:00' 1 4 10 0
#   ./run_awr_trend.sh / '2026-04-15 09:00'                   # connect / as sysdba
#   # Last 4 consecutive 1-hour windows ending at the prior full hour:
#   ./run_awr_trend.sh user/pw@svc AUTO 1 4 10 0 1 h
#   # Every other day for the past 7 days:
#   ./run_awr_trend.sh user/pw@svc AUTO 1 7 10 0 2 d
#
set -euo pipefail

if [[ $# -lt 1 ]]; then
    sed -n '1,20p' "$0"
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
@@awr_trend.sql
EXIT
EOF
