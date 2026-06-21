--
-- fleet/collect/awrw_collect.pks
--
-- The collector: pulls new AWR history from each Target's Source into the
-- Warehouse over a read-only Connection (DB link), incrementally by the
-- per-(Target,DBID) high-water mark. Pure PL/SQL -- INSERT ... SELECT@link --
-- so nothing runs on the AIX Sources but SELECT, and the Warehouse is the only
-- writer (preserving the project's read-only invariant).
--
-- Snapshot-atomic per DBID: all facts for the new snap range commit together
-- and the HWM advances only on success, so a Snapshot present in the Warehouse
-- is always complete, and a failed pull simply re-runs next cycle.
--
-- Run as the warehouse owner. Schedule collect_all from DBMS_SCHEDULER.
--
CREATE OR REPLACE PACKAGE awrw_collect AS

    -- Collect every enabled Target. One Target's failure never stops the fleet.
    PROCEDURE collect_all;

    -- Collect one Target: discover its DBID set through the Connection, then
    -- pull new Snapshots + facts + dimensions for each owned DBID.
    PROCEDURE collect_target(p_target_id IN NUMBER);

    -- Re-evaluate Target Health (CURRENT / LAGGING / STALE) from collection
    -- freshness vs each Target's expected snapshot cadence. Call after
    -- collect_all; UNREACHABLE is set inline by a failed collection.
    PROCEDURE refresh_health;

END awrw_collect;
/
