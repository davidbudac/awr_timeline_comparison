"""
Synthetic "very busy production database" world for the demo report.

One deterministic, hour-resolution model of a 3-month period.  Every
section emitter derives its numbers from the SAME hourly metrics so the
report stays internally coherent (a spike in DB time shows up in the ASH
timeline, the wait tables, Top SQL, segment I/O ... at the same instant).

Story (see README):
  * Steady weekday business-hours workload (order-entry OLTP + hourly
    reporting), a nightly batch at 01:00-03:00, quieter weekends, slow
    +9 % growth over the quarter.
  * Marked milestones (releases / upgrades) each cause a distinct spike:
      2026-06-30 22:00  Release 4.0      -> hard-parse storm + library cache
                                           mutex contention, ~2.5 days,
                                           cleared by Hotfix 4.0.1
      2026-07-03 09:00  Hotfix 4.0.1     -> cursor_sharing=FORCE
      2026-07-21 01:00  RU 19.28 patch   -> instance restart, cold cache
                                           (physical reads) for ~3 h
      2026-08-11 22:00  Release 4.1      -> new Loyalty feature: two new
                                           SQL_IDs, +12 % steady load, one
                                           day of row-lock contention
      2026-09-08 22:00  Release 4.2      -> optimizer_adaptive_plans=TRUE,
                                           ORDER lookup flips to a full scan
                                           of ORDER_LINES: physical reads x3,
                                           User I/O waits x3.5 -- STILL
                                           ongoing at target_end, so the
                                           Current window is the regression
  * Unmarked "life happens" blips: month-end close batches (Jul 31,
    Aug 31 evenings), a 90-minute log-file-sync incident on Aug 25.

Public surface (used by demo/awrdemo/sections/*.py):
  World                      -- params, identity, snaps, windows, catalogs
  World.hour(ts)             -> HourMetrics for the hour ENDING at ts
  World.hours(start, end)    -> [HourMetrics] for hours ending in (start, end]
  World.window_metrics(w)    -> HourMetrics aggregated over window w
  World.rng(*key)            -> seeded random.Random (stable per key)
HourMetrics fields are documented on the class.
"""
from __future__ import annotations

import hashlib
import math
import random
from dataclasses import dataclass, field
from datetime import datetime, timedelta
from functools import lru_cache

H = timedelta(hours=1)

# ---------------------------------------------------------------------
# Run parameters / identity
# ---------------------------------------------------------------------

DB_NAME = "ORCLPRD"
HOST_NAME = "prd-ora-01.corp.example"
DB_VERSION = "19.0.0.0.0"
DBID = 1483726519
CALLER_USER = "AWR_READER"
AWR_VERSION = "1.4.0"

TARGET_END = datetime(2026, 9, 10, 10, 0)      # Thursday
WIN_HOURS = 1
WEEKS_BACK = 12
STEP = 1
STEP_UNIT = "w"
STEP_HOURS = 168.0
TOP_N = 10
INST_NUM = 0
TEMPLATE = "comprehensive"
PROFILE_DAYS = 7
SQLMON_DETAIL = 3
RUN_ID = "20260910101512483"
GENERATED_AT = "2026-09-10 10:15:12 +02:00"
REPORT_TS = "202609101015"

MARKERS = [
    (datetime(2026, 6, 30, 22, 0), "Release 4.0"),
    (datetime(2026, 7, 3, 9, 0), "Hotfix 4.0.1"),
    (datetime(2026, 7, 21, 1, 0), "RU 19.28 patch"),
    (datetime(2026, 8, 11, 22, 0), "Release 4.1"),
    (datetime(2026, 9, 8, 22, 0), "Release 4.2"),
]

# Snapshot grid: hourly, from well before the first compared window (the
# day profile needs 8 days, the SQL Monitor "new" test needs the span).
SNAP_FIRST = datetime(2026, 6, 1, 0, 0)
SNAP_ID_BASE = 41000
RESTART_AT = datetime(2026, 7, 21, 0, 40)      # RU patch bounce
STARTUP_BEFORE = datetime(2026, 3, 14, 4, 12, 37)
STARTUP_AFTER = datetime(2026, 7, 21, 0, 51, 9)


def _seed(*key) -> int:
    h = hashlib.md5("|".join(str(k) for k in key).encode()).hexdigest()
    return int(h[:12], 16)


def rng(*key) -> random.Random:
    return random.Random(_seed(*key))


def fmt_one(h: float) -> str:
    """Twin of the driver's fmt_one (compact hour label)."""
    if h < 1 and (h * 60) % 1 == 0:
        return f"{round(h*60)}m"
    if h % 168 == 0:
        return f"{round(h/168)}w"
    if h % 24 == 0:
        return f"{round(h/24)}d"
    if h % 1 == 0:
        return f"{round(h)}h"
    return f"{h:.2f}".rstrip("0").rstrip(".") + "h"


# ---------------------------------------------------------------------
# Catalogs
# ---------------------------------------------------------------------

@dataclass
class Snap:
    snap_id: int
    end_ts: datetime
    begin_ts: datetime
    startup_time: datetime
    instance_number: int = 1
    dbid: int = DBID


@dataclass
class Window:
    week_offset: int
    win_start_ts: datetime
    win_end_ts: datetime
    begin_snap_id: int | None
    end_snap_id: int | None
    valid_flag: str            # 'Y' | 'N'
    skip_reason: str | None
    dur_sec: float
    dbid: int = DBID

    @property
    def valid(self) -> bool:
        return self.valid_flag == "Y"


@dataclass
class WaitEvent:
    name: str
    wait_class: str
    share: float        # share of (DB time - CPU) at baseline, foreground
    avg_us: float       # typical wait latency in microseconds
    bg: bool = False    # background (DBA_HIST_BG_EVENT_SUMMARY) event


# Foreground wait catalog.  Shares are of the non-CPU part of DB time at
# baseline; 'Idle' rows carry their own absolute AAS-equivalents instead.
FG_EVENTS = [
    WaitEvent("db file sequential read", "User I/O", 0.30, 480),
    WaitEvent("db file scattered read", "User I/O", 0.07, 1400),
    WaitEvent("direct path read", "User I/O", 0.09, 950),
    WaitEvent("direct path read temp", "User I/O", 0.025, 700),
    WaitEvent("db file parallel read", "User I/O", 0.035, 2600),
    WaitEvent("read by other session", "User I/O", 0.012, 520),
    WaitEvent("direct path write temp", "User I/O", 0.012, 800),
    WaitEvent("log file sync", "Commit", 0.17, 1900),
    WaitEvent("enq: TX - row lock contention", "Application", 0.045, 48000),
    WaitEvent("SQL*Net break/reset to client", "Application", 0.006, 900),
    WaitEvent("enq: TX - index contention", "Concurrency", 0.012, 6000),
    WaitEvent("buffer busy waits", "Concurrency", 0.026, 1100),
    WaitEvent("latch: cache buffers chains", "Concurrency", 0.02, 60),
    WaitEvent("library cache: mutex X", "Concurrency", 0.012, 250),
    WaitEvent("cursor: pin S wait on X", "Concurrency", 0.008, 3200),
    WaitEvent("latch: shared pool", "Concurrency", 0.004, 90),
    WaitEvent("SQL*Net more data to client", "Network", 0.03, 45),
    WaitEvent("SQL*Net more data from client", "Network", 0.01, 120),
    WaitEvent("log buffer space", "Configuration", 0.01, 3500),
    WaitEvent("free buffer waits", "Configuration", 0.006, 2100),
    WaitEvent("log file switch completion", "Configuration", 0.004, 22000),
    WaitEvent("enq: HW - contention", "Configuration", 0.003, 15000),
    WaitEvent("control file sequential read", "System I/O", 0.03, 210),
    WaitEvent("resmgr:cpu quantum", "Scheduler", 0.02, 4000),
    WaitEvent("PGA memory operation", "Other", 0.02, 18),
    WaitEvent("ASM file metadata operation", "Other", 0.006, 150),
    WaitEvent("reliable message", "Other", 0.008, 900),
    WaitEvent("enq: RO - fast object reuse", "Other", 0.003, 12000),
    WaitEvent("SQL*Net message from client", "Idle", 0.0, 15000),
    WaitEvent("SQL*Net message to client", "Idle", 0.0, 3),
    WaitEvent("jobq slave wait", "Idle", 0.0, 500000),
    WaitEvent("PX Deq: Execution Msg", "Idle", 0.0, 4000),
]

BG_EVENTS = [
    WaitEvent("db file parallel write", "System I/O", 0.30, 1500, True),
    WaitEvent("log file parallel write", "System I/O", 0.26, 900, True),
    WaitEvent("db file async I/O submit", "System I/O", 0.10, 600, True),
    WaitEvent("log file sequential read", "System I/O", 0.05, 800, True),
    WaitEvent("control file parallel write", "System I/O", 0.06, 2600, True),
    WaitEvent("control file sequential read", "System I/O", 0.04, 200, True),
    WaitEvent("LGWR wait for redo copy", "Other", 0.02, 40, True),
    WaitEvent("os thread creation", "Other", 0.03, 9000, True),
    WaitEvent("oracle thread bootstrap", "Other", 0.02, 25000, True),
    WaitEvent("latch free", "Other", 0.01, 70, True),
    WaitEvent("enq: CF - contention", "Other", 0.01, 8000, True),
    WaitEvent("direct path write", "User I/O", 0.05, 1200, True),
    WaitEvent("Data file init write", "User I/O", 0.01, 3000, True),
    WaitEvent("log file switch (checkpoint incomplete)", "Configuration", 0.03, 60000, True),
    WaitEvent("rdbms ipc message", "Idle", 0.0, 2800000, True),
    WaitEvent("DIAG idle wait", "Idle", 0.0, 1000000, True),
    WaitEvent("Space Manager: slave idle wait", "Idle", 0.0, 5000000, True),
    WaitEvent("smon timer", "Idle", 0.0, 300000000, True),
    WaitEvent("pmon timer", "Idle", 0.0, 3000000, True),
    WaitEvent("ASM background timer", "Idle", 0.0, 5000000, True),
]

WAIT_CLASSES = ["CPU", "Scheduler", "User I/O", "System I/O", "Concurrency",
                "Application", "Commit", "Configuration", "Administrative",
                "Network", "Queueing", "Cluster", "Other"]


@dataclass
class SqlDef:
    sql_id: str
    schema: str
    module: str
    action: str
    text: str
    execs_h: float          # executions per hour at intensity 1.0
    ela_us: float           # elapsed per execution (microseconds)
    cpu_frac: float         # CPU share of elapsed
    gets: float             # buffer gets per execution
    reads: float            # disk reads per execution
    rows: float             # rows per execution
    plan_hash: int
    waits: dict = field(default_factory=dict)   # event -> share of non-CPU elapsed
    profile: str = "oltp"   # oltp | batch_night | hourly | reporting | sys
    first_seen: datetime | None = None          # None = always existed


