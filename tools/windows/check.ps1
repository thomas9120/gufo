# Read-only prerequisite check for the native Windows build.
param(
  [string]$Rocm = "C:\TheRock\build",
  [string]$CompilerBin = "",
  [string]$Vcpkg = "C:\vcpkg",
  [string]$Ninja = "ninja",
  [switch]$Hip
)
$ErrorActionPreference = "Stop"
if (-not [Environment]::Is64BitOperatingSystem) { throw "Windows x64 is required" }
foreach ($tool in @("cmake", $Ninja, "python", "git")) {
  if (-not (Get-Command $tool -CommandType Application -ErrorAction SilentlyContinue)) {
    throw "$tool is required on PATH (Ninja may be supplied with -Ninja)"
  }
}
$cmakeVersion = [version]((& cmake --version | Select-Object -First 1) -replace "[^0-9.]", "")
if ($cmakeVersion -lt [version]"3.21") { throw "CMake 3.21 or newer is required" }
if (-not $CompilerBin) { $CompilerBin = "$Rocm/lib/llvm/bin" }
foreach ($file in @("$CompilerBin/clang.exe", "$CompilerBin/clang++.exe", "$CompilerBin/lld-link.exe", "$Vcpkg/vcpkg.exe")) {
  if (-not (Test-Path -LiteralPath $file)) { throw "Missing $file; see docs/WINDOWS.md" }
}
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$vs = if (Test-Path -LiteralPath $vswhere) {
  & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
}
if (-not $vs) { throw "Install Visual Studio Build Tools with Desktop development with C++" }
if ($Hip) {
  $rockVersionFile = Join-Path $Rocm ".info\version"
  if (-not (Test-Path -LiteralPath $rockVersionFile)) {
    throw "TheRock not found at $Rocm (required for HIP builds; see docs/WINDOWS.md)"
  }
  $rockVersion = (Get-Content -LiteralPath $rockVersionFile -TotalCount 1).Trim()
  if ($rockVersion -ne "10.0.0") {
    Write-Warning "TheRock $rockVersion at $Rocm; this port is validated on 10.0.0"
  }
  foreach ($file in @("$Rocm/lib/cmake/hip/hip-config.cmake", "$Rocm/bin/amdhip64_7.dll")) {
    if (-not (Test-Path -LiteralPath $file)) { throw "Missing $file; re-extract TheRock 10.0.0 to $Rocm" }
  }
  Write-Host "HIP prerequisites found: TheRock $rockVersion at $Rocm"
}
Write-Host "CPU prerequisites found: CMake $cmakeVersion, $CompilerBin, vcpkg, VS C++/SDK, Ninja, Python, Git"
