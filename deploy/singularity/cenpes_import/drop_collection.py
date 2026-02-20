#!/usr/bin/env python3
"""
Drop one or more Milvus collections by name.

Usage:
    python3 drop_collection.py SEP
    python3 drop_collection.py SEP SAIG SEISCOPE
    python3 drop_collection.py --list
"""

import argparse
import sys

from pymilvus import MilvusClient


MILVUS_URI = "http://localhost:19530"


def main():
    parser = argparse.ArgumentParser(description="Drop Milvus collections")
    parser.add_argument("collections", nargs="*", help="Collection names to drop")
    parser.add_argument("--list", action="store_true", help="List all existing collections")
    parser.add_argument("--uri", default=MILVUS_URI, help=f"Milvus URI (default: {MILVUS_URI})")
    parser.add_argument("--yes", "-y", action="store_true", help="Skip confirmation prompt")
    args = parser.parse_args()

    client = MilvusClient(uri=args.uri)

    existing = client.list_collections()

    if args.list:
        if not existing:
            print("No collections found.")
        else:
            print(f"Collections in Milvus ({len(existing)}):")
            for name in sorted(existing):
                stats = client.get_collection_stats(name)
                count = stats.get("row_count", "?")
                print(f"  • {name}  ({count} entities)")
        return

    if not args.collections:
        parser.print_help()
        sys.exit(1)

    # Validate all names before dropping anything
    missing = [c for c in args.collections if c not in existing]
    if missing:
        print(f"Collection(s) not found: {', '.join(missing)}")
        print(f"Existing: {', '.join(sorted(existing)) or '(none)'}")
        sys.exit(1)

    print(f"Collections to drop: {', '.join(args.collections)}")
    for name in args.collections:
        stats = client.get_collection_stats(name)
        count = stats.get("row_count", "?")
        print(f"  • {name}  ({count} entities)")

    if not args.yes:
        answer = input("\nConfirm drop? [y/N] ").strip().lower()
        if answer != "y":
            print("Aborted.")
            sys.exit(0)

    for name in args.collections:
        client.drop_collection(name)
        print(f"✅ Dropped: {name}")


if __name__ == "__main__":
    main()
