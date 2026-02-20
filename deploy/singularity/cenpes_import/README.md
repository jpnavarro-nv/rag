# CENPES Collection Importer

Imports all first-level subdirectories of `/gaia/b04s/CONSORCIOS` as
separate collections into the NVIDIA RAG Blueprint.

## How it works

```
/gaia/b04s/CONSORCIOS/
├── CWP/          →  collection: CWP         (all files inside, recursively)
├── PROJ_ALPHA/   →  collection: PROJ_ALPHA
└── Dados 2024/   →  collection: Dados_2024  (spaces → underscores)
```

- Collections are processed **in parallel** (configurable `--workers`)
- Within each collection, upload batches are **sequential** (safer for the ingestor)
- A failure in one collection does **not** stop the others
- A per-collection log file is written to `--log-dir` (default: `cenpes_import_logs/`)
- A real-time progress table is shown in the terminal
- A final summary report is printed at the end

## Requirements

- Python 3.10+
- The **Ingestor Server** must be running and reachable (default: `localhost:8082`)
- The script runs on the **host** — no container needed

```bash
pip install -r requirements.txt
```

If pip install fails (e.g. corporate SSL proxy), use the `alpine/httpie` Singularity
container which ships `requests` and `rich` pre-installed:

```bash
apptainer exec --bind /gaia:/gaia httpie_latest.sif python3 cenpes_import.py
```

## Usage

```bash
# 1. Dry run — discover files, validate readability/permissions, no upload
python cenpes_import.py --dry-run

# 2. Full import with defaults
python cenpes_import.py

# 3. Process only specific collections
python cenpes_import.py --collections SEISCOPE CREWES

# 4. Force full re-upload (ignore deduplication)
python cenpes_import.py --skip-dedup

# 5. Custom options
python cenpes_import.py \
  --root-dir /gaia/b04s/CONSORCIOS \
  --ingestor-host localhost \
  --ingestor-port 8082 \
  --parallel-workers 4 \
  --batch-size 16 \
  --log-dir /scratch/cenpes_logs

# 6. Via environment variables (useful in cluster job scripts)
export INGESTOR_HOST=localhost
export INGESTOR_PORT=8082
python cenpes_import.py --workers 6
```

## Options

| Option | Default | Description |
|---|---|---|
| `--root-dir` | `/gaia/b04s/CONSORCIOS` | Root directory to scan |
| `--ingestor-host` | `localhost` | Ingestor server host (or `$INGESTOR_HOST`) |
| `--ingestor-port` | `8082` | Ingestor server port (or `$INGESTOR_PORT`) |
| `--parallel-workers` | `4` | Collections processed in parallel |
| `--batch-size` | `16` | Files per upload batch |
| `--chunk-size` | `512` | Text chunk size for splitter |
| `--chunk-overlap` | `150` | Text chunk overlap for splitter |
| `--log-dir` | `cenpes_import_logs/` | Directory for per-collection log files |
| `--dry-run` | — | Discover files and validate readability; no upload |
| `--skip-dedup` | — | Re-upload all files unconditionally (skip deduplication) |
| `--collections` | all | Process only these subdirectory names from `--root-dir` |

## Importing specific collections

By default the script processes **every** first-level subdirectory under `--root-dir`.
Use `--collections` to select only the directories you want:

```bash
# Import a single collection
python cenpes_import.py --collections SEISCOPE

# Import several collections in one run
python cenpes_import.py --collections SEISCOPE CREWES DEEPWAVE

# Combine with other flags (dry-run first, then import)
python cenpes_import.py --collections SEISCOPE --dry-run
python cenpes_import.py --collections SEISCOPE
```

The names passed to `--collections` must match the **directory names** exactly
(case-sensitive) as they appear on disk, not the sanitized collection names.

```
/gaia/b04s/CONSORCIOS/
├── SEISCOPE/       ← use "SEISCOPE"
├── Dados 2024/     ← use "Dados 2024"   (with the space)
└── PROJ-ALPHA/     ← use "PROJ-ALPHA"   (with the hyphen)
```

To discover the available directory names before running:

```bash
ls /gaia/b04s/CONSORCIOS/
```

If a name passed to `--collections` does not exist in `--root-dir`, the script
exits immediately with an error listing the unknown names.

## Dry run

`--dry-run` scans the filesystem without sending anything to the ingestor.
For each collection it:

1. Recursively discovers all supported files
2. Tries to open and read 1 byte from each file
3. Reports **readable**, **unreadable** (permission denied / I/O error), and **empty** files

The progress table uses the same color coding as a full run:
- ✓ green — all files readable
- ⚠ yellow — some files unreadable (partial)
- ✗ red — all files unreadable

Use `--dry-run` before a real import to catch permission issues early.

## Deduplication

Deduplication is **enabled by default**. Before uploading, the script:

1. Queries the ingestor for documents already in the collection
2. Computes the SHA-256 hash of each local file (streaming, 64 KB chunks)
3. Classifies each file:
   - **NEW** — not present on server → uploaded
   - **MODIFIED** — path matches but SHA-256 differs → old doc deleted, then re-uploaded
   - **UNCHANGED** — path and SHA-256 match → skipped

The `source_path` (full disk path) and `sha256` are stored as `custom_metadata`
on every uploaded document, so subsequent runs can detect already-current files
without any local checkpoint.

To force a full re-upload (e.g. after changing chunk settings):

```bash
python cenpes_import.py --skip-dedup
```

## Status indicators

| Icon | Color | Meaning |
|---|---|---|
| ⚙ | cyan | Running |
| ✓ | green | Completed — all files ingested (or all readable in dry-run) |
| ⚠ | yellow | Partial — some files failed (others succeeded) |
| ✗ | red | Failed — no files ingested (or all unreadable in dry-run) |
| ⊘ | dim | Skipped — no supported files found in this directory |

## Supported file types

| Extension | Type |
|---|---|
| `.pdf` | PDF documents |
| `.docx` | Word documents |
| `.pptx` | PowerPoint presentations |
| `.txt` | Plain text |
| `.html` | Web pages |
| `.md` | Markdown |
| `.png` `.jpeg` `.jpg` `.bmp` `.tiff` | Images (processed by VLM) |
| `.mp3` `.wav` | Audio |
| `.json` | JSON data |

## Fault tolerance

- **Batch failure**: a failed batch is logged and skipped; the next batch continues
- **Collection failure**: a fatal error marks the collection as failed; others continue
- **Collection already exists**: the server returns a 4xx but the script continues (idempotent)
- **Dedup query failure**: if `GET /v1/documents` fails, all files are treated as new and upload proceeds
- **Poll retries**: up to 10 consecutive HTTP errors are retried before aborting the task
- All errors are written to the per-collection log file in `--log-dir`

## Collection name rules

Milvus requires collection names to be alphanumeric + underscore, max 255 chars,
starting with a letter or underscore. The script sanitizes directory names automatically:

- Spaces, hyphens, dots → `_`
- Consecutive underscores collapsed to one
- Leading digits prefixed with `col_`

## Re-running

The script uses **server-side deduplication** by default — re-running it is safe and
efficient. Files already ingested with the same content are detected via SHA-256 and
skipped automatically.

If a previous import was interrupted partway through a collection, simply re-run the
script. Only the missing or changed files will be uploaded.

To reset a collection completely before re-importing, use the blueprint's API:

```bash
curl -X DELETE http://localhost:8082/v1/collection \
  -H "Content-Type: application/json" \
  -d '{"collection_name": "MY_COLLECTION"}'
python cenpes_import.py --collections MY_COLLECTION
```
