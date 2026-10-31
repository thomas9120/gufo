#!/usr/bin/env python3
"""Fresh-process first-prompt control for Flash-Next on Windows.

Each arm stages one binary and its colocated DLLs at the same path, starts a
private server, sends a varied long prompt with prompt reuse enabled, repeats
it with `cache_prompt: false`, then stops the server. Arms alternate base and
head (ABBA across repeats) for every mode. Warmed benchmarks missed both the
n-gram first-prompt regression and #699; this control caught them.

Everything needed to qualify or re-examine a result is retained in a new
output directory: control.json (settings, binary/DLL/model identities, exact
commands, /props, complete responses and per-phase timings), one server log
per arm and comparison.json from compare-phases.py. Omitting --head-binary
runs an unchanged-binary control. See docs/WINDOWS-UPSTREAM-SYNC.md.
"""

import argparse
import hashlib
import http.client
import importlib.util
import json
import os
from pathlib import Path
import random
import shutil
import signal
import socket
import subprocess
import sys
import time

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parents[1] / "tests" / "functional"))

if os.name == "nt":
    import windows_server  # noqa: E402
# The retained October 2026 workload: 11,000 words, 11,036 prompt tokens.
WORDS = ("river town family valley stone bridge boats timber salt wool market "
         "wheat children forest quiet garden road lake tree green water blue").split()
SEED = 813
TARGET = "Qwen3.8-Flash-Next-UD-Q4_K_XL-00001-of-00004.gguf"
MTP = "mtp-Qwen3.8-Flash-Next-shared-Q8_0.gguf"
GiB = 1 << 30
# Server-side request phases reported in usage.gufo; wall_ms is the client's.
PHASES = ("queue_ms", "ttft_ms", "prefill_ms", "decode_ms", "cache_restore_ms",
          "cache_snapshot_ms", "max_inter_token_ms")


def load_compare():
    spec = importlib.util.spec_from_file_location("compare_phases", HERE / "compare-phases.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def request_body(words, cache_prompt):
    passage = " ".join(random.Random(SEED).choices(WORDS, k=words))
    return {
        "model": "gufo",
        "messages": [
            {"role": "system", "content": "Read the archive. Follow the final user instruction exactly."},
            {"role": "user", "content": passage + "\nReply with exactly the word ACK."},
        ],
        "max_tokens": 128, "temperature": 0, "seed": 42,
        "chat_template_kwargs": {"enable_thinking": False},
        "cache_prompt": cache_prompt,
    }


def sha256(path):
    digest = hashlib.sha256()
    with open(path, "rb") as stream:
        for block in iter(lambda: stream.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def runtime_files(binary):
    """The executable plus everything Windows loads beside it."""
    directory = binary.parent
    files = [binary, *sorted(directory.glob("*.dll"))]
    library = directory / "hipblaslt"
    if library.is_dir():
        files += sorted(path for path in library.rglob("*") if path.is_file())
    return files


def binary_identity(binary):
    hashes = {path.relative_to(binary.parent).as_posix(): sha256(path)
              for path in runtime_files(binary)[1:]}
    dll_set = hashlib.sha256(json.dumps(hashes, sort_keys=True).encode()).hexdigest()
    version = subprocess.run([str(binary), "--version"], capture_output=True, text=True,
                             timeout=60)
    return {"path": str(binary), "sha256": sha256(binary), "version": version.stdout.strip(),
            "dll_set_sha256": dll_set, "runtime_files": hashes}


def stage(binary, directory):
    """Hard-link (or copy) a runtime into one fixed directory; return the staged exe."""
    if directory.exists():
        shutil.rmtree(directory)
    for source in runtime_files(binary):
        target = directory / source.relative_to(binary.parent)
        target.parent.mkdir(parents=True, exist_ok=True)
        try:
            os.link(source, target)
        except OSError:
            shutil.copy2(source, target)
    return directory / binary.name


def model_identity(path):
    stat = path.stat()
    return {"path": str(path), "bytes": stat.st_size, "mtime_ns": stat.st_mtime_ns}


def free_port():
    with socket.socket() as reserve:
        reserve.bind(("127.0.0.1", 0))
        return reserve.getsockname()[1]


def http_json(port, method, path, body=None, timeout=30):
    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=timeout)
    try:
        payload = None if body is None else json.dumps(body)
        headers = {} if body is None else {"Content-Type": "application/json"}
        connection.request(method, path, payload, headers)
        response = connection.getresponse()
        data = response.read()
        return response.status, response.getheader("Server-Timing"), json.loads(data or b"null")
    finally:
        connection.close()


# The server runs in a private hidden console as its own process group.
# Sending it CTRL_BREAK requires attaching to that console, which a helper
# process does so this harness keeps its own console and output. Addressing
# only the server's group keeps the event away from the helper itself.
BREAK_HELPER = """
import ctypes, sys
kernel = ctypes.WinDLL("kernel32", use_last_error=True)
pid = int(sys.argv[1])
kernel.FreeConsole()
if not kernel.AttachConsole(pid):
    sys.exit(ctypes.get_last_error() or 1)
sys.exit(0 if kernel.GenerateConsoleCtrlEvent(1, pid) else 2)
"""


def launch(command, log):
    options = {}
    if os.name == "nt":
        options = windows_server.launch_options()
        options["creationflags"] |= subprocess.CREATE_NEW_PROCESS_GROUP
    return subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT, **options)


