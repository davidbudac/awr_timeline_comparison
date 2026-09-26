#!/bin/sh
#
# tools/js2plsql.sh -- regenerate the PUT_LINE bodies of the generated
# client-side scripts from their readable JavaScript source.
#
#   sql/lib/src/<name>.js   (readable source, edit this)
#     -> sql/lib/<name>.plsql (generated: the header comment block above the
#        BEGIN line is kept as is, everything from BEGIN on is rewritten)
#
# Usage:
#   tools/js2plsql.sh            regenerate every sql/lib/src/*.js
#   tools/js2plsql.sh js_wingrid regenerate one (name without .js)
#   tools/js2plsql.sh --check    exit 1 if a committed .plsql is stale
#                                (lint.sh runs this; no file is written)
#
# Dev-time only: the toolkit itself never runs this (the generated .plsql
# files stay committed, so a report run needs no Python, Node or awk
# beyond what SQL*Plus already has).  POSIX sh + awk, no GNU-only flags.
#
# Rules the generator enforces (each would break the report run):
#   - no tilde anywhere in the JS (SET DEFINE tilde in every section:
#     a stray one prompts "Enter value for" and truncates the output)
#   - no source line of 2300 characters or more (SQL*Plus rejects input
#     lines past 2499 characters, and the PUT_LINE wrapper adds ~30)
#   - blank lines are dropped; single quotes are doubled
#
set -u
cd "$(dirname "$0")/.." || exit 2

check=0
names=""
for a in "$@"; do
    case "$a" in
        --check) check=1 ;;
        *) names="$names $a" ;;
    esac
done
if [ -z "$names" ]; then
    for f in sql/lib/src/*.js; do
        [ -f "$f" ] || continue
        b=$(basename "$f" .js)
        names="$names $b"
    done
fi

gen() {  # $1 = name; writes the generated .plsql to stdout
    src="sql/lib/src/$1.js"
    dst="sql/lib/$1.plsql"
    if [ ! -f "$src" ] || [ ! -f "$dst" ]; then
        echo "js2plsql: missing $src or $dst" >&2
        return 2
    fi
    if grep -n '~' "$src" >&2; then
        echo "js2plsql: $src contains a tilde (SET DEFINE tilde)" >&2
        return 2
    fi
    awk '/^BEGIN$/ {exit} {print}' "$dst"
    printf '%s\n' 'BEGIN' "    DBMS_OUTPUT.PUT_LINE('<script>');"
    awk -v src="$src" '
        /^[ \t]*$/ { next }
        length($0) >= 2300 { printf "js2plsql: %s:%d is %d chars (limit 2299)\n", src, NR, length($0) > "/dev/stderr"; bad = 1; next }
        { s = $0; gsub(/\047/, "\047\047", s); printf "    DBMS_OUTPUT.PUT_LINE(\047%s\047);\n", s }
        END { if (bad) exit 2 }
    ' "$src" || return 2
    printf '%s\n' "    DBMS_OUTPUT.PUT_LINE('</script>');" 'END;' '/'
}

rc=0
tmp="${TMPDIR:-/tmp}/js2plsql.$$"
trap 'rm -f "$tmp"' EXIT
for n in $names; do
    if ! gen "$n" > "$tmp"; then rc=2; continue; fi
    if [ "$check" -eq 1 ]; then
        if ! cmp -s "$tmp" "sql/lib/$n.plsql"; then
            echo "js2plsql: sql/lib/$n.plsql is stale; run tools/js2plsql.sh $n" >&2
            rc=1
        fi
    else
        if cmp -s "$tmp" "sql/lib/$n.plsql"; then
            echo "sql/lib/$n.plsql unchanged"
        else
            cp "$tmp" "sql/lib/$n.plsql" && echo "sql/lib/$n.plsql regenerated"
        fi
    fi
done
exit $rc
