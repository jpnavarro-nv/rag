#!/usr/bin/env python3
"""
CENPES Collection Importer
==========================

Scans a root directory (default: /gaia/b04s/CONSORCIOS) and imports each
first-level subdirectory as a separate collection in the NVIDIA RAG Blueprint.

Behavior:
  - Each first-level subdirectory  →  one collection
  - Files are discovered recursively inside each subdirectory
  - Collections are processed in parallel (--workers)
  - Within each collection, upload batches are sequential
  - Fault-tolerant: a failure in one collection does not stop others
  - Per-collection log files written to --log-dir
  - Real-time progress table shown during import
  - Final summary report printed at the end

Deduplication (on by default, disable with --skip-dedup):
  - Before uploading, queries the ingestor for document names in the collection
  - Files whose filename already exists on the server are skipped (name-based)
  - Note: content-change detection is not available (server rejects extra metadata)

Usage:
  python cenpes_import.py [options]

  # Dry run — validate readability/permissions, no upload:
  python cenpes_import.py --dry-run

  # Process only specific collections:
  python cenpes_import.py --collections SEISCOPE CREWES

  # Full import:
  python cenpes_import.py --ingestor-host localhost --workers 4

  # Force full re-upload ignoring deduplication:
  python cenpes_import.py --skip-dedup

Requirements:
  pip install requests rich
"""

import argparse
import concurrent.futures
import json
import logging
import os
import re
import sys
import threading
import time
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path
from typing import Optional

import requests
from rich import box
from rich.console import Console
from rich.live import Live
from rich.table import Table

# ==============================================================================
# Constants
# ==============================================================================

DEFAULT_ROOT_DIR     = "/gaia/b04s/CONSORCIOS"
DEFAULT_INGESTOR_HOST = "localhost"
DEFAULT_INGESTOR_PORT = 8082
DEFAULT_MAX_WORKERS  = 4
DEFAULT_BATCH_SIZE   = 16     # files per upload batch (matches NV-Ingest default)
DEFAULT_CHUNK_SIZE   = 512
DEFAULT_CHUNK_OVERLAP = 150
DEFAULT_LOG_DIR      = Path("cenpes_import_logs")

POLL_INTERVAL_S = 5
POLL_TIMEOUT_S  = 6 * 3600   # 6 h — large PDFs take a long time to process

# Supported by the NVIDIA RAG Blueprint frontend + ingestor backend
SUPPORTED_EXTENSIONS = {
    ".pdf", ".docx", ".pptx",
    ".txt", ".html", ".md",
    ".png", ".jpeg", ".jpg", ".bmp", ".tiff", ".tif",
    ".mp3", ".wav",
    ".json",
}

CONTENT_TYPES: dict[str, str] = {
    ".pdf":   "application/pdf",
    ".docx":  "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
    ".pptx":  "application/vnd.openxmlformats-officedocument.presentationml.presentation",
    ".txt":   "text/plain",
    ".html":  "text/html",
    ".md":    "text/markdown",
    ".png":   "image/png",
    ".jpeg":  "image/jpeg",
    ".jpg":   "image/jpeg",
    ".bmp":   "image/bmp",
    ".tiff":  "image/tiff",
    ".tif":   "image/tiff",
    ".mp3":   "audio/mpeg",
    ".wav":   "audio/wav",
    ".json":  "application/json",
}

# ==============================================================================
# Data model
# ==============================================================================

@dataclass
class CollectionResult:
    dir_path: Path
    collection_name: str
    status: str = "pending"        # pending | running | done | partial | failed | skipped
    total_files: int = 0           # files to upload this run (new)
    ingested_files: int = 0
    failed_files: int = 0
    skipped_files: int = 0         # files skipped because already present in server
    current_step: str = "Queued"
    error: Optional[str] = None
    start_time: Optional[float] = None
    end_time: Optional[float] = None
    log_path: Optional[Path] = None

    @property
    def elapsed(self) -> float:
        if self.start_time is None:
            return 0.0
        return (self.end_time or time.time()) - self.start_time

    @property
    def elapsed_str(self) -> str:
        s = int(self.elapsed)
        if s < 60:
            return f"{s}s"
        m, sec = divmod(s, 60)
        if m < 60:
            return f"{m}m{sec:02d}s"
        h, mn = divmod(m, 60)
        return f"{h}h{mn:02d}m"


