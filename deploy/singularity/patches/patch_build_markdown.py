#!/usr/bin/env python3
"""
Patch nv_ingest_api/util/image_processing/table_and_chart.py

Fixes IndexError: single positional indexer is out-of-bounds in build_markdown()
when YOLOX table-structure model returns a sparse/empty DataFrame whose integer
index is no longer contiguous after groupby/reset_index operations.

Changes applied:
  1. df["col_ids"][i]  →  df["col_ids"].iloc[i]
  2. df["row_ids"][i]  →  df["row_ids"].iloc[i]
  3. df["text"][i]     →  df["text"].iloc[i]
  4. Early-return guard when the DataFrame is empty or has no rows.

Usage:
    python3 patch_build_markdown.py <input.py> <output.py>
"""

import re
import sys


REPLACEMENTS = [
    # Label-based → positional indexing
    (r'df\["col_ids"\]\[(\w+)\]',  r'df["col_ids"].iloc[\1]'),
    (r'df\["row_ids"\]\[(\w+)\]',  r'df["row_ids"].iloc[\1]'),
    (r'df\["text"\]\[(\w+)\]',     r'df["text"].iloc[\1]'),
]

# Anchor used to insert the empty-DataFrame guard just after the last
# reset_index inside build_markdown().  We look for the canonical
# "reset_index(drop=True)" call that appears at the end of the setup
# block, then insert a guard line immediately after.
GUARD_ANCHOR = re.compile(
    r'(df\s*=\s*df\.reset_index\(drop=True\))',
    re.MULTILINE
)
GUARD_CODE = (
    r'\1\n'
    r'    if df.empty or len(df) == 0:\n'
    r'        return ""\n'
)


def patch(src: str) -> str:
    out = src

    # 1. Fix positional indexing
    for pattern, replacement in REPLACEMENTS:
        out, n = re.subn(pattern, replacement, out)
        if n:
            print(f"  Applied ({n}x): {pattern!r}  →  {replacement!r}")

    # 2. Insert empty-DataFrame guard (only once — first occurrence)
    out, n = GUARD_ANCHOR.subn(GUARD_CODE, out, count=1)
    if n:
        print("  Inserted empty-DataFrame guard after reset_index(drop=True)")
    else:
        print("  WARNING: anchor for empty-DataFrame guard not found — "
              "guard NOT inserted (check the source manually)")

    return out


def main():
    if len(sys.argv) != 3:
        print(f"Usage: {sys.argv[0]} <input.py> <output.py>")
        sys.exit(1)

    src_path, dst_path = sys.argv[1], sys.argv[2]

    with open(src_path, "r") as f:
        src = f.read()

    print(f"Patching {src_path}  →  {dst_path}")
    patched = patch(src)

    if patched == src:
        print("WARNING: no changes applied — source may already be patched "
              "or patterns did not match.")

    with open(dst_path, "w") as f:
        f.write(patched)

    print("Done.")


if __name__ == "__main__":
    main()
