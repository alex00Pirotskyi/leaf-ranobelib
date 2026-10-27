# Leaf — RanobeLIB → EPUB (Flutter Web)

A compact, responsive, Kindle-inspired web interface for [zeroma25/ranobelib-downloader](https://github.com/zeroma25/ranobelib-downloader), using its **real Python downloader and EPUB creator**, not a fake/mock conversion. The upstream code is MIT-licensed and is cloned unmodified on setup. UI language: English. Works on iPhone Safari or desktop when hosted.

**Features:** paste a link; inspect book metadata and translation branches; choose all/last 50/a custom chapter range; optional cover, images, chapter caching; watch per-chapter progress; cancel; download an actual EPUB file.

The user-provided book URL is already prefilled in the Flutter interface.

## One-command start (Makefile)

The project is initialized as a Git repository (branch `main`) with a configured
GitHub remote:

`https://github.com/alex00Pirotskyi/leaf-ranobelib.git`

**Note:** This is the configured *destination*, not yet a created GitHub repository.
Create it using one of the methods below before pushing.

```sh
make            # builds and runs the app using Docker, in the background
make help       # all available commands
make logs       # follow server logs
make down       # stop containers without deleting the cache
make test       # backend tests (after make setup, or if deps are installed)
```

### Publish to GitHub

The repository is configured to be **private** by default to avoid publishing
personal code accidentally. There are two ways to create the remote:

**Option 1 — GitHub web interface (no GitHub CLI required)**

1. Open [GitHub: create `leaf-ranobelib`](https://github.com/new?name=leaf-ranobelib&visibility=private).
2. Make the owner `alex00Pirotskyi` and choose **Private**.
3. Do not add a README, license or `.gitignore` (they are already in the project).
4. From this project folder, run `make github-push` (Git authentication is required).

**Option 2 — GitHub CLI**

```sh
gh auth login          # one-time setup if not already authenticated
make github-create    # creates a PRIVATE repo and pushes `main`
```

To target another GitHub account or repo, supply variables:

```sh
make github-create GITHUB_OWNER=my-account REPO_NAME=my-repo
```

This project has no GitHub authentication credentials or tokens built in.

## Fastest setup: Docker

Requires Docker + Docker Compose, and internet access during build and when retrieving chapters.

```sh
make
# Equivalent to: docker compose up --build -d
```

Open **http://localhost:8080** on the computer hosting Docker. The app and API are served from the **same origin** (no CORS configuration required). For access from iPhone, serve it over HTTPS behind a proxy (e.g. Caddy) or change the Compose port binding to `8080:8080` for temporary access from the same Wi-Fi. **Do not publicly expose this anonymous downloader without authentication / access control.**

You can check `http://localhost:8080/api/health` to see whether the backend is running and the Python downloader was installed.

## Run without Docker (development)

Requires Python 3.10+, Git and a supported Flutter SDK (Flutter 3.22+ with Dart 3.4+). On the project root:

```sh
./setup.sh
./run_backend.sh
```

In another terminal:

```sh
cd flutter_app
flutter pub get
flutter run -d chrome --dart-define=API_BASE_URL=http://localhost:8000
```

To build your own release web bundle:

```sh
cd flutter_app
flutter pub get
flutter build web --release --dart-define=API_BASE_URL=https://your-domain.example
```

If your Flutter SDK expects web scaffolding files, run `flutter create --platforms web .` **inside `flutter_app/`** (does not change `lib/main.dart`) before building. A basic `web/index.html` and `web/manifest.json` are already provided.

### Serve a release bundle from Python

You can also serve a compiled web bundle + API in one Python process:

```sh
RANOBELIB_DOWNLOADER_PATH="$PWD/upstream" \
FLUTTER_WEB_DIR="$PWD/flutter_app/build/web" \
DOWNLOAD_DIR="$PWD/exports" \
.venv/bin/uvicorn backend.app:app --host 127.0.0.1 --port 8080
```

For a secure HTTPS deployment, configure a reverse proxy and limit access to your own device/account. A web server is required: **Flutter Web alone cannot execute Python** or work around browser CORS. It is not compatible with a static-only Cloudflare Workers deployment by itself.

## How it works

```text
Flutter Web (mobile/desktop)
    └── POST /api/book/inspect           preview book + translation branches
    └── POST /api/jobs                   create export
    └── GET  /api/jobs/{id}              progress polling
    └── POST /api/jobs/{id}/cancel       cancel export
    └── GET  /api/jobs/{id}/file         download EPUB
                │
                ▼
FastAPI (one export worker, rate limit handled by upstream)
                │
                ▼
zeroma25/ranobelib-downloader (unmodified Python src/)
                └── RanobeLibAPI → ContentProcessor → EpubCreator
```

Downloads are stored per export in `DOWNLOAD_DIR/{job_id}` and are eligible for cleanup after one hour. The worker is serialized because the upstream library uses process-global settings/cache. Repeated chapters can reuse the upstream chapter cache. A new export can be queued while another one is running.

### Limitations

- Publicly accessible chapters only in this version. The upstream application supports login, but this web wrapper **intentionally doesn't handle credentials**. Paid, hidden, licensed or otherwise inaccessible chapters cannot be downloaded or bypassed.
- The original project and the RanobeLIB API can change, reject requests, rate limit, or become unavailable. The app surfaces those errors rather than pretending the export succeeded.
- Not an official RanobeLIB application. Respect the rights of authors/translators and the website's terms; export only material you have permission to save.
- iOS Safari downloads usually appear in Files. Tap the EPUB and use Share → Books to read it in Apple Books.

## Testing

```sh
make test
```

Tests use mocks to check API behavior and downloader integration wiring; live site connectivity and compiling Flutter Web must be checked on a host with internet and Flutter installed.

## Credits

The EPUB conversion implementation comes from the original open-source [RanobeLIB Downloader](https://github.com/zeroma25/ranobelib-downloader) (MIT). This app is an independent web UI and API bridge.