# ==============================================================================
# Utilities
# ==============================================================================

def sanitize_collection_name(name: str) -> str:
    """Convert a directory name to a valid Milvus collection name.

    Milvus rules: alphanumeric + underscore, max 255 chars,
    must start with a letter or underscore.
    """
    s = re.sub(r"[^a-zA-Z0-9_]", "_", name)
    s = re.sub(r"_+", "_", s).strip("_")
    if not s:
        s = "collection"
    if not (s[0].isalpha() or s[0] == "_"):
        s = "col_" + s
    return s[:255]


def discover_files(folder: Path) -> list[Path]:
    """Recursively find all ingestible files under folder."""
    files: list[Path] = []
    for root, _dirs, filenames in os.walk(folder):
        for name in filenames:
            p = Path(root) / name
            if p.suffix.lower() in SUPPORTED_EXTENSIONS:
                files.append(p)
    return sorted(files)


def chunked(lst: list, size: int):
    """Yield successive chunks of `size` from `lst`."""
    for i in range(0, len(lst), size):
        yield lst[i : i + size]


def validate_readable(path: Path) -> Optional[str]:
    """Try to open and read 1 byte from path.

    Returns None if the file is readable, or an error string describing
    the problem (PermissionError, OSError, empty file warning, etc.).
    """
    try:
        with open(path, "rb") as f:
            data = f.read(1)
        if not data:
            return "Empty file"
        return None
    except PermissionError:
        return "Permission denied"
    except OSError as exc:
        return str(exc)


def make_logger(log_path: Path, name: str) -> logging.Logger:
    """Create a file-only logger for one collection."""
    log_path.parent.mkdir(parents=True, exist_ok=True)
    logger = logging.getLogger(name)
    logger.setLevel(logging.DEBUG)
    logger.handlers.clear()
    fh = logging.FileHandler(log_path, encoding="utf-8")
    fh.setFormatter(logging.Formatter(
        "%(asctime)s | %(levelname)-8s | %(message)s",
        datefmt="%Y-%m-%d %H:%M:%S",
    ))
    logger.addHandler(fh)
    logger.propagate = False
    return logger


# ==============================================================================
# Ingestor API client
# (follows patterns from scripts/batch_ingestion.py in this repository)
# ==============================================================================

