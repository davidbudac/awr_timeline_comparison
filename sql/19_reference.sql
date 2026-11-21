--
-- 19_reference.sql
-- Reference material shown in EVERY view (v1.6.0, "Mock D" round 2):
--   1. <section id="guide">  "Reading the charts": one small example and
--      one or two lines per chart / glyph kind.  Static markup -- the band
--      and Delta examples are the real components (sql/lib/band_glyph
--      .plsql classes), the rest are tiny inline SVGs drawn with the page's
--      CSS variables so they follow the theme.  Keep them in lockstep with
--      the .bd / .gd-* rules in sql/_style.sql when either changes.
--   2. <section id="about">  the ONE collapsed "About this report" fold
--      holding every method note (sources, formulas, thresholds, caveats)
--      that used to sit under each section heading.
-- Neither carries a view class (.vw), so both show in Summary, Timeline and
-- All sections alike; the rail links to them from its "Reference" group.
-- Emitted after section 12 and before 17 (17 must stay last).  No cursor,
-- no DML: only DEFINEs already resolved by the driver.  Twin:
-- demo/awrdemo/sections/s19_reference.py (lifts the literal PUT_LINEs).
-- Generated once from design/report_mock_d_hybrid.html; edit here.
--

SET DEFINE '~'
SET SERVEROUTPUT ON SIZE UNLIMITED

BEGIN DBMS_OUTPUT.PUT_LINE('<!-- AWR-SECTION: 19_reference BEGIN -->'); END;
/

