<#
.SYNOPSIS
  Builds the GitHub release archive: dist\Talky-<version>-windows.zip and dist\SHA256SUMS.txt.

.DESCRIPTION
  Archive content (at the root of the zip):
    Talky\            the mod, for a manual install in %USERPROFILE%\Zomboid\mods
    bridge\           bridge.js, lib\, locales\, config.example.json, package.json
                      (never config.json nor bridge-state.json: the bridge creates
                      config.json on its first start)
    start-bridge.cmd, README.md, README.fr.md, LICENSE, CHANGELOG.md

  The version comes from bridge\package.json and must match modversion in mod.info.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File tools\build-release.ps1
#>
param(
    [string]$OutDir = ''
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$root = Split-Path -Parent $PSScriptRoot
if (-not $OutDir) { $OutDir = Join-Path $root 'dist' }
$OutDir = [System.IO.Path]::GetFullPath($OutDir)

function Fail([string]$message) {
    Write-Host "ERROR: $message" -ForegroundColor Red
    exit 1
}

# ---------------------------------------------------------------- version

$pkg = [System.IO.File]::ReadAllText((Join-Path $root 'bridge\package.json'), [System.Text.Encoding]::UTF8) | ConvertFrom-Json
$version = $pkg.version
$modInfo = Get-Content (Join-Path $root 'mod\Talky\42\mod.info') -Encoding UTF8
$modVersion = ($modInfo | Where-Object { $_ -match '^modversion=' } | Select-Object -First 1) -replace '^modversion=', ''
if ($version -ne $modVersion) { Fail "bridge\package.json says $version but mod.info says $modVersion" }

# ---------------------------------------------------------------- file list

$entries = New-Object System.Collections.Generic.List[object]
function Add-Entry([string]$source, [string]$entryName) {
    if (-not (Test-Path $source)) { Fail "missing file: $source" }
    $entries.Add([pscustomobject]@{ Source = $source; Name = $entryName })
}
function Add-Tree([string]$sourceDir, [string]$prefix, [string[]]$excludeNames, [string[]]$excludeDirs) {
    $base = (Get-Item $sourceDir).FullName
    Get-ChildItem -Recurse -File $base | ForEach-Object {
        $rel = $_.FullName.Substring($base.Length).TrimStart('\', '/') -replace '\\', '/'
        $first = ($rel -split '/')[0]
        if ($excludeNames -contains $_.Name) { return }
        if ($excludeDirs -contains $first) { return }
        if ($_.Name -like '*.tmp') { return }
        Add-Entry $_.FullName ($prefix + $rel)
    }
}

Add-Tree (Join-Path $root 'mod\Talky') 'Talky/' @() @()
Add-Tree (Join-Path $root 'bridge') 'bridge/' @('config.json', 'bridge-state.json') @('node_modules', 'test')
foreach ($f in @('start-bridge.cmd', 'README.md', 'README.fr.md', 'LICENSE', 'CHANGELOG.md')) {
    Add-Entry (Join-Path $root $f) $f
}

# ---------------------------------------------------------------- zip

New-Item -ItemType Directory -Force $OutDir | Out-Null
$zipName = "Talky-$version-windows.zip"
$zipPath = Join-Path $OutDir $zipName
if (Test-Path $zipPath) { Remove-Item -Force $zipPath }

# Entries written one by one so names always use "/" (Windows PowerShell's Compress-Archive
# writes "\", which other unzip tools turn into flat file names).
$zip = [System.IO.Compression.ZipFile]::Open($zipPath, [System.IO.Compression.ZipArchiveMode]::Create)
try {
    foreach ($e in $entries) {
        [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $e.Source, $e.Name, [System.IO.Compression.CompressionLevel]::Optimal) | Out-Null
    }
} finally {
    $zip.Dispose()
}

# ---------------------------------------------------------------- checks

$check = [System.IO.Compression.ZipFile]::OpenRead($zipPath)
try {
    $names = $check.Entries | ForEach-Object { $_.FullName }
} finally {
    $check.Dispose()
}
foreach ($required in @('Talky/42/mod.info', 'Talky/42/poster.png', 'bridge/bridge.js', 'bridge/config.example.json', 'bridge/package.json', 'start-bridge.cmd', 'README.md', 'README.fr.md', 'LICENSE')) {
    if ($names -notcontains $required) { Fail "$required is missing from the archive" }
}
foreach ($secret in @('bridge/config.json', 'bridge/bridge-state.json')) {
    if ($names -contains $secret) { Fail "$secret must never be in the archive" }
}
if ($names | Where-Object { $_ -like '*.ps1' }) { Fail 'the archive must not contain PowerShell scripts (the bridge sets itself up on its first start)' }
if ($names | Where-Object { $_ -match '\\' }) { Fail 'an entry name contains a backslash' }

# ---------------------------------------------------------------- checksums

$hash = (Get-FileHash -Algorithm SHA256 $zipPath).Hash.ToLowerInvariant()
$sums = Join-Path $OutDir 'SHA256SUMS.txt'
[System.IO.File]::WriteAllText($sums, "$hash  $zipName`n", (New-Object System.Text.UTF8Encoding($false)))

$size = (Get-Item $zipPath).Length
Write-Host "Talky $version release built:"
Write-Host ("  {0}  ({1} files, {2:N0} KB)" -f $zipPath, $names.Count, ($size / 1KB))
Write-Host "  $sums"
Write-Host "  sha256 $hash"