class IngestionClient:

    def __init__(self, base_url: str, logger: logging.Logger) -> None:
        self.base_url = base_url.rstrip("/")
        self.logger = logger

    def create_collection(self, collection_name: str, embedding_dimension: int = 2048) -> None:
        """POST /v1/collection — create the collection (idempotent on server side)."""
        url = f"{self.base_url}/v1/collection"
        payload = {
            "collection_name": collection_name,
            "embedding_dimension": embedding_dimension,
        }
        resp = requests.post(url, json=payload, timeout=60)
        if resp.status_code >= 400:
            self.logger.error(f"create_collection HTTP {resp.status_code}: {resp.text}")
            resp.raise_for_status()
        self.logger.info(f"Collection '{collection_name}' created: {resp.text[:120]}")

    def list_documents(self, collection_name: str) -> set[str]:
        """GET /v1/documents — return set of document names already in the collection."""
        url = f"{self.base_url}/v1/documents"
        resp = requests.get(url, params={"collection_name": collection_name}, timeout=60)
        if resp.status_code == 404:
            return set()
        resp.raise_for_status()
        data = resp.json()
        names: set[str] = set()
        for doc in data.get("documents", []):
            name = doc.get("document_name") or doc.get("name", "")
            if name:
                names.add(name)
        self.logger.info(
            f"list_documents: {len(names)} existing doc(s) in '{collection_name}' "
            f"(total reported: {data.get('total_documents', 0)})"
        )
        return names

    def upload_batch(
        self,
        paths: list[Path],
        collection_name: str,
        chunk_size: int,
        chunk_overlap: int,
    ) -> str:
        """POST /v1/documents (multipart) — returns task_id."""
        url = f"{self.base_url}/v1/documents"
        payload = {
            "collection_name": collection_name,
            "blocking": False,
            "split_options": {"chunk_size": chunk_size, "chunk_overlap": chunk_overlap},
            "generate_summary": False,
        }

        files_form: list = []
        opened: list = []
        try:
            for path in paths:
                ct = CONTENT_TYPES.get(path.suffix.lower(), "application/octet-stream")
                fobj = open(path, "rb")  # noqa: WPS515
                opened.append(fobj)
                files_form.append(("documents", (path.name, fobj, ct)))
            files_form.append(("data", (None, json.dumps(payload), "application/json")))

            resp = requests.post(url, files=files_form, timeout=300)
            if resp.status_code >= 400:
                self.logger.error(f"upload_batch HTTP {resp.status_code}: {resp.text}")
                resp.raise_for_status()

            data = resp.json()
            task_id = data.get("task_id") or data.get("task") or data.get("id")
            if not task_id:
                raise RuntimeError(f"No task_id in upload response: {data}")
            self.logger.info(f"Upload accepted → task_id={task_id}")
            return task_id
        finally:
            for fobj in opened:
                try:
                    fobj.close()
                except Exception:
                    pass

    def poll_task(self, task_id: str, timeout: int = POLL_TIMEOUT_S) -> dict:
        """GET /v1/status until FINISHED; raises on FAILED / timeout."""
        url = f"{self.base_url}/v1/status"
        start = time.time()
        retries = 0

        while True:
            try:
                resp = requests.get(url, params={"task_id": task_id}, timeout=60)
                resp.raise_for_status()
                data: dict = resp.json() or {}
                retries = 0
            except Exception as exc:
                retries += 1
                self.logger.warning(f"Poll error (attempt {retries}): {exc}")
                if retries > 10:
                    raise RuntimeError(f"Poll retries exceeded for task {task_id}: {exc}") from exc
                time.sleep(POLL_INTERVAL_S)
                continue

            state = data.get("state", "UNKNOWN")
            elapsed = time.time() - start

            if state == "FINISHED":
                failed_docs = data.get("result", {}).get("failed_documents", [])
                if failed_docs:
                    self.logger.warning(
                        f"Task {task_id}: {len(failed_docs)} document(s) failed — "
                        + json.dumps([d.get("document_name") for d in failed_docs])
                    )
                self.logger.info(f"Task {task_id} FINISHED in {elapsed:.0f}s")
                return data

            if state in ("FAILED", "UNKNOWN"):
                raise RuntimeError(f"Task {task_id} ended with state={state}: {data}")

            if elapsed > timeout:
                raise TimeoutError(f"Poll timeout ({timeout}s) for task {task_id}")

            self.logger.debug(f"Task {task_id} state={state} elapsed={elapsed:.0f}s — waiting …")
            time.sleep(POLL_INTERVAL_S)


# ==============================================================================
# Per-collection worker (runs inside a thread-pool thread)
# ==============================================================================

def _update(result: CollectionResult, lock: threading.Lock, **kwargs) -> None:
    with lock:
        for k, v in kwargs.items():
            setattr(result, k, v)


