#!/usr/bin/env python3
"""Compare first-prompt control arms per request and phase, without averaging.

Reads a control.json written by first-prompt-control.py. Base and head arms of
the same mode and repeat are paired; each request phase gets the repository's
paired verdict (a change counts only when every repeat moves by more than 5%
and 3 ms in the same direction). Phases are compared only when both arms did
the same work; correctness failures (reused tokens, wrong answer, unclean
shutdown) fail the comparison outright. When both arms use byte-identical
binaries and DLLs, the run is an unchanged-binary control and any flagged
phase is measurement noise, reported as inconclusive.

On Windows, the first GPU submission after the device idles for about 5 s
stalls for 0.3-0.9 s in the driver. A fresh server's first request hits it at
random, inside slot reassignment, so slot_wait_ms is reported but not gated,
and is subtracted from the wall, queue and TTFT phases that contain it.

The cache snapshot and restore phases time a pageable device-to-host copy, so
their duration follows the payload instead of the request's other work. On
Windows the same binary moved up to 53% between repeats at a byte-identical
payload (evidence: the unchanged-binary control in
`sync-noise-floor-2026-10-24`), which is wider than the 3 ms/5% rule; such a
move is reported as `within noise` with its payload and throughput instead of
being judged, and differing payload bytes are a work difference. Prefill,
TTFT and decode keep the strict rule: they are what this control exists to
catch.

Exit status: 0 passed, 1 failed, 2 inconclusive.
"""

import argparse
import json
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "tests" / "functional"))

from metrics import NOISE_MS, SLOWDOWN  # noqa: E402
from phases import verdict  # noqa: E402

PHASES = ("wall_ms", "queue_ms", "ttft_ms", "slot_wait_ms", "prefill_ms", "decode_ms",
          "cache_restore_ms", "cache_snapshot_ms", "max_inter_token_ms")
WAKE = "slot_wait_ms"
CONTAINS_WAKE = {"wall_ms", "queue_ms", "ttft_ms"}
# Decode-side timings follow the generated tokens and accepted drafts.
WORK = ("prompt_tokens", "cached_tokens", "completion_tokens", "draft_tokens",
        "draft_tokens_accepted", "text_sha256")
PREFILL_WORK = ("prompt_tokens", "cached_tokens")
DECODE_PHASES = {"decode_ms", "max_inter_token_ms", "wall_ms", "cache_snapshot_ms"}
# Phases that time a pageable copy; the value is the payload field that must
# match. Their repeatability on Windows reaches 53%, so a move inside that band
# is reported as `within noise` rather than judged (see the module docstring).
MEMCPY_PHASES = {"cache_snapshot_ms": "cache_snapshot_bytes",
                 "cache_restore_ms": "cache_restore_bytes"}
MEMCPY_REPEATABILITY = 0.55


def identity(arm):
    binary = arm["binary"]
    return binary["sha256"], binary["dll_set_sha256"]


def slot_waits(arm):
    """Per-request slot-reassignment wait; the server reports a process total."""
    waits, waited = [], 0.0
    for request in arm["requests"]:
        usage = (request.get("response") or {}).get("usage", {})
        total = (usage.get("gufo", {}).get("component_cache", {})
                 .get("global_spill", {}).get("residual_wait_ms"))
        waits.append(None if total is None else total - waited)
        waited = waited if total is None else total
    return waits


def value(request, phase, wait):
    measured = request["phases"].get(phase)
    if phase == WAKE:
        return wait
    if phase in CONTAINS_WAKE and measured is not None and wait is not None:
        return measured - wait
    return measured


def work_value(request, field):
    """A work field; payload sizes live in the response, not beside the request."""
    if field in MEMCPY_PHASES.values():
        usage = (request.get("response") or {}).get("usage", {}).get("gufo", {})
        return usage.get(field)
    return request.get(field)


def payload(request, phase):
    """Copied bytes for a memcpy phase, or None when the evidence lacks it."""
    field = MEMCPY_PHASES.get(phase)
    return None if field is None else work_value(request, field)


def gigabytes_per_second(size, milliseconds):
    if not size or not milliseconds:
        return None
    return size / 1e6 / milliseconds


def within_repeatability(phase, complete):
    """True when every paired move stays inside the phase's repeatability band."""
    if phase not in MEMCPY_PHASES or not complete:
        return False
    return all(abs(head - base) <= max(NOISE_MS, MEMCPY_REPEATABILITY * base)
               for base, head in complete)


