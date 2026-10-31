"""First-prompt control: request workload, verdicts and Windows server shutdown."""

import copy
import hashlib
import importlib.util
import os
from pathlib import Path
import subprocess
import sys
import unittest


TOOLS = Path(__file__).resolve().parents[2] / "tools" / "windows"


def load(name, module):
    spec = importlib.util.spec_from_file_location(module, TOOLS / name)
    loaded = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(loaded)
    return loaded


control = load("first-prompt-control.py", "first_prompt_control")
compare = load("compare-phases.py", "compare_phases")


def request(name, prefill=6000.0, decode=50.0, completion=2, text="ACK", wait=0.0, total=None,
            snapshot=40.0, snapshot_bytes=1070551172, restore=0.0, restore_bytes=0):
    observed = {"name": name, "prompt_tokens": 11036, "cached_tokens": 0,
                "completion_tokens": completion, "draft_tokens": 0, "draft_tokens_accepted": 0,
                "text_sha256": text,
                "phases": {"wall_ms": prefill + decode + 20 + wait, "queue_ms": 0.1 + wait,
                           "ttft_ms": prefill + 25 + wait, "prefill_ms": prefill,
                           "decode_ms": decode, "cache_restore_ms": restore,
                           "cache_snapshot_ms": snapshot, "max_inter_token_ms": decode}}
    usage = {"cache_snapshot_bytes": snapshot_bytes, "cache_restore_bytes": restore_bytes}
    if total is not None:
        usage["component_cache"] = {"global_spill": {"residual_wait_ms": total}}
    observed["response"] = {"usage": {"gufo": usage}}
    return observed


def arm(label, repeat, binary="same", waits=None, **changes):
    """`waits` gives each request's slot wait; responses carry the process total."""
    if waits is None:
        requests = [request("reuse", **changes), request("no-reuse", **changes)]
    else:
        requests = [request("reuse", wait=waits[0], total=waits[0], **changes),
                    request("no-reuse", wait=waits[1], total=sum(waits), **changes)]
    return {"label": label, "mode": "ar", "repeat": repeat, "problems": [],
            "binary": {"sha256": binary, "dll_set_sha256": "dlls"}, "requests": requests}


def run(*arms):
    return compare.compare({"arms": list(arms)})


def verdicts(result, phase, name="reuse"):
    return [row["verdict"] for row in result["measurements"]
            if row["phase"] == phase and row["request"] == name]


class WorkloadTest(unittest.TestCase):
    def test_body_is_the_retained_workload(self):
        body = control.request_body(11000, True)
        user = body["messages"][1]["content"]
        self.assertEqual(len(user.split("\n")[0].split()), 11000)
        # Pinned so earlier evidence stays comparable (11,036 prompt tokens).
        self.assertEqual(hashlib.sha256(user.encode()).hexdigest(),
                         "f77b4e5d818c4d19674446b9720f46303ccbef3d37281dcaed9fdcfcc94712b2")
        self.assertTrue(body["cache_prompt"])
        self.assertFalse(control.request_body(11000, False)["cache_prompt"])
        self.assertEqual(body["messages"][1]["content"],
                         control.request_body(11000, False)["messages"][1]["content"])

    def test_observe_flags_reuse_and_wrong_answers(self):
        response = {"choices": [{"message": {"content": "NO"}}],
                    "usage": {"prompt_tokens": 11036, "cached_tokens": 512,
                              "completion_tokens": 2, "gufo": {"prefill_ms": 1.0}}}
        observed, problems = control.observe("reuse", True, 200, None, response, 9.0, "ACK")
        self.assertEqual(observed["phases"]["wall_ms"], 9.0)
        self.assertEqual(observed["phases"]["prefill_ms"], 1.0)
        self.assertEqual(problems, ["reuse: reused 512 tokens",
                                    "reuse: answered 'NO', expected 'ACK'"])
        _, problems = control.observe("reuse", True, 500, None, {"error": "x"}, 1.0, None)
        self.assertIn("reuse: HTTP 500", problems)


