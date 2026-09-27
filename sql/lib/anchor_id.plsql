--
-- sql/lib/anchor_id.plsql
--
-- anchor_id(kind, name): the ONE rule that turns an entity name into a
-- stable HTML id, so an entity link (a.ent, emitted by the verdict, the
-- finding cards, the Timeline labels ...) and its target row can never
-- drift.  Lower-cased, every run of non [a-z0-9] collapsed to one '-',
-- leading / trailing '-' trimmed, capped at 64 chars after the kind:
--   anchor_id('we', 'db file sequential read')   -> 'we-db-file-sequential-read'
--   anchor_id('sg', 'ORDERS_APP.ORDER_LINES')    -> 'sg-orders-app-order-lines'
--
-- Kinds (v1.6.0, design/HANDOFF_report_redesign.md "entity links"):
--   07  fr-<d>-<name>   findings row; <d> = l / m / w (LOAD / METRIC /
--                       WAIT domain) -- use finding_anchor(domain, name)
--   04  we-<event>      foreground event, time-waited table
--       wa-<event>      foreground event, average-wait table
--       wc-<class>      foreground wait class rollup
--   05  be-<event> / ba-<event>   background event, time / average tables
--   06  sq-<dim>-<sql_id>  Top SQL row per ranking tab (sq-elapsed-... is
--                       the link target); anchor_id('sq-elapsed', sql_id)
--   18  sm-<sql_id>     SQL Monitor statement row
--   14  sg-<owner.segment[.partition]>
--   15  fl-<parent dir>-<file name>   -- use file_anchor(full path)
--   12  pa-<parameter>, pa--<_hidden>, pa---<__double> -- param_anchor(name)
--   02  load-<stat>     03  metric-<name>     11  ash-card-<sql_id>
--
-- The contract (v1.6.0 review #7): an id is a PURE FUNCTION of (kind, full
-- name), so a link emitted anywhere (the verdict, a card, the narrative,
-- a Timeline label) computes the very id its target row carries without
-- knowing which other rows exist:
--   * names unique within their kind (events, classes, statements,
--     segments, stats) use anchor_id();
--   * files use file_anchor(): a short name repeats across containers
--     (every PDB has its users01.dbf), so the id keeps the parent
--     directory -- never the short name alone;
--   * parameters use param_anchor(): the slug drops leading underscores,
--     and _x / __x / x are three different parameters (db_cache_size and
--     the auto-tuned __db_cache_size change together), so each leading
--     underscore adds a hyphen after the kind.
-- A target table additionally guards DOM uniqueness (anchor_uniq below,
-- or 14 / 15's equivalent map): if two DIFFERENT names still slug alike
-- (a punctuation-only difference, e.g. SYS.OBJ$ and SYS.OBJ) the later
-- row gets '-2', '-3' ...; a link then reaches the first of the pair --
-- the one case the pure function cannot tell apart.
-- Only link to rows that are actually emitted (a sql_id outside the Top-N
-- has no row).  demo/verify_report.js checks every href="#..." resolves to
-- exactly one id.  Twin: demo/awrdemo/helpers.py anchor_id / finding_anchor
-- / file_anchor / param_anchor / anchor_uniq.
-- Include inside a DECLARE block, after the plain variables (two at-signs
-- + sql/lib/anchor_id.plsql).  Pure string functions, no DB access.
--
    FUNCTION anchor_id(p_prefix IN VARCHAR2, p_name IN VARCHAR2) RETURN VARCHAR2 IS
        v VARCHAR2(4000);
    BEGIN
        v := REGEXP_REPLACE(LOWER(NVL(p_name, '')), '[^a-z0-9]+', '-');
        v := REGEXP_REPLACE(v, '^-+|-+$', '');
        RETURN p_prefix || '-' || SUBSTR(v, 1, 64);
    END anchor_id;

    -- The findings-table row of a LOAD / METRIC / WAIT metric (07).
    FUNCTION finding_anchor(p_domain IN VARCHAR2, p_name IN VARCHAR2) RETURN VARCHAR2 IS
    BEGIN
        RETURN anchor_id('fr-' || LOWER(SUBSTR(p_domain, 1, 1)), p_name);
    END finding_anchor;

    -- A data / temp file's row (15) and every link to it: the parent
    -- directory and the file name, so two containers' users01.dbf get two
    -- ids ('/u02/oradata/CDB1/pdb1/users01.dbf' -> 'fl-pdb1-users01-dbf',
    -- '+DATA/CDB1/DATAFILE/users.259.1098' -> 'fl-datafile-users-259-1098').
    FUNCTION file_anchor(p_path IN VARCHAR2) RETURN VARCHAR2 IS
    BEGIN
        RETURN anchor_id('fl', NVL(REGEXP_SUBSTR(p_path, '[^/\]*[/\]?[^/\]+$'), p_path));
    END file_anchor;

    -- An init parameter's row (12) and every link to it: one extra hyphen
    -- after the kind per leading underscore ('db_cache_size' -> 'pa-db-cache-
    -- size', '_x_y' -> 'pa--x-y', '__db_cache_size' -> 'pa---db-cache-size');
    -- a plain slug never starts with a hyphen, so the three cannot meet.
    FUNCTION param_anchor(p_name IN VARCHAR2) RETURN VARCHAR2 IS
    BEGIN
        RETURN anchor_id('pa' || RPAD('-', LENGTH(p_name) - NVL(LENGTH(LTRIM(p_name, '_')), 0), '-'),
                         p_name);
    END param_anchor;

    -- DOM-unique id for p_name in one id space: p_id (its pure-function id)
    -- the first time an id is seen, p_id || '-<n>' when a DIFFERENT name
    -- already took it.  p_seen is the caller's memo (a CLOB, NULL at start,
    -- one per id space: hundreds of events would outgrow a VARCHAR2);
    -- asking again for the same name returns the same id, so a table row
    -- and its Timeline row agree.
    FUNCTION anchor_uniq(p_id IN VARCHAR2, p_name IN VARCHAR2,
                         p_seen IN OUT NOCOPY CLOB) RETURN VARCHAR2 IS
        v_key VARCHAR2(4000) := CHR(1) || p_name || CHR(2);
        v_i   PLS_INTEGER := INSTR(p_seen, v_key);
        v_id  VARCHAR2(4000) := p_id;
        v_n   PLS_INTEGER := 1;
    BEGIN
        IF v_i > 0 THEN
            v_i := v_i + LENGTH(v_key);
            RETURN SUBSTR(p_seen, v_i, INSTR(p_seen, CHR(1), v_i) - v_i);
        END IF;
        WHILE INSTR(p_seen, CHR(2) || v_id || CHR(1)) > 0 LOOP
            v_n  := v_n + 1;
            v_id := p_id || '-' || v_n;
        END LOOP;
        p_seen := p_seen || v_key || v_id || CHR(1);
        RETURN v_id;
    END anchor_uniq;
