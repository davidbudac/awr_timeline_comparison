--
-- sql/lib/off_label.plsql
--
-- The compact offset label of prior window k: "1w", "2d", "36h", "45m" --
-- k x step_hours in the units of the driver's fmt_one() (awr_trend.sql):
--   < 1h with whole-minute value -> "Nm"; multiple of 168 -> "Nw";
--   multiple of 24 -> "Nd"; multiple of 1 -> "Nh"; else "X.YYh".
-- One function for ANY window count.  The driver used to hand out a
-- 16-entry offset_labels DEFINE (a substitution variable holds at most
-- 240 characters, so it could not grow with weeks_back); past 16 windows
-- every column header, window chip and ruler label read a bare minus.
--
-- Include inside a DECLARE block after the plain variables (it declares a
-- function) and BEFORE sql/lib/wingrid.plsql, which calls it (lint check
-- 29).  Declares only a function (no TYPE).  Reads the step_hours DEFINE.
-- No tilde-words in comments below.
-- Twin: demo/awrdemo/model.py (World.offset_labels, one per window).
--

    FUNCTION off_label(p_k NUMBER) RETURN VARCHAR2 IS
        h NUMBER := p_k * (~step_hours);
    BEGIN
        IF h IS NULL THEN
            RETURN NULL;
        ELSIF h < 1 AND MOD(h * 60, 1) = 0 THEN
            RETURN TO_CHAR(ROUND(h * 60)) || 'm';
        ELSIF MOD(h, 168) = 0 THEN
            RETURN TO_CHAR(ROUND(h / 168)) || 'w';
        ELSIF MOD(h, 24) = 0 THEN
            RETURN TO_CHAR(ROUND(h / 24)) || 'd';
        ELSIF MOD(h, 1) = 0 THEN
            RETURN TO_CHAR(ROUND(h)) || 'h';
        END IF;
        RETURN TO_CHAR(h, 'FM999990.99', 'NLS_NUMERIC_CHARACTERS=''.,''') || 'h';
    END off_label;
