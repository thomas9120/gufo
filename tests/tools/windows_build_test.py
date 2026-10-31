"""Exercise OpenMP packaging without compiling or installing dependencies."""

import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]


def quote(value):
    return "'" + str(value).replace("'", "''") + "'"


@unittest.skipUnless(os.name == "nt", "Windows packaging requires Windows")
class WindowsBuildTest(unittest.TestCase):
    def run_packaging(self, *, redist="14.44.35112", environment="selected",
                      runtime=True, standalone=False):
        shells = [path for name in ("powershell.exe", "pwsh.exe")
                  if (path := shutil.which(name))]
        self.assertTrue(shells)
        source = (ROOT / "tools/windows/build.ps1").read_text(encoding="utf-8")
        # Execute the production packaging tail, leaving configure/build untouched.
        packaging = source.split("# Developer use only:", 1)[1]
        for shell in shells:
            with self.subTest(shell=shell), tempfile.TemporaryDirectory(
                    prefix="gufo OpenMP ") as temporary:
                root = Path(temporary).resolve()
                build = root / "build"
                build.mkdir()
                vs = root / "Visual Studio"
                library = vs / "VC/Tools/MSVC/14.44.35207/lib/x64/libomp.lib"
                selected_redist = vs / "VC/Redist/MSVC" / redist
                compiler = root / "LLVM/bin"
                llvm_library = compiler.parent / "lib/libomp.lib"
                if standalone:
                    library = llvm_library
                    dll = compiler / "libomp.dll"
                else:
                    dll = (selected_redist / "debug_nonredist/x64"
                           / "Microsoft.VC143.OpenMP.LLVM/libomp140.x86_64.dll")
                library.parent.mkdir(parents=True)
                library.write_bytes(b"import library fixture")
                if runtime:
                    dll.parent.mkdir(parents=True, exist_ok=True)
                    dll.write_bytes(b"selected runtime fixture")
                (build / "CMakeCache.txt").write_text(
                    f"OpenMP_libomp_LIBRARY:FILEPATH={library.as_posix()}\n")
                env = {key: value for key, value in os.environ.items()
                       if key.lower() not in {"psmodulepath", "vctoolsredistdir"}}
                if environment == "selected":
                    env["VCToolsRedistDir"] = str(selected_redist) + "\\"
                elif environment == "other":
                    other = root / "Other VS/VC/Redist/MSVC/14.50.12345"
                    other_dll = (other / "debug_nonredist/x64"
                                 / "Microsoft.VC145.OpenMP.LLVM/libomp140.x86_64.dll")
                    other_dll.parent.mkdir(parents=True)
                    other_dll.write_bytes(b"unrelated runtime fixture")
                    env["VCToolsRedistDir"] = str(other) + "\\"
                script = root / "package.ps1"
                script.write_text(
                    "$ErrorActionPreference = 'Stop'\n"
                    f"$build = {quote(build)}\n"
                    f"$compilerDir = {quote(compiler.as_posix())}\n"
                    f"$llvmOpenmp = {quote(llvm_library.as_posix())}\n"
                    "$hip = $false\n# Developer use only:" + packaging,
                    encoding="utf-8-sig")
                result = subprocess.run(
                    [shell, "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", str(script)],
                    env=env, capture_output=True, text=True, timeout=30)
                if runtime:
                    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                    self.assertEqual((build / dll.name).read_bytes(), dll.read_bytes())
                else:
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn("Cannot find this build's local OpenMP runtime", result.stderr)
                    self.assertFalse((build / dll.name).exists())

    def test_toolset_and_redist_patch_versions_can_differ(self):
        self.run_packaging()

    def test_exact_version_without_redist_environment(self):
        self.run_packaging(redist="14.44.35207", environment="missing")

    def test_unrelated_visual_studio_runtime_is_not_selected(self):
        self.run_packaging(environment="other", runtime=False)

    def test_missing_runtime_still_fails(self):
        self.run_packaging(runtime=False)

    def test_standalone_llvm_uses_its_own_runtime(self):
        self.run_packaging(environment="other", standalone=True)


if __name__ == "__main__":
    unittest.main()
