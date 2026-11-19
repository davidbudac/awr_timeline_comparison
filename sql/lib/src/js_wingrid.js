(function(){
var W=window.AWR_WG={}, doc=document;
if(doc.body)doc.body.classList.add("js-wg");
function $$(s,r){return Array.prototype.slice.call((r||doc).querySelectorAll(s));}
function shown(el){return !!el&&el.getClientRects().length>0;}
function mk(t,c,p){var e=doc.createElement(t);if(c)e.className=c;if(p)p.appendChild(e);return e;}
function cssNum(el,n,d){var v=parseFloat(getComputedStyle(el).getPropertyValue(n));return isNaN(v)?d:v;}
function num(s){if(s==null||s==="")return null;var v=+s;return isNaN(v)?null:v;}
function nums(s){return String(s||"").split(",").map(num);}
var MON=["Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"],DOW=["Sun","Mon","Tue","Wed","Thu","Fri","Sat"];
function dayTxt(t){var d=new Date(String(t).replace(" ","T"));if(isNaN(d.getTime()))return String(t);return DOW[d.getDay()]+" "+d.getDate()+" "+MON[d.getMonth()];}
/* a short flag label: "Release 4.2" -> "R 4.2", "RU 19.28 patch" -> "RU 19.28" */
function shortLbl(l){var w=String(l).split(/\s+/),d=w.filter(function(x){return /\d/.test(x);});
  if(!d.length)return l.length>10?l.slice(0,9)+"\u2026":l;
  if(/\d/.test(w[0]))return d.join(" ");
  return (w[0].length<=3&&w[0]===w[0].toUpperCase()?w[0]:w[0].charAt(0).toUpperCase())+" "+d.join(" ");}
/* markers on window boundaries: a marker that falls after the start of one
   compared window and before the start of the next sits on the left edge
   of the later one (o = its week_offset); inside Current -> on Current */
var MK=null;
W.markers=function(){
  if(MK)return MK;MK=[];
  var win=window.AWR_WIN,ms=window.AWR_MARKERS||[];if(!win||!win.w||win.w.length<2)return MK;
  var w=win.w,n=w.length;
  ms.forEach(function(m){
    var t=String(m.t||""),lab=String(m.label||"");if(!t||t<=w[0].s||t>w[n-1].e)return;
    var i=1;while(i<n-1&&t>w[i].s)i++;
    MK.push({o:w[i].o,after:w[i-1].o,l:lab,s:shortLbl(lab),t:dayTxt(t),at:t});
  });
  return MK;
};
W.markerAt=function(o){var r=null;W.markers().forEach(function(m){if(m.o===o)r=m;});return r;};
/* ---- pattern tags (plan 027): the shape of one row's 13 values, as a
   hint.  Pure: vals oldest first (null = no value), valid[i] false = a
   skipped window, mu / sd = the row's prior mean / sd (data-mu / data-sd),
   marks = [{i: column index whose LEFT edge carries a marker, l: label}].
   At most two tags, the Current one first:
     {k:"jump"|"spike", dir, m}  only Current is outside mean +- 2 floored
         sigma ("jump" when a marker sits on Current's left edge, m = label)
     {k:"run", dir, n}  Current and the n-1 windows right before it are all
         outside on the same side (a skipped window ends the run)
     {k:"step", dir, at, m}  the prior windows from index at on sit apart
         from the ones before (m = the marker on that edge, else null)
     {k:"trend", dir, n}  the n prior windows follow a line better than a step
   dir = 1 up, -1 down.  Thresholds in W.PAT.  Tags never change a
   severity, an order or a count. */
W.PAT={MIN_PRIOR:4,STEP_L:3,STEP_R:2,STEP_PAIR:0.9,STEP_REL:0.10,STEP_SEP:2,TREND_MIN:6,TREND_R2:0.6,TREND_REL:0.10};
function avg(a){var s=0;for(var i=0;i<a.length;i++)s+=a[i];return s/a.length;}
function sdev(a){if(a.length<2)return 0;var m=avg(a),s=0;for(var i=0;i<a.length;i++)s+=(a[i]-m)*(a[i]-m);return Math.sqrt(s/(a.length-1));}
function sqs(a){var m=avg(a),s=0;for(var i=0;i<a.length;i++)s+=(a[i]-m)*(a[i]-m);return s;}
W.patterns=function(vals,valid,mu,sd,marks){
  var P=W.PAT,n=vals.length,c=vals[n-1],out=[],pi=[],i;
  if(c==null||mu==null||n<2)return out;
  for(i=0;i<n-1;i++)if(vals[i]!=null&&valid[i]!==false)pi.push(i);
  if(pi.length<P.MIN_PRIOR)return out;
  var mkAt=function(x){for(var k=0;k<(marks||[]).length;k++)if(marks[k].i===x)return marks[k].l;return null;};
  var den=Math.max(sd||0,0.02*Math.abs(mu)),hi=mu+2*den,lo=mu-2*den,dir=c>hi?1:c<lo?-1:0;
  if(dir){
    var run=0;
    for(i=n-2;i>=0;i--){var v=vals[i];if(v==null||valid[i]===false)break;if((dir>0&&v>hi)||(dir<0&&v<lo))run++;else break;}
    if(run>=1)out.push({k:"run",dir:dir,n:run+1});
    else{var lm=mkAt(n-1);out.push({k:lm?"jump":"spike",dir:dir,m:lm});}
  }
  var best=null,s;
  for(s=1;s<n-1;s++){
    var L=[],R=[];pi.forEach(function(x){(x<s?L:R).push(vals[x]);});
    if(L.length<P.STEP_L||R.length<P.STEP_R)continue;
    var mL=avg(L),mR=avg(R);if(mL===0)continue;
    var d=mR>mL?1:-1,pairs=0;
    R.forEach(function(r){L.forEach(function(l){if(d>0?r>l:r<l)pairs++;});});
    var gap=Math.abs(mR-mL),fl=Math.max(sdev(L),sdev(R),0.02*Math.abs(mL)),sc=gap/fl;
    if(pairs/(L.length*R.length)<P.STEP_PAIR||gap/Math.abs(mL)<P.STEP_REL||gap<=P.STEP_SEP*fl)continue;
    if(!best||sc>best.sc||(sc===best.sc&&s>best.at))best={dir:d,at:s,m:mkAt(s),sc:sc,rss:sqs(L)+sqs(R)};
  }
  var tr=null;
  if(pi.length>=P.TREND_MIN){
    var ys=pi.map(function(x){return vals[x];}),mx=avg(pi),my=avg(ys),sxx=0,sxy=0,syy=0;
    pi.forEach(function(x,k){sxx+=(x-mx)*(x-mx);sxy+=(x-mx)*(ys[k]-my);syy+=(ys[k]-my)*(ys[k]-my);});
    if(sxx>0&&syy>0&&my!==0){
      var b=sxy/sxx,r2=sxy*sxy/(sxx*syy),rss=syy-sxy*sxy/sxx,rise=Math.abs(b*(pi[pi.length-1]-pi[0]));
      if(r2>=P.TREND_R2&&rise>=P.TREND_REL*Math.abs(my))tr={dir:b>0?1:-1,n:pi.length,rss:rss};
    }
  }
  if(tr&&(!best||tr.rss<=best.rss))out.push({k:"trend",dir:tr.dir,n:tr.n});
  else if(best)out.push({k:"step",dir:best.dir,at:best.at,m:best.m});
  return out;
};
/* a tag's words: text (on the chip) and title (the hover) */
W.patternText=function(t,dates){
  var up=t.dir>0,dt=function(i){return (dates&&dates[i])||"?";},lab=function(l){l=String(l);return l.length>24?l.slice(0,23)+"...":l;};
  if(t.k==="jump")return {text:(up?"jump":"drop")+" after "+lab(t.m),title:"Only the Current window is outside the normal range of the prior windows; the marker "+t.m+" sits right before it."};
  if(t.k==="spike")return {text:(up?"spike":"dip")+": Current only",title:"Only the Current window is outside the normal range of the prior windows."};
  if(t.k==="run")return {text:(up?"high":"low")+" for "+t.n+" windows",title:"The Current window and the "+(t.n-1)+" before it are all "+(up?"above":"below")+" the normal range."};
  if(t.k==="step")return {text:"step "+(up?"up":"down")+(t.m?" at "+lab(t.m):" on "+dt(t.at)),title:"The prior windows from "+dt(t.at)+" on sit "+(up?"above":"below")+" the ones before"+(t.m?" (marker "+t.m+")":"")+": the normal range mixes two levels."};
  return {text:(up?"rising":"falling")+" across "+t.n+" windows",title:"The prior windows follow a steady "+(up?"rise":"fall")+": the normal range is a moving target."};
};
function esc(s){return String(s==null?"":s).replace(/[&<>"]/g,function(c){return {"&":"&amp;","<":"&lt;",">":"&gt;","\"":"&quot;"}[c];});}
/* the compared windows as column indices: validity, dates, marker columns */
function winIdx(){
  var w=(window.AWR_WIN&&window.AWR_WIN.w)||[],valid=[],dates=[],ix={};
  w.forEach(function(x,i){valid.push(x.v!=="N");dates.push(x.d);ix[x.o]=i;});
  var marks=W.markers().map(function(m){return {i:ix[m.o],l:m.l};}).filter(function(m){return m.i!=null;});
  return {valid:valid,dates:dates,marks:marks};
}
/* every finding card (07) gets its tags in its header; plan 025's triage
   row for the card gets the same chips */
function tagCards(){
  var X=winIdx();if(!X.valid.length)return;
  $$("#findings article.fc:not(.chg)").forEach(function(card){
    var row=card.querySelector(".fc-main .wg .r[data-v]");if(!row)return;
    var vals=nums(row.getAttribute("data-v"));if(vals.length!==X.valid.length)return;
    var a=function(n){var v=row.getAttribute(n+"0");return num(v!=null?v:row.getAttribute(n));};
    var tags=W.patterns(vals,X.valid,a("data-mu"),a("data-sd"),X.marks);if(!tags.length)return;
    var html=tags.map(function(t){var p=W.patternText(t,X.dates);
      return '<span class="ptag p-'+t.k+(t.m?' p-rel':'')+'" title="'+esc(p.title)+'">'+esc(p.text)+'</span>';}).join("");
    var box=card.querySelector(".fc-tags");
    if(!box){var k=card.querySelector(".fc-h .fc-k");if(!k)return;box=mk("span","fc-tags",k);}
    box.innerHTML=html;
    $$('#triage .tri-row[data-card="'+card.id+'"] .tri-tags').forEach(function(t){t.innerHTML=html;});
  });
}
/* one bars row: grey prior columns, the Current one in the accent, the
   prior normal zone (mean +- 1 / 2 floored sigma; in the Timeline grid
   #tl only behind the Current bar) and a severity dot */
function sizeRow(row){
  var cells=$$(":scope > .c",row);if(!cells.length)return;
  var vals=nums(row.getAttribute("data-v")),mu=num(row.getAttribute("data-mu")),sd=num(row.getAttribute("data-sd")),sev=row.getAttribute("data-sev")||"";
  var z=null;if(mu!=null){var d=Math.max(sd||0,0.02*Math.abs(mu));z=[Math.max(0,mu-2*d),mu+2*d,Math.max(0,mu-d),mu+d,mu];}
  var have=vals.filter(function(v){return v!=null;}),max=Math.max.apply(null,have.concat(z?[z[1]]:[]).concat([0]));if(!(max>0))max=1;
  var bh=cssNum(row,"--bh",24),bb=cssNum(row,"--bb",4),bare=!!row.closest(".wg.bare"),tl=!!row.closest("#tl");
  var y=function(v){return Math.max(0,v)/max*bh;};
  cells.forEach(function(c,k){
    $$(":scope > i",c).forEach(function(x){c.removeChild(x);});
    if(z&&(!tl||c.classList.contains("cur"))){var z2=mk("i","z2",c);z2.style.bottom=(bb+y(z[0]))+"px";z2.style.height=Math.max(1,y(z[1])-y(z[0]))+"px";
      var z1=mk("i","z1",c);z1.style.bottom=(bb+y(z[2]))+"px";z1.style.height=Math.max(1,y(z[3])-y(z[2]))+"px";
      var mn=mk("i","mn",c);mn.style.bottom=(bb+y(z[4]))+"px";}
    if(bare)mk("i","base",c);
    var v=vals[k];if(v==null)return;
    var h=Math.max(1.5,y(v)),b=mk("i","b",c);b.style.height=h+"px";
    if(c.classList.contains("cur")&&(sev==="large"||sev==="moderate")){var s=mk("i","sd s-"+sev,c);s.style.bottom=(bb+h)+"px";}
  });
}
W.sizeRow=sizeRow;
function markCols(wg){
  W.markers().forEach(function(m){$$('.c[data-w="'+m.o+'"],.h[data-w="'+m.o+'"]',wg).forEach(function(c){c.classList.add("mk");});});
}
/* release flags on the column boundaries: full label, else the short one,
   in two tiers, left- or right-anchored, never overlapping.  ".qf" (quiet
   flags, the card charts): only the marker on the Current window's left
   edge is labelled; the others keep their column line (markCols). */
function layoutFlags(wg){
  var quiet=wg.classList.contains("qf");
  $$(".flags",wg).forEach(function(fl){
    if(!shown(fl))return;fl.innerHTML="";
    var base=fl.getBoundingClientRect().left,width=fl.clientWidth,TH=17,tiers=[[],[]],narrow=width<520;
    W.markers().forEach(function(m){
      if(quiet&&m.o!==0)return;
      var ref=$$('[data-w="'+m.o+'"]',wg).filter(function(e){return !e.closest(".flags");})[0];if(!ref)return;
      var x=ref.getBoundingClientRect().left-base,labels=narrow?[m.s]:[m.l,m.s],cands=[];
      labels.forEach(function(l){cands.push([l,0]);});labels.forEach(function(l){cands.push([l,1]);});
      cands.some(function(cd){
        for(var t=0;t<tiers.length;t++){
          var f=mk("div","flag",fl);f.textContent=cd[0];f.style.left=x+"px";f.style.top=(2+t*TH)+"px";f.title=m.l+", "+m.t;
          var w=f.offsetWidth,x0=x-2,x1=x+w+6;
          if(cd[1]){f.classList.add("end");f.style.left=(x-w)+"px";x0=x-w-6;x1=x+2;}
          var clash=tiers[t].some(function(r){return x0<r[1]&&x1>r[0];})||x1>width+1||x0<-1;
          if(!clash){tiers[t].push([x0,x1]);var p=mk("i","pole",fl);p.style.left=(x-0.75)+"px";p.style.top=(2+t*TH)+"px";return true;}
          fl.removeChild(f);
        }
        return false;
      });
    });
  });
}
function fit(wg){
  if(!shown(wg))return;
  var c=wg.querySelector('.r:not(.fr) > .c:not(.cur),.rin > .h:not(.cur),.dr > .h:not(.cur)');
  if(c)wg.classList.toggle("tight",c.getBoundingClientRect().width<42);
  layoutFlags(wg);
}
W.fit=fit;
W.render=function(scope){
  var s=scope||doc;
  $$(".wg .r.bars",s).forEach(sizeRow);
  $$("[data-wg]",s).forEach(function(wg){markCols(wg);fit(wg);});
  if(s.matches&&s.matches("[data-wg]")){markCols(s);fit(s);}
};
function refit(){$$("[data-wg]").forEach(fit);}
W.refit=refit;
/* marker text slots: <span data-mk-at="o" [data-mk-pre=" after "] [data-mk-icon]> */
function fillMk(){
  $$("[data-mk-at]").forEach(function(el){
    var m=W.markerAt(+el.getAttribute("data-mk-at"));if(!m)return;
    el.innerHTML="";
    if(el.hasAttribute("data-mk-icon"))mk("i","kf",el);
    el.appendChild(doc.createTextNode((el.getAttribute("data-mk-pre")||"")+m.l+(el.hasAttribute("data-mk-icon")?"":" ("+m.t+")")));
    el.title=m.l+", "+m.t;el.hidden=false;
  });
}
/* entity links whose row was never emitted become plain text */
function unwrap(){
  $$("a.ent").forEach(function(a){
    var id=(a.getAttribute("href")||"").slice(1).split("!")[0];
    if(id&&doc.getElementById(id))return;
    var s=mk("span","ent-x");while(a.firstChild)s.appendChild(a.firstChild);a.parentNode.replaceChild(s,a);
  });
}
/* hover a column: every cell of that window lights up, its value shows */
var hovWg=null,hovW=null;
function hover(wg,w){
  if(hovWg&&(hovWg!==wg||hovW!==w))$$(".hc",hovWg).forEach(function(x){x.classList.remove("hc");});
  hovWg=wg;hovW=w;
  if(wg&&w!=null)$$('.c[data-w="'+w+'"],.h[data-w="'+w+'"]',wg).forEach(function(x){if(!x.closest(".flags"))x.classList.add("hc");});
}
doc.addEventListener("mouseover",function(ev){
  var t=ev.target&&ev.target.closest?ev.target.closest(".wg.hov [data-w]"):null;
  if(!t){if(hovWg)hover(null,null);return;}
  hover(t.closest(".wg"),t.getAttribute("data-w"));
});
/* "Timeline ->": the row that phase 3 emits (data-tl) wins over #timeline */
doc.addEventListener("click",function(ev){
  var a=ev.target&&ev.target.closest?ev.target.closest("a.jump[data-tl]"):null;if(!a||ev.button||ev.metaKey||ev.ctrlKey||ev.shiftKey)return;
  var el=doc.getElementById(a.getAttribute("data-tl"));
  if(el&&window.AWR_goTo){ev.preventDefault();window.AWR_goTo(el,true,true);}
});
var rt=null;
window.addEventListener("resize",function(){if(rt)clearTimeout(rt);rt=setTimeout(refit,120);});
doc.addEventListener("awr:view",function(){setTimeout(refit,40);});
doc.addEventListener("toggle",function(ev){var t=ev.target;if(t&&t.querySelector&&t.querySelector("[data-wg]"))setTimeout(function(){W.render(t);},20);},true);
doc.addEventListener("DOMContentLoaded",function(){unwrap();fillMk();W.render(doc);tagCards();setTimeout(refit,300);});
})();
