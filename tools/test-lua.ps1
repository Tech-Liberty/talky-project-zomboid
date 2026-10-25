<#
.SYNOPSIS
  Runs the Lua tests of the Talky mod in Kahlua, the Lua VM shipped with Project Zomboid.

.DESCRIPTION
  Needs a Java 17+ JDK (java on the PATH or -Java) and an installed Project Zomboid Build 42
  (-GameDir). Nothing is written to the game folder: stdlib.lua is copied to a temporary
  folder and the game jar is only read.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File tools\test-lua.ps1 -GameDir "D:\SteamLibrary\steamapps\common\ProjectZomboid"
#>
param(
    [string]$GameDir = '',
    [string]$Java = 'java'
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot

if (-not $GameDir) {
    $candidates = @(
        "${env:ProgramFiles(x86)}\Steam\steamapps\common\ProjectZomboid",
        "$env:ProgramFiles\Steam\steamapps\common\ProjectZomboid",
        'D:\SteamLibrary\steamapps\common\ProjectZomboid'
    )
    $GameDir = $candidates | Where-Object { Test-Path (Join-Path $_ 'projectzomboid.jar') } | Select-Object -First 1
}
if (-not $GameDir -or -not (Test-Path (Join-Path $GameDir 'projectzomboid.jar'))) {
    Write-Error 'Project Zomboid not found. Pass -GameDir "<path to ProjectZomboid>".'
}

$work = Join-Path ([System.IO.Path]::GetTempPath()) ("talky-lua-test-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force $work | Out-Null
try {
    Copy-Item (Join-Path $GameDir 'stdlib.lua') $work
    $jar = Join-Path $GameDir 'projectzomboid.jar'
    $sim = Join-Path $PSScriptRoot 'lua-test\LuaSim.java'
    $script = Join-Path $PSScriptRoot 'lua-test\sim.lua'
    $lua = Join-Path $root 'mod\Talky\42\media\lua'
    Push-Location $work
    try {
        & $Java -cp $jar $sim $lua $script
        $code = $LASTEXITCODE
    } finally {
        Pop-Location
    }
} finally {
    Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
}
exit $code
