# Gufo Windows installer: TUI bootstrap for the windows-main source build.
# Dot-source this file (as preview.ps1 does) to render screens without installing anything.
[CmdletBinding()]
param(
  [ValidateSet("", "install", "update", "repair", "uninstall")][string]$Action = "",
  [string]$InstallDir = "",
  [ValidateRange(0, 64)][int]$Jobs = 0,
  [string]$Rocm = "",
  [string]$Vcpkg = "",
  [switch]$Yes,
  [switch]$Plain,
  [ValidateSet("Auto", "TrueColor", "Ansi16", "None")][string]$ColorMode = "Auto",
  [switch]$AsciiGlyphs,
  [switch]$NoShortcut
)
$ErrorActionPreference = "Stop"

$script:GufoRepository = "https://github.com/thomas9120/gufo-windows.git"
$script:GufoBranch = "windows-main"
$script:GufoGitPackage = "Git.Git"
$script:GufoGitVersion = "2.55.0.3"
$script:GufoInstallerTag = "@TAG@"
$script:GufoMinWidth = 72
$script:GufoMinHeight = 20
$script:GufoMaxWidth = 120
$script:GufoInteractive = $false
$script:GufoVt = $false
$script:GufoConsole = @{ AltScreen = $false; CursorHidden = $false; CtrlC = $false }

# A screen's steps are the visible phases; keys map log markers onto them.
$script:GufoRuns = @{
  fetch = @{
    Steps = @("Locate Git for Windows", "Clone windows-main", "Check the checkout")
    Keys = @{ git = 0; clone = 1; check = 2 }
  }
  plan = @{
    Steps = @("Read the setup plan")
    Keys = @{ plan = 0 }
  }
  install = @{
    Steps = @("Prepare tools and GPU runtime", "Prepare dependency library", "Compile the engine", "Verify GPU startup", "Finish")
    Keys = @{ tools = 0; deps = 1; compile = 2; verify = 3; finish = 4 }
  }
  update = @{
    Steps = @("Pull windows-main", "Recompile the engine", "Verify the build")
    Keys = @{ pull = 0; compile = 1; verify = 2 }
  }
}

# ---------------------------------------------------------------- console ---

function Enable-GufoVirtualTerminal {
  try {
    if (-not ("GufoInstaller.NativeConsole" -as [type])) {
      Add-Type -Namespace GufoInstaller -Name NativeConsole -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError = true)]
public static extern System.IntPtr GetStdHandle(int handle);
[System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError = true)]
public static extern bool GetConsoleMode(System.IntPtr handle, out uint mode);
[System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError = true)]
public static extern bool SetConsoleMode(System.IntPtr handle, uint mode);
'@
    }
    $handle = [GufoInstaller.NativeConsole]::GetStdHandle(-11)
    [uint32]$mode = 0
    if ([GufoInstaller.NativeConsole]::GetConsoleMode($handle, [ref]$mode)) {
      if (($mode -band 0x4) -eq 0) {
        return [GufoInstaller.NativeConsole]::SetConsoleMode($handle, $mode -bor 0x4)
      }
      return $true
    }
  } catch {
  }
  return $false
}

function Resolve-GufoColorMode {
  param([string]$Requested, [bool]$Vt)
  if ($Requested -eq "None" -or $env:NO_COLOR) { return "None" }
  if ($Requested -ne "Auto") { return $Requested }
  if (-not $Vt) { return "None" }
  return "TrueColor"
}

