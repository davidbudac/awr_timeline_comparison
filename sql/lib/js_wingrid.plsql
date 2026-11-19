--
-- sql/lib/js_wingrid.plsql
--
-- Client half of the window component (sql/lib/wingrid.plsql markup, the
-- ".wg" CSS in sql/_style.sql) and of the Summary view's entity links.
-- Emitted once by the driver prologue (after js_markers.plsql); pure
-- inline JS, CDN-free, so it works offline and with ECharts blocked.
--
-- Exposes window.AWR_WG:
--   markers()     AWR_MARKERS mapped onto the compared windows (reads
--                 window.AWR_WIN, emitted by 00_params.sql): one entry per
--                 marker that falls inside the compared span,
--                 {o: week_offset of the column whose LEFT edge it sits on,
--                  after: the offset before it, l: label, s: short label,
--                  t: "Tue 8 Sep", at: "YYYY-MM-DD HH:MI"}
--   markerAt(o)   the marker on window o's left boundary (or null)
--   sizeRow(row)  draw one .r.bars row from data-v / data-mu / data-sd /
--                 data-sev (bars, normal zone, mean line, severity dot)
--   render(scope) size every bars row, mark the marker columns and lay out
--                 the flags of every [data-wg] under scope
--   fit(wg) / refit()   re-measure (tight labels, flag layout) after a
--                 layout change; run on resize, awr:view and details toggle
--   patterns(vals, valid, mu, sd, marks)   pattern tags of one row (pure;
--                 plan 027), patternText(tag, dates) their words, PAT the
--                 thresholds; tagCards() fills the finding cards' .fc-tags
--                 (and #triage .tri-tags) on DOMContentLoaded
-- Also, at DOMContentLoaded: every a.ent whose target id is missing is
-- unwrapped to plain text (only link to rows that are emitted); every
-- [data-mk-at="o"] slot gets the marker on that boundary; a.jump[data-tl]
-- ("Timeline ->" on the finding cards) goes to the row id in data-tl when
-- the Timeline emits one, else follows its href.
-- No literal tilde below (SET DEFINE tilde).  GENERATED: the body below
-- (BEGIN .. END) is written by tools/js2plsql.sh from the readable source
-- sql/lib/src/js_wingrid.js -- edit the .js, then run tools/js2plsql.sh
-- (lint check 24 fails on a stale body).  This header is kept as is.
--
BEGIN
    DBMS_OUTPUT.PUT_LINE('<script>');
    DBMS_OUTPUT.PUT_LINE('(function(){');
    DBMS_OUTPUT.PUT_LINE('var W=window.AWR_WG={}, doc=document;');
    DBMS_OUTPUT.PUT_LINE('if(doc.body)doc.body.classList.add("js-wg");');
    DBMS_OUTPUT.PUT_LINE('function $$(s,r){return Array.prototype.slice.call((r||doc).querySelectorAll(s));}');
    DBMS_OUTPUT.PUT_LINE('function shown(el){return !!el&&el.getClientRects().length>0;}');
    DBMS_OUTPUT.PUT_LINE('function mk(t,c,p){var e=doc.createElement(t);if(c)e.className=c;if(p)p.appendChild(e);return e;}');
    DBMS_OUTPUT.PUT_LINE('function cssNum(el,n,d){var v=parseFloat(getComputedStyle(el).getPropertyValue(n));return isNaN(v)?d:v;}');
    DBMS_OUTPUT.PUT_LINE('function num(s){if(s==null||s==="")return null;var v=+s;return isNaN(v)?null:v;}');
    DBMS_OUTPUT.PUT_LINE('function nums(s){return String(s||"").split(",").map(num);}');
    DBMS_OUTPUT.PUT_LINE('var MON=["Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"],DOW=["Sun","Mon","Tue","Wed","Thu","Fri","Sat"];');
    DBMS_OUTPUT.PUT_LINE('function dayTxt(t){var d=new Date(String(t).replace(" ","T"));if(isNaN(d.getTime()))return String(t);return DOW[d.getDay()]+" "+d.getDate()+" "+MON[d.getMonth()];}');
    DBMS_OUTPUT.PUT_LINE('/* a short flag label: "Release 4.2" -> "R 4.2", "RU 19.28 patch" -> "RU 19.28" */');
    DBMS_OUTPUT.PUT_LINE('function shortLbl(l){var w=String(l).split(/\s+/),d=w.filter(function(x){return /\d/.test(x);});');
    DBMS_OUTPUT.PUT_LINE('  if(!d.length)return l.length>10?l.slice(0,9)+"\u2026":l;');
    DBMS_OUTPUT.PUT_LINE('  if(/\d/.test(w[0]))return d.join(" ");');
    DBMS_OUTPUT.PUT_LINE('  return (w[0].length<=3&&w[0]===w[0].toUpperCase()?w[0]:w[0].charAt(0).toUpperCase())+" "+d.join(" ");}');
    DBMS_OUTPUT.PUT_LINE('/* markers on window boundaries: a marker that falls after the start of one');
    DBMS_OUTPUT.PUT_LINE('   compared window and before the start of the next sits on the left edge');
    DBMS_OUTPUT.PUT_LINE('   of the later one (o = its week_offset); inside Current -> on Current */');
    DBMS_OUTPUT.PUT_LINE('var MK=null;');
    DBMS_OUTPUT.PUT_LINE('W.markers=function(){');
    DBMS_OUTPUT.PUT_LINE('  if(MK)return MK;MK=[];');
    DBMS_OUTPUT.PUT_LINE('  var win=window.AWR_WIN,ms=window.AWR_MARKERS||[];if(!win||!win.w||win.w.length<2)return MK;');
    DBMS_OUTPUT.PUT_LINE('  var w=win.w,n=w.length;');
    DBMS_OUTPUT.PUT_LINE('  ms.forEach(function(m){');
    DBMS_OUTPUT.PUT_LINE('    var t=String(m.t||""),lab=String(m.label||"");if(!t||t<=w[0].s||t>w[n-1].e)return;');
    DBMS_OUTPUT.PUT_LINE('    var i=1;while(i<n-1&&t>w[i].s)i++;');
    DBMS_OUTPUT.PUT_LINE('    MK.push({o:w[i].o,after:w[i-1].o,l:lab,s:shortLbl(lab),t:dayTxt(t),at:t});');
    DBMS_OUTPUT.PUT_LINE('  });');
    DBMS_OUTPUT.PUT_LINE('  return MK;');
    DBMS_OUTPUT.PUT_LINE('};');
    DBMS_OUTPUT.PUT_LINE('W.markerAt=function(o){var r=null;W.markers().forEach(function(m){if(m.o===o)r=m;});return r;};');
    DBMS_OUTPUT.PUT_LINE('/* ---- pattern tags (plan 027): the shape of one row''s per-window values,');
    DBMS_OUTPUT.PUT_LINE('   as a hint.  Pure: vals oldest first (null = no value), valid[i] false = a');
    DBMS_OUTPUT.PUT_LINE('   skipped window, mu / sd = the row''s prior mean / sd (data-mu / data-sd),');
    DBMS_OUTPUT.PUT_LINE('   marks = [{i: column index whose LEFT edge carries a marker, l: label}].');
    DBMS_OUTPUT.PUT_LINE('   At most two tags, the Current one first:');
    DBMS_OUTPUT.PUT_LINE('     {k:"jump"|"spike", dir, m}  only Current is outside mean +- 2 floored');
    DBMS_OUTPUT.PUT_LINE('         sigma on that side: no valid prior window is (else no Current tag;');
    DBMS_OUTPUT.PUT_LINE('         "jump" when a marker sits on Current''s left edge, m = label)');
    DBMS_OUTPUT.PUT_LINE('     {k:"run", dir, n}  Current and the n-1 windows right before it are all');
    DBMS_OUTPUT.PUT_LINE('         outside on the same side (a skipped window ends the run)');
    DBMS_OUTPUT.PUT_LINE('     {k:"step", dir, at, m}  the prior windows from index at on sit apart');
    DBMS_OUTPUT.PUT_LINE('         from the ones before (m = the marker on that edge, else null; a');
    DBMS_OUTPUT.PUT_LINE('         skipped window makes the splits around it equal: the one with a');
    DBMS_OUTPUT.PUT_LINE('         marker wins, else the later)');
    DBMS_OUTPUT.PUT_LINE('     {k:"trend", dir, n}  the n prior windows follow a line better than a step');
    DBMS_OUTPUT.PUT_LINE('   dir = 1 up, -1 down.  Thresholds in W.PAT.  Tags never change a');
    DBMS_OUTPUT.PUT_LINE('   severity, an order or a count. */');
    DBMS_OUTPUT.PUT_LINE('W.PAT={MIN_PRIOR:4,STEP_L:3,STEP_R:2,STEP_PAIR:0.9,STEP_REL:0.10,STEP_SEP:2,TREND_MIN:6,TREND_R2:0.6,TREND_REL:0.10};');
    DBMS_OUTPUT.PUT_LINE('function avg(a){var s=0;for(var i=0;i<a.length;i++)s+=a[i];return s/a.length;}');
    DBMS_OUTPUT.PUT_LINE('function sdev(a){if(a.length<2)return 0;var m=avg(a),s=0;for(var i=0;i<a.length;i++)s+=(a[i]-m)*(a[i]-m);return Math.sqrt(s/(a.length-1));}');
    DBMS_OUTPUT.PUT_LINE('function sqs(a){var m=avg(a),s=0;for(var i=0;i<a.length;i++)s+=(a[i]-m)*(a[i]-m);return s;}');
    DBMS_OUTPUT.PUT_LINE('W.patterns=function(vals,valid,mu,sd,marks){');
    DBMS_OUTPUT.PUT_LINE('  var P=W.PAT,n=vals.length,c=vals[n-1],out=[],pi=[],i;');
    DBMS_OUTPUT.PUT_LINE('  if(c==null||mu==null||n<2)return out;');
    DBMS_OUTPUT.PUT_LINE('  for(i=0;i<n-1;i++)if(vals[i]!=null&&valid[i]!==false)pi.push(i);');
    DBMS_OUTPUT.PUT_LINE('  if(pi.length<P.MIN_PRIOR)return out;');
    DBMS_OUTPUT.PUT_LINE('  var mkAt=function(x){for(var k=0;k<(marks||[]).length;k++)if(marks[k].i===x)return marks[k].l;return null;};');
    DBMS_OUTPUT.PUT_LINE('  var den=Math.max(sd||0,0.02*Math.abs(mu)),hi=mu+2*den,lo=mu-2*den,dir=c>hi?1:c<lo?-1:0;');
    DBMS_OUTPUT.PUT_LINE('  if(dir){');
    DBMS_OUTPUT.PUT_LINE('    var run=0;');
    DBMS_OUTPUT.PUT_LINE('    for(i=n-2;i>=0;i--){var v=vals[i];if(v==null||valid[i]===false)break;if((dir>0&&v>hi)||(dir<0&&v<lo))run++;else break;}');
    DBMS_OUTPUT.PUT_LINE('    if(run>=1)out.push({k:"run",dir:dir,n:run+1});');
    DBMS_OUTPUT.PUT_LINE('    else if(!pi.some(function(x){return dir>0?vals[x]>hi:vals[x]<lo;})){var lm=mkAt(n-1);out.push({k:lm?"jump":"spike",dir:dir,m:lm});}');
    DBMS_OUTPUT.PUT_LINE('  }');
    DBMS_OUTPUT.PUT_LINE('  var best=null,s;');
    DBMS_OUTPUT.PUT_LINE('  for(s=1;s<n-1;s++){');
    DBMS_OUTPUT.PUT_LINE('    var L=[],R=[];pi.forEach(function(x){(x<s?L:R).push(vals[x]);});');
    DBMS_OUTPUT.PUT_LINE('    if(L.length<P.STEP_L||R.length<P.STEP_R)continue;');
    DBMS_OUTPUT.PUT_LINE('    var mL=avg(L),mR=avg(R);if(mL===0)continue;');
    DBMS_OUTPUT.PUT_LINE('    var d=mR>mL?1:-1,pairs=0;');
    DBMS_OUTPUT.PUT_LINE('    R.forEach(function(r){L.forEach(function(l){if(d>0?r>l:r<l)pairs++;});});');
    DBMS_OUTPUT.PUT_LINE('    var gap=Math.abs(mR-mL),fl=Math.max(sdev(L),sdev(R),0.02*Math.abs(mL)),sc=gap/fl;');
    DBMS_OUTPUT.PUT_LINE('    if(pairs/(L.length*R.length)<P.STEP_PAIR||gap/Math.abs(mL)<P.STEP_REL||gap<=P.STEP_SEP*fl)continue;');
    DBMS_OUTPUT.PUT_LINE('    var sm=mkAt(s);');
    DBMS_OUTPUT.PUT_LINE('    if(!best||sc>best.sc||(sc===best.sc&&(sm&&!best.m||!sm===!best.m&&s>best.at)))best={dir:d,at:s,m:sm,sc:sc,rss:sqs(L)+sqs(R)};');
    DBMS_OUTPUT.PUT_LINE('  }');
    DBMS_OUTPUT.PUT_LINE('  var tr=null;');
    DBMS_OUTPUT.PUT_LINE('  if(pi.length>=P.TREND_MIN){');
    DBMS_OUTPUT.PUT_LINE('    var ys=pi.map(function(x){return vals[x];}),mx=avg(pi),my=avg(ys),sxx=0,sxy=0,syy=0;');
    DBMS_OUTPUT.PUT_LINE('    pi.forEach(function(x,k){sxx+=(x-mx)*(x-mx);sxy+=(x-mx)*(ys[k]-my);syy+=(ys[k]-my)*(ys[k]-my);});');
    DBMS_OUTPUT.PUT_LINE('    if(sxx>0&&syy>0&&my!==0){');
    DBMS_OUTPUT.PUT_LINE('      var b=sxy/sxx,r2=sxy*sxy/(sxx*syy),rss=syy-sxy*sxy/sxx,rise=Math.abs(b*(pi[pi.length-1]-pi[0]));');
    DBMS_OUTPUT.PUT_LINE('      if(r2>=P.TREND_R2&&rise>=P.TREND_REL*Math.abs(my))tr={dir:b>0?1:-1,n:pi.length,rss:rss};');
    DBMS_OUTPUT.PUT_LINE('    }');
    DBMS_OUTPUT.PUT_LINE('  }');
    DBMS_OUTPUT.PUT_LINE('  if(tr&&(!best||tr.rss<=best.rss))out.push({k:"trend",dir:tr.dir,n:tr.n});');
    DBMS_OUTPUT.PUT_LINE('  else if(best)out.push({k:"step",dir:best.dir,at:best.at,m:best.m});');
    DBMS_OUTPUT.PUT_LINE('  return out;');
    DBMS_OUTPUT.PUT_LINE('};');
    DBMS_OUTPUT.PUT_LINE('/* a tag''s words: text (on the chip) and title (the hover) */');
    DBMS_OUTPUT.PUT_LINE('W.patternText=function(t,dates){');
    DBMS_OUTPUT.PUT_LINE('  var up=t.dir>0,dt=function(i){return (dates&&dates[i])||"?";},lab=function(l){l=String(l);return l.length>24?l.slice(0,23)+"...":l;};');
    DBMS_OUTPUT.PUT_LINE('  if(t.k==="jump")return {text:(up?"jump":"drop")+" after "+lab(t.m),title:"Only the Current window is outside the normal range of the prior windows; the marker "+t.m+" sits right before it."};');
    DBMS_OUTPUT.PUT_LINE('  if(t.k==="spike")return {text:(up?"spike":"dip")+": Current only",title:"Only the Current window is outside the normal range of the prior windows."};');
    DBMS_OUTPUT.PUT_LINE('  if(t.k==="run")return {text:(up?"high":"low")+" for "+t.n+" windows",title:"The Current window and the "+(t.n-1)+" before it are all "+(up?"above":"below")+" the normal range."};');
    DBMS_OUTPUT.PUT_LINE('  if(t.k==="step")return {text:"step "+(up?"up":"down")+(t.m?" at "+lab(t.m):" on "+dt(t.at)),title:"The prior windows from "+dt(t.at)+" on sit "+(up?"above":"below")+" the ones before"+(t.m?" (marker "+t.m+")":"")+": the normal range mixes two levels."};');
    DBMS_OUTPUT.PUT_LINE('  return {text:(up?"rising":"falling")+" across "+t.n+" windows",title:"The prior windows follow a steady "+(up?"rise":"fall")+": the normal range is a moving target."};');
    DBMS_OUTPUT.PUT_LINE('};');
    DBMS_OUTPUT.PUT_LINE('function esc(s){return String(s==null?"":s).replace(/[&<>"]/g,function(c){return {"&":"&amp;","<":"&lt;",">":"&gt;","\"":"&quot;"}[c];});}');
    DBMS_OUTPUT.PUT_LINE('/* the compared windows as column indices: validity, dates, marker columns */');
    DBMS_OUTPUT.PUT_LINE('function winIdx(){');
    DBMS_OUTPUT.PUT_LINE('  var w=(window.AWR_WIN&&window.AWR_WIN.w)||[],valid=[],dates=[],ix={};');
    DBMS_OUTPUT.PUT_LINE('  w.forEach(function(x,i){valid.push(x.v!=="N");dates.push(x.d);ix[x.o]=i;});');
    DBMS_OUTPUT.PUT_LINE('  var marks=W.markers().map(function(m){return {i:ix[m.o],l:m.l};}).filter(function(m){return m.i!=null;});');
    DBMS_OUTPUT.PUT_LINE('  return {valid:valid,dates:dates,marks:marks};');
    DBMS_OUTPUT.PUT_LINE('}');
    DBMS_OUTPUT.PUT_LINE('/* every finding card (07) gets its tags in its header; plan 025''s triage');
    DBMS_OUTPUT.PUT_LINE('   row for the card gets the same chips */');
    DBMS_OUTPUT.PUT_LINE('function tagCards(){');
    DBMS_OUTPUT.PUT_LINE('  var X=winIdx();if(!X.valid.length)return;');
    DBMS_OUTPUT.PUT_LINE('  $$("#findings article.fc:not(.chg)").forEach(function(card){');
    DBMS_OUTPUT.PUT_LINE('    var row=card.querySelector(".fc-main .wg .r[data-v]");if(!row)return;');
    DBMS_OUTPUT.PUT_LINE('    var vals=nums(row.getAttribute("data-v"));if(vals.length!==X.valid.length)return;');
    DBMS_OUTPUT.PUT_LINE('    var a=function(n){var v=row.getAttribute(n+"0");return num(v!=null?v:row.getAttribute(n));};');
    DBMS_OUTPUT.PUT_LINE('    var tags=W.patterns(vals,X.valid,a("data-mu"),a("data-sd"),X.marks);if(!tags.length)return;');
    DBMS_OUTPUT.PUT_LINE('    var html=tags.map(function(t){var p=W.patternText(t,X.dates);');
    DBMS_OUTPUT.PUT_LINE('      return ''<span class="ptag p-''+t.k+(t.m?'' p-rel'':'''')+''" title="''+esc(p.title)+''">''+esc(p.text)+''</span>'';}).join("");');
    DBMS_OUTPUT.PUT_LINE('    var box=card.querySelector(".fc-tags");');
    DBMS_OUTPUT.PUT_LINE('    if(!box){var k=card.querySelector(".fc-h .fc-k");if(!k)return;box=mk("span","fc-tags",k);}');
    DBMS_OUTPUT.PUT_LINE('    box.innerHTML=html;');
    DBMS_OUTPUT.PUT_LINE('    $$(''#triage .tri-row[data-card="''+card.id+''"] .tri-tags'').forEach(function(t){t.innerHTML=html;});');
    DBMS_OUTPUT.PUT_LINE('  });');
    DBMS_OUTPUT.PUT_LINE('}');
    DBMS_OUTPUT.PUT_LINE('/* one bars row: grey prior columns, the Current one in the accent, the');
    DBMS_OUTPUT.PUT_LINE('   prior normal zone (mean +- 1 / 2 floored sigma; in the Timeline grid');
    DBMS_OUTPUT.PUT_LINE('   #tl only behind the Current bar) and a severity dot */');
    DBMS_OUTPUT.PUT_LINE('function sizeRow(row){');
    DBMS_OUTPUT.PUT_LINE('  var cells=$$(":scope > .c",row);if(!cells.length)return;');
    DBMS_OUTPUT.PUT_LINE('  var vals=nums(row.getAttribute("data-v")),mu=num(row.getAttribute("data-mu")),sd=num(row.getAttribute("data-sd")),sev=row.getAttribute("data-sev")||"";');
    DBMS_OUTPUT.PUT_LINE('  var z=null;if(mu!=null){var d=Math.max(sd||0,0.02*Math.abs(mu));z=[Math.max(0,mu-2*d),mu+2*d,Math.max(0,mu-d),mu+d,mu];}');
    DBMS_OUTPUT.PUT_LINE('  var have=vals.filter(function(v){return v!=null;}),max=Math.max.apply(null,have.concat(z?[z[1]]:[]).concat([0]));if(!(max>0))max=1;');
    DBMS_OUTPUT.PUT_LINE('  var bh=cssNum(row,"--bh",24),bb=cssNum(row,"--bb",4),bare=!!row.closest(".wg.bare"),tl=!!row.closest("#tl");');
    DBMS_OUTPUT.PUT_LINE('  var y=function(v){return Math.max(0,v)/max*bh;};');
    DBMS_OUTPUT.PUT_LINE('  cells.forEach(function(c,k){');
    DBMS_OUTPUT.PUT_LINE('    $$(":scope > i",c).forEach(function(x){c.removeChild(x);});');
    DBMS_OUTPUT.PUT_LINE('    if(z&&(!tl||c.classList.contains("cur"))){var z2=mk("i","z2",c);z2.style.bottom=(bb+y(z[0]))+"px";z2.style.height=Math.max(1,y(z[1])-y(z[0]))+"px";');
    DBMS_OUTPUT.PUT_LINE('      var z1=mk("i","z1",c);z1.style.bottom=(bb+y(z[2]))+"px";z1.style.height=Math.max(1,y(z[3])-y(z[2]))+"px";');
    DBMS_OUTPUT.PUT_LINE('      var mn=mk("i","mn",c);mn.style.bottom=(bb+y(z[4]))+"px";}');
    DBMS_OUTPUT.PUT_LINE('    if(bare)mk("i","base",c);');
    DBMS_OUTPUT.PUT_LINE('    var v=vals[k];if(v==null)return;');
    DBMS_OUTPUT.PUT_LINE('    var h=Math.max(1.5,y(v)),b=mk("i","b",c);b.style.height=h+"px";');
    DBMS_OUTPUT.PUT_LINE('    if(c.classList.contains("cur")&&(sev==="large"||sev==="moderate")){var s=mk("i","sd s-"+sev,c);s.style.bottom=(bb+h)+"px";}');
    DBMS_OUTPUT.PUT_LINE('  });');
    DBMS_OUTPUT.PUT_LINE('}');
    DBMS_OUTPUT.PUT_LINE('W.sizeRow=sizeRow;');
    DBMS_OUTPUT.PUT_LINE('function markCols(wg){');
    DBMS_OUTPUT.PUT_LINE('  W.markers().forEach(function(m){$$(''.c[data-w="''+m.o+''"],.h[data-w="''+m.o+''"]'',wg).forEach(function(c){c.classList.add("mk");});});');
    DBMS_OUTPUT.PUT_LINE('}');
    DBMS_OUTPUT.PUT_LINE('/* release flags on the column boundaries: full label, else the short one,');
    DBMS_OUTPUT.PUT_LINE('   in two tiers, left- or right-anchored, never overlapping.  ".qf" (quiet');
    DBMS_OUTPUT.PUT_LINE('   flags, the card charts): only the marker on the Current window''s left');
    DBMS_OUTPUT.PUT_LINE('   edge is labelled; the others keep their column line (markCols). */');
    DBMS_OUTPUT.PUT_LINE('function layoutFlags(wg){');
    DBMS_OUTPUT.PUT_LINE('  var quiet=wg.classList.contains("qf");');
    DBMS_OUTPUT.PUT_LINE('  $$(".flags",wg).forEach(function(fl){');
    DBMS_OUTPUT.PUT_LINE('    if(!shown(fl))return;fl.innerHTML="";');
    DBMS_OUTPUT.PUT_LINE('    var base=fl.getBoundingClientRect().left,width=fl.clientWidth,TH=17,tiers=[[],[]],narrow=width<520;');
    DBMS_OUTPUT.PUT_LINE('    W.markers().forEach(function(m){');
    DBMS_OUTPUT.PUT_LINE('      if(quiet&&m.o!==0)return;');
    DBMS_OUTPUT.PUT_LINE('      var ref=$$(''[data-w="''+m.o+''"]'',wg).filter(function(e){return !e.closest(".flags");})[0];if(!ref)return;');
    DBMS_OUTPUT.PUT_LINE('      var x=ref.getBoundingClientRect().left-base,labels=narrow?[m.s]:[m.l,m.s],cands=[];');
    DBMS_OUTPUT.PUT_LINE('      labels.forEach(function(l){cands.push([l,0]);});labels.forEach(function(l){cands.push([l,1]);});');
    DBMS_OUTPUT.PUT_LINE('      cands.some(function(cd){');
    DBMS_OUTPUT.PUT_LINE('        for(var t=0;t<tiers.length;t++){');
    DBMS_OUTPUT.PUT_LINE('          var f=mk("div","flag",fl);f.textContent=cd[0];f.style.left=x+"px";f.style.top=(2+t*TH)+"px";f.title=m.l+", "+m.t;');
    DBMS_OUTPUT.PUT_LINE('          var w=f.offsetWidth,x0=x-2,x1=x+w+6;');
    DBMS_OUTPUT.PUT_LINE('          if(cd[1]){f.classList.add("end");f.style.left=(x-w)+"px";x0=x-w-6;x1=x+2;}');
    DBMS_OUTPUT.PUT_LINE('          var clash=tiers[t].some(function(r){return x0<r[1]&&x1>r[0];})||x1>width+1||x0<-1;');
    DBMS_OUTPUT.PUT_LINE('          if(!clash){tiers[t].push([x0,x1]);var p=mk("i","pole",fl);p.style.left=(x-0.75)+"px";p.style.top=(2+t*TH)+"px";return true;}');
    DBMS_OUTPUT.PUT_LINE('          fl.removeChild(f);');
    DBMS_OUTPUT.PUT_LINE('        }');
    DBMS_OUTPUT.PUT_LINE('        return false;');
    DBMS_OUTPUT.PUT_LINE('      });');
    DBMS_OUTPUT.PUT_LINE('    });');
    DBMS_OUTPUT.PUT_LINE('  });');
    DBMS_OUTPUT.PUT_LINE('}');
    DBMS_OUTPUT.PUT_LINE('function fit(wg){');
    DBMS_OUTPUT.PUT_LINE('  if(!shown(wg))return;');
    DBMS_OUTPUT.PUT_LINE('  var c=wg.querySelector(''.r:not(.fr) > .c:not(.cur),.rin > .h:not(.cur),.dr > .h:not(.cur)'');');
    DBMS_OUTPUT.PUT_LINE('  if(c)wg.classList.toggle("tight",c.getBoundingClientRect().width<42);');
    DBMS_OUTPUT.PUT_LINE('  layoutFlags(wg);');
    DBMS_OUTPUT.PUT_LINE('}');
    DBMS_OUTPUT.PUT_LINE('W.fit=fit;');
    DBMS_OUTPUT.PUT_LINE('W.render=function(scope){');
    DBMS_OUTPUT.PUT_LINE('  var s=scope||doc;');
    DBMS_OUTPUT.PUT_LINE('  $$(".wg .r.bars",s).forEach(sizeRow);');
    DBMS_OUTPUT.PUT_LINE('  $$("[data-wg]",s).forEach(function(wg){markCols(wg);fit(wg);});');
    DBMS_OUTPUT.PUT_LINE('  if(s.matches&&s.matches("[data-wg]")){markCols(s);fit(s);}');
    DBMS_OUTPUT.PUT_LINE('};');
    DBMS_OUTPUT.PUT_LINE('function refit(){$$("[data-wg]").forEach(fit);}');
    DBMS_OUTPUT.PUT_LINE('W.refit=refit;');
    DBMS_OUTPUT.PUT_LINE('/* marker text slots: <span data-mk-at="o" [data-mk-pre=" after "] [data-mk-icon]> */');
    DBMS_OUTPUT.PUT_LINE('function fillMk(){');
    DBMS_OUTPUT.PUT_LINE('  $$("[data-mk-at]").forEach(function(el){');
    DBMS_OUTPUT.PUT_LINE('    var m=W.markerAt(+el.getAttribute("data-mk-at"));if(!m)return;');
    DBMS_OUTPUT.PUT_LINE('    el.innerHTML="";');
    DBMS_OUTPUT.PUT_LINE('    if(el.hasAttribute("data-mk-icon"))mk("i","kf",el);');
    DBMS_OUTPUT.PUT_LINE('    el.appendChild(doc.createTextNode((el.getAttribute("data-mk-pre")||"")+m.l+(el.hasAttribute("data-mk-icon")?"":" ("+m.t+")")));');
    DBMS_OUTPUT.PUT_LINE('    el.title=m.l+", "+m.t;el.hidden=false;');
    DBMS_OUTPUT.PUT_LINE('  });');
    DBMS_OUTPUT.PUT_LINE('}');
    DBMS_OUTPUT.PUT_LINE('/* entity links whose row was never emitted become plain text */');
    DBMS_OUTPUT.PUT_LINE('function unwrap(){');
    DBMS_OUTPUT.PUT_LINE('  $$("a.ent").forEach(function(a){');
    DBMS_OUTPUT.PUT_LINE('    var id=(a.getAttribute("href")||"").slice(1).split("!")[0];');
    DBMS_OUTPUT.PUT_LINE('    if(id&&doc.getElementById(id))return;');
    DBMS_OUTPUT.PUT_LINE('    var s=mk("span","ent-x");while(a.firstChild)s.appendChild(a.firstChild);a.parentNode.replaceChild(s,a);');
    DBMS_OUTPUT.PUT_LINE('  });');
    DBMS_OUTPUT.PUT_LINE('}');
    DBMS_OUTPUT.PUT_LINE('/* hover a column: every cell of that window lights up, its value shows */');
    DBMS_OUTPUT.PUT_LINE('var hovWg=null,hovW=null;');
    DBMS_OUTPUT.PUT_LINE('function hover(wg,w){');
    DBMS_OUTPUT.PUT_LINE('  if(hovWg&&(hovWg!==wg||hovW!==w))$$(".hc",hovWg).forEach(function(x){x.classList.remove("hc");});');
    DBMS_OUTPUT.PUT_LINE('  hovWg=wg;hovW=w;');
    DBMS_OUTPUT.PUT_LINE('  if(wg&&w!=null)$$(''.c[data-w="''+w+''"],.h[data-w="''+w+''"]'',wg).forEach(function(x){if(!x.closest(".flags"))x.classList.add("hc");});');
    DBMS_OUTPUT.PUT_LINE('}');
    DBMS_OUTPUT.PUT_LINE('doc.addEventListener("mouseover",function(ev){');
    DBMS_OUTPUT.PUT_LINE('  var t=ev.target&&ev.target.closest?ev.target.closest(".wg.hov [data-w]"):null;');
    DBMS_OUTPUT.PUT_LINE('  if(!t){if(hovWg)hover(null,null);return;}');
    DBMS_OUTPUT.PUT_LINE('  hover(t.closest(".wg"),t.getAttribute("data-w"));');
    DBMS_OUTPUT.PUT_LINE('});');
    DBMS_OUTPUT.PUT_LINE('/* "Timeline ->": the row that phase 3 emits (data-tl) wins over #timeline */');
    DBMS_OUTPUT.PUT_LINE('doc.addEventListener("click",function(ev){');
    DBMS_OUTPUT.PUT_LINE('  var a=ev.target&&ev.target.closest?ev.target.closest("a.jump[data-tl]"):null;if(!a||ev.button||ev.metaKey||ev.ctrlKey||ev.shiftKey)return;');
    DBMS_OUTPUT.PUT_LINE('  var el=doc.getElementById(a.getAttribute("data-tl"));');
    DBMS_OUTPUT.PUT_LINE('  if(el&&window.AWR_goTo){ev.preventDefault();window.AWR_goTo(el,true,true);}');
    DBMS_OUTPUT.PUT_LINE('});');
    DBMS_OUTPUT.PUT_LINE('var rt=null;');
    DBMS_OUTPUT.PUT_LINE('window.addEventListener("resize",function(){if(rt)clearTimeout(rt);rt=setTimeout(refit,120);});');
    DBMS_OUTPUT.PUT_LINE('doc.addEventListener("awr:view",function(){setTimeout(refit,40);});');
    DBMS_OUTPUT.PUT_LINE('doc.addEventListener("toggle",function(ev){var t=ev.target;if(t&&t.querySelector&&t.querySelector("[data-wg]"))setTimeout(function(){W.render(t);},20);},true);');
    DBMS_OUTPUT.PUT_LINE('doc.addEventListener("DOMContentLoaded",function(){unwrap();fillMk();W.render(doc);tagCards();setTimeout(refit,300);});');
    DBMS_OUTPUT.PUT_LINE('})();');
    DBMS_OUTPUT.PUT_LINE('</script>');
END;
/
