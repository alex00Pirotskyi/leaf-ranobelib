#!/usr/bin/env sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PYTHON=${PYTHON:-python3}
if ! command -v git >/dev/null 2>&1; then
  echo 'Git is required.' >&2
  exit 1
fi
if [ ! -f "$ROOT/upstream/src/api.py" ]; then
  git clone --depth 1 https://github.com/zeroma25/ranobelib-downloader.git "$ROOT/upstream"
fi
"$PYTHON" -m venv "$ROOT/.venv"
"$ROOT/.venv/bin/pip" install --upgrade pip
"$ROOT/.venv/bin/pip" install -r "$ROOT/backend/requirements-dev.txt"
echo 'Setup complete. Run ./run_backend.sh and then start Flutter Web.'