SQLS = [
    SqlDef("7k2m9dx4qp1zb", "ORDERS_APP", "OrderService", "order-lookup",
           "SELECT o.order_id, o.status, o.total_amount, l.line_no, l.sku, l.qty, l.unit_price "
           "FROM orders o JOIN order_lines l ON l.order_id = o.order_id "
           "WHERE o.customer_id = :1 AND o.created_at > :2 ORDER BY o.created_at DESC",
           910000, 2100, 0.72, 38, 0.9, 6.2, 3197245811,
           {"db file sequential read": 0.85, "SQL*Net more data to client": 0.15}),
    SqlDef("g3c8w1a2nfy5r", "ORDERS_APP", "OrderService", "checkout",
           "INSERT INTO orders (order_id, customer_id, status, total_amount, created_at, channel) "
           "VALUES (orders_seq.NEXTVAL, :1, :2, :3, SYSTIMESTAMP, :4)",
           118000, 1650, 0.45, 22, 0.15, 1, 1466803562,
           {"log file sync": 0.7, "buffer busy waits": 0.2, "enq: TX - index contention": 0.1}),
    SqlDef("b6f4h0kq3ztr8", "ORDERS_APP", "OrderService", "checkout",
           "INSERT INTO order_lines (order_id, line_no, sku, qty, unit_price) VALUES (:1, :2, :3, :4, :5)",
           385000, 780, 0.55, 14, 0.05, 1, 2611947330,
           {"log file sync": 0.5, "buffer busy waits": 0.35, "enq: TX - index contention": 0.15}),
    SqlDef("2yq9jv7c5hm3d", "ORDERS_APP", "OrderService", "checkout",
           "UPDATE inventory SET qty_on_hand = qty_on_hand - :1, last_modified = SYSTIMESTAMP "
           "WHERE sku = :2 AND warehouse_id = :3",
           372000, 2900, 0.30, 9, 0.2, 1, 902817346,
           {"enq: TX - row lock contention": 0.75, "log file sync": 0.15, "db file sequential read": 0.1}),
    SqlDef("d8s3n5tw2xk7f", "INVENTORY", "InventorySync", "sync",
           "MERGE INTO inventory i USING (SELECT sku, warehouse_id, qty, last_update FROM inv_feed_stage "
           "WHERE batch_id = :1) s ON (i.sku = s.sku AND i.warehouse_id = s.warehouse_id) "
           "WHEN MATCHED THEN UPDATE SET i.qty_on_hand = s.qty WHEN NOT MATCHED THEN INSERT (...) VALUES (...)",
           4, 38_000_000, 0.55, 2_900_000, 61000, 210000, 3350188817,
           {"db file scattered read": 0.4, "db file sequential read": 0.35, "log file sync": 0.1,
            "enq: TX - row lock contention": 0.15}, "hourly"),
    SqlDef("f1p7r4mz8vb2c", "ORDERS_APP", "OrderService", "customer-profile",
           "SELECT c.customer_id, c.email, c.tier, a.line1, a.city, a.postcode, a.country "
           "FROM customers c JOIN addresses a ON a.customer_id = c.customer_id AND a.is_default = 'Y' "
           "WHERE c.customer_id = :1",
           1_420_000, 410, 0.80, 7, 0.08, 1, 4172308451,
           {"db file sequential read": 0.9, "latch: cache buffers chains": 0.1}),
    SqlDef("9wz2ke6yq4tn1", "REPORTING", "ReportEngine", "daily-sales",
           "SELECT /*+ PARALLEL(sf 8) */ sf.region_id, sf.channel, TRUNC(sf.sale_ts) AS sale_day, "
           "SUM(sf.amount) AS revenue, COUNT(*) AS orders FROM sales_fact sf "
           "WHERE sf.sale_ts >= :1 AND sf.sale_ts < :2 GROUP BY sf.region_id, sf.channel, TRUNC(sf.sale_ts)",
           1, 214_000_000, 0.42, 4_100_000, 3_650_000, 1840, 2789504216,
           {"direct path read": 0.85, "PX Deq: Execution Msg": 0.0, "direct path read temp": 0.15}, "hourly"),
    SqlDef("h5x1c9pa7rd3s", "REPORTING", "ReportEngine", "inventory-aging",
           "SELECT w.warehouse_name, p.category, SUM(CASE WHEN h.age_days > 90 THEN h.qty END) AS aged_qty, "
           "SUM(h.qty * p.unit_cost) AS stock_value FROM inventory_hist h JOIN products p ON p.sku = h.sku "
           "JOIN warehouses w ON w.warehouse_id = h.warehouse_id WHERE h.snapshot_date = :1 "
           "GROUP BY w.warehouse_name, p.category",
           1, 96_000_000, 0.50, 1_850_000, 920_000, 412, 1655218763,
           {"direct path read": 0.6, "db file scattered read": 0.25, "direct path read temp": 0.15}, "hourly"),
    SqlDef("k4m8v2bn6ws9e", "LOYALTY", "LoyaltyService", "points-accrual",
           "INSERT INTO loyalty_ledger (ledger_id, customer_id, order_id, points, reason, created_at) "
           "VALUES (loyalty_seq.NEXTVAL, :1, :2, :3, :4, SYSTIMESTAMP)",
           116000, 920, 0.5, 11, 0.05, 1, 3946117820,
           {"log file sync": 0.6, "buffer busy waits": 0.25, "enq: TX - index contention": 0.15},
           "oltp", datetime(2026, 8, 11, 22, 0)),
    SqlDef("n7t3q5xc1yj4g", "LOYALTY", "LoyaltyService", "points-balance",
           "SELECT NVL(SUM(points), 0) AS balance, MAX(created_at) AS last_activity "
           "FROM loyalty_ledger WHERE customer_id = :1",
           640000, 1400, 0.85, 61, 0.7, 1, 1288463905,
           {"db file sequential read": 0.9, "latch: cache buffers chains": 0.1},
           "oltp", datetime(2026, 8, 11, 22, 0)),
    SqlDef("s9e4y7mk2cq6v", "ORDERS_APP", "OrderService", "order-status",
           "UPDATE orders SET status = :1, updated_at = SYSTIMESTAMP WHERE order_id = :2",
           205000, 610, 0.55, 6, 0.1, 1, 622053178,
           {"log file sync": 0.8, "db file sequential read": 0.2}),
    SqlDef("t3h6u1zr9nb8w", "ORDERS_APP", "OrderService", "cart",
           "SELECT ci.sku, ci.qty, p.name, p.list_price, p.image_url FROM cart_items ci "
           "JOIN products p ON p.sku = ci.sku WHERE ci.session_id = :1",
           1_180_000, 520, 0.78, 12, 0.12, 3.4, 3527641099,
           {"db file sequential read": 0.8, "SQL*Net more data to client": 0.2}),
    SqlDef("v8c2l5qs3wd7m", "INVENTORY", "DBMS_SCHEDULER", "REORDER_CHECK_JOB",
           "SELECT i.sku, i.warehouse_id, i.qty_on_hand, i.reorder_level, i.reorder_qty FROM inventory i "
           "WHERE i.qty_on_hand < i.reorder_level AND i.active = 'Y'",
           1, 41_000_000, 0.35, 1_240_000, 610_000, 18300, 2098345671,
           {"db file scattered read": 0.9, "read by other session": 0.1}, "hourly"),
    SqlDef("w1n9k3pf6tx4a", "REPORTING", "SQL*Plus", "",
           "DELETE FROM sales_fact_stage WHERE load_date < :1",
           1, 388_000_000, 0.28, 6_200_000, 1_150_000, 2_450_000, 1913066235,
           {"db file scattered read": 0.5, "log file sync": 0.1, "db file sequential read": 0.3,
            "free buffer waits": 0.1}, "batch_night"),
    SqlDef("x6j2d8rq5vm1b", "SYS", "DBMS_SCHEDULER", "ORA$AT_OS_OPT_SY_2371",
           "call dbms_stats.gather_database_stats_job_proc ( )",
           1, 2_640_000_000, 0.62, 48_000_000, 9_800_000, 1, 0,
           {"db file scattered read": 0.55, "direct path read": 0.35, "direct path read temp": 0.1}, "batch_night"),
    SqlDef("y4a7f1sk9cz3n", "DBSNMP", "emagent_SQL_oracle_database", "",
           "SELECT metric_name, value FROM v$sysmetric WHERE group_id = 2 AND metric_name IN (:1, :2, :3, :4)",
           2400, 180, 0.95, 3, 0, 4, 1730926184, {}, "sys"),
    SqlDef("z2b5g8wt4dn6p", "SYS", "sqlplus@prd-ora-01 (TNS V1-V3)", "",
           "select o.obj#, o.type#, o.name, u.name from sys.obj$ o, sys.user$ u where o.owner# = u.user# "
           "and o.type# in (1, 2) and bitand(o.flags, 128) = 0",
           30, 92000, 0.88, 4100, 12, 8600, 3814905027,
           {"db file sequential read": 1.0}, "sys"),
    SqlDef("c7v3m6hq1kf9e", "ORDERS_APP", "PaymentGateway", "authorize",
           "INSERT INTO payments (payment_id, order_id, provider, auth_code, amount, status, created_at) "
           "VALUES (payments_seq.NEXTVAL, :1, :2, :3, :4, 'AUTH', SYSTIMESTAMP)",
           116000, 1500, 0.4, 16, 0.1, 1, 1090277735,
           {"log file sync": 0.85, "buffer busy waits": 0.15}),
    SqlDef("e1k8s4yn7pw2j", "ORDERS_APP", "PaymentGateway", "settle",
           "UPDATE payments SET status = 'SETTLED', settled_at = SYSTIMESTAMP "
           "WHERE status = 'AUTH' AND created_at < :1 AND provider = :2",
           1, 74_000_000, 0.4, 2_100_000, 380_000, 110_000, 806345113,
           {"db file sequential read": 0.6, "log file sync": 0.2, "log buffer space": 0.2}, "settle"),
    SqlDef("m5q1x9cb3rt7h", "ORDERS_APP", "OrderService", "order-lookup",
           "SELECT COUNT(*) FROM order_lines WHERE order_id = :1",
           905000, 140, 0.92, 4, 0.01, 1, 2475096182,
           {"db file sequential read": 1.0}),
    SqlDef("q8w4t2ve6ju3y", "REPORTING", "ReportEngine", "dashboard",
           "SELECT hour_ts, region_id, revenue, orders, avg_basket FROM mv_sales_hourly "
           "WHERE hour_ts >= :1 ORDER BY hour_ts DESC, region_id",
           18000, 6200, 0.7, 340, 8, 96, 651834720,
           {"db file scattered read": 0.7, "SQL*Net more data to client": 0.3}),
    SqlDef("r3z7n1md8ky5c", "INVENTORY", "InventorySync", "sync",
           "SELECT sku, warehouse_id, qty_on_hand, last_modified FROM inventory WHERE last_modified > :1",
           240, 2_600_000, 0.9, 210_000, 1400, 41000, 3082517486,
           {"db file scattered read": 1.0}, "hourly"),
    SqlDef("u9d5p3fw2hs8x", "ORDERS_APP", "OrderService", "search",
           "SELECT p.sku, p.name, p.list_price, SCORE(1) FROM products p "
           "WHERE CONTAINS(p.description, :1, 1) > 0 AND p.active = 'Y' ORDER BY SCORE(1) DESC FETCH FIRST 24 ROWS ONLY",
           96000, 9800, 0.9, 480, 2.5, 24, 1367128900,
           {"db file sequential read": 0.6, "SQL*Net more data to client": 0.4}),
    SqlDef("a4g6j2ct5nq1w", "LOYALTY", "DBMS_SCHEDULER", "LOYALTY_TIER_RECALC",
           "MERGE INTO customers c USING (SELECT customer_id, SUM(points) AS pts FROM loyalty_ledger "
           "WHERE created_at > ADD_MONTHS(SYSDATE, -12) GROUP BY customer_id) l ON (c.customer_id = l.customer_id) "
           "WHEN MATCHED THEN UPDATE SET c.tier = CASE WHEN l.pts > 5000 THEN 'GOLD' WHEN l.pts > 1000 THEN 'SILVER' ELSE 'BRONZE' END",
           1, 512_000_000, 0.45, 9_400_000, 2_100_000, 3_900_000, 2210476903,
           {"direct path read": 0.5, "db file sequential read": 0.3, "log file sync": 0.1, "direct path read temp": 0.1},
           "batch_night", datetime(2026, 8, 11, 22, 0)),
    SqlDef("j6b1v4nr8xt2p", "ORDERS_APP", "OrderService", "order-lookup",
           "SELECT s.shipment_id, s.carrier, s.tracking_no, s.status, s.eta FROM shipments s WHERE s.order_id = :1",
           540000, 380, 0.82, 6, 0.06, 1.1, 4034711296,
           {"db file sequential read": 1.0}),
]

