# Leaf reading experience: research and implementation

Research date: 28 October 2026, Asia/Ho_Chi_Minh. Baseline inspected: `977affa3ad8c577eed9b653f25c2604fc5a27af3`.

## Product conclusion

The strongest experience under the existing Flutter web / GitHub Pages / no backend / no extension constraints is a book-first catalogue with source-aware acquisition:

- Use an existing EPUB when a provider supplies one.
- Otherwise discover an ordered contents manifest from a browser-readable source, then collect and package locally.
- Offer explicit manual links/import for sources that cannot be read by Leaf.
- Save each completed section and distinguish a full selected manifest from a partial capture.

One tap can initiate the complete acquisition process. Phone browsers may require a second, explicit Save/Share tap after the file is prepared. A universal cross-origin scraper with a user-solved CAPTCHA is not achievable by a normal static web app.

## Problems found in the baseline

| Finding | Consequence | Implemented response |
|---|---|---|
| First/last URLs were required before any useful action | Users had to find and copy chapter endpoints manually | Search-first home, featured editions, automatic contents |
| EPUB language, identifier and modified timestamp were hardcoded | English books claimed Russian; different books shared an ID | Source language, UUID, current UTC timestamp |
| `div`/`section` wrappers became paragraphs | Invalid nested XHTML paragraphs | Preserve block structure; validate all XML and EPUBCheck |
| Self-contained helpers flattened newlines while retaining `//` comments | Actual copied iPhone helper could be syntactically broken | Percent-encode preserved source; compile real generated bookmarklets |
| No durable chapter checkpoint | Reload/background interruption lost the job | IndexedDB checkpoints and direct-reader resume |
| Pause/restart reused a global cancellation flag | Old responses could enter a new book | Per-run generation guards |
| Collector silently truncated oversized text | A successful-looking EPUB could lose content | Halt with explicit error, retain recoverable chapters |
| Generic “Глава N” links could be treated as Next | Previous chapter, contents links and loops could be followed | Explicit Next priority, ambiguity/visited checks |
| Collector status messages lacked the token required by receiver | Useful status messages were discarded | Consistent authenticated bridge payloads |
| Unknown-range safety cap could be confused with completion | Reaching a cap could label an incomplete book complete | Exact ending URL and explicit completion state |
| File imports sorted lexically and accepted placeholder content | Wrong order or empty chapters | Natural order, strict validation, completeness metadata |
| Android external-source flow used desktop bookmark setup | Unactionable waiting state on a phone | Explicit import fallback; direct library route remains available |
| GitHub Pages PWA manifest started at `/` | Home-screen launch could leave the project path | Relative start URL and scope |

## Browser facts and their implications

