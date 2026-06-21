--
-- fleet/admin/awrw_admin.sql
--
-- Thin admin helpers for registering and enabling Targets. The read-only DB
-- link itself is created separately (it needs Source credentials) -- see
-- fleet/README.md "Register a Target". add_target only records the registry row.
--
CREATE OR REPLACE PACKAGE awrw_admin AS
    -- Register a Target against an ALREADY-EXISTING DB link (records the registry row only).
    PROCEDURE add_target(p_name             IN VARCHAR2,
                         p_db_link          IN VARCHAR2,
                         p_profile          IN VARCHAR2 DEFAULT 'DEFAULT',
                         p_snap_interval_min IN NUMBER  DEFAULT 60,
                         p_notes            IN VARCHAR2 DEFAULT NULL);

    -- One-call registration: CREATE the read-only DB link AND register the Target,
    -- folding the two manual steps into one (ideal for a bootstrap loop).
    --   p_connect  the USING descriptor: EZConnect '//host:port/service' or a tnsnames alias
    --   p_reader   the source-side read-only account (a simple identifier)
    --   p_password NULL => create a wallet/external-auth link (no IDENTIFIED BY clause)
    --   p_link_name defaults to p_name; p_replace='Y' drops+recreates an existing link
    -- After CREATE it probes the link (SELECT 1 FROM dual@link) and raises if unreachable,
    -- so a bad link/credential fails fast instead of registering a dead Target.
    -- NB: the warehouse owner needs CREATE DATABASE LINK granted DIRECTLY (definer-rights
    -- PL/SQL ignores role-granted privileges).
    PROCEDURE add_target_dblink(p_name              IN VARCHAR2,
                                p_connect           IN VARCHAR2,
                                p_reader            IN VARCHAR2,
                                p_password          IN VARCHAR2 DEFAULT NULL,
                                p_profile           IN VARCHAR2 DEFAULT 'DEFAULT',
                                p_snap_interval_min IN NUMBER   DEFAULT 60,
                                p_notes             IN VARCHAR2 DEFAULT NULL,
                                p_link_name         IN VARCHAR2 DEFAULT NULL,
                                p_replace           IN VARCHAR2 DEFAULT 'Y');

    PROCEDURE set_enabled(p_name IN VARCHAR2, p_enabled IN VARCHAR2);
END awrw_admin;
/

CREATE OR REPLACE PACKAGE BODY awrw_admin AS

    PROCEDURE add_target(p_name             IN VARCHAR2,
                         p_db_link          IN VARCHAR2,
                         p_profile          IN VARCHAR2 DEFAULT 'DEFAULT',
                         p_snap_interval_min IN NUMBER  DEFAULT 60,
                         p_notes            IN VARCHAR2 DEFAULT NULL) IS
    BEGIN
        MERGE INTO awrw_target t
        USING (SELECT p_name nm FROM dual) s ON (t.target_name = s.nm)
        WHEN MATCHED THEN UPDATE SET
            db_link = p_db_link, profile_name = p_profile,
            snap_interval_min = p_snap_interval_min, notes = p_notes
        WHEN NOT MATCHED THEN INSERT (target_name, db_link, profile_name, snap_interval_min, enabled, notes)
            VALUES (p_name, p_db_link, p_profile, p_snap_interval_min, 'Y', p_notes);
        COMMIT;
    END add_target;

    PROCEDURE add_target_dblink(p_name              IN VARCHAR2,
                                p_connect           IN VARCHAR2,
                                p_reader            IN VARCHAR2,
                                p_password          IN VARCHAR2 DEFAULT NULL,
                                p_profile           IN VARCHAR2 DEFAULT 'DEFAULT',
                                p_snap_interval_min IN NUMBER   DEFAULT 60,
                                p_notes             IN VARCHAR2 DEFAULT NULL,
                                p_link_name         IN VARCHAR2 DEFAULT NULL,
                                p_replace           IN VARCHAR2 DEFAULT 'Y') IS
        v_link VARCHAR2(128)  := SYS.DBMS_ASSERT.SIMPLE_SQL_NAME(NVL(p_link_name, p_name));
        v_rdr  VARCHAR2(128)  := SYS.DBMS_ASSERT.SIMPLE_SQL_NAME(p_reader);
        v_conn VARCHAR2(2000) := REPLACE(p_connect,  '''', '''''');  -- escape ' for the USING literal
        v_pw   VARCHAR2(256)  := REPLACE(p_password, '"',  '""');    -- escape " for IDENTIFIED BY "..."
        v_sql  VARCHAR2(4000);
        v_chk  NUMBER;
    BEGIN
        IF p_replace = 'Y' THEN
            BEGIN EXECUTE IMMEDIATE 'DROP DATABASE LINK '||v_link;
            EXCEPTION WHEN OTHERS THEN IF SQLCODE != -2024 THEN RAISE; END IF;  -- -2024: link not found
            END;
        END IF;

        v_sql := 'CREATE DATABASE LINK '||v_link||' CONNECT TO '||v_rdr;
        IF p_password IS NOT NULL THEN v_sql := v_sql||' IDENTIFIED BY "'||v_pw||'"'; END IF;
        v_sql := v_sql||' USING '''||v_conn||'''';
        EXECUTE IMMEDIATE v_sql;

        -- fail fast: prove the link connects before registering an enabled Target
        BEGIN
            EXECUTE IMMEDIATE 'SELECT 1 FROM dual@'||v_link INTO v_chk;
        EXCEPTION WHEN OTHERS THEN
            RAISE_APPLICATION_ERROR(-20010,
                'Link '||v_link||' created but not reachable ('||SQLERRM||
                '). Fix network/credentials, then re-run.');
        END;

        add_target(p_name => p_name, p_db_link => v_link, p_profile => p_profile,
                   p_snap_interval_min => p_snap_interval_min, p_notes => p_notes);
    END add_target_dblink;

    PROCEDURE set_enabled(p_name IN VARCHAR2, p_enabled IN VARCHAR2) IS
    BEGIN
        UPDATE awrw_target SET enabled = p_enabled WHERE target_name = p_name;
        COMMIT;
    END set_enabled;

END awrw_admin;
/
