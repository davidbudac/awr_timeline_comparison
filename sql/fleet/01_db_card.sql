--
-- sql/fleet/01_db_card.sql
-- Opens this database's <section class="db-card"> and renders the identity
-- strip: alias, db_name, host, version, DBID, window/cadence line. Every
-- value comes from a substitution variable already resolved once by
-- awr_fleet_extract.sql's derived-vars SELECT -- no query here, matching
-- 00_params.sql's masthead identity block in spirit but without any of the
-- window-ribbon / verdict machinery that needs a DB round trip.
--
-- The section opened here is closed by sql/fleet/05_close.sql; sections
-- 02-04 append their own <h3> subsections into the same <section> in
-- between.
--

SET DEFINE '~'
SET SERVEROUTPUT ON SIZE UNLIMITED FORMAT WRAPPED

BEGIN DBMS_OUTPUT.PUT_LINE('<!-- AWR-SECTION: fleet_01 BEGIN -->'); END;
/

BEGIN
    DBMS_OUTPUT.PUT_LINE('<section class="db-card" id="db-'
        || DBMS_XMLGEN.CONVERT('~fleet_alias') || '">');
    DBMS_OUTPUT.PUT_LINE('<div class="db-card-id">');
    DBMS_OUTPUT.PUT_LINE('<h2>' || DBMS_XMLGEN.CONVERT('~fleet_alias') || '</h2>');
    DBMS_OUTPUT.PUT_LINE('<span class="badge info">' || DBMS_XMLGEN.CONVERT('~db_name') || '</span>');
    DBMS_OUTPUT.PUT_LINE('</div>');
    DBMS_OUTPUT.PUT_LINE('<div class="db-card-meta">'
        || 'Host ' || DBMS_XMLGEN.CONVERT('~host_name')
        || ' &middot; ' || DBMS_XMLGEN.CONVERT('~db_version')
        -- dbid is a NUMBER-typed NEW_VALUE (no quoting/injection concern),
        -- so it is emitted directly -- same convention as the masthead's
        -- primary DBID label in sql/00_params.sql.
        || ' &middot; DBID ' || '~dbid'
        || ' &middot; window ending ' || DBMS_XMLGEN.CONVERT('~target_end_resolved')
        || ' (' || DBMS_XMLGEN.CONVERT('~dow_name') || ')'
        || ' &middot; ' || '~win_hours' || 'h span'
        || ' &middot; cadence ' || DBMS_XMLGEN.CONVERT('~period_step_label')
        || ' &middot; ' || '~weeks_back' || ' prior windows'
        || '</div>');
END;
/

BEGIN DBMS_OUTPUT.PUT_LINE('<!-- AWR-SECTION: fleet_01 END -->'); END;
/
