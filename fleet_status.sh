#!/bin/sh
# fleet_status.sh -- live status of a running fleet report (run_awr_fleet.sh).
#
# Reads only the per-run workdir reports/fleet_work_<id>/ the wrapper writes
# (manifest.tsv, <alias>.rc, <alias>.detail.rc, <alias>.detail.log); never
# touches the database or the wrapper.  POSIX sh, no watch / GNU-only flags,
# so it runs on AIX / Solaris DB hosts too.
#
# Usage: ./fleet_status.sh [--once] [workdir] [interval_seconds]
#   workdir   default: the newest reports/fleet_work_* (relative to this script)
#   interval  default: 30 seconds between refreshes
#   --once    print one table and exit
#
# Per database:
#   extract=running   no <alias>.rc yet (running, or queued behind FLEET_PAR)
#   extract=0 / N     extract done OK / failed with rc N
#   detail=-          not flagged for a detailed report (or the extract failed)
#   detail=running    detailed report running or queued; shows its last
#                     progress marker when the log has one
#   detail=0 / 124 / N / skipped   done OK / timed out / failed / not run
# Stops by itself when every database is done or the workdir disappears (a
# clean run deletes it after assembling the report).

once=0
if [ "${1:-}" = "--once" ]; then once=1; shift; fi
case "${1:-}" in -h|--help) sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;; esac

cd "$(dirname "$0")" || exit 2
W="${1:-}"
if [ -z "$W" ]; then
    W=$(ls -dt reports/fleet_work_* 2>/dev/null | head -1)
    [ -n "$W" ] || { echo "error: no reports/fleet_work_* workdir found (is a fleet run going?)" >&2; exit 2; }
fi
INTERVAL="${2:-30}"
case "$INTERVAL" in ''|*[!0-9]*) echo "error: interval must be a whole number of seconds" >&2; exit 2 ;; esac
[ -f "$W/manifest.tsv" ] || { echo "error: $W/manifest.tsv not found -- not a fleet workdir" >&2; exit 2; }

TAB=$(printf '\t')

show() {
    n=0; ndone=0; nfail=0
    while IFS="$TAB" read -r a disp flag; do
        [ -n "$a" ] || continue
        n=$((n + 1))
        ex=$(cat "$W/$a.rc" 2>/dev/null) || ex=running
        dt=$(cat "$W/$a.detail.rc" 2>/dev/null) || dt=''
        fin=0
        if [ "$ex" = running ]; then
            dt=-
        elif [ "$flag" != Y ] || [ "$ex" != 0 ]; then
            dt=-; fin=1
        elif [ -z "$dt" ]; then
            mk=$(grep '^\[awr_trend ' "$W/$a.detail.log" 2>/dev/null | tail -1)
            dt="running${mk:+: $mk}"
        else
            fin=1
        fi
        [ "$fin" = 1 ] && ndone=$((ndone + 1))
        { [ "$ex" != running ] && [ "$ex" != 0 ]; } && nfail=$((nfail + 1))
        case "$dt" in -|running*|0|skipped) ;; *) nfail=$((nfail + 1)) ;; esac
        printf '%-20s extract=%-8s detail=%s\n' "$a" "$ex" "$dt"
    done < "$W/manifest.tsv"
    echo "-- $ndone/$n done, $nfail failure(s)"
}

while :; do
    if [ ! -d "$W" ]; then echo "workdir $W is gone: the run finished cleanly"; exit 0; fi
    [ "$once" = 1 ] || { clear 2>/dev/null || printf '\n\n'; }
    echo "$(date '+%Y-%m-%d %H:%M:%S')  $W"
    out=$(show)
    printf '%s\n' "$out"
    [ "$once" = 1 ] && exit 0
    case "$out" in
        *"-- "*) last=${out##*-- }; d=${last%%/*}; t=${last#*/}; t=${t%% *}
                 if [ "$d" = "$t" ]; then echo "all databases done (assembling / finished)"; exit 0; fi ;;
    esac
    sleep "$INTERVAL"
done
