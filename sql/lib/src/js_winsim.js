/* js_winsim: client half of sql/26_window_similarity.sql (Window similarity).
   Reads AWR_DATA.winsim (built by the section, oldest window first like
   AWR_WIN) and draws Part 1 (the similarity matrix + each window's
   distance from the prior windows) and Part 2 (the what-if: drop prior
   windows, re-score every metric).
   bucket() below is a TWIN of policy_bucket() in sql/lib/metric_policy.plsql
   (z over max(sample sd, 2% of |mean|), n < 3 insufficient history, |z| > 3
   large / > 2 moderate, materiality by min_pct / min_abs / share, then the
   direction).  The two MUST stay in lockstep: with nothing dropped every
   metric's bucket is compared with the PL/SQL one ("pb"), and with each
   suggestion's windows dropped with "sb"[s]; a mismatch goes to console.error
   and window.AWR_WINSIM.check.  Inline SVG / canvas, colours from CSS. */
(function(){
'use strict';
var doc=document,D=window.AWR_DATA&&window.AWR_DATA.winsim,AW=window.AWR_WIN;
if(!D||!AW||!AW.w||!D.w||D.w.length!==AW.w.length)return;
var NW=D.w.length,CI=NW-1,M=D.m,SVGNS='http://www.w3.org/2000/svg';
var TRI=String.fromCharCode(9650),TIMES=String.fromCharCode(215),MINUS=String.fromCharCode(8722);
var drop={},app,mx,chips,res,btnReset,act,tip,lastW=-1;
function esc(s){return String(s==null?'':s).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;');}
function off(i){return CI-i;}
function lab(i){return i===CI?'Current':AW.w[i].l.replace(/^-/,MINUS);}
function f1(v){return v==null?'-':(Math.round(v*10)/10).toFixed(1);}
function f2(v){return v==null?'-':v.toFixed(2);}
function zt(z){return z==null?'&ndash;':(z<0?'&minus;':'+')+Math.abs(z).toFixed(1);}
/* ---- 1. the scoring twin */
function stats(m,dr){
  var a=[],i,s=0,q=0,n,mu,sd;
  for(i=0;i<CI;i++){if(dr[off(i)]||AW.w[i].v!=='Y')continue;if(m.v[i]==null)continue;a.push(m.v[i]);}
  n=a.length;if(n===0)return {n:0,mu:null,sd:null};
  for(i=0;i<n;i++)s+=a[i];mu=s/n;
  for(i=0;i<n;i++)q+=(a[i]-mu)*(a[i]-mu);
  sd=n>1?Math.sqrt(q/(n-1)):0;
  return {n:n,mu:mu,sd:sd};
}
function bucket(m,cur,mu,sd,n){
  if(cur==null)return 'n/a';
  if(!(n>=3))return 'insufficient history';
  if(mu==null||sd==null)return 'flat baseline';
  var den=Math.max(sd,0.02*Math.abs(mu));
  if(den===0)return 'flat baseline';
  var z=(cur-mu)/den;
  if(Math.abs(z)<=2)return 'typical';
  var pct=mu===0?null:(cur-mu)/Math.abs(mu)*100;
  if(pct!=null&&Math.abs(pct)<(m.p==null?10:m.p))return 'typical';
  if(m.a!=null){
    if(m.d==='WAIT'){if(m.sh!=null&&m.sh<m.a)return 'typical';}
    else if(Math.max(Math.abs(cur),Math.abs(mu))<m.a)return 'typical';
  }else if(m.d==='WAIT'&&m.sh!=null&&m.sh<0.02)return 'typical';
  if(m.dir==='INFO')return 'noted';
  if((m.dir==='UP'&&cur<mu)||(m.dir==='DOWN'&&cur>mu))return 'improved';
  return Math.abs(z)>3?'large':'moderate';
}
function rescore(dr){
  return M.map(function(m){
    var cur=m.v[CI],s=stats(m,dr),z=null;
    if(cur!=null&&s.mu!=null&&s.sd!=null){var den=Math.max(s.sd,0.02*Math.abs(s.mu));if(den>0)z=(cur-s.mu)/den;}
    return {b:bucket(m,cur,s.mu,s.sd,s.n),z:z,n:s.n};
  });
}
function flag(b){return b==='large'||b==='moderate';}
/* finding cards: one per card group with a canonical large / moderate
   member (card_group() in sql/lib/finding_cards.plsql, emitted as m.g) */
function cards(r){
  var g={},o={cards:0,large:0,moderate:0,ml:0,mm:0};
  M.forEach(function(m,i){if(m.k!=='Y'||!flag(r[i].b))return;
    if(r[i].b==='large'){o.ml++;g[m.g]='large';}else{o.mm++;if(!g[m.g])g[m.g]='moderate';}});
  Object.keys(g).forEach(function(k){o.cards++;o[g[k]]++;});
  return o;
}
var R0=rescore({}),C0=cards(R0),CHK=[],SUG=D.sug||[];
M.forEach(function(m,i){if(R0[i].b!==m.pb)CHK.push({metric:m.d+':'+m.n,js:R0[i].b,plsql:m.pb});});
if(C0.cards!==D.cb)CHK.push({metric:'finding cards',js:C0.cards,plsql:D.cb});
SUG.forEach(function(sg,s){var dr={};sg.drop.forEach(function(o){dr[o]=1;});var RS=rescore(dr),CS=cards(RS),ch=0;
  M.forEach(function(m,i){if(RS[i].b!==R0[i].b)ch++;if(RS[i].b!==m.sb[s])CHK.push({metric:m.d+':'+m.n,js:RS[i].b,plsql:m.sb[s],dropped:sg.drop.join(',')});});
  if(ch!==sg.chg||CS.cards!==sg.ca)CHK.push({metric:'suggestion '+sg.drop.join(','),js:ch+' changed, '+CS.cards+' cards',plsql:sg.chg+' changed, '+sg.ca+' cards'});});
window.AWR_WINSIM={check:CHK,rescore:function(offs){var d={};(offs||[]).forEach(function(o){d[o]=1;});var r=rescore(d);return {buckets:r.map(function(x){return x.b;}),cards:cards(r)};}};
if(CHK.length&&window.console)console.error('winsim: the client twin of policy_bucket() disagrees with PL/SQL on '+CHK.length+' metric(s)',CHK);
/* ---- 2. tooltip (own element, the look of #tip) */
function tipOn(h,e){if(!tip){tip=doc.createElement('div');tip.className='winsim-tip';tip.setAttribute('role','tooltip');doc.body.appendChild(tip);}
  tip.innerHTML=h;tip.hidden=false;var x=e.clientX+14,y=e.clientY+16,w=tip.offsetWidth,hh=tip.offsetHeight;
  if(x+w>innerWidth-8)x=e.clientX-w-12;if(y+hh>innerHeight-8)y=e.clientY-hh-12;tip.style.left=Math.max(8,x)+'px';tip.style.top=Math.max(8,y)+'px';}
function tipOff(){if(tip)tip.hidden=true;}
/* ---- 3. Part 1: the matrix and the distance bars */
function dist(i,j){if(i===j)return 0;var a=Math.max(i,j),b=Math.min(i,j),r=D.dm[a];return r?r[b]:null;}
function scaled(m,i){var v=m.v[i];return v==null||!m.vec||!m.sp?null:(v-m.md)/m.sp;}
function diffTop(i,j){
  var a=[];M.forEach(function(m){if(!m.vec)return;var x=scaled(m,i),y=scaled(m,j);if(x==null||y==null)return;
    a.push({l:m.l,c:Math.min(Math.abs(x-y),D.cap),s:x-y});});
  a.sort(function(p,q){return q.c-p.c;});return a.slice(0,3);
}
function word(d){return d==null?'':d<=D.medd?'alike':d<=D.thr?'somewhat different':'very different';}
var DMAX=1;
(function(){for(var i=0;i<NW;i++)for(var j=0;j<i;j++){var d=dist(i,j);if(d!=null&&d>DMAX)DMAX=d;}})();
function pct(d){return Math.round(Math.min(1,d/DMAX)*16)/16;}
function mixCss(p){return 'color-mix(in srgb,var(--mean) '+Math.round(14+p*76)+'%,var(--panel))';}
function el(n,a,p){var e=doc.createElementNS(SVGNS,n);for(var k in a)e.setAttribute(k,a[k]);if(p)p.appendChild(e);return e;}
function tx(p,x,y,t,cls,anc){var e=el('text',{x:x,y:y,'class':cls||'','text-anchor':anc||'start'},p);e.textContent=t;return e;}
var G=null;   /* geometry of the last draw */
function draw(){
  if(!mx)return;var avail=mx.clientWidth;if(!avail)return;
  lastW=avail;mx.textContent='';
  var LW=46,TH=30,c=Math.max(NW>60?2:6,Math.min(26,Math.floor((avail-LW-6)/NW))),S=NW*c;
  var canvas=NW>60,BH=96,stp=Math.max(1,Math.ceil(30/c));
  G={LW:LW,TH:TH,c:c};
  var showLab=function(i){return i===CI||(CI-i)%stp===0;};
  var dimOf=function(i){return i<CI&&drop[off(i)];};
  /* the matrix */
  var box=doc.createElement('div');box.className='winsim-mxb';mx.appendChild(box);
  var svg=el('svg',{width:LW+S+4,height:TH+S+4,'class':'winsim-svg',role:'img',
    'aria-label':'Similarity matrix of the '+NW+' compared windows, oldest first, the Current window last: darker cells are windows further apart.'},null);
  box.appendChild(svg);
  for(var i=0;i<NW;i++){if(!showLab(i))continue;
    var cls='winsim-ax'+(i===CI?' cur':'')+(D.w[i].odd?' odd':'')+(dimOf(i)?' dr':'');
    tx(svg,LW+i*c+c/2,TH-6,i===CI?'Cur':lab(i),cls,'middle');
    tx(svg,LW-5,TH+i*c+c/2+3.5,(D.w[i].odd?TRI+' ':'')+(i===CI?'Cur':lab(i)),cls,'end');}
  if(canvas){
    var cv=doc.createElement('canvas'),dpr=window.devicePixelRatio||1;cv.width=Math.ceil(S*dpr);cv.height=Math.ceil(S*dpr);
    cv.style.width=S+'px';cv.style.height=S+'px';cv.className='winsim-cv';cv.style.left=LW+'px';cv.style.top=TH+'px';
    box.appendChild(cv);var g=cv.getContext('2d');g.scale(dpr,dpr);
    var pal={},probe=doc.createElement('i');probe.className='winsim-probe';mx.appendChild(probe);
    var col=function(css){if(pal[css])return pal[css];probe.style.color=css;return (pal[css]=getComputedStyle(probe).color);};
    for(i=0;i<NW;i++)for(var j=0;j<NW;j++){var d=dist(i,j),f;
      if(D.w[i].v!=='Y'||D.w[j].v!=='Y')continue;else if(i===j)f=col('var(--line)');else f=col(d==null?'var(--track)':mixCss(pct(d)));
      g.fillStyle=f;g.fillRect(j*c,i*c,c,c);}
    probe.remove();
  }else{
    for(i=0;i<NW;i++)for(j=0;j<NW;j++){var dd=dist(i,j),sk=D.w[i].v!=='Y'||D.w[j].v!=='Y';
      el('rect',{x:LW+j*c+0.5,y:TH+i*c+0.5,width:Math.max(1,c-1),height:Math.max(1,c-1),rx:c>10?2:0,
        'class':'winsim-c'+(sk?' sk':i===j?' dg':'')+((dimOf(i)||dimOf(j))&&!sk?' dr':''),
        style:sk||i===j||dd==null?'':'fill:'+mixCss(pct(dd))},svg);}
  }
  /* the Current row and column, the odd windows' columns */
  el('rect',{x:LW+CI*c,y:TH,width:c,height:S,'class':'winsim-curb'},svg);
  el('rect',{x:LW,y:TH+CI*c,width:S,height:c,'class':'winsim-curb'},svg);
  for(i=0;i<CI;i++)if(D.w[i].odd)el('rect',{x:LW+i*c,y:TH,width:c,height:S,'class':'winsim-oddb'},svg);
  if(canvas){svg.style.position='relative';box.style.height=(TH+S+4)+'px';}
  svg.addEventListener('mousemove',function(e){
    var r=svg.getBoundingClientRect(),x=e.clientX-r.left-LW,y=e.clientY-r.top-TH,jj=Math.floor(x/c),ii=Math.floor(y/c);
    if(x<0||y<0||ii>=NW||jj>=NW){tipOff();return;}tipOn(cellTip(ii,jj),e);});
  svg.addEventListener('mouseleave',tipOff);
  /* the distance bars, same columns */
  var vmax=Math.max(D.thr||0,D.cv||0);D.w.forEach(function(w){if(w.dd!=null&&w.dd>vmax)vmax=w.dd;});vmax=vmax*1.12||1;
  var bs=el('svg',{width:LW+S+64,height:BH+34,'class':'winsim-svg winsim-bars',role:'img',
    'aria-label':'Each window\'s distance from the prior windows, oldest first; bars above the dashed threshold are odd ones out.'},null);
  mx.appendChild(bs);
  var y=function(v){return 8+BH-(v/vmax)*BH;};
  el('line',{x1:LW,x2:LW+S,y1:y(0),y2:y(0),'class':'winsim-base'},bs);
  tx(bs,LW-5,y(0)+3.5,'0','winsim-ax','end');tx(bs,LW-5,y(vmax/1.12)+3.5,f1(vmax/1.12),'winsim-ax','end');
  for(i=0;i<NW;i++){var w=D.w[i],x0=LW+i*c+(c>4?1:0),bw=Math.max(1,c-(c>4?2:0));
    if(w.v!=='Y'){if(c>=6)tx(bs,LW+i*c+c/2,y(0)-3,TIMES,'winsim-skx','middle');continue;}
    if(w.dd==null)continue;
    el('rect',{x:x0,y:y(w.dd),width:bw,height:Math.max(1,y(0)-y(w.dd)),'class':'winsim-bar'+(i===CI?' cur':w.odd?' odd':'')+(dimOf(i)?' dr':'')},bs);
    if(w.odd&&c>=8)tx(bs,LW+i*c+c/2,y(w.dd)-3,TRI,'winsim-oddg','middle');}
  if(D.thr!=null){el('line',{x1:LW,x2:LW+S,y1:y(D.thr),y2:y(D.thr),'class':'winsim-thr'},bs);
    tx(bs,LW+S+4,y(D.thr)-2,'odd past','winsim-thrl','start');tx(bs,LW+S+4,y(D.thr)+9,f1(D.thr),'winsim-thrl','start');}
  for(i=0;i<NW;i++)if(showLab(i))tx(bs,LW+i*c+c/2,BH+26,i===CI?'Cur':lab(i),'winsim-ax'+(i===CI?' cur':'')+(D.w[i].odd?' odd':''),'middle');
  bs.addEventListener('mousemove',function(e){var r=bs.getBoundingClientRect(),ii=Math.floor((e.clientX-r.left-LW)/c);
    if(ii<0||ii>=NW){tipOff();return;}tipOn(barTip(ii),e);});
  bs.addEventListener('mouseleave',tipOff);
}
function cellTip(i,j){
  var a=AW.w[i],b=AW.w[j],h='<b>'+esc(lab(i))+' vs '+esc(lab(j))+'</b><br><span class="tm">'+esc(a.t)+'<br>'+esc(b.t)+'</span><br>';
  if(D.w[i].v!=='Y'||D.w[j].v!=='Y')return h+'<span class="tm">skipped window, not compared</span>';
  if(i===j)return h+'<span class="tm">the same window</span>';
  var d=dist(i,j);if(d==null)return h+'<span class="tm">no metric in common</span>';
  h+='distance <b>'+f2(d)+'</b> robust spreads, '+word(d);
  var t=diffTop(i,j);if(t.length){h+='<br><span class="tm">Differs most in:</span>';
    t.forEach(function(x){h+='<div class="tr2"><span>'+esc(x.l)+'</span><b>'+esc(lab(i))+' '+(x.s<0?'lower':'higher')+'</b></div>';});}
  return h;
}
function barTip(i){
  var w=D.w[i],a=AW.w[i],h='<b>'+esc(lab(i))+'</b><br><span class="tm">'+esc(a.t)+'</span><br>';
  if(w.v!=='Y')return h+'<span class="tm">skipped window, not scored</span>';
  if(w.dd==null)return h+'<span class="tm">no distance</span>';
  h+=(i===CI?'distance from the prior windows ':'distance from the other priors ')+'<b>'+f2(w.dd)+'</b>';
  h+='<br><span class="tm">'+(i===CI?'the window being judged, never flagged':w.odd===2?TRI+' in a group unlike the rest (threshold '+f2(D.thr)+')':w.odd?TRI+' odd one out (threshold '+f2(D.thr)+')':'alike (threshold '+f2(D.thr)+')')+'</span>';
  if(w.top&&w.top.length){h+='<br><span class="tm">Differs most in:</span>';
    w.top.forEach(function(t){h+='<div class="tr2"><span>'+esc(M[t[0]].l)+'</span><b>'+(t[2]<0?'lower':'higher')+'</b></div>';});}
  if(i<CI&&drop[off(i)])h+='<br><span class="tm">dropped in the what-if</span>';
  return h;
}
function legend(){
  var lg=app.querySelector('.winsim-lg');if(!lg)return;
  lg.innerHTML='<span class="winsim-gr"><em>alike</em><i style="background:linear-gradient(to right,'+mixCss(0)+','+mixCss(1)+')"></i><em>'+f1(DMAX)+' different</em></span>'
    +'<span><i class="winsim-sw cur"></i>Current</span><span><i class="winsim-sw odd"></i>&#9650; odd one out or group</span><span><i class="winsim-sw sk"></i>skipped (blank)</span>';
}
/* ---- 4. Part 2: the what-if */
function bk(b){var c=b==='large'?'large':b==='moderate'?'moderate':b==='improved'?'improved':b==='noted'?'noted':b==='typical'?'typical':'skip';
  return '<span class="winsim-b b-'+c+'"><i aria-hidden="true"></i>'+esc(b)+'</span>';}
function cnt(c){return '<b>'+c.cards+'</b> finding'+(c.cards===1?'':'s')+(c.cards?' ('+[c.large?c.large+' large':'',c.moderate?c.moderate+' moderate':''].filter(Boolean).join(' &middot; ')+')':'');}
function dropped(){return Object.keys(drop).filter(function(k){return drop[k];}).map(Number).sort(function(a,b){return b-a;});}
function nameOf(o){var i=CI-o;return AW.w[i]?lab(i):String(o);}
function renderChips(){
  chips.textContent='';
  for(var i=0;i<CI;i++){(function(i){var w=AW.w[i],o=off(i),b=doc.createElement('button');b.type='button';
    b.className='winsim-chip'+(D.w[i].odd?' odd':'')+(D.w[i].odd===2?' grp':'')+(w.v!=='Y'?' sk':'');
    b.innerHTML='<b>'+(D.w[i].odd?'&#9650; ':'')+esc(lab(i))+'</b><small>'+esc(w.d)+'</small>';
    if(w.v!=='Y'){b.disabled=true;b.title=w.t+': skipped window, never in the baseline';b.setAttribute('aria-pressed','false');}
    else{b.setAttribute('aria-pressed',drop[o]?'false':'true');
      b.title=w.t+(drop[o]?': dropped. Click to put it back.':': in the baseline. Click to drop it.')+(D.w[i].odd===2?' (in a group unlike the rest)':D.w[i].odd?' (odd one out)':'');
      b.addEventListener('click',function(){drop[o]=!drop[o];update();var n=chips.querySelectorAll('.winsim-chip')[i];if(n)n.focus();});}
    chips.appendChild(b);})(i);}
}
function update(){
  renderChips();
  var dl=dropped(),r=dl.length?rescore(drop):R0,c=dl.length?cards(r):C0,h='';
  btnReset.disabled=!dl.length;
  var nb=0;for(var i=0;i<CI;i++)if(AW.w[i].v==='Y'&&!drop[off(i)])nb++;
  if(!dl.length){h='<p class="winsim-sum">Nothing dropped: '+cnt(C0)+' as reported, against '+nb+' prior window'+(nb===1?'':'s')
    +' ('+C0.ml+' large and '+C0.mm+' moderate metric'+(C0.ml+C0.mm===1?'':'s')+').</p>';}
  else{
    h='<p class="winsim-sum">Without '+dl.map(nameOf).join(', ')+' ('+nb+' prior window'+(nb===1?'':'s')+' left): '+cnt(c)
      +', as reported '+cnt(C0)+'. Metrics moved: '+(c.ml+c.mm)+', as reported '+(C0.ml+C0.mm)+'.</p>';
    var ch=[];M.forEach(function(m,i){if(r[i].b!==R0[i].b)ch.push(i);});
    var rk=function(i){var a=flag(R0[i].b)?1:0,b=flag(r[i].b)?1:0;return (M[i].k==='Y'?0:4)+(a!==b?0:2);};
    ch.sort(function(a,b){return rk(a)-rk(b)||Math.abs(r[b].z||0)-Math.abs(r[a].z||0);});
    if(!ch.length)h+='<p class="winsim-sum">No metric changes bucket.</p>';
    else{
      h+='<div class="winsim-tw"><table class="winsim-ct" data-nosort data-notools data-nocount><thead><tr><th>Metric</th><th>Bucket, as reported &rarr; now</th>'
        +'<th class="num">z, as reported &rarr; now</th><th class="num">n</th></tr></thead><tbody>';
      ch.slice(0,40).forEach(function(i){var m=M[i];
        h+='<tr'+(m.k!=='Y'?' class="twin"':'')+'><td>'+m.lk+(m.k!=='Y'?' <span class="chip" title="same quantity as a counted row; not counted again">twin</span>':'')+'</td>'
          +'<td>'+bk(R0[i].b)+' &rarr; '+bk(r[i].b)+'</td><td class="num">'+zt(R0[i].z)+' &rarr; '+zt(r[i].z)+'</td><td class="num">'+R0[i].n+' &rarr; '+r[i].n+'</td></tr>';});
      h+='</tbody></table></div>';
      if(ch.length>40)h+='<p class="winsim-cap">+ '+(ch.length-40)+' more metrics change bucket.</p>';
    }
  }
  res.innerHTML=h;
  if(lastW>0)draw();
}
/* ---- 5. wiring */
function init(){
  app=doc.getElementById('winsim-app');mx=doc.getElementById('winsim-mx');chips=doc.getElementById('winsim-chips');
  res=doc.getElementById('winsim-res');btnReset=doc.getElementById('winsim-reset');act=app&&app.querySelector('.winsim-act');
  if(!app||!mx||!chips||!res)return;
  var sec=doc.getElementById('win-sim');if(sec)sec.setAttribute('data-winsim-check',CHK.length?CHK.length+' mismatch':'ok');
  app.hidden=false;var nj=sec&&sec.querySelector('.winsim-nojs');if(nj)nj.hidden=true;
  legend();
  btnReset.addEventListener('click',function(){drop={};update();});
  SUG.forEach(function(sg){var b=doc.createElement('button'),nm=sg.drop.map(function(o){return esc(nameOf(o));});
    b.type='button';b.className='winsim-btn winsim-sug';
    b.innerHTML='Try without '+(sg.k==='grp'?'the group ':'')+(nm.length>5?nm[0]+', &hellip; '+nm[nm.length-1]+' ('+nm.length+' windows)':nm.join(', '));
    b.addEventListener('click',function(){drop={};sg.drop.forEach(function(o){drop[o]=true;});update();});
    if(act)act.insertBefore(b,btnReset);});
  update();draw();
  var redraw=function(){if(mx.clientWidth&&mx.clientWidth!==lastW)draw();};
  if(window.ResizeObserver)new ResizeObserver(redraw).observe(mx);
  window.addEventListener('resize',redraw);
  doc.addEventListener('awr:view',function(){setTimeout(function(){lastW=-1;redraw();},30);});
  doc.addEventListener('awr:theme',function(){if(NW>60){lastW=-1;redraw();}});
  doc.addEventListener('scroll',tipOff,{passive:true});
}
if(doc.readyState==='loading')doc.addEventListener('DOMContentLoaded',init);else init();
})();
