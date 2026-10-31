"""Upstream sync guard checks against a synthetic official/fork history."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
TOOLS = ROOT / "tools" / "windows"
SHELLS = [path for name in ("powershell.exe", "pwsh.exe", "pwsh")
          if (path := shutil.which(name))]


@unittest.skipUnless(SHELLS and shutil.which("git"), "PowerShell and git are required")
class SyncToolsTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="gufo-sync-")
        self.addCleanup(self.temporary.cleanup)
        self.repo = Path(self.temporary.name).resolve() / "repo"
        self.repo.mkdir()
        self.git("init", "-q", "-b", "main")
        self.git("config", "user.email", "test@example.invalid")
        self.git("config", "user.name", "Test")
        self.git("config", "core.autocrlf", "false")
        # Official history: base, then a regressing PR.
        self.write("src/shared.cpp", "int Shared() { return 1; }\n")
        self.write("src/engine.cpp", "int Engine() { return 1; }\n")
        self.write("docs/compat.md", "# Contracts\n\n- [ ] **Sockets.** Keep them.\n"
                   "- [ ] **Filesystem.** Keep it.\n")
        self.base = self.commit("chore: base (#1)")
        self.write("src/engine.cpp", "int Engine() { return FastThing(); }\n")
        self.regression = self.commit("perf: fast thing (#2)")
        # Fork: Windows file plus one shared edit, starting at the base.
        self.git("switch", "-q", "-c", "fork", self.base)
        self.write("compat/win32/posix.cpp", "int Posix() { return 0; }\n")
        self.write("src/shared.cpp", "int Shared() { return 2; }\n")
        self.fork = self.commit("feat: windows")
        self.write_json("allow.json", {"files": {"src/shared.cpp": {"reason": "test"}}})
        self.write_json("regressions.json", {"regressions": [{
            "pr": 2, "title": "fast thing", "mergeSha": self.regression,
            "status": "reverted", "revertSha": "", "log": "docs/sync.md",
            "symptom": "slow", "absentIdentifiers": ["FastThing"],
            "reintroductionChecks": ["Rerun the control."]}]})

    def git(self, *args):
        return subprocess.run(["git", *args], cwd=self.repo, check=True,
                              capture_output=True, text=True).stdout.strip()

    def write(self, name, text):
        path = self.repo / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8", newline="\n")

    def write_json(self, name, value):
        (self.repo.parent / name).write_text(json.dumps(value), encoding="utf-8")

    def commit(self, message):
        self.git("add", "-A")
        self.git("commit", "-q", "-m", message)
        return self.git("rev-parse", "HEAD")

    def run_tool(self, script, *args):
        results = []
        for shell in SHELLS:
            result = subprocess.run(
                [shell, "-NoProfile", "-ExecutionPolicy", "Bypass", "-File",
                 str(TOOLS / script), *args],
                cwd=self.repo, capture_output=True, text=True, timeout=120)
            results.append(result)
        # Every available PowerShell must agree.
        self.assertEqual(len({r.returncode for r in results}), 1,
                         [r.stdout + r.stderr for r in results])
        return results[0]

    def guard(self, head="HEAD", official="main"):
        side = self.repo.parent
        return self.run_tool("diff-guard.ps1", "-Official", official, "-Head", head,
                             "-Allowlist", str(side / "allow.json"),
                             "-Regressions", str(side / "regressions.json"))

    def inventory(self, *args):
        side = self.repo.parent
        return self.run_tool("sync-inventory.ps1", "-OfficialHead", "main", "-Offline",
                             "-Regressions", str(side / "regressions.json"),
                             "-Contracts", str(self.repo / "docs/compat.md"),
                             "-SharedEdits", str(side / "allow.json"), *args)

    def test_guard_accepts_listed_and_fork_owned_files(self):
        result = self.guard(official=self.base)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("1 fork-owned files", result.stdout)

    def test_guard_rejects_unlisted_shared_edit(self):
        self.write("src/engine.cpp", "int Engine() { return 3; }\n")
        self.commit("fix: windows engine")
        result = self.guard(official=self.base)
        self.assertEqual(result.returncode, 1)
        self.assertIn("src/engine.cpp: upstream file changed (M) but not listed", result.stdout)

    def test_guard_warns_on_stale_entry(self):
        self.write_json("allow.json", {"files": {
            "src/shared.cpp": {"reason": "test"}, "src/engine.cpp": {"reason": "stale"},
            "compat/win32/posix.cpp": {"reason": "fork-owned"}}})
        result = self.guard(official=self.base)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("src/engine.cpp: listed but matches upstream", result.stderr + result.stdout)
        self.assertIn("compat/win32/posix.cpp: listed but", result.stderr + result.stdout)

    def test_guard_requires_markers_per_hunk(self):
        self.write_json("allow.json", {"files": {"src/shared.cpp": {"reason": "t", "markers": True}}})
        result = self.guard(official=self.base)
        self.assertEqual(result.returncode, 1)
        self.assertIn("src/shared.cpp: hunk +1 has no WINDOWS: marker", result.stdout)
        self.write("src/shared.cpp", "// WINDOWS: native return value.\nint Shared() { return 2; }\n")
        self.commit("docs: mark windows edit")
        result = self.guard(official=self.base)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def merge_and_revert(self):
        self.git("merge", "-q", "--no-ff", "-m", "chore(sync): merge", "main")
        self.git("revert", "--no-edit", self.regression)
        revert = self.git("rev-parse", "HEAD")
        regressions = json.loads((self.repo.parent / "regressions.json").read_text())
        regressions["regressions"][0]["revertSha"] = revert
        self.write_json("regressions.json", regressions)
        return revert

    def test_guard_allows_files_of_a_reverted_regression(self):
        self.merge_and_revert()
        result = self.guard()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("1 via reverted regressions", result.stdout)
        # Without the revert recorded, the revert's shared edit is unlisted.
        self.write_json("regressions.json", {"regressions": []})
        result = self.guard()
        self.assertEqual(result.returncode, 1)
        self.assertIn("src/engine.cpp: upstream file changed (M)", result.stdout)

    def test_inventory_gates_an_arriving_regression(self):
        result = self.inventory("-WindowsBase", "fork")
        self.assertEqual(result.returncode, 1)
        self.assertIn("**FAIL**: this sync imports the regression", result.stdout)
        self.assertIn("| [#2](https://github.com/gufo-org/gufo/pull/2) | perf: fast thing; "
                      "**reverted/deferred on Windows** |", result.stdout)
        self.assertIn("| Sockets | pending (TBD) |", result.stdout)
        self.assertIn("| Filesystem | pending (TBD) |", result.stdout)

        self.git("merge", "-q", "--no-ff", "-m", "chore(sync): merge", "main")
        merged = self.git("rev-parse", "HEAD")
        result = self.inventory("-WindowsBase", self.fork, "-Candidate", merged)
        self.assertEqual(result.returncode, 1)
        self.assertIn("candidate contains reverted code: FastThing: src/engine.cpp", result.stdout)

        self.git("revert", "--no-edit", self.regression)
        result = self.inventory("-WindowsBase", self.fork, "-Candidate", "HEAD")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("PASS: none of the 1 reverted identifiers", result.stdout)

    def test_inventory_reports_upstream_work_on_reverted_regions(self):
        revert = self.merge_and_revert()
        self.git("switch", "-q", "main")
        self.write("src/engine.cpp", "int Engine() { return FastThing() + 1; }\n")
        fix = self.commit("fix: fast thing on more hosts (#3)")
        self.write("README.md", "Note.\n")
        self.commit("docs: note the follow-up to #2 (#4)")
        self.git("switch", "-q", "fork")

        result = self.inventory("-WindowsBase", "fork")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(f"REVIEW `{fix[:8]}` fix: fast thing on more hosts (#3): "
                      "touches `src/engine.cpp`", result.stdout)
        self.assertIn("docs: note the follow-up to #2 (#4): mentions #2.", result.stdout)
        self.assertIn("- `src/engine.cpp`", result.stdout)  # changed on both sides

        result = self.inventory("-WindowsBase", "fork", "-Candidate", "HEAD")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(f"revert `{revert[:8]}` is an ancestor", result.stdout)

    def test_inventory_suggests_batches(self):
        self.write_json("regressions.json", {"regressions": []})
        self.write_json("batching.json", {
            "limits": {"convergence": 1, "timing": 4}, "releaseCuts": True,
            "classes": {
                "convergence": {"paths": ["src/core/platform/*"], "checks": "Converge."},
                "timing": {"paths": ["src/models/qwen/*"], "checks": "Time it."},
                "shared": {"checks": "Review shared."},
                "contained": {"checks": "CPU gate."},
                "inert": {"paths": ["*.md", "version.txt"], "checks": "Docs only."}}})
        self.git("switch", "-q", "main")
        self.write("src/core/platform/a.cpp", "int A() { return 0; }\n")
        self.commit("feat(platform): a leaf (#3)")
        self.write("src/models/qwen/b.cpp", "int B() { return 0; }\n")
        self.write("src/shared.cpp", "int Shared() { return 3; }\n")
        self.commit("perf(qwen): faster b (#4)")
        self.write("version.txt", "0.2.0\n")
        release = self.commit("chore(main): release 0.2.0")
        self.git("tag", "v0.2.0")
        self.write("README.md", "Note.\n")
        self.commit("docs: note (#5)")
        self.write("version.txt", "0.2.1\n")
        self.commit("chore(main): release 0.2.1")  # no risk yet, so no cut
        self.write("src/core/platform/c.cpp", "int C() { return 0; }\n")
        second = self.commit("feat(platform): c leaf (#6)")
        self.write("src/core/platform/d.cpp", "int D() { return 0; }\n")
        last = self.commit("feat(platform): d leaf (#7)")
        self.git("switch", "-q", "fork")

        result = self.inventory("-WindowsBase", "fork",
                                "-Batching", str(self.repo.parent / "batching.json"))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        out = result.stdout
        self.assertIn(f"### Batch 1: through `{release[:8]}` (v0.2.0)", out)
        self.assertIn("ends at release v0.2.0.", out)
        self.assertIn("| perf: fast thing (#2) | contained |", out)
        self.assertIn("| perf(qwen): faster b (#4) | timing, shared (`src/shared.cpp`) |", out)
        self.assertIn("- Timing suspects: #4.", out)
        self.assertIn(f"### Batch 2: through `{second[:8]}`", out)
        self.assertIn(f"ends before `{last[:8]}`, which would exceed the convergence limit.", out)
        self.assertIn("| docs: note (#5) | inert |", out)
        self.assertIn(f"| 3 | `{last}` | 1 | convergence | `TBD` |", out)


if __name__ == "__main__":
    unittest.main()
