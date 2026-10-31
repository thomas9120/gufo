"""Check Windows queue diagnostics before model loading, without a GPU."""

import os
import subprocess
import sys


def main():
    binary = sys.argv[1]
    env = {key: value for key, value in os.environ.items()
           if key not in {"HOST", "PORT", "GUFO_HOST", "GUFO_PORT",
                          "GPU_MAX_HW_QUEUES"}}

    def run(args, status):
        result = subprocess.run([binary, *args], env=env, text=True,
                                capture_output=True, timeout=10)
        assert result.returncode == status, (args, result.stderr)
        return result.stderr

    for cap in (None, "", "1", "2", "4", "invalid"):
        if cap is None:
            env.pop("GPU_MAX_HW_QUEUES", None)
        else:
            env["GPU_MAX_HW_QUEUES"] = cap
        source = "operator" if cap else "runtime"
        for modality in ("llm", "tts", "asr", "video", "image"):
            args = ["serve", modality, "--model", "missing.gguf"]
            expected = (f"event=queue_budget kind={modality} "
                        "observed=unknown budget=unknown "
                        f"expected_max=unknown cap={source} census=unavailable")
            for level in ("info", "debug", "warn", "error"):
                output = run([*args, "--log-level", level], 1)
                assert (expected in output) == (level in {"info", "debug"}), (
                    cap, modality, level, output)
                assert "event=queue_budget_exceeded" not in output
            assert "event=queue_budget" not in run(
                ["serve", modality, "--help"], 0)
            assert "event=queue_budget" not in run(
                ["serve", modality, "--host", "invalid"], 2)
    print("Windows queue policy: all modalities/settings/thresholds passed")


if __name__ == "__main__":
    main()
