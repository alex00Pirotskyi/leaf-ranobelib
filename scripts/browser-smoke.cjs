// End-to-end checks against an already built Leaf site. Run in CI after serving
// flutter_app/build/web at /leaf-ranobelib/. No browser source mocks are used.
const { chromium, webkit, devices } = require('playwright');
const fs = require('node:fs');
const path = require('node:path');
const { execFileSync } = require('node:child_process');

const SITE = (process.env.LEAF_SITE || 'https://alex00pirotskyi.github.io/leaf-ranobelib/').replace(/\/?$/, '/');
const OUT = path.resolve(process.env.LEAF_SMOKE_ARTIFACTS || 'smoke-artifacts');
fs.mkdirSync(OUT, { recursive: true });
const report = { site: SITE, started: new Date().toISOString(), scenarios: [], downloads: [], requests: [], diagnostics: [] };
const browsers = [];
const contexts = [];
const epubExpectations = [];
let activePage;
let activeScenario = 'initialization';
const assert = (condition, message) => { if (!condition) throw new Error(message); };
const delay = milliseconds => new Promise(resolve => setTimeout(resolve, milliseconds));

async function scenario(name, body) {
  activeScenario = name;
  console.log('SCENARIO:', name);
  const started = Date.now();
  try {
    const details = await body();
    report.scenarios.push({ name, status: 'passed', milliseconds: Date.now() - started, ...(details || {}) });
    console.log('PASS:', name);
  } catch (error) {
    report.scenarios.push({ name, status: 'failed', milliseconds: Date.now() - started, error: error.stack || String(error) });
    throw error;
  }
}

async function newPage(browser, label, options = {}) {
  const context = await browser.newContext({ acceptDownloads: true, viewport: { width: 1280, height: 1000 }, ...options });
  contexts.push({ context, label });
  await context.tracing.start({ screenshots: true, snapshots: true });
  const page = await context.newPage();
  activePage = page;
  page.setDefaultTimeout(20000);
  const runtimeErrors = [];
  const downloadEvents = [];
  page.on('pageerror', error => { runtimeErrors.push(error.message); report.diagnostics.push({ label, type: 'pageerror', text: error.message }); });
  page.on('console', message => {
    if (message.type() === 'error' || /RenderFlex.*overflow|EXCEPTION CAUGHT/i.test(message.text())) {
      report.diagnostics.push({ label, type: message.type(), text: message.text() });
      if (/RenderFlex.*overflow|EXCEPTION CAUGHT/i.test(message.text())) runtimeErrors.push(message.text());
    }
  });
  page.on('download', download => downloadEvents.push(download));
  page.on('request', request => {
    const url = new URL(request.url());
    if (/\.wiki(?:source|books)\.org$/.test(url.hostname) && url.pathname === '/w/api.php') {
      report.requests.push({ label, action: url.searchParams.get('action'), page: url.searchParams.get('page'),
        prop: url.searchParams.get('prop'), search: url.searchParams.get('srsearch'), at: Date.now() });
    }
  });
  page.on('requestfailed', request => report.diagnostics.push({ label, type: 'requestfailed',
    url: request.url(), error: request.failure()?.errorText }));
  return { page, context, label, runtimeErrors, downloadEvents };
}

async function enableAccessibility(page) {
  await page.waitForSelector('flutter-view, flt-glass-pane', { state: 'attached', timeout: 60000 });
  await page.waitForFunction(() => document.querySelector('flt-semantics-placeholder') ||
    document.querySelector('flt-semantics [role="textbox"]'), null, { timeout: 45000 });
  await page.evaluate(() => document.querySelector('flt-semantics-placeholder')?.click());
  await page.getByRole('textbox', { name: /Search books/i }).waitFor({ state: 'visible', timeout: 45000 });
}

async function openHome(page) {
  activePage = page;
  await page.goto(SITE, { waitUntil: 'domcontentloaded', timeout: 45000 });
  await enableAccessibility(page);
}

