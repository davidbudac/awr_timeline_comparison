# Getting This Running From Scratch

This document is for an Oracle DBA who already has an Oracle database, but has never set up Oracle APEX before.

It walks you from:

1. No APEX installed
2. No ORDS installed
3. Existing Oracle database only
4. To a working APEX environment that can run the `apex_app/` backend in this repo

`apex_app/` now contains:

- the database backend
- a real importable APEX application export at `apex_app/apex/f100.sql`
- reference page SQL and process definitions at `apex_app/apex/page_sources.sql`

## Recommended target shape

If your database is multitenant, use a **single PDB** for this app and install APEX **locally in that PDB**.

That is the recommended model for most environments. Oracle’s APEX 24.2 documentation says installing APEX in individual PDBs is recommended for the majority of use cases, except cases where every PDB must share the exact same APEX version.

This guide assumes:

- Oracle Database 19c or later
- One target PDB for APEX
- Oracle APEX 24.2 patched to `24.2.15`
- Oracle REST Data Services (ORDS) 26.1
- ORDS running in standalone mode first, because it is the fastest path to a working environment

As of **April 20, 2026**, Oracle’s public APEX download page still lists `24.2` as the latest full APEX release, and its latest published Patch Set Bundle updates that release to `24.2.15` (page updated March 23, 2026). So the practical “latest APEX version currently available” is:

- Base install: `24.2`
- Then immediately patch to: `24.2.15`

## High-level flow

1. Pick the PDB that will host APEX.
2. Install APEX into that PDB.
3. Create the APEX instance admin account.
4. Unlock and set the `APEX_PUBLIC_USER` password.
5. Install and configure ORDS.
6. Verify you can open APEX in a browser.
7. Create a schema for this project.
8. Create an APEX workspace mapped to that schema.
9. Install this repo’s backend objects.
10. Create DB links to the monitored databases.
11. Register targets.
12. Import the APEX app from `apex_app/apex/f100.sql`.

## 1. Pre-checks

Run these checks first as `SYS` or another privileged DBA account.

### Confirm database version

```sql
SELECT banner_full
FROM   v$version
WHERE  banner_full LIKE 'Oracle Database%';
```

You want Oracle Database 19c or later for APEX 24.2 / 24.2.15.

### If you are using multitenant, confirm the target PDB

```sql
SHOW CON_NAME
SHOW PDBS
```

Pick the PDB where you want to host APEX. In the examples below I will call it `AWRPDB`.

### Confirm XML DB is installed

APEX requires Oracle XML DB for a full development environment.

```sql
SELECT comp_id, comp_name, status
FROM   dba_registry
WHERE  comp_id = 'XDB';
```

Expected result: `VALID`.

### Optional check: confirm APEX is not already installed in the target PDB

Connect to the target PDB and run:

```sql
SELECT owner, object_name
FROM   dba_objects
WHERE  object_name = 'APEX_RELEASE';
```

If that returns no rows, APEX is probably not installed there.

## 2. Download the software

Download these two components on the database or middleware host:

- Oracle APEX 24.2 base install zip
- Oracle APEX Patch Set Bundle for 24.2, currently `24.2.15`
- Oracle REST Data Services 26.1

Use Oracle’s download pages:

