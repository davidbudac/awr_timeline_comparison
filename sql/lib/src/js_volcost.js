/* js_volcost: client half of section 21_volume_cost (Volume vs unit cost).
   Reads window.AWR_DATA.volcost = {thr, top, sql:[item], ev:[item]}, item =
   {n name, l link id or "", r own table row id, ec/ep executions (waits) now /
   normal, pc/pp ms per run (per wait) now / normal, tc/tp seconds now / normal,
   k cost + category ("us" = up, slower per run), g label rank (0 = none)}.
   Draws one log2 / log2 plane (inline SVG) into #vc-plot for the mode chosen
   by the segmented control; redraws on width change (a closed library row
   measures 0), awr:view and resize.  Colours come from CSS classes. */
(function(){
'use strict';
var doc=document,D=window.AWR_DATA&&window.AWR_DATA.volcost,sec=doc.getElementById('volume-cost');
if(!D||!sec)return;
var plot=doc.getElementById('vc-plot');if(!plot)return;
var NS='http://www.w3.org/2000/svg',X=String.fromCharCode(215);
var mode=sec.getAttribute('data-mode')==='ev'?'ev':'sql',lastW=-1,tip=null,Q=[];
sec.classList.add('vc-on');
function el(t,a,p,txt){var e=doc.createElementNS(NS,t);for(var k in a)e.setAttribute(k,a[k]);if(txt!=null)e.textContent=txt;if(p)p.appendChild(e);return e;}
function esc(s){return String(s).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;');}
function l2(v){return Math.log(v)/Math.LN2;}
function grp(n){return String(n).replace(/\B(?=(\d{3})+(?!\d))/g,',');}
function rx(r){if(r==null||!isFinite(r))return '-';if(r<0.005)return X+'<0.01';
  return X+(r>=9.95?grp(Math.round(r)):r>=0.095?r.toFixed(1):r.toFixed(2));}
/* about four significant digits, k / M / G past 1e4 (fmt_num's look) */
function fv(v){if(v==null||!isFinite(v))return '-';var a=Math.abs(v),s='',t;
  if(a>=1e9){a/=1e9;s=' G';}else if(a>=1e6){a/=1e6;s=' M';}else if(a>=1e4){a/=1e3;s=' k';}
  t=a>=1000?grp(Math.round(a)):a>=100?a.toFixed(1):a>=10?a.toFixed(2):a>=1?a.toFixed(3):a===0?'0':String(+a.toPrecision(4));
  return (v<0?'-':'')+t+s;}
function step(d,n){var s=d[1]-d[0];return s>(n?12:16)?4:s>(n?6:8)?2:1;}
function tickLab(i){var v=Math.pow(2,Math.abs(i));return i===0?X+'1':i>0?X+grp(v):X+'1/'+grp(v);}
function points(k){var out=[];(D[k]||[]).forEach(function(p){
  if(!(p.ep>0&&p.pp>0&&p.tp>0&&p.ec>0&&p.pc>0))return;
  var x=p.ec/p.ep,y=p.pc/p.pp;out.push({p:p,x:x,y:y,t:p.tc/p.tp,lx:l2(x),ly:l2(y)});});return out;}
/* axis domain in log2 units: at least x1/2 .. x2, at most x1/16384 .. x16384 */
function dom(v){var lo=0,hi=0;v.forEach(function(a){if(a<lo)lo=a;if(a>hi)hi=a;});
  return [Math.max(-14,Math.min(-1,Math.floor(lo-0.2))),Math.min(14,Math.max(1,Math.ceil(hi+0.2)))];}
function cls(q){var k=q.p.k||'e';return 'vc-dot '+(k.charAt(0)==='u'?'vc-u':k.charAt(0)==='d'?'vc-d':'vc-e');}
function noun(){return mode==='sql'?'statement':'wait event';}
function tipEl(){if(!tip){tip=doc.getElementById('tip');if(!tip){tip=doc.createElement('div');tip.id='tip';tip.setAttribute('role','tooltip');tip.hidden=true;doc.body.appendChild(tip);}}return tip;}
function row(a,b){return '<div class="tr2"><span>'+a+'</span><b>'+b+'</b></div>';}
function tipHtml(q){var p=q.p,s=mode==='sql';
  return '<b>'+esc(p.n)+'</b><br><span class="tm">now vs normal (mean of '+(s?'the prior windows it ran in':'the prior windows with a wait')+')</span>'
    +row(s?'Executions':'Waits',fv(p.ec)+' vs '+fv(p.ep)+' ('+esc(rx(q.x))+')')
    +row(s?'Per run':'Per wait',fv(p.pc)+' vs '+fv(p.pp)+' ms ('+esc(rx(q.y))+')')
    +row(s?'Elapsed':'Waited',fv(p.tc)+' vs '+fv(p.tp)+' s ('+esc(rx(q.t))+')');}
function place(x,y){var t=tipEl(),w=t.offsetWidth,h=t.offsetHeight,px=x+14,py=y+16;
  if(px+w>innerWidth-8)px=x-w-12;if(py+h>innerHeight-8)py=y-h-12;
  t.style.left=Math.max(8,px)+'px';t.style.top=Math.max(8,py)+'px';}
function tipOn(q,x,y){var t=tipEl();t.innerHTML=tipHtml(q);t.hidden=false;place(x,y);}
function tipOff(){if(tip)tip.hidden=true;}
function go(q){var p=q.p,t=(p.l&&doc.getElementById(p.l))||doc.getElementById(p.r);if(!t)return;tipOff();
  if(window.AWR_goTo)window.AWR_goTo(t,true,true);else t.scrollIntoView({block:'center'});}
function draw(force){
  var w=plot.clientWidth;if(!w)return;if(!force&&w===lastW)return;lastW=w;
  plot.textContent='';Q=points(mode);
  if(!Q.length){var n=doc.createElement('p');n.className='vc-none';n.textContent='No '+noun()+' has a prior baseline to place.';plot.appendChild(n);return;}
  var narrow=w<520,H=Math.round(Math.max(260,Math.min(440,w*0.6))),rmax=narrow?14:20,L=narrow?44:52,R=Math.round(rmax*0.7),T=Math.round(rmax*0.7),B=24,i,c;
  var dx=dom(Q.map(function(q){return q.lx;})),dy=dom(Q.map(function(q){return q.ly;}));
  var sx=(w-L-R)/(dx[1]-dx[0]),sy=(H-T-B)/(dy[1]-dy[0]);
  var PX=function(v){return L+(Math.max(dx[0],Math.min(dx[1],v))-dx[0])*sx;};
  var PY=function(v){return H-B-(Math.max(dy[0],Math.min(dy[1],v))-dy[0])*sy;};
  var s=el('svg',{width:w,height:H,viewBox:'0 0 '+w+' '+H,'class':'vc-svg',role:'img',
    'aria-label':'Volume against unit cost, '+Q.length+' '+noun()+'s: '+(mode==='sql'?'executions':'waits')
      +' versus normal across, time per '+(mode==='sql'?'run':'wait')+' versus normal up, both on log scales; the table below holds every value'},plot);
  var g=el('g',{'class':'vc-grid'},s),stx=step(dx,narrow),sty=step(dy,narrow);
  for(i=dx[0];i<=dx[1];i++){if(i%stx&&i)continue;
    el('line',{x1:PX(i),x2:PX(i),y1:T,y2:H-B,'class':i?'vc-g':'vc-ax'},g);
    el('text',{x:PX(i),y:H-B+15,'class':'vc-tk','text-anchor':'middle'},g,tickLab(i));}
  for(i=dy[0];i<=dy[1];i++){if(i%sty&&i)continue;
    el('line',{x1:L,x2:w-R,y1:PY(i),y2:PY(i),'class':i?'vc-g':'vc-ax'},g);
    el('text',{x:L-6,y:PY(i)+4,'class':'vc-tk','text-anchor':'end'},g,tickLab(i));}
  /* diagonals of equal total time: lx + ly = c */
  var ds=Math.max(stx,sty),ang=Math.atan2(sy,sx)*180/Math.PI,dg=el('g',{'class':'vc-dgs'},s);
  for(c=dx[0]+dy[0];c<=dx[1]+dy[1];c++){
    if(c%ds)continue;var a=Math.max(dx[0],c-dy[1]),b=Math.min(dx[1],c-dy[0]);if(b-a<0.4)continue;
    el('line',{x1:PX(a),y1:PY(c-a),x2:PX(b),y2:PY(c-b),'class':'vc-dg'+(c===0?' vc-d0':'')},dg);
    if(c<-1||c>3||(narrow&&c!==0&&c!==1))continue;
    var lb=c===0?'same total time':c===-1?'half the total time':X+Math.pow(2,c)+' total time',lx=b-0.12;
    var gt=el('g',{transform:'translate('+PX(lx).toFixed(1)+','+PY(c-lx).toFixed(1)+') rotate('+ang.toFixed(1)+')'},dg);
    el('text',{x:-2,y:-4,'class':'vc-dl','text-anchor':'end'},gt,lb);}
  /* dots: biggest first so the small ones stay on top */
  var vmax=0;Q.forEach(function(q){if(q.p.tc>vmax)vmax=q.p.tc;});
  var order=Q.slice().sort(function(a,b){return b.p.tc-a.p.tc;}),dots=el('g',{'class':'vc-dots'},s);
  order.forEach(function(q){
    q.r=Math.max(3,rmax*Math.sqrt(q.p.tc/vmax));q.cx=PX(q.lx);q.cy=PY(q.ly);
    var out=q.lx<dx[0]||q.lx>dx[1]||q.ly<dy[0]||q.ly>dy[1];
    var e=el('circle',{cx:q.cx.toFixed(1),cy:q.cy.toFixed(1),r:q.r.toFixed(1),'class':cls(q)+(out?' vc-o':''),tabindex:'0',
      'aria-label':q.p.n+': '+(mode==='sql'?'executions ':'waits ')+rx(q.x)+', per '+(mode==='sql'?'run ':'wait ')+rx(q.y)+', total '+rx(q.t)+' normal'},dots);
    e.addEventListener('mousemove',function(ev){tipOn(q,ev.clientX,ev.clientY);});
    e.addEventListener('mouseleave',tipOff);
    e.addEventListener('focus',function(){var rc=e.getBoundingClientRect();tipOn(q,rc.right,rc.top);});
    e.addEventListener('blur',tipOff);
    e.addEventListener('click',function(){go(q);});
    e.addEventListener('keydown',function(ev){if(ev.key==='Enter'||ev.key===' '){ev.preventDefault();go(q);}});
  });
  /* labels for the biggest movers, placed where they fit */
  var boxes=[],lim=narrow?3:6,mono=mode==='sql';
  Q.filter(function(q){return q.p.g>0&&q.p.g<=lim;}).sort(function(a,b){return a.p.g-b.p.g;}).forEach(function(q){
    var tx=q.p.n.length>26?q.p.n.slice(0,25)+'...':q.p.n,tw=tx.length*(mono?6.7:6.1)+4,th=13;
    var cand=[[q.cx+q.r+4,q.cy+4,'start'],[q.cx-q.r-4,q.cy+4,'end'],[q.cx,q.cy-q.r-5,'middle'],[q.cx,q.cy+q.r+13,'middle']];
    for(var j=0;j<cand.length;j++){var p=cand[j],x0=p[2]==='start'?p[0]:p[2]==='end'?p[0]-tw:p[0]-tw/2,y0=p[1]-th+3;
      if(x0<L+2||x0+tw>w-R||y0<T||y0+th>H-B)continue;
      var hit=boxes.some(function(bx){return x0<bx[0]+bx[2]&&x0+tw>bx[0]&&y0<bx[1]+bx[3]&&y0+th>bx[1];});
      if(hit)continue;boxes.push([x0,y0,tw,th]);
      el('text',{x:p[0].toFixed(1),y:p[1].toFixed(1),'class':'vc-lb'+(mono?' vc-mn':''),'text-anchor':p[2]},s,tx);break;}
  });
}
function setMode(k,focus){if(k!=='sql'&&k!=='ev')return;mode=k;sec.setAttribute('data-mode',k);
  [].forEach.call(sec.querySelectorAll('.vc-seg button'),function(b){var on=b.getAttribute('data-k')===k;b.setAttribute('aria-pressed',on?'true':'false');if(on&&focus)b.focus();});
  tipOff();draw(true);}
[].forEach.call(sec.querySelectorAll('.vc-seg button'),function(b){
  b.addEventListener('click',function(){setMode(b.getAttribute('data-k'));});
  b.addEventListener('keydown',function(ev){if(ev.key==='ArrowLeft'||ev.key==='ArrowRight'||ev.key==='Home'||ev.key==='End'){
    ev.preventDefault();setMode(ev.key==='ArrowLeft'||ev.key==='Home'?'sql':'ev',true);}});
});
if(window.ResizeObserver)new ResizeObserver(function(){draw(false);}).observe(plot);
window.addEventListener('resize',function(){draw(false);});
doc.addEventListener('awr:view',function(){setTimeout(function(){draw(false);},60);});
if(doc.readyState==='loading')doc.addEventListener('DOMContentLoaded',function(){draw(true);});else draw(true);
})();
