(function(){
"use strict";
/* Fleet co-anomaly grid: DBs x time buckets on one absolute time axis.
   Readable source of sql/fleet/js_fleet_coanom.plsql (regenerate with
   sh sql/fleet/src/fleet_js2plsql.sh).  Pure ASCII, no tilde. */
var ZR=2,ZF=3,ZX=6,MADK=1.4826,FREL=0.20,FABS=0.05,MINCOV=0.5,SHARE=0.25,PHDAYS=3,PHMIN=3,MAXCOL=400;
var DOW=["Sun","Mon","Tue","Wed","Thu","Fri","Sat"];
var S=null;
function esc(s){return String(s==null?"":s).replace(/[&<>"]/g,function(c){return({"&":"&amp;","<":"&lt;",">":"&gt;","\"":"&quot;"})[c];});}
function p2(n){return (n<10?"0":"")+n;}
function pts(s){if(!s)return NaN;return Date.parse(String(s).replace(" ","T"));}
function dec(d){if(!d||!d.k||d.__dec||!d.vals)return d;var k=+d.k;d.vals=d.vals.map(function(r){var o=[],i,j,v;for(i=0;i<r.length;i++){v=+r[i];if(v<0){for(j=0;j<-v;j++)o.push(0);}else{o.push(v/k);}}return o;});d.__dec=true;return d;}
function hm(t){var d=new Date(t);return p2(d.getHours())+":"+p2(d.getMinutes());}
function dayHm(t){var d=new Date(t);return DOW[d.getDay()]+" "+p2(d.getDate())+" "+hm(t);}
function rangeTxt(t,B){var a=new Date(t),b=new Date(t+B);if(B<86400000&&a.getDate()===b.getDate())return DOW[a.getDay()]+" "+p2(a.getDate())+" "+hm(t)+"-"+hm(t+B);return dayHm(t)+" to "+dayHm(t+B);}
function f2(v){if(v==null||isNaN(v))return "-";v=+v;return Math.abs(v)>=100?String(Math.round(v)):v.toFixed(2);}
function median(a){if(!a.length)return null;var b=a.slice().sort(function(x,y){return x-y;}),m=b.length>>1;return b.length%2?b[m]:(b[m-1]+b[m])/2;}
function lvlOf(z){if(z==null||isNaN(z))return "na";if(z>=ZX)return "x";if(z>=ZF)return "f";if(z>=ZR)return "r";return "n";}
var LVW={n:"normal",r:"raised",f:"far out",x:"far out (extreme)",na:"no data"};
/* resample one source series (t0 ms, bh ms, vals) onto the common grid */
function resample(vals,s0,bh,g0,B,nc){var acc=[],cov=[],j,i;for(j=0;j<nc;j++){acc.push(0);cov.push(0);}for(i=0;i<vals.length;i++){var a=s0+i*bh,b=a+bh,v=+vals[i]||0,j0=Math.max(0,Math.floor((a-g0)/B)),j1=Math.min(nc-1,Math.floor((b-1-g0)/B));for(j=j0;j<=j1;j++){var lo=Math.max(a,g0+j*B),hi=Math.min(b,g0+(j+1)*B);if(hi>lo){acc[j]+=v*(hi-lo);cov[j]+=hi-lo;}}}var out=[];for(j=0;j<nc;j++)out.push(cov[j]>=MINCOV*B?acc[j]/cov[j]:null);return out;}
function compute(){
  var cfg=window.FLEET_COANOM,A=window.FLEET_ASH||{};if(!cfg||!cfg.rows)return null;
  var rows=[],i,j,c;
  cfg.rows.forEach(function(r){var al=r[0],err=+r[1],d=err?null:dec(A[al]),ok=!!(d&&d.classes&&d.classes.length&&d.vals&&d.vals[0]&&d.vals[0].length&&!isNaN(pts(d.t0))&&(+d.bh)>0);rows.push({a:al,err:err,d:ok?d:null});});
  var data=rows.filter(function(r){return r.d;});
  if(!data.length)return {rows:rows,nd:0};
  var B=0,anchor=null,mn=Infinity,mx=-Infinity,bhs={};
  data.forEach(function(r){var bh=(+r.d.bh)*3600000,s0=pts(r.d.t0),e=s0+r.d.vals[0].length*bh;r.s0=s0;r.bh=bh;r.e=e;bhs[r.d.bh]=1;if(bh>B){B=bh;anchor=s0;}if(s0<mn)mn=s0;if(e>mx)mx=e;});
  var g0=anchor-Math.ceil((anchor-mn)/B-1e-9)*B,nc=Math.ceil((mx-g0)/B-1e-9);if(nc>MAXCOL){g0=mx-MAXCOL*B;nc=MAXCOL;}
  var spanH=(mx-g0)/3600000,phase=spanH>=24*PHDAYS&&B<86400000;
  function pkey(j){var d=new Date(g0+j*B+B/2);return d.getHours();}
  data.forEach(function(r){
    var d=r.d,cls=[],tot=[];
    for(c=0;c<d.classes.length;c++)cls.push(resample(d.vals[c],r.s0,r.bh,g0,B,nc));
    for(j=0;j<nc;j++){var t=null;for(c=0;c<cls.length;c++){if(cls[c][j]!=null)t=(t||0)+cls[c][j];}tot.push(t);}
    var grp={},all=[];for(j=0;j<nc;j++){if(tot[j]==null)continue;all.push(j);var k=phase?pkey(j):0;(grp[k]=grp[k]||[]).push(j);}
    function stats(idx){var v=idx.map(function(j){return tot[j];}),m=median(v),mad=median(v.map(function(x){return Math.abs(x-m);}));var cm=[];for(c=0;c<cls.length;c++)cm.push(median(idx.map(function(j){return cls[c][j]==null?0:cls[c][j];})));return {m:m,sd:Math.max(MADK*mad,FREL*Math.abs(m),FABS),n:v.length,cm:cm};}
    var stAll=all.length?stats(all):null,stG={};
    for(var k in grp){if(grp.hasOwnProperty(k))stG[k]=(phase&&grp[k].length>=PHMIN)?stats(grp[k]):null;}
    var cell=[],nf=0;
    for(j=0;j<nc;j++){if(tot[j]==null||!stAll){cell.push(null);continue;}var kk=phase?pkey(j):0,st=stG[kk]||stAll,z=(tot[j]-st.m)/st.sd,lv=lvlOf(z),top=null,tx=0;for(c=0;c<cls.length;c++){var ex=(cls[c][j]||0)-st.cm[c];if(ex>tx){tx=ex;top=d.classes[c];}}if(lv==="f"||lv==="x")nf++;cell.push({v:tot[j],m:st.m,sd:st.sd,n:st.n,z:z,lv:lv,top:top,tx:tx,ph:st!==stAll});}
    r.cell=cell;r.nf=nf;});
  var cnt=[],who=[];for(j=0;j<nc;j++){cnt.push(0);who.push([]);}
  data.forEach(function(r){for(j=0;j<nc;j++){var x=r.cell[j];if(x&&(x.lv==="f"||x.lv==="x")){cnt[j]++;who[j].push(r.a);}}});
  var nd=data.length,need=Math.max(2,Math.ceil(SHARE*nd)),shared=[];for(j=0;j<nc;j++)shared.push(nd>=2&&cnt[j]>=need);
  var zs=[];for(j=0;j<nc;j++){var zz=0;data.forEach(function(r){var x=r.cell[j];if(x&&(x.lv==="f"||x.lv==="x"))zz+=x.z;});zs.push(zz);}
  var eps=[];for(j=0;j<nc;j++){if(!shared[j])continue;var e=eps.length?eps[eps.length-1]:null;if(e&&e.b===j-1){e.b=j;}else{e={a:j,b:j,pk:j};eps.push(e);}if(cnt[j]>cnt[e.pk]||(cnt[j]===cnt[e.pk]&&zs[j]>zs[e.pk]))e.pk=j;}
  eps.sort(function(x,y){return (cnt[y.pk]-cnt[x.pk])||(zs[y.pk]-zs[x.pk])||(x.a-y.a);});
  var nbh=0;for(var q in bhs){if(bhs.hasOwnProperty(q))nbh++;}
  return {rows:rows,nd:nd,B:B,g0:g0,nc:nc,cnt:cnt,who:who,need:need,shared:shared,eps:eps,phase:phase,mixed:nbh>1};
}
function summary(R){
  if(R.nd<2)return "Co-anomaly needs 2 or more databases with ASH data; this fleet has "+R.nd+". The strip shows that one database against its own normal.";
  var j,mxc=0,mxj=-1;for(j=0;j<R.nc;j++){if(R.cnt[j]>mxc){mxc=R.cnt[j];mxj=j;}}
  if(R.eps.length){var e=R.eps[0],w=R.who[e.pk],nm=w.slice(0,6).map(esc).join(", ")+(w.length>6?", +"+(w.length-6)+" more":""),t=R.g0+e.a*R.B,len=(e.b-e.a+1)*R.B,k=R.eps.length-1;return "<b>"+esc(rangeTxt(t,len))+": "+R.cnt[e.pk]+" of "+R.nd+" databases abnormal at once</b> ("+nm+(e.b>e.a?"; peak "+esc(hm(R.g0+e.pk*R.B)):"")+") &mdash; look for a shared cause (storage, network, host, batch window)."+(k?" "+k+" other shared episode"+(k>1?"s are":" is")+" highlighted.":"");}
  if(mxc>=2)return "No bucket reached the threshold ("+R.need+" of "+R.nd+" databases); the largest overlap is "+mxc+" databases at "+esc(rangeTxt(R.g0+mxj*R.B,R.B))+" ("+R.who[mxj].map(esc).join(", ")+").";
  return "No bucket where two or more databases were abnormal together"+(mxc?"; the far-out cells are single databases on their own.":".");
}
function tipHtml(R,r,j){
  var t=R.g0+j*R.B,h="<b>"+esc(r.a)+"</b> &middot; "+esc(rangeTxt(t,R.B));
  if(r.err)return h+"<br>no data (the extract failed for this database)";
  if(!r.d)return h+"<br>no data (no ASH payload)";
  var x=r.cell[j];if(!x)return h+"<br>no data (bucket outside this database&#39;s span)";
  var lo=Math.max(0,x.m-2*x.sd),hi=x.m+2*x.sd;
  h+="<br>AAS <b>"+f2(x.v)+"</b> &middot; normal "+f2(lo)+"&ndash;"+f2(hi)+" (median "+f2(x.m)+", "+(x.ph?"same hour of day, ":"whole span, ")+x.n+" buckets)";
  h+="<br>z "+(x.z>=0?"+":"")+x.z.toFixed(1)+" &middot; "+LVW[x.lv];
  if(x.top&&x.lv!=="n")h+="<br>Excess mostly <b>"+esc(x.top)+"</b> (+"+f2(x.tx)+" AAS over its normal)";
  return h;
}
function colTip(R,j){var w=R.who[j];return "<b>"+esc(rangeTxt(R.g0+j*R.B,R.B))+"</b><br>"+R.cnt[j]+" of "+R.nd+" databases far out"+(w.length?": "+w.slice(0,12).map(esc).join(", ")+(w.length>12?", +"+(w.length-12)+" more":""):"")+(R.shared[j]?"<br>at or above the threshold ("+R.need+"); click to emphasise these databases":"");}
function ticks(R,cw){var B=R.B,minPx=64,step=[0.25,0.5,1,2,3,6,12,24,48,168].map(function(h){return h*3600000;}).filter(function(s){return s>=B&&s/B*cw>=minPx;})[0]||(Math.ceil(minPx/cw)*B),out=[],t0=R.g0,t1=R.g0+R.nc*B,d=new Date(t0);d.setHours(0,0,0,0);var t=d.getTime();while(t<t0)t+=step;for(;t<=t1;t+=step){var dd=new Date(t);out.push({x:(t-t0)/B*cw,l:(dd.getHours()===0&&dd.getMinutes()===0)||step>=86400000?DOW[dd.getDay()]+" "+p2(dd.getDate()):hm(t),day:dd.getHours()===0&&dd.getMinutes()===0});}return out;}
function rowOf(al){var rs=document.querySelectorAll("tr.dbrow");for(var i=0;i<rs.length;i++){if(rs[i].getAttribute("data-db")===al)return rs[i];}return null;}
function openDb(al){var tr=rowOf(al);if(!tr)return;if(tr.hidden){var f=document.getElementById("dbFilter");if(f&&f.value){f.value="";f.dispatchEvent(new Event("input"));}}if(window.__fleetSetRowOpen)window.__fleetSetRowOpen(tr,true);else if(!tr.classList.contains("open"))tr.click();tr.scrollIntoView({block:"start",behavior:"smooth"});tr.classList.add("ca-flash");setTimeout(function(){tr.classList.remove("ca-flash");},1600);try{tr.focus({preventScroll:true});}catch(e){}}
function render(){
  var host=document.getElementById("coanom");if(!host)return;var box=host.querySelector(".ca-body");if(!box)return;
  if(!S)S={R:compute(),sel:-1,cur:{r:0,c:0}};var R=S.R;host.classList.add("ca-js");
  var sum=host.querySelector(".ca-sum");
  if(!R||!R.nd){box.innerHTML="";if(sum)sum.innerHTML="No database shipped an ASH payload, so there is nothing to line up in time.";return;}
  var rows=R.rows,n=rows.length,rh=n>24?12:(n>12?14:17),fs=n>24?10:11,FL=16,BA=30,GAP=6,H0=FL+BA+GAP,AX=18,H=H0+n*rh+AX;
  var scr=box.querySelector(".ca-scroll"),lab,cntc;
  if(!scr){box.innerHTML="<div class=\"ca-lab\"></div><div class=\"ca-scroll\"></div><div class=\"ca-cnt\"></div>";scr=box.querySelector(".ca-scroll");}
  lab=box.querySelector(".ca-lab");cntc=box.querySelector(".ca-cnt");
  var lh="<div class=\"ca-lh\" style=\"height:"+H0+"px\"><span style=\"bottom:"+(GAP+2)+"px\">DBs far out</span></div>";
  var ch="<div class=\"ca-lh\" style=\"height:"+H0+"px\"><span style=\"bottom:"+(GAP+2)+"px\" title=\"far-out buckets per database\">far out</span></div>";
  for(i=0;i<n;i++){var rr=rows[i],dm=S.sel>=0&&!(rr.cell&&rr.cell[S.sel]&&(rr.cell[S.sel].lv==="f"||rr.cell[S.sel].lv==="x")),st=rr.err?"extract failed, no data":(rr.d?rr.nf+" far-out bucket"+(rr.nf===1?"":"s"):"no ASH payload");
    lh+="<button type=\"button\" class=\"ca-rl"+(dm?" dim":"")+(rr.cell?"":" nd")+"\" data-db=\""+esc(rr.a)+"\" style=\"height:"+rh+"px;font-size:"+fs+"px\" title=\""+esc(rr.a)+": "+st+". Open its row.\" aria-label=\""+esc(rr.a)+", "+st+". Open its row in the table.\">"+esc(rr.a)+(rr.cell?"":" <i>no data</i>")+"</button>";
    ch+="<div class=\"ca-rc"+(dm?" dim":"")+(rr.nf?" hit":"")+"\" style=\"height:"+rh+"px;font-size:"+fs+"px\">"+(rr.cell?rr.nf:"&ndash;")+"</div>";}
  lab.innerHTML=lh;cntc.innerHTML=ch;
  var avail=scr.clientWidth||600,cw=Math.max(4,Math.min(28,Math.floor(avail/R.nc))),W=cw*R.nc,j,i;
  S.cw=cw;S.rh=rh;S.H0=H0;
  var maxc=1;for(j=0;j<R.nc;j++)if(R.cnt[j]>maxc)maxc=R.cnt[j];
  var s="<svg class=\"ca-svg\" width=\""+W+"\" height=\""+H+"\" viewBox=\"0 0 "+W+" "+H+"\" tabindex=\"0\" role=\"application\" aria-roledescription=\"co-anomaly grid\" aria-label=\""+n+" databases by "+R.nc+" time buckets. Arrow keys move between cells, Enter opens that database&#39;s row.\" aria-describedby=\"ca-live\">";
  s+="<defs><pattern id=\"ca-hatch\" width=\"4\" height=\"4\" patternUnits=\"userSpaceOnUse\" patternTransform=\"rotate(45)\"><rect width=\"4\" height=\"4\" class=\"ca-hb\"/><line x1=\"0\" y1=\"0\" x2=\"0\" y2=\"4\" class=\"ca-hl2\"/></pattern></defs>";
  for(j=0;j<R.nc;j++){if(R.shared[j])s+="<rect class=\"ca-colhl"+(S.sel===j?" on":"")+"\" x=\""+(j*cw)+"\" y=\""+FL+"\" width=\""+cw+"\" height=\""+(BA+GAP+n*rh)+"\"/>";}
  ticks(R,cw).forEach(function(t){if(t.day)s+="<line class=\"ca-day\" x1=\""+t.x.toFixed(1)+"\" x2=\""+t.x.toFixed(1)+"\" y1=\""+FL+"\" y2=\""+(H0+n*rh)+"\"/>";s+="<line class=\"ca-tk\" x1=\""+t.x.toFixed(1)+"\" x2=\""+t.x.toFixed(1)+"\" y1=\""+(H0+n*rh)+"\" y2=\""+(H0+n*rh+3)+"\"/>";var anc=t.x<20?"start":(t.x>W-24?"end":"middle");s+="<text class=\"ca-ax\" x=\""+t.x.toFixed(1)+"\" y=\""+(H-4)+"\" text-anchor=\""+anc+"\">"+esc(t.l)+"</text>";});
  s+="<line class=\"ca-base\" x1=\"0\" x2=\""+W+"\" y1=\""+(FL+BA)+"\" y2=\""+(FL+BA)+"\"/>";
  var pk={};R.eps.forEach(function(e){pk[e.pk]=1;});var lastL=-99;for(j=0;j<R.nc;j++){var c=R.cnt[j];if(!c)continue;var bh2=Math.max(2,Math.round(c/maxc*(BA-11))),bx=j*cw+(cw>5?1:0),bw=cw>5?cw-2:cw;s+="<g class=\"ca-bar"+(R.shared[j]?" sh":"")+"\" data-c=\""+j+"\""+(R.shared[j]?" tabindex=\"0\" role=\"button\" aria-pressed=\""+(S.sel===j)+"\" aria-label=\""+esc(rangeTxt(R.g0+j*R.B,R.B))+": "+c+" of "+R.nd+" databases far out. Emphasise them.\"":"")+"><rect x=\""+bx+"\" y=\""+(FL+BA-bh2)+"\" width=\""+bw+"\" height=\""+bh2+"\" rx=\"1\"/>";var lx=j*cw+cw/2;if((cw>=14||(R.shared[j]&&(cw>=10||pk[j])))&&lx-lastL>=13){lastL=lx;s+="<text class=\"ca-bn\" x=\""+(j*cw+cw/2).toFixed(1)+"\" y=\""+(FL+BA-bh2-2)+"\" text-anchor=\"middle\">"+c+"</text>";}s+="</g>";}
  var dotR=Math.min(cw,rh)>=9?1.6:0;
  for(i=0;i<n;i++){var r=rows[i],y=H0+i*rh,dim=S.sel>=0&&!(r.cell&&r.cell[S.sel]&&(r.cell[S.sel].lv==="f"||r.cell[S.sel].lv==="x"));s+="<g class=\"ca-row"+(dim?" dim":"")+"\">";
    if(!r.cell){s+="<rect class=\"ca-na\" x=\"0\" y=\""+(y+0.5)+"\" width=\""+W+"\" height=\""+(rh-1)+"\" style=\"fill:url(#ca-hatch)\"/>";}
    else{for(j=0;j<R.nc;j++){var x=r.cell[j],cx=j*cw+(cw>4?0.5:0),ww=cw>4?cw-1:cw;if(!x){s+="<rect x=\""+cx+"\" y=\""+(y+0.5)+"\" width=\""+ww+"\" height=\""+(rh-1)+"\" style=\"fill:url(#ca-hatch)\"/>";continue;}s+="<rect class=\"ca-"+x.lv+"\" x=\""+cx+"\" y=\""+(y+0.5)+"\" width=\""+ww+"\" height=\""+(rh-1)+"\"/>";if(dotR&&(x.lv==="f"||x.lv==="x"))s+="<circle class=\"ca-g\" cx=\""+(j*cw+cw/2).toFixed(1)+"\" cy=\""+(y+rh/2).toFixed(1)+"\" r=\""+(x.lv==="x"?dotR+0.8:dotR)+"\"/>";}}
    s+="</g>";}
  var M=window.FLEET_MARKERS||[],mks=[];M.forEach(function(m,k){var t=pts(m.t);if(isNaN(t)||t<R.g0||t>R.g0+R.nc*R.B)return;mks.push({m:m,k:k,x:(t-R.g0)/R.B*cw});});mks.sort(function(a,b){return a.x-b.x;});var lastR=-1e9;mks.forEach(function(o){var m=o.m,k=o.k,mx=o.x,col=k%2?"var(--warn)":"var(--accent)",lw=String(m.l).length*5.6+10,right=mx>W-lw-4,l0=right?mx-lw:mx,showL=l0>lastR+4;if(showL)lastR=right?mx:mx+lw;s+="<g class=\"ca-mk\" style=\"color:"+col+"\"><title>"+esc(m.l)+" &middot; "+esc(m.t)+"</title><line x1=\""+mx.toFixed(1)+"\" x2=\""+mx.toFixed(1)+"\" y1=\"3\" y2=\""+(H0+n*rh)+"\"/><path d=\"M"+mx.toFixed(1)+" 2l6 3.5-6 3.5z\"/><text x=\""+(mx+(right?-3:8)).toFixed(1)+"\" y=\"10\" text-anchor=\""+(right?"end":"start")+"\">"+(showL?esc(m.l):"")+"</text></g>";});
  s+="<rect class=\"ca-cur\" x=\"-99\" y=\"-99\" width=\""+cw+"\" height=\""+rh+"\"/></svg>";
  scr.innerHTML=s;
  var lf=host.querySelector(".ca-filt");if(lf){if(S.sel>=0){lf.hidden=false;lf.querySelector(".ca-ft").innerHTML="Emphasising the "+R.cnt[S.sel]+" databases far out at <b>"+esc(rangeTxt(R.g0+S.sel*R.B,R.B))+"</b> (marked in the table too).";}else{lf.hidden=true;}}
  if(sum)sum.innerHTML=summary(R);
  var meta=host.querySelector(".ca-meta");if(meta)meta.innerHTML="Bucket "+(R.B>=3600000?f2(R.B/3600000).replace(/\.?0+$/,"")+" h":Math.round(R.B/60000)+" min")+(R.mixed?" (databases with finer buckets resampled to the coarsest, time-weighted)":"")+" &middot; baseline per database: "+(R.phase?"same hour of day over the span":"the whole span")+" &middot; "+(R.nd>=2?"highlight: "+R.need+" or more of "+R.nd+" databases far out at once ("+Math.round(SHARE*100)+"%, at least 2)":"co-anomaly needs 2 or more databases")+" &middot; far out = robust z &ge; "+ZF+" (median and MAD, sigma at least "+Math.round(FREL*100)+"% of the median and "+FABS+" AAS)";
  S.W=W;S.n=n;
  if(!S.scrolled&&W>scr.clientWidth){S.scrolled=true;var fx=R.eps.length?R.eps[0].pk*cw:W;scr.scrollLeft=Math.max(0,Math.min(W-scr.clientWidth,fx-scr.clientWidth/2));}
  markTable();
  if(S.focus)moveCur(S.cur.r,S.cur.c,true);
}
function markTable(){var R=S.R,rs=document.querySelectorAll("tr.dbrow");for(var i=0;i<rs.length;i++){var al=rs[i].getAttribute("data-db"),hit=false;if(S.sel>=0){R.rows.forEach(function(r){if(r.a===al&&r.cell&&r.cell[S.sel]&&(r.cell[S.sel].lv==="f"||r.cell[S.sel].lv==="x"))hit=true;});}rs[i].classList.toggle("ca-hit",hit);}}
var tip=null;
function showTip(html,x,y){if(!tip){tip=document.createElement("div");tip.className="ca-tip";tip.setAttribute("role","tooltip");document.body.appendChild(tip);}tip.innerHTML=html;tip.style.display="block";var w=tip.offsetWidth,h=tip.offsetHeight,vw=document.documentElement.clientWidth,vh=window.innerHeight,lx=x+14,ly=y+14;if(lx+w>vw-6)lx=Math.max(6,x-w-14);if(ly+h>vh-6)ly=Math.max(6,y-h-14);tip.style.left=lx+"px";tip.style.top=ly+"px";}
function hideTip(){if(tip)tip.style.display="none";}
function live(html){var l=document.getElementById("ca-live");if(l){var d=document.createElement("div");d.innerHTML=html.replace(/<br>/g,". ");l.textContent=d.textContent;}}
function moveCur(r,c,quiet){var R=S.R;r=Math.max(0,Math.min(S.n-1,r));c=Math.max(0,Math.min(R.nc-1,c));S.cur={r:r,c:c};var svg=document.querySelector("#coanom .ca-svg");if(!svg)return;var cur=svg.querySelector(".ca-cur");cur.setAttribute("x",c*S.cw);cur.setAttribute("y",S.H0+r*S.rh);var html=tipHtml(R,R.rows[r],c);live(html);if(!quiet){var sc=svg.parentNode,x0=c*S.cw;if(x0<sc.scrollLeft)sc.scrollLeft=x0-20;else if(x0+S.cw>sc.scrollLeft+sc.clientWidth)sc.scrollLeft=x0+S.cw-sc.clientWidth+20;var b=cur.getBoundingClientRect();showTip(html,b.right,b.bottom);}}
function hit(ev){var svg=ev.target.closest?ev.target.closest(".ca-svg"):null;if(!svg)return null;var b=svg.getBoundingClientRect(),x=ev.clientX-b.left,y=ev.clientY-b.top,c=Math.floor(x/S.cw),r=Math.floor((y-S.H0)/S.rh);if(c<0||c>=S.R.nc)return null;if(y<S.H0)return {col:c};if(r<0||r>=S.n)return null;return {r:r,c:c};}
function setSel(j){S.sel=(j===S.sel)?-1:j;render();var b=document.querySelector("#coanom .ca-bar[data-c=\""+j+"\"]");if(b&&S.sel>=0)try{b.focus({preventScroll:true});}catch(e){}}
function wire(){
  var host=document.getElementById("coanom");if(!host||host.__caw)return;host.__caw=true;
  host.addEventListener("mousemove",function(ev){if(!S||!S.R||!S.R.nd)return;var bar=ev.target.closest?ev.target.closest(".ca-bar"):null;if(bar){showTip(colTip(S.R,+bar.getAttribute("data-c")),ev.clientX,ev.clientY);return;}var h=hit(ev);if(!h){hideTip();return;}if(h.col!=null){var cc=S.R.cnt[h.col];if(cc)showTip(colTip(S.R,h.col),ev.clientX,ev.clientY);else hideTip();return;}showTip(tipHtml(S.R,S.R.rows[h.r],h.c),ev.clientX,ev.clientY);});
  host.addEventListener("mouseleave",hideTip);
  host.addEventListener("click",function(ev){if(!S||!S.R)return;var t=ev.target;var rl=t.closest?t.closest(".ca-rl"):null;if(rl){openDb(rl.getAttribute("data-db"));return;}if(t.closest&&t.closest(".ca-clear")){S.sel=-1;render();return;}var bar=t.closest?t.closest(".ca-bar.sh"):null;if(bar){setSel(+bar.getAttribute("data-c"));return;}var h=hit(ev);if(!h)return;if(h.col!=null){if(S.R.shared[h.col])setSel(h.col);return;}S.cur={r:h.r,c:h.c};openDb(S.R.rows[h.r].a);});
  host.addEventListener("keydown",function(ev){if(!S||!S.R)return;var t=ev.target;if(t.classList&&t.classList.contains("ca-svg")){var r=S.cur.r,c=S.cur.c,k=ev.key,step=ev.shiftKey?6:1;if(k==="ArrowRight")c+=step;else if(k==="ArrowLeft")c-=step;else if(k==="ArrowDown")r++;else if(k==="ArrowUp")r--;else if(k==="Home")c=0;else if(k==="End")c=S.R.nc-1;else if(k==="PageUp")r=0;else if(k==="PageDown")r=S.n-1;else if(k==="Enter"||k===" "){ev.preventDefault();openDb(S.R.rows[S.cur.r].a);return;}else if(k==="Escape"){if(S.sel>=0){S.sel=-1;render();}hideTip();return;}else return;ev.preventDefault();moveCur(r,c);return;}var bar=t.closest?t.closest(".ca-bar.sh"):null;if(bar&&(ev.key==="Enter"||ev.key===" ")){ev.preventDefault();setSel(+bar.getAttribute("data-c"));return;}if(ev.key==="Escape"&&S.sel>=0){S.sel=-1;render();}});
  host.addEventListener("focusin",function(ev){var t=ev.target;if(t.classList&&t.classList.contains("ca-svg")){S.focus=true;moveCur(S.cur.r,S.cur.c);}else if(t.closest&&t.closest(".ca-bar")){var b=t.getBoundingClientRect();showTip(colTip(S.R,+t.getAttribute("data-c")),b.right,b.bottom);}});
  host.addEventListener("focusout",function(ev){var t=ev.target;if(t.classList&&t.classList.contains("ca-svg")){S.focus=false;var cur=t.querySelector(".ca-cur");if(cur){cur.setAttribute("x",-99);cur.setAttribute("y",-99);}}hideTip();});
  document.addEventListener("keydown",function(ev){if(ev.key==="Escape"&&S&&S.sel>=0&&!(ev.target.closest&&ev.target.closest("#coanom"))){S.sel=-1;render();}});
  var tmr=null,lw=0;window.addEventListener("resize",function(){if(tmr)clearTimeout(tmr);tmr=setTimeout(function(){var sc=document.querySelector("#coanom .ca-scroll");var w=sc?sc.clientWidth:0;if(w&&w!==lw){lw=w;render();}},150);});
}
function boot(){try{render();wire();}catch(e){var h=document.getElementById("coanom");if(h){var s=h.querySelector(".ca-sum");if(s)s.textContent="The co-anomaly grid could not be drawn: "+e.message;}if(window.console)console.error(e);}}
if(document.readyState==="loading")document.addEventListener("DOMContentLoaded",boot);else boot();
window.AWR_FLEET_COANOM={compute:compute,render:render};
})();