OLTP_SCALE = 3.6      # execs_h in the catalog are "per-service" figures
CPU_COUNT = 16

# Release 4.2 plan flip of the order-lookup statement.
ORDER_LOOKUP_SQL = "7k2m9dx4qp1zb"
ORDER_LOOKUP_BAD_PLAN = 2088341150


@dataclass
class Segment:
    owner: str
    name: str
    object_type: str
    tablespace: str
    obj_no: int
    reads_h: float      # physical reads (blocks) per hour at intensity 1
    writes_h: float
    logical_h: float
    read_req_ratio: float = 0.85   # requests per block read (multi-block -> lower)
    write_req_ratio: float = 0.6


SEGMENTS = [
    Segment("ORDERS_APP", "ORDER_LINES", "TABLE", "TS_ORDERS_DATA", 78412, 8_400_000, 1_150_000, 480_000_000),
    Segment("ORDERS_APP", "ORDER_LINES_PK", "INDEX", "TS_ORDERS_IDX", 78413, 3_900_000, 620_000, 210_000_000),
    Segment("ORDERS_APP", "ORDER_LINES_ORD_IX", "INDEX", "TS_ORDERS_IDX", 78414, 2_100_000, 410_000, 150_000_000),
    Segment("ORDERS_APP", "ORDERS", "TABLE", "TS_ORDERS_DATA", 78402, 5_600_000, 690_000, 320_000_000),
    Segment("ORDERS_APP", "ORDERS_PK", "INDEX", "TS_ORDERS_IDX", 78403, 2_400_000, 310_000, 190_000_000),
    Segment("ORDERS_APP", "ORDERS_CUST_CREATED_IX", "INDEX", "TS_ORDERS_IDX", 78405, 1_900_000, 300_000, 120_000_000),
    Segment("ORDERS_APP", "INVENTORY", "TABLE", "TS_ORDERS_DATA", 78430, 1_700_000, 980_000, 260_000_000),
    Segment("ORDERS_APP", "INVENTORY_PK", "INDEX", "TS_ORDERS_IDX", 78431, 800_000, 260_000, 110_000_000),
    Segment("ORDERS_APP", "CUSTOMERS", "TABLE", "TS_ORDERS_DATA", 78420, 2_300_000, 90_000, 140_000_000),
    Segment("ORDERS_APP", "ADDRESSES", "TABLE", "TS_ORDERS_DATA", 78422, 1_100_000, 40_000, 70_000_000),
    Segment("ORDERS_APP", "PRODUCTS", "TABLE", "TS_ORDERS_DATA", 78440, 900_000, 20_000, 96_000_000),
    Segment("ORDERS_APP", "PAYMENTS", "TABLE", "TS_ORDERS_DATA", 78450, 1_300_000, 420_000, 60_000_000),
    Segment("ORDERS_APP", "CART_ITEMS", "TABLE", "TS_ORDERS_DATA", 78460, 1_500_000, 380_000, 88_000_000),
    Segment("ORDERS_APP", "SHIPMENTS", "TABLE", "TS_ORDERS_DATA", 78470, 700_000, 160_000, 38_000_000),
    Segment("REPORTING", "SALES_FACT", "TABLE PARTITION", "TS_DW_DATA", 91208, 6_800_000, 1_400_000, 41_000_000, 0.12, 0.25),
    Segment("REPORTING", "SALES_FACT_STAGE", "TABLE", "TS_DW_STAGE", 91230, 1_200_000, 1_600_000, 12_000_000, 0.15, 0.3),
    Segment("REPORTING", "INVENTORY_HIST", "TABLE PARTITION", "TS_DW_DATA", 91240, 1_900_000, 220_000, 9_000_000, 0.12, 0.3),
    Segment("REPORTING", "MV_SALES_HOURLY", "TABLE", "TS_DW_DATA", 91250, 420_000, 180_000, 21_000_000, 0.3),
    Segment("LOYALTY", "LOYALTY_LEDGER", "TABLE", "TS_LOYALTY", 93110, 900_000, 520_000, 62_000_000),
    Segment("LOYALTY", "LOYALTY_LEDGER_CUST_IX", "INDEX", "TS_LOYALTY", 93111, 1_400_000, 300_000, 95_000_000),
    Segment("SYS", "I_OBJ2", "INDEX", "SYSTEM", 37, 60_000, 2_000, 4_000_000),
    Segment("SYS", "WRH$_ACTIVE_SESSION_HISTORY", "TABLE PARTITION", "SYSAUX", 12455, 90_000, 260_000, 1_200_000),
    Segment("SYS", "WRH$_SQLSTAT", "TABLE PARTITION", "SYSAUX", 12470, 40_000, 120_000, 600_000),
]


@dataclass
class DataFile:
    file_id: int
    name: str
    tablespace: str
    is_temp: bool = False
    weight: float = 1.0     # share of I/O within its tablespace group


FILES = [
    DataFile(1, "+DATA/ORCLPRD/DATAFILE/system.256.1128937611", "SYSTEM"),
    DataFile(3, "+DATA/ORCLPRD/DATAFILE/sysaux.257.1128937665", "SYSAUX"),
    DataFile(4, "+DATA/ORCLPRD/DATAFILE/undotbs1.258.1128937703", "UNDOTBS1"),
    DataFile(7, "+DATA/ORCLPRD/DATAFILE/ts_orders_data.301.1131588213", "TS_ORDERS_DATA", weight=0.4),
    DataFile(8, "+DATA/ORCLPRD/DATAFILE/ts_orders_data.302.1131588221", "TS_ORDERS_DATA", weight=0.35),
    DataFile(9, "+DATA/ORCLPRD/DATAFILE/ts_orders_data.303.1136220407", "TS_ORDERS_DATA", weight=0.25),
    DataFile(10, "+DATA/ORCLPRD/DATAFILE/ts_orders_idx.304.1131588239", "TS_ORDERS_IDX", weight=0.55),
    DataFile(11, "+DATA/ORCLPRD/DATAFILE/ts_orders_idx.305.1131588247", "TS_ORDERS_IDX", weight=0.45),
    DataFile(12, "+DATA/ORCLPRD/DATAFILE/ts_dw_data.310.1131590011", "TS_DW_DATA", weight=0.5),
    DataFile(13, "+DATA/ORCLPRD/DATAFILE/ts_dw_data.311.1131590019", "TS_DW_DATA", weight=0.5),
    DataFile(14, "+DATA/ORCLPRD/DATAFILE/ts_dw_stage.312.1131590027", "TS_DW_STAGE"),
    DataFile(15, "+DATA/ORCLPRD/DATAFILE/ts_loyalty.320.1146701253", "TS_LOYALTY"),
    DataFile(1, "+DATA/ORCLPRD/TEMPFILE/temp.259.1128937717", "TEMP", True, 0.5),
    DataFile(2, "+DATA/ORCLPRD/TEMPFILE/temp.260.1128937719", "TEMP", True, 0.5),
]

FILETYPES = ["Data File", "Temp File", "Log File", "Control File", "Archive Log",
             "Flashback Log", "Other"]


@dataclass
class ParamChange:
    name: str
    old: str
    new: str
    at: datetime


PARAM_CHANGES = [
    ParamChange("cursor_sharing", "EXACT", "FORCE", datetime(2026, 7, 3, 9, 0)),
    ParamChange("sga_target", "51539607552", "68719476736", datetime(2026, 7, 21, 1, 0)),
    ParamChange("pga_aggregate_target", "8589934592", "12884901888", datetime(2026, 8, 11, 22, 0)),
    ParamChange("optimizer_adaptive_plans", "FALSE", "TRUE", datetime(2026, 9, 8, 22, 0)),
]

# Static parameters that never change (for the "differs across windows"
# section only the PARAM_CHANGES matter; these are here for completeness).
PARAMS_STATIC = {
    "compatible": "19.0.0", "db_block_size": "8192", "processes": "3000",
    "sessions": "4544", "open_cursors": "2000", "optimizer_mode": "ALL_ROWS",
    "optimizer_adaptive_statistics": "FALSE", "db_files": "1024",
    "log_buffer": "268435456", "undo_retention": "3600", "parallel_max_servers": "192",
    "filesystemio_options": "SETALL", "db_writer_processes": "8",
    "result_cache_max_size": "268435456", "memory_target": "0",
}


# ---------------------------------------------------------------------
# Workload shape
# ---------------------------------------------------------------------

_HOD = [0.34, 0.30, 0.29, 0.30, 0.31, 0.36, 0.48, 0.66, 0.84, 0.96, 1.00, 1.00,
        0.94, 0.97, 1.00, 0.98, 0.92, 0.84, 0.74, 0.66, 0.60, 0.54, 0.46, 0.39]


def base_intensity(ts: datetime) -> float:
    """Business intensity of the hour ENDING at ts (0.29 .. ~1.09)."""
    h = (ts - H)                      # hour start
    hod = _HOD[h.hour]
    dow = h.weekday()
    if dow == 5:
        hod = 0.30 + (hod - 0.30) * 0.50
    elif dow == 6:
        hod = 0.30 + (hod - 0.30) * 0.38
    days = (h - SNAP_FIRST).total_seconds() / 86400
    growth = 1.0 + 0.09 * days / 101.0
    return hod * growth


