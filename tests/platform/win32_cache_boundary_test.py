"""Validate the Windows shim before running the unchanged cache boundary check."""

import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest


CONFIG = Path(__file__).with_name("win32_cache_dependencies.json")
SCOPE_MARKER = re.compile(r"::@(?:\([0-9a-fA-F]+\))?")


def dependencies(metadata):
    return [library for line in metadata.read_text().splitlines()
            for library in line.split(";")
            if library and not SCOPE_MARKER.fullmatch(library)]


def upstream_links(cache_metadata, compat_metadata, config):
    """Remove only a reviewed shim; leave all other links for upstream to check."""
    allowed = json.loads(config.read_text())
    compat_links = dependencies(compat_metadata)
    for library in compat_links:
        if library not in allowed["gufo_posix_compat"]:
            raise ValueError(f"gufo_posix_compat: unapproved dependency {library}")
    return [library for library in dependencies(cache_metadata)
            if library != "gufo_posix_compat"]


class WindowsBoundaryTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.cache = Path(self.tmp.name) / "cache.txt"
        self.compat = Path(self.tmp.name) / "compat.txt"
        self.cache.write_text("Threads::Threads;::@(000012AB);gufo_posix_compat;::@\n")
        self.compat.write_text("ws2_32;psapi;advapi32\nws2_32;psapi;advapi32\n")

    def test_reviewed_shim(self):
        self.assertEqual(upstream_links(self.cache, self.compat, CONFIG),
                         ["Threads::Threads"])

    def test_unreviewed_compat_dependencies(self):
        for library in ("hip::host", "dxgi", "gufo_core", "gufo_model_relay"):
            with self.subTest(library=library):
                self.compat.write_text("ws2_32;psapi;" + library + "\n")
                with self.assertRaisesRegex(ValueError, "unapproved dependency"):
                    upstream_links(self.cache, self.compat, CONFIG)

    def test_unreviewed_cache_links_stay_visible(self):
        for library in ("hip::host", "gufo_core", "gufo_model_relay", "::@(not-hex)"):
            with self.subTest(library=library):
                self.cache.write_text("gufo_posix_compat;" + library + "\n")
                self.assertEqual(upstream_links(self.cache, self.compat, CONFIG), [library])

    def test_missing_metadata_or_config_fails(self):
        for path in (self.cache, self.compat, Path(self.tmp.name) / "config.json"):
            with self.subTest(path=path):
                if path.exists():
                    contents = path.read_text()
                    path.unlink()
                else:
                    contents = None
                try:
                    config = path if path.name == "config.json" else CONFIG
                    with self.assertRaises(FileNotFoundError):
                        upstream_links(self.cache, self.compat, config)
                finally:
                    if contents is not None:
                        path.write_text(contents)


def main():
    upstream, root, cache, compat = map(Path, sys.argv[1:])
    try:
        links = upstream_links(cache, compat, CONFIG)
    except (OSError, ValueError) as error:
        sys.exit(str(error))
    with tempfile.TemporaryDirectory() as tmp:
        metadata = Path(tmp) / "cache-links.txt"
        metadata.write_text(";".join(links) + "\n")
        result = subprocess.run([sys.executable, str(upstream), str(root), str(metadata)])
    if result.returncode:
        return result.returncode
    tests = unittest.main(argv=[sys.argv[0]], exit=False)
    return 0 if tests.result.wasSuccessful() else 1


if __name__ == "__main__":
    sys.exit(main())
