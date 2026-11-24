// js_onset: client half of section 25_onset (Trend breaks).
// Draws AWR_DATA.onset (one metric at a time, picked with the tab row):
// the series over its seasonal band with the compared windows, release
// markers and the detected onset; below it the CUSUM strip with its
// threshold.  Adds "2 h after Release 4.2" to the Reads-as sentence.
// Inline SVG only, colours from CSS classes; works with the CDN blocked.
(function(){
'use strict';
var D=window.AWR_DATA&&window.AWR_DATA.onset,doc=document,sec=doc.getElementById('onset');
if(!D||!sec||!D.m||!D.m.length)return;
var viz=sec.querySelector('.onset-viz'),plot=doc.getElementById('onset-plot');
if(!viz||!plot)return;
var btns=[].slice.call(sec.querySelectorAll('.onset-b'));
viz.hidden=false;sec.classList.add('onset-js');
var NS='http://www.w3.org/2000/svg',MIN=60000,HOUR=3600000,DAY=86400000;
/* local wall-clock strings as UTC-naive milliseconds (no DST games) */
function P(s){var m=/^(\d{4})-(\d\d)-(\d\d) (\d\d):(\d\d)/.exec(String(s||''));return m?Date.UTC(+m[1],m[2]-1,+m[3],+m[4],+m[5]):NaN;}
var bm=D.bm*MIN,nb=D.nb,t1=P(D.t1),t0=t1-nb*bm,tc=P(D.tc),SPAN=t1-t0;
var DN=['Sun','Mon','Tue','Wed','Thu','Fri','Sat'],MN=['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
function two(n){return (n<10?'0':'')+n;}
function hm(t){var d=new Date(t);return two(d.getUTCHours())+':'+two(d.getUTCMinutes());}
function dm(t){var d=new Date(t);return d.getUTCDate()+' '+MN[d.getUTCMonth()];}
function dy(t){return DN[new Date(t).getUTCDay()];}
function dt(t){return dy(t)+' '+dm(t)+' '+hm(t);}
function dur(ms){var m=Math.abs(ms)/MIN;if(m<60)return Math.round(m)+' min';if(m<2880){var h=m/60;return (m<600?Math.round(h*10)/10:Math.round(h))+' h';}return Math.round(m/1440)+' days';}
function fmt(v){if(v==null||isNaN(v))return '-';var a=Math.abs(v),u='';
  if(a>=1e9){v/=1e9;u=' G';}else if(a>=1e6){v/=1e6;u=' M';}else if(a>=1e4){v/=1e3;u=' k';}
  a=Math.abs(v);var d=a===0?0:a>=100?1:a>=10?2:a>=1?3:4;return String(+v.toFixed(d))+u;}
function esc(s){return String(s).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;');}
function el(n,a,p){var e=doc.createElementNS(NS,n);for(var k in a)if(a[k]!=null)e.setAttribute(k,a[k]);if(p)p.appendChild(e);return e;}
function tx(p,x,y,s,c,anc){var e=el('text',{x:x.toFixed(1),y:y.toFixed(1),'class':c||'o-t','text-anchor':anc||'start'},p);e.textContent=s;return e;}
/* rendered text width (falls back to an estimate when not laid out) */
function tw(t,s){var w=0;try{w=t.getComputedTextLength();}catch(e){}return w>0?w:s.length*6.2;}
function num(v){return v==null||v===''||isNaN(v)?null:+v;}
function tS(i){return t0+i*bm;}
/* release markers inside the span */
var MKS=[];
(window.AWR_MARKERS||[]).forEach(function(m){var t=P(m.t);if(!isNaN(t)&&t>=t0&&t<=t1)MKS.push({t:t,l:String(m.label||'')});});
MKS.sort(function(a,b){return a.t-b.t;});
/* the compared windows */
var WINS=[];
((window.AWR_WIN&&window.AWR_WIN.w)||[]).forEach(function(w){var s=P(w.s),e=P(w.e);if(isNaN(s)||isNaN(e)||e<=t0||s>=t1)return;WINS.push({s:Math.max(s,t0),e:Math.min(e,t1),o:w.o,v:w.v,t:w.t});});
/* the nearest release marker to an onset, within 6 h */
var TOL=6*HOUR;
function near(t){var best=null;MKS.forEach(function(m){var d=t-m.t;if(Math.abs(d)<=TOL&&(!best||Math.abs(d)<Math.abs(best.d)))best={d:d,l:m.l};});return best;}
function rel(t){var n=near(t);if(!n)return '';if(Math.abs(n.d)<MIN)return 'at '+n.l;return dur(n.d)+' '+(n.d>0?'after ':'before ')+n.l;}
function onsetOf(m){if(m.on)return m.on[0];if(m.cl)return m.cl[0];return null;}
/* Reads as: the lead metric's onset next to a marker */
(function(){var mk=sec.querySelector('.onset-mk');if(!mk||D.lead==null)return;var m=D.m[D.lead],a=onsetOf(m);if(a==null)return;var r=rel(tS(a));if(r)mk.textContent=' ('+r+')';})();
var cur=D.lead!=null?D.lead:0,curI=null,lastW=0,G=null,zPref=null;
/* the time range: the whole span, or around the picked metric's shift
   (a 3-month span puts a 2-day shift in the last few pixels) */
var zb=doc.createElement('div');zb.className='onset-zoom';zb.setAttribute('role','group');zb.setAttribute('aria-label','Time range');
zb.innerHTML='<button type="button" data-z="0">Whole span</button><button type="button" data-z="1">Around the shift</button>';
plot.parentNode.insertBefore(zb,plot);
var zbs=[].slice.call(zb.querySelectorAll('button'));
zbs.forEach(function(b){b.addEventListener('click',function(){zPref=+b.getAttribute('data-z');uncursor();draw();});});
function exOf(m){return m.on?[m.on[0],nb-1,m.on[2],1]:m.cl?[m.cl[0],m.cl[1],m.cl[2],0]:null;}
function zoomDom(m){var ex=exOf(m);if(!ex)return null;var a=tS(ex[0]),e=tS(ex[1])+bm,L=Math.max(e-a,24*bm,12*HOUR);
  var d0=Math.max(t0,a-L),d1=ex[3]?t1:Math.min(t1,e+L);return d1-d0<0.8*SPAN?[d0,d1]:null;}
/* nice tick step for a value axis */
function nice(mx){if(!(mx>0))return 1;var r=mx/4,p=Math.pow(10,Math.floor(Math.log(r)/Math.LN10)),f=r/p;return (f<=1?1:f<=2?2:f<=2.5?2.5:f<=5?5:10)*p;}
function segs(arr,fx,fy,close){/* polyline segments over consecutive non-null points */
  var d='',on=false;for(var i=0;i<nb;i++){var v=fy(i);if(v==null){on=false;continue;}d+=(on?'L':'M')+fx(i).toFixed(1)+' '+v.toFixed(1);on=true;}return d;}
function bandPath(m,X,Y){var d='',i=0;
  while(i<nb){while(i<nb&&num(m.md[i])==null)i++;if(i>=nb)break;var a=i;while(i<nb&&num(m.md[i])!=null)i++;var b=i-1,k,up='',lo='';
    for(k=a;k<=b;k++){var c=num(m.md[k]),s=num(m.s[k])||0,xx=X(k).toFixed(1);up+=(k===a?'M':'L')+xx+' '+Y(c+2*s).toFixed(1);}
    for(k=b;k>=a;k--){var c2=num(m.md[k]),s2=num(m.s[k])||0;lo+='L'+X(k).toFixed(1)+' '+Y(Math.max(0,c2-2*s2)).toFixed(1);}
    d+=up+lo+'Z';}
  return d;}
function draw(){
  var W=plot.clientWidth;if(W<40)return;lastW=W;
  var m=D.m[cur],x=m.x||[],H,padL=Math.max(46,Math.min(64,W*0.09)),padR=12;
  var flagH=MKS.length?30:6,T1=flagH+8,B1=T1+(W<520?150:180),T2=B1+22,B2=T2+64;H=B2+34;
  var zd=zoomDom(m),ex0=exOf(m),zon=!!zd&&(zPref!=null?zPref===1:(ex0&&(tS(ex0[1])+bm-tS(ex0[0]))<0.06*SPAN));
  zbs.forEach(function(b){var z=b.getAttribute('data-z')==='1';b.setAttribute('aria-pressed',z===zon?'true':'false');if(z)b.disabled=!zd;});
  var Z0=zon?zd[0]:t0,Z1=zon?zd[1]:t1,ZS=Z1-Z0;
  var pw=W-padL-padR,X=function(i){return padL+(tS(i)+bm/2-Z0)/ZS*pw;},XT=function(t){return padL+(t-Z0)/ZS*pw;};
  var mx=0,i;
  for(i=0;i<nb;i++){if(tS(i)+bm<Z0||tS(i)>Z1)continue;var v=num(x[i]);if(v!=null&&v>mx)mx=v;var c=num(m.md[i]);if(c!=null){var s=num(m.s[i])||0;if(c+2*s>mx)mx=c+2*s;}}
  var st=nice(mx||1),top=Math.ceil((mx||1)/st)*st;if(top<=0)top=1;
  var Y=function(v){return B1-(B1-T1)*Math.max(0,Math.min(v,top*1.15))/top;};
  var cap=(D.h||5)+3,Y2=function(v){return (T2+B2)/2-(B2-T2)/2*Math.max(-cap,Math.min(cap,v))/cap;};
  plot.innerHTML='';
  var svg=el('svg',{width:W,height:H,viewBox:'0 0 '+W+' '+H,role:'img','aria-label':m.n+': '+(m.st==='open'?'open shift since '+dt(tS(m.on[0])):m.st==='closed'?'closed excursion from '+dt(tS(m.cl[0])):m.st==='none'?'no shift':'too little history')},plot);
  var defs=el('defs',{},svg),cl=el('clipPath',{id:'onset-clip'},defs);el('rect',{x:padL,y:T1-2,width:pw,height:B1-T1+2},cl);
  el('rect',{x:padL,y:T2-1,width:pw,height:B2-T2+2},el('clipPath',{id:'onset-clip2'},defs));
  el('rect',{x:padL,y:0,width:pw,height:B2},el('clipPath',{id:'onset-clip3'},defs));
  var inX=function(xx){return xx>=padL-0.5&&xx<=padL+pw+0.5;};
  /* windows */
  var gw=el('g',{'class':'o-wins','clip-path':'url(#onset-clip3)'},svg);
  WINS.forEach(function(w){var a=XT(w.s),b=XT(w.e);el('rect',{x:a.toFixed(1),y:T1,width:Math.max(1.5,b-a).toFixed(1),height:B1-T1,'class':'o-w'+(w.o===0?' cur':'')+(w.v==='N'?' sk':'')},gw);
    el('rect',{x:a.toFixed(1),y:T2,width:Math.max(1.5,b-a).toFixed(1),height:B2-T2,'class':'o-w2'+(w.o===0?' cur':'')},gw);});
  /* value grid */
  for(var g=0;g<=top+1e-9;g+=st){var yy=Y(g);el('line',{x1:padL,x2:W-padR,y1:yy.toFixed(1),y2:yy.toFixed(1),'class':g?'o-g':'o-ax'},svg);tx(svg,padL-6,yy+3.5,fmt(g),'o-t','end');}
  tx(svg,padL,T1-4,m.u,'o-t o-u');
  /* time axis */
  var steps=[15,30,60,120,180,360,720,1440,2880,4320,10080,20160,40320],sm=steps[steps.length-1]*MIN;
  for(i=0;i<steps.length;i++){if(pw*steps[i]*MIN/ZS>=(steps[i]<1440?62:54)){sm=steps[i]*MIN;break;}}
  var tk=sm>=7*DAY?Math.ceil((Z0-4*DAY)/sm)*sm+4*DAY:Math.ceil(Z0/sm)*sm,last=-1e9,ticks=[],mid=false,t;
  for(t=tk;t<=Z1;t+=sm){ticks.push(t);if(t%DAY===0)mid=true;}
  ticks.forEach(function(t,k){var xx=XT(t);el('line',{x1:xx.toFixed(1),x2:xx.toFixed(1),y1:T1,y2:B1,'class':'o-g'},svg);el('line',{x1:xx.toFixed(1),x2:xx.toFixed(1),y1:T2,y2:B2,'class':'o-g'},svg);el('line',{x1:xx.toFixed(1),x2:xx.toFixed(1),y1:B2,y2:B2+4,'class':'o-ax'},svg);
    var lab,c2='o-t';if(sm>=DAY)lab=dm(t);else if(t%DAY===0){lab=dy(t)+' '+dm(t);c2='o-t o-d';}else lab=(!mid&&!k?dy(t)+' '+dm(t)+' ':'')+hm(t);
    var w2=lab.length*6.1,an='middle',lx=xx;if(lx-w2/2<padL-padL*0.5){an='start';lx=Math.max(xx-4,2);}if(lx+w2/2>W-2){an='end';lx=W-2;}
    var l0=an==='start'?lx:an==='end'?lx-w2:lx-w2/2;if(l0<last+8)return;last=l0+w2;tx(svg,lx,B2+16,lab,c2,an);});
  /* band, normal, series */
  var gp=el('g',{'clip-path':'url(#onset-clip)'},svg);
  el('path',{d:bandPath(m,X,Y),'class':'o-band'},gp);
  el('path',{d:segs(m.md,X,function(i){var c=num(m.md[i]);return c==null?null:Y(c);}),'class':'o-md'},gp);
  /* the excursion's span (light) */
  var ex=ex0;
  if(ex){var ea=XT(tS(ex[0])),eb=XT(tS(ex[1])+bm);el('rect',{x:ea.toFixed(1),y:T1,width:Math.max(1,eb-ea).toFixed(1),height:B1-T1,'class':'o-ex'+(ex[3]?' open':'')},gp);}
  el('path',{d:segs(x,X,function(i){var v=num(x[i]);return v==null?null:Y(v);}),'class':'o-ln'},gp);
  for(i=0;i<nb;i++){if(num(x[i])!=null&&(i===0||num(x[i-1])==null)&&(i===nb-1||num(x[i+1])==null))el('circle',{cx:X(i).toFixed(1),cy:Y(+x[i]).toFixed(1),r:1.8,'class':'o-pt'},gp);}
  /* CUSUM strip */
  var hh=D.h||5;
  el('line',{x1:padL,x2:W-padR,y1:Y2(0),y2:Y2(0),'class':'o-ax'},svg);
  [hh,-hh].forEach(function(v){el('line',{x1:padL,x2:W-padR,y1:Y2(v).toFixed(1),y2:Y2(v).toFixed(1),'class':'o-th'},svg);});
  tx(svg,padL-6,Y2(hh)+3.5,'+'+hh,'o-t','end');tx(svg,padL-6,Y2(0)+3.5,'0','o-t','end');tx(svg,padL-6,Y2(-hh)+3.5,'-'+hh,'o-t','end');
  tx(svg,padL,T2-5,'CUSUM, spreads (threshold '+hh+')','o-t o-u');
  var cc=m.c||[];
  function area(sign){var d='',a=-1,k;for(k=0;k<=nb;k++){var v=k<nb?num(cc[k]):null;if(v!=null){if(a<0)a=k;}else if(a>=0){var p='M'+X(a).toFixed(1)+' '+Y2(0).toFixed(1);for(var j=a;j<k;j++){var q=+cc[j]/10;p+='L'+X(j).toFixed(1)+' '+Y2(sign>0?Math.max(0,q):Math.min(0,q)).toFixed(1);}p+='L'+X(k-1).toFixed(1)+' '+Y2(0).toFixed(1)+'Z';d+=p;a=-1;}}return d;}
  var gc=el('g',{'clip-path':'url(#onset-clip2)'},svg);el('path',{d:area(1),'class':'o-cu'},gc);el('path',{d:area(-1),'class':'o-cd'},gc);
  /* the steps the scan found: a small triangle at each onset, above the strip */
  (m.sp||[]).forEach(function(q){var sx=XT(tS(q[0]));if(!inX(sx))return;var y0=T2-1,up=q[2]>0;
    var tg=el('path',{d:'M'+(sx-3.5).toFixed(1)+' '+(up?y0:y0-6)+'L'+(sx+3.5).toFixed(1)+' '+(up?y0:y0-6)+'L'+sx.toFixed(1)+' '+(up?y0-6:y0)+'Z','class':'o-st'+(up?' up':' dn')},svg);
    el('title',{},tg).textContent='step '+(up?'up':'down')+' from '+dt(tS(q[0]))+', found '+dt(tS(q[1]))+'; level '+(q[3]>=0?'+':'')+(q[3]/10).toFixed(1)+' spreads';});
  /* release markers: a line through both panels, flags in two tiers */
  var tiers=[-1e9,-1e9];
  MKS.forEach(function(mk){var xx=XT(mk.t);if(!inX(xx))return;el('line',{x1:xx.toFixed(1),x2:xx.toFixed(1),y1:T1-2,y2:B2,'class':'o-mkl'},svg);
    var gt=el('g',{'class':'o-flag'},svg);el('title',{},gt).textContent=mk.l+' ('+dt(mk.t)+')';
    var fr=el('rect',{height:13,rx:2,'class':'o-fb'},gt),ft=tx(gt,0,0,mk.l,'o-t o-ft'),w2=tw(ft,mk.l)+10;
    var lx=Math.max(2,Math.min(xx,W-padR-w2)),tr=tiers[0]<lx-4?0:tiers[1]<lx-4?1:-1;
    if(tr<0){gt.removeChild(fr);gt.removeChild(ft);el('circle',{cx:xx.toFixed(1),cy:T1-3,r:2.5,'class':'o-mkd'},gt);return;}
    tiers[tr]=lx+w2;var fy=2+tr*14;fr.setAttribute('x',lx.toFixed(1));fr.setAttribute('y',fy);fr.setAttribute('width',w2.toFixed(1));
    ft.setAttribute('x',(lx+5).toFixed(1));ft.setAttribute('y',fy+10);});
  /* the onset rule */
  if(m.on&&m.on[1]<m.on[0]){var bx=XT(tS(m.on[1]));if(inX(bx)){var bl=el('g',{'class':'o-onl'},svg);el('title',{},bl).textContent='the shift this one sits on began '+dt(tS(m.on[1]))+(rel(tS(m.on[1]))?', '+rel(tS(m.on[1])):'');
    el('line',{x1:bx.toFixed(1),x2:bx.toFixed(1),y1:T1,y2:B2,'class':'o-on base'},bl);}}
  if(ex&&inX(XT(tS(ex[0])))){var ox=XT(tS(ex[0]));el('line',{x1:ox.toFixed(1),x2:ox.toFixed(1),y1:T1,y2:B2,'class':'o-on'+(ex[3]?'':' closed')},svg);
    var r=rel(tS(ex[0])),pre=(ex[3]?'onset ':'excursion ')+(ex[2]>0?'\u25B2 ':'\u25BC '),cands=[pre+dt(tS(ex[0]))+(r?', '+r:''),pre+dt(tS(ex[0])),pre+hm(tS(ex[0]))],lab,w3,la,lxx,room;
    var lg=el('g',{'class':'o-onl'},svg);el('title',{},lg).textContent=cands[0];
    var ob=el('rect',{y:T1+3,height:15,rx:2,'class':'o-ob'},lg),ot=tx(lg,0,T1+14,'','o-t o-ot'+(ex[3]?'':' closed'));
    room=Math.max(W-padR-ox-5,ox-5-padL);
    for(var q=0;q<cands.length;q++){lab=cands[q];ot.textContent=lab;w3=tw(ot,lab);if(w3<=room||q===cands.length-1)break;}
    la=ox+5+w3<=W-padR?'start':'end';lxx=la==='start'?ox+5:ox-5-w3;if(lxx<padL)lxx=padL;
    ot.setAttribute('x',lxx.toFixed(1));ob.setAttribute('x',(lxx-3).toFixed(1));ob.setAttribute('width',(w3+6).toFixed(1));}
  /* hover cursor */
  G={padL:padL,pw:pw,Z0:Z0,ZS:ZS,X:X,Y:Y,Y2:Y2,T1:T1,B1:B1,T2:T2,B2:B2,svg:svg,cur:el('g',{'class':'o-cur'},svg)};
  if(curI!=null)cursor(curI,null);
}
function tipEl(){var t=doc.getElementById('tip');if(!t){t=doc.createElement('div');t.id='tip';t.setAttribute('role','tooltip');t.hidden=true;doc.body.appendChild(t);}return t;}
function tipHtml(i){var m=D.m[cur],v=num(m.x[i]),c=num(m.md[i]),s=num(m.s[i]),cs=num(m.c[i]),a=tS(i);
  var h='<b>'+esc(m.n)+'</b><br><span class="tm">'+dt(a)+' - '+hm(a+bm)+(a+bm/2>=tc?', Current window':'')+'</span>';
  if(v==null)return h+'<br><span class="tm">no value: a gap (restart or missing snapshots)</span>';
  h+='<div class="tr2"><span>value</span><b>'+fmt(v)+' '+esc(m.u)+'</b></div>';
  if(c==null)return h+'<div class="tr2"><span>normal</span><b>too little history</b></div>';
  h+='<div class="tr2"><span>normal</span><b>'+fmt(c)+'</b></div><div class="tr2"><span>normal range</span><b>'+fmt(Math.max(0,c-2*s))+' - '+fmt(c+2*s)+'</b></div>';
  h+='<div class="tr2"><span>residual</span><b>'+(s>0?((v-c)/s>=0?'+':'')+((v-c)/s).toFixed(1)+' spreads':'-')+'</b></div>';
  if(cs!=null)h+='<div class="tr2"><span>CUSUM</span><b>'+(cs>=0?'upward '+(cs/10).toFixed(1):'downward '+(-cs/10).toFixed(1))+'</b></div>';
  return h;}
function cursor(i,e){if(!G)return;curI=i;var g=G.cur;while(g.firstChild)g.removeChild(g.firstChild);
  var m=D.m[cur],xx=G.X(i),v=num(m.x[i]),cs=num(m.c[i]);
  el('line',{x1:xx.toFixed(1),x2:xx.toFixed(1),y1:G.T1,y2:G.B2,'class':'o-cl'},g);
  if(v!=null)el('circle',{cx:xx.toFixed(1),cy:G.Y(v).toFixed(1),r:3.2,'class':'o-cd2'},g);
  if(cs!=null)el('circle',{cx:xx.toFixed(1),cy:G.Y2(cs/10).toFixed(1),r:2.6,'class':'o-cd2'},g);
  var t=tipEl();t.innerHTML=tipHtml(i);t.hidden=false;
  var cx,cy;if(e){cx=e.clientX;cy=e.clientY;}else{var r=plot.getBoundingClientRect();cx=r.left+xx-plot.scrollLeft;cy=r.top+G.T1+20;}
  var x2=cx+14,y2=cy+16,w=t.offsetWidth,h=t.offsetHeight;if(x2+w>innerWidth-8)x2=cx-w-12;if(y2+h>innerHeight-8)y2=cy-h-12;
  t.style.left=Math.max(8,x2)+'px';t.style.top=Math.max(8,y2)+'px';}
function uncursor(){curI=null;if(G){var g=G.cur;while(g.firstChild)g.removeChild(g.firstChild);}var t=doc.getElementById('tip');if(t)t.hidden=true;}
function idxAt(e){if(!G)return null;var r=G.svg.getBoundingClientRect(),xx=e.clientX-r.left;if(xx<G.padL||xx>G.padL+G.pw)return null;var i=Math.floor((G.Z0+(xx-G.padL)/G.pw*G.ZS-t0)/bm);return Math.max(0,Math.min(nb-1,i));}
plot.addEventListener('mousemove',function(e){var i=idxAt(e);if(i==null){uncursor();return;}cursor(i,e);});
plot.addEventListener('mouseleave',uncursor);
plot.addEventListener('blur',uncursor);
plot.addEventListener('keydown',function(e){var k=e.key,i=curI==null?(D.m[cur].on?D.m[cur].on[0]:nb-1):curI,n=e.shiftKey?10:1;
  if(k==='ArrowRight')i=Math.min(nb-1,i+(curI==null?0:n));else if(k==='ArrowLeft')i=Math.max(0,i-(curI==null?0:n));else if(k==='Home')i=0;else if(k==='End')i=nb-1;else return;
  e.preventDefault();cursor(i,null);});
/* the picker: roving tabindex, arrows / Home / End */
function pick(i,focus){if(!(i>=0&&i<D.m.length))return;cur=i;btns.forEach(function(b,j){var on=j===i;b.setAttribute('aria-selected',on?'true':'false');b.tabIndex=on?0:-1;b.classList.toggle('on',on);});
  if(focus&&btns[i])btns[i].focus();var keep=curI;draw();if(keep!=null&&doc.activeElement===plot)cursor(keep,null);else uncursor();}
btns.forEach(function(b,j){b.addEventListener('click',function(){pick(j);});
  b.addEventListener('keydown',function(e){var n=btns.length,k=e.key,t=(k==='ArrowRight'||k==='ArrowDown')?(j+1)%n:(k==='ArrowLeft'||k==='ArrowUp')?(j-1+n)%n:k==='Home'?0:k==='End'?n-1:-1;if(t<0)return;e.preventDefault();pick(t,true);});});
/* the rows of the table pick too */
[].slice.call(sec.querySelectorAll('.onset-tbl tbody tr[data-i]')).forEach(function(tr){tr.addEventListener('click',function(){pick(+tr.getAttribute('data-i'));});});
pick(cur);
function redraw(){if(plot.clientWidth!==lastW)draw();}
if(window.ResizeObserver)new ResizeObserver(redraw).observe(plot);
window.addEventListener('resize',redraw);
doc.addEventListener('awr:view',function(){setTimeout(draw,30);});
window.AWR_ONSET={redraw:draw,pick:pick};
})();
