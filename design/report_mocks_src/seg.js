const { chromium } = require('playwright');
const path=require('path');
(async()=>{
  const [,,file,prefix,mode,step]=process.argv;
  const b=await chromium.launch({channel:'chrome'});
  const p=await b.newPage({viewport:{width:1440,height:1000}});
  await p.goto('file://'+path.resolve(file),{waitUntil:'load'});
  await p.waitForTimeout(1500);
  if(mode==='full'){const bd=await p.$('#mode-full'); if(bd){await bd.click();await p.waitForTimeout(800);}}
  const H=await p.evaluate(()=>document.documentElement.scrollHeight);
  const st=+step||1000; let i=0;
  for(let y=0;y<H;y+=st){await p.evaluate(y=>window.scrollTo(0,y),y);await p.waitForTimeout(250);await p.screenshot({path:`${prefix}_${String(i).padStart(2,'0')}.png`});i++;}
  console.log('H',H,'segs',i);
  await b.close();
})();
