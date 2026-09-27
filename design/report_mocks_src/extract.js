const { chromium } = require('playwright');
(async()=>{
  const b=await chromium.launch({channel:'chrome'});
  const p=await b.newPage({viewport:{width:1440,height:1000}});
  await p.goto('file:///Users/davidbudac/claude_projects/awr_timeline_comparison/docs/examples/demo_busy_db.html');
  await p.waitForTimeout(1200);
  await (await p.$('#mode-full')).click(); await p.waitForTimeout(600);
  const out=await p.evaluate(()=>{
    const T=s=>(s||'').replace(/\s+/g,' ').trim();
    let o='';
    const hdr=document.querySelector('header.report, header');
    o+='## MASTHEAD\n'+T(hdr&&hdr.innerText).slice(0,4000)+'\n\n';
    o+='MARKERS: '+JSON.stringify(window.AWR_MARKERS||[])+'\n\n';
    for(const s of document.querySelectorAll('main > section')){
      const h=s.querySelector('h2,h1'); o+='## SECTION #'+s.id+' — '+T(h&&h.innerText)+'\n';
      const cap=s.querySelector('.cap,.sub,p'); 
      s.querySelectorAll('table').forEach((t,ti)=>{
        const rows=[...t.querySelectorAll('tr')].slice(0,26);
        o+='### table '+ti+(t.id?(' #'+t.id):'')+' ('+t.querySelectorAll('tbody tr').length+' rows)\n';
        rows.forEach(r=>{const cells=[...r.children].map(c=>T(c.innerText||c.textContent)||T(c.textContent).slice(0,90)); const sp=r.querySelector('[data-spark]'); o+=cells.join(' | ')+(sp?('  {spark:'+sp.getAttribute('data-spark').slice(0,200)+'}'):'')+'\n';});
      });
      // cards / non-table text
      if(!s.querySelector('table')) o+=T(s.innerText).slice(0,2500)+'\n';
      o+='\n';
    }
    return o;
  });
  require('fs').writeFileSync('demo_data_dump.txt',out);
  console.log(out.length);
  await b.close();
})();
