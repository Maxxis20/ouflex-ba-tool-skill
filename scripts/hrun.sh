#!/usr/bin/env bash
# HNAME=<instance> hrun.sh <file.ps1>        run a script on the UI thread of the hosted BA Tool, print its output
# HNAME=<instance> hrun.sh -c '<powershell>' the same for a line of PowerShell
# win/prelude.ps1 is loaded in front of the script. HRUN_TICKS (x 0.3 s, default 330) = how long to wait; on TIMEOUT
# the script keeps running in the host: hwait.sh collects it. A modal dialog opened by the script also gives TIMEOUT.
set -euo pipefail
S=$(cd "$(dirname "$0")" && pwd)
: "${HNAME:?set HNAME=<instance>, e.g. HNAME=ab}"
if [ "${1:-}" = "-c" ]; then
  t=$(mktemp); mv "$t" "$t.ps1"; printf '%s\n' "$2" > "$t.ps1"
  "$S/batool.sh" hrun "$HNAME" "$t.ps1" "${HRUN_TICKS:-330}" || true; rm -f "$t.ps1"
else
  exec "$S/batool.sh" hrun "$HNAME" "$1" "${HRUN_TICKS:-330}"
fi
