const { chromium } = require('playwright');
const fs = require('node:fs');
const path = require('node:path');

const SITE = 'https://alex00pirotskyi.github.io/leaf-ranobelib/';
const out = path.join(process.cwd(), 'smoke-artifacts');
fs.mkdirSync(out, {recursive:true});

function assert(value, message) { if(!value) throw new Error(message); }
const sleep = ms => new Promise(r=>setTimeout(r,ms));

async function enableAccessibility(page) {
  await page.waitForTimeout(1800);
  await page.evaluate(() => {
    const x=document.querySelector('flt-semantics-placeholder');
    if(x) x.click();
  });
  await page.waitForTimeout(1000);
}

async function verifyDownload(download, filename) {
  const file = path.join(out, filename);
  await download.saveAs(file);
  const size=fs.statSync(file).size;
  assert(size>500,'Downloaded EPUB is suspiciously small: '+size);
  const fd=fs.openSync(file,'r');
  const head=Buffer.alloc(4);fs.readSync(fd,head,0,4,0);fs.closeSync(fd);
  assert(head[0]===0x50&&head[1]===0x4b,'Not a ZIP/EPUB');
  console.log('VERIFIED',filename,'size',size,'suggested',download.suggestedFilename());
}

(async()=>{
 const browser = await chromium.launch({headless:true,args:['--disable-dev-shm-usage']});
 const context=await browser.newContext({acceptDownloads:true, viewport:{width:1280,height:900}});
 const page=await context.newPage();
 page.on('console',m=>{if(m.type()==='error')console.log('BROWSER:',m.text());});
 page.on('pageerror',err=>console.log('PAGE ERROR:',err.message));
 try {
   console.log('SCENARIO 1: one-click direct Wikisource API to EPUB');
   await page.goto(SITE,{waitUntil:'domcontentloaded',timeout:45000});
   await enableAccessibility(page);
   let startButton=page.getByRole('button',{name:/Collect.*download EPUB/i});
   await startButton.waitFor({timeout:30000});
   const [firstDownload] = await Promise.all([
     page.waitForEvent('download',{timeout:100000}),
     startButton.click(),
   ]);
   await verifyDownload(firstDownload,'wikimedia_demo.epub');
   console.log('SCENARIO 1 PASS');

   console.log('SCENARIO 2: user-activated in-page helper on a public chapter fixture');
   await page.reload({waitUntil:'domcontentloaded'});
   await enableAccessibility(page);
   await page.getByRole('button',{name:/Try test collector pages/i}).click();
   const [popup] = await Promise.all([
     page.waitForEvent('popup',{timeout:20000}),
     page.getByRole('button',{name:/Collect.*download EPUB/i}).click(),
   ]);
   await popup.waitForLoadState('domcontentloaded');
   console.log('Reader tab',popup.url(),'opener?',await popup.evaluate(()=>!!window.opener));
   assert(popup.url()===SITE+'fixtures/chapter-1.html',
     'Wrong tab URL: '+popup.url());
   await page.evaluate(() => {
     window.__leafDebugMessages=[];
     window.addEventListener('message',e=>{
       try { window.__leafDebugMessages.push({
         origin:e.origin,data:String(e.data).slice(0,450)
       }); } catch(_) {}
     });
   });
   popup.on('console',m=>{if(m.type()==='error')console.log('READER CONSOLE',m.text());});
   popup.on('pageerror',err=>console.log('READER PAGE ERROR',err.message));
   const downloadPromise=page.waitForEvent('download',{timeout:35000});
   // Simulate a real user clicking the Leaf Capture bookmark on the fixture.
   await popup.evaluate(() => {
     const s=document.createElement('script');
     s.src='https://alex00pirotskyi.github.io/leaf-ranobelib/leaf-capture.js';
     document.head.appendChild(s);
   });
   await page.waitForTimeout(7000);
   console.log('CAPTURE HELPER STATE',JSON.stringify(await popup.evaluate(()=>{
     const host=document.getElementById('leaf-capture-v2');
     return { loaded:!!window.__leafCaptureV2,
       panel:host?.shadowRoot?.textContent?.slice(0,1300)||'NONE',
       opener:!!window.opener };
   })));
   console.log('LEAF BRIDGE MESSAGES',JSON.stringify(await page.evaluate(
     ()=>window.__leafDebugMessages||[])));
   const secondDownload=await downloadPromise;
   await verifyDownload(secondDownload,'bookmarklet_fixture.epub');
   console.log('SCENARIO 2 PASS');
 }catch(err){
   console.error('SMOKE FAILURE:',err.stack||err);
   try{await page.screenshot({path:path.join(out,'failure.png'),fullPage:true});}catch(_){}
   process.exitCode=1;
 }finally{
   await browser.close();
 }
})();
