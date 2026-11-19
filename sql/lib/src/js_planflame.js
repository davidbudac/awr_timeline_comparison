// js_planflame: client half of section 23_plan_flame (Plan shape, old vs new).
// Reads window.AWR_DATA.planflame = {spw, min, mode, st:[{id, sql, p:[plan]}]},
// plan = {r: "old"|"new"|"cur", phv, div, n, nol, lines, state, s:[step]},
// step = [id, parent_id, operation, options, owner, object, self samples,
//         {class: samples on the step}, hidden steps without samples].
// Draws one icicle per plan into div.pf-plot[data-q] of div.pf-st#<id>: root
// on top, width = inclusive samples per window (both plans of a statement
// on ONE scale), the step's own samples on the right end of its bar,
// split by activity class; a step without samples is a thin sliver.
(function(){
'use strict';
var doc=document,NS='http://www.w3.org/2000/svg',D=null,TIP=null;
var MID=String.fromCharCode(183),ELL=String.fromCharCode(8230),DASH=String.fromCharCode(8211);
var ORD=['CPU','User I/O','System I/O','Commit','Application','Concurrency','Network','Configuration','Scheduler','Cluster','Administrative','Queueing','Other'];
var RH=22,CAP=14,MAXR=18;
function col(c){var m=window.AWR_WAIT_COLORS||{};return m[c]||'#9AA3AD';}
function el(n,a,p){var e=doc.createElementNS(NS,n);for(var k in a)if(a.hasOwnProperty(k))e.setAttribute(k,a[k]);if(p)p.appendChild(e);return e;}
function esc(s){return String(s==null?'':s).replace(/[&<>"]/g,function(c){return c==='&'?'&amp;':c==='<'?'&lt;':c==='>'?'&gt;':'&quot;';});}
function fs(v){return v>=100?String(Math.round(v)):v>=10?v.toFixed(1):v>=1?v.toFixed(1):v>0?v.toFixed(2):'0';}
function pc(a,b){return b>0?Math.round(100*a/b)+'%':'0%';}
function stepTxt(n){return [n.op,n.opt,n.obj].filter(function(x){return x;}).join(' ');}
/* ---- the tree of one plan */
function build(P){
  var by={},root=null;
  P.s.forEach(function(a){by[a[0]]={id:a[0],pid:a[1],op:a[2],opt:a[3],own:a[4],obj:a[5],s:a[6],c:a[7]||{},hid:a[8]||0,ch:[]};});
  P.s.forEach(function(a){var n=by[a[0]],p=n.pid!=null?by[n.pid]:null;if(p&&p!==n)p.ch.push(n);else if(n.id===0||!root)root=n;});
  if(!root)return null;
  (function tot(n){var t=n.s;n.ch.forEach(function(c){t+=tot(c);});n.t=t;return t;})(root);
  return root;
}
/* display tree: chains of steps without samples of their own and one busy
   child fold into one bar (only when the plan is deeper than CAP rows);
   children without samples become slivers */
function rowsOf(n){if(!n.t)return 1;var m=0;n.ch.forEach(function(c){m=Math.max(m,rowsOf(c));});return 1+m;}
function disp(n,fold){
  var chain=[n],cur=n,lost=0;
  if(fold){while(cur.s===0){var pos=cur.ch.filter(function(c){return c.t>0;});if(pos.length!==1)break;
    cur.ch.forEach(function(c){if(!c.t)lost+=1+c.hid;});lost+=cur.hid;cur=pos[0];chain.push(cur);}}
  var d={n:cur,chain:chain,lost:lost,t:n.t,kids:[]};
  cur.ch.forEach(function(c){if(c.t>0)d.kids.push(disp(c,fold));});
  cur.ch.forEach(function(c){if(!c.t)d.kids.push({sl:1,n:c,t:0,hid:c.hid,kids:[]});});
  if(cur.hid>0)d.kids.push({sl:1,n:null,t:0,hid:cur.hid,kids:[]});
  return d;
}
function depth(d){var m=0;d.kids.forEach(function(k){m=Math.max(m,depth(k));});return 1+m;}
function slivers(d,row){var c=d.sl?1:0;if(!d.sl&&row<MAXR-1)d.kids.forEach(function(k){c+=slivers(k,row+1);});d.nsl=c;return c;}
/* ---- tooltip (own element; js_timeline's #tip is driven by its grid) */
function tipOn(html,x,y){if(!TIP)return;TIP.innerHTML=html;TIP.hidden=false;
  var w=TIP.offsetWidth,h=TIP.offsetHeight,a=x+14,b=y+16;
  if(a+w>innerWidth-8)a=x-w-12;if(b+h>innerHeight-8)b=y-h-12;
  TIP.style.left=Math.max(8,a)+'px';TIP.style.top=Math.max(8,b)+'px';}
function tipOff(){if(TIP)TIP.hidden=true;}
function tipHtml(d,P,tot){
  var div=P.div||1,spw=D.spw||10,sec=function(n){return n*spw/div;},h;
  if(d.sl){
    if(!d.n)return '<b>'+d.hid+' step'+(d.hid!==1?'s':'')+' without samples</b><br><span class="tm">folded; the plan table lists the steps with samples</span>';
    return '<b>'+esc(stepTxt(d.n))+'</b><br><span class="tm">line '+d.n.id+', no ASH samples'+(d.hid?' (with '+d.hid+' step'+(d.hid!==1?'s':'')+' below)':'')+'</span>';
  }
  var n=d.n,own=n.own&&n.obj?n.own+'.'+n.obj:'';
  h='<b>'+esc(stepTxt(n))+'</b><br><span class="tm">line '+n.id+(own?' '+MID+' '+esc(own):'')+'</span>';
  h+='<div class="tr2"><span>With the steps below</span><b>'+fs(sec(d.t))+' s '+MID+' '+pc(d.t,tot)+'</b></div>';
  h+='<div class="tr2"><span>On the step itself</span><b>'+fs(sec(n.s))+' s</b></div>';
  ORD.forEach(function(c){var v=n.c[c];if(v)h+='<div class="tr2"><span><i class="sw" style="--sw:'+col(c)+'"></i>'+esc(c)+'</span><b>'+fs(sec(v))+' s '+MID+' '+pc(v,n.s)+'</b></div>';});
  if(n.id===0&&P.nol)h+='<span class="tm">'+P.nol+' sample'+(P.nol!==1?'s':'')+' without a plan line counted here</span><br>';
  if(d.chain.length>1){var up=d.chain.slice(0,-1),nm=function(c){return esc(stepTxt(c))+' ('+c.id+')';};
    h+='<span class="tm">Folded into this bar, no samples of their own: '+(up.length<=3?up.map(nm).join(', '):up.length+' steps, '+nm(up[0])+' down to '+nm(up[up.length-1]))+'</span><br>';}
  if(d.lost)h+='<span class="tm">'+d.lost+' step'+(d.lost!==1?'s':'')+' without samples folded</span><br>';
  if(d.cut)h+='<span class="tm">Deeper steps not drawn: see the plan table</span>';
  return h+'<span class="tm">'+(P.r==='old'?'mean of '+div+' prior window'+(div!==1?'s':''):'Current window')+', '+(n.s?n.s+' sample'+(n.s!==1?'s':'')+' on the step':'no sample on the step')+'</span>';
}
/* ---- one icicle */
/* the first candidate label that fits the bar, measured on the real text
   (an estimate only when the text cannot be measured) */
function label(g,d,x,y,w,sx,onc,P){
  /* on a bar mostly coloured by its own samples the label is white on the
     colour; else it stays on the neutral part left of the colour */
  var lx=onc?Math.max(x,sx):x,room=onc?x+w-lx-10:sx-x-9;
  if(room<14)return;
  var n=d.n,full=stepTxt(n),sec=fs(d.t*(D.spw||10)/(P.div||1))+' s';
  var cand=[full+'  '+sec,full,n.obj?n.op+' '+n.obj:null,n.obj||(n.op+(n.opt?' '+n.opt:'')),n.op];
  var t=el('text',{'class':'pf-lb'+(onc?' onc':''),x:lx+5,y:y+RH/2+4},g),len=function(s){t.textContent=s;var v=0;try{v=t.getComputedTextLength();}catch(e){}return v>0?v:s.length*6.6;};
  for(var i=0;i<cand.length;i++){if(cand[i]&&len(cand[i])<=room)return;}
  var base=n.obj||n.op;
  for(var m=base.length-1;m>=3;m--){if(len(base.slice(0,m)+ELL)<=room)return;}
  g.removeChild(t);
}
function drawPlan(box,P,dt,k,SW,blk){
  box.textContent='';
  var W=box.clientWidth,rows=Math.min(depth(dt),MAXR),H=rows*RH+30;
  var svg=el('svg',{width:W,height:H,viewBox:'0 0 '+W+' '+H,'class':'pf-svg',role:'img'},box);
  var tot=dt.t,div=P.div||1;
  var hot=null;(function f(d){if(d.sl)return;if(!hot||d.n.s>hot.n.s)hot=d;d.kids.forEach(f);})(dt);
  svg.setAttribute('aria-label','Icicle chart of plan '+P.phv+': '+fs(tot*(D.spw||10)/div)+' s of DB time per window'+(hot?'; most on '+stepTxt(hot.n)+', line '+hot.n.id:''));
  var nodes=[];
  function wOf(d){return d.t/div*k+(d.nsl||0)*SW;}
  function draw(d,x,y,row,par){
    var w=wOf(d),g=el('g',{'class':d.sl?'pf-g pf-s':'pf-g',tabindex:'-1'},svg);
    g._pf={d:d,par:par,kids:[],x:x,y:y,w:w};if(par)par._pf.kids.push(g);nodes.push(g);
    if(d.sl){if(SW>0)el('rect',{x:x+0.5,y:y+1,width:Math.max(0.8,SW-1),height:RH-2,'class':'pf-slr'},g);return g;}
    var n=d.n;if(n.obj)g.setAttribute('data-o',(n.own||'')+'.'+n.obj);
    el('rect',{x:x+0.5,y:y+0.5,width:Math.max(1,w-1),height:RH-1,rx:2,'class':'pf-bg'},g);
    var sw=n.s/div*k,sx=x+w-sw,cls=ORD.filter(function(c){return n.c[c];}).sort(function(a,b){return n.c[b]-n.c[a];}),cx=sx;
    var csum=0;cls.forEach(function(c){csum+=n.c[c];});
    cls.forEach(function(c){var cw2=sw*n.c[c]/(csum||1);if(cw2>0.15)el('rect',{x:cx+0.5,y:y+1,width:Math.max(0.6,cw2-(cw2>2?1:0)),height:RH-2,'class':'pf-own',style:'fill:'+col(c)},g);cx+=cw2;});
    if(row>=MAXR-1&&d.kids.some(function(q){return !q.sl;})){d.cut=1;el('line',{x1:x+1,x2:x+w-1,y1:y+RH-1,y2:y+RH-1,'class':'pf-cut'},g);}
    label(g,d,x,y,w,sx,sx<=x+w*0.45,P);
    if(!d.cut&&row<MAXR-1){var kx=x;d.kids.forEach(function(q){draw(q,kx,y+RH,row+1,g);kx+=wOf(q);});}
    return g;
  }
  var root=draw(dt,0,0,0,null);
  /* scale bar */
  var tgt=W/4,nice=[1,2,5,10,20,30,60,120,300,600,1200,1800,3600],sv=nice[0],spw=D.spw||10;
  nice.forEach(function(v){if(v/spw*k<=tgt)sv=v;});
  var bl=sv/spw*k,by=rows*RH+14;
  if(bl>=8){el('line',{x1:0.5,x2:bl,y1:by,y2:by,'class':'pf-ax'},svg);el('line',{x1:0.5,x2:0.5,y1:by-4,y2:by+4,'class':'pf-ax'},svg);el('line',{x1:bl,x2:bl,y1:by-4,y2:by+4,'class':'pf-ax'},svg);
    var t=el('text',{x:bl+6,y:by+4,'class':'pf-axl'},svg);t.textContent=sv+' s of DB time per window';}
  /* interaction */
  root.setAttribute('tabindex','0');
  nodes.forEach(function(g){
    var d=g._pf.d;
    g.addEventListener('mouseenter',function(e){same(blk,g,true);tipOn(tipHtml(d,P,tot),e.clientX,e.clientY);});
    g.addEventListener('mousemove',function(e){if(TIP&&!TIP.hidden)tipOn(TIP.innerHTML,e.clientX,e.clientY);});
    g.addEventListener('mouseleave',function(){same(blk,g,false);tipOff();});
    g.addEventListener('focus',function(){same(blk,g,true);var r=g.getBoundingClientRect();tipOn(tipHtml(d,P,tot),r.left+Math.min(r.width,40),r.bottom);});
    g.addEventListener('blur',function(){same(blk,g,false);tipOff();});
    g.addEventListener('click',function(){open(blk,box,d);});
    g.addEventListener('keydown',function(e){var f=g._pf,to=null,sib=f.par?f.par._pf.kids:[g],i=sib.indexOf(g);
      if(e.key==='ArrowDown')to=f.kids[0];else if(e.key==='ArrowUp')to=f.par;
      else if(e.key==='ArrowRight')to=sib[i+1];else if(e.key==='ArrowLeft')to=sib[i-1];
      else if(e.key==='Enter'||e.key===' '){e.preventDefault();open(blk,box,d);return;}
      else if(e.key==='Escape'){tipOff();return;}
      if(to){e.preventDefault();g.setAttribute('tabindex','-1');to.setAttribute('tabindex','0');to.focus();}});
  });
}
/* the same object in both plans lights up */
function same(blk,g,on){var o=g.getAttribute('data-o');g.classList.toggle('pf-hov',on);if(!o)return;
  blk.querySelectorAll('.pf-g[data-o]').forEach(function(x){if(x.getAttribute('data-o')===o)x.classList.toggle('pf-same',on);});}
/* click / Enter: the step's row in the plan table */
function open(blk,box,d){
  if(d.sl&&!d.n)return;var q=box.getAttribute('data-q'),tb=blk.querySelector('table.pf-tb[data-pl="'+q+'"]');if(!tb)return;
  var tr=tb.querySelector('tr[data-ln="'+d.n.id+'"]');if(!tr)return;
  var det=tb.closest('details');if(det)det.open=true;
  if(window.AWR_goTo)window.AWR_goTo(tr,true,false);else tr.scrollIntoView({block:'center'});
}
/* ---- one statement: both plans on one scale */
function drawBlock(B){
  var ok=B.plots.filter(function(x){return x.box.clientWidth>0;});
  if(!ok.length)return;
  var key=ok.map(function(x){return x.box.clientWidth;}).join(',');
  if(key===B.key)return;B.key=key;
  var SW=4;
  ok.forEach(function(x){var s=x.nsl;if(s*SW>0.3*x.box.clientWidth)SW=Math.min(SW,0.3*x.box.clientWidth/s);});
  if(SW<1)SW=0;
  var k=Infinity;
  ok.forEach(function(x){var T=x.dt.t/(x.P.div||1);if(T>0)k=Math.min(k,(x.box.clientWidth-x.nsl*SW-1)/T);});
  if(!isFinite(k)||k<=0)return;
  ok.forEach(function(x){drawPlan(x.box,x.P,x.dt,k,SW,B.el);});
}
function drawAll(force){if(!D)return;BL.forEach(function(B){if(force)B.key=null;drawBlock(B);});}
var BL=[];
function legend(){
  var lg=doc.querySelector('#plan-flame .pf-lg');if(!lg)return;var seen={},h='';
  D.st.forEach(function(s){s.p.forEach(function(P){P.s.forEach(function(a){for(var c in a[7])if(a[7].hasOwnProperty(c))seen[c]=1;});});});
  ORD.forEach(function(c){if(seen[c])h+='<span><i class="pf-sw" style="background:'+col(c)+'"></i>'+esc(c)+' on the step itself</span>';});
  h+='<span><i class="pf-sw pf-swn"></i>time in the steps below</span><span><i class="pf-sw pf-sws"></i>step without samples</span>';
  h+='<span class="pf-lgh">Hover or focus a step (arrow keys move, Enter opens its table row); the same object lights up in the other plan.</span>';
  lg.innerHTML=h;
}
/* the plan-change card of section 18 gets a "Plan shape" link */
function cardLinks(){
  D.st.forEach(function(s){
    var c=doc.getElementById('f-plan-'+s.sql);if(!c||c.querySelector('a.pf-cl'))return;
    var f=c.querySelector('.fc-f');if(!f)return;var e=f.querySelector('.evl')||f;
    var a=doc.createElement('a');a.className='pf-cl';a.href='#'+s.id;a.textContent='Plan shape';
    e.insertBefore(a,e.firstChild);
  });
}
doc.addEventListener('DOMContentLoaded',function(){
  D=(window.AWR_DATA||{}).planflame||null;if(!D||!D.st)return;
  var sec=doc.getElementById('plan-flame');if(!sec)return;
  sec.classList.add('pf-js');
  TIP=doc.createElement('div');TIP.className='planflame-tip';TIP.setAttribute('role','tooltip');TIP.hidden=true;doc.body.appendChild(TIP);
  legend();
  D.st.forEach(function(s){
    var blk=doc.getElementById(s.id);if(!blk)return;var B={el:blk,plots:[],key:null};
    blk.querySelectorAll('.pf-plot[data-q]').forEach(function(box){
      var P=s.p[+box.getAttribute('data-q')];if(!P||P.state!=='Y')return;
      var root=build(P);if(!root||!root.t)return;
      var dt=disp(root,rowsOf(root)>CAP);
      B.plots.push({box:box,P:P,dt:dt,nsl:slivers(dt,0)});
    });
    if(B.plots.length)BL.push(B);
    if(window.ResizeObserver){var ro=new ResizeObserver(function(){drawBlock(B);});B.plots.forEach(function(x){ro.observe(x.box);});}
  });
  if(!BL.length){var lg=sec.querySelector('.pf-lg');if(lg)lg.hidden=true;}
  cardLinks();
  drawAll(true);
  window.addEventListener('resize',function(){drawAll(false);});
  doc.addEventListener('awr:view',function(){setTimeout(function(){drawAll(false);},30);});
  doc.addEventListener('toggle',function(){drawAll(false);},true);
  doc.addEventListener('scroll',tipOff,{passive:true});
});
})();
