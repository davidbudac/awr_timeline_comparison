#!/usr/bin/env bash
#
# lint.sh -- static checks for the SQL*Plus footguns documented in CLAUDE.md.
#
# Every check here encodes a "Things NOT to do" rule or a gotcha that has
# actually bitten a session: bad @@ include paths, stray tilde substitutions
# (which hang the run at an "Enter value for ..." prompt), flat template
# includes, dbid equality instead of dbid_list membership, leading-underscore
# SQL identifiers (ORA-00911), and the literal 7 as cadence multiplier.
#
# Pure grep/awk -- no database needed. Exit 0 = clean, 1 = findings.
# Run from anywhere; it cd's to the repo root.

set -uo pipefail
cd "$(dirname "$0")"

fail=0
finding() {                     # finding <check-name> <file:line-ish> <message>
    printf 'LINT [%s] %s\n    %s\n' "$1" "$2" "$3"
    fail=1
}

# All SQL*Plus-parsed sources (the driver + every section/lib/template file).
sql_files() {
    printf '%s\n' awr_trend.sql sql/defaults.sql
    find sql -type f \( -name '*.sql' -o -name '*.plsql' \) | sort
}

# ----------------------------------------------------------------------
# 1. @@ include paths.  Nested @@ resolves against the OUTERMOST caller
#    (the driver at project root), so only @@sql/... and the two resolved
#    substitution forms are legal.  @@lib/... or @@../... silently include
#    the wrong file (or nothing).
# ----------------------------------------------------------------------
while IFS= read -r hit; do
    file=${hit%%:*}; rest=${hit#*:}; lineno=${rest%%:*}
    inc=$(sed -E 's/^[^:]+:[0-9]+:[[:space:]]*//' <<<"$hit")
    case "$inc" in
        @@sql/*|@@~template_dir/*|@@~marker_include*) : ;;
        *) finding include-path "$file:$lineno" \
             "include '$inc' does not resolve from the project root; use @@sql/lib/<file> or @@~template_dir/<file> (see CLAUDE.md)";;
    esac
done < <(sql_files | xargs grep -nE '^[[:space:]]*@@' /dev/null 2>/dev/null)

# ----------------------------------------------------------------------
# 2. Curated target lists are per-template: a flat @@sql/lib/..._targets.sql
#    bypasses the template mechanism.  Must go through ~template_dir.
# ----------------------------------------------------------------------
while IFS= read -r hit; do
    finding flat-template-include "${hit%%:*}:$(cut -d: -f2 <<<"$hit")" \
        "curated target lists must be included via @@~template_dir/<file>.sql, never a flat sql/lib path"
done < <(sql_files | xargs grep -nE '^[[:space:]]*@@sql/lib/(templates/)?[A-Za-z0-9_]*_targets\.sql' 2>/dev/null)

# ----------------------------------------------------------------------
# 3. Stray tilde substitutions.  Sections run under SET DEFINE '~', so any
#    ~word whose word is not a known DEFINE / COLUMN ... NEW_VALUE variable
#    triggers an interactive "Enter value for ..." prompt that silently
#    truncates the section (or aborts a heredoc run with SP2-0310).
# ----------------------------------------------------------------------
known_vars=$(
    { sql_files | xargs grep -hoiE '^[[:space:]]*DEFINE[[:space:]]+[A-Za-z0-9_]+' 2>/dev/null | awk '{print $2}'
      sql_files | xargs grep -hoiE 'NEW_VALUE[[:space:]]+[A-Za-z0-9_]+'            2>/dev/null | awk '{print $2}'
    } | tr '[:upper:]' '[:lower:]' | sort -u
)
while IFS= read -r hit; do
    file=${hit%%:*}; rest=${hit#*:}; lineno=${rest%%:*}; var=${hit##*:}; var=${var#"~"}
    if ! grep -qx "$(tr '[:upper:]' '[:lower:]' <<<"$var")" <<<"$known_vars"; then
        finding stray-tilde "$file:$lineno" \
            "'~$var' is not a known substitution variable -- a literal tilde here hangs the run at a var prompt (write the tilde out in prose)"
    fi
done < <(sql_files | xargs grep -noE '~[A-Za-z_][A-Za-z0-9_]*' 2>/dev/null)

# ----------------------------------------------------------------------
# 4. AWR filters must use dbid IN (~dbid_list), never equality against the
#    single primary ~dbid (breaks non-CDB -> PDB migrated history).
#    Joins like s.dbid = b.dbid are fine and not matched.
# ----------------------------------------------------------------------
while IFS= read -r hit; do
    finding dbid-equality "${hit%%:*}:$(cut -d: -f2 <<<"$hit")" \
        "AWR filter compares dbid = ~dbid; use dbid IN (~dbid_list) so history spanning a DBID change stays visible"
done < <(sql_files | xargs grep -niE 'dbid[[:space:]]*=[[:space:]]*~dbid\b' 2>/dev/null)

# ----------------------------------------------------------------------
# 5. Leading-underscore SQL identifiers raise ORA-00911 (Oracle identifiers
#    can't start with '_'; DEFINE names like _dbg_msg are fine -- this only
#    checks column aliases and COLUMN commands).
# ----------------------------------------------------------------------
while IFS= read -r hit; do
    finding underscore-identifier "${hit%%:*}:$(cut -d: -f2 <<<"$hit")" \
        "SQL identifier starts with '_' (ORA-00911); rename it (e.g. dbg_ts, not _dbg_ts)"
done < <(sql_files | xargs grep -niE '(\bAS[[:space:]]+_[A-Za-z]|^[[:space:]]*COLUMN[[:space:]]+_[A-Za-z])' 2>/dev/null)

# ----------------------------------------------------------------------
# 6. Cadence must be ~step_hours-driven; a literal 7 as a day/week multiplier
#    silently reintroduces the weekly-only assumption.  Comment lines are
#    skipped; flag arithmetic like "* 7" / "7 *" in the numbered sections.
# ----------------------------------------------------------------------
while IFS= read -r hit; do
    finding literal-7-cadence "${hit%%:*}:$(cut -d: -f2 <<<"$hit")" \
        "literal 7 used as a multiplier; the cadence is ~step_hours/24 (step may be hours/days/weeks)"
done < <(grep -nE '\*[[:space:]]*7\b|\b7[[:space:]]*\*' sql/[0-9][0-9]_*.sql sql/lib/windows_cte.sql 2>/dev/null | grep -vE '^[^:]+:[0-9]+:[[:space:]]*--')

# ----------------------------------------------------------------------
# 7. Every numbered section must pin SET DEFINE '~' (they are @@-included
#    into a session where '&' may have been restored).
# ----------------------------------------------------------------------
for f in sql/[0-9][0-9]_*.sql; do
    grep -qE "^[[:space:]]*SET[[:space:]]+DEFINE[[:space:]]+'~'" "$f" ||
        finding missing-set-define "$f" "section does not SET DEFINE '~'"
done

# ----------------------------------------------------------------------
# 8. Every template dir ships the full trio of target lists (a missing file
#    aborts the run only at include time, deep inside a section).
# ----------------------------------------------------------------------
for d in sql/lib/templates/*/; do
    for t in sysstat_load_targets sysmetric_targets wait_event_targets; do
        [ -f "$d$t.sql" ] || finding template-incomplete "$d" "missing $t.sql"
    done
done

if [ "$fail" -eq 0 ]; then
    echo "lint: clean ($(sql_files | wc -l | tr -d ' ') files checked)"
fi
exit "$fail"
