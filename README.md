# leaf. — Chapter URLs → EPUB, right in Flutter Web

**Live:** https://alex00pirotskyi.github.io/leaf-ranobelib/

A minimal Flutter Web application that turns a range of accessible reading pages into an EPUB. No Python, Render, Docker, or central conversion backend. EPUB generation, chapter ordering, content cleaning, ZIP creation, and local download all run in Dart in your browser.

## The three paths

### A. One click — public Wikisource and Wikibooks chapters

The MediaWiki API supports cross-origin requests when `origin=*` is provided. Paste your first and last chapter URLs (or select the built-in sample), then press **Collect & download EPUB**. Leaf infers changing numeric page IDs, reads chapters sequentially, cleans wiki navigation, and builds the EPUB.

Try these public-domain example URLs:

- First: `https://en.wikisource.org/wiki/Pride_and_Prejudice_(1817)/Chapter_1`
- Last: `https://en.wikisource.org/wiki/Pride_and_Prejudice_(1817)/Chapter_3`

The direct reader supports Wikisource and Wikibooks language subdomains with `/wiki/...` page URLs. It intentionally limits a session to **120 pages** and spaces requests to avoid overwhelming public APIs. Reuse content only in accordance with each source's license and attribution requirements.

### B. Two-click collection — websites that block direct browser reads

A normal GitHub Pages application **cannot read a cross-origin tab**. For other reading sites, Leaf uses a user-activated bookmarklet running inside the site's own browser tab.

**One-time desktop Chrome/Edge setup:**

1. Open the Leaf website. Under **Other websites — setup once**, drag **Leaf Capture** into the bookmarks bar (or use **Copy bookmarklet URL** to create a bookmark manually).
2. Paste the first and last chapter URLs into Leaf and press **Collect & download EPUB**.
3. Leaf opens your first chapter in a normal tab. Log in or solve any CAPTCHA **yourself**, if the website requests it. Then click the **Leaf Capture** bookmark in that tab *once*.
4. The helper uses same-origin page requests with your regular browser session, extracts readable text, and sends chapters to your open Leaf tab. On completion Leaf assembles the EPUB and starts the download.

For simple numbered URLs, intermediate chapter URLs are computed without guessing any other number (IDs and `?bid=` query parameters are preserved). For unnumbered/opaque URLs, the helper looks for the page's **Next** link and stops exactly at the ending URL.

The helper tries static HTML first; if a page requires client-side rendering, it tries a same-origin hidden frame. If it encounters a challenge, blocked response, missing chapter, duplicate content or a rate limit, it stops. You may need to navigate the site manually, re-activate the bookmarklet, or use **Import files** instead.

**Compatibility is site-dependent and not guaranteed.** A website's Content Security Policy can prevent the bookmarklet or loading the helper; its Cross-Origin-Opener-Policy can sever its connection to Leaf. Browser restrictions are respected, not bypassed. This approach is intended for chapters you have the rights and website permission to save. In particular, **RanobeLIB remains unverified with an authenticated live reader**.

The source-tab helper has a small panel with **Pause**, **Resume**, **Pick text area**, and **Export JSON** controls.

### C. Import files — works entirely offline

Choose TXT, HTML, HTM or chapter JSON files you already have permission to use, then click **Create EPUB**. No network, bookmarklet or source website is required.

## Deep research: real source-compatibility audit

Ran on GitHub Actions against **live public endpoints, October 27, 2026**, using the Origin header of Leaf's published website. This tests HTTP/CORS response headers; it is not a guarantee that every individual chapter is available.

| Website | HTTP | CORS exposed to Flutter Web? | Leaf path |
|---|---:|---|---|
| English Wikisource API | 200 | Yes (`*`) | Direct API |
| English Wikibooks API | 200 | Yes (`*`) | Direct API |
| Russian Wikisource API | 200 | Yes (`*`) | Direct API |
| Standard Ebooks public landing page | 200 | Yes (`*`) | Site-dependent (not a chapter API) |
| Project Gutenberg public HTML | 200 | No CORS header | Bookmarklet or official EPUB |
| RanobeLIB chapter API | 403 | No (DDoS-Guard) | Experimental bookmarklet; cannot promise |

Details: [Public-source audit workflow](https://github.com/alex00Pirotskyi/leaf-ranobelib/actions/workflows/source-audit.yml). Wikimedia documents its public CORS API: https://www.mediawiki.org/wiki/API:Cross-site_requests .

## Technical design

```text
Flutter Web — GitHub Pages
  ├── ChapterUrlPlan: single numeric difference or Next-link fallback
  ├── OpenReader: direct public Wikimedia CORS API
  ├── Live bridge: authenticated opener + exact origin + session token
  │      └── user-invoked leaf-capture.js on source site
  │           ├── read visible chapter
  │           ├── fetch sequential same-origin pages (bounded & paced)
  │           ├── SPA render fallback, pause on blockers
  │           └── postMessage chapters back to the Leaf tab
  ├── LocalImporter: TXT / HTML / JSON
  └── EpubBuilder: clean XHTML + OPF/nav/NCX + ZIP/mimetype → .epub
```

All chapter transfer is directly **browser-to-browser using `postMessage`** with an explicit receiver origin and a per-session random token. The app verifies each page URL and chapter index before accepting it. Text is not transmitted to Leaf's GitHub repository, a Python backend or a third-party conversion service.

Static files:

- `flutter_app/lib/main.dart` — Flutter UI, download and guarded session receiver
- `flutter_app/lib/core/chapter_url_plan.dart` — bounded numeric URL inference
- `flutter_app/lib/core/open_reader.dart` — Wikimedia API adapter
- `flutter_app/web/leaf-capture.js` — optional user-invoked, in-page helper
- `flutter_app/lib/core/epub_builder.dart` — EPUB packager and HTML sanitizer
- `flutter_app/lib/core/local_importer.dart` — local-file fallback
- `flutter_app/test/` — reproducible Dart tests
- `scripts/browser-smoke.cjs` — real Chromium test of live Pages
- `flutter_app/web/fixtures/` — original sample chapters for bridge testing

## Tests and deployment

The GitHub Pages workflow runs the EPUB and reading tests, validates the in-page JavaScript syntax, compiles Flutter Web and deploys the artifact under `/leaf-ranobelib/`. The separately runnable live Chromium smoke test attempts one-click Wikisource → EPUB and source-tab capture → EPUB, and inspects the resulting ZIPs. Test outcomes are published in GitHub Actions.

Local development needs only Flutter, no Docker:

```bash
make setup
make test
make dev
make build
```

## Constraints

- External images and cover art are omitted in the current text-focused EPUB generator.
- External reading sites can change their DOM, access rules, and rate limits. No tool can guarantee bulk chapter collection from every website.
- Bookmarklet installation works best on desktop browsers. On iPhone Safari it may require manual bookmark editing and can be restricted.
- The browser may block automatic downloads not initiated by a direct user gesture; the **Download EPUB again** button is available if that happens.
- Respect copyright and website terms. A CAPTCHA may be solved by the user on the site, but this project neither automatically solves CAPTCHAs nor bypasses paywalls or restricted chapters.

Independent learning project, not affiliated with any reading provider.