def ingest_collection(
    result: CollectionResult,
    base_url: str,
    log_dir: Path,
    batch_size: int,
    chunk_size: int,
    chunk_overlap: int,
    lock: threading.Lock,
    skip_dedup: bool = False,
) -> None:
    """
    Full lifecycle for one collection.
    All state changes go through `_update` (thread-safe).
    Exceptions are caught so the caller's thread-pool remains healthy.

    Deduplication (unless skip_dedup):
      - Queries the ingestor for document names already in the collection.
      - Files whose filename already exists on the server are skipped (NEW only).
      - Note: content-change detection (SHA-256) is not supported because the
        ingestor rejects arbitrary per-file metadata fields.
    """
    log_path = log_dir / f"{result.collection_name}.log"
    _update(result, lock, log_path=log_path)
    logger = make_logger(log_path, f"cenpes.{result.collection_name}")

    logger.info(f"=== START  dir='{result.dir_path}'  collection='{result.collection_name}' ===")
    _update(result, lock, status="running", start_time=time.time(), current_step="Discovering files")

    try:
        # ── 1. Discover files ─────────────────────────────────────────────────
        all_files = discover_files(result.dir_path)
        logger.info(f"Discovered {len(all_files)} supported file(s)")

        if not all_files:
            logger.warning("No supported files found — skipping collection.")
            _update(result, lock, status="skipped", end_time=time.time(),
                    current_step="No supported files")
            return

        # ── 2. Create collection ──────────────────────────────────────────────
        client = IngestionClient(base_url, logger)
        _update(result, lock, current_step="Creating collection")
        try:
            client.create_collection(result.collection_name)
        except Exception as exc:
            logger.warning(f"create_collection error (may already exist): {exc}")

        # ── 3. Deduplication: query server for existing filenames ─────────────
        existing_names: set[str] = set()
        if not skip_dedup:
            _update(result, lock, current_step="Querying collection")
            try:
                existing_names = client.list_documents(result.collection_name)
            except Exception as exc:
                logger.warning(f"list_documents failed — treating all files as new: {exc}")

        to_upload: list[Path] = []
        skipped = 0

        for path in all_files:
            if path.name in existing_names:
                skipped += 1   # already present — skip
            else:
                to_upload.append(path)  # NEW

        logger.info(f"Classification: {len(to_upload)} new, {skipped} already present")

        _update(result, lock,
                total_files=len(to_upload),
                skipped_files=skipped,
                current_step=_classify_step(len(to_upload), skipped))

        # ── 4. All files already present ─────────────────────────────────────
        if not to_upload:
            step = f"All {skipped} file(s) already present"
            _update(result, lock, status="done", end_time=time.time(), current_step=step)
            logger.info(f"=== SKIP  {step} ===")
            return

        # ── 5. Upload batches sequentially ────────────────────────────────────
        batches = list(chunked(to_upload, batch_size))
        total_batches = len(batches)
        logger.info(f"Uploading {total_batches} batch(es) of up to {batch_size} file(s) each")

        failed_files_count = 0

        for batch_idx, batch in enumerate(batches, start=1):
            label = f"batch {batch_idx}/{total_batches} ({len(batch)} files)"
            _update(result, lock, current_step=f"Uploading {label}")
            logger.info(f"--- {label} ---")
            logger.debug("  Files: " + ", ".join(p.name for p in batch))

            try:
                task_id = client.upload_batch(batch, result.collection_name, chunk_size, chunk_overlap)
                client.poll_task(task_id)
                with lock:
                    result.ingested_files += len(batch)
                logger.info(f"✅ {label} complete")

            except Exception as exc:
                logger.error(f"❌ {label} failed: {exc}", exc_info=True)
                failed_files_count += len(batch)
                with lock:
                    result.failed_files += len(batch)
                # Continue with next batch — fault-tolerant

        # ── 6. Finalize ───────────────────────────────────────────────────────
        skip_note = f" · {skipped} already present" if skipped else ""
        if failed_files_count == 0:
            _update(result, lock, status="done", end_time=time.time(),
                    current_step=f"Done ({result.ingested_files} files{skip_note})")
            logger.info(f"=== SUCCESS  ingested={result.ingested_files}  skipped={skipped} ===")
        elif result.ingested_files > 0:
            step = f"{result.ingested_files} ok · {failed_files_count} failed{skip_note}"
            _update(result, lock, status="partial", end_time=time.time(),
                    current_step=step, error=step)
            logger.error(f"=== PARTIAL FAILURE  ok={result.ingested_files}  failed={failed_files_count}  skipped={skipped} ===")
        else:
            step = f"All {failed_files_count} files failed"
            _update(result, lock, status="failed", end_time=time.time(),
                    current_step=step, error=step)
            logger.error(f"=== TOTAL FAILURE  failed={failed_files_count}  skipped={skipped} ===")

    except Exception as exc:
        logger.error(f"=== FATAL ERROR: {exc} ===", exc_info=True)
        _update(result, lock, status="failed", end_time=time.time(),
                current_step="Fatal error", error=str(exc)[:120])


