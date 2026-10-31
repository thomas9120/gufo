# Native CPU build. CMake owns targets and compiler flags.
param(
  [string]$Preset = "windows-cpu",
  [string]$Target = "",
  [string]$Rocm = "C:\TheRock\build",
  [string]$CompilerBin = "",
  [string]$Vcpkg = "C:\vcpkg",
  [string]$Ninja = "ninja",
  [int]$Jobs = 4,
  [string[]]$CMakeArgs = @()
)
$ErrorActionPreference = "Stop"
$root = (Resolve-Path "$PSScriptRoot\..\..").Path
# Host-specific defaults live in ignored tools/windows/local.json (see
# local.example.json). Explicit arguments always win; only defaults are
# replaced so a shared checkout never bakes in one machine's paths.
$localFile = Join-Path $PSScriptRoot "local.json"
if (Test-Path -LiteralPath $localFile) {
  try {
    $local = Get-Content -LiteralPath $localFile -Raw | ConvertFrom-Json
    if ($Rocm -eq "C:\TheRock\build" -and $local.Rocm) { $Rocm = $local.Rocm }
    if ($Vcpkg -eq "C:\vcpkg" -and $local.Vcpkg) { $Vcpkg = $local.Vcpkg }
    if ($Ninja -eq "ninja" -and $local.Ninja) { $Ninja = $local.Ninja }
  } catch { Write-Warning "Ignoring ${localFile}: $($_.Exception.Message)" }
}
if (-not $CompilerBin) { $CompilerBin = "$Rocm/lib/llvm/bin" }
# HIP presets build the gfx1151 backend against TheRock; the rest are CPU-only.
$hip = $Preset -notin @("windows-cpu", "cpu-test", "cpu-sanitizer")
if ($hip) {
  & "$PSScriptRoot\check.ps1" -CompilerBin $CompilerBin -Vcpkg $Vcpkg -Ninja $Ninja -Hip -Rocm $Rocm
} else {
  & "$PSScriptRoot\check.ps1" -CompilerBin $CompilerBin -Vcpkg $Vcpkg -Ninja $Ninja
}

