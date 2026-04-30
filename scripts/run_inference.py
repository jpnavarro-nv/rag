#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Stream inference from a vLLM endpoint. Reasoning tokens are hidden.

Usage:
    python scripts/run_inference.py --url http://node:8000 "Your question here"
    python scripts/run_inference.py --list          # show supported models
    python scripts/run_inference.py --help          # usage help

The endpoint URL can be set via --url or the LLM_URL environment variable.
Default: http://localhost:8000

No external dependencies — uses only Python standard library.
"""

import os
import sys
import json
import argparse
import urllib.request
import urllib.error

DEFAULT_URL = "http://localhost:8000"

THINK_OPEN = "<think>"
THINK_CLOSE = "</think>"


def _request(url, data=None, timeout=10):
    """Make an HTTP request and return the response object."""
    headers = {"Content-Type": "application/json"} if data else {}
    body = json.dumps(data).encode() if data else None
    req = urllib.request.Request(url, data=body, headers=headers)
    return urllib.request.urlopen(req, timeout=timeout)


def detect_model(base_url):
    """Query the endpoint to find which model is loaded."""
    try:
        resp = _request(f"{base_url}/v1/models")
        data = json.loads(resp.read().decode())
        models = data.get("data", [])
        if models:
            return models[0]["id"]
    except urllib.error.URLError as e:
        print(f"Error: cannot connect to {base_url}: {e.reason}", file=sys.stderr)
        sys.exit(1)
    except (json.JSONDecodeError, KeyError, IndexError) as e:
        print(f"Error querying models endpoint: {e}", file=sys.stderr)
        sys.exit(1)
    return None


def list_models(base_url):
    """List models available on the endpoint."""
    try:
        resp = _request(f"{base_url}/v1/models")
        data = json.loads(resp.read().decode())
        models = data.get("data", [])
        if not models:
            print(f"No models found on {base_url}")
            return
        print(f"Models available on {base_url}:")
        print()
        for m in models:
            print(f"  {m['id']}")
        print()
    except urllib.error.URLError as e:
        print(f"Error: cannot connect to {base_url}: {e.reason}", file=sys.stderr)
        sys.exit(1)
    except (json.JSONDecodeError, KeyError) as e:
        print(f"Error querying models endpoint: {e}", file=sys.stderr)
        sys.exit(1)


def stream_tokens(base_url, question, model):
    """Yield content tokens from the streaming API."""
    try:
        resp = _request(
            f"{base_url}/v1/chat/completions",
            data={
                "model": model,
                "messages": [{"role": "user", "content": question}],
                "temperature": 0.6,
                "top_p": 0.95,
                "max_tokens": 4096,
                "stream": True,
            },
            timeout=300,
        )
    except urllib.error.HTTPError as e:
        print(f"Error: server returned {e.code}: {e.read().decode()}", file=sys.stderr)
        sys.exit(1)
    except urllib.error.URLError as e:
        print(f"Error: cannot connect to {base_url}: {e.reason}", file=sys.stderr)
        sys.exit(1)

    # Read SSE stream line by line
    for raw_line in resp:
        line = raw_line.decode().rstrip("\n\r")
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
    # HPC nodes often lack UTF-8 locale — avoid UnicodeEncodeError on emojis
    import io
    if (sys.stdout.encoding
            and sys.stdout.encoding.lower() not in ("utf-8", "utf8")
            and hasattr(sys.stdout, "buffer")):
        sys.stdout = io.TextIOWrapper(
            sys.stdout.buffer, encoding=sys.stdout.encoding, errors="replace"
        )
        if hasattr(sys.stderr, "buffer"):
            sys.stderr = io.TextIOWrapper(
                sys.stderr.buffer, encoding=sys.stderr.encoding, errors="replace"
            )

    llm_url = os.environ.get("LLM_URL", DEFAULT_URL)

    parser = argparse.ArgumentParser(
        description="Stream inference from a vLLM endpoint.",
        epilog="The endpoint URL can also be set via the LLM_URL environment variable.",
    )
    parser.add_argument("question", nargs="?", help="Question to send to the model")
    parser.add_argument(
        "--url", default=llm_url,
        help=f"Endpoint URL (default: LLM_URL env or {DEFAULT_URL})",
    )
    parser.add_argument(
        "--list", "-l", action="store_true",
        help="List models available on the endpoint",
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
        print("Error: no model loaded on the endpoint", file=sys.stderr)
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
