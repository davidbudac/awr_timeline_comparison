#!/usr/bin/env bash
# fake_bin/run_awr_fleet.sh -- test double for the real run_awr_fleet.sh,
# used only by server/tests. It honors the same positional argv layout and
# emits stdout in the same summary format (see run_awr_fleet.sh:1053-1059)
# closely enough for server/app/runner.py + records.py to be exercised
# end-to-end without a database. Matches the real wrapper's per-run folder
# output layout: reports/awr_fleet_<ts>_run<id>/index.html plus one
# detail_<alias>.html per detail-flagged DB, in the same folder.
#
# Test knobs (env vars):
#   FAKE_SLEEP                  seconds to sleep before doing anything (tests
#                                the max_run_minutes wall-clock clamp)
#   FAKE_RC                     force this exit code regardless of computed
#                                OK/ERROR counts
#   FAKE_FORCE_ERROR_ALIASES    comma-separated aliases to emit as ERROR rows
#   FAKE_DETAIL_FAIL_ALIASES    comma-separated aliases whose detail run
#                                should report detail=failed instead of ok
#   FAKE_RUN_ID                 override the generated RUN_ID (deterministic
#                                report/detail filenames in tests)
#   FLEET_DETAIL                all|none|'' -- same override semantics as
#                                the real wrapper
set -uo pipefail

CONF="${1:-}"

if [[ -z "$CONF" || ! -r "$CONF" ]]; then
    echo "error: fleet.conf '$CONF' does not exist or is not readable." >&2
    exit 2
fi

if [[ -n "${FAKE_SLEEP:-}" ]]; then
    sleep "$FAKE_SLEEP"
fi

RUN_ID="${FAKE_RUN_ID:-$(date +%Y%m%d%H%M%S)$$}"
REPORT_TS="$(date +%Y%m%d%H%M)"
RUN_DIR="reports/awr_fleet_${REPORT_TS}_run${RUN_ID}"
mkdir -p "$RUN_DIR"
REPORT="$RUN_DIR/index.html"

IFS=',' read -r -a FORCE_ERR <<< "${FAKE_FORCE_ERROR_ALIASES:-}"
IFS=',' read -r -a FORCE_DETAIL_FAIL <<< "${FAKE_DETAIL_FAIL_ALIASES:-}"

is_in() {
    local needle="$1"; shift
    local x
    for x in "$@"; do [[ "$x" == "$needle" ]] && return 0; done
    return 1
}

n_ok=0
n_err=0
SUMMARY_LINES=()

while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    [[ -z "${line//[[:space:]]/}" ]] && continue
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ "$line" != *'|'* ]] && continue
    db_alias="${line%%|*}"
    rest="${line#*|}"
    db_alias="$(printf '%s' "$db_alias" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"

    detail_flag='N'
    if [[ "$rest" =~ ^(.*)\|[[:space:]]*[Dd][Ee][Tt][Aa][Ii][Ll][[:space:]]*$ ]]; then
        detail_flag='Y'
    fi
    case "${FLEET_DETAIL:-}" in
        [Aa][Ll][Ll]) detail_flag='Y' ;;
        [Nn][Oo][Nn][Ee]) detail_flag='N' ;;
    esac

    if is_in "$db_alias" "${FORCE_ERR[@]}"; then
        n_err=$((n_err + 1))
        dstat='-'
        [[ "$detail_flag" == 'Y' ]] && dstat='skipped'
        SUMMARY_LINES+=("$(printf '%-24s ERROR  rc=%-5s detail=%-7s %s' "$db_alias" "1" "$dstat" "simulated failure for $db_alias")")
        continue
    fi

    n_ok=$((n_ok + 1))
    dstat='-'
    if [[ "$detail_flag" == 'Y' ]]; then
        if is_in "$db_alias" "${FORCE_DETAIL_FAIL[@]}"; then
            dstat='failed'
        else
            dstat='ok'
            dfile="${RUN_DIR}/detail_${db_alias}.html"
            printf '<html><body>fake detail report for %s</body></html>\n' "$db_alias" > "$dfile"
        fi
    fi
    SUMMARY_LINES+=("$(printf '%-24s OK     score=%-4s crit=%s warn=%s suppressed=%s topsql_n=%s topsql_pts=%s detail=%s' "$db_alias" "3" "0" "1" "0" "2" "3" "$dstat")")
done < "$CONF"

printf '<html><body>fake fleet report run %s</body></html>\n' "$RUN_ID" > "$REPORT"

for l in "${SUMMARY_LINES[@]}"; do
    printf '%s\n' "$l"
done
echo "Report: $REPORT"

if [[ -n "${FAKE_RC:-}" ]]; then
    exit "$FAKE_RC"
fi
if [[ "$n_ok" -ge 1 ]]; then
    exit 0
fi
exit 3
