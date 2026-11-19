/* js_waithist: client half of section 22_wait_histogram (Wait latency histograms).
   Reads window.AWR_DATA.waithist = {min, ev:[{n, cl, k, nc, nn, np, lab, rg,
   cc, ct, mc, mt, lc, hc, lt, ht}]} (one entry per card, same order as the
   article.whc[data-i] elements) and draws one inline SVG per card into its
   .whp: Current = bars (share of the event's waits per latency bucket),
   normal = the mean prior share as a stepped line over the prior min-max
   band, plus the median / p95 bucket of both.  "By count | By time"
   re-weights every bucket by its approximate time (ct / mt / lt / ht).
   Colours come from CSS classes (sql/lib/src/css_waithist.css). */
(function(){
var doc=document,NS='http://www.w3.org/2000/svg',D=null,MODE='c',SEC=null;
function el(n,a,p){var e=doc.createElementNS(NS,n);for(var k in a)e.setAttribute(k,a[k]);if(p)p.appendChild(e);return e;}
function tx(p,x,y,s,c,an){var t=el('text',{x:x,y:y,'class':c||''},p);if(an)t.setAttribute('text-anchor',an);t.textContent=s;return t;}
function esc(s){return String(s).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;');}
function pct(v){return v==null?'-':(v*100>=10?Math.round(v*100):Math.round(v*1000)/10)+'%';}
function sum(a){var s=0;for(var i=0;i<a.length;i++)s+=a[i]||0;return s;}
function shares(a){var s=sum(a);return a.map(function(v){return s>0?v/s:0;});}
/* first bucket whose cumulative share reaches q (null without data) */
function pIdx(sh,q){var c=0,t=sum(sh);if(!(t>0))return null;for(var i=0;i<sh.length;i++){c+=sh[i];if(c>=q*t-1e-9)return i;}return sh.length-1;}
function series(e){
  var t=MODE==='t';
  return {cur:shares(t?e.ct:e.cc),nrm:t?e.mt:e.mc,lo:t?e.lt:e.lc,hi:t?e.ht:e.hc};
}
function nice(m){var st=[0.05,0.1,0.2,0.25,0.5,1];for(var i=0;i<st.length;i++)if(m/st[i]<=4)return st[i];return 1;}
function draw(card){
  var i=+card.getAttribute('data-i'),e=D.ev[i],box=card.querySelector('.whp');if(!e||!box)return;
  var W=Math.round(box.clientWidth);if(W<60)return;
  if(box._w===W&&box._m===MODE)return;box._w=W;box._m=MODE;
  var H=196,L=36,R=6,T=38,B=26,n=e.lab.length,bw=(W-L-R)/n,s=series(e),np=e.np>0,few=e.nc<D.min;
  var mx=0;for(var k=0;k<n;k++)mx=Math.max(mx,s.cur[k]||0,np?(s.nrm[k]||0):0,np?(s.hi[k]||0):0);
  mx=Math.max(mx,0.05);var st=nice(mx),top=Math.ceil(mx/st-1e-9)*st;
  var Y=function(v){return H-B-(H-T-B)*Math.min(v,top)/top;},X=function(k){return L+k*bw;};
  box.textContent='';
  var c50=pIdx(s.cur,0.5),c95=pIdx(s.cur,0.95),n50=np?pIdx(s.nrm,0.5):null,n95=np?pIdx(s.nrm,0.95):null;
  var what=MODE==='t'?'time':'waits';
  var svg=el('svg',{width:W,height:H,viewBox:'0 0 '+W+' '+H,role:'img','class':'whsvg',
    'aria-label':e.n+', share of '+what+' per latency bucket: Current median '+(c50==null?'-':e.rg[c50])+', p95 '+(c95==null?'-':e.rg[c95])
      +(np?'; normal median '+e.rg[n50]+', p95 '+e.rg[n95]:'; no normal shape')},box);
  for(var g=0;g<=top+1e-9;g+=st){var y=Y(g);el('line',{x1:L,x2:W-R,y1:y,y2:y,'class':g?'whgl':'whax'},svg);
    tx(svg,L-5,y+3.5,Math.round(g*100)+'%','whtk','end');}
  if(np){for(k=0;k<n;k++){var lo=s.lo[k]||0,hi=s.hi[k]||0;if(hi>lo)el('rect',{x:X(k)+1,width:Math.max(1,bw-2),y:Y(hi),height:Math.max(0.5,Y(lo)-Y(hi)),'class':'whbnd'},svg);}}
  for(k=0;k<n;k++){var v=s.cur[k]||0;if(v>0)el('rect',{x:X(k)+Math.min(3,bw*0.12),width:Math.max(1,bw-2*Math.min(3,bw*0.12)),y:Y(v),height:Math.max(0.5,Y(0)-Y(v)),rx:1.5,'class':'whbr'+(few?' whfew':'')},svg);}
  if(np){var d='';for(k=0;k<n;k++){var yy=Y(s.nrm[k]||0).toFixed(1);d+=(k?'L':'M')+X(k).toFixed(1)+' '+yy+'L'+X(k+1).toFixed(1)+' '+yy;}
    el('path',{d:d,'class':'whnl'},svg);}
  /* x labels: thin out when the buckets are narrow */
  var ext=[],lw=function(k){return e.lab[k].length*5.6+6;};
  function fits(a,b){for(var q=0;q<ext.length;q++)if(a<ext[q][1]&&b>ext[q][0])return false;return true;}
  function put(k,an){var w=lw(k),x=an==='end'?X(k+1):an==='start'?X(k):X(k)+bw/2,a=an==='end'?x-w:an==='start'?x:x-w/2;
    if(!fits(a,a+w))return;ext.push([a,a+w]);tx(svg,x,H-B+14,e.lab[k],'whxl',an);}
  put(n-1,'end');put(0,'start');
  var every=Math.max(1,Math.ceil(lw(0)/bw));
  for(k=every;k<n-1;k+=every)put(k,'middle');
  tx(svg,W-R,H-1,'wait time per wait, bucket upper bound','whtk','end');
  /* percentile marks: Current (solid) on the first row, normal (dashed) on the second */
  function marks(a,b,row,cls,lab){if(a==null)return;var y=row?23:11;
    tx(svg,L-5,y+3,lab,'whml '+cls,'end');
    var near=b-a===1&&bw<28,pts=a===b?[[a,'p50, p95','middle',0]]:[[a,'p50',near?'end':'middle',near?2:0],[b,'p95',near?'start':'middle',near?-2:0]];
    pts.forEach(function(p){var x=X(p[0])+bw/2;el('line',{x1:x,x2:x,y1:T-6,y2:H-B,'class':'whpm '+cls},svg);
      var an=p[2],lx=x+p[3],w=p[1].length*5.4;if(an==='middle'&&lx+w/2>W-R){an='end';lx=W-R;}
      tx(svg,lx,y+3,p[1],'whml '+cls,an);});}
  marks(c50,c95,0,'whmc','now');
  if(np)marks(n50,n95,1,'whmn','normal');
  for(k=0;k<n;k++)el('rect',{x:X(k),y:T,width:bw,height:H-T-B,'class':'whhit','data-wh':i+':'+k},svg);
}
function tipHtml(i,k){
  var e=D.ev[i],s=series(e),t=MODE==='t',cnt=e.cc[k]||0,np=e.np>0;
  return '<b>'+esc(e.n)+'</b><br><span class="tm">waits '+esc(e.rg[k])+(t?', share of the time (approx.)':', share of the waits')+'</span>'
    +'<div class="tr2"><span>Current</span><b>'+pct(s.cur[k])+'</b></div>'
    +'<div class="tr2"><span>Current waits</span><b>'+Math.round(cnt).toLocaleString('en-US')+'</b></div>'
    +(np?'<div class="tr2"><span>Normal (mean)</span><b>'+pct(s.nrm[k])+'</b></div>'
        +'<div class="tr2"><span>Prior range</span><b>'+pct(s.lo[k])+' - '+pct(s.hi[k])+'</b></div>'
        :'<div class="tr2"><span class="tm">no normal shape</span></div>');
}
var tip=null;
function getTip(){if(!tip)tip=doc.getElementById('tip');if(!tip){tip=doc.createElement('div');tip.id='tip';tip.setAttribute('role','tooltip');tip.hidden=true;doc.body.appendChild(tip);}return tip;}
function place(ev){var t=getTip(),x=ev.clientX+14,y=ev.clientY+16,w=t.offsetWidth,h=t.offsetHeight;
  if(x+w>innerWidth-8)x=ev.clientX-w-12;if(y+h>innerHeight-8)y=ev.clientY-h-12;
  t.style.left=Math.max(8,x)+'px';t.style.top=Math.max(8,y)+'px';}
var hot=null;
function hov(r){if(hot===r)return;if(hot)hot.classList.remove('on');hot=r;if(r)r.classList.add('on');}
function drawAll(force){if(!D||!SEC)return;Array.prototype.forEach.call(SEC.querySelectorAll('article.whc'),function(c){if(force){var b=c.querySelector('.whp');if(b)b._w=0;}draw(c);});}
function setMode(m,focus){MODE=m;hov(null);if(tip)tip.hidden=true;
  Array.prototype.forEach.call(SEC.querySelectorAll('.whseg button'),function(b){var on=b.getAttribute('data-m')===m;b.setAttribute('aria-pressed',on?'true':'false');b.tabIndex=on?0:-1;if(on&&focus)b.focus();});
  drawAll(true);}
doc.addEventListener('DOMContentLoaded',function(){
  D=(window.AWR_DATA||{}).waithist||null;SEC=doc.getElementById('wait-hist');
  if(!D||!SEC||!D.ev||!D.ev.length)return;
  SEC.classList.add('whjs');
  var seg=SEC.querySelector('.whseg');
  if(seg){seg.hidden=false;
    seg.addEventListener('click',function(ev){var b=ev.target.closest&&ev.target.closest('button[data-m]');if(b)setMode(b.getAttribute('data-m'),false);});
    seg.addEventListener('keydown',function(ev){if(ev.key==='ArrowLeft'||ev.key==='ArrowRight'||ev.key==='Home'||ev.key==='End'){ev.preventDefault();
      setMode(ev.key==='ArrowLeft'||ev.key==='Home'?'c':'t',true);}});
    setMode('c',false);}
  doc.addEventListener('mouseover',function(ev){var t=ev.target,r=t&&t.closest&&t.closest('#wait-hist rect.whhit');
    if(!r){if(hot){hov(null);getTip().hidden=true;}return;}
    var p=r.getAttribute('data-wh').split(':');hov(r);var tp=getTip();tp.innerHTML=tipHtml(+p[0],+p[1]);tp.hidden=false;place(ev);});
  SEC.addEventListener('mousemove',function(ev){if(hot)place(ev);},{passive:true});
  if(window.ResizeObserver){var ro=new ResizeObserver(function(){drawAll(false);});Array.prototype.forEach.call(SEC.querySelectorAll('.whp'),function(b){ro.observe(b);});}
  doc.addEventListener('awr:view',function(){setTimeout(function(){drawAll(false);},0);});
  window.addEventListener('resize',function(){drawAll(false);});
  drawAll(false);
});
})();
