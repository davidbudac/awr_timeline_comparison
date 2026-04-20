#!/usr/bin/env bash
#
# Convenience wrapper around awr_trend.sql.
# Usage:
#   ./run_awr_trend.sh <connect_string> [target_end] [win_hours] [weeks_back] [top_n] [inst_num]
#
# Examples:
#   ./run_awr_trend.sh user/pw@svc
#   ./run_awr_trend.sh user/pw@svc '2026-04-15 09:00' 1 4 10 0
#   ./run_awr_trend.sh / '2026-04-15 09:00'               # connect / as sysdba
#
set -euo pipefail

if [[ $# -lt 1 ]]; then
    sed -n '1,12p' "$0"
    exit 1
fi

CONN="$1"
TARGET_END="${2:-AUTO}"
WIN_HOURS="${3:-1}"
WEEKS_BACK="${4:-4}"
TOP_N="${5:-10}"
INST_NUM="${6:-0}"

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
@@awr_trend.sql
EXIT
EOF
