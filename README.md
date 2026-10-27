# Leaf — Flutter Web EPUB Maker

A minimalist, browser-only EPUB maker built with **Flutter and Dart**.

**Live project:** https://alex00pirotskyi.github.io/leaf-ranobelib/

No Python backend, Docker, Render, login, cookies, or cloud processing. The EPUB ZIP is assembled locally in the browser using the Dart [archive](https://pub.dev/packages/archive) package.

## What works

- **Import chapters:** choose one or more UTF-8 TXT, HTML, HTM, or JSON files. Each file becomes one chapter. JSON may also contain an array of chapters or a `{"chapters":[...]}` object.
- **Create EPUB 3:** Russian text, title and author, table of contents, accessible XHTML chapters, local EPUB file download.
- **Privacy:** text you import is never uploaded. All processing stays in the tab.
- **RanobeLIB URL mode:** attempts direct calls to RanobeLIB's public chapter API, with translation selection, chapter ranges, and sequential downloads; only usable **when the source allows CORS requests**.

### Important limitation: RanobeLIB blocks direct browser downloads

We verified the real upstream API from a GitHub Actions runner on October 27, 2026. Requests to `https://api.cdnlibs.org/api/manga/...` received HTTP **403** from DDoS-Guard with **no `Access-Control-Allow-Origin` header**, including OPTIONS preflight.

**Flutter cannot override the browser's CORS security rules.** The link-based mode is intentionally experimental and currently unlikely to work on GitHub Pages. There is **no proxy** and no promise of downloading the book directly from the URL. Use the file-import mode with chapters you have permission to save. Copying or saving material still requires appropriate rights/authorization.

The app currently creates **text-only EPUBs**: external image and cover downloads are not supported by the browser-only build.

## Local development (optional)

Requires Flutter SDK; you do **not** need Docker/Python.

```sh
make setup
make dev
```

To test and compile:

```sh
make test
make build
```

The repository has a GitHub Actions workflow at `.github/workflows/pages.yml` which runs Dart EPUB tests and builds the project site automatically when Flutter files change. Run `make deploy` to trigger deployment manually using the authenticated GitHub CLI. Your project is hosted at the **project path** `/leaf-ranobelib/`, not at the account-root website.

## Layout

```text
flutter_app/
  lib/
    main.dart                   Flutter interface and local browser download
    core/
      ranobe_client.dart        Direct RanobeLIB API client, when CORS permits
      local_importer.dart       User-selected local TXT/HTML/JSON chapters
      epub_builder.dart         Pure Dart EPUB 3 packaging
  test/
    epub_builder_test.dart      EPUB integrity, markup safety, URL validation
.github/workflows/pages.yml    Build, test, and deploy Flutter Web
Makefile                        Development and deployment commands
```

## EPUB details

EPUB 3, `mimetype` stored as the first and uncompressed ZIP entry, required container XML, OPF manifest/spine, accessible EPUB navigation document, NCX compatibility document, and one XHTML file per chapter. Imported HTML is sanitized to safe reading markup (scripts, embeds, and remote resources are excluded).

## FAQ

**Why does the link return HTTP 403/CORS?** The restriction originates from RanobeLIB's website or its protective CDN, not from Flutter or GitHub Pages. Browser-only applications cannot read responses when the remote server disallows cross-origin access.

**Why not a server?** This version deliberately does not use one. Local import works offline after the web app is loaded, including on iPhone Safari for supported file types.

**Can it save illustrations?** Not currently. Text and navigation are supported; image embedding would require images chosen locally or permission to download remote image bytes.

**Is it official?** No. This project is independent of RanobeLIB.
