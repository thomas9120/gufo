"""Guided setup checks using temporary files and simulated installers; no installs."""

import hashlib
import http.server
import io
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import threading
import unittest


ROOT = Path(__file__).resolve().parents[2]


def quote(value):
    return "'" + str(value).replace("'", "''") + "'"


@unittest.skipUnless(os.name == "nt", "Windows setup requires Windows")
class WindowsSetupTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="gufo setup ")
        self.addCleanup(self.temporary.cleanup)
        # Native process paths expand Windows 8.3 aliases used by CI's TEMP.
        self.root = Path(self.temporary.name).resolve()
        self.shells = [path for name in ("powershell.exe", "pwsh.exe")
                       if (path := shutil.which(name))]
        self.assertTrue(self.shells)
        self.environment = {key: value for key, value in os.environ.items()
                            if key.lower() != "psmodulepath"}

    def run_ps(self, body, *, main=False):
        for index, shell in enumerate(self.shells):
            with self.subTest(shell=shell):
                case = self.root / f"case-{index}"
                case.mkdir(exist_ok=True)
                script = case / "test.ps1"
                script.write_text(
                    f". {quote(ROOT / 'tools/windows/setup.ps1')}\n"
                    f"$root = {quote(case)}\n"
                    "$stateFile = Join-Path $root 'build/windows-setup.json'\n"
                    "$deps = Join-Path $root 'dependencies'\n"
                    "$ErrorActionPreference = 'Stop'\n"
                    "function Assert($condition, $message) { if (-not $condition) { throw $message } }\n"
                    + (self.main_fixture() if main else "") + body,
                    encoding="utf-8-sig",
                )
                result = subprocess.run(
                    [shell, "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", str(script)],
                    cwd=self.root, env=self.environment, capture_output=True, text=True,
                    timeout=60,
                )
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    @staticmethod
    def main_fixture():
        return r'''
$Yes = $true
$NoLaunch = $true
$events = [Collections.Generic.List[string]]::new()
function Assert-SetupMachine { }
function Assert-EngineStopped { }
function Assert-SetupSpace { }
function Get-SetupTools {
  [pscustomobject]@{Git='C:\tools\git.exe'; VS='C:\vs'; CMake='C:\tools\cmake.exe';
    Ninja='C:\tools\ninja.exe'; Python='C:\python\python.exe'; Rocm='C:\rock'; Vcpkg='C:\vcpkg'}
}
function Initialize-SetupVcpkg { $events.Add('vcpkg'); return 'C:\vcpkg' }
function Install-SetupPackage { throw 'Unexpected package installation' }
function Install-SetupRock { throw 'Unexpected download' }
function Invoke-SetupCommand($File, $Arguments) { $events.Add("$File $Arguments") }
'''

    def test_preview_and_declining_plan_do_not_mutate(self):
        self.run_ps(r'''
$CheckOnly = $true
Invoke-WindowsSetup
Assert ($events.Count -eq 0) 'Preview executed a command'
Assert (-not (Test-Path -LiteralPath $stateFile)) 'Preview wrote state'
$CheckOnly = $false
$Yes = $false
function Read-Host { return 'n' }
Invoke-WindowsSetup
Assert ($events.Count -eq 0) 'Declining the plan executed a command'
Assert (-not (Test-Path -LiteralPath $stateFile)) 'Declining the plan wrote state'
''', main=True)

    def test_batch_runs_from_another_directory_and_forwards_quoted_arguments(self):
        checkout = self.root / "checkout & spaces"
        script = checkout / "tools/windows/setup.ps1"
        script.parent.mkdir(parents=True)
        script.write_text('''param([switch]$CheckOnly, [string]$Vcpkg)
Write-Output "PREVIEW=$CheckOnly"
Write-Output "VCPKG=$Vcpkg"
exit 0
''')
        batch = checkout / "setup-windows.bat"
        shutil.copy2(ROOT / "setup-windows.bat", batch)
        selected = self.root / "vcpkg & tools"
        command = f'"{os.environ["COMSPEC"]}" /d /s /c ""{batch}" -CheckOnly -Vcpkg "{selected}""'
        result = subprocess.run(command, cwd=self.root, env=self.environment,
                                capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("PREVIEW=True", result.stdout)
        self.assertIn(f"VCPKG={selected}", result.stdout)

    def test_existing_tools_no_install_and_settings_preserved(self):
        self.run_ps(r'''
$settings = Join-Path $root 'launcher.json'
Set-Content -LiteralPath $settings -Value '{"settings":{"executable":"custom.exe","model":"mine.gguf"}}'
$before = (Get-FileHash -LiteralPath $settings).Hash
Invoke-WindowsSetup
Assert ((Get-FileHash -LiteralPath $settings).Hash -eq $before) 'Settings changed'
Assert (Test-Path -LiteralPath $stateFile) 'Tool paths not saved'
Assert (($events -match 'build.ps1').Count -eq 1) 'Build not run'
Assert (($events -match 'build.ps1.*-Preset windows-gpu').Count -eq 1) 'Wrong build preset'
Assert (($events -match 'check.ps1.*-Hip').Count -eq 1) 'HIP prerequisites not checked'
Assert (($events -match 'check.ps1.*-Python').Count -eq 0) 'Unsupported prerequisite argument'
Assert (($events -match 'windows-gpu\\gufo.exe --version').Count -eq 1) 'Wrong executable path'
Assert (($events -match 'diagnose --section gpu').Count -eq 1) 'GPU check not run'
Assert (($events -match 'gui.ps1').Count -eq 1) 'NoLaunch opened GUI'
Assert (($events -match '-PrepareOnly').Count -eq 1) 'GUI environment not prepared'
''', main=True)

    def test_failure_does_not_advance_to_gui_or_claim_success(self):
        self.run_ps(r'''
function Invoke-SetupCommand($File, $Arguments) {
  $events.Add("$File $Arguments")
  if ($Arguments -contains 'diagnose') { throw 'GPU driver unavailable' }
}
$failed = $false
try { Invoke-WindowsSetup } catch { $failed = $_.Exception.Message -eq 'GPU driver unavailable' }
Assert $failed 'GPU failure was hidden'
Assert (($events -match 'gui.ps1').Count -eq 0) 'GUI opened despite failed startup'
Assert (Test-Path -LiteralPath $stateFile) 'Completed setup paths lost'
''', main=True)

    def test_missing_package_is_rechecked_and_retry_reuses_it(self):
        self.run_ps(r'''
$installed = $false
function Get-SetupTools {
  [pscustomobject]@{Git='C:\tools\git.exe'; VS='C:\vs'; CMake='C:\tools\cmake.exe';
    Ninja='C:\tools\ninja.exe'; Python=$(if ($script:installed) {'C:\python\python.exe'} else {$null});
    Rocm='C:\rock'; Vcpkg='C:\vcpkg'}
}
function Install-SetupPackage($Name) { $events.Add("install $Name"); $script:installed = $true }
Invoke-WindowsSetup
Invoke-WindowsSetup
Assert (($events -match '^install Python$').Count -eq 1) 'Rerun reinstalled Python'
Assert (($events -match 'build.ps1').Count -eq 2) 'Rerun failed to resume build'
''', main=True)

    def test_running_engine_blocks_rebuild(self):
        self.run_ps(r'''
function Get-Process { [pscustomobject]@{Id=123; Path=(Join-Path $root 'build\windows-gpu\gufo.exe')} }
$failed = $false
try { Assert-EngineStopped } catch { $failed = $_.Exception.Message -match 'Stop it in the launcher' }
Assert $failed 'Running engine was not protected'
''')

    def test_completed_partial_download_is_verified_and_reused(self):
        self.run_ps(r'''
$destination = Join-Path $root 'download.tar.gz'
Set-Content -LiteralPath "$destination.partial" -Value 'verified bytes'
$hash = (Get-FileHash -LiteralPath "$destination.partial").Hash
function Invoke-SetupCommand { throw 'Unexpected network access' }
Get-VerifiedDownload 'https://unused.invalid/archive' $destination $hash
Get-VerifiedDownload 'https://unused.invalid/archive' $destination $hash
Assert (Test-Path -LiteralPath $destination) 'Verified download missing'
Assert (-not (Test-Path -LiteralPath "$destination.partial")) 'Partial not promoted'
Set-Content -LiteralPath $destination -Value 'corrupt bytes'
$failed = $false
try { Get-VerifiedDownload 'https://unused.invalid/archive' $destination $hash } catch {
  $failed = $_.Exception.Message -match 'wrong checksum'
}
Assert $failed 'Corrupt cached archive accepted'
''')

    def test_download_resumes_and_rejects_bad_checksum(self):
        data = b"gufo fixture bytes\n" * 1000
        ranges = []

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                header = self.headers.get("Range")
                ranges.append(header)
                start = int(header.split("=")[1].split("-")[0]) if header else 0
                self.send_response(206 if header else 200)
                self.send_header("Content-Length", str(len(data) - start))
                if header:
                    self.send_header("Content-Range", f"bytes {start}-{len(data)-1}/{len(data)}")
                self.end_headers()
                self.wfile.write(data[start:])

            def log_message(self, *args):
                pass

        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            source = self.root / "prefix.bin"
            source.write_bytes(data[:100])
            url = f"http://127.0.0.1:{server.server_port}/archive"
            self.run_ps(f'''
$destination = Join-Path $root 'archive'
Copy-Item -LiteralPath {quote(source)} -Destination "$destination.partial"
Get-VerifiedDownload {quote(url)} $destination {quote(hashlib.sha256(data).hexdigest())}
Assert ((Get-Item -LiteralPath $destination).Length -eq {len(data)}) 'Resume lost data'
$failed = $false
try {{ Get-VerifiedDownload {quote(url)} "$destination-bad" ('0' * 64) }} catch {{
  $failed = $_.Exception.Message -match 'checksum failed'
}}
Assert $failed 'Bad checksum accepted'
Assert (-not (Test-Path -LiteralPath "$destination-bad")) 'Bad archive promoted'
Assert (-not (Test-Path -LiteralPath "$destination-bad.partial")) 'Corrupt partial retained'
''')
            self.assertIn("bytes=100-", ranges)
        finally:
            server.shutdown()
            server.server_close()
            thread.join()

    def test_verified_archive_extracts_and_incomplete_extraction_is_not_ready(self):
        source = self.root / "rock.tar.gz"
        with tarfile.open(source, "w:gz") as archive:
            for name, data in ((".info/version", b"10.0.0\n"),
                               ("lib/llvm/bin/clang++.exe", b"fixture")):
                entry = tarfile.TarInfo(name)
                entry.size = len(data)
                archive.addfile(entry, io.BytesIO(data))
        self.run_ps(f'''
$cache = Join-Path $deps 'downloads/therock-dist-windows-gfx1151-10.0.0.tar.gz'
New-Item -ItemType Directory -Force -Path (Split-Path $cache) | Out-Null
Copy-Item -LiteralPath {quote(source)} -Destination $cache
$rockHash = (Get-FileHash -LiteralPath $cache).Hash
$installed = Install-SetupRock
Assert (Test-Rock $installed) 'Extracted runtime invalid'
Assert (Test-Path -LiteralPath "$installed/.gufo-complete") 'Completion marker missing'
Remove-Item -LiteralPath "$installed/.gufo-complete"
function Invoke-SetupCommand {{ throw 'interrupted tar extraction' }}
try {{ Install-SetupRock }} catch {{ }}
Assert (-not (Test-Path -LiteralPath "$installed/.gufo-complete")) 'Failed extraction marked ready'
''')

    def test_native_command_failure_propagates(self):
        self.run_ps(r'''
$failed = $false
try { Invoke-SetupCommand $env:ComSpec @('/d', '/c', 'exit 23') } catch {
  $failed = $_.Exception.Message -match 'exit 23'
}
Assert $failed 'Native exit code was swallowed'
''')

    def test_installer_arguments_preserve_version_and_component_selection(self):
        compiler = Path(os.environ["WINDIR"]) / "Microsoft.NET/Framework64/v4.0.30319/csc.exe"
        source = self.root / "installer.cs"
        binary = self.root / "fake winget.exe"
        capture = self.root / "arguments.txt"
        source.write_text('''using System; using System.IO;
class Installer {
  static int Main(string[] args) {
    File.WriteAllLines(Environment.GetEnvironmentVariable("GUFO_SETUP_CAPTURE"), args);
    return 0;
  }
}
''')
        subprocess.run([str(compiler), "/nologo", f"/out:{binary}", str(source)], check=True,
                       capture_output=True)
        self.environment["GUFO_SETUP_CAPTURE"] = str(capture)
        self.run_ps(f'''
function Find-VisualStudio {{ }}
function Get-Command {{ [pscustomobject]@{{Source={quote(binary)}}} }}
Install-SetupPackage VS
$arguments = @(Get-Content -LiteralPath {quote(capture)})
Assert ($arguments -contains '18.8.0') 'Installer version not pinned'
$override = [array]::IndexOf($arguments, '--override')
Assert ($override -ge 0) 'Missing component selection'
Assert ($arguments[$override + 1] -match 'VC.Tools.x86.x64.*Windows11SDK.26100') 'Components split across native arguments'
Assert ($arguments[$override + 1] -match '--norestart') 'Installer could reboot automatically'
Install-SetupPackage Python
$arguments = @(Get-Content -LiteralPath {quote(capture)})
Assert ($arguments -contains 'Python.Python.3.14') 'Wrong Python package'
Assert ($arguments -contains '3.14.6') 'Python version not pinned'
Assert ($arguments -contains 'user') 'Python should use user scope'
''')

    def test_fresh_vcpkg_is_pinned_and_resumes_without_resetting_edits(self):
        git = shutil.which("git")
        self.assertIsNotNone(git)
        upstream = self.root / "vcpkg fixture"
        upstream.mkdir()
        (upstream / "bootstrap-vcpkg.bat").write_text('@echo off\ntype nul > "%~dp0vcpkg.exe"\nexit /b 0\n')
        (upstream / ".gitignore").write_text("vcpkg.exe\n")
        for arguments in (["init"], ["add", "."],
                          ["-c", "user.name=Setup test", "-c", "user.email=setup@example.invalid",
                           "commit", "-m", "fixture"]):
            subprocess.run([git, "-C", str(upstream), *arguments], check=True,
                           capture_output=True, env=self.environment)
        revision = subprocess.check_output([git, "-C", str(upstream), "rev-parse", "HEAD"],
                                           text=True, env=self.environment).strip()
        # Keep production remote checks intact, but fetch only this local fixture.
        self.environment["GIT_CONFIG_COUNT"] = "1"
        self.environment["GIT_CONFIG_KEY_0"] = f"url.{upstream.as_posix()}.insteadOf"
        self.environment["GIT_CONFIG_VALUE_0"] = "https://github.com/microsoft/vcpkg.git"
        # get-url expands insteadOf; use config's stored URL in the setup guard.
        self.run_ps(f'''
Set-Content -LiteralPath (Join-Path $root 'vcpkg.json') -Value '{{"builtin-baseline":"{revision}"}}'
$path = Initialize-SetupVcpkg {quote(git)} ''
Assert (Test-Path -LiteralPath "$path/vcpkg.exe") 'Bootstrap failed'
$head = & {quote(git)} -C $path rev-parse HEAD
Assert ($head -eq '{revision}') 'Wrong vcpkg revision'
$again = Initialize-SetupVcpkg {quote(git)} ''
Assert ($again -eq $path) 'Retry used a different checkout'
Add-Content -LiteralPath "$path/bootstrap-vcpkg.bat" -Value 'rem user edit'
$failed = $false
try {{ Initialize-SetupVcpkg {quote(git)} '' }} catch {{ $failed = $_.Exception.Message -match 'Local changes' }}
Assert $failed 'User edits overwritten'
Assert ((Get-Content -LiteralPath "$path/bootstrap-vcpkg.bat" -Raw) -match 'user edit') 'Edit lost'
''')


if __name__ == "__main__":
    unittest.main()