def dry_run_collection(
    result: CollectionResult,
    lock: threading.Lock,
    unreadable_by_collection: dict,
) -> None:
    """Dry-run worker: discover files and validate readability for one collection."""
    _update(result, lock, status="running", start_time=time.time(),
            current_step="Scanning…")

    files = discover_files(result.dir_path)

    if not files:
        _update(result, lock, total_files=0, status="skipped",
                end_time=time.time(), current_step="No supported files")
        return

    _update(result, lock, total_files=len(files),
            current_step=f"Validating {len(files)} files…")

    unreadable: list[tuple[Path, str]] = []
    for path in files:
        err = validate_readable(path)
        if err is not None:
            unreadable.append((path, err))

    readable_n   = len(files) - len(unreadable)
    unreadable_n = len(unreadable)

    if unreadable:
        with lock:
            unreadable_by_collection[result.collection_name] = unreadable

    if unreadable_n == 0:
        status = "done"
        step   = f"All {readable_n} files readable"
    elif readable_n > 0:
        status = "partial"
        step   = f"{readable_n} readable · {unreadable_n} unreadable"
    else:
        status = "failed"
        step   = f"All {unreadable_n} files unreadable"

    _update(result, lock,
            ingested_files=readable_n,
            failed_files=unreadable_n,
            status=status,
            end_time=time.time(),
            current_step=step,
            error=step if unreadable_n > 0 else None)


def _classify_step(n_new: int, n_skipped: int) -> str:
    """Build a human-readable classification summary for the current_step field."""
    parts = []
    if n_new:
        parts.append(f"{n_new} new")
    if n_skipped:
        parts.append(f"{n_skipped} already present")
    return " · ".join(parts) if parts else "No files to upload"


# ==============================================================================
# Live progress table
# ==============================================================================

_STATUS_COLOR = {
    "pending": "dim",
    "running": "cyan",
    "done":    "green",
    "partial": "yellow",
    "failed":  "red bold",
    "skipped": "dim",
}
_STATUS_ICON = {
    "pending": "·",
    "running": "⚙",
    "done":    "✓",
    "partial": "⚠",
    "failed":  "✗",
    "skipped": "⊘",
}


def _bar(fraction: float, width: int = 20) -> str:
    filled = int(fraction * width)
    return "█" * filled + "░" * (width - filled)


def build_table(results: list[CollectionResult], lock: threading.Lock) -> Table:
    table = Table(
        box=box.SIMPLE_HEAVY,
        header_style="bold white",
        show_edge=True,
        expand=True,
        pad_edge=True,
    )
    table.add_column(" ", width=3, justify="center", no_wrap=True)
    table.add_column("Collection", min_width=24, no_wrap=True)
    table.add_column("Files", width=14, justify="right")
    table.add_column("Progress", min_width=26, no_wrap=True)
    table.add_column("Current step", min_width=22, no_wrap=True)
    table.add_column("Elapsed", width=9, justify="right")

    with lock:
        snapshot = list(results)

    for r in snapshot:
        color = _STATUS_COLOR.get(r.status, "white")
        icon  = _STATUS_ICON.get(r.status, "?")

        # Files column
        if r.total_files:
            files_str = f"{r.ingested_files}/{r.total_files}"
        else:
            files_str = "—"

        # Progress bar
        if r.total_files > 0 and r.status not in ("pending",):
            frac = r.ingested_files / r.total_files
            pct  = frac * 100
            bar  = f"[{color}]{_bar(frac)}[/] {pct:4.0f}%"
        elif r.status == "done":
            bar = f"[green]{_bar(1.0)}[/] 100%"
        else:
            bar = f"[dim]{_bar(0.0)}[/]   —"

        # Step / error text
        step_text = (r.error or r.current_step) if r.status in ("failed", "partial") else r.current_step
        if len(step_text) > 36:
            step_text = step_text[:35] + "…"

        table.add_row(
            f"[{color}]{icon}[/]",
            f"[{color}]{r.collection_name[:38]}[/]",
            f"[{color}]{files_str}[/]",
            bar,
            f"[{color}]{step_text}[/]",
            f"[dim]{r.elapsed_str}[/]",
        )

    # Summary footer row
    done_n    = sum(1 for r in snapshot if r.status == "done")
    running_n = sum(1 for r in snapshot if r.status == "running")
    pending_n = sum(1 for r in snapshot if r.status == "pending")
    partial_n = sum(1 for r in snapshot if r.status == "partial")
    failed_n  = sum(1 for r in snapshot if r.status == "failed")

    table.add_section()
    table.add_row(
        "",
        f"[dim]{len(snapshot)} total[/]",
        "",
        f"[green]{done_n} done[/]  [cyan]{running_n} running[/]  "
        f"[dim]{pending_n} pending[/]  [yellow]{partial_n} partial[/]  [red]{failed_n} failed[/]",
        "",
        "",
    )
    return table


