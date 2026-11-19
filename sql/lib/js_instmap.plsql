--
-- sql/lib/js_instmap.plsql
--
-- The client script of section 27_instance_map (Instance map).
-- @@-included by sql/27_instance_map.sql, after its markup and payload.
--
-- No literal tilde below (SET DEFINE tilde).  GENERATED: the body below
-- (BEGIN .. END) is written by tools/js2plsql.sh from the readable source
-- sql/lib/src/js_instmap.js -- edit that file and regenerate.
--
BEGIN
    DBMS_OUTPUT.PUT_LINE('<script>');
    DBMS_OUTPUT.PUT_LINE('// js_instmap: client half of section 27_instance_map (Instance map).');
    DBMS_OUTPUT.PUT_LINE('// The map itself is server-drawn SVG; this adds the popover (the area''s');
    DBMS_OUTPUT.PUT_LINE('// flagged metrics as entity links + its finding card), keyboard focus and');
    DBMS_OUTPUT.PUT_LINE('// the jump to the card through AWR_goTo.  JS off: the SVG links still');
    DBMS_OUTPUT.PUT_LINE('// follow their href, the table below holds every number.');
    DBMS_OUTPUT.PUT_LINE('(function(){');
    DBMS_OUTPUT.PUT_LINE('var sec=document.getElementById(''instance-map'');');
    DBMS_OUTPUT.PUT_LINE('if(!sec)return;');
    DBMS_OUTPUT.PUT_LINE('var wrap=sec.querySelector(''.im-wrap''),pop=sec.querySelector(''.im-pop'');');
    DBMS_OUTPUT.PUT_LINE('if(!wrap||!pop)return;');
    DBMS_OUTPUT.PUT_LINE('var cur=null,hideT=0;');
    DBMS_OUTPUT.PUT_LINE('function src(k){return sec.querySelector(''.im-src[data-c="''+k+''"]'');}');
    DBMS_OUTPUT.PUT_LINE('function place(n){');
    DBMS_OUTPUT.PUT_LINE('  var wr=wrap.getBoundingClientRect(),br=n.getBoundingClientRect();');
    DBMS_OUTPUT.PUT_LINE('  var pw=pop.offsetWidth,ph=pop.offsetHeight;');
    DBMS_OUTPUT.PUT_LINE('  var x=br.left-wr.left,y=br.bottom-wr.top+6;');
    DBMS_OUTPUT.PUT_LINE('  if(x+pw>wr.width)x=Math.max(0,wr.width-pw);');
    DBMS_OUTPUT.PUT_LINE('  if(br.bottom+ph+12>window.innerHeight&&br.top-ph-6>0)y=br.top-wr.top-ph-6;');
    DBMS_OUTPUT.PUT_LINE('  pop.style.left=Math.max(0,x)+''px'';pop.style.top=y+''px'';');
    DBMS_OUTPUT.PUT_LINE('}');
    DBMS_OUTPUT.PUT_LINE('function show(n){');
    DBMS_OUTPUT.PUT_LINE('  clearTimeout(hideT);');
    DBMS_OUTPUT.PUT_LINE('  if(cur===n&&!pop.hidden)return;');
    DBMS_OUTPUT.PUT_LINE('  var s=src(n.getAttribute(''data-c''));if(!s)return;');
    DBMS_OUTPUT.PUT_LINE('  if(cur)cur.classList.remove(''on'');');
    DBMS_OUTPUT.PUT_LINE('  cur=n;n.classList.add(''on'');');
    DBMS_OUTPUT.PUT_LINE('  pop.innerHTML=s.innerHTML;pop.hidden=false;place(n);');
    DBMS_OUTPUT.PUT_LINE('}');
    DBMS_OUTPUT.PUT_LINE('function hide(){');
    DBMS_OUTPUT.PUT_LINE('  clearTimeout(hideT);pop.hidden=true;');
    DBMS_OUTPUT.PUT_LINE('  if(cur)cur.classList.remove(''on'');cur=null;');
    DBMS_OUTPUT.PUT_LINE('}');
    DBMS_OUTPUT.PUT_LINE('function later(){clearTimeout(hideT);hideT=setTimeout(hide,250);}');
    DBMS_OUTPUT.PUT_LINE('function card(n){');
    DBMS_OUTPUT.PUT_LINE('  var h=n.getAttribute(''href'');');
    DBMS_OUTPUT.PUT_LINE('  return h?document.getElementById(h.slice(1)):null;');
    DBMS_OUTPUT.PUT_LINE('}');
    DBMS_OUTPUT.PUT_LINE('function go(el){');
    DBMS_OUTPUT.PUT_LINE('  if(window.AWR_goTo){window.AWR_goTo(el,true,true);try{history.replaceState(null,'''',''#''+el.id);}catch(e){}return true;}');
    DBMS_OUTPUT.PUT_LINE('  return false;');
    DBMS_OUTPUT.PUT_LINE('}');
    DBMS_OUTPUT.PUT_LINE('var nodes=sec.querySelectorAll(''.im-n'');');
    DBMS_OUTPUT.PUT_LINE('Array.prototype.forEach.call(nodes,function(n){');
    DBMS_OUTPUT.PUT_LINE('  n.addEventListener(''mouseenter'',function(){show(n);});');
    DBMS_OUTPUT.PUT_LINE('  n.addEventListener(''mouseleave'',later);');
    DBMS_OUTPUT.PUT_LINE('  n.addEventListener(''focus'',function(){show(n);});');
    DBMS_OUTPUT.PUT_LINE('  n.addEventListener(''blur'',function(e){if(!(e.relatedTarget&&pop.contains(e.relatedTarget)))later();});');
    DBMS_OUTPUT.PUT_LINE('  n.addEventListener(''click'',function(e){');
    DBMS_OUTPUT.PUT_LINE('    if(e.button||e.metaKey||e.ctrlKey||e.shiftKey)return;');
    DBMS_OUTPUT.PUT_LINE('    var c=card(n);');
    DBMS_OUTPUT.PUT_LINE('    if(c){e.preventDefault();e.stopPropagation();hide();go(c);return;}');
    DBMS_OUTPUT.PUT_LINE('    if(cur===n&&!pop.hidden)hide();else show(n);');
    DBMS_OUTPUT.PUT_LINE('  });');
    DBMS_OUTPUT.PUT_LINE('  n.addEventListener(''keydown'',function(e){');
    DBMS_OUTPUT.PUT_LINE('    if(n.tagName.toLowerCase()===''a'')return;');
    DBMS_OUTPUT.PUT_LINE('    if(e.key===''Enter''||e.key==='' ''){');
    DBMS_OUTPUT.PUT_LINE('      e.preventDefault();show(n);');
    DBMS_OUTPUT.PUT_LINE('      var f=pop.querySelector(''a'');if(f)f.focus();');
    DBMS_OUTPUT.PUT_LINE('    }');
    DBMS_OUTPUT.PUT_LINE('  });');
    DBMS_OUTPUT.PUT_LINE('});');
    DBMS_OUTPUT.PUT_LINE('pop.addEventListener(''mouseenter'',function(){clearTimeout(hideT);});');
    DBMS_OUTPUT.PUT_LINE('pop.addEventListener(''mouseleave'',later);');
    DBMS_OUTPUT.PUT_LINE('pop.addEventListener(''focusout'',function(e){');
    DBMS_OUTPUT.PUT_LINE('  if(!(e.relatedTarget&&(pop.contains(e.relatedTarget)||e.relatedTarget===cur)))later();');
    DBMS_OUTPUT.PUT_LINE('});');
    DBMS_OUTPUT.PUT_LINE('pop.addEventListener(''click'',function(e){');
    DBMS_OUTPUT.PUT_LINE('  var a=e.target.closest&&e.target.closest(''a.im-go'');');
    DBMS_OUTPUT.PUT_LINE('  if(!a)return;');
    DBMS_OUTPUT.PUT_LINE('  var c=card(a);');
    DBMS_OUTPUT.PUT_LINE('  if(c){e.preventDefault();e.stopPropagation();hide();go(c);}');
    DBMS_OUTPUT.PUT_LINE('});');
    DBMS_OUTPUT.PUT_LINE('document.addEventListener(''keydown'',function(e){');
    DBMS_OUTPUT.PUT_LINE('  if(e.key===''Escape''&&!pop.hidden){');
    DBMS_OUTPUT.PUT_LINE('    var back=cur;hide();if(back&&pop.contains(document.activeElement))back.focus();');
    DBMS_OUTPUT.PUT_LINE('    e.stopPropagation();');
    DBMS_OUTPUT.PUT_LINE('  }');
    DBMS_OUTPUT.PUT_LINE('},true);');
    DBMS_OUTPUT.PUT_LINE('document.addEventListener(''scroll'',function(){if(!pop.hidden&&cur)place(cur);},{passive:true});');
    DBMS_OUTPUT.PUT_LINE('var sc=sec.querySelector(''.im-scroll'');');
    DBMS_OUTPUT.PUT_LINE('if(sc)sc.addEventListener(''scroll'',function(){if(!pop.hidden)hide();},{passive:true});');
    DBMS_OUTPUT.PUT_LINE('window.addEventListener(''resize'',function(){if(!pop.hidden)hide();});');
    DBMS_OUTPUT.PUT_LINE('document.addEventListener(''awr:view'',hide);');
    DBMS_OUTPUT.PUT_LINE('})();');
    DBMS_OUTPUT.PUT_LINE('</script>');
END;
/
