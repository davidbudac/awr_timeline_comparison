#!/bin/sh
#
# sql/fleet/src/fleet_js2plsql.sh -- fleet-owned twin of tools/js2plsql.sh
# for the fleet's generated client files (the fleet may not edit the
# single-DB tool, see CLAUDE.md "Fleet report"):
#
#   sql/fleet/src/js_fleet_coanom.js   -> sql/fleet/js_fleet_coanom.plsql
#   sql/fleet/src/css_fleet_coanom.css -> sql/fleet/css_fleet_coanom.plsql
#
# Same rules and output shape as tools/js2plsql.sh: the header comment
# above the BEGIN line of the .plsql is kept, the body is rewritten as one
# PUT_LINE per non-blank source line wrapped in <script> / <style>, single
# quotes doubled; a tilde or a line of 2300+ characters is rejected.
#
# Usage:  sh sql/fleet/src/fleet_js2plsql.sh [--check]
# Dev-time only; POSIX sh + awk, no GNU-only flags.
#
set -u
cd "$(dirname "$0")/../../.." || exit 2
check=0
[ "${1:-}" = "--check" ] && check=1
rc=0
for pair in "js_fleet_coanom.js:script" "css_fleet_coanom.css:style"; do
    f=${pair%%:*}; tag=${pair#*:}
    src="sql/fleet/src/$f"; dst="sql/fleet/${f%.*}.plsql"
    if [ ! -f "$src" ] || [ ! -f "$dst" ]; then echo "fleet_js2plsql: missing $src or $dst" >&2; rc=2; continue; fi
    if grep -n '~' "$src" >&2; then echo "fleet_js2plsql: $src contains a tilde" >&2; rc=2; continue; fi
    tmp="${TMPDIR:-/tmp}/fleet_js2plsql.$$"
    {
        awk '/^BEGIN$/ {exit} {print}' "$dst"
        printf '%s\n' 'BEGIN' "    DBMS_OUTPUT.PUT_LINE('<$tag>');"
        awk -v src="$src" '
            /^[ \t]*$/ { next }
            length($0) >= 2300 { printf "fleet_js2plsql: %s:%d is %d chars (limit 2299)\n", src, NR, length($0) > "/dev/stderr"; bad = 1; next }
            { s = $0; gsub(/\047/, "\047\047", s); printf "    DBMS_OUTPUT.PUT_LINE(\047%s\047);\n", s }
            END { if (bad) exit 2 }
        ' "$src" || { rc=2; rm -f "$tmp"; continue; }
        printf '%s\n' "    DBMS_OUTPUT.PUT_LINE('</$tag>');" 'END;' '/'
    } > "$tmp"
    if [ "$check" -eq 1 ]; then
        cmp -s "$tmp" "$dst" || { echo "fleet_js2plsql: $dst is stale (run sh $0)" >&2; rc=1; }
        rm -f "$tmp"
    else
        mv "$tmp" "$dst"
    fi
done
exit $rc
