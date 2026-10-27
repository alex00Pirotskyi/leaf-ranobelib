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
   const popupUrl = new URL(popup.url());
   assert(popupUrl.origin + popupUrl.pathname === SITE+'fixtures/chapter-1.html',
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

   console.log('SCENARIO 5: iPhone Safari shows actionable setup rather than a fake 0/23 wait');
   const safariContext=await browser.newContext({
     userAgent:'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1',
     viewport:{width:390,height:844},deviceScaleFactor:3,
     isMobile:true,hasTouch:true,
     acceptDownloads:true,
   });
   const iphone=await safariContext.newPage();
   await iphone.goto(SITE,{waitUntil:'domcontentloaded'});
   await enableAccessibility(iphone);
   await iphone.getByRole('button',{name:/Try test collector pages/i}).click();
   await iphone.getByRole('button',{name:/Set up Safari capture/i}).click();
   await iphone.getByText(/iPhone Safari — capture chapters/i).waitFor({timeout:10000});
   assert(await iphone.getByText(/Import JSON to make EPUB/i).isVisible(),
     'Mobile instructions are missing');
   assert((await iphone.getByText(/Waiting for Leaf Capture in source tab/i).count())===0,
     'Mobile Safari must not pretend capture is active');
   assert((await iphone.getByText(/Collecting chapters/i).count())===0,
     'Mobile Safari must not show fictitious collection progress');
   await iphone.screenshot({path:path.join(out,'iphone-safari-setup.png'),fullPage:true});
   await safariContext.close();
   console.log('SCENARIO 5 PASS');

   console.log('SCENARIO 3: standalone bookmarklet without an opener, export JSON');
   const isolated=await context.newPage();
   await isolated.goto(SITE+'fixtures/chapter-1.html',{waitUntil:'domcontentloaded'});
   const plan={
     leaf:2,type:'job',token:'smoke-manual-session',
     start:SITE+'fixtures/chapter-1.html',
     end:SITE+'fixtures/chapter-3.html',
     urls:[1,2,3].map(i=>SITE+'fixtures/chapter-'+i+'.html'),
     max:3,title:'Offline Archive Example',resumeFrom:0,manualMode:true,
   };
   const jsonPromise=isolated.waitForEvent('download',{timeout:45000});
   await isolated.evaluate(() => {
     const s=document.createElement('script');
     s.src='https://alex00pirotskyi.github.io/leaf-ranobelib/leaf-capture.js';
     document.head.appendChild(s);
   });
   await isolated.waitForFunction(
     () => !!document.querySelector('#leaf-capture-v2')?.shadowRoot?.querySelector('textarea'),
     {timeout:15000}
   );
   await isolated.evaluate(plan => {
     const root=document.querySelector('#leaf-capture-v2').shadowRoot;
     const textarea=root.querySelector('textarea');
     textarea.value=JSON.stringify(plan);
     [...root.querySelectorAll('button')].find(b=>b.textContent.includes('Start using pasted plan')).click();
   },plan);
   const jsonDownload=await jsonPromise;
   const jsonFile=path.join(out,'standalone_book.json');
   await jsonDownload.saveAs(jsonFile);
   const book=JSON.parse(fs.readFileSync(jsonFile,'utf8'));
   assert(book.chapters?.length===3,'Standalone collector did not save 3 chapters');
   assert(book.chapters[2].html.includes('Chapter 3 begins'),
     'Standalone collector saved wrong final chapter');
   console.log('SCENARIO 3 PASS JSON with',book.chapters.length,'chapters');

   console.log('SCENARIO 4: import standalone JSON into Leaf, build EPUB locally');
   await page.reload({waitUntil:'domcontentloaded'});
   await enableAccessibility(page);
   // Flutter ChoiceChip uses radio/toggle semantics rather than button.
   await page.getByText('Import files',{exact:true}).first().click();
   const [chooser]=await Promise.all([
     page.waitForEvent('filechooser',{timeout:20000}),
     page.getByRole('button',{name:/Choose files/i}).click(),
   ]);
   await chooser.setFiles(jsonFile);
   const [thirdDownload]=await Promise.all([
     page.waitForEvent('download',{timeout:45000}),
     page.getByRole('button',{name:/Create EPUB/i}).click(),
   ]);
   await verifyDownload(thirdDownload,'standalone_import.epub');
   console.log('SCENARIO 4 PASS');


 }catch(err){
   console.error('SMOKE FAILURE:',err.stack||err);
   try{await page.screenshot({path:path.join(out,'failure.png'),fullPage:true});}catch(_){}
   process.exitCode=1;
 }finally{
   await browser.close();
 }
})();
