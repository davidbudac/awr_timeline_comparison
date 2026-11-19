/* js_reldelta: client half of section 28_release_delta (Before and after a
   release).  Reads window.AWR_DATA.reldelta (per-window values of every
   canonical LOAD / METRIC row and the wait classes), window.AWR_WIN (the
   compared windows, oldest first) and window.AWR_MARKERS (release
   markers); splits the VALID windows at a marker or a window boundary
   (before = ends at or before the instant, after = starts at or after it,
   a window containing it straddles) and draws one lollipop row per metric:
   the change of the after mean against the before mean, in percent on a
   symmetric axis, over the before windows' own variation (mean +- 2 sd,
   sd floored at 2% of the mean).  HTML / CSS only (positions in percent),
   so it needs no width to draw and works with the CDN blocked.  Runs at
   parse time (the payload, AWR_WIN and AWR_MARKERS exist already). */
(function(){
var doc=document,R=window.AWR_DATA&&window.AWR_DATA.reldelta,sec=doc.getElementById("release-delta");
if(!R||!sec)return;
var app=sec.querySelector(".rd-app"),WIN=window.AWR_WIN;
if(!app||!WIN||!WIN.w||WIN.w.length<2)return;
var W=WIN.w,N=W.length,M=R.m||[];
var X=String.fromCharCode(215),UP=String.fromCharCode(9650),DN=String.fromCharCode(9660),MI=String.fromCharCode(8722),PM=String.fromCharCode(177);
var MON=["Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"],DOW=["Sun","Mon","Tue","Wed","Thu","Fri","Sat"];
function $(s,r){return (r||app).querySelector(s);}
function mk(t,c,p){var e=doc.createElement(t);if(c)e.className=c;if(p)p.appendChild(e);return e;}
function esc(s){return String(s).replace(/&/g,"&amp;").replace(/</g,"&lt;").replace(/>/g,"&gt;").replace(/"/g,"&quot;");}
function dt(t){var d=new Date(String(t).replace(" ","T"));return isNaN(d.getTime())?null:d;}
function dayTxt(t){var d=dt(t);return d?DOW[d.getDay()]+" "+d.getDate()+" "+MON[d.getMonth()]:String(t);}
function dtTxt(t){var d=dt(t);if(!d)return String(t);var h=d.getHours(),m=d.getMinutes();return dayTxt(t)+" "+(h<10?"0":"")+h+":"+(m<10?"0":"")+m;}
function lc(s){return s.length>1&&s.charAt(1)===s.charAt(1).toLowerCase()?s.charAt(0).toLowerCase()+s.slice(1):s;}
/* numbers: about 4 significant digits, k / M / G past 1e4 (fmt_num's rule) */
function fnum(v){if(v==null||isNaN(v))return "&mdash;";
  if(v===0)return "0";var a=Math.abs(v),s=v<0?"-":"",u="";
  if(a>=1e9){a/=1e9;u=" G";}else if(a>=1e6){a/=1e6;u=" M";}else if(a>=1e4){a/=1e3;u=" k";}
  var t=a>=1000?String(Math.round(a)):a>=100?a.toFixed(1):a>=10?a.toFixed(2):a>=1?a.toFixed(3):a.toPrecision(3);
  if(t.indexOf(".")>=0&&a<1)t=t.replace(/0+$/,"").replace(/\.$/,"");
  return s+t+u;}
function fv(v,u){if(v==null||isNaN(v))return "&mdash;";
  if(u==="B/s"){var a=Math.abs(v);if(a>=1e9)return fnum(v/1e9)+" GB/s";if(a>=1e6)return fnum(v/1e6)+" MB/s";if(a>=1e3)return fnum(v/1e3)+" kB/s";return fnum(v)+" B/s";}
  return fnum(v)+(!u?"":u.charAt(0)==="/"?u:" "+u);}
function pct(p){var a=Math.abs(p),t=a<10?a.toFixed(1):String(Math.round(a));return (p>0?"+":p<0?MI:"")+t+"%";}
/* the change label: x n when after / before >= 2 (delta_span's rule), else a signed percent */
function chgTxt(r){if(r.zero)return "from 0";var q=r.ma/r.mb;if(r.mb>0&&q>=2)return X+(q<10?q.toFixed(1):String(Math.round(q)));return pct(r.chg);}
function mean(a){var s=0;a.forEach(function(v){s+=v;});return s/a.length;}
function sdev(a,m){if(a.length<2)return 0;var s=0;a.forEach(function(v){s+=(v-m)*(v-m);});return Math.sqrt(s/(a.length-1));}

/* ---- the split: valid windows before / after an instant (strings compare as 'YYYY-MM-DD HH:MI') */
function split(t){var b=[],a=[],s=[],k=0;
  W.forEach(function(w){if(w.v!=="Y"){k++;return;}if(w.e<=t)b.push(w);else if(w.s>=t)a.push(w);else s.push(w);});
  return {t:t,b:b,a:a,s:s,k:k};}
function whyNot(sp){if(sp.b.length<2)return "only "+(sp.b.length?"one valid window":"no valid window")+" before it (needs 2)";
  if(!sp.a.length)return sp.s.length?"it falls inside the "+(sp.s[sp.s.length-1].o===0?"Current window":"last window")+", no complete window after it":"no valid window after it";
  return "";}
var MKS=[],OUT=[];
(window.AWR_MARKERS||[]).forEach(function(m){var t=String(m.t||""),l=String(m.label||"");if(!t)return;
  var o={t:t,l:l};if(t<W[0].s||t>=W[N-1].e){OUT.push(o);return;}o.sp=split(t);o.why=whyNot(o.sp);MKS.push(o);});
MKS.sort(function(x,y){return x.t<y.t?1:x.t>y.t?-1:0;});

/* ---- per-metric statistics for one split */
function stats(sp){var rows=[],na=[],wt=0;
  M.forEach(function(m){var B=[],A=[];
    sp.b.forEach(function(w){var v=m.v[w.o];if(v!=null)B.push(v);});
    sp.a.forEach(function(w){var v=m.v[w.o];if(v!=null)A.push({o:w.o,v:v});});
    if(B.length<2||!A.length){na.push(m);return;}
    var mb=mean(B),sd=sdev(B,mb),ma=mean(A.map(function(x){return x.v;})),den=Math.max(sd,0.02*Math.abs(mb));
    var r={m:m,nb:B.length,na:A.length,mb:mb,sd:sd,ma:ma,av:A,zero:false};
    if(mb===0){r.chg=ma===0?0:null;r.zero=ma!==0;r.band=0;r.z=ma===0?0:(den>0?(ma-mb)/den:Infinity);}
    else{r.chg=(ma-mb)/Math.abs(mb)*100;r.band=200*den/Math.abs(mb);r.z=(ma-mb)/den;}
    r.out=Math.abs(r.z)>2;if(m.d==="W")wt+=ma;rows.push(r);});
  rows.forEach(function(r){var m=r.m,mat=r.chg==null||Math.abs(r.chg)>=(m.mp==null?10:m.mp);
    if(mat&&m.ma!=null){if(m.d==="W"){if(wt>0&&r.ma/wt<m.ma)mat=false;}else if(Math.max(Math.abs(r.ma),Math.abs(r.mb))<m.ma)mat=false;}
    r.mat=mat;var up=r.ma>r.mb;
    r.st=!r.out?"inside":!mat?"small":m.dir==="UP"?(up?"worse":"better"):m.dir==="DOWN"?(up?"better":"worse"):"changed";
    r.flag=r.st==="worse"||r.st==="better"||r.st==="changed";});
  rows.sort(function(x,y){if(x.flag!==y.flag)return x.flag?-1:1;var d=Math.abs(y.z)-Math.abs(x.z);return d||(x.m.l<y.m.l?-1:1);});
  return {rows:rows,na:na};}

/* ---- the chart: one row per metric, percent positions on a symmetric axis */
var STEPS=[10,20,25,50,100,150,200,300,400];
function scaleOf(rows){var mx=0;rows.forEach(function(r){var c=r.chg==null?400:Math.abs(r.chg);mx=Math.max(mx,Math.min(400,c),Math.min(400,r.band));
    r.av.forEach(function(a){if(r.mb)mx=Math.max(mx,Math.min(400,Math.abs((a.v-r.mb)/r.mb*100)));});});
  for(var i=0;i<STEPS.length;i++)if(STEPS[i]>=mx*1.08)return STEPS[i];return 400;}
function xp(p,L){p=Math.max(-L,Math.min(L,p));return (p+L)/(2*L)*100;}
function f2(v){return (Math.round(v*100)/100)+"%";}
var WORD={worse:"worse",better:"better",changed:"changed",small:"small move",inside:"inside"};
function glyph(r){return r.ma>r.mb?UP:r.ma<r.mb?DN:"";}
function tipHtml(r,L){var m=r.m,u=m.u,s=m.s;
  var h='<b>'+esc(m.l)+'</b><br>before: '+fv(r.mb*s,u)+' '+PM+' '+fv(r.sd*s,u)+' ('+r.nb+' window'+(r.nb>1?'s':'')+')<br>after: '+fv(r.ma*s,u)+' ('+r.na+' window'+(r.na>1?'s':'')+')';
  h+='<br>change: '+(r.zero?'from 0':pct(r.chg)+(chgTxt(r)!==pct(r.chg)?' ('+chgTxt(r)+')':''));
  if(!r.zero&&r.mb)h+='<br><span class="tm">usual variation before: '+PM+(r.band<10?r.band.toFixed(1):Math.round(r.band))+'%</span>';
  if(r.chg==null||Math.abs(r.chg)>L)h+='<br><span class="tm">off the scale (beyond '+PM+L+'%)</span>';
  h+='<br>'+(r.flag?'<b>'+glyph(r)+' '+WORD[r.st]+'</b>: outside its usual variation':r.st==="small"?'outside its usual variation, but by less than its '+(m.mp==null?10:m.mp)+'% materiality floor':'inside its usual variation');
  if(r.na>1)h+='<br><span class="tm">each window after: '+r.av.map(function(a){return fv(a.v*s,u);}).join(', ')+'</span>';
  return h;}
var tip=null;
function tipOn(html,e){tip=tip||doc.getElementById("tip");if(!tip){tip=mk("div","",doc.body);tip.id="tip";tip.setAttribute("role","tooltip");}
  tip.innerHTML=html;tip.hidden=false;var x=e.clientX+14,y=e.clientY+16,w=tip.offsetWidth,h=tip.offsetHeight;
  if(x+w>innerWidth-8)x=e.clientX-w-12;if(y+h>innerHeight-8)y=e.clientY-h-12;tip.style.left=Math.max(8,x)+"px";tip.style.top=Math.max(8,y)+"px";}
function tipOff(){if(tip)tip.hidden=true;}
function axisRow(box,L,head,clipped){var r=mk("div","rd-r rd-ax",box);r.setAttribute("aria-hidden","true");
  mk("span","rd-lab",r).textContent=head;var sc=mk("span","rd-sc",mk("span","rd-st",r)),i;
  for(i=-2;i<=2;i++){var p=L*i/2,e=mk("em",i?"":"z",sc);e.style.left=xp(p,L)+"%";
    e.textContent=(i===2&&L===400&&clipped)?"> "+X+"5":i===0?"0":pct(p).replace(".0%","%");}
  mk("span","rd-w",r).textContent="status";}
function row(box,r,L){var m=r.m,e=mk("div","rd-r s-"+r.st+(r.flag?" fl":""),box),lab=mk("span","rd-lab",e),t=doc.getElementById(m.id);
  e.setAttribute("role","listitem");
  if(t){var a=mk("a","",lab);a.className="ent";a.href="#"+m.id;a.setAttribute("data-ent","metric");a.textContent=m.l;}else lab.textContent=m.l;
  lab.title=m.n;
  var st=mk("span","rd-st",e),sc=mk("span","rd-sc",st),i;st.setAttribute("role","img");
  var lbl=chgTxt(r),cl=r.chg==null||Math.abs(r.chg)>L,c=r.chg==null?(r.ma>r.mb?L:-L):r.chg,x=xp(c,L),x0=xp(0,L);
  st.setAttribute("aria-label",m.l+": "+lbl+" after the split, usual variation "+PM+(r.zero?"0":Math.round(r.band))+"%, "+(r.flag?WORD[r.st]:r.st==="small"?"outside but small":"inside its usual variation"));
  for(i=-2;i<=2;i++)mk("i","rd-g"+(i?"":" z"),sc).style.left=xp(L*i/2,L)+"%";
  if(r.band>0){var bl=xp(-r.band,L),b=mk("i","rd-band",sc);b.style.left=bl+"%";b.style.width=(xp(r.band,L)-bl)+"%";}
  var sm=mk("i","rd-stem",sc);sm.style.left=Math.min(x,x0)+"%";sm.style.width=Math.abs(x-x0)+"%";
  var tx=[];if(r.na>1&&r.mb)r.av.forEach(function(a){var q=xp((a.v-r.mb)/Math.abs(r.mb)*100,L);tx.push(q);mk("i","rd-tk",sc).style.left=q+"%";});
  mk("i","rd-dot"+(r.na>1?"":" hol")+(cl?" clip"+(c<0?" neg":""):""),sc).style.left=x+"%";
  var vx=c>=0?Math.max.apply(null,[x,xp(r.band,L)].concat(tx)):Math.min.apply(null,[x,xp(-r.band,L)].concat(tx)),v=mk("b","rd-val"+(c<0?" neg":""),sc);
  v.style.left=vx+"%";v.textContent=(r.out?glyph(r)+" ":"")+lbl;
  mk("span","rd-w",e).textContent=(r.flag?glyph(r)+" ":"")+WORD[r.st];
  st.addEventListener("mousemove",function(ev){tipOn(tipHtml(r,L),ev);});st.addEventListener("mouseleave",tipOff);}
function chart(box,rows,head){box.innerHTML="";if(!rows.length)return;var L=scaleOf(rows),clipped=false;
  rows.forEach(function(r){if(r.chg==null||Math.abs(r.chg)>L)clipped=true;});
  axisRow(box,L,head,clipped);rows.forEach(function(r){row(box,r,L);});}

/* ---- the numbers of the split (a real table; the chrome sorts it) */
function table(S){var tb=$(".rd-tbl tbody");if(!tb)return;var h=[];
  S.rows.concat(S.na.map(function(m){return {m:m,nil:true};})).forEach(function(r){var m=r.m,u=m.u,s=m.s,
    lk=doc.getElementById(m.id)?'<a href="#'+m.id+'" data-ent="metric">'+esc(m.l)+'</a>':esc(m.l);
    if(r.nil){h.push('<tr><td>'+lk+'</td><td class="num">&mdash;</td><td class="num">&mdash;</td><td class="num">&mdash;</td><td class="num">&mdash;</td><td class="num">&mdash;</td><td class="num">&mdash;</td><td class="num">&mdash;</td><td>not enough windows</td></tr>');return;}
    h.push('<tr class="rd-'+r.st+'"><td>'+lk+'</td><td class="num">'+fv(r.mb*s,u)+'</td><td class="num">'+fv(r.sd*s,u)+'</td><td class="num">'+r.nb
      +'</td><td class="num">'+fv(r.ma*s,u)+'</td><td class="num">'+r.na+'</td><td class="num">'+(r.zero?'from 0':pct(r.chg))
      +'</td><td class="num">'+(r.zero||!r.mb?'&mdash;':PM+f2(Math.round(r.band*10)/10))+'</td><td>'+(r.flag?glyph(r)+' ':'')+WORD[r.st]+'</td></tr>');});
  tb.innerHTML=h.join("");
  /* entity links: the chrome styles a.ent; set the class as a property (lint 21 keeps the literal in ent()) */
  Array.prototype.forEach.call(tb.querySelectorAll("a[data-ent]"),function(a){a.className="ent";});}

/* ---- render one split, or the invitation */
var CUR=null;
function nameOf(o){return o.mk?o.mk.l+" ("+dayTxt(o.mk.t)+")":"the boundary at "+dtTxt(o.t);}
/* a window's start: the day, plus the time when the cadence is under a day */
var SUB=dt(W[1].s)&&dt(W[0].s)&&(dt(W[1].s)-dt(W[0].s))<864e5;
function wTxt(w){return SUB?dtTxt(w.s):dayTxt(w.s);}
function rangeTxt(ws){if(!ws.length)return "none";if(ws.length===1)return ws[0].o===0?"1 (Current)":"1 ("+wTxt(ws[0])+")";
  return ws.length+" ("+wTxt(ws[0])+" &ndash; "+(ws[ws.length-1].o===0?"Current":wTxt(ws[ws.length-1]))+")";}
function render(o){CUR=o;var body=$(".rd-body"),why=$(".rd-why"),side=$(".rd-side");
  Array.prototype.forEach.call(app.querySelectorAll(".rd-mb"),function(b){b.setAttribute("aria-pressed",o&&o.mk&&b._mk===o.mk?"true":"false");});
  if(!o){body.hidden=true;side.innerHTML="";why.hidden=false;
    why.innerHTML=(MKS.length?"No release marker falls on a usable boundary of the compared windows (see above).":OUT.length?"No release marker falls inside the compared span (see above).":"No release markers in this run.")
      +" Set them when you run the report, for example <code>MARKERS='2026-09-08 22:00|Release 4.2'</code> (or <code>marker_file</code>), or pick a window boundary above: the view then compares the windows before it with the windows after it.";
    return null;}
  why.hidden=true;body.hidden=false;var sp=o.sp,S=stats(sp);
  side.innerHTML="<b>Before:</b> "+rangeTxt(sp.b)+" valid windows &middot; <b>after:</b> "+rangeTxt(sp.a)
    +(sp.s.length?" &middot; <b>straddles</b> (in neither): "+sp.s.map(wTxt).join(", "):"")
    +(sp.k?" &middot; "+sp.k+" skipped window"+(sp.k>1?"s":""):"");
  var fl=S.rows.filter(function(r){return r.flag;}),main=S.rows.slice(0,Math.min(24,Math.max(12,fl.length))),rest=S.rows.slice(main.length);
  chart($(".rd-chart"),main,"change of the after mean vs before");
  var more=$(".rd-more"),nin=rest.filter(function(r){return r.st==="inside";}).length;
  more.hidden=!rest.length&&!S.na.length;chart($(".rd-chart2"),rest,"change vs before");
  var sm=more.querySelector("summary");
  sm.innerHTML=!rest.length?S.na.length+" without enough windows":nin===rest.length?"+ "+rest.length+" within usual variation":"+ "+rest.length+" more ("+nin+" within usual variation)";
  var nap=more.querySelector(".rd-na");if(nap)nap.remove();
  if(S.na.length){nap=mk("p","rd-na note",more);nap.textContent="Not enough windows on one side (2 before, 1 after needed): "+S.na.map(function(m){return m.l;}).join(", ")+".";}
  table(S);
  /* Reads as */
  var n=S.rows.length,nsm=S.rows.filter(function(r){return r.st==="small";}).length,lst=fl.slice(0,3).map(function(r){return esc(lc(r.m.l))+" "+chgTxt(r);}).join(", ");
  var one=sp.a.length===1?" Only one window after it"+(sp.a[0].o===0?" (Current)":"")+": a single window, not yet a trend.":"";
  var head="After "+esc(nameOf(o)),txt;
  if(fl.length)txt=head+": "+fl.length+" of "+n+" metrics moved outside their usual variation &mdash; "+lst+(fl.length>3?" and "+(fl.length-3)+" more":"")
    +"; "+(n-fl.length-nsm)+" stayed inside"+(nsm?", "+nsm+" moved outside it by too little to matter":"")+"."+one;
  else txt=head+": none of the "+n+" metrics moved outside its usual variation"+(nsm?" by enough to matter ("+nsm+" moved slightly outside it)":"")+"."+one;
  $(".rd-reads").innerHTML="<b>Reads as:</b> "+txt;
  return {fl:fl,n:n,lst:lst,head:head};}

/* ---- the picker: one button per usable marker (newest first) + any window boundary */
var mks=$(".rd-mks"),sel=$(".rd-sel"),i;
MKS.forEach(function(m){if(m.why)return;var b=mk("button","rd-mb",mks);b.type="button";b._mk=m;
  b.innerHTML=esc(m.l)+"<small>"+dayTxt(m.t)+"</small>";b.title=m.l+" at "+m.t+": "+m.sp.b.length+" valid windows before, "+m.sp.a.length+" after";
  b.addEventListener("click",function(){sel.value="";render({mk:m,t:m.t,sp:m.sp});});});
if(!mks.children.length)mk("span","rd-none",mks).textContent=MKS.length||OUT.length?"no usable release marker":"no release markers";
var o0=mk("option","",sel);o0.value="";o0.textContent="choose a boundary";
for(i=N-1;i>=1;i--){var sp=split(W[i].s),op=mk("option","",sel),wn=whyNot(sp);op.value=String(i);
  op.textContent="before "+W[i].t+(W[i].o===0?" (Current)":"")+(wn?" - "+wn:"");if(wn)op.disabled=true;}
sel.addEventListener("change",function(){if(sel.value===""){render(null);return;}var k=+sel.value;render({t:W[k].s,sp:split(W[k].s)});});
/* markers that cannot split: listed under the picker with the reason */
var skip=MKS.filter(function(m){return m.why;}).map(function(m){return "<b>"+esc(m.l)+"</b> ("+dtTxt(m.t)+"): "+esc(m.why);})
  .concat(OUT.map(function(m){return "<b>"+esc(m.l)+"</b> ("+dtTxt(m.t)+"): outside the compared span";}));
if(skip.length){var sk=mk("p","rd-skip",null);sk.innerHTML="Not usable: "+skip.join("; ")+".";$(".rd-pick").insertAdjacentElement("afterend",sk);}

var nojs=sec.querySelector(".rd-nojs");if(nojs)nojs.hidden=true;
app.hidden=false;
var first=null;MKS.forEach(function(m){if(!first&&!m.why)first=m;});
var res=render(first?{mk:first,t:first.t,sp:first.sp}:null);
/* the evidence-library row: the default split's answer */
if(window.AWR_ls){
  if(res)window.AWR_ls("release-delta",res.head+": "+(res.fl.length?res.fl.length+" of "+res.n+" metrics outside their usual variation &mdash; "+res.lst:"every metric inside its usual variation"));
  else window.AWR_ls("release-delta",(MKS.length||OUT.length?"no release marker on a usable boundary":"no release markers")+"; pick a window boundary to split "+R.nv+" valid windows");}
})();
