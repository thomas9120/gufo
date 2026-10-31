# Shared helpers for the upstream sync tools; dot-source, do not run directly.
# Works in Windows PowerShell 5.1 and PowerShell 7 on any OS.

function Invoke-Git {
  $output = & git @args
  if ($LASTEXITCODE -ne 0) { throw "git $($args -join ' ') failed with exit code $LASTEXITCODE" }
  return @($output | Where-Object { $_ -ne $null -and $_ -ne "" })
}

function Resolve-Commit([string]$Ref) {
  $sha = & git rev-parse --verify --quiet "$Ref^{commit}"
  if ($LASTEXITCODE -ne 0 -or -not $sha) { throw "Unknown revision '$Ref'; fetch it first (e.g. git fetch official)" }
  return "$sha".Trim()
}

function Test-Ancestor([string]$Ancestor, [string]$Descendant) {
  & git merge-base --is-ancestor $Ancestor $Descendant
  if ($LASTEXITCODE -eq 0) { return $true }
  if ($LASTEXITCODE -eq 1) { return $false }
  throw "git merge-base --is-ancestor $Ancestor $Descendant failed with exit code $LASTEXITCODE"
}

function Test-CommitExists([string]$Sha) {
  # rev-parse --quiet reports a missing object only through its exit code;
  # redirecting native stderr would raise an error in Windows PowerShell.
  $null = & git rev-parse --verify --quiet "$Sha^{commit}"
  return $LASTEXITCODE -eq 0
}

function Read-JsonFile([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path)) { throw "Missing $Path" }
  return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
}

# Paths changed by a commit against its first parent.
function Get-CommitPaths([string]$Sha) {
  return Invoke-Git diff-tree --no-commit-id --name-only -r --no-renames "$Sha^" $Sha
}

# Occurrences of whole-word identifiers in src/ and tests/ at a revision,
# as "identifier: path" strings.
function Find-Identifiers([string]$Rev, [string[]]$Identifiers) {
  $found = @()
  foreach ($identifier in $Identifiers) {
    $hits = & git grep -l -w -F -e $identifier $Rev '--' src tests
    if ($LASTEXITCODE -gt 1) { throw "git grep failed with exit code $LASTEXITCODE" }
    foreach ($hit in @($hits)) {
      if ($hit) { $found += "${identifier}: $($hit.Substring($Rev.Length + 1))" }
    }
  }
  return $found
}
