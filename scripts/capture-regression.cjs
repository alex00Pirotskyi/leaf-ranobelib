// Unit regressions for the shipped collector. Uses Node's VM and DOM-shaped
// fixtures, not a browser; live browser coverage remains a separate check.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const {webcrypto} = require('node:crypto');
const {execFileSync} = require('node:child_process');

const source = fs.readFileSync(path.join(__dirname,
  '../flutter_app/web/leaf-capture.js'), 'utf8');
new vm.Script(source);

function section(first, next) {
  const begin = source.indexOf(first);
  const end = source.indexOf(next, begin + first.length);
  assert(begin >= 0 && end > begin, `Collector function boundary missing: ${first}`);
  return source.slice(begin, end);
}
const sourceUrl = 'https://reader.example/chapter/one';
const first = sourceUrl;
const second = 'https://reader.example/chapter/two';
const last = 'https://reader.example/chapter/three';
function anchor(href, text, rel = '') {
  return {textContent: text, getAttribute: name =>
    ({href, rel, 'aria-label': '', title: ''}[name] || null)};
}
function documentWithLinks(anchors) {
  return {querySelectorAll: () => anchors};
}

function harness(extra = {}) {
  const sent = [], notes = [];
  const context = vm.createContext({
    URL, Uint8Array, TextEncoder, crypto: webcrypto,
    location: new URL(sourceUrl),
    MAX: 120, MIN_TEXT: 150, MAX_HTML: 600000, PACE_MS: 0,
    sessionToken: 'session', LEAF_ORIGIN: 'https://alex00pirotskyi.github.io',
    job: null, index: 0, currentUrl: sourceUrl, captured: [], completed: false,
    busy: false, stopped: false, visited: new Set(), contentSignatures: new Set(),
    pendingDuplicate: null, allowDuplicateOnce: '',
    duplicateButton: {style: {display: 'none'}},
    offlineJob: null, window: {opener: {}},
    sleep: async () => {}, send: payload => sent.push(payload),
    status: message => notes.push(message), downloadJson: () => {},
    ...extra,
  });
  vm.runInContext(section('  const same =', '  const send =') +
    section('  function text(', '  function visible(') +
    section('  function findNext(', '  async function run(') +
    section('  async function run(', '  function downloadJson(') +
    section('  function acceptJob(', "  window.addEventListener('message'"), context);
  return {context, sent, notes};
}

const cases = [];
function test(name, fn) { cases.push({name, fn}); }

test('actual Dart-generated desktop and Safari bookmarklets compile', () => {
  const fixture = JSON.parse(execFileSync(process.env.LEAF_DART_BIN || 'dart',
    [path.join(__dirname, 'bookmarklet-fixture.dart')],
    {encoding: 'utf8', maxBuffer: 1024 * 1024}));
  for (const [name, url] of Object.entries(fixture)) {
    assert(url.startsWith('javascript:'), name);
    assert(!url.includes('\n'), 'Bookmark URL contains a raw line break');
    const script = decodeURIComponent(url.slice('javascript:'.length));
    assert(script.includes('// Fallback'), 'Fixture did not exercise line comments');
    new vm.Script(script, {filename: `${name}-bookmarklet.js`});
    if (name === 'generic') assert.equal(script, source);
    else assert(script.includes('Книга'), 'Cyrillic job metadata was lost');
  }
});

test('collector only permits HTTPS sites or same-origin local development', () => {
  const production = harness().context;
  assert.equal(production.same('https://reader.example/chapter/two'), true);
  assert.equal(production.same('http://reader.example/chapter/two'), false);
  assert.equal(production.same('https://another.example/chapter/two'), false);
  const local = harness({location: new URL('http://127.0.0.1:8765/chapter/one')}).context;
  assert.equal(local.same('http://127.0.0.1:8765/chapter/two'), true);
  assert.equal(local.same('http://127.0.0.1:7777/chapter/two'), false);
  assert.equal(local.same('http://attacker.example/chapter/two'), false);
});

