# leaf. — Find a book. Take it with you.

**App:** https://alex00pirotskyi.github.io/leaf-ranobelib/

Leaf is a Flutter web app for finding Russian and English reading material and preparing EPUBs on the reader's device. It runs on GitHub Pages without a conversion server or browser extension.

## The main experience

1. Open **Find a book**, choose **Русский**, **English**, or **All books**.
2. Search by title/author, paste a supported edition URL, or tap a featured book.
3. Leaf discovers the source's contents, downloads the selected reading sections, and builds an EPUB locally.
4. Desktop browsers receive a download and a **Download EPUB again** button. On a phone, tap **Save EPUB** when ready. **Share / open in a reader** appears only when the browser can share the actual EPUB file.

Featured books include **Капитанская дочка**, **Евгений Онегин**, **Alice's Adventures in Wonderland**, and a source-provided **Pride and Prejudice** EPUB. The Gutenberg card opens the provider's existing file; it does not scrape chapters or pretend Leaf has inspected an external download.

## What is integrated

| Source | Search in Leaf | Acquisition |
|---|---|---|
| Russian Wikisource / Викитека | Yes; title-prefix fallback if full-text search is busy | Discover edition contents and build EPUB locally |
| English Wikisource | Yes | Discover edition contents and build EPUB locally |
| Wikibooks | Paste a supported book/chapter URL | Same public API reading adapter |
| Project Gutenberg | Featured direct EPUB plus library link | Source-native EPUB download |
| Standard Ebooks, Open Library | Library directory | Open the provider to find editions and available downloads |
| RanobeLIB, Author.Today, Royal Road | Library directory | Source website; permitted local file import; optional experimental capture where compatible |

The **Explore book libraries** directory labels external discovery separately from integrated reading. A catalogue listing does not mean that every title can be downloaded automatically.

## Automatic chapter discovery

Leaf follows the reading order in a source's actual contents, including named/Roman chapters and nested volumes. It does not assume that incrementing a number means the whole book has been found. A title page that lists different editions is rejected rather than merging incompatible versions.

Verified real source responses produced:

- **Капитанская дочка**, 1960 edition: 16 sections — 14 chapters, appendix, and substantive text/notes on the contents page.
- **Евгений Онегин**, 1959 edition: one full-text source page.
- **Alice**, 1866 edition: 13 sections — opening poem plus 12 chapters.
- **Pride and Prejudice**, 1817 edition: 61 chapters.

The automatic adapter stops explicitly at more than 500 sections, 64 contents pages, or eight nested levels. Missing pages, circular contents, unsupported edition indexes, and known incomplete editions are errors, not silently shortened books. A conservative single-page result explains its scope.

## Recovery and phones

Each completed direct-API section is saved in IndexedDB. **Pause download**, a full reload, and **Continue saved book** preserve downloaded content and resume at the next missing section. Metadata and chapter bodies are read/written atomically, and new chapter bodies are appended rather than rewriting an entire long book after every request. Storage errors are visible.

Keep the browser open for long downloads: phones can suspend background tabs. Saving progress makes interruptions recoverable; it does not create background execution privileges. Private browsing, quota limits, clearing site data, or browser eviction can remove local progress.

Captured chapters from an external source tab can be **recovered** after reloading Leaf, but the old popup/session connection cannot be reconstructed. Those chapters can be exported as a clearly marked partial EPUB.

Mobile saving needs a deliberate tap after a long job. EPUB file sharing is feature-detected with the actual file; it is never assumed from the presence of `navigator.share` alone.

## Manual chapter links and imports

**Chapter links** accepts a first and last HTTPS chapter URL. A single recognizable changing chapter/page number may generate a bounded range; opaque URLs use explicit Next links through the optional source-tab collector. Book IDs, percent-encoded Cyrillic, query IDs, and browser hash routes are not guessed as chapter numbers.

**Import files** accepts TXT, HTML/HTM, and chapter JSON. Files are ordered naturally (`1, 2, 10`), decoded as strict UTF-8, and validated before conversion. Invalid or missing chapter text rejects the batch. JSON metadata, language, expected chapter count, and `complete:false` survive import. Re-selecting files replaces the selection rather than silently duplicating it.

