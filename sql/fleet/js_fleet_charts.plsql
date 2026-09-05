--
-- sql/fleet/js_fleet_charts.plsql
--
-- The fleet report's inline-SVG chart + interaction layer (no ECharts, no
-- external anything).  @@-included once by sql/fleet/00_fleet_chrome.sql, so
-- it ships in the shared chrome copy every DB spools (the assembler keeps the
-- first).  On DOMContentLoaded it:
--   * renders every [data-ash-of] div -- a full-report-span ASH stacked-area
--     chart with an adaptive bucket width, either "ribbon" mode (172x30,
--     marker ticks, no labels; in the summary dbrow) or "timeline" mode
--     (container-width x 108, y-gridlines + AAS labels, x date/time labels,
--     dashed labeled marker lines; in the detailrow), positioning markers
--     from window.FLEET_MARKERS by timestamp.  The div's data-ash-src attr
--     selects the payload: absent/default -> window.FLEET_ASH (stacked by
--     wait CLASS, colored from the WC map, series reordered into WCO stacking
--     order), "ev" -> window.FLEET_ASH_EV (stacked by wait EVENT, payload
--     order preserved, colored from the EVP categorical palette with CPU=WC
--     green and "Other events"=EVOTHER grey, plus a per-series color legend
--     filled into the sibling .ev-legend div);
--   * renders every [data-profile-of] div -- the optional Day profile band:
--     a 24-column (hour of day) x N-row (stat) inline-SVG heatmap from
--     window.FLEET_PROFILE, cell fill = signed z-score (red above the
--     prior-day mean, blue below, alpha scaled by |z| up to 3.5; no-data
--     cells in var(--panel-2)), a <title> tooltip per cell and a legend of
--     swatches in the sibling .tl-caption.  Lazy like the timelines (needs
--     a real clientWidth) and re-rendered on resize;
--   * wires row expand/collapse (delegated click on tr.dbrow -> its sibling
--     tr.detailrow), re-rendering the newly revealed timeline once the row
--     opens so it picks up its real container width;
--   * wires the masthead theme toggle (flip body.dark, persist localStorage
--     "awr-theme" -- same key the early bootstrap + single-DB report use);
--   * wires a debounced window-resize handler that re-renders any open
--     timeline chart whose container width has changed;
--   * wires the masthead-adjacent #fleetToolbar (facelift F1): a text filter,
--     Score/Name/AAS/Errors-first sort pills, All/Crit/Warn+ show pills, and
--     Expand-all/Collapse-all -- all read straight from the already-rendered
--     DOM (score span text, .dot severity class, .aas cell, .alias text) so
--     no new payload or data-* plumbing is needed from the SQL sections.
--     Expand/collapse-all share setRowOpen with the delegated row-toggle
--     click handler, so the lazy chart render on first expand is single-
--     sourced;
--   * wires a delegated ".copy-btn" click handler (facelift F4) that copies
--     the text of the element named by its data-copy selector (the drill-
--     down command block) via navigator.clipboard, falling back to a hidden
--     textarea + document.execCommand("copy") where the Clipboard API is
--     unavailable, flipping the button's label to "Copied" for 1.2s.
--
-- Axis/label/gridline colors are emitted as var(--muted)/var(--line-soft)
-- CSS-var references inside the SVG, so they re-resolve automatically on a
-- theme flip -- no JS re-render needed.  The wait-class fill hexes ARE
-- theme-independent and copied from sql/lib/js_wait_colors.plsql; keep the
-- WC map below in lockstep with that file (do not edit the lib file).
--
-- Emitted as double-quoted JS (inner quotes backslash-escaped) so the SQL
-- single-quoted literals never need doubling, matching js_sparkline.plsql;
-- contains no apostrophes and no live substitution character (that
-- character is the substitution char in every fleet SQL file).
--
BEGIN
    DBMS_OUTPUT.PUT_LINE('<script>(function(){');
    DBMS_OUTPUT.PUT_LINE('"use strict";');
    -- wait-class palette -- LOCKSTEP with sql/lib/js_wait_colors.plsql
    DBMS_OUTPUT.PUT_LINE('var WC={"CPU":"#3FB344","Scheduler":"#88C070","User I/O":"#4A90D9","System I/O":"#1F4E89","Concurrency":"#8B0000","Application":"#D62728","Commit":"#E89B40","Configuration":"#793C32","Administrative":"#7B6FA8","Network":"#967259","Queueing":"#E89BB7","Cluster":"#E5C228","Other":"#C77CB0"};');
    DBMS_OUTPUT.PUT_LINE('var WCO=["CPU","Scheduler","User I/O","System I/O","Concurrency","Application","Commit","Configuration","Administrative","Network","Queueing","Cluster","Other"];');
    -- categorical palette for the by-event timeline (events have no fixed
    -- palette): 15 distinct hexes, no pure greens (green stays reserved for
    -- CPU) and no confusing overlap with the WC class hexes.  CPU keeps the WC
    -- green and "Other events" gets EVOTHER grey, both assigned explicitly.
    DBMS_OUTPUT.PUT_LINE('var EVP=["#1F77B4","#FF7F0E","#9467BD","#17BECF","#BCBD22","#E377C2","#8C564B","#AEC7E8","#FFBB78","#C5B0D5","#9EDAE5","#F7B6D2","#C49C94","#DBDB8D","#5254A3"];');
    DBMS_OUTPUT.PUT_LINE('var EVOTHER="#9AA3AD";');
    DBMS_OUTPUT.PUT_LINE('function esc(s){return String(s==null?"":s).replace(/[&<>]/g,function(c){return({"&":"&amp;","<":"&lt;",">":"&gt;"})[c];});}');
    DBMS_OUTPUT.PUT_LINE('function pad2(n){return (n<10?"0":"")+n;}');
    DBMS_OUTPUT.PUT_LINE('function parseTs(s){if(!s)return NaN;return Date.parse(String(s).replace(" ","T"));}');
    DBMS_OUTPUT.PUT_LINE('function markerColor(i){return (i%2===0)?"var(--accent)":"var(--warn)";}');
    DBMS_OUTPUT.PUT_LINE('function markersFor(t0,bh,n){var out=[],base=parseTs(t0);if(isNaN(base))return out;var M=window.FLEET_MARKERS||[];for(var k=0;k<M.length;k++){var t=parseTs(M[k].t);if(isNaN(t))continue;var i=(t-base)/(3600000*bh);if(i<0||i>n-1)continue;out.push({i:i,color:markerColor(k),label:M[k].l});}return out;}');
    DBMS_OUTPUT.PUT_LINE('function svgEl(w,h){return "<svg viewBox=\"0 0 "+w+" "+h+"\" width=\""+w+"\" height=\""+h+"\" preserveAspectRatio=\"none\" xmlns=\"http://www.w3.org/2000/svg\">";}');
    -- tick indices at 0/25/50/75/100% of the span, de-duplicated for short
    -- spans; label granularity depends on the total span (n*bh hours): a
    -- HH:MM clock for a <=48h span, an MM-DD HH:MM stamp for a longer one
    -- (an hour-only label would be ambiguous across days/weeks).
    DBMS_OUTPUT.PUT_LINE('function xLabels(t0,bh,n){var base=parseTs(t0);var idx=[0,Math.round((n-1)*0.25),Math.round((n-1)*0.5),Math.round((n-1)*0.75),n-1];var seen={},uniq=[];for(var k=0;k<idx.length;k++){if(!seen[idx[k]]){seen[idx[k]]=true;uniq.push(idx[k]);}}var span=n*bh,long=span>48;return uniq.map(function(i){if(isNaN(base))return [i,""];var d=new Date(base+i*bh*3600000);var hm=pad2(d.getHours())+":"+pad2(d.getMinutes());return [i,long?(pad2(d.getMonth()+1)+"-"+pad2(d.getDate())+" "+hm):hm];});}');
    -- order the per-class value arrays into WCO stacking order, extras appended
    DBMS_OUTPUT.PUT_LINE('function orderSeries(classes,vals){var by={},i;for(i=0;i<classes.length;i++)by[classes[i]]=vals[i];var ser=[];WCO.forEach(function(k){if(by[k]){ser.push({cls:k,vals:by[k]});delete by[k];}});for(var k in by){if(by.hasOwnProperty(k))ser.push({cls:k,vals:by[k]});}return ser;}');
    -- stacked ASH area chart (ribbon or timeline); n (bucket count) and bh
    -- (hours per bucket) are derived from the payload, not a fixed constant
    DBMS_OUTPUT.PUT_LINE('function buildStack(classes,vals,w,h,opts){');
    DBMS_OUTPUT.PUT_LINE('  opts=opts||{};var pad=opts.pad||{t:0,r:0,b:0,l:0};var bh=opts.bh||1;');
    DBMS_OUTPUT.PUT_LINE('  var iw=w-pad.l-pad.r,ih=h-pad.t-pad.b,series,n,i,s;');
    -- ev mode passes opts.keepOrder (payload order = stacking order) + opts.colors;
    -- class mode omits both, keeping the WCO reorder + WC-map fill bit-identical
    DBMS_OUTPUT.PUT_LINE('  if(opts.keepOrder){series=[];for(i=0;i<classes.length;i++)series.push({cls:classes[i],vals:vals[i]});}else{series=orderSeries(classes,vals);}');
    DBMS_OUTPUT.PUT_LINE('  n=series.length?series[0].vals.length:0;');
    DBMS_OUTPUT.PUT_LINE('  if(n<2)return svgEl(w,h)+"</svg>";');
    DBMS_OUTPUT.PUT_LINE('  var maxTotal=0;for(i=0;i<n;i++){var t=0;for(s=0;s<series.length;s++){var v=series[s].vals[i];t+=(v==null||isNaN(v))?0:+v;}if(t>maxTotal)maxTotal=t;}');
    DBMS_OUTPUT.PUT_LINE('  var maxY=opts.maxY||Math.max(maxTotal*1.08,0.5);');
    DBMS_OUTPUT.PUT_LINE('  function X(i){return pad.l+(n<=1?0:(i/(n-1))*iw);}');
    DBMS_OUTPUT.PUT_LINE('  function Y(v){return pad.t+ih-(v/maxY)*ih;}');
    DBMS_OUTPUT.PUT_LINE('  var out=svgEl(w,h);');
    DBMS_OUTPUT.PUT_LINE('  if(opts.bg){out+="<rect x=\""+pad.l+"\" y=\""+pad.t+"\" width=\""+iw+"\" height=\""+ih+"\" fill=\""+opts.bg+"\"/>";}');
    -- B3: the y-axis unit ("AAS") used to be drawn as a corner text label at
    -- (pad.l-4, pad.t+8), which overprinted the topmost gridline's own value
    -- label (e.g. "0.5") sitting almost the same spot. The unit now lives
    -- once in the band's caption line (sql/fleet/01_row.sql's panel-h
    -- already reads "... (AAS) ..."), so the corner label is dropped rather
    -- than repositioned -- nothing else needs to render there.
    DBMS_OUTPUT.PUT_LINE('  if(opts.grid){var gl=opts.gridLines||3,g;for(g=1;g<=gl;g++){var gv=maxY*g/gl,gy=Y(gv);out+="<line x1=\""+pad.l+"\" y1=\""+gy.toFixed(1)+"\" x2=\""+(pad.l+iw)+"\" y2=\""+gy.toFixed(1)+"\" stroke=\"var(--line-soft)\" stroke-width=\"1\"/>";out+="<text x=\""+(pad.l-4)+"\" y=\""+(gy+3).toFixed(1)+"\" text-anchor=\"end\" font-size=\"9\" fill=\"var(--muted)\">"+(Math.round(gv*10)/10)+"</text>";}}');
    DBMS_OUTPUT.PUT_LINE('  var bottom=[];for(i=0;i<n;i++)bottom[i]=0;');
    DBMS_OUTPUT.PUT_LINE('  for(s=0;s<series.length;s++){var top=[],pts=[];for(i=0;i<n;i++){var vv=series[s].vals[i];vv=(vv==null||isNaN(vv))?0:+vv;top[i]=bottom[i]+vv;}for(i=0;i<n;i++)pts.push(X(i).toFixed(1)+","+Y(top[i]).toFixed(2));for(i=n-1;i>=0;i--)pts.push(X(i).toFixed(1)+","+Y(bottom[i]).toFixed(2));out+="<polygon points=\""+pts.join(" ")+"\" fill=\""+(opts.colors?(opts.colors[s]||"#888888"):(WC[series[s].cls]||"#888888"))+"\" fill-opacity=\""+(opts.fillOpacity||0.92)+"\"/>";bottom=top;}');
    DBMS_OUTPUT.PUT_LINE('  if(opts.xLabels){xLabels(opts.t0,bh,n).forEach(function(L){var lx=X(L[0]);out+="<line x1=\""+lx.toFixed(1)+"\" y1=\""+(pad.t+ih)+"\" x2=\""+lx.toFixed(1)+"\" y2=\""+(pad.t+ih+3)+"\" stroke=\"var(--muted)\" stroke-width=\"1\"/>";var anc=L[0]===0?"start":(L[0]===n-1?"end":"middle");out+="<text x=\""+lx.toFixed(1)+"\" y=\""+(pad.t+ih+13)+"\" text-anchor=\""+anc+"\" font-size=\"9\" fill=\"var(--muted)\">"+esc(L[1])+"</text>";});}');
    -- F3: the ribbon (dbrow summary) draws markers as short 6px ticks at the
    -- top edge only -- a full-height line was too heavy for the compact
    -- 30px-tall ribbon and fought with the stacked-area fill. The expanded
    -- timeline (opts.ribbon falsy) is unchanged: full-height dashed lines
    -- with a label, since it has the vertical room and the marker is the
    -- primary way to correlate an event with the wider chart.
    DBMS_OUTPUT.PUT_LINE('  if(opts.markers){markersFor(opts.t0,bh,n).forEach(function(m){var mx=X(m.i);if(opts.ribbon){out+="<line x1=\""+mx.toFixed(1)+"\" y1=\""+pad.t+"\" x2=\""+mx.toFixed(1)+"\" y2=\""+(pad.t+6)+"\" stroke=\""+m.color+"\" stroke-width=\"2\" stroke-linecap=\"round\" stroke-opacity=\"0.95\"/>";}else{out+="<line x1=\""+mx.toFixed(1)+"\" y1=\""+pad.t+"\" x2=\""+mx.toFixed(1)+"\" y2=\""+(pad.t+ih)+"\" stroke=\""+m.color+"\" stroke-width=\"1.2\" stroke-dasharray=\"3 2\" stroke-opacity=\"0.9\"/>";var tx=mx,anc2="middle";if(mx>w-70){anc2="end";tx=mx-3;}else if(mx<60){anc2="start";tx=mx+3;}out+="<text x=\""+tx.toFixed(1)+"\" y=\""+(pad.t+10)+"\" text-anchor=\""+anc2+"\" font-size=\"9.5\" font-weight=\"600\" fill=\""+m.color+"\">"+esc(m.label)+"</text>";}});}');
    DBMS_OUTPUT.PUT_LINE('  return out+"</svg>";');
    DBMS_OUTPUT.PUT_LINE('}');
    -- fill the timeline caption (nextElementSibling .tl-caption) with a
    -- span-info blurb (start timestamp + bucket width) followed by in-span
    -- markers
    DBMS_OUTPUT.PUT_LINE('function fillCaption(el,d){var cap=el.nextElementSibling;if(!cap||String(cap.className).indexOf("tl-caption")<0)return;var bh=(+d.bh)||1;var n=(d.vals&&d.vals[0])?d.vals[0].length:0;var mk=markersFor(d.t0,bh,n);var bucketLabel=bh>=1?(Math.round(bh*10)/10)+"h":Math.round(bh*60)+"m";var items=["<span>"+esc(d.t0)+" to end of window, bucket "+bucketLabel+"</span>"];items=items.concat(mk.map(function(m){return "<span><span style=\"color:"+m.color+";font-weight:700\">|</span> "+esc(m.label)+"</span>";}));cap.innerHTML=items.join("");}');
    -- by-event colors: payload order preserved; CPU keeps WC green, "Other
    -- events" the fixed grey, every other event cycles EVP (j counts only the
    -- non-special series so the rotation is stable regardless of CPU/Other)
    DBMS_OUTPUT.PUT_LINE('function evColors(names){var out=[],j=0;for(var i=0;i<names.length;i++){var nm=names[i];if(nm==="CPU"){out.push(WC["CPU"]);}else if(nm==="Other events"){out.push(EVOTHER);}else{out.push(EVP[j%EVP.length]);j++;}}return out;}');
    -- fill the by-event legend (nextElementSibling .ev-legend), one chip per
    -- series in stack order, colors matching the drawn polygons
    DBMS_OUTPUT.PUT_LINE('function fillEvLegend(el,names,colors){var lg=el.nextElementSibling;if(!lg||String(lg.className).indexOf("ev-legend")<0)return;var h="";for(var i=0;i<names.length;i++){h+="<span class=\"ev-item\"><span class=\"ev-swatch\" style=\"background:"+colors[i]+"\"></span>"+esc(names[i])+"</span>";}lg.innerHTML=h;}');
    -- ribbon renders at a fixed size; timeline renders at the elements real
    -- container width (skipped, without marking __ashed, while the detail
    -- row is still display:none and clientWidth is 0 -- it renders once the
    -- row opens, via wireToggle below)
    DBMS_OUTPUT.PUT_LINE('function renderAsh(){var els=document.querySelectorAll("[data-ash-of]");Array.prototype.forEach.call(els,function(el){if(el.__ashed)return;var alias=el.getAttribute("data-ash-of"),mode=el.getAttribute("data-ash-mode")||"ribbon",src=el.getAttribute("data-ash-src"),store=src==="ev"?(window.FLEET_ASH_EV||{}):(window.FLEET_ASH||{}),d=store[alias];if(!d||!d.classes||!d.classes.length){el.innerHTML="";el.__ashed=true;return;}var bh=(+d.bh)||1;if(mode==="ribbon"){el.innerHTML=buildStack(d.classes,d.vals,172,30,{ribbon:true,markers:true,t0:d.t0,bh:bh,pad:{t:4,r:2,b:2,l:2},fillOpacity:0.95});el.__ashed=true;}else{var w=el.clientWidth;if(!w)return;w=Math.max(480,w);if(src==="ev"){var colors=evColors(d.classes);el.innerHTML=buildStack(d.classes,d.vals,w,108,{grid:true,gridLines:3,xLabels:true,markers:true,t0:d.t0,bh:bh,bg:"var(--panel-2)",pad:{t:6,r:8,b:18,l:26},fillOpacity:0.9,keepOrder:true,colors:colors});fillEvLegend(el,d.classes,colors);}else{el.innerHTML=buildStack(d.classes,d.vals,w,108,{grid:true,gridLines:3,xLabels:true,markers:true,t0:d.t0,bh:bh,bg:"var(--panel-2)",pad:{t:6,r:8,b:18,l:26},fillOpacity:0.9});fillCaption(el,d);}el.__ashW=w;el.__ashed=true;}});}');
    -- delegated row expand/collapse: a click anywhere in a dbrow toggles its
    -- sibling detailrow; opening re-runs renderAsh so its timeline (skipped
    -- while hidden, above) picks up its real width
    -- day-profile heatmap: hours across, stats down; fill alpha from |z|
    DBMS_OUTPUT.PUT_LINE('function profFill(z){if(z==null||isNaN(+z))return "var(--panel-2)";var a=Math.min(1,Math.abs(+z)/3.5);a=(0.10+0.90*a).toFixed(2);return (+z>=0?"rgba(176,28,28,":"rgba(37,99,235,")+a+")";}');
    DBMS_OUTPUT.PUT_LINE('function fmtN(v){if(v==null)return "-";v=+v;if(isNaN(v))return "-";return Math.abs(v)>=100?Math.round(v).toLocaleString():v.toFixed(2);}');
    DBMS_OUTPUT.PUT_LINE('function fillProfLegend(el,d){var cap=el.nextElementSibling;if(!cap||String(cap.className).indexOf("tl-caption")<0)return;var sw=function(z,l){return "<span><span class=\"dp-sw\" style=\"background:"+profFill(z)+"\"></span>"+l+"</span>";};cap.innerHTML=sw(3.5,"z \u2265 +3 (large)")+sw(2.5,"+2 to +3 (moderate)")+sw(0.5,"typical")+sw(-2.5,"\u22122 to \u22123")+sw(-3.5,"z \u2264 \u22123")+sw(null,"no data")+"<span>"+d.ndays+" prior day(s); hover a cell for values</span>";}');
    DBMS_OUTPUT.PUT_LINE('function buildProfile(d,w){var L=150,T=14,n=d.stats.length,cw=(w-L-4)/24,ch=16,H=T+ch*n+2,s=svgEl(w,H);for(var j=0;j<24;j+=3){s+="<text x=\""+(L+j*cw+1).toFixed(1)+"\" y=\""+(T-4)+"\" font-size=\"9\" fill=\"var(--muted)\">"+esc(d.hours[j])+"</text>";}for(var i=0;i<n;i++){var y=T+i*ch;s+="<text x=\""+(L-6)+"\" y=\""+(y+ch*0.72).toFixed(1)+"\" font-size=\"10\" text-anchor=\"end\" fill=\"var(--muted)\">"+esc(d.stats[i])+"</text>";for(var k=0;k<24;k++){var z=d.z[i][k],tip=esc(d.stats[i])+" @ "+esc(d.hours[k])+": current "+fmtN(d.cur[i][k])+" | prior mean "+fmtN(d.mu[i][k])+" (n="+d.n[i][k]+") | z "+(z==null?"-":(+z).toFixed(2))+" | "+(d.pct[i][k]==null?"-":d.pct[i][k]+"%")+" | "+esc(d.sev[i][k]);s+="<rect x=\""+(L+k*cw).toFixed(1)+"\" y=\""+y+"\" width=\""+Math.max(1,cw-1).toFixed(1)+"\" height=\""+(ch-1)+"\" rx=\"2\" fill=\""+profFill(z)+"\"><title>"+tip+"</title></rect>";}}return s+"</svg>";}');
    DBMS_OUTPUT.PUT_LINE('function renderProfile(){var els=document.querySelectorAll("[data-profile-of]");Array.prototype.forEach.call(els,function(el){if(el.__profiled)return;var d=(window.FLEET_PROFILE||{})[el.getAttribute("data-profile-of")];if(!d||!d.stats||!d.stats.length||!d.z){el.innerHTML="";el.__profiled=true;return;}var w=el.clientWidth;if(!w)return;w=Math.max(480,w);el.innerHTML=buildProfile(d,w);fillProfLegend(el,d);el.__profW=w;el.__profiled=true;});}');
    -- setRowOpen is the single code path for opening/closing a detailrow --
    -- the delegated click handler AND the F1 toolbar's Expand/Collapse-all
    -- buttons both call it, so the lazy first-render of a row's charts
    -- (renderAsh/renderProfile, needed once a hidden container gets a real
    -- clientWidth) only ever lives in one place.
    DBMS_OUTPUT.PUT_LINE('function setRowOpen(row,open){var det=row.nextElementSibling;if(!det||String(det.className).indexOf("detailrow")<0)return;var isOpen=row.classList.contains("open");if(open===isOpen)return;if(open){row.classList.add("open");det.classList.remove("hidden");renderAsh();renderProfile();}else{row.classList.remove("open");det.classList.add("hidden");}}');
    DBMS_OUTPUT.PUT_LINE('function wireToggle(){document.addEventListener("click",function(ev){var tgt=ev.target;if(!tgt||!tgt.closest)return;var row=tgt.closest("tr.dbrow");if(!row)return;setRowOpen(row,!row.classList.contains("open"));});}');
    -- theme toggle: flip body.dark, persist localStorage "awr-theme"
    DBMS_OUTPUT.PUT_LINE('function wireTheme(){var b=document.getElementById("themeToggle");if(!b)return;b.setAttribute("aria-pressed",document.body.classList.contains("dark")?"true":"false");b.addEventListener("click",function(){var on=document.body.classList.toggle("dark");try{localStorage.setItem("awr-theme",on?"dark":"light");}catch(e){}b.setAttribute("aria-pressed",on?"true":"false");});}');
    -- debounced resize: re-render any open (visible, clientWidth>0) timeline
    -- whose container width actually changed, so the SVG tracks a resized
    -- viewport/panel instead of staying stretched from its first render
    DBMS_OUTPUT.PUT_LINE('function wireResize(){var tmr=null;window.addEventListener("resize",function(){if(tmr)clearTimeout(tmr);tmr=setTimeout(function(){var changed=false;var els=document.querySelectorAll("[data-ash-of][data-ash-mode=\"timeline\"]");Array.prototype.forEach.call(els,function(el){var w=el.clientWidth;if(w>0&&w!==el.__ashW){el.__ashed=false;changed=true;}});if(changed)renderAsh();var pc=false;var pe=document.querySelectorAll("[data-profile-of]");Array.prototype.forEach.call(pe,function(el){var w=el.clientWidth;if(w>0&&w!==el.__profW){el.__profiled=false;pc=true;}});if(pc)renderProfile();},150);});}');
    -- F1 toolbar: filter/sort/show/expand-collapse, all client-side over the
    -- existing tr.dbrow/tr.detailrow pairs -- no payload or markup changes.
    -- Reads every value straight out of the already-rendered DOM (the score
    -- span's text, the .dot's severity class, the .aas cell, the .alias
    -- text) rather than adding new data-* plumbing through the SQL sections.
    DBMS_OUTPUT.PUT_LINE('function wireToolbar(){var tb=document.getElementById("fleetToolbar");if(!tb)return;var tbody=document.querySelector("table.fleet tbody");if(!tbody)return;');
    DBMS_OUTPUT.PUT_LINE('  var pairs=[];Array.prototype.forEach.call(tbody.querySelectorAll("tr.dbrow"),function(tr,i){var det=tr.nextElementSibling;if(!det||String(det.className).indexOf("detailrow")<0)det=null;tr.setAttribute("data-orig-idx",i);pairs.push({row:tr,det:det});});');
    DBMS_OUTPUT.PUT_LINE('  var state={q:"",sort:"score",show:"all"};');
    DBMS_OUTPUT.PUT_LINE('  function numOf(sel,row){var el=row.querySelector(sel);if(!el)return NaN;var v=parseFloat(el.textContent);return v;}');
    DBMS_OUTPUT.PUT_LINE('  function sevOf(row){var dot=row.querySelector(".dot");if(!dot)return "";return String(dot.className).replace("dot","").replace(/\\s+/g,"");}');
    DBMS_OUTPUT.PUT_LINE('  function nameOf(row){var el=row.querySelector(".alias");return el?el.textContent.toLowerCase():"";}');
    DBMS_OUTPUT.PUT_LINE('  function apply(){var q=state.q.trim().toLowerCase();pairs.forEach(function(p){var show=true;if(q&&nameOf(p.row).indexOf(q)<0)show=false;if(show&&state.show!=="all"){var sev=sevOf(p.row);if(state.show==="crit"){show=(sev==="crit"||sev==="dead");}else if(state.show==="warn"){show=(sev==="crit"||sev==="warn"||sev==="dead");}}p.row.hidden=!show;if(p.det)p.det.hidden=!show;});}');
    -- comparators: "errors" == original assembled order (unreachable rows
    -- first, then OK rows score-desc) since that IS the DOM order captured
    -- into data-orig-idx above; the other three are pure single-field sorts.
    DBMS_OUTPUT.PUT_LINE('  function cmpScore(a,b){var sa=numOf(".score",a.row),sb=numOf(".score",b.row);if(isNaN(sa))sa=-1;if(isNaN(sb))sb=-1;return sb-sa;}');
    DBMS_OUTPUT.PUT_LINE('  function cmpName(a,b){var na=nameOf(a.row),nb=nameOf(b.row);return na<nb?-1:(na>nb?1:0);}');
    DBMS_OUTPUT.PUT_LINE('  function cmpAas(a,b){var sa=numOf(".aas",a.row),sb=numOf(".aas",b.row);if(isNaN(sa))sa=-1;if(isNaN(sb))sb=-1;return sb-sa;}');
    DBMS_OUTPUT.PUT_LINE('  function cmpErrors(a,b){return (+a.row.getAttribute("data-orig-idx"))-(+b.row.getAttribute("data-orig-idx"));}');
    DBMS_OUTPUT.PUT_LINE('  function sortRows(){var cmp=state.sort==="name"?cmpName:state.sort==="aas"?cmpAas:state.sort==="errors"?cmpErrors:cmpScore;var ordered=pairs.slice().sort(cmp);ordered.forEach(function(p){tbody.appendChild(p.row);if(p.det)tbody.appendChild(p.det);});}');
    DBMS_OUTPUT.PUT_LINE('  var inp=tb.querySelector("#dbFilter");if(inp)inp.addEventListener("input",function(){state.q=inp.value;apply();});');
    DBMS_OUTPUT.PUT_LINE('  Array.prototype.forEach.call(tb.querySelectorAll("[data-sort]"),function(btn){btn.addEventListener("click",function(){state.sort=btn.getAttribute("data-sort");Array.prototype.forEach.call(tb.querySelectorAll("[data-sort]"),function(b){b.classList.toggle("active",b===btn);});sortRows();});});');
    DBMS_OUTPUT.PUT_LINE('  Array.prototype.forEach.call(tb.querySelectorAll("[data-show]"),function(btn){btn.addEventListener("click",function(){state.show=btn.getAttribute("data-show");Array.prototype.forEach.call(tb.querySelectorAll("[data-show]"),function(b){b.classList.toggle("active",b===btn);});apply();});});');
    DBMS_OUTPUT.PUT_LINE('  var ea=tb.querySelector("#expandAll"),ca=tb.querySelector("#collapseAll");if(ea)ea.addEventListener("click",function(){pairs.forEach(function(p){setRowOpen(p.row,true);});});if(ca)ca.addEventListener("click",function(){pairs.forEach(function(p){setRowOpen(p.row,false);});});');
    DBMS_OUTPUT.PUT_LINE('}');
    -- F4 copy-to-clipboard for the drill-down command block: one delegated
    -- click handler for every ".copy-btn" (data-copy holds a CSS selector
    -- for the text to copy), navigator.clipboard with a textarea fallback
    -- for browsers/contexts without it (e.g. non-HTTPS file:// preview).
    DBMS_OUTPUT.PUT_LINE('function fallbackCopy(text){try{var ta=document.createElement("textarea");ta.value=text;ta.style.position="fixed";ta.style.opacity="0";document.body.appendChild(ta);ta.focus();ta.select();document.execCommand("copy");document.body.removeChild(ta);}catch(e){}}');
    DBMS_OUTPUT.PUT_LINE('function wireCopy(){document.addEventListener("click",function(ev){var btn=ev.target&&ev.target.closest?ev.target.closest(".copy-btn"):null;if(!btn)return;ev.stopPropagation();var sel=btn.getAttribute("data-copy");var el=sel?document.querySelector(sel):null;var text=el?(el.innerText||el.textContent||""):"";function done(){var orig=btn.textContent;btn.textContent="Copied";btn.classList.add("copied");setTimeout(function(){btn.textContent=orig;btn.classList.remove("copied");},1200);}if(navigator.clipboard&&navigator.clipboard.writeText){navigator.clipboard.writeText(text).then(done,function(){fallbackCopy(text);done();});}else{fallbackCopy(text);done();}});}');
    DBMS_OUTPUT.PUT_LINE('function boot(){renderAsh();renderProfile();wireToggle();wireTheme();wireResize();wireToolbar();wireCopy();}');
    DBMS_OUTPUT.PUT_LINE('if(document.readyState==="loading")document.addEventListener("DOMContentLoaded",boot);else boot();');
    DBMS_OUTPUT.PUT_LINE('window.__fleetRenderAsh=renderAsh;');
    DBMS_OUTPUT.PUT_LINE('window.__fleetRenderProfile=renderProfile;');
    DBMS_OUTPUT.PUT_LINE('})();</script>');
END;
/