def compare(control):
    arms = control["arms"]
    labels = sorted({arm["label"] for arm in arms})
    if labels != ["base", "head"]:
        raise ValueError(f"expected base and head arms, found {labels}")
    unchanged = len({identity(arm) for arm in arms}) == 1
    correctness = [f"{arm['label']} {arm['mode']} #{arm['repeat']}: {problem}"
                   for arm in arms for problem in arm.get("problems", [])]
    rows, notes = [], []
    for mode in sorted({arm["mode"] for arm in arms}):
        pairs = {}
        for arm in arms:
            if arm["mode"] == mode:
                pairs.setdefault(arm["repeat"], {})[arm["label"]] = arm
        pairs = [pair for _, pair in sorted(pairs.items()) if len(pair) == 2]
        if not pairs:
            raise ValueError(f"{mode}: no complete base/head pair")
        names = [request["name"] for request in pairs[0]["base"]["requests"]]
        waits = [{label: slot_waits(arm) for label, arm in pair.items()} for pair in pairs]
        for index, name in enumerate(names):
            observed = [(pair["base"]["requests"][index], pair["head"]["requests"][index])
                        for pair in pairs]
            wait = [(w["base"][index], w["head"][index]) for w in waits]
            # Without a slot wait on every request, compare unadjusted.
            measured = all(w is not None for pair in wait for w in pair)
            for phase in PHASES:
                work = WORK if phase in DECODE_PHASES else PREFILL_WORK
                payload_field = MEMCPY_PHASES.get(phase)
                if payload_field:
                    work = work + (payload_field,)
                differs = sorted({field for base, head in observed for field in work
                                  if work_value(base, field) != work_value(head, field)})
                exclude = measured and phase in CONTAINS_WAKE
                values = [(value(base, phase, wb if measured else None),
                           value(head, phase, wh if measured else None))
                          for (base, head), (wb, wh) in zip(observed, wait)]
                complete = [(b, h) for b, h in values if b is not None and h is not None]
                result = verdict(complete) if not differs else "work differs"
                size = payload(observed[0][0], phase) if observed else None
                if result in ("faster", "slower", "noisy") and not differs \
                        and size and within_repeatability(phase, complete):
                    moved = [100.0 * (head - base) / base for base, head in complete if base]
                    span = (f"{moved[0]:+.1f}%" if len(moved) == 1 else
                            f"{min(moved):+.1f}% to {max(moved):+.1f}%")
                    notes.append(
                        f"{mode} {name}: {phase} moved {span} inside the "
                        f"{MEMCPY_REPEATABILITY:.0%} repeatability of identical binaries at "
                        f"{size / 1e9:.2f} GB; not qualified")
                    result = "within noise"
                rows.append({"mode": mode, "request": name, "phase": phase,
                             "base": [b for b, _ in values], "head": [h for _, h in values],
                             "verdict": result, "work_differs": differs,
                             "payload_bytes": size,
                             "gated": phase != WAKE, "excludes": WAKE if exclude else None})
                if phase == WAKE and result == "slower":
                    notes.append(f"{mode} {name}: {WAKE} is slower in every repeat; the idle "
                                 "wake lands at random, so check the server logs before "
                                 "calling it noise")
    gated = [row for row in rows if row["gated"]]
    slower = [row for row in gated if row["verdict"] == "slower"]
    unsettled = [row for row in gated if row["verdict"] in ("noisy", "work differs", "missing")]
    if correctness:
        status = "failed"
    elif unchanged:
        moved = [row for row in gated if row["verdict"] in ("slower", "faster", "noisy")]
        status = "inconclusive" if moved else "passed"
    elif slower:
        status = "failed"
    elif unsettled:
        status = "inconclusive"
    else:
        status = "passed"
    return {"schema": 2, "status": status, "unchanged_binary_control": unchanged,
            "slowdown": SLOWDOWN, "noise_ms": NOISE_MS,
            "memcpy_repeatability": MEMCPY_REPEATABILITY,
            "correctness": correctness, "notes": notes, "measurements": rows}


def table(result):
    lines = ["| Mode | Request | Phase | Base ms | Head ms | Verdict |",
             "| --- | --- | --- | ---: | ---: | --- |"]
    for row in result["measurements"]:
        cells = [", ".join("-" if value is None else f"{value:.2f}" for value in row[side])
                 for side in ("base", "head")]
        phase = row["phase"] + (f" - {row['excludes']}" if row.get("excludes") else "")
        detail = [f"{row['payload_bytes'] / 1e9:.2f} GB"] if row.get("payload_bytes") else []
        detail += [f"{throughput:.1f} GB/s" for throughput in
                   (gigabytes_per_second(row.get("payload_bytes"), row[side][0])
                    if row[side] else None for side in ("base", "head"))
                   if throughput]
        if detail:
            phase += f" ({', '.join(detail)})"
        verdict = row["verdict"] + ("" if row.get("gated", True) else " (not gated)")
        lines.append(f"| {row['mode']} | {row['request']} | {phase} | "
                     f"{cells[0]} | {cells[1]} | {verdict} |")
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("control", type=Path, help="control.json from first-prompt-control.py")
    parser.add_argument("--output", type=Path, help="New comparison JSON file")
    args = parser.parse_args()
    try:
        result = compare(json.loads(args.control.read_text(encoding="utf-8")))
    except (ValueError, KeyError, IndexError, OSError) as error:
        result = {"schema": 1, "status": "failed", "error": str(error), "notes": [],
                  "measurements": []}
    if args.output:
        with args.output.open("x", encoding="utf-8") as output:
            output.write(json.dumps(result, indent=2) + "\n")
    print(table(result))
    for problem in result.get("correctness", []):
        print(f"correctness: {problem}")
    for note in result.get("notes", []):
        print(f"note: {note}")
    if "error" in result:
        print(f"error: {result['error']}")
    control = " (unchanged-binary control)" if result.get("unchanged_binary_control") else ""
    print(f"{result['status']}{control}")
    return {"passed": 0, "failed": 1, "inconclusive": 2}[result["status"]]


if __name__ == "__main__":
    sys.exit(main())
