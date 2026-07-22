--
-- sql/fleet/js_fleet_charts.plsql
--
-- The fleet report's inline-SVG chart + interaction layer (no ECharts, no
-- external anything).  @@-included once by sql/fleet/00_fleet_chrome.sql, so
-- it ships in the shared chrome copy every DB spools (the assembler keeps the
-- first).  On DOMContentLoaded it:
--   * renders every [data-ash-of] div from window.FLEET_ASH -- a 24h ASH
--     stacked-area chart, either "ribbon" mode (172x30, marker ticks, no
--     labels; in the summary dbrow) or "timeline" mode (640x108, y-gridlines
--     + AAS labels, x hour labels, dashed labeled marker lines; in the
--     detailrow), positioning markers from window.FLEET_MARKERS by timestamp;
--   * wires row expand/collapse (delegated click on tr.dbrow -> its sibling
--     tr.detailrow);
--   * wires the masthead theme toggle (flip body.dark, persist localStorage
--     "awr-theme" -- same key the early bootstrap + single-DB report use).
--
-- Axis/label/gridline colors are emitted as var(--muted)/var(--line-soft)
-- CSS-var references inside the SVG, so they re-resolve automatically on a
-- theme flip -- no JS re-render needed.  The wait-class fill hexes ARE
-- theme-independent and copied from sql/lib/js_wait_colors.plsql; keep the
-- WC map below in lockstep with that file (do not edit the lib file).
--
-- Emitted as double-quoted JS (inner quotes backslash-escaped) so the SQL
-- single-quoted literals never need doubling, matching js_sparkline.plsql;
-- contains no apostrophes and no '~' (the tilde is the live substitution
-- char in every fleet SQL file).
--
BEGIN
    DBMS_OUTPUT.PUT_LINE('<script>(function(){');
    DBMS_OUTPUT.PUT_LINE('"use strict";');
    -- wait-class palette -- LOCKSTEP with sql/lib/js_wait_colors.plsql
    DBMS_OUTPUT.PUT_LINE('var WC={"CPU":"#3FB344","Scheduler":"#88C070","User I/O":"#4A90D9","System I/O":"#1F4E89","Concurrency":"#8B0000","Application":"#D62728","Commit":"#E89B40","Configuration":"#793C32","Administrative":"#7B6FA8","Network":"#967259","Queueing":"#E89BB7","Cluster":"#E5C228","Other":"#C77CB0"};');
    DBMS_OUTPUT.PUT_LINE('var WCO=["CPU","Scheduler","User I/O","System I/O","Concurrency","Application","Commit","Configuration","Administrative","Network","Queueing","Cluster","Other"];');
    DBMS_OUTPUT.PUT_LINE('var N=24;');
    DBMS_OUTPUT.PUT_LINE('function esc(s){return String(s==null?"":s).replace(/[&<>]/g,function(c){return({"&":"&amp;","<":"&lt;",">":"&gt;"})[c];});}');
    DBMS_OUTPUT.PUT_LINE('function pad2(n){return (n<10?"0":"")+n;}');
    DBMS_OUTPUT.PUT_LINE('function parseTs(s){if(!s)return NaN;return Date.parse(String(s).replace(" ","T"));}');
    DBMS_OUTPUT.PUT_LINE('function markerColor(i){return (i%2===0)?"var(--accent)":"var(--warn)";}');
    DBMS_OUTPUT.PUT_LINE('function markersFor(t0){var out=[],base=parseTs(t0);if(isNaN(base))return out;var M=window.FLEET_MARKERS||[];for(var k=0;k<M.length;k++){var t=parseTs(M[k].t);if(isNaN(t))continue;var i=(t-base)/3600000;if(i<0||i>N-1)continue;out.push({i:i,color:markerColor(k),label:M[k].l});}return out;}');
    DBMS_OUTPUT.PUT_LINE('function svgEl(w,h){return "<svg viewBox=\"0 0 "+w+" "+h+"\" width=\""+w+"\" height=\""+h+"\" preserveAspectRatio=\"none\" xmlns=\"http://www.w3.org/2000/svg\">";}');
    DBMS_OUTPUT.PUT_LINE('function xLabels(t0){var base=parseTs(t0),idx=[0,6,12,18,23];return idx.map(function(i){if(isNaN(base))return [i,""];var d=new Date(base+i*3600000);return [i,pad2(d.getHours())+":"+pad2(d.getMinutes())];});}');
    -- order the per-class value arrays into WCO stacking order, extras appended
    DBMS_OUTPUT.PUT_LINE('function orderSeries(classes,vals){var by={},i;for(i=0;i<classes.length;i++)by[classes[i]]=vals[i];var ser=[];WCO.forEach(function(k){if(by[k]){ser.push({cls:k,vals:by[k]});delete by[k];}});for(var k in by){if(by.hasOwnProperty(k))ser.push({cls:k,vals:by[k]});}return ser;}');
    -- stacked ASH area chart (ribbon or timeline)
    DBMS_OUTPUT.PUT_LINE('function buildStack(classes,vals,w,h,opts){');
    DBMS_OUTPUT.PUT_LINE('  opts=opts||{};var pad=opts.pad||{t:0,r:0,b:0,l:0};');
    DBMS_OUTPUT.PUT_LINE('  var iw=w-pad.l-pad.r,ih=h-pad.t-pad.b,series=orderSeries(classes,vals),n=N,i,s;');
    DBMS_OUTPUT.PUT_LINE('  var maxTotal=0;for(i=0;i<n;i++){var t=0;for(s=0;s<series.length;s++){var v=series[s].vals[i];t+=(v==null||isNaN(v))?0:+v;}if(t>maxTotal)maxTotal=t;}');
    DBMS_OUTPUT.PUT_LINE('  var maxY=opts.maxY||Math.max(maxTotal*1.08,0.5);');
    DBMS_OUTPUT.PUT_LINE('  function X(i){return pad.l+(n<=1?0:(i/(n-1))*iw);}');
    DBMS_OUTPUT.PUT_LINE('  function Y(v){return pad.t+ih-(v/maxY)*ih;}');
    DBMS_OUTPUT.PUT_LINE('  var out=svgEl(w,h);');
    DBMS_OUTPUT.PUT_LINE('  if(opts.bg){out+="<rect x=\""+pad.l+"\" y=\""+pad.t+"\" width=\""+iw+"\" height=\""+ih+"\" fill=\""+opts.bg+"\"/>";}');
    DBMS_OUTPUT.PUT_LINE('  if(opts.grid){var gl=opts.gridLines||3,g;for(g=1;g<=gl;g++){var gv=maxY*g/gl,gy=Y(gv);out+="<line x1=\""+pad.l+"\" y1=\""+gy.toFixed(1)+"\" x2=\""+(pad.l+iw)+"\" y2=\""+gy.toFixed(1)+"\" stroke=\"var(--line-soft)\" stroke-width=\"1\"/>";out+="<text x=\""+(pad.l-4)+"\" y=\""+(gy+3).toFixed(1)+"\" text-anchor=\"end\" font-size=\"9\" fill=\"var(--muted)\">"+(Math.round(gv*10)/10)+"</text>";}out+="<text x=\""+(pad.l-4)+"\" y=\""+(pad.t+8)+"\" text-anchor=\"end\" font-size=\"9\" fill=\"var(--muted)\">AAS</text>";}');
    DBMS_OUTPUT.PUT_LINE('  var bottom=[];for(i=0;i<n;i++)bottom[i]=0;');
    DBMS_OUTPUT.PUT_LINE('  for(s=0;s<series.length;s++){var top=[],pts=[];for(i=0;i<n;i++){var vv=series[s].vals[i];vv=(vv==null||isNaN(vv))?0:+vv;top[i]=bottom[i]+vv;}for(i=0;i<n;i++)pts.push(X(i).toFixed(1)+","+Y(top[i]).toFixed(2));for(i=n-1;i>=0;i--)pts.push(X(i).toFixed(1)+","+Y(bottom[i]).toFixed(2));out+="<polygon points=\""+pts.join(" ")+"\" fill=\""+(WC[series[s].cls]||"#888888")+"\" fill-opacity=\""+(opts.fillOpacity||0.92)+"\"/>";bottom=top;}');
    DBMS_OUTPUT.PUT_LINE('  if(opts.xLabels){xLabels(opts.t0).forEach(function(L){var lx=X(L[0]);out+="<line x1=\""+lx.toFixed(1)+"\" y1=\""+(pad.t+ih)+"\" x2=\""+lx.toFixed(1)+"\" y2=\""+(pad.t+ih+3)+"\" stroke=\"var(--muted)\" stroke-width=\"1\"/>";var anc=L[0]===0?"start":(L[0]===n-1?"end":"middle");out+="<text x=\""+lx.toFixed(1)+"\" y=\""+(pad.t+ih+13)+"\" text-anchor=\""+anc+"\" font-size=\"9\" fill=\"var(--muted)\">"+esc(L[1])+"</text>";});}');
    DBMS_OUTPUT.PUT_LINE('  if(opts.markers){markersFor(opts.t0).forEach(function(m){var mx=X(m.i);if(opts.ribbon){out+="<line x1=\""+mx.toFixed(1)+"\" y1=\""+pad.t+"\" x2=\""+mx.toFixed(1)+"\" y2=\""+(pad.t+ih)+"\" stroke=\""+m.color+"\" stroke-width=\"1\" stroke-opacity=\"0.85\"/>";out+="<path d=\"M"+(mx-2.5).toFixed(1)+","+pad.t+" L"+(mx+2.5).toFixed(1)+","+pad.t+" L"+mx.toFixed(1)+","+(pad.t+3.5)+" Z\" fill=\""+m.color+"\"/>";}else{out+="<line x1=\""+mx.toFixed(1)+"\" y1=\""+pad.t+"\" x2=\""+mx.toFixed(1)+"\" y2=\""+(pad.t+ih)+"\" stroke=\""+m.color+"\" stroke-width=\"1.2\" stroke-dasharray=\"3 2\" stroke-opacity=\"0.9\"/>";var tx=mx,anc2="middle";if(mx>w-70){anc2="end";tx=mx-3;}else if(mx<60){anc2="start";tx=mx+3;}out+="<text x=\""+tx.toFixed(1)+"\" y=\""+(pad.t+10)+"\" text-anchor=\""+anc2+"\" font-size=\"9.5\" font-weight=\"600\" fill=\""+m.color+"\">"+esc(m.label)+"</text>";}});}');
    DBMS_OUTPUT.PUT_LINE('  return out+"</svg>";');
    DBMS_OUTPUT.PUT_LINE('}');
    -- fill the timeline caption (nextElementSibling .tl-caption) with in-span markers
    DBMS_OUTPUT.PUT_LINE('function fillCaption(el,t0){var cap=el.nextElementSibling;if(!cap||String(cap.className).indexOf("tl-caption")<0)return;var mk=markersFor(t0);cap.innerHTML=mk.map(function(m){return "<span><span style=\"color:"+m.color+";font-weight:700\">|</span> "+esc(m.label)+"</span>";}).join("");}');
    DBMS_OUTPUT.PUT_LINE('function renderAsh(){var els=document.querySelectorAll("[data-ash-of]");Array.prototype.forEach.call(els,function(el){if(el.__ashed)return;var alias=el.getAttribute("data-ash-of"),mode=el.getAttribute("data-ash-mode")||"ribbon",d=(window.FLEET_ASH||{})[alias];if(!d||!d.classes||!d.classes.length){el.innerHTML="";el.__ashed=true;return;}if(mode==="ribbon"){el.innerHTML=buildStack(d.classes,d.vals,172,30,{ribbon:true,markers:true,t0:d.t0,pad:{t:4,r:2,b:2,l:2},fillOpacity:0.95});}else{el.innerHTML=buildStack(d.classes,d.vals,640,108,{grid:true,gridLines:3,xLabels:true,markers:true,t0:d.t0,bg:"var(--panel-2)",pad:{t:6,r:8,b:18,l:26},fillOpacity:0.9});fillCaption(el,d.t0);}el.__ashed=true;});}');
    -- delegated row expand/collapse: a click anywhere in a dbrow toggles its sibling detailrow
    DBMS_OUTPUT.PUT_LINE('function wireToggle(){document.addEventListener("click",function(ev){var tgt=ev.target;if(!tgt||!tgt.closest)return;var row=tgt.closest("tr.dbrow");if(!row)return;var det=row.nextElementSibling;if(!det||String(det.className).indexOf("detailrow")<0)return;var open=row.classList.toggle("open");if(open)det.classList.remove("hidden");else det.classList.add("hidden");});}');
    -- theme toggle: flip body.dark, persist localStorage "awr-theme"
    DBMS_OUTPUT.PUT_LINE('function wireTheme(){var b=document.getElementById("themeToggle");if(!b)return;b.setAttribute("aria-pressed",document.body.classList.contains("dark")?"true":"false");b.addEventListener("click",function(){var on=document.body.classList.toggle("dark");try{localStorage.setItem("awr-theme",on?"dark":"light");}catch(e){}b.setAttribute("aria-pressed",on?"true":"false");});}');
    DBMS_OUTPUT.PUT_LINE('function boot(){renderAsh();wireToggle();wireTheme();}');
    DBMS_OUTPUT.PUT_LINE('if(document.readyState==="loading")document.addEventListener("DOMContentLoaded",boot);else boot();');
    DBMS_OUTPUT.PUT_LINE('window.__fleetRenderAsh=renderAsh;');
    DBMS_OUTPUT.PUT_LINE('})();</script>');
END;
/