test('Next navigation ignores chapter menu and previous links', () => {
  const {context} = harness();
  const doc = documentWithLinks([
    anchor('/chapter/zero', 'Глава 0'),
    anchor('/chapter/one', 'Previous chapter', 'prev'),
    anchor('/chapter/two', 'Следующая глава', 'next'),
  ]);
  assert.equal(context.findNext(doc, first), second);
  assert.equal(context.findNext(documentWithLinks([
    anchor('/chapter/zero', 'Глава 0'), anchor('/chapter/two', 'Глава 2'),
  ]), first), null);
});

test('conflicting Next targets and a navigation loop halt', () => {
  const {context} = harness();
  assert.throws(() => context.findNext(documentWithLinks([
    anchor(second, 'Next'), anchor(last, 'Next'),
  ]), first), /Several different Next/);
  context.visited.add(second);
  assert.throws(() => context.findNext(documentWithLinks([
    anchor(second, 'Next', 'next'),
  ]), first), /already collected/);
});

test('same target in top and bottom navigation is accepted', () => {
  const {context} = harness();
  assert.equal(context.findNext(documentWithLinks([
    anchor(second, 'Next', 'next'), anchor(second + '#text', 'Next', 'next'),
  ]), first), second);
});

test('content signature includes full chapter, not just first 500 characters', async () => {
  const {context} = harness();
  const prefix = 'Same first paragraph. '.repeat(40);
  assert.notEqual(await context.contentSignature(prefix + 'one'),
    await context.contentSignature(prefix + 'two'));
});

function response(url, anchors = [], body) {
  const plain = body || `A complete chapter at ${url}. `.repeat(10);
  return {doc: documentWithLinks(anchors), result: {
    title: url.split('/').pop(), html: `<p>${plain}</p>`, plain,
  }};
}

test('a complete explicit range sends exactly ordered chapters and final URL', async () => {
  const {context, sent} = harness({fetchChapter: async url => response(url)});
  context.job = {token: 'session', start: first, end: last,
    urls: [first, second, last], max: 3};
  await context.run();
  assert.deepEqual(sent.filter(item => item.type === 'chapter').map(item => item.url),
    [first, second, last]);
  const done = sent.find(item => item.type === 'done');
  assert.equal(done.count, 3);
  assert.equal(done.lastUrl, last);
  assert.equal(context.completed, true);
});

test('duplicate chapter text fails without reporting a complete book', async () => {
  const {context, sent} = harness({fetchChapter: async url =>
    response(url, [], 'The same body on every response. '.repeat(20))});
  context.job = {token: 'session', start: first, end: last,
    urls: [first, second, last], max: 3};
  await context.run();
  assert.equal(context.index, 1);
  assert.equal(context.completed, false);
  assert.equal(sent.some(item => item.type === 'done'), false);
  assert.match(sent.find(item => item.type === 'halt').note, /identical book text/);
  assert.equal(context.duplicateButton.style.display, 'inline-block');
  assert.equal(context.pendingDuplicate.url, second);
});


test('explicit approval allows an intentional duplicate once, without hiding later duplicates', async () => {
  const {context, sent} = harness({fetchChapter: async url =>
    response(url, [], 'The same chapter text, deliberately repeated by the author. '.repeat(15))});
  context.job = {token: 'session', start: first, end: last,
    urls: [first, second, last], max: 3};
  await context.run();
  assert.equal(context.index, 1);
  assert.equal(context.pendingDuplicate.url, second);
  context.allowDuplicateOnce = second;
  await context.run();
  assert.equal(context.index, 2);
  assert.equal(context.pendingDuplicate.url, last);
  context.allowDuplicateOnce = last;
  await context.run();
  assert.equal(context.index, 3);
  assert.equal(context.completed, true);
  assert.equal(sent.filter(item => item.type === 'chapter').length, 3);
});

test('an opaque URL loop cannot produce a false successful EPUB', async () => {
  const {context, sent} = harness({fetchChapter: async url => response(url,
    [anchor(url === first ? second : first, 'Next', 'next')])});
  context.job = {token: 'session', start: first, end: last, urls: [], max: 120};
  await context.run();
  assert.equal(context.index, 2);
  assert.equal(sent.some(item => item.type === 'done'), false);
  assert.match(sent.find(item => item.type === 'halt').note, /already collected/);
});

