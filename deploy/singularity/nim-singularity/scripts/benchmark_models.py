#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Sequential and concurrent LLM benchmark for vLLM endpoints.

Sweeps concurrency levels (default: 1, 2, 5, 10, 50) to produce a
throughput-vs-concurrency curve for each active model on the cluster.

Usage:
    python3 scripts/benchmark_models.py --discover
    python3 scripts/benchmark_models.py --endpoints node1:8000 node2:8000
    python3 scripts/benchmark_models.py --discover --concurrency 1,5,50
    python3 scripts/benchmark_models.py --help

Requires Python 3.6+. No external dependencies — uses only Python standard library.
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
import threading
import time
import urllib.error
import urllib.request
from collections import OrderedDict
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime

# =============================================================================
# Constants
# =============================================================================
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
DEFAULT_PROMPTS = os.path.join(SCRIPT_DIR, "benchmark_prompts.json")
THINK_OPEN = "<think>"
THINK_CLOSE = "</think>"
WARMUP_PROMPT = "Hello, respond with a single short sentence."
DEFAULT_MAX_TOKENS = 8192
DEFAULT_TIMEOUT = 300
DEFAULT_TEMPERATURE = 0
WARMUP_COUNT = 3
DEFAULT_CONCURRENCY = [1, 2, 5, 10, 50]
CHART_COLORS = ["#2563eb", "#dc2626", "#16a34a", "#9333ea", "#ea580c"]

_RESULT_FIELDS = [
    "concurrency", "model_key", "backend", "prompt_id", "prompt_name",
    "prompt_category", "status", "error_message", "ttft_ms", "ttfa_ms",
    "e2e_s", "gen_s", "output_tokens", "prompt_tokens", "total_tokens",
    "output_tok_s", "prefill_tok_s", "tpot_ms", "thinking_s",
    "think_tokens_est", "answer_tokens_est",
]


# =============================================================================
# Data structures (plain classes for Python 3.6 compatibility)
# =============================================================================
class EndpointInfo(object):
    def __init__(self, model_key="", model_id="", endpoint="", backend="",
                 node="", port="", sif_name="", slurm_job_id=""):
        self.model_key = model_key
        self.model_id = model_id
        self.endpoint = endpoint
        self.backend = backend
        self.node = node
        self.port = port
        self.sif_name = sif_name
        self.slurm_job_id = slurm_job_id


class Prompt(object):
    def __init__(self, id="", name="", category="", content=""):
        self.id = id
        self.name = name
        self.category = category
        self.content = content


class BenchmarkResult(object):
    def __init__(self, concurrency=1, model_key="", backend="",
                 prompt_id="", prompt_name="", prompt_category="",
                 status="", error_message="",
                 ttft_ms=-1, ttfa_ms=-1, e2e_s=-1, gen_s=-1,
                 output_tokens=0, prompt_tokens=0, total_tokens=0,
                 output_tok_s=0, prefill_tok_s=0, tpot_ms=0,
                 thinking_s=0, think_tokens_est=0, answer_tokens_est=0):
        self.concurrency = concurrency
        self.model_key = model_key
        self.backend = backend
        self.prompt_id = prompt_id
        self.prompt_name = prompt_name
        self.prompt_category = prompt_category
        self.status = status
        self.error_message = error_message
        self.ttft_ms = ttft_ms
        self.ttfa_ms = ttfa_ms
        self.e2e_s = e2e_s
        self.gen_s = gen_s
        self.output_tokens = output_tokens
        self.prompt_tokens = prompt_tokens
        self.total_tokens = total_tokens
        self.output_tok_s = output_tok_s
        self.prefill_tok_s = prefill_tok_s
        self.tpot_ms = tpot_ms
        self.thinking_s = thinking_s
        self.think_tokens_est = think_tokens_est
        self.answer_tokens_est = answer_tokens_est

    def to_dict(self):
        return {f: getattr(self, f) for f in _RESULT_FIELDS}


class ConcurrencyResult(object):
    def __init__(self, concurrency, results, system_tok_s, requests_per_s,
                 wall_time_s):
        self.concurrency = concurrency
        self.results = results
        self.system_tok_s = system_tok_s
        self.requests_per_s = requests_per_s
        self.wall_time_s = wall_time_s