def stop(process, timeout):
    """Request graceful shutdown; return (exit code, graceful)."""
    if process.poll() is not None:
        return process.returncode, False
    if os.name == "nt":
        helper = subprocess.run([sys.executable, "-c", BREAK_HELPER, str(process.pid)],
                                capture_output=True, timeout=30)
        if helper.returncode != 0 and process.poll() is None:
            print(f"console break failed ({helper.returncode}); killing", file=sys.stderr)
    else:
        process.send_signal(signal.SIGINT)
    try:
        return process.wait(timeout=timeout), True
    except subprocess.TimeoutExpired:
        process.kill()
        return process.wait(timeout=30), False


def observe(name, cache_prompt, status, timing, response, wall_ms, expect):
    usage = (response or {}).get("usage", {}) if isinstance(response, dict) else {}
    gufo = usage.get("gufo", {})
    text = ""
    if status == 200:
        text = response["choices"][0]["message"].get("content") or ""
    phases = {key: gufo.get(key) for key in PHASES}
    phases["wall_ms"] = wall_ms
    observed = {
        "name": name, "cache_prompt": cache_prompt, "status": status, "server_timing": timing,
        "prompt_tokens": usage.get("prompt_tokens"),
        "cached_tokens": usage.get("cached_tokens"),
        "completion_tokens": usage.get("completion_tokens"),
        "draft_tokens": usage.get("draft_tokens"),
        "draft_tokens_accepted": usage.get("draft_tokens_accepted"),
        "text": text, "text_sha256": hashlib.sha256(text.encode()).hexdigest(),
        "phases": phases, "response": response,
    }
    problems = []
    if status != 200:
        problems.append(f"{name}: HTTP {status}")
    if observed["cached_tokens"] != 0:
        problems.append(f"{name}: reused {observed['cached_tokens']} tokens")
    if expect is not None and text.strip() != expect:
        problems.append(f"{name}: answered {text.strip()[:40]!r}, expected {expect!r}")
    return observed, problems


def run_arm(args, label, mode, repeat, binary, logs):
    staged = stage(binary, args.output / "run-bin")
    port = free_port()
    command = [str(staged), "serve", "--host", "127.0.0.1", "--port", str(port), "llm",
               "--model", str(args.models / args.target),
               "--context", str(args.context), "--sessions", str(args.sessions),
               "--think", "off", "--served-model-name", "gufo",
               "--cache-ram-bytes", str(args.cache_ram_bytes)]
    command += (["--speculative", "mtp", "--mtp-model", str(args.models / args.mtp)]
                if mode == "mtp" else ["--speculative", "off"])
    log_path = logs / f"{mode}-{repeat}-{label}.log"
    arm = {"label": label, "mode": mode, "repeat": repeat, "command": command,
           "log": log_path.name, "requests": [], "problems": []}
    print(f"[{mode} #{repeat}] {label}: starting", flush=True)
    with log_path.open("w", encoding="utf-8") as log:
        started = time.monotonic()
        process = launch(command, log)
        try:
            deadline = started + args.startup_timeout
            while True:
                if process.poll() is not None:
                    raise RuntimeError(f"server exited {process.returncode}; see {log_path}")
                if time.monotonic() > deadline:
                    raise TimeoutError(f"server startup timed out; see {log_path}")
                try:
                    if http_json(port, "GET", "/health", timeout=2)[0] == 200:
                        break
                except (OSError, http.client.HTTPException, ValueError):
                    pass
                time.sleep(0.05)
            arm["startup_ms"] = (time.monotonic() - started) * 1000
            arm["props"] = http_json(port, "GET", "/props")[2]
            for name, cache_prompt in (("reuse", True), ("no-reuse", False)):
                body = request_body(args.words, cache_prompt)
                sent = time.perf_counter()
                status, timing, response = http_json(port, "POST", "/v1/chat/completions",
                                                     body, timeout=args.request_timeout)
                wall_ms = (time.perf_counter() - sent) * 1000
                observed, problems = observe(name, cache_prompt, status, timing, response,
                                             wall_ms, args.expect)
                arm["requests"].append(observed)
                arm["problems"] += problems
                phases = observed["phases"]
                print(f"[{mode} #{repeat}] {label} {name}: prompt {observed['prompt_tokens']}, "
                      f"prefill {phases['prefill_ms']} ms, decode {phases['decode_ms']} ms, "
                      f"text {observed['text'].strip()[:20]!r}", flush=True)
        finally:
            code, graceful = stop(process, args.stop_timeout)
            arm["exit_code"], arm["graceful_stop"] = code, graceful
    if not arm["graceful_stop"] or arm["exit_code"] != 0:
        arm["problems"].append(f"server stop: exit {arm['exit_code']}, graceful {arm['graceful_stop']}")
    return arm


