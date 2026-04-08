#!/usr/bin/env python3
"""Stream inference from a local NIM LLM. Reasoning is enabled but hidden.

Usage:
    python run_inference.py "Qual a capital do Brasil?"
    python run_inference.py --list          # show supported models
    python run_inference.py --help          # usage help

Requires: pip install requests
"""

import sys
import json
import requests

NIM_URL = "http://localhost:8999"
COMPLETIONS_URL = f"{NIM_URL}/v1/chat/completions"
MODELS_URL = f"{NIM_URL}/v1/models"

THINK_OPEN = "<think>"
THINK_CLOSE = "</think>"

# Supported models (for --list display only; the script auto-detects the running model)
SUPPORTED_MODELS = [
    ("nemotron-49b", "nvidia/llama-3.3-nemotron-super-49b-v1.5", "Nemotron Super 49B"),
    ("qwen3-122b", "qwen/qwen3.5-122b-a10b", "Qwen 3.5 122B-A10B MoE"),
    ("gpt-oss-120b", "openai/gpt-oss-120b", "GPT-OSS 120B MoE"),
    ("nemotron3-120b", "nvidia/nemotron-3-super-120b-a12b", "Nemotron-3 Super 120B MoE"),
]


def show_help():
    print("Usage: python run_inference.py [OPTIONS] \"Your question here\"")
    print("")
    print("Options:")
    print("  --list, -l    Show supported models")
    print("  --help, -h    Show this help message")
    print("")
    print("Examples:")
    print("  python run_inference.py \"Qual a capital do Brasil?\"")
    print("  python run_inference.py \"Explain quantum entanglement in simple terms\"")
    print("")
    print("The script auto-detects which model is running on localhost:8999.")
    print("Start a model first with: ./run-nim.sh [MODEL]")


def show_models():
    print("Supported models (start with ./run-nim.sh [KEY]):")
    print("")
    for key, api_name, desc in SUPPORTED_MODELS:
        print(f"  {key:<18s} {desc:<28s} ({api_name})")
    print("")
    print("The script auto-detects the running model via /v1/models endpoint.")


def detect_model():
    """Query the NIM to find which model is loaded."""
    try:
        resp = requests.get(MODELS_URL, timeout=5)
        resp.raise_for_status()
        data = resp.json()
        models = data.get("data", [])
        if models:
            return models[0]["id"]
    except requests.ConnectionError:
        print(f"Error: cannot connect to NIM at {NIM_URL}", file=sys.stderr)
        print("Is the NIM running? Start it with: ./run-nim.sh", file=sys.stderr)
        sys.exit(1)
    except requests.Timeout:
        print(f"Error: connection to {NIM_URL} timed out", file=sys.stderr)
        sys.exit(1)
    except (requests.HTTPError, KeyError, IndexError) as e:
        print(f"Error querying NIM models endpoint: {e}", file=sys.stderr)
        sys.exit(1)
    return None


def stream_tokens(question, model):
    """Yield content tokens from the NIM streaming API."""
    try:
        resp = requests.post(
            COMPLETIONS_URL,
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
        print(f"Error: cannot connect to NIM at {NIM_URL}", file=sys.stderr)
        print("Is the NIM running? Start it with: ./run-nim.sh", file=sys.stderr)
        sys.exit(1)
    except requests.Timeout:
        print(f"Error: connection to {NIM_URL} timed out", file=sys.stderr)
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
    if len(sys.argv) < 2 or sys.argv[1] in ("--help", "-h"):
        show_help()
        sys.exit(0 if len(sys.argv) >= 2 else 1)

    if sys.argv[1] in ("--list", "-l"):
        show_models()
        sys.exit(0)

    question = sys.argv[1]

    # Auto-detect running model
    model = detect_model()
    if not model:
        print("Error: no model loaded on the NIM endpoint", file=sys.stderr)
        sys.exit(1)

    sys.stderr.write(f"Model: {model}\n")
    sys.stderr.flush()

    buf = ""
    phase = "detect"  # detect -> thinking -> answering

    for token in stream_tokens(question, model):
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
                sys.stderr.write("Pensando... ")
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
            sys.stderr.write("pronto.\n")
            sys.stderr.flush()
            if after:
                print(after, end="", flush=True)

    if buf and phase != "thinking":
        print(buf, end="", flush=True)

    print()


if __name__ == "__main__":
    main()
