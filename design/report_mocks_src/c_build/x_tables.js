const { chromium } = require('playwright');
(async()=>{
  const b=await chromium.launch({channel:'chrome'});
  const p=await b.newPage();
  await p.goto('file:///Users/davidbudac/claude_projects/awr_timeline_comparison/docs/examples/demo_busy_db.html');
  await p.waitForTimeout(1000);
  const ids=['load-profile','findings-load','findings-metric','findings-wait','sysmetric','waits-fg-time','waits-fg-class','segio-detail-PREADS','fileio-detail-READMB','topsql-detail-ELAPSED','param-changes-table','windows-table'];
  const out=await p.evaluate((ids)=>{
    const T=s=>(s||'').replace(/\s+/g,' ').trim();
    const o={};
    for(const id of ids){
      const t=document.getElementById(id); if(!t){o[id]=null;continue;}
      const rows=[...t.querySelectorAll(':scope > tbody > tr, :scope > thead > tr, :scope > tr')];
      o[id]=rows.map(r=>({cells:[...r.children].map(c=>T(c.textContent)), spark:(r.querySelector('[data-spark]')||{dataset:{}}).dataset.spark||null}));
    }
    return o;
  },ids);
  require('fs').writeFileSync('c_build/tables.json',JSON.stringify(out,null,1));
  for(const k in out) console.log(k, out[k]?out[k].length:null);
  await b.close();
})();
