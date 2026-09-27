(function(){
var doc=document, W=window.AWR_WG=window.AWR_WG||{}, TL=window.AWR_TL={};
var H1=36e5, MINUS='\u2212';
function $(s,r){return (r||doc).querySelector(s);}
function $$(s,r){return Array.prototype.slice.call((r||doc).querySelectorAll(s));}
function shown(el){return !!el&&el.getClientRects().length>0;}
function mk(t,c,p){var e=doc.createElement(t);if(c)e.className=c;if(p)p.appendChild(e);return e;}
function esc(s){return String(s==null?'':s).replace(/[&<>"]/g,function(c){return {'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c];});}
function num(s){if(s==null||s==='')return null;var v=+s;return isNaN(v)?null:v;}
function nums(s){return String(s||'').split(',').map(num);}
function cssNum(el,n,d){var v=parseFloat(getComputedStyle(el).getPropertyValue(n));return isNaN(v)?d:v;}
function reduced(){try{return matchMedia('(prefers-reduced-motion: reduce)').matches;}catch(e){return false;}}
/* sql/lib/fmt_num.plsql, client side: about 4 significant digits, k / M / G */
function grp(n){return String(n).replace(/\B(?=(\d{3})+(?!\d))/g,',');}
function fmtNum(p){
  if(p==null)return '\u2014';if(p===0)return '0';
  var a=Math.abs(p),s=p<0?'-':'',u='',v=a,t;
  if(a>=1e9){v=a/1e9;u=' G';}else if(a>=1e6){v=a/1e6;u=' M';}else if(a>=1e4){v=a/1e3;u=' k';}
  if(v>=1000)t=grp(Math.round(v));else if(v>=100)t=grp(v.toFixed(1));else if(v>=10)t=v.toFixed(2);else if(v>=1)t=v.toFixed(3);
  else{var d=Math.min(6,3-Math.floor(Math.log10(v)));if(Math.round(v*1e6)===0)return s+'<0.000001';t=String(+v.toFixed(d));if(t.charAt(0)!=='0')t='0'+t.slice(t.indexOf('.'));}
  return s+t+u;
}
/* the page's one Delta rule (sql/lib/band_glyph.plsql delta_span) */
function delta(cur,mu){
  if(cur==null||mu==null||mu===0)return '\u2014';
  var q=cur/mu;
  if(mu>0&&q>=2)return '\u25b2 \u00d7'+(q<100?q.toFixed(1):Math.round(q));
  var p=(cur-mu)/Math.abs(mu)*100;
  return (p>=0?'\u25b2 ':'\u25bc ')+Math.abs(p).toFixed(1)+'%';
}
function aasTxt(v){return v>=10?v.toFixed(0):v>=1?v.toFixed(1):v>=0.01?v.toFixed(2):v.toPrecision(1);}
function niceStep(max,n){var raw=max/n,p=Math.pow(10,Math.floor(Math.log10(raw))),m=raw/p;return (m<=1?1:m<=2?2:m<=5?5:10)*p;}
/* the compared windows, oldest first (window.AWR_WIN from 00_params.sql) */
function wins(){return (window.AWR_WIN&&window.AWR_WIN.w)||[];}
function winAt(o){var w=wins();for(var i=0;i<w.length;i++)if(w[i].o===+o)return w[i];return null;}
function idxOf(o){var w=wins();for(var i=0;i<w.length;i++)if(w[i].o===+o)return i;return -1;}
function offTxt(w){return w.o===0?'Current':String(w.l).replace('-',MINUS);}
function wcol(c){return (window.AWR_WAIT_COLORS||{})[c]||'#9AA3AD';}
var MON=['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'],DOW=['Sun','Mon','Tue','Wed','Thu','Fri','Sat'];
function PT(s){return Date.parse(String(s).replace(' ','T')+':00Z');}
function p2(n){return (n<10?'0':'')+n;}
function fDay(t){var d=new Date(t);return d.getUTCDate()+' '+MON[d.getUTCMonth()];}
function fAt(t){var d=new Date(t);return DOW[d.getUTCDay()]+' '+fDay(t)+' '+p2(d.getUTCHours())+':'+p2(d.getUTCMinutes());}
function fHM(t){var d=new Date(t);return p2(d.getUTCHours())+':'+p2(d.getUTCMinutes());}
/* ---- 1. lane sources: a section's rows ride in <template class="tl-src">,
   the inline script right after it calls take() while the page parses */
TL.take=function(){
  var s=doc.currentScript,t=s&&s.previousElementSibling;
  if(!t||t.tagName!=='TEMPLATE')return;
  var lane=doc.getElementById(t.getAttribute('data-lane')),box=lane&&$('.lrows',lane);
  if(!box)return;
  Array.prototype.slice.call(t.content.children).forEach(function(r){
    var a=r.getAttribute('data-after'),ref=a?doc.getElementById(a):null;
    if(ref&&ref.parentNode===box){
      while(ref.nextElementSibling&&ref.nextElementSibling.getAttribute('data-after')===a)ref=ref.nextElementSibling;
      box.insertBefore(r,ref.nextElementSibling);
    }else box.appendChild(r);
  });
  lane.hidden=false;
  t.parentNode.removeChild(t);
};
/* open whatever hides a Timeline row: a closed lane, the folded rows */
TL.reveal=function(el){
  var lane=el&&el.closest?el.closest('#tl .lane'):null;if(!lane)return;
  if(lane.classList.contains('closed')){lane.classList.remove('closed');var b=$('.lt2',lane);if(b)b.setAttribute('aria-expanded','true');}
  if(el.classList.contains('more'))showMore(lane);
  setTimeout(function(){if(W.render)W.render(lane);},0);
};
function showMore(lane){lane.classList.add('showmore');var b=$('.xpb',lane);if(b)b.setAttribute('aria-expanded','true');if(W.render)W.render(lane);}
/* ---- 2. lanes: fold toggles, "+ Show N more", counts in the lane head */
function laneMeta(lane){
  var m=$('.gh2 .meta',lane);if(!m)return[0,0];
  var rows=$$('.lrows > .r',lane),kind=lane.getAttribute('data-kind'),h='',lg=0,md=0,nr=0;
  rows.forEach(function(r){if(r.classList.contains('twin')||r.classList.contains('xpr'))return;var s=r.getAttribute('data-sev');if(s==='large')lg++;else if(s==='moderate')md++;else if(s)nr++;});
  if(kind==='scored'){
    if(lg)h+='<span><i class="dotk large"></i>'+lg+' large</span>';
    if(md)h+='<span><i class="dotk moderate"></i>'+md+' moderate</span>';
    if(nr)h+='<span><i class="dotk typical"></i>'+nr+' normal</span>';
  }else if(kind==='sql'){
    var pc=$$('.r:not(.sub) .glf.gp',lane).length,nw=$$('.glf.gn',lane).length,dp=$$('.glf.gd',lane).length;
    if(pc)h+='<span><b>\u25c6</b> '+pc+' plan change'+(pc>1?'s':'')+'</span>';
    if(nw)h+='<span><b>\u271a</b> '+nw+' new</span>';
    if(dp)h+='<span><b>\u25bd</b> '+dp+' DOP</span>';
    if(!h)h='<span class="muted">ranked, not scored</span>';
  }else if(kind==='config'){
    var n=0,f=0;
    rows.forEach(function(r){if(!r.classList.contains('p'))return;n++;var hit=false;$$('.c',r).forEach(function(c){if($('.nd',c)&&W.markerAt&&W.markerAt(+c.getAttribute('data-w')))hit=true;});if(hit)f++;});
    h='<span class="muted">'+(f&&f===n?(n>1?'all '+n+' under a flag':'under a flag'):f?f+' of '+n+' under a flag':n+' changed')+'</span>';
  }else h='<span class="muted">'+esc(lane.getAttribute('data-note')||'not scored')+'</span>';
  m.innerHTML=h;
  return [lg,md];
}
function lanes(){
  var tl=doc.getElementById('tl');if(!tl)return;
  var np=wins().length,tot=[0,0];
  $$('.lane',tl).forEach(function(lane){
    var more=$$('.lrows > .r.more',lane);
    if(more.length&&!$('.r.xpr',lane)){
      var x=doc.createElement('div');x.className='r xpr';x.setAttribute('role','row');
      var h='<div class="l" role="rowheader"><button class="xpb" type="button" aria-expanded="false">+ Show '+more.length+' more '+esc(lane.getAttribute('data-noun')||'rows')+'</button></div>';
      wins().forEach(function(w){h+='<div class="c'+(w.o===0?' cur':'')+'" data-w="'+w.o+'"></div>';});
      x.innerHTML=h+'<div class="g" role="cell"></div>';
      more[0].parentNode.insertBefore(x,more[0]);
      $('.xpb',x).addEventListener('click',function(){showMore(lane);});
    }
    var n=laneMeta(lane);tot[0]+=n[0];tot[1]+=n[1];
    var b=$('.lt2',lane);
    if(b)b.addEventListener('click',function(){var open=lane.classList.toggle('closed')===false;b.setAttribute('aria-expanded',String(open));if(open&&W.render)W.render(lane);});
    var rl=doc.querySelector('nav.toc a[href="#'+lane.id+'"]');
    if(rl){rl.hidden=lane.hidden;if(n[0]){var p=mk('span','cnt c',rl);p.textContent=n[0];}if(n[1]){var q=mk('span','cnt w',rl);q.textContent=n[1];}}
    var jn=$('.jumpnav a[href="#'+lane.id+'"]',tl);if(jn)jn.hidden=lane.hidden;
  });
  var h2=$('#timeline > h2');
  if(h2&&!$('.meta',h2)&&(tot[0]||tot[1])){var m=mk('span','meta');m.innerHTML=(tot[0]?'<span><i class="dotk large"></i>'+tot[0]+' large</span>':'')+(tot[1]?'<span><i class="dotk moderate"></i>'+tot[1]+' moderate</span>':'');h2.appendChild(m);}
  if(!np)return;
  /* a skipped window (no valid snapshot pair) greys its date in the ruler */
  wins().forEach(function(w){if(w.v!=='N')return;var h=$('.ruler .h[data-w="'+w.o+'"]',tl);if(h){h.classList.add('skw');h.title+=' (skipped window: left out of every baseline)';}});
  /* the prior values, filled from data-v (shown on hover / pin) */
  $$('.r.bars[data-v]',tl).forEach(function(row){
    var v=nums(row.getAttribute('data-v'));
    $$(':scope > .c[data-w]',row).forEach(function(c){
      if($('.v',c))return;var x=v[idxOf(c.getAttribute('data-w'))];
      c.insertAdjacentHTML('afterbegin',x==null?'<span class="v nil" aria-label="no value">\u2013</span>':'<span class="v">'+fmtNum(x)+'</span>');
    });
  });
}
/* ---- 3. pin a window: its column tints, the gutter compares against it */
var PW=null;
W.pinned=function(){return PW;};
function flashCol(o){
  $$('#tl .c[data-w="'+o+'"], #tl .ruler .h[data-w="'+o+'"]').forEach(function(c){c.classList.remove('colflash');void c.offsetWidth;c.classList.add('colflash');});
}
W.pin=function(o){
  var tl=doc.getElementById('tl');if(!tl)return;
  o=(o==null||o==='')?null:+o;
  var same=(PW!==null&&o===PW),bd=doc.body,gt=doc.getElementById('tl-gt'),gs=doc.getElementById('tl-gs');
  $$('.ruler .h[aria-pressed]',tl).forEach(function(h){h.setAttribute('aria-pressed','false');});
  $$('.pc',tl).forEach(function(x){x.classList.remove('pc');});
  $$('.r .g .d1[data-orig]',tl).forEach(function(d){d.innerHTML=d.getAttribute('data-orig');d.removeAttribute('data-orig');});
  if(same||o===null||o===0){
    PW=null;bd.removeAttribute('data-pw');
    if(gt)gt.textContent='vs prior mean';if(gs)gs.textContent='click a date to pin';
    drawAll(true);return;
  }
  var w=winAt(o),i=idxOf(o);if(!w)return;
  PW=o;bd.setAttribute('data-pw',String(o));
  var h=$('.ruler .h[data-w="'+o+'"]',tl);if(h)h.setAttribute('aria-pressed','true');
  $$('[data-w="'+o+'"]',tl).forEach(function(x){if(!x.closest('.flags'))x.classList.add('pc');});
  $$('.r.bars[data-v]',tl).forEach(function(row){
    var d=$(':scope > .g .d1',row);if(!d)return;
    var v=nums(row.getAttribute('data-v'));
    d.setAttribute('data-orig',d.innerHTML);
    d.textContent=delta(v[v.length-1],v[i])+' vs '+w.d;
  });
  if(gt){gt.innerHTML='vs '+esc(w.d)+' <button type="button" class="unpin" aria-label="Clear the pinned window">clear</button>';$('.unpin',gt).addEventListener('click',function(){W.pin(null);});}
  if(gs)gs.textContent='band stays vs prior mean';
  drawAll(true);
};
doc.addEventListener('click',function(ev){
  var h=ev.target&&ev.target.closest?ev.target.closest('#tl .ruler .h[data-w]'):null;if(!h)return;
  var o=+h.getAttribute('data-w');
  if(o===0){W.pin(null);flashCol(0);}else W.pin(o);
});
doc.addEventListener('keydown',function(ev){if(ev.key==='Escape'&&PW!==null)W.pin(null);});
/* the pin survives a view switch: the Activity charts that show it are at
   the top of every view (Esc, Current or the gutter's clear unpin) */
doc.addEventListener('awr:view',function(ev){
  var v=ev.detail&&ev.detail.view;
  setTimeout(function(){drawAll(true);if(v==='timeline'){sync();startAtCurrent();}},50);
});
/* ---- 4. tooltip over the grid and the full-span chart */
var tip=null;
function tipOn(html,e){if(!tip)return;tip.innerHTML=html;tip.hidden=false;place(e);}
function tipOff(){if(tip)tip.hidden=true;}
function place(e){
  var x=e.clientX+14,y=e.clientY+16,w=tip.offsetWidth,h=tip.offsetHeight;
  if(x+w>innerWidth-8)x=e.clientX-w-12;if(y+h>innerHeight-8)y=e.clientY-h-12;
  tip.style.left=Math.max(8,x)+'px';tip.style.top=Math.max(8,y)+'px';
}
/* per-series AAS rows, top of the stack first; names / colours from the
   payload (classes or events), vis = the legend state (null = all) */
function ashRows(names,cols,get,vis,noun){
  var h='',tot=0,hid=false;
  for(var c=names.length-1;c>=0;c--){if(vis&&!vis[c]){hid=true;continue;}var v=get(c);if(v==null)continue;tot+=v;
    if(v>=0.005)h+='<div class="tr2"><span><i class="sw" style="--sw:'+cols[c]+'"></i>'+esc(names[c])+'</span><b>'+v.toFixed(2)+'</b></div>';}
  return h+'<div class="tr2 tsum"><span>'+(hid?'Total, shown '+(noun||'classes'):'Total')+'</span><b>'+tot.toFixed(1)+' AAS</b></div>';
}
function cellTip(cell){
  var row=cell.closest('.r');if(!row||!row.getAttribute('data-name'))return '';
  var o=+cell.getAttribute('data-w'),w=winAt(o),i=idxOf(o);if(!w)return '';
  var head='<b>'+esc(row.getAttribute('data-name'))+'</b><br><span class="tm">'+esc(w.t)+', '+offTxt(w)+(w.v==='N'?', skipped window':'')+'</span><br>';
  if(row.classList.contains('ash')&&AX&&AX.win)return head+ashRows(AX.classes,AX.classes.map(wcol),function(c){return AX.win[c][i];});
  if(row.classList.contains('p'))return head+'<b>'+esc(cell.getAttribute('data-pv')||'')+'</b>';
  var v=nums(row.getAttribute('data-v'))[i];
  if(v==null)return head+'<span class="tm">'+(row.classList.contains('q')||row.classList.contains('o')?'not in the top list in this window':'no value in this window')+'</span>';
  var g=$('.glf',cell);
  return head+'<b>'+fmtNum(v)+'</b> '+esc(row.getAttribute('data-unit')||'')+(g?'<br>'+esc(g.title):'');
}
doc.addEventListener('mouseover',function(e){
  var t=e.target;if(!t||!t.closest||!tip)return;
  if(t.closest('.ashx .axp'))return;
  var c=t.closest('#tl .lrows .c[data-w]');
  if(c){var s=cellTip(c);if(s){tipOn(s,e);return;}}
  tipOff();
});
doc.addEventListener('mousemove',function(e){if(tip&&!tip.hidden&&!(e.target.closest&&e.target.closest('.ashx .axp')))place(e);},{passive:true});
doc.addEventListener('scroll',tipOff,{passive:true});
/* ---- 5. stacked activity per window: the Activity lane and the DB time card */
function stack(row,vals,opt){
  var A=AX,np=wins().length,tot=[],mx=0;
  for(var i=0;i<np;i++){var s=0;A.classes.forEach(function(c,k){s+=vals[k][i]||0;});tot.push(s);if(s>mx)mx=s;}
  if(!(mx>0))return false;
  var step=niceStep(mx,3),max=mx*1.04,ticks=[];for(var t=step;t<=max+1e-9;t+=step)ticks.push(t);
  var bh=cssNum(row,'--bh',148),bb=cssNum(row,'--bb',6),GAP=2;
  $$(':scope > .c[data-w]',row).forEach(function(c){
    var i=idxOf(c.getAttribute('data-w'));if(i<0)return;
    $$('.stk,.gline,.dl',c).forEach(function(x){x.parentNode.removeChild(x);});
    ticks.forEach(function(t){var g=mk('i','gline',c);g.style.bottom=(bb+t/max*bh)+'px';});
    var st=mk('div','stk',c),y=0,segs=[];
    A.classes.forEach(function(name,k){
      var v=vals[k][i]||0,h=v/max*bh;if(h<0.4)return;
      var s=mk('i','',st);s.style.background=wcol(name);s.style.bottom=y+'px';s.style.height=Math.max(0.6,h-(h>4?GAP:0))+'px';
      segs.push({n:name,v:v,mid:y+h/2});y+=h;
    });
    if(c.classList.contains('cur')&&opt.labels){
      var last=-99;
      segs.slice().sort(function(a,b){return b.v-a.v;}).slice(0,2).sort(function(a,b){return a.mid-b.mid;}).forEach(function(s){
        if(s.v/max*bh<8)return;
        var pos=Math.max(s.mid,last+16);last=pos;
        var d=mk('span','dl',c);d.innerHTML='<i class="sw" style="--sw:'+wcol(s.n)+'"></i>'+aasTxt(s.v);d.title=s.n;d.style.bottom=(bb+pos)+'px';
      });
    }
  });
  var ax=$('.axn',row);
  if(ax){ax.innerHTML='';[0].concat(ticks).forEach(function(t){var i=mk('i','',ax);i.textContent=t;i.style.bottom=(bb+t/max*bh)+'px';});}
  return true;
}
function activity(){
  if(!AX||!AX.win||!AX.classes.length)return;
  $$('#tl .r.ash').forEach(function(row){stack(row,AX.win,{labels:true});});
  /* the DB time card: FOREGROUND ASH per window, stacked by wait class.
     DB time is foreground time and ASH's foreground samples are its
     sampled estimate, so the bars measure what the headline measures;
     the Current value printed stays the card's DB time. */
  var row=$('#f-dbtime .fc-main .wg .r.bars');if(!row)return;
  var W=AX.winfg||AX.win,np=wins().length,cur=[];
  AX.classes.forEach(function(c,k){cur.push([c,W[k][np-1]||0,k]);});
  cur.sort(function(a,b){return b[1]-a[1];});
  row.classList.remove('bars');row.classList.add('ash');
  if(!stack(row,W,{labels:true})){row.classList.remove('ash');row.classList.add('bars');return;}
  var tot=0;cur.forEach(function(x){tot+=x[1];});
  $$(':scope > .c',row).forEach(function(c){var v=$('.v',c);if(v&&!c.classList.contains('cur'))v.parentNode.removeChild(v);});
  $$(':scope > .c > i',row).forEach(function(x){x.parentNode.removeChild(x);});
  var ul=doc.createElement('ul');ul.className='leg fcleg';ul.setAttribute('aria-label','Foreground active sessions by wait class, ASH');
  ul.innerHTML=cur.filter(function(x){return x[1]>0;}).map(function(x){return '<li><i class="sw" style="--sw:'+wcol(x[0])+'"></i>'+esc(x[0])+'</li>';}).join('');
  var wg=row.closest('.wg');wg.parentNode.insertBefore(ul,wg);
  wg.title='Foreground active sessions (ASH, a sampled estimate of DB time) per compared window, stacked by wait class; Current '+tot.toFixed(2)+' AAS in ASH. The Current value is the DB time headline.';
}
/* ---- 6. Activity, whole span (section#activity, top of every view): one
   chart factory, two instances over one time axis -- by wait class
   (AWR_DATA.ashx) and by wait event (AWR_DATA.ashe).  Linked: a zoom on
   either zooms both, the hover crosshair is mirrored, the pinned window
   (AWR_WG.pin) is the same stripe in both.  Hover, legend, brush zoom,
   Reset / double-click, window stripes, release markers in each. */
var AX=null,AE=null,CH=[],SP=null,DRAG=null,cvs=null;
/* the event palette: 15 categorical hues, the first 13 (all a chart can
   use: 14 events, CPU among them) well apart, readable on both themes, no
   green (CPU keeps the wait-class CPU green, "Other events" a fixed grey) */
var EVP=['#4E79A7','#F28E2B','#E15759','#76B7B2','#EDC948','#B07AA1','#FF9DA7','#9C755F','#A0CBE8','#D37295','#17BECF','#B6992D','#7F3C8D','#FFBE7D','#499894'],EVO='#9AA3AD';
function evColors(names){var j=0;return names.map(function(n){if(n==='CPU')return wcol('CPU');if(n==='Other events')return EVO;return EVP[(j++)%EVP.length];});}
/* a bucket's length as text: 15-min, 1-hour, 2-hour, 0.75 h = 45-min */
function bLab(h){return h<1&&Math.abs(h*60-Math.round(h*60))<1e-6?Math.round(h*60)+'-min':(Math.round(h*100)/100)+'-hour';}
/* the buckets in [a, b): first and last index, O(1) on the regular grid */
function bRange(a,b){var n=SP.T.length,i0=Math.max(0,Math.floor((a-SP.t0)/SP.bh)),i1=Math.min(n-1,Math.ceil((b-SP.t0)/SP.bh)-1);
  while(i0<n&&SP.T1[i0]<=a)i0++;while(i1>=0&&SP.T[i1]>=b)i1--;return [i0,i1];}
/* one step line through segments [x0, x1] at heights ys (SVG y strings),
   a run of equal heights drawn as one horizontal; fwd = left to right,
   else right to left (the lower edge of a band).  Starts with 'L'. */
function stepPath(sg,ys,fwd){
  var d='',n=sg.length,q,j,y;
  for(q=0;q<n;q++){j=fwd?q:n-1-q;y=ys[j];
    if(q===0||ys[fwd?j-1:j+1]!==y)d+='L'+(fwd?sg[j][0]:sg[j][1]).toFixed(1)+' '+y;
    if(q===n-1||ys[fwd?j+1:j-1]!==y)d+='L'+(fwd?sg[j][1]:sg[j][0]).toFixed(1)+' '+y;}
  return d;
}
function tw(t){if(!cvs)cvs=doc.createElement('canvas').getContext('2d');cvs.font='11px ui-sans-serif, -apple-system, "Segoe UI", Inter, Roboto, system-ui, sans-serif';return cvs.measureText(t).width;}
function okPay(P,n){return !!(P&&P.classes&&P.classes.length&&P.vals&&P.vals.length===P.classes.length&&P.vals[0]&&P.vals[0].length===n);}
function spInit(){
  var D=window.AWR_DATA||{};AX=D.ashx||null;AE=D.ashe||null;
  var panel=doc.getElementById('ashx');if(!panel)return;
  panel.hidden=false;
  var n=AX&&AX.vals&&AX.vals[0]?AX.vals[0].length:0;
  if(!AX||!AX.t0||!okPay(AX,n)){var e=$('#ax-empty',panel);if(e)e.hidden=false;$$('.axch,.axn2,.axk',panel).forEach(function(x){x.hidden=true;});return;}
  var bh=AX.bh*H1,t0=PT(AX.t0),end=PT(AX.end),T=[],T1=[];
  for(var i=0;i<n;i++){T.push(t0+i*bh);T1.push(Math.min(t0+(i+1)*bh,end));}
  SP={T:T,T1:T1,t0:t0,bh:bh,full:[t0,end],dom:[t0,end],win:wins().map(function(w){return [PT(w.s),PT(w.e)];}),
      min:Math.max(4*bh,Math.min(6*H1,(end-t0)/4)),bhTxt:AX.bh===1?'hourly':bLab(AX.bh)+' averages',
      reset:doc.getElementById('ax-reset'),range:doc.getElementById('ax-range'),sel:null};
  CH=[];
  mkChart(doc.getElementById('ax-cls'),AX,AX.classes.map(wcol),{flags:true,noun:'classes',what:'wait class'});
  var ev=doc.getElementById('ax-ev');
  if(okPay(AE,n))mkChart(ev,AE,evColors(AE.classes),{noun:'events',what:'wait event'});
  else if(ev)ev.hidden=true;
  if(CH.length)CH[CH.length-1].xl=true;
  if(SP.reset)SP.reset.addEventListener('click',spReset);
  doc.addEventListener('mousemove',function(e){
    var dg=DRAG;if(!dg)return;
    if(!dg.moved&&Math.abs(e.clientX-dg.x0)<5)return;
    dg.moved=true;tipOff();hideAll();
    var c=dg.c,r=c.svg.getBoundingClientRect(),sc=r.width/c.g.W,mn=r.left+c.g.padL*sc,mx=r.left+(c.g.W-c.g.padR)*sc;
    dg.a=Math.max(mn,Math.min(dg.x0,e.clientX));dg.b=Math.min(mx,Math.max(dg.x0,e.clientX));
    /* the brush shows on both charts: same width, same x mapping */
    CH.forEach(function(o){if(!o.g)return;var ro=o.svg.getBoundingClientRect(),so=ro.width/o.g.W;
      o.br.hidden=false;o.br.style.left=(dg.a-ro.left)+'px';o.br.style.width=Math.max(0,dg.b-dg.a)+'px';
      o.br.style.top=(o.g.top*so)+'px';o.br.style.height=(o.g.ph*so)+'px';});
  });
  doc.addEventListener('mouseup',function(){
    var dg=DRAG;if(!dg)return;DRAG=null;CH.forEach(function(o){o.br.hidden=true;});
    if(dg.moved){if(dg.b-dg.a>6)spZoom(tAt(dg.c,dg.a),tAt(dg.c,dg.b));return;}
    if(dg.w!=null){SP.sel={prev:PW,t:Date.now()};spSelect(dg.w);}
  });
}
function mkChart(root,P,cols,opt){
  if(!root)return null;
  var c={root:root,P:P,cols:cols,svg:$('.axsvg',root),plot:$('.axp',root),br:$('.axbr',root),
         vis:P.classes.map(function(){return true;}),flags:!!opt.flags,noun:opt.noun,what:opt.what,xl:false,g:null,w:0,uid:root.id};
  var lg=$('.axlg',root);
  if(lg){lg.innerHTML=P.classes.map(function(nm,k){return '<button type="button" class="axc" data-c="'+k+'" aria-pressed="true" title="Show or hide '+esc(nm)+'"><i class="sw" style="--sw:'+cols[k]+'" aria-hidden="true"></i>'+esc(nm)+'</button>';}).join('');
    $$('.axc',lg).forEach(function(b){b.addEventListener('click',function(){var k=+b.getAttribute('data-c');c.vis[k]=!c.vis[k];b.setAttribute('aria-pressed',String(c.vis[k]));draw(c,true);});});}
  var s=c.svg;
  s.addEventListener('mousemove',function(e){hover(c,e);});
  s.addEventListener('mouseleave',function(){if(!DRAG){tipOff();hideAll();}});
  s.addEventListener('mousedown',function(e){
    if(e.button!==0||!c.g)return;e.preventDefault();
    /* the second press of a double-click resets the zoom (the chart is redrawn
       between the two presses, so a dblclick event may never fire) and undoes
       the pin the first press made on a window stripe */
    if(e.detail>=2){if(SP.sel&&Date.now()-SP.sel.t<700)W.pin(SP.sel.prev);SP.sel=null;DRAG=null;spReset();return;}
    var wh=e.target.closest('.xwh');DRAG={c:c,x0:e.clientX,moved:false,w:wh?+wh.getAttribute('data-i'):null};
  });
  s.addEventListener('dblclick',spReset);
  s.addEventListener('keydown',function(e){var wh=e.target.closest&&e.target.closest('.xwh');if(wh&&(e.key==='Enter'||e.key===' ')){e.preventDefault();spSelect(+wh.getAttribute('data-i'));}});
  CH.push(c);
  return c;
}
function drawAll(force){CH.forEach(function(c){draw(c,force);});spHead();}
function spHead(){
  if(!SP)return;var d0=SP.dom[0],d1=SP.dom[1],zoomed=d0>SP.full[0]||d1<SP.full[1];
  if(SP.reset)SP.reset.hidden=!zoomed;
  if(SP.range)SP.range.textContent=zoomed?fAt(d0)+' to '+fAt(d1)+', zoomed':fDay(SP.full[0])+' to '+fDay(SP.full[1])+', '+SP.bhTxt;
}
function draw(c,force){
  if(!c||!SP||!shown(c.plot))return;
  var Wd=Math.max(480,c.plot.clientWidth),d0=SP.dom[0],d1=SP.dom[1];
  if(!force&&c.w===Wd&&c.g&&c.pw===PW&&c.g.d0===d0&&c.g.d1===d1)return;c.w=Wd;c.pw=PW;
  var mks=W.markers?W.markers():[],P=c.P,T=SP.T,T1=SP.T1;
  var top=c.flags&&mks.length?46:22,ph=150,bot=c.xl?26:8,padL=40,padR=14,H=top+ph+bot,pw=Wd-padL-padR;
  c.svg.setAttribute('viewBox','0 0 '+Wd+' '+H);c.svg.setAttribute('height',H);
  var X=function(t){return padL+pw*(t-d0)/(d1-d0);};
  /* the buckets in view, their stacked totals, and the drawn segments: one
     per bucket while a bucket is at least a pixel wide; zoomed out further,
     one per pixel column, drawn at the column's busiest bucket (largest
     stacked total), so a one-bucket spike still shows; zooming in brings
     back every bucket, and the tooltip always reads the bucket under the
     cursor */
  var br=bRange(d0,d1),i0=br[0],i1=br[1],tot=[],mx=0.05,sg=[],cb=null,i,k,sm;
  for(i=i0;i<=i1;i++){sm=0;for(k=0;k<P.vals.length;k++)if(c.vis[k])sm+=P.vals[k][i]||0;tot.push(sm);if(sm>mx)mx=sm;
    var xa=X(T[i]),xb=X(T1[i]),col=Math.floor(xa),g=sg[sg.length-1];
    if(g&&col===cb){g[1]=xb;if(sm>tot[g[2]-i0])g[2]=i;}else{sg.push([xa,xb,i]);cb=col;}}
  var step=niceStep(mx,3),ymax=Math.ceil(mx/step-1e-9)*step;
  var Y=function(v){return top+ph-ph*v/ymax;},clip='axclip-'+c.uid;
  var s='<defs><clipPath id="'+clip+'"><rect x="'+padL+'" y="'+(top-6)+'" width="'+pw+'" height="'+(ph+6)+'"/></clipPath></defs>';
  for(var v=0;v<=ymax+1e-9;v+=step){var dec=step<1?(step<0.1?2:1):0;
    s+='<line class="gl" x1="'+padL+'" x2="'+(Wd-padR)+'" y1="'+Y(v).toFixed(1)+'" y2="'+Y(v).toFixed(1)+'"/><text class="at" x="'+(padL-6)+'" y="'+(Y(v)+4).toFixed(1)+'" text-anchor="end">'+v.toFixed(dec)+'</text>';}
  s+='<text class="at" x="'+(padL-6)+'" y="'+(top-10)+'" text-anchor="end">AAS</text><g clip-path="url(#'+clip+')">';
  /* one path per series, painted top of the stack first: each fills from
     the axis up to its own cumulative height, and the series below paint
     over it, so a path is one step line plus the axis (half the markup of
     a two-edged band, and no seams); every shown series gets its path,
     even a flat one (a sparse series can be absent from every drawn
     column when zoomed out) */
  var lo=sg.map(function(){return 0;}),y0=Y(0).toFixed(1),bands=[];
  P.vals.forEach(function(vals,k){
    if(!c.vis[k]||!sg.length)return;
    var hi=lo.map(function(l,j){return l+(vals[sg[j][2]]||0);});
    bands.push('<path class="xa" fill="'+c.cols[k]+'" d="M'+sg[0][0].toFixed(1)+' '+y0
      +stepPath(sg,hi.map(function(h){return Y(h).toFixed(1);}),true)+'L'+sg[sg.length-1][1].toFixed(1)+' '+y0+'Z"/>');
    lo=hi;
  });
  s+=bands.reverse().join('');
  s+='<rect class="xbk" x="0" y="'+top+'" width="0" height="'+ph+'" visibility="hidden"/>';
  var ws=wins(),hit=[],cur=ws.length-1;
  SP.win.forEach(function(r,i){
    var xa=X(r[0]),xb=X(r[1]);if(xb<padL-2||xa>Wd-padR+2)return;
    var w=Math.max(i===cur?4:3,xb-xa),x=(xa+xb)/2-w/2,cls=(i===cur?' cur':'')+(ws[i].o===PW?' on':'')+(ws[i].v==='N'?' sk':'');
    s+='<rect class="xw'+cls+'" x="'+x.toFixed(1)+'" y="'+top+'" width="'+w.toFixed(1)+'" height="'+ph+'"/><rect class="xwc'+cls+'" x="'+x.toFixed(1)+'" y="'+(top-5)+'" width="'+w.toFixed(1)+'" height="4" rx="1"/>';
    hit.push([i,x,w]);
  });
  s+='</g><line class="ax" x1="'+padL+'" x2="'+(Wd-padR)+'" y1="'+(top+ph)+'" y2="'+(top+ph)+'"/>';
  /* x ticks: the smallest interval that leaves about 88 px per label, counted from
     midnight of the Current window's day (weekly ticks land on its weekday);
     labels on the lower chart only -- one shared axis */
  var IVS=[5/60,10/60,0.25,0.5,1,2,3,6,12,24,48,168,336,672].map(function(h){return h*H1;}),iv=IVS[IVS.length-1];
  for(var q=0;q<IVS.length;q++){if(pw*IVS[q]/(d1-d0)>=88){iv=IVS[q];break;}}
  var org=Math.floor(SP.win[cur][0]/864e5)*864e5;
  for(var tt=org+Math.ceil((d0-org)/iv)*iv;tt<=d1;tt+=iv){
    var xt=X(tt);if(xt<padL+12||xt>Wd-padR-12)continue;
    s+='<line class="ax" x1="'+xt.toFixed(1)+'" x2="'+xt.toFixed(1)+'" y1="'+(top+ph)+'" y2="'+(top+ph+4)+'"/>';
    if(c.xl)s+='<text class="at" x="'+xt.toFixed(1)+'" y="'+(top+ph+18)+'" text-anchor="middle">'+((iv>=24*H1||new Date(tt).getUTCHours()===0)?fDay(tt):fHM(tt))+'</text>';
  }
  /* release markers: a line through the plot on both charts; the flags (two
     tiers) on the upper one */
  var tiers=[[],[]];
  mks.forEach(function(m){
    var x=X(PT(m.at));if(x<padL||x>Wd-padR)return;
    if(!c.flags){s+='<line class="cfl" x1="'+x.toFixed(1)+'" x2="'+x.toFixed(1)+'" y1="'+top+'" y2="'+(top+ph)+'"><title>'+esc(m.l+', '+m.t)+'</title></line>';return;}
    [m.l,m.s].some(function(lb){
      var w=tw(lb)+12,x0=x+w>Wd-padR?x-w:x,end=x0!==x;
      for(var L=0;L<2;L++){
        if(tiers[L].some(function(r){return x0<r[1]+6&&x0+w>r[0]-6;}))continue;
        tiers[L].push([x0,x0+w]);var y=2+L*19;
        s+='<line class="cfl" x1="'+x.toFixed(1)+'" x2="'+x.toFixed(1)+'" y1="'+(y+16)+'" y2="'+(top+ph)+'"/><line class="cf" x1="'+x.toFixed(1)+'" x2="'+x.toFixed(1)+'" y1="'+y+'" y2="'+(y+16)+'"/>'
          +'<rect class="cfh" x="'+(end?x0:x+1).toFixed(1)+'" y="'+y+'" width="'+(w-1)+'" height="16" rx="2"/>'
          +'<text class="cft" x="'+(end?x-6:x+6).toFixed(1)+'" y="'+(y+12)+'" text-anchor="'+(end?'end':'start')+'"><title>'+esc(m.l+', '+m.t)+'</title>'+esc(lb)+'</text>';
        return true;
      }
      return false;
    });
  });
  s+='<line class="xch" x1="0" x2="0" y1="'+top+'" y2="'+(top+ph)+'" visibility="hidden"/>';
  hit.forEach(function(q){
    var i=q[0],w=ws[i],hw=Math.max(12,q[2]),hx=q[1]+q[2]/2-hw/2;
    s+='<rect class="xwh" data-i="'+i+'" data-w="'+w.o+'" x="'+hx.toFixed(1)+'" y="'+(top-6)+'" width="'+hw.toFixed(1)+'" height="'+(ph+6)+'" tabindex="0" role="button" aria-label="'
      +esc((w.o===0?'Current window, ':offTxt(w)+' window, ')+w.t+(w.o===0?'':'. Pin it'))+'"/>';
  });
  c.svg.innerHTML=s;
  c.g={X:X,W:Wd,padL:padL,padR:padR,top:top,ph:ph,pw:pw,d0:d0,d1:d1};
}
function tAt(c,cx){var r=c.svg.getBoundingClientRect(),x=(cx-r.left)*c.g.W/r.width;return c.g.d0+(x-c.g.padL)/c.g.pw*(c.g.d1-c.g.d0);}
function bucketAt(t){var j=Math.floor((t-SP.t0)/SP.bh);return j>=0&&j<SP.T.length&&t<SP.T1[j]?j:-1;}
function hideCross(c){var hb=$('.xbk',c.svg),ch=$('.xch',c.svg);if(hb){hb.setAttribute('visibility','hidden');ch.setAttribute('visibility','hidden');}}
function hideAll(){CH.forEach(hideCross);}
/* the crosshair + bucket band at time t (bucket k) on chart c */
function cross(c,t,k){
  var hb=$('.xbk',c.svg),ch=$('.xch',c.svg);if(!c.g||!hb)return;
  var xa=Math.max(c.g.padL,c.g.X(SP.T[k])),xb=Math.min(c.g.W-c.g.padR,c.g.X(SP.T1[k])),x=c.g.X(t);
  hb.setAttribute('x',xa.toFixed(1));hb.setAttribute('width',Math.max(1,xb-xa).toFixed(1));hb.setAttribute('visibility','visible');
  ch.setAttribute('x1',x.toFixed(1));ch.setAttribute('x2',x.toFixed(1));ch.setAttribute('visibility','visible');
}
function hover(c,e){
  if(!c.g||DRAG&&DRAG.moved)return;
  var wh=e.target.closest&&e.target.closest('.xwh'),P=c.P;
  if(wh){
    var i=+wh.getAttribute('data-i'),w=wins()[i];hideAll();
    tipOn('<b>'+esc(w.t)+'</b><br><span class="tm">'+(w.o===0?'Current window':offTxt(w)+' window')+(w.v==='N'?', skipped':'')+', by '+c.what+'</span>'
      +(P.win?ashRows(P.classes,c.cols,function(k){return P.win[k][i];},c.vis,c.noun):'')+(w.o===0?'':'<span class="tm">Click to pin this window</span>'),e);
    return;
  }
  var t=tAt(c,e.clientX),k=bucketAt(t);
  if(k<0||t<c.g.d0||t>c.g.d1){hideAll();tipOff();return;}
  CH.forEach(function(o){cross(o,t,k);});
  tipOn('<b>'+fAt(SP.T[k])+'\u2013'+fHM(SP.T1[k])+'</b><br><span class="tm">'+bLab((SP.T1[k]-SP.T[k])/H1)+' average, by '+c.what+'</span>'
    +ashRows(P.classes,c.cols,function(q){return P.vals[q][k];},c.vis,c.noun),e);
}
/* a window stripe: pin it (Current unpins); in the Timeline view the grid
   column flashes and comes into view */
function spSelect(i){
  var w=wins()[i];if(!w)return;
  if(w.o===0){if(PW!==null)W.pin(null);}else W.pin(w.o);
  flashCol(w.o);
  var tl=doc.getElementById('tl');if(!tl||!shown(tl))return;
  var r=tl.getBoundingClientRect();if(r.top>innerHeight-220)window.scrollBy({top:r.top-innerHeight+320,behavior:reduced()?'auto':'smooth'});
}
function spZoom(a,b){
  a=Math.max(SP.full[0],a);b=Math.min(SP.full[1],b);
  if(b-a<SP.min){var m=(a+b)/2;a=Math.max(SP.full[0],m-SP.min/2);b=Math.min(SP.full[1],a+SP.min);a=Math.max(SP.full[0],b-SP.min);}
  SP.dom=[a,b];drawAll(true);
}
function spReset(){if(!SP)return;SP.dom=SP.full.slice();drawAll(true);}
/* ---- 7. the grid's scroll: the sticky ruler follows the body, lane captions stay in view */
function sync(){var b=doc.getElementById('tl-body'),i=doc.getElementById('tl-in'),r=$('#tl > .ruler');if(!b||!i)return;if(r)r.scrollLeft=b.scrollLeft;i.style.setProperty('--sl',b.scrollLeft+'px');i.style.setProperty('--vw',b.clientWidth+'px');}
function startAtCurrent(){var b=doc.getElementById('tl-body');if(b&&b.scrollWidth>b.clientWidth+2&&!b.scrollLeft)b.scrollLeft=b.scrollWidth;sync();}
/* ---- boot */
doc.addEventListener('DOMContentLoaded',function(){
  tip=doc.getElementById('tip');if(!tip){tip=mk('div','',doc.body);tip.id='tip';tip.setAttribute('role','tooltip');tip.hidden=true;}
  $$('.sw[data-wc]').forEach(function(s){s.style.setProperty('--sw',wcol(s.getAttribute('data-wc')));});
  AX=(window.AWR_DATA||{}).ashx||null;
  lanes();
  activity();
  spInit();
  var b=doc.getElementById('tl-body');if(b)b.addEventListener('scroll',sync,{passive:true});
  var tl=doc.getElementById('tl');if(tl&&W.render)W.render(tl);
  setTimeout(function(){drawAll(true);startAtCurrent();},60);
  var rt=null;window.addEventListener('resize',function(){if(rt)clearTimeout(rt);rt=setTimeout(function(){drawAll();sync();},120);});
});
})();
