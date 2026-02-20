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

## Usage

```bash
# 1. Dry run — discover and count files, no upload
python cenpes_import.py --dry-run

# 2. Full import with defaults
python cenpes_import.py

# 3. Custom options
python cenpes_import.py \
  --root-dir /gaia/b04s/CONSORCIOS \
  --ingestor-host localhost \
  --ingestor-port 8082 \
  --workers 4 \
  --batch-size 16 \
  --log-dir /scratch/cenpes_logs

# 4. Via environment variables (useful in cluster job scripts)
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
| `--workers` | `4` | Collections processed in parallel |
| `--batch-size` | `16` | Files per upload batch |
| `--chunk-size` | `512` | Text chunk size for splitter |
| `--chunk-overlap` | `150` | Text chunk overlap for splitter |
| `--log-dir` | `cenpes_import_logs/` | Directory for per-collection log files |
| `--dry-run` | — | Discover files without uploading |

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
- **Poll retries**: up to 10 consecutive HTTP errors are retried before aborting the task
- All errors are written to the per-collection log file in `--log-dir`

## Collection name rules

Milvus requires collection names to be alphanumeric + underscore, max 255 chars,
starting with a letter or underscore. The script sanitizes directory names automatically:

- Spaces, hyphens, dots → `_`
- Consecutive underscores collapsed to one
- Leading digits prefixed with `col_`

## Re-running

The script does **not** check for already-ingested files before uploading.
If you need to resume a partial import, run with `--dry-run` first to see
which collections completed, then delete or comment out the completed ones
from the root directory (or use the blueprint's `DELETE /v1/collections` API
to reset a collection before re-importing).