# =============================================================================
# HTTP helpers
# =============================================================================
def _request(url, data=None, timeout=10):
    headers = {"Content-Type": "application/json"} if data else {}
    body = json.dumps(data).encode() if data else None
    req = urllib.request.Request(url, data=body, headers=headers)
    return urllib.request.urlopen(req, timeout=timeout)


def _check_health(endpoint_url, timeout=5):
    try:
        resp = _request(f"{endpoint_url}/health", timeout=timeout)
        return resp.status == 200
    except Exception:
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
            universal_newlines=True, timeout=10
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
                        v = v.strip('"')
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
    with open(path, encoding="utf-8") as f:
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


def select_prompts(prompts, max_prompts):
    """Select up to max_prompts using round-robin across categories."""
    if max_prompts is None or max_prompts >= len(prompts):
        return prompts

    # Group by category, preserving order within each category
    by_cat = OrderedDict()
    for p in prompts:
        by_cat.setdefault(p.category, []).append(p)

    selected = []
    iterators = {cat: iter(ps) for cat, ps in by_cat.items()}
    while len(selected) < max_prompts:
        for cat in list(iterators):
            if len(selected) >= max_prompts:
                break
            try:
                selected.append(next(iterators[cat]))
            except StopIteration:
                del iterators[cat]
    return selected


# =============================================================================
# Core benchmark (single request)
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

    e2e = t_end - t_start
    ttft = (t_first_token - t_start) if t_first_token else e2e
    ttfa = (t_first_answer - t_start) if t_first_answer else ttft
    gen_time = (t_end - t_first_token) if t_first_token else 0
    thinking_time = (
        (t_think_end or t_end) - t_think_start) if t_think_start else 0

    output_tokens = 0
    prompt_tokens_count = 0
    if usage:
        output_tokens = usage.get("completion_tokens", 0)
        prompt_tokens_count = usage.get("prompt_tokens", 0)
    if output_tokens == 0:
        output_tokens = token_count

    total_tokens = prompt_tokens_count + output_tokens

    total_chars = thinking_chars + answer_chars
    if total_chars > 0 and output_tokens > 0:
        think_tokens = int(output_tokens * thinking_chars / total_chars)
        answer_tokens = output_tokens - think_tokens
    else:
        think_tokens = 0
        answer_tokens = output_tokens

    output_tok_s = output_tokens / gen_time if gen_time > 0 else 0
    prefill_tok_s = (prompt_tokens_count / ttft
                     if ttft > 0 and prompt_tokens_count > 0 else 0)
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


def warm_up(endpoint, timeout, temperature):
    sys.stderr.write(f"  [{endpoint.model_key}] Warming up... ")
    sys.stderr.flush()
    dummy = Prompt(id="warmup", name="warmup", category="warmup",
                   content=WARMUP_PROMPT)
    for i in range(WARMUP_COUNT):
        run_single(endpoint, dummy, max_tokens=256, timeout=timeout,
                   temperature=temperature)
    sys.stderr.write("done\n")
    sys.stderr.flush()


# =============================================================================
# Concurrency runner
# =============================================================================
_progress_lock = threading.Lock()


