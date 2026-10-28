/* Leaf chapter collector v2. Run ONLY by a user-clicked bookmarklet on
   a chapter page the user is permitted to read. No login/CAPTCHA bypass. */
(() => {
  'use strict';
  if (window.top !== window) return;
  if (window.__leafCaptureV2) {
    window.__leafCaptureV2.resume();
    return;
  }

  const LEAF_ORIGIN = 'https://alex00pirotskyi.github.io';
  const sessionToken=(new URLSearchParams(location.hash.slice(1))).get('leaf_session') || '';
  const offlineJob=window.__leafOfflineJobV2 || null;
  const MAX = 120;
  const MIN_TEXT = 150;
  const PACE_MS = 1200;
  const MAX_HTML = 600000;
  const WAIT_RENDER_MS = 12000;
  let job = null, stopped = false, busy = false, picker = false, selector = '';
  let index = 0, currentUrl = location.href, captured = [], completed = false;
  let visited = new Set(), contentSignatures = new Set();
  const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
  const same = url => {
    try { const u = new URL(url, location.href); return u.protocol === 'https:' && u.origin === location.origin; }
    catch (_) { return false; }
  };
  const normalize = url => {
    const u = new URL(url, location.href); u.hash = ''; return u.href;
  };
  const send = obj => {
    try {
      if (window.opener) window.opener.postMessage(JSON.stringify({leaf:2,...obj}), LEAF_ORIGIN);
    } catch (_) {}
  };

  const host = document.createElement('div');
  host.id = 'leaf-capture-v2';
  host.style.cssText = 'position:fixed!important;bottom:20px!important;right:20px!important;z-index:2147483646!important;width:315px!important;max-width:calc(100vw - 40px)!important;font:13px/1.5 Arial,sans-serif!important;';
  const shadow = host.attachShadow({mode:'open'});
  const panel = document.createElement('div');
  panel.style.cssText = 'background:#faf9f4;color:#28362e;border:1px solid #bdc6b8;border-radius:14px;padding:17px;box-shadow:0 10px 44px #0005';
  const titleEl = document.createElement('div');
  titleEl.textContent = 'leaf.  chapter collector';
  titleEl.style.cssText = 'font-weight:bold;font-size:16px;margin-bottom:7px';
  const msg = document.createElement('div');
  msg.style.cssText = 'min-height:34px;margin:8px 0 13px;color:#4b604d;white-space:pre-wrap;overflow-wrap:anywhere';
  msg.textContent = 'Contacting Leaf…';
  const controls = document.createElement('div');
  controls.style.cssText = 'display:flex;gap:6px;flex-wrap:wrap';
  function button(label, cb) {
    const b = document.createElement('button');
    b.type='button'; b.textContent=label;
    b.style.cssText='border:1px solid #9fae9f;background:#e5ede4;border-radius:7px;padding:8px 10px;cursor:pointer;color:#28362e;font-size:12px';
    b.addEventListener('click', cb); controls.appendChild(b); return b;
  }
  const pauseBtn = button('Pause', () => {stopped=true; status('Paused after ' + index + ' chapters.');});
  const resumeBtn = button('Resume', () => {stopped=false; if(job&&!busy) void run();});
  const pickBtn = button('Pick text area', () => {
    picker=true; status('Click the main chapter text on this page.');
  });
  button('Export JSON', downloadJson);
  button('Close', () => {
    stopped = true; host.remove(); window.__leafCaptureV2=null;
  });

  // Fallback for COOP-isolated tabs, mobile Safari and browsers that do not
  // preserve window.opener. Users paste a plan explicitly copied from Leaf.
  const pasteZone = document.createElement('div');
  pasteZone.style.cssText = 'margin-top:12px;border-top:1px solid #b8c9b7;padding-top:10px';
  const pasteLabel = document.createElement('div');
  pasteLabel.textContent = 'No connection to Leaf? Paste a capture plan:';
  pasteLabel.style.cssText = 'font-size:11px;margin-bottom:6px;color:#536455';
  const planInput = document.createElement('textarea');
  planInput.rows = 3;
  planInput.placeholder = 'Paste the plan copied from Leaf…';
  planInput.style.cssText = 'display:block;width:100%;box-sizing:border-box;font:11px/1.4 monospace;border:1px solid #a7b9a9;background:white;color:#28362e;border-radius:6px;padding:5px;';
  const pasteButton = document.createElement('button');
  pasteButton.textContent = 'Start using pasted plan';
  pasteButton.style.cssText = 'margin-top:7px;padding:7px 10px;background:#e0ebde;color:#27392f;border:1px solid #8ba991;border-radius:6px;cursor:pointer;font:12px Arial,sans-serif';
  pasteButton.addEventListener('click', () => {
    try {
      const data = JSON.parse(planInput.value);
      if (data?.leaf !== 2 || data.type !== 'job' || data.manualMode !== true) {
        throw Error('Not a Leaf capture plan.');
      }
      if (!Array.isArray(data.urls) || data.urls.length > MAX) {
        throw Error('Invalid chapter range.');
      }
      acceptJob(data);
    } catch (error) {
      status('Could not use the pasted plan: ' + (error.message || error));
    }
  });
  pasteZone.append(pasteLabel, planInput, pasteButton);

  panel.append(titleEl,msg,controls,pasteZone);
  shadow.appendChild(panel);
  (document.body||document.documentElement).appendChild(host);
  const status = text => {msg.textContent=String(text); send({type:'status',token:job?.token||sessionToken,note:String(text),index});};

  function text(node) {
    return (node?.innerText || node?.textContent || '').replace(/\s+/g,' ').trim();
  }
  function visible(node) {
    if (!node || node.hasAttribute?.('hidden') ||
        node.getAttribute?.('aria-hidden') === 'true' ||
        node.hasAttribute?.('inert')) return false;
    // DOMParser creates a detached document. Requiring isConnected here
    // previously discarded every static chapter candidate.
    const view = node.ownerDocument?.defaultView;
    if (!view || !node.isConnected) return true;
    try {
      const style = view.getComputedStyle(node);
      if (style.display === 'none' || style.visibility === 'hidden' ||
          style.opacity === '0') return false;
    } catch (_) {}
    return true;
  }

  // Reader-first scoring: the longest element on a page is often the whole
  // application shell. Prefer actual paragraphs inside a chapter container.
  // Keep this code self-contained so the bookmarklet works without a server.
  function selectContent(doc) {
    if (!doc?.body) return null;
    const known = [
      ['[data-reader-content] .text-content', 450],
      ['main[data-reader-content] .text-content', 450],
      ['[data-reader-content] [class*="chapter"]', 390],
      ['[data-testid="chapter-content"]', 390],
      ['#chapter-content', 390],
      ['.chapter__content', 380],
      ['.chapter-content', 380],
      ['.chapter-body', 360],
      ['.reader__content', 360],
      ['.reader-content', 350],
      ['.reading-content', 340],
      ['.text-content', 310],
      ['[data-reader-content]', 275],
      ['.mw-parser-output', 260],
      ['article [class*="content"]', 245],
      ['article', 185],
      ['[role="article"]', 180],
      ['.prose', 170],
      ['main', 25],
      ['body', -140],
    ];
    const nodes = new Map();
    const add = (node, priority, picked = false) => {
      if (!node || typeof node.cloneNode !== 'function') return;
      const previous = nodes.get(node);
      if (!previous || previous.priority < priority) {
        nodes.set(node, {node, priority, picked});
      }
    };
    if (selector) {
      try {
        for (const node of doc.querySelectorAll(selector)) add(node, 900, true);
      } catch (_) {}
    }
    for (const [query, priority] of known) {
      try {
        for (const node of doc.querySelectorAll(query)) {
          add(node, priority);
          if (nodes.size >= 170) break;
        }
      } catch (_) {}
      if (nodes.size >= 170) break;
    }
    // A browser may provide a minimal body with bare paragraph children.
    add(doc.body, -140);
    const noise = [
      'script','style','noscript','template','svg','canvas','video','audio',
      'iframe','object','embed','form','button','input','select','textarea',
      'nav','header','footer','aside','dialog',
      '[hidden]','[inert]','[aria-hidden="true"]','[role="navigation"]',
      '[role="toolbar"]','[role="dialog"]',
      '#leaf-capture-v2','.comments','.comment-list','.advertisement','.ads',
      '.navbox','.sidebar','.breadcrumbs','.breadcrumb','.pagination',
      '.reader-settings','.chapter-navigation','.chapter-pagination',
      '.chapter-controls','.reader-controls','.reader-toolbar',
      '.recommendations','.related-books',
      '[class*="comment-section"]','[class*="share-buttons"]',
      '[class*="advertisement"]','[class*="chapter-list"]',
      '[class*="sidebar"]','[class*="pagination"]',
    ].join(',');
    let best = null, bestScore = -Infinity;
    for (const {node, priority, picked} of nodes.values()) {
      if (!visible(node) || node.closest?.('#leaf-capture-v2')) continue;
      // A navigation or menu container is not a chapter even if its name
      // contains the generic word "content".
      const identity = ((node.id || '') + ' ' +
        (typeof node.className === 'string' ? node.className : '')).toLowerCase();
      if (!picked && /(^|[\s_-])(menu|sidebar|comment|nav|related|recommend|footer|toolbar|pagination|chapters-list)([\s_-]|$)/.test(identity)) continue;
      const clone = node.cloneNode(true);
      try {
        for (const unwanted of clone.querySelectorAll(noise)) unwanted.remove();
      } catch (_) {}
      const plain = text(clone);
      if (plain.length < MIN_TEXT) continue;
      const html = clone.innerHTML || '';
      if (html.length > MAX_HTML) {
        // Only raise for the strongest plausible chapter candidate, not a
        // bloated BODY wrapper full of unrelated page data.
        if (picked || priority >= 275) {
          throw Error('This chapter exceeds the safe capture size. Nothing was truncated. Save this chapter manually and import the complete file.');
        }
        continue;
      }
      const links = clone.querySelectorAll?.('a') || [];
      let linkText = 0;
      for (const anchor of links) linkText += text(anchor).length;
      const linkRatio = linkText / Math.max(1, plain.length);
      if (!picked && linkRatio > 0.28) continue;
      const paragraphs = [...(clone.querySelectorAll?.('p,li,blockquote,pre') || [])];
      let prose = 0, substantial = 0;
      for (const part of paragraphs) {
        const length = text(part).length;
        if (length < 36) continue;
        substantial++;
        prose += length;
      }
      // A long list of book links is not long-form prose. For flat-reader
      // implementations (nested div/span rather than <p>), allow a strong
      // reader-specific selector with meaningful text.
      const strongReader = picked || priority >= 260;
      const textOnly = substantial === 0 && plain.length >= 350 && strongReader &&
        linkRatio < 0.07;
      if (!picked && !textOnly && substantial === 0) continue;
      if (!picked && priority < 180 &&
          (substantial < 2 || prose < 170)) continue;
      const coverage = prose / Math.max(1,plain.length);
      const score = priority +
        Math.min(90, plain.length / 24) +
        Math.min(80, substantial * 10) +
        Math.min(45, coverage * 45) -
        linkRatio * 430 -
        (priority < 0 ? 45 : 0);
      if (score > bestScore) {
        bestScore = score;
        // Prefer a chapter heading INSIDE the reading body rather than the
        // site's generic h1/logo. Some sites reuse document.title for all pages.
        const insideTitle = node.querySelector?.(
          '[data-chapter-title],.chapter-title,[class*="chapter__title"],h1,h2');
        const outsideTitle = doc.querySelector?.(
          '[data-chapter-title],.chapter-title,[class*="chapter__title"]');
        const titleNode = insideTitle || outsideTitle || doc.querySelector?.('h1');
        const fallback = decodeURIComponent(
          (doc.location?.pathname || location.pathname).split('/').pop() || 'Chapter');
        const title = (text(titleNode).slice(0,190) ||
          doc.title || fallback || 'Chapter').trim();
        best = {
          title, html, plain, quality: score, paragraphCount: substantial,
          sourceSelector: picked ? selector :
            (priority >= 260 ? 'reader' : priority >= 170 ? 'article' : 'generic'),
        };
      }
    }
    return best;
  }

  function challenge(doc) {
    const str=(text(doc.body).slice(0,3500)+' '+doc.title).toLowerCase();
    const clues=['captcha','ddos-guard','verify you are human',
      'checking your browser','подтвердите, что вы человек',
      'проверка безопасности','cloudflare','access denied'];
    return clues.some(x=>str.includes(x)) &&
      (str.length<1200 || /captcha|ddos-guard|verify you are human|checking your browser|access denied/.test((doc.title||'').toLowerCase()));
  }

  function selectorFor(el) {
    if (el.id && /^[a-z][\w-]*$/i.test(el.id)) return '#'+el.id;
    const cls=[...el.classList].filter(c=>/^[\w-]{3,}$/.test(c)).slice(0,2);
    return el.tagName.toLowerCase() + (cls.length?'.'+cls.join('.'):'');
  }
  document.addEventListener('click',e=>{
    if(!picker || e.target.closest?.('#leaf-capture-v2')) return;
    picker=false; e.preventDefault(); e.stopPropagation();
    const node=e.target.closest('article,main,[class*="chapter"],[class*="reader"],.mw-parser-output')||e.target.parentElement;
    selector=selectorFor(node);
    status('Selected '+selector+'. Press Resume to try collection.');
  },true);

  async function loadFrame(url) {
    if (!same(url)) throw Error('Refusing a different website.');
    const iframe=document.createElement('iframe');
    iframe.style.cssText='position:fixed;left:-10000px;top:0;width:500px;height:600px;opacity:0;pointer-events:none';
    iframe.setAttribute('aria-hidden','true');
    document.body.appendChild(iframe);
    try {
      iframe.src=url;
      const deadline=Date.now()+WAIT_RENDER_MS;
      while(Date.now()<deadline && !stopped){
        await sleep(450);
        let doc;
        try {doc=iframe.contentDocument;} catch (_) {return null;}
        if (!doc || !doc.body) continue;
        if (challenge(doc)) throw Error('Challenge on source page. Open that page manually, solve it, then resume.');
        const result=selectContent(doc);
        if(result) return {doc,result};
      }
      return null;
    } finally {iframe.remove();}
  }

  async function fetchChapter(url) {
    if (!same(url)) throw Error('Refusing cross-origin navigation.');
    const normalized=normalize(url);
    if (normalized===normalize(location.href)) {
      if (challenge(document)) throw Error('Solve the site challenge in this tab, then press Resume.');
      const live=selectContent(document);
      if (live) return {result:live,doc:document};
    }
    let resp;
    try {
      resp=await fetch(normalized,{credentials:'same-origin',redirect:'follow',cache:'default',headers:{Accept:'text/html'}});
    } catch (err) {throw Error('Page cannot be loaded: '+err);}
    if(!same(resp.url)) throw Error('Page redirected off the original website.');
    if(resp.status===401||resp.status===403||resp.status===429)
      throw Error('Source blocked the request (HTTP '+resp.status+'). Open the page in this tab and resolve it manually. The helper does not bypass restrictions.');
    if(!resp.ok) throw Error('Cannot read page (HTTP '+resp.status+').');
    const html=await resp.text();
    if(html.length>3000000) throw Error('Page is unexpectedly large. Stopped.');
    const doc=new DOMParser().parseFromString(html,'text/html');
    if(challenge(doc)) throw Error('Source returned a verification page. Resolve it manually and resume.');
    let result=selectContent(doc);
    if(result) return {doc,result};
    const frame=await loadFrame(normalized);
    if(frame) return frame;
    throw Error('Chapter text not found. This may be a JavaScript reader. Open the page and try Pick text area, or capture one page manually.');
  }

  function findNext(doc, url) {
    const anchors=[...doc.querySelectorAll('a[href],link[rel~="next"][href]')];
    const candidates=anchors.map(a=>{
      const href=a.getAttribute('href');
      if (!href) return null;
      let resolved;
      try {resolved=new URL(href,url).href;} catch (_) {return null;}
      if(!same(resolved)||normalize(resolved)===normalize(url))return null;
      const rel=(a.getAttribute('rel')||'').toLowerCase().split(/\s+/);
      const label=(text(a)+' '+(a.getAttribute('aria-label')||'')+' '+(a.getAttribute('title')||'')).toLowerCase();
      if (rel.includes('prev') || /previous|\bprev\b|предыдущ|назад/.test(label)) return null;
      const score=rel.includes('next') ? 100 :
        /\bnext\b|следующ|далее|впер[её]д/.test(label) ? 60 :
        /^[\s›»→]+$/.test(label) ? 10 : 0;
      return score?{url:normalize(resolved),score}:null;
    }).filter(Boolean);
    candidates.sort((a,b)=>b.score-a.score);
    if (!candidates.length) return null;
    const strongest=candidates.filter(candidate=>candidate.score===candidates[0].score);
    const targets=[...new Set(strongest.map(candidate=>candidate.url))];
    if (targets.length!==1) throw Error('Several different Next links were found. Stopped rather than guessing the chapter order.');
    if (visited.has(targets[0])) throw Error('The Next link returns to an already collected page. Stopped to avoid a chapter loop.');
    return targets[0];
  }

  async function contentSignature(plain) {
    if (globalThis.crypto?.subtle) {
      const digest=await globalThis.crypto.subtle.digest('SHA-256',new TextEncoder().encode(plain));
      return [...new Uint8Array(digest)].map(value=>value.toString(16).padStart(2,'0')).join('');
    }
    // Exact comparison on browsers without Web Crypto; never use a prefix.
    return plain;
  }

  async function run() {
    if(!job||busy)return;
    if(!same(job.start)||!same(job.end)){status('Only pages from this website are supported.');return;}
    busy=true; stopped=false;
    const max=Math.min(MAX,Number(job.max)||MAX);
    try {
      while(!stopped && index<max){
        const url=job.urls?.length ? job.urls[index] : currentUrl;
        if(!url) throw Error('The chapter list ended before the requested final page.');
        if(!same(url)) throw Error('A chapter URL points to another website.');
        if(visited.has(normalize(url))) throw Error('This page was already collected. Stopped to avoid a chapter loop.');
        status('Reading '+(index+1)+' / '+(job.urls?.length||max)+'…');
        const {doc,result}=await fetchChapter(url);
        if(stopped)break;
        const plain=result.plain.replace(/\s+/g,' ').trim();
        const signature=await contentSignature(plain);
        if(stopped)break;
        if(contentSignatures.has(signature))
          throw Error('Repeated chapter content detected; stopped to avoid an incorrect EPUB.');
        const payload={type:'chapter',token:job.token,index,url:normalize(url),title:result.title,html:result.html};
        captured.push({...payload,signature});
        contentSignatures.add(signature);
        visited.add(payload.url);
        send(payload);
        index++;
        if(normalize(url)===normalize(job.end)){
          completed=true;
          send({type:'done',token:job.token,count:index,lastUrl:normalize(url)});
          if(offlineJob || job?.manualMode || !window.opener) {
            status('Done: '+index+' chapters. Saving JSON for Leaf Import files…');
            downloadJson();
          } else {
            status('Complete: '+index+' chapters sent to Leaf. Your EPUB is being created.');
          }
          return;
        }
        if(!job.urls?.length){
          const next=findNext(doc,url);
          if(!next)throw Error('Next link not found. Enter numeric start/end URLs, or choose a reader with regular Next links.');
          currentUrl=next;
        }
        await sleep(PACE_MS);
      }
      if(stopped){status('Paused after '+index+' chapters. Click Resume to continue.');}
      else if (index>=max) {status('Stopped at safety limit ('+max+').');send({type:'halt',token:job.token,note:'Safety limit reached before end URL'});}
    } catch(err) {
      stopped=true;
      status(String(err.message||err));
      send({type:'halt',token:job.token,note:String(err.message||err),index});
    } finally {busy=false;}
  }

  function downloadJson() {
    if(!captured.length){status('No chapters have been collected yet.');return;}
    const data={leaf:2,title:job?.title||document.title||'Collected chapters',
      complete:completed&&captured.length===index,
      expectedChapters:job?.urls?.length||null,capturedChapters:captured.length,
      start:job?.start,end:job?.end,
      chapters:captured.map(x=>({title:x.title,html:x.html,source:x.url}))};
    const blob=new Blob([JSON.stringify(data)],{type:'application/json'});
    const url=URL.createObjectURL(blob);
    const a=document.createElement('a');a.href=url;a.download='leaf-captured-chapters.json';document.body.appendChild(a);
    a.click();a.remove();setTimeout(()=>URL.revokeObjectURL(url),10000);
  }

  function acceptJob(data) {
    const urls=Array.isArray(data.urls)?data.urls:[];
    const resumeFrom=Number(data.resumeFrom)||0;
    if(!data.token||!same(data.start)||!same(data.end)||urls.length>MAX||urls.some(x=>!same(x))||
        !Number.isInteger(resumeFrom)||resumeFrom<0||resumeFrom>MAX||
        (urls.length&&(normalize(urls[0])!==normalize(data.start)||
          normalize(urls[urls.length-1])!==normalize(data.end)||
          new Set(urls.map(normalize)).size!==urls.length||resumeFrom>urls.length))) {
      status('Invalid job configuration. Start again from Leaf.');return;
    }
    if(busy){status('Collection is already running. Pause before changing the range.');return;}
    const sameJob=job?.token===data.token;
    const retainedCurrent=sameJob&&resumeFrom===index ? currentUrl :
      sameJob ? captured.find(chapter=>chapter.index===resumeFrom)?.url : null;
    if(!sameJob)captured=[];
    else captured=captured.filter(chapter=>chapter.index<resumeFrom);
    visited=new Set(captured.map(chapter=>chapter.url));
    contentSignatures=new Set(captured.map(chapter=>chapter.signature));
    job=data;currentUrl=retainedCurrent||job.start;index=resumeFrom;completed=false;
    if(urls.length && index===urls.length){
      completed=true;
      status('All chapters already received.');
      send({type:'done',token:job.token,count:index,lastUrl:normalize(job.end)});
      return;
    }
    status('Connected to Leaf. Starting collection…');
    void run();
  }

  window.addEventListener('message', event=>{
    if(event.origin!==LEAF_ORIGIN||!window.opener||event.source!==window.opener)return;
    let data;try{data=typeof event.data==='string'?JSON.parse(event.data):event.data;}catch(_){return;}
    if(data?.leaf===2 && data.type==='job'&&sessionToken&&data.token===sessionToken)acceptJob(data);
    if(data?.leaf===2 && data.type==='stop' && data.token===job?.token)stopped=true;
  });

  window.__leafCaptureV2={resume:()=>{
    stopped=false;
    if(window.opener&&sessionToken&&!offlineJob&&!job?.manualMode){
      send({type:'hello',token:sessionToken,pageUrl:normalize(location.href)});
    }else if(job&&!busy)void run();
  }};
  if(offlineJob){
    status('Mobile standalone mode: reading chapters locally. JSON will be saved for Leaf.');
    acceptJob(offlineJob);
  } else if(!window.opener) {
    status('No Leaf tab connection. Use the personalized mobile helper from Leaf, or Export JSON after collecting chapters.');
  } else {
    status('Connected to chapter page. Requesting range from Leaf…');
    send({type:'hello',token:sessionToken,pageUrl:normalize(location.href)});
  }
})();
