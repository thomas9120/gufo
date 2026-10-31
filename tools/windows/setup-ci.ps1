# Pinned CPU-only toolchain; no ROCm installation or administrator privileges.
$ErrorActionPreference = "Stop"
$root = (Resolve-Path "$PSScriptRoot\..\..").Path
$tools = Join-Path $root "build/windows-ci"
$version = "23.1.2"
$package = "clang+llvm-$version-x86_64-pc-windows-msvc"
$llvm = Join-Path $tools $package
$checksum = "8fb91cdc44fcbbdcf6b3ffd0a1f9859abd14a3c3aae4423c2b6d4a4f90bf0095"
New-Item -ItemType Directory -Force $tools | Out-Null
if (-not (Test-Path -LiteralPath "$llvm/.complete") -or
    (Get-Content -LiteralPath "$llvm/.complete" -Raw).Trim() -ne $checksum) {
  $archive = Join-Path $tools "llvm.tar.xz"
  Write-Host "Downloading LLVM $version"
  & curl.exe --silent --show-error -L --fail --retry 3 -o $archive "https://github.com/llvm/llvm-project/releases/download/llvmorg-$version/clang%2Bllvm-$version-x86_64-pc-windows-msvc.tar.xz"
  if ($LASTEXITCODE -ne 0) { throw "LLVM download failed" }
  if ((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash -ne $checksum) {
    throw "LLVM archive checksum mismatch"
  }
  # Retain the C/C++ drivers, linker/archive/resource tools, compiler resources,
  # and matching OpenMP pair. Unrelated LLVM tools consume several runner GB.
  $entries = @("$package/lib/clang", "$package/lib/libomp.lib", "$package/bin/libomp.dll")
  foreach ($exe in @("clang", "clang++", "clang-scan-deps", "lld-link", "llvm-ar", "llvm-lib", "llvm-ranlib", "llvm-rc", "llvm-mt")) {
    $entries += "$package/bin/$exe.exe"
  }
  & tar -xf $archive -C $tools @entries
  if ($LASTEXITCODE -ne 0) { throw "LLVM extraction failed" }
  Set-Content -LiteralPath "$llvm/.complete" -Value $checksum
  Remove-Item -LiteralPath $archive
}

# The manifest is the single source of the vcpkg revision. Do not use the
# runner image's rolling checkout or a developer's existing installation.
$baseline = (Get-Content "$root/vcpkg.json" -Raw | ConvertFrom-Json).'builtin-baseline'
if ($baseline -notmatch '^[0-9a-f]{40}$') { throw "Invalid vcpkg baseline" }
$vcpkg = Join-Path $tools "vcpkg"
if (-not (Test-Path -LiteralPath "$vcpkg/.git")) {
  & git init $vcpkg | Out-Host
  if ($LASTEXITCODE -ne 0) { throw "vcpkg initialization failed" }
  & git -C $vcpkg remote add origin https://github.com/microsoft/vcpkg.git
  if ($LASTEXITCODE -ne 0) { throw "vcpkg remote setup failed" }
}
$current = & git -C $vcpkg rev-parse --verify --quiet HEAD
if ($current -ne $baseline) {
  & git -C $vcpkg fetch --depth 1 origin $baseline | Out-Host
  if ($LASTEXITCODE -ne 0) { throw "vcpkg fetch failed" }
  & git -C $vcpkg checkout --detach $baseline | Out-Host
  if ($LASTEXITCODE -ne 0) { throw "vcpkg checkout failed" }
}
& "$vcpkg/bootstrap-vcpkg.bat" -disableMetrics | Out-Host
if ($LASTEXITCODE -ne 0) { throw "vcpkg bootstrap failed" }
[pscustomobject]@{ CompilerBin = "$llvm/bin"; Vcpkg = $vcpkg }
