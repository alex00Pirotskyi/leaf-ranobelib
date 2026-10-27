"""Private single-user HTTP API for the Flutter reader UI."""
from __future__ import annotations

import os
import shutil
import threading
import time
import uuid
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass, field
from pathlib import Path
from typing import Literal

from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel, Field

from . import engine

BASE = Path(os.environ.get("DOWNLOAD_DIR", "/tmp/ranobe-reader-exports"))
executor = ThreadPoolExecutor(max_workers=1, thread_name_prefix="epub")
lock = threading.RLock()
jobs: dict[str, "Job"] = {}
MAX_JOBS = 30

app = FastAPI(title="Leaf · RanobeLIB to EPUB", docs_url="/api/docs", redoc_url=None)
_allowed_origins = [
    origin.strip().rstrip("/")
    for origin in os.getenv("LEAF_ALLOWED_ORIGINS", "").split(",")
    if origin.strip()
]

app.add_middleware(
    CORSMiddleware,
    allow_origins=_allowed_origins,
    allow_origin_regex=r"^https?://(localhost|127\.0\.0\.1)(:\d+)?$",
    allow_methods=["GET", "POST"],
    allow_headers=["Content-Type"],
)


class BookRequest(BaseModel):
    url: str = Field(min_length=1, max_length=2048)


class ExportRequest(BookRequest):
    branch: str = "default"
    start: int = Field(default=1, ge=1)
    end: int | None = Field(default=None, ge=1)
    cover: bool = True
    images: bool = True
    cache: bool = True


@dataclass
class Job:
    id: str
    status: Literal["queued", "running", "complete", "error", "canceled"] = "queued"
    stage: str = "Waiting for worker"
    progress: int = 0
    total: int = 0
    filename: str | None = None
    file_path: str | None = None
    error: str | None = None
    created: float = field(default_factory=time.monotonic)
    cancel_requested: bool = False
    api: object | None = None

    def public(self) -> dict:
        return {
            "id": self.id, "status": self.status, "stage": self.stage,
            "progress": self.progress, "total": self.total,
            "filename": self.filename, "error": self.error,
            "download_url": f"/api/jobs/{self.id}/file" if self.status == "complete" else None,
        }


def _get_job(job_id: str) -> Job:
    with lock:
        job = jobs.get(job_id)
        if job is None:
            raise HTTPException(404, "Job not found or expired")
        return job


def _clean_old_jobs():
    """Remove expired artifacts, without touching active jobs."""
    now = time.monotonic()
    with lock:
        expired = [k for k, v in jobs.items() if
                   v.status in ("complete", "error", "canceled") and
                   now - v.created > 3600]
        for k in expired:
            jobs.pop(k)
            shutil.rmtree(BASE / k, ignore_errors=True)


def _run_job(job_id: str, spec: ExportRequest) -> None:
    with lock:
        job = jobs[job_id]
        if job.cancel_requested:
            job.status = "canceled"
            job.stage = "Canceled"
            return
        job.status = "running"
        job.stage = "Fetching metadata"

    def on_progress(current: int, total: int, stage: str):
        with lock:
            job.progress = current
            job.total = total
            job.stage = stage

    def should_cancel() -> bool:
        with lock:
            return job.cancel_requested

    def set_cancel_api(api):
        with lock:
            job.api = api

    try:
        filename = engine.generate_epub(
            url=spec.url, branch=spec.branch, start=spec.start, end=spec.end,
            cover=spec.cover, images=spec.images, cache=spec.cache,
            output_dir=BASE / job_id,
            on_progress=on_progress,
            should_cancel=should_cancel,
            set_cancel_api=set_cancel_api,
        )
        with lock:
            if job.cancel_requested:
                job.status = "canceled"
                job.stage = "Canceled"
            else:
                job.filename = filename.name
                job.file_path = str(filename)
                job.status = "complete"
                job.stage = "Your EPUB is ready"
    except Exception as exc:
        with lock:
            if job.cancel_requested:
                job.status = "canceled"
                job.stage = "Canceled"
            else:
                job.status = "error"
                job.stage = "Export failed"
                job.error = str(exc)[:400]
    finally:
        with lock:
            job.api = None
            remove = job.status != "complete"
        if remove:
            shutil.rmtree(BASE / job_id, ignore_errors=True)


@app.get("/api/health")
def health():
    return {"status": "ok", "downloader_installed": (engine.UPSTREAM / "src" / "api.py").exists()}


@app.post("/api/book/inspect")
def inspect(payload: BookRequest):
    try:
        engine.validate_url(payload.url)
        return engine.inspect_book(payload.url)
    except engine.InputError as exc:
        raise HTTPException(422, str(exc)) from exc
    except Exception as exc:
        raise HTTPException(502, f"RanobeLIB is unavailable: {exc}") from exc


@app.post("/api/jobs", status_code=202)
def start_export(payload: ExportRequest):
    try:
        engine.validate_url(payload.url)
    except engine.InputError as exc:
        raise HTTPException(422, str(exc)) from exc
    _clean_old_jobs()
    with lock:
        if len(jobs) >= MAX_JOBS:
            raise HTTPException(429, "Too many jobs; try again after an older export expires.")
        job_id = uuid.uuid4().hex
        job = Job(id=job_id)
        jobs[job_id] = job
    executor.submit(_run_job, job_id, payload)
    return job.public()


@app.get("/api/jobs/{job_id}")
def status(job_id: str):
    return _get_job(job_id).public()


@app.post("/api/jobs/{job_id}/cancel")
def cancel(job_id: str):
    job = _get_job(job_id)
    with lock:
        if job.status in ("complete", "error", "canceled"):
            return job.public()
        job.cancel_requested = True
        api = job.api
    if api is not None:
        api.cancel_pending_requests()
    return job.public()


@app.get("/api/jobs/{job_id}/file")
def download(job_id: str):
    job = _get_job(job_id)
    with lock:
        if job.status != "complete" or not job.file_path:
            raise HTTPException(409, "EPUB is not ready")
        file_path = Path(job.file_path)
        filename = job.filename
    if not file_path.is_file() or file_path.parent != BASE / job_id:
        raise HTTPException(404, "Export expired")
    return FileResponse(file_path, filename=filename, media_type="application/epub+zip")


STATIC_DIR = os.environ.get("FLUTTER_WEB_DIR")
if STATIC_DIR and Path(STATIC_DIR).is_dir():
    app.mount("/", StaticFiles(directory=STATIC_DIR, html=True), name="flutter")