def batch_factor(ts: datetime) -> float:
    """Nightly batch (01:00-03:00) I/O-heavy bump; month-end close evenings."""
    h = ts - H
    f = 0.0
    if h.hour in (1, 2):
        f += 1.0
    if h.hour == 3:
        f += 0.35
    return f


def month_end_factor(ts: datetime) -> float:
    h = ts - H
    nxt = (h + timedelta(days=1)).day == 1
    if nxt and 17 <= h.hour <= 23:
        return 1.0 - abs(h.hour - 20) * 0.18
    return 0.0


def _decay(ts: datetime, start: datetime, hours: float, tau_h: float) -> float:
    """1.0 at `start`, exponentially decaying with time constant tau_h, zero
    before start and after start+hours."""
    if ts <= start:
        return 0.0
    dt = (ts - start).total_seconds() / 3600
    if dt > hours:
        return 0.0
    return math.exp(-dt / tau_h)


@dataclass
class Effects:
    """Multipliers layered on the baseline for one hour."""
    dbtime: float = 1.0
    cpu: float = 1.0
    phys_reads: float = 1.0
    scans: float = 1.0
    hard_parse: float = 1.0
    concurrency: float = 1.0     # library cache mutex / cursor pin
    row_lock: float = 1.0
    commit: float = 1.0          # log file sync latency
    order_lookup_bad: float = 0.0  # 0..1 share of order-lookup execs on the bad plan
    loyalty: float = 0.0         # 0..1 feature enabled
    cold_cache: float = 0.0


def effects(ts: datetime) -> Effects:
    e = Effects()
    # Release 4.0: hard-parse storm until Hotfix 4.0.1
    r40, hf = MARKERS[0][0], MARKERS[1][0]
    if r40 < ts <= hf + H:
        k = 1.0 - 0.35 * ((ts - r40).total_seconds() / (hf - r40).total_seconds())
        e.hard_parse *= 1 + 14 * k
        e.concurrency *= 1 + 9 * k
        e.cpu *= 1 + 0.55 * k
        e.dbtime *= 1 + 0.75 * k
    # RU patch: restart + cold cache
    ru = MARKERS[2][0]
    d = _decay(ts, ru, 5, 1.6)
    if d:
        e.cold_cache = d
        e.phys_reads *= 1 + 2.4 * d
        e.dbtime *= 1 + 0.6 * d
    # Release 4.1: loyalty feature (+ steady load), row-lock day
    r41 = MARKERS[3][0]
    if ts > r41:
        e.loyalty = 1.0
        e.dbtime *= 1.12
        e.cpu *= 1.10
    d = _decay(ts, r41 + timedelta(hours=9), 30, 9)
    if d:
        e.row_lock *= 1 + 12 * d
        e.dbtime *= 1 + 0.5 * d
    # Aug 25 log file sync incident (storage latency), 90 min
    inc = datetime(2026, 8, 25, 14, 0)
    if inc < ts <= inc + timedelta(hours=2):
        k = 1.0 if ts <= inc + H else 0.45
        e.commit *= 1 + 11 * k
        e.dbtime *= 1 + 0.9 * k
    # Release 4.2: adaptive plan flip of the order lookup -- persists
    r42 = MARKERS[4][0]
    if ts > r42:
        ramp = min(1.0, (ts - r42).total_seconds() / 7200)
        e.order_lookup_bad = ramp
        e.phys_reads *= 1 + 0.9 * ramp
        e.scans *= 1 + 7 * ramp
        e.dbtime *= 1 + 0.30 * ramp
        e.cpu *= 1 + 0.02 * ramp
    return e


# ---------------------------------------------------------------------
# Hourly metrics
# ---------------------------------------------------------------------

LOAD_STATS = [
    "redo size", "redo size for lost write detection", "DB time", "DB CPU",
    "CPU used by this session", "session logical reads", "physical reads",
    "physical read total bytes", "physical writes", "physical write total bytes",
    "user calls", "user commits", "user rollbacks", "execute count",
    "parse count (total)", "parse count (hard)", "parse count (failures)",
    "sorts (memory)", "sorts (disk)", "sorts (rows)", "logons cumulative",
    "opened cursors cumulative", "redo writes", "table scans (long tables)",
    "table fetch by rowid", "bytes sent via SQL*Net to client",
    "bytes received via SQL*Net from client",
    # extras some sections / the day profile touch
    "db block changes", "table scans (short tables)", "physical read IO requests",
    "physical write IO requests",
]

SYSMETRICS = [
    "Host CPU Utilization (%)", "Database CPU Time Ratio", "Database Wait Time Ratio",
    "Average Active Sessions", "Average Synchronous Single-Block Read Latency",
    "Physical Reads Per Sec", "Physical Writes Per Sec",
    "Physical Read Total IO Requests Per Sec", "Physical Write Total IO Requests Per Sec",
    "Physical Read Total Bytes Per Sec", "Physical Write Total Bytes Per Sec",
    "Redo Generated Per Sec", "Logons Per Sec", "Logical Reads Per Sec",
    "User Calls Per Sec", "User Commits Per Sec", "User Rollbacks Per Sec",
    "Executions Per Sec", "Hard Parse Count Per Sec", "Total Parse Count Per Sec",
    "Session Count", "Network Traffic Volume Per Sec", "SQL Service Response Time",
    "User Transaction Per Sec", "Open Cursors Per Sec", "Current Logons Count",
    "Current Open Cursors Count", "DB Block Changes Per Sec", "I/O Megabytes per Second",
    "I/O Requests per Second", "CPU Usage Per Sec", "Response Time Per Txn",
    "Buffer Cache Hit Ratio", "Library Cache Hit Ratio", "Soft Parse Ratio",
    "Execute Without Parse Ratio", "Temp Space Used", "Total PGA Allocated",
]


@dataclass
class SqlHour:
    execs: float
    elapsed_us: float
    cpu_us: float
    gets: float
    reads: float
    rows: float
    iowait_us: float
    plan_hash: int
    waits: dict          # event -> microseconds (non-CPU elapsed split)


@dataclass
class HourMetrics:
    """Everything the report reads for ONE hour (the AWR snap interval
    ending at `ts`).  All *_delta style quantities are per-hour totals;
    rates are derived by consumers as total / dur_sec.

      ts            hour end (== snap end_interval_time)
      dur_sec       3600 (or the resolved span when aggregated)
      intensity     business intensity used for the hour
      load          {stat_name: total for the hour}   (DBA_HIST_SYSSTAT delta)
      sysmetric     {metric_name: value}              (SYSMETRIC_SUMMARY avg)
      time_model    {'DB time','DB CPU','background elapsed time',
                     'background cpu time'}  microseconds
      fg_waits      {event: (wait_class, total_waits, time_waited_us)}
      bg_waits      same, DBA_HIST_BG_EVENT_SUMMARY
      ash_class     {wait_class: samples}  ('CPU' included; Idle excluded)
      ash_events    {(wait_class, event): samples}  ('CPU','CPU') included
      sql           {sql_id: SqlHour}   (DBA_HIST_SQLSTAT *_DELTA)
      ash_sql       {sql_id: {event: samples}}   ('CPU' key for on-CPU)
      seg           {(owner,name): (phys_reads, phys_writes, read_reqs,
                                    write_reqs, logical_reads)}
      files         {(is_temp,file_id): (phyrds, phywrts, phyblkrd,
                                          phyblkwrt, readtim_cs, writetim_cs)}
      iostat        {filetype: (read_mb, write_mb, read_reqs, write_reqs)}
    """
    ts: datetime
    dur_sec: float
    intensity: float
    effects: Effects
    load: dict
    sysmetric: dict
    time_model: dict
    fg_waits: dict
    bg_waits: dict
    ash_class: dict
    ash_events: dict
    sql: dict
    ash_sql: dict
    seg: dict
    files: dict
    iostat: dict


def _noise(r: random.Random, sd: float = 0.04) -> float:
    return max(0.5, 1.0 + r.gauss(0, sd))


def _sql_execs(s: SqlDef, ts: datetime, inten: float, e: Effects, r: random.Random) -> float:
    h = ts - H
    if s.first_seen and ts <= s.first_seen:
        return 0.0
    if s.profile == "oltp":
        n = s.execs_h * OLTP_SCALE * inten * _noise(r, 0.03)
        if s.schema == "LOYALTY":
            n *= e.loyalty
        return n
    if s.profile == "hourly":
        if s.sql_id == "9wz2ke6yq4tn1":          # daily-sales: hourly refresh + 06:00 full
            return 1 + (3 if h.hour == 6 else 0)
        if s.sql_id == "h5x1c9pa7rd3s":          # inventory-aging: 4x a day
            return 1 if h.hour in (0, 6, 12, 18) else 0
        if s.sql_id == "d8s3n5tw2xk7f":          # inventory merge: every 15 min
            return 4
        if s.sql_id == "v8c2l5qs3wd7m":          # reorder job: hourly
            return 1
        if s.sql_id == "r3z7n1md8ky5c":          # inventory delta poll: every 15 s
            return 240
        return 1
    if s.profile == "batch_night":
        if s.sql_id == "w1n9k3pf6tx4a":
            return 1 if h.hour == 1 else 0
        if s.sql_id == "x6j2d8rq5vm1b":
            return 1 if (h.hour == 22 and h.weekday() < 5) or (h.hour == 6 and h.weekday() >= 5) else 0
        if s.sql_id == "a4g6j2ct5nq1w":
            return 1 if h.hour == 2 else 0
        return 0
    if s.profile == "settle":
        return 1 if h.hour == 23 else 0
    if s.profile == "sys":
        return s.execs_h * OLTP_SCALE * _noise(r, 0.02)
    return 0.0


def _sql_hour(s: SqlDef, ts: datetime, inten: float, e: Effects, r: random.Random) -> SqlHour | None:
    n = _sql_execs(s, ts, inten, e, r)
    if n <= 0:
        return None
    ela = s.ela_us * _noise(r, 0.05)
    cpu_frac = s.cpu_frac
    gets, reads, rows = s.gets, s.reads, s.rows
    plan = s.plan_hash
    waits = dict(s.waits)
    # per-statement story hooks
    if s.sql_id == ORDER_LOOKUP_SQL and e.order_lookup_bad > 0:
        b = e.order_lookup_bad
        ela = s.ela_us * (1 - b) + 9_000 * b
        gets = s.gets * (1 - b) + 700 * b
        reads = s.reads * (1 - b) + 14 * b
        cpu_frac = 0.72 * (1 - b) + 0.16 * b
        waits = {"db file scattered read": 0.55, "direct path read": 0.30,
                 "SQL*Net more data to client": 0.15} if b > 0.5 else waits
        plan = ORDER_LOOKUP_BAD_PLAN if b > 0.5 else s.plan_hash
    if s.sql_id == "n7t3q5xc1yj4g":              # loyalty balance: ledger grows
        days = max(0.0, (ts - MARKERS[3][0]).total_seconds() / 86400)
        g = 1 + 0.028 * days
        ela *= g
        gets *= g
        reads *= g
    if s.sql_id == "2yq9jv7c5hm3d" and e.row_lock > 1:
        ela *= 1 + 0.6 * (e.row_lock - 1)
    if "log file sync" in waits and e.commit > 1:
        ela *= 1 + 0.5 * (e.commit - 1) * (1 - cpu_frac) * waits["log file sync"]
    if e.cold_cache > 0 and reads > 0:
        reads *= 1 + 2.0 * e.cold_cache
        ela *= 1 + 0.5 * e.cold_cache
    if s.sql_id == "9wz2ke6yq4tn1" and (ts - H).hour == 6:
        ela *= 2.4                                  # the 06:00 full-day run
    elapsed = n * ela
    cpu = elapsed * cpu_frac
    noncpu = elapsed - cpu
    wsplit = {}
    tot = sum(waits.values()) or 1.0
    for ev, sh in waits.items():
        if sh > 0:
            wsplit[ev] = noncpu * sh / tot
    io_ev = {"db file sequential read", "db file scattered read", "direct path read",
             "direct path read temp", "direct path write temp", "read by other session",
             "db file parallel read"}
    iowait = sum(v for k, v in wsplit.items() if k in io_ev)
    return SqlHour(n, elapsed, cpu, n * gets, n * reads, n * rows, iowait, plan, wsplit)


