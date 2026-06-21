--
-- fleet/admin/awrw_admin.sql
--
-- Thin admin helpers for registering and enabling Targets. The read-only DB
-- link itself is created separately (it needs Source credentials) -- see
-- fleet/README.md "Register a Target". add_target only records the registry row.
--
CREATE OR REPLACE PACKAGE awrw_admin AS
    PROCEDURE add_target(p_name             IN VARCHAR2,
                         p_db_link          IN VARCHAR2,
                         p_profile          IN VARCHAR2 DEFAULT 'DEFAULT',
                         p_snap_interval_min IN NUMBER  DEFAULT 60,
                         p_notes            IN VARCHAR2 DEFAULT NULL);
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

    PROCEDURE set_enabled(p_name IN VARCHAR2, p_enabled IN VARCHAR2) IS
    BEGIN
        UPDATE awrw_target SET enabled = p_enabled WHERE target_name = p_name;
        COMMIT;
    END set_enabled;

END awrw_admin;
/
