# Update windows-main from thomas9120/gufo-windows and rebuild Gufo.
[CmdletBinding()]
param(
  [string]$Rocm = "",
  [string]$Vcpkg = "",
  [string]$Ninja = "",
  [ValidateRange(1, 64)][int]$Jobs = 4
)
$ErrorActionPreference = "Stop"
# Reuse setup's read-only tool discovery and running-executable guard.
. "$PSScriptRoot\setup.ps1" -Rocm $Rocm -Vcpkg $Vcpkg -Jobs $Jobs

function Invoke-UpdateGit([string[]]$Arguments) {
  & $tools.Git -C $root @Arguments
  if ($LASTEXITCODE -ne 0) { throw "Git failed (exit $LASTEXITCODE). Fix the reported issue and rerun update-windows.bat." }
}

function Invoke-WindowsUpdate {
  $tools = Get-SetupTools
  if ($Ninja) { $tools.Ninja = (Get-Command $Ninja -CommandType Application -ErrorAction Stop).Source }
  $missing = @(@("Git", "VS", "CMake", "Ninja", "Rocm", "Vcpkg") | Where-Object { -not $tools.$_ })
  if ($missing.Count -or -not (Test-Path -LiteralPath "$($tools.Vcpkg)\vcpkg.exe")) {
    throw "Build prerequisites are missing ($($missing -join ', ')). Run setup-windows.bat first."
  }
  Assert-EngineStopped
  $changes = Invoke-UpdateGit @("status", "--porcelain", "--untracked-files=all")
  if ($changes) { throw "This checkout has local changes or untracked files. Commit, stash or move them before updating." }
  $branch = & $tools.Git -C $root symbolic-ref --quiet --short HEAD
  if ($LASTEXITCODE -ne 0) { throw "Check out a branch before updating; detached HEAD cannot be updated automatically." }
  if ($branch -ne "windows-main") { throw "Check out windows-main before updating; the current branch is '$branch'." }
  $repository = "https://github.com/thomas9120/gufo-windows.git"

  Write-Host "Updating $branch from $repository (windows-main)..." -ForegroundColor Cyan
  # Override pull settings that could rebase or automatically stash local work.
  Invoke-UpdateGit @("pull", "--ff-only", "--no-rebase", "--no-autostash", $repository, "windows-main")
  Assert-EngineStopped
  $env:PATH = "$(Split-Path $tools.Git);$(Split-Path $tools.CMake);$(Split-Path $tools.Ninja);$(Split-Path $tools.Python);$env:PATH"
  $shell = Join-Path $PSHOME "powershell.exe"
  if (-not (Test-Path -LiteralPath $shell)) { $shell = Join-Path $PSHOME "pwsh.exe" }
  Write-Host "Rebuilding build\windows-gpu\gufo.exe..." -ForegroundColor Cyan
  & $shell -NoLogo -NoProfile -ExecutionPolicy Bypass -File "$PSScriptRoot\build.ps1" `
    -Preset windows-gpu -Target gufo -Jobs $Jobs -Rocm $tools.Rocm -Vcpkg $tools.Vcpkg -Ninja $tools.Ninja
  if ($LASTEXITCODE -ne 0) { throw "Build failed. The source update is retained; fix the build issue and rerun update-windows.bat." }
  $engine = Join-Path $root "build\windows-gpu\gufo.exe"
  & $engine --version
  if ($LASTEXITCODE -ne 0) { throw "The rebuilt executable failed its version check. See docs/WINDOWS.md for runtime prerequisites." }
  Write-Host "`nUpdate complete: $engine" -ForegroundColor Green
  Write-Host "Open launch-gui.bat and select this executable in the GUI."
}

if ($MyInvocation.InvocationName -ne ".") {
  try { Invoke-WindowsUpdate } catch {
    Write-Host "`nUpdate stopped: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
  }
}