def run_concurrency_level(endpoint, prompts, concurrency, max_tokens,
                          timeout, temperature):
    """Run prompts at a given concurrency level and return aggregated
    results with system-level throughput metrics.

    When concurrency exceeds the number of prompts, prompts are recycled
    round-robin so that every worker has a request to process.
    """
    total = max(len(prompts), concurrency)
    request_prompts = [prompts[i % len(prompts)] for i in range(total)]

    results = []
    completed = [0]
    error_count = [0]
    t_start = time.monotonic()

    def _report(result):
        if result.status != "ok":
            error_count[0] += 1
        completed[0] += 1
        with _progress_lock:
            err = ""
            if error_count[0]:
                err = ", {} errors".format(error_count[0])
            sys.stderr.write(
                f"\r  [conc={concurrency}] {completed[0]}/{total} done"
                f"{err}      "
            )
            sys.stderr.flush()

    sys.stderr.write(
        f"  [conc={concurrency}] Running {total} requests "
        f"({len(prompts)} unique prompts)...\n")
    sys.stderr.flush()

    if concurrency == 1:
        for prompt in request_prompts:
            result = run_single(endpoint, prompt, max_tokens, timeout,
                                temperature)
            result.concurrency = concurrency
            results.append(result)
            _report(result)
    else:
        with ThreadPoolExecutor(max_workers=concurrency) as executor:
            futures = []
            for prompt in request_prompts:
                fut = executor.submit(run_single, endpoint, prompt,
                                      max_tokens, timeout, temperature)
                futures.append(fut)

            for fut in as_completed(futures):
                result = fut.result()
                result.concurrency = concurrency
                results.append(result)
                _report(result)

    sys.stderr.write("\n")
    sys.stderr.flush()

    t_total = time.monotonic() - t_start
    ok = [r for r in results if r.status == "ok"]
    total_tokens = sum(r.output_tokens for r in ok)
    system_tok_s = total_tokens / t_total if t_total > 0 else 0
    req_per_s = len(ok) / t_total if t_total > 0 else 0

    return ConcurrencyResult(concurrency, results, system_tok_s,
                             req_per_s, t_total)


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
    try:
        out = subprocess.check_output(
            ["nvidia-smi", "--query-gpu=name,memory.total,driver_version",
             "--format=csv,noheader"],
            universal_newlines=True, timeout=10,
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
            ["nvidia-smi"], universal_newlines=True, timeout=10,
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
    header_line = sep.join(
        str(h).ljust(w) for h, w in zip(headers, col_widths))
    divider = sep.join("-" * w for w in col_widths)
    lines = [header_line, divider]
    for row in rows:
        lines.append(
            sep.join(str(v).ljust(w) for v, w in zip(row, col_widths)))
    return "\n".join(lines)


def _has_thinking(conc_results_list):
    """Check if any result across all concurrency levels has thinking."""
    for cr in conc_results_list:
        for r in cr.results:
            if r.status == "ok" and r.thinking_s > 0.1:
                return True
    return False


def print_model_summary(model_key, backend, conc_results):
    sys.stderr.flush()
    sys.stdout.flush()
    total_prompts = len(conc_results[0].results) if conc_results else 0
    n_levels = len(conc_results)
    print()
    print("-" * 70)
    print(f"  {model_key} ({backend}) — "
          f"{total_prompts} prompts x {n_levels} concurrency levels")

    thinking = _has_thinking(conc_results)

    headers = ["Samples", "TTFT(ms)", "Tok/s", "TPOT(ms)", "E2E(s)",
               "SysTok/s"]
    if thinking:
        headers.append("Think(s)")

    rows = []
    for cr in conc_results:
        ok = [r for r in cr.results if r.status == "ok"]
        if not ok:
            row = [str(cr.concurrency)] + ["-"] * (len(headers) - 1)
            rows.append(row)
            continue

        row = [
            str(cr.concurrency),
            f"{statistics.mean([r.ttft_ms for r in ok]):.0f}",
            f"{statistics.mean([r.output_tok_s for r in ok]):.1f}",
            f"{statistics.mean([r.tpot_ms for r in ok]):.1f}",
            f"{statistics.mean([r.e2e_s for r in ok]):.1f}",
            f"{cr.system_tok_s:.1f}",
        ]
        if thinking:
            row.append(
                f"{statistics.mean([r.thinking_s for r in ok]):.1f}")
        rows.append(row)

    col_widths = [7, 10, 8, 10, 8, 10]
    if thinking:
        col_widths.append(9)
    print(f"  {fmt_table(headers, rows, col_widths)}")


def print_summary_table(all_model_data):
    print("\n" + "=" * 80)
    print("SUMMARY — mean across all prompts")
    print("=" * 80)

    thinking = any(
        _has_thinking(crs) for _, crs in all_model_data)

    headers = ["Model", "Backend", "Samples", "TTFT(ms)", "Tok/s",
               "TPOT(ms)", "E2E(s)", "SysTok/s", "Err"]
    if thinking:
        headers.insert(7, "Think(s)")

    rows = []
    for endpoint, conc_results in all_model_data:
        for cr in conc_results:
            ok = [r for r in cr.results if r.status == "ok"]
            errors = len(cr.results) - len(ok)

            if not ok:
                row = [endpoint.model_key, endpoint.backend,
                       str(cr.concurrency)]
                row += ["-"] * 5 + [str(errors)]
                if thinking:
                    row.insert(7, "-")
                rows.append(row)
                continue

            row = [
                endpoint.model_key,
                endpoint.backend,
                str(cr.concurrency),
                f"{statistics.mean([r.ttft_ms for r in ok]):.0f}",
                f"{statistics.mean([r.output_tok_s for r in ok]):.1f}",
                f"{statistics.mean([r.tpot_ms for r in ok]):.1f}",
                f"{statistics.mean([r.e2e_s for r in ok]):.1f}",
                f"{cr.system_tok_s:.1f}",
                str(errors),
            ]
            if thinking:
                think_avg = statistics.mean(
                    [r.thinking_s for r in ok])
                row.insert(7, f"{think_avg:.1f}")
            rows.append(row)

    col_widths = [18, 8, 7, 10, 8, 10, 8, 10, 5]
    if thinking:
        col_widths.insert(7, 9)
    print(fmt_table(headers, rows, col_widths))


# =============================================================================
# Export
# =============================================================================
def _default_output_base():
    user = os.environ.get("USER", "unknown")
    ts = datetime.now().strftime("%Y%m%d_%H%M%S")
    output_dir = os.path.join(SCRIPT_DIR, "..", "output", "benchmarks")
    os.makedirs(output_dir, exist_ok=True)
    base = os.path.join(output_dir, "benchmark_{}_{}".format(user, ts))
    return base


def export_json(all_model_data, env_info, concurrency_levels, path):
    models = {}
    for endpoint, conc_results in all_model_data:
        mk = endpoint.model_key
        conc_data = {}
        for cr in conc_results:
            ok = [r for r in cr.results if r.status == "ok"]
            errors = len(cr.results) - len(ok)
            level = {
                "system_tok_s": cr.system_tok_s,
                "requests_per_s": cr.requests_per_s,
                "wall_time_s": cr.wall_time_s,
                "samples": len(ok),
                "errors": errors,
                "results": [r.to_dict() for r in cr.results],
            }
            if ok:
                level["per_request_stats"] = {
                    "ttft_ms": compute_stats([r.ttft_ms for r in ok]),
                    "output_tok_s": compute_stats(
                        [r.output_tok_s for r in ok]),
                    "tpot_ms": compute_stats([r.tpot_ms for r in ok]),
                    "e2e_s": compute_stats([r.e2e_s for r in ok]),
                    "output_tokens": compute_stats(
                        [float(r.output_tokens) for r in ok]),
                    "gen_s": compute_stats([r.gen_s for r in ok]),
                    "thinking_s": compute_stats(
                        [r.thinking_s for r in ok]),
                    "prefill_tok_s": compute_stats(
                        [r.prefill_tok_s for r in ok]),
                }
            conc_data[str(cr.concurrency)] = level

        models[mk] = {
            "endpoint": {
                "model_key": endpoint.model_key,
                "model_id": endpoint.model_id,
                "backend": endpoint.backend,
                "node": endpoint.node,
                "port": endpoint.port,
                "sif_name": endpoint.sif_name,
                "endpoint": endpoint.endpoint,
            },
            "concurrency": conc_data,
        }

    data = {
        "environment": env_info,
        "benchmark_config": {
            "concurrency_levels": concurrency_levels,
            "prompts_per_level": (
                len(all_model_data[0][1][0].results)
                if all_model_data and all_model_data[0][1] else 0),
            "max_tokens": DEFAULT_MAX_TOKENS,
            "temperature": DEFAULT_TEMPERATURE,
            "warmup_count": WARMUP_COUNT,
        },
        "models": models,
    }
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2)
    print(f"  JSON:  {path}")


