const { chromium } = require('playwright');
const path=require('path');
(async()=>{
  const [,,file,out,w,h,mode,full]=process.argv;
  const b=await chromium.launch({channel:'chrome'}).catch(e=>{console.error(e.message);process.exit(1)});
  const p=await b.newPage({viewport:{width:+w||1440,height:+h||1000}});
  const errs=[];p.on('pageerror',e=>errs.push(e.message));p.on('console',m=>{if(m.type()==='error')errs.push(m.text())});
  await p.goto('file://'+path.resolve(file),{waitUntil:'load'});
  await p.waitForTimeout(1500);
  if(mode==='full'){const bd=await p.$('#mode-full'); if(bd){await bd.click();await p.waitForTimeout(800);}}
  if(mode==='dark'){await p.evaluate(()=>document.body.classList.add('dark'));await p.waitForTimeout(500);}
  await p.screenshot({path:out,fullPage:full==='1'});
  const H=await p.evaluate(()=>document.documentElement.scrollHeight);
  console.log('height',H,'errors',errs.length,errs.slice(0,3).join(' | '));
  await b.close();
})();
