--
-- sql/lib/js_markers.plsql
--
-- Client-side helper for user-defined timeline markers (milestones).
-- Emits one <script> that:
--   1. Initialises window.AWR_MARKERS = [] (each marker config line then
--      pushes a {t,label} object onto it; see sql/lib/marker.sql).
--   2. Defines window.AWR_markLine(catLabels) -> an ECharts markLine
--      config object (or null) for the calendar-timeline charts in
--      sections 00/09/10/11.
--
-- The dated charts use a `category` x-axis whose labels are
-- 'YYYY-MM-DD HH24:MI' strings, not a real time axis, so each marker is
-- snapped to the nearest category tick and markers outside the chart's
-- span are dropped (per chart).  Pure DOM + ECharts config; no extra CDN
-- dependency, and it degrades to nothing when ECharts is unavailable
-- (the init blocks return before calling it).
--
BEGIN
    DBMS_OUTPUT.PUT_LINE('<script>');
    DBMS_OUTPUT.PUT_LINE('window.AWR_MARKERS = window.AWR_MARKERS || [];');
    DBMS_OUTPUT.PUT_LINE('window.AWR_markLine = function(cats){');
    DBMS_OUTPUT.PUT_LINE('  var ms = window.AWR_MARKERS || [];');
    DBMS_OUTPUT.PUT_LINE('  if(!ms.length || !cats || cats.length < 2) return null;');
    DBMS_OUTPUT.PUT_LINE('  function ts(s){return Date.parse(String(s).replace(" ","T"));}');
    DBMS_OUTPUT.PUT_LINE('  var lo = ts(cats[0]), hi = ts(cats[cats.length-1]);');
    DBMS_OUTPUT.PUT_LINE('  if(isNaN(lo) || isNaN(hi)) return null;');
    DBMS_OUTPUT.PUT_LINE('  var cs = getComputedStyle(document.body);');
    DBMS_OUTPUT.PUT_LINE('  var ink = cs.getPropertyValue("--ink").trim() || "#333";');
    DBMS_OUTPUT.PUT_LINE('  var paper = cs.getPropertyValue("--paper").trim() || "#fff";');
    DBMS_OUTPUT.PUT_LINE('  var data = [];');
    DBMS_OUTPUT.PUT_LINE('  ms.forEach(function(m){');
    DBMS_OUTPUT.PUT_LINE('    var t = ts(m.t); if(isNaN(t) || t < lo || t > hi) return;');
    DBMS_OUTPUT.PUT_LINE('    var best = 0, bd = Infinity;');
    DBMS_OUTPUT.PUT_LINE('    for(var i=0;i<cats.length;i++){var dd=Math.abs(ts(cats[i])-t); if(dd<bd){bd=dd;best=i;}}');
    DBMS_OUTPUT.PUT_LINE('    data.push({xAxis:cats[best],');
    DBMS_OUTPUT.PUT_LINE('      label:{show:true,formatter:(function(lbl){return function(){return lbl;};})(m.label),');
    DBMS_OUTPUT.PUT_LINE('        rotate:90,position:"end",color:ink,fontSize:9,');
    DBMS_OUTPUT.PUT_LINE('        backgroundColor:paper,padding:[1,2,1,2],borderRadius:2,distance:3}});');
    DBMS_OUTPUT.PUT_LINE('  });');
    DBMS_OUTPUT.PUT_LINE('  if(!data.length) return null;');
    DBMS_OUTPUT.PUT_LINE('  return {symbol:["none","none"],silent:true,emphasis:{disabled:true},');
    DBMS_OUTPUT.PUT_LINE('    lineStyle:{type:"dashed",width:1,color:ink,opacity:0.75},data:data};');
    DBMS_OUTPUT.PUT_LINE('};');
    DBMS_OUTPUT.PUT_LINE('</script>');
END;
/