Limits: 16 MB per file, 64 MB per import, 500 imported chapters. Limits produce errors instead of truncation.

## CAPTCHA and other websites

A normal web app cannot read another origin's tab or iframe. Opening a website and solving its CAPTCHA does not remove browser CORS/same-origin restrictions.

The existing **Leaf Capture** bookmarklet is an optional, user-activated collector that runs on the source page. It may work on compatible accessible sites, but a source can block it through its access controls, CSP, COOP, or page structure. It stops on challenges, rate limits, duplicate bodies, loops, ambiguous Next links, or oversized chapters. It neither solves CAPTCHAs nor bypasses access restrictions.

Desktop capture and the personalized iPhone Safari bookmark remain experimental. On Android, unsupported external sources lead to an explicit import path, not desktop drag-to-bookmark instructions or a fictitious collection spinner. Integrated library downloads work directly on phone and desktop.

**RanobeLIB authenticated full-book capture remains unverified.** Do not advertise universal one-click downloads from arbitrary sites.

### Chapter text extraction and duplicate recovery (October 28, 2026)

The optional **Leaf Capture** bookmarklet now selects reader/chapter prose first
instead of choosing the longest HTML container. It removes navigation, related
books, settings, comments, advertising and toolbars before scoring candidate
regions. It also recognizes RanobeLIB-style
`[data-reader-content] .text-content` markup when the accessible reading page
actually contains that element.

If the static HTML serves yesterday's chapter or a shared application shell,
Leaf checks the site's rendered page and waits for stable **new** text before
accepting the chapter. If a real duplicate is still found, the collector keeps
previous chapters and offers:

- **Preview text** — inspect the detected title, paragraph count and sample
  prose; verify it is not the site's menu.
- **Pick text area** — click inside the actual novel text, then **Resume**.
- **Keep duplicate once** — only when you confirm the chapter intentionally
  repeats the previous text. There is no silent skipping or false completion.

**After updating:** refresh Leaf, replace any old *self-contained* bookmarklet,
and reload the source chapter tab before retrying. The regular bookmarklet now
uses a versioned script URL to avoid stale browser caching. Running an older
in-page helper in an already-open tab does not magically update that tab.

The [desktop/mobile GitHub Actions suite](https://github.com/alex00Pirotskyi/leaf-ranobelib/actions/runs/40639956369)
verified 17 collector regressions and a real Chromium test of three noisy
chapter pages, including identical site boilerplate and a second chapter that
only becomes unique after JavaScript hydration. RanobeLIB authenticated
full-book collection itself remains unverified.

## EPUB quality

The Dart builder creates EPUB 3 with the correct source language, a unique identifier, actual UTC modification time, and consistent navigation/spine metadata. Sanitized XHTML preserves paragraphs, emphasis, lists, quotations, tables, superscripts and preformatted text. External images are represented by placeholders; cover art and original page styling are not bundled.

EN and RU production-generated fixtures passed official **W3C EPUBCheck 5.4.0** with zero errors and zero warnings. See [the research and validation notes](docs/reading-experience-research.md) for scope and evidence.

## Development and checks

Flutter is pinned to **3.47.8** in CI; application dependencies are locked.

```bash
make setup
make test
make dev
make build
```

Additional collector regressions compile the actual copied desktop/Safari bookmarklets, not merely the raw helper source:

```bash
node scripts/capture-regression.cjs
```

The **Desktop and mobile reading checks** workflow builds the exact source under review and tests it in Chromium desktop, an Android viewport, and the WebKit engine with an iPhone viewport. It exercises discovery, search fallback, pause/reload/resume, manual links, import, mobile saving, and actual EPUB ZIP/XML/content checks. It keeps screenshots, downloaded books, and test reports as workflow artifacts. WebKit emulation is not a physical iPhone/Apple Books test.

The Pages workflow runs the complete Dart suite and collector regressions before deploying `main` to the existing project URL.