- APEX downloads: [oracle.com/tools/downloads/apex-downloads.html](https://www.oracle.com/tools/downloads/apex-downloads.html)
- ORDS downloads: [oracle.com/database/technologies/appdev/rest-data-services-downloads.html](https://www.oracle.com/database/technologies/appdev/rest-data-services-downloads.html)

Suggested filesystem layout:

```text
/u01/software/apex_24.2/
/u01/software/apex_24.2_psb/
/u01/software/ords-26.1/
/u01/ords-config/
```

Unzip APEX and ORDS into short paths without spaces.

For example:

```bash
mkdir -p /u01/software
cd /u01/software
unzip apex_24.2_en.zip
mkdir -p /u01/software/apex_24.2_psb
# unpack the Patch Set Bundle zip from My Oracle Support here
unzip ords-latest.zip -d ords-26.1
```

If you need non-English development languages, use the full APEX zip instead of the `_en` zip.

### What “latest” means here

Oracle distributes APEX in two layers:

- a full release zip, currently `24.2`
- a Patch Set Bundle, currently `24.2.15`

So install the full `24.2` release first, then apply the latest `24.2` Patch Set Bundle immediately.

## 3. Install APEX into the PDB

### Important assumption

These steps assume:

- you are installing APEX **locally in one PDB**
- not into `CDB$ROOT`

That is the recommended path for most use cases.

### Connect as SYS to the CDB, then switch to the PDB

From the unzipped APEX `apex/` directory:

```bash
cd /u01/software/apex
sql /nolog
```

Then:

```sql
CONNECT SYS@<your_cdb_service> AS SYSDBA
ALTER SESSION SET CONTAINER = AWRPDB;
SHOW CON_NAME
```

### Install the full development environment

Oracle’s documented command for a full development installation is:

```sql
@apexins.sql tablespace_apex tablespace_files tablespace_temp images
```

A simple example is:

```sql
@apexins.sql SYSAUX SYSAUX TEMP /i/
```

If you use dedicated tablespaces for app components, substitute them here.

### Notes

- Use `/i/` as the images virtual path. Oracle recommends that path because it simplifies future upgrades.
- Let the script finish completely. It may take a while.
- If your target is a non-CDB, skip the `ALTER SESSION SET CONTAINER` step.

## 4. Create the APEX instance administrator

Still from the unzipped APEX `apex/` directory, as `SYS`:

```sql
@apxchpwd.sql
```

Follow the prompts for:

- instance admin username
- password
- email address

This creates the APEX instance admin account used to sign in to `apex_admin`.

## 4a. Immediately patch APEX to 24.2.15

If you want the latest currently available APEX version, do not stop at the base `24.2` install. Apply the latest 24.2 Patch Set Bundle right away.

As of **March 23, 2026**, Oracle’s APEX download page shows the latest 24.2 Patch Set Bundle level as `24.2.15`.

### Where to get it

The Patch Set Bundle is listed on Oracle’s public APEX download page, but the patch download itself is from My Oracle Support.

### Apply the patch

The exact patching mechanics are described in the Patch Set Bundle README that comes with the MOS download, and you should follow that README for the exact steps for your environment.

At a high level:

1. Install base APEX `24.2`.
2. Download the latest 24.2 Patch Set Bundle from My Oracle Support.
3. Read the included README fully.
4. Apply the SQL patching steps it specifies while connected to the same target PDB where APEX was installed.
5. Update static resources if the README instructs you to do so.
6. Run `sys.validate_apex`.

### After patching, verify the APEX version

As `SYS` or another privileged account in the target PDB:

```sql
SELECT version_no
FROM   apex_release;
```

Expected result after patching:

```text
24.2.15
```

## 5. Configure `APEX_PUBLIC_USER`

APEX creates `APEX_PUBLIC_USER` with a random password on new installs. Set it explicitly and unlock it.

As `SYS` in the same PDB:

```sql
ALTER USER APEX_PUBLIC_USER ACCOUNT UNLOCK;
ALTER USER APEX_PUBLIC_USER IDENTIFIED BY "<strong_password>";
```

### Strong recommendation

Do not let `APEX_PUBLIC_USER` expire every 180 days under the default profile. If it expires, APEX stops working.

Create or assign a profile with unlimited password lifetime for `APEX_PUBLIC_USER`.

Example:

```sql
CREATE PROFILE APEX_NOEXP LIMIT PASSWORD_LIFE_TIME UNLIMITED;
ALTER USER APEX_PUBLIC_USER PROFILE APEX_NOEXP;
```

## 6. Install and configure ORDS

### Why ORDS exists

APEX is database-resident, but it still needs a web listener to serve HTTP requests. ORDS is the standard choice.

### First-time ORDS install

From the ORDS directory:

```bash
cd /u01/software/ords-26.1
./bin/ords --config /u01/ords-config install -i
```

The interactive installer will prompt you for:

- config location
- database connection
- whether to configure standalone mode
- standalone HTTP or HTTPS settings

For the quickest first bring-up:

- choose standalone mode
- choose an HTTP port such as `8080`
- point ORDS at the same PDB where you installed APEX

### Required ORDS setting for APEX

After APEX is installed, set PL/SQL gateway mode to `proxied`.

```bash
./bin/ords --config /u01/ords-config config set plsql.gateway.mode proxied
```

If you are using a non-default database pool:

```bash
./bin/ords --config /u01/ords-config config --db-pool <pool_name> set plsql.gateway.mode proxied
```

### Point ORDS at the APEX images directory

```bash
./bin/ords --config /u01/ords-config config set standalone.static.path /u01/software/apex/images
./bin/ords --config /u01/ords-config config set standalone.context.path /ords
```

### Validate APEX after ORDS install or patching

Oracle documents that if ORDS is installed after APEX, or after each ORDS upgrade, you should run `sys.validate_apex`. It is also a good post-check after applying the APEX Patch Set Bundle.

As `SYS` in the target PDB:

```sql
SET SERVEROUTPUT ON
BEGIN
    sys.validate_apex;
END;
/
```

### Start ORDS

```bash
./bin/ords --config /u01/ords-config serve --port 8080
```

At this point you should have:

- APEX 24.2.15 installed in the PDB
- ORDS running
- static images configured
- PL/SQL gateway mode set to `proxied`

## 7. Verify that APEX opens in the browser

### Admin URL

Open:

```text
http://<host>:8080/ords/apex_admin
```

Sign in with the instance admin user you created with `apxchpwd.sql`.

### Workspace sign-in URL

Later, normal workspace users will use:

```text
http://<host>:8080/ords/
```

If `apex_admin` does not open:

1. Check that ORDS is running.
2. Check that `standalone.static.path` points at the APEX `images` folder.
3. Check that `plsql.gateway.mode` is `proxied`.
4. Check that `APEX_PUBLIC_USER` is unlocked.
5. Re-run `sys.validate_apex`.

## 8. Create the schema for this project

Create a dedicated schema for this app. I will call it `AWR_APEX`.

As `SYS` in the target PDB:

```sql
CREATE USER AWR_APEX IDENTIFIED BY "<strong_password>"
    DEFAULT TABLESPACE USERS
    TEMPORARY TABLESPACE TEMP
    QUOTA UNLIMITED ON USERS;

GRANT CREATE SESSION TO AWR_APEX;
GRANT CREATE TABLE TO AWR_APEX;
GRANT CREATE VIEW TO AWR_APEX;
GRANT CREATE SEQUENCE TO AWR_APEX;
GRANT CREATE PROCEDURE TO AWR_APEX;
GRANT CREATE JOB TO AWR_APEX;
```

If you use a different application tablespace, substitute that instead of `USERS`.

## 9. Create the APEX workspace

### In the browser

Go to:

```text
http://<host>:8080/ords/apex_admin
```

Then:

1. Sign in as the APEX instance administrator.
2. Click `Manage Workspaces`.
3. Click `Create Workspace`.
4. Use these values:
   - Workspace Name: `AWR_TREND`
   - Re-use existing schema: `Yes`
   - Schema: `AWR_APEX`
   - Workspace admin username: pick one, for example `ADMIN`
   - Workspace admin password: set a password

Once created, sign out of `apex_admin`.

Then sign in to the workspace at:

```text
http://<host>:8080/ords/
```

with:

- workspace: `AWR_TREND`
- username: your workspace admin user
- password: the one you just set

## 10. Install this repo’s backend objects

Now switch to the repository root on disk and connect as `AWR_APEX`.

Example:

```bash
cd /path/to/this/repo
sql AWR_APEX/<password>@<your_pdb_service>
```

Then run:

```sql
@apex_app/sql/install.sql
```

This installs:

- compatibility `AWR_TREND_*` repository tables if they do not already exist
- `AWR_APP_TARGETS`
- `AWR_APP_SCHEDULES`
- `AWR_APP_RUN_LOG`
- APEX-facing views
- the collector/orchestration packages

## 11. Create DB links to the monitored databases

This app is designed as a central repository. It connects to monitored databases through DB links.

Create one DB link in the `AWR_APEX` schema per monitored database.

Example:

```sql
CONNECT AWR_APEX/<password>@<your_pdb_service>

CREATE DATABASE LINK PROD1_AWR
CONNECT TO awr_reader IDENTIFIED BY "<remote_password>"
USING 'PROD1_TNS';
```

The remote user behind each DB link needs at least the privileges listed in [apex_app/README.md](/Users/davidbudac/.codex/worktrees/8778/awr_timeline_comparison/apex_app/README.md).

### Quick DB link smoke test

```sql
SELECT * FROM v$database@PROD1_AWR;
SELECT COUNT(*) FROM dba_hist_snapshot@PROD1_AWR;
```

If those fail, the app will fail too.

## 12. Register a target in the app metadata

As `AWR_APEX`:

```sql
INSERT INTO awr_app_targets (
    target_id,
    target_name,
    db_link_name,
    description,
    default_target_end_mode,
    default_win_hours,
    default_weeks_back,
    default_top_n,
    default_inst_num,
    enabled_flag,
    created_by
) VALUES (
    awr_app_target_seq.NEXTVAL,
    'PROD1',
    'PROD1_AWR',
    'Production database 1',
    'AUTO',
    1,
    4,
    10,
    0,
    'Y',
    USER
);

COMMIT;
```

## 13. Test the backend before touching the APEX UI

Do this first. It isolates database issues from APEX UI issues.

As `AWR_APEX`:

```sql
VARIABLE run_id NUMBER

BEGIN
    :run_id := awr_app_run_api.submit_run(
        p_target_id => 1
    );
END;
/

PRINT run_id
```

Then either run it immediately:

```sql
BEGIN
    awr_app_run_api.execute_run(:run_id);
END;
/
```

Or use the async job path:

```sql
BEGIN
    awr_app_run_api.enqueue_run(:run_id);
END;
/
```

Then inspect:

```sql
SELECT run_id, status, error_text, started_at, finished_at
FROM   awr_trend_runs
ORDER BY run_id DESC;

SELECT created_at, step_name, log_level, status, message
FROM   awr_app_run_log
WHERE  run_id = :run_id
ORDER BY created_at, log_id;

SELECT severity, metric_domain, metric_name, z_score, pct_delta
FROM   awr_trend_findings
WHERE  run_id = :run_id
ORDER BY severity, ABS(NVL(z_score, 0)) DESC;
```

Do not proceed to the APEX UI until this backend test works.

## 14. Import the APEX application

This repo now includes an importable APEX application SQL file:

- app export: [apex_app/apex/f100.sql](/Users/davidbudac/.codex/worktrees/8778/awr_timeline_comparison/apex_app/apex/f100.sql)
- page reference SQL: [apex_app/apex/page_sources.sql](/Users/davidbudac/.codex/worktrees/8778/awr_timeline_comparison/apex_app/apex/page_sources.sql)
- page inventory: [apex_app/docs/page-map.md](/Users/davidbudac/.codex/worktrees/8778/awr_timeline_comparison/apex_app/docs/page-map.md)

### Import option 1: SQL Workshop

Inside the `AWR_TREND` workspace:

1. Open `SQL Workshop`.
2. Open `SQL Scripts`.
3. Upload `apex_app/apex/f100.sql`.
4. Run it as parsing schema `AWR_APEX`.

### Import option 2: SQLcl or SQL*Plus

Connect as the parsing schema in the target PDB:

```sql
BEGIN
    apex_application_install.set_workspace('AWR_TREND');
    apex_application_install.set_schema('AWR_APEX');
    apex_application_install.set_application_id(100);
    apex_application_install.set_application_alias('AWR_TREND_CENTRAL');
END;
/

@apex_app/apex/f100.sql
```

### After import

In App Builder, you should see application `100` named `AWR Trend Central`.

If you want to inspect or modify the pages after import, use:

- [apex_app/apex/page_sources.sql](/Users/davidbudac/.codex/worktrees/8778/awr_timeline_comparison/apex_app/apex/page_sources.sql)
- [apex_app/docs/page-map.md](/Users/davidbudac/.codex/worktrees/8778/awr_timeline_comparison/apex_app/docs/page-map.md)

## 15. Optional: add a recurring schedule

After the backend works, add a schedule:

```sql
INSERT INTO awr_app_schedules (
    schedule_id,
    target_id,
    schedule_name,
    repeat_interval,
    enabled_flag,
    created_by
) VALUES (
    awr_app_schedule_seq.NEXTVAL,
    1,
    'Hourly PROD1 comparison',
    'FREQ=HOURLY;INTERVAL=1',
    'Y',
    USER
);

COMMIT;

BEGIN
    awr_app_admin_api.sync_schedules;
END;
/
```

Then inspect:

```sql
SELECT schedule_id, schedule_name, scheduler_job_name, enabled_flag, last_status
FROM   awr_app_schedules;

SELECT job_name, state, repeat_interval
FROM   user_scheduler_jobs
WHERE  job_name LIKE 'AWR_APP_SCHED_%';
```

## 16. What to troubleshoot first

### Problem: APEX URL opens but CSS/images are broken

Usually:

- `standalone.static.path` is wrong
- ORDS cannot read the APEX `images` directory
- the APEX Patch Set Bundle updated the static resources, but the served `images` path was not refreshed to match

Check:

```bash
./bin/ords --config /u01/ords-config config list | grep standalone
```

### Problem: `apex_admin` returns an error

Usually:

- `plsql.gateway.mode` is not `proxied`
- `APEX_PUBLIC_USER` is locked
- `sys.validate_apex` was not run after ORDS install

### Problem: backend run fails immediately

Usually:

- bad DB link
- missing remote AWR grants
- wrong parsing schema

Start with:

```sql
SELECT * FROM v$database@<db_link>;
SELECT COUNT(*) FROM dba_hist_snapshot@<db_link>;
```

### Problem: APEX page loads, but regions fail

Usually:

- region SQL was pasted into the wrong page
- page items such as `P3_RUN_ID` are missing
- parsing schema is not `AWR_APEX`

## 17. Recommended first-day validation checklist

Before you call this done, make sure all of these are true:

- APEX Admin page opens: `http://<host>:8080/ords/apex_admin`
- Workspace sign-in page opens: `http://<host>:8080/ords/`
- Workspace `AWR_TREND` exists
- Schema `AWR_APEX` exists
- `@apex_app/sql/install.sql` completed cleanly
- At least one DB link works from `AWR_APEX`
- `awr_app_run_api.submit_run` works
- `awr_app_run_api.execute_run` works
- `awr_trend_findings` contains rows for a completed run
- At least the Home, Runs, Run Overview, and Run Log pages work in APEX

## 18. Exact repo files you will use

- Backend installer:
  [apex_app/sql/install.sql](/Users/davidbudac/.codex/worktrees/8778/awr_timeline_comparison/apex_app/sql/install.sql)
- Backend README:
  [apex_app/README.md](/Users/davidbudac/.codex/worktrees/8778/awr_timeline_comparison/apex_app/README.md)
- Architecture:
  [apex_app/docs/architecture.md](/Users/davidbudac/.codex/worktrees/8778/awr_timeline_comparison/apex_app/docs/architecture.md)
- Page inventory:
  [apex_app/docs/page-map.md](/Users/davidbudac/.codex/worktrees/8778/awr_timeline_comparison/apex_app/docs/page-map.md)
- APEX page SQL/process definitions:
  [apex_app/apex/page_sources.sql](/Users/davidbudac/.codex/worktrees/8778/awr_timeline_comparison/apex_app/apex/page_sources.sql)
- APEX app export:
  [apex_app/apex/f100.sql](/Users/davidbudac/.codex/worktrees/8778/awr_timeline_comparison/apex_app/apex/f100.sql)

## Sources

These instructions are based on current Oracle documentation I checked on April 20, 2026:

- Oracle APEX download page:
  [oracle.com/tools/downloads/apex-downloads.html](https://www.oracle.com/tools/downloads/apex-downloads.html)

- Oracle APEX Installation Guide 24.2:
  [docs.oracle.com/en/database/oracle/apex/24.2/htmig/](https://docs.oracle.com/en/database/oracle/apex/24.2/htmig/)
- APEX installation requirements:
  [docs.oracle.com/en/database/oracle/apex/24.2/htmig/apex-installation-requirements.html](https://docs.oracle.com/en/database/oracle/apex/24.2/htmig/apex-installation-requirements.html)
- Downloading and installing APEX:
  [docs.oracle.com/en/database/oracle/apex/24.2/htmig/downloading-installing-apex.html](https://docs.oracle.com/en/database/oracle/apex/24.2/htmig/downloading-installing-apex.html)
- Installing APEX locally in a PDB:
  [docs.oracle.com/en/database/oracle/apex/24.2/htmig/installing-apex-into-different-pdbs.html](https://docs.oracle.com/en/database/oracle/apex/24.2/htmig/installing-apex-into-different-pdbs.html)
- Creating a workspace manually:
  [docs.oracle.com/en/database/oracle/apex/24.2/htmig/creating-workspace-and-adding-apex-users.html](https://docs.oracle.com/en/database/oracle/apex/24.2/htmig/creating-workspace-and-adding-apex-users.html)
- Signing in to APEX Administration Services:
  [docs.oracle.com/en/database/oracle/apex/24.2/aeadm/accessing-oracle-application-express-administration-services.html](https://docs.oracle.com/en/database/oracle/apex/24.2/aeadm/accessing-oracle-application-express-administration-services.html)
- ORDS Installation and Configuration Guide 26.1:
  [docs.oracle.com/en/database/oracle/oracle-rest-data-services/26.1/ordig/](https://docs.oracle.com/en/database/oracle/oracle-rest-data-services/26.1/ordig/)
- ORDS install/config PDF:
  [docs.oracle.com/en/database/oracle/oracle-rest-data-services/26.1/ordig/oracle-rest-data-services-installation-and-configuration-guide.pdf](https://docs.oracle.com/en/database/oracle/oracle-rest-data-services/26.1/ordig/oracle-rest-data-services-installation-and-configuration-guide.pdf)
- APEX app installation context:
  [docs.oracle.com/en/database/oracle/apex/24.1/aeadm/installing-an-application.html](https://docs.oracle.com/en/database/oracle/apex/24.1/aeadm/installing-an-application.html)
