# Builds the Windows app and packs it into dist\FreeNotes-Setup-<version>.exe
# Needs: Flutter, Visual Studio Build Tools (C++ + ATL), Inno Setup 6.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Set-Location $root

$version = (Select-String -Path pubspec.yaml -Pattern '^version:\s*([0-9.]+)').Matches[0].Groups[1].Value
$flutter = (Get-Command flutter -ErrorAction SilentlyContinue).Source
if (-not $flutter) { $flutter = "$HOME\flutter\bin\flutter.bat" }

& $flutter build windows --release
if ($LASTEXITCODE) { throw 'flutter build failed' }

# Ship the Microsoft C++ runtime next to the exe, so the app also runs on PCs without it.
$crt = Get-ChildItem "${env:ProgramFiles(x86)}\Microsoft Visual Studio\2022\*\VC\Redist\MSVC\*\x64\Microsoft.VC143.CRT" -Directory |
  Sort-Object FullName -Descending | Select-Object -First 1
if (-not $crt) { throw 'C++ runtime not found (install Visual Studio Build Tools with the C++ workload)' }
Copy-Item "$($crt.FullName)\msvcp140.dll", "$($crt.FullName)\vcruntime140.dll", "$($crt.FullName)\vcruntime140_1.dll" `
  "build\windows\x64\runner\Release\" -Force

$iscc = @("$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe", "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe") |
  Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $iscc) { throw 'Inno Setup 6 not found (winget install JRSoftware.InnoSetup)' }
& $iscc "/DAppVersion=$version" installer\freenotes.iss
if ($LASTEXITCODE) { throw 'installer build failed' }
Write-Host "Done: dist\FreeNotes-Setup-$version.exe"
