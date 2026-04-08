#!/usr/bin/env python3
"""Stream inference from a NIM LLM endpoint. Reasoning tokens are hidden.

Usage:
    python scripts/run_inference.py --url http://node:8999 "Your question here"
    python scripts/run_inference.py --list          # show supported models
    python scripts/run_inference.py --help          # usage help

The endpoint URL can be set via --url or the NIM_URL environment variable.
Default: http://localhost:8999

Requires: pip install requests
"""

import os
import sys
import json
import argparse
import requests

DEFAULT_URL = "http://localhost:8999"

THINK_OPEN = "<think>"
THINK_CLOSE = "</think>"


def detect_model(base_url):
    """Query the NIM to find which model is loaded."""
    url = f"{base_url}/v1/models"
    try:
        resp = requests.get(url, timeout=5)
        resp.raise_for_status()
        data = resp.json()
        models = data.get("data", [])
        if models:
            return models[0]["id"]
    except requests.ConnectionError:
        print(f"Error: cannot connect to NIM at {base_url}", file=sys.stderr)
        print("Is the NIM running? Check with: ./list-nims.sh", file=sys.stderr)
        sys.exit(1)
    except requests.Timeout:
        print(f"Error: connection to {base_url} timed out", file=sys.stderr)
        sys.exit(1)
    except (requests.HTTPError, KeyError, IndexError) as e:
        print(f"Error querying NIM models endpoint: {e}", file=sys.stderr)
        sys.exit(1)
    return None


def list_models(base_url):
    """List models available on the NIM endpoint."""
    url = f"{base_url}/v1/models"
    try:
        resp = requests.get(url, timeout=5)
        resp.raise_for_status()
        data = resp.json()
        models = data.get("data", [])
        if not models:
            print(f"No models found on {base_url}")
            return
        print(f"Models available on {base_url}:")
        print()
        for m in models:
            print(f"  {m['id']}")
        print()
    except requests.ConnectionError:
        print(f"Error: cannot connect to NIM at {base_url}", file=sys.stderr)
        print("Is the NIM running? Check with: ./list-nims.sh", file=sys.stderr)
        sys.exit(1)
    except requests.Timeout:
        print(f"Error: connection to {base_url} timed out", file=sys.stderr)
        sys.exit(1)
    except (requests.HTTPError, KeyError) as e:
        print(f"Error querying NIM models endpoint: {e}", file=sys.stderr)
        sys.exit(1)


def stream_tokens(base_url, question, model):
    """Yield content tokens from the NIM streaming API."""
    url = f"{base_url}/v1/chat/completions"
    try:
        resp = requests.post(
            url,
            json={
                "model": model,
                "messages": [{"role": "user", "content": question}],
                "temperature": 0.6,
                "top_p": 0.95,
                "max_tokens": 4096,
                "stream": True,
            },
            stream=True,
            timeout=(10, 300),
        )
        resp.raise_for_status()
    except requests.ConnectionError:
        print(f"Error: cannot connect to NIM at {base_url}", file=sys.stderr)
        sys.exit(1)
    except requests.Timeout:
        print(f"Error: connection to {base_url} timed out", file=sys.stderr)
        sys.exit(1)
    except requests.HTTPError as e:
        print(f"Error: NIM returned {e.response.status_code}: {e.response.text}", file=sys.stderr)
        sys.exit(1)

    for line in resp.iter_lines(decode_unicode=True):
        if not line or not line.startswith("data: "):
            continue
        data = line[6:]
        if data == "[DONE]":
            break
        try:
            delta = json.loads(data)["choices"][0]["delta"]
        except (json.JSONDecodeError, KeyError, IndexError):
            continue
        content = delta.get("content", "")
        if content:
            yield content


def main():
    nim_url = os.environ.get("NIM_URL", DEFAULT_URL)

    parser = argparse.ArgumentParser(
        description="Stream inference from a NIM LLM endpoint.",
        epilog="The endpoint URL can also be set via the NIM_URL environment variable.",
    )
    parser.add_argument("question", nargs="?", help="Question to send to the model")
    parser.add_argument(
        "--url", default=nim_url,
        help=f"NIM endpoint URL (default: NIM_URL env or {DEFAULT_URL})",
    )
    parser.add_argument(
        "--list", "-l", action="store_true",
        help="List models available on the NIM endpoint",
    )

    args = parser.parse_args()
    base_url = args.url.rstrip("/")

    if args.list:
        list_models(base_url)
        sys.exit(0)

    if not args.question:
        parser.print_help()
        sys.exit(1)

    # Auto-detect running model
    model = detect_model(base_url)
    if not model:
        print("Error: no model loaded on the NIM endpoint", file=sys.stderr)
        sys.exit(1)

    sys.stderr.write(f"Model: {model}\n")
    sys.stderr.flush()

    buf = ""
    phase = "detect"  # detect -> thinking -> answering

    for token in stream_tokens(base_url, args.question, model):
        if phase == "answering":
            print(token, end="", flush=True)
            continue

        buf += token

        if phase == "detect":
            if THINK_OPEN in buf:
                before = buf[: buf.index(THINK_OPEN)]
                if before:
                    print(before, end="", flush=True)
                phase = "thinking"
                buf = buf[buf.index(THINK_OPEN) + len(THINK_OPEN) :]
                sys.stderr.write("Thinking... ")
                sys.stderr.flush()
            elif len(buf) > len(THINK_OPEN):
                # No think tag — model didn't reason, stream directly
                phase = "answering"
                print(buf, end="", flush=True)
                buf = ""

        if phase == "thinking" and THINK_CLOSE in buf:
            phase = "answering"
            after = buf[buf.index(THINK_CLOSE) + len(THINK_CLOSE) :]
            buf = ""
            sys.stderr.write("done.\n")
            sys.stderr.flush()
            if after:
                print(after, end="", flush=True)

    if buf and phase != "thinking":
        print(buf, end="", flush=True)

    print()


if __name__ == "__main__":
    main()
