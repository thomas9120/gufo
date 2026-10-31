@echo off
setlocal
rem Gufo Windows setup launcher. Release builds fill in the three values below.
set "GUFO_REPO=@REPO@"
set "GUFO_TAG=@TAG@"
set "GUFO_SHA=@PS1SHA256@"
set "PS1=%~dp0Gufo-Setup.ps1"
if exist "%PS1%" goto verify
set "PS1=%~dp0tools\installer\Gufo-Setup.ps1"
if exist "%PS1%" goto verify
if "%GUFO_TAG:~0,1%"=="@" goto unprepared
set "PS1=%TEMP%\Gufo-Setup-%GUFO_TAG%.ps1"
echo Downloading the Gufo installer...
set "GUFO_PS1=%PS1%"
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -Command ^
  "$ErrorActionPreference='Stop';" ^
  "$url='https://github.com/' + $env:GUFO_REPO + '/releases/download/' + $env:GUFO_TAG + '/Gufo-Setup.ps1';" ^
  "Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $env:GUFO_PS1"
if errorlevel 1 goto failed
:verify
rem Local checkouts keep the placeholders and need no release checksum.
if "%GUFO_TAG:~0,1%"=="@" goto launch
set "GUFO_PS1=%PS1%"
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -Command ^
  "$ErrorActionPreference='Stop';" ^
  "$hash=(Get-FileHash -LiteralPath $env:GUFO_PS1 -Algorithm SHA256).Hash;" ^
  "if ($hash -ne $env:GUFO_SHA) { Write-Host ('Installer checksum mismatch: ' + $hash); exit 1 }"
if errorlevel 1 goto failed
:launch
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%PS1%" %*
set "GUFO_EXIT=%errorlevel%"
if "%GUFO_EXIT%"=="0" exit /b 0
rem Exit code 2 means the user declined or cancelled; nothing went wrong.
if "%GUFO_EXIT%"=="2" exit /b 2
echo.
echo Gufo Setup stopped. Read the message above, then run this file again.
if "%~1"=="" pause
exit /b %GUFO_EXIT%
:failed
echo.
echo Could not download or verify the installer. Download Gufo-Setup.cmd together
echo with Gufo-Setup.ps1 from the release page and run it again.
if "%~1"=="" pause
exit /b 1
:unprepared
echo.
echo This Gufo-Setup.cmd was not prepared by a release. Keep it next to
echo Gufo-Setup.ps1, or download the release version.
if "%~1"=="" pause
exit /b 1
