@echo off
rem Starts the Talky bridge. Keep this window open while you play.
rem   start-bridge.cmd          solo mode: the bridge of your PC, next to your game (double-click)
rem   start-bridge.cmd server   server mode: next to a dedicated server, or on the PC that hosts
rem                             the game (the admin adds the streamers in game, F8 > Webhooks)
setlocal
cd /d "%~dp0bridge"

set "MODE="
if /i "%~1"=="server" set "MODE=--server"
if /i "%~1"=="--server" set "MODE=--server"
if /i "%~1"=="solo" set "MODE=--solo"
if /i "%~1"=="--solo" set "MODE=--solo"
if "%MODE%"=="--server" (title Talky bridge - server mode) else (title Talky bridge)

where node >nul 2>nul
if errorlevel 1 goto nonode
node -e "process.exit(Number(process.versions.node.split('.')[0]) < 18 ? 1 : 0)"
if errorlevel 1 goto oldnode

rem On the first start, the bridge creates bridge\config.json and copies its token to the clipboard.
node bridge.js %MODE%
echo.
echo The bridge has stopped.
pause
exit /b 0

:nonode
echo Node.js was not found on this PC.
echo The Talky bridge needs Node.js 18 or later. Install it with:
echo.
echo     winget install OpenJS.NodeJS.LTS
echo.
echo or from https://nodejs.org, then close this window and start start-bridge.cmd again.
pause
exit /b 1

:oldnode
for /f %%v in ('node --version') do set NODEVER=%%v
echo Node.js %NODEVER% is too old: the Talky bridge needs Node.js 18 or later.
echo.
echo     winget upgrade OpenJS.NodeJS.LTS
echo.
pause
exit /b 1
