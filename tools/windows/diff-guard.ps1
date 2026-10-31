# Enforce the small maintained difference from official Gufo.
#
# Compares HEAD with its merge base on official/main (the last imported
# official commit). Files this fork added are Windows-owned. Every changed or
# deleted upstream file must be listed in shared-edits.json or belong to a
# reverted known regression; listed files with "markers": true must carry a
# WINDOWS: marker in each changed hunk. Exit code 1 reports violations.
param(
  [string]$Official = "official/main",
  [string]$Head = "HEAD",
  [string]$Allowlist = "",
  [string]$Regressions = ""
)
$ErrorActionPreference = "Stop"
. "$PSScriptRoot/sync-common.ps1"
if (-not $Allowlist) { $Allowlist = Join-Path $PSScriptRoot "shared-edits.json" }
if (-not $Regressions) { $Regressions = Join-Path $PSScriptRoot "known-regressions.json" }

$headSha = Resolve-Commit $Head
$officialSha = Resolve-Commit $Official
$base = @(Invoke-Git merge-base $officialSha $headSha)[0]
$listed = @{}
foreach ($entry in (Read-JsonFile $Allowlist).files.PSObject.Properties) { $listed[$entry.Name] = $entry.Value }

# Upstream files changed by a revert of a known regression stay allowed while
# that revert is part of HEAD.
$reverted = @{}
foreach ($regression in @((Read-JsonFile $Regressions).regressions)) {
  if ($regression.status -ne "reverted" -or -not $regression.revertSha) { continue }
  if (-not (Test-CommitExists $regression.revertSha)) { continue }
  if (-not (Test-Ancestor $regression.revertSha $headSha)) { continue }
  foreach ($path in Get-CommitPaths $regression.revertSha) { $reverted[$path] = "#$($regression.pr)" }
}

$violations = @()
$warnings = @()
$shared = @{}
$added = 0
foreach ($line in Invoke-Git diff --name-status --no-renames $base $headSha) {
  $status, $path = $line -split "`t", 2
  if ($status -eq "A") { $added++; continue }
  $shared[$path] = $status
  if ($listed.ContainsKey($path)) {
    if ($listed[$path].markers -and $status -ne "D") {
      $hunk = $null
      $marked = $false
      foreach ($diffLine in @(Invoke-Git diff -U0 --no-color $base $headSha '--' $path) + "@@ end") {
        if ($diffLine.StartsWith("@@")) {
          if ($hunk -and -not $marked) { $violations += "${path}: hunk $hunk has no WINDOWS: marker" }
          $hunk = ($diffLine -split " ")[2]
          $marked = $false
        } elseif ($hunk -and $diffLine.StartsWith("+") -and $diffLine.Contains("WINDOWS:")) {
          $marked = $true
        }
      }
    }
  } elseif ($reverted.ContainsKey($path)) {
    continue
  } else {
    $violations += "${path}: upstream file changed ($status) but not listed in $(Split-Path -Leaf $Allowlist)"
  }
}
foreach ($path in $listed.Keys) {
  if (-not $shared.ContainsKey($path)) {
    $warnings += "${path}: listed but matches upstream (or is fork-owned); remove the entry"
  }
}

Write-Host "Official base $base; HEAD $headSha"
Write-Host "$added fork-owned files, $($shared.Count) changed upstream files ($($listed.Count) listed, $(@($shared.Keys | Where-Object { $reverted.ContainsKey($_) -and -not $listed.ContainsKey($_) }).Count) via reverted regressions)"
foreach ($warning in $warnings | Sort-Object) { Write-Warning $warning }
if ($violations) {
  foreach ($violation in $violations | Sort-Object) { Write-Host "FAIL $violation" }
  exit 1
}
Write-Host "Maintained difference is within the allowlist."