def export_csv(all_model_data, path):
    fields = list(_RESULT_FIELDS)
    all_results = []
    for _, conc_results in all_model_data:
        for cr in conc_results:
            all_results.extend(cr.results)
    if not all_results:
        return
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        f.write(",".join(fields) + "\n")
        for r in all_results:
            d = r.to_dict()
            row = []
            for fld in fields:
                v = d[fld]
                if isinstance(v, str):
                    v = '"{}"'.format(v.replace('"', '""'))
                else:
                    v = str(v)
                row.append(v)
            f.write(",".join(row) + "\n")
    print(f"  CSV:   {path}")


# =============================================================================
# SVG chart generation (pure Python, no external dependencies)
# =============================================================================
def generate_chart(all_model_data, path):
    """Generate a concurrency-throughput SVG chart.

    X-axis: Number of Concurrent Inferences.
    Y-axis: Throughput (tokens / second).
    Each point is a concurrency level, connected per model.
    """
    # Collect series data
    series = []
    for endpoint, conc_results in all_model_data:
        points = []
        for cr in conc_results:
            ok = [r for r in cr.results if r.status == "ok"]
            if ok:
                points.append((cr.concurrency, cr.system_tok_s))
        if points:
            series.append((endpoint.model_key, points))

    if not series:
        return

    # Chart dimensions
    W, H = 800, 500
    mg = {"top": 60, "right": 30, "bottom": 70, "left": 90}
    pw = W - mg["left"] - mg["right"]
    ph = H - mg["top"] - mg["bottom"]

    # Data ranges
    all_x = [p[0] for _, pts in series for p in pts]
    all_y = [p[1] for _, pts in series for p in pts]

    x_lo = 0
    x_hi = max(all_x) * 1.1
    if x_hi == 0:
        x_hi = 1
    y_lo = 0
    y_hi = max(all_y) * 1.15
    if y_hi == 0:
        y_hi = 1

    def sx(v):
        return mg["left"] + (v - x_lo) / (x_hi - x_lo) * pw

    def sy(v):
        return mg["top"] + ph - (v - y_lo) / (y_hi - y_lo) * ph

    svg = []
    svg.append('<svg xmlns="http://www.w3.org/2000/svg" '
               'width="{}" height="{}">'.format(W, H))
    svg.append('<rect width="{}" height="{}" fill="white"/>'.format(W, H))

    # Title
    svg.append('<text x="{}" y="35" text-anchor="middle" '
               'font-size="16" font-family="sans-serif" '
               'font-weight="bold">Throughput vs Concurrency</text>'.format(
                   W / 2))
    svg.append('<text x="{}" y="52" text-anchor="middle" '
               'font-size="11" font-family="sans-serif" '
               'fill="#666">vLLM 0.17.0 -- 4x A100 80GB (TP=4)'
               '</text>'.format(W / 2))

    # Grid lines + ticks
    n_ticks = 5
    for i in range(n_ticks + 1):
        # Y axis
        y_val = y_lo + (y_hi - y_lo) * i / n_ticks
        yp = sy(y_val)
        svg.append('<line x1="{}" y1="{}" x2="{}" y2="{}" '
                   'stroke="#e5e5e5" stroke-width="0.5"/>'.format(
                       mg["left"], yp, mg["left"] + pw, yp))
        svg.append('<text x="{}" y="{}" text-anchor="end" '
                   'font-size="10" font-family="sans-serif" '
                   'fill="#333">{:.0f}</text>'.format(
                       mg["left"] - 8, yp + 4, y_val))
        # X axis
        x_val = x_lo + (x_hi - x_lo) * i / n_ticks
        xp = sx(x_val)
        svg.append('<line x1="{}" y1="{}" x2="{}" y2="{}" '
                   'stroke="#e5e5e5" stroke-width="0.5"/>'.format(
                       xp, mg["top"], xp, mg["top"] + ph))
        svg.append('<text x="{}" y="{}" text-anchor="middle" '
                   'font-size="10" font-family="sans-serif" '
                   'fill="#333">{:.0f}</text>'.format(
                       xp, mg["top"] + ph + 18, x_val))

    # Axes
    svg.append('<line x1="{}" y1="{}" x2="{}" y2="{}" '
               'stroke="#333" stroke-width="1"/>'.format(
                   mg["left"], mg["top"] + ph,
                   mg["left"] + pw, mg["top"] + ph))
    svg.append('<line x1="{}" y1="{}" x2="{}" y2="{}" '
               'stroke="#333" stroke-width="1"/>'.format(
                   mg["left"], mg["top"],
                   mg["left"], mg["top"] + ph))

    # Axis labels
    svg.append('<text x="{}" y="{}" text-anchor="middle" '
               'font-size="12" font-family="sans-serif" '
               'fill="#333">Number of Concurrent Inferences</text>'.format(
                   mg["left"] + pw / 2, H - 15))
    svg.append('<text x="18" y="{}" text-anchor="middle" '
               'font-size="12" font-family="sans-serif" fill="#333" '
               'transform="rotate(-90, 18, {})">Throughput '
               '(tokens / second)</text>'.format(mg["top"] + ph / 2,
                                                  mg["top"] + ph / 2))

    # Data series
    for idx, (model_key, points) in enumerate(series):
        color = CHART_COLORS[idx % len(CHART_COLORS)]
        sorted_pts = sorted(points, key=lambda p: p[0])

        # Line connecting points
        path_parts = []
        for i, (conc, tps) in enumerate(sorted_pts):
            x, y = sx(conc), sy(tps)
            if i == 0:
                path_parts.append("M {:.1f} {:.1f}".format(x, y))
            else:
                path_parts.append(" L {:.1f} {:.1f}".format(x, y))
        svg.append('<path d="{}" fill="none" stroke="{}" '
                   'stroke-width="2" opacity="0.8"/>'.format(
                       "".join(path_parts), color))

        # Points + labels
        for conc, tps in sorted_pts:
            x, y = sx(conc), sy(tps)
            svg.append('<circle cx="{:.1f}" cy="{:.1f}" r="5" '
                       'fill="{}" stroke="white" '
                       'stroke-width="1.5"/>'.format(x, y, color))
            svg.append('<text x="{:.1f}" y="{:.1f}" font-size="9" '
                       'font-family="sans-serif" '
                       'fill="{}">{:.0f}</text>'.format(
                           x + 8, y - 8, color, tps))

    # Legend
    ly = mg["top"] + 15
    for idx, (model_key, _) in enumerate(series):
        color = CHART_COLORS[idx % len(CHART_COLORS)]
        lx = mg["left"] + pw - 160
        cur_y = ly + idx * 20
        svg.append('<rect x="{}" y="{}" width="14" height="14" '
                   'fill="{}" rx="2"/>'.format(lx, cur_y - 10, color))
        svg.append('<text x="{}" y="{}" font-size="11" '
                   'font-family="sans-serif" '
                   'fill="#333">{}</text>'.format(
                       lx + 18, cur_y + 1, model_key))

    svg.append('</svg>')

    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        f.write("\n".join(svg))
    print(f"  Chart: {path}")