@lru_cache(maxsize=4096)
def hour(ts: datetime) -> HourMetrics:
    """HourMetrics for the AWR interval ending at ts (must be on the hour)."""
    r = rng("hour", ts)
    inten = base_intensity(ts) * _noise(r, 0.035)
    e = effects(ts)
    bf = batch_factor(ts)
    mef = month_end_factor(ts)
    dur = 3600.0

    # ---- Top SQL first: DB time is built bottom-up from them + a residual
    sql = {}
    for s in SQLS:
        sh = _sql_hour(s, ts, inten, e, rng("sql", s.sql_id, ts))
        if sh:
            sql[s.sql_id] = sh
    sql_ela = sum(x.elapsed_us for x in sql.values())
    sql_cpu = sum(x.cpu_us for x in sql.values())

    # residual ("everything else": PL/SQL, recursive SQL, unlisted statements)
    resid_ela = (14e9 * inten + 6e9 * bf + 8e9 * mef) * e.dbtime * _noise(r, 0.05)
    resid_cpu = resid_ela * 0.58 * e.cpu / e.dbtime
    resid_cpu = min(resid_cpu, resid_ela * 0.9)
    db_time_us = sql_ela + resid_ela
    db_cpu_us = sql_cpu + resid_cpu
    # hard-parse storm burns extra CPU
    if e.hard_parse > 1:
        extra = 3e9 * inten * (e.hard_parse - 1) / 14
        db_time_us += extra
        db_cpu_us += extra * 0.85
    db_cpu_us = min(db_cpu_us, db_time_us * 0.92)
    noncpu_us = db_time_us - db_cpu_us

    # ---- foreground waits: sum the SQL-level splits + residual by catalog share
    ev_us = {}
    for x in sql.values():
        for ev, us in x.waits.items():
            ev_us[ev] = ev_us.get(ev, 0.0) + us
    sql_wait = sum(ev_us.values())
    resid_wait = max(0.0, noncpu_us - sql_wait)
    shares = {ev.name: ev.share for ev in FG_EVENTS if ev.wait_class != "Idle"}
    # story multipliers on the residual split
    mult = {}
    for ev in FG_EVENTS:
        m = 1.0
        if ev.name in ("library cache: mutex X", "cursor: pin S wait on X", "latch: shared pool"):
            m *= e.concurrency
        if ev.name == "enq: TX - row lock contention":
            m *= e.row_lock
        if ev.name == "log file sync":
            m *= e.commit
        if ev.wait_class == "User I/O":
            m *= 1 + 0.35 * (e.phys_reads - 1)
        mult[ev.name] = m
    tot = sum(shares[k] * mult[k] for k in shares) or 1.0
    for k in shares:
        ev_us[k] = ev_us.get(k, 0.0) + resid_wait * shares[k] * mult[k] / tot
    # normalise so the sum is exactly noncpu_us (story multipliers grew it)
    tot_now = sum(ev_us.values()) or 1.0
    scale = noncpu_us / tot_now
    ev_us = {k: v * scale for k, v in ev_us.items()}
    fg = {}
    for ev in FG_EVENTS:
        if ev.wait_class == "Idle":
            if ev.name == "SQL*Net message from client":
                cnt = 3_600 * 5200 * inten * 1.05
                tw = cnt * ev.avg_us * 1.4
            elif ev.name == "SQL*Net message to client":
                cnt = 3_600 * 5200 * inten * 1.05
                tw = cnt * ev.avg_us
            elif ev.name == "jobq slave wait":
                cnt = 7200
                tw = cnt * ev.avg_us
            else:
                cnt = 40000 * inten
                tw = cnt * ev.avg_us
            fg[ev.name] = (ev.wait_class, cnt, tw)
            continue
        us = ev_us.get(ev.name, 0.0)
        lat = ev.avg_us * _noise(r, 0.035)
        if ev.name == "log file sync":
            lat *= 1 + 0.8 * (e.commit - 1)
        if ev.name == "enq: TX - row lock contention":
            lat *= 1 + 0.3 * (e.row_lock - 1)
        if ev.name in ("db file sequential read", "db file scattered read") and e.phys_reads > 1.5:
            lat *= 1 + 0.25 * min(2.0, e.phys_reads - 1)
        cnt = us / lat if lat > 0 else 0
        fg[ev.name] = (ev.wait_class, cnt, us)

    # ---- background
    bg_ela = db_time_us * 0.085 * _noise(r, 0.04)
    bg_cpu = bg_ela * 0.35
    bg_wait = bg_ela - bg_cpu
    tot = sum(ev.share for ev in BG_EVENTS if ev.wait_class != "Idle")
    bg = {}
    for ev in BG_EVENTS:
        if ev.wait_class == "Idle":
            cnt = {"rdbms ipc message": 900000, "DIAG idle wait": 7200, "Space Manager: slave idle wait": 720,
                   "smon timer": 12, "pmon timer": 1200, "ASM background timer": 720}[ev.name]
            bg[ev.name] = (ev.wait_class, cnt, cnt * ev.avg_us)
            continue
        m = 1.0
        if ev.name == "log file parallel write":
            m *= 1 + 0.9 * (e.commit - 1)
        if ev.name == "db file parallel write":
            m *= 1 + 0.6 * bf
        us = bg_wait * ev.share * m / tot
        bg[ev.name] = (ev.wait_class, us / (ev.avg_us * _noise(r, 0.035)), us)
    tm = {"DB time": db_time_us, "DB CPU": db_cpu_us,
          "background elapsed time": bg_ela, "background cpu time": bg_cpu}

    # ---- ASH (10-s samples: 360 per fully busy session-hour)
    ash_class = {"CPU": db_cpu_us / 1e6 / 10}
    ash_events = {("CPU", "CPU"): ash_class["CPU"]}
    for name, (wc, cnt, us) in fg.items():
        if wc == "Idle":
            continue
        smp = us / 1e6 / 10
        ash_class[wc] = ash_class.get(wc, 0.0) + smp
        ash_events[(wc, name)] = smp
    # background sessions also show in ASH (small)
    for name, (wc, cnt, us) in bg.items():
        if wc == "Idle":
            continue
        smp = us / 1e6 / 10
        ash_class[wc] = ash_class.get(wc, 0.0) + smp
        ash_events[(wc, name)] = ash_events.get((wc, name), 0.0) + smp
    ash_sql = {}
    for sid, x in sql.items():
        d = {"CPU": x.cpu_us / 1e6 / 10}
        for ev, us in x.waits.items():
            d[ev] = us / 1e6 / 10
        ash_sql[sid] = d

    # ---- SYSSTAT totals for the hour
    execs = sum(x.execs for x in sql.values()) * 1.35 * _noise(r, 0.02)
    commits = 3600 * 505 * inten * (1 + 0.25 * e.loyalty) * _noise(r, 0.03) + 3600 * 40 * bf
    hard = 3600 * 3.1 * inten * e.hard_parse * _noise(r, 0.08)
    lreads = sum(x.gets for x in sql.values()) * 1.25 * _noise(r, 0.02) + 3600 * 60000 * bf
    preads = (sum(x.reads for x in sql.values()) * 1.3 + 3600 * 1800 * bf) * _noise(r, 0.03)
    preads *= 1 + 0.15 * (e.phys_reads - 1)
    pwrites = (3600 * 1850 * inten + 3600 * 2600 * bf + 3600 * 1400 * mef) * _noise(r, 0.04)
    redo = (3600 * 3.4e6 * inten * (1 + 0.15 * e.loyalty) + 3600 * 5.5e6 * bf + 3600 * 4e6 * mef) * _noise(r, 0.03)
    ucalls = 3600 * 6100 * inten * _noise(r, 0.02)
    logons = 3600 * 3.9 * inten * _noise(r, 0.05)
    scans_long = (3600 * 2.2 * inten * e.scans + 3600 * 3 * bf) * _noise(r, 0.1)
    if e.order_lookup_bad > 0.5:
        scans_long += sql[ORDER_LOOKUP_SQL].execs * 0.05
    load = {
        "DB time": db_time_us / 1e4,                     # centiseconds
        "DB CPU": db_cpu_us / 1e4,
        "CPU used by this session": db_cpu_us / 1e4 * 0.985,
        "redo size": redo,
        "redo size for lost write detection": 0.0,
        "session logical reads": lreads,
        "physical reads": preads,
        "physical read total bytes": preads * 8192 * 1.06,
        "physical writes": pwrites,
        "physical write total bytes": pwrites * 8192 * 1.9,   # + redo/archive/control
        "user calls": ucalls,
        "user commits": commits,
        "user rollbacks": commits * 0.0062 * _noise(r, 0.1),
        "execute count": execs,
        "parse count (total)": execs * 0.071 * _noise(r, 0.03) + hard,
        "parse count (hard)": hard,
        "parse count (failures)": 3600 * 0.14 * inten * _noise(r, 0.2),
        "sorts (memory)": 3600 * 2150 * inten * _noise(r, 0.03) + 3600 * 800 * bf,
        "sorts (disk)": (3600 * 0.42 * inten + 3600 * 3.5 * bf + 3600 * 2 * mef) * _noise(r, 0.15),
        "sorts (rows)": 3600 * 1.45e6 * inten * _noise(r, 0.04) + 3600 * 4e6 * bf,
        "logons cumulative": logons,
        "opened cursors cumulative": execs * 0.62,
        "redo writes": 3600 * 390 * inten * _noise(r, 0.03) + 3600 * 300 * bf,
        "table scans (long tables)": scans_long,
        "table scans (short tables)": 3600 * 420 * inten * _noise(r, 0.03),
        "table fetch by rowid": 3600 * 215000 * inten * _noise(r, 0.03),
        "bytes sent via SQL*Net to client": 3600 * 9.6e6 * inten * _noise(r, 0.03),
        "bytes received via SQL*Net from client": 3600 * 2.15e6 * inten * _noise(r, 0.03),
        "db block changes": 3600 * 24000 * inten * _noise(r, 0.03) + 3600 * 30000 * bf,
        "physical read IO requests": preads * 0.72,
        "physical write IO requests": pwrites * 0.55,
    }

    # ---- SYSMETRIC averages
    aas = db_time_us / 1e6 / dur
    cpu_aas = db_cpu_us / 1e6 / dur
    host_cpu = min(97.0, (cpu_aas / CPU_COUNT) * 100 * 1.22 + 6.0)
    fg_sync_us = fg["db file sequential read"][2]
    fg_sync_n = fg["db file sequential read"][1]
    sblk_lat_ms = (fg_sync_us / fg_sync_n / 1000) if fg_sync_n else 0.48
    sessions = 1100 + 900 * inten * (1 + 0.1 * e.loyalty) + r.gauss(0, 12)
    io_mb = (load["physical read total bytes"] + load["physical write total bytes"] + redo) / 1048576 / dur
    sm = {
        "Host CPU Utilization (%)": host_cpu,
        "Database CPU Time Ratio": db_cpu_us / db_time_us * 100,
        "Database Wait Time Ratio": (1 - db_cpu_us / db_time_us) * 100,
        "Average Active Sessions": aas,
        "Average Synchronous Single-Block Read Latency": sblk_lat_ms,
        "Physical Reads Per Sec": preads / dur,
        "Physical Writes Per Sec": pwrites / dur,
        "Physical Read Total IO Requests Per Sec": load["physical read IO requests"] / dur,
        "Physical Write Total IO Requests Per Sec": load["physical write IO requests"] / dur,
        "Physical Read Total Bytes Per Sec": load["physical read total bytes"] / dur,
        "Physical Write Total Bytes Per Sec": load["physical write total bytes"] / dur,
        "Redo Generated Per Sec": redo / dur,
        "Logons Per Sec": logons / dur,
        "Logical Reads Per Sec": lreads / dur,
        "User Calls Per Sec": ucalls / dur,
        "User Commits Per Sec": commits / dur,
        "User Rollbacks Per Sec": load["user rollbacks"] / dur,
        "Executions Per Sec": execs / dur,
        "Hard Parse Count Per Sec": hard / dur,
        "Total Parse Count Per Sec": load["parse count (total)"] / dur,
        "Session Count": sessions,
        "Network Traffic Volume Per Sec": (load["bytes sent via SQL*Net to client"]
                                           + load["bytes received via SQL*Net from client"]) / dur,
        "SQL Service Response Time": db_time_us / 1e4 / max(1.0, ucalls) * 1000 / 3600 * 3600 / 100,
        "User Transaction Per Sec": (commits + load["user rollbacks"]) / dur,
        "Open Cursors Per Sec": load["opened cursors cumulative"] / dur,
        "Current Logons Count": sessions * 0.93,
        "Current Open Cursors Count": sessions * 14.2,
        "DB Block Changes Per Sec": load["db block changes"] / dur,
        "I/O Megabytes per Second": io_mb,
        "I/O Requests per Second": (load["physical read IO requests"] + load["physical write IO requests"]) / dur,
        "CPU Usage Per Sec": cpu_aas * 100,
        "Response Time Per Txn": db_time_us / 1e4 / max(1.0, commits),
        "Buffer Cache Hit Ratio": max(80.0, 100 - preads / max(1.0, lreads) * 100),
        "Library Cache Hit Ratio": max(85.0, 100 - hard / max(1.0, load["parse count (total)"]) * 100),
        "Soft Parse Ratio": max(50.0, 100 - hard / max(1.0, load["parse count (total)"]) * 100),
        "Execute Without Parse Ratio": 92.8 + r.gauss(0, 0.4),
        "Temp Space Used": (1.8e9 * inten + 9e9 * bf + 6e9 * mef) * _noise(r, 0.1),
        "Total PGA Allocated": (5.2e9 + 2.5e9 * inten + 3e9 * bf) * _noise(r, 0.03),
    }
    # SQL Service Response Time: cs per user call
    sm["SQL Service Response Time"] = (db_time_us / 1e4) / max(1.0, ucalls)

    # ---- segments
    seg = {}
    seg_r = rng("seg", ts)
    for g in SEGMENTS:
        m_r = m_w = 1.0
        if g.owner == "LOYALTY":
            m_r = m_w = e.loyalty
        if g.name.startswith("ORDER_LINES") and e.order_lookup_bad > 0:
            m_r *= 1 + 12 * e.order_lookup_bad if g.object_type == "TABLE" else 1 + 0.3 * e.order_lookup_bad
        if g.owner == "REPORTING":
            m_r *= 0.35 + 1.4 * bf + 0.5 * mef + (0.6 if (ts - H).hour in (0, 6, 12, 18) else 0.0)
            m_w *= 0.25 + 2.0 * bf + 1.0 * mef
        if g.name.startswith("WRH$"):
            m_r, m_w = 0.6 + 0.4 * inten, 1.0
        if e.cold_cache > 0:
            m_r *= 1 + 2.2 * e.cold_cache
        pr = g.reads_h * inten * m_r * _noise(seg_r, 0.06)
        pw = g.writes_h * inten * m_w * _noise(seg_r, 0.06)
        lr = g.logical_h * inten * (1 + (0.4 * e.order_lookup_bad if g.name.startswith("ORDER_LINES") else 0)) * _noise(seg_r, 0.04)
        seg[(g.owner, g.name)] = (pr, pw, pr * g.read_req_ratio, pw * g.write_req_ratio, lr)

    # ---- files: distribute segment I/O by tablespace, temp from sorts
    ts_r = {}
    ts_w = {}
    for g in SEGMENTS:
        pr, pw, rr, wr, _ = seg[(g.owner, g.name)]
        ts_r[g.tablespace] = ts_r.get(g.tablespace, 0.0) + pr
        ts_w[g.tablespace] = ts_w.get(g.tablespace, 0.0) + pw
    ts_r["UNDOTBS1"] = pwrites * 0.05
    ts_w["UNDOTBS1"] = pwrites * 0.18
    ts_r["SYSTEM"] = ts_r.get("SYSTEM", 0.0) + preads * 0.004
    ts_w["SYSTEM"] = ts_w.get("SYSTEM", 0.0) + pwrites * 0.003
    temp_blk = (3600 * 900 * inten + 3600 * 25000 * bf + 3600 * 12000 * mef) * _noise(r, 0.1)
    files = {}
    for f in FILES:
        if f.is_temp:
            blk_r = temp_blk * f.weight
            blk_w = temp_blk * 0.95 * f.weight
            rds, wts = blk_r / 14, blk_w / 16
            files[(True, f.file_id)] = (rds, wts, blk_r, blk_w, rds * 0.075, wts * 0.09)
        else:
            blk_r = ts_r.get(f.tablespace, 0.0) * f.weight
            blk_w = ts_w.get(f.tablespace, 0.0) * f.weight
            avg_mb = 1.0 if f.tablespace in ("TS_ORDERS_DATA", "TS_ORDERS_IDX", "TS_LOYALTY") else 6.5
            if f.tablespace == "TS_ORDERS_DATA" and e.order_lookup_bad > 0:
                avg_mb = 1.0 + 8 * e.order_lookup_bad
            rds = blk_r / avg_mb
            wts = blk_w / 1.7
            files[(False, f.file_id)] = (rds, wts, blk_r, blk_w,
                                          rds * sblk_lat_ms / 10 * (1.0 if avg_mb < 2 else 2.4),
                                          wts * 0.12)
    data_rd_mb = sum(v[2] for k, v in files.items() if not k[0]) * 8192 / 1048576
    data_wr_mb = sum(v[3] for k, v in files.items() if not k[0]) * 8192 / 1048576
    data_rr = sum(v[0] for k, v in files.items() if not k[0])
    data_wr = sum(v[1] for k, v in files.items() if not k[0])
    temp_rd_mb = sum(v[2] for k, v in files.items() if k[0]) * 8192 / 1048576
    temp_wr_mb = sum(v[3] for k, v in files.items() if k[0]) * 8192 / 1048576
    temp_rr = sum(v[0] for k, v in files.items() if k[0])
    temp_wr = sum(v[1] for k, v in files.items() if k[0])
    redo_mb = redo / 1048576
    iostat = {
        "Data File": (data_rd_mb, data_wr_mb, data_rr, data_wr),
        "Temp File": (temp_rd_mb, temp_wr_mb, temp_rr, temp_wr),
        "Log File": (redo_mb * 0.02, redo_mb * 1.02, load["redo writes"] * 0.02, load["redo writes"]),
        "Archive Log": (redo_mb * 0.01, redo_mb * 1.0, 40 * inten, redo_mb / 4),
        "Control File": (18.0 * inten + 6, 9.0 * inten + 4, fg["control file sequential read"][1],
                         bg["control file parallel write"][1]),
        "Flashback Log": (0.4, redo_mb * 0.35, 30, redo_mb * 0.35 / 1.2),
        "Other": (6.0 * inten, 2.0 * inten, 900 * inten, 320 * inten),
    }

    return HourMetrics(ts, dur, inten, e, load, sm, tm, fg, bg, ash_class, ash_events,
                       sql, ash_sql, seg, files, iostat)


