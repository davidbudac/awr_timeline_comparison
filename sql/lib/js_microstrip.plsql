--
-- sql/lib/js_microstrip.plsql
--
-- The Trend cell of the single-DB per-window tables (v1.6.0, Mock D's
-- "13-bar micro strip", which replaced the line sparkline): every
-- <td class="trend" data-spark="v,v,v" data-spark-title="name"> becomes a
-- small inline SVG -- one grey bar per compared window from zero, oldest
-- left, the Current window last (wider, in the accent), and the prior
-- normal zone (mean +- 2 sigma of the prior values in the CSV, sigma
-- floored at 2% of the mean like the band glyph) shaded behind the bars.
-- The cell title lists the last four windows and the normal range.
-- Emitters and their positional CSV are unchanged (LISTAGG ORDER BY
-- week_offset DESC, one slot per window, '' = no value, Current last);
-- the mean and sd come from the CSV's own prior slots, which hold exactly
-- the valid prior windows the band cells score against.
-- CDN-free and dependency-free, so trends render with ECharts blocked;
-- with JS off the cell stays empty (the numbers sit right next to it).
--
-- Replaces sql/lib/js_sparkline.plsql in the single-DB driver only; the
-- fleet report keeps js_sparkline (its row / headline sparklines).
-- Exposes window.AWR_microStrip(csv, title) -> {svg, title} and
-- window.__awrRenderSparks() (rescan, same name as js_sparkline's).
--
-- No literal tilde below (SET DEFINE tilde).  GENERATED: the body below
-- (BEGIN .. END) is written by tools/js2plsql.sh from the readable source
-- sql/lib/src/js_microstrip.js -- edit the .js, then run tools/js2plsql.sh
-- (lint check 24 fails on a stale body).  This header is kept as is.
--
BEGIN
    DBMS_OUTPUT.PUT_LINE('<script>');
    DBMS_OUTPUT.PUT_LINE('(function(){');
    DBMS_OUTPUT.PUT_LINE('var doc=document;');
    DBMS_OUTPUT.PUT_LINE('function num(s){s=String(s==null?"":s).trim();if(s===""||s==="null")return null;var v=+s;return isNaN(v)?null:v;}');
    DBMS_OUTPUT.PUT_LINE('/* client twin of sql/lib/fmt_num.plsql: about 4 significant digits, k / M / G */');
    DBMS_OUTPUT.PUT_LINE('function grp(n){return String(n).replace(/\B(?=(\d{3})+(?!\d))/g,",");}');
    DBMS_OUTPUT.PUT_LINE('function fmt(p){');
    DBMS_OUTPUT.PUT_LINE('  if(p==null)return "\u2014";if(p===0)return "0";');
    DBMS_OUTPUT.PUT_LINE('  var a=Math.abs(p),s=p<0?"-":"",u="",v=a,t;');
    DBMS_OUTPUT.PUT_LINE('  if(a>=1e9){v=a/1e9;u=" G";}else if(a>=1e6){v=a/1e6;u=" M";}else if(a>=1e4){v=a/1e3;u=" k";}');
    DBMS_OUTPUT.PUT_LINE('  if(v>=1000)t=grp(Math.round(v));else if(v>=100)t=grp(v.toFixed(1));else if(v>=10)t=v.toFixed(2);else if(v>=1)t=v.toFixed(3);');
    DBMS_OUTPUT.PUT_LINE('  else{var d=Math.min(6,3-Math.floor(Math.log10(v)));if(Math.round(v*1e6)===0)return s+"<0.000001";t=String(+v.toFixed(d));}');
    DBMS_OUTPUT.PUT_LINE('  return s+t+u;');
    DBMS_OUTPUT.PUT_LINE('}');
    DBMS_OUTPUT.PUT_LINE('/* the column label of the k-th window, oldest first (window.AWR_WIN from sql/00_params.sql) */');
    DBMS_OUTPUT.PUT_LINE('function wlab(k,n){');
    DBMS_OUTPUT.PUT_LINE('  var W=window.AWR_WIN;');
    DBMS_OUTPUT.PUT_LINE('  if(W&&W.w&&W.w.length===n&&W.w[k])return k===n-1?"Current":W.w[k].d;');
    DBMS_OUTPUT.PUT_LINE('  return k===n-1?"Current":"\u2212"+(n-1-k);');
    DBMS_OUTPUT.PUT_LINE('}');
    DBMS_OUTPUT.PUT_LINE('/* one 13-bar micro strip: every window as a grey bar from zero, Current last,');
    DBMS_OUTPUT.PUT_LINE('   wider and in the accent; the prior normal zone (mean +- 2 sigma, sigma');
    DBMS_OUTPUT.PUT_LINE('   floored at 2% of the mean like the band) shaded behind the bars */');
    DBMS_OUTPUT.PUT_LINE('function strip(raw,title){');
    DBMS_OUTPUT.PUT_LINE('  var v=String(raw||"").split(",").map(num), n=v.length;');
    DBMS_OUTPUT.PUT_LINE('  var W=92,H=22,gap=n>20?1:2,cw=(W-gap*n)/(n+0.6);');
    DBMS_OUTPUT.PUT_LINE('  if(!n||cw<=0)return "";');
    DBMS_OUTPUT.PUT_LINE('  var pr=v.slice(0,n-1).filter(function(x){return x!=null;}), mu=null, sd=null, lo=null, hi=null;');
    DBMS_OUTPUT.PUT_LINE('  if(pr.length){');
    DBMS_OUTPUT.PUT_LINE('    mu=pr.reduce(function(a,b){return a+b;},0)/pr.length;');
    DBMS_OUTPUT.PUT_LINE('    sd=pr.length>1?Math.sqrt(pr.reduce(function(a,b){return a+(b-mu)*(b-mu);},0)/(pr.length-1)):0;');
    DBMS_OUTPUT.PUT_LINE('    var den=Math.max(sd,Math.abs(mu)*0.02);');
    DBMS_OUTPUT.PUT_LINE('    lo=Math.max(0,mu-2*den); hi=mu+2*den;');
    DBMS_OUTPUT.PUT_LINE('  }');
    DBMS_OUTPUT.PUT_LINE('  var have=v.filter(function(x){return x!=null;}).map(function(x){return Math.max(0,x);});');
    DBMS_OUTPUT.PUT_LINE('  var max=Math.max.apply(null,have.concat(hi!=null?[hi]:[0]))||1;');
    DBMS_OUTPUT.PUT_LINE('  function Y(x){return H-1-(H-3)*Math.max(0,x)/max;}');
    DBMS_OUTPUT.PUT_LINE('  var s="<svg class=\"mw\" width=\""+W+"\" height=\""+H+"\" viewBox=\"0 0 "+W+" "+H+"\" aria-hidden=\"true\">";');
    DBMS_OUTPUT.PUT_LINE('  if(hi!=null)s+="<rect class=\"z2\" x=\"0\" y=\""+Y(hi).toFixed(1)+"\" width=\""+W+"\" height=\""+Math.max(1,Y(lo)-Y(hi)).toFixed(1)+"\" rx=\"1\"/>";');
    DBMS_OUTPUT.PUT_LINE('  var x=0;');
    DBMS_OUTPUT.PUT_LINE('  v.forEach(function(val,k){');
    DBMS_OUTPUT.PUT_LINE('    var cur=k===n-1, w=cur?cw*1.6:cw;');
    DBMS_OUTPUT.PUT_LINE('    if(val!=null){var y=Y(val);s+="<rect class=\"b"+(cur?" cur":"")+"\" x=\""+x.toFixed(1)+"\" y=\""+y.toFixed(1)+"\" width=\""+w.toFixed(1)+"\" height=\""+Math.max(1,H-1-y).toFixed(1)+"\" rx=\"1\"/>";}');
    DBMS_OUTPUT.PUT_LINE('    x+=w+gap;');
    DBMS_OUTPUT.PUT_LINE('  });');
    DBMS_OUTPUT.PUT_LINE('  s+="</svg>";');
    DBMS_OUTPUT.PUT_LINE('  var tip=[];');
    DBMS_OUTPUT.PUT_LINE('  for(var k=Math.max(0,n-4);k<n;k++)tip.push(wlab(k,n)+" "+fmt(v[k]));');
    DBMS_OUTPUT.PUT_LINE('  return {svg:s,title:(title?title+": ":"")+tip.join(", ")+(mu!=null?"; normal "+fmt(lo)+"\u2013"+fmt(hi):"")};');
    DBMS_OUTPUT.PUT_LINE('}');
    DBMS_OUTPUT.PUT_LINE('window.AWR_microStrip=strip;');
    DBMS_OUTPUT.PUT_LINE('function render(){');
    DBMS_OUTPUT.PUT_LINE('  doc.querySelectorAll("[data-spark]").forEach(function(el){');
    DBMS_OUTPUT.PUT_LINE('    if(el.__sparked)return;');
    DBMS_OUTPUT.PUT_LINE('    var r=strip(el.getAttribute("data-spark"),el.getAttribute("data-spark-title")||"");');
    DBMS_OUTPUT.PUT_LINE('    el.__sparked=true;');
    DBMS_OUTPUT.PUT_LINE('    if(!r)return;');
    DBMS_OUTPUT.PUT_LINE('    el.innerHTML=r.svg; el.title=r.title;');
    DBMS_OUTPUT.PUT_LINE('  });');
    DBMS_OUTPUT.PUT_LINE('}');
    DBMS_OUTPUT.PUT_LINE('if(doc.readyState==="loading")doc.addEventListener("DOMContentLoaded",render);else render();');
    DBMS_OUTPUT.PUT_LINE('window.__awrRenderSparks=render;');
    DBMS_OUTPUT.PUT_LINE('})();');
    DBMS_OUTPUT.PUT_LINE('</script>');
END;
/
