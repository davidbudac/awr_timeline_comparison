--
-- sql/lib/is_oracle_schema.plsql
--
-- Local PL/SQL helper that classifies a parsing-schema name as
-- Oracle-maintained ("system") or not.  Used by the SQL-centric sections
-- (06 Top SQL, 11 Top SQL ASH breakdown) to tag each top SQL with a
-- data-sys="Y|N" marker so the report's "Application only" toggle can hide
-- Oracle-internal / recursive SQL (parsed as SYS, SYSTEM, XDB, ...) and
-- leave only genuine application SQL on screen.  No DB access: it is a pure
-- name test against a curated list, so it adds NO grant requirement (a
-- DBA_USERS.ORACLE_MAINTAINED lookup would have).
--
-- Usage: include this file *inside* a section's DECLARE block, BEFORE the
-- BEGIN keyword (exactly like sql/lib/nth_csv.plsql):
--
--   DECLARE
--       ...
--       @@sql/lib/is_oracle_schema.plsql
--   BEGIN
--       ...
--       v_is_sys := is_oracle_schema(v_parsing_schema);   -- 'Y' or 'N'
--       ...
--   END;
--   /
--
-- Returns 'Y' for the well-known Oracle-maintained dictionary / option /
-- infrastructure schemas (and the APEX/FLOWS engine schema families), 'N'
-- otherwise (including NULL input).  Deliberately CONSERVATIVE: an unknown
-- schema is treated as application ('N') so a real app schema is never
-- hidden -- under-filtering merely leaves a little Oracle noise visible,
-- whereas over-filtering would suppress genuine application behaviour.
--
    FUNCTION is_oracle_schema(p_schema IN VARCHAR2) RETURN VARCHAR2 IS
        v_s VARCHAR2(128);
    BEGIN
        IF p_schema IS NULL THEN
            RETURN 'N';
        END IF;
        v_s := UPPER(TRIM(p_schema));
        IF v_s IN (
               'SYS','SYSTEM','SYSAUX','SYSBACKUP','SYSDG','SYSKM','SYSRAC',
               'SYS$UMF','DBSNMP','DBSFWUSER','APPQOSSYS','AUDSYS',
               'GSMADMIN_INTERNAL','GSMCATUSER','GSMUSER','GGSYS',
               'XDB','ANONYMOUS','XS$NULL','CTXSYS','MDSYS','MDDATA',
               'ORDSYS','ORDDATA','ORDPLUGINS','SI_INFORMTN_SCHEMA',
               'WMSYS','OLAPSYS','EXFSYS','OUTLN','DVSYS','DVF','LBACSYS',
               'OJVMSYS','ORACLE_OCM','REMOTE_SCHEDULER_AGENT','DGPDB_INT',
               'SPATIAL_CSW_ADMIN_USR','SPATIAL_WFS_ADMIN_USR',
               'FLOWS_FILES','APEX_PUBLIC_USER')
           OR v_s LIKE 'APEX\_%' ESCAPE '\'
           OR v_s LIKE 'FLOWS\_%' ESCAPE '\'
        THEN
            RETURN 'Y';
        END IF;
        RETURN 'N';
    END is_oracle_schema;