# ==============================================================================
# CLI
# ==============================================================================

def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(
        description="Import CONSORCIOS subdirectories as NVIDIA RAG Blueprint collections",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    p.add_argument(
        "--root-dir", default=DEFAULT_ROOT_DIR,
        help="Root directory whose first-level subdirs become collections",
    )
    p.add_argument(
        "--ingestor-host",
        default=os.environ.get("INGESTOR_HOST", DEFAULT_INGESTOR_HOST),
        help="Ingestor server host",
    )
    p.add_argument(
        "--ingestor-port", type=int,
        default=int(os.environ.get("INGESTOR_PORT", DEFAULT_INGESTOR_PORT)),
        help="Ingestor server port",
    )
    p.add_argument(
        "--workers", type=int, default=DEFAULT_MAX_WORKERS,
        help="Number of collections to process in parallel",
    )
    p.add_argument(
        "--batch-size", type=int, default=DEFAULT_BATCH_SIZE,
        help="Files per upload batch",
    )
    p.add_argument(
        "--chunk-size", type=int, default=DEFAULT_CHUNK_SIZE,
        help="Text chunk size for the splitter",
    )
    p.add_argument(
        "--chunk-overlap", type=int, default=DEFAULT_CHUNK_OVERLAP,
        help="Text chunk overlap for the splitter",
    )
    p.add_argument(
        "--log-dir", type=Path, default=DEFAULT_LOG_DIR,
        help="Directory for per-collection log files",
    )
    p.add_argument(
        "--dry-run", action="store_true",
        help="Discover files and show counts without uploading anything",
    )
    p.add_argument(
        "--skip-dedup", action="store_true",
        help="Skip server-side deduplication and re-upload all files unconditionally",
    )
    p.add_argument(
        "--collections", nargs="+", metavar="NAME",
        help="Process only these subdirectory names from root-dir (default: all)",
    )
    return p.parse_args()


# ==============================================================================
# Main
# ==============================================================================

def main() -> int:
    args = parse_args()
    console = Console()
    base_url = f"http://{args.ingestor_host}:{args.ingestor_port}"

    # Each run gets its own timestamped subdirectory so logs are never overwritten.
    run_ts  = datetime.now().strftime("%Y-%m-%d_%H-%M-%S")
    log_dir: Path = args.log_dir / run_ts
    log_dir.mkdir(parents=True, exist_ok=True)

    # ── Discover first-level directories ──────────────────────────────────────
    root = Path(args.root_dir)
    if not root.is_dir():
        console.print(f"[red]❌ Root directory not found: {root}[/]")
        return 2

    all_subdirs = {d.name: d for d in root.iterdir() if d.is_dir()}

    if args.collections:
        unknown = [n for n in args.collections if n not in all_subdirs]
        if unknown:
            for n in unknown:
                console.print(f"[red]❌ Collection not found in {root}: {n}[/]")
            return 2
        subdirs = sorted(all_subdirs[n] for n in args.collections)
    else:
        subdirs = sorted(all_subdirs.values())

    if not subdirs:
        console.print(f"[yellow]⚠️  No subdirectories found in {root}[/]")
        return 0

    # ── Print header ──────────────────────────────────────────────────────────
    console.print()
    console.print("[bold cyan]╔══════════════════════════════════════════╗[/]")
    console.print("[bold cyan]║     CENPES Collection Importer            ║[/]")
    console.print("[bold cyan]╚══════════════════════════════════════════╝[/]")
    console.print(f"  Root dir:   [white]{root}[/]")
    console.print(f"  Ingestor:   [white]{base_url}[/]")
    console.print(f"  Workers:    [white]{args.workers} parallel collections[/]")
    console.print(f"  Batch size: [white]{args.batch_size} files[/]")
    console.print(f"  Log dir:    [white]{args.log_dir.resolve()}/{run_ts}/[/]")
    if args.collections:
        console.print(f"  Collections:[white] {len(subdirs)} selected (of {len(all_subdirs)} available)[/]")
    else:
        console.print(f"  Collections:[white] {len(subdirs)} found[/]")
    if args.dry_run:
        console.print("  [yellow bold]DRY RUN — no files will be uploaded[/]")
    if args.skip_dedup:
        console.print("  [yellow]Deduplication: DISABLED (--skip-dedup)[/]")
    console.print()

    # ── Build result objects ───────────────────────────────────────────────────
    results: list[CollectionResult] = [
        CollectionResult(
            dir_path=d,
            collection_name=sanitize_collection_name(d.name),
        )
        for d in subdirs
    ]
    lock = threading.Lock()

    # ── Validate collection name collisions ────────────────────────────────────
    seen: dict[str, str] = {}
    for r in results:
        if r.collection_name in seen:
            console.print(
                f"[yellow]⚠️  Name collision: '{r.dir_path.name}' and "
                f"'{seen[r.collection_name]}' both map to '{r.collection_name}'. "
                f"The second will overwrite the first in the vector DB.[/]"
            )
        seen[r.collection_name] = r.dir_path.name

    # ── Live display + execution ───────────────────────────────────────────────
    # Populated during dry-run; used for the post-display unreadable file report.
    unreadable_by_collection: dict[str, list[tuple[Path, str]]] = {}

    with Live(console=console, refresh_per_second=4, screen=False) as live:

        def refresh() -> None:
            live.update(build_table(results, lock))

        refresh()

        if args.dry_run:
            # Discover files and validate readability — parallel, no uploads
            with concurrent.futures.ThreadPoolExecutor(max_workers=args.workers) as pool:
                future_map = {
                    pool.submit(dry_run_collection, r, lock, unreadable_by_collection): r
                    for r in results
                }

                pending = set(future_map)
                while pending:
                    done, pending = concurrent.futures.wait(pending, timeout=0.25)
                    for fut in done:
                        try:
                            fut.result()
                        except Exception as exc:
                            r = future_map[fut]
                            _update(r, lock, status="failed", end_time=time.time(),
                                    current_step="Unhandled error",
                                    error=str(exc)[:120])
                    refresh()

        else:
            # Parallel collection processing
            with concurrent.futures.ThreadPoolExecutor(max_workers=args.workers) as pool:
                future_map = {
                    pool.submit(
                        ingest_collection,
                        r, base_url, log_dir,
                        args.batch_size, args.chunk_size, args.chunk_overlap,
                        lock, args.skip_dedup,
                    ): r
                    for r in results
                }

                pending = set(future_map)
                while pending:
                    done, pending = concurrent.futures.wait(pending, timeout=0.25)
                    for fut in done:
                        try:
                            fut.result()           # surface any unhandled exception
                        except Exception as exc:
                            r = future_map[fut]
                            _update(r, lock, status="failed", end_time=time.time(),
                                    current_step="Unhandled error",
                                    error=str(exc)[:120])
                    refresh()

        refresh()  # final snapshot

    # ── Summary report ─────────────────────────────────────────────────────────
    done_results    = [r for r in results if r.status == "done"]
    partial_results = [r for r in results if r.status == "partial"]
    failed_results  = [r for r in results if r.status == "failed"]
    skipped_results = [r for r in results if r.status == "skipped"]

    total_files    = sum(r.total_files    for r in results)
    ingested_files = sum(r.ingested_files for r in results)
    failed_files   = sum(r.failed_files   for r in results)
    skipped_files  = sum(r.skipped_files  for r in results)

    # Labels differ between dry-run (validation) and full run (ingestion)
    dr = args.dry_run
    console.print()
    console.print("[bold white]══════════════════════════════════════════════[/]")
    title = "DRY RUN — VALIDATION SUMMARY" if dr else "IMPORT SUMMARY"
    console.print(f"[bold white]          {title:<34}[/]")
    console.print("[bold white]══════════════════════════════════════════════[/]")
    console.print()
    console.print(f"  Collections total:  [white]{len(results)}[/]")
    console.print(f"  [green]✅ {'All readable' if dr else 'Successful'}:      {len(done_results)}[/]")
    if partial_results:
        note = "some unreadable" if dr else "some files failed"
        console.print(f"  [yellow]⚠  Partial:         {len(partial_results)}  ({note})[/]")
    if skipped_results:
        console.print(f"  [dim]⊘  Skipped:         {len(skipped_results)}  (no supported files)[/]")
    if failed_results:
        note = "all unreadable" if dr else "no files ingested"
        console.print(f"  [red]❌ Failed:          {len(failed_results)}  ({note})[/]")
    console.print()
    console.print(f"  Files discovered:   [white]{total_files}[/]")
    if dr:
        console.print(f"  [green]Readable:           {ingested_files}[/]")
        if failed_files:
            console.print(f"  [red]Unreadable:         {failed_files}[/]")
    else:
        console.print(f"  [green]Ingested:           {ingested_files}[/]")
        if skipped_files:
            console.print(f"  [dim]Already current:    {skipped_files}  (skipped)[/]")
        if failed_files:
            console.print(f"  [red]Failed:             {failed_files}[/]")
    console.print()
    if not dr:
        console.print(f"  Per-collection logs: [dim]{log_dir.resolve()}/[/]")
        console.print()

    if partial_results:
        header = "Collections with unreadable files:" if dr else "Partial collections (some files failed):"
        console.print(f"[bold yellow]{header}[/]")
        for r in partial_results:
            console.print(f"  [yellow]• {r.collection_name}[/]")
            if not dr:
                console.print(f"    Result:  {r.error or 'see log'}")
                console.print(f"    Log:     {r.log_path}")
        console.print()

    if failed_results:
        header = "Collections entirely unreadable:" if dr else "Failed collections (no files ingested):"
        console.print(f"[bold red]{header}[/]")
        for r in failed_results:
            console.print(f"  [red]• {r.collection_name}[/]")
            if not dr:
                console.print(f"    Error:   {r.error or 'see log'}")
                console.print(f"    Log:     {r.log_path}")
        console.print()

    # Dry-run: print each unreadable file with its error
    if dr and unreadable_by_collection:
        console.print("[bold red]Unreadable files:[/]")
        for col, entries in unreadable_by_collection.items():
            console.print(f"  [yellow]{col}[/]")
            for path, err in entries:
                console.print(f"    [red]{path}[/]")
                console.print(f"      [dim]{err}[/]")
        console.print()

    if skipped_results:
        console.print("[bold dim]Skipped collections (no supported files found):[/]")
        for r in skipped_results:
            console.print(f"  [dim]• {r.dir_path.name}  →  {r.collection_name}[/]")
        console.print()

    console.print("[bold white]══════════════════════════════════════════════[/]")
    console.print()

    return 0 if not (failed_results or partial_results) else 1


if __name__ == "__main__":
    raise SystemExit(main())
