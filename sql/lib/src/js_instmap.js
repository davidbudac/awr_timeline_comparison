// js_instmap: client half of section 27_instance_map (Instance map).
// The map itself is server-drawn SVG; this adds the popover (the area's
// flagged metrics as entity links + its finding card), keyboard focus and
// the jump to the card through AWR_goTo.  JS off: the SVG links still
// follow their href, the table below holds every number.
(function(){
var sec=document.getElementById('instance-map');
if(!sec)return;
var wrap=sec.querySelector('.im-wrap'),pop=sec.querySelector('.im-pop');
if(!wrap||!pop)return;
var cur=null,hideT=0;
function src(k){return sec.querySelector('.im-src[data-c="'+k+'"]');}
function place(n){
  var wr=wrap.getBoundingClientRect(),br=n.getBoundingClientRect();
  var pw=pop.offsetWidth,ph=pop.offsetHeight;
  var x=br.left-wr.left,y=br.bottom-wr.top+6;
  if(x+pw>wr.width)x=Math.max(0,wr.width-pw);
  if(br.bottom+ph+12>window.innerHeight&&br.top-ph-6>0)y=br.top-wr.top-ph-6;
  pop.style.left=Math.max(0,x)+'px';pop.style.top=y+'px';
}
function show(n){
  clearTimeout(hideT);
  if(cur===n&&!pop.hidden)return;
  var s=src(n.getAttribute('data-c'));if(!s)return;
  if(cur)cur.classList.remove('on');
  cur=n;n.classList.add('on');
  pop.innerHTML=s.innerHTML;pop.hidden=false;place(n);
}
function hide(){
  clearTimeout(hideT);pop.hidden=true;
  if(cur)cur.classList.remove('on');cur=null;
}
function later(){clearTimeout(hideT);hideT=setTimeout(hide,250);}
function card(n){
  var h=n.getAttribute('href');
  return h?document.getElementById(h.slice(1)):null;
}
function go(el){
  if(window.AWR_goTo){window.AWR_goTo(el,true,true);try{history.replaceState(null,'','#'+el.id);}catch(e){}return true;}
  return false;
}
var nodes=sec.querySelectorAll('.im-n');
Array.prototype.forEach.call(nodes,function(n){
  n.addEventListener('mouseenter',function(){show(n);});
  n.addEventListener('mouseleave',later);
  n.addEventListener('focus',function(){show(n);});
  n.addEventListener('blur',function(e){if(!(e.relatedTarget&&pop.contains(e.relatedTarget)))later();});
  n.addEventListener('click',function(e){
    if(e.button||e.metaKey||e.ctrlKey||e.shiftKey)return;
    var c=card(n);
    if(c){e.preventDefault();e.stopPropagation();hide();go(c);return;}
    if(cur===n&&!pop.hidden)hide();else show(n);
  });
  n.addEventListener('keydown',function(e){
    if(n.tagName.toLowerCase()==='a')return;
    if(e.key==='Enter'||e.key===' '){
      e.preventDefault();show(n);
      var f=pop.querySelector('a');if(f)f.focus();
    }
  });
});
pop.addEventListener('mouseenter',function(){clearTimeout(hideT);});
pop.addEventListener('mouseleave',later);
pop.addEventListener('focusout',function(e){
  if(!(e.relatedTarget&&(pop.contains(e.relatedTarget)||e.relatedTarget===cur)))later();
});
pop.addEventListener('click',function(e){
  var a=e.target.closest&&e.target.closest('a.im-go');
  if(!a)return;
  var c=card(a);
  if(c){e.preventDefault();e.stopPropagation();hide();go(c);}
});
document.addEventListener('keydown',function(e){
  if(e.key==='Escape'&&!pop.hidden){
    var back=cur;hide();if(back&&pop.contains(document.activeElement))back.focus();
    e.stopPropagation();
  }
},true);
document.addEventListener('scroll',function(){if(!pop.hidden&&cur)place(cur);},{passive:true});
var sc=sec.querySelector('.im-scroll');
if(sc)sc.addEventListener('scroll',function(){if(!pop.hidden)hide();},{passive:true});
window.addEventListener('resize',function(){if(!pop.hidden)hide();});
document.addEventListener('awr:view',hide);
})();