function Initialize-GufoConsole {
  if ([Console]::IsOutputRedirected -or [Console]::IsInputRedirected) { return }
  try {
    [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
  } catch {
  }
  try {
    $current = & chcp.com 2>&1
    if ("$current" -match "(\d+)") {
      $script:GufoConsole.CodePage = [int]$Matches[1]
    }
    & chcp.com 65001 > $null 2>&1
  } catch {
  }
  try {
    [Console]::TreatControlCAsInput = $true
    $script:GufoConsole.CtrlC = $true
  } catch {
  }
}

function Enter-GufoFullScreen {
  $e = [string][char]27
  [Console]::Write("$($e)[?1049h$($e)[?25l")
  $script:GufoConsole.AltScreen = $true
  $script:GufoConsole.CursorHidden = $true
}

function Exit-GufoFullScreen {
  $e = [string][char]27
  try {
    [Console]::Write("$($e)[0m$($e)[?25h$($e)[?1049l")
  } catch {
  }
  if ($script:GufoConsole.CtrlC) {
    try { [Console]::TreatControlCAsInput = $false } catch {
    }
  }
  if ($script:GufoConsole.CodePage) {
    try { & chcp.com $script:GufoConsole.CodePage > $null 2>&1 } catch {
    }
  }
  $script:GufoConsole.AltScreen = $false
  $script:GufoConsole.CursorHidden = $false
}

function Get-GufoViewport {
  $width = 100
  $height = 32
  try {
    $width = [Console]::WindowWidth
    $height = [Console]::WindowHeight
  } catch {
  }
  if ($width -lt 40) { $width = 100 }
  if ($height -lt 10) { $height = 32 }
  return @{ Width = $width; Height = $height }
}

function Invoke-GufoDraw {
  param($State)
  $viewport = Get-GufoViewport
  $State.ViewWidth = $viewport.Width
  $State.ViewHeight = $viewport.Height
  if ($viewport.Width -lt $script:GufoMinWidth -or $viewport.Height -lt $script:GufoMinHeight) {
    $State.Small = $true
    $State.Width = $viewport.Width
    $State.Height = $viewport.Height
    $lines = Resize-GufoFrame (Get-GufoSmallScreen $viewport.Width $viewport.Height) $viewport.Height
  } else {
    $State.Small = $false
    $State.Width = [Math]::Min($script:GufoMaxWidth, $viewport.Width)
    $State.Height = $viewport.Height
    $lines = Get-GufoScreen $State
    $lines = Resize-GufoFrame $lines $State.Height
  }
  $e = [string][char]27
  $buffer = New-Object System.Text.StringBuilder
  [void]$buffer.Append("$($e)[H")
  for ($index = 0; $index -lt $lines.Count; $index++) {
    [void]$buffer.Append([string]$lines[$index])
    [void]$buffer.Append("$($e)[K")
    # A newline on the bottom row would scroll the whole frame up by one line.
    if ($index -lt $lines.Count - 1) { [void]$buffer.Append("`n") }
  }
  [void]$buffer.Append("$($e)[J")
  [Console]::Write($buffer.ToString())
}

function Read-GufoKey {
  param([int]$TimeoutMs = 0)
  $deadline = [DateTime]::UtcNow.AddMilliseconds([Math]::Max(0, $TimeoutMs))
  while ($true) {
    try {
      if ([Console]::KeyAvailable) { break }
    } catch {
      Start-Sleep -Milliseconds 100
      return $null
    }
    if ($TimeoutMs -gt 0 -and [DateTime]::UtcNow -ge $deadline) { return $null }
    Start-Sleep -Milliseconds 20
  }
  $key = [Console]::ReadKey($true)
  switch ($key.Key) {
    "UpArrow" { return "Up" }
    "DownArrow" { return "Down" }
    "LeftArrow" { return "Left" }
    "RightArrow" { return "Right" }
    "PageUp" { return "PgUp" }
    "PageDown" { return "PgDn" }
    "Home" { return "Home" }
    "End" { return "End" }
    "Enter" { return "Enter" }
    "Escape" { return "Esc" }
    "Tab" { return "Tab" }
    "Backspace" { return "Backspace" }
    "Spacebar" { return "Space" }
  }
  if ([char]::IsControl($key.KeyChar)) {
    if ($key.KeyChar -eq [char]3) { return "CtrlC" }
    return ""
  }
  return "Char:$($key.KeyChar)"
}

# ------------------------------------------------------------------ theme ---

function Get-GufoGlyphs {
  param([switch]$Ascii)
  if ($Ascii) {
    return @{
      TL = "+"; TR = "+"; BL = "+"; BR = "+"; H = "-"; V = "|"; LT = "+"; RT = "+"
      Bullet = "*"; Check = "+"; Cross = "x"; Dot = "."; Arrow = ">"
      BarOn = "#"; BarOff = "-"; UpDown = "^v"
      Logo = @(
        "      .######.",
        "     ###'  '''",
        "     ###  #####",
        "     ###.  ####",
        "      '######'"
      )
    }
  }
  return @{
    TL = "╭"; TR = "╮"; BL = "╰"; BR = "╯"; H = "─"; V = "│"; LT = "├"; RT = "┤"
    Bullet = "●"; Check = "✓"; Cross = "✗"; Dot = "·"; Arrow = "›"
    BarOn = "▓"; BarOff = "░"; UpDown = "↑↓"
    Logo = @(
      "      ▄▄████████▄▄",
      "     ███▀      ▀▀▀▀",
      "     ███    ███████",
      "     ███▄      ████",
      "      ▀▀████████▀▀"
    )
  }
}

function New-GufoScheme {
  param([string]$Mode = "TrueColor", [switch]$Ascii)
  $e = [string][char]27
  $scheme = @{ Mode = $Mode; Glyphs = (Get-GufoGlyphs -Ascii:$Ascii) }
  $roles = @("frame", "accent", "accent2", "text", "muted", "ok", "warn", "error", "sel", "barOff", "bold", "reset")
  if ($Mode -eq "None") {
    foreach ($role in $roles) { $scheme[$role] = "" }
    return $scheme
  }
  if ($Mode -eq "Ansi16") {
    $scheme.frame = "$($e)[90m"
    $scheme.accent = "$($e)[33m"
    $scheme.accent2 = "$($e)[93m"
    $scheme.text = "$($e)[97m"
    $scheme.muted = "$($e)[90m"
    $scheme.ok = "$($e)[92m"
    $scheme.warn = "$($e)[93m"
    $scheme.error = "$($e)[91m"
    $scheme.sel = "$($e)[7m"
    $scheme.barOff = "$($e)[90m"
    $scheme.bold = "$($e)[1m"
    $scheme.reset = "$($e)[0m"
    return $scheme
  }
  $scheme.frame = "$($e)[38;2;94;122;94m"
  $scheme.accent = "$($e)[38;2;217;160;91m"
  $scheme.accent2 = "$($e)[38;2;240;124;27m"
  $scheme.text = "$($e)[38;2;237;224;200m"
  $scheme.muted = "$($e)[38;2;138;154;132m"
  $scheme.ok = "$($e)[38;2;143;191;111m"
  $scheme.warn = "$($e)[38;2;240;179;60m"
  $scheme.error = "$($e)[38;2;224;113;90m"
  $scheme.sel = "$($e)[48;2;46;74;52m$($e)[38;2;242;231;210m"
  $scheme.barOff = "$($e)[38;2;58;74;58m"
  $scheme.bold = "$($e)[1m"
  $scheme.reset = "$($e)[0m"
  return $scheme
}

function Get-GufoRuns {
  param($Line)
  if ($null -eq $Line) { return @() }
  if ($Line -is [string]) { return @(@{ t = $Line; c = "text" }) }
  if ($Line -is [System.Collections.IDictionary]) {
    $role = "text"
    if ($Line.c) { $role = [string]$Line.c }
    return @(@{ t = [string]$Line.t; c = $role })
  }
  $runs = New-Object System.Collections.Generic.List[object]
  foreach ($item in @($Line)) {
    if ($null -eq $item) { continue }
    if ($item -is [string]) {
      $runs.Add(@{ t = $item; c = "text" })
      continue
    }
    if ($item -is [System.Collections.IDictionary]) {
      $role = "text"
      if ($item.c) { $role = [string]$item.c }
      $runs.Add(@{ t = [string]$item.t; c = $role })
    }
  }
  return $runs.ToArray()
}

function Format-GufoRaw {
  param($Runs, $Scheme)
  $buffer = New-Object System.Text.StringBuilder
  foreach ($run in (Get-GufoRuns $Runs)) {
    [void]$buffer.Append($Scheme[$run.c])
    [void]$buffer.Append($run.t)
    [void]$buffer.Append($Scheme.reset)
  }
  return $buffer.ToString()
}

function Format-GufoText {
  param($Runs, [int]$Width, $Scheme, [string]$PadRole = "none")
  if ($Width -lt 1) { return "" }
  $list = @(Get-GufoRuns $Runs)
  $plainLength = 0
  foreach ($run in $list) { $plainLength += $run.t.Length }
  $limit = $Width
  $ellipsis = $false
  if ($plainLength -gt $Width) {
    if ($Width -ge 3) {
      $limit = $Width - 3
      $ellipsis = $true
    } else {
      $limit = $Width
    }
  }
  $buffer = New-Object System.Text.StringBuilder
  $used = 0
  foreach ($run in $list) {
    if ($used -ge $limit) { break }
    $take = [Math]::Min($run.t.Length, $limit - $used)
    if ($take -le 0) { continue }
    [void]$buffer.Append($Scheme[$run.c])
    [void]$buffer.Append($run.t.Substring(0, $take))
    [void]$buffer.Append($Scheme.reset)
    $used += $take
  }
  if ($ellipsis) {
    [void]$buffer.Append($Scheme.muted)
    [void]$buffer.Append("...")
    [void]$buffer.Append($Scheme.reset)
    $used += 3
  }
  if ($used -lt $Width) {
    if ($PadRole -ne "none") { [void]$buffer.Append($Scheme[$PadRole]) }
    [void]$buffer.Append(" " * ($Width - $used))
    if ($PadRole -ne "none") { [void]$buffer.Append($Scheme.reset) }
  }
  return $buffer.ToString()
}

function Get-GufoBanner {
  param($Scheme, [int]$Width)
  $glyphs = $Scheme.Glyphs
  $logo = @($glyphs.Logo)
  $logoWidth = 0
  foreach ($line in $logo) { if ($line.Length -gt $logoWidth) { $logoWidth = $line.Length } }
  $words = @(
    @(@{ t = "G U F O"; c = "accent2" }, @{ t = "   ·   Windows setup"; c = "muted" }),
    @(@{ t = "local inference for AMD Strix Halo"; c = "muted" }),
    @(@{ t = "gfx1151 · Windows 11 x64"; c = "muted" })
  )
  $rows = New-Object System.Collections.Generic.List[object]
  for ($index = 0; $index -lt $logo.Count; $index++) {
    $runs = @(@{ t = $logo[$index].PadRight($logoWidth + 6); c = "accent" })
    if ($index -lt $words.Count -and $Width -gt ($logoWidth + 20)) { $runs += $words[$index] }
    $rows.Add($runs)
  }
  return $rows.ToArray()
}

function Format-GufoBox {
  param($Scheme, [int]$Width, [string]$Title = "", [string]$Right = "", $Rows = @(), [string]$Footer = "")
  $glyphs = $Scheme.Glyphs
  $inner = $Width - 4
  $lines = New-Object System.Collections.Generic.List[string]
  $left = ""
  if ($Title) { $left = " $Title " }
  $right = ""
  if ($Right) { $right = " $Right " }
  $fill = $Width - 4 - $left.Length - $right.Length
  if ($fill -lt 1) {
    $right = ""
    $fill = $Width - 4 - $left.Length
  }
  if ($fill -lt 1) {
    $left = ""
    $fill = $Width - 4
  }
  $top = @(
    @{ t = ($glyphs.TL + $glyphs.H); c = "frame" },
    @{ t = $left; c = "accent" },
    @{ t = ($glyphs.H * $fill); c = "frame" }
  )
  if ($right) { $top += @{ t = $right; c = "muted" } }
  $top += @{ t = ($glyphs.H + $glyphs.TR); c = "frame" }
  $lines.Add((Format-GufoRaw $top $Scheme))
  foreach ($row in $Rows) {
    if ($row -is [System.Collections.IDictionary] -and $row.hr) {
      $lines.Add($Scheme.frame + $glyphs.LT + ($glyphs.H * ($Width - 2)) + $glyphs.RT + $Scheme.reset)
      continue
    }
    $lines.Add($Scheme.frame + $glyphs.V + $Scheme.reset + " " + (Format-GufoText $row $inner $Scheme) + " " + $Scheme.frame + $glyphs.V + $Scheme.reset)
  }
  if ($Footer) {
    $lines.Add($Scheme.frame + $glyphs.LT + ($glyphs.H * ($Width - 2)) + $glyphs.RT + $Scheme.reset)
    $lines.Add($Scheme.frame + $glyphs.V + $Scheme.reset + " " + (Format-GufoText $Footer $inner $Scheme) + " " + $Scheme.frame + $glyphs.V + $Scheme.reset)
  }
  $lines.Add($Scheme.frame + $glyphs.BL + ($glyphs.H * ($Width - 2)) + $glyphs.BR + $Scheme.reset)
  return $lines.ToArray()
}

function Get-GufoBar {
  param([double]$Fraction, [int]$Width, $Scheme, [switch]$Indeterminate, [double]$Phase = 0)
  $width = [Math]::Max(8, $Width)
  $glyphs = $Scheme.Glyphs
  if ($Indeterminate) {
    $segment = [Math]::Max(3, [int]($width / 5))
    $travel = $width + $segment
    $start = [int](($Phase % 1) * $travel) - $segment
    $before = [int][Math]::Min($width, [Math]::Max(0, $start))
    $middle = [int][Math]::Min($width, [Math]::Max(0, $start + $segment)) - $before
    $after = $width - $before - $middle
    $runs = @()
    if ($before -gt 0) { $runs += @{ t = ($glyphs.BarOff * $before); c = "barOff" } }
    if ($middle -gt 0) { $runs += @{ t = ($glyphs.BarOn * $middle); c = "accent" } }
    if ($after -gt 0) { $runs += @{ t = ($glyphs.BarOff * $after); c = "barOff" } }
    return $runs
  }
  $filled = [int][Math]::Round([Math]::Min(1.0, [Math]::Max(0.0, $Fraction)) * $width)
  $runs = @()
  if ($filled -gt 0) { $runs += @{ t = ($glyphs.BarOn * $filled); c = "accent" } }
  if ($width - $filled -gt 0) { $runs += @{ t = ($glyphs.BarOff * ($width - $filled)); c = "barOff" } }
  return $runs
}

function Get-GufoWrap {
  param([string]$Text, [int]$Width)
  if (-not $Text -or $Width -lt 1) { return @() }
  $lines = New-Object System.Collections.Generic.List[string]
  $current = ""
  foreach ($word in ($Text -split "\s+")) {
    if (-not $word) { continue }
    if (-not $current) {
      $current = $word
    } elseif (($current.Length + 1 + $word.Length) -le $Width) {
      $current += " " + $word
    } else {
      $lines.Add($current)
      $current = $word
    }
  }
  if ($current) { $lines.Add($current) }
  return $lines.ToArray()
}

function Resize-GufoFrame {
  param($Lines, [int]$Height)
  $list = New-Object System.Collections.Generic.List[string]
  foreach ($line in @($Lines)) {
    if ($list.Count -ge $Height) { break }
    $list.Add([string]$line)
  }
  while ($list.Count -lt $Height) { $list.Add("") }
  return $list.ToArray()
}

function Format-GufoElapsed {
  param($Span)
  if ($Span.TotalHours -ge 1) {
    return ("{0}:{1:00}:{2:00}" -f [int]$Span.TotalHours, $Span.Minutes, $Span.Seconds)
  }
  return ("{0:00}:{1:00}" -f [int]$Span.TotalMinutes, $Span.Seconds)
}

function Format-GufoAge {
  param($Time)
  if (-not $Time) { return "" }
  $span = (Get-Date) - $Time
  if ($span.TotalMinutes -lt 1) { return "just now" }
  if ($span.TotalMinutes -lt 60) { return "$([int]$span.TotalMinutes) min ago" }
  if ($span.TotalHours -lt 24) { return "$([int]$span.TotalHours) h ago" }
  return "$([int]$span.TotalDays) d ago"
}

function Get-GufoFactRow {
  param([string]$Label, [string]$Value, $Scheme, [string]$Role = "text")
  return @(
    @{ t = ("  " + $Label.PadRight(13)); c = "muted" },
    @{ t = $Value; c = $Role }
  )
}

function Get-GufoSpreadRow {
  param([string]$Left, [string]$Right, [int]$Width, $Scheme, [string]$LeftRole = "text", [string]$RightRole = "muted")
  $indent = "  "
  $room = $Width - $indent.Length - $Right.Length - 2
  $text = $Left
  if ($text.Length -gt $room) { $text = $text.Substring(0, [Math]::Max(0, $room)) }
  $gap = $Width - $indent.Length - $text.Length - $Right.Length
  if ($gap -lt 1) { $gap = 1 }
  return @(
    @{ t = $indent; c = "muted" },
    @{ t = $text; c = $LeftRole },
    @{ t = (" " * $gap); c = "text" },
    @{ t = $Right; c = $RightRole }
  )
}

function Get-GufoMenuRow {
  param($Item, [bool]$Selected, [int]$Width, $Scheme)
  $glyphs = $Scheme.Glyphs
  $labelWidth = [Math]::Min(22, [Math]::Max(10, $Width - 44))
  if ($Selected) {
    $text = "  $($glyphs.Arrow) "
  } else {
    $text = "    "
  }
  $text += $Item.Label.PadRight($labelWidth)
  if ($Item.Hint) { $text += $Item.Hint }
  if ($text.Length -gt $Width) {
    $text = $text.Substring(0, [Math]::Max(0, $Width - 3)) + "..."
  }
  $text = $text.PadRight($Width)
  $role = "text"
  if ($Selected) { $role = "sel" } elseif ($Item.Disabled) { $role = "muted" }
  return @{ t = $text; c = $role }
}

# ------------------------------------------------------------------ state ---

function Get-GufoInstallerTag {
  if (-not $script:GufoInstallerTag -or $script:GufoInstallerTag -match "^@") { return "dev" }
  return ($script:GufoInstallerTag -replace "^Windows-Gufo-", "")
}

function Test-GufoDevBuild {
  return (-not $script:GufoInstallerTag -or $script:GufoInstallerTag -match "^@")
}

function Get-GufoDefaultInstallDir {
  return (Join-Path $env:USERPROFILE "Gufo")
}

function Get-GufoRunningCheckout {
  # The checkout this installer runs from (tools\installer inside it), if any.
  if (-not $PSScriptRoot) { return "" }
  $candidate = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\.."))
  if (Test-GufoSourceFolder $candidate) { return $candidate }
  return ""
}

function Test-GufoSamePath {
  param([string]$Left, [string]$Right)
  if (-not $Left -or -not $Right) { return $false }
  try {
    return ([IO.Path]::GetFullPath($Left).TrimEnd([char]92) -eq [IO.Path]::GetFullPath($Right).TrimEnd([char]92))
  } catch {
    return $false
  }
}

function Get-GufoInstallSourceText {
  param([string]$Source)
  switch ($Source) {
    "argument" { return "set by -InstallDir" }
    "checkout" { return "the checkout running this installer; not saved" }
    "saved" { return "saved from a previous run" }
    "chosen" { return "chosen in Advanced" }
  }
  return "default folder"
}

function Get-GufoDefaultJobs {
  $jobs = [int][Math]::Floor([Environment]::ProcessorCount / 2)
  if ($jobs -lt 4) { $jobs = 4 }
  if ($jobs -gt 8) { $jobs = 8 }
  return $jobs
}

function Get-GufoShortcutPath {
  $desktop = [Environment]::GetFolderPath("Desktop")
  if (-not $desktop) { return "" }
  return (Join-Path $desktop "Gufo.lnk")
}

function Get-GufoSetupDir {
  param($State)
  return (Join-Path $State.SettingsDir "installer")
}

function Test-GufoRunningFromSetupDir {
  param($State)
  return ([IO.Path]::GetFullPath($PSScriptRoot) -eq [IO.Path]::GetFullPath((Get-GufoSetupDir $State)))
}

function Get-GufoStartMenuShortcutPath {
  $programs = [Environment]::GetFolderPath("Programs")
  if (-not $programs) { return "" }
  return (Join-Path $programs "Gufo Setup.lnk")
}

function Get-GufoCheckoutState {
  param([string]$Dir)
  $state = @{
    Dir = $Dir
    Exists = $false
    Valid = $false
    Branch = ""
    Head = ""
    Engine = ""
    EngineExists = $false
    Built = $null
    Remote = ""
  }
  if (-not $Dir) { return $state }
  if (-not (Test-Path -LiteralPath $Dir -PathType Container)) { return $state }
  $state.Exists = $true
  $state.Valid = (Test-Path -LiteralPath (Join-Path $Dir "vcpkg.json")) -and
    (Test-Path -LiteralPath (Join-Path $Dir "setup-windows.bat")) -and
    (Test-Path -LiteralPath (Join-Path $Dir "tools\windows\setup.ps1"))
  $engine = Join-Path $Dir "build\windows-gpu\gufo.exe"
  if (Test-Path -LiteralPath $engine) {
    $state.Engine = $engine
    $state.EngineExists = $true
    $state.Built = (Get-Item -LiteralPath $engine).LastWriteTime
  }
  if ($state.Valid -and (Get-Command git.exe -CommandType Application -ErrorAction SilentlyContinue)) {
    try {
      $branch = & git.exe -C $Dir rev-parse --abbrev-ref HEAD 2>$null
      if ($branch) { $state.Branch = ([string]($branch | Select-Object -First 1)).Trim() }
      $head = & git.exe -C $Dir rev-parse --short HEAD 2>$null
      if ($head) { $state.Head = ([string]($head | Select-Object -First 1)).Trim() }
      $remote = & git.exe -C $Dir remote get-url origin 2>$null
      if ($remote) { $state.Remote = ([string]($remote | Select-Object -First 1)).Trim() }
    } catch {
    }
  }
  return $state
}

function Get-GufoMachine {
  $machine = @{ Cpu = "unknown CPU"; Os = "Windows"; Build = 0; RamGiB = 0; Problem = $null }
  try {
    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
    $machine.Os = [string]$os.Caption
    $machine.Build = [int]$os.BuildNumber
    $machine.RamGiB = [int][Math]::Round($os.TotalVisibleMemorySize / 1MB, 0)
  } catch {
  }
  try {
    $cpu = Get-CimInstance Win32_Processor -ErrorAction Stop | Select-Object -First 1
    if ($cpu -and $cpu.Name) { $machine.Cpu = ([string]$cpu.Name).Trim() }
  } catch {
  }
  $machine.Os = ($machine.Os -replace "^Microsoft ", "")
  if (-not [Environment]::Is64BitProcess) {
    $machine.Problem = "64-bit Windows is required."
  } elseif ($machine.Build -and $machine.Build -lt 22000) {
    $machine.Problem = "Windows 11 (build 22000 or newer) is required."
  } elseif ($env:PROCESSOR_ARCHITECTURE -ne "AMD64") {
    $machine.Problem = "Windows 11 on AMD64 is required."
  } elseif ($machine.Cpu -notmatch "Ryzen\s+AI\s+MAX") {
    $machine.Problem = "This build targets AMD Ryzen AI Max (Strix Halo, gfx1151). Detected: $($machine.Cpu)."
  }
  return $machine
}

function Get-GufoLogDir {
  $dir = Join-Path (Join-Path $env:LOCALAPPDATA "Gufo") "logs"
  if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
  return $dir
}

function Get-GufoLogPath {
  param([string]$Kind)
  return (Join-Path (Get-GufoLogDir) ("{0}-{1}.log" -f $Kind, (Get-Date -Format "yyyyMMdd-HHmmss")))
}

function New-GufoState {
  param($Scheme, [string]$InstallDir = "", [int]$Jobs = 0, [string]$Rocm = "", [string]$Vcpkg = "", [bool]$Shortcut = $true, [bool]$Interactive = $true)
  $settingsDir = Join-Path $env:LOCALAPPDATA "Gufo"
  $state = @{
    Screen = "splash"
    Width = 100
    Height = 32
    Small = $false
    Scheme = $Scheme
    Tag = Get-GufoInstallerTag
    Interactive = $Interactive
    Machine = $null
    Checkout = $null
    InstallDir = Get-GufoDefaultInstallDir
    InstallSource = "default"
    InstallNote = ""
    SavedInstallDir = ""
    LauncherDir = ""
    DepsDir = Join-Path $settingsDir "dependencies"
    SettingsDir = $settingsDir
    Jobs = Get-GufoDefaultJobs
    Rocm = ""
    Vcpkg = ""
    Shortcut = $Shortcut
    MenuIndex = 0
    MenuItems = @()
    AdvancedIndex = 0
    Edit = $null
    Plan = $null
    Run = $null
    Done = $null
    Uninstall = $null
    LogView = @{ Path = ""; Lines = @(); Offset = 0 }
    Notice = ""
    NoticeAt = [DateTime]::MinValue
    Quit = $false
    AutoConfirm = $false
    ViewWidth = 0
    ViewHeight = 0
    AdvancedReturn = "menu"
    PlanKey = ""
    FetchedDir = ""
  }
  Load-GufoOptions $state
  Resolve-GufoInstallDir $state $InstallDir
  if ($Jobs -gt 0) { $state.Jobs = $Jobs }
  if ($Rocm) { $state.Rocm = $Rocm }
  if ($Vcpkg) { $state.Vcpkg = $Vcpkg }
  if ($PSBoundParameters.ContainsKey("Shortcut")) { $state.Shortcut = $Shortcut }
  $state.Checkout = Get-GufoCheckoutState $state.InstallDir
  $state.LauncherDir = Get-GufoLauncherCheckout $state
  return $state
}

function Resolve-GufoInstallDir {
  # -InstallDir wins, then the checkout running this installer, then the saved folder.
  param($State, [string]$Requested = "")
  $State.InstallNote = ""
  $saved = $State.SavedInstallDir
  $running = Get-GufoRunningCheckout
  if ($Requested) {
    $State.InstallDir = $Requested
    $State.InstallSource = "argument"
  } elseif ($running) {
    $State.InstallDir = $running
    $State.InstallSource = "checkout"
  } elseif ($saved -and (Test-GufoSourceFolder $saved)) {
    $State.InstallDir = $saved
    $State.InstallSource = "saved"
  } else {
    $State.InstallDir = Get-GufoDefaultInstallDir
    $State.InstallSource = "default"
    if ($saved -and -not (Test-GufoSamePath $saved $State.InstallDir)) {
      $State.InstallNote = "The saved folder $saved has no Gufo checkout, so the default folder is used."
    }
  }
}

function Get-GufoOptionsPath {
  param($State)
  # Development copies keep their own choices so they never steer a release installer.
  $name = "installer.json"
  if (Test-GufoDevBuild) { $name = "installer.dev.json" }
  return (Join-Path $State.SettingsDir $name)
}

function Get-GufoLauncherCheckout {
  # The checkout whose engine the browser launcher starts, if it is one.
  param($State)
  $path = Join-Path $State.SettingsDir "launcher.json"
  if (-not (Test-Path -LiteralPath $path)) { return "" }
  try {
    $saved = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    $executable = [string]$saved.launcher.executable
    if (-not $executable) { $executable = [string]$saved.executable }
    if (-not $executable) { return "" }
    # The engine normally sits at build\<preset>\gufo.exe inside the checkout.
    $dir = Split-Path -Parent ([IO.Path]::GetFullPath($executable))
    for ($depth = 0; $dir -and $depth -lt 4; $depth++) {
      if (Test-GufoSourceFolder $dir) { return $dir }
      $dir = Split-Path -Parent $dir
    }
  } catch {
  }
  return ""
}

function Test-GufoLauncherElsewhere {
  param($State)
  return ($State.LauncherDir -and -not (Test-GufoSamePath $State.LauncherDir $State.InstallDir))
}

function Set-GufoInstallDir {
  # A folder the user picked; it is saved for the next run.
  param($State, [string]$Dir)
  $State.InstallDir = $Dir
  $State.InstallSource = "chosen"
  $State.InstallNote = ""
  Update-GufoCheckout $State
}

function Load-GufoOptions {
  param($State)
  $path = Get-GufoOptionsPath $State
  if (-not (Test-Path -LiteralPath $path)) { return }
  try {
    $saved = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    if ($saved.installDir) { $State.SavedInstallDir = [string]$saved.installDir }
    if ($saved.jobs) { $State.Jobs = [int]$saved.jobs }
    if ($saved.rocm) { $State.Rocm = [string]$saved.rocm }
    if ($saved.vcpkg) { $State.Vcpkg = [string]$saved.vcpkg }
    if ($null -ne $saved.shortcut) { $State.Shortcut = [bool]$saved.shortcut }
  } catch {
  }
}

function Save-GufoOptions {
  param($State)
  try {
    if (-not (Test-Path -LiteralPath $State.SettingsDir)) { New-Item -ItemType Directory -Force -Path $State.SettingsDir | Out-Null }
    # Only a folder someone chose, or one that now holds a checkout, is remembered.
    # The checkout running this installer is never adopted; the earlier choice stays.
    $installDir = ""
    if ($State.InstallSource -eq "checkout") {
      $installDir = $State.SavedInstallDir
    } elseif ($State.InstallSource -ne "default" -or (Test-GufoSourceFolder $State.InstallDir)) {
      $installDir = $State.InstallDir
    }
    $State.SavedInstallDir = $installDir
    $data = [ordered]@{
      installDir = $installDir
      jobs = $State.Jobs
      rocm = $State.Rocm
      vcpkg = $State.Vcpkg
      shortcut = $State.Shortcut
    }
    [IO.File]::WriteAllText((Get-GufoOptionsPath $State), ($data | ConvertTo-Json))
  } catch {
  }
}

function Set-GufoNotice {
  param($State, [string]$Text)
  $State.Notice = $Text
  $State.NoticeAt = Get-Date
}

function Test-GufoNoticeActive {
  param($State)
  if (-not $State.Notice) { return $false }
  return (((Get-Date) - $State.NoticeAt).TotalSeconds -lt 8)
}

function Update-GufoCheckout {
  param($State)
  $State.Checkout = Get-GufoCheckoutState $State.InstallDir
  $State.LauncherDir = Get-GufoLauncherCheckout $State
  if ($State.Screen -eq "menu") { Update-GufoMenu $State }
}

function Update-GufoMenu {
  param($State)
  $State.MenuItems = @(Get-GufoMenuItems $State)
  if ($State.MenuIndex -ge $State.MenuItems.Count) {
    $State.MenuIndex = [Math]::Max(0, $State.MenuItems.Count - 1)
  }
}

function Get-GufoMenuItems {
  param($State)
  $items = New-Object System.Collections.Generic.List[object]
  if ($State.Checkout.Valid) {
    $items.Add(@{ Key = "update"; Label = "Update"; Hint = "pull windows-main and rebuild the engine" })
    $items.Add(@{ Key = "repair"; Label = "Install/Repair"; Hint = "recheck tools, rebuild, verify the GPU" })
  } else {
    $items.Add(@{ Key = "install"; Label = "Install Gufo"; Hint = "fetch windows-main, build for this PC, verify the GPU" })
  }
  if ($State.Checkout.Exists -or (Test-Path -LiteralPath $State.DepsDir) -or (Test-Path -LiteralPath (Join-Path $State.SettingsDir "launcher.json"))) {
    $items.Add(@{ Key = "uninstall"; Label = "Uninstall"; Hint = "remove the checkout, build, and settings" })
  }
  if (Test-GufoLauncherElsewhere $State) {
    $items.Add(@{ Key = "uselauncher"; Label = "Use launcher folder"; Hint = "manage $($State.LauncherDir) instead" })
  }
  $items.Add(@{ Key = "advanced"; Label = "Advanced"; Hint = "install folder, build jobs, GPU and vcpkg paths" })
  $items.Add(@{ Key = "quit"; Label = "Quit"; Hint = "" })
  return $items.ToArray()
}

function Test-GufoSourceFolder {
  param([string]$Dir)
  if (-not $Dir) { return $false }
  return (Test-Path -LiteralPath (Join-Path $Dir "vcpkg.json")) -and
    (Test-Path -LiteralPath (Join-Path $Dir "setup-windows.bat"))
}

function Get-GufoModelWarning {
  param([string]$Dir)
  if (-not (Test-Path -LiteralPath (Join-Path $Dir ".git"))) {
    return "No Git metadata: model files could not be checked. Keep this folder."
  }
  $git = Find-GufoGit
  if (-not $git) { return "Git is unavailable: model files could not be checked. Keep this folder." }
  try {
    # Without exclusion rules, --others includes ignored files as well.
    $models = @(& $git -C $Dir ls-files --cached --others -- `
      ":(glob,icase)**/*.gguf" ":(glob,icase)**/*.safetensors" ":(glob,icase)**/*.ckpt" `
      ":(glob,icase)**/pytorch_model*.bin" ":(top,glob,icase)models/**" 2>$null)
    if ($LASTEXITCODE -ne 0) { return "Model files could not be checked. Keep this folder." }
    if ($models.Count) { return "This folder contains model files. Move them outside the checkout before removing it." }
  } catch {
    return "Model files could not be checked. Keep this folder."
  }
  return ""
}

function Get-GufoCheckoutWarning {
  # A folder that may hold someone's work is never removed by default.
  param([string]$Dir)
  if ($PSScriptRoot) {
    $prefix = [IO.Path]::GetFullPath($Dir).TrimEnd([char]92) + [char]92
    if ([IO.Path]::GetFullPath($PSScriptRoot).StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
      return "This installer runs from this folder, so it may be a development checkout."
    }
  }
  if (-not (Test-Path -LiteralPath (Join-Path $Dir ".git"))) { return "" }
  $git = Find-GufoGit
  if (-not $git) { return "Git is unavailable, so local changes could not be checked." }
  try {
    $status = & $git -C $Dir status --porcelain 2>$null
    if ($LASTEXITCODE -ne 0) { return "Local changes could not be checked." }
    if (@($status).Count -gt 0) { return "This checkout has uncommitted or untracked files." }
    $unpublished = & $git -C $Dir rev-list --max-count=1 --branches HEAD --not --remotes -- 2>$null
    if ($LASTEXITCODE -ne 0) { return "Unpublished commits could not be checked." }
    if ($unpublished) { return "This checkout has unpublished commits." }
    $stashes = & $git -C $Dir stash list 2>$null
    if ($LASTEXITCODE -ne 0) { return "Stashes could not be checked." }
    if ($stashes) { return "This checkout has stashed work." }
  } catch {
    return "Local changes could not be checked."
  }
  return ""
}

function Get-GufoUninstallItems {
  param($State)
  $items = New-Object System.Collections.Generic.List[object]
  if (Test-GufoSourceFolder $State.InstallDir) {
    $modelWarning = Get-GufoModelWarning $State.InstallDir
    $warning = if ($modelWarning) { $modelWarning } else { Get-GufoCheckoutWarning $State.InstallDir }
    $items.Add(@{
      Key = "source"
      Label = "Source, build, and GUI environment"
      Files = @($State.InstallDir)
      Checked = (-not $warning)
      Warning = $warning
      Blocked = [bool]$modelWarning
    })
  }
  if (Test-Path -LiteralPath $State.DepsDir) {
    $items.Add(@{
      Key = "deps"
      Label = "Shared GPU runtime and dependency caches"
      Files = @($State.DepsDir)
      Checked = $true
    })
  }
  $settings = @()
  foreach ($name in @("launcher.json", "installer.json", "installer.dev.json")) {
    $path = Join-Path $State.SettingsDir $name
    if (Test-Path -LiteralPath $path) { $settings += $path }
  }
  foreach ($name in @("logs", "installer")) {
    $path = Join-Path $State.SettingsDir $name
    if (-not (Test-Path -LiteralPath $path)) { continue }
    if ($name -eq "installer" -and (Test-GufoRunningFromSetupDir $State)) { continue }
    $settings += $path
  }
  if ($settings.Count) {
    $items.Add(@{
      Key = "settings"
      Label = "Launcher settings, logs, and the setup entry"
      Files = $settings
      Checked = $true
    })
  }
  $shortcuts = @()
  foreach ($path in @((Get-GufoShortcutPath), (Get-GufoStartMenuShortcutPath))) {
    if ($path -and (Test-Path -LiteralPath $path)) { $shortcuts += $path }
  }
  if ($shortcuts.Count) {
    $items.Add(@{
      Key = "shortcut"
      Label = "Desktop and Start Menu shortcuts"
      Files = $shortcuts
      Checked = $true
    })
  }
  return $items.ToArray()
}

# ---------------------------------------------------------------- screens ---

function Get-GufoScreen {
  param($State)
  switch ($State.Screen) {
    "splash" { return Get-GufoSplashScreen $State }
    "menu" { return Get-GufoMenuScreen $State }
    "advanced" { return Get-GufoAdvancedScreen $State }
    "review" { return Get-GufoReviewScreen $State }
    "run" { if ($State.Run) { return Get-GufoRunScreen $State }; return Get-GufoMenuScreen $State }
    "done" { if ($State.Done) { return Get-GufoDoneScreen $State }; return Get-GufoMenuScreen $State }
    "uninstall" { if ($State.Uninstall) { return Get-GufoUninstallScreen $State }; return Get-GufoMenuScreen $State }
    "log" { return Get-GufoLogScreen $State }
    "help" { return Get-GufoHelpScreen $State }
    default { return Get-GufoSplashScreen $State }
  }
}

function Get-GufoSmallScreen {
  param([int]$Width, [int]$Height)
  return @(
    "",
    "  Gufo Setup needs a larger terminal window.",
    "  Current ${Width}x${Height}; needs at least 72x20.",
    "",
    "  Resize or maximize Windows Terminal; this screen updates itself.",
    "  Press Q to quit."
  )
}

function Get-GufoSplashScreen {
  param($State)
  $rows = New-Object System.Collections.Generic.List[object]
  foreach ($row in (Get-GufoBanner $State.Scheme ($State.Width - 4))) { $rows.Add($row) }
  $rows.Add($null)
  $rows.Add(@(@{ t = "  Checking this PC..."; c = "muted" }))
  return Format-GufoBox -Scheme $State.Scheme -Width $State.Width -Title "Gufo Setup" -Right $State.Tag -Rows $rows.ToArray()
}

function Get-GufoMenuScreen {
  param($State)
  $inner = $State.Width - 4
  $scheme = $State.Scheme
  $rows = New-Object System.Collections.Generic.List[object]
  foreach ($row in (Get-GufoBanner $scheme $inner)) { $rows.Add($row) }
  $rows.Add($null)
  if ($State.Machine) {
    $rows.Add((Get-GufoFactRow "Detected" $State.Machine.Cpu $scheme))
    $rows.Add((Get-GufoFactRow "Windows" "$($State.Machine.Os) $($State.Machine.Build) · $($State.Machine.RamGiB) GiB RAM" $scheme))
  }
  $installValue = $State.InstallDir
  $installRole = "text"
  if ($State.Checkout.Valid) {
    $suffix = ""
    if ($State.Checkout.Branch) { $suffix = "  ·  $($State.Checkout.Branch)" }
    if ($State.Checkout.Head) { $suffix += " @ $($State.Checkout.Head)" }
    $installValue += $suffix
  } elseif ($State.Checkout.Exists) {
    $installValue += "  ·  not a Gufo checkout"
    $installRole = "warn"
  }
  $rows.Add((Get-GufoFactRow "Install" $installValue $scheme $installRole))
  $rows.Add((Get-GufoFactRow "" "$(Get-GufoInstallSourceText $State.InstallSource)  ·  F changes it" $scheme "muted"))
  if ($State.InstallNote) { $rows.Add((Get-GufoFactRow "" $State.InstallNote $scheme "warn")) }
  if (Test-GufoLauncherElsewhere $State) {
    $rows.Add((Get-GufoFactRow "Launcher" "starts the engine in $($State.LauncherDir)" $scheme "warn"))
  }
  if ($State.Checkout.Valid) {
    if ($State.Checkout.EngineExists) {
      $rows.Add((Get-GufoFactRow "Engine" "build\windows-gpu\gufo.exe  ·  built $(Format-GufoAge $State.Checkout.Built)" $scheme))
    } else {
      $rows.Add((Get-GufoFactRow "Engine" "not built yet" $scheme "warn"))
    }
  }
  if ($State.Machine -and $State.Machine.Problem) {
    $rows.Add($null)
    foreach ($line in (Get-GufoWrap $State.Machine.Problem ($inner - 3))) {
      $rows.Add(@(@{ t = "  ! "; c = "warn" }, @{ t = $line; c = "warn" }))
    }
  }
  if (Test-GufoNoticeActive $State) {
    $rows.Add($null)
    foreach ($line in (Get-GufoWrap $State.Notice ($inner - 3))) {
      $rows.Add(@(@{ t = "  · "; c = "accent" }, @{ t = $line; c = "accent" }))
    }
  }
  $rows.Add($null)
  $index = 0
  foreach ($item in $State.MenuItems) {
    $rows.Add((Get-GufoMenuRow -Item $item -Selected ($index -eq $State.MenuIndex) -Width $inner -Scheme $scheme))
    $index++
  }
  return Format-GufoBox -Scheme $scheme -Width $State.Width -Title "Gufo Setup" -Right $State.Tag -Rows $rows.ToArray() -Footer "  $($scheme.Glyphs.UpDown) move   Enter select   F folder   A advanced   ? keys   Q quit"
}

function Get-GufoAdvancedScreen {
  param($State)
  $inner = $State.Width - 4
  $scheme = $State.Scheme
  $rows = New-Object System.Collections.Generic.List[object]
  $fields = Get-GufoAdvancedFields $State
  $rows.Add(@(@{ t = "  These settings are saved for the next run."; c = "muted" }))
  $rows.Add((@{ hr = $true }))
  $rows.Add($null)
  $index = 0
  foreach ($field in $fields) {
    $selected = ($index -eq $State.AdvancedIndex)
    $marker = "  "
    if ($selected) { $marker = "  $($scheme.Glyphs.Arrow) " }
    $value = $field.Value
    if ($State.Edit -and $State.Edit.Key -eq $field.Key) {
      $value = $State.Edit.Buffer + "_"
    }
    $runs = @(
      @{ t = $marker; c = "accent" },
      @{ t = $field.Label.PadRight(18); c = "muted" },
      @{ t = $value; c = "text" }
    )
    $rows.Add($runs)
    if ($selected -and $field.Hint) {
      $rows.Add(@(@{ t = "     "; c = "muted" }, @{ t = $field.Hint; c = "muted" }))
    }
    $index++
  }
  $rows.Add($null)
  $rows.Add((@{ hr = $true }))
  if (Test-GufoNoticeActive $State) {
    foreach ($line in (Get-GufoWrap $State.Notice ($inner - 3))) {
      $rows.Add(@(@{ t = "  ! "; c = "warn" }, @{ t = $line; c = "warn" }))
    }
  } else {
    $rows.Add(@(@{ t = "  The install folder holds the checkout and the build. Models live wherever you keep them."; c = "muted" }))
  }
  if ($State.Edit) {
    $footer = "  Type a value   Enter save   Esc cancel"
  } else {
    $footer = "  $($scheme.Glyphs.UpDown) move   Enter edit or toggle   Esc save and go back"
  }
  return Format-GufoBox -Scheme $scheme -Width $State.Width -Title "Gufo Setup · advanced" -Right $State.Tag -Rows $rows.ToArray() -Footer $footer
}

function Get-GufoAdvancedFields {
  param($State)
  $rocm = "auto-detect TheRock"
  if ($State.Rocm) { $rocm = $State.Rocm }
  $vcpkg = "prepare a pinned checkout"
  if ($State.Vcpkg) { $vcpkg = $State.Vcpkg }
  $shortcut = "create after setup"
  if (-not $State.Shortcut) { $shortcut = "do not create" }
  return @(
    @{ Key = "install"; Label = "Install folder"; Value = $State.InstallDir; Hint = "where windows-main is cloned and built"; Editable = $true },
    @{ Key = "jobs"; Label = "Build jobs"; Value = [string]$State.Jobs; Hint = "parallel compilers (default $(Get-GufoDefaultJobs))"; Editable = $true },
    @{ Key = "rocm"; Label = "GPU runtime"; Value = $rocm; Hint = "optional TheRock 10.0.0 folder"; Editable = $true },
    @{ Key = "vcpkg"; Label = "vcpkg"; Value = $vcpkg; Hint = "optional existing vcpkg checkout"; Editable = $true },
    @{ Key = "shortcut"; Label = "Desktop shortcut"; Value = $shortcut; Hint = "Space toggles it"; Editable = $false }
  )
}

function Get-GufoReviewScreen {
  param($State)
  $inner = $State.Width - 4
  $scheme = $State.Scheme
  $plan = $State.Plan
  $rows = New-Object System.Collections.Generic.List[object]
  $rows.Add(@(@{ t = "  Plan from tools\windows\setup.ps1 -CheckOnly"; c = "muted" }))
  $rows.Add((@{ hr = $true }))
  $rows.Add($null)
  if ($plan) {
    $rows.Add((Get-GufoFactRow "Install to" $State.InstallDir $scheme))
    $branch = $script:GufoBranch
    if ($State.Checkout.Head) { $branch += " @ $($State.Checkout.Head)" }
    $rows.Add((Get-GufoFactRow "Branch" $branch $scheme))
    $space = $null
    try {
      $drive = [IO.Path]::GetPathRoot($State.InstallDir)
      $space = @($plan.space) | Where-Object { $_.root -eq $drive } | Select-Object -First 1
    } catch {
    }
    if ($space) { $rows.Add((Get-GufoFactRow "Free space" "$($space.freeGiB) GiB on $($space.root)" $scheme)) }
    $packages = @($plan.packages)
    $install = @($packages | Where-Object { $_.action -eq "install" })
    $reuse = @($packages | Where-Object { $_.action -eq "reuse" })
    $rows.Add((Get-GufoFactRow "Tools" "$($install.Count) to install, $($reuse.Count) already present" $scheme))
    if ($install.Count) {
      $text = ($install | ForEach-Object { "$($_.name) $($_.version)" }) -join " · "
      foreach ($line in (Get-GufoWrap $text ($inner - 19))) {
        $rows.Add(@(@{ t = "               "; c = "muted" }, @{ t = $line; c = "text" }))
      }
    }
    if ($plan.rock.action -eq "reuse") {
      $rows.Add((Get-GufoFactRow "GPU runtime" "reuse $($plan.rock.path)" $scheme))
    } else {
      $rows.Add((Get-GufoFactRow "GPU runtime" "download TheRock $($plan.rock.version) for gfx1151" $scheme))
    }
    if ($plan.vcpkg.action -eq "reuse") {
      $rows.Add((Get-GufoFactRow "Dependencies" "reuse $($plan.vcpkg.path)" $scheme))
    } else {
      $rows.Add((Get-GufoFactRow "Dependencies" "prepare the pinned vcpkg checkout" $scheme))
    }
    $rows.Add((Get-GufoFactRow "Build" "gufo.exe with $($State.Jobs) parallel jobs" $scheme))
    $rows.Add($null)
    $notes = "The first setup is long and mostly compiler work. Installers may ask for Windows permission. Interrupting is safe: completed downloads and build steps are reused."
    foreach ($line in (Get-GufoWrap $notes ($inner - 4))) {
      $rows.Add(@(@{ t = "  · "; c = "accent" }, @{ t = $line; c = "muted" }))
    }
  } else {
    $rows.Add((Get-GufoFactRow "Plan" "not read yet" $scheme "warn"))
  }
  $rows.Add($null)
  if (Test-GufoNoticeActive $State) {
    foreach ($line in (Get-GufoWrap $State.Notice ($inner - 3))) {
      $rows.Add(@(@{ t = "  ! "; c = "warn" }, @{ t = $line; c = "warn" }))
    }
    $rows.Add($null)
  }
  $actions = @(
    @{ Key = "start"; Label = "Start setup"; Hint = "install, build, verify the GPU, open the launcher" },
    @{ Key = "advanced"; Label = "Advanced"; Hint = "change the folder, build jobs, or tool paths" },
    @{ Key = "back"; Label = "Back"; Hint = "return without changing anything" }
  )
  $index = 0
  foreach ($item in $actions) {
    $rows.Add((Get-GufoMenuRow -Item $item -Selected ($index -eq $State.MenuIndex) -Width $inner -Scheme $scheme))
    $index++
  }
  return Format-GufoBox -Scheme $scheme -Width $State.Width -Title "Gufo Setup · review" -Right $State.Tag -Rows $rows.ToArray() -Footer "  $($scheme.Glyphs.UpDown) move   Enter confirm   Esc back"
}

function Get-GufoRunScreen {
  param($State)
  $inner = $State.Width - 4
  $scheme = $State.Scheme
  $run = $State.Run
  $rows = New-Object System.Collections.Generic.List[object]
  $rows.Add(@(@{ t = "  $($run.Title)"; c = "accent2" }))
  $elapsed = Format-GufoElapsed $run.Started.Elapsed
  $rows.Add((Get-GufoSpreadRow -Left $run.Phase -Right $elapsed -Width $inner -Scheme $scheme))
  $barWidth = [int][Math]::Min(30, [Math]::Max(10, $inner / 3))
  if ($null -ne $run.Fraction) {
    $bar = Get-GufoBar -Fraction $run.Fraction -Width $barWidth -Scheme $scheme
    $detail = ""
    if ($run.Detail) { $detail = "  $($run.Detail)" }
    $barRuns = @(@{ t = "  ["; c = "frame" }) + @($bar) + @(@{ t = "]"; c = "frame" }, @{ t = $detail; c = "muted" })
    $rows.Add($barRuns)
  } else {
    $bar = Get-GufoBar -Indeterminate -Phase ($run.Started.Elapsed.TotalSeconds / 2) -Width $barWidth -Scheme $scheme
    $detail = ""
    if ($run.Detail) { $detail = "  $($run.Detail)" }
    $barRuns = @(@{ t = "  ["; c = "frame" }) + @($bar) + @(@{ t = "]"; c = "frame" }, @{ t = $detail; c = "muted" })
    $rows.Add($barRuns)
  }
  $rows.Add((@{ hr = $true }))
  $rows.Add($null)
  $index = 0
  foreach ($step in $run.Steps) {
    if ($run.Cancelled -or ($null -ne $run.ExitCode -and $run.ExitCode -ne 0)) {
      $marker = $scheme.Glyphs.Dot
      $markerRole = "muted"
      $nameRole = "muted"
    } elseif ($index -lt $run.Step) {
      $marker = $scheme.Glyphs.Check
      $markerRole = "ok"
      $nameRole = "muted"
    } elseif ($index -eq $run.Step) {
      $marker = $scheme.Glyphs.Bullet
      $markerRole = "accent2"
      $nameRole = "text"
    } else {
      $marker = $scheme.Glyphs.Dot
      $markerRole = "muted"
      $nameRole = "muted"
    }
    $rows.Add(@(@{ t = "   $marker "; c = $markerRole }, @{ t = $step; c = $nameRole }))
    $index++
  }
  $rows.Add($null)
  $rows.Add(@(@{ t = "  Latest output"; c = "muted" }))
  $maxTail = [Math]::Max(2, $State.Height - 17)
  $tail = @($run.Tail)
  $start = [Math]::Max(0, $tail.Count - $maxTail)
  for ($line = $start; $line -lt $tail.Count; $line++) {
    $text = ($tail[$line] -replace "\s+$", "")
    $rows.Add(@(@{ t = "    "; c = "muted" }, @{ t = $text; c = "muted" }))
  }
  $rows.Add($null)
  $rows.Add(@(@{ t = "  Log  "; c = "muted" }, @{ t = $run.LogPath; c = "muted" }))
  if (Test-GufoRunArmed $run.CancelAt) {
    $footer = "  Press C again to stop the build; any other key keeps it running."
  } elseif (Test-GufoRunArmed $run.QuitAt) {
    $footer = "  Press Q again to stop the build and quit; other keys cancel."
  } else {
    $footer = "  L full log   O open log   C cancel   Q quit"
  }
  return Format-GufoBox -Scheme $scheme -Width $State.Width -Title "Gufo Setup · working" -Right $State.Tag -Rows $rows.ToArray() -Footer $footer
}

function Get-GufoDoneScreen {
  param($State)
  $inner = $State.Width - 4
  $scheme = $State.Scheme
  $done = $State.Done
  $rows = New-Object System.Collections.Generic.List[object]
  if ($done.Ok) {
    $rows.Add(@(@{ t = "  $($scheme.Glyphs.Check) "; c = "ok" }, @{ t = $done.Title; c = "ok" }))
  } else {
    $rows.Add(@(@{ t = "  $($scheme.Glyphs.Cross) "; c = "error" }, @{ t = $done.Title; c = "error" }))
  }
  $rows.Add((@{ hr = $true }))
  $rows.Add($null)
  if ($done.Message) {
    foreach ($line in (Get-GufoWrap $done.Message ($inner - 4))) {
      $rows.Add(@(@{ t = "  "; c = "text" }, @{ t = $line; c = "text" }))
    }
    $rows.Add($null)
  }
  if ($done.Version) { $rows.Add((Get-GufoFactRow "Version" $done.Version $scheme)) }
  if ($State.Checkout.EngineExists) {
    $rows.Add((Get-GufoFactRow "Engine" $State.Checkout.Engine $scheme))
  }
  if ($done.LogPath) {
    $rows.Add((Get-GufoFactRow "Log" $done.LogPath $scheme "muted"))
  }
  foreach ($detail in @($done.Details)) {
    if ($detail) { $rows.Add(@(@{ t = "  "; c = "muted" }, @{ t = $detail; c = "muted" })) }
  }
  if ($done.Ok -and $State.Checkout.EngineExists) {
    $rows.Add($null)
    foreach ($line in (Get-GufoWrap "Launch the launcher, choose your model files, then press Start. The launcher opens at http://127.0.0.1:8090." ($inner - 4))) {
      $rows.Add(@(@{ t = "  · "; c = "accent" }, @{ t = $line; c = "muted" }))
    }
  }
  if (Test-GufoNoticeActive $State) {
    $rows.Add($null)
    foreach ($line in (Get-GufoWrap $State.Notice ($inner - 3))) {
      $rows.Add(@(@{ t = "  ! "; c = "warn" }, @{ t = $line; c = "warn" }))
    }
  }
  $rows.Add($null)
  $index = 0
  foreach ($item in $State.MenuItems) {
    $rows.Add((Get-GufoMenuRow -Item $item -Selected ($index -eq $State.MenuIndex) -Width $inner -Scheme $scheme))
    $index++
  }
  return Format-GufoBox -Scheme $scheme -Width $State.Width -Title "Gufo Setup · result" -Right $State.Tag -Rows $rows.ToArray() -Footer "  $($scheme.Glyphs.UpDown) move   Enter select   Esc menu   Q quit"
}

function Get-GufoUninstallScreen {
  param($State)
  $inner = $State.Width - 4
  $scheme = $State.Scheme
  $uninstall = $State.Uninstall
  $rows = New-Object System.Collections.Generic.List[object]
  $rows.Add(@(@{ t = "  This removes Gufo files from this PC. It cannot be undone."; c = "warn" }))
  $rows.Add((@{ hr = $true }))
  $rows.Add($null)
  if (-not $uninstall.Items.Count) {
    $rows.Add(@(@{ t = "  Nothing to remove: no checkout, dependencies, or settings found."; c = "muted" }))
  }
  $index = 0
  $selectedStart = 0
  $selectedEnd = 0
  foreach ($item in $uninstall.Items) {
    $box = "[ ]"
    $boxRole = "muted"
    if ($item.Checked) {
      $box = "[x]"
      $boxRole = "ok"
    }
    $selected = ($index -eq $uninstall.Index)
    if ($selected) { $selectedStart = $rows.Count }
    $marker = " "
    if ($selected) { $marker = $scheme.Glyphs.Arrow }
    $rows.Add(@(
      @{ t = "  $marker "; c = "accent" },
      @{ t = "$box "; c = $boxRole },
      @{ t = $item.Label; c = "text" }
    ))
    foreach ($file in $item.Files) {
      $rows.Add(@(@{ t = "       "; c = "muted" }, @{ t = $file; c = "muted" }))
    }
    if ($item.Warning) {
      $warning = $item.Warning
      if (-not $item.Blocked) { $warning += " Not selected by default." }
      foreach ($line in (Get-GufoWrap $warning ($inner - 10))) {
        $rows.Add(@(@{ t = "     ! "; c = "warn" }, @{ t = $line; c = "warn" }))
      }
    }
    if ($selected) { $selectedEnd = $rows.Count }
    $index++
  }
  $rows.Add($null)
  $rows.Add(@(@{ t = "  Kept: Git, Visual Studio Build Tools, CMake, Ninja, Python, the AMD driver,"; c = "muted" }))
  $rows.Add(@(@{ t = "        and your model files."; c = "muted" }))
  if (Test-GufoRunningFromSetupDir $State) {
    foreach ($line in (Get-GufoWrap "The installer copy you are running stays in $(Get-GufoSetupDir $State); its shortcut is removed." ($inner - 4))) {
      $rows.Add(@(@{ t = "        "; c = "muted" }, @{ t = $line; c = "muted" }))
    }
  }
  $rows.Add($null)
  $body = $rows
  $rows = New-Object System.Collections.Generic.List[object]
  $confirm = $uninstall.Confirm
  $confirmRole = "text"
  if ($confirm -eq "uninstall") { $confirmRole = "ok" }
  $rows.Add(@(
    @{ t = "  Type uninstall to confirm:  "; c = "muted" },
    @{ t = ($confirm + "_"); c = $confirmRole }
  ))
  if (Test-GufoNoticeActive $State) {
    $rows.Add(@(@{ t = "  ! "; c = "warn" }, @{ t = $State.Notice; c = "warn" }))
  }
  # Reserve the confirmation, scroll indicator, and box/footer before paging
  # the variable-length list. Selection follows arrow keys; paging is manual.
  $available = [Math]::Max(1, $State.Height - 5 - $rows.Count)
  $offset = [int]$uninstall.Offset
  if ($null -eq $uninstall.LastIndex -or $uninstall.LastIndex -ne $uninstall.Index) {
    if ($selectedStart -lt $offset) { $offset = $selectedStart }
    if ($selectedEnd -gt $offset + $available) { $offset = [Math]::Min($selectedStart, $selectedEnd - $available) }
  }
  $offset = [Math]::Max(0, [Math]::Min($offset, $body.Count - $available))
  $uninstall.Offset = $offset
  $uninstall.LastIndex = $uninstall.Index
  $page = $body.GetRange($offset, [Math]::Min($available, $body.Count - $offset))
  $scroll = ""
  if ($body.Count -gt $available) { $scroll = "  Rows $($offset + 1)-$($offset + $page.Count) of $($body.Count) · PgUp/PgDn scroll" }
  $page.Add(@(@{ t = $scroll; c = "muted" }))
  $page.AddRange($rows)
  return Format-GufoBox -Scheme $scheme -Width $State.Width -Title "Gufo Setup · uninstall" -Right $State.Tag -Rows $page.ToArray() -Footer "  $($scheme.Glyphs.UpDown) move   Space toggle   Enter remove   Esc back"
}

function Get-GufoLogScreen {
  param($State)
  $scheme = $State.Scheme
  $inner = $State.Width - 4
  $rows = New-Object System.Collections.Generic.List[object]
  $rows.Add(@(@{ t = "  $($State.LogView.Path)"; c = "muted" }))
  $rows.Add((@{ hr = $true }))
  $available = [Math]::Max(3, $State.Height - 7)
  $lines = @($State.LogView.Lines)
  $offset = [Math]::Min($State.LogView.Offset, [Math]::Max(0, $lines.Count - 1))
  for ($index = $offset; $index -lt [Math]::Min($lines.Count, $offset + $available); $index++) {
    $rows.Add(@(@{ t = "  "; c = "muted" }, @{ t = $lines[$index]; c = "text" }))
  }
  $position = "line $([Math]::Min($lines.Count, $offset + 1)) of $($lines.Count)"
  return Format-GufoBox -Scheme $scheme -Width $State.Width -Title "Gufo Setup · log" -Right $State.Tag -Rows $rows.ToArray() -Footer "  $($scheme.Glyphs.UpDown) scroll   PgUp/PgDn   Home/End   $position   Esc back"
}

function Get-GufoHelpScreen {
  param($State)
  $scheme = $State.Scheme
  $inner = $State.Width - 4
  $rows = New-Object System.Collections.Generic.List[object]
  $keys = @(
    @{ Key = "Up / Down"; Text = "move the selection" },
    @{ Key = "Enter"; Text = "open or confirm the selection" },
    @{ Key = "Esc"; Text = "go back to the previous screen" },
    @{ Key = "Space"; Text = "toggle a checkbox in Uninstall" },
    @{ Key = "C"; Text = "stop a running build (press twice)" },
    @{ Key = "L / O"; Text = "show the full log / open it in Notepad" },
    @{ Key = "F"; Text = "change the install folder" },
    @{ Key = "A / R"; Text = "advanced options / rescan this PC" },
    @{ Key = "Q"; Text = "quit without changing anything" }
  )
  $rows.Add(@(@{ t = "  Gufo Setup installs the Windows build of Gufo from windows-main."; c = "muted" }))
  $rows.Add((@{ hr = $true }))
  $rows.Add($null)
  foreach ($entry in $keys) {
    $rows.Add(@(@{ t = "  "; c = "muted" }, @{ t = $entry.Key.PadRight(12); c = "accent" }, @{ t = $entry.Text; c = "text" }))
  }
  $rows.Add($null)
  foreach ($line in (Get-GufoWrap "Tool paths, setup logs, and answers to installer prompts follow the source setup. See docs/WINDOWS.md in the checkout." $inner)) {
    $rows.Add(@(@{ t = "  "; c = "muted" }, @{ t = $line; c = "muted" }))
  }
  return Format-GufoBox -Scheme $scheme -Width $State.Width -Title "Gufo Setup · keys" -Right $State.Tag -Rows $rows.ToArray() -Footer "  Press any key to go back"
}

# ------------------------------------------------------------- processes ---

function New-GufoLogReader {
  param([string]$Path)
  return @{
    Path = $Path
    Stream = $null
    Position = 0L
    Pending = New-Object System.IO.MemoryStream
    Buffer = New-Object "byte[]" 65536
  }
}

function Update-GufoLogReader {
  param($Reader)
  $lines = New-Object System.Collections.Generic.List[string]
  if (-not $Reader.Stream) {
    if (-not (Test-Path -LiteralPath $Reader.Path)) { return $lines.ToArray() }
    try {
      $Reader.Stream = New-Object System.IO.FileStream($Reader.Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    } catch {
      return $lines.ToArray()
    }
  }
  try {
    if ($Reader.Stream.Length -gt $Reader.Position) {
      $Reader.Stream.Position = $Reader.Position
      while (($read = $Reader.Stream.Read($Reader.Buffer, 0, $Reader.Buffer.Length)) -gt 0) {
        $Reader.Position += $read
        $Reader.Pending.Write($Reader.Buffer, 0, $read)
      }
    }
  } catch {
    return $lines.ToArray()
  }
  $bytes = $Reader.Pending.ToArray()
  if (-not $bytes -or $bytes.Length -eq 0) { return $lines.ToArray() }
  $cut = -1
  for ($index = $bytes.Length - 1; $index -ge 0; $index--) {
    if ($bytes[$index] -eq 10 -or $bytes[$index] -eq 13) { $cut = $index; break }
  }
  if ($cut -lt 0) { return $lines.ToArray() }
  $text = [Text.Encoding]::UTF8.GetString($bytes, 0, $cut + 1)
  $Reader.Pending.SetLength(0)
  if ($cut + 1 -lt $bytes.Length) { $Reader.Pending.Write($bytes, $cut + 1, $bytes.Length - $cut - 1) }
  foreach ($line in [regex]::Split($text, "\r\n|\r|\n")) {
    if ($line.Length -gt 0) { $lines.Add($line) }
  }
  return $lines.ToArray()
}

function Start-GufoChildProcess {
  param([string]$CommandLine, [hashtable]$Environment, [string]$WorkingDirectory, [string]$LogPath)
  $info = New-Object System.Diagnostics.ProcessStartInfo
  $info.FileName = $env:ComSpec
  # cmd strips the first and last quote when the command starts with a quote,
  # so a quoted program needs one extra wrapping pair around the whole line.
  $redirected = "$CommandLine > `"%GUFO_LOG%`" 2>&1"
  if ($CommandLine.StartsWith('"')) {
    $info.Arguments = "/d /s /c `"$redirected`""
  } else {
    $info.Arguments = "/d /s /c $redirected"
  }
  $info.UseShellExecute = $false
  $info.CreateNoWindow = $true
  if ($WorkingDirectory) { $info.WorkingDirectory = $WorkingDirectory }
  $info.EnvironmentVariables["GUFO_LOG"] = $LogPath
  if ($Environment) {
    foreach ($key in $Environment.Keys) { $info.EnvironmentVariables[$key] = [string]$Environment[$key] }
  }
  return [System.Diagnostics.Process]::Start($info)
}

function Set-GufoRunStep {
  param($Run, [string]$Name, [string]$Phase = "", $Fraction = $null, [string]$Detail = "")
  if (-not $Run.Keys.ContainsKey($Name)) { return }
  $Run.Step = $Run.Keys[$Name]
  if ($Phase) { $Run.Phase = $Phase }
  $Run.Fraction = $Fraction
  $Run.Detail = $Detail
}

function Update-GufoRunLine {
  param($Run, [string]$Line)
  if ($Line -match "Receiving objects:\s+(\d+)%") {
    Set-GufoRunStep $Run "clone" "Cloning windows-main" ([double]$Matches[1] / 100) "receiving objects $($Matches[1])%"
  } elseif ($Line -match "Resolving deltas:\s+(\d+)%") {
    Set-GufoRunStep $Run "clone" "Cloning windows-main" ([double]$Matches[1] / 100) "resolving deltas $($Matches[1])%"
  } elseif ($Line -match "Installing ([A-Za-z]+) \(") {
    Set-GufoRunStep $Run "tools" "Installing $($Matches[1])"
  } elseif ($Line -match "Downloading/verifying TheRock") {
    Set-GufoRunStep $Run "tools" "Downloading TheRock GPU libraries"
  } elseif ($Line -match "Extracting TheRock") {
    Set-GufoRunStep $Run "tools" "Extracting TheRock"
  } elseif ($Line -match "Preparing vcpkg") {
    Set-GufoRunStep $Run "deps" "Preparing vcpkg dependencies"
  } elseif ($Line -match "Building Gufo") {
    Set-GufoRunStep $Run "compile" "Compiling the engine"
  } elseif ($Line -match "Checking the built executable") {
    Set-GufoRunStep $Run "verify" "Verifying the engine and GPU"
  } elseif ($Line -match "Setup complete") {
    Set-GufoRunStep $Run "finish" "Finishing"
  } elseif ($Line -match "Updating .* windows-main") {
    Set-GufoRunStep $Run "pull" "Pulling windows-main"
  } elseif ($Line -match "Rebuilding build\\windows-gpu") {
    Set-GufoRunStep $Run "compile" "Compiling the engine"
  } elseif ($Line -match "Cloning into") {
    Set-GufoRunStep $Run "clone" "Cloning windows-main"
  } elseif ($Line -match "\[(\d+)/(\d+)\]") {
    $done = [double]$Matches[1]
    $total = [double]$Matches[2]
    if ($total -gt 0) {
      Set-GufoRunStep $Run "compile" "Compiling the engine" ($done / $total) "$($Matches[1]) of $($Matches[2]) targets"
    }
  }
}

function Get-GufoFailureText {
  param($Run)
  $tail = @($Run.Tail)
  for ($index = $tail.Count - 1; $index -ge 0; $index--) {
    if ($tail[$index] -match "failed|error|stopped|cannot|not found|missing|denied") {
      $start = [Math]::Max(0, $index - 2)
      return (($tail[$start..([Math]::Min($tail.Count - 1, $index + 2))]) -join "`n")
    }
  }
  if ($tail.Count) { return (($tail | Select-Object -Last 4) -join "`n") }
  return ""
}

function Test-GufoRunArmed {
  # A destructive key was pressed once and is waiting for its confirming press.
  param($Time)
  if (-not $Time) { return $false }
  return (((Get-Date) - $Time).TotalSeconds -lt 4)
}

function Stop-GufoChild {
  param($Process)
  try {
    & taskkill.exe /PID $Process.Id /T /F > $null 2>&1
  } catch {
  }
  try { [void]$Process.WaitForExit(10000) } catch {
  }
}

function Invoke-GufoRun {
  param($State, [string]$Kind, [string]$Title, [string]$CommandLine, [hashtable]$Environment, [string]$WorkingDirectory, [string]$LogPath)
  $definition = $script:GufoRuns[$Kind]
  $run = @{
    Kind = $Kind
    Title = $Title
    Steps = @($definition.Steps)
    Keys = $definition.Keys
    Step = 0
    Phase = "Starting"
    Fraction = $null
    Detail = ""
    Tail = New-Object System.Collections.Generic.List[string]
    LogPath = $LogPath
    Started = [Diagnostics.Stopwatch]::StartNew()
    ExitCode = $null
    Cancelled = $false
    CancelAt = $null
    QuitAt = $null
    QuitAfter = $false
    Process = $null
  }
  $State.Run = $run
  $State.Screen = "run"
  $reader = New-GufoLogReader $LogPath
  try {
    $run.Process = Start-GufoChildProcess -CommandLine $CommandLine -Environment $Environment -WorkingDirectory $WorkingDirectory -LogPath $LogPath
  } catch {
    $run.ExitCode = 1
    $run.Tail.Add("Could not start the process: $($_.Exception.Message)")
    return @{ Ok = $false; ExitCode = 1; Cancelled = $false; QuitAfter = $false; Log = $LogPath; Tail = $run.Tail.ToArray(); Failure = $run.Tail[0] }
  }
  while ($true) {
    foreach ($line in (Update-GufoLogReader $reader)) {
      $run.Tail.Add($line)
      if ($run.Tail.Count -gt 400) { $run.Tail.RemoveAt(0) }
      Update-GufoRunLine $run $line
      if (-not $State.Interactive) { Write-Host $line }
    }
    if ($run.Process.HasExited) {
      Start-Sleep -Milliseconds 120
      $rest = @(Update-GufoLogReader $reader)
      foreach ($line in $rest) {
        $run.Tail.Add($line)
        if ($run.Tail.Count -gt 400) { $run.Tail.RemoveAt(0) }
        Update-GufoRunLine $run $line
        if (-not $State.Interactive) { Write-Host $line }
      }
      if ($rest.Count -eq 0) { break }
    }
    if ($State.Interactive) {
      Invoke-GufoDraw $State
      $key = Read-GufoKey -TimeoutMs 200
      if ($null -eq $key) { continue }
      if ($key -eq "Char:c" -or $key -eq "CtrlC") {
        if (Test-GufoRunArmed $run.CancelAt) {
          $run.Cancelled = $true
          $run.Phase = "Stopping"
          Stop-GufoChild $run.Process
          break
        }
        $run.CancelAt = Get-Date
        $run.QuitAt = $null
      } elseif ($key -eq "Char:q") {
        if (Test-GufoRunArmed $run.QuitAt) {
          $run.QuitAfter = $true
          $run.Cancelled = $true
          $run.Phase = "Stopping"
          Stop-GufoChild $run.Process
          break
        }
        $run.QuitAt = Get-Date
        $run.CancelAt = $null
      } elseif ($key -eq "Char:l") {
        $run.CancelAt = $null
        $run.QuitAt = $null
        Show-GufoLogWhileRunning $State $run $LogPath
      } elseif ($key -eq "Char:o") {
        $run.CancelAt = $null
        $run.QuitAt = $null
        Open-GufoLogFile $LogPath
      } else {
        $run.CancelAt = $null
        $run.QuitAt = $null
      }
    } else {
      Start-Sleep -Milliseconds 120
    }
  }
  try { $run.ExitCode = $run.Process.ExitCode } catch { $run.ExitCode = 1 }
  $run.Started.Stop()
  if ($reader.Stream) {
    try { $reader.Stream.Dispose() } catch {
    }
  }
  $ok = ($run.ExitCode -eq 0 -and -not $run.Cancelled)
  $failure = ""
  if (-not $ok) { $failure = Get-GufoFailureText $run }
  return @{
    Ok = $ok
    ExitCode = $run.ExitCode
    Cancelled = $run.Cancelled
    QuitAfter = $run.QuitAfter
    Log = $LogPath
    Tail = $run.Tail.ToArray()
    Failure = $failure
  }
}

# ------------------------------------------------------------------ tools ---

function Find-GufoGit {
  $found = Get-Command git.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($found) { return $found.Source }
  foreach ($candidate in @(
    "$env:ProgramFiles\Git\cmd\git.exe",
    "${env:ProgramFiles(x86)}\Git\cmd\git.exe",
    "$env:LOCALAPPDATA\Programs\Git\cmd\git.exe"
  )) {
    if ($candidate -and (Test-Path -LiteralPath $candidate)) { return $candidate }
  }
  return ""
}

function Refresh-GufoPath {
  try {
    $machine = [Environment]::GetEnvironmentVariable("PATH", "Machine")
    $user = [Environment]::GetEnvironmentVariable("PATH", "User")
    $env:PATH = "$env:PATH;$machine;$user"
  } catch {
  }
}

function Test-GufoInstallDir {
  param([string]$Dir)
  if (-not [IO.Path]::IsPathRooted($Dir)) { return "Use a full path such as $env:USERPROFILE\Gufo." }
  if ($Dir -match "^[A-Za-z]:\\?$") { return "Choose a folder, not a drive root." }
  $parent = Split-Path -Parent $Dir
  if ($parent -and -not (Test-Path -LiteralPath $parent -PathType Container)) { return "The parent folder does not exist: $parent" }
  if (Test-Path -LiteralPath $Dir) {
    if (-not (Test-Path -LiteralPath $Dir -PathType Container)) { return "A file with that name already exists: $Dir" }
    $entries = @(Get-ChildItem -LiteralPath $Dir -Force -ErrorAction SilentlyContinue)
    if ($entries.Count -and -not (Get-GufoCheckoutState $Dir).Valid) {
      return "That folder already has files and is not a Gufo checkout. Choose another folder."
    }
  }
  return $null
}

function Test-GufoOptions {
  param($State)
  $errorText = Test-GufoInstallDir $State.InstallDir
  if ($errorText) { return $errorText }
  if ($State.Jobs -lt 1 -or $State.Jobs -gt 64) { return "Build jobs must be between 1 and 64." }
  if ($State.Vcpkg -and -not (Test-Path -LiteralPath (Join-Path $State.Vcpkg "bootstrap-vcpkg.bat"))) {
    return "The vcpkg folder must contain bootstrap-vcpkg.bat: $($State.Vcpkg)"
  }
  if ($State.Rocm -and -not (Test-Path -LiteralPath $State.Rocm -PathType Container)) {
    return "The GPU runtime folder does not exist: $($State.Rocm)"
  }
  return $null
}

function Get-GufoEngineVersion {
  param([string]$Path)
  if (-not (Test-Path -LiteralPath $Path)) { return "" }
  try {
    $output = & $Path --version 2>&1
    $text = ([string](@($output) | Select-Object -First 1)).Trim()
    return $text
  } catch {
    return ""
  }
}

function Get-GufoEngineRunning {
  param([string]$InstallDir = "")
  if (@(Get-Process -Name gufo -ErrorAction SilentlyContinue).Count -gt 0) { return $true }
  if (-not $InstallDir) { return $false }
  try {
    foreach ($process in @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)) {
      if ($process.ExecutablePath -and $process.ExecutablePath.StartsWith($InstallDir, [StringComparison]::OrdinalIgnoreCase)) {
        return $true
      }
    }
  } catch {
  }
  return $false
}

