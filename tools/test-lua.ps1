<#
.SYNOPSIS
  Runs the Lua tests of the Talky mod in Kahlua, the Lua VM shipped with Project Zomboid.

.DESCRIPTION
  Needs a JDK 25 or later (java on the PATH or -Java): the classes of Build 42.21 are
  Java 25 classes, and running LuaSim.java from source needs the jdk.compiler module (the
  game's own jre64 does not have it). Needs an installed Project Zomboid Build 42 (-GameDir;
  for a dedicated server only, pass its "java" folder). Nothing is written to the game
  folder: stdlib.lua is copied to a temporary folder and the game jar is only read.
  The tests simulate a single player game, a dedicated server with several clients and a
  hosted game, each in a Lua state of its own (tools/lua-test/sim.lua).

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
        'D:\SteamLibrary\steamapps\common\ProjectZomboid',
        "${env:ProgramFiles(x86)}\Steam\steamapps\common\Project Zomboid Dedicated Server\java",
        'D:\SteamLibrary\steamapps\common\Project Zomboid Dedicated Server\java'
    )
    $GameDir = $candidates | Where-Object { Test-Path (Join-Path $_ 'projectzomboid.jar') } | Select-Object -First 1
}
# A dedicated server keeps projectzomboid.jar and stdlib.lua in its "java" folder.
if ($GameDir -and -not (Test-Path (Join-Path $GameDir 'projectzomboid.jar')) -and (Test-Path (Join-Path $GameDir 'java\projectzomboid.jar'))) {
    $GameDir = Join-Path $GameDir 'java'
}
if (-not $GameDir -or -not (Test-Path (Join-Path $GameDir 'projectzomboid.jar'))) {
    Write-Error 'Project Zomboid not found. Pass -GameDir "<path to ProjectZomboid>".'
}

# JDK 17 or 21 fail later with "cannot access J2SEPlatform" (class file version 69): say it now.
$previous = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$versionText = (& $Java -version 2>&1 | ForEach-Object { "$_" }) -join ' '
$ErrorActionPreference = $previous
if ($versionText -match 'version "(\d+)') {
    if ([int]$Matches[1] -lt 25) {
        Write-Error "Java $($Matches[1]) found ($Java). The tests need a JDK 25 or later: pass -Java '<path to a JDK 25>\bin\java.exe'."
    }
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
        # The game's network serializer (used by the tests) loads LWJGL: allow it without a warning.
        & $Java --enable-native-access=ALL-UNNAMED -cp $jar $sim $lua $script
        $code = $LASTEXITCODE
    } finally {
        Pop-Location
    }
} finally {
    Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
}
exit $code
