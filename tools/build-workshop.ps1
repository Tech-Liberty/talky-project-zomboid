<#
.SYNOPSIS
  Assembles the Steam Workshop folder of Talky.

.DESCRIPTION
  Builds <OutDir> (default: %USERPROFILE%\Zomboid\Workshop\Talky) with the layout Project
  Zomboid expects for an upload:

    workshop.txt
    preview.png                       exactly 256x256, under 1000 KB
    Contents\mods\Talky\42\...        the mod (mod.info, poster.png, media\lua\...)
    Contents\mods\Talky\common\

  Then, in the game: main menu > Workshop > Create and update items > Talky.

  The "id=" line the game writes into workshop.txt after the first upload is kept, so the
  next upload updates the same Workshop item. The build stops if the mod contains a file
  type the Workshop refuses (.exe .dll .bat .app .dylib .sh .so .zip). The bridge is not
  part of the Workshop item: it ships in the GitHub release (tools\build-release.ps1).

.PARAMETER OutDir
  Where to assemble the item. Use another folder to inspect the result without touching
  the game's Workshop folder.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File tools\build-workshop.ps1
  powershell -ExecutionPolicy Bypass -File tools\build-workshop.ps1 -OutDir "$env:TEMP\talky-workshop"
#>
param(
    [string]$OutDir = (Join-Path $env:USERPROFILE 'Zomboid\Workshop\Talky')
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

$root = Split-Path -Parent $PSScriptRoot
$modSrc = Join-Path $root 'mod\Talky'
$packaging = Join-Path $root 'packaging\workshop'
$forbidden = @('.exe', '.dll', '.bat', '.app', '.dylib', '.sh', '.so', '.zip')

function Fail([string]$message) {
    Write-Host "ERROR: $message" -ForegroundColor Red
    exit 1
}

# ---------------------------------------------------------------- checks on the sources

foreach ($p in @((Join-Path $modSrc '42\mod.info'), (Join-Path $modSrc '42\poster.png'), (Join-Path $packaging 'workshop.txt'), (Join-Path $packaging 'preview.png'))) {
    if (-not (Test-Path $p)) { Fail "missing file: $p" }
}

$bad = Get-ChildItem -Recurse -File $modSrc | Where-Object { $forbidden -contains $_.Extension.ToLowerInvariant() }
if ($bad) {
    Fail ("the Workshop refuses these files: " + (($bad | ForEach-Object { $_.FullName }) -join ', '))
}

$previewPath = Join-Path $packaging 'preview.png'
$preview = Get-Item $previewPath
if ($preview.Length -ge 1000KB) { Fail "preview.png is $($preview.Length) bytes, the Workshop accepts less than 1000 KB" }
$img = [System.Drawing.Image]::FromFile($preview.FullName)
try {
    if ($img.Width -ne 256 -or $img.Height -ne 256) { Fail "preview.png is $($img.Width)x$($img.Height), the Workshop wants exactly 256x256" }
    if ($img.RawFormat.Guid -ne [System.Drawing.Imaging.ImageFormat]::Png.Guid) { Fail 'preview.png is not a PNG file' }
} finally {
    $img.Dispose()
}

$modInfo = Get-Content (Join-Path $modSrc '42\mod.info') -Encoding UTF8
foreach ($key in @('name', 'id', 'description', 'poster')) {
    if (-not ($modInfo | Where-Object { $_ -match "^$key=" })) { Fail "mod.info has no '$key=' line" }
}
$version = ($modInfo | Where-Object { $_ -match '^modversion=' } | Select-Object -First 1) -replace '^modversion=', ''

# ---------------------------------------------------------------- assemble

$OutDir = [System.IO.Path]::GetFullPath($OutDir)
New-Item -ItemType Directory -Force $OutDir | Out-Null

# Keep the Workshop id written by the game after the first upload
$existingId = $null
$outTxt = Join-Path $OutDir 'workshop.txt'
if (Test-Path $outTxt) {
    $existingId = Get-Content $outTxt -Encoding UTF8 | Where-Object { $_ -match '^id=\d+' } | Select-Object -First 1
}

$contents = Join-Path $OutDir 'Contents'
if (Test-Path $contents) { Remove-Item -Recurse -Force $contents }
$modOut = Join-Path $contents 'mods\Talky'
New-Item -ItemType Directory -Force $modOut | Out-Null
Copy-Item -Recurse (Join-Path $modSrc '42') (Join-Path $modOut '42')
if (Test-Path (Join-Path $modSrc 'common')) {
    Copy-Item -Recurse (Join-Path $modSrc 'common') (Join-Path $modOut 'common')
} else {
    New-Item -ItemType Directory -Force (Join-Path $modOut 'common') | Out-Null
}

Copy-Item $previewPath (Join-Path $OutDir 'preview.png') -Force

$lines = Get-Content (Join-Path $packaging 'workshop.txt') -Encoding UTF8 | Where-Object { $_ -notmatch '^id=' }
if ($existingId) {
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($l in $lines) {
        $out.Add($l)
        if ($l -match '^version=') { $out.Add($existingId) }
    }
    $lines = $out
}
# UTF-8 without BOM, CRLF like the game's template
$utf8 = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($outTxt, (($lines -join "`r`n") + "`r`n"), $utf8)

# ---------------------------------------------------------------- checks on the result

$top = Get-ChildItem $contents
if (($top | Where-Object { $_.Name -ne 'mods' -or -not $_.PSIsContainer }).Count -gt 0) { Fail 'Contents may only hold the "mods" folder' }
if ((Get-ChildItem (Join-Path $contents 'mods') -File).Count -gt 0) { Fail 'Contents\mods may only hold folders' }
$bad = Get-ChildItem -Recurse -File $OutDir | Where-Object { $forbidden -contains $_.Extension.ToLowerInvariant() }
if ($bad) { Fail ("forbidden files in the result: " + (($bad | ForEach-Object { $_.FullName }) -join ', ')) }

$files = Get-ChildItem -Recurse -File $OutDir
$size = ($files | Measure-Object -Property Length -Sum).Sum
Write-Host "Talky $version assembled in $OutDir"
Write-Host ("  {0} files, {1:N0} KB" -f $files.Count, ($size / 1KB))
if ($existingId) { Write-Host "  kept $existingId (updates the existing Workshop item)" } else { Write-Host '  no Workshop id yet: the game will create a new item on the first upload' }
Write-Host 'Next: Project Zomboid > Workshop > Create and update items > Talky.'