# --------------------------------------------------------------- actions ---

function Invoke-GufoFetch {
  param($State)
  if ((Get-GufoCheckoutState $State.InstallDir).Valid) { return @{ Ok = $true } }
  $existing = @(Get-ChildItem -LiteralPath $State.InstallDir -Force -ErrorAction SilentlyContinue)
  if ((Test-Path -LiteralPath $State.InstallDir) -and $existing.Count) {
    return @{ Ok = $false; Message = "The install folder already has files and is not a Gufo checkout. Choose another folder in Advanced." }
  }
  $git = Find-GufoGit
  if (-not $git) {
    $winget = Get-Command winget.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $winget) {
      return @{ Ok = $false; Message = "Git for Windows is required. Install it from https://git-scm.com/downloads/win, then retry. Microsoft's App Installer (winget) would let setup install it automatically." }
    }
    $log = Get-GufoLogPath "git"
    $command = "`"%GUFO_WINGET%`" install --id $($script:GufoGitPackage) --version $($script:GufoGitVersion) --exact --source winget --architecture x64 --accept-source-agreements"
    $run = Invoke-GufoRun -State $State -Kind "fetch" -Title "Installing Git for Windows" -CommandLine $command -Environment @{ GUFO_WINGET = $winget.Source } -WorkingDirectory $env:TEMP -LogPath $log
    if (-not $run.Ok) {
      return @{ Ok = $false; Message = "Git installation did not finish. Install Git for Windows manually, then retry."; Log = $run.Log }
    }
    Refresh-GufoPath
    $git = Find-GufoGit
    if (-not $git) {
      return @{ Ok = $false; Message = "Git is still unavailable after installation. Restart this terminal, or install Git for Windows manually."; Log = $run.Log }
    }
  }
  $parent = Split-Path -Parent $State.InstallDir
  if (-not (Test-Path -LiteralPath $parent)) {
    try { New-Item -ItemType Directory -Force -Path $parent | Out-Null } catch {
      return @{ Ok = $false; Message = "Cannot create $parent`: $($_.Exception.Message)" }
    }
  }
  $log = Get-GufoLogPath "clone"
  $command = "`"%GUFO_GIT%`" clone --branch $($script:GufoBranch) --single-branch --progress `"%GUFO_REPO%`" `"%GUFO_DEST%`""
  $run = Invoke-GufoRun -State $State -Kind "fetch" -Title "Fetching windows-main" -CommandLine $command -Environment @{
    GUFO_GIT = $git
    GUFO_REPO = $script:GufoRepository
    GUFO_DEST = $State.InstallDir
  } -WorkingDirectory $parent -LogPath $log
  if (-not $run.Ok) {
    # A failed clone leaves a partial folder; remove it so Retry starts clean.
    try {
      if ((Test-Path -LiteralPath $State.InstallDir) -and -not (Get-GufoCheckoutState $State.InstallDir).Valid) {
        if (@(Get-ChildItem -LiteralPath $State.InstallDir -Force -ErrorAction SilentlyContinue).Count) {
          Remove-GufoPath $State.InstallDir
        }
      }
    } catch {
    }
    return @{ Ok = $false; Message = "The clone did not finish. Check your connection and retry; the partial folder was removed."; Log = $run.Log; QuitAfter = $run.QuitAfter }
  }
  $checkout = Get-GufoCheckoutState $State.InstallDir
  if (-not $checkout.Valid) {
    return @{ Ok = $false; Message = "The clone finished but the checkout is incomplete. Remove $($State.InstallDir) and retry."; Log = $run.Log }
  }
  $State.FetchedDir = $State.InstallDir
  return @{ Ok = $true; Log = $run.Log }
}

