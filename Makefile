# Leaf - RanobeLIB to EPUB
# Quick start: `make` (or `make up`) builds and starts the Docker app.
# Run `make help` to see the full command list.
.DEFAULT_GOAL := up

SHELL := /bin/sh

GITHUB_OWNER ?= alex00Pirotskyi
REPO_NAME ?= leaf-ranobelib
PAGES_REPO := $(GITHUB_OWNER).github.io
LEAF_API_URL ?=
GITHUB_REPO := $(GITHUB_OWNER)/$(REPO_NAME)
GITHUB_REMOTE := https://github.com/$(GITHUB_REPO).git
PYTHON ?= python3
VENV_PYTHON := .venv/bin/python
DEV_PYTHON := $(if $(wildcard $(VENV_PYTHON)),$(VENV_PYTHON),$(PYTHON))
COMPOSE ?= docker compose
FLUTTER ?= flutter

.PHONY: up start down stop restart rebuild logs ps health setup backend web dev build-web test git-status git-remote github-create github-push pages-restore-repo pages-enable publish-pages pages-api-url pages-open clean help

up: ## Build and start app (http://localhost:8080)
	$(COMPOSE) up --build -d
	@printf '\nLeaf: http://localhost:8080\n'

start: ## Start previously created containers
	$(COMPOSE) up -d

down: ## Stop containers; keep downloaded files and chapter cache
	$(COMPOSE) down

stop: down

restart: ## Restart the running container
	$(COMPOSE) restart leaf

rebuild: ## Rebuild and start (pull fresh base images when available)
	$(COMPOSE) build --pull
	$(COMPOSE) up -d

logs: ## Follow application logs
	$(COMPOSE) logs --follow --tail=100 leaf

ps: ## Show Docker container status
	$(COMPOSE) ps

health: ## Check application health
	@curl --fail --silent --show-error http://localhost:8080/api/health; printf '\n'

setup: ## Clone the original downloader and install Python dependencies
	./setup.sh

backend: ## Start backend locally at http://localhost:8000 (after `make setup`)
	./run_backend.sh

web: ## Start Flutter Web dev server in Chrome (after `make setup`)
	cd flutter_app && $(FLUTTER) pub get && $(FLUTTER) run -d chrome --dart-define=API_BASE_URL=http://localhost:8000

dev: ## Start backend and Flutter together (Ctrl+C to stop)
	$(MAKE) -j2 backend web

build-web: ## Compile the Flutter Web release bundle
	cd flutter_app && $(FLUTTER) pub get && $(FLUTTER) build web --release

test: ## Run backend unit tests (install requirements-dev.txt if necessary)
	$(DEV_PYTHON) -m pytest backend/tests -q

git-status: ## Show current Git status
	git status --short --branch

git-remote: ## Display the configured GitHub remote
	git remote -v

github-create: ## Create a PRIVATE GitHub repo and push (needs gh auth login)
	@command -v gh >/dev/null 2>&1 || { echo 'GitHub CLI missing: install https://cli.github.com/'; exit 1; }
	@gh auth status >/dev/null 2>&1 || { echo 'Run: gh auth login'; exit 1; }
	@if gh repo view "$(GITHUB_REPO)" >/dev/null 2>&1; then \
		echo 'GitHub repository already exists: $(GITHUB_REPO)'; \
	else \
		gh repo create "$(GITHUB_REPO)" --private --description 'Leaf: Flutter Web UI for RanobeLIB to EPUB'; \
	fi
	@git remote set-url origin "$(GITHUB_REMOTE)"
	@git push --set-upstream origin main

# Use when the repo already exists (created in the GitHub web UI).
github-push: ## Push main to the configured origin
	@git push --set-upstream origin main

pages-restore-repo: ## Restore original leaf-ranobelib repository name (one-time recovery)
	@gh auth status >/dev/null 2>&1 || { echo "Run: gh auth login"; exit 1; }
	@if [ "$$(gh repo view "$(GITHUB_OWNER)/$(REPO_NAME)" --json name --jq .name 2>/dev/null)" = "$(REPO_NAME)" ]; then \
		echo "Repository name is already $(REPO_NAME)"; \
	else \
		gh repo rename "$(REPO_NAME)" --repo "$(GITHUB_OWNER)/$(PAGES_REPO)" --yes; \
	fi
	@git remote set-url origin "$(GITHUB_REMOTE)"
	@echo "Repository: https://github.com/$(GITHUB_REPO)"

pages-enable: ## Enable GitHub Pages for the project repository and start the Flutter build
	@gh auth status >/dev/null 2>&1 || { echo "Run: gh auth login"; exit 1; }
	@if gh api "repos/$(GITHUB_REPO)/pages" >/dev/null 2>&1; then \
		gh api -X PUT "repos/$(GITHUB_REPO)/pages" -f build_type=workflow >/dev/null; \
	else \
		gh api -X POST "repos/$(GITHUB_REPO)/pages" -f build_type=workflow >/dev/null; \
	fi
	@gh workflow run pages.yml --repo "$(GITHUB_REPO)" --ref main
	@echo "Pages workflow: https://github.com/$(GITHUB_REPO)/actions"

publish-pages: pages-restore-repo pages-enable ## Restore repo name and deploy to PROJECT Pages (no username-site rename)

pages-api-url: ## Set API URL used by Flutter release; e.g. make pages-api-url LEAF_API_URL=https://api.example.com
	@test -n "$(LEAF_API_URL)" || { echo "Missing LEAF_API_URL=https://your-backend.onrender.com"; exit 1; }
	@gh variable set LEAF_API_URL --body "$(LEAF_API_URL)" --repo "$(GITHUB_REPO)"

pages-open: ## Show project GitHub Pages URL
	@echo "https://$(shell echo $(GITHUB_OWNER) | tr '[:upper:]' '[:lower:]').github.io/$(REPO_NAME)/"

clean: ## Remove generated local files only (never Docker volumes)
	rm -rf flutter_app/build flutter_app/.dart_tool .pytest_cache

help: ## List Makefile commands
	@printf 'Leaf - RanobeLIB to EPUB\n\n'
	@printf 'Quick start: make          -> build and run http://localhost:8080\n\n'
	@awk 'BEGIN {FS = ":.*## "} /^[a-zA-Z0-9_-]+:.*## / {printf "  %-18s %s\n", $$1, $$2}' $(MAKEFILE_LIST)
