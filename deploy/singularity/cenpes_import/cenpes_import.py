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

Usage:
  python cenpes_import.py [options]

  # Dry run (discover files, no upload):
  python cenpes_import.py --dry-run

  # Full import:
  python cenpes_import.py --ingestor-host localhost --workers 4

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
    status: str = "pending"        # pending | running | done | failed | skipped
    total_files: int = 0
    ingested_files: int = 0
    failed_files: int = 0
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
            "metadata_schema": [],
        }
        resp = requests.post(url, json=payload, timeout=60)
        if resp.status_code >= 400:
            self.logger.error(f"create_collection HTTP {resp.status_code}: {resp.text}")
            resp.raise_for_status()
        self.logger.info(f"Collection '{collection_name}' created: {resp.text[:120]}")

    def upload_batch(
        self,
        files: list[Path],
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
            "custom_metadata": [],
            "generate_summary": False,
        }

        files_form: list = []
        opened: list = []
        try:
            for p in files:
                ct = CONTENT_TYPES.get(p.suffix.lower(), "application/octet-stream")
                fobj = open(p, "rb")  # noqa: WPS515
                opened.append(fobj)
                files_form.append(("documents", (p.name, fobj, ct)))
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
) -> None:
    """
    Full lifecycle for one collection.
    All state changes go through `_update` (thread-safe).
    Exceptions are caught so the caller's thread-pool remains healthy.
    """
    log_path = log_dir / f"{result.collection_name}.log"
    _update(result, lock, log_path=log_path)
    logger = make_logger(log_path, f"cenpes.{result.collection_name}")

    logger.info(f"=== START  dir='{result.dir_path}'  collection='{result.collection_name}' ===")
    _update(result, lock, status="running", start_time=time.time(), current_step="Discovering files")

    try:
        # ── 1. Discover files ─────────────────────────────────────────────────
        files = discover_files(result.dir_path)
        _update(result, lock, total_files=len(files), current_step=f"Found {len(files)} files")
        logger.info(f"Discovered {len(files)} supported file(s)")

        if not files:
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
            # Collection may already exist — log and continue
            logger.warning(f"create_collection error (may already exist): {exc}")

        # ── 3. Upload batches sequentially ────────────────────────────────────
        batches = list(chunked(files, batch_size))
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

        # ── 4. Finalize ───────────────────────────────────────────────────────
        if failed_files_count == 0:
            _update(result, lock, status="done", end_time=time.time(),
                    current_step=f"Done ({result.ingested_files} files)")
            logger.info(f"=== SUCCESS  ingested={result.ingested_files} ===")
        elif result.ingested_files > 0:
            _update(result, lock, status="partial", end_time=time.time(),
                    current_step=f"{result.ingested_files} ok · {failed_files_count} failed",
                    error=f"{result.ingested_files} ok · {failed_files_count} failed")
            logger.error(f"=== PARTIAL FAILURE  ok={result.ingested_files}  failed={failed_files_count}/{len(files)} ===")
        else:
            _update(result, lock, status="failed", end_time=time.time(),
                    current_step=f"All {failed_files_count} files failed",
                    error=f"All {failed_files_count} files failed")
            logger.error(f"=== TOTAL FAILURE  failed={failed_files_count}/{len(files)} ===")

    except Exception as exc:
        logger.error(f"=== FATAL ERROR: {exc} ===", exc_info=True)
        _update(result, lock, status="failed", end_time=time.time(),
                current_step="Fatal error", error=str(exc)[:120])


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
    return p.parse_args()


# ==============================================================================
# Main
# ==============================================================================

def main() -> int:
    args = parse_args()
    console = Console()
    base_url = f"http://{args.ingestor_host}:{args.ingestor_port}"
    log_dir: Path = args.log_dir
    log_dir.mkdir(parents=True, exist_ok=True)

    # ── Discover first-level directories ──────────────────────────────────────
    root = Path(args.root_dir)
    if not root.is_dir():
        console.print(f"[red]❌ Root directory not found: {root}[/]")
        return 2

    subdirs = sorted(d for d in root.iterdir() if d.is_dir())
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
    console.print(f"  Log dir:    [white]{log_dir.resolve()}[/]")
    console.print(f"  Collections:[white] {len(subdirs)} found[/]")
    if args.dry_run:
        console.print("  [yellow bold]DRY RUN — no files will be uploaded[/]")
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
    with Live(console=console, refresh_per_second=4, screen=False) as live:

        def refresh() -> None:
            live.update(build_table(results, lock))

        refresh()

        if args.dry_run:
            # Discover only — no uploads
            for r in results:
                _update(r, lock, status="running", start_time=time.time(),
                        current_step="Scanning…")
                refresh()
                files = discover_files(r.dir_path)
                _update(r, lock,
                        total_files=len(files),
                        ingested_files=len(files),
                        status="done" if files else "skipped",
                        end_time=time.time(),
                        current_step=f"Found {len(files)} files")
                refresh()

        else:
            # Parallel collection processing
            with concurrent.futures.ThreadPoolExecutor(max_workers=args.workers) as pool:
                future_map = {
                    pool.submit(
                        ingest_collection,
                        r, base_url, log_dir,
                        args.batch_size, args.chunk_size, args.chunk_overlap,
                        lock,
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

    console.print()
    console.print("[bold white]══════════════════════════════════════════════[/]")
    console.print("[bold white]                 IMPORT SUMMARY               [/]")
    console.print("[bold white]══════════════════════════════════════════════[/]")
    console.print()
    console.print(f"  Collections total:  [white]{len(results)}[/]")
    console.print(f"  [green]✅ Successful:      {len(done_results)}[/]")
    if partial_results:
        console.print(f"  [yellow]⚠  Partial:         {len(partial_results)}  (some files failed)[/]")
    if skipped_results:
        console.print(f"  [dim]⊘  Skipped:         {len(skipped_results)}  (no supported files)[/]")
    if failed_results:
        console.print(f"  [red]❌ Failed:          {len(failed_results)}[/]")
    console.print()
    console.print(f"  Files discovered:   [white]{total_files}[/]")
    console.print(f"  [green]Ingested:           {ingested_files}[/]")
    if failed_files:
        console.print(f"  [red]Failed:             {failed_files}[/]")
    console.print()
    console.print(f"  Per-collection logs: [dim]{log_dir.resolve()}/[/]")
    console.print()

    if partial_results:
        console.print("[bold yellow]Partial collections (some files failed):[/]")
        for r in partial_results:
            console.print(f"  [yellow]• {r.collection_name}[/]")
            console.print(f"    Result:  {r.error or 'see log'}")
            console.print(f"    Log:     {r.log_path}")
        console.print()

    if failed_results:
        console.print("[bold red]Failed collections (no files ingested):[/]")
        for r in failed_results:
            console.print(f"  [red]• {r.collection_name}[/]")
            console.print(f"    Error:   {r.error or 'see log'}")
            console.print(f"    Log:     {r.log_path}")
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