function Get-GufoPowerShellPath {
  $shell = Join-Path $PSHOME "powershell.exe"
  if (Test-Path -LiteralPath $shell) { return $shell }
  $shell = Join-Path $PSHOME "pwsh.exe"
  if (Test-Path -LiteralPath $shell) { return $shell }
  return ""
}

function Invoke-GufoPlan {
  param($State)
  $setup = Join-Path $State.InstallDir "tools\windows\setup.ps1"
  if (-not (Test-Path -LiteralPath $setup)) {
    return @{ Ok = $false; Message = "tools\windows\setup.ps1 is missing from $($State.InstallDir)." }
  }
  $shell = Get-GufoPowerShellPath
  if (-not $shell) { return @{ Ok = $false; Message = "Windows PowerShell could not be located." } }
  $planPath = Join-Path $env:TEMP ("gufo-plan-{0}.json" -f ([guid]::NewGuid().ToString("N")))
  $arguments = @(" -CheckOnly", " -Jobs $($State.Jobs)", " -PlanJson `"%GUFO_PLAN%`"")
  if ($State.Rocm) { $arguments += " -Rocm `"%GUFO_ROCM%`"" }
  if ($State.Vcpkg) { $arguments += " -Vcpkg `"%GUFO_VCPKG%`"" }
  $command = "`"%GUFO_SHELL%`" -NoLogo -NoProfile -ExecutionPolicy Bypass -File `"%GUFO_PS1%`"" + ($arguments -join "")
  $log = Get-GufoLogPath "plan"
  $environment = @{ GUFO_SHELL = $shell; GUFO_PS1 = $setup; GUFO_PLAN = $planPath }
  if ($State.Rocm) { $environment.GUFO_ROCM = $State.Rocm }
  if ($State.Vcpkg) { $environment.GUFO_VCPKG = $State.Vcpkg }
  $run = Invoke-GufoRun -State $State -Kind "plan" -Title "Reading the setup plan" -CommandLine $command -Environment $environment -WorkingDirectory $State.InstallDir -LogPath $log
  if (-not $run.Ok) {
    return @{ Ok = $false; Message = "The setup plan could not be read. $(if ($run.Failure) { $run.Failure })"; Log = $run.Log; QuitAfter = $run.QuitAfter }
  }
  if (-not (Test-Path -LiteralPath $planPath)) {
    return @{ Ok = $false; Message = "The setup plan file was not written. Retry, or run tools\windows\setup.ps1 -CheckOnly in $($State.InstallDir)."; Log = $run.Log }
  }
  try {
    $plan = Get-Content -LiteralPath $planPath -Raw | ConvertFrom-Json
  } catch {
    return @{ Ok = $false; Message = "The setup plan file is not readable: $($_.Exception.Message)"; Log = $run.Log }
  } finally {
    Remove-Item -LiteralPath $planPath -Force -ErrorAction SilentlyContinue
  }
  $State.Plan = $plan
  $State.PlanKey = Get-GufoPlanKey $State
  return @{ Ok = $true; Plan = $plan; Log = $run.Log }
}

function Invoke-GufoSetupRun {
  param($State, [string]$Kind)
  $setup = Join-Path $State.InstallDir "tools\windows\setup.ps1"
  if (-not (Test-Path -LiteralPath $setup)) {
    return @{ Ok = $false; Message = "tools\windows\setup.ps1 is missing from $($State.InstallDir)." }
  }
  $shell = Get-GufoPowerShellPath
  if (-not $shell) { return @{ Ok = $false; Message = "Windows PowerShell could not be located." } }
  $arguments = @(" -Yes -NoLaunch", " -Jobs $($State.Jobs)")
  if ($State.Rocm) { $arguments += " -Rocm `"%GUFO_ROCM%`"" }
  if ($State.Vcpkg) { $arguments += " -Vcpkg `"%GUFO_VCPKG%`"" }
  $command = "`"%GUFO_SHELL%`" -NoLogo -NoProfile -ExecutionPolicy Bypass -File `"%GUFO_PS1%`"" + ($arguments -join "")
  $environment = @{ GUFO_SHELL = $shell; GUFO_PS1 = $setup }
  if ($State.Rocm) { $environment.GUFO_ROCM = $State.Rocm }
  if ($State.Vcpkg) { $environment.GUFO_VCPKG = $State.Vcpkg }
  $log = Get-GufoLogPath "setup"
  $title = "Building Gufo"
  if ($Kind -eq "repair") { $title = "Repairing Gufo" }
  $run = Invoke-GufoRun -State $State -Kind "install" -Title $title -CommandLine $command -Environment $environment -WorkingDirectory $State.InstallDir -LogPath $log
  Update-GufoCheckout $State
  if (-not $run.Ok) {
    return @{ Ok = $false; Message = $(if ($run.Cancelled) { "" } else { $run.Failure }); Log = $run.Log; Cancelled = $run.Cancelled; QuitAfter = $run.QuitAfter }
  }
  $details = @()
  if ($State.Shortcut) {
    try {
      $shortcut = New-GufoShortcut $State
      $details += "Desktop shortcut: $shortcut"
    } catch {
      $details += "Desktop shortcut was not created: $($_.Exception.Message)"
    }
  }
  try {
    $entry = Install-GufoSetupEntry $State
    if ($entry) { $details += "Setup shortcut: $entry" }
  } catch {
    $details += "Setup shortcut was not created: $($_.Exception.Message)"
  }
  Save-GufoOptions $State
  return @{ Ok = $true; Log = $run.Log; Details = $details; QuitAfter = $run.QuitAfter }
}

function Invoke-GufoUpdateRun {
  param($State)
  $update = Join-Path $State.InstallDir "tools\windows\update.ps1"
  if (-not (Test-Path -LiteralPath $update)) {
    return @{ Ok = $false; Message = "tools\windows\update.ps1 is missing from $($State.InstallDir)." }
  }
  $shell = Get-GufoPowerShellPath
  if (-not $shell) { return @{ Ok = $false; Message = "Windows PowerShell could not be located." } }
  $arguments = @(" -Jobs $($State.Jobs)")
  if ($State.Rocm) { $arguments += " -Rocm `"%GUFO_ROCM%`"" }
  if ($State.Vcpkg) { $arguments += " -Vcpkg `"%GUFO_VCPKG%`"" }
  $command = "`"%GUFO_SHELL%`" -NoLogo -NoProfile -ExecutionPolicy Bypass -File `"%GUFO_PS1%`"" + ($arguments -join "")
  $environment = @{ GUFO_SHELL = $shell; GUFO_PS1 = $update }
  if ($State.Rocm) { $environment.GUFO_ROCM = $State.Rocm }
  if ($State.Vcpkg) { $environment.GUFO_VCPKG = $State.Vcpkg }
  $log = Get-GufoLogPath "update"
  $run = Invoke-GufoRun -State $State -Kind "update" -Title "Updating windows-main" -CommandLine $command -Environment $environment -WorkingDirectory $State.InstallDir -LogPath $log
  Update-GufoCheckout $State
  if (-not $run.Ok) {
    return @{ Ok = $false; Message = $(if ($run.Cancelled) { "" } else { $run.Failure }); Log = $run.Log; Cancelled = $run.Cancelled; QuitAfter = $run.QuitAfter }
  }
  $details = @()
  try {
    $entry = Install-GufoSetupEntry $State
    if ($entry) { $details += "Setup shortcut: $entry" }
  } catch {
  }
  Save-GufoOptions $State
  return @{ Ok = $true; Log = $run.Log; Details = $details; QuitAfter = $run.QuitAfter }
}

function Test-GufoRemovable {
  param($State, $Item)
  if ($Item.Key -eq "source") {
    return (Test-GufoSourceFolder $Item.Files[0]) -and
      ([IO.Path]::GetFullPath($Item.Files[0]) -eq [IO.Path]::GetFullPath($State.InstallDir)) -and
      (-not (Get-GufoModelWarning $Item.Files[0]))
  }
  if ($Item.Key -eq "deps") {
    return ([IO.Path]::GetFullPath($Item.Files[0]) -eq [IO.Path]::GetFullPath($State.DepsDir))
  }
  if ($Item.Key -eq "settings") {
    $root = [IO.Path]::GetFullPath($State.SettingsDir)
    $prefix = $root.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    $deps = [IO.Path]::GetFullPath($State.DepsDir)
    foreach ($file in $Item.Files) {
      $full = [IO.Path]::GetFullPath($file)
      if (-not $full.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { return $false }
      if ($full.Equals($deps, [StringComparison]::OrdinalIgnoreCase)) { return $false }
    }
    return $true
  }
  if ($Item.Key -eq "shortcut") {
    $allowed = @()
    foreach ($path in @((Get-GufoShortcutPath), (Get-GufoStartMenuShortcutPath))) {
      if ($path) { $allowed += [IO.Path]::GetFullPath($path) }
    }
    foreach ($file in $Item.Files) {
      if ($allowed -notcontains [IO.Path]::GetFullPath($file)) { return $false }
    }
    return $true
  }
  return $false
}

function Remove-GufoPath {
  param([string]$Path)
  if (-not (Test-Path -LiteralPath $Path)) { return }
  $full = [IO.Path]::GetFullPath($Path)
  if ([IO.Directory]::Exists($full)) {
    # Windows PowerShell 5.1 Remove-Item -Recurse can follow junctions and
    # symlinks into their targets. rmdir removes the link itself, and the
    # extended-length prefix covers build and vcpkg trees past MAX_PATH.
    $info = New-Object System.Diagnostics.ProcessStartInfo
    $info.FileName = $env:ComSpec
    $info.Arguments = "/d /c rmdir /s /q `"\\?\$full`""
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    try {
      $process = [System.Diagnostics.Process]::Start($info)
      [void]$process.WaitForExit()
    } catch {
    }
    if ([IO.Directory]::Exists($full)) {
      # .NET also deletes reparse points without following them.
      [IO.Directory]::Delete("\\?\$full", $true)
    }
    return
  }
  if ([IO.File]::Exists($full)) {
    try {
      Remove-Item -LiteralPath $full -Force -ErrorAction Stop
    } catch {
      [IO.File]::Delete("\\?\$full")
    }
    return
  }
  throw "Cannot remove $Path"
}

function Invoke-GufoRemove {
  param($State, $Items)
  $removed = New-Object System.Collections.Generic.List[string]
  $failed = New-Object System.Collections.Generic.List[string]
  foreach ($item in $Items) {
    if (-not $item.Checked) { continue }
    if (-not (Test-GufoRemovable $State $item)) {
      $failed.Add("$($item.Label): refused the safety check")
      continue
    }
    foreach ($file in $item.Files) {
      try {
        Remove-GufoPath $file
        $removed.Add($file)
      } catch {
        $failed.Add("$file`: $($_.Exception.Message)")
      }
    }
  }
  Update-GufoCheckout $State
  return @{
    Ok = ($failed.Count -eq 0)
    Message = $(if ($failed.Count) { ($failed -join "`n") } else { "" })
    Details = @($removed | ForEach-Object { "Removed: $_" })
    Log = ""
  }
}

# --------------------------------------------------------------- helpers ---

function New-GufoShortcut {
  param($State)
  $installDir = $State.InstallDir
  $launcher = Join-Path $installDir "launch-gui.bat"
  if (-not (Test-Path -LiteralPath $launcher)) { throw "launch-gui.bat is missing from the checkout" }
  $path = Get-GufoShortcutPath
  if (-not $path) { throw "The Desktop folder could not be located" }
  $parent = Split-Path -Parent $path
  if ($parent -and -not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
  $shell = New-Object -ComObject WScript.Shell
  $link = $shell.CreateShortcut($path)
  $link.TargetPath = $launcher
  $link.WorkingDirectory = $installDir
  $link.Description = "Gufo local inference launcher"
  $icon = Join-Path $installDir "build\windows-gpu\gufo.exe"
  if (Test-Path -LiteralPath $icon) {
    $link.IconLocation = "$icon,0"
  } else {
    $link.IconLocation = "$env:SystemRoot\System32\shell32.dll,13"
  }
  $link.Save()
  return $path
}

function Install-GufoSetupEntry {
  param($State)
  $scriptPath = Join-Path $PSScriptRoot "Gufo-Setup.ps1"
  if (-not (Test-Path -LiteralPath $scriptPath)) { return "" }
  $target = Get-GufoSetupDir $State
  $targetScript = Join-Path $target "Gufo-Setup.ps1"
  if ([IO.Path]::GetFullPath($scriptPath) -ne [IO.Path]::GetFullPath($targetScript)) {
    New-Item -ItemType Directory -Force -Path $target | Out-Null
    Copy-Item -LiteralPath $scriptPath -Destination $targetScript -Force
  }
  $stub = @(
    "@echo off",
    "setlocal",
    "powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File `"%~dp0Gufo-Setup.ps1`" %*",
    "set `"GUFO_EXIT=%errorlevel%`"",
    "if `"%GUFO_EXIT%`"==`"0`" exit /b 0",
    "if `"%GUFO_EXIT%`"==`"2`" exit /b 2",
    "if `"%~1`"==`"`" pause",
    "exit /b %GUFO_EXIT%"
  ) -join "`r`n"
  $stubPath = Join-Path $target "Gufo-Setup.cmd"
  $stubText = $stub + "`r`n"
  $current = ""
  if (Test-Path -LiteralPath $stubPath) { $current = [IO.File]::ReadAllText($stubPath) }
  if ($current -ne $stubText) {
    [IO.File]::WriteAllText($stubPath, $stubText, [Text.Encoding]::ASCII)
  }
  $shortcut = Get-GufoStartMenuShortcutPath
  if (-not $shortcut) { return "" }
  $parent = Split-Path -Parent $shortcut
  if ($parent -and -not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
  $shell = New-Object -ComObject WScript.Shell
  $link = $shell.CreateShortcut($shortcut)
  $link.TargetPath = Join-Path $target "Gufo-Setup.cmd"
  $link.WorkingDirectory = $target
  $link.Description = "Gufo Setup: update, repair, or uninstall Gufo"
  $link.IconLocation = "$env:SystemRoot\System32\shell32.dll,13"
  $link.Save()
  return $shortcut
}

function Start-GufoLauncher {
  param($State)
  $launcher = Join-Path $State.InstallDir "launch-gui.bat"
  if (-not (Test-Path -LiteralPath $launcher)) { return $false }
  try {
    Start-Process -FilePath $launcher -WorkingDirectory $State.InstallDir | Out-Null
  } catch {
    return $false
  }
  return $true
}

function Open-GufoLogView {
  param($State, [string]$Path)
  $lines = @()
  if (Test-Path -LiteralPath $Path) {
    try {
      $lines = @(Get-Content -LiteralPath $Path -Tail 4000 -Encoding UTF8 -ErrorAction Stop)
    } catch {
      $lines = @("Cannot read $Path`: $($_.Exception.Message)")
    }
  }
  $return = $State.Screen
  if (-not $return -or $return -eq "log") { $return = "menu" }
  $State.LogView = @{ Path = $Path; Lines = $lines; Offset = [Math]::Max(0, $lines.Count - 20); Return = $return }
  $State.Screen = "log"
}

function Show-GufoLogWhileRunning {
  param($State, $Run, [string]$Path)
  # Keep the child running (it writes to a file) while the log is browsable.
  Open-GufoLogView $State $Path
  while ($State.Screen -eq "log" -and -not $Run.Process.HasExited) {
    Invoke-GufoDraw $State
    $key = Read-GufoKey -TimeoutMs 300
    if ($null -ne $key -and $key -ne "") { Invoke-GufoKey $State $key }
  }
  if ($State.Screen -eq "log") { $State.Screen = "run" }
}

function Open-GufoLogFile {
  param([string]$Path)
  if (-not (Test-Path -LiteralPath $Path)) { return }
  try { Start-Process -FilePath "notepad.exe" -ArgumentList @($Path) | Out-Null } catch {
  }
}

function Set-GufoDone {
  param($State, [bool]$Ok, [string]$Title, [string]$Message = "", [string]$LogPath = "", [string]$Version = "", $Details = @(), [string]$Kind = "")
  $State.Done = @{
    Ok = $Ok
    Title = $Title
    Message = $Message
    LogPath = $LogPath
    Version = $Version
    Details = @($Details)
    Kind = $Kind
  }
  $State.Screen = "done"
  $State.MenuItems = @(Get-GufoDoneItems $State)
  $State.MenuIndex = 0
}

function Get-GufoDoneItems {
  param($State)
  $items = New-Object System.Collections.Generic.List[object]
  if ($State.Done.Ok) {
    if ($State.Checkout.EngineExists) {
      $items.Add(@{ Key = "launch"; Label = "Launch launcher"; Hint = "open http://127.0.0.1:8090" })
    }
    if ($State.Checkout.Valid) {
      $items.Add(@{ Key = "shortcut"; Label = "Desktop shortcut"; Hint = "create or refresh Gufo.lnk" })
      $items.Add(@{ Key = "folder"; Label = "Open install folder"; Hint = $State.InstallDir })
    }
  } else {
    $items.Add(@{ Key = "retry"; Label = "Retry"; Hint = "run the same step again" })
    if ($State.Done.LogPath) {
      $items.Add(@{ Key = "log"; Label = "Open log"; Hint = "read the full output" })
    }
  }
  $items.Add(@{ Key = "menu"; Label = "Back to menu"; Hint = "" })
  $items.Add(@{ Key = "quit"; Label = "Quit"; Hint = "" })
  return $items.ToArray()
}

function Complete-GufoRun {
  param($State, $Result, [string]$SuccessTitle, [string]$SuccessMessage, [string]$Kind)
  Update-GufoCheckout $State
  Save-GufoOptions $State
  $version = ""
  if ($State.Checkout.EngineExists) { $version = Get-GufoEngineVersion $State.Checkout.Engine }
  $ok = [bool]$Result.Ok
  $title = $SuccessTitle
  $message = $SuccessMessage
  if (-not $ok) {
    if ($Result.Cancelled) {
      $title = "Stopped"
      $message = "The build was stopped. Completed downloads and build steps are reused when you retry."
    } else {
      $title = "Setup stopped"
      $message = [string]$Result.Message
    }
  }
  Set-GufoDone -State $State -Ok $ok -Title $title -Message $message -LogPath $Result.Log -Version $version -Details $Result.Details -Kind $Kind
}

# ------------------------------------------------------------- interface ---

function Set-GufoScreen {
  param($State, [string]$Screen)
  $State.Screen = $Screen
  $State.Edit = $null
  $State.MenuIndex = 0
  if ($Screen -eq "menu") { Update-GufoMenu $State }
}

function Invoke-GufoMenuAction {
  param($State)
  Update-GufoMenu $State
  $item = $State.MenuItems[$State.MenuIndex]
  if (-not $item) { return }
  switch ($item.Key) {
    "quit" { $State.Quit = $true }
    "advanced" { Open-GufoAdvanced $State "menu" }
    "install" { Start-GufoPrepare $State }
    "update" { Start-GufoUpdateAction $State }
    "repair" { Start-GufoRunSetupAction $State "repair" }
    "uninstall" { Start-GufoUninstallAction $State }
    "uselauncher" {
      $dir = $State.LauncherDir
      Set-GufoInstallDir $State $dir
      Save-GufoOptions $State
      Set-GufoNotice $State "Install folder set to $dir."
    }
  }
}

function Start-GufoPrepare {
  param($State)
  if ($State.Machine -and $State.Machine.Problem) {
    Set-GufoDone -State $State -Ok $false -Title "This PC is not supported" -Message $State.Machine.Problem -Kind "prepare"
    return
  }
  $errorText = Test-GufoOptions $State
  if ($errorText) {
    Set-GufoNotice $State $errorText
    return
  }
  $fetch = Invoke-GufoFetch $State
  if ($fetch.QuitAfter) { $State.Quit = $true; return }
  if (-not $fetch.Ok) {
    Set-GufoDone -State $State -Ok $false -Title "Could not fetch the source" -Message $fetch.Message -LogPath $fetch.Log -Kind "prepare"
    return
  }
  Update-GufoCheckout $State
  $plan = Invoke-GufoPlan $State
  if ($plan.QuitAfter) { $State.Quit = $true; return }
  if (-not $plan.Ok) {
    Set-GufoDone -State $State -Ok $false -Title "Could not read the setup plan" -Message $plan.Message -LogPath $plan.Log -Kind "prepare"
    return
  }
  Set-GufoScreen $State "review"
}

function Start-GufoRunSetupAction {
  param($State, [string]$Kind)
  if ($Kind -eq "repair" -and -not $State.Checkout.Valid) {
    Set-GufoDone -State $State -Ok $false -Title "No checkout to repair" -Message "Install Gufo first, or choose a different install folder in Advanced." -Kind $Kind
    return
  }
  $result = Invoke-GufoSetupRun -State $State -Kind $Kind
  if ($result.QuitAfter) { $State.Quit = $true; return }
  Complete-GufoRun -State $State -Result $result -SuccessTitle "Gufo is ready" -SuccessMessage "The engine was built and verified for this PC." -Kind $Kind
}

function Start-GufoUpdateAction {
  param($State)
  if (-not $State.Checkout.Valid) {
    Set-GufoDone -State $State -Ok $false -Title "No checkout to update" -Message "Install Gufo first, or choose a different install folder in Advanced." -Kind "update"
    return
  }
  $result = Invoke-GufoUpdateRun $State
  if ($result.QuitAfter) { $State.Quit = $true; return }
  Complete-GufoRun -State $State -Result $result -SuccessTitle "Gufo is up to date" -SuccessMessage "windows-main was pulled and the engine was rebuilt." -Kind "update"
}

function Start-GufoUninstallAction {
  param($State)
  if (Get-GufoEngineRunning $State.InstallDir) {
    Set-GufoDone -State $State -Ok $false -Title "Gufo is running" -Message "Stop the engine in the launcher, then open Uninstall again." -Kind "uninstall"
    return
  }
  $State.Uninstall = @{
    Items = @(Get-GufoUninstallItems $State)
    Index = 0
    Confirm = ""
  }
  $State.Screen = "uninstall"
  $State.MenuIndex = 0
}

function Open-GufoAdvanced {
  param($State, [string]$From)
  $State.AdvancedReturn = $From
  Set-GufoScreen $State "advanced"
}

function Open-GufoInstallEdit {
  param($State)
  Open-GufoAdvanced $State "menu"
  $State.AdvancedIndex = 0
  $State.Edit = @{ Key = "install"; Buffer = [string]$State.InstallDir }
}

function Get-GufoPlanKey {
  param($State)
  return "$($State.InstallDir)|$($State.Rocm)|$($State.Vcpkg)"
}

function Close-GufoAdvanced {
  param($State)
  Save-GufoOptions $State
  if ($State.AdvancedReturn -ne "review" -or -not $State.Plan) {
    Set-GufoScreen $State "menu"
    return
  }
  if ((Get-GufoPlanKey $State) -eq $State.PlanKey) {
    Set-GufoScreen $State "review"
    return
  }
  # The folder or tool paths changed, so the plan on screen no longer applies.
  $abandoned = $State.FetchedDir
  $State.Plan = $null
  $State.FetchedDir = ""
  if ($abandoned -and $abandoned -ne $State.InstallDir -and (Test-GufoSourceFolder $abandoned) -and
    -not (Get-GufoCheckoutWarning $abandoned) -and -not (Get-GufoModelWarning $abandoned)) {
    # Only the clone this run made, and only while nothing in it has changed.
    try { Remove-GufoPath $abandoned } catch {
    }
  }
  Set-GufoScreen $State "menu"
  Start-GufoPrepare $State
}

function Invoke-GufoReviewAction {
  param($State)
  $items = @(
    @{ Key = "start"; Label = "" },
    @{ Key = "advanced"; Label = "" },
    @{ Key = "back"; Label = "" }
  )
  $item = $items[$State.MenuIndex]
  if (-not $item) { return }
  switch ($item.Key) {
    "start" { Start-GufoRunSetupAction $State "install" }
    "advanced" { Open-GufoAdvanced $State "review" }
    "back" { Set-GufoScreen $State "menu" }
  }
}

function Invoke-GufoDoneAction {
  param($State)
  $item = $State.MenuItems[$State.MenuIndex]
  if (-not $item) { return }
  switch ($item.Key) {
    "launch" {
      if (Start-GufoLauncher $State) {
        Set-GufoNotice $State "The launcher is starting in a new window."
      } else {
        Set-GufoNotice $State "launch-gui.bat is missing from the checkout."
      }
    }
    "shortcut" {
      try {
        $path = New-GufoShortcut $State
        Set-GufoNotice $State "Shortcut created: $path"
      } catch {
        Set-GufoNotice $State "Shortcut failed: $($_.Exception.Message)"
      }
    }
    "folder" {
      if (Test-Path -LiteralPath $State.InstallDir) {
        try { Start-Process -FilePath "explorer.exe" -ArgumentList @($State.InstallDir) | Out-Null } catch {
        }
      }
    }
    "log" { Open-GufoLogView $State $State.Done.LogPath }
    "retry" {
      switch ($State.Done.Kind) {
        "update" { Start-GufoUpdateAction $State }
        "repair" { Start-GufoRunSetupAction $State "repair" }
        "prepare" { Start-GufoPrepare $State }
        "uninstall" { Start-GufoUninstallAction $State }
        default { Start-GufoRunSetupAction $State "install" }
      }
    }
    "menu" { Set-GufoScreen $State "menu" }
    "quit" { $State.Quit = $true }
  }
}

function Invoke-GufoAdvancedAction {
  param($State)
  $fields = @(Get-GufoAdvancedFields $State)
  $field = $fields[$State.AdvancedIndex]
  if (-not $field) { return }
  if ($field.Key -eq "shortcut") {
    $State.Shortcut = -not $State.Shortcut
    Save-GufoOptions $State
    return
  }
  $buffer = [string]$field.Value
  if ($field.Key -eq "jobs") { $buffer = "" }
  if ($field.Key -eq "rocm") { $buffer = $State.Rocm }
  if ($field.Key -eq "vcpkg") { $buffer = $State.Vcpkg }
  $State.Edit = @{ Key = $field.Key; Buffer = $buffer }
}

function Commit-GufoEdit {
  param($State)
  $edit = $State.Edit
  if (-not $edit) { return }
  $value = ([string]$edit.Buffer).Trim()
  switch ($edit.Key) {
    "install" {
      $value = $value.Trim([char]34)
      if (-not $value) { Set-GufoNotice $State "Enter a folder."; return }
      $errorText = Test-GufoInstallDir $value
      if ($errorText) { Set-GufoNotice $State $errorText; return }
      Set-GufoInstallDir $State $value
    }
    "jobs" {
      if (-not $value) { $State.Edit = $null; return }
      $parsed = 0
      if (-not [int]::TryParse($value, [ref]$parsed) -or $parsed -lt 1 -or $parsed -gt 64) {
        Set-GufoNotice $State "Use 1 to 64 build jobs."
        return
      }
      $State.Jobs = $parsed
    }
    "rocm" {
      if ($value -and -not (Test-Path -LiteralPath $value -PathType Container)) {
        Set-GufoNotice $State "That GPU runtime folder does not exist."
        return
      }
      $State.Rocm = $value
    }
    "vcpkg" {
      if ($value -and -not (Test-Path -LiteralPath (Join-Path $value "bootstrap-vcpkg.bat"))) {
        Set-GufoNotice $State "That folder has no bootstrap-vcpkg.bat."
        return
      }
      $State.Vcpkg = $value
    }
  }
  $State.Edit = $null
  Save-GufoOptions $State
}

function Invoke-GufoKey {
  param($State, [string]$Key)
  if ($State.Screen -eq "done" -and -not $State.Done) { Set-GufoScreen $State "menu" }
  if ($State.Screen -eq "uninstall" -and -not $State.Uninstall) { Set-GufoScreen $State "menu" }
  if ($State.Screen -eq "run" -and -not $State.Run) { Set-GufoScreen $State "menu" }
  if ($State.Small) {
    if ($Key -eq "Char:q" -or $Key -eq "Esc" -or $Key -eq "CtrlC") { $State.Quit = $true }
    return
  }
  switch ($State.Screen) {
    "menu" {
      switch ($Key) {
        "Up" { $State.MenuIndex = [Math]::Max(0, $State.MenuIndex - 1) }
        "Down" { $State.MenuIndex = [Math]::Min($State.MenuItems.Count - 1, $State.MenuIndex + 1) }
        "Enter" { Invoke-GufoMenuAction $State }
        "Char:a" { Open-GufoAdvanced $State "menu" }
        "Char:f" { Open-GufoInstallEdit $State }
        "Char:r" { Update-GufoCheckout $State; Set-GufoNotice $State "Rescanned this PC." }
        "Char:?" { Set-GufoScreen $State "help" }
        "Char:q" { $State.Quit = $true }
        "CtrlC" { $State.Quit = $true }
      }
    }
    "advanced" {
      if ($State.Edit) {
        if ($Key -eq "Enter") { Commit-GufoEdit $State; return }
        if ($Key -eq "Esc") { $State.Edit = $null; return }
        if ($Key -eq "Backspace") {
          if ($State.Edit.Buffer.Length -gt 0) { $State.Edit.Buffer = $State.Edit.Buffer.Substring(0, $State.Edit.Buffer.Length - 1) }
          return
        }
        if ($Key -eq "Space") { $State.Edit.Buffer += " "; return }
        if ($Key.StartsWith("Char:")) { $State.Edit.Buffer += $Key.Substring(5); return }
        return
      }
      switch ($Key) {
        "Up" { $State.AdvancedIndex = [Math]::Max(0, $State.AdvancedIndex - 1) }
        "Down" { $State.AdvancedIndex = [Math]::Min((@(Get-GufoAdvancedFields $State).Count - 1), $State.AdvancedIndex + 1) }
        "Enter" { Invoke-GufoAdvancedAction $State }
        "Space" { Invoke-GufoAdvancedAction $State }
        "Esc" { Close-GufoAdvanced $State }
      }
    }
    "review" {
      switch ($Key) {
        "Up" { $State.MenuIndex = [Math]::Max(0, $State.MenuIndex - 1) }
        "Down" { $State.MenuIndex = [Math]::Min(2, $State.MenuIndex + 1) }
        "Enter" { Invoke-GufoReviewAction $State }
        "Esc" { Set-GufoScreen $State "menu" }
        "Char:a" { Open-GufoAdvanced $State "review" }
      }
    }
    "done" {
      switch ($Key) {
        "Up" { $State.MenuIndex = [Math]::Max(0, $State.MenuIndex - 1) }
        "Down" { $State.MenuIndex = [Math]::Min($State.MenuItems.Count - 1, $State.MenuIndex + 1) }
        "Enter" { Invoke-GufoDoneAction $State }
        "Esc" { Set-GufoScreen $State "menu" }
        "Char:q" { $State.Quit = $true }
        "CtrlC" { $State.Quit = $true }
      }
    }
    "uninstall" {
      if ($Key -eq "Esc") { Set-GufoScreen $State "menu"; return }
      if ($Key -eq "Up") { $State.Uninstall.Index = [Math]::Max(0, $State.Uninstall.Index - 1); return }
      if ($Key -eq "Down") { $State.Uninstall.Index = [Math]::Min([Math]::Max(0, $State.Uninstall.Items.Count - 1), $State.Uninstall.Index + 1); return }
      if ($Key -eq "PgUp") { $State.Uninstall.Offset = [Math]::Max(0, [int]$State.Uninstall.Offset - 5); return }
      if ($Key -eq "PgDn") { $State.Uninstall.Offset = [int]$State.Uninstall.Offset + 5; return }
      if ($Key -eq "Space") {
        $item = $State.Uninstall.Items[$State.Uninstall.Index]
        if ($item) {
          if ($item.Blocked) { Set-GufoNotice $State $item.Warning; return }
          $item.Checked = -not $item.Checked
        }
        return
      }
      if ($Key -eq "Backspace") {
        if ($State.Uninstall.Confirm.Length -gt 0) { $State.Uninstall.Confirm = $State.Uninstall.Confirm.Substring(0, $State.Uninstall.Confirm.Length - 1) }
        return
      }
      if ($Key.StartsWith("Char:")) {
        $State.Uninstall.Confirm += $Key.Substring(5)
        return
      }
      if ($Key -eq "Enter") {
        if ($State.Uninstall.Confirm -ne "uninstall") { Set-GufoNotice $State "Type uninstall to confirm."; return }
        $checked = @($State.Uninstall.Items | Where-Object { $_.Checked })
        if (-not $checked.Count) { Set-GufoNotice $State "Nothing is selected."; return }
        if (Get-GufoEngineRunning $State.InstallDir) { Set-GufoNotice $State "Gufo is running. Stop it in the launcher first."; return }
        $result = Invoke-GufoRemove -State $State -Items $checked
        Set-GufoDone -State $State -Ok $result.Ok -Title $(if ($result.Ok) { "Gufo was removed" } else { "Some items were not removed" }) -Message $result.Message -Details $result.Details -Kind "uninstall"
        return
      }
    }
    "log" {
      switch ($Key) {
        "Up" { $State.LogView.Offset = [Math]::Max(0, $State.LogView.Offset - 1) }
        "Down" { $State.LogView.Offset = [Math]::Min([Math]::Max(0, $State.LogView.Lines.Count - 1), $State.LogView.Offset + 1) }
        "PgUp" { $State.LogView.Offset = [Math]::Max(0, $State.LogView.Offset - 20) }
        "PgDn" { $State.LogView.Offset = [Math]::Min([Math]::Max(0, $State.LogView.Lines.Count - 1), $State.LogView.Offset + 20) }
        "Home" { $State.LogView.Offset = 0 }
        "End" { $State.LogView.Offset = [Math]::Max(0, $State.LogView.Lines.Count - 1) }
        "Esc" { $State.Screen = $(if ($State.LogView.Return) { $State.LogView.Return } else { "menu" }) }
        "Enter" { $State.Screen = $(if ($State.LogView.Return) { $State.LogView.Return } else { "menu" }) }
      }
    }
    "help" { $State.Screen = "menu" }
  }
}

function Invoke-GufoApp {
  param($State)
  Initialize-GufoConsole
  Enter-GufoFullScreen
  try {
    Set-GufoScreen $State "splash"
    Invoke-GufoDraw $State
    $State.Machine = Get-GufoMachine
    Update-GufoCheckout $State
    Set-GufoScreen $State "menu"
    $noticeShown = $false
    while (-not $State.Quit) {
      Invoke-GufoDraw $State
      $noticeShown = Test-GufoNoticeActive $State
      $key = $null
      while (-not $State.Quit) {
        # Wake up to redraw when the window is resized or a notice expires.
        $key = Read-GufoKey -TimeoutMs 300
        if ($null -ne $key) { break }
        $viewport = Get-GufoViewport
        if ($viewport.Width -ne $State.ViewWidth -or $viewport.Height -ne $State.ViewHeight) { break }
        if ($noticeShown -and -not (Test-GufoNoticeActive $State)) { break }
      }
      if ($null -eq $key -or $key -eq "") { continue }
      Invoke-GufoKey $State $key
    }
  } finally {
    Exit-GufoFullScreen
  }
  return 0
}

# ------------------------------------------------------------ plain mode ---

function Format-GufoPlainPlan {
  param($Plan)
  $lines = New-Object System.Collections.Generic.List[string]
  $lines.Add("  Install to : $($Plan.root)")
  $packages = @($Plan.packages)
  foreach ($package in $packages) {
    if ($package.action -eq "reuse") {
      $lines.Add("  Reuse      : $($package.name) $($package.version) - $($package.path)")
    } else {
      $lines.Add("  Install    : $($package.name) $($package.version)")
    }
  }
  if ($Plan.rock.action -eq "reuse") {
    $lines.Add("  GPU runtime: reuse $($Plan.rock.path)")
  } else {
    $lines.Add("  GPU runtime: download TheRock $($Plan.rock.version) for gfx1151")
  }
  if ($Plan.vcpkg.action -eq "reuse") {
    $lines.Add("  vcpkg      : reuse $($Plan.vcpkg.path)")
  } else {
    $lines.Add("  vcpkg      : prepare the pinned checkout")
  }
  foreach ($entry in @($Plan.space)) {
    $lines.Add("  Free space : $($entry.freeGiB) GiB on $($entry.root)")
  }
  $lines.Add("  Build      : gufo.exe with $($Plan.jobs) parallel jobs")
  return ($lines -join "`n")
}

function Invoke-GufoPlain {
  param($State)
  Write-Host ""
  Write-Host "Gufo Setup $($State.Tag) - Windows source installer"
  Write-Host "Folder   : $($State.InstallDir) ($(Get-GufoInstallSourceText $State.InstallSource))"
  if ($State.InstallNote) { Write-Host "Note     : $($State.InstallNote)" -ForegroundColor Yellow }
  if (Test-GufoLauncherElsewhere $State) {
    Write-Host "Launcher : starts the engine in $($State.LauncherDir); pass -InstallDir to manage it" -ForegroundColor Yellow
  }
  Write-Host "Detected : $($State.Machine.Cpu)"
  Write-Host "Windows  : $($State.Machine.Os) ($($State.Machine.Build)), $($State.Machine.RamGiB) GiB RAM"
  if ($State.Checkout.Valid) {
    $lines = "checkout $($State.Checkout.Branch) @ $($State.Checkout.Head)"
    if ($State.Checkout.EngineExists) { $lines += ", engine built $(Format-GufoAge $State.Checkout.Built)" } else { $lines += ", engine not built" }
    Write-Host "Checkout : $lines"
  } else {
    Write-Host "Checkout : none at $($State.InstallDir)"
  }
  if ($State.Machine.Problem) {
    Write-Host "Problem  : $($State.Machine.Problem)" -ForegroundColor Red
    if ($Action) { return 1 }
  }
  $choice = $Action
  if (-not $choice) {
    Write-Host ""
    Write-Host "1) Install"
    Write-Host "2) Update (existing checkout)"
    Write-Host "3) Install/Repair (existing checkout)"
    Write-Host "4) Uninstall"
    Write-Host "5) Quit"
    $answer = Read-Host "Choose [1-5]"
    switch ($answer) {
      "1" { $choice = "install" }
      "2" { $choice = "update" }
      "3" { $choice = "repair" }
      "4" { $choice = "uninstall" }
      default { Write-Host "Cancelled."; return 2 }
    }
  }
  if ($choice -eq "install" -or $choice -eq "repair") {
    if ($State.Machine.Problem) { Write-Host "Unsupported PC: $($State.Machine.Problem)" -ForegroundColor Red; return 1 }
    $errorText = Test-GufoOptions $State
    if ($errorText) { Write-Host $errorText -ForegroundColor Red; return 1 }
    if ($choice -eq "install") {
      $fetch = Invoke-GufoFetch $State
      if (-not $fetch.Ok) { Write-Host $fetch.Message -ForegroundColor Red; return 1 }
      $plan = Invoke-GufoPlan $State
      if (-not $plan.Ok) { Write-Host $plan.Message -ForegroundColor Red; return 1 }
      Write-Host ""
      Write-Host (Format-GufoPlainPlan $plan.Plan)
      if (-not $Yes) {
        $answer = Read-Host "Continue with this plan? [y/N]"
        if ($answer -notmatch "^(y|yes)$") { Write-Host "Cancelled. Nothing was installed."; return 2 }
      }
      $result = Invoke-GufoSetupRun -State $State -Kind "install"
    } else {
      if (-not $State.Checkout.Valid) { Write-Host "No checkout to repair. Install Gufo first." -ForegroundColor Red; return 1 }
      $result = Invoke-GufoSetupRun -State $State -Kind "repair"
    }
    if (-not $result.Ok) {
      if ($result.Cancelled) { Write-Host "Stopped."; return 2 }
      Write-Host "Setup failed." -ForegroundColor Red
      if ($result.Message) { Write-Host $result.Message -ForegroundColor Red }
      if ($result.Log) { Write-Host "Log: $($result.Log)" }
      return 1
    }
    $version = ""
    if ($State.Checkout.EngineExists) { $version = Get-GufoEngineVersion $State.Checkout.Engine }
    Write-Host ""
    Write-Host "Gufo is ready. $version" -ForegroundColor Green
    Write-Host "Engine: $($State.Checkout.Engine)"
    if ($State.Shortcut) {
      try { Write-Host "Shortcut: $(New-GufoShortcut $State)" } catch { Write-Host "Shortcut not created: $($_.Exception.Message)" }
    }
    try {
      $entry = Install-GufoSetupEntry $State
      if ($entry) { Write-Host "Setup shortcut: $entry" }
    } catch {
      Write-Host "Setup shortcut not created: $($_.Exception.Message)"
    }
    Save-GufoOptions $State
    Write-Host "Launch with launch-gui.bat, or use the desktop shortcut."
    return 0
  }
  if ($choice -eq "update") {
    if (-not $State.Checkout.Valid) { Write-Host "No checkout to update. Install Gufo first." -ForegroundColor Red; return 1 }
    $result = Invoke-GufoUpdateRun $State
    if (-not $result.Ok) {
      if ($result.Cancelled) { Write-Host "Stopped."; return 2 }
      Write-Host "Update failed." -ForegroundColor Red
      if ($result.Message) { Write-Host $result.Message -ForegroundColor Red }
      if ($result.Log) { Write-Host "Log: $($result.Log)" }
      return 1
    }
    Write-Host "Update complete: $($State.Checkout.Engine)" -ForegroundColor Green
    return 0
  }
  if ($choice -eq "uninstall") {
    $items = @(Get-GufoUninstallItems $State)
    if (-not $items.Count) { Write-Host "Nothing to remove."; return 0 }
    Write-Host ""
    Write-Host "Remove:"
    foreach ($item in $items) {
      foreach ($file in $item.Files) { Write-Host "  - $($item.Label): $file" }
      if ($item.Warning) { Write-Host "    Skipped: $($item.Warning) Remove it by hand if you are sure." -ForegroundColor Yellow }
    }
    Write-Host "Kept: Git, Visual Studio Build Tools, CMake, Ninja, Python, the AMD driver, and your model files."
    if (-not $Yes) {
      $answer = Read-Host "Type uninstall to confirm"
      if ($answer -ne "uninstall") { Write-Host "Cancelled."; return 2 }
    }
    if (Get-GufoEngineRunning $State.InstallDir) { Write-Host "Gufo is running. Stop it first." -ForegroundColor Red; return 1 }
    $result = Invoke-GufoRemove -State $State -Items $items
    foreach ($detail in $result.Details) { Write-Host $detail }
    if (-not $result.Ok) { Write-Host $result.Message -ForegroundColor Red; return 1 }
    Write-Host "Gufo was removed." -ForegroundColor Green
    return 0
  }
  Write-Host "Unknown action: $choice" -ForegroundColor Red
  return 1
}

# ------------------------------------------------------------------- main ---

function Invoke-GufoInstaller {
  $interactive = -not $Plain -and -not $Action -and -not [Console]::IsInputRedirected -and -not [Console]::IsOutputRedirected
  $script:GufoInteractive = $interactive
  if ($interactive) {
    $script:GufoVt = Enable-GufoVirtualTerminal
    if (-not $script:GufoVt) {
      # Without virtual-terminal support the drawn screens would be garbage; use line mode.
      $interactive = $false
      $script:GufoInteractive = $false
    }
  }
  $scheme = $null
  if ($interactive) {
    $mode = Resolve-GufoColorMode -Requested $ColorMode -Vt $script:GufoVt
    $scheme = New-GufoScheme -Mode $mode -Ascii:($AsciiGlyphs -or -not $script:GufoVt)
  } else {
    $scheme = New-GufoScheme -Mode "None"
  }
  $state = New-GufoState -Scheme $scheme -InstallDir $InstallDir -Jobs $Jobs -Rocm $Rocm -Vcpkg $Vcpkg -Interactive $interactive
  if ($NoShortcut) { $state.Shortcut = $false }
  $state.AutoConfirm = $Yes
  if ($interactive) {
    return (Invoke-GufoApp $state)
  }
  $state.Machine = Get-GufoMachine
  $state.Checkout = Get-GufoCheckoutState $state.InstallDir
  return (Invoke-GufoPlain $state)
}

if ($MyInvocation.InvocationName -ne ".") {
  # Stray pipeline output must never turn the exit code into an array.
  exit ([int](@(Invoke-GufoInstaller) | Select-Object -Last 1))
}
