#!/usr/bin/env bash
# HNAME=<instance> hwait.sh [script name] : wait (HRUN_TICKS x 0.3 s) for a hosted script that hrun.sh reported as TIMEOUT.
# Without a name: the last script sent to that instance.
: "${HNAME:?set HNAME=<instance>}"
exec "$(dirname "$0")/batool.sh" hwait "$HNAME" "${1:-}" "${HRUN_TICKS:-330}"
