#!/usr/bin/env sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
export RANOBELIB_DOWNLOADER_PATH="$ROOT/upstream"
export DOWNLOAD_DIR="$ROOT/exports"
cd "$ROOT"
exec "$ROOT/.venv/bin/uvicorn" backend.app:app --host 127.0.0.1 --port 8000