const bookButton = (page, title) => page.getByRole('button', {
  name: new RegExp('^Prepare EPUB: ' + title.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')),
}).first();

// Flutter ChoiceChip semantics can expose button, radio or checkbox roles
// depending on the framework/browser version. All locators use the actual
// visible/accessibility label, with no screen-coordinate assumptions.
async function clickLabel(page, label) {
  const names = { name: label, exact: true };
  await page.getByRole('button', names)
    .or(page.getByRole('radio', names))
    .or(page.getByRole('checkbox', names))
    .or(page.getByText(label, { exact: true })).first().click();
}

async function assertHealthy(state) {
  assert(state.runtimeErrors.length === 0, state.label + ' runtime errors: ' + state.runtimeErrors.join(' | '));
  const geometry = await state.page.evaluate(() => ({
    viewport: window.innerWidth,
    document: document.documentElement.scrollWidth,
    body: document.body?.scrollWidth || 0,
  }));
  assert(geometry.document <= geometry.viewport + 2 && geometry.body <= geometry.viewport + 2,
    state.label + ' has horizontal overflow: ' + JSON.stringify(geometry));
  return geometry;
}

// Read the public application's own IndexedDB, not a private Dart variable.
// This verifies actual durable content and survives a full page reload.
async function checkpoint(page) {
  return page.evaluate(() => new Promise((resolve, reject) => {
    const request = indexedDB.open('leaf-reading-v3');
    request.onerror = () => reject(request.error);
    request.onsuccess = () => {
      const db = request.result;
      if (!db.objectStoreNames.contains('jobs')) { db.close(); resolve(null); return; }
      const transaction = db.transaction('jobs', 'readonly');
      const store = transaction.objectStore('jobs');
      const current = store.get('current');
      let result = null;
      current.onsuccess = () => {
        if (typeof current.result !== 'string') return;
        result = JSON.parse(current.result);
        if (Array.isArray(result.chapters)) return;
        result.chapters = [];
        for (let index = 0; index < (result.chapterCount || 0); index++) {
          const chapter = store.get('chapter:' + index);
          chapter.onsuccess = () => { result.chapters[index] = typeof chapter.result === 'string' ? JSON.parse(chapter.result) : null; };
        }
      };
      transaction.oncomplete = () => { db.close(); resolve(result); };
      transaction.onerror = () => { db.close(); reject(transaction.error); };
    };
  }));
}

async function waitForCheckpoint(page, predicate, timeout = 60000) {
  const deadline = Date.now() + timeout;
  let latest;
  while (Date.now() < deadline) {
    latest = await checkpoint(page);
    if (predicate(latest)) return latest;
    await delay(150);
  }
  throw new Error('Saved progress did not reach the expected state: ' + JSON.stringify(latest && {
    chapterCount: latest.chapters?.length, total: latest.total, complete: latest.complete,
  }));
}

// Python's standard-library ZIP and XML parsers check every member's CRC and
// well-formed XML, then compare the actual EPUB spine, navigation and text.
const VALIDATE_EPUB = String.raw`
import json, re, sys, zipfile, posixpath
import xml.etree.ElementTree as ET
filename, expected = sys.argv[1], json.loads(sys.argv[2])
ns = {'opf': 'http://www.idpf.org/2007/opf', 'dc': 'http://purl.org/dc/elements/1.1/', 'h': 'http://www.w3.org/1999/xhtml'}
with zipfile.ZipFile(filename) as archive:
    names = archive.namelist()
    assert len(names) == len(set(names)), 'Duplicate archive members'
    first = archive.infolist()[0]
    assert first.filename == 'mimetype' and first.compress_type == zipfile.ZIP_STORED, 'mimetype must be first and stored'
    assert archive.read('mimetype') == b'application/epub+zip', 'Incorrect EPUB MIME'
    assert archive.testzip() is None, 'ZIP member CRC failed'
    container = ET.fromstring(archive.read('META-INF/container.xml'))
    rootfile = container.find('.//{urn:oasis:names:tc:opendocument:xmlns:container}rootfile').attrib['full-path']
    opf = ET.fromstring(archive.read(rootfile))
    base = posixpath.dirname(rootfile)
    title = opf.findtext('opf:metadata/dc:title', namespaces=ns)
    language = opf.findtext('opf:metadata/dc:language', namespaces=ns)
    author = opf.findtext('opf:metadata/dc:creator', namespaces=ns)
    assert expected['title'] in title, (title, expected['title'])
    assert language == expected['language'], (language, expected['language'])
    if expected.get('author'): assert expected['author'] in author, (author, expected['author'])
    manifest = {item.attrib['id']: item for item in opf.findall('opf:manifest/opf:item', ns)}
    spine = [item.attrib['idref'] for item in opf.findall('opf:spine/opf:itemref', ns)]
    assert len(spine) == expected['sections'], (len(spine), expected['sections'])
    texts = []
    chapter_paths = []
    for identifier in spine:
        member = posixpath.normpath(posixpath.join(base, manifest[identifier].attrib['href']))
        chapter_paths.append(member)
        document = ET.fromstring(archive.read(member))
        assert not document.findall('.//h:script', ns), 'Executable content in EPUB'
        texts.append(re.sub(r'\s+', ' ', ' '.join(document.itertext())))
    nav_item = next(item for item in manifest.values() if 'nav' in item.attrib.get('properties', '').split())
    nav_path = posixpath.normpath(posixpath.join(base, nav_item.attrib['href']))
    nav = ET.fromstring(archive.read(nav_path))
    nav_links = nav.findall('.//h:nav/h:ol/h:li/h:a', ns)
    assert len(nav_links) == len(spine), 'Navigation/spine count mismatch'
    nav_paths = [posixpath.normpath(posixpath.join(posixpath.dirname(nav_path), item.attrib['href'])) for item in nav_links]
    assert nav_paths == chapter_paths, 'Navigation order differs from spine'
    joined = ' '.join(texts)
    for needle in expected.get('needles', []): assert needle in joined, 'Missing book text: ' + needle
    for name in names:
        if name.endswith(('.xhtml', '.xml', '.opf', '.ncx')): ET.fromstring(archive.read(name))
    print(json.dumps({'title': title, 'author': author, 'language': language, 'sections': len(spine), 'members': len(names)}, ensure_ascii=False))
`;

async function verifyDownload(download, filename, expected) {
  const failure = await download.failure();
  assert(!failure, 'Browser download failed: ' + failure);
  const destination = path.join(OUT, filename);
  await download.saveAs(destination);
  const size = fs.statSync(destination).size;
  assert(size > 500, 'Downloaded EPUB is suspiciously small: ' + size);
  epubExpectations.push({ filename, language: expected.language,
    chapters: expected.sections, contains: expected.needles || [] });
  fs.writeFileSync(path.join(OUT, 'epub-expectations.json'), JSON.stringify(epubExpectations, null, 2));
  const details = JSON.parse(execFileSync('python3', ['-c', VALIDATE_EPUB, destination, JSON.stringify(expected)], { encoding: 'utf8' }));
  report.downloads.push({ filename, suggestedFilename: download.suggestedFilename(), bytes: size, ...details });
  console.log('VERIFIED EPUB:', filename, JSON.stringify(details));
  return details;
}

async function search(page, language, query, title) {
  const input = page.getByRole('textbox', { name: /Search books/i });
  await input.fill('');
  await input.press('Enter');
  await page.getByText('Start with a good story', { exact: true }).waitFor();
  await clickLabel(page, language);
  await input.fill(query);
  const request = page.waitForRequest(request => {
    const url = new URL(request.url());
    return url.searchParams.get('action') === 'query' && (url.searchParams.get('srsearch') || '').startsWith(query);
  }, { timeout: 15000 });
  await input.press('Enter');
  await request;
  await page.getByText('Search results', { exact: true }).waitFor({ timeout: 40000 });
  await bookButton(page, title).waitFor({ state: 'visible' });
  const fallbackMessages = await page.getByText(/search is (?:busy|unavailable)|Search took too long|catalogue returned|Full-text search is busy/i).allTextContents();
  return { language, query, fallbackMessages };
}

async function mobileFlow(browser, label, device) {
  const state = await newPage(browser, label, { ...device, viewport: { width: 390, height: 844 } });
  await openHome(state.page);
  await state.page.screenshot({ path: path.join(OUT, label + '-home.png'), fullPage: true });
  await bookButton(state.page, 'Евгений Онегин').click();
  await state.page.getByText('Your EPUB is ready', { exact: true }).waitFor({ timeout: 90000 });
  assert(state.downloadEvents.length === 0, 'Phone must wait for the user’s Save EPUB gesture.');
  const saving = state.page.waitForEvent('download', { timeout: 30000 });
  await state.page.getByRole('button', { name: 'Save EPUB', exact: true }).click();
  await verifyDownload(await saving, label + '-onegin.epub', {
    title: 'Евгений Онегин', language: 'ru', author: 'Пушкин', sections: 1,
    needles: ['Мой дядя самых честных правил'],
  });
  const geometry = await assertHealthy(state);
  await state.page.screenshot({ path: path.join(OUT, label + '-ready.png'), fullPage: true });
  let externalSourceFallback;
  if (label === 'mobile-chromium') {
    await openHome(state.page);
    await clickLabel(state.page, 'Chapter links');
    await state.page.getByRole('button', { name: 'Try test collector pages (3 chapters)', exact: true }).click();
    const pagesBefore = state.context.pages().length;
    await state.page.getByRole('button', { name: 'Import chapters on this phone', exact: true }).click();
    await state.page.getByRole('button', { name: 'Choose files', exact: true }).waitFor();
    assert(await state.page.getByText(/Waiting for Leaf Capture|Collecting chapters|Preparing your book/).count() === 0,
      'Android external-source fallback must not pretend collection is running.');
    assert(state.context.pages().length === pagesBefore, 'Android fallback opened an unsupported capture tab.');
    externalSourceFallback = 'explicit local import, without fictitious collection';
    await assertHealthy(state);
    await state.page.screenshot({ path: path.join(OUT, 'android-external-source-fallback.png'), fullPage: true });
  }
  return { engine: label, physicalDevice: false, geometry, saveRequiredFreshGesture: true, externalSourceFallback };
}

(async () => {
  try {
    const chrome = await chromium.launch({ headless: true, args: ['--disable-dev-shm-usage'] });
    browsers.push(chrome);
    const desktop = await newPage(chrome, 'desktop-chromium');
    await scenario('desktop homepage exposes four featured books', async () => {
      await openHome(desktop.page);
      const cards = desktop.page.getByRole('button', { name: /^(?:Prepare|Download) EPUB:/ });
      assert(await cards.count() === 4, 'Expected exactly four accessible featured book actions.');
      for (const title of ['Капитанская дочка', "Alice's Adventures in Wonderland", 'Евгений Онегин']) {
        await bookButton(desktop.page, title).waitFor({ state: 'visible' });
      }
      await desktop.page.screenshot({ path: path.join(OUT, 'desktop-home.png'), fullPage: true });
      return { featuredBooks: await cards.count(), geometry: await assertHealthy(desktop) };
    });

    await scenario('English and Russian catalogue search preserves usable fallbacks', async () => ({
      searches: [await search(desktop.page, 'English', 'Alice', "Alice's Adventures in Wonderland"),
        await search(desktop.page, 'Русский', 'Евгений Онегин', 'Евгений Онегин')],
    }));

    await scenario('Alice: pause, reload, resume without fetching saved sections again', async () => {
      await openHome(desktop.page);
      await bookButton(desktop.page, "Alice's Adventures in Wonderland").click();
      await waitForCheckpoint(desktop.page, saved => saved?.chapters?.length > 0 && !saved.complete);
      await desktop.page.getByRole('button', { name: 'Pause download', exact: true }).click();
      await desktop.page.getByRole('button', { name: 'Continue download', exact: true }).waitFor();
      const saved = await checkpoint(desktop.page);
      assert(saved.chapters.length > 0 && saved.chapters.length < 13, 'Pause must preserve a partial real book.');
      assert(saved.chapters.every(chapter => chapter?.html?.length > 80), 'Durable checkpoint contains chapter bodies.');
      const prefix = JSON.stringify(saved.chapters);
      await desktop.page.reload({ waitUntil: 'domcontentloaded' });
      await enableAccessibility(desktop.page);
      await desktop.page.getByRole('button', { name: 'Continue saved book', exact: true }).waitFor();
      const restored = await checkpoint(desktop.page);
      assert(JSON.stringify(restored.chapters) === prefix, 'Chapter content did not survive reload unchanged.');
      const requestStart = report.requests.length;
      const download = desktop.page.waitForEvent('download', { timeout: 150000 });
      await desktop.page.getByRole('button', { name: 'Continue saved book', exact: true }).click();
      await verifyDownload(await download, 'alice-complete-resumed.epub', {
        title: "Alice's Adventures in Wonderland", author: 'Lewis Carroll', language: 'en', sections: 13,
        needles: ['All in the golden afternoon', 'rabbit-hole'],
      });
      const savedTitles = new Set(saved.receivedUrls.map(value => decodeURIComponent(new URL(value).pathname.slice('/wiki/'.length)).replaceAll('_', ' ')));
      const reread = report.requests.slice(requestStart).filter(request => request.label === desktop.label && request.prop === 'text' && savedTitles.has(request.page));
      assert(reread.length === 0, 'Saved chapters were unnecessarily fetched again: ' + JSON.stringify(reread));
      const completed = await checkpoint(desktop.page);
      assert(completed.complete && completed.chapters.length === 13, 'Completion was not checkpointed.');
      await assertHealthy(desktop);
      await desktop.page.screenshot({ path: path.join(OUT, 'alice-ready.png'), fullPage: true });
      return { savedBeforeReload: saved.chapters.length, completedSections: 13, savedSectionsRefetched: 0 };
    });

    await scenario('Russian full-text book: one action, Cyrillic EPUB and language metadata', async () => {
      await openHome(desktop.page);
      const download = desktop.page.waitForEvent('download', { timeout: 90000 });
      await bookButton(desktop.page, 'Евгений Онегин').click();
      await verifyDownload(await download, 'desktop-onegin.epub', {
        title: 'Евгений Онегин', author: 'Пушкин', language: 'ru', sections: 1,
        needles: ['Мой дядя самых честных правил'],
      });
      await assertHealthy(desktop);
    });

    await scenario('Manual first/last chapter demo still downloads three sections', async () => {
      await openHome(desktop.page);
      await clickLabel(desktop.page, 'Chapter links');
      await desktop.page.getByRole('button', { name: 'Try the open-book demo (3 chapters)', exact: true }).click();
      const download = desktop.page.waitForEvent('download', { timeout: 90000 });
      await desktop.page.getByRole('button', { name: 'Collect & download EPUB', exact: true }).click();
      await verifyDownload(await download, 'manual-three-chapters.epub', {
        title: 'Pride and Prejudice', author: 'Jane Austen', language: 'en', sections: 3,
        needles: ['universally acknowledged'],
      });
    });

    await scenario('Local JSON import uses file chooser and creates a validated EPUB', async () => {
      await openHome(desktop.page);
      await clickLabel(desktop.page, 'Import files');
      const chapters = [1, 2, 3].map(number => ({ title: 'Imported chapter ' + number,
        html: '<p>Chapter ' + number + ' begins here. This locally chosen reading material stays on the device and becomes a complete EPUB with its original reading order.</p>' }));
      const choosing = desktop.page.waitForEvent('filechooser');
      await desktop.page.getByRole('button', { name: 'Choose files', exact: true }).click();
      await (await choosing).setFiles({ name: 'offline-reading.json', mimeType: 'application/json',
        buffer: Buffer.from(JSON.stringify({ title: 'Offline import smoke', author: 'Test Reader', language: 'en', complete: true, chapters })) });
      await desktop.page.getByText('3 chapters ready', { exact: true }).waitFor();
      const inputs = desktop.page.getByRole('textbox');
      assert(await inputs.count() === 2, 'Import panel must expose title and author fields.');
      await inputs.nth(0).fill('Offline import smoke');
      await inputs.nth(1).fill('Test Reader');
      const download = desktop.page.waitForEvent('download', { timeout: 30000 });
      await desktop.page.getByRole('button', { name: 'Create EPUB', exact: true }).click();
      await verifyDownload(await download, 'local-import.epub', {
        title: 'Offline import smoke', author: 'Test Reader', language: 'en', sections: 3,
        needles: ['Chapter 3 begins here'],
      });
      await assertHealthy(desktop);
    });

    const safari = await webkit.launch({ headless: true });
    browsers.push(safari);
    await scenario('Mobile WebKit: iPhone layout and explicit Save EPUB gesture', () =>
      mobileFlow(safari, 'mobile-webkit', devices['iPhone 13']));
    await scenario('Mobile Chromium: Android layout and explicit Save EPUB gesture', () =>
      mobileFlow(chrome, 'mobile-chromium', devices['Pixel 7']));
  } catch (error) {
    console.error('SMOKE FAILURE:', activeScenario, error.stack || error);
    report.failure = { scenario: activeScenario, error: error.stack || String(error) };
    process.exitCode = 1;
    if (activePage) {
      try { await activePage.screenshot({ path: path.join(OUT, 'failure.png'), fullPage: true }); } catch (_) {}
      try { fs.writeFileSync(path.join(OUT, 'failure-dom.txt'), await activePage.locator('body').innerText()); } catch (_) {}
    }
  } finally {
    report.finished = new Date().toISOString();
    fs.writeFileSync(path.join(OUT, 'report.json'), JSON.stringify(report, null, 2));
    fs.writeFileSync(path.join(OUT, 'epub-expectations.json'), JSON.stringify(epubExpectations, null, 2));
    for (const { context, label } of contexts) {
      try { await context.tracing.stop(report.failure ? { path: path.join(OUT, label + '-trace.zip') } : {}); } catch (_) {}
      try { await context.close(); } catch (_) {}
    }
    for (const browser of browsers) { try { await browser.close(); } catch (_) {} }
  }
})();