# =============================================================================
# Main
# =============================================================================
def main():
    # UTF-8 safety for HPC nodes
    if (sys.stdout.encoding
            and sys.stdout.encoding.lower() not in ("utf-8", "utf8")
            and hasattr(sys.stdout, "buffer")):
        sys.stdout = io.TextIOWrapper(
            sys.stdout.buffer, encoding=sys.stdout.encoding,
            errors="replace")
        if hasattr(sys.stderr, "buffer"):
            sys.stderr = io.TextIOWrapper(
                sys.stderr.buffer, encoding=sys.stderr.encoding,
                errors="replace")

    parser = argparse.ArgumentParser(
        description="LLM benchmark with concurrency sweep for vLLM endpoints.",
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
        "--prompts", default=DEFAULT_PROMPTS,
        help="Prompts JSON file (default: benchmark_prompts.json)",
    )
    parser.add_argument(
        "--max-prompts", type=int, default=None, metavar="N",
        help="Use N prompts (round-robin across categories). "
             "When concurrency > N, prompts are recycled. "
             "Default: use all prompts.",
    )
    parser.add_argument(
        "--concurrency",
        default=",".join(str(c) for c in DEFAULT_CONCURRENCY),
        help="Comma-separated concurrency levels "
             "(default: {})".format(
                 ",".join(str(c) for c in DEFAULT_CONCURRENCY)),
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
        help="Override default JSON output path",
    )
    parser.add_argument(
        "--output-csv", metavar="FILE",
        help="Also export results as CSV",
    )

    if len(sys.argv) == 1:
        parser.print_help()
        sys.exit(0)

    args = parser.parse_args()

    if args.max_prompts is not None and args.max_prompts < 1:
        parser.error("--max-prompts must be >= 1")

    # Parse concurrency levels
    try:
        conc_levels = sorted(set(
            int(c.strip()) for c in args.concurrency.split(",")
        ))
    except ValueError:
        print("ERROR: --concurrency must be comma-separated integers",
              file=sys.stderr)
        sys.exit(1)

    # Discover or parse endpoints
    if args.discover:
        nim_base = os.environ.get("NIM_BASE_DIR")
        if not nim_base:
            print("ERROR: NIM_BASE_DIR must be set for --discover",
                  file=sys.stderr)
            sys.exit(1)
        sessions_dir = f"{nim_base}/sessions"
        endpoints = discover_endpoints(sessions_dir)
        if not endpoints:
            print("ERROR: No active endpoints found.", file=sys.stderr)
            print("Check NIM_BASE_DIR and ensure models are running.",
                  file=sys.stderr)
            sys.exit(1)
    else:
        endpoints = parse_endpoint_args(args.endpoints)

    # Load prompts
    try:
        all_prompts = load_prompts(args.prompts)
    except (OSError, json.JSONDecodeError) as e:
        print(f"ERROR: Cannot load prompts from {args.prompts}: {e}",
              file=sys.stderr)
        sys.exit(1)

    prompts = select_prompts(all_prompts, args.max_prompts)

    env_info = collect_env_info(endpoints)

    # Header
    print("=" * 80)
    print(f"LLM BENCHMARK — {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
    print("=" * 80)
    print(f"  Prompts:      {len(prompts)} "
          f"(of {len(all_prompts)} available)")
    print(f"  Models:       {len(endpoints)}")
    print(f"  Concurrency:  {', '.join(str(c) for c in conc_levels)}")
    print(f"  Max tokens:   {args.max_tokens}")
    print(f"  Temperature:  {args.temperature}")
    print()

    # Health check
    healthy = []
    for ep in endpoints:
        sys.stderr.write(
            f"  Checking {ep.model_key} at {ep.endpoint}... ")
        sys.stderr.flush()
        if _check_health(ep.endpoint):
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

    # =========================================================================
    # Per-model: warmup → concurrency sweep → model summary
    # =========================================================================
    all_model_data = []

    for ep in healthy:
        if not args.no_warmup:
            warm_up(ep, args.timeout, args.temperature)

        conc_results = []
        for conc in conc_levels:
            cr = run_concurrency_level(
                ep, prompts, conc, args.max_tokens, args.timeout,
                args.temperature)
            conc_results.append(cr)

        all_model_data.append((ep, conc_results))

        # Per-model summary
        print_model_summary(ep.model_key, ep.backend, conc_results)

    # Final summary
    print_summary_table(all_model_data)

    # Export
    output_base = _default_output_base()
    json_path = args.output_json or (output_base + ".json")
    svg_path = output_base + ".svg"

    print()
    export_json(all_model_data, env_info, conc_levels, json_path)
    if args.output_csv:
        export_csv(all_model_data, args.output_csv)
    generate_chart(all_model_data, svg_path)

    # Final counts
    total_req = sum(
        len(cr.results)
        for _, crs in all_model_data for cr in crs)
    total_ok = sum(
        sum(1 for r in cr.results if r.status == "ok")
        for _, crs in all_model_data for cr in crs)
    total_err = total_req - total_ok
    print(f"\n  Total: {total_ok} OK, {total_err} errors "
          f"out of {total_req} requests "
          f"({len(conc_levels)} concurrency levels)")
    print()


if __name__ == "__main__":
    main()