class CompareTest(unittest.TestCase):
    def test_identical_control_passes(self):
        result = run(arm("base", 0), arm("head", 0))
        self.assertEqual(result["status"], "passed")
        self.assertTrue(result["unchanged_binary_control"])

    def test_moved_phase_in_a_control_is_inconclusive(self):
        result = run(arm("base", 0), arm("head", 0, prefill=6600.0))
        self.assertEqual(verdicts(result, "prefill_ms"), ["slower"])
        self.assertEqual(result["status"], "inconclusive")

    def test_consistent_slowdown_fails_a_changed_binary(self):
        result = run(arm("base", 0), arm("head", 0, "new", prefill=6600.0),
                     arm("head", 1, "new", prefill=6700.0), arm("base", 1))
        self.assertFalse(result["unchanged_binary_control"])
        self.assertEqual(verdicts(result, "prefill_ms"), ["slower"])
        self.assertEqual(result["status"], "failed")

    def test_small_or_mixed_moves_do_not_fail(self):
        # 2 ms is under the 3 ms floor; mixed directions are noise.
        result = run(arm("base", 0), arm("head", 0, "new", decode=52.0),
                     arm("head", 1, "new", prefill=6600.0), arm("base", 1))
        self.assertEqual(verdicts(result, "decode_ms"), ["same"])
        self.assertEqual(verdicts(result, "prefill_ms"), ["noisy"])
        self.assertEqual(result["status"], "inconclusive")

    def test_different_work_is_not_compared(self):
        result = run(arm("base", 0), arm("head", 0, "new", decode=90.0, completion=3))
        self.assertEqual(verdicts(result, "decode_ms"), ["work differs"])
        # Prefill did the same work and is still compared.
        self.assertEqual(verdicts(result, "prefill_ms"), ["same"])
        self.assertEqual(result["status"], "inconclusive")

    def test_correctness_problems_fail(self):
        head = arm("head", 0, "new")
        head["problems"] = ["reuse: reused 512 tokens"]
        result = run(arm("base", 0), head)
        self.assertEqual(result["status"], "failed")
        self.assertEqual(result["correctness"], ["head ar #0: reuse: reused 512 tokens"])

    def test_idle_wake_is_reported_not_gated(self):
        # The Windows idle wake lands in one arm's first slot reassignment.
        result = run(arm("base", 0, waits=(8.0, 1.0)), arm("head", 0, waits=(900.0, 1.0)))
        self.assertEqual(verdicts(result, "slot_wait_ms"), ["slower"])
        for phase in ("wall_ms", "queue_ms", "ttft_ms"):
            self.assertEqual(verdicts(result, phase), ["same"])
            self.assertEqual(verdicts(result, phase, "no-reuse"), ["same"])
        queue = [row for row in result["measurements"]
                 if row["phase"] == "queue_ms" and row["request"] == "reuse"][0]
        self.assertEqual(queue["excludes"], "slot_wait_ms")
        self.assertAlmostEqual(queue["head"][0], 0.1)
        self.assertEqual(result["status"], "passed")
        self.assertEqual(len(result["notes"]), 1)
        self.assertTrue(result["notes"][0].startswith("ar reuse: slot_wait_ms"))
        self.assertIn("| queue_ms - slot_wait_ms |", compare.table(result))

    def test_per_request_slot_wait_from_process_totals(self):
        waits = compare.slot_waits(arm("head", 0, waits=(900.0, 2.5)))
        self.assertEqual(waits, [900.0, 2.5])

    def test_evidence_without_slot_wait_is_compared_unadjusted(self):
        result = run(arm("base", 0), arm("head", 0, "new", prefill=6600.0),
                     arm("head", 1, "new", prefill=6700.0), arm("base", 1))
        self.assertEqual(verdicts(result, "slot_wait_ms"), ["missing"])
        self.assertEqual(verdicts(result, "ttft_ms"), ["slower"])
        self.assertEqual(result["status"], "failed")

    def test_incomplete_pairs_are_rejected(self):
        with self.assertRaises(ValueError):
            run(arm("base", 0))
        base = arm("base", 0)
        lone = copy.deepcopy(base)
        lone["mode"] = "mtp"
        with self.assertRaises(ValueError):
            run(base, arm("head", 0), lone)


