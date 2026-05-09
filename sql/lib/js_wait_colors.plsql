--
-- sql/lib/js_wait_colors.plsql
--
-- Wait-class colour map shared by every chart that stacks by wait_class
-- (sections 09 ASH timeline + 10 DB time summary). Approximation of the
-- Oracle Enterprise Manager 13c "Top Activity" / ASH analytics palette;
-- exact OEM hex codes drift across releases so these are eyeballed
-- conventions, not lifted from a docs page. Charts fall back to their
-- positional palette for any wait_class that is not in this map.
--
-- Emitted from the driver prologue via @@-include after the AWR_DATA
-- bootstrap, before any section runs.
--
BEGIN
    DBMS_OUTPUT.PUT_LINE('<script>window.AWR_WAIT_COLORS = {');
    DBMS_OUTPUT.PUT_LINE('  "CPU":            "#3FB344",');
    DBMS_OUTPUT.PUT_LINE('  "Scheduler":      "#88C070",');
    DBMS_OUTPUT.PUT_LINE('  "User I/O":       "#4A90D9",');
    DBMS_OUTPUT.PUT_LINE('  "System I/O":     "#1F4E89",');
    DBMS_OUTPUT.PUT_LINE('  "Concurrency":    "#8B0000",');
    DBMS_OUTPUT.PUT_LINE('  "Application":    "#D62728",');
    DBMS_OUTPUT.PUT_LINE('  "Commit":         "#E89B40",');
    DBMS_OUTPUT.PUT_LINE('  "Configuration":  "#793C32",');
    DBMS_OUTPUT.PUT_LINE('  "Administrative": "#7B6FA8",');
    DBMS_OUTPUT.PUT_LINE('  "Network":        "#967259",');
    DBMS_OUTPUT.PUT_LINE('  "Queueing":       "#E89BB7",');
    DBMS_OUTPUT.PUT_LINE('  "Cluster":        "#E5C228",');
    DBMS_OUTPUT.PUT_LINE('  "Other":          "#C77CB0"');
    DBMS_OUTPUT.PUT_LINE('};</script>');
END;
/
