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
--   14  sg-<owner.segment[.partition]>   15  fl-<file name>
--   12  pa-<parameter>
--   02  load-<stat>     03  metric-<name>     11  ash-card-<sql_id>
-- Only link to rows that are actually emitted (a sql_id outside the Top-N
-- has no row); where two names collide after slugging the emitter appends
-- the rank.  demo/verify_report.js checks every href="#..." resolves to
-- exactly one id.  Twin: demo/awrdemo/helpers.py anchor_id / finding_anchor.
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
