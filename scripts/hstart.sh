#!/usr/bin/env bash
# hstart.sh <instance> <target.exe> [args...] : (re)start a hosted tool instance on this machine's desktop.
#   hstart.sh ab ApplicationBuilder.exe 'C:\agentwork\apps\X.ouear' mode=1 lang=en-GB
#   hstart.sh pm ProjectManager.exe
# Prints the host log; "timer armed" means the instance takes scripts (hrun.sh).
exec "$(dirname "$0")/batool.sh" hstart "$@"
