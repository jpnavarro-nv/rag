#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Sequential LLM benchmark for NIM and vLLM endpoints.

Measures single-request latency and throughput for all active models
on the cluster. Prompts are loaded from benchmark_prompts.json.

Usage:
    python scripts/benchmark_models.py --endpoints node1:8000 node2:8000
    python scripts/benchmark_models.py --discover          # auto-detect from nim.env
    python scripts/benchmark_models.py --help

No external dependencies — uses only Python standard library.
"""

import argparse
import glob
import io
import json
import os
import socket
import statistics
import subprocess
import sys
import time
import urllib.error
import urllib.request
from dataclasses import dataclass, field, asdict
from datetime import datetime
from pathlib import Path

# =============================================================================
# Constants
# =============================================================================
SCRIPT_DIR = Path(__file__).resolve().parent
DEFAULT_PROMPTS = SCRIPT_DIR / "benchmark_prompts.json"
THINK_OPEN = "<think>"
THINK_CLOSE = "</think>"
WARMUP_PROMPT = "Hello, respond with a single short sentence."
DEFAULT_MAX_TOKENS = 8192
DEFAULT_TIMEOUT = 300
DEFAULT_TEMPERATURE = 0
WARMUP_COUNT = 3


# =============================================================================
# Data structures
# =============================================================================
@dataclass
class EndpointInfo:
    model_key: str
    model_id: str
    endpoint: str
    backend: str
    node: str
    port: str
    sif_name: str = ""
    slurm_job_id: str = ""


@dataclass
class Prompt:
    id: str
    name: str
    category: str
    content: str


@dataclass
class BenchmarkResult:
    model_key: str
    backend: str
    prompt_id: str
    prompt_name: str
    prompt_category: str
    status: str  # ok | error | timeout
    error_message: str = ""
    ttft_ms: float = -1
    ttfa_ms: float = -1  # time to first answer (after </think>)
    e2e_s: float = -1
    gen_s: float = -1  # generation time (first token to last)
    output_tokens: int = 0
    prompt_tokens: int = 0
    total_tokens: int = 0
    output_tok_s: float = 0
    prefill_tok_s: float = 0
    tpot_ms: float = 0  # mean time per output token
    thinking_s: float = 0
    think_tokens_est: int = 0
    answer_tokens_est: int = 0


# =============================================================================
# HTTP helpers
# =============================================================================
def _request(url, data=None, timeout=10):
    headers = {"Content-Type": "application/json"} if data else {}
    body = json.dumps(data).encode() if data else None
    req = urllib.request.Request(url, data=body, headers=headers)
    return urllib.request.urlopen(req, timeout=timeout)


def _check_health(endpoint_url, timeout=5):
    for path in ["/health", "/v1/health/ready"]:
        try:
            resp = _request(f"{endpoint_url}{path}", timeout=timeout)
            if resp.status == 200:
                return True
        except Exception:
            continue
    return False


def _detect_model(endpoint_url, timeout=10):
    try:
        resp = _request(f"{endpoint_url}/v1/models", timeout=timeout)
        data = json.loads(resp.read().decode())
        models = data.get("data", [])
        if models:
            return models[0]["id"]
    except Exception:
        pass
    return None


# =============================================================================
# Endpoint discovery
# =============================================================================
def discover_endpoints(sessions_dir):
    active_jobs = set()
    try:
        out = subprocess.check_output(
            ["squeue", "--noheader", "--format=%i"],
            text=True, timeout=10
        )
        for line in out.strip().split("\n"):
            jid = line.strip()
            if jid:
                active_jobs.add(jid)
    except (subprocess.CalledProcessError, FileNotFoundError):
        pass

    endpoints = []
    for env_file in sorted(glob.glob(f"{sessions_dir}/*/job_*/nim.env")):
        job_dir = os.path.dirname(env_file)
        job_id = os.path.basename(job_dir).replace("job_", "")

        if active_jobs and job_id not in active_jobs:
            continue

        meta = {}
        try:
            with open(env_file) as f:
                for line in f:
                    line = line.strip()
                    if "=" in line and not line.startswith("#"):
                        k, v = line.split("=", 1)
                        meta[k] = v
        except OSError:
            continue

        ep = EndpointInfo(
            model_key=meta.get("MODEL_KEY", "unknown"),
            model_id=meta.get("MODEL_ID", ""),
            endpoint=meta.get("ENDPOINT", ""),
            backend=meta.get("BACKEND", "unknown"),
            node=meta.get("NODE", ""),
            port=meta.get("PORT", "8000"),
            sif_name=meta.get("SIF_NAME", ""),
            slurm_job_id=meta.get("SLURM_JOB_ID", job_id),
        )
        if ep.endpoint:
            endpoints.append(ep)

    return endpoints


def parse_endpoint_args(endpoint_strs):
    endpoints = []
    for s in endpoint_strs:
        if "://" in s:
            url = s.rstrip("/")
        else:
            url = f"http://{s}"

        model_id = _detect_model(url, timeout=10)
        ep = EndpointInfo(
            model_key=model_id or url.split("//")[1].split(":")[0],
            model_id=model_id or "unknown",
            endpoint=url,
            backend="unknown",
            node=url.split("//")[1].split(":")[0],
            port=url.split(":")[-1].split("/")[0],
        )
        endpoints.append(ep)
    return endpoints


# =============================================================================
# Prompt loading
# =============================================================================
def load_prompts(path):
    with open(path) as f:
        data = json.load(f)
    return [
        Prompt(
            id=p["id"],
            name=p["name"],
            category=p["category"],
            content=p["content"],
        )
        for p in data["prompts"]
    ]


# =============================================================================
# Core benchmark
# =============================================================================
def run_single(endpoint, prompt, max_tokens, timeout, temperature):
    payload = {
        "model": endpoint.model_id,
        "messages": [{"role": "user", "content": prompt.content}],
        "max_tokens": max_tokens,
        "temperature": temperature,
        "stream": True,
        "stream_options": {"include_usage": True},
    }

    t_start = time.monotonic()
    try:
        resp = _request(
            f"{endpoint.endpoint}/v1/chat/completions",
            data=payload,
            timeout=timeout,
        )
    except urllib.error.HTTPError as e:
        return BenchmarkResult(
            model_key=endpoint.model_key, backend=endpoint.backend,
            prompt_id=prompt.id, prompt_name=prompt.name,
            prompt_category=prompt.category, status="error",
            error_message=f"HTTP {e.code}: {e.read().decode()[:200]}",
        )
    except (urllib.error.URLError, OSError) as e:
        return BenchmarkResult(
            model_key=endpoint.model_key, backend=endpoint.backend,
            prompt_id=prompt.id, prompt_name=prompt.name,
            prompt_category=prompt.category, status="error",
            error_message=str(e),
        )

    t_first_token = None
    t_first_answer = None
    t_think_start = None
    t_think_end = None
    phase = "detect"
    buf = ""
    thinking_chars = 0
    answer_chars = 0
    usage = None
    token_count = 0

    try:
        for raw_line in resp:
            line = raw_line.decode().rstrip("\n\r")
            if not line.startswith("data: "):
                continue
            data_str = line[6:]
            if data_str == "[DONE]":
                break

            try:
                chunk = json.loads(data_str)
            except json.JSONDecodeError:
                continue

            if "usage" in chunk and chunk["usage"]:
                usage = chunk["usage"]

            choices = chunk.get("choices", [])
            if not choices:
                continue
            delta = choices[0].get("delta", {})
            content = delta.get("content", "")
            if not content:
                continue

            now = time.monotonic()
            token_count += 1

            if t_first_token is None:
                t_first_token = now

            # Think/answer state machine
            if phase == "detect":
                buf += content
                if THINK_OPEN in buf:
                    phase = "thinking"
                    t_think_start = now
                    buf = buf[buf.index(THINK_OPEN) + len(THINK_OPEN):]
                    thinking_chars += len(buf)
                elif len(buf) > len(THINK_OPEN):
                    phase = "answering"
                    answer_chars += len(buf)
                    if t_first_answer is None:
                        t_first_answer = t_first_token
                    buf = ""
            elif phase == "thinking":
                buf += content
                thinking_chars += len(content)
                if THINK_CLOSE in buf:
                    phase = "answering"
                    t_think_end = now
                    after = buf[buf.index(THINK_CLOSE) + len(THINK_CLOSE):]
                    answer_chars += len(after)
                    if after.strip() and t_first_answer is None:
                        t_first_answer = now
                    buf = ""
            elif phase == "answering":
                answer_chars += len(content)
                if t_first_answer is None:
                    t_first_answer = now
    except Exception as e:
        return BenchmarkResult(
            model_key=endpoint.model_key, backend=endpoint.backend,
            prompt_id=prompt.id, prompt_name=prompt.name,
            prompt_category=prompt.category, status="error",
            error_message=f"Stream error: {e}",
        )

    t_end = time.monotonic()

    # Compute metrics
    e2e = t_end - t_start
    ttft = (t_first_token - t_start) if t_first_token else e2e
    ttfa = (t_first_answer - t_start) if t_first_answer else ttft
    gen_time = (t_end - t_first_token) if t_first_token else 0
    thinking_time = ((t_think_end or t_end) - t_think_start) if t_think_start else 0

    # Token counts from API usage (preferred) or fallback to chunk count
    output_tokens = 0
    prompt_tokens_count = 0
    if usage:
        output_tokens = usage.get("completion_tokens", 0)
        prompt_tokens_count = usage.get("prompt_tokens", 0)
    if output_tokens == 0:
        output_tokens = token_count

    total_tokens = prompt_tokens_count + output_tokens

    # Apportion thinking vs answer tokens
    total_chars = thinking_chars + answer_chars
    if total_chars > 0 and output_tokens > 0:
        think_tokens = int(output_tokens * thinking_chars / total_chars)
        answer_tokens = output_tokens - think_tokens
    else:
        think_tokens = 0
        answer_tokens = output_tokens

    # Throughput
    output_tok_s = output_tokens / gen_time if gen_time > 0 else 0
    prefill_tok_s = prompt_tokens_count / ttft if ttft > 0 and prompt_tokens_count > 0 else 0
    tpot = (gen_time / output_tokens * 1000) if output_tokens > 0 else 0

    return BenchmarkResult(
        model_key=endpoint.model_key,
        backend=endpoint.backend,
        prompt_id=prompt.id,
        prompt_name=prompt.name,
        prompt_category=prompt.category,
        status="ok",
        ttft_ms=ttft * 1000,
        ttfa_ms=ttfa * 1000,
        e2e_s=e2e,
        gen_s=gen_time,
        output_tokens=output_tokens,
        prompt_tokens=prompt_tokens_count,
        total_tokens=total_tokens,
        output_tok_s=output_tok_s,
        prefill_tok_s=prefill_tok_s,
        tpot_ms=tpot,
        thinking_s=thinking_time,
        think_tokens_est=think_tokens,
        answer_tokens_est=answer_tokens,
    )


def warm_up(endpoint, max_tokens, timeout, temperature):
    sys.stderr.write(f"  Warming up {endpoint.model_key}... ")
    sys.stderr.flush()
    dummy = Prompt(id="warmup", name="warmup", category="warmup",
                   content=WARMUP_PROMPT)
    for i in range(WARMUP_COUNT):
        run_single(endpoint, dummy, max_tokens=256, timeout=timeout,
                   temperature=temperature)
    sys.stderr.write("done\n")
    sys.stderr.flush()


# =============================================================================
# Statistics helpers
# =============================================================================
def _percentile(data, p):
    if not data:
        return 0
    sorted_data = sorted(data)
    k = (len(sorted_data) - 1) * p / 100
    f = int(k)
    c = f + 1 if f + 1 < len(sorted_data) else f
    return sorted_data[f] + (k - f) * (sorted_data[c] - sorted_data[f])


def compute_stats(values):
    if not values:
        return {"mean": 0, "median": 0, "p90": 0, "p99": 0, "std": 0,
                "min": 0, "max": 0}
    return {
        "mean": statistics.mean(values),
        "median": statistics.median(values),
        "p90": _percentile(values, 90),
        "p99": _percentile(values, 99),
        "std": statistics.stdev(values) if len(values) > 1 else 0,
        "min": min(values),
        "max": max(values),
    }


# =============================================================================
# Environment info
# =============================================================================
def collect_env_info(endpoints):
    info = {
        "timestamp": datetime.now().isoformat(),
        "hostname": socket.gethostname(),
        "gpu": {},
        "models": [],
    }
    # Try nvidia-smi on local machine (may be login node, not GPU node)
    try:
        out = subprocess.check_output(
            ["nvidia-smi", "--query-gpu=name,memory.total,driver_version",
             "--format=csv,noheader"],
            text=True, timeout=10,
        )
        lines = [l.strip() for l in out.strip().split("\n") if l.strip()]
        if lines:
            parts = lines[0].split(", ")
            info["gpu"] = {
                "name": parts[0] if len(parts) > 0 else "unknown",
                "memory": parts[1] if len(parts) > 1 else "unknown",
                "driver": parts[2] if len(parts) > 2 else "unknown",
            }
            info["gpu"]["count_per_node"] = len(lines)
    except (subprocess.CalledProcessError, FileNotFoundError):
        info["gpu"] = {"name": "unavailable (run on GPU node for details)"}

    try:
        out = subprocess.check_output(
            ["nvidia-smi"], text=True, timeout=10,
        )
        for line in out.split("\n"):
            if "CUDA Version" in line:
                cuda_ver = line.split("CUDA Version:")[1].strip().split()[0]
                info["gpu"]["cuda_version"] = cuda_ver
                break
    except (subprocess.CalledProcessError, FileNotFoundError):
        pass

    for ep in endpoints:
        info["models"].append({
            "model_key": ep.model_key,
            "model_id": ep.model_id,
            "backend": ep.backend,
            "node": ep.node,
            "port": ep.port,
            "sif_name": ep.sif_name,
            "endpoint": ep.endpoint,
        })

    return info


# =============================================================================
# Output formatting
# =============================================================================
def fmt_table(headers, rows, col_widths=None):
    if not col_widths:
        col_widths = []
        for i, h in enumerate(headers):
            w = len(h)
            for row in rows:
                w = max(w, len(str(row[i])))
            col_widths.append(w + 2)

    sep = "  "
    header_line = sep.join(str(h).ljust(w) for h, w in zip(headers, col_widths))
    divider = sep.join("-" * w for w in col_widths)
    lines = [header_line, divider]
    for row in rows:
        lines.append(sep.join(str(v).ljust(w) for v, w in zip(row, col_widths)))
    return "\n".join(lines)


def print_per_sample_table(results, endpoints):
    ep_map = {ep.model_key: ep for ep in endpoints}
    model_keys = list(dict.fromkeys(r.model_key for r in results))

    # Group by prompt
    prompts_seen = []
    prompt_ids = set()
    for r in results:
        if r.prompt_id not in prompt_ids and r.status == "ok":
            prompts_seen.append((r.prompt_id, r.prompt_name, r.prompt_category))
            prompt_ids.add(r.prompt_id)

    headers = ["Model", "TTFT(ms)", "Gen(s)", "E2E(s)", "OutTok",
               "Tok/s", "TPOT(ms)", "Think(s)"]

    for pid, pname, pcat in prompts_seen:
        print(f"\n  [{pcat}] {pname}")
        print(f"  {'-' * 70}")
        rows = []
        for mk in model_keys:
            match = [r for r in results
                     if r.model_key == mk and r.prompt_id == pid]
            if not match:
                continue
            r = match[0]
            if r.status != "ok":
                rows.append([mk, "ERR", "-", "-", "-", "-", "-", "-"])
                continue
            think_str = f"{r.thinking_s:.1f}" if r.thinking_s > 0.1 else "-"
            rows.append([
                mk,
                f"{r.ttft_ms:.0f}",
                f"{r.gen_s:.1f}",
                f"{r.e2e_s:.1f}",
                str(r.output_tokens),
                f"{r.output_tok_s:.1f}",
                f"{r.tpot_ms:.1f}",
                think_str,
            ])
        col_widths = [18, 10, 8, 8, 8, 8, 10, 10]
        print(f"  {fmt_table(headers, rows, col_widths)}")


def print_summary_table(results, endpoints):
    model_keys = list(dict.fromkeys(r.model_key for r in results))

    print("\n" + "=" * 80)
    print("SUMMARY (across all prompts)")
    print("=" * 80)

    headers = ["Model", "Backend", "TTFT(ms)", "Tok/s", "E2E(s)",
               "TPOT(ms)", "Samples", "Errors"]

    rows = []
    for mk in model_keys:
        model_results = [r for r in results if r.model_key == mk]
        ok_results = [r for r in model_results if r.status == "ok"]
        errors = len(model_results) - len(ok_results)
        backend = model_results[0].backend if model_results else "?"

        if not ok_results:
            rows.append([mk, backend, "-", "-", "-", "-", "0", str(errors)])
            continue

        ttft_stats = compute_stats([r.ttft_ms for r in ok_results])
        toks_stats = compute_stats([r.output_tok_s for r in ok_results])
        e2e_stats = compute_stats([r.e2e_s for r in ok_results])
        tpot_stats = compute_stats([r.tpot_ms for r in ok_results])

        rows.append([
            mk,
            backend,
            f"{ttft_stats['median']:.0f}",
            f"{toks_stats['median']:.1f}",
            f"{e2e_stats['median']:.1f}",
            f"{tpot_stats['median']:.1f}",
            str(len(ok_results)),
            str(errors),
        ])

    col_widths = [18, 8, 10, 8, 8, 10, 9, 8]
    print(fmt_table(headers, rows, col_widths))


def print_detailed_stats(results):
    model_keys = list(dict.fromkeys(r.model_key for r in results))

    print("\n" + "=" * 80)
    print("DETAILED STATISTICS")
    print("=" * 80)

    for mk in model_keys:
        ok = [r for r in results if r.model_key == mk and r.status == "ok"]
        if not ok:
            continue

        print(f"\n  {mk}")
        print(f"  {'-' * 70}")

        metrics = [
            ("TTFT (ms)", [r.ttft_ms for r in ok]),
            ("E2E Latency (s)", [r.e2e_s for r in ok]),
            ("Output Tok/s", [r.output_tok_s for r in ok]),
            ("TPOT (ms/tok)", [r.tpot_ms for r in ok]),
            ("Output Tokens", [float(r.output_tokens) for r in ok]),
        ]

        # Add prefill if data available
        prefill = [r.prefill_tok_s for r in ok if r.prefill_tok_s > 0]
        if prefill:
            metrics.append(("Prefill Tok/s", prefill))

        # Add thinking if any model thinks
        think = [r.thinking_s for r in ok if r.thinking_s > 0.1]
        if think:
            metrics.append(("Think Time (s)", think))

        headers = ["Metric", "Mean", "Median", "P90", "P99", "Std", "Min", "Max"]
        rows = []
        for name, vals in metrics:
            s = compute_stats(vals)
            rows.append([
                name,
                f"{s['mean']:.1f}",
                f"{s['median']:.1f}",
                f"{s['p90']:.1f}",
                f"{s['p99']:.1f}",
                f"{s['std']:.1f}",
                f"{s['min']:.1f}",
                f"{s['max']:.1f}",
            ])

        col_widths = [18, 10, 10, 10, 10, 10, 10, 10]
        print(f"  {fmt_table(headers, rows, col_widths)}")


def print_environment(env_info):
    print("\n" + "=" * 80)
    print("ENVIRONMENT")
    print("=" * 80)
    gpu = env_info.get("gpu", {})
    print(f"  Benchmark host:  {env_info.get('hostname', 'unknown')}")
    print(f"  Timestamp:       {env_info.get('timestamp', 'unknown')}")
    if isinstance(gpu, dict) and gpu.get("name"):
        print(f"  GPU:             {gpu.get('name', 'N/A')}")
        if gpu.get("memory"):
            print(f"  GPU Memory:      {gpu.get('memory', 'N/A')}")
        if gpu.get("count_per_node"):
            print(f"  GPUs/Node:       {gpu.get('count_per_node', 'N/A')}")
        if gpu.get("driver"):
            print(f"  Driver:          {gpu.get('driver', 'N/A')}")
        if gpu.get("cuda_version"):
            print(f"  CUDA:            {gpu.get('cuda_version', 'N/A')}")

    print("\n  Models:")
    for m in env_info.get("models", []):
        print(f"    {m['model_key']:18s}  backend={m['backend']:5s}  "
              f"node={m['node']}:{m['port']}  sif={m.get('sif_name', 'N/A')}")


def export_json(results, env_info, path):
    data = {
        "environment": env_info,
        "results": [asdict(r) for r in results],
    }
    with open(path, "w") as f:
        json.dump(data, f, indent=2)
    print(f"\n  JSON exported: {path}")


def export_csv(results, path):
    if not results:
        return
    fields = list(asdict(results[0]).keys())
    with open(path, "w") as f:
        f.write(",".join(fields) + "\n")
        for r in results:
            d = asdict(r)
            row = []
            for fld in fields:
                v = d[fld]
                if isinstance(v, str):
                    v = f'"{v}"'
                else:
                    v = str(v)
                row.append(v)
            f.write(",".join(row) + "\n")
    print(f"  CSV exported:  {path}")


# =============================================================================
# Main
# =============================================================================
def main():
    # UTF-8 safety for HPC nodes
    if (sys.stdout.encoding
            and sys.stdout.encoding.lower() not in ("utf-8", "utf8")
            and hasattr(sys.stdout, "buffer")):
        sys.stdout = io.TextIOWrapper(
            sys.stdout.buffer, encoding=sys.stdout.encoding, errors="replace")
        if hasattr(sys.stderr, "buffer"):
            sys.stderr = io.TextIOWrapper(
                sys.stderr.buffer, encoding=sys.stderr.encoding, errors="replace")

    parser = argparse.ArgumentParser(
        description="Sequential LLM benchmark for NIM/vLLM endpoints.",
    )
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument(
        "--endpoints", nargs="+", metavar="HOST:PORT",
        help="Endpoint URLs (e.g., node1:8000 node2:8000)",
    )
    group.add_argument(
        "--discover", action="store_true",
        help="Auto-discover endpoints from $NIM_BASE_DIR/sessions/",
    )
    parser.add_argument(
        "--prompts", default=str(DEFAULT_PROMPTS),
        help=f"Prompts JSON file (default: {DEFAULT_PROMPTS.name})",
    )
    parser.add_argument(
        "--max-tokens", type=int, default=DEFAULT_MAX_TOKENS,
        help=f"Max tokens per response (default: {DEFAULT_MAX_TOKENS})",
    )
    parser.add_argument(
        "--timeout", type=int, default=DEFAULT_TIMEOUT,
        help=f"Per-request timeout in seconds (default: {DEFAULT_TIMEOUT})",
    )
    parser.add_argument(
        "--temperature", type=float, default=DEFAULT_TEMPERATURE,
        help=f"Sampling temperature (default: {DEFAULT_TEMPERATURE})",
    )
    parser.add_argument(
        "--no-warmup", action="store_true",
        help="Skip warm-up requests",
    )
    parser.add_argument(
        "--output-json", metavar="FILE",
        help="Export raw results as JSON",
    )
    parser.add_argument(
        "--output-csv", metavar="FILE",
        help="Export raw results as CSV",
    )
    parser.add_argument(
        "--quiet", action="store_true",
        help="Summary only (skip per-prompt tables)",
    )

    args = parser.parse_args()

    # Discover or parse endpoints
    if args.discover:
        nim_base = os.environ.get("NIM_BASE_DIR")
        if not nim_base:
            print("ERROR: NIM_BASE_DIR must be set for --discover", file=sys.stderr)
            sys.exit(1)
        sessions_dir = f"{nim_base}/sessions"
        endpoints = discover_endpoints(sessions_dir)
        if not endpoints:
            print("ERROR: No active endpoints found.", file=sys.stderr)
            print("Check NIM_BASE_DIR and ensure models are running.", file=sys.stderr)
            sys.exit(1)
    else:
        endpoints = parse_endpoint_args(args.endpoints)

    # Load prompts
    try:
        prompts = load_prompts(args.prompts)
    except (OSError, json.JSONDecodeError) as e:
        print(f"ERROR: Cannot load prompts from {args.prompts}: {e}",
              file=sys.stderr)
        sys.exit(1)

    # Collect environment info
    env_info = collect_env_info(endpoints)

    # Header
    print("=" * 80)
    print(f"LLM BENCHMARK — {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
    print("=" * 80)
    print(f"  Prompts:     {len(prompts)} from {args.prompts}")
    print(f"  Models:      {len(endpoints)}")
    print(f"  Max tokens:  {args.max_tokens}")
    print(f"  Temperature: {args.temperature}")
    print(f"  Timeout:     {args.timeout}s")
    print()

    # Health check
    healthy = []
    for ep in endpoints:
        sys.stderr.write(f"  Checking {ep.model_key} at {ep.endpoint}... ")
        sys.stderr.flush()
        if _check_health(ep.endpoint):
            # Auto-detect model_id if not set
            if not ep.model_id or ep.model_id == "unknown":
                detected = _detect_model(ep.endpoint)
                if detected:
                    ep.model_id = detected
            sys.stderr.write(f"OK ({ep.model_id})\n")
            healthy.append(ep)
        else:
            sys.stderr.write("UNREACHABLE — skipping\n")
    sys.stderr.flush()

    if not healthy:
        print("\nERROR: No healthy endpoints found.", file=sys.stderr)
        sys.exit(1)

    # Warm-up
    if not args.no_warmup:
        print()
        for ep in healthy:
            warm_up(ep, args.max_tokens, args.timeout, args.temperature)
        print()

    # Run benchmark
    all_results = []
    total = len(healthy) * len(prompts)
    current = 0

    for ep in healthy:
        print(f"  Benchmarking {ep.model_key} ({ep.backend})...")
        for prompt in prompts:
            current += 1
            sys.stderr.write(
                f"\r  [{current}/{total}] {ep.model_key}: {prompt.id}...        "
            )
            sys.stderr.flush()

            result = run_single(
                ep, prompt, args.max_tokens, args.timeout, args.temperature
            )
            all_results.append(result)

            if result.status == "ok":
                sys.stderr.write(
                    f"\r  [{current}/{total}] {ep.model_key}: {prompt.id} "
                    f"— {result.ttft_ms:.0f}ms TTFT, "
                    f"{result.output_tok_s:.1f} tok/s, "
                    f"{result.e2e_s:.1f}s E2E\n"
                )
            else:
                sys.stderr.write(
                    f"\r  [{current}/{total}] {ep.model_key}: {prompt.id} "
                    f"— {result.status}: {result.error_message[:60]}\n"
                )
            sys.stderr.flush()
        print()

    # Output
    print("\n" + "=" * 80)
    print("RESULTS")
    print("=" * 80)

    if not args.quiet:
        print_per_sample_table(all_results, healthy)

    print_summary_table(all_results, healthy)
    print_detailed_stats(all_results)
    print_environment(env_info)

    # Export
    if args.output_json:
        export_json(all_results, env_info, args.output_json)
    if args.output_csv:
        export_csv(all_results, args.output_csv)

    # Final counts
    ok_count = sum(1 for r in all_results if r.status == "ok")
    err_count = sum(1 for r in all_results if r.status != "ok")
    print(f"\n  Total: {ok_count} OK, {err_count} errors out of {len(all_results)} requests")
    print()


if __name__ == "__main__":
    main()