class MemcpyRepeatabilityTest(unittest.TestCase):
    """Payload-bound copy phases are reported, not judged, inside their band."""

    def test_snapshot_move_inside_repeatability_is_reported_not_gated(self):
        # October 2026 #703 evidence: identical binaries differed by up to 53%.
        result = run(arm("base", 0, snapshot=73.32), arm("head", 0, "new", snapshot=58.06),
                     arm("head", 1, "new", snapshot=50.08), arm("base", 1, snapshot=61.14))
        self.assertEqual(verdicts(result, "cache_snapshot_ms"), ["within noise"])
        self.assertEqual(verdicts(result, "cache_snapshot_ms", "no-reuse"), ["within noise"])
        self.assertEqual(result["status"], "passed")
        self.assertTrue(any("cache_snapshot_ms" in note and "not qualified" in note
                            for note in result["notes"]))
        self.assertEqual(result["memcpy_repeatability"], compare.MEMCPY_REPEATABILITY)

    def test_snapshot_move_beyond_repeatability_still_fails(self):
        result = run(arm("base", 0, snapshot=40.0), arm("head", 0, "new", snapshot=80.0),
                     arm("head", 1, "new", snapshot=82.0), arm("base", 1, snapshot=41.0))
        self.assertEqual(verdicts(result, "cache_snapshot_ms"), ["slower"])
        self.assertEqual(result["status"], "failed")

    def test_snapshot_payload_change_is_a_work_difference(self):
        result = run(arm("base", 0, snapshot=73.32),
                     arm("head", 0, "new", snapshot=58.06, snapshot_bytes=544091652),
                     arm("head", 1, "new", snapshot=50.08, snapshot_bytes=544091652),
                     arm("base", 1, snapshot=61.14))
        self.assertEqual(verdicts(result, "cache_snapshot_ms"), ["work differs"])
        self.assertEqual(result["status"], "inconclusive")

    def test_evidence_without_the_payload_is_not_softened(self):
        result = run(arm("base", 0, snapshot=73.32, snapshot_bytes=None),
                     arm("head", 0, "new", snapshot=58.06, snapshot_bytes=None),
                     arm("head", 1, "new", snapshot=50.08, snapshot_bytes=None),
                     arm("base", 1, snapshot=61.14, snapshot_bytes=None))
        self.assertEqual(verdicts(result, "cache_snapshot_ms"), ["faster"])

    def test_decode_keeps_the_strict_floor(self):
        # The band covers copies only; decode is what this control exists to catch.
        result = run(arm("base", 0, decode=57.96), arm("head", 0, "new", decode=54.61),
                     arm("head", 1, "new", decode=53.42), arm("base", 1, decode=53.48))
        self.assertEqual(verdicts(result, "decode_ms"), ["noisy"])
        self.assertEqual(result["status"], "inconclusive")

    def test_table_reports_payload_and_throughput(self):
        result = run(arm("base", 0), arm("head", 0, "new"))
        self.assertIn("(1.07 GB, ", compare.table(result))
        self.assertIn("GB/s)", compare.table(result))


CHILD = """
import signal, sys, time
signal.signal(signal.SIGBREAK, lambda *_: sys.exit(0))
print("ready", flush=True)
for _ in range(600):
    time.sleep(0.1)
sys.exit(3)
"""


@unittest.skipUnless(os.name == "nt", "console control events are Windows-only")
class StopTest(unittest.TestCase):
    def test_ctrl_break_reaches_only_the_private_console(self):
        process = control.launch([sys.executable, "-c", CHILD], subprocess.PIPE)
        self.assertEqual(process.stdout.readline().strip(), b"ready")
        code, graceful = control.stop(process, timeout=20)
        process.stdout.close()
        self.assertEqual((code, graceful), (0, True))


if __name__ == "__main__":
    unittest.main()
