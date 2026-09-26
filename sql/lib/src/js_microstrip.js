(function(){
var doc=document;
function num(s){s=String(s==null?"":s).trim();if(s===""||s==="null")return null;var v=+s;return isNaN(v)?null:v;}
/* client twin of sql/lib/fmt_num.plsql: about 4 significant digits, k / M / G */
function grp(n){return String(n).replace(/\B(?=(\d{3})+(?!\d))/g,",");}
function fmt(p){
  if(p==null)return "\u2014";if(p===0)return "0";
  var a=Math.abs(p),s=p<0?"-":"",u="",v=a,t;
  if(a>=1e9){v=a/1e9;u=" G";}else if(a>=1e6){v=a/1e6;u=" M";}else if(a>=1e4){v=a/1e3;u=" k";}
  if(v>=1000)t=grp(Math.round(v));else if(v>=100)t=grp(v.toFixed(1));else if(v>=10)t=v.toFixed(2);else if(v>=1)t=v.toFixed(3);
  else{var d=Math.min(6,3-Math.floor(Math.log10(v)));if(Math.round(v*1e6)===0)return s+"<0.000001";t=String(+v.toFixed(d));}
  return s+t+u;
}
/* the column label of the k-th window, oldest first (window.AWR_WIN from sql/00_params.sql) */
function wlab(k,n){
  var W=window.AWR_WIN;
  if(W&&W.w&&W.w.length===n&&W.w[k])return k===n-1?"Current":W.w[k].d;
  return k===n-1?"Current":"\u2212"+(n-1-k);
}
/* one 13-bar micro strip: every window as a grey bar from zero, Current last,
   wider and in the accent; the prior normal zone (mean +- 2 sigma, sigma
   floored at 2% of the mean like the band) shaded behind the bars */
function strip(raw,title){
  var v=String(raw||"").split(",").map(num), n=v.length;
  var W=92,H=22,gap=n>20?1:2,cw=(W-gap*n)/(n+0.6);
  if(!n||cw<=0)return "";
  var pr=v.slice(0,n-1).filter(function(x){return x!=null;}), mu=null, sd=null, lo=null, hi=null;
  if(pr.length){
    mu=pr.reduce(function(a,b){return a+b;},0)/pr.length;
    sd=pr.length>1?Math.sqrt(pr.reduce(function(a,b){return a+(b-mu)*(b-mu);},0)/(pr.length-1)):0;
    var den=Math.max(sd,Math.abs(mu)*0.02);
    lo=Math.max(0,mu-2*den); hi=mu+2*den;
  }
  var have=v.filter(function(x){return x!=null;}).map(function(x){return Math.max(0,x);});
  var max=Math.max.apply(null,have.concat(hi!=null?[hi]:[0]))||1;
  function Y(x){return H-1-(H-3)*Math.max(0,x)/max;}
  var s="<svg class=\"mw\" width=\""+W+"\" height=\""+H+"\" viewBox=\"0 0 "+W+" "+H+"\" aria-hidden=\"true\">";
  if(hi!=null)s+="<rect class=\"z2\" x=\"0\" y=\""+Y(hi).toFixed(1)+"\" width=\""+W+"\" height=\""+Math.max(1,Y(lo)-Y(hi)).toFixed(1)+"\" rx=\"1\"/>";
  var x=0;
  v.forEach(function(val,k){
    var cur=k===n-1, w=cur?cw*1.6:cw;
    if(val!=null){var y=Y(val);s+="<rect class=\"b"+(cur?" cur":"")+"\" x=\""+x.toFixed(1)+"\" y=\""+y.toFixed(1)+"\" width=\""+w.toFixed(1)+"\" height=\""+Math.max(1,H-1-y).toFixed(1)+"\" rx=\"1\"/>";}
    x+=w+gap;
  });
  s+="</svg>";
  var tip=[];
  for(var k=Math.max(0,n-4);k<n;k++)tip.push(wlab(k,n)+" "+fmt(v[k]));
  return {svg:s,title:(title?title+": ":"")+tip.join(", ")+(mu!=null?"; normal "+fmt(lo)+"\u2013"+fmt(hi):"")};
}
window.AWR_microStrip=strip;
function render(){
  doc.querySelectorAll("[data-spark]").forEach(function(el){
    if(el.__sparked)return;
    var r=strip(el.getAttribute("data-spark"),el.getAttribute("data-spark-title")||"");
    el.__sparked=true;
    if(!r)return;
    el.innerHTML=r.svg; el.title=r.title;
  });
}
if(doc.readyState==="loading")doc.addEventListener("DOMContentLoaded",render);else render();
window.__awrRenderSparks=render;
})();