def default_models():
    local = HERE / "local.json"
    if local.is_file():
        models = json.loads(local.read_text(encoding="utf-8")).get("Models")
        if models:
            return Path(models)
    return None


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--base-binary", type=Path, required=True,
                        help="Previous Windows gufo.exe (its DLLs are taken from beside it)")
    parser.add_argument("--head-binary", type=Path,
                        help="Candidate gufo.exe; omit for an unchanged-binary control")
    parser.add_argument("--output", type=Path, required=True, help="New evidence directory")
    parser.add_argument("--models", type=Path, default=default_models(),
                        help="Model directory (default: Models in tools/windows/local.json)")
    parser.add_argument("--target", default=TARGET, help="Target GGUF (first shard) in --models")
    parser.add_argument("--mtp", default=MTP, help="MTP sidecar GGUF in --models")
    parser.add_argument("--mode", choices=("ar", "mtp"), action="append",
                        help="Repeatable; default both")
    parser.add_argument("--repeats", type=int, default=1, help="Arm pairs per mode (ABBA order)")
    parser.add_argument("--words", type=int, default=11000,
                        help="Prompt words; 11000 gives 11,036 tokens, keep within 10-16K tokens")
    parser.add_argument("--context", type=int, default=32768)
    parser.add_argument("--sessions", type=int, default=2)
    parser.add_argument("--cache-ram-bytes", type=int, default=8 * GiB)
    parser.add_argument("--expect", default="ACK", help="Required answer; empty to skip")
    parser.add_argument("--pause", type=float, default=15, help="Idle seconds before each arm")
    parser.add_argument("--startup-timeout", type=float, default=600)
    parser.add_argument("--request-timeout", type=float, default=900)
    parser.add_argument("--stop-timeout", type=float, default=60)
    args = parser.parse_args()
    if args.models is None:
        parser.error("--models is required when tools/windows/local.json has no Models entry")
    args.expect = args.expect or None
    modes = args.mode or ["ar", "mtp"]
    args.output = args.output.resolve()
    if args.output.exists() and any(args.output.iterdir()):
        parser.error(f"{args.output} is not empty; evidence is never overwritten")
    logs = args.output / "logs"
    logs.mkdir(parents=True)

    binaries = {"base": args.base_binary.resolve(),
                "head": (args.head_binary or args.base_binary).resolve()}
    identities = {label: binary_identity(path) for label, path in binaries.items()}
    target = args.models / args.target
    shards = sorted(target.parent.glob(target.name.replace("00001-of", "*-of"))) or [target]
    models = [model_identity(path) for path in shards]
    if "mtp" in modes:
        models.append(model_identity(args.models / args.mtp))
    control = {
        "schema": 1, "tool": "tools/windows/first-prompt-control.py",
        "started": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
        "unchanged_binary_control": args.head_binary is None,
        "binaries": identities, "models": models,
        "settings": {"modes": modes, "repeats": args.repeats, "words": args.words,
                     "seed": SEED, "context": args.context, "sessions": args.sessions,
                     "cache_ram_bytes": args.cache_ram_bytes, "expect": args.expect,
                     "pause_s": args.pause, "staged_path": str(args.output / "run-bin")},
        "arms": [],
    }
    path = args.output / "control.json"
    for mode in modes:
        for repeat in range(args.repeats):
            order = ("base", "head") if repeat % 2 == 0 else ("head", "base")
            for label in order:
                time.sleep(args.pause)
                arm = run_arm(args, label, mode, repeat, binaries[label], logs)
                arm["binary"] = identities[label]
                control["arms"].append(arm)
                # Retain partial evidence after every arm.
                path.write_text(json.dumps(control, indent=2) + "\n", encoding="utf-8")
    shutil.rmtree(args.output / "run-bin", ignore_errors=True)

    compare = load_compare()
    result = compare.compare(control)
    (args.output / "comparison.json").write_text(json.dumps(result, indent=2) + "\n",
                                                 encoding="utf-8")
    print(compare.table(result))
    for problem in result["correctness"]:
        print(f"correctness: {problem}")
    for note in result["notes"]:
        print(f"note: {note}")
    print(f"{result['status']}{' (unchanged-binary control)' if result['unchanged_binary_control'] else ''}: "
          f"{args.output}")
    return {"passed": 0, "failed": 1, "inconclusive": 2}[result["status"]]


if __name__ == "__main__":
    sys.exit(main())
