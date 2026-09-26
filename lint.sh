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
# A finding raised inside a `... | while read` loop runs in a subshell, where
# fail=1 is lost; the flag file carries it back to the final exit code.
failflag=$(mktemp "${TMPDIR:-/tmp}/awr_lint.XXXXXX") || exit 2
trap 'rm -f "$failflag"' EXIT
finding() {                     # finding <check-name> <file:line-ish> <message>
    printf 'LINT [%s] %s\n    %s\n' "$1" "$2" "$3"
    fail=1
    echo x >> "$failflag"
}

# All SQL*Plus-parsed sources (the driver + every section/lib/template file).
sql_files() {
    printf '%s\n' awr_trend.sql sql/defaults.sql awr_fleet_extract.sql
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

# 3b. Tilde followed by a DIGIT (e.g. a stray '~6x' or '~24000' in a comment).
#     Under SET DEFINE '~' these read as undefined positional params (~1, ~2,
#     ...) and hang the run at a prompt -> SP2-0546/EOF, silently truncating
#     the section.  The ONLY legitimate ~digit is marker.sql's ~1/~2 positional
#     params (it runs under SET DEFINE '~' by design), so exclude just that file.
while IFS= read -r hit; do
    file=${hit%%:*}
    case "$file" in */lib/marker.sql) continue ;; esac
    rest=${hit#*:}; lineno=${rest%%:*}
    finding stray-tilde-digit "$file:$lineno" \
        "'~<digit>' reads as an undefined positional param under SET DEFINE '~' and hangs the run (write the number out in prose, e.g. 'up to 6x')"
done < <(sql_files | xargs grep -noE '~[0-9]' 2>/dev/null)

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
done < <(grep -nE '\*[[:space:]]*7\b|\b7[[:space:]]*\*' sql/[0-9][0-9]_*.sql sql/fleet/[0-9][0-9]_*.sql sql/lib/windows_cte.sql 2>/dev/null | grep -vE '^[^:]+:[0-9]+:[[:space:]]*--')

# ----------------------------------------------------------------------
# 7. Every numbered section must pin SET DEFINE '~' (they are @@-included
#    into a session where '&' may have been restored).
# ----------------------------------------------------------------------
for f in sql/[0-9][0-9]_*.sql sql/fleet/[0-9][0-9]_*.sql; do
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

# ----------------------------------------------------------------------
# 9. LISTAGG drops NULL measures outright -- no token, no delimiter -- so
#    aggregating a nullable token as LISTAGG(CASE ... THEN '' ...) left-
#    compacts the positional per-week CSV and silently shifts every later
#    slot (values render under the wrong week; chart points drift to the
#    wrong window).  Emitters must fold the delimiter into the measure:
#    SUBSTR(LISTAGG(','||token) WITHIN GROUP (...), 2).  A non-null
#    sentinel token like THEN 'null' is fine.  See sql/lib/nth_csv.plsql.
# ----------------------------------------------------------------------
while IFS= read -r loc; do
    finding listagg-null-token "$loc" \
        "nullable LISTAGG token ('' is NULL; LISTAGG drops it and its delimiter, misaligning the positional CSV); use SUBSTR(LISTAGG(','||token) ..., 2) -- see sql/lib/nth_csv.plsql"
done < <(sql_files | xargs grep -n -A4 'LISTAGG *(' /dev/null 2>/dev/null \
         | grep "THEN ''" | sed -E 's/^([^:-]+)[:-]([0-9]+)[:-].*/\1:\2/' | sort -u)

# ----------------------------------------------------------------------
# 10. The bash wrappers run on AIX/Solaris DB hosts, where GNU-only tool
#     flags fail -- often silently when stderr is discarded.  Bit us twice
#     (2026-07-22): grep -oE broke FLEET-COUNTS scoring, then
#     find -maxdepth/-print0 broke the detail-report harvest ("found 0"
#     with the report sitting right there).  dbmint has GNU coreutils and
#     will NEVER surface this class.  Flag: grep -o, sed -E/-r,
#     find -maxdepth/-mindepth/-print0, date -d outside the guarded probe
#     idiom (a line that self-tests `date -d "2000-01-01 ..."` first is
#     allowed), and tar -z/-j/-J (AIX 7.2 tar has no compression flag at
#     all -- use tar piped through gzip instead, see the ARCHIVE/
#     FLEET_ARCHIVE archive_report / archive_fleet_run helpers for the
#     pattern).  Comment lines are skipped.
# ----------------------------------------------------------------------
while IFS= read -r hit; do
    finding gnu-only-flag "${hit%%:*}:$(cut -d: -f2 <<<"$hit")" \
        "GNU-only flag or unsupported tar compression flag in a bash wrapper (breaks on AIX/Solaris find/grep/sed/date, or AIX tar, which has no -z/-j/-J at all; use POSIX flags, bash =~, a plain glob, or tar piped through gzip)"
done < <(grep -nE 'grep +(-[A-Za-z]+ +)*-[A-Za-z]*o|sed +(-[a-z]+ +)*-[Er]\b|find +[^|;]*-(maxdepth|mindepth|print0)|date +-d\b|\btar\b[[:space:]]+-?[A-Za-z]*[zjJ][A-Za-z]*\b' \
             run_awr_fleet.sh run_awr_trend.sh 2>/dev/null \
         | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' \
         | grep -vF '2000-01-01')

# ----------------------------------------------------------------------
# 11. Fleet detail-report links must stay bare relative names inside the
#     per-run folder (detail_<alias>.html), never the old flat
#     awr_fleet_detail_<alias>_run<id>.html naming or a reports/-prefixed
#     href -- either would break the folder's relocatability (CLAUDE.md
#     "Fleet report" per-run-folder layout).
# ----------------------------------------------------------------------
while IFS= read -r hit; do
    finding fleet-detail-href "${hit%%:*}:$(cut -d: -f2 <<<"$hit")" \
        "old flat 'awr_fleet_detail_<alias>_run<id>' naming reappeared in run_awr_fleet.sh -- detail report paths/hrefs must use the per-run folder's bare 'detail_<alias>.html'"
done < <(grep -n 'awr_fleet_detail_' run_awr_fleet.sh 2>/dev/null)

while IFS= read -r hit; do
    finding fleet-detail-href-prefix "${hit%%:*}:$(cut -d: -f2 <<<"$hit")" \
        "detail-report href carries a 'reports/' prefix -- it must be a bare relative name so the per-run folder stays relocatable"
done < <(grep -n 'href="reports/' run_awr_fleet.sh 2>/dev/null)

# ----------------------------------------------------------------------
# 12. Every LOAD / METRIC name in every template's target list must have
#     a policy line in sql/lib/metric_policy.plsql (family / direction /
#     floors); an unmapped name falls through to the generic default and
#     never folds or gets a direction.
# ----------------------------------------------------------------------
for d in sql/lib/templates/*/; do
    for t in sysstat_load_targets sysmetric_targets; do
        f="$d$t.sql"
        [ -f "$f" ] || continue
        while IFS= read -r name; do
            [ -n "$name" ] || continue
            if ! grep -qF "WHEN '$name'" sql/lib/metric_policy.plsql; then
                finding metric-policy "$f" \
                    "target name '$name' has no line in sql/lib/metric_policy.plsql (add a WHEN 'name' THEN RETURN pol(...) line)"
            fi
        done < <(sed -n "s/^[[:space:]]*SELECT '\([^']*\)'.*/\1/p" "$f")
    done
done

# ----------------------------------------------------------------------
# 13. sql/lib/score_cells.plsql calls policy_bucket(), so every file that
#     includes it must include sql/lib/metric_policy.plsql first.
# ----------------------------------------------------------------------
for f in $(grep -l '@@sql/lib/score_cells.plsql' sql/*.sql sql/fleet/*.sql awr_fleet_extract.sql 2>/dev/null); do
    a=$(grep -n '@@sql/lib/metric_policy.plsql' "$f" | head -1 | cut -d: -f1)
    b=$(grep -n '@@sql/lib/score_cells.plsql' "$f" | head -1 | cut -d: -f1)
    if [ -z "$a" ] || [ "$a" -gt "$b" ]; then
        finding policy-include-order "$f:${b:-0}" \
            "sql/lib/score_cells.plsql is included without sql/lib/metric_policy.plsql before it (policy_bucket would be undefined)"
    fi
done

# ----------------------------------------------------------------------
# 14. PL/SQL forbids a variable / TYPE declaration AFTER a subprogram in
#     the same DECLARE section (PLS-00103 "expecting begin function pragma
#     procedure").  Every sql/lib/*.plsql include declares subprograms, so
#     inside a top-level DECLARE ... BEGIN block nothing that looks like a
#     declaration may follow the first such include or FUNCTION/PROCEDURE.
#     Bit 00/02/03/07/17 live on dbmint (v1.5.0).
# ----------------------------------------------------------------------
for f in $(sql_files); do
    awk -v file="$f" '
        /^DECLARE[[:space:]]*$/ { inblk=1; seen=0; next }
        /^BEGIN[[:space:]]*$/   { inblk=0; next }
        inblk {
            ind = match($0, /[^ ]/) - 1
            if (ind > 4 || $0 ~ /^[[:space:]]*--/) next
            if ($0 ~ /^[[:space:]]*(FUNCTION|PROCEDURE)[[:space:]]/ || $0 ~ /^[[:space:]]*@@sql\/lib\/[^ ]*\.plsql/) {
                if (!seen) seen = NR; next
            }
            if (seen && $0 ~ /^[[:space:]]+(TYPE[[:space:]]|[A-Za-z_][A-Za-z0-9_]*[[:space:]]+(CONSTANT[[:space:]]+)?(NUMBER|VARCHAR2|PLS_INTEGER|BINARY_INTEGER|BOOLEAN|DATE|TIMESTAMP|CLOB|[A-Za-z_]+_t|[A-Za-z_]+_rec|[A-Za-z_]+_tab)[[:space:](;])/) {
                printf "%s:%d: declaration after a subprogram (first subprogram/include at line %d)\n", file, NR, seen
            }
        }' "$f" | while IFS= read -r line; do
        finding plsql-decl-order "${line%%: *}" "${line#*: }"
    done
done

# ----------------------------------------------------------------------
# 15. Oracle reserved words used as PL/SQL identifiers / SQL aliases.
#     SHARE (LOCK TABLE ... IN SHARE MODE) bit the findings record on dbmint.
# ----------------------------------------------------------------------
for f in $(sql_files); do
    grep -n -i -E '(^[[:space:]]+share[[:space:]]+(NUMBER|VARCHAR2|PLS_INTEGER)|[[:space:]]AS[[:space:]]+share[[:space:]]*(,|$)|\.share\)|,[[:space:]]*share[[:space:]]*(,|$))' "$f" \
      | grep -v -- '--' | while IFS= read -r line; do
        finding reserved-word "$f:${line%%:*}" "'share' is an Oracle reserved word; use 'shr' (${line#*:})"
    done
done

# ----------------------------------------------------------------------
# 16. sql/lib/metric_policy.plsql opens with a TYPE (policy_rec), which
#     PL/SQL forbids after any subprogram -- so in every DECLARE block it
#     must be the FIRST subprogram-declaring item (before any inline
#     FUNCTION/PROCEDURE and before every other sql/lib/*.plsql include),
#     and after every plain variable (check 14).
# ----------------------------------------------------------------------
for f in $(grep -l '@@sql/lib/metric_policy.plsql' $(sql_files) 2>/dev/null); do
    awk -v file="$f" '
        /^DECLARE[[:space:]]*$/ { inblk=1; first=0; next }
        /^BEGIN[[:space:]]*$/   { inblk=0; next }
        inblk && (match($0, /[^ ]/) - 1) <= 4 && ($0 ~ /^[[:space:]]*(FUNCTION|PROCEDURE)[[:space:]]/ || $0 ~ /^[[:space:]]*@@sql\/lib\/[^ ]*\.plsql/) {
            if (!first) first = NR
            if ($0 ~ /metric_policy\.plsql/ && first != NR)
                printf "%s:%d: sql/lib/metric_policy.plsql must precede the first FUNCTION/PROCEDURE/.plsql include of its DECLARE block (line %d)\n", file, NR, first
        }' "$f" | while IFS= read -r line; do
        finding policy-include-first "${line%%: *}" "${line#*: }"
    done
done

# ----------------------------------------------------------------------
# 17. sql/lib/band_glyph.plsql calls fmt_num() (normal-range text), and
#     sql/lib/score_cells.plsql delegates to band_cells(): in every file
#     fmt_num must be included before band_glyph, and band_glyph before
#     score_cells (else PLS-00313 at compile time on the DB).
# ----------------------------------------------------------------------
for f in $(grep -l -E '@@sql/lib/(band_glyph|score_cells)\.plsql' $(sql_files) 2>/dev/null); do
    fn=$(grep -n '@@sql/lib/fmt_num.plsql' "$f" | head -1 | cut -d: -f1)
    bg=$(grep -n '@@sql/lib/band_glyph.plsql' "$f" | head -1 | cut -d: -f1)
    sc=$(grep -n '@@sql/lib/score_cells.plsql' "$f" | head -1 | cut -d: -f1)
    if [ -n "$sc" ] && { [ -z "$bg" ] || [ "$bg" -gt "$sc" ]; }; then
        finding band-include-order "$f:$sc" "sql/lib/score_cells.plsql needs sql/lib/band_glyph.plsql included before it"
    fi
    if [ -n "$bg" ] && { [ -z "$fn" ] || [ "$fn" -gt "$bg" ]; }; then
        finding band-include-order "$f:$bg" "sql/lib/band_glyph.plsql needs sql/lib/fmt_num.plsql included before it"
    fi
done

# ----------------------------------------------------------------------
# 18. The v1.5.0 Normal / Full view model is retired (v1.6.0): sections
#     declare view membership with class="vw in-s|in-t|in-a" and the chrome
#     keeps the view in localStorage "awr-view".  The old hooks must not
#     come back (they would silently match nothing), nor the dev_bucket
#     heat tint the band glyph replaced.
# ----------------------------------------------------------------------
for f in awr_trend.sql sql/*.sql sql/lib/*.plsql; do
    grep -n -E 'data-normal|full-only|"awr-mode"|data-dev=|dev_attr\(' "$f" | grep -v -E '^[0-9]+:[[:space:]]*--' \
      | while IFS= read -r line; do
        finding retired-view-hook "$f:${line%%:*}" "v1.5.0 view hook (data-normal / full-only / awr-mode / data-dev) -- use class=\"vw in-s|in-t|in-a\" (CLAUDE.md, views)"
    done
done

# ----------------------------------------------------------------------
# 19. Every report <section> opts into its views explicitly: a numbered
#     section must carry class="vw ..." (or be one of the view-less
#     reference sections, guide / about, shown in every view).
# ----------------------------------------------------------------------
for f in sql/[0-9]*.sql; do
    grep -n "<section id=" "$f" | grep -v 'class="vw ' | grep -v -E 'id="(guide|about)"' \
      | while IFS= read -r line; do
        finding section-view-class "$f:${line%%:*}" "<section> without class=\"vw in-s|in-t|in-a\" -- declare which views show it"
    done
done

# ----------------------------------------------------------------------
# 20. sql/lib/wingrid.plsql (the window component) and
#     sql/lib/finding_cards.plsql (Summary vocabulary) call fmt_num(): in
#     every file that includes either, fmt_num must come first (else
#     PLS-00313 at compile time on the DB).
# ----------------------------------------------------------------------
for f in $(grep -l -E '@@sql/lib/(wingrid|finding_cards)\.plsql' $(sql_files) 2>/dev/null); do
    fn=$(grep -n '@@sql/lib/fmt_num.plsql' "$f" | head -1 | cut -d: -f1)
    for lib in wingrid finding_cards; do
        ln=$(grep -n "@@sql/lib/$lib.plsql" "$f" | head -1 | cut -d: -f1)
        if [ -n "$ln" ] && { [ -z "$fn" ] || [ "$fn" -gt "$ln" ]; }; then
            finding summary-include-order "$f:$ln" "sql/lib/$lib.plsql needs sql/lib/fmt_num.plsql included before it"
        fi
    done
done

# ----------------------------------------------------------------------
# 21. Entity links (a.ent, v1.6.0) have ONE emitter, ent() in
#     sql/lib/finding_cards.plsql, fed an id from sql/lib/anchor_id.plsql
#     (anchor_id / finding_anchor), so a link and its target row can never
#     drift.  A hand-written class="ent" anywhere else is flagged.
# ----------------------------------------------------------------------
for f in awr_trend.sql sql/*.sql sql/lib/*.plsql; do
    [ "$f" = "sql/lib/finding_cards.plsql" ] && continue
    grep -n 'class="ent"' "$f" | grep -v -E '^[0-9]+:[[:space:]]*--' \
      | while IFS= read -r line; do
        finding ent-emitter "$f:${line%%:*}" "hand-written class=\"ent\" -- use ent(html, anchor_id(kind, name), kind) (sql/lib/finding_cards.plsql)"
    done
done

# ----------------------------------------------------------------------
# 22. sql/lib/timeline.plsql (the Timeline view's grid rows) calls
#     fmt_num, band_glyph (band_z / band_span / delta_span), ent() from
#     finding_cards and wg_tok / wg_date from wingrid: in every file that
#     includes it, all five must come first (else PLS-00313 at compile
#     time on the DB), anchor_id too (its callers build the row ids).
# ----------------------------------------------------------------------
for f in $(grep -l '@@sql/lib/timeline.plsql' $(sql_files) 2>/dev/null); do
    tl=$(grep -n '@@sql/lib/timeline.plsql' "$f" | head -1 | cut -d: -f1)
    for lib in fmt_num band_glyph anchor_id finding_cards wingrid; do
        ln=$(grep -n "@@sql/lib/$lib.plsql" "$f" | head -1 | cut -d: -f1)
        if [ -z "$ln" ] || [ "$ln" -gt "$tl" ]; then
            finding timeline-include-order "$f:$tl" "sql/lib/timeline.plsql needs sql/lib/$lib.plsql included before it"
        fi
    done
done

# ----------------------------------------------------------------------
# 23. A Timeline lane source (tl_open) must be closed (tl_close) in the
#     same file, and never be emitted inside a table: the inert
#     <template> would still parse, but a <script> in a <tbody> is easy to
#     misplace.  Cheap proxy: every file with tl_open( has tl_close.
# ----------------------------------------------------------------------
for f in $(grep -l "tl_open(" sql/[0-9]*.sql 2>/dev/null); do
    if ! grep -q "tl_close" "$f"; then
        finding timeline-source "$f" "tl_open(...) without tl_close -- the lane's rows never leave their <template>"
    fi
done

# ----------------------------------------------------------------------
# 24. Generated client scripts must match their readable source.  The
#     PUT_LINE bodies of sql/lib/js_timeline.plsql and js_wingrid.plsql
#     are generated from sql/lib/src/<name>.js by tools/js2plsql.sh (also
#     rejects a tilde or an over-long line); edit the .js and regenerate.
# ----------------------------------------------------------------------
if ! sh tools/js2plsql.sh --check >/dev/null 2>"${TMPDIR:-/tmp}/lint_js2plsql.$$"; then
    while IFS= read -r l; do
        finding generated-js "tools/js2plsql.sh" "$l"
    done < "${TMPDIR:-/tmp}/lint_js2plsql.$$"
fi
rm -f "${TMPDIR:-/tmp}/lint_js2plsql.$$"

# ----------------------------------------------------------------------
# 25. No non-ASCII byte in anything the single-DB report emits.  SQL*Plus
#     converts PUT_LINE text to the client character set, and on a client
#     that is not UTF-8 (dbmint's) every multi-byte character arrives as
#     "?" -- phase 3/4 shipped literal dashes / triangles in js_timeline
#     and the Timeline's skipped-window cells read "???".  Use an HTML
#     entity (&ndash; &sigma;) in markup and a \uXXXX escape in JS.
#     Comment lines (--) are exempt; the fleet files are out of scope.
# ----------------------------------------------------------------------
for f in awr_trend.sql sql/[0-9]*.sql sql/_style.sql sql/lib/*.plsql sql/lib/src/*.js; do
    [ -f "$f" ] || continue
    LC_ALL=C grep -n "$(printf '[\200-\377]')" "$f" | grep -v -E '^[0-9]+:[[:space:]]*(--|//)' \
      | while IFS= read -r line; do
        finding non-ascii "$f:${line%%:*}" "non-ASCII character in emitted text -- use an HTML entity (markup) or a \\uXXXX escape (JS); non-UTF-8 SQL*Plus clients print ?"
    done
done

[ -s "$failflag" ] && fail=1
if [ "$fail" -eq 0 ]; then
    echo "lint: clean ($(sql_files | wc -l | tr -d ' ') files checked)"
fi
exit "$fail"
