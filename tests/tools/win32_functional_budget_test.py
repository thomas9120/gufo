"""Reject unmatched effective cache budgets before Windows timing qualification."""

import importlib.util
import json
from pathlib import Path
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "win32_compare_functional", ROOT / "tools/windows/compare-functional.py")
compare = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(compare)


class BudgetTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)

    def run_fixture(self, name, requested=8192, ram=8192, staging=1024, disk=8192):
        path = self.root / name
        path.mkdir()
        report = {"command": ["gufo", "serve", "llm", "--cache-ram-bytes", str(requested)],
                  "restart_ms": 1}
        (path / "report.json").write_text(json.dumps(report))
        log = ("[cache] schema=component-cache-v1 event=configured sessions=2 "
               f"capacity_bytes={ram} staging_capacity_bytes={staging} "
               f"disk_capacity_bytes={disk}\n")
        for name in ("server.log", "server-restarted.log"):
            (path / name).write_text(log)
        return path

    def test_equal_effective_budgets_accept_control_anchor_reuse(self):
        base, head, control = [self.run_fixture(name) for name in ("base", "head", "control")]
        result = compare.validate_budgets([(base, head)], [(base, control)])
        self.assertEqual(len(result), 3)

    def test_identical_requests_do_not_hide_clamping(self):
        base = self.run_fixture("base")
        head = self.run_fixture("head", ram=4096)
        with self.assertRaisesRegex(ValueError, "requested RAM cache 8192, configured 4096"):
            compare.validate_budgets([(base, head)])

    def test_restart_must_honor_the_request_too(self):
        path = self.run_fixture("head")
        log = path / "server-restarted.log"
        log.write_text(log.read_text().replace("capacity_bytes=8192", "capacity_bytes=4096", 1))
        with self.assertRaisesRegex(ValueError, "server-restarted.log: requested RAM cache"):
            compare.cache_budgets(path)

    def test_equals_option_cannot_hide_clamping(self):
        path = self.run_fixture("head", ram=4096)
        report = path / "report.json"
        data = json.loads(report.read_text())
        data["command"] = ["gufo", "serve", "llm", "--cache-ram-bytes=8192"]
        report.write_text(json.dumps(data))
        with self.assertRaisesRegex(ValueError, "requested RAM cache 8192, configured 4096"):
            compare.cache_budgets(path)

    def test_equal_ram_does_not_hide_different_staging_or_disk(self):
        base = self.run_fixture("base")
        for key in ("staging", "disk"):
            with self.subTest(key=key):
                head = self.run_fixture(key, **{key: 2048})
                with self.assertRaisesRegex(ValueError, "effective cache budgets differ"):
                    compare.validate_budgets([(base, head)])

    def test_automatic_ram_still_needs_matching_effective_capacity(self):
        base = self.run_fixture("base", requested=0)
        head = self.run_fixture("head", requested=0, ram=4096)
        with self.assertRaisesRegex(ValueError, "effective cache budgets differ"):
            compare.validate_budgets([(base, head)])

    def test_missing_configuration_cannot_qualify(self):
        path = self.run_fixture("base")
        (path / "server.log").write_text("server started\n")
        with self.assertRaisesRegex(ValueError, "expected one component-cache configuration"):
            compare.cache_budgets(path)


if __name__ == "__main__":
    unittest.main()
