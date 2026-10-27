# Leaf — Flutter Web only. No Python backend, Docker or Render.
# On GitHub, pushes to flutter_app/ automatically deploy the Pages project.
.DEFAULT_GOAL := help
SHELL := /bin/sh

FLUTTER ?= flutter
GITHUB_OWNER ?= alex00Pirotskyi
REPO_NAME ?= leaf-ranobelib
REPO := $(GITHUB_OWNER)/$(REPO_NAME)
PAGES_URL := https://alex00pirotskyi.github.io/$(REPO_NAME)/

.PHONY: help setup dev web test check build pages-enable deploy github-push git-status clean

help: ## Show available targets (no Docker required)
	@echo 'Leaf — pure Flutter / Dart'
	@echo 'Website: $(PAGES_URL)'
	@echo 'make setup       Prepare Flutter Web project'
	@echo 'make dev         Run browser development build'
	@echo 'make test        Test EPUB creation'
	@echo 'make check       Analyze source code'
	@echo 'make build       Build static GitHub Pages bundle'
	@echo 'make deploy      Trigger GitHub Pages workflow via GitHub CLI'
	@echo 'make github-push Push your main branch'

setup: ## Initialize Flutter project and dependencies
	cd flutter_app && $(FLUTTER) create --platforms=web --project-name=leaf_reader . && $(FLUTTER) pub get

dev: ## Start Flutter Web in Chrome
	cd flutter_app && $(FLUTTER) run -d chrome

web: dev

test: ## Run Dart EPUB tests
	cd flutter_app && $(FLUTTER) test test/epub_builder_test.dart

check: ## Static analysis
	cd flutter_app && $(FLUTTER) analyze lib

build: ## Build for GitHub Pages project URL
	cd flutter_app && $(FLUTTER) build web --release --base-href="/$(REPO_NAME)/"

pages-enable: ## One-time enable GitHub Actions deployment source
	@gh api -X PUT "repos/$(REPO)/pages" -f build_type=workflow >/dev/null || \
	gh api -X POST "repos/$(REPO)/pages" -f build_type=workflow >/dev/null
	@echo 'GitHub Pages workflow enabled.'

deploy: ## Trigger build and publish (GitHub CLI required)
	gh workflow run pages.yml --repo "$(REPO)" --ref main
	@echo 'Track deployment: https://github.com/$(REPO)/actions'

github-push: ## Push current main branch to GitHub
	git push origin main

git-status: ## Inspect Git state
	git status -sb

clean: ## Delete locally generated Flutter outputs
	rm -rf flutter_app/build flutter_app/.dart_tool
