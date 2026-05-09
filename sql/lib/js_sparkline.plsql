--
-- sql/lib/js_sparkline.plsql
--
-- Tiny dependency-free sparkline renderer. Each numeric table that needs
-- an inline trend column emits <td class="trend" data-spark="v,v,v"></td>;
-- this script swaps the attribute for a viewBox-scaled SVG path. No
-- charting library needed, so trends render even if the ECharts CDN is
-- blocked. Cell stays empty (but the numbers are right next to it) if
-- JS itself is disabled.
--
-- Flatness guard: if the relative swing vs. the mean magnitude is below
-- 2%, autoscaling would turn imperceptible noise into a dramatic zigzag.
-- Collapse to a flat midline in that case so the eye reads "steady".
--
-- Exposes:
--   window.__awrSpark(csv, klass, title)  -> SVG markup string
--   window.__awrRenderSparks()            -> rescan the DOM (used by
--                                            sections that render
--                                            sparklines after DOMReady,
--                                            e.g. 06_top_sql detail tables)
--
BEGIN
    DBMS_OUTPUT.PUT_LINE('<script>(function(){');
    DBMS_OUTPUT.PUT_LINE('function esc(s){return String(s).replace(/[&<>]/g,function(c){return({"&":"&amp;","<":"&lt;",">":"&gt;"})[c];});}');
    DBMS_OUTPUT.PUT_LINE('function spark(raw, klass, title){');
    DBMS_OUTPUT.PUT_LINE('  var W=110,H=24,PAD=2;');
    DBMS_OUTPUT.PUT_LINE('  var arr=String(raw||"").split(",").map(function(s){s=s.trim();return s===""?null:+s;});');
    DBMS_OUTPUT.PUT_LINE('  var vs=arr.filter(function(v){return v!=null&&!isNaN(v);});');
    DBMS_OUTPUT.PUT_LINE('  if(vs.length===0)return "<svg class=\""+klass+"\" viewBox=\"0 0 "+W+" "+H+"\"></svg>";');
    DBMS_OUTPUT.PUT_LINE('  var mn=Math.min.apply(null,vs), mx=Math.max.apply(null,vs);');
    DBMS_OUTPUT.PUT_LINE('  var sum=0; vs.forEach(function(v){sum+=v;}); var mean=sum/vs.length;');
    DBMS_OUTPUT.PUT_LINE('  var flat=(mx===mn)||(Math.abs(mean)>0 && (mx-mn)/Math.abs(mean)<0.02)||(mean===0 && mx-mn<1e-9);');
    DBMS_OUTPUT.PUT_LINE('  var rng=flat?1:(mx-mn);');
    DBMS_OUTPUT.PUT_LINE('  var step=(W-2*PAD)/Math.max(arr.length-1,1);');
    DBMS_OUTPUT.PUT_LINE('  var pts=[];');
    DBMS_OUTPUT.PUT_LINE('  arr.forEach(function(v,i){if(v==null||isNaN(v))return;var y=flat?(H/2):(H-PAD-(v-mn)/rng*(H-2*PAD));pts.push({x:PAD+i*step,y:y});});');
    DBMS_OUTPUT.PUT_LINE('  if(pts.length===0)return "<svg class=\""+klass+"\" viewBox=\"0 0 "+W+" "+H+"\"></svg>";');
    DBMS_OUTPUT.PUT_LINE('  var line=pts.map(function(p){return p.x.toFixed(1)+","+p.y.toFixed(1);}).join(" L ");');
    DBMS_OUTPUT.PUT_LINE('  var fx=pts[0].x.toFixed(1), last=pts[pts.length-1];');
    DBMS_OUTPUT.PUT_LINE('  var out="<svg class=\""+klass+"\" viewBox=\"0 0 "+W+" "+H+"\""+(title?" aria-label=\""+esc(title)+"\"":"")+">";');
    DBMS_OUTPUT.PUT_LINE('  if(title) out+="<title>"+esc(title)+"</title>";');
    DBMS_OUTPUT.PUT_LINE('  if(pts.length>=2){out+="<path class=\"fill\" d=\"M "+fx+","+(H-PAD)+" L "+line+" L "+last.x.toFixed(1)+","+(H-PAD)+" Z\"/>";}');
    DBMS_OUTPUT.PUT_LINE('  out+="<path class=\"line\" d=\"M "+line+"\"/>";');
    DBMS_OUTPUT.PUT_LINE('  out+="<circle class=\"dot\" cx=\""+last.x.toFixed(1)+"\" cy=\""+last.y.toFixed(1)+"\" r=\"2.5\"/>";');
    DBMS_OUTPUT.PUT_LINE('  return out+"</svg>";');
    DBMS_OUTPUT.PUT_LINE('}');
    DBMS_OUTPUT.PUT_LINE('window.__awrSpark=spark;');
    DBMS_OUTPUT.PUT_LINE('function render(){document.querySelectorAll("[data-spark]").forEach(function(el){');
    DBMS_OUTPUT.PUT_LINE('  if(el.__sparked) return;');
    DBMS_OUTPUT.PUT_LINE('  el.innerHTML=spark(el.getAttribute("data-spark"), el.getAttribute("data-spark-cls")||"spark", el.getAttribute("data-spark-title")||"");');
    DBMS_OUTPUT.PUT_LINE('  el.__sparked=true;});}');
    DBMS_OUTPUT.PUT_LINE('if(document.readyState==="loading") document.addEventListener("DOMContentLoaded",render); else render();');
    DBMS_OUTPUT.PUT_LINE('window.__awrRenderSparks=render;');
    DBMS_OUTPUT.PUT_LINE('})();</script>');
END;
/
