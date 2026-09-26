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
    axDraw();return;
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
  axDraw();
};
doc.addEventListener('click',function(ev){
  var h=ev.target&&ev.target.closest?ev.target.closest('#tl .ruler .h[data-w]'):null;if(!h)return;
  var o=+h.getAttribute('data-w');
  if(o===0){W.pin(null);flashCol(0);}else W.pin(o);
});
doc.addEventListener('keydown',function(ev){if(ev.key==='Escape'&&PW!==null)W.pin(null);});
doc.addEventListener('awr:view',function(ev){
  var v=ev.detail&&ev.detail.view;
  if(v!=='timeline'&&PW!==null)W.pin(null);
  if(v==='timeline')setTimeout(function(){axDraw(true);sync();startAtCurrent();},50);
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
function ashRows(get,cls){
  var h='',tot=0,A=AX;
  for(var c=A.classes.length-1;c>=0;c--){if(cls&&!cls[c])continue;var v=get(c);if(v==null)continue;tot+=v;
    if(v>=0.005)h+='<div class="tr2"><span><i class="sw" style="--sw:'+wcol(A.classes[c])+'"></i>'+esc(A.classes[c])+'</span><b>'+v.toFixed(2)+'</b></div>';}
  return h+'<div class="tr2 tsum"><span>'+(cls?'Total, shown classes':'Total')+'</span><b>'+tot.toFixed(1)+' AAS</b></div>';
}
function cellTip(cell){
  var row=cell.closest('.r');if(!row||!row.getAttribute('data-name'))return '';
  var o=+cell.getAttribute('data-w'),w=winAt(o),i=idxOf(o);if(!w)return '';
  var head='<b>'+esc(row.getAttribute('data-name'))+'</b><br><span class="tm">'+esc(w.t)+', '+offTxt(w)+(w.v==='N'?', skipped window':'')+'</span><br>';
  if(row.classList.contains('ash')&&AX&&AX.win)return head+ashRows(function(c){return AX.win[c][i];});
  if(row.classList.contains('p'))return head+'<b>'+esc(cell.getAttribute('data-pv')||'')+'</b>';
  var v=nums(row.getAttribute('data-v'))[i];
  if(v==null)return head+'<span class="tm">'+(row.classList.contains('q')||row.classList.contains('o')?'not in the top list in this window':'no value in this window')+'</span>';
  var g=$('.glf',cell);
  return head+'<b>'+fmtNum(v)+'</b> '+esc(row.getAttribute('data-unit')||'')+(g?'<br>'+esc(g.title):'');
}
doc.addEventListener('mouseover',function(e){
  var t=e.target;if(!t||!t.closest||!tip)return;
  if(t.closest('#ax-plot'))return;
  var c=t.closest('#tl .lrows .c[data-w]');
  if(c){var s=cellTip(c);if(s){tipOn(s,e);return;}}
  tipOff();
});
doc.addEventListener('mousemove',function(e){if(tip&&!tip.hidden&&!(e.target.closest&&e.target.closest('#ax-plot')))place(e);},{passive:true});
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
/* ---- 6. the full-span ASH chart: hover, legend, brush zoom, windows, markers */
var AX=null,ax=null,cvs=null;
function tw(t){if(!cvs)cvs=doc.createElement('canvas').getContext('2d');cvs.font='11px ui-sans-serif, -apple-system, "Segoe UI", Inter, Roboto, system-ui, sans-serif';return cvs.measureText(t).width;}
function axInit(){
  AX=(window.AWR_DATA||{}).ashx||null;
  var panel=doc.getElementById('tl-ash');if(!panel||!AX||!AX.t0)return;
  panel.hidden=false;
  if(!AX.classes||!AX.classes.length){var n=$('#ax-empty',panel);if(n)n.hidden=false;var p=$('#ax-plot',panel);if(p)p.hidden=true;return;}
  var bh=AX.bh*H1,t0=PT(AX.t0),end=PT(AX.end),n2=AX.vals[0].length,T=[],T1=[];
  for(var i=0;i<n2;i++){T.push(t0+i*bh);T1.push(Math.min(t0+(i+1)*bh,end));}
  ax={svg:$('#ax-svg'),plot:$('#ax-plot'),br:$('#ax-brush'),reset:$('#ax-reset'),range:$('#ax-range'),T:T,T1:T1,full:[t0,end],dom:[t0,end],
      vis:AX.classes.map(function(){return true;}),win:wins().map(function(w){return [PT(w.s),PT(w.e)];}),g:null,drag:null,w:0,
      min:Math.max(3*bh,Math.min(12*H1,(end-t0)/4)),bhTxt:AX.bh===1?'hourly':(Math.round(AX.bh*100)/100)+'-hour averages'};
  var lg=$('#ax-lg');
  if(lg){lg.innerHTML=AX.classes.map(function(c,k){return '<button type="button" class="axc" data-c="'+k+'" aria-pressed="true" title="Show or hide '+esc(c)+'"><i class="sw" style="--sw:'+wcol(c)+'" aria-hidden="true"></i>'+esc(c)+'</button>';}).join('');
    $$('.axc',lg).forEach(function(b){b.addEventListener('click',function(){var c=+b.getAttribute('data-c');ax.vis[c]=!ax.vis[c];b.setAttribute('aria-pressed',String(ax.vis[c]));axDraw(true);});});}
  var s=ax.svg;
  s.addEventListener('mousemove',axHover);
  s.addEventListener('mouseleave',function(){tipOff();axHide();});
  s.addEventListener('mousedown',function(e){
    if(e.button!==0||!ax.g)return;e.preventDefault();
    /* the second press of a double-click resets the zoom (the chart is redrawn
       between the two presses, so a dblclick event may never fire) and undoes
       the pin the first press made on a window stripe */
    if(e.detail>=2){if(ax.sel&&Date.now()-ax.sel.t<700)W.pin(ax.sel.prev);ax.sel=null;ax.drag=null;ax.dom=ax.full.slice();axDraw(true);return;}
    var wh=e.target.closest('.xwh');ax.drag={x0:e.clientX,moved:false,w:wh?+wh.getAttribute('data-i'):null};
  });
  doc.addEventListener('mousemove',function(e){
    var dg=ax.drag;if(!dg)return;
    if(!dg.moved&&Math.abs(e.clientX-dg.x0)<5)return;
    dg.moved=true;tipOff();
    var r=ax.svg.getBoundingClientRect(),sc=r.width/ax.g.W,mn=r.left+ax.g.padL*sc,mx=r.left+(ax.g.W-ax.g.padR)*sc;
    var a=Math.max(mn,Math.min(dg.x0,e.clientX)),b=Math.min(mx,Math.max(dg.x0,e.clientX));
    ax.br.hidden=false;ax.br.style.left=(a-r.left)+'px';ax.br.style.width=Math.max(0,b-a)+'px';
    ax.br.style.top=(ax.g.top*sc)+'px';ax.br.style.height=(ax.g.ph*sc)+'px';dg.a=a;dg.b=b;
  });
  doc.addEventListener('mouseup',function(){
    var dg=ax.drag;if(!dg)return;ax.drag=null;ax.br.hidden=true;
    if(dg.moved){if(dg.b-dg.a>6)axZoom(axTime(dg.a),axTime(dg.b));return;}
    if(dg.w!=null){ax.sel={prev:PW,t:Date.now()};axSelect(dg.w);}
  });
  s.addEventListener('dblclick',function(){ax.dom=ax.full.slice();axDraw(true);});
  s.addEventListener('keydown',function(e){var wh=e.target.closest&&e.target.closest('.xwh');if(wh&&(e.key==='Enter'||e.key===' ')){e.preventDefault();axSelect(+wh.getAttribute('data-i'));}});
  ax.reset.addEventListener('click',function(){ax.dom=ax.full.slice();axDraw(true);});
}
function axHide(){var hb=doc.getElementById('ax-hb'),ch=doc.getElementById('ax-ch');if(hb){hb.setAttribute('visibility','hidden');ch.setAttribute('visibility','hidden');}}
function axDraw(force){
  if(!ax||!shown(ax.plot))return;
  var Wd=Math.max(480,ax.plot.clientWidth);if(!force&&ax.w===Wd&&ax.g&&ax.pw===PW)return;ax.w=Wd;ax.pw=PW;
  var top=44,ph=236,bot=26,padL=40,padR=14,H=top+ph+bot,pw=Wd-padL-padR,d0=ax.dom[0],d1=ax.dom[1],A=AX;
  ax.svg.setAttribute('viewBox','0 0 '+Wd+' '+H);ax.svg.setAttribute('height',H);
  var X=function(t){return padL+pw*(t-d0)/(d1-d0);};
  var idx=[];for(var i=0;i<ax.T.length;i++)if(ax.T1[i]>d0&&ax.T[i]<d1)idx.push(i);
  var tot=idx.map(function(i){var s=0;A.vals.forEach(function(v,c){if(ax.vis[c])s+=v[i]||0;});return s;});
  var mx=Math.max.apply(null,tot.concat([0.05])),step=niceStep(mx,4),ymax=Math.ceil(mx/step-1e-9)*step;
  var Y=function(v){return top+ph-ph*v/ymax;};
  var s='<defs><clipPath id="ax-clip"><rect x="'+padL+'" y="'+(top-6)+'" width="'+pw+'" height="'+(ph+6)+'"/></clipPath></defs>';
  for(var v=0;v<=ymax+1e-9;v+=step){var dec=step<1?(step<0.1?2:1):0;
    s+='<line class="gl" x1="'+padL+'" x2="'+(Wd-padR)+'" y1="'+Y(v).toFixed(1)+'" y2="'+Y(v).toFixed(1)+'"/><text class="at" x="'+(padL-6)+'" y="'+(Y(v)+4).toFixed(1)+'" text-anchor="end">'+v.toFixed(dec)+'</text>';}
  s+='<text class="at" x="'+(padL-6)+'" y="'+(top-10)+'" text-anchor="end">AAS</text><g clip-path="url(#ax-clip)">';
  var lo=idx.map(function(){return 0;});
  A.vals.forEach(function(vals,c){
    if(!ax.vis[c]||!idx.length)return;
    var hi=lo.map(function(l,j){return l+(vals[idx[j]]||0);}),d='';
    idx.forEach(function(i,j){var y=Y(hi[j]).toFixed(1);d+=(j?'L':'M')+X(ax.T[i]).toFixed(1)+' '+y+'L'+X(ax.T1[i]).toFixed(1)+' '+y;});
    for(var j=idx.length-1;j>=0;j--){var y0=Y(lo[j]).toFixed(1);d+='L'+X(ax.T1[idx[j]]).toFixed(1)+' '+y0+'L'+X(ax.T[idx[j]]).toFixed(1)+' '+y0;}
    s+='<path class="xa" fill="'+wcol(A.classes[c])+'" d="'+d+'Z"/>';lo=hi;
  });
  s+='<rect id="ax-hb" class="xbk" x="0" y="'+top+'" width="0" height="'+ph+'" visibility="hidden"/>';
  var ws=wins(),hit=[],cur=ws.length-1;
  ax.win.forEach(function(r,i){
    var xa=X(r[0]),xb=X(r[1]);if(xb<padL-2||xa>Wd-padR+2)return;
    var w=Math.max(i===cur?4:3,xb-xa),x=(xa+xb)/2-w/2,cls=(i===cur?' cur':'')+(ws[i].o===PW?' on':'')+(ws[i].v==='N'?' sk':'');
    s+='<rect class="xw'+cls+'" x="'+x.toFixed(1)+'" y="'+top+'" width="'+w.toFixed(1)+'" height="'+ph+'"/><rect class="xwc'+cls+'" x="'+x.toFixed(1)+'" y="'+(top-5)+'" width="'+w.toFixed(1)+'" height="4" rx="1"/>';
    hit.push([i,x,w]);
  });
  s+='</g><line class="ax" x1="'+padL+'" x2="'+(Wd-padR)+'" y1="'+(top+ph)+'" y2="'+(top+ph)+'"/>';
  /* x ticks: the smallest interval that leaves about 88 px per label, counted from
     midnight of the Current window's day (weekly ticks land on its weekday) */
  var IVS=[1,2,3,6,12,24,48,168,336,672].map(function(h){return h*H1;}),iv=IVS[IVS.length-1];
  for(var q=0;q<IVS.length;q++){if(pw*IVS[q]/(d1-d0)>=88){iv=IVS[q];break;}}
  var org=Math.floor(ax.win[cur][0]/864e5)*864e5;
  for(var tt=org+Math.ceil((d0-org)/iv)*iv;tt<=d1;tt+=iv){
    var xt=X(tt);if(xt<padL+12||xt>Wd-padR-12)continue;
    var lab=(iv>=24*H1||new Date(tt).getUTCHours()===0)?fDay(tt):fHM(tt);
    s+='<line class="ax" x1="'+xt.toFixed(1)+'" x2="'+xt.toFixed(1)+'" y1="'+(top+ph)+'" y2="'+(top+ph+4)+'"/><text class="at" x="'+xt.toFixed(1)+'" y="'+(top+ph+18)+'" text-anchor="middle">'+lab+'</text>';
  }
  /* release markers: a flag in a two-tier band, a line through the plot */
  var tiers=[[],[]];
  (W.markers?W.markers():[]).forEach(function(m){
    var x=X(PT(m.at));if(x<padL||x>Wd-padR)return;
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
  s+='<line id="ax-ch" class="xch" x1="0" x2="0" y1="'+top+'" y2="'+(top+ph)+'" visibility="hidden"/>';
  hit.forEach(function(q){
    var i=q[0],w=ws[i],hw=Math.max(12,q[2]),hx=q[1]+q[2]/2-hw/2;
    s+='<rect class="xwh" data-i="'+i+'" data-w="'+w.o+'" x="'+hx.toFixed(1)+'" y="'+(top-6)+'" width="'+hw.toFixed(1)+'" height="'+(ph+6)+'" tabindex="0" role="button" aria-label="'
      +esc((w.o===0?'Current window, ':offTxt(w)+' window, ')+w.t+(w.o===0?'':'. Pin its column in the grid'))+'"/>';
  });
  ax.svg.innerHTML=s;
  ax.g={X:X,W:Wd,padL:padL,padR:padR,top:top,ph:ph,pw:pw,d0:d0,d1:d1};
  var zoomed=d0>ax.full[0]||d1<ax.full[1];
  ax.reset.hidden=!zoomed;
  ax.range.textContent=zoomed?fAt(d0)+' to '+fAt(d1)+', zoomed':fDay(ax.full[0])+' to '+fDay(ax.full[1])+', '+ax.bhTxt;
}
function axTime(cx){var r=ax.svg.getBoundingClientRect(),x=(cx-r.left)*ax.g.W/r.width;return ax.g.d0+(x-ax.g.padL)/ax.g.pw*(ax.g.d1-ax.g.d0);}
function axHover(e){
  if(!ax.g||ax.drag&&ax.drag.moved)return;
  var hb=doc.getElementById('ax-hb'),ch=doc.getElementById('ax-ch'),wh=e.target.closest&&e.target.closest('.xwh');
  if(wh){
    var i=+wh.getAttribute('data-i'),w=wins()[i];axHide();
    tipOn('<b>'+esc(w.t)+'</b><br><span class="tm">'+(w.o===0?'Current window':offTxt(w)+' window')+(w.v==='N'?', skipped':'')+', the window itself</span>'
      +ashRows(function(c){return AX.win[c][i];},ax.vis)+(w.o===0?'':'<span class="tm">Click to pin this column below</span>'),e);
    return;
  }
  var t=axTime(e.clientX),k=-1;
  for(var j=0;j<ax.T.length;j++)if(ax.T[j]<=t&&t<ax.T1[j]){k=j;break;}
  if(k<0||t<ax.g.d0||t>ax.g.d1){axHide();tipOff();return;}
  var xa=Math.max(ax.g.padL,ax.g.X(ax.T[k])),xb=Math.min(ax.g.W-ax.g.padR,ax.g.X(ax.T1[k])),x=ax.g.X(t);
  hb.setAttribute('x',xa.toFixed(1));hb.setAttribute('width',Math.max(1,xb-xa).toFixed(1));hb.setAttribute('visibility','visible');
  ch.setAttribute('x1',x.toFixed(1));ch.setAttribute('x2',x.toFixed(1));ch.setAttribute('visibility','visible');
  var hrs=Math.round((ax.T1[k]-ax.T[k])/H1*100)/100;
  tipOn('<b>'+fAt(ax.T[k])+'\u2013'+fHM(ax.T1[k])+'</b><br><span class="tm">'+(hrs===1?'1-hour':hrs+'-hour')+' average</span>'+ashRows(function(c){return AX.vals[c][k];},ax.vis),e);
}
function axSelect(i){
  var w=wins()[i];if(!w)return;
  if(w.o===0){if(PW!==null)W.pin(null);}else W.pin(w.o);
  flashCol(w.o);
  var tl=doc.getElementById('tl');if(!tl)return;
  var r=tl.getBoundingClientRect();if(r.top>innerHeight-220)window.scrollBy({top:r.top-innerHeight+320,behavior:reduced()?'auto':'smooth'});
}
function axZoom(a,b){
  a=Math.max(ax.full[0],a);b=Math.min(ax.full[1],b);
  if(b-a<ax.min){var m=(a+b)/2;a=Math.max(ax.full[0],m-ax.min/2);b=Math.min(ax.full[1],a+ax.min);a=Math.max(ax.full[0],b-ax.min);}
  ax.dom=[a,b];axDraw(true);
}
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
  axInit();
  var b=doc.getElementById('tl-body');if(b)b.addEventListener('scroll',sync,{passive:true});
  var tl=doc.getElementById('tl');if(tl&&W.render)W.render(tl);
  setTimeout(function(){axDraw(true);startAtCurrent();},60);
  var rt=null;window.addEventListener('resize',function(){if(rt)clearTimeout(rt);rt=setTimeout(function(){axDraw();sync();},120);});
});
})();
