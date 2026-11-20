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
  if(lane.getAttribute('data-kind')==='scored'&&el.classList.contains('bars')&&!flagged(el)&&lane.closest('#tl.flagonly'))setRows('all',false);
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
    if(rl)rl.hidden=lane.hidden;
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
/* ---- 2b. the row toolbar (plan 031), above the grid: "Flagged only"
   hides the rows of the scored lanes that are not large / moderate
   (folded ones included); "Biggest change first" sorts the scored lanes
   (waits: by added AAS when every row is in AAS, else by z; headline and
   load: by z), wait-class rows staying above the events.  A viewer's
   choice, saved on a click only (localStorage awr-tl-rows /
   awr-tl-order), like awr-view.  Counts, pills and ids never change. */
var TLF={rows:'all',order:'report'};
function lsGet(k){try{return localStorage.getItem(k);}catch(e){return null;}}
function lsSet(k,v){try{localStorage.setItem(k,v);}catch(e){}}
function scoredLanes(){return $$('#tl .lane[data-kind="scored"]');}
function laneRows(lane){return $$('.lrows > .r.bars',lane);}
function flagged(r){var s=r.getAttribute('data-sev');return s==='large'||s==='moderate';}
function toolSync(note){
  $$('#tl-tools button[data-tlf]').forEach(function(b){b.setAttribute('aria-pressed',String(b.getAttribute('data-tlf')===TLF.rows));});
  $$('#tl-tools button[data-tlo]').forEach(function(b){b.setAttribute('aria-pressed',String(b.getAttribute('data-tlo')===TLF.order));});
  if(note!=null){var n=$('#tl-tools .tlt-n');if(n)n.innerHTML=note;}
}
function setRows(v,save,boot){
  var tl=doc.getElementById('tl');if(!tl)return;TLF.rows=v;
  tl.classList.toggle('flagonly',v==='flagged');
  scoredLanes().forEach(function(l){l.classList.toggle('nofl',!laneRows(l).some(flagged));});
  toolSync();if(save)lsSet('awr-tl-rows',v);
  if(!boot&&W.render)W.render(tl);
}
function setOrder(v,save,boot){
  var tl=doc.getElementById('tl');if(!tl)return;TLF.order=v;
  var notes=[];
  scoredLanes().forEach(function(lane){
    var rows=laneRows(lane),box=$('.lrows',lane);if(!rows.length||!box)return;
    rows.forEach(function(r,i){if(!r.hasAttribute('data-ord'))r.setAttribute('data-ord',String(i));});
    var aas=rows.every(function(r){return r.getAttribute('data-unit')==='AAS';});
    var key=function(r){return W.changeKey(nums(r.getAttribute('data-v')),num(r.getAttribute('data-mu')),num(r.getAttribute('data-sd')),aas);};
    var grp=function(r){return /^tl-fr-w-/.test(r.id)?0:1;},ord=function(r){return +r.getAttribute('data-ord');};
    rows.sort(v==='change'?function(a,b){var g=grp(a)-grp(b);if(g)return g;var ka=key(a),kb=key(b);
      if(ka==null&&kb!=null)return 1;if(kb==null&&ka!=null)return -1;if(ka!==kb&&ka!=null)return kb-ka;return ord(a)-ord(b);}
      :function(a,b){return ord(a)-ord(b);});
    rows.forEach(function(r){box.appendChild(r);});
    var x=$('.r.xpr',lane),m=$('.lrows > .r.more',lane),nf=$('.r.nfl',lane),xb=$('.xpb',lane);
    if(v==='change'){if(m&&!lane.classList.contains('showmore')){lane.setAttribute('data-autoshow','1');showMore(lane);}
      notes.push(esc(($('.lti',lane)||{}).textContent||lane.id)+': by '+(aas?'added AAS':'size of the move (z)'));}
    else{if(lane.hasAttribute('data-autoshow')){lane.removeAttribute('data-autoshow');lane.classList.remove('showmore');if(xb)xb.setAttribute('aria-expanded','false');}
      if(x&&m)box.insertBefore(x,m);}
    if(nf)box.appendChild(nf);
  });
  toolSync(notes.join('; '));if(save)lsSet('awr-tl-order',v);
  if(!boot&&W.render)W.render(tl);
}
function tools(){
  var tl=doc.getElementById('tl');if(!tl||!scoredLanes().length||doc.getElementById('tl-tools'))return;
  scoredLanes().forEach(function(lane){var box=$('.lrows',lane);if(!box)return;var nf=mk('div','r nfl',box);nf.setAttribute('role','row');nf.innerHTML='<div class="l" role="rowheader">No large or moderate row here</div>';});
  var t=mk('div','tl-tools');t.id='tl-tools';t.setAttribute('role','toolbar');t.setAttribute('aria-label','Timeline rows');
  t.innerHTML='<span class="tlt-g" role="group" aria-label="Rows"><span class="tlt-l">Rows</span><button type="button" data-tlf="all">All</button><button type="button" data-tlf="flagged">Flagged only</button></span>'
    +'<span class="tlt-g" role="group" aria-label="Order"><span class="tlt-l">Order</span><button type="button" data-tlo="report">Report order</button><button type="button" data-tlo="change">Biggest change first</button></span>'
    +'<span class="tlt-n"></span>';
  tl.parentNode.insertBefore(t,tl);
  t.addEventListener('click',function(ev){var b=ev.target&&ev.target.closest?ev.target.closest('button'):null;if(!b)return;
    if(b.hasAttribute('data-tlf'))setRows(b.getAttribute('data-tlf'),true);else if(b.hasAttribute('data-tlo'))setOrder(b.getAttribute('data-tlo'),true);});
  /* boot: no render here, the DOMContentLoaded block renders #tl next */
  var r=lsGet('awr-tl-rows'),o=lsGet('awr-tl-order');
  setRows(r==='flagged'?'flagged':'all',false,true);setOrder(o==='change'?'change':'report',false,true);
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
/* Esc: the first press clears a highlighted Activity series (hlEsc,
   section 6), the next one the pinned window */
doc.addEventListener('keydown',function(ev){if(ev.key!=='Escape')return;if(hlEsc())return;if(PW!==null)W.pin(null);});
/* the pin survives a view switch: the Activity charts that show it are in
   every view (Esc, Current or the gutter's clear unpin) */
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
function ashRows(names,cols,get,vis,noun,hl){
  var h='',tot=0,hid=false,lead=[],hs=0;
  for(var c=names.length-1;c>=0;c--){if(vis&&!vis[c]){hid=true;continue;}var v=get(c);if(v==null)continue;tot+=v;
    if(hl&&hl[c]){lead.push([c,v]);hs+=v;continue;}
    if(v>=0.005)h+='<div class="tr2"><span><i class="sw" style="--sw:'+cols[c]+'"></i>'+esc(names[c])+'</span><b>'+v.toFixed(2)+'</b></div>';}
  /* a highlighted series leads (its share of the total beside it); several
     (a wait class's events) add their sum */
  var pc=function(v){return tot>0?' <span class="tpc">'+Math.round(v/tot*100)+'%</span>':'';},l='';
  lead.forEach(function(x){l+='<div class="tr2 thl"><span><i class="sw" style="--sw:'+cols[x[0]]+'"></i>'+esc(names[x[0]])+'</span><b>'+x[1].toFixed(2)+pc(x[1])+'</b></div>';});
  if(lead.length>1)l+='<div class="tr2 thl"><span>Highlighted, together</span><b>'+hs.toFixed(2)+pc(hs)+'</b></div>';
  return (l?'<div class="thlb">'+l+'</div>':'')+h+'<div class="tr2 tsum"><span>'+(hid?'Total, shown '+(noun||'classes'):'Total')+'</span><b>'+tot.toFixed(1)+' AAS</b></div>';
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
  return head+'<b>'+fmtNum(v)+'</b> '+esc(row.getAttribute('data-unit')||'')+(g?'<br>'+esc(g.title):'')
    +($('i.b.brk',cell)?'<br><span class="tm">bar cut: more than 1.5&times; the tallest prior window</span>':'');
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
/* ---- 6. Activity, whole span (section#activity, first in Timeline / All
   sections, under the verdict in Summary, compact there): one
   chart factory, two instances over one time axis -- by wait class
   (AWR_DATA.ashx) and by wait event (AWR_DATA.ashe).  Linked: a zoom on
   either zooms both, the hover crosshair is mirrored, the pinned window
   (AWR_WG.pin) is the same stripe in both.  Hover, legend, brush zoom,
   Reset / double-click, window stripes, release markers in each.
   Series highlight: a legend entry hovered or keyboard-focused (or a
   sticky one) is drawn from zero with the y axis fitted to it, the other
   series faded on top; the series under the pointer in the plot is
   highlighted in place (no re-stacking, so it cannot slide away from the
   pointer).  Linked through ashe.ecls (each event's wait class): a class
   highlights its events in the event chart, an event its class, lightly,
   in the class chart.  Sticky: a click on a band in the plot or
   Shift+click / Shift+Enter on a legend entry; the same again, a click
   off the stack or Esc clears it (the next Esc unpins the window). */
var AX=null,AE=null,CH=[],SP=null,DRAG=null,cvs=null;
/* Summary opens the charts compact (SP.cmp): the by-class chart only, a
   shorter plot with its own date labels; #ax-more shows the by-event chart.
   The reader's choice is kept in localStorage awr-ax, written on a click. */
function cmp(){return !!(SP&&SP.cmp)&&doc.body.classList.contains('vs');}
function axMore(b){b.setAttribute('aria-expanded',String(!SP.cmp));b.textContent=SP.cmp?'Show by wait event':'Hide by wait event';}
/* the highlight: HS sticky, HT passing (legend hover / focus, or soft =
   the plot hover), each {c: chart, k: series}; HT wins while it lasts */
var HS=null,HT=null;
function hlSame(a,b){return a===b||!!(a&&b&&a.c===b.c&&a.k===b.k&&!!a.soft===!!b.soft);}
function hlSet(t){if(hlSame(HT,t))return;HT=t;hlApply();}
function hlStick(c,k){HS=(k<0||(HS&&HS.c===c&&HS.k===k))?null:{c:c,k:k};HT=null;hlApply();}
function hlEsc(){if(!HS&&!HT)return false;HS=null;HT=null;hlApply();return true;}
/* each chart's c.hl = {set: {series: 1}, strong: re-based + fitted, fade:
   the others' opacity, note}; redraw only the charts whose state changed */
function hlApply(){
  var E=HT||HS;
  CH.forEach(function(c){c.hl=null;});
  if(E&&E.c.vis[E.k]){
    var s=E.c,strong=!E.soft,nm=s.P.classes[E.k],one={},m=s.xmap&&s.xmap[E.k],o=s.peer;
    var tail=E===HS?' \u00b7 Esc clears':'';
    one[E.k]=1;
    s.hl={set:one,strong:strong,fade:strong?0.12:0.3,note:strong?nm+' drawn from zero, y axis fitted to it'+tail:''};
    if(o&&m&&m.length){
      var set={};m.forEach(function(q){set[q]=1;});
      var on1=m.length===1&&o.P.classes[m[0]]===nm;
      o.hl=s===CH[0]?{set:set,strong:strong,fade:strong?0.12:0.3,note:strong?(on1?nm+' drawn from zero, y axis fitted to it':'The '+nm+' events drawn from zero, y axis fitted to them')+tail:''}
                    :{set:set,strong:false,fade:0.35,note:''};
    }
  }
  CH.forEach(function(c){
    var h=c.hl,key=h?Object.keys(h.set).join(',')+'|'+h.strong+'|'+h.fade+'|'+h.note:'';
    if(c.lg){c.lg.classList.toggle('hlon',!!h);$$('.axc',c.lg).forEach(function(b){b.classList.toggle('hl',!!(h&&h.set[+b.getAttribute('data-c')]));});}
    if(key!==c.hk){c.hk=key;draw(c,true);}
  });
}
/* the series drawn under client point (x, y) on chart c, or -1 (off the
   stack): the bucket under x, its values stacked in the drawn order */
function seriesAt(c,x,y){
  if(!c.g||!c.g.ord)return -1;
  var r=c.svg.getBoundingClientRect(),sy=(y-r.top)*c.g.W/r.width;
  if(sy<c.g.top||sy>c.g.top+c.g.ph)return -1;
  var ref;
  if(c.g.mode==='win'){var pq=panAt(c,x);if(!pq)return -1;ref=wRefAt(c,pq.q,pq.t);}
  else{var t=tAt(c,x);if(t<c.g.d0||t>c.g.d1)return -1;ref=refAt(t);}
  if(ref==null)return -1;
  var v=(c.g.top+c.g.ph-sy)/c.g.ph*c.g.ymax,acc=0;
  for(var q=0;q<c.g.ord.length;q++){var k=c.g.ord[q],a=rV(c,k,ref)||0;if(a<=0)continue;acc+=a;if(v<=acc)return k;}
  return -1;
}
/* the event palette: 15 categorical hues, the first 13 (all a chart can
   use: 14 events, CPU among them) well apart, readable on both themes, no
   green (CPU keeps the wait-class CPU green, "Other events" a fixed grey) */
var EVP=['#4E79A7','#F28E2B','#E15759','#76B7B2','#EDC948','#B07AA1','#FF9DA7','#9C755F','#A0CBE8','#D37295','#17BECF','#B6992D','#7F3C8D','#FFBE7D','#499894'],EVO='#9AA3AD';
function evColors(names){var j=0;return names.map(function(n){if(n==='CPU')return wcol('CPU');if(n==='Other events')return EVO;return EVP[(j++)%EVP.length];});}
/* a bucket's length as text: 15-min, 1-hour, 2-hour, 0.75 h = 45-min */
function bLab(h){return h<1&&Math.abs(h*60-Math.round(h*60))<1e-6?Math.round(h*60)+'-min':(Math.round(h*100)/100)+'-hour';}
/* the 1-minute detail (ashx.fine / ashe.fine): when the view is FMAX or
   narrower and overlaps a compared window, the minutes inside the windows
   replace the coarse buckets they overlap; zoomed that far the brush may
   go down to FMIN.  A bucket is a ref: coarse i >= 0, 1-minute j = -1 - j. */
var FMAX=6*H1,FMIN=30*6e4;
function rS(r){return r>=0?SP.T[r]:SP.F.T[-1-r];}
function rE(r){return r>=0?SP.T1[r]:Math.min(SP.F.T[-1-r]+SP.F.bm,SP.full[1]);}
function rV(c,k,r){return r>=0?c.P.vals[k][r]:c.FV[k][-1-r];}
/* a fine series: integer samples a minute, -k = k zero minutes; AAS = n / div */
function unRle(a,n,div){if(!a||!a.length)return null;var o=[],i,z,x;for(i=0;i<a.length;i++){x=+a[i];if(x<0){for(z=0;z<-x;z++)o.push(0);}else o.push(x/div);}return o.length===n?o:null;}
function fineInit(f){
  if(!f||!f.segs||!f.segs.length||!(f.bm>0))return null;
  var bm=f.bm*6e4,T=[],S=[];
  f.segs.forEach(function(g){var a=SP.t0+g[0]*6e4;S.push([a,a+g[1]*bm,T.length]);for(var q=0;q<g[1];q++)T.push(a+q*bm);});
  return {T:T,S:S,bm:bm,div:6*f.bm,capped:!!f.capped};
}
function fineVals(P){
  var f=P.fine,F=SP.F;if(!F||!f||!f.vals||f.vals.length!==P.classes.length)return null;
  var o=f.vals.map(function(a){return unRle(a,F.T.length,F.div);});
  return o.some(function(a){return !a;})?null:o;
}
/* the time the segments cover in [a, b) */
function fineCov(a,b){var F=SP.F,v=0;if(!F)return 0;F.S.forEach(function(g){var x=Math.max(a,g[0]),y=Math.min(b,g[1]);if(y>x)v+=y-x;});return v;}
function fineOn(a,b){return !!SP.F&&b-a<=FMAX+1&&fineCov(a,b)>0;}
/* the buckets drawn for [d0, d1], in time order, a bucket or two past each
   edge so the lines run out of the plot */
function refs(d0,d1){
  var key=d0+'|'+d1;if(SP.rk===key)return SP.rv;
  var br=bRange(d0,d1),n=SP.T.length,i0=Math.max(0,br[0]-1),i1=Math.min(n-1,br[1]+1),out=[],i;
  if(!fineOn(d0,d1)){for(i=i0;i<=i1;i++)out.push(i);}
  else{
    var F=SP.F,fl=[],cl=[],pa=d0-2*SP.bh,pb=d1+2*SP.bh;
    F.S.forEach(function(g){
      if(g[1]<=pa||g[0]>=pb)return;
      var nb=Math.round((g[1]-g[0])/F.bm),ja=Math.max(0,Math.floor((pa-g[0])/F.bm)),jb=Math.min(nb-1,Math.ceil((pb-g[0])/F.bm));
      for(var j=ja;j<=jb;j++)fl.push(-1-(g[2]+j));
    });
    for(i=i0;i<=i1;i++){var a=SP.T[i],b=SP.T1[i];if(!F.S.some(function(g){return g[0]<b&&g[1]>a;}))cl.push(i);}
    var p=0,q=0;while(p<cl.length||q<fl.length){if(q>=fl.length||(p<cl.length&&rS(cl[p])<rS(fl[q])))out.push(cl[p++]);else out.push(fl[q++]);}
  }
  SP.rk=key;SP.rv=out;return out;
}
/* the ref under time t (fine inside a window when the view shows the detail) */
function refAt(t){
  var F=SP.F;
  if(F&&fineOn(SP.dom[0],SP.dom[1]))for(var q=0;q<F.S.length;q++){var g=F.S[q];if(t>=g[0]&&t<g[1])return -1-(g[2]+Math.floor((t-g[0])/F.bm));}
  var j=bucketAt(t);return j<0?null:j;
}
/* a band's top edge: the fill colour, darker */
function shade(h){var m=/^#([0-9a-f]{6})$/i.exec(h);if(!m)return h;var n=parseInt(m[1],16);return 'rgb('+[n>>16,(n>>8)&255,n&255].map(function(v){return Math.round(v*0.8);}).join(',')+')';}
/* the buckets in [a, b): first and last index, O(1) on the regular grid */
function bRange(a,b){var n=SP.T.length,i0=Math.max(0,Math.floor((a-SP.t0)/SP.bh)),i1=Math.min(n-1,Math.ceil((b-SP.t0)/SP.bh)-1);
  while(i0<n&&SP.T1[i0]<=a)i0++;while(i1>=0&&SP.T[i1]>=b)i1--;return [i0,i1];}
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
      reset:doc.getElementById('ax-reset'),range:doc.getElementById('ax-range'),sel:null,F:null,rk:null,rv:null,mode:'span',wk:0,wf:0};
  SP.F=fineInit(AX.fine);
  CH=[];
  mkChart(doc.getElementById('ax-cls'),AX,AX.classes.map(wcol),{flags:true,noun:'classes',what:'wait class',labels:true});
  var ev=doc.getElementById('ax-ev');
  if(okPay(AE,n))mkChart(ev,AE,evColors(AE.classes),{noun:'events',what:'wait event',labels:true});
  else if(ev)ev.hidden=true;
  /* the detail only when every chart has it */
  CH.forEach(function(c){c.FV=fineVals(c.P);});
  if(CH.some(function(c){return !c.FV;}))SP.F=null;
  if(CH.length)CH[CH.length-1].xl=true;
  /* the link between the charts: ashe.ecls[e] = event e's wait class
     (CPU -> CPU, Other events -> null) */
  if(CH.length===2&&AE&&AE.ecls&&AE.ecls.length===AE.classes.length){
    var ca=CH[0],ce=CH[1];ca.peer=ce;ce.peer=ca;
    ca.xmap=AX.classes.map(function(cn){var o=[];AE.ecls.forEach(function(x,e){if(x===cn)o.push(e);});return o;});
    ce.xmap=AE.ecls.map(function(x){var i=x==null?-1:AX.classes.indexOf(x);return i<0?[]:[i];});
  }
  /* the dashboard design shows one chart at a time with its own tabs
     (js_design.js activityTabs): no compact mode there */
  var sec=doc.getElementById('activity'),mb=doc.getElementById('ax-more'),sv=null,dash=window.AWR_DESIGN==='dashboard';
  try{sv=localStorage.getItem('awr-ax');}catch(e){}
  SP.cmp=CH.length===2&&sv!=='full'&&!dash;
  if(sec)sec.classList.toggle('ax-cmp',SP.cmp);
  if(mb&&CH.length===2&&!dash){
    mb.hidden=false;axMore(mb);
    mb.addEventListener('click',function(){
      SP.cmp=!SP.cmp;if(sec)sec.classList.toggle('ax-cmp',SP.cmp);axMore(mb);
      try{localStorage.setItem('awr-ax',SP.cmp?'compact':'full');}catch(e){}
      drawAll(true);
    });
  }
  /* the layout switch (Windows side by side / Full span): shown when at
     least two windows get a panel AXMP px wide; the reader's last click
     (localStorage awr-axlayout) wins, else AXDEF (54 = draw's padL + padR) */
  var mg=$('#activity .axlayout'),sm=null,pw0=CH.length?Math.max(480,CH[0].plot.clientWidth)-54:0;
  try{sm=localStorage.getItem('awr-axlayout');}catch(e){}
  if(mg&&SP.win.length>=2&&winFit(pw0)>=2){
    mg.hidden=false;
    SP.mode=(sm==='win'||sm==='span')?sm:(AXDEF==='win'&&SP.win.length<=winFit(pw0)?'win':'span');
    $$('[data-m]',mg).forEach(function(b){
      b.setAttribute('aria-pressed',String(b.getAttribute('data-m')===SP.mode));
      b.addEventListener('click',function(){TL.axLayout(b.getAttribute('data-m'),true);});
    });
  }
  if(SP.reset)SP.reset.addEventListener('click',spReset);
  doc.addEventListener('mousemove',function(e){
    var dg=DRAG;if(!dg)return;
    if(!dg.moved&&Math.abs(e.clientX-dg.x0)<5)return;
    dg.moved=true;tipOff();hideAll();
    if(SP.mode==='win')return;
    var c=dg.c,r=c.svg.getBoundingClientRect(),sc=r.width/c.g.W,mn=r.left+c.g.padL*sc,mx=r.left+(c.g.W-c.g.padR)*sc;
    dg.a=Math.max(mn,Math.min(dg.x0,e.clientX));dg.b=Math.min(mx,Math.max(dg.x0,e.clientX));
    /* the brush shows on both charts: same width, same x mapping */
    CH.forEach(function(o){if(!o.g)return;var ro=o.svg.getBoundingClientRect(),so=ro.width/o.g.W;
      o.br.hidden=false;o.br.style.left=(dg.a-ro.left)+'px';o.br.style.width=Math.max(0,dg.b-dg.a)+'px';
      o.br.style.top=(o.g.top*so)+'px';o.br.style.height=(o.g.ph*so)+'px';});
  });
  doc.addEventListener('mouseup',function(){
    var dg=DRAG;if(!dg)return;DRAG=null;CH.forEach(function(o){o.br.hidden=true;});
    if(dg.moved){if(SP.mode!=='win'&&dg.b-dg.a>6)spZoom(tAt(dg.c,dg.a),tAt(dg.c,dg.b));return;}
    if(dg.w!=null){SP.sel={prev:PW,t:Date.now()};spSelect(dg.w);return;}
    /* a click on a band makes its highlight sticky (the same band again,
       or a click off the stack, clears it) */
    var k=seriesAt(dg.c,dg.x0,dg.y0);
    if(k>=0||HS){SP.hsel={prev:HS,t:Date.now()};hlStick(dg.c,k);}
  });
}
function mkChart(root,P,cols,opt){
  if(!root)return null;
  var c={root:root,P:P,cols:cols,svg:$('.axsvg',root),plot:$('.axp',root),br:$('.axbr',root),
         vis:P.classes.map(function(){return true;}),flags:!!opt.flags,noun:opt.noun,what:opt.what,xl:false,g:null,w:0,uid:root.id,
         lg:$('.axlg',root),hl:null,hk:'',peer:null,xmap:null,lab:opt.labels!==false};
  var lg=c.lg;
  if(lg){lg.innerHTML=P.classes.map(function(nm,k){return '<button type="button" class="axc" data-c="'+k+'" aria-pressed="true" title="'+esc(nm)+': hover to highlight, click to show or hide, Shift+click to keep it highlighted"><i class="sw" style="--sw:'+cols[k]+'" aria-hidden="true"></i>'+esc(nm)+'</button>';}).join('');
    /* hover / keyboard focus highlights; a click hides / shows; Shift+click
       or Shift+Enter keeps the highlight */
    $$('.axc',lg).forEach(function(b){
      var k=+b.getAttribute('data-c'),mine=function(){return HT&&HT.c===c&&HT.k===k;};
      b.addEventListener('click',function(e){
        if(e.shiftKey){e.preventDefault();hlStick(c,k);return;}
        c.vis[k]=!c.vis[k];b.setAttribute('aria-pressed',String(c.vis[k]));hlApply();draw(c,true);});
      b.addEventListener('keydown',function(e){if(e.key==='Enter'&&e.shiftKey){e.preventDefault();hlStick(c,k);}});
      b.addEventListener('mouseenter',function(){hlSet({c:c,k:k});});
      b.addEventListener('mouseleave',function(){if(mine())hlSet(null);});
      b.addEventListener('focus',function(){var fv=true;try{fv=b.matches(':focus-visible');}catch(x){}if(fv)hlSet({c:c,k:k});});
      b.addEventListener('blur',function(){if(mine())hlSet(null);});
    });}
  var s=c.svg;
  s.addEventListener('mousemove',function(e){hover(c,e);});
  s.addEventListener('mouseleave',function(){if(!DRAG){tipOff();hideAll();if(HT&&HT.soft)hlSet(null);}});
  s.addEventListener('mousedown',function(e){
    if(e.button!==0||!c.g)return;e.preventDefault();
    /* the second press of a double-click resets the zoom (the chart is redrawn
       between the two presses, so a dblclick event may never fire) and undoes
       the pin the first press made on a window stripe */
    if(e.detail>=2){if(SP.sel&&Date.now()-SP.sel.t<700)W.pin(SP.sel.prev);SP.sel=null;
      if(SP.hsel&&Date.now()-SP.hsel.t<700){HS=SP.hsel.prev;HT=null;hlApply();}SP.hsel=null;
      DRAG=null;if(SP.mode!=='win')spReset();return;}
    var wh=e.target.closest('.xwh');DRAG={c:c,x0:e.clientX,y0:e.clientY,moved:false,w:wh?+wh.getAttribute('data-i'):null};
  });
  s.addEventListener('dblclick',function(){if(SP.mode!=='win')spReset();});
  s.addEventListener('keydown',function(e){var wh=e.target.closest&&e.target.closest('.xwh');if(wh&&(e.key==='Enter'||e.key===' ')){e.preventDefault();spSelect(+wh.getAttribute('data-i'));}});
  CH.push(c);
  return c;
}
function drawAll(force){CH.forEach(function(c){draw(c,force);});spHead();}
/* redraw both Activity charts now (a design that shows / hides one calls it) */
TL.redraw=function(){drawAll(true);};
/* the Activity charts' layout: 'win' (windows side by side) or 'span'
   (full span); persist = the reader clicked (localStorage awr-axlayout) */
TL.axLayout=function(m,persist){
  if(!SP||(m!=='win'&&m!=='span'))return;
  SP.mode=m;
  $$('#activity .axlayout [data-m]').forEach(function(b){b.setAttribute('aria-pressed',String(b.getAttribute('data-m')===m));});
  if(persist){try{localStorage.setItem('awr-axlayout',m);}catch(e){}}
  hideAll();tipOff();drawAll(true);
};
function spHead(){
  if(!SP)return;var d0=SP.dom[0],d1=SP.dom[1],zoomed=d0>SP.full[0]||d1<SP.full[1];
  if(SP.mode==='win'){
    if(SP.reset)SP.reset.hidden=true;
    var n=SP.win.length,K=SP.wk||n,f=SP.wf||0;
    if(SP.range)SP.range.textContent=(K===n?n+' compared windows side by side':'The '+K+' most recent of '+n+' compared windows side by side (Full span shows all)')
      +(f===K?', 1-min detail':f>0?', 1-min detail in the '+f+' most recent, '+SP.bhTxt+' in the rest':', '+SP.bhTxt);
    return;
  }
  if(SP.reset)SP.reset.hidden=!zoomed;
  var res=SP.bhTxt;
  if(fineOn(d0,d1))res=fineCov(d0,d1)>=d1-d0-1?'1-min detail':'1-min detail in the compared windows, '+SP.bhTxt+' elsewhere';
  if(SP.range)SP.range.textContent=zoomed?fAt(d0)+' to '+fAt(d1)+', zoomed, '+res:fDay(SP.full[0])+' to '+fDay(SP.full[1])+', '+SP.bhTxt;
}
/* the highlight state and the series drawing order of chart c (re-based:
   the highlighted series first) */
function hlOrd(c){
  var P=c.P,hl=c.hl,on=null,k,ord=[];
  if(hl){on=P.classes.map(function(x,q){return !!hl.set[q]&&c.vis[q];});if(!on.some(Boolean)){hl=null;on=null;}}
  var reb=!!(hl&&hl.strong);
  for(k=0;k<P.vals.length;k++)if(c.vis[k]&&(!reb||on[k]))ord.push(k);
  if(reb)for(k=0;k<P.vals.length;k++)if(c.vis[k]&&!on[k])ord.push(k);
  return {hl:hl,on:on,reb:reb,ord:ord};
}
/* the points drawn for refs R over [d0, d1] mapped by X (see draw) and the
   largest stacked total mx / highlighted total mh inside [d0, d1] */
function colPts(c,R,X,d0,d1,reb,on){
  var P=c.P,pts=[],cb=null,mx=0.05,mh=0,i,k,sm,sh,r;
  for(i=0;i<R.length;i++){r=R[i];sm=0;sh=0;for(k=0;k<P.vals.length;k++)if(c.vis[k]){var vk=rV(c,k,r)||0;sm+=vk;if(reb&&on[k])sh+=vk;}
    var ra=rS(r),rb=rE(r);if(rb>d0&&ra<d1){if(sm>mx)mx=sm;if(sh>mh)mh=sh;}
    var xm=X((ra+rb)/2),col=Math.floor(xm),g=pts[pts.length-1];
    if(g&&col===cb){if(reb?(sh>g[3]||(sh===g[3]&&sm>g[2])):sm>g[2]){g[0]=xm;g[1]=r;g[2]=sm;g[3]=sh;}}else{pts.push([xm,r,sm,sh]);cb=col;}}
  if(pts.length){var pf=pts[0],pl=pts[pts.length-1];
    if(rS(pf[1])>=d0)pts.unshift([X(rS(pf[1])),pf[1],pf[2],pf[3]]);
    if(rE(pl[1])<=d1)pts.push([X(rE(pl[1])),pl[1],pl[2],pl[3]]);}
  return {pts:pts,mx:mx,mh:mh};
}
/* the band paths of points pts (colPts) in series order ord, y mapped by Y:
   one fill per series, painted top of the stack first (the caller reverses
   fills / edges): each fills from the axis up to its own cumulative line
   and the series below paint over it (no seams); then each band's top
   edge, a thin darker line.  A point in the middle of a flat run is left
   out of the path.  Highlighted: the other series paint the same way inside
   one faded group (the group's opacity applies once, so their overlap does
   not darken), then each highlighted series as its own band (hf, between
   its lower and upper line) at full colour with a clear top edge (he). */
function bands(c,pts,ord,on,Y){
  var lo=pts.map(function(){return 0;}),np=pts.length,y0=Y(0).toFixed(1),fills=[],edges=[],hf=[],he=[];
  var pl2=function(ys,rev){var o='',j,q;for(q=0;q<np;q++){j=rev?np-1-q:q;if(q>0&&q<np-1&&ys[j]===ys[rev?j+1:j-1]&&ys[j]===ys[rev?j-1:j+1])continue;o+=(o?'L':'')+pts[j][0].toFixed(1)+' '+ys[j];}return o;};
  ord.forEach(function(k){
    if(!np)return;
    var hi=lo.map(function(l,j){return l+(rV(c,k,pts[j][1])||0);}),ys=hi.map(function(h){return Y(h).toFixed(1);}),ln=pl2(ys,false);
    if(on&&on[k]){
      hf.push('<path class="xa xah" fill="'+c.cols[k]+'" d="M'+ln+'L'+pl2(lo.map(function(h){return Y(h).toFixed(1);}),true)+'Z"/>');
      he.push('<path class="xe xeh" stroke="'+shade(c.cols[k])+'" d="M'+ln+'"/>');
    }else{
      fills.push('<path class="xa" fill="'+c.cols[k]+'" d="M'+pts[0][0].toFixed(1)+' '+y0+'L'+ln+'L'+pts[np-1][0].toFixed(1)+' '+y0+'Z"/>');
      edges.push('<path class="xe" stroke="'+shade(c.cols[k])+'" d="M'+ln+'"/>');
    }
    lo=hi;
  });
  return {fills:fills,edges:edges,hf:hf,he:he};
}
/* direct labels (plan 036): each shown series is a candidate at the point
   where its band is thickest; a label (its name, at most LW px wide, cut
   with "...") goes there when the band stays at least LBH px thick under the
   whole label and no placed label is in the way.  The thickest bands win,
   at most LMAX a chart; with a strong highlight only the highlighted series.
   groups = [{pts, x0, x1}]: one for Full span, one per panel side by side
   (a label never crosses a panel edge); only points inside [x0, x1] are
   candidates (zoomed, pts run a couple of buckets past the plot).  nb =
   the highlight note's box [x0, y0, x1, y1] (or null): no label covers it.
   Drawn inside the plot clip, above bands and stripes, pointer-events none. */
var LBH=13,LMAX=6,LW=160;
function edgeAt(pts,ys,x){
  for(var j=1;j<pts.length;j++)if(pts[j][0]>=x){var a=pts[j-1][0],b=pts[j][0],f=b>a?(x-a)/(b-a):0;return ys[j-1]+(ys[j]-ys[j-1])*f;}
  return ys[ys.length-1];
}
/* the highlight note's box for dlab (the note is 600 weight and Geist in the
   quiet / dashboard designs, tw() measures the 400 system stack: 1.2x) */
function noteBox(hl,padL,top){return hl&&hl.note?[padL+6,top+3,padL+6+tw(hl.note)*1.2,top+16]:null;}
function dlab(c,groups,ord,on,Y,reb,nb){
  if(!c.lab)return '';
  var cand=[],placed=[],s='';
  groups.forEach(function(G){
    var pts=G.pts,np=pts.length;if(np<2)return;
    var lo=pts.map(function(){return 0;});
    ord.forEach(function(k){
      var hi=lo.map(function(l,j){return l+(rV(c,k,pts[j][1])||0);});
      if(!reb||(on&&on[k])){
        var yl=lo.map(Y),yh=hi.map(Y),best=-1,bt=0;
        for(var j=0;j<np;j++){var t=yl[j]-yh[j];if(pts[j][0]>=G.x0&&pts[j][0]<=G.x1&&t>bt){bt=t;best=j;}}
        if(best>=0&&bt>=LBH)cand.push({k:k,G:G,yl:yl,yh:yh,j:best,t:bt});
      }
      lo=hi;
    });
  });
  cand.sort(function(a,b){return b.t-a.t;});
  cand.forEach(function(C){
    if(placed.length>=LMAX)return;
    var nm=c.P.classes[C.k],txt=nm,w=tw(txt)+6;
    if(w>LW){while(txt.length>4&&tw(txt+'...')+6>LW)txt=txt.slice(0,-1);txt=txt.replace(/\s+$/,'')+'...';w=tw(txt)+6;}
    var pts=C.G.pts,x=pts[C.j][0],xa=x-w/2,xb=x+w/2;
    if(xa<C.G.x0){xa=C.G.x0;xb=xa+w;}
    if(xb>C.G.x1){xb=C.G.x1;xa=xb-w;}
    if(xa<C.G.x0)return;
    var top=Math.max(edgeAt(pts,C.yh,xa),edgeAt(pts,C.yh,xb)),bot=Math.min(edgeAt(pts,C.yl,xa),edgeAt(pts,C.yl,xb));
    for(var j=0;j<pts.length;j++){var px=pts[j][0];if(px<xa||px>xb)continue;top=Math.max(top,C.yh[j]);bot=Math.min(bot,C.yl[j]);}
    if(bot-top<LBH)return;
    var yc=(top+bot)/2,box=[xa,yc-LBH/2,xb,yc+LBH/2];
    if(placed.concat(nb?[nb]:[]).some(function(p){return box[0]<p[2]+2&&box[2]>p[0]-2&&box[1]<p[3]+2&&box[3]>p[1]-2;}))return;
    placed.push(box);
    s+='<text class="xdl" x="'+((xa+xb)/2).toFixed(1)+'" y="'+(yc+4).toFixed(1)+'" text-anchor="middle">'+esc(txt)+'</text>';
  });
  return s;
}
/* the release markers of list [{x: px, m: marker}]: a line through the plot
   on every chart shown, the flags (two tiers) on the chart with c.flags */
function flagSvg(c,list,top,ph,Wd,padL,padR){
  var s='',tiers=[[],[]];
  list.forEach(function(it){
    var x=it.x,m=it.m;if(x<padL||x>Wd-padR)return;
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
  return s;
}
/* ---- "Windows side by side" (SP.mode 'win'): each compared window as its
   own panel on one shared y axis, oldest left, Current last.  A panel is
   drawn minute by minute when every minute of its window is in the
   1-minute detail (SP.F), else from the coarse buckets overlapping it.
   Panels are at least AXMP px wide, AXGAP px apart: when not all windows
   fit, the most recent that fit (the Current always).  No zoom here; a
   click on a panel's top edge pins its window.  AXDEF = the mode for a
   reader who never clicked the switch ('win': side by side when every
   window fits, else full span). */
var AXMP=24,AXGAP=6,AXDEF='span';
function winFit(pw){return Math.max(1,Math.floor((pw+AXGAP)/(AXMP+AXGAP)));}
/* the refs of window i: its 1-minute buckets when the detail covers it all,
   else the coarse buckets overlapping it */
function wSlice(i){
  var a=SP.win[i][0],b=SP.win[i][1],F=SP.F,out=[],q,g,j,j0,j1;
  if(F&&fineCov(a,b)>=b-a-1){
    for(q=0;q<F.S.length;q++){g=F.S[q];if(g[1]<=a||g[0]>=b)continue;
      j0=Math.max(0,Math.floor((a-g[0])/F.bm));j1=Math.min(Math.round((g[1]-g[0])/F.bm),Math.ceil((b-g[0])/F.bm))-1;
      for(j=j0;j<=j1;j++)out.push(-1-(g[2]+j));}
    return {r:out,fine:true};
  }
  var br=bRange(a,b);for(j=br[0];j<=br[1];j++)out.push(j);
  return {r:out,fine:false};
}
/* the panel under client x on chart c: {q: panel index, t: time} or null */
function panAt(c,cx){
  var g=c.g;if(!g||g.mode!=='win')return null;
  var r=c.svg.getBoundingClientRect(),x=(cx-r.left)*g.W/r.width;
  for(var q=0;q<g.pan.length;q++){var p=g.pan[q];if(x>=p.x0&&x<p.x0+p.w)return {q:q,t:p.a+(x-p.x0)/p.w*(p.b-p.a)};}
  return null;
}
/* the ref drawn at time t in panel q (1-minute or coarse, as the panel) */
function wRefAt(c,q,t){
  var p=c.g.pan[q];if(!p)return null;
  if(p.fine){var F=SP.F;for(var k=0;k<F.S.length;k++){var g=F.S[k];if(t>=g[0]&&t<g[1])return -1-(g[2]+Math.floor((t-g[0])/F.bm));}return null;}
  var j=bucketAt(t);return j<0?null:j;
}
/* chart c side by side (draw passes its size; flags / labels follow
   c.flags / c.xl as in draw) */
function drawWin(c,o){
  var Wd=o.Wd,top=o.top,ph=o.ph,padL=o.padL,padR=o.padR,pw=o.pw;
  var n=SP.win.length,K=Math.min(n,winFit(pw)),w=(pw-AXGAP*(K-1))/K,ws=wins(),cur=ws.length-1;
  var h=hlOrd(c),hl=h.hl,on=h.on,reb=h.reb,ord=h.ord,pan=[],mx=0.05,mh=0,nf=0,q;
  for(q=0;q<K;q++){
    var i=n-K+q,a=SP.win[i][0],b=SP.win[i][1],x0=padL+q*(w+AXGAP),sl=wSlice(i);
    var X=(function(x0,a,b){return function(t){return x0+w*Math.min(1,Math.max(0,(t-a)/(b-a)));};})(x0,a,b);
    var cp=colPts(c,sl.r,X,a,b,reb,on);
    if(cp.mx>mx)mx=cp.mx;if(cp.mh>mh)mh=cp.mh;if(sl.fine)nf++;
    pan.push({i:i,x0:x0,w:w,a:a,b:b,X:X,fine:sl.fine,pts:cp.pts});
  }
  SP.wk=K;SP.wf=nf;
  /* y scale, clip paths, gridlines, "AAS", open the clipped group: as draw */
  var yb=reb&&mh>0?Math.max(mh,0.05):mx,step=niceStep(yb,3),ymax=Math.ceil(yb/step-1e-9)*step;
  var Y=function(v){return top+ph-ph*v/ymax;},clip='axclip-'+c.uid;
  var s='<defs><clipPath id="'+clip+'"><rect x="'+padL+'" y="'+(top-6)+'" width="'+pw+'" height="'+(ph+6)+'"/></clipPath>'
    +(reb?'<clipPath id="'+clip+'f"><rect x="'+padL+'" y="'+top+'" width="'+pw+'" height="'+ph+'"/></clipPath>':'')+'</defs>';
  for(var v=0;v<=ymax+1e-9;v+=step){var dec=step<1?(step<0.1?2:1):0;
    s+='<line class="gl" x1="'+padL+'" x2="'+(Wd-padR)+'" y1="'+Y(v).toFixed(1)+'" y2="'+Y(v).toFixed(1)+'"/><text class="at" x="'+(padL-6)+'" y="'+(Y(v)+4).toFixed(1)+'" text-anchor="end">'+v.toFixed(dec)+'</text>';}
  s+='<text class="at" x="'+(padL-6)+'" y="'+(top-10)+'" text-anchor="end">AAS</text><g clip-path="url(#'+clip+')">';
  /* panel backgrounds under the bands; classes as the stripes' */
  var hit=[];
  pan.forEach(function(p){var wi=ws[p.i],cls=(p.i===cur?' cur':'')+(wi.o===PW?' on':'')+(wi.v==='N'?' sk':'');
    s+='<rect class="xw xpn'+cls+'" x="'+p.x0.toFixed(1)+'" y="'+top+'" width="'+p.w.toFixed(1)+'" height="'+ph+'"/>';
    hit.push([p.i,p.x0,p.w,cls]);});
  /* the bands, panel by panel (each panel's fills top of the stack first, as draw) */
  var F=[],E=[],HF=[],HE=[];
  pan.forEach(function(p){var B=bands(c,p.pts,ord,on,Y);F=F.concat(B.fills.reverse());E=E.concat(B.edges.reverse());HF=HF.concat(B.hf);HE=HE.concat(B.he);});
  if(!hl)s+=F.join('')+E.join('');
  else s+=(reb?'<g clip-path="url(#'+clip+'f)">':'')+'<g class="xfd" opacity="'+(reb&&ymax<mx?Math.min(hl.fade,0.07):hl.fade)+'">'+F.join('')+'</g>'+HF.join('')+HE.join('')+(reb?'</g>':'');
  /* the hidden bucket band: as draw; the caps */
  s+='<rect class="xbk" x="0" y="'+top+'" width="0" height="'+ph+'" visibility="hidden"/>';
  hit.forEach(function(r){s+='<rect class="xwc'+r[3]+'" x="'+r[1].toFixed(1)+'" y="'+(top-5)+'" width="'+r[2].toFixed(1)+'" height="4" rx="1"/>';});
  /* the direct labels, each inside its panel (dlab) */
  s+=dlab(c,pan.map(function(p){return {pts:p.pts,x0:p.x0,x1:p.x0+p.w};}),ord,on,Y,reb,noteBox(hl,padL,top));
  /* close the group and the x axis line: as draw */
  s+='</g><line class="ax" x1="'+padL+'" x2="'+(Wd-padR)+'" y1="'+(top+ph)+'" y2="'+(top+ph)+'"/>';
  /* window labels under the lower chart: every st-th panel counted from the Current one */
  if(o.xl){var lw=0;pan.forEach(function(p){lw=Math.max(lw,tw(ws[p.i].d));});var st=Math.max(1,Math.ceil((lw+8)/(w+AXGAP)));
    pan.forEach(function(p,q){if((K-1-q)%st)return;var wi=ws[p.i];
      s+='<text class="at xpl'+(p.i===cur?' cur':'')+(wi.v==='N'?' sk':'')+'" x="'+(p.x0+p.w/2).toFixed(1)+'" y="'+(top+ph+18)+'" text-anchor="middle">'+esc(wi.d)+'</text>';});}
  /* release markers: in the gap before the window they precede */
  var list=[];o.mks.forEach(function(m){var ib=idxOf(m.o);pan.forEach(function(p){if(p.i===ib)list.push({x:Math.max(padL,p.x0-AXGAP/2),m:m});});});
  s+=flagSvg(c,list,top,ph,Wd,padL,padR);
  /* highlight note and crosshair: as draw */
  if(hl&&hl.note)s+='<text class="xhn" x="'+(padL+6)+'" y="'+(top+13)+'">'+esc(hl.note)+'</text>';
  s+='<line class="xch" x1="0" x2="0" y1="'+top+'" y2="'+(top+ph)+'" visibility="hidden"/>';
  /* hit areas: the caps only (a band in the plot keeps its highlight on a click) */
  hit.forEach(function(r){var wi=ws[r[0]];
    s+='<rect class="xwh" data-i="'+r[0]+'" data-w="'+wi.o+'" x="'+r[1].toFixed(1)+'" y="'+(top-6)+'" width="'+r[2].toFixed(1)+'" height="10" tabindex="0" role="button" aria-label="'
      +esc((wi.o===0?'Current window, ':offTxt(wi)+' window, ')+wi.t+(wi.o===0?'':'. Pin it'))+'"/>';});
  c.svg.innerHTML=s;
  c.g={mode:'win',pan:pan,W:Wd,padL:padL,padR:padR,top:top,ph:ph,pw:pw,d0:SP.dom[0],d1:SP.dom[1],ymax:ymax,ord:ord,hk:c.hk,cm:o.cm};
}
function draw(c,force){
  if(!c||!SP||!shown(c.plot))return;
  /* the release flags go on the first chart shown, the x labels on the
     last one (both on one chart when a design shows a single chart) */
  var vis=CH.filter(function(x){return shown(x.plot);}),lay;c.flags=vis[0]===c;c.xl=vis[vis.length-1]===c;lay=(c.flags?1:0)+(c.xl?2:0);
  var Wd=Math.max(480,c.plot.clientWidth),d0=SP.dom[0],d1=SP.dom[1];
  if(!force&&c.w===Wd&&c.lay===lay&&c.g&&c.pw===PW&&c.g.d0===d0&&c.g.d1===d1&&c.g.hk===c.hk&&c.g.cm===cmp()&&(c.g.mode||'span')===SP.mode)return;c.w=Wd;c.pw=PW;c.lay=lay;
  var mks=W.markers?W.markers():[],P=c.P;
  var cm=cmp();
  var top=c.flags&&mks.length?46:22,ph=cm?96:150,bot=c.xl?26:8,padL=40,padR=14,H=top+ph+bot,pw=Wd-padL-padR;
  c.svg.setAttribute('viewBox','0 0 '+Wd+' '+H);c.svg.setAttribute('height',H);
  var X=function(t){return padL+pw*(t-d0)/(d1-d0);};
  if(SP.mode==='win'){drawWin(c,{Wd:Wd,top:top,ph:ph,padL:padL,padR:padR,pw:pw,xl:c.xl,cm:cm,mks:mks});return;}
  /* stacked areas: one point per bucket at its midpoint, straight lines
     between them.  While a bucket is at least a pixel wide every bucket is
     a point; zoomed out further, one point per pixel column at the
     column's busiest bucket (largest stacked total), so a one-bucket spike
     still shows; the tooltip always reads the bucket under the cursor.
     The first / last bucket of the data runs flat out to its edge. */
  /* the highlight (hlApply): on[k] = series k highlighted and shown; re-based
     (strong) = the highlighted series stacked first, from zero, the y axis
     fitted to them and each pixel column keeping THEIR busiest bucket */
  var h=hlOrd(c),hl=h.hl,on=h.on,reb=h.reb,ord=h.ord;
  var cp=colPts(c,refs(d0,d1),X,d0,d1,reb,on),pts=cp.pts,mx=cp.mx,mh=cp.mh;
  var yb=reb&&mh>0?Math.max(mh,0.05):mx,step=niceStep(yb,3),ymax=Math.ceil(yb/step-1e-9)*step;
  var Y=function(v){return top+ph-ph*v/ymax;},clip='axclip-'+c.uid;
  var s='<defs><clipPath id="'+clip+'"><rect x="'+padL+'" y="'+(top-6)+'" width="'+pw+'" height="'+(ph+6)+'"/></clipPath>'
    +(reb?'<clipPath id="'+clip+'f"><rect x="'+padL+'" y="'+top+'" width="'+pw+'" height="'+ph+'"/></clipPath>':'')+'</defs>';
  for(var v=0;v<=ymax+1e-9;v+=step){var dec=step<1?(step<0.1?2:1):0;
    s+='<line class="gl" x1="'+padL+'" x2="'+(Wd-padR)+'" y1="'+Y(v).toFixed(1)+'" y2="'+Y(v).toFixed(1)+'"/><text class="at" x="'+(padL-6)+'" y="'+(Y(v)+4).toFixed(1)+'" text-anchor="end">'+v.toFixed(dec)+'</text>';}
  s+='<text class="at" x="'+(padL-6)+'" y="'+(top-10)+'" text-anchor="end">AAS</text><g clip-path="url(#'+clip+')">';
  var B=bands(c,pts,ord,on,Y),fills=B.fills,edges=B.edges,hf=B.hf,he=B.he;
  if(!hl)s+=fills.reverse().join('')+edges.reverse().join('');
  /* fitted below the stack's top, the faded stack would fill the plot: fainter then */
  else s+=(reb?'<g clip-path="url(#'+clip+'f)">':'')+'<g class="xfd" opacity="'+(reb&&ymax<mx?Math.min(hl.fade,0.07):hl.fade)+'">'+fills.reverse().join('')+'</g>'+hf.join('')+he.join('')+(reb?'</g>':'');
  s+='<rect class="xbk" x="0" y="'+top+'" width="0" height="'+ph+'" visibility="hidden"/>';
  var ws=wins(),hit=[],cur=ws.length-1;
  SP.win.forEach(function(r,i){
    var xa=X(r[0]),xb=X(r[1]);if(xb<padL-2||xa>Wd-padR+2)return;
    var w=Math.max(i===cur?4:3,xb-xa),x=(xa+xb)/2-w/2,cls=(i===cur?' cur':'')+(ws[i].o===PW?' on':'')+(ws[i].v==='N'?' sk':'')+(w>40?' wd':'');
    s+='<rect class="xw'+cls+'" x="'+x.toFixed(1)+'" y="'+top+'" width="'+w.toFixed(1)+'" height="'+ph+'"/><rect class="xwc'+cls+'" x="'+x.toFixed(1)+'" y="'+(top-5)+'" width="'+w.toFixed(1)+'" height="4" rx="1"/>';
    hit.push([i,x,w]);
  });
  /* the largest bands named on the chart (dlab), above the stripes */
  s+=dlab(c,[{pts:pts,x0:padL,x1:Wd-padR}],ord,on,Y,reb,noteBox(hl,padL,top));
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
  s+=flagSvg(c,mks.map(function(m){return {x:X(PT(m.at)),m:m};}),top,ph,Wd,padL,padR);
  if(hl&&hl.note)s+='<text class="xhn" x="'+(padL+6)+'" y="'+(top+13)+'">'+esc(hl.note)+'</text>';
  s+='<line class="xch" x1="0" x2="0" y1="'+top+'" y2="'+(top+ph)+'" visibility="hidden"/>';
  /* a stripe's hit area: the whole stripe while it is narrow; zoomed into
     a window (a wide stripe) only its cap, so the plot under it hovers
     bucket by bucket and a drag there zooms */
  hit.forEach(function(q){
    var i=q[0],w=ws[i],hw=Math.max(12,q[2]),hx=q[1]+q[2]/2-hw/2,hh=q[2]>24?10:ph+6;
    s+='<rect class="xwh" data-i="'+i+'" data-w="'+w.o+'" x="'+hx.toFixed(1)+'" y="'+(top-6)+'" width="'+hw.toFixed(1)+'" height="'+hh+'" tabindex="0" role="button" aria-label="'
      +esc((w.o===0?'Current window, ':offTxt(w)+' window, ')+w.t+(w.o===0?'':'. Pin it'))+'"/>';
  });
  c.svg.innerHTML=s;
  c.g={mode:'span',X:X,W:Wd,padL:padL,padR:padR,top:top,ph:ph,pw:pw,d0:d0,d1:d1,ymax:ymax,ord:ord,hk:c.hk,cm:cm};
}
function tAt(c,cx){var r=c.svg.getBoundingClientRect(),x=(cx-r.left)*c.g.W/r.width;return c.g.d0+(x-c.g.padL)/c.g.pw*(c.g.d1-c.g.d0);}
function bucketAt(t){var j=Math.floor((t-SP.t0)/SP.bh);return j>=0&&j<SP.T.length&&t<SP.T1[j]?j:-1;}
function hideCross(c){var hb=$('.xbk',c.svg),ch=$('.xch',c.svg);if(hb){hb.setAttribute('visibility','hidden');ch.setAttribute('visibility','hidden');}}
function hideAll(){CH.forEach(hideCross);}
/* the crosshair + bucket band at time t (bucket ref r) on chart c (side by
   side: in panel q) */
function cross(c,t,r,q){
  var hb=$('.xbk',c.svg),ch=$('.xch',c.svg);if(!c.g||!hb)return;
  var X=c.g.X,lo=c.g.padL,hi=c.g.W-c.g.padR;
  if(c.g.mode==='win'){var p=c.g.pan&&c.g.pan[q];if(!p){hideCross(c);return;}X=p.X;lo=p.x0;hi=p.x0+p.w;}
  var xa=Math.max(lo,X(rS(r))),xb=Math.min(hi,X(rE(r))),x=X(t);
  hb.setAttribute('x',xa.toFixed(1));hb.setAttribute('width',Math.max(1,xb-xa).toFixed(1));hb.setAttribute('visibility','visible');
  ch.setAttribute('x1',x.toFixed(1));ch.setAttribute('x2',x.toFixed(1));ch.setAttribute('visibility','visible');
}
/* the tooltip of ref r (a bucket or a minute) on chart c */
function ptTip(c,r,e){var P=c.P;
  tipOn('<b>'+fAt(rS(r))+'\u2013'+fHM(rE(r))+'</b><br><span class="tm">'+(r<0?'1-min':bLab((rE(r)-rS(r))/H1))+' average, by '+c.what+'</span>'
    +ashRows(P.classes,c.cols,function(q){return rV(c,q,r);},c.vis,c.noun,c.hl&&c.hl.set),e);
}
function hover(c,e){
  if(!c.g||DRAG&&DRAG.moved)return;
  var wh=e.target.closest&&e.target.closest('.xwh'),P=c.P;
  if(wh){
    var i=+wh.getAttribute('data-i'),w=wins()[i];hideAll();
    if(HT&&HT.soft)hlSet(null);
    tipOn('<b>'+esc(w.t)+'</b><br><span class="tm">'+(w.o===0?'Current window':offTxt(w)+' window')+(w.v==='N'?', skipped':'')+', by '+c.what+'</span>'
      +(P.win?ashRows(P.classes,c.cols,function(k){return P.win[k][i];},c.vis,c.noun,c.hl&&c.hl.set):'')+(w.o===0?'':'<span class="tm">Click to pin this window</span>'),e);
    return;
  }
  if(c.g.mode==='win'){
    var pq=panAt(c,e.clientX),pr=pq?wRefAt(c,pq.q,pq.t):null;
    if(pr==null){hideAll();tipOff();if(HT&&HT.soft)hlSet(null);return;}
    if(!HS&&!DRAG){var pk=seriesAt(c,e.clientX,e.clientY);hlSet(pk<0?null:{c:c,k:pk,soft:true});}
    CH.forEach(function(o){cross(o,pq.t,pr,pq.q);});
    ptTip(c,pr,e);return;
  }
  var t=tAt(c,e.clientX),r=refAt(t);
  if(r==null||t<c.g.d0||t>c.g.d1){hideAll();tipOff();if(HT&&HT.soft)hlSet(null);return;}
  /* the band under the pointer highlights in place (not while one is sticky) */
  if(!HS&&!DRAG){var hk=seriesAt(c,e.clientX,e.clientY);hlSet(hk<0?null:{c:c,k:hk,soft:true});}
  CH.forEach(function(o){cross(o,t,r);});
  ptTip(c,r,e);
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
  var mn=SP.F&&fineCov(a,b)>0?Math.min(SP.min,FMIN):SP.min;
  if(b-a<mn){var m=(a+b)/2;a=Math.max(SP.full[0],m-mn/2);b=Math.min(SP.full[1],a+mn);a=Math.max(SP.full[0],b-mn);}
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
  tools();
  activity();
  spInit();
  var b=doc.getElementById('tl-body');if(b)b.addEventListener('scroll',sync,{passive:true});
  var tl=doc.getElementById('tl');if(tl&&W.render)W.render(tl);
  setTimeout(function(){drawAll(true);startAtCurrent();},60);
  var rt=null;window.addEventListener('resize',function(){if(rt)clearTimeout(rt);rt=setTimeout(function(){drawAll();sync();},120);});
});
})();
