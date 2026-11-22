#!/usr/bin/env bash
# build.sh <program dir> : build one Ouflex program in BA Tool from its plan, from nothing, and verify it.
#   build.sh ../examples/dh-ex2
# <program dir> holds program.json and plan.json. Stages (STAGES, default all but deliver):
#   gen apps device modbus filecheck shots [deliver]
# APPS="A B" limits the apps stage; KEEP_GOING=1 does not stop at the first difference. Outputs: <program dir>/build/out/.
# The work is done by win/build.ps1; this only hands over the folder. Keep hands off keyboard and mouse while it runs.
[ -n "${1:-}" ] || { sed -n 2,7p "$0"; exit 2; }
exec "$(dirname "$0")/batool.sh" build "$1"