$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$vs = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
$vcvars = Join-Path $vs "VC\Auxiliary\Build\vcvars64.bat"
$env:PATH = "$(Split-Path $vswhere);$env:PATH"
$environment = & cmd /c "`"$vcvars`" >nul && set"
if ($LASTEXITCODE -ne 0) { throw "MSVC environment setup failed" }
$environment | ForEach-Object {
  if ($_ -match "^([^=]+)=(.*)$") { Set-Item -Path "env:$($matches[1])" -Value $matches[2] }
}
Write-Host "MSVC $env:VCToolsVersion, Windows SDK $env:WindowsSDKVersion"
$ninjaPath = (Get-Command $Ninja -CommandType Application | Select-Object -First 1).Source.Replace('\', '/')
$compilerDir = (Resolve-Path -LiteralPath $CompilerBin).Path.Replace('\', '/')
# Standalone LLVM ships its own OpenMP import library/runtime. Keep that pair
# together; TheRock builds can still use the matching VS developer runtime.
$llvmOpenmp = [IO.Path]::GetFullPath("$compilerDir/../lib/libomp.lib").Replace('\', '/')
$openmpArgs = @()
if ((Test-Path -LiteralPath $llvmOpenmp) -and (Test-Path -LiteralPath "$compilerDir/libomp.dll")) {
  $openmpArgs = @("-DOpenMP_libomp_LIBRARY:FILEPATH=$llvmOpenmp")
}
$hipArgs = @()
if ($hip) {
  $env:HIP_PATH = $Rocm.Replace('\', '/')
  $env:HIP_DEVICE_LIB_PATH = "$Rocm/lib/llvm/amdgcn/bitcode".Replace('\', '/')
  $env:PATH = "$Rocm\bin;$CompilerBin;$env:PATH"
  $hipArgs = @("-DCMAKE_HIP_COMPILER=$($CompilerBin.Replace('\', '/'))/clang++.exe",
               "-DCMAKE_PREFIX_PATH=$($Rocm.Replace('\', '/'))")
}
$revision = & git -C $root rev-parse --short=12 HEAD
if ($LASTEXITCODE -ne 0) { throw "cannot identify the source revision" }
$dirty = & git -C $root status --porcelain
if ($LASTEXITCODE -ne 0) { throw "cannot inspect the source revision" }
if ($dirty) { $revision += "-dirty" }
$release = (Get-Content "$root/version.txt" -Raw).Trim()
$dependencies = "$root/build/vcpkg_installed".Replace('\', '/')
& cmake -S $root --preset $Preset `
  "-DCMAKE_MAKE_PROGRAM=$ninjaPath" `
  "-DCMAKE_C_COMPILER=$compilerDir/clang.exe" `
  "-DCMAKE_CXX_COMPILER=$compilerDir/clang++.exe" `
  "-DCMAKE_TOOLCHAIN_FILE=$($Vcpkg.Replace('\', '/'))/scripts/buildsystems/vcpkg.cmake" `
  "-DVCPKG_TARGET_TRIPLET=x64-windows" `
  "-DVCPKG_MANIFEST_MODE=ON" `
  "-DVCPKG_MANIFEST_DIR=$($root.Replace('\', '/'))" `
  "-DVCPKG_INSTALLED_DIR=$dependencies" `
  "-DCMAKE_LINKER_TYPE=LLD" `
  "-DGUFO_RELEASE_VERSION=$release" "-DGUFO_REVISION=$revision" @openmpArgs @hipArgs @CMakeArgs
if ($LASTEXITCODE -ne 0) { throw "configure failed" }
$buildArgs = @("--build", "--preset", $Preset, "--parallel", $Jobs)
if ($Target) { $buildArgs += @("--target", $Target) }
Push-Location $root
try {
  & cmake @buildArgs
  if ($LASTEXITCODE -ne 0) { throw "build failed" }
} finally { Pop-Location }

$build = Join-Path $root "build/$Preset"
# Gufo executables are colocated; running needs no global PATH changes.
Get-ChildItem "$dependencies/x64-windows/bin/*.dll" | Copy-Item -Destination $build -Force
if ($hip) {
  # ROCm runtime and BLAS kernel libraries beside the executables; PATH alone
  # can select an incompatible HIP runtime from System32.
  $rocmDlls = @("amdhip64_7.dll", "amd_comgr*.dll", "hipblas.dll", "libhipblaslt.dll", "origami.dll", "rocblas.dll", "rocsolver.dll", "rocsparse.dll", "rocm_kpack.dll", "rocm-openblas*.dll", "hiprtc*.dll")
  foreach ($pattern in $rocmDlls) {
    Get-ChildItem "$Rocm\bin\$pattern" -ErrorAction SilentlyContinue | Copy-Item -Destination $build -Force
  }
  foreach ($dir in @("hipblaslt", "rocblas")) {
    $libraryDir = Join-Path "$Rocm\bin" $dir
    if (Test-Path -LiteralPath $libraryDir) {
      Copy-Item -LiteralPath $libraryDir -Destination $build -Recurse -Force
    }
  }
}
if ($env:VCToolsRedistDir) {
  Get-ChildItem "$env:VCToolsRedistDir/x64/Microsoft.VC*.CRT/*.dll" | Copy-Item -Destination $build -Force
}
# Developer use only: VS's LLVM OpenMP DLL is not a redistributable release.
$openmp = Select-String -LiteralPath "$build/CMakeCache.txt" -Pattern '^OpenMP_libomp_LIBRARY:FILEPATH=(.*)$'
if ($openmp -and $openmp.Matches[0].Groups[1].Value -match '^(.*)/VC/Tools/MSVC/([^/]+)/lib/x64/libomp\.lib$') {
  $redist = "$($Matches[1])/VC/Redist/MSVC/$($Matches[2])"
  # Toolset and redist patch versions can differ. Use vcvars' selected redist
  # only when it belongs to the installation that supplied the import library.
  if ($env:VCToolsRedistDir -and $env:VCToolsRedistDir.Replace('\', '/').StartsWith(
      "$($Matches[1])/VC/Redist/MSVC/", [StringComparison]::OrdinalIgnoreCase)) {
    $redist = $env:VCToolsRedistDir
  }
  $runtime = Get-ChildItem "$redist/debug_nonredist/x64/Microsoft.VC*.OpenMP.LLVM/libomp140.x86_64.dll" -ErrorAction SilentlyContinue
  if (-not $runtime) { throw "Cannot find this build's local OpenMP runtime" }
  $runtime | Copy-Item -Destination $build -Force
} elseif ($openmp -and $openmp.Matches[0].Groups[1].Value -eq $llvmOpenmp) {
  Copy-Item -LiteralPath "$compilerDir/libomp.dll" -Destination $build -Force
}
if ($hip) { Write-Host "Built $build (HIP gfx1151)" } else { Write-Host "Built $build (CPU only)" }