# ---------------------------------------------------------------------
# SQL Monitor (DBA_HIST_REPORTS) executions + plan lines
# ---------------------------------------------------------------------

@dataclass
class MonExec:
    report_id: int
    sql_id: str
    sql_exec_id: int
    exec_start: datetime
    status: str          # DONE (ALL ROWS) | DONE (ERROR) | DONE
    username: str
    module: str
    plan_hash: int
    px_req: int
    px_alloc: int
    elapsed_us: float
    read_bytes: float
    write_bytes: float
    cpu_us: float
    buffer_gets: float


@dataclass
class PlanLine:
    id: int
    parent_id: int | None
    depth: int
    name: str
    options: str
    owner: str
    obj: str
    est_rows: float
    starts: float
    act_rows: float
    duration_s: float
    max_mem: float


def _plan(sql_id: str, plan_hash: int, x: SqlHour | None, execs_scale: float = 1.0) -> list[PlanLine]:
    """Plan lines with per-execution statistics for the SQL Monitor drift
    block (only the monitored statements need one)."""
    if sql_id == ORDER_LOOKUP_SQL:
        if plan_hash == ORDER_LOOKUP_BAD_PLAN:
            return [
                PlanLine(0, None, 0, "SELECT STATEMENT", "", "", "", 6, 1, 6, 0.17, 0),
                PlanLine(1, 0, 1, "SORT", "ORDER BY", "", "", 6, 1, 6, 0.001, 24576),
                PlanLine(2, 1, 2, "HASH JOIN", "", "", "", 6, 1, 6, 0.004, 1_540_096),
                PlanLine(3, 2, 3, "TABLE ACCESS", "BY INDEX ROWID BATCHED", "ORDERS_APP", "ORDERS", 2, 1, 2, 0.001, 0),
                PlanLine(4, 3, 4, "INDEX", "RANGE SCAN", "ORDERS_APP", "ORDERS_CUST_CREATED_IX", 2, 1, 2, 0.0004, 0),
                PlanLine(5, 2, 3, "TABLE ACCESS", "FULL", "ORDERS_APP", "ORDER_LINES", 3_260_000, 1, 3_284_117, 0.163, 0),
            ]
        return [
            PlanLine(0, None, 0, "SELECT STATEMENT", "", "", "", 6, 1, 6, 0.002, 0),
            PlanLine(1, 0, 1, "SORT", "ORDER BY", "", "", 6, 1, 6, 0.0001, 24576),
            PlanLine(2, 1, 2, "NESTED LOOPS", "", "", "", 6, 1, 6, 0.0002, 0),
            PlanLine(3, 2, 3, "NESTED LOOPS", "", "", "", 6, 1, 6, 0.0001, 0),
            PlanLine(4, 3, 4, "TABLE ACCESS", "BY INDEX ROWID BATCHED", "ORDERS_APP", "ORDERS", 2, 1, 2, 0.0005, 0),
            PlanLine(5, 4, 5, "INDEX", "RANGE SCAN", "ORDERS_APP", "ORDERS_CUST_CREATED_IX", 2, 1, 2, 0.0003, 0),
            PlanLine(6, 3, 4, "INDEX", "RANGE SCAN", "ORDERS_APP", "ORDER_LINES_ORD_IX", 3, 2, 6, 0.0004, 0),
            PlanLine(7, 2, 3, "TABLE ACCESS", "BY INDEX ROWID", "ORDERS_APP", "ORDER_LINES", 3, 6, 6, 0.0006, 0),
        ]
    if sql_id == "9wz2ke6yq4tn1":
        return [
            PlanLine(0, None, 0, "SELECT STATEMENT", "", "", "", 1840, 1, 1832, 214, 0),
            PlanLine(1, 0, 1, "PX COORDINATOR", "", "", "", 1840, 1, 1832, 0.9, 0),
            PlanLine(2, 1, 2, "PX SEND QC (RANDOM)", "", "", ":TQ10001", 1840, 8, 1832, 0.3, 0),
            PlanLine(3, 2, 3, "HASH", "GROUP BY", "", "", 1840, 8, 1832, 11.2, 48_234_496),
            PlanLine(4, 3, 4, "PX RECEIVE", "", "", "", 1840, 8, 14656, 2.1, 0),
            PlanLine(5, 4, 5, "PX SEND HASH", "", "", ":TQ10000", 1840, 8, 14656, 4.6, 0),
            PlanLine(6, 5, 6, "HASH", "GROUP BY", "", "", 1840, 8, 14656, 38.4, 61_997_056),
            PlanLine(7, 6, 7, "PX BLOCK ITERATOR", "", "", "", 41_200_000, 8, 41_388_204, 4.0, 0),
            PlanLine(8, 7, 8, "TABLE ACCESS", "FULL", "REPORTING", "SALES_FACT", 41_200_000, 1024, 41_388_204, 152.6, 0),
        ]
    if sql_id == "h5x1c9pa7rd3s":
        return [
            PlanLine(0, None, 0, "SELECT STATEMENT", "", "", "", 412, 1, 408, 96, 0),
            PlanLine(1, 0, 1, "HASH", "GROUP BY", "", "", 412, 1, 408, 3.1, 2_301_952),
            PlanLine(2, 1, 2, "HASH JOIN", "", "", "", 8_900_000, 1, 8_912_540, 22.4, 118_489_088),
            PlanLine(3, 2, 3, "TABLE ACCESS", "FULL", "REPORTING", "WAREHOUSES", 42, 1, 42, 0.002, 0),
            PlanLine(4, 2, 3, "HASH JOIN", "", "", "", 8_900_000, 1, 8_912_540, 18.7, 96_468_992),
            PlanLine(5, 4, 4, "TABLE ACCESS", "FULL", "ORDERS_APP", "PRODUCTS", 218_000, 1, 218_442, 1.4, 0),
            PlanLine(6, 4, 4, "PARTITION RANGE", "SINGLE", "", "", 8_900_000, 1, 8_912_540, 0.2, 0),
            PlanLine(7, 6, 5, "TABLE ACCESS", "FULL", "REPORTING", "INVENTORY_HIST", 8_900_000, 1, 8_912_540, 50.2, 0),
        ]
    if sql_id == "a4g6j2ct5nq1w":
        return [
            PlanLine(0, None, 0, "MERGE STATEMENT", "", "", "", 3_900_000, 1, 3_912_006, 512, 0),
            PlanLine(1, 0, 1, "MERGE", "", "LOYALTY", "CUSTOMERS", 3_900_000, 1, 3_912_006, 201, 0),
            PlanLine(2, 1, 2, "VIEW", "", "", "", 3_900_000, 1, 3_912_006, 1.2, 0),
            PlanLine(3, 2, 3, "HASH JOIN", "", "", "", 3_900_000, 1, 3_912_006, 60.4, 618_262_528),
            PlanLine(4, 3, 4, "VIEW", "", "", "", 3_900_000, 1, 3_912_006, 0.8, 0),
            PlanLine(5, 4, 5, "HASH", "GROUP BY", "", "", 3_900_000, 1, 3_912_006, 88.2, 402_653_184),
            PlanLine(6, 5, 6, "TABLE ACCESS", "FULL", "LOYALTY", "LOYALTY_LEDGER", 61_000_000, 1, 61_884_120, 108.6, 0),
            PlanLine(7, 3, 4, "TABLE ACCESS", "FULL", "ORDERS_APP", "CUSTOMERS", 4_100_000, 1, 4_118_207, 51.8, 0),
        ]
    if sql_id == "d8s3n5tw2xk7f":
        return [
            PlanLine(0, None, 0, "MERGE STATEMENT", "", "", "", 210_000, 1, 209_884, 38, 0),
            PlanLine(1, 0, 1, "MERGE", "", "INVENTORY", "INVENTORY", 210_000, 1, 209_884, 14.9, 0),
            PlanLine(2, 1, 2, "VIEW", "", "", "", 210_000, 1, 209_884, 0.3, 0),
            PlanLine(3, 2, 3, "HASH JOIN", "OUTER", "", "", 210_000, 1, 209_884, 6.1, 34_603_008),
            PlanLine(4, 3, 4, "TABLE ACCESS", "FULL", "INVENTORY", "INV_FEED_STAGE", 210_000, 1, 209_884, 2.2, 0),
            PlanLine(5, 3, 4, "TABLE ACCESS", "FULL", "INVENTORY", "INVENTORY", 2_400_000, 1, 2_418_331, 14.5, 0),
        ]
    if sql_id == "v8c2l5qs3wd7m":
        return [
            PlanLine(0, None, 0, "SELECT STATEMENT", "", "", "", 18300, 1, 18412, 41, 0),
            PlanLine(1, 0, 1, "TABLE ACCESS", "FULL", "INVENTORY", "INVENTORY", 18300, 1, 18412, 40.6, 0),
        ]
    if sql_id == "e1k8s4yn7pw2j":
        return [
            PlanLine(0, None, 0, "UPDATE STATEMENT", "", "", "", 110_000, 1, 109_412, 74, 0),
            PlanLine(1, 0, 1, "UPDATE", "", "ORDERS_APP", "PAYMENTS", 110_000, 1, 109_412, 41.2, 0),
            PlanLine(2, 1, 2, "TABLE ACCESS", "BY INDEX ROWID BATCHED", "ORDERS_APP", "PAYMENTS", 110_000, 1, 109_412, 30.1, 0),
            PlanLine(3, 2, 3, "INDEX", "RANGE SCAN", "ORDERS_APP", "PAYMENTS_STATUS_IX", 110_000, 1, 109_412, 2.7, 0),
        ]
    return []


