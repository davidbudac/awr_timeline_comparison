--
-- sql/lib/anchor_id.plsql
--
-- Local PL/SQL helper that turns a stat / metric / event / class name into
-- a stable HTML id fragment so sections can link to each other's rows:
--   anchor_id('load',   'physical reads')            -> 'load-physical-reads'
--   anchor_id('metric', 'Physical Reads Per Sec')    -> 'metric-physical-reads-per-sec'
--   anchor_id('fg',     'db file sequential read')   -> 'fg-db-file-sequential-read'
--   anchor_id('fgc',    'User I/O')                  -> 'fgc-user-i-o'
-- Lower-cased, every run of non [a-z0-9] collapsed to one '-', leading /
-- trailing '-' trimmed, capped at 64 chars after the prefix.  Emitter and
-- linker must call it with the same prefix + raw name (see the id
-- convention in design/UI_UX_IMPROVEMENT_PLAN.md, phase 3):
--   02 load-<stat>   03 metric-<name>   04 fg-<event> / fgms-<event> / fgc-<class>
--   05 bg-<event> / bgms-<event>   07 find-<domain>-<name>   11 ash-card-<sql_id>
--   18 sqlmon-<sql_id>   06 sql-<sql_id> (pre-existing)
-- Include inside a DECLARE block, before BEGIN (two at-signs +
-- sql/lib/anchor_id.plsql).  Pure string function, no DB access.
--
    FUNCTION anchor_id(p_prefix IN VARCHAR2, p_name IN VARCHAR2) RETURN VARCHAR2 IS
        v VARCHAR2(4000);
    BEGIN
        v := REGEXP_REPLACE(LOWER(NVL(p_name, '')), '[^a-z0-9]+', '-');
        v := REGEXP_REPLACE(v, '^-+|-+$', '');
        RETURN p_prefix || '-' || SUBSTR(v, 1, 64);
    END anchor_id;