[MDN's same-origin documentation](https://developer.mozilla.org/en-US/docs/Web/Security/Defenses/Same-origin_policy) distinguishes navigation from reading another origin's DOM. An opened source tab can let a person read or authenticate, but Leaf cannot inspect that tab automatically. An iframe does not change this rule, and the source can prohibit embedding altogether.

[MediaWiki's cross-site API](https://www.mediawiki.org/wiki/API:Cross-site_requests) deliberately allows unauthenticated cross-origin requests when `origin=*` is included. That is why Wikisource/Wikibooks are appropriate direct adapters. This capability cannot be inferred from a site being publicly readable.

[WebKit's user-activation explanation](https://webkit.org/blog/13862/the-user-activation-api/) shows why a long fetch/build can outlive the gesture needed to invoke native sharing. Leaf exposes a ready-state Save button. [MDN's `canShare` reference](https://developer.mozilla.org/en-US/docs/Web/API/Navigator/canShare) also makes clear that file support must be tested against the actual data; EPUB sharing is conditional.

A direct external EPUB download is a navigation, not a cross-origin fetch. It can therefore work without exposing the file's bytes to Leaf. The browser/source controls that download, so the UI describes it as a source EPUB rather than claiming local packaging or validation.

## Source research and low-volume probes

Requests used Leaf's published Origin header where applicable. HTTP/header probes are not equivalent to a physical mobile-browser test; browser integration checks are separate.

| Source or endpoint | Observation | Decision |
|---|---|---|
| RU/EN Wikisource parse API | HTTP 200 JSON and `Access-Control-Allow-Origin: *` | Integrated direct reading |
| EN Wikisource title search | HTTP 200 JSON, CORS `*`, actual edition results | Integrated search |
| RU full-text search | HTTP 200 with `cirrussearch-too-busy-error` in the JSON | Preserve other results; do not equate HTTP 200 with success |
| RU title-prefix fallback | HTTP 200 JSON, CORS `*`, actual edition found | One bounded fallback, visibly labelled |
| Project Gutenberg EPUB 1342 | HTTP 200 EPUB, ZIP signature verified, no CORS header | Source-native download link |
| Project Gutenberg HTML/text | No CORS header on sampled response | No promise of direct in-app fetch |
| WS Export EPUB | HTTP 200 `application/epub+zip`, ZIP verified, no CORS header | Suitable native export link, not a fetch/Blob assumption |
| Open Library search | HTTP 200 JSON, CORS `*` | Discovery is viable; not proof of full-text availability |
| Standard Ebooks complete OPDS feed | HTTP 401 with patron authentication challenge | External directory; do not rely on unrestricted full feed |
| Gutendex | Timeout followed by HTTP 403 | Excluded from the critical integrated path |
| RanobeLIB | Baseline audit observed API 403/DDoS-Guard; no authenticated live book verified in this revision | Experimental compatible-source capture only; no universal download claim |

[Project Gutenberg's robot-access policy](https://www.gutenberg.org/policy/robot_access.html) provides specific catalogue/harvesting mechanisms rather than supporting arbitrary bulk scraping of the main site. A user-initiated link to the provider's EPUB is the appropriate small-scale flow here. [Open Library's API guidance](https://openlibrary.org/developers/api) supports human book lookup and asks clients to avoid bulk HTML scraping. Its catalogue includes editions with different reading/borrowing availability.

[Standard Ebooks feed documentation](https://standardebooks.org/feeds) distinguishes public new-release feeds from the complete feed benefits. The directory remains useful without promising automated access to a protected feed.

## Edition and chapter verification

A book title is not necessarily a book body. Russian title pages such as `Капитанская дочка (Пушкин)` can be lists of editions. Combining their links would mix translations/editions or duplicate the text. The discovery adapter inspects source properties and categories and asks for a specific edition instead.

The adapter reads authoritative source links in order. It supports ordinary descendants, explicitly marked contents, nested volumes and source-confirmed parent links. It retains meaningful text on the contents page. [Wikisource's export preparation guide](https://en.wikisource.org/wiki/Help:Preparing_for_export) explains the same underlying need: export depends on the source's contents links, and a properly prepared work must be self-contained and complete.

Actual saved API responses were inspected and fed through the production Dart discovery code:

| Edition | Discovered sections | Content verification |
|---|---:|---|
| Капитанская дочка /1960 (СО) | 16 | 14 chapters, appendix, and source epigraph/editorial notes retained |
| Евгений Онегин /СС 1959 (СО) | 1 | Full-text source page |
| Alice's Adventures in Wonderland (1866) | 13 | Opening poem plus 12 chapters |
| Pride and Prejudice (1817) | 61 | Ordered chapters |
| Captain's Daughter editions index | Rejected | Prevents incompatible editions from being concatenated |

This is evidence for the tested layouts, not a claim that every possible wiki work is complete or uniformly structured. Missing/ambiguous/over-limit contents fail explicitly. A single-page fallback explains its limited scope.

## Reliability implementation

Direct downloads carry an immutable URL order and per-run generation number. A late response from a stopped job cannot append to a replacement job. The next missing section is resumed; completed content is not fetched again.

The last job is stored locally in IndexedDB. Chapter bodies are appended, while the small manifest/progress record is updated. The implementation reads persisted ownership inside the same write transaction and reads metadata plus chapter bodies in one read transaction, preventing mixed-book recovery across tabs. A stale tab cannot replace a newer prefix of the same job. Storage failures are shown instead of claiming successful persistence.

For source-tab capture, the receiver checks the session token, source origin, sequence index, allowed URL and exact ending URL. The collector authenticates its opener, detects full-body duplicates and visited links, and stops at challenges or ambiguous navigation. A partial export is named and labelled partial. Recovered external captures can be saved, but popup connections are not claimed to survive reload.

## Verification record

- Complete Dart suite: 63 tests passed at integration checkpoint, covering discovery, source search/fallback, imports, URL planning, bookmarklet encoding, EPUB XML/metadata and content extraction.
- Collector regressions: 15 passed, including compilation of the actual production-generated generic/personalized bookmarklet URLs.
- Flutter release web build: passed at integration checkpoint.
- W3C EPUBCheck 5.4.0: production-generated English and Russian fixtures, plus the actual browser-downloaded Alice (13 sections) and Onegin (one full-text section), each produced zero errors and zero warnings.
- The desktop/mobile workflow builds this exact branch before running its browser scenarios and retains downloadable EPUBs, screenshots and a structured report. Consult the workflow run for its final result; the existence of the test script is not itself a passing browser result.

Official EPUBCheck release: https://github.com/w3c/epubcheck/releases/tag/v5.4.0 . Downloaded release ZIP SHA256 verified as `33350c61038e71dfb3d45a76aed04bf5481e6d5500cb780f6e98db8bbd15a28c`.

## Remaining boundaries

- WebKit on Linux with an iPhone viewport is not a physical iPhone, iOS Files or Apple Books test.
- Full-book authenticated RanobeLIB capture is not verified.
- An external library link is not an integrated downloader for that library.
- Text EPUB generation does not yet embed cover art, remote illustrations or preserve all original styling.
- Static Flutter cannot guarantee long background execution. Saved progress can also be removed by browser eviction or clearing site data.
- ZIP packaging still runs on the browser main thread; the bounded text workload is practical, but very large/illustrated books would need a measured worker/storage design before increasing limits.

The next useful expansion is another provider with a documented searchable catalogue and allowed text/EPUB delivery, tested as a separate adapter. Adding more arbitrary URL patterns or promising a generic CAPTCHA workaround would not improve reliability.