def _monexecs() -> list[MonExec]:
    """Every persisted SQL Monitor report in the span.  Only long / parallel
    statements are captured (SQL Monitor's own policy): the reporting
    queries, the nightly batches, the inventory merge, the settle job, and
    -- after Release 4.2 -- the regressed order lookup when a burst of it
    runs long enough (>= 5 s) via the customer-service bulk lookups."""
    out = []
    rid = 2_000_000
    sql_by_id = {s.sql_id: s for s in SQLS}
    t = SNAP_FIRST + timedelta(days=9)
    while t <= TARGET_END:
        hm = hour(t + H) if t + H <= TARGET_END else hour(TARGET_END)
        hs = t.hour
        r = rng("mon", t)
        for sid in ("9wz2ke6yq4tn1", "h5x1c9pa7rd3s", "d8s3n5tw2xk7f", "w1n9k3pf6tx4a",
                    "a4g6j2ct5nq1w", "e1k8s4yn7pw2j", "x6j2d8rq5vm1b", "v8c2l5qs3wd7m"):
            x = hm.sql.get(sid)
            if not x:
                continue
            s = sql_by_id[sid]
            n = int(round(x.execs))
            if sid == "d8s3n5tw2xk7f":
                n = 4
            for k in range(n):
                per = x.elapsed_us / max(1, x.execs)
                ela = per * _noise(r, 0.12)
                if sid == "9wz2ke6yq4tn1" and hs == 6 and k == 0:
                    ela = per * 1.0
                start = t + timedelta(minutes=(60 // max(1, n)) * k + r.randint(0, 6), seconds=r.randint(0, 59))
                status = "DONE (ALL ROWS)" if sid not in ("w1n9k3pf6tx4a", "a4g6j2ct5nq1w", "d8s3n5tw2xk7f",
                                                         "e1k8s4yn7pw2j", "x6j2d8rq5vm1b") else "DONE"
                px_req = px_alloc = 0
                if sid == "9wz2ke6yq4tn1":
                    px_req = 8
                    px_alloc = 8
                    # DOP downgrades during the nightly batch / month-end contention
                    if hs in (1, 2, 3) or month_end_factor(t + H) > 0:
                        px_alloc = 4 if r.random() < 0.7 else 8
                    if hs == 6:
                        px_alloc = 8
                if sid == "h5x1c9pa7rd3s":
                    px_req = 4
                    px_alloc = 4 if r.random() < 0.85 else 2
                if sid == "a4g6j2ct5nq1w" and t.date() == datetime(2026, 8, 12).date():
                    status = "DONE (ERROR)"      # first run after 4.1 blew ORA-01555
                    ela = 1_910_000_000
                if sid == "w1n9k3pf6tx4a" and t.date() == datetime(2026, 7, 31).date():
                    status = "DONE (ERROR)"      # month-end: ORA-30036 undo
                    ela = 2_280_000_000
                plan = x.plan_hash
                if sid == "x6j2d8rq5vm1b":
                    plan = 0
                per_gets = x.gets / max(1, x.execs)
                per_reads = x.reads / max(1, x.execs)
                out.append(MonExec(rid, sid, 16_777_216 + rid % 100000, start, status,
                                   s.schema, s.module, plan, px_req, px_alloc, ela,
                                   per_reads * 8192, (per_reads * 8192 * 0.02 if "INSERT" not in s.text else per_reads * 8192 * 0.5),
                                   ela * s.cpu_frac, per_gets))
                rid += 1
        # Regressed order lookup: batch lookups from the service desk run > 5 s
        x = hm.sql.get(ORDER_LOOKUP_SQL)
        if x and x.plan_hash == ORDER_LOOKUP_BAD_PLAN and 8 <= hs <= 18:
            for k in range(3):
                ela = 5.2e6 + r.random() * 3.1e6
                start = t + timedelta(minutes=12 + 15 * k + r.randint(0, 4), seconds=r.randint(0, 59))
                out.append(MonExec(rid, ORDER_LOOKUP_SQL, 16_777_216 + rid % 100000, start, "DONE (ALL ROWS)",
                                   "ORDERS_APP", "OrderService", ORDER_LOOKUP_BAD_PLAN, 0, 0, ela,
                                   610 * 8192 * 31, 0, ela * 0.22, 4_900 * 31))
                rid += 1
        # pre-4.2 the same bulk lookups on the good plan occasionally cross the
        # 1-s floor too (thousands of orders for one customer), ~twice a day
        elif x and 9 <= hs <= 17 and (hs == 9 and t.weekday() < 5 or r.random() < 0.22):
            # the 09:00 customer-service bulk lookup runs every weekday, so the
            # compared hour always has a capture (drift needs >= 3 priors)
            ela = 1.05e6 + r.random() * 0.9e6
            start = t + timedelta(minutes=r.randint(0, 59), seconds=r.randint(0, 59))
            out.append(MonExec(rid, ORDER_LOOKUP_SQL, 16_777_216 + rid % 100000, start, "DONE (ALL ROWS)",
                               "ORDERS_APP", "OrderService", sql_by_id[ORDER_LOOKUP_SQL].plan_hash, 0, 0, ela,
                               0.9 * 8192 * 900, 0, ela * 0.72, 38 * 900))
            rid += 1
        t += H
    out.sort(key=lambda m: m.exec_start)
    return out


def plan_lines(sql_id: str, plan_hash: int, m: MonExec | None = None) -> list[PlanLine]:
    """Plan lines for one execution; durations scaled to the execution's
    elapsed so two executions of the same plan differ realistically."""
    base = _plan(sql_id, plan_hash, None)
    if not base or m is None:
        return base
    ref = base[0].duration_s or 1.0
    k = (m.elapsed_us / 1e6) / ref
    r = rng("plan", m.report_id)
    out = []
    for l in base:
        j = 1.0 if l.id == 0 else min(1.0 + r.gauss(0, 0.06), 0.995 * ref / max(l.duration_s, 1e-9))
        out.append(PlanLine(l.id, l.parent_id, l.depth, l.name, l.options, l.owner, l.obj,
                            l.est_rows, l.starts, l.act_rows * (1.0 + r.gauss(0, 0.01) if l.act_rows > 100 else 1.0),
                            l.duration_s * k * j, l.max_mem))
    return out


# ---------------------------------------------------------------------
# World
# ---------------------------------------------------------------------

class World:
    def __init__(self):
        self.db_name = DB_NAME
        self.host_name = HOST_NAME
        self.db_version = DB_VERSION
        self.dbid = DBID
        self.dbid_list = str(DBID)
        self.caller_user = CALLER_USER
        self.awr_version = AWR_VERSION
        self.run_id = RUN_ID
        self.generated_at = GENERATED_AT
        self.target_end = TARGET_END
        self.target_end_requested = TARGET_END
        self.win_hours = WIN_HOURS
        self.weeks_back = WEEKS_BACK
        self.step = STEP
        self.step_unit = STEP_UNIT
        self.step_hours = STEP_HOURS
        self.top_n = TOP_N
        self.inst_num = INST_NUM
        self.template = TEMPLATE
        self.template_dir = f"sql/lib/templates/{TEMPLATE}"
        self.profile_days = PROFILE_DAYS
        self.sqlmon_detail = SQLMON_DETAIL
        self.markers = list(MARKERS)
        self.markers_define = ";;".join(f"{t:%Y-%m-%d %H:%M}|{l}" for t, l in MARKERS)
        self.echarts = "vendor/echarts.min.js"
        # derived labels (twins of the driver's COLUMN ... NEW_VALUE set)
        self.period_unit_short = "w"
        self.period_unit_long = "week"
        self.period_unit_title = "Week"
        self.period_step_label = "w"
        self.period_axis_fmt = "Mon DD"
        self.win_label = fmt_one(WIN_HOURS)
        self.step_label = fmt_one(STEP_HOURS)
        self.offset_labels = [fmt_one(k * STEP_HOURS) for k in range(1, 17)]
        self.bucket_hours = 1.0
        self.report_path = (f"reports/awr_trend_{DB_NAME}_{DBID}_{REPORT_TS}_run{RUN_ID}.html")
        self.dow_name = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"][TARGET_END.weekday()]
        self.snaps = self._build_snaps()
        self.snap_by_end = {s.end_ts: s for s in self.snaps}
        self.windows = self._build_windows()
        self.sqls = SQLS
        self.sql_by_id = {s.sql_id: s for s in SQLS}
        self.fg_events = FG_EVENTS
        self.bg_events = BG_EVENTS
        self.wait_classes = WAIT_CLASSES
        self.segments = SEGMENTS
        self.files = FILES
        self.filetypes = FILETYPES
        self.param_changes = PARAM_CHANGES
        self.params_static = PARAMS_STATIC
        self._monexecs = None

    # ---- snapshots / windows ------------------------------------------
    def _build_snaps(self) -> list[Snap]:
        out = []
        t = SNAP_FIRST
        i = 0
        while t <= TARGET_END:
            startup = STARTUP_BEFORE if t < RESTART_AT else STARTUP_AFTER
            begin = t - H
            if t > RESTART_AT and begin < RESTART_AT:
                begin = STARTUP_AFTER      # first snap after the bounce
            out.append(Snap(SNAP_ID_BASE + i, t, begin, startup))
            t += H
            i += 1
        return out

    def snap_at(self, ts: datetime) -> Snap | None:
        return self.snap_by_end.get(ts)

    def _build_windows(self) -> list[Window]:
        out = []
        for k in range(WEEKS_BACK + 1):
            end = TARGET_END - timedelta(hours=STEP_HOURS * k)
            start = end - timedelta(hours=WIN_HOURS)
            b, e = self.snap_at(start), self.snap_at(end)
            if b is None or e is None:
                out.append(Window(k, start, end, b.snap_id if b else None, e.snap_id if e else None,
                                  "N", "no begin/end snapshot", 0.0))
                continue
            if b.startup_time != e.startup_time:
                out.append(Window(k, start, end, b.snap_id, e.snap_id, "N",
                                  "instance restarted inside window", 0.0))
                continue
            out.append(Window(k, start, end, b.snap_id, e.snap_id, "Y", None,
                              (e.end_ts - b.end_ts).total_seconds()))
        return out

    @property
    def valid_windows(self) -> list[Window]:
        return [w for w in self.windows if w.valid]

    def window(self, k: int) -> Window:
        return self.windows[k]

    # ---- metrics ------------------------------------------------------
    def hour(self, ts: datetime) -> HourMetrics:
        return hour(ts)

    def hours(self, start: datetime, end: datetime) -> list[HourMetrics]:
        """HourMetrics for every snap interval ending in (start, end]."""
        out = []
        t = start.replace(minute=0, second=0, microsecond=0)
        if t <= start:
            t += H
        while t <= end:
            if t in self.snap_by_end:
                out.append(hour(t))
            t += H
        return out

    def window_metrics(self, w: Window) -> HourMetrics | None:
        """The window's aggregate (a 1-hour window on an hourly grid is one
        HourMetrics; longer windows would sum)."""
        if not w.valid:
            return None
        hs = self.hours(w.win_start_ts, w.win_end_ts)
        if len(hs) == 1:
            return hs[0]
        return _sum_hours(hs)

    def window_series(self, fn) -> list:
        """[fn(HourMetrics) or None] indexed by week_offset 0..weeks_back
        (None for a skipped window)."""
        out = []
        for w in self.windows:
            m = self.window_metrics(w)
            out.append(None if m is None else fn(m))
        return out

    # ---- span helpers --------------------------------------------------
    @property
    def span_start(self) -> datetime:
        """Earliest compared-window start (same as 09/10's range start)."""
        return TARGET_END - timedelta(hours=WEEKS_BACK * STEP_HOURS + WIN_HOURS)

    def param_value(self, name: str, ts: datetime) -> str | None:
        v = self.params_static.get(name)
        for pc in self.param_changes:
            if pc.name == name:
                v = pc.new if ts >= pc.at else pc.old
        return v

    def monexecs(self) -> list[MonExec]:
        if self._monexecs is None:
            self._monexecs = _monexecs()
        return self._monexecs

    def plan_lines(self, sql_id: str, plan_hash: int, m: MonExec | None = None) -> list[PlanLine]:
        return plan_lines(sql_id, plan_hash, m)

    def rng(self, *key) -> random.Random:
        return rng(*key)


def _sum_hours(hs: list[HourMetrics]) -> HourMetrics:
    """Sum additive quantities over several hours (multi-hour windows)."""
    first = hs[0]
    n = len(hs)

    def sumd(getter):
        out = {}
        for h in hs:
            for k, v in getter(h).items():
                if isinstance(v, tuple):
                    cur = out.get(k)
                    out[k] = tuple((cur[i] if cur else 0) + v[i] if not isinstance(v[i], str) else v[i]
                                   for i in range(len(v)))
                else:
                    out[k] = out.get(k, 0.0) + v
        return out

    sql = {}
    for h in hs:
        for sid, x in h.sql.items():
            c = sql.get(sid)
            if c is None:
                sql[sid] = SqlHour(x.execs, x.elapsed_us, x.cpu_us, x.gets, x.reads, x.rows,
                                   x.iowait_us, x.plan_hash, dict(x.waits))
            else:
                c.execs += x.execs
                c.elapsed_us += x.elapsed_us
                c.cpu_us += x.cpu_us
                c.gets += x.gets
                c.reads += x.reads
                c.rows += x.rows
                c.iowait_us += x.iowait_us
                c.plan_hash = x.plan_hash
                for ev, us in x.waits.items():
                    c.waits[ev] = c.waits.get(ev, 0.0) + us
    sm = {k: sum(h.sysmetric[k] for h in hs) / n for k in first.sysmetric}
    return HourMetrics(hs[-1].ts, sum(h.dur_sec for h in hs), sum(h.intensity for h in hs) / n,
                       hs[-1].effects, sumd(lambda h: h.load), sm, sumd(lambda h: h.time_model),
                       sumd(lambda h: h.fg_waits), sumd(lambda h: h.bg_waits),
                       sumd(lambda h: h.ash_class), sumd(lambda h: h.ash_events), sql,
                       {}, sumd(lambda h: h.seg), sumd(lambda h: h.files), sumd(lambda h: h.iostat))


_WORLD = None


def world() -> World:
    global _WORLD
    if _WORLD is None:
        _WORLD = World()
    return _WORLD
