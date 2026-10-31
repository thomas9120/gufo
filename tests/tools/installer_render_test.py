#!/usr/bin/env python3
"""Layout and syntax checks for the Windows TUI installer.

The installer draws its screens in PowerShell. preview.ps1 renders them to
plain text so the layout can be checked without an interactive terminal: every
row must fit the requested width, colours must not move anything, and the
fallback glyph set must not rely on box-drawing characters.
"""

import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
PREVIEW = ROOT / "tools/installer/preview.ps1"
SETUP = ROOT / "tools/installer/Gufo-Setup.ps1"
POWERSHELL = shutil.which("powershell") or shutil.which("pwsh")
ANSI = re.compile("\x1b\\[[0-9;?]*[A-Za-z]")
BOX_GLYPHS = re.compile(r"[\u2500-\u257f\u2580-\u259f]")
SCREENS = ("splash", "menu", "advanced", "review", "run", "done",
           "uninstall", "log", "help")


def strip_ansi(text):
    return ANSI.sub("", text)


@unittest.skipUnless(sys.platform == "win32" and POWERSHELL, "Windows PowerShell is required")
class InstallerRenderTest(unittest.TestCase):
    def render(self, screens="menu", width=100, height=30, mode="None", ascii_theme=False):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "frame.txt"
            command = [POWERSHELL, "-NoLogo", "-NoProfile", "-ExecutionPolicy", "Bypass",
                       "-File", str(PREVIEW), "-Screen", screens,
                       "-Width", str(width), "-Height", str(height),
                       "-Mode", mode, "-OutFile", str(output)]
            if ascii_theme:
                command.append("-Ascii")
            result = subprocess.run(command, cwd=ROOT, capture_output=True,
                                    text=True, encoding="utf-8", errors="replace")
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            return output.read_text(encoding="utf-8")

    def frames(self, text, height):
        lines = text.splitlines()
        size = height + 1  # each frame is padded to the height plus one blank line
        self.assertEqual(len(lines) % size, 0, "unexpected frame length")
        return [lines[start:start + size] for start in range(0, len(lines), size)]

    def test_every_row_fits_the_requested_width(self):
        for width in (72, 80, 100, 132):
            with self.subTest(width=width):
                text = self.render(screens=",".join(SCREENS), width=width, height=30)
                for frame in self.frames(text, 30):
                    for row in frame:
                        self.assertLessEqual(len(strip_ansi(row)), width, row)

    def test_plain_output_has_no_escape_sequences(self):
        text = self.render(screens="menu,run", mode="None")
        self.assertNotIn("\x1b", text)

    def test_colour_does_not_change_layout(self):
        for width in (72, 100):
            with self.subTest(width=width):
                plain = self.render(screens=",".join(SCREENS), width=width, mode="None")
                colour = strip_ansi(self.render(screens=",".join(SCREENS), width=width, mode="TrueColor"))
                self.assertEqual(plain, colour)

    def test_fallback_glyphs_avoid_box_drawing(self):
        text = self.render(screens=",".join(SCREENS), ascii_theme=True)
        self.assertIsNone(BOX_GLYPHS.search(text), "ascii fallback used box-drawing glyphs")

    def test_screens_show_their_expected_labels(self):
        text = self.render(screens=",".join(SCREENS))
        for label in ("Gufo Setup", "Install folder", "windows-main", "Start setup",
                      "Compiling the engine", "Latest output", "Gufo is ready",
                      "Type uninstall to confirm", "Setup complete", "quit"):
            self.assertIn(label, text)

    def test_run_and_uninstall_fit_the_minimum_height(self):
        text = self.render(screens="run,uninstall", width=72, height=20)
        for frame in self.frames(text, 20):
            for row in frame:
                self.assertLessEqual(len(strip_ansi(row)), 72, row)

    def test_uninstall_confirmation_stays_visible_with_all_paths_and_warnings(self):
        script = r'''
. $env:GUFO_PREVIEW -Screen splash -Width 72 -Height 20 -OutFile $env:GUFO_FRAME
$state.Screen = 'uninstall'
$state.Uninstall.Items[0].Warning = 'This checkout has unpublished commits and model files. Keep this folder.'
$state.Uninstall.Items[2].Files = @('C:\Gufo\launcher.json', 'C:\Gufo\installer.json', 'C:\Gufo\logs', 'C:\Gufo\installer')
$state.Uninstall.Items[3].Files += 'C:\Start Menu\Gufo Setup.lnk'
Set-GufoNotice $state 'A warning that must stay visible while confirming uninstall.'
foreach ($height in @(20, 30)) {
  $state.Height = $height
  for ($index = 0; $index -lt $state.Uninstall.Items.Count; $index++) {
    $state.Uninstall.Index = $index
    $frame = @(Resize-GufoFrame (Get-GufoScreen $state) $height)
    $text = $frame -join "`n"
    foreach ($label in @('Type uninstall to confirm', 'Space toggle', 'Enter remove', 'Esc back', $state.Uninstall.Items[$index].Label)) {
      if (-not $text.Contains($label)) { throw "Missing $label at height $height, selection $index" }
    }
  }
}
$state.Height = 20
$state.Uninstall.Index = 0
[void](Get-GufoScreen $state)
$before = $state.Uninstall.Offset
Invoke-GufoKey $state 'PgDn'
[void](Get-GufoScreen $state)
if ($state.Uninstall.Offset -le $before) { throw 'Page Down did not scroll the uninstall list' }
Invoke-GufoKey $state 'PgUp'
[void](Get-GufoScreen $state)
if ($state.Uninstall.Offset -ne $before) { throw 'Page Up did not restore the uninstall list' }
'''
        with tempfile.TemporaryDirectory() as directory:
            result = subprocess.run(
                [POWERSHELL, "-NoLogo", "-NoProfile", "-Command", script], cwd=ROOT,
                capture_output=True, text=True, encoding="utf-8", errors="replace",
                env={**os.environ, "GUFO_PREVIEW": str(PREVIEW),
                     "GUFO_FRAME": str(Path(directory) / "frame.txt")},
            )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_unknown_screen_is_rejected(self):
        command = [POWERSHELL, "-NoLogo", "-NoProfile", "-ExecutionPolicy", "Bypass",
                   "-File", str(PREVIEW), "-Screen", "nope"]
        result = subprocess.run(command, cwd=ROOT, capture_output=True,
                                text=True, encoding="utf-8", errors="replace")
        self.assertNotEqual(result.returncode, 0)

    def test_installer_scripts_parse(self):
        command = [POWERSHELL, "-NoLogo", "-NoProfile", "-Command",
                   "$bad=$false; foreach ($f in @($env:GUFO_SETUP, $env:GUFO_PREVIEW)) {"
                   " $e=$null; [void][System.Management.Automation.Language.Parser]::ParseFile("
                   "  (Resolve-Path $f), [ref]$null, [ref]$e);"
                   " if ($e) { $e | ForEach-Object { Write-Output ($f + ': ' + $_.Message) }; $bad=$true } };"
                   " if ($bad) { exit 1 }"]
        environment = {"GUFO_SETUP": str(SETUP), "GUFO_PREVIEW": str(PREVIEW)}
        result = subprocess.run(command, cwd=ROOT, capture_output=True, text=True,
                                encoding="utf-8", errors="replace",
                                env={**os.environ, **environment})
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_advanced_edit_accepts_spaces(self):
        script = (
            '. $env:GUFO_SETUP; '
            '$s = @{ Screen = "advanced"; Small = $false; Done = $null; Uninstall = $null; Run = $null;'
            ' Edit = @{ Key = "install"; Buffer = "C:\\Program" } }; '
            'Invoke-GufoKey $s "Space"; Invoke-GufoKey $s "Char:F"; '
            'Write-Output ("[" + $s.Edit.Buffer + "]")')
        command = [POWERSHELL, "-NoLogo", "-NoProfile", "-Command", script]
        result = subprocess.run(command, cwd=ROOT, capture_output=True, text=True,
                                encoding="utf-8", errors="replace",
                                env={**os.environ, "GUFO_SETUP": str(SETUP)})
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("[C:\\Program F]", result.stdout)

    def test_installer_pins_the_same_git_as_setup(self):
        installer = re.search(r'GufoGitVersion = "([^"]+)"', SETUP.read_text(encoding="utf-8-sig"))
        setup = re.search(r'Git = @\("Git\.Git", "([^"]+)"\)',
                          (ROOT / "tools/windows/setup.ps1").read_text(encoding="utf-8-sig"))
        self.assertTrue(installer and setup, "Git pin not found")
        self.assertEqual(installer.group(1), setup.group(1))

    def test_release_workflow_fills_every_launcher_placeholder(self):
        launcher = (ROOT / "Gufo-Setup.cmd").read_text(encoding="ascii")
        workflow = (ROOT / ".github/workflows/release.yml").read_text(encoding="utf-8")
        placeholders = set(re.findall(r"@[A-Z0-9]+@", launcher))
        self.assertEqual(placeholders, {"@REPO@", "@TAG@", "@PS1SHA256@"})
        for placeholder in placeholders:
            self.assertIn(f'b"{placeholder}"', workflow)

    def test_launcher_uses_crlf_line_endings(self):
        data = (ROOT / "Gufo-Setup.cmd").read_bytes()
        self.assertNotIn(b"\n", data.replace(b"\r\n", b""))


if __name__ == "__main__":
    unittest.main()
