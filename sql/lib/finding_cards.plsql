--
-- sql/lib/finding_cards.plsql
--
-- Summary-view vocabulary (v1.6.0): how a scored metric is NAMED, which
-- UNIT it is shown in, and which finding CARD it belongs to.  Shared by
-- the verdict (00), the finding cards and "checked and normal" rows (07)
-- and the narrative / likely-source line (17), so the three can never
-- word the same metric differently.  Single-DB only (the fleet has its
-- own vocabulary).  Twin: demo/awrdemo/helpers.py (card_group, ...).
--
-- Card groups.  A finding card is one metric FAMILY from
-- sql/lib/metric_policy.plsql (its `family` field), and a few families
-- that tell one story share a card.  The mapping is the documented link
-- between the policy's families and Mock D's four cards:
--   IO      Physical I/O    READ_IO + SCANS + LOGICAL_IO + WAIT:User I/O
--   DBTIME  DB time         DB_TIME + CPU_WAIT_RATIO + RESPONSE
--   NET     Network         WAIT:Network + NETWORK
--   COMMIT  Commit          WAIT:Commit + COMMIT
--   PARSE   Parsing         PARSE + HARD_PARSE + CURSORS
--   WRITE   Writes and redo WRITE_IO + REDO + WAIT:System I/O
--   any other family is its own card (WAIT:<class> -> "<class> waits").
-- card_primary() names the family whose best member leads the card when it
-- is flagged (the physical-read count, not the long-table-scan count,
-- heads the I/O story), otherwise the card's highest-|z| member leads.
--
-- Units.  metric_scale() x the stored value = the value in metric_unit():
-- DB time / DB CPU / CPU used are centiseconds per second -> AAS (x 0.01);
-- SQL Service Response Time is centiseconds per call -> ms per call (x 10);
-- wait classes are seconds waited per second = AAS.  Scoring always runs
-- on the stored value (the band and z are scale-free).
--
-- Include inside a DECLARE block AFTER sql/lib/fmt_num.plsql.  Declares
-- only functions (no TYPE).
--

    FUNCTION card_group(p_family VARCHAR2) RETURN VARCHAR2 IS
    BEGIN
        RETURN CASE
            WHEN p_family IN ('READ_IO', 'SCANS', 'LOGICAL_IO', 'WAIT:User I/O') THEN 'IO'
            WHEN p_family IN ('DB_TIME', 'CPU_WAIT_RATIO', 'RESPONSE')            THEN 'DBTIME'
            WHEN p_family IN ('WAIT:Network', 'NETWORK')                          THEN 'NET'
            WHEN p_family IN ('WAIT:Commit', 'COMMIT')                            THEN 'COMMIT'
            WHEN p_family IN ('PARSE', 'HARD_PARSE', 'CURSORS')                   THEN 'PARSE'
            WHEN p_family IN ('WRITE_IO', 'REDO', 'WAIT:System I/O')              THEN 'WRITE'
            ELSE p_family END;
    END card_group;

    FUNCTION card_primary(p_group VARCHAR2) RETURN VARCHAR2 IS
    BEGIN
        RETURN CASE p_group
            WHEN 'IO'     THEN 'READ_IO'
            WHEN 'DBTIME' THEN 'DB_TIME'
            WHEN 'NET'    THEN 'WAIT:Network'
            WHEN 'COMMIT' THEN 'WAIT:Commit'
            WHEN 'PARSE'  THEN 'HARD_PARSE'
            WHEN 'WRITE'  THEN 'WRITE_IO'
            ELSE p_group END;
    END card_primary;

    FUNCTION card_label(p_group VARCHAR2) RETURN VARCHAR2 IS
    BEGIN
        RETURN CASE
            WHEN p_group = 'IO'     THEN 'Physical I/O'
            WHEN p_group = 'DBTIME' THEN 'DB time'
            WHEN p_group = 'NET'    THEN 'Network'
            WHEN p_group = 'COMMIT' THEN 'Commit'
            WHEN p_group = 'PARSE'  THEN 'Parsing'
            WHEN p_group = 'WRITE'  THEN 'Writes and redo'
            WHEN p_group LIKE 'WAIT:%' THEN SUBSTR(p_group, 6) || ' waits'
            WHEN p_group LIKE 'OTHER:%' THEN SUBSTR(p_group, 7)
            ELSE INITCAP(REPLACE(p_group, '_', ' ')) END;
    END card_label;

    -- the card's element id: f-io, f-dbtime, f-wait-concurrency, ...
    FUNCTION card_id(p_group VARCHAR2) RETURN VARCHAR2 IS
        v VARCHAR2(200);
    BEGIN
        v := REGEXP_REPLACE(LOWER(p_group), '[^a-z0-9]+', '-');
        RETURN 'f-' || SUBSTR(REGEXP_REPLACE(v, '^-+|-+$', ''), 1, 48);
    END card_id;

    -- the plain-English name of a scored metric
    FUNCTION metric_label(p_domain VARCHAR2, p_name VARCHAR2) RETURN VARCHAR2 IS
    BEGIN
        IF p_domain = 'WAIT' THEN
            RETURN REGEXP_REPLACE(p_name, '^Wait class: ', '') || ' waits';
        END IF;
        RETURN CASE p_name
            WHEN 'physical reads'                         THEN 'Physical reads'
            WHEN 'physical read total bytes'              THEN 'Physical read bytes'
            WHEN 'Physical Read Total IO Requests Per Sec' THEN 'Read I/O requests'
            WHEN 'Physical Write Total IO Requests Per Sec' THEN 'Write I/O requests'
            WHEN 'session logical reads'                  THEN 'Logical reads'
            WHEN 'table scans (long tables)'              THEN 'Table scans (long tables)'
            WHEN 'table fetch by rowid'                   THEN 'Rowid fetches'
            WHEN 'DB time'                                THEN 'DB time'
            WHEN 'DB CPU'                                 THEN 'DB CPU'
            WHEN 'CPU used by this session'               THEN 'CPU used'
            WHEN 'Database Wait Time Ratio'               THEN 'Wait time ratio'
            WHEN 'Database CPU Time Ratio'                THEN 'CPU time ratio'
            WHEN 'SQL Service Response Time'              THEN 'SQL response time'
            WHEN 'Average Active Sessions'                THEN 'Average active sessions'
            WHEN 'Host CPU Utilization (%)'               THEN 'Host CPU'
            WHEN 'Average Synchronous Single-Block Read Latency' THEN 'Single-block read latency'
            WHEN 'execute count'                          THEN 'Executions'
            WHEN 'user calls'                             THEN 'User calls'
            WHEN 'user commits'                           THEN 'User commits'
            WHEN 'user rollbacks'                         THEN 'User rollbacks'
            WHEN 'redo size'                              THEN 'Redo generated'
            WHEN 'redo writes'                            THEN 'Redo writes'
            WHEN 'physical writes'                        THEN 'Physical writes'
            WHEN 'physical write total bytes'             THEN 'Write volume'
            WHEN 'parse count (hard)'                     THEN 'Hard parses'
            WHEN 'parse count (total)'                    THEN 'Parses (total)'
            WHEN 'parse count (failures)'                 THEN 'Parse failures'
            WHEN 'Session Count'                          THEN 'Sessions'
            WHEN 'logons cumulative'                      THEN 'Logons'
            WHEN 'opened cursors cumulative'              THEN 'Cursors opened'
            WHEN 'sorts (disk)'                           THEN 'Sorts (disk)'
            WHEN 'sorts (memory)'                         THEN 'Sorts (memory)'
            WHEN 'sorts (rows)'                           THEN 'Sorted rows'
            WHEN 'bytes sent via SQL*Net to client'       THEN 'Bytes to clients'
            WHEN 'bytes received via SQL*Net from client' THEN 'Bytes from clients'
            WHEN 'Network Traffic Volume Per Sec'         THEN 'Network volume'
            WHEN 'redo size for lost write detection'     THEN 'Lost-write redo'
            ELSE UPPER(SUBSTR(p_name, 1, 1)) || SUBSTR(p_name, 2) END;
    END metric_label;

    FUNCTION metric_unit(p_domain VARCHAR2, p_name VARCHAR2) RETURN VARCHAR2 IS
    BEGIN
        IF p_domain = 'WAIT' THEN RETURN 'AAS'; END IF;
        IF p_domain = 'LOAD' THEN
            RETURN CASE
                WHEN p_name IN ('DB time', 'DB CPU', 'CPU used by this session') THEN 'AAS'
                WHEN p_name LIKE '%bytes%' OR p_name LIKE 'redo size%'           THEN 'B/s'
                ELSE '/s' END;
        END IF;
        RETURN CASE
            WHEN p_name = 'SQL Service Response Time'   THEN 'ms/call'
            WHEN p_name = 'Session Count'               THEN 'sessions'
            WHEN p_name = 'Average Active Sessions'     THEN 'AAS'
            WHEN p_name LIKE '%Latency%'                THEN 'ms'
            WHEN p_name LIKE '%(%)%' OR p_name LIKE '%Ratio%' THEN '%'
            WHEN p_name LIKE '%Bytes Per Sec' OR p_name = 'Network Traffic Volume Per Sec' THEN 'B/s'
            ELSE '/s' END;
    END metric_unit;

    FUNCTION metric_scale(p_domain VARCHAR2, p_name VARCHAR2) RETURN NUMBER IS
    BEGIN
        IF p_domain = 'LOAD' AND p_name IN ('DB time', 'DB CPU', 'CPU used by this session') THEN
            RETURN 0.01;
        ELSIF p_domain = 'METRIC' AND p_name = 'SQL Service Response Time' THEN
            RETURN 10;
        END IF;
        RETURN 1;
    END metric_scale;

    -- the number part of a value in its unit (bytes scale to k / M / G)
    FUNCTION fv_num(p_v NUMBER, p_unit VARCHAR2) RETURN VARCHAR2 IS
    BEGIN
        IF p_unit = 'B/s' AND p_v IS NOT NULL THEN
            RETURN CASE WHEN ABS(p_v) >= 1e9 THEN fmt_num(p_v / 1e9)
                        WHEN ABS(p_v) >= 1e6 THEN fmt_num(p_v / 1e6)
                        WHEN ABS(p_v) >= 1e3 THEN fmt_num(p_v / 1e3)
                        ELSE fmt_num(p_v) END;
        END IF;
        RETURN fmt_num(p_v);
    END fv_num;

    FUNCTION fv_unit(p_v NUMBER, p_unit VARCHAR2) RETURN VARCHAR2 IS
    BEGIN
        IF p_unit = 'B/s' AND p_v IS NOT NULL THEN
            RETURN CASE WHEN ABS(p_v) >= 1e9 THEN 'GB/s'
                        WHEN ABS(p_v) >= 1e6 THEN 'MB/s'
                        WHEN ABS(p_v) >= 1e3 THEN 'kB/s'
                        ELSE 'B/s' END;
        END IF;
        RETURN p_unit;
    END fv_unit;

    -- "3.992 MB/s", "22.24 k/s", "20.35 AAS", "57.8 %"
    FUNCTION fv(p_v NUMBER, p_unit VARCHAR2) RETURN VARCHAR2 IS
        v_u VARCHAR2(20) := fv_unit(p_v, p_unit);
    BEGIN
        IF p_v IS NULL THEN RETURN '&mdash;'; END IF;
        RETURN fv_num(p_v, p_unit)
            || CASE WHEN v_u IS NULL THEN ''
                    WHEN SUBSTR(v_u, 1, 1) = '/' THEN v_u
                    ELSE ' ' || v_u END;
    END fv;

    -- normal range (mean +- 2 floored sigma) in the unit: "8.38-14.3 AAS"
    FUNCTION fv_range(p_mu NUMBER, p_sd NUMBER, p_unit VARCHAR2) RETURN VARCHAR2 IS
        v_den NUMBER;
        v_hi  NUMBER;
    BEGIN
        IF p_mu IS NULL OR p_sd IS NULL THEN RETURN '&mdash;'; END IF;
        v_den := GREATEST(p_sd, 0.02 * ABS(p_mu));
        v_hi  := p_mu + 2 * v_den;
        IF p_unit = 'B/s' THEN
            -- both ends in the unit of the upper one: "2.8-4.5 MB/s"
            RETURN fmt_num(GREATEST(0, p_mu - 2 * v_den)
                           / CASE WHEN ABS(v_hi) >= 1e9 THEN 1e9 WHEN ABS(v_hi) >= 1e6 THEN 1e6
                                  WHEN ABS(v_hi) >= 1e3 THEN 1e3 ELSE 1 END)
                || '&ndash;' || fv(v_hi, 'B/s');
        END IF;
        RETURN fmt_num(GREATEST(0, p_mu - 2 * v_den)) || '&ndash;' || fv(v_hi, p_unit);
    END fv_range;

    -- where the extra DB time went: 'W' all of it wait, 'w' mostly wait,
    -- 'm' CPU and wait alike, 'c' mostly CPU; NULL when DB time did not rise
    FUNCTION time_split(p_dbt_cur NUMBER, p_dbt_mu NUMBER,
                        p_cpu_cur NUMBER, p_cpu_mu NUMBER) RETURN VARCHAR2 IS
        v_x NUMBER;
        v_c NUMBER;
    BEGIN
        IF p_dbt_cur IS NULL OR p_dbt_mu IS NULL OR p_cpu_cur IS NULL OR p_cpu_mu IS NULL THEN
            RETURN NULL;
        END IF;
        v_x := p_dbt_cur - p_dbt_mu;
        IF v_x <= 0 THEN RETURN NULL; END IF;
        v_c := (p_cpu_cur - p_cpu_mu) / v_x;
        RETURN CASE WHEN v_c <= 0.1 THEN 'W'
                    WHEN v_c <= 0.4 THEN 'w'
                    WHEN v_c >= 0.6 THEN 'c'
                    ELSE 'm' END;
    END time_split;

    -- the headline move of a metric: "<b>5.4&times;</b> normal" (x n at
    -- twice the mean or more), "up <b>22.5%</b>", "down <b>31%</b>"; the
    -- number carries the Delta class of its bucket
    FUNCTION move_txt(p_cur NUMBER, p_mu NUMBER, p_bucket VARCHAR2) RETURN VARCHAR2 IS
        v_q   NUMBER;
        v_pct NUMBER;
        v_cls VARCHAR2(20) := CASE p_bucket WHEN 'large' THEN 's-large'
                                            WHEN 'moderate' THEN 's-moderate'
                                            WHEN 'improved' THEN 's-improved'
                                            ELSE 's-typical' END;
    BEGIN
        IF p_cur IS NULL OR p_mu IS NULL OR p_mu = 0 THEN RETURN 'moved'; END IF;
        v_q := p_cur / p_mu;
        IF p_mu > 0 AND v_q >= 2 THEN
            RETURN '<span class="d ' || v_cls || '">'
                || CASE WHEN v_q < 100
                        THEN TO_CHAR(v_q, 'FM99990D0', 'NLS_NUMERIC_CHARACTERS=''.,''')
                        ELSE TO_CHAR(ROUND(v_q), 'FM999999999990') END
                || '&times;</span> normal';
        END IF;
        v_pct := (p_cur - p_mu) / ABS(p_mu) * 100;
        RETURN CASE WHEN v_pct >= 0 THEN 'up ' ELSE 'down ' END
            || '<span class="d ' || v_cls || '">'
            || TO_CHAR(ABS(v_pct), 'FM999999990D0', 'NLS_NUMERIC_CHARACTERS=''.,''') || '%</span>';
    END move_txt;

    -- a subtle in-page link from a named entity to its detail row; the
    -- chrome unwraps it to plain text when the row was never emitted
    FUNCTION ent(p_html VARCHAR2, p_id VARCHAR2, p_kind VARCHAR2) RETURN VARCHAR2 IS
    BEGIN
        RETURN '<a class="ent" href="#' || p_id || '" data-ent="' || p_kind || '">'
            || p_html || '</a>';
    END ent;

    FUNCTION sev_rank(p_bucket VARCHAR2) RETURN PLS_INTEGER IS
    BEGIN
        RETURN CASE p_bucket WHEN 'large' THEN 2 WHEN 'moderate' THEN 1 ELSE 0 END;
    END sev_rank;

    -- which of two flagged rows leads a card: large before moderate, then a
    -- member of the card's primary family, then the larger |z|; a tie (a
    -- counter and its bytes twin move by the same z) goes to the plainer,
    -- shorter name ("Physical reads" over "Physical read bytes")
    FUNCTION lead_better(p_group VARCHAR2,
                         p_bkt_a VARCHAR2, p_fam_a VARCHAR2, p_z_a NUMBER,
                         p_bkt_b VARCHAR2, p_fam_b VARCHAR2, p_z_b NUMBER,
                         p_lab_a VARCHAR2 DEFAULT NULL, p_lab_b VARCHAR2 DEFAULT NULL) RETURN BOOLEAN IS
        v_pa PLS_INTEGER := CASE WHEN p_fam_a = card_primary(p_group) THEN 1 ELSE 0 END;
        v_pb PLS_INTEGER := CASE WHEN p_fam_b = card_primary(p_group) THEN 1 ELSE 0 END;
        v_za NUMBER := ROUND(ABS(NVL(p_z_a, 0)), 6);
        v_zb NUMBER := ROUND(ABS(NVL(p_z_b, 0)), 6);
    BEGIN
        IF sev_rank(p_bkt_a) <> sev_rank(p_bkt_b) THEN
            RETURN sev_rank(p_bkt_a) > sev_rank(p_bkt_b);
        END IF;
        IF v_pa <> v_pb THEN RETURN v_pa > v_pb; END IF;
        IF v_za <> v_zb THEN RETURN v_za > v_zb; END IF;
        RETURN NVL(LENGTH(p_lab_a), 999) < NVL(LENGTH(p_lab_b), 999);
    END lead_better;

    -- card order, part 1: large cards before moderate ones, then the larger
    -- |z| of ANY member (a card is as loud as its loudest metric).  Part 2,
    -- done by the caller after sorting: a flagged DB time card moves up to
    -- second place, right after the lead card -- it is the number users
    -- feel.  00 (verdict) and 07 (cards) apply the same two steps.
    FUNCTION card_before(p_sev_a PLS_INTEGER, p_z_a NUMBER,
                         p_sev_b PLS_INTEGER, p_z_b NUMBER) RETURN BOOLEAN IS
    BEGIN
        IF p_sev_a <> p_sev_b THEN RETURN p_sev_a > p_sev_b; END IF;
        RETURN NVL(p_z_a, 0) > NVL(p_z_b, 0);
    END card_before;
