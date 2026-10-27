"""Bridge to zeroma25/ranobelib-downloader (MIT).

No scraping logic is reimplemented here: metadata, translation selection, chapter
loading and EPUB generation use the original project's Python classes.
"""
from __future__ import annotations

import importlib
import os
import re
import sys
from pathlib import Path
from typing import Any, Callable
from urllib.parse import urlsplit

UPSTREAM = Path(os.getenv("RANOBELIB_DOWNLOADER_PATH", "/opt/ranobelib-downloader"))
URL_PATTERN = re.compile(r"^/(?:ru/)?book/([0-9]+--[a-zA-Z0-9_-]+)/*$")


class InputError(ValueError):
    pass


def validate_url(url: str) -> str:
    """Allow only supported RanobeLIB book links (no arbitrary URL requests)."""
    if not isinstance(url, str) or len(url) > 2048:
        raise InputError("Enter a valid RanobeLIB book URL.")
    try:
        parsed = urlsplit(url.strip())
        if (
            parsed.scheme != "https"
            or parsed.hostname != "ranobelib.me"
            or parsed.port is not None
            or parsed.username is not None
            or parsed.password is not None
        ):
            raise InputError("Use an https://ranobelib.me/ru/book/... link.")
    except ValueError as exc:
        raise InputError("Invalid URL.") from exc
    match = URL_PATTERN.fullmatch(parsed.path)
    if not match:
        raise InputError("Please paste the main /ru/book/... URL, not a chapter link.")
    return match.group(1)


def load_upstream() -> dict[str, Any]:
    if not (UPSTREAM / "src" / "api.py").is_file():
        raise RuntimeError(
            f"Downloader source missing at {UPSTREAM}. Run ./setup.sh or use Docker."
        )
    path = str(UPSTREAM)
    if path not in sys.path:
        sys.path.insert(0, path)
    modules = {}
    for name in ("api", "branches", "parser", "img", "processing", "settings", "creators"):
        modules[name] = importlib.import_module(f"src.{name}")
    return modules


def _branch_options(modules: dict[str, Any], info: dict, chapters: list) -> list[dict]:
    b = modules["branches"]
    branches = b.get_formatted_branches_with_teams(info, chapters)
    options = [{"id": "default", "label": "Automatic · best available", "count": b.get_unique_chapters_count(chapters)}]
    for branch_id, value in sorted(branches.items(), key=lambda x: -x[1]["chapter_count"]):
        label = value["name"]
        teams = value.get("team_names") or []
        if teams and teams != [label]:
            label += " · " + ", ".join(teams)
        options.append({"id": str(branch_id), "label": label, "count": value["chapter_count"]})
    return options


def _metadata(modules: dict, url: str) -> tuple[dict, list, list]:
    slug = validate_url(url)
    api = modules["api"].RanobeLibAPI()
    info = api.get_novel_info(slug)
    if not info or not info.get("id"):
        raise InputError("Book not found or not accessible; check the link.")
    chapters = api.get_novel_chapters(slug)
    if not chapters:
        raise InputError("No downloadable public chapters were returned by RanobeLIB.")
    return info, chapters, _branch_options(modules, info, chapters)


def inspect_book(url: str) -> dict:
    m = load_upstream()
    info, chapters, options = _metadata(m, url)
    cover = info.get("cover") or {}
    cover_url = cover.get("default") if isinstance(cover, dict) else None
    return {
        "id": str(info["id"]),
        "title": info.get("rus_name") or info.get("eng_name") or info.get("name") or "Untitled",
        "author": ", ".join(a.get("name", "") for a in (info.get("authors") or []) if isinstance(a, dict)) or "RanobeLIB",
        "cover_url": cover_url if isinstance(cover_url, str) and cover_url.startswith("https://") else None,
        "chapter_count": options[0]["count"],
        "branches": options,
    }


def generate_epub(
    *, url: str, branch: str, start: int, end: int | None,
    cover: bool, images: bool, cache: bool, output_dir: Path,
    on_progress: Callable[[int, int, str], None],
    should_cancel: Callable[[], bool],
    set_cancel_api: Callable[[Any], None],
) -> Path:
    m = load_upstream()
    slug = validate_url(url)
    api = m["api"].RanobeLibAPI()
    set_cancel_api(api)
    if should_cancel():
        raise m["api"].OperationCancelledError("Canceled")
    info = api.get_novel_info(slug)
    if not info or not info.get("id"):
        raise InputError("Book not found or inaccessible.")
    chapters = api.get_novel_chapters(slug)
    if not chapters:
        raise InputError("No downloadable chapters available.")
    options = _branch_options(m, info, chapters)
    if branch not in {v["id"] for v in options}:
        raise InputError("Selected translation is no longer available. Inspect the book again.")

    parser = m["parser"].RanobeLibParser(api)
    image_handler = m["img"].ImageHandler(api)
    processor = m["processing"].ContentProcessor(api, parser, image_handler)
    chosen = processor.chapter_loader._filter_chapters(chapters, branch)
    count = len(chosen)
    stop = count if end is None else end
    if count == 0 or start < 1 or start > count or stop < start or stop > count:
        raise InputError(f"Chapter range must be between 1 and {count}.")
    chosen = chosen[start - 1:stop]
    # Rebuild a chapter list with one precise translation per chapter. This also
    # preserves the automatic branch selection made by the original downloader.
    selected = [{**entry["chapter"], "branches": [entry["branch"]]} for entry in chosen]

    # Upstream Settings is a process-wide singleton, so run one export at a time.
    settings = m["settings"].settings
    settings._settings.update({
        "save_directory": str(output_dir.absolute()),
        "download_cover": cover, "download_images": images,
        "compress_images": False,
        "cache_chapters": cache, "add_translator": False,
        "group_by_volumes": True,
    })
    processor.update_settings()
    output_dir.mkdir(parents=True, exist_ok=True)
    _, img_folder = processor.file_manager.prepare_dirs(info["id"])
    total = len(selected)
    on_progress(0, total, "Downloading chapters")

    original = processor.chapter_loader._process_single_chapter
    completed = 0

    def process_one(ch_data: dict, novel_info: dict, image_folder: str) -> dict:
        nonlocal completed
        if should_cancel():
            api.cancel_pending_requests()
            raise m["api"].OperationCancelledError("Canceled")
        result = original(ch_data, novel_info, image_folder)
        completed += 1
        on_progress(completed, total, "Downloading chapters")
        return result

    processor.chapter_loader._process_single_chapter = process_one
    try:
        # Prepare once; EpubCreator reuses the upstream in-memory cache.
        processor.chapter_loader.prepare_chapters(info, selected, None, img_folder)
        if should_cancel():
            raise m["api"].OperationCancelledError("Canceled")
        on_progress(total, total, "Building EPUB")
        filename = m["creators"].EpubCreator(processor).create(info, selected, None)
        output = Path(filename)
        if not output.is_file() or output.stat().st_size == 0:
            raise RuntimeError("The downloader did not produce an EPUB file.")
        on_progress(total, total, "Complete")
        return output
    finally:
        processor.chapter_loader._process_single_chapter = original
        m["processing"].ContentProcessor.clear_novel_cache(info["id"])