test('missing Next and safety cap remain incomplete', async () => {
  for (const max of [1, 120]) {
    const {context, sent} = harness({fetchChapter: async url => response(url,
      max === 1 ? [anchor(second, 'Next', 'next')] : [])});
    context.job = {token: 'session', start: first, end: last, urls: [], max};
    await context.run();
    assert.equal(context.completed, false);
    assert.equal(sent.some(item => item.type === 'done'), false);
    assert.equal(sent.some(item => item.type === 'halt'), true);
  }
});

test('invalid or duplicate explicit URL plans are rejected before fetching', () => {
  const {context, notes} = harness();
  context.run = () => { throw Error('Should never run'); };
  for (const urls of [[first, second], [first, first, last],
    [first, 'https://different.example/two', last]]) {
    context.acceptJob({token: 'session', start: first, end: last,
      urls, max: 3, resumeFrom: 0});
    assert.match(notes.at(-1), /Invalid job configuration/);
    assert.equal(context.job, null);
  }
});

test('another job cannot reset a running collector', () => {
  const {context, notes} = harness();
  context.job = {token: 'existing'};
  context.busy = true;
  context.index = 2;
  context.acceptJob({token: 'new', start: first, end: last,
    urls: [first, second, last], max: 3, resumeFrom: 0});
  assert.equal(context.job.token, 'existing');
  assert.equal(context.index, 2);
  assert.match(notes.at(-1), /already running/);
});

test('resuming opaque navigation retains the next pending URL', () => {
  const {context} = harness();
  context.job = {token: 'session'};
  context.currentUrl = second;
  context.index = 1;
  context.captured = [{index: 0, url: first, signature: 'first'}];
  context.run = () => {};
  context.acceptJob({token: 'session', start: first, end: last,
    urls: [], max: 120, resumeFrom: 1});
  assert.equal(context.currentUrl, second);
  assert.equal(context.index, 1);
  assert.equal(context.captured.length, 1);
});

test('message bridge requires correct opener, origin and session token', () => {
  let listener;
  const opener = {};
  const {context} = harness({window: {opener,
    addEventListener: (_name, fn) => {listener = fn;}}});
  const accepted = [];
  context.acceptJob = job => accepted.push(job);
  vm.runInContext(section("  window.addEventListener('message'",
    '  window.__leafCaptureV2='), context);
  const data = {leaf: 2, type: 'job', token: 'session'};
  listener({origin: context.LEAF_ORIGIN, source: {}, data});
  listener({origin: 'https://attacker.example', source: opener, data});
  listener({origin: context.LEAF_ORIGIN, source: opener,
    data: {...data, token: 'wrong'}});
  assert.equal(accepted.length, 0);
  listener({origin: context.LEAF_ORIGIN, source: opener, data});
  assert.equal(accepted.length, 1);
});

test('the live page is checked for a challenge before extracting text', async () => {
  const {context} = harness({document: {},
    challenge: () => true,
    selectContent: () => {throw Error('Must not inspect challenge as a chapter');},
  });
  vm.runInContext(section('  async function fetchChapter(',
    '  function findNext('), context);
  await assert.rejects(context.fetchChapter(first), /Solve the site challenge/);
});

test('oversize chapters halt and are never silently shortened', () => {
  const clone = {innerHTML: 'x'.repeat(600001), textContent: 'Chapter text. '.repeat(20),
    querySelectorAll: () => []};
  const node = {textContent: clone.textContent, tagName: 'ARTICLE', isConnected: true,
    closest: () => null, querySelectorAll: () => [], cloneNode: () => clone};
  const doc = {body: node, querySelectorAll: () => [node], querySelector: () => null, title: 'Chapter'};
  const {context} = harness({selector: '', visible: () => true});
  vm.runInContext(section('  function selectContent(', '  function challenge('), context);
  assert.throws(() => context.selectContent(doc), /Nothing was truncated/);
});

(async () => {
  for (const {name, fn} of cases) {
    await fn();
    console.log('PASS', name);
  }
  console.log(`${cases.length} collector regressions passed.`);
})().catch(error => {console.error(error.stack || String(error)); process.exitCode = 1;});
