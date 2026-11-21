(function(){
/* sql/lib/src/js_design.js -- the quiet / dashboard design script
   (window.AWR_DESIGN, set by sql/lib/design_tail.sql).  Runs from the
   last DOMContentLoaded handler of the page, after the chrome (00), the
   window component and the Timeline have built their DOM; it only moves
   and restyles what they built, so every id, link and number survives.
   JS off: none of this runs and the design is the skin alone. */
var doc=document,D=window.AWR_DESIGN||"quiet";
function $(s,r){return (r||doc).querySelector(s);}
function $$(s,r){return Array.prototype.slice.call((r||doc).querySelectorAll(s));}
function mk(t,c,p){var e=doc.createElement(t);if(c)e.className=c;if(p)p.appendChild(e);return e;}
function txt(el){return el?(el.textContent||"").replace(/\s+/g," ").trim():"";}
function esc(s){return String(s==null?"":s).replace(/[&<>"]/g,function(c){return {"&":"&amp;","<":"&lt;",">":"&gt;","\"":"&quot;"}[c];});}
function num(s){if(s==null||s==="")return null;var v=+s;return isNaN(v)?null:v;}
function cl(el){return el?el.cloneNode(true):null;}
function own(el){var c=el.cloneNode(true);$$(".chip,.xlink,.xlinks,.copy-btn",c).forEach(function(x){x.parentNode.removeChild(x);});return txt(c);}
var MID=" \u00B7 ";

/* ---- 1. both designs: the Activity help paragraph behind "How to read" */
function howToRead(){
  var ax=$("#ashx"),p=ax&&$(".axn2",ax),h=ax&&$(".axh",ax);if(!p||!h)return;
  if(!p.id)p.id="ax-how";
  var b=mk("button","axhow");b.type="button";b.setAttribute("aria-expanded","false");b.setAttribute("aria-controls",p.id);
  b.innerHTML='<i aria-hidden="true">?</i>How to read';
  h.appendChild(b);h.appendChild(p);ax.classList.add("howable");
  function set(on){ax.classList.toggle("howopen",on);b.setAttribute("aria-expanded",on?"true":"false");}
  b.addEventListener("click",function(e){e.stopPropagation();set(!ax.classList.contains("howopen"));});
  doc.addEventListener("click",function(e){if(ax.classList.contains("howopen")&&!p.contains(e.target)&&e.target!==b)set(false);});
  window.addEventListener("keydown",function(e){if(e.key==="Escape"&&ax.classList.contains("howopen")){e.stopImmediatePropagation();set(false);b.focus();}},true);
}

/* ---- 2. both designs: the per-table CSV / Markdown copy buttons in one menu */
function toolMenus(){
  $$(".tbl-tools").forEach(function(bar){
    var btns=$$(":scope > .tool-btn",bar);if(!btns.length)return;
    var d=mk("details","tmenu"),s=mk("summary","",d),p=mk("div","tmenu-p",d);
    s.setAttribute("aria-label","Copy this table");s.title="Copy this table as CSV or Markdown";s.textContent="\u00B7\u00B7\u00B7";
    btns.forEach(function(b){var t=txt(b);b.textContent=/MD/.test(t)?"Copy as Markdown":"Copy as CSV";p.appendChild(b);
      b.addEventListener("click",function(){setTimeout(function(){d.open=false;},900);});});
    bar.appendChild(d);bar.classList.add("tmenu-on");
  });
  doc.addEventListener("click",function(e){$$("details.tmenu[open]").forEach(function(d){if(!d.contains(e.target))d.open=false;});});
}

/* ---- 3. dashboard helpers: per-window bars as one SVG (KPI cards, rows) */
function fmt(v){
  if(v==null||isNaN(v))return "\u2014";
  var a=Math.abs(v),d=v,u="";
  if(a>=1e9){d=v/1e9;u=" G";}else if(a>=1e6){d=v/1e6;u=" M";}else if(a>=1e4){d=v/1e3;u=" k";}
  else if(a>=1000)return Math.round(v).toLocaleString("en-US");
  return String(Number(d.toPrecision(4)))+u;
}
function withUnit(v,unit){var s=fmt(v);if(!unit)return s;if(/^[kMG]?B/.test(unit)&&/ [kMG]$/.test(s))return s.replace(/ ([kMG])$/," $1")+unit;return s+(/^[\/%]/.test(unit)?"":" ")+unit;}
function rowData(r){
  if(!r)return null;
  var v=String(r.getAttribute("data-v")||"").split(",").map(num);if(!v.length)return null;
  return {v:v,mu:num(r.getAttribute("data-mu")),sd:num(r.getAttribute("data-sd")),sev:r.getAttribute("data-sev")||"",unit:r.getAttribute("data-unit")||""};
}
function wins(){var w=window.AWR_WIN;return w&&w.w?w.w:[];}
function marks(){return window.AWR_WG&&AWR_WG.markers?AWR_WG.markers():[];}
/* o: {v, mu, sd, unit}; opt: {w, h, mini} */
function wbars(o,opt){
  var v=o.v,N=v.length,W=opt.w,H=opt.h,mini=!!opt.mini,ws=wins(),dates=!mini&&ws.length===N;
  var top=mini?2:22,bot=mini?1:(dates?18:4),ph=H-top-bot,slot=W/N;
  var have=v.filter(function(x){return x!=null;}),z=null;
  if(o.mu!=null){var d=Math.max(o.sd||0,0.02*Math.abs(o.mu));z=[Math.max(0,o.mu-2*d),o.mu+2*d,o.mu];}
  var max=Math.max.apply(null,have.concat(z?[z[1]]:[]).concat([0]));if(!(max>0))max=1;
  var y=function(x){return top+ph-Math.max(0,x)/max*ph;};
  var s='<svg class="dwb'+(mini?' mini':'')+'" viewBox="0 0 '+W+' '+H+'" width="'+W+'" height="'+H+'"'+(mini?' preserveAspectRatio="none"':'')+' role="img" aria-label="'+esc(opt.label||"Value per compared window")+'">';
  if(z){s+='<rect class="dz" x="0" y="'+y(z[1]).toFixed(1)+'" width="'+W+'" height="'+Math.max(1,y(z[0])-y(z[1])).toFixed(1)+'"/>';
    s+='<line class="dm" x1="0" x2="'+W+'" y1="'+y(z[2]).toFixed(1)+'" y2="'+y(z[2]).toFixed(1)+'"/>';}
  var every=Math.max(1,Math.ceil(46/slot)),lastLab=-1;
  v.forEach(function(x,i){
    var cur=i===N-1,bw=Math.min(slot*(cur?0.7:0.58),cur?26:20),cx=slot*i+slot/2,wi=ws[i]||{};
    var tt=(wi.t||("window "+(i+1)))+": "+(x==null?"no value (window skipped)":withUnit(x,o.unit));
    if(x!=null){var h=Math.max(1.5,top+ph-y(x));s+='<rect class="'+(cur?'dbc':'dbp')+'" x="'+(cx-bw/2).toFixed(1)+'" y="'+(top+ph-h).toFixed(1)+'" width="'+bw.toFixed(1)+'" height="'+h.toFixed(1)+'" rx="'+(mini?0.8:2)+'"><title>'+esc(tt)+'</title></rect>';}
    else if(!mini)s+='<rect class="dnil" x="'+(cx-3).toFixed(1)+'" y="'+(top+ph-1.5)+'" width="6" height="1.5"><title>'+esc(tt)+'</title></rect>';
    if(dates&&(cur||(i%every===0&&N-1-i>=every))){s+='<text class="dax'+(cur?' cur':'')+'" x="'+(cur?W-1:cx).toFixed(1)+'" y="'+(H-4)+'" text-anchor="'+(cur?'end':'middle')+'">'+esc(wi.d||"")+'</text>';lastLab=i;}
    if(cur&&!mini&&x!=null)s+='<text class="dcv" x="'+(W-1)+'" y="'+Math.max(11,top+ph-Math.max(1.5,top+ph-y(x))-4).toFixed(1)+'" text-anchor="end">'+esc(fmt(x))+'</text>';
  });
  if(!mini&&ws.length===N){
    var tiers=[],lv=v[N-1];if(lv!=null)tiers.push([W-fmt(lv).length*7-6,W]);
    marks().forEach(function(m){
      var i=-1;ws.forEach(function(wi,k){if(wi.o===m.o)i=k;});if(i<0)return;
      var x=slot*i;s+='<line class="dmk" x1="'+x.toFixed(1)+'" x2="'+x.toFixed(1)+'" y1="'+(top-6)+'" y2="'+(top+ph)+'"><title>'+esc(m.l+", "+m.t)+'</title></line>';
      var lw=m.s.length*6+6,clash=function(a){return tiers.some(function(r){return a<r[1]&&a+lw>r[0];});},end=x+lw>W||clash(x),x0=end?x-lw:x;
      if(clash(x0))return;tiers.push([x0,x0+lw]);
      s+='<text class="dml" x="'+(end?x-3:x+3).toFixed(1)+'" y="'+(top-9)+'" text-anchor="'+(end?'end':'start')+'"><title>'+esc(m.l+", "+m.t)+'</title>'+esc(m.s)+'</text>';
    });
  }
  return s+'</svg>';
}

/* ---- 4. dashboard: the "Jump to" palette (Ctrl+K) instead of the rail */
function palette(){
  var tb=$("#topbar"),seg=tb&&$(".seg",tb);if(!tb)return;
  var b=mk("button","dsearch");b.type="button";b.setAttribute("aria-haspopup","dialog");
  b.innerHTML='<svg viewBox="0 0 16 16" width="14" height="14" aria-hidden="true"><circle cx="7" cy="7" r="4.5" fill="none" stroke="currentColor" stroke-width="1.5"/><path d="M10.5 10.5l3 3" stroke="currentColor" stroke-width="1.5" stroke-linecap="round"/></svg><span>Jump to\u2026</span><kbd>Ctrl K</kbd>';
  tb.insertBefore(b,seg||null);
  var dlg=mk("dialog","dpal",doc.body);dlg.setAttribute("aria-label","Jump to a section or a row");
  dlg.innerHTML='<div class="dpi"><svg viewBox="0 0 16 16" width="15" height="15" aria-hidden="true"><circle cx="7" cy="7" r="4.5" fill="none" stroke="currentColor" stroke-width="1.5"/><path d="M10.5 10.5l3 3" stroke="currentColor" stroke-width="1.5" stroke-linecap="round"/></svg>'
    +'<input type="text" role="combobox" aria-expanded="true" aria-controls="dpal-list" aria-autocomplete="list" autocomplete="off" spellcheck="false" placeholder="Section, finding, metric, event, SQL id, segment, file, parameter"></div>'
    +'<ul id="dpal-list" role="listbox" aria-label="Matches"></ul><p class="dpf"><span><kbd>\u2191</kbd><kbd>\u2193</kbd> move</span><span><kbd>Enter</kbd> open</span><span><kbd>Esc</kbd> close</span></p>';
  var inp=$("input",dlg),ul=$("ul",dlg),items=null,res=[],act=0;
  function build(){
    items=[];var seen={};
    function add(id,label,grp,kind){if(!id||seen[id]||!label)return;var el=doc.getElementById(id);if(!el)return;seen[id]=1;items.push({id:id,l:label,g:grp,k:kind,s:(label+" "+grp+" "+id).toLowerCase()});}
    var grp="";
    $$("nav.toc .rail-list > *").forEach(function(el){
      if(el.tagName==="B"){grp=txt(el);return;}
      if(el.tagName!=="A"||el.hidden||el.classList.contains("more-sections"))return;
      var h=(el.getAttribute("href")||"").slice(1);
      add(h,el.getAttribute("data-label")||own(el),el.classList.contains("sub")?"Finding":grp,el.classList.contains("sub")?"finding":"section");
    });
    $$("details.drow[id]").forEach(function(d){add(d.id,txt($(".dnm b",d)),"Finding"+MID+txt($(".dnm small",d)),"finding");});
    $$("main tr[id]").forEach(function(tr){
      if(tr.closest("details.drow")||!tr.cells||!tr.cells.length)return;
      var tb=tr.closest("table"),cap=tb&&tb.caption?txt(tb.caption):"",sec=tr.closest("section"),h=sec&&$("h2",sec);
      var g=cap?cap.replace(/\s+\u2014\s+/g,MID):(h?txt($(".lt",h)||h.firstChild):"");
      add(tr.id,own(tr.cells[0]).slice(0,90),g,"row");
    });
    $$("main [id^='ash-card-'], main article.fc[id], main [id^='sm-']").forEach(function(el){
      var h=$("h3",el)||el;add(el.id,txt(h).slice(0,90),el.tagName==="ARTICLE"?"Card":"SQL","row");
    });
  }
  function render(q){
    if(!items)build();
    var w=q.toLowerCase().split(/\s+/).filter(Boolean);
    res=items.filter(function(it){return w.every(function(x){return it.s.indexOf(x)>=0;});});
    if(w.length)res.sort(function(a,b){var pa=a.l.toLowerCase().indexOf(w[0])===0?0:1,pb=b.l.toLowerCase().indexOf(w[0])===0?0:1;
      if(pa!==pb)return pa-pb;var ka=a.k==="row"?1:0,kb=b.k==="row"?1:0;return ka-kb;});
    else res=res.filter(function(it){return it.k!=="row";});
    res=res.slice(0,60);
    var fi=doc.getElementById("row-filter");
    if(w.length&&fi)res.push({id:"",l:'Filter every table to rows matching "'+q+'"',g:"Filter rows",k:"filter",q:q});
    act=0;ul.innerHTML=res.map(function(it,i){return '<li role="option" id="dpo-'+i+'" data-i="'+i+'" class="'+it.k+'" aria-selected="'+(i===0)+'"><span class="dpl">'+esc(it.l)+'</span><span class="dpg">'+esc(it.g)+'</span></li>';}).join("")
      ||'<li class="dpn" role="option" aria-disabled="true" aria-selected="false">No match</li>';
    sel(0);
  }
  function sel(i){if(!res.length)return;act=(i+res.length)%res.length;$$("li[data-i]",ul).forEach(function(li,k){li.setAttribute("aria-selected",String(k===act));});
    var li=$('li[data-i="'+act+'"]',ul);if(li){inp.setAttribute("aria-activedescendant",li.id);li.scrollIntoView({block:"nearest"});}}
  function go(it){
    dlg.close();if(!it)return;
    if(it.k==="filter"){var fi=doc.getElementById("row-filter");if(fi){fi.value=it.q;fi.dispatchEvent(new Event("input",{bubbles:true}));}if(window.AWR_setView)AWR_setView("all",true);return;}
    var el=doc.getElementById(it.id);if(el&&window.AWR_goTo)AWR_goTo(el,el.tagName!=="SECTION",true);
    try{history.replaceState(null,"","#"+it.id);}catch(e){}
  }
  function open(){if(dlg.open)return;inp.value="";render("");try{dlg.showModal();}catch(e){dlg.setAttribute("open","");}inp.focus();}
  b.addEventListener("click",open);
  inp.addEventListener("input",function(){render(inp.value.trim());});
  dlg.addEventListener("keydown",function(e){
    if(e.key==="ArrowDown"){e.preventDefault();sel(act+1);}
    else if(e.key==="ArrowUp"){e.preventDefault();sel(act-1);}
    else if(e.key==="Enter"){e.preventDefault();go(res[act]);}
    else if(e.key==="Escape"){e.preventDefault();e.stopPropagation();dlg.close();b.focus();}
    e.stopPropagation();
  });
  ul.addEventListener("click",function(e){var li=e.target.closest("li[data-i]");if(li)go(res[+li.getAttribute("data-i")]);});
  ul.addEventListener("mousemove",function(e){var li=e.target.closest("li[data-i]");if(li&&+li.getAttribute("data-i")!==act)sel(+li.getAttribute("data-i"));});
  dlg.addEventListener("click",function(e){if(e.target===dlg)dlg.close();});
  window.addEventListener("keydown",function(e){
    if((e.metaKey||e.ctrlKey)&&(e.key==="k"||e.key==="K")){e.preventDefault();e.stopImmediatePropagation();open();}
  },true);
  window.AWR_palette=open;
}

/* ---- 5. dashboard: Activity as one chart at a time (or both) */
function activityTabs(){
  var ax=$("#ashx"),h=ax&&$(".axh",ax);if(!h||!$("#ax-cls")||!$("#ax-ev"))return;
  var g=mk("div","seg axseg");g.setAttribute("role","group");g.setAttribute("aria-label","Which Activity chart");
  [["cls","By wait class"],["ev","By wait event"],["both","Both"]].forEach(function(o){
    var b=mk("button","",g);b.type="button";b.setAttribute("data-ax",o[0]);b.textContent=o[1];
    b.addEventListener("click",function(){mode(o[0]);});
  });
  var how=$(".axhow",h);h.insertBefore(g,how||null);
  function mode(m){
    ax.classList.toggle("ax-cls-only",m==="cls");ax.classList.toggle("ax-ev-only",m==="ev");
    $$("button",g).forEach(function(b){b.setAttribute("aria-pressed",String(b.getAttribute("data-ax")===m));});
    if(window.AWR_TL&&AWR_TL.redraw)setTimeout(AWR_TL.redraw,0);
  }
  mode("cls");
  window.AWR_axMode=mode;
}

/* ---- 6. dashboard: KPI cards (DB time + one per finding card) */
function sevOf(card){return card.classList.contains("f-large")?"large":card.classList.contains("f-moderate")?"moderate":"";}
function sevWord(s){return s==="large"?"Large":s==="moderate"?"Moderate":"Normal";}
function detailOf(card){var a=$("h3 a.ent",card);return a?doc.getElementById((a.getAttribute("href")||"").slice(1)):null;}
function famOf(card){return txt($('nav.toc a.sub[href="#'+card.id+'"]'))||txt($(".fc-k",card));}
function kpi(o){
  var a=mk(o.href?"a":"div","dkpi"+(o.sev?" s-"+o.sev:""));if(o.href)a.href=o.href;
  var bd=o.sev==="large"?"crit":o.sev==="moderate"?"warn":"ok";
  a.innerHTML='<span class="kh"><span class="kl">'+esc(o.label)+'</span><span class="badge '+bd+'">'+sevWord(o.sev)+'</span></span>'
    +'<span class="kv"><span class="kb">'+esc(o.value)+'</span><span class="ku">'+esc(o.unit)+'</span><span class="kd"></span></span>'
    +'<span class="kbars"></span><span class="kc">'+esc(o.ctx)+'</span>';
  if(o.delta)$(".kd",a).appendChild(o.delta);
  if(o.data)$(".kbars",a).innerHTML=wbars(o.data,{w:240,h:40,mini:true,label:o.label+" per compared window"});
  if(o.title)a.title=o.title;
  return a;
}
function kpis(){
  var v=$("#verdict");if(!v)return;
  var row=mk("div","dkpis vw in-s");
  var hb=$("#hero-dbt"),dbc=$("#findings .cards > article#f-dbtime");
  if(hb){
    var big=cl($(".l .big",hb)),u=big?$(".u",big):null,unit=u?txt(u):"";if(u)u.parentNode.removeChild(u);
    var g=$(".g",hb),z=txt($(".z",g)),ctx=[txt($(".l .sub",hb))];
    if(dbc){var t=txt($("h3",dbc)).match(/,\s*(mostly .*|all .*)$/);if(t)ctx.push(t[1]);}
    row.appendChild(kpi({label:"DB time",value:txt(big),unit:unit,sev:dbc?sevOf(dbc):(hb.getAttribute("data-sev")==="large"||hb.getAttribute("data-sev")==="moderate"?hb.getAttribute("data-sev"):""),
      delta:cl($(".d",g)),data:rowData(hb),ctx:ctx.filter(Boolean).join(MID),href:dbc?"#f-dbtime":"",title:"DB time per compared window"+(z?", "+z:"")}));
  }
  $$("#findings .cards > article.fc:not(.chg)").forEach(function(card){
    if(card.id==="f-dbtime")return;
    var det=detailOf(card),r=$(".wg .r.bars",card)||(det&&doc.getElementById("tl-"+det.id));
    var ev=$(".ev .evr dd .id",card),ctx=[txt($(".big .nrm",card)),txt(ev)];
    var lead=$("h3 a.ent",card);
    row.appendChild(kpi({label:lead?txt(lead):famOf(card),value:txt($(".big .v",card)),unit:txt($(".big .u",card)),sev:sevOf(card),
      delta:cl(det&&$("td.c-d .d",det))||cl($("h3 .d",card)),data:rowData(r),ctx:ctx.filter(Boolean).join(MID),href:"#"+card.id,title:famOf(card)+": "+txt($("h3",card))}));
  });
  var n=row.children.length;if(!n)return;
  /* four to a row (a lone DB time card stays a quarter wide); five or six: three to a row */
  row.style.setProperty("--kn",n===5||n===6?3:4);
  v.parentNode.insertBefore(row,v.nextSibling);
}

/* ---- 7. dashboard: the findings as one expandable table, What changed beside it */
/* plan 020: the Summary view prints z only up to 10 sigma (band_ztxt's
   p_cap); the findings table clones its bands from the All-sections
   tables, which keep the exact z, so cap the clone's pinned text */
function capz(bd){
  var b=bd&&$(".ov",bd);if(!b)return bd;
  var M=String.fromCharCode(8722),S=String.fromCharCode(963),t=txt(b);
  var z=parseFloat(t.replace(/^[<>]/,"").replace(M,"-"));
  if(isNaN(z)||Math.abs(z)<=10)return bd;
  var c=z>0?">+10"+S:"<"+M+"10"+S,al=bd.getAttribute("aria-label");
  if(al)bd.setAttribute("aria-label",al.split(t).join(c));
  b.textContent=c;return bd;
}
function drow(o){
  var d=mk("details","drow"+(o.sev?" s-"+o.sev:"")+(o.lead?" lead":""));
  if(o.key){d.setAttribute("data-row",o.key);var rid="dr-"+o.key,k=2;while(doc.getElementById(rid))rid="dr-"+o.key+"-"+(k++);d.id=rid;}
  var s=mk("summary","",d);
  s.innerHTML='<span class="dch" aria-hidden="true"></span><span class="dsev"><i aria-hidden="true"></i>'+sevWord(o.sev)+'</span>'
    +'<span class="dnm"><b>'+esc(o.name)+'</b><small>'+esc(o.fam)+'</small></span><span class="dcur">'+esc(o.cur)+'</span>'
    +'<span class="dnr">'+esc(o.nrm)+'</span><span class="dbd"></span><span class="ddl"></span><span class="dtr"></span>';
  if(o.band)$(".dbd",s).appendChild(capz(o.band));
  if(o.delta)$(".ddl",s).appendChild(o.delta);
  if(o.data){var tc=$(".dtr",s),ms=null;
    if(window.AWR_microStrip){try{ms=AWR_microStrip(o.data.v.map(function(x){return x==null?"":x;}).join(","),o.name);}catch(e){ms=null;}}
    if(ms&&ms.svg){tc.innerHTML=ms.svg;if(ms.title)tc.title=ms.title;}
    else tc.innerHTML=wbars(o.data,{w:92,h:18,mini:true,label:o.name+" per compared window"});}
  var b=mk("div","dbody",d);
  if(o.body)b.appendChild(o.body);
  if(o.data&&!o.lead){var bars=mk("div","dbars",b);if(o.body)b.insertBefore(bars,o.body);
    var draw=function(){var w=Math.max(260,Math.min(620,(bars.clientWidth||b.clientWidth||520)));bars.innerHTML=wbars(o.data,{w:w,h:150,label:o.name+" per compared window"});};
    d.addEventListener("toggle",function(){if(d.open)draw();});d._draw=function(){if(d.open)draw();};}
  return d;
}
/* plan 020 follow-up (G4): the card's impact as a chip in its lead row --
   the row hides the card's header, where the .fc-imp chip lives.  From
   data-impact / data-share like the triage list; only a rise of 0.01 AAS
   or more, as on the card */
function impChip(card){
  var im=card.getAttribute("data-impact"),sh=card.getAttribute("data-share");
  if(im===null||im===""||!(+im>=0.01))return null;
  var v=+im,a=Math.abs(v),s=(sh===null||sh==="")?null:+sh,ch=$(".fc-k .fc-imp",card);
  var c=mk("span","dimp");
  c.textContent="+"+(a>=10?a.toFixed(1):a>=1?a.toFixed(2):a.toFixed(3))+" AAS"+(card.id==="f-dbtime"?" above normal":s===null?"":MID+(s<1?"<1":s)+"%");
  c.title=ch?txt(ch)+". "+(ch.getAttribute("title")||""):"Time added, in average active sessions";
  return c;
}
function findTable(){
  var fs=$("#findings");if(!fs)return null;
  /* the cards, or (nothing moved) 07's "No finding" note */
  var cw=$(":scope > .cards",fs),calm=$(":scope > .panel.calm.in-s",fs),h2=$(":scope > h2",fs);
  var cards=cw?$$(":scope > article.fc:not(.chg)",cw):[];
  var grid=mk("div","dgrid vw in-s");fs.insertBefore(grid,cw||calm||(h2?h2.nextSibling:fs.firstChild));
  var main=mk("div","dmain",grid);
  var tabs=mk("div","tabs dtabs",main);tabs.setAttribute("data-tabs","dfind");tabs.setAttribute("role","tablist");tabs.setAttribute("aria-label","Findings");
  function tab(k,label,n,on){var t=mk("button","",tabs);t.type="button";t.setAttribute("data-t",k);t.setAttribute("role","tab");
    t.setAttribute("aria-selected",on?"true":"false");t.setAttribute("tabindex",on?"0":"-1");if(on)t.classList.add("on");
    t.innerHTML=esc(label)+(n!=null?' <span class="n">'+n+'</span>':'');
    t.id="dfind-t-"+k;t.setAttribute("aria-controls","dfind-p-"+k);
    var p=mk("div","tabpanel dpanel"+(on?" on":""),main);p.setAttribute("data-tabs","dfind");p.setAttribute("data-t",k);p.setAttribute("role","tabpanel");p.id="dfind-p-"+k;p.setAttribute("aria-labelledby",t.id);return p;}
  var moved=0,tbl=mk("div","dft");
  var hd=mk("div","dfh",tbl);hd.setAttribute("aria-hidden","true");
  hd.innerHTML='<span></span><span>Severity</span><span>Metric</span><span class="dcur">Current</span><span class="dnr">Normal</span><span class="dbd">vs normal</span><span class="ddl">\u0394</span><span class="dtr">Trend</span>';
  cards.forEach(function(card){
    /* plan 025: a card folded by 07's script opens: the row is the fold */
    if(window.AWR_fcOpen)AWR_fcOpen(card);
    var fam=famOf(card),det=detailOf(card),sev=sevOf(card),lead=$("h3 a.ent",card);
    var tl=det?doc.getElementById("tl-"+det.id):null;
    var unit=txt($(".big .u",card)),nrm=txt($(".big .nrm",card)).replace(/^normal\s+/,"");
    if(unit&&nrm.slice(-unit.length)===unit)nrm=nrm.slice(0,-unit.length).trim();
    var lrow=drow({lead:true,key:card.id,sev:sev,name:lead?txt(lead):fam,fam:fam,cur:(txt($(".big .v",card))+(/^[\/%]/.test(unit)?"":" ")+unit).trim(),nrm:nrm,
      band:cl(det&&$("td.c-band .bd",det))||cl($(".fc-band .bd",card)),delta:cl(det&&$("td.c-d .d",det))||cl($("h3 .d",card)),data:rowData(tl||$(".wg .r.bars",card)),body:card});
    tbl.appendChild(lrow);
    /* the card's impact chip (G4) and, plan 027, its pattern tags (js_wingrid
       tagCards ran before) on one line under the name */
    var imp=impChip(card),ptg=$(".fc-tags",card),ptn=ptg&&ptg.children.length;
    if(imp||ptn){var mt=mk("span","dmeta",$(".dnm",lrow));if(imp)mt.appendChild(imp);
      if(ptn){var pcl=ptg.cloneNode(true);pcl.className="fc-tags dtags";mt.appendChild(pcl);}}
    moved++;
    $$(".rel tbody tr",card).forEach(function(tr){
      if(tr.classList.contains("twin")||!(tr.classList.contains("crit")||tr.classList.contains("warn")))return;
      var a=$("td:first-child a.ent",tr),id=a?(a.getAttribute("href")||"").slice(1):"",tr2=id?doc.getElementById("tl-"+id):null;
      var body=mk("div","dnote"),nm=a?txt(a):own(tr.cells[0]);
      body.innerHTML='<p>Part of the <b>'+esc(fam)+'</b> finding, led by '+esc(lead?txt(lead):fam)+'.</p>';
      var ln=mk("p","dlinks",body);
      var cf=mk("a","",ln);cf.href="#"+card.id;cf.textContent="Open the finding";
      if(tr2){var j=mk("a","jump",ln);j.href="#timeline";j.setAttribute("data-tl",tr2.id);j.textContent="Open in Timeline";}
      if(id&&doc.getElementById(id)){var al=mk("a","",ln);al.href="#"+id;al.textContent="Row in All sections";}
      tbl.appendChild(drow({key:id,sev:tr.classList.contains("crit")?"large":"moderate",name:nm,fam:fam,cur:txt($('td[data-w="0"]',tr)),nrm:txt($("td.c-rng",tr)),
        band:cl($("td.c-band .bd",tr)),delta:cl($("td.c-d .d",tr)),data:rowData(tr2),body:body}));
      moved++;
    });
  });
  var pM=tab("moved","Moved",moved,true);
  if(moved)pM.appendChild(tbl);else if(calm)pM.appendChild(calm);else{var no=mk("p","dempty",pM);no.textContent="No scored metric moved beyond its normal range.";}
  var sn=$("#s-normal"),imp=sn&&$(".panel.note.improved",sn);
  if(sn){var nn=(txt($("h2 .meta",sn)).match(/\d+/)||[null])[0];var pN=tab("normal","Normal",nn,false);pN.appendChild(sn);
    /* plan 032: the tab is the fold, so the folded body opens */
    var cf=$("details.calm-fold",sn);if(cf)cf.open=true;}
  if(imp){var pI=tab("improved","Improved",$$(".nr",imp).length,false);pI.appendChild(imp);}
  /* What changed around it: the plan / config cards + the releases */
  var side=mk("aside","dside",grid);side.setAttribute("aria-label","What changed around it");
  var sc=$("#s-changes");if(sc&&!sc.hidden)side.appendChild(sc);
  var ms=marks();
  if(ms.length){
    var rel=mk("div","drel panel",side);
    rel.innerHTML='<h3>Releases in the span <span class="n">'+ms.length+'</span></h3><ul>'+ms.map(function(m){return '<li title="'+esc(m.l+", "+m.at)+'"><i aria-hidden="true"></i><span>'+esc(m.l)+'</span><span class="dt">'+esc(m.t)+'</span></li>';}).join("")+'</ul>';
  }
  if(!side.children.length)grid.classList.add("noside");
  return grid;
}

/* plan 026: a plan-change card that 17 moved under the card it explains
   goes back to "What changed around it", which the dashboard shows
   beside the findings table */
function explainsBack(){
  var sl=$("#changes-slot"),sc=$("#s-changes");if(!sl)return;
  var ex=$$("#findings article.fc[data-explains]");if(!ex.length)return;
  /* 17 folds it with a folded card (G4): the side column shows it open, no toggle */
  ex.reverse().forEach(function(p){sl.insertBefore(p,sl.firstChild);if(window.AWR_fcOpen)AWR_fcOpen(p);var tg=$(".fc-tg",p);if(tg)tg.parentNode.removeChild(tg);});
  if(sc&&sc.hidden){sc.hidden=false;var rl=$('nav.toc a[href="#s-changes"]');if(rl)rl.hidden=false;}
}

/* G4: print shows every finding card -- the closed lead rows open for
   print and shut again after (css_design.css shows every findings tab) */
function printRows(){
  var op=null;
  window.addEventListener("beforeprint",function(){if(op)return;op=$$("details.drow.lead:not([open])");
    op.forEach(function(d){d.open=true;if(window.AWR_WG)AWR_WG.render(d);});});
  window.addEventListener("afterprint",function(){if(!op)return;op.forEach(function(d){d.open=false;});op=null;});
}
function dashboard(){
  var bd=doc.body;
  palette();
  activityTabs();
  explainsBack();
  kpis();
  findTable();
  printRows();
  bd.classList.add("d-dash");
  var rt=null;
  window.addEventListener("resize",function(){if(rt)clearTimeout(rt);rt=setTimeout(function(){$$("details.drow[open]").forEach(function(d){if(d._draw)d._draw();});},150);});
  doc.addEventListener("awr:view",function(){setTimeout(function(){$$("details.drow[open]").forEach(function(d){if(d._draw)d._draw();});},60);});
  if(window.AWR_fitTables)setTimeout(AWR_fitTables,60);
  if(window.AWR_WG&&AWR_WG.refit)setTimeout(AWR_WG.refit,80);
  if(window.AWR_TL&&AWR_TL.redraw)setTimeout(AWR_TL.redraw,90);
  /* a hash that points into a moved block (e.g. #f-io) opens its row */
  var h=(location.hash||"").slice(1).split("!")[0],el=h&&!/^view=/.test(h)?doc.getElementById(h):null;
  if(el&&el.closest("details.drow")&&window.AWR_goTo)setTimeout(function(){AWR_goTo(el,false,false);},120);
}

doc.addEventListener("DOMContentLoaded",function(){
  doc.body.classList.add("d-"+D);
  try{howToRead();}catch(e){if(window.console)console.warn("design: how-to-read",e);}
  try{toolMenus();}catch(e){if(window.console)console.warn("design: table menus",e);}
  if(D==="dashboard"){try{dashboard();}catch(e){if(window.console)console.warn("design: dashboard",e);}}
});
})();
