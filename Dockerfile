# One-image deployment: Flutter Web is compiled to static assets, while
# Python runs the original MIT-licensed zeroma25 downloader server-side.
FROM ghcr.io/cirruslabs/flutter:stable AS flutter-builder
WORKDIR /build
COPY flutter_app/ ./
RUN flutter pub get && flutter build web --release

FROM python:3.12-slim
ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    RANOBELIB_DOWNLOADER_PATH=/opt/ranobelib-downloader \
    FLUTTER_WEB_DIR=/app/web \
    DOWNLOAD_DIR=/app/exports
RUN apt-get update && apt-get install -y --no-install-recommends git ca-certificates \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY backend/requirements.txt ./requirements.txt
RUN pip install --no-cache-dir -r requirements.txt
# Original project, installed unmodified. This repo is released under MIT.
RUN git clone --depth=1 https://github.com/zeroma25/ranobelib-downloader.git /opt/ranobelib-downloader
COPY backend/ ./backend/
COPY --from=flutter-builder /build/build/web /app/web
RUN mkdir -p /app/exports
EXPOSE 8080
CMD ["uvicorn", "backend.app:app", "--host", "0.0.0.0", "--port", "8080"]
