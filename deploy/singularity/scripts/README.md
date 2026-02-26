# Collection Importer

Imports all first-level subdirectories of a root directory as separate collections
into the NVIDIA RAG Blueprint.

## How it works

```
/path/to/data/
├── PROJECT_A/    →  collection: PROJECT_A   (all files inside, recursively)
├── PROJECT_B/    →  collection: PROJECT_B
└── Data 2024/    →  collection: Data_2024   (spaces → underscores)
```

- Collections are processed **in parallel** (configurable `--parallel-workers`)
- Within each collection, upload batches are **sequential** (safer for the ingestor)
- A failure in one collection does **not** stop the others
- A per-collection log file is written to `--log-dir` (default: `import_logs/`)
- A real-time progress table is shown in the terminal
- A final summary report is printed at the end

## Requirements

- Python 3.10+
- The **Ingestor Server** must be running and reachable (default: `localhost:8082`)
- The script runs on the **host** — no container needed

```bash
pip install -r requirements.txt
```

If pip install fails (e.g. network-restricted cluster), use a container that ships
`requests` and `rich` pre-installed:

```bash
singularity exec httpie_latest.sif python3 ingest_collections.py --root-dir /path/to/data
```

## Usage

```bash
# 1. Dry run — discover files, validate readability/permissions, no upload
python ingest_collections.py --root-dir /path/to/data --dry-run

# 2. Full import with defaults
python ingest_collections.py --root-dir /path/to/data

# 3. Process only specific collections
python ingest_collections.py --root-dir /path/to/data --collections PROJECT_A PROJECT_B

# 4. Force full re-upload (ignore deduplication)
python ingest_collections.py --root-dir /path/to/data --skip-dedup

# 5. Custom options
python ingest_collections.py \
  --root-dir /path/to/data \
  --ingestor-host localhost \
  --ingestor-port 8082 \
  --parallel-workers 4 \
  --batch-size 16 \
  --log-dir /scratch/import_logs

# 6. Via environment variables (useful in cluster job scripts)
export INGESTOR_HOST=localhost
export INGESTOR_PORT=8082
python ingest_collections.py --root-dir /path/to/data --parallel-workers 6
```

## Options

| Option | Default | Description |
|---|---|---|
| `--root-dir` | **required** | Root directory to scan |
| `--ingestor-host` | `localhost` | Ingestor server host (or `$INGESTOR_HOST`) |
| `--ingestor-port` | `8082` | Ingestor server port (or `$INGESTOR_PORT`) |
| `--parallel-workers` | `4` | Collections processed in parallel |
| `--batch-size` | `16` | Files per upload batch |
| `--chunk-size` | `512` | Text chunk size for splitter |
| `--chunk-overlap` | `150` | Text chunk overlap for splitter |
| `--log-dir` | `import_logs/` | Directory for per-collection log files |
| `--dry-run` | — | Discover files and validate readability; no upload |
| `--skip-dedup` | — | Re-upload all files unconditionally (skip deduplication) |
| `--collections` | all | Process only these subdirectory names from `--root-dir` |

## Importing specific collections

By default the script processes **every** first-level subdirectory under `--root-dir`.
Use `--collections` to select only the directories you want:

```bash
# Import a single collection
python ingest_collections.py --root-dir /path/to/data --collections PROJECT_A

# Import several collections in one run
python ingest_collections.py --root-dir /path/to/data --collections PROJECT_A PROJECT_B PROJECT_C

# Combine with other flags (dry-run first, then import)
python ingest_collections.py --root-dir /path/to/data --collections PROJECT_A --dry-run
python ingest_collections.py --root-dir /path/to/data --collections PROJECT_A
```

The names passed to `--collections` must match the **directory names** exactly
(case-sensitive) as they appear on disk, not the sanitized collection names.

```
/path/to/data/
├── PROJECT_A/    ← use "PROJECT_A"
├── Data 2024/    ← use "Data 2024"   (with the space)
└── PROJ-BETA/    ← use "PROJ-BETA"   (with the hyphen)
```

To discover available directory names before running:

```bash
ls /path/to/data/
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
2. Skips files whose filename already exists on the server

To force a full re-upload (e.g. after changing chunk settings):

```bash
python ingest_collections.py --root-dir /path/to/data --skip-dedup
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
efficient. Files already ingested with the same filename are skipped automatically.

If a previous import was interrupted partway through a collection, simply re-run the
script. Only the missing files will be uploaded.

To reset a collection completely before re-importing, use the blueprint's API:

```bash
curl -X DELETE http://localhost:8082/v1/collection \
  -H "Content-Type: application/json" \
  -d '{"collection_name": "MY_COLLECTION"}'
python ingest_collections.py --root-dir /path/to/data --collections MY_COLLECTION
```
