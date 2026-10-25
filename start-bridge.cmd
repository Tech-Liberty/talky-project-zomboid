@echo off
rem Starts the Talky bridge. Keep this window open while you play.
setlocal
title Talky bridge
cd /d "%~dp0bridge"

where node >nul 2>nul
if errorlevel 1 goto nonode
node -e "process.exit(Number(process.versions.node.split('.')[0]) < 18 ? 1 : 0)"
if errorlevel 1 goto oldnode

rem On the first start, the bridge creates bridge\config.json and copies its token to the clipboard.
node bridge.js
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
