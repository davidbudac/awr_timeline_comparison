# AWR Trend Central APEX App

Standalone Oracle APEX application implementation for the AWR timeline comparison toolkit.

This folder adds a central-repository APEX deployment without changing the original SQL\*Plus toolkit. The app stores orchestration metadata locally, connects to monitored databases through DB links, executes the comparison logic in PL/SQL, and renders the stored facts through native APEX pages.

## Contents

- `sql/install.sql`
  Installs all repository tables, views, sequences, and PL/SQL packages needed by the app.
- `sql/schema/`
  Creates or upgrades `AWR_TREND_*` compatibility objects and adds `AWR_APP_*` metadata objects.
- `sql/packages/`
  Run orchestration, collector logic, and scheduler sync packages.
- `sql/jobs/`
  Small helper entrypoints for recurring scheduler maintenance.
- `apex/`
  APEX application export and companion reference files.
- `docs/`
  Architecture and page map notes.

## Deployment model

- Central repository database with Oracle APEX installed.
- One schema owns all `AWR_TREND_*` and `AWR_APP_*` objects.
- That schema has DB links to each monitored database.
- Each monitored database exposes the same AWR views used by the original toolkit.

## Required central-schema privileges

- `CREATE SESSION`
- `CREATE TABLE`
- `CREATE VIEW`
- `CREATE SEQUENCE`
- `CREATE PROCEDURE`
- `CREATE JOB`
- `SELECT` on `ALL_DB_LINKS` if your environment restricts it
- Whatever APEX parsing-schema privileges are standard in your workspace

## Required remote-database access through each DB link

- `SELECT` on:
  - `DBA_HIST_SNAPSHOT`
  - `DBA_HIST_SYSSTAT`
  - `DBA_HIST_SYSTEM_EVENT`
  - `DBA_HIST_BG_EVENT_SUMMARY`
  - `DBA_HIST_SYSMETRIC_SUMMARY`
  - `DBA_HIST_SQLSTAT`
  - `DBA_HIST_SQLTEXT`
  - `V_$DATABASE`

## Install

Run the installer from this folder:

```sql
SQL> @apex_app/sql/install.sql
```

Then register targets:

```sql
INSERT INTO awr_app_targets (
    target_id,
    target_name,
    db_link_name,
    default_win_hours,
    default_weeks_back,
    default_top_n,
    default_inst_num,
    enabled_flag
) VALUES (
    awr_app_target_seq.NEXTVAL,
    'PROD1',
    'PROD1_AWR',
    1,
    4,
    10,
    0,
    'Y'
);
COMMIT;
```

Optional schedule example:

```sql
INSERT INTO awr_app_schedules (
    schedule_id,
    target_id,
    schedule_name,
    repeat_interval,
    enabled_flag
) VALUES (
    awr_app_schedule_seq.NEXTVAL,
    1,
    'Hourly PROD1 comparison',
    'FREQ=HOURLY;INTERVAL=1',
    'Y'
);
COMMIT;

BEGIN
    awr_app_admin_api.sync_schedules;
END;
/
```

## APEX app

The APEX-facing files live under `apex/`:

- `f100.sql`
  Importable APEX application SQL export for application `100`.
- `page_sources.sql`
  Reference SQL and process catalog that matches the imported app.

Import the app with:

```sql
SQL> @apex_app/apex/f100.sql
```

You can still use `page_sources.sql` as a readable reference when you want to modify pages in App Builder after import.

See `docs/page-map.md` for the page inventory.
