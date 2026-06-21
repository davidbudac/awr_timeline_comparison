--
-- fleet/install_warehouse.sql
--
-- Installs the AWR Fleet Warehouse schema + collector into the CURRENT schema
-- on the central 19c Warehouse. Run as the warehouse owner:
--
--   cd fleet
--   sqlplus awrwh/pw@warehouse @install_warehouse.sql
--
-- Idempotent re-install: drop first with @ddl/00_drop.sql (destroys all
-- collected history -- intended for dev/test only).
--
SET ECHO ON
SET DEFINE OFF
WHENEVER SQLERROR CONTINUE

PROMPT ===== 1/4  control plane + types + dimensions + facts + findings =====
@@ddl/10_control_plane.sql
@@ddl/15_types.sql
@@ddl/20_dimensions.sql
@@ddl/30_facts.sql
@@ddl/40_findings.sql
@@ddl/45_digest.sql

PROMPT ===== 2/4  AWRV_* seam views =====
@@ddl/50_awrv_views.sql

PROMPT ===== 3/4  packages =====
@@collect/awrw_collect.pks
@@collect/awrw_collect.pkb
@@admin/awrw_admin.sql
@@analyze/awrw_score.sql
@@analyze/awrw_analyze.pks
@@analyze/awrw_analyze.pkb
@@analyze/awrw_notify.sql
@@schedule/awrw_schedule.sql

PROMPT ===== 4/4  seed default profile =====
@@seed/profile_default.sql

PROMPT ===== validate objects =====
SELECT object_type, object_name, status
  FROM user_objects
 WHERE object_name LIKE 'AWRW%' OR object_name LIKE 'AWRV%'
 ORDER BY object_type, object_name;

PROMPT ===== install complete =====
