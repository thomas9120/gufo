# Render Gufo installer screens as deterministic text for review and Windows CI.
# Example: powershell -File tools/installer/preview.ps1 -Screen menu,review -Width 100 -Height 34
[CmdletBinding()]
param(
  [string]$Screen = "menu,review,run,done,uninstall",
  [ValidateRange(60, 200)][int]$Width = 100,
  [ValidateRange(18, 60)][int]$Height = 34,
  [ValidateSet("None", "Ansi16", "TrueColor")][string]$Mode = "None",
  [switch]$Ascii,
  [string]$OutFile = ""
)
$ErrorActionPreference = "Stop"
. "$PSScriptRoot\Gufo-Setup.ps1"

function New-GufoPreviewState {
  param($Scheme, [int]$Width, [int]$Height)
  $installDir = "C:\Users\you\Gufo"
  $state = @{
    Screen = "menu"
    Width = $Width
    Height = $Height
    Small = $false
    Scheme = $Scheme
    Tag = Get-GufoInstallerTag
    Interactive = $true
    Machine = @{
      Cpu = "AMD Ryzen AI MAX+ 395 w/ Radeon 8060S"
      Os = "Windows 11 Pro"
      Build = 26200
      RamGiB = 121
      Problem = $null
    }
    Checkout = @{
      Dir = $installDir
      Exists = $true
      Valid = $true
      Branch = "windows-main"
      Head = "3394a881"
      Engine = Join-Path $installDir "build\windows-gpu\gufo.exe"
      EngineExists = $true
      Built = (Get-Date).AddHours(-2)
      Remote = $script:GufoRepository
    }
    InstallDir = $installDir
    InstallSource = "saved"
    InstallNote = ""
    SavedInstallDir = $installDir
    LauncherDir = ""
    DepsDir = "C:\Users\you\AppData\Local\Gufo\dependencies"
    SettingsDir = "C:\Users\you\AppData\Local\Gufo"
    Jobs = 8
    Rocm = ""
    Vcpkg = ""
    Shortcut = $true
    MenuIndex = 0
    MenuItems = @()
    AdvancedIndex = 0
    Edit = $null
    Plan = [pscustomobject]@{
      root = $installDir
      jobs = 8
      machine = [pscustomobject]@{ cpu = "AMD Ryzen AI MAX+ 395"; os = "Microsoft Windows 11 Pro"; build = 26200; ramGiB = 121 }
      space = @([pscustomobject]@{ root = "C:\"; freeGiB = 412.4 })
      packages = @(
        [pscustomobject]@{ name = "Git"; wingetId = "Git.Git"; version = "2.55.0.3"; path = "C:\Program Files\Git\cmd\git.exe"; action = "reuse" },
        [pscustomobject]@{ name = "VS"; wingetId = "Microsoft.VisualStudio.BuildTools"; version = "18.8.0"; path = ""; action = "install" },
        [pscustomobject]@{ name = "CMake"; wingetId = "Kitware.CMake"; version = "4.4.0"; path = ""; action = "install" },
        [pscustomobject]@{ name = "Ninja"; wingetId = "Ninja-build.Ninja"; version = "1.13.2"; path = ""; action = "install" },
        [pscustomobject]@{ name = "Python"; wingetId = "Python.Python.3.14"; version = "3.14.6"; path = ""; action = "install" }
      )
      rock = [pscustomobject]@{ version = "10.0.0"; path = ""; action = "download" }
      vcpkg = [pscustomobject]@{ path = ""; action = "prepare" }
      missing = @("VS", "CMake", "Ninja", "Python")
    }
    Run = @{
      Kind = "install"
      Title = "Building Gufo"
      Steps = @("Prepare tools and GPU runtime", "Prepare dependency library", "Compile the engine", "Verify GPU startup", "Finish")
      Keys = @{ tools = 0; deps = 1; compile = 2; verify = 3; finish = 4 }
      Step = 2
      Phase = "Compiling the engine"
      Fraction = 0.63
      Detail = "1,384 of 2,201 targets"
      Tail = New-Object System.Collections.Generic.List[string]
      LogPath = Join-Path $env:LOCALAPPDATA "Gufo\logs\setup-20261021-104512.log"
      Started = New-Object System.Diagnostics.Stopwatch
      ExitCode = $null
      Cancelled = $false
      CancelAt = $null
      QuitAfter = $false
      Process = $null
    }
    Done = $null
    Uninstall = @{
      Items = @(
        @{ Key = "source"; Label = "Source, build, and GUI environment"; Files = @($installDir); Checked = $true },
        @{ Key = "deps"; Label = "Shared GPU runtime and dependency caches"; Files = @("C:\Users\you\AppData\Local\Gufo\dependencies"); Checked = $true },
        @{ Key = "settings"; Label = "Launcher settings, presets, and installer options"; Files = @("C:\Users\you\AppData\Local\Gufo\launcher.json"); Checked = $true },
        @{ Key = "shortcut"; Label = "Desktop shortcut"; Files = @("C:\Users\you\Desktop\Gufo.lnk"); Checked = $false }
      )
      Index = 0
      Confirm = ""
    }
    LogView = @{
      Path = Join-Path $env:LOCALAPPDATA "Gufo\logs\setup-20261021-104512.log"
      Lines = @(
        "Detailed setup log: C:\Users\you\Gufo\build\setup-20261021-104512.log",
        "  Free space on C:\: 412.4 GiB",
        "Installing VS (18.8.0)...",
        "Downloading/verifying TheRock 10.0.0 GPU libraries...",
        "Extracting TheRock. Completed downloads are reused if setup is interrupted.",
        "Preparing vcpkg dependencies...",
        "MSVC 14.44.35207, Windows SDK 10.0.26100.0",
        "Building Gufo. The first build also compiles dependencies; this can take a while...",
        "[1104/2201] Building CXX object src/models/qwen/CMakeFiles/gufo_qwen.dir/forward.cpp.obj",
        "[1105/2201] Building CXX object src/serve/CMakeFiles/gufo_serve.dir/server.cpp.obj",
        "[1106/2201] Linking CXX executable gufo.exe",
        "Checking the built executable and GPU (no model is loaded)...",
        "gufo 2026.10.24",
        "Setup complete. Next time, double-click launch-gui.bat."
      )
      Offset = 0
    }
    Notice = ""
    NoticeAt = [DateTime]::MinValue
    Quit = $false
    AutoConfirm = $false
  }
  $state.Run.Tail.Add("[1089/2201] Building CXX object src/core/CMakeFiles/gufo_core.dir/alloc.cpp.obj")
  $state.Run.Tail.Add("[1104/2201] Building CXX object src/models/qwen/CMakeFiles/gufo_qwen.dir/forward.cpp.obj")
  $state.Run.Tail.Add("[1105/2201] Building CXX object src/serve/CMakeFiles/gufo_serve.dir/server.cpp.obj")
  $state.Run.Tail.Add("[1106/2201] Linking CXX executable gufo.exe")
  Update-GufoMenu $state
  return $state
}

$known = @("all", "splash", "menu", "advanced", "review", "run", "done", "uninstall", "log", "help")
$names = @($Screen -split "," | ForEach-Object { $_.Trim() } | Where-Object { $_ })
foreach ($name in $names) {
  if ($known -notcontains $name) {
    throw "Unknown screen '$name'. Use: $($known -join ', ')"
  }
}
if ($names -contains "all") {
  $names = @("splash", "menu", "advanced", "review", "run", "done", "uninstall", "log", "help")
}
$scheme = New-GufoScheme -Mode $Mode -Ascii:$Ascii
$state = New-GufoPreviewState -Scheme $scheme -Width $Width -Height $Height
$output = New-Object System.Text.StringBuilder
foreach ($name in $names) {
  $state.Screen = $name
  switch ($name) {
    "done" {
      Set-GufoDone -State $state -Ok $true -Title "Gufo is ready" -Message "The engine was built and verified for this PC." -LogPath $state.Run.LogPath -Version "gufo 2026.10.24 (gfx1151)" -Details @("Desktop shortcut: C:\Users\you\Desktop\Gufo.lnk") -Kind "install"
    }
    "review" { $state.MenuIndex = 0 }
    "advanced" { $state.AdvancedIndex = 0 }
  }
  $lines = Get-GufoScreen $state
  $lines = Resize-GufoFrame $lines $Height
  foreach ($line in $lines) { [void]$output.AppendLine($line) }
  [void]$output.AppendLine("")
}
$text = $output.ToString()
if ($OutFile) {
  [IO.File]::WriteAllText($OutFile, $text, (New-Object System.Text.UTF8Encoding($false)))
} else {
  [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
  Write-Output $text
}
