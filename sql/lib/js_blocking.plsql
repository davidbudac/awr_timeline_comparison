--
-- sql/lib/js_blocking.plsql
--
-- The client script of section 24_blocking (Blocking).
-- @@-included by sql/24_blocking.sql, after its markup and payload.
--
-- No literal tilde below (SET DEFINE tilde).  GENERATED: the body below
-- (BEGIN .. END) is written by tools/js2plsql.sh from the readable source
-- sql/lib/src/js_blocking.js -- edit that file and regenerate.
--
BEGIN
    DBMS_OUTPUT.PUT_LINE('<script>');
    DBMS_OUTPUT.PUT_LINE('// js_blocking: client half of section 24_blocking (Blocking).');
    DBMS_OUTPUT.PUT_LINE('// Draws the Current window''s holder -> waiter trees from');
    DBMS_OUTPUT.PUT_LINE('// window.AWR_DATA.blocking.nodes (flat, parent first: i, p, lv, r, k =');
    DBMS_OUTPUT.PUT_LINE('// r root | w waiter | m "+ n more") into #bk-plot as inline SVG: one band');
    DBMS_OUTPUT.PUT_LINE('// per root, columns by level, a curved arrow from holder to waiter whose');
    DBMS_OUTPUT.PUT_LINE('// width is the seconds the waiter spent behind it (scaled to the largest');
    DBMS_OUTPUT.PUT_LINE('// edge, at least 300 s, so a handful of 10 s edges stay thin).  Every node is');
    DBMS_OUTPUT.PUT_LINE('// keyboard-focusable, with the exact numbers in the shared #tip; Enter /');
    DBMS_OUTPUT.PUT_LINE('// click on a node with an emitted Top SQL row jumps there.');
    DBMS_OUTPUT.PUT_LINE('(function(){');
    DBMS_OUTPUT.PUT_LINE('var doc=document,NS=''http://www.w3.org/2000/svg'',D=null,plot=null,lastW=-1,tip=null;');
    DBMS_OUTPUT.PUT_LINE('function el(n,a,p){var e=doc.createElementNS(NS,n);for(var k in a)e.setAttribute(k,a[k]);if(p)p.appendChild(e);return e;}');
    DBMS_OUTPUT.PUT_LINE('function esc(s){return String(s==null?'''':s).replace(/&/g,''&amp;'').replace(/</g,''&lt;'').replace(/>/g,''&gt;'');}');
    DBMS_OUTPUT.PUT_LINE('function dur(s){if(s<120)return Math.round(s)+'' s'';if(s<600)return (s/60).toFixed(1)+'' min'';if(s<7200)return Math.round(s/60)+'' min'';return (s/3600).toFixed(1)+'' h'';}');
    DBMS_OUTPUT.PUT_LINE('function num(v){return String(Math.round(v)).replace(/\B(?=(\d{3})+(?!\d))/g,'','');}');
    DBMS_OUTPUT.PUT_LINE('function cut(s,n){s=String(s||'''');return s.length>n?s.slice(0,n-1)+String.fromCharCode(8230):s;}');
    DBMS_OUTPUT.PUT_LINE('function txt(g,x,y,s,c){var t=el(''text'',{x:x,y:y,''class'':c||''''},g);t.textContent=s;return t;}');
    DBMS_OUTPUT.PUT_LINE('function lines(n){');
    DBMS_OUTPUT.PUT_LINE('  if(n.k===''m'')return [[''+ ''+n.n+'' more session''+(n.n===1?'''':''s''),''b''],[dur(n.s)+'' blocked in all'',''m'']];');
    DBMS_OUTPUT.PUT_LINE('  var a=[[n.id+(n.sql?''  ''+n.sql:''''),''b'']];');
    DBMS_OUTPUT.PUT_LINE('  a.push([n.ns?''holder not sampled (idle in transaction?)'':n.who,n.ns?''m i'':''m'']);');
    DBMS_OUTPUT.PUT_LINE('  if(n.lv===0)a.push([n.ns?'''':(n.ev||'''')+(n.cyc?'' \u00b7 cycle'':''''),''m'']);');
    DBMS_OUTPUT.PUT_LINE('  else a.push([(n.ev||'''')+(n.obj?'' \u00b7 ''+n.obj:''''),''m'']);');
    DBMS_OUTPUT.PUT_LINE('  if(n.lv===0)a.push([n.bn+'' session''+(n.bn===1?'''':''s'')+'', ''+dur(n.bs)+'' behind it'',''b'']);');
    DBMS_OUTPUT.PUT_LINE('  else a.push([''waited ''+dur(n.s)+(n.deep&&n.bn?'' \u00b7 + ''+n.bn+'' deeper, ''+dur(n.bs):(n.bn?'' \u00b7 holds ''+n.bn+'', ''+dur(n.bs):'''')),''b'']);');
    DBMS_OUTPUT.PUT_LINE('  return a;');
    DBMS_OUTPUT.PUT_LINE('}');
    DBMS_OUTPUT.PUT_LINE('function tipHtml(n,par){');
    DBMS_OUTPUT.PUT_LINE('  if(n.k===''m'')return ''<b>''+n.n+'' more session''+(n.n===1?'''':''s'')+''</b><br><span class="tm">not drawn, under ''+esc(par?par.id:'''')+''</span><br>''+num(n.s)+'' s blocked in all'';');
    DBMS_OUTPUT.PUT_LINE('  var h=''<b>''+esc(n.id)+''</b>''+(n.ns?''<br><span class="tm">holder not sampled in the Current window (idle in transaction?)</span>'':''<br><span class="tm">''+esc(n.who)+''</span>'');');
    DBMS_OUTPUT.PUT_LINE('  if(n.sql)h+=''<br>SQL ''+esc(n.sql);if(n.ev)h+=''<br>''+esc(n.ev);if(n.obj)h+=''<br>object ''+esc(n.obj);');
    DBMS_OUTPUT.PUT_LINE('  if(n.lv>0){h+=''<br><b>''+num(n.s)+'' s</b> behind ''+esc(par?par.id:'''');if(n.t>n.s)h+=''<br>''+num(n.t)+'' s blocked in this tree in all'';}');
    DBMS_OUTPUT.PUT_LINE('  if(n.bn)h+=''<br>''+n.bn+'' session''+(n.bn===1?'''':''s'')+'' behind it''+(n.deep?'' (not drawn)'':'''')+'', ''+num(n.bs)+'' s'';');
    DBMS_OUTPUT.PUT_LINE('  return h;');
    DBMS_OUTPUT.PUT_LINE('}');
    DBMS_OUTPUT.PUT_LINE('function tipOn(html,x,y){if(!tip){tip=doc.getElementById(''tip'');if(!tip){tip=doc.createElement(''div'');tip.id=''tip'';tip.setAttribute(''role'',''tooltip'');tip.hidden=true;doc.body.appendChild(tip);}}');
    DBMS_OUTPUT.PUT_LINE('  tip.innerHTML=html;tip.hidden=false;var w=tip.offsetWidth,h=tip.offsetHeight;x+=14;y+=16;');
    DBMS_OUTPUT.PUT_LINE('  if(x+w>innerWidth-8)x=x-w-26;if(y+h>innerHeight-8)y=y-h-28;tip.style.left=Math.max(8,x)+''px'';tip.style.top=Math.max(8,y)+''px'';}');
    DBMS_OUTPUT.PUT_LINE('function tipOff(){if(tip)tip.hidden=true;}');
    DBMS_OUTPUT.PUT_LINE('function draw(){');
    DBMS_OUTPUT.PUT_LINE('  if(!plot||!D)return;var cw=plot.clientWidth;if(!cw||cw===lastW)return;lastW=cw;');
    DBMS_OUTPUT.PUT_LINE('  var N=D.nodes,by={},kids={},i,lv=0;');
    DBMS_OUTPUT.PUT_LINE('  for(i=0;i<N.length;i++){by[N[i].i]=N[i];kids[N[i].i]=[];if(N[i].lv>lv)lv=N[i].lv;}');
    DBMS_OUTPUT.PUT_LINE('  for(i=0;i<N.length;i++)if(N[i].p&&kids[N[i].p])kids[N[i].p].push(N[i]);');
    DBMS_OUTPUT.PUT_LINE('  var G=64,nw=Math.max(cw<560?160:190,Math.min(260,Math.floor((cw-2-G*lv)/(lv+1)))),nh=70,rh=nh+12,bg=18;');
    DBMS_OUTPUT.PUT_LINE('  var W=nw*(lv+1)+G*lv+2,row=0,ms=300;');
    DBMS_OUTPUT.PUT_LINE('  for(i=0;i<N.length;i++)if(N[i].lv>0&&N[i].s>ms)ms=N[i].s;');
    DBMS_OUTPUT.PUT_LINE('  function lay(n){var k=kids[n.i];if(!k.length){n.y=row*rh;row++;return;}');
    DBMS_OUTPUT.PUT_LINE('    k.forEach(lay);n.y=(k[0].y+k[k.length-1].y)/2;}');
    DBMS_OUTPUT.PUT_LINE('  var y0=3;N.forEach(function(n){if(n.lv===0){row=0;lay(n);var o=y0;(function sh(m){m.y+=o;kids[m.i].forEach(sh);})(n);y0+=row*rh+bg;}});');
    DBMS_OUTPUT.PUT_LINE('  var H=Math.max(nh,y0-bg)+6;');
    DBMS_OUTPUT.PUT_LINE('  plot.textContent='''';');
    DBMS_OUTPUT.PUT_LINE('  var svg=el(''svg'',{width:W,height:H,viewBox:''0 0 ''+W+'' ''+H,role:''img'',''class'':''bk-svg'',''aria-label'':(doc.querySelector(''#blocking .bk-rd'')||{}).textContent||''Blocking graph''},plot);');
    DBMS_OUTPUT.PUT_LINE('  var ge=el(''g'',{''class'':''bk-edges''},svg),gl=el(''g'',{},svg),gn=el(''g'',{},svg),cpl=Math.floor((nw-20)/7.4);');
    DBMS_OUTPUT.PUT_LINE('  N.forEach(function(n){n.x=1+n.lv*(nw+G);});');
    DBMS_OUTPUT.PUT_LINE('  N.forEach(function(n){if(!n.p||!by[n.p])return;var a=by[n.p],x1=a.x+nw,y1=a.y+nh/2,x2=n.x-7,y2=n.y+nh/2,mx=(x1+x2)/2;');
    DBMS_OUTPUT.PUT_LINE('    var w=n.k===''m''?1.5:2+14*n.s/ms,d=''M''+x1+'' ''+y1+''C''+mx+'' ''+y1+'' ''+mx+'' ''+y2+'' ''+x2+'' ''+y2;');
    DBMS_OUTPUT.PUT_LINE('    el(''path'',{d:d,''class'':''bk-e''+(n.k===''m''?'' bk-em'':''''),style:''stroke-width:''+w.toFixed(1)},ge);');
    DBMS_OUTPUT.PUT_LINE('    var hs=Math.max(7,Math.min(12,w*.8));el(''path'',{d:''M''+(n.x-1)+'' ''+y2+''L''+(n.x-1-hs)+'' ''+(y2-hs*.6)+''L''+(n.x-1-hs)+'' ''+(y2+hs*.6)+''Z'',''class'':''bk-ah''+(n.k===''m''?'' bk-em'':'''')},ge);');
    DBMS_OUTPUT.PUT_LINE('    if(n.k!==''m''){var t=txt(gl,x2-hs-3,y2-6,dur(n.s),''bk-el'');t.setAttribute(''text-anchor'',''end'');}});');
    DBMS_OUTPUT.PUT_LINE('  N.forEach(function(n){var par=by[n.p];');
    DBMS_OUTPUT.PUT_LINE('    var g=el(''g'',{''class'':''bkn bk-''+n.k+(n.ns?'' bk-nsm'':''''),tabindex:''0'',transform:''translate(''+n.x+'',''+n.y+'')''},gn);');
    DBMS_OUTPUT.PUT_LINE('    var L=lines(n);g.setAttribute(''aria-label'',L.map(function(l){return l[0];}).join(''. ''));');
    DBMS_OUTPUT.PUT_LINE('    el(''rect'',{width:nw,height:nh,rx:8,''class'':''bk-box''},g);');
    DBMS_OUTPUT.PUT_LINE('    var yy=n.k===''m''?28:16;L.forEach(function(l){txt(g,9,yy,cut(l[0],cpl),''bk-t ''+l[1]);yy+=16;});');
    DBMS_OUTPUT.PUT_LINE('    g.__bk={n:n,par:par};');
    DBMS_OUTPUT.PUT_LINE('    if(n.sql&&doc.getElementById(''sq-elapsed-''+n.sql.toLowerCase()))g.classList.add(''bk-go'');});');
    DBMS_OUTPUT.PUT_LINE('}');
    DBMS_OUTPUT.PUT_LINE('function nodeOf(t){return t&&t.closest?t.closest(''#blocking .bkn''):null;}');
    DBMS_OUTPUT.PUT_LINE('function go(g){var n=g.__bk&&g.__bk.n;if(!n||!n.sql)return;var t=doc.getElementById(''sq-elapsed-''+n.sql.toLowerCase());if(t&&window.AWR_goTo)window.AWR_goTo(t,true,true);}');
    DBMS_OUTPUT.PUT_LINE('/* registered after js_timeline''s own document mouseover (which hides the');
    DBMS_OUTPUT.PUT_LINE('   shared tip over anything that is not its grid), so this one wins */');
    DBMS_OUTPUT.PUT_LINE('doc.addEventListener(''mouseover'',function(e){var g=nodeOf(e.target);if(g&&g.__bk)tipOn(tipHtml(g.__bk.n,g.__bk.par),e.clientX,e.clientY);else if(e.target.closest&&e.target.closest(''#blocking .bk-svg''))tipOff();});');
    DBMS_OUTPUT.PUT_LINE('doc.addEventListener(''mouseout'',function(e){var g=nodeOf(e.target);if(g&&!(e.relatedTarget&&g.contains(e.relatedTarget)))tipOff();});');
    DBMS_OUTPUT.PUT_LINE('doc.addEventListener(''focusin'',function(e){var g=nodeOf(e.target);if(g&&g.__bk){var b=g.getBoundingClientRect();tipOn(tipHtml(g.__bk.n,g.__bk.par),b.left+20,b.bottom-10);}});');
    DBMS_OUTPUT.PUT_LINE('doc.addEventListener(''focusout'',function(e){if(nodeOf(e.target))tipOff();});');
    DBMS_OUTPUT.PUT_LINE('doc.addEventListener(''click'',function(e){var g=nodeOf(e.target);if(g)go(g);});');
    DBMS_OUTPUT.PUT_LINE('doc.addEventListener(''keydown'',function(e){var g=nodeOf(e.target);if(!g)return;if(e.key===''Enter''||e.key==='' ''){e.preventDefault();go(g);}else if(e.key===''Escape'')tipOff();});');
    DBMS_OUTPUT.PUT_LINE('function init(){D=window.AWR_DATA&&window.AWR_DATA.blocking;plot=doc.getElementById(''bk-plot'');if(!plot||!D||!D.nodes||!D.nodes.length)return;');
    DBMS_OUTPUT.PUT_LINE('  var re=function(){lastW=-1;draw();};');
    DBMS_OUTPUT.PUT_LINE('  if(window.ResizeObserver)new ResizeObserver(function(){draw();}).observe(plot);');
    DBMS_OUTPUT.PUT_LINE('  doc.addEventListener(''awr:view'',function(){setTimeout(re,30);});');
    DBMS_OUTPUT.PUT_LINE('  addEventListener(''resize'',function(){draw();});');
    DBMS_OUTPUT.PUT_LINE('  draw();}');
    DBMS_OUTPUT.PUT_LINE('if(doc.readyState===''loading'')doc.addEventListener(''DOMContentLoaded'',init);else init();');
    DBMS_OUTPUT.PUT_LINE('})();');
    DBMS_OUTPUT.PUT_LINE('</script>');
END;
/
