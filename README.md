# Leaf — RanobeLIB → EPUB (Flutter Web)

A compact, responsive, Kindle-inspired web interface for [zeroma25/ranobelib-downloader](https://github.com/zeroma25/ranobelib-downloader), using its **real Python downloader and EPUB creator**, not a fake/mock conversion. The upstream code is MIT-licensed and is cloned unmodified on setup. UI language: English. Works on iPhone Safari or desktop when hosted.

**Features:** paste a link; inspect book metadata and translation branches; choose all/last 50/a custom chapter range; optional cover, images, chapter caching; watch per-chapter progress; cancel; download an actual EPUB file.

The user-provided book URL is already prefilled in the Flutter interface.

## Deploy on the public internet (GitHub Pages + Render)

**GitHub Pages cannot execute Python.** This project uses GitHub Pages for the Flutter Web frontend and a separate Docker web service for the original EPUB downloader. A public frontend without a reachable API can display, but cannot download books.

### 1. Put this site at https://alex00pirotskyi.github.io/

Your existing repository is `alex00Pirotskyi/leaf-ranobelib`. Rename it to
`alex00Pirotskyi.github.io` at GitHub **Settings → General → Repository name**.
Or, with GitHub CLI installed and logged in, run:

```powershell
make github-rename-pages
```

This is a **username-site** repository name; keeping the name `leaf-ranobelib` gives the project URL `https://alex00pirotskyi.github.io/leaf-ranobelib/` instead. The Pages workflow supports both cases.

**GitHub Pages on private repositories depends on your plan/permissions.**
If Pages is unavailable for this private repository, make it public deliberately
or use an alternative static host. Do not commit any secrets.

In repository **Settings → Pages**, choose **Build and deployment → Source: GitHub Actions**.
The workflow `.github/workflows/pages.yml` builds and deploys Flutter Web on
push to `main`. The first run can also be triggered manually from **Actions → Deploy Flutter Web to GitHub Pages → Run workflow**.

### 2. Host the Python backend

A `render.yaml` Blueprint is included for a Docker web service at Render.
In your Render dashboard, create a Blueprint from the GitHub repository.
Authorize Render for this private repo and select the Blueprint. The default is
the paid `starter` plan; inspect Render's current prices before confirming.
Your URL will resemble `https://leaf-ranobelib-api.onrender.com`, but **use the
actual URL Render assigns**, not this example.

The service must have environment variable:

```text
LEAF_ALLOWED_ORIGINS=https://alex00pirotskyi.github.io
```

If keeping the original project path, this is still the correct origin.
The backend is anonymous by design and can consume compute/bandwidth; use
network/access controls or an authentication layer if you expose it publicly.
CORS is not authentication.

### 3. Link the Flutter build to your backend

From the GitHub repository, go to **Settings → Secrets and variables → Actions →
Variables → New repository variable**. Set:

- Name: `LEAF_API_URL`
- Value: the Render HTTPS backend origin (no trailing slash), e.g. `https://your-service.onrender.com`

Or use:

```powershell
make pages-api-url LEAF_API_URL=https://your-actual-service.onrender.com
```

Trigger **Actions → Deploy Flutter Web to GitHub Pages → Run workflow** again after
the variable is set. Visit `https://alex00pirotskyi.github.io/` once both
deployments are healthy. If you did not rename the repository, use
`https://alex00pirotskyi.github.io/leaf-ranobelib/`.

**Local Windows error `make: docker: No such file or directory`:** Docker Desktop
is missing/not in PATH. Docker is only needed for local `make`. The GitHub
Actions frontend build and Render backend deployment do not need Docker
installed on your own computer.

---

## One-command start (Makefile)

The project is initialized as a Git repository (branch `main`) with a configured
GitHub remote:

`https://github.com/alex00Pirotskyi/leaf-ranobelib.git`

**Note:** This repository has already been created and pushed to GitHub. See the public deployment guide above for Pages setup.

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
