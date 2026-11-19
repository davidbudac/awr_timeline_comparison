/* js_loadresp: client half of section 20 (Load vs response time).
   Draws the scatter of window.AWR_DATA.loadresp into #load-response
   .lr-plot as inline SVG: the grey cloud (one dot per snapshot interval),
   the normal curve (bin medians, dashed) and its middle-half band, the
   prior windows (rings, data-w) and the Current window (accent dot +
   label).  The segmented controls switch the load / response pair and
   the "Reads as" sentence (computed in PL/SQL per pair).  Redraws on
   resize (ResizeObserver), awr:view and window resize; draws nothing
   while the plot has no width (a closed library row).  Colours come from
   CSS classes only.  Pure ASCII. */
(function(){
'use strict';
var doc=document,NS='http://www.w3.org/2000/svg',D=null,sec=null,plot=null,cur={x:0,y:0},tip=null,lastW=0;
function el(n,a,p){var e=doc.createElementNS(NS,n);for(var k in a)if(a[k]!=null)e.setAttribute(k,a[k]);if(p)p.appendChild(e);return e;}
function tx(p,x,y,s,c,anc){var t=el('text',{x:x,y:y,'class':c||null,'text-anchor':anc||null},p);t.textContent=s;return t;}
function esc(s){return String(s).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;');}
/* fmt_num's look: about 4 significant digits, k / M / G past 1e4 / 1e6 / 1e9 */
function fmt(v){
  if(v==null||isNaN(v))return '\u2014';if(v===0)return '0';
  var a=Math.abs(v),s=v<0?'-':'',u='';
  if(a>=1e9){a/=1e9;u=' G';}else if(a>=1e6){a/=1e6;u=' M';}else if(a>=1e4){a/=1e3;u=' k';}
  var d=a>=1000?0:a>=100?1:a>=10?2:a>=1?3:4,t=a.toFixed(d);
  if(!u&&a>=1000)t=t.replace(/\B(?=(\d{3})+(?!\d))/g,',');
  if(!u&&a<1)t=String(+a.toPrecision(4));
  return s+t+u;
}
/* x / y of pair p from the five window / interval metrics
   m = [user calls/s, executions/s, logical reads/s, service time ms, DB time cs/s] */
/* an axis tick: no trailing zeros, k / M past 1e4 / 1e6 */
function tfmt(v){var a=Math.abs(v),u='';if(a>=1e6){v/=1e6;u='M';}else if(a>=1e4){v/=1e3;u='k';}
  var t=String(+v.toFixed(6));if(!u&&Math.abs(v)>=1000)t=t.replace(/\B(?=(\d{3})+(?!\d))/g,',');return t+u;}
function xv(p,m){var v=m[p%3];return v!=null&&v>0?v:null;}
function yv(p,m){var x=xv(p,m);if(x==null)return null;if(p<3)return m[3];if(m[4]==null)return null;return m[4]*10/x*(p%3===2?1000:1);}
function pid(){return cur.x+3*cur.y;}
function niceStep(span,n){var r=span/n,p=Math.pow(10,Math.floor(Math.log(r)/Math.LN10)),q=r/p;return (q<1.5?1:q<3?2:q<7?5:10)*p;}
function pctl(a,q){if(!a.length)return null;var s=a.slice().sort(function(x,y){return x-y;}),i=(s.length-1)*q,l=Math.floor(i),h=Math.ceil(i);return s[l]+(s[h]-s[l])*(i-l);}
var MON=['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'],DY=['Sun','Mon','Tue','Wed','Thu','Fri','Sat'];
var T0=0;
function tAt(min){var d=new Date(T0+min*60000),z=function(v){return (v<10?'0':'')+v;};
  return DY[d.getUTCDay()]+' '+d.getUTCDate()+' '+MON[d.getUTCMonth()]+' '+z(d.getUTCHours())+':'+z(d.getUTCMinutes());}
function tipOn(html,cx,cy){if(!tip)return;tip.innerHTML=html;tip.hidden=false;
  var x=cx+14,y=cy+16,w=tip.offsetWidth,h=tip.offsetHeight;
  if(x+w>innerWidth-8)x=cx-w-12;if(y+h>innerHeight-8)y=cy-h-12;
  tip.style.left=Math.max(8,x)+'px';tip.style.top=Math.max(8,y)+'px';}
function tipOff(){if(tip)tip.hidden=true;}
function draw(){
  if(!D||!plot)return;
  var W=plot.clientWidth;if(!W)return;lastW=W;
  var p=pid(),P=D.p[p],narrow=W<560,H=narrow?280:350,L=narrow?40:52,R=narrow?10:18,T=26,B=40,i,k;
  plot.innerHTML='';
  if(!P||!P.n){plot.innerHTML='<p class="note">No intervals with this load and response pair.</p>';return;}
  /* points */
  var bx=[],by=[],bi=[];
  for(i=0;i<D.bt.length;i++){var m=[D.b0[i],D.b1[i],D.b2[i],D.b3[i],D.b4[i]],x=xv(p,m),y=yv(p,m);if(x==null||y==null)continue;bx.push(x);by.push(y);bi.push(i);}
  var ws=[];D.w.forEach(function(w){if(w.v!=='Y'||!w.m.length)return;var x=xv(p,w.m),y=yv(p,w.m);if(x==null||y==null)return;ws.push({w:w,x:x,y:y});});
  var cw=null;ws.forEach(function(o){if(o.w.o===0)cw=o;});
  /* axis ranges: the windows and the curve always fit; the cloud up to
     its 98th / 96th percentile (outliers pin to the edge with a caret) */
  var xm=pctl(bx,0.98)||0,ym=pctl(by,0.96)||0;
  ws.forEach(function(o){xm=Math.max(xm,o.x);ym=Math.max(ym,o.y);});
  P.c.forEach(function(c){xm=Math.max(xm,c[0]);ym=Math.max(ym,c[3]);});
  if(!(xm>0))xm=1;if(!(ym>0))ym=1;
  var xs=niceStep(xm*1.05,narrow?4:6),ys=niceStep(ym*1.08,5),xM=Math.ceil(xm*1.05/xs)*xs,yM=Math.ceil(ym*1.08/ys)*ys;
  var X=function(v){return L+(W-L-R)*Math.min(v,xM)/xM;},Y=function(v){return H-B-(H-T-B)*Math.min(v,yM)/yM;};
  var s=el('svg',{width:W,height:H,viewBox:'0 0 '+W+' '+H,'class':'lr-svg',role:'img',
    'aria-label':P.xl+' against '+P.yl+': '+bx.length+' snapshot intervals, '+ws.length+' windows'+(cw?', Current '+fmt(cw.x)+' '+P.xu+', '+fmt(cw.y)+' '+P.yu:'')},plot);
  for(var v=0;v<=yM+ys/2;v+=ys){el('line',{x1:L,x2:W-R,y1:Y(v),y2:Y(v),'class':v?'lr-g':'lr-ax'},s);tx(s,L-6,Y(v)+4,tfmt(v),'lr-tl','end');}
  for(v=0;v<=xM+xs/2;v+=xs){el('line',{x1:X(v),x2:X(v),y1:H-B,y2:H-B+4,'class':'lr-ax'},s);tx(s,X(v),H-B+16,tfmt(v),'lr-tl',X(v)>W-R-14?'end':'middle');}
  el('line',{x1:L,x2:L,y1:T,y2:H-B,'class':'lr-ax'},s);
  tx(s,L-(narrow?36:48),12,P.yl,'lr-at');tx(s,W-R,H-4,P.xl,'lr-at','end');
  /* the normal band + curve */
  if(P.c.length>=2){
    var up='',dn='',ln='';
    P.c.forEach(function(c,j){up+=(j?'L':'M')+X(c[0]).toFixed(1)+' '+Y(c[3]).toFixed(1);ln+=(j?'L':'M')+X(c[0]).toFixed(1)+' '+Y(c[1]).toFixed(1);});
    for(j=P.c.length-1;j>=0;j--)dn+='L'+X(P.c[j][0]).toFixed(1)+' '+Y(P.c[j][2]).toFixed(1);
    el('path',{d:up+dn+'Z','class':'lr-band'},s);el('path',{d:ln,'class':'lr-norm'},s);
  }
  var j;
  /* the cloud */
  var gb=el('g',{'class':'lr-cloud'},s);
  for(k=0;k<bx.length;k++){var ix=bi[k],out=bx[k]>xM||by[k]>yM,c=D.bc[ix]===1;
    el(out?'rect':'circle',out?{x:X(bx[k])-2,y:Y(by[k])-2,width:4,height:4,'class':'lr-b out'+(c?' c':''),'data-b':k}
      :{cx:X(bx[k]).toFixed(1),cy:Y(by[k]).toFixed(1),r:c?2.6:2,'class':'lr-b'+(c?' c':''),'data-b':k},gb);}
  /* prior windows, then Current */
  ws.forEach(function(o){if(o.w.o===0)return;
    el('circle',{cx:X(o.x).toFixed(1),cy:Y(o.y).toFixed(1),r:5,'class':'lr-w','data-w':o.w.o,'data-k':'w'+o.w.o,tabindex:0,
      'aria-label':o.w.l+' window, '+o.w.t.replace(/&ndash;/g,'-')+': '+fmt(o.x)+' '+P.xu+', '+fmt(o.y)+' '+P.yu},s);});
  if(cw){
    var cx=X(cw.x),cy=Y(cw.y),e=P.e;
    if(e!=null&&e>0){var ey=Y(e);if(Math.abs(ey-cy)>14){el('line',{x1:cx,x2:cx,y1:ey,y2:cy+(cy<ey?9:-9),'class':'lr-cl'},s);
      el('circle',{cx:cx,cy:ey,r:3,'class':'lr-ce'},s);}}
    el('circle',{cx:cx,cy:cy,r:7,'class':'lr-cur','data-w':0,'data-k':'w0',tabindex:0,
      'aria-label':'Current window: '+fmt(cw.x)+' '+P.xu+', '+fmt(cw.y)+' '+P.yu},s);
    var right=cx<L+(W-L-R)*0.62,lx=cx+(right?13:-13),an=right?'start':'end',ly=Math.max(T+12,Math.min(H-B-24,cy+4));
    tx(s,lx,ly,narrow?'Current '+fmt(cw.y)+' ms':'Current: '+fmt(cw.y)+' '+P.yu,'lr-cll',an);
    if(e!=null&&e>0)tx(s,lx,ly+15,(cw.y/e).toFixed(1)+'\u00d7 '+(narrow?'the curve':'the dashed curve ('+fmt(e)+' ms) at this load'),'lr-cls',an);
  }
  var rt=sec.querySelector('.lr-rt');if(rt&&P.r&&rt.getAttribute('data-p')!==String(p)){rt.innerHTML=P.r;rt.setAttribute('data-p',p);mkFill(rt);}
  /* hover + focus */
  s.addEventListener('mousemove',function(ev){var t=ev.target,h=hint(t,P,bx,by,bi,ws);if(h)tipOn(h,ev.clientX,ev.clientY);else tipOff();});
  s.addEventListener('mouseleave',tipOff);
  s.addEventListener('focusin',function(ev){var h=hint(ev.target,P,bx,by,bi,ws);if(h){var r=ev.target.getBoundingClientRect();tipOn(h,r.right,r.top);}});
  s.addEventListener('focusout',tipOff);
  s.addEventListener('click',function(ev){go(ev.target);});
  s.addEventListener('keydown',function(ev){if(ev.key==='Enter'||ev.key===' '){if(go(ev.target))ev.preventDefault();}});
}
/* the release slot of the sentence (js_wingrid fills the first copy) */
function mkFill(r){var W=window.AWR_WG;if(!W||!W.markerAt)return;
  [].forEach.call(r.querySelectorAll('[data-mk-at]'),function(e){var m=W.markerAt(+e.getAttribute('data-mk-at'));if(!m)return;
    e.textContent=(e.getAttribute('data-mk-pre')||'')+m.l+' ('+m.t+')';e.title=m.l+', '+m.t;e.hidden=false;});}
function go(t){var k=t&&t.getAttribute&&t.getAttribute('data-k');if(!k)return false;
  var r=doc.getElementById('lr-'+k);if(r&&window.AWR_goTo){window.AWR_goTo(r,true,false);return true;}return false;}
function hint(t,P,bx,by,bi,ws){
  if(!t||!t.getAttribute)return '';
  var b=t.getAttribute('data-b');
  if(b!=null){b=+b;return '<b>'+tAt(D.bt[bi[b]])+'</b><br><span class="tm">snapshot interval'+(D.bc[bi[b]]===1?', in the Current window':'')+'</span><br>'
    +fmt(bx[b])+' '+esc(P.xu)+'<br>'+fmt(by[b])+' '+esc(P.yu);}
  var k=t.getAttribute('data-k');if(!k)return '';
  var o=+k.slice(1),w=null;ws.forEach(function(x){if(x.w.o===o)w=x;});if(!w)return '';
  return '<b>'+w.w.t+'</b><br><span class="tm">'+(o===0?'Current window':esc(w.w.l)+' window')+', window average</span><br>'
    +fmt(w.x)+' '+esc(P.xu)+'<br>'+fmt(w.y)+' '+esc(P.yu)+(o===0&&P.e!=null?'<br><span class="tm">the dashed curve at that load: '+fmt(P.e)+'</span>':'');
}
function setPair(xi,yi){
  if(xi!=null)cur.x=xi;if(yi!=null)cur.y=yi;
  if(!D.p[pid()].n){/* fall back to the response kind that has data */cur.y=1-cur.y;}
  [].forEach.call(sec.querySelectorAll('.lr-seg button'),function(b){
    var on=b.hasAttribute('data-x')?+b.getAttribute('data-x')===cur.x:+b.getAttribute('data-y')===cur.y;
    b.setAttribute('aria-pressed',on?'true':'false');
    if(b.hasAttribute('data-y'))b.disabled=!D.p[cur.x+3*(+b.getAttribute('data-y'))].n;});
  draw();
}
function boot(){
  D=(window.AWR_DATA||{}).loadresp||null;sec=doc.getElementById('load-response');
  if(!D||!sec)return;
  plot=sec.querySelector('.lr-plot');if(!plot)return;
  var m=/^(\d+)-(\d+)-(\d+) (\d+):(\d+)/.exec(D.t0||'');T0=m?Date.UTC(+m[1],+m[2]-1,+m[3],+m[4],+m[5]):0;
  tip=doc.getElementById('tip');if(!tip){tip=doc.createElement('div');tip.id='tip';tip.setAttribute('role','tooltip');tip.hidden=true;doc.body.appendChild(tip);}
  cur.x=D.def%3;cur.y=Math.floor(D.def/3);
  sec.classList.add('lr-js');
  sec.querySelector('.lr-chart').addEventListener('click',function(ev){
    var b=ev.target.closest&&ev.target.closest('.lr-seg button');if(!b||b.disabled)return;
    if(b.hasAttribute('data-x'))setPair(+b.getAttribute('data-x'),null);else setPair(null,+b.getAttribute('data-y'));});
  setPair(null,null);
  if(window.ResizeObserver)new ResizeObserver(function(){if(plot.clientWidth!==lastW)draw();}).observe(plot);
  doc.addEventListener('awr:view',function(){setTimeout(draw,30);});
  window.addEventListener('resize',function(){if(plot.clientWidth!==lastW)draw();});
}
if(doc.readyState==='loading')doc.addEventListener('DOMContentLoaded',boot);else boot();
})();