BEGIN
    DBMS_OUTPUT.PUT_LINE('<section id="guide" class="guide" aria-labelledby="guide-h"><h2 id="guide-h">Reading the charts<small class="h2sub">What each chart and glyph on this page encodes</small></h2><div class="gdg">');
    DBMS_OUTPUT.PUT_LINE('<div class="gi"><div class="gv"><span class="bd s-large sm" style="--x:.767" role="img" aria-label="large, z +5.2&sigma;"><i></i></span><span class="bd s-typical sm" style="--x:.375" role="img"'
        || ' aria-label="normal, z +0.5&sigma;"><i></i></span></div><div class="gx2"><h3>Band</h3><p>Dot = Current, in &sigma; from the prior mean. Shaded = normal (&plusmn;1&sigma;, &plusmn;2&sigma;); ticks at'
        || ' &plusmn;2&sigma; and &plusmn;3&sigma;. <span class="g2">Filled = finding, hollow = normal; past +8&sigma; the dot pins and prints its z.</span></p></div></div>');
    DBMS_OUTPUT.PUT_LINE('<div class="gi"><div class="gv"><span class="gd-dl"><span class="d s-large">&#9650; &times;5.4</span><span class="d s-moderate">&#9650; 22.5%</span><span class="d s-typical">&#9660;'
        || ' 4.2%</span></span></div><div class="gx2"><h3>&Delta; vs mean</h3><p>&times;n when Current is at least twice the prior mean, else a percentage. <span class="g2">Red or amber only on a'
        || ' finding.</span></p></div></div>');
    DBMS_OUTPUT.PUT_LINE('<div class="gi"><div class="gv"><svg class="gd" width="152" height="44" viewBox="0 0 152 44" role="img" aria-label="Thirteen window columns, Current last and wider, with the normal band and a release'
        || ' flag"><rect class="gd-z2" x="0" y="22.0" width="152" height="9"/><line class="gd-mn" x1="0" x2="152" y1="26.5" y2="26.5"/><rect class="gd-b" x="2.0" y="27.0" width="8.4" height="13" rx="1"/><rect'
        || ' class="gd-b" x="12.8" y="28.0" width="8.4" height="12" rx="1"/><rect class="gd-b" x="23.6" y="25.0" width="8.4" height="15" rx="1"/><rect class="gd-b" x="34.4" y="27.0" width="8.4" height="13"'
        || ' rx="1"/><rect class="gd-b" x="45.2" y="28.0" width="8.4" height="12" rx="1"/><rect class="gd-b" x="56.0" y="26.0" width="8.4" height="14" rx="1"/><rect class="gd-b" x="66.8" y="27.0" width="8.4"'
        || ' height="13" rx="1"/><rect class="gd-b" x="77.6" y="28.0" width="8.4" height="12" rx="1"/><rect class="gd-b" x="88.4" y="25.0" width="8.4" height="15" rx="1"/><rect class="gd-b" x="99.2" y="26.0"'
        || ' width="8.4" height="14" rx="1"/><line class="gd-mk" x1="98.0" x2="98.0" y1="1" y2="40"/><path class="gd-mkf" d="M98.0 1h7l-2 3 2 3h-7z"/><rect class="gd-b" x="110.0" y="27.0" width="8.4" height="13"'
        || ' rx="1"/><rect class="gd-b" x="120.8" y="26.0" width="8.4" height="14" rx="1"/><rect class="gd-cbg" x="130.4" y="0" width="15.8" height="44"/><rect class="gd-bc" x="131.6" y="6.0" width="13.4"'
        || ' height="34" rx="1"/><circle class="gd-dot" cx="138.3" cy="6.0" r="3.4"/><line class="gd-ax" x1="0" x2="152" y1="40.5" y2="40.5"/></svg></div><div class="gx2"><h3>13-window chart</h3><p>One column'
        || ' per compared window, oldest left; Current last, wider, indigo. <span class="g2">Band = normal range, line = mean, dot = finding.</span></p></div></div>');
    DBMS_OUTPUT.PUT_LINE('<div class="gi"><div class="gv"><svg class="gd" width="152" height="44" viewBox="0 0 152 44" role="img" aria-label="Stacked area of active sessions by wait class with compared windows shaded"><path'
        || ' d="M0.0 28.8 L3.2 27.0 L6.5 25.4 L9.7 24.2 L12.9 23.5 L16.2 23.3 L19.4 23.8 L22.6 24.8 L25.9 26.3 L29.1 28.0 L32.3 29.8 L35.6 31.6 L38.8 33.0 L42.0 33.9 L45.3 34.3 L48.5 34.1 L51.7 33.3 L55.0 32.0'
        || ' L58.2 30.3 L61.4 28.5 L64.7 26.7 L67.9 25.2 L71.1 24.0 L74.4 23.4 L77.6 23.4 L80.9 23.9 L84.1 25.0 L87.3 26.5 L90.6 28.3 L93.8 30.1 L97.0 31.8 L100.3 33.1 L103.5 34.0 L106.7 34.3 L110.0 34.0 L113.2'
        || ' 33.1 L116.4 31.8 L119.7 30.1 L122.9 28.2 L126.1 26.5 L129.4 25.0 L132.6 23.9 L135.8 23.4 L139.1 23.4 L142.3 24.1 L145.5 25.2 L148.8 26.8 L152.0 28.6 L152.0 42.0 L148.8 42.0 L145.5 42.0 L142.3 42.0'
        || ' L139.1 42.0 L135.8 42.0 L132.6 42.0 L129.4 42.0 L126.1 42.0 L122.9 42.0 L119.7 42.0 L116.4 42.0 L113.2 42.0 L110.0 42.0 L106.7 42.0 L103.5 42.0 L100.3 42.0 L97.0 42.0 L93.8 42.0 L90.6 42.0 L87.3'
        || ' 42.0 L84.1 42.0 L80.9 42.0 L77.6 42.0 L74.4 42.0 L71.1 42.0 L67.9 42.0 L64.7 42.0 L61.4 42.0 L58.2 42.0 L55.0 42.0 L51.7 42.0 L48.5 42.0 L45.3 42.0 L42.0 42.0 L38.8 42.0 L35.6 42.0 L32.3 42.0 L29.1'
        || ' 42.0 L25.9 42.0 L22.6 42.0 L19.4 42.0 L16.2 42.0 L12.9 42.0 L9.7 42.0 L6.5 42.0 L3.2 42.0 L0.0 42.0Z" fill="#3FB344" class="gd-ar"/><path d="M0.0 20.0 L3.2 17.8 L6.5 16.3 L9.7 15.7 L12.9 16.0 L16.2'
        || ' 17.1 L19.4 18.7 L22.6 20.5 L25.9 22.3 L29.1 23.9 L32.3 25.0 L35.6 25.7 L38.8 25.9 L42.0 25.8 L45.3 25.4 L48.5 24.8 L51.7 24.3 L55.0 23.7 L58.2 23.1 L61.4 22.5 L64.7 21.8 L67.9 21.0 L71.1 20.1 L74.4'
        || ' 19.2 L77.6 18.4 L80.9 17.9 L84.1 17.8 L87.3 18.2 L90.6 19.3 L93.8 20.9 L97.0 22.9 L100.3 25.0 L103.5 27.0 L106.7 28.5 L110.0 29.2 L113.2 29.0 L116.4 27.8 L119.7 25.7 L122.9 23.1 L126.1 20.2 L129.4'
        || ' 17.5 L132.6 4.4 L135.8 3.3 L139.1 3.2 L142.3 4.2 L145.5 6.3 L148.8 9.0 L152.0 11.9 L152.0 28.6 L148.8 26.8 L145.5 25.2 L142.3 24.1 L139.1 23.4 L135.8 23.4 L132.6 23.9 L129.4 25.0 L126.1 26.5 L122.9'
        || ' 28.2 L119.7 30.1 L116.4 31.8 L113.2 33.1 L110.0 34.0 L106.7 34.3 L103.5 34.0 L100.3 33.1 L97.0 31.8 L93.8 30.1 L90.6 28.3 L87.3 26.5 L84.1 25.0 L80.9 23.9 L77.6 23.4 L74.4 23.4 L71.1 24.0 L67.9 25.2'
        || ' L64.7 26.7 L61.4 28.5 L58.2 30.3 L55.0 32.0 L51.7 33.3 L48.5 34.1 L45.3 34.3 L42.0 33.9 L38.8 33.0 L35.6 31.6 L32.3 29.8 L29.1 28.0 L25.9 26.3 L22.6 24.8 L19.4 23.8 L16.2 23.3 L12.9 23.5 L9.7 24.2'
        || ' L6.5 25.4 L3.2 27.0 L0.0 28.8Z" fill="#4A90D9" class="gd-ar"/><path d="M0.0 16.5 L3.2 13.5 L6.5 11.6 L9.7 10.9 L12.9 11.6 L16.2 13.3 L19.4 15.6 L22.6 18.1 L25.9 20.1 L29.1 21.5 L32.3 22.0 L35.6 21.9'
        || ' L38.8 21.5 L42.0 21.0 L45.3 20.6 L48.5 20.6 L51.7 20.7 L55.0 20.9 L58.2 20.8 L61.4 20.3 L64.7 19.2 L67.9 17.7 L71.1 16.1 L74.4 14.6 L77.6 13.5 L80.9 13.2 L84.1 13.7 L87.3 14.9 L90.6 16.7 L93.8 18.6'
        || ' L97.0 20.6 L100.3 22.3 L103.5 23.5 L106.7 24.2 L110.0 24.5 L113.2 24.1 L116.4 23.3 L119.7 21.9 L122.9 20.0 L126.1 17.8 L129.4 15.3 L132.6 2.0 L135.8 0.3 L139.1 -0.5 L142.3 -0.2 L145.5 1.5 L148.8 4.2'
        || ' L152.0 7.6 L152.0 11.9 L148.8 9.0 L145.5 6.3 L142.3 4.2 L139.1 3.2 L135.8 3.3 L132.6 4.4 L129.4 17.5 L126.1 20.2 L122.9 23.1 L119.7 25.7 L116.4 27.8 L113.2 29.0 L110.0 29.2 L106.7 28.5 L103.5 27.0'
        || ' L100.3 25.0 L97.0 22.9 L93.8 20.9 L90.6 19.3 L87.3 18.2 L84.1 17.8 L80.9 17.9 L77.6 18.4 L74.4 19.2 L71.1 20.1 L67.9 21.0 L64.7 21.8 L61.4 22.5 L58.2 23.1 L55.0 23.7 L51.7 24.3 L48.5 24.8 L45.3 25.4'
        || ' L42.0 25.8 L38.8 25.9 L35.6 25.7 L32.3 25.0 L29.1 23.9 L25.9 22.3 L22.6 20.5 L19.4 18.7 L16.2 17.1 L12.9 16.0 L9.7 15.7 L6.5 16.3 L3.2 17.8 L0.0 20.0Z" fill="#E89B40" class="gd-ar"/><rect'
        || ' class="gd-w" x="4.5" y="0" width="2.2" height="44"/><rect class="gd-w" x="15.7" y="0" width="2.2" height="44"/><rect class="gd-w" x="26.9" y="0" width="2.2" height="44"/><rect class="gd-w" x="38.1"'
        || ' y="0" width="2.2" height="44"/><rect class="gd-w" x="49.3" y="0" width="2.2" height="44"/><rect class="gd-w" x="60.5" y="0" width="2.2" height="44"/><rect class="gd-w" x="71.7" y="0" width="2.2"'
        || ' height="44"/><rect class="gd-w" x="82.9" y="0" width="2.2" height="44"/><rect class="gd-w" x="94.1" y="0" width="2.2" height="44"/><rect class="gd-w" x="105.3" y="0" width="2.2" height="44"/><rect'
        || ' class="gd-w" x="116.5" y="0" width="2.2" height="44"/><rect class="gd-w" x="127.7" y="0" width="2.2" height="44"/><rect class="gd-wc" x="138.9" y="0" width="3" height="44"/></svg></div><div'
        || ' class="gx2"><h3>Full-span activity</h3><p>Under the verdict in Summary (compact: by wait class; Show by wait event adds the second chart), at the top of Timeline and All sections: active sessions over the whole span as stacked areas, hourly (or the shorter cadence), by wait class and by wait event (the 14'
        || ' largest, the rest as Other events); zoomed to 6 hours or less, the compared windows minute by minute. <span class="g2">Stripes = compared windows (Current indigo, pinned amber, skipped grey). Hover for each series&rsquo; AAS, drag across either chart to zoom both,'
        || ' double-click to reset; a legend item hides its series, a stripe pins its window. Hover a class or event to highlight it: from the legend it is drawn from zero, its own axis;'
        || ' a class lights its events below. Click its band (or Shift+click the legend) to keep it, Esc clears. <b>Windows side by side</b>: the compared windows as adjacent panels on one y axis, a panel&rsquo;s top edge pins it. A band carries its name where it is thick enough over the name&rsquo;s width (cut short with ... when only a shorter piece fits).</span></p></div></div>');
    DBMS_OUTPUT.PUT_LINE('<div class="gi"><div class="gv"><svg class="gd" width="152" height="44" viewBox="0 0 152 44" role="img" aria-label="One stacked column per compared window"><rect class="gd-cbg" x="130.4" y="0"'
        || ' width="15.8" height="44"/><rect x="2.0" y="30.6" width="8.4" height="11.4" fill="#3FB344"/><rect x="2.0" y="26.6" width="8.4" height="3.4" fill="#4A90D9"/><rect x="2.0" y="23.6" width="8.4"'
        || ' height="2.4" fill="#E89B40"/><rect x="12.8" y="29.6" width="8.4" height="12.4" fill="#3FB344"/><rect x="12.8" y="25.6" width="8.4" height="3.4" fill="#4A90D9"/><rect x="12.8" y="22.6" width="8.4"'
        || ' height="2.4" fill="#E89B40"/><rect x="23.6" y="28.6" width="8.4" height="13.4" fill="#3FB344"/><rect x="23.6" y="24.6" width="8.4" height="3.4" fill="#4A90D9"/><rect x="23.6" y="21.6" width="8.4"'
        || ' height="2.4" fill="#E89B40"/><rect x="34.4" y="30.6" width="8.4" height="11.4" fill="#3FB344"/><rect x="34.4" y="26.6" width="8.4" height="3.4" fill="#4A90D9"/><rect x="34.4" y="23.6" width="8.4"'
        || ' height="2.4" fill="#E89B40"/><rect x="45.2" y="29.6" width="8.4" height="12.4" fill="#3FB344"/><rect x="45.2" y="25.6" width="8.4" height="3.4" fill="#4A90D9"/><rect x="45.2" y="22.6" width="8.4"'
        || ' height="2.4" fill="#E89B40"/><rect x="56.0" y="28.6" width="8.4" height="13.4" fill="#3FB344"/><rect x="56.0" y="24.6" width="8.4" height="3.4" fill="#4A90D9"/><rect x="56.0" y="21.6" width="8.4"'
        || ' height="2.4" fill="#E89B40"/><rect x="66.8" y="30.6" width="8.4" height="11.4" fill="#3FB344"/><rect x="66.8" y="26.6" width="8.4" height="3.4" fill="#4A90D9"/><rect x="66.8" y="23.6" width="8.4"'
        || ' height="2.4" fill="#E89B40"/><rect x="77.6" y="29.6" width="8.4" height="12.4" fill="#3FB344"/><rect x="77.6" y="25.6" width="8.4" height="3.4" fill="#4A90D9"/><rect x="77.6" y="22.6" width="8.4"'
        || ' height="2.4" fill="#E89B40"/><rect x="88.4" y="28.6" width="8.4" height="13.4" fill="#3FB344"/><rect x="88.4" y="24.6" width="8.4" height="3.4" fill="#4A90D9"/><rect x="88.4" y="21.6" width="8.4"'
        || ' height="2.4" fill="#E89B40"/><rect x="99.2" y="30.6" width="8.4" height="11.4" fill="#3FB344"/><rect x="99.2" y="26.6" width="8.4" height="3.4" fill="#4A90D9"/><rect x="99.2" y="23.6" width="8.4"'
        || ' height="2.4" fill="#E89B40"/><rect x="110.0" y="29.6" width="8.4" height="12.4" fill="#3FB344"/><rect x="110.0" y="25.6" width="8.4" height="3.4" fill="#4A90D9"/><rect x="110.0" y="22.6" width="8.4"'
        || ' height="2.4" fill="#E89B40"/><rect x="120.8" y="28.6" width="8.4" height="13.4" fill="#3FB344"/><rect x="120.8" y="24.6" width="8.4" height="3.4" fill="#4A90D9"/><rect x="120.8" y="21.6" width="8.4"'
        || ' height="2.4" fill="#E89B40"/><rect x="131.6" y="30.6" width="13.4" height="11.4" fill="#3FB344"/><rect x="131.6" y="14.6" width="13.4" height="15.4" fill="#4A90D9"/><rect x="131.6" y="11.6"'
        || ' width="13.4" height="2.4" fill="#E89B40"/></svg></div><div class="gx2"><h3>Activity per window</h3><p>Timeline Activity lane (all sessions) and the DB time card (foreground sessions only, ASH&rsquo;s estimate of DB time): one stacked column per compared window,'
        || ' same wait classes. <span class="g2">Current labels its two largest classes.</span></p></div></div>');
    DBMS_OUTPUT.PUT_LINE('<div class="gi"><div class="gv"><svg class="gd" width="152" height="44" viewBox="0 0 152 44" role="img" aria-label="Stacked area of active sessions by wait class"><path d="M0.0 28.8 L3.2 27.0 L6.5'
        || ' 25.4 L9.7 24.2 L12.9 23.5 L16.2 23.3 L19.4 23.8 L22.6 24.8 L25.9 26.3 L29.1 28.0 L32.3 29.8 L35.6 31.6 L38.8 33.0 L42.0 33.9 L45.3 34.3 L48.5 34.1 L51.7 33.3 L55.0 32.0 L58.2 30.3 L61.4 28.5 L64.7'
        || ' 26.7 L67.9 25.2 L71.1 24.0 L74.4 23.4 L77.6 23.4 L80.9 23.9 L84.1 25.0 L87.3 26.5 L90.6 28.3 L93.8 30.1 L97.0 31.8 L100.3 33.1 L103.5 34.0 L106.7 34.3 L110.0 34.0 L113.2 33.1 L116.4 31.8 L119.7 30.1'
        || ' L122.9 28.2 L126.1 26.5 L129.4 25.0 L132.6 23.9 L135.8 23.4 L139.1 23.4 L142.3 24.1 L145.5 25.2 L148.8 26.8 L152.0 28.6 L152.0 42.0 L148.8 42.0 L145.5 42.0 L142.3 42.0 L139.1 42.0 L135.8 42.0 L132.6'
        || ' 42.0 L129.4 42.0 L126.1 42.0 L122.9 42.0 L119.7 42.0 L116.4 42.0 L113.2 42.0 L110.0 42.0 L106.7 42.0 L103.5 42.0 L100.3 42.0 L97.0 42.0 L93.8 42.0 L90.6 42.0 L87.3 42.0 L84.1 42.0 L80.9 42.0 L77.6'
        || ' 42.0 L74.4 42.0 L71.1 42.0 L67.9 42.0 L64.7 42.0 L61.4 42.0 L58.2 42.0 L55.0 42.0 L51.7 42.0 L48.5 42.0 L45.3 42.0 L42.0 42.0 L38.8 42.0 L35.6 42.0 L32.3 42.0 L29.1 42.0 L25.9 42.0 L22.6 42.0 L19.4'
        || ' 42.0 L16.2 42.0 L12.9 42.0 L9.7 42.0 L6.5 42.0 L3.2 42.0 L0.0 42.0Z" fill="#3FB344" class="gd-ar"/><path d="M0.0 20.0 L3.2 17.8 L6.5 16.3 L9.7 15.7 L12.9 16.0 L16.2 17.1 L19.4 18.7 L22.6 20.5 L25.9'
        || ' 22.3 L29.1 23.9 L32.3 25.0 L35.6 25.7 L38.8 25.9 L42.0 25.8 L45.3 25.4 L48.5 24.8 L51.7 24.3 L55.0 23.7 L58.2 23.1 L61.4 22.5 L64.7 21.8 L67.9 21.0 L71.1 20.1 L74.4 19.2 L77.6 18.4 L80.9 17.9 L84.1'
        || ' 17.8 L87.3 18.2 L90.6 19.3 L93.8 20.9 L97.0 22.9 L100.3 25.0 L103.5 27.0 L106.7 28.5 L110.0 29.2 L113.2 29.0 L116.4 27.8 L119.7 25.7 L122.9 23.1 L126.1 20.2 L129.4 17.5 L132.6 4.4 L135.8 3.3 L139.1'
        || ' 3.2 L142.3 4.2 L145.5 6.3 L148.8 9.0 L152.0 11.9 L152.0 28.6 L148.8 26.8 L145.5 25.2 L142.3 24.1 L139.1 23.4 L135.8 23.4 L132.6 23.9 L129.4 25.0 L126.1 26.5 L122.9 28.2 L119.7 30.1 L116.4 31.8'
        || ' L113.2 33.1 L110.0 34.0 L106.7 34.3 L103.5 34.0 L100.3 33.1 L97.0 31.8 L93.8 30.1 L90.6 28.3 L87.3 26.5 L84.1 25.0 L80.9 23.9 L77.6 23.4 L74.4 23.4 L71.1 24.0 L67.9 25.2 L64.7 26.7 L61.4 28.5 L58.2'
        || ' 30.3 L55.0 32.0 L51.7 33.3 L48.5 34.1 L45.3 34.3 L42.0 33.9 L38.8 33.0 L35.6 31.6 L32.3 29.8 L29.1 28.0 L25.9 26.3 L22.6 24.8 L19.4 23.8 L16.2 23.3 L12.9 23.5 L9.7 24.2 L6.5 25.4 L3.2 27.0 L0.0'
        || ' 28.8Z" fill="#4A90D9" class="gd-ar"/><path d="M0.0 16.5 L3.2 13.5 L6.5 11.6 L9.7 10.9 L12.9 11.6 L16.2 13.3 L19.4 15.6 L22.6 18.1 L25.9 20.1 L29.1 21.5 L32.3 22.0 L35.6 21.9 L38.8 21.5 L42.0 21.0'
        || ' L45.3 20.6 L48.5 20.6 L51.7 20.7 L55.0 20.9 L58.2 20.8 L61.4 20.3 L64.7 19.2 L67.9 17.7 L71.1 16.1 L74.4 14.6 L77.6 13.5 L80.9 13.2 L84.1 13.7 L87.3 14.9 L90.6 16.7 L93.8 18.6 L97.0 20.6 L100.3 22.3'
        || ' L103.5 23.5 L106.7 24.2 L110.0 24.5 L113.2 24.1 L116.4 23.3 L119.7 21.9 L122.9 20.0 L126.1 17.8 L129.4 15.3 L132.6 2.0 L135.8 0.3 L139.1 -0.5 L142.3 -0.2 L145.5 1.5 L148.8 4.2 L152.0 7.6 L152.0 11.9'
        || ' L148.8 9.0 L145.5 6.3 L142.3 4.2 L139.1 3.2 L135.8 3.3 L132.6 4.4 L129.4 17.5 L126.1 20.2 L122.9 23.1 L119.7 25.7 L116.4 27.8 L113.2 29.0 L110.0 29.2 L106.7 28.5 L103.5 27.0 L100.3 25.0 L97.0 22.9'
        || ' L93.8 20.9 L90.6 19.3 L87.3 18.2 L84.1 17.8 L80.9 17.9 L77.6 18.4 L74.4 19.2 L71.1 20.1 L67.9 21.0 L64.7 21.8 L61.4 22.5 L58.2 23.1 L55.0 23.7 L51.7 24.3 L48.5 24.8 L45.3 25.4 L42.0 25.8 L38.8 25.9'
        || ' L35.6 25.7 L32.3 25.0 L29.1 23.9 L25.9 22.3 L22.6 20.5 L19.4 18.7 L16.2 17.1 L12.9 16.0 L9.7 15.7 L6.5 16.3 L3.2 17.8 L0.0 20.0Z" fill="#E89B40" class="gd-ar"/><circle class="gd-dp" cx="6.0"'
        || ' cy="10.6" r="2.2"/><circle class="gd-dp" cx="17.2" cy="12.3" r="2.2"/><circle class="gd-dp" cx="28.4" cy="20.5" r="2.2"/><circle class="gd-dp" cx="39.6" cy="20.5" r="2.2"/><circle class="gd-dp"'
        || ' cx="50.8" cy="19.7" r="2.2"/><circle class="gd-dp" cx="62.0" cy="19.3" r="2.2"/><circle class="gd-dp" cx="73.2" cy="13.6" r="2.2"/><circle class="gd-dp" cx="84.4" cy="12.7" r="2.2"/><circle'
        || ' class="gd-dp" cx="95.6" cy="19.6" r="2.2"/><circle class="gd-dp" cx="106.8" cy="23.2" r="2.2"/><circle class="gd-dp" cx="118.0" cy="22.3" r="2.2"/><circle class="gd-dp" cx="129.2" cy="14.3"'
        || ' r="2.2"/><circle class="gd-dc" cx="140.4" cy="-1.5" r="3"/></svg></div><div class="gx2"><h3>Span chart</h3><p>All sections: active sessions by wait class across the whole span. <span'
        || ' class="g2">Compared windows shaded, Current in indigo.</span></p></div></div>');
    -- the Trend cell of the per-window tables (sql/lib/js_microstrip.plsql)
    DBMS_OUTPUT.PUT_LINE('<div class="gi"><div class="gv"><svg class="mw" width="92" height="22" viewBox="0 0 92 22" role="img" aria-label="Thirteen-bar micro strip"><rect class="z2" x="0" y="11" width="92" height="6" rx="1"/><rect class="b" x="0.0" y="13" width="5.2" height="8" rx="1"/><rect class="b" x="6.8" y="14" width="5.2" height="7" rx="1"/><rect class="b" x="13.6" y="12" width="5.2" height="9" rx="1"/><rect class="b" x="20.4" y="13" width="5.2" height="8" rx="1"/><rect class="b" x="27.2" y="14" width="5.2" height="7" rx="1"/><rect class="b" x="34.0" y="13" width="5.2" height="8" rx="1"/>'
        || '<rect class="b" x="40.8" y="13" width="5.2" height="8" rx="1"/><rect class="b" x="47.6" y="14" width="5.2" height="7" rx="1"/><rect class="b" x="54.4" y="12" width="5.2" height="9" rx="1"/><rect class="b" x="61.2" y="13" width="5.2" height="8" rx="1"/><rect class="b" x="68.0" y="13" width="5.2" height="8" rx="1"/><rect class="b" x="74.8" y="12" width="5.2" height="9" rx="1"/><rect class="b cur" x="81.6" y="2" width="8.3" height="19" rx="1"/></svg></div><div class="gx2"><h3>Trend</h3><p>A table row&rsquo;s windows as bars from zero, oldest left: shaded = normal range, indigo = Current.'
        || ' <span class="g2">Hover a strip for the last four values and the normal range.</span></p></div></div>');
    DBMS_OUTPUT.PUT_LINE('<div class="gi"><div class="gv"><svg class="gd" width="150" height="44" viewBox="0 0 150 44" role="img" aria-label="A release flag on the boundary between two windows"><rect class="gd-cell" x="0"'
        || ' y="18" width="150" height="24"/><line class="gd-cl" x1="30" x2="30" y1="18" y2="42"/><line class="gd-cl" x1="60" x2="60" y1="18" y2="42"/><line class="gd-cl" x1="90" x2="90" y1="18" y2="42"/><line'
        || ' class="gd-cl" x1="120" x2="120" y1="18" y2="42"/><line class="gd-mk" x1="60" x2="60" y1="2" y2="42"/><rect class="gd-flg" x="60" y="2" width="44" height="12" rx="2"/><text class="gd-t" x="64"'
        || ' y="11">Release</text></svg></div><div class="gx2"><h3>Release marker</h3><p>A release or patch, on the boundary between the two windows it fell between. <span class="g2">Its line runs down every'
        || ' chart. On the Activity charts, markers at one spot get a flag each while there is room, then one &ldquo;+n&rdquo; flag whose tooltip lists the rest.</span></p></div></div>');
    DBMS_OUTPUT.PUT_LINE('<div class="gi"><div class="gv"><svg class="gd" width="150" height="44" viewBox="0 0 150 44" role="img" aria-label="Step line: value changes between two windows"><path class="gd-st" d="M0'
        || ' 32H86V14H150"/><line class="gd-str" x1="86" x2="86" y1="32" y2="14"/><circle class="gd-nd" cx="86" cy="14" r="3.5"/><text class="gd-t m" x="4" y="28">FALSE</text><text class="gd-t m b" x="92"'
        || ' y="10">TRUE</text></svg></div><div class="gx2"><h3>Step line</h3><p>Parameters and plan hashes step where the value changed. <span class="g2">Dot = the change; labels = old and new'
        || ' value.</span></p></div></div>');
    DBMS_OUTPUT.PUT_LINE('<div class="gi"><div class="gv"><span class="gd-gl"><span><b>&#9670;</b> plan changed</span><span><b>&#10010;</b> first seen</span><span><b>&#9661;</b> DOP downgrade</span></span></div><div'
        || ' class="gx2"><h3>Glyphs</h3><p>Drawn in the window where it happened.</p></div></div>');
    -- the Day profile heatmap of section 16 (Timeline and All sections)
    DBMS_OUTPUT.PUT_LINE('<div class="gi"><div class="gv"><svg class="gd" width="152" height="44" viewBox="0 0 152 44" role="img" aria-label="Day profile heatmap: stats by hour, signed z">'
        || '<rect x="2.0" y="6" width="5.6" height="14" style="fill:var(--crit-dot);fill-opacity:0.90"/><rect x="8.2" y="6" width="5.6" height="14" style="fill:var(--crit-dot);fill-opacity:0.90"/><rect x="14.4" y="6" width="5.6" height="14" style="fill:var(--crit-dot);fill-opacity:0.80"/><rect x="20.6" y="6" width="5.6" height="14" style="fill:var(--crit-dot);fill-opacity:0.90"/><rect x="26.8" y="6" width="5.6" height="14" style="fill:var(--crit-dot);fill-opacity:0.80"/><rect x="33.0" y="6" width="5.6" height="14" style="fill:var(--crit-dot);fill-opacity:0.70"/><rect x="39.2" y="6" width="5.6" height="14" style="fill:var(--crit-dot);fill-opacity:0.60"/><rect x="45.4" y="6" width="5.6" height="14" style="fill:var(--crit-dot);fill-opacity:0.50"/><rect x="51.6" y="6" width="5.6" height="14" style="fill:var(--crit-dot);fill-opacity:0.35"/><rect x="57.8" y="6" width="5.6" height="14" style="fill:var(--crit-dot);fill-opacity:0.30"/>'
        || '<rect x="64.0" y="6" width="5.6" height="14" style="fill:var(--crit-dot);fill-opacity:0.20"/><rect x="70.2" y="6" width="5.6" height="14" style="fill:var(--crit-dot);fill-opacity:0.20"/><rect x="76.4" y="6" width="5.6" height="14" style="fill:var(--crit-dot);fill-opacity:0.15"/><rect x="82.6" y="6" width="5.6" height="14" style="fill:var(--crit-dot);fill-opacity:0.10"/><rect x="88.8" y="6" width="5.6" height="14" style="fill:var(--crit-dot);fill-opacity:0.10"/><rect x="95.0" y="6" width="5.6" height="14" style="fill:var(--crit-dot);fill-opacity:0.15"/><rect x="101.2" y="6" width="5.6" height="14" style="fill:var(--crit-dot);fill-opacity:0.20"/><rect x="107.4" y="6" width="5.6" height="14" style="fill:var(--crit-dot);fill-opacity:0.20"/><rect x="113.6" y="6" width="5.6" height="14" style="fill:var(--crit-dot);fill-opacity:0.25"/><rect x="119.8" y="6" width="5.6" height="14" style="fill:var(--crit-dot);fill-opacity:0.20"/>'
        || '<rect x="126.0" y="6" width="5.6" height="14" style="fill:var(--crit-dot);fill-opacity:0.30"/><rect x="132.2" y="6" width="5.6" height="14" style="fill:var(--crit-dot);fill-opacity:0.25"/><rect x="138.4" y="6" width="5.6" height="14" style="fill:var(--crit-dot);fill-opacity:0.30"/><rect x="144.6" y="6" width="5.6" height="14" style="fill:var(--crit-dot);fill-opacity:0.35"/><rect x="2.0" y="22" width="5.6" height="14" style="fill:var(--crit-dot);fill-opacity:0.12"/><rect x="8.2" y="22" width="5.6" height="14" style="fill:var(--crit-dot);fill-opacity:0.10"/><rect x="14.4" y="22" width="5.6" height="14" style="fill:var(--crit-dot);fill-opacity:0.09"/><rect x="20.6" y="22" width="5.6" height="14" style="fill:var(--crit-dot);fill-opacity:0.10"/><rect x="26.8" y="22" width="5.6" height="14" style="fill:var(--crit-dot);fill-opacity:0.07"/><rect x="33.0" y="22" width="5.6" height="14" style="fill:var(--crit-dot);fill-opacity:0.09"/>'
        || '<rect x="39.2" y="22" width="5.6" height="14" style="fill:var(--crit-dot);fill-opacity:0.07"/><rect x="45.4" y="22" width="5.6" height="14" style="fill:var(--crit-dot);fill-opacity:0.07"/><rect x="51.6" y="22" width="5.6" height="14" style="fill:var(--crit-dot);fill-opacity:0.06"/><rect x="57.8" y="22" width="5.6" height="14" style="fill:var(--crit-dot);fill-opacity:0.06"/><rect x="64.0" y="22" width="5.6" height="14" style="fill:var(--crit-dot);fill-opacity:0.06"/><rect x="70.2" y="22" width="5.6" height="14" style="fill:var(--crit-dot);fill-opacity:0.06"/><rect x="76.4" y="22" width="5.6" height="14" style="fill:var(--crit-dot);fill-opacity:0.07"/><rect x="82.6" y="22" width="5.6" height="14" style="fill:var(--crit-dot);fill-opacity:0.07"/><rect x="88.8" y="22" width="5.6" height="14" style="fill:var(--crit-dot);fill-opacity:0.10"/><rect x="95.0" y="22" width="5.6" height="14" style="fill:var(--crit-dot);fill-opacity:0.12"/>'
        || '<rect x="101.2" y="22" width="5.6" height="14" style="fill:var(--crit-dot);fill-opacity:0.17"/><rect x="107.4" y="22" width="5.6" height="14" style="fill:var(--crit-dot);fill-opacity:0.21"/><rect x="113.6" y="22" width="5.6" height="14" style="fill:var(--crit-dot);fill-opacity:0.24"/><rect x="119.8" y="22" width="5.6" height="14" style="fill:var(--crit-dot);fill-opacity:0.28"/><rect x="126.0" y="22" width="5.6" height="14" style="fill:var(--crit-dot);fill-opacity:0.32"/><rect x="132.2" y="22" width="5.6" height="14" style="fill:var(--crit-dot);fill-opacity:0.28"/><rect x="138.4" y="22" width="5.6" height="14" style="fill:var(--crit-dot);fill-opacity:0.32"/><rect x="144.6" y="22" width="5.6" height="14" style="fill:var(--crit-dot);fill-opacity:0.32"/><rect x="82.6" y="22" width="5.6" height="14" style="fill:var(--acc);fill-opacity:.45"/>'
        || '</svg></div><div class="gx2"><h3>Day profile</h3><p>Last 24 h by hour vs the same hour on the prior days, one row per stat: red above, blue below (signed z).'
        || ' <span class="g2">A triangle marks a flagged hour; the line chart below it plots one stat: pick it with its button (the dot and counts say how unusual its day is), a row label, or the arrow keys.</span></p></div></div>');
    DBMS_OUTPUT.PUT_LINE('<div class="gi"><div class="gv"><svg class="gd" width="150" height="44" viewBox="0 0 150 44" role="img" aria-label="A pinned column highlighted in amber"><line class="gd-cl" x1="0.0" x2="0.0" y1="0"'
        || ' y2="44"/><rect class="gd-b" x="6.7" y="28" width="8" height="12" rx="1"/><line class="gd-cl" x1="21.4" x2="21.4" y1="0" y2="44"/><rect class="gd-b" x="28.1" y="28" width="8" height="12"'
        || ' rx="1"/><rect class="gd-pin" x="42.8" y="0" width="21.4" height="44"/><line class="gd-cl" x1="42.8" x2="42.8" y1="0" y2="44"/><rect class="gd-b" x="49.5" y="28" width="8" height="12" rx="1"/><line'
        || ' class="gd-cl" x1="64.2" x2="64.2" y1="0" y2="44"/><rect class="gd-b" x="70.9" y="28" width="8" height="12" rx="1"/><line class="gd-cl" x1="85.6" x2="85.6" y1="0" y2="44"/><rect class="gd-b" x="92.3"'
        || ' y="28" width="8" height="12" rx="1"/><line class="gd-cl" x1="107.0" x2="107.0" y1="0" y2="44"/><rect class="gd-b" x="113.7" y="28" width="8" height="12" rx="1"/><rect class="gd-cbg" x="128.4" y="0"'
        || ' width="21.4" height="44"/><line class="gd-cl" x1="128.4" x2="128.4" y1="0" y2="44"/><rect class="gd-bc" x="135.1" y="14" width="8" height="26" rx="1"/><text class="gd-t pn" x="53.5" y="10"'
        || ' text-anchor="middle">pinned</text></svg></div><div class="gx2"><h3>Hover and pin</h3><p>Timeline: hover a column for its values; click a date or an ASH stripe to pin it. <span class="g2">The gutter'
        || ' then compares against it (&ldquo;vs 13 Aug&rdquo;); Current or Esc clears it.</span></p></div></div>');
    -- the visualization sections (20-28): one item each
    DBMS_OUTPUT.PUT_LINE('<div class="gi"><div class="gv"><svg class="gd" width="150" height="44" viewBox="0 0 150 44" role="img" aria-label="Scatter of load against response time with a dashed normal'
        || ' curve"><path d="M6 12 C30 30 70 33 144 34" style="stroke:var(--ink-3);fill:none" stroke-dasharray="3 3"/><circle cx="14" cy="20" r="1.6" style="fill:var(--ink-4)"/><circle'
        || ' cx="22" cy="26" r="1.6" style="fill:var(--ink-4)"/><circle cx="34" cy="30" r="1.6" style="fill:var(--ink-4)"/><circle cx="46" cy="31" r="1.6" style="fill:var(--ink-4)"/><circle'
        || ' cx="58" cy="33" r="1.6" style="fill:var(--ink-4)"/><circle cx="70" cy="32" r="1.6" style="fill:var(--ink-4)"/><circle cx="82" cy="34" r="1.6" style="fill:var(--ink-4)"/><circle'
        || ' cx="94" cy="33" r="1.6" style="fill:var(--ink-4)"/><circle cx="106" cy="35" r="1.6" style="fill:var(--ink-4)"/><circle cx="120" cy="34" r="1.6" style="fill:var(--ink-4)"/><circle'
        || ' cx="132" cy="33" r="1.6" style="fill:var(--ink-4)"/><circle cx="96" cy="10" r="4" style="fill:var(--acc)"/></svg></div><div class="gx2"><h3>Load vs response time</h3><p>Further'
        || ' right means busier, higher means each call took longer; a Current dot along the dashed curve is just more traffic. <span class="g2">A Current dot high above the curve at its'
        || ' usual load means each call got slower: something broke, not the volume.</span></p></div></div>');
    DBMS_OUTPUT.PUT_LINE('<div class="gi"><div class="gv"><svg class="gd" width="150" height="44" viewBox="0 0 150 44" role="img" aria-label="Log-log plane: executions across, time per execution up,'
        || ' diagonals of equal total time"><line x1="6" x2="144" y1="30" y2="30" style="stroke:var(--line-2);fill:none"/><line x1="60" x2="60" y1="2" y2="42"'
        || ' style="stroke:var(--line-2);fill:none"/><line x1="20" x2="110" y1="2" y2="42" style="stroke:var(--ink-3);fill:none" stroke-dasharray="3 3"/><circle cx="56" cy="31" r="2"'
        || ' style="fill:var(--ink-4)"/><circle cx="63" cy="28" r="2" style="fill:var(--ink-4)"/><circle cx="66" cy="32" r="2" style="fill:var(--ink-4)"/><circle cx="72" cy="29" r="2"'
        || ' style="fill:var(--ink-4)"/><circle cx="62" cy="9" r="5" style="fill:var(--crit-dot)"/><circle cx="118" cy="29" r="3.5" style="fill:var(--crit-dot)"/></svg></div><div'
        || ' class="gx2"><h3>Volume vs unit cost</h3><p>Each dot is a statement or wait event: how often it ran across, how long each run took up, both against its own normal; dot area is its'
        || ' time in Current. <span class="g2">Right = ran more often (look at the caller); up = slower per run (plan, I/O, locks); the dashed diagonals mark equal total'
        || ' time.</span></p></div></div>');
    DBMS_OUTPUT.PUT_LINE('<div class="gi"><div class="gv"><svg class="gd" width="150" height="44" viewBox="0 0 150 44" role="img" aria-label="Histogram of wait latency: Current bars against the normal'
        || ' shape"><rect x="8" y="36" width="12" height="4" rx="1" style="fill:var(--acc);fill-opacity:.75"/><rect x="22" y="26" width="12" height="14" rx="1"'
        || ' style="fill:var(--acc);fill-opacity:.75"/><rect x="36" y="10" width="12" height="30" rx="1" style="fill:var(--acc);fill-opacity:.75"/><rect x="50" y="18" width="12" height="22"'
        || ' rx="1" style="fill:var(--acc);fill-opacity:.75"/><rect x="64" y="32" width="12" height="8" rx="1" style="fill:var(--acc);fill-opacity:.75"/><rect x="78" y="38" width="12"'
        || ' height="2" rx="1" style="fill:var(--acc);fill-opacity:.75"/><rect x="106" y="38" width="12" height="2" rx="1" style="fill:var(--acc);fill-opacity:.75"/><rect x="120" y="34"'
        || ' width="12" height="6" rx="1" style="fill:var(--acc);fill-opacity:.75"/><path d="M8 37H22V27H36V9H50V16H64V31H78V37H134V40" style="stroke:var(--ink-3);fill:none"/></svg></div><div'
        || ' class="gx2"><h3>Latency histogram</h3><p>Bars are the Current window&rsquo;s share of an event&rsquo;s waits per latency bucket (each bucket twice as wide as the one before); the'
        || ' stepped line is the normal shape. <span class="g2">A bar standing alone to the right of the line is a slow tail; the whole hump sliding right means every wait got'
        || ' slower.</span></p></div></div>');
    DBMS_OUTPUT.PUT_LINE('<div class="gi"><div class="gv"><svg class="gd" width="150" height="44" viewBox="0 0 150 44" role="img" aria-label="Icicle chart of a plan: one bar per plan step"><rect x="4"'
        || ' y="2" width="142" height="9" rx="1" style="fill:var(--zone2)"/><rect x="4" y="13" width="120" height="9" rx="1" style="fill:var(--zone2)"/><rect x="4" y="24" width="20"'
        || ' height="9" rx="1" style="fill:var(--zone2)"/><rect x="26" y="24" width="96" height="9" rx="1" fill="#4A90D9"/><rect x="124" y="13" width="10" height="9" rx="1"'
        || ' fill="#3FB344"/><rect x="26" y="35" width="30" height="7" rx="1" style="fill:var(--zone2)"/></svg></div><div class="gx2"><h3>Plan shape (icicle)</h3><p>Each bar is one plan step,'
        || ' as wide as the DB time spent on it and every step beneath it, so the widest path down is where a statement&rsquo;s time goes. <span class="g2">The coloured end of a bar is time'
        || ' on the step itself, by what it was doing; old and new plan share one scale.</span></p></div></div>');
    DBMS_OUTPUT.PUT_LINE('<div class="gi"><div class="gv"><svg class="gd" width="150" height="44" viewBox="0 0 150 44" role="img" aria-label="Blocking graph: a holder on the left, the sessions waiting'
        || ' behind it on the right"><rect x="4" y="14" width="44" height="16" rx="3" style="fill:none;stroke:var(--ink-2);stroke-width:1.5"/><rect x="98" y="2" width="48" height="11" rx="3"'
        || ' style="fill:var(--acc-band);stroke:var(--acc)"/><rect x="98" y="17" width="48" height="11" rx="3" style="fill:var(--acc-band);stroke:var(--acc)"/><rect x="98" y="32" width="48"'
        || ' height="11" rx="3" style="fill:var(--acc-band);stroke:var(--acc)"/><path d="M48 22 C70 22 76 7 98 7" style="stroke:var(--acc);fill:none;stroke-width:3;stroke-opacity:.6"/><path'
        || ' d="M48 22H98" style="stroke:var(--acc);fill:none;stroke-width:1.5;stroke-opacity:.6"/><path d="M48 22 C70 22 76 37 98 37"'
        || ' style="stroke:var(--acc);fill:none;stroke-width:1;stroke-opacity:.6"/></svg></div><div class="gx2"><h3>Blocking graph</h3><p>Each box is a session: the final holder on the left,'
        || ' the sessions waiting behind it to the right; an arrow&rsquo;s width and label are the seconds that waiter spent behind the holder. <span class="g2">A dashed holder was never'
        || ' sampled in the window, often a session idle in an open transaction.</span></p></div></div>');
    DBMS_OUTPUT.PUT_LINE('<div class="gi"><div class="gv"><svg class="gd" width="150" height="44" viewBox="0 0 150 44" role="img" aria-label="A series that steps up at a detected onset"><rect x="4" y="22"'
        || ' width="142" height="12" style="fill:var(--zone2)"/><path d="M4 29 L20 26 L36 30 L52 27 L68 29 L84 28 L92 14 L108 10 L124 13 L146 9"'
        || ' style="stroke:var(--ink-2);fill:none;stroke-width:1.5"/><line x1="86" x2="86" y1="2" y2="42" style="stroke:var(--crit-dot);stroke-width:1.5"/></svg></div><div'
        || ' class="gx2"><h3>Onset</h3><p>The line is a metric at every snapshot interval, the grey band its normal for that hour, and the red rule the detected onset: when the shift that is'
        || ' still open began. <span class="g2">The strip below is the CUSUM: it climbs while the series stays off its level, and a step is called where it crosses the dashed'
        || ' threshold.</span></p></div></div>');
    DBMS_OUTPUT.PUT_LINE('<div class="gi"><div class="gv"><svg class="gd" width="150" height="44" viewBox="0 0 150 44" role="img" aria-label="Matrix of window-to-window similarity with one odd row and'
        || ' column"><rect x="50" y="2" width="9" height="9" style="fill:var(--mean);fill-opacity:.15"/><rect x="60" y="2" width="9" height="9"'
        || ' style="fill:var(--mean);fill-opacity:.75"/><rect x="70" y="2" width="9" height="9" style="fill:var(--mean);fill-opacity:.15"/><rect x="80" y="2" width="9" height="9"'
        || ' style="fill:var(--mean);fill-opacity:.15"/><rect x="50" y="12" width="9" height="9" style="fill:var(--mean);fill-opacity:.75"/><rect x="60" y="12" width="9" height="9"'
        || ' style="fill:var(--mean);fill-opacity:.15"/><rect x="70" y="12" width="9" height="9" style="fill:var(--mean);fill-opacity:.75"/><rect x="80" y="12" width="9" height="9"'
        || ' style="fill:var(--mean);fill-opacity:.75"/><rect x="50" y="22" width="9" height="9" style="fill:var(--mean);fill-opacity:.15"/><rect x="60" y="22" width="9" height="9"'
        || ' style="fill:var(--mean);fill-opacity:.75"/><rect x="70" y="22" width="9" height="9" style="fill:var(--mean);fill-opacity:.15"/><rect x="80" y="22" width="9" height="9"'
        || ' style="fill:var(--mean);fill-opacity:.15"/><rect x="50" y="32" width="9" height="9" style="fill:var(--mean);fill-opacity:.15"/><rect x="60" y="32" width="9" height="9"'
        || ' style="fill:var(--mean);fill-opacity:.75"/><rect x="70" y="32" width="9" height="9" style="fill:var(--mean);fill-opacity:.15"/><rect x="80" y="32" width="9" height="9"'
        || ' style="fill:var(--mean);fill-opacity:.15"/></svg></div><div class="gx2"><h3>Window similarity</h3><p>Each cell compares two compared windows over every material metric: the'
        || ' stronger the shade, the further apart they are, so a strong row and column is a prior window unlike the rest (a holiday, a month-end, an outage). <span class="g2">The chips below'
        || ' drop a prior window and re-score the report in the page, so you see what the verdict would be without it.</span></p></div></div>');
    DBMS_OUTPUT.PUT_LINE('<div class="gi"><div class="gv"><svg class="gd" width="150" height="44" viewBox="0 0 150 44" role="img" aria-label="Schematic of the instance with one area flagged"><rect x="4"'
        || ' y="14" width="34" height="16" rx="3" style="fill:none;stroke:var(--line-2)"/><rect x="58" y="14" width="34" height="16" rx="3" style="fill:none;stroke:var(--line-2)"/><rect'
        || ' x="112" y="14" width="34" height="16" rx="3" style="fill:var(--crit-dot);fill-opacity:.12;stroke:var(--crit-dot)"/><path d="M38 22H58"'
        || ' style="stroke:var(--line-2);fill:none"/><path d="M112 22H92" style="stroke:var(--crit-dot);fill:none;stroke-width:2"/><circle cx="119" cy="22" r="2.5"'
        || ' style="fill:var(--crit-dot)"/></svg></div><div class="gx2"><h3>Instance map</h3><p>Boxes are parts of the instance, arrows the flow of work; a red or amber box (and its thicker'
        || ' arrow) is where the findings are, with its loudest metric and &Delta; inside. <span class="g2">Hover a box for its flagged metrics; click it to open its finding'
        || ' card.</span></p></div></div>');
    DBMS_OUTPUT.PUT_LINE('<div class="gi"><div class="gv"><svg class="gd" width="150" height="44" viewBox="0 0 150 44" role="img" aria-label="Lollipop rows: the change after a release against the usual'
        || ' variation"><line x1="60" x2="60" y1="2" y2="42" style="stroke:var(--line-2);fill:none"/><rect x="52" y="5" width="16" height="8" rx="2" style="fill:var(--zone2)"/><rect x="50"'
        || ' y="18" width="20" height="8" rx="2" style="fill:var(--zone2)"/><rect x="54" y="31" width="12" height="8" rx="2" style="fill:var(--zone2)"/><line x1="60" x2="128" y1="9" y2="9"'
        || ' style="stroke:var(--crit-dot);stroke-width:2"/><circle cx="128" cy="9" r="3.5" style="fill:var(--crit-dot)"/><line x1="60" x2="92" y1="22" y2="22"'
        || ' style="stroke:var(--crit-dot);stroke-width:2"/><circle cx="92" cy="22" r="3.5" style="fill:var(--crit-dot)"/><circle cx="63" cy="35" r="3"'
        || ' style="fill:var(--ink-4)"/></svg></div><div class="gx2"><h3>Before and after a release</h3><p>Each row is one metric: the grey band is how much it varied in the windows before'
        || ' the split, the dot how far its mean moved after it. <span class="g2">A hollow dot means only one window follows; small ticks are the individual windows after; the word says'
        || ' whether the move is outside the band and in the bad direction.</span></p></div></div>');
    DBMS_OUTPUT.PUT_LINE('</div></section>');
    -- About this report: every method note, one fold.  Parameter values
    -- come from the driver's DEFINEs.
    DBMS_OUTPUT.PUT_LINE('<section id="about" class="aboutsec"><details class="aboutrep"><summary><span class="lt">About this report</span><span class="ls">Method, sources and thresholds behind every'
        || ' section</span></summary><div class="ab-body"><dl class="notes">');
    DBMS_OUTPUT.PUT_LINE('<dt>Scoring</dt><dd>z = (Current &minus; &mu;) &divide; max(&sigma;, 2% of |&mu;|) over the prior <b>valid</b> windows. |z| &gt; 3 is large, |z| &gt; 2 moderate, else normal &mdash; but only when the'
        || ' move is material: |&Delta;| &ge; 10% and, for wait classes, &ge; 2% of the Current window&rsquo;s wait time (otherwise normal, tagged <i>immaterial</i>). Each metric has its own direction and floors'
        || ' (<code>sql/lib/metric_policy.plsql</code>): a move in the good direction is <b>improved</b>, an informational counter is <b>noted</b> &mdash; neither is highlighted or counted. Twins (the SYSMETRIC'
        || ' rate of a SYSSTAT counter, the CPU half of the CPU/wait ratio) are shown muted and never counted. Fewer than 3 prior values: &Delta; only. |z| beyond &plusmn;99 is capped for display;'
        || ' &sigma;&approx;0 flags a baseline that barely moved.</dd>');
    DBMS_OUTPUT.PUT_LINE('<dt>Band and &Delta;</dt><dd>The band plots Current in &sigma; from the prior mean on one scale for the whole page (&minus;4 to +8&sigma;). Normal range = &mu; &plusmn; 2&sigma; in the row&rsquo;s'
        || ' own unit. &Delta; vs mean reads &times;n at twice the mean or more, else a percentage.</dd>');
    DBMS_OUTPUT.PUT_LINE('<dt>Windows</dt><dd>One window per step back from <b>~target_end_resolved</b>, ~win_label wide, every ~step_label. A window is skipped (and dropped from every baseline) when a snapshot is missing,'
        || ' the begin and end snapshot are the same, the instance restarted inside it, it straddles a DBID change, or its nearest snapshot is more than 15 minutes off the window edge.</dd>');
    DBMS_OUTPUT.PUT_LINE('<dt>DB time</dt><dd>DB CPU (<code>dba_hist_sys_time_model</code>, foreground) plus non-idle wait time (<code>dba_hist_system_event</code>, <b>all sessions incl. background</b>) per snapshot interval,'
        || ' stacked by wait class, from the earliest compared window to Current. Not a strict foreground DB-time profile. A snapshot pair across an instance restart is a gap.</dd>');
    DBMS_OUTPUT.PUT_LINE('<dt>Verdict</dt><dd>One sentence from the first two finding cards (the card that added the most DB time, then DB time when it is flagged): the lead metric and its move, &times;n at twice the mean'
        || ' or more, else a percentage. For DB time, where the extra time went: CPU vs wait from DB CPU against DB time. <b>Likely source</b>: a statement that ran with a new plan in the'
        || ' Current window, else a newcomer in the top SQL by physical reads, else a statement first seen this window, else the segment the extra reads land on. Fixed phrases, no free text.'
        || ' <b>Where the extra DB time went</b>: the DB-time rise split into DB CPU and the foreground wait time of each wait class (<code>time_waited_micro_fg</code>; Current minus prior mean, average active sessions), largest first; solid = behind a finding, hatched = grew but stayed inside its normal range.'
        || ' Like DB time the parts count foreground sessions only, so they roughly add up to the rise: DB time that no wait class records (such as waiting for a CPU) is the unlabelled rest (the rise less the parts&rsquo; net sum, so a part that fell offsets one that rose), and DB time (time model) and the parts (wait interface) are kept apart by Oracle, so they never match to the digit.</dd>');
    DBMS_OUTPUT.PUT_LINE('<dt>Finding cards</dt><dd>One card per metric family of the scoring policy (<code>sql/lib/metric_policy.plsql</code>); families that tell one story share a card:'
        || ' Physical I/O (physical and logical reads, long table scans, User I/O waits), DB time (DB time, the CPU / wait ratio, response time), Network (Network waits, SQL*Net bytes), Commit'
        || ' (Commit waits, commits), Parsing, Writes and redo. A card is led by its loudest large, else moderate, metric of the card&rsquo;s main family.'
        || ' Cards are ordered by the time they added: the rise of the card&rsquo;s time measure (DB time, DB CPU or the foreground wait time of its wait class) above its prior mean, in'
        || ' average active sessions, largest first; cards whose time measure rose by less than 0.01 average active sessions, fell, or that have none follow, large before moderate'
        || ' (the chip still shows a smaller rise). A wait class is scored on all sessions, background included;'
        || ' only the time it added counts foreground sessions, like DB time. The printed z of a band in the Summary view'
        || ' stops at &gt;+10&sigma;; tables show the exact value. Twins are folded under'
        || ' <b>related metrics</b> and never counted.</dd>');
    DBMS_OUTPUT.PUT_LINE('<dt>DB time strip</dt><dd><code>DBA_HIST_SYSSTAT</code> DB time per compared window, divided by 100 (centiseconds per second = average active sessions); release markers sit'
        || ' on the boundary between the two windows they fall between.</dd>');
    DBMS_OUTPUT.PUT_LINE('<dt>Checked and normal</dt><dd>Every other scored metric: the normal ones, loudest first; <b>moved, too small to matter</b> = past |z| 2 but under the metric&rsquo;s'
        || ' materiality floor, or an informational counter; <b>improved</b> = a material move in the good direction. None of them is counted.</dd>');
    DBMS_OUTPUT.PUT_LINE('<dt>What changed around it</dt><dd><b>Plan change</b>: a statement that ran in the Current window with a plan other than the prior windows&rsquo; most frequent one'
        || ' (SQL Monitor). Its bars are its elapsed seconds per window from <code>DBA_HIST_SQLSTAT</code>; the step line is the most frequent captured plan per window, carried over windows'
        || ' with no capture; only the SQL Monitor max elapsed is scored. <b>Configuration</b>: every changed parameter as a step line.</dd>');
    DBMS_OUTPUT.PUT_LINE('<dt>Evidence library</dt><dd>Summary view: every other section as one row with a one-line status and its counts; open a row to read the section in place.'
        || ' All sections shows every section in full.</dd>');
    DBMS_OUTPUT.PUT_LINE('<dt>ASH timeline</dt><dd><code>dba_hist_active_sess_history</code> over the full span, one scan: hourly (or the cadence) in All sections; in the Activity charts (under'
        || ' the verdict in Summary, at the top of the other views) on the same grid (coarser only past 10000 buckets), by wait class and by wait event (the 14 events with the most samples, ties by name,'
        || ' the rest summed as Other events), plus each compared window&rsquo;s own values (samples &divide; 360 &divide; window hours; overlapping windows each count a shared sample)'
        || ' and a 1-minute series inside the compared windows (samples &divide; 6, each minute once; at most 40000 minutes, the most recent windows first), drawn when zoomed'
        || ' to 6 hours or less.'
        || ' <b>Windows side by side</b> draws each compared window as its own panel from the same data: the 1-minute series where it covers the whole window, else the coarse buckets.'
        || ' ON CPU is <b>CPU</b> in both; Idle excluded. Compared windows shaded. ASH is not scored. Each event carries its wait class from the same scan, so'
        || ' highlighting a class lights its events (and an event its class); a highlighted series is re-stacked from zero on its own y axis, the others faded above it.</dd>');
    DBMS_OUTPUT.PUT_LINE('<dt>Timeline</dt><dd>One column per compared window, one row per metric, from the same values and scoring as the tables: the headline and every flagged load / metric'
        || ' row, flagged wait classes and the top foreground events (both in AAS; an event row is each window&rsquo;s seconds waited divided by that window&rsquo;s snapshot span, as for the classes;'
        || ' its severity, z and &Delta; are the table&rsquo;s), the top segments and datafile by reads, the top statements by elapsed (SQL Monitor rows for a plan change or a DOP'
        || ' downgrade), changed parameters. Statement, segment and file rows are ranked, not scored: a plain ratio against the mean of the prior windows they made the top list in.'
        || ' Needs JavaScript; every number is also in All sections.</dd>');
    IF ~profile_days > 0 THEN
        DBMS_OUTPUT.PUT_LINE('<dt>Day profile</dt><dd>Each hour of the 24 h ending at the report end against the <b>same hour-of-day</b> on the ~profile_days prior days, independent of the report cadence. Per-second rates from'
            || ' <code>DBA_HIST_SYSSTAT</code> snapshot deltas (restart-guarded); an hour covered by less than 30 minutes of snapshots is left blank. Cells are scored like the findings (at least 3 prior values). A'
            || ' stat flagged in 12 or more hours in the same direction is one <b>day-wide shift</b>, not isolated hours. The heatmap shows <b>signed</b> z.</dd>');
    END IF;
    DBMS_OUTPUT.PUT_LINE('<dt>Utilization</dt><dd>Workload volume and shape (transaction, call and logon rates, session counts, data and network volume) from <code>DBA_HIST_SYSMETRIC_SUMMARY</code>, averaged over each window.'
        || ' A usage overview, not a health check: the band is drawn but never scored.</dd>');
    DBMS_OUTPUT.PUT_LINE('<dt>Load profile</dt><dd><code>DBA_HIST_SYSSTAT</code> (end &minus; begin snapshot) &divide; window seconds, summed across instances. <b>Trend</b>: per-window values as bars, oldest to Current, over the shaded normal range.'
        || ' <b>Current</b> cell bar = value &divide; row maximum.</dd>');
    DBMS_OUTPUT.PUT_LINE('<dt>System metrics</dt><dd><code>DBA_HIST_SYSMETRIC_SUMMARY</code> averaged over each window. Rates and counters: SUM across instances per snapshot, then AVG; ratios and latencies: AVG across'
        || ' instances per snapshot, then AVG. Units per metric name.</dd>');
    DBMS_OUTPUT.PUT_LINE('<dt>Wait events</dt><dd>Foreground: <code>DBA_HIST_SYSTEM_EVENT</code>; background: <code>DBA_HIST_BG_EVENT_SUMMARY</code>. Idle excluded. Top ~top_n events by time waited (s) and by average latency'
        || ' (ms = time waited &divide; total waits); the chart stacks wait-class time per window. When five or more flagged events moved together within a narrow band, the table notes one <b>table-wide'
        || ' shift</b> and demotes large rows to moderate.</dd>');
    DBMS_OUTPUT.PUT_LINE('<dt>Top SQL</dt><dd>Top ~top_n statements per ranking and window from <code>DBA_HIST_SQLSTAT</code> <code>*_DELTA</code> columns; ranked, not scored. The bump chart draws one line per statement'
        || ' across the windows; <b>Break down by</b> re-aggregates by parsing schema, module or action.'
        || ' <b>Biggest change</b>, the first tab, ranks statements by Current-window total elapsed minus the mean over the prior valid windows'
        || ' (a valid window without an AWR row for the statement counts as 0; regressions only; the tab is left out when nothing got slower);'
        || ' the &Delta; next to the Current value compares the two: <i>new</i> when no prior valid window has a row for the statement,'
        || ' <i>from 0</i> when its rows there all show 0 s elapsed.</dd>');
    DBMS_OUTPUT.PUT_LINE('<dt>Top SQL ASH</dt><dd>For each statement in the Top SQL pool: ASH samples per bucket split by wait event (top 7 per statement, the rest as <b>Other</b>; <b>CPU</b> = ON CPU). Statements with fewer'
        || ' than 5 samples are placeholders.</dd>');
    DBMS_OUTPUT.PUT_LINE('<dt>SQL Monitor</dt><dd>Executions persisted by SQL Monitor (<code>DBA_HIST_REPORTS</code>, <code>component_name=&#39;sqlmonitor&#39;</code>), summaries only. Only completed, expensive-enough or'
        || ' parallel executions are persisted, so a statement&rsquo;s absence does not mean it ran fast and row counts are not execution rates. An execution still running at the report end has no row yet. Rows'
        || ' are attributed to a window by execution <i>start</i> time. The table is scored on max elapsed time (rule above); the scatter plots every captured execution.'
        || ' The table lists large, then moderate rows first, each group by Current max elapsed (JavaScript off: by Current max elapsed only).</dd>');
    DBMS_OUTPUT.PUT_LINE('<dt>Segment and file I/O</dt><dd>Segments: <code>DBA_HIST_SEG_STAT</code> <code>*_DELTA</code> joined to <code>DBA_HIST_SEG_STAT_OBJ</code>; reads and writes in blocks, requests in I/O calls. Files:'
        || ' <code>DBA_HIST_FILESTATXS</code> / <code>DBA_HIST_TEMPSTATXS</code> deltas, blocks scaled to MB by block size; the file-type view is <code>DBA_HIST_IOSTAT_FILETYPE</code> (all database I/O, so its'
        || ' totals differ). Ranked, not scored; the type rollups cover <b>all</b> segments and files.</dd>');
    DBMS_OUTPUT.PUT_LINE('<dt>Parameters</dt><dd>Initialization parameters from <code>dba_hist_parameter</code> whose value differs across the compared windows (value as of each window&rsquo;s end snapshot, lowest container'
        || ' wins in a CDB). Highlighted cells differ from Current; &mdash; = not present at that snapshot; (unset) = present but empty.</dd>');
    -- the visualization sections (20-28)
    DBMS_OUTPUT.PUT_LINE('<dt>Instance map</dt><dd>The findings drawn on a schematic of the instance. Each area takes the worst bucket of the counted metrics behind it: their policy family decides the area'
        || ' (network and calls &rarr; clients; DB time, CPU, response &rarr; sessions; Application / Concurrency waits &rarr; locks; parses &rarr; shared pool; logical reads &rarr; buffer'
        || ' cache; physical writes &rarr; DBWR; redo, commits &rarr; LGWR; physical reads, User I/O &rarr; datafiles; System I/O &rarr; redo logs; disk sorts &rarr; temp; other wait classes'
        || ' &rarr; other). It is scored with the same rule as the finding cards, so a flagged area always has a card, and clicking the area opens it. Twins never colour a box; with fewer'
        || ' than 3 valid prior windows every area is &ldquo;not measured&rdquo;.</dd>');
    DBMS_OUTPUT.PUT_LINE('<dt>Load vs response time</dt><dd>Each dot is one snapshot interval (<code>DBA_HIST_SYSMETRIC_SUMMARY</code>): x = load (user calls, executions or logical reads per second), y ='
        || ' response time (SQL Service Response Time, or DB time divided by that load). The dashed &ldquo;normal for that load&rdquo; curve joins the medians of up to 8 equal-count load bins'
        || ' of every interval outside the Current window; the band is their 25th&ndash;75th percentile. The verdict compares Current with the prior windows on both axes through the'
        || ' report&rsquo;s own rule (z over max(&sigma;, 2% of the mean) plus the policy&rsquo;s materiality floors) and, when both rose, Current&rsquo;s ratio to the curve with the prior'
        || ' windows&rsquo; ratios. It explains; it adds no finding.</dd>');
    DBMS_OUTPUT.PUT_LINE('<dt>Before and after a release</dt><dd>The valid compared windows are split at a release marker (or a window boundary you pick): windows ending at or before it are'
        || ' &ldquo;before&rdquo;, windows starting at or after it are &ldquo;after&rdquo; (Current is always after), a window containing it belongs to neither. Per metric the after mean is'
        || ' compared with the before mean; the band is the before windows&rsquo; mean &plusmn; 2 sd (sd floored at 2% of the mean). Outside the band and past the metric policy&rsquo;s'
        || ' materiality floor = marked worse / better / changed by the policy&rsquo;s direction. Markers exist only in the page, so the split is computed by the page script; JS off shows'
        || ' Current against all prior windows.</dd>');
    DBMS_OUTPUT.PUT_LINE('<dt>Wait latency histograms</dt><dd>From <code>DBA_HIST_EVENT_HISTOGRAM</code>: per compared window, end minus begin per power-of-two latency bucket (a bucket missing in one'
        || ' snapshot never goes negative), summed over instances, valid windows only. For the Current window&rsquo;s top foreground events (the Foreground waits order, at most 8), the'
        || ' Current share of waits per bucket is set against the mean share over prior valid windows with 30 or more waits, with their min&ndash;max. Fixed rules on the count percentiles'
        || ' (one bucket = a factor of two): slow tail = p95 up two or more buckets while the median moves at most one; shifted = median moves two or more; tail gone = p95 down two or more;'
        || ' volume only = shape alike but the count ratio is 2x or more (or 0.5x or less). Fewer than 30 Current waits, or fewer than two qualifying prior windows, is not compared. By time'
        || ' weights each bucket by waits &times; its midpoint (an approximation). Explanatory only: no findings, no severity. Needs SELECT on <code>DBA_HIST_EVENT_HISTOGRAM</code>; without'
        || ' it the section shows a note.</dd>');
    DBMS_OUTPUT.PUT_LINE('<dt>Blocking</dt><dd>Blocked time = ASH samples whose holder is known by session (<code>blocking_session_status</code> VALID) &times; 10 s, any event, per compared window; GLOBAL'
        || ' (holder on another RAC instance, not named) is counted apart; NO HOLDER / NOT IN WAIT / UNKNOWN are ignored. Not scored: no metric policy line fits, the strip shows the plain'
        || ' &Delta; vs the prior mean. The graph follows every blocked Current sample up its chain to the final holder in that same sample (sessions keyed by instance, sid and serial#; a'
        || ' cycle stops the walk), then sums the paths: top 5 holders, 6 direct waiters, 3 below each, deeper waiters summed. The row opens at 300 s or more of Current blocked time when that'
        || ' is at least twice the prior mean (or there is no usable baseline).</dd>');
    DBMS_OUTPUT.PUT_LINE('<dt>Volume vs unit cost</dt><dd>Each statement in the Current window&rsquo;s top by elapsed time (and each foreground wait event of the Foreground waits table) is placed against'
        || ' its own normal, taken over the valid prior windows in which it completed at least one execution (had at least one wait): across = executions (waits) now / normal, up = time per'
        || ' execution (per wait) now / normal, where normal time per execution = normal total / normal executions, so the diagonals of equal total time are exact. &ldquo;Costs more&rdquo; ='
        || ' total time at least 1.5&times; normal and at least 2% of the plotted Current total; &ldquo;more often&rdquo; = executions at least 1.5&times; with time per run under 1.5&times;,'
        || ' &ldquo;slower per run&rdquo; the reverse, anything else &ldquo;both&rdquo;. A statement no valid prior window saw is listed as new in Current (a skipped window never makes it'
        || ' new); one with no completed execution now is only counted. Foreground columns of <code>DBA_HIST_SYSTEM_EVENT</code>, so event numbers can differ from the Foreground waits table,'
        || ' which shows all sessions. Explains only: it adds no findings.</dd>');
    DBMS_OUTPUT.PUT_LINE('<dt>Plan shape</dt><dd>For statements in the Current window&rsquo;s top N by elapsed whose plan hash differs from the plan they used most in the prior valid windows (at most'
        || ' three), ASH samples are counted per plan line: the new plan inside the Current window, the old plan inside the prior windows divided by the number of prior windows it has samples'
        || ' in. One sample is about 10 s of DB time, so both read in seconds per window. The plan tree comes from <code>DBA_HIST_SQL_PLAN</code> (without SELECT on it the section lists the'
        || ' samples by plan line only); samples without a plan line are counted on the root step. With no plan change, the highest-ranked of the first three top statements with at least 5'
        || ' samples is shown alone.</dd>');
    DBMS_OUTPUT.PUT_LINE('<dt>Onset</dt><dd>Every snapshot interval of the span (time-weighted over irregular snapshots; a restart or a missed snapshot is a gap, never 0) of DB time, DB CPU, user calls,'
        || ' executions, logical and physical reads and redo is compared with its normal: the median of the same hour of the week in the other weeks (spans of 21 days or more), else of the'
        || ' same hour of the day on the other days (3 days or more), else of every point before the Current window. Spread = interquartile range / 1.349, at least 2% of the median and the'
        || ' metric&rsquo;s materiality floor from the policy; a point needs 3 same-hour points from 2 other periods (flat: 8). Residuals, clipped to &plusmn;3 spreads, feed a two-sided CUSUM'
        || ' with the textbook slack k = 0.5 and threshold h = 5 (about 465 points between false alarms on clean noise, about 10 points to catch a one-spread shift). At each crossing the scan'
        || ' records a step (onset = where that sum last stood at zero) and restarts from the new level, so a shift on top of an earlier one is dated from its own start. A shift is open when'
        || ' the last run of steps is still away from the normal and the Current window&rsquo;s median residual agrees. A release marker within 6 h of an onset is named beside it. On a span'
        || ' under 3 days the normal is flat, so a daily rhythm can read as a shift; the sentence says which normal it used.</dd>');
    DBMS_OUTPUT.PUT_LINE('<dt>Window similarity</dt><dd>Each canonical metric that reaches its materiality floor in at least one window (twins left out) is scaled per window as (value &minus; median)'
        || ' &divide; spread over the valid windows, spread = 1.4826 &times; MAD floored at 2% of |median| (else 1.2533 &times; the mean absolute deviation; a constant metric is left out).'
        || ' Two windows&rsquo; distance is the mean, over the metrics both have, of min(|a &minus; b|, 5): how many robust spreads apart they are on average, capped so one metric cannot'
        || ' decide alone. A mean absolute difference rather than a correlation, because it reads in the band glyph&rsquo;s unit and a correlation is blind to a uniformly lower window (a'
        || ' holiday). A prior window&rsquo;s distance from the other priors is the median of its distances to them; it is odd above max(median + 3 &times; 1.4826 &times; MAD, 1.5 &times;'
        || ' median) of those distances. Odd windows that are alike each other form a group (a change or an episode, not a single odd window). The what-if re-scores every metric in the'
        || ' browser with the findings&rsquo; own rule against the priors left; with nothing dropped it reproduces the reported buckets exactly.</dd>');
    DBMS_OUTPUT.PUT_LINE('</dl>');
    DBMS_OUTPUT.PUT_LINE('<p class="ab-meta">Run <code>~run_id</code> &middot; template <code>'
        || DBMS_XMLGEN.CONVERT('~template_name') || '</code> &middot; top_n ~top_n'
        || ' &middot; generated ~generated_at_s by ' || DBMS_XMLGEN.CONVERT('~caller_user')
        || CASE WHEN '~sqlmon_on' = 'N'
                THEN ' &middot; SQL Monitor skipped (<code>sqlmon=N</code>)' END
        || ' &middot; read-only against '
        || '<code>DBA_HIST_*</code>, no scratch schema.</p>');
    DBMS_OUTPUT.PUT_LINE('</div></details></section>');
END;
/

BEGIN DBMS_OUTPUT.PUT_LINE('<!-- AWR-SECTION: 19_reference END -->'); END;
/
