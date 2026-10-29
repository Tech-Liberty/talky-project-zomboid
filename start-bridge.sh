#!/bin/sh
# Starts the Talky bridge on Linux, next to a Project Zomboid dedicated server (server mode by
# default). Run it with the account that runs the server: the bridge then uses its Zomboid/Lua
# folder (~/Zomboid/Lua; for a server started with -cachedir, set "zomboidLuaDir" in
# bridge/config.json).
#   sh start-bridge.sh           server mode
#   sh start-bridge.sh --solo    solo mode (the bridge of a player's PC, next to the game)
# To start it with the machine: talky-bridge.service, an example unit for systemd.

set -eu
cd "$(dirname "$0")/bridge"

if ! command -v node >/dev/null 2>&1; then
  echo "Node.js was not found. The Talky bridge needs Node.js 18 or later:"
  echo "the package of your distribution when it is 18 or later, or https://nodejs.org."
  exit 1
fi
if ! node -e "process.exit(Number(process.versions.node.split('.')[0]) < 18 ? 1 : 0)"; then
  echo "Node.js $(node --version) is too old: the Talky bridge needs Node.js 18 or later."
  exit 1
fi

mode=--server
for arg in "$@"; do
  case "$arg" in
    solo|--solo) mode=--solo ;;
    server|--server) mode=--server ;;
  esac
done

# On the first start, the bridge creates bridge/config.json with a random token.
exec node bridge.js "$mode"
