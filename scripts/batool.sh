#!/usr/bin/env bash
# batool.sh - Ouflex BA Tool driver, for a bash on the Windows machine that has the tool (Git Bash, which Claude Code uses).
#   batool.sh check                    what is ready on this machine and what is not, one line each
#   batool.sh setup [force]            work folder, host compiled into the tool folder, block library read, base project
#   batool.sh hstart <instance> <exe> [args]     same as hstart.sh
#   batool.sh hrun <instance> <file.ps1> | hwait <instance> [script] | hstop [instance]
#   batool.sh gui '<cmd>' ...          same as gui.sh
#   batool.sh shot [png]               screenshot of the primary screen, prints the path
#   batool.sh dlg list | dlg file '<win path>' | dlg button <id>     standard dialogs of the hosted tool (1 OK/Save, 2 Cancel, 6 Yes, 7 No)
#   batool.sh run <file.ps1>           plain PowerShell with win/lib.ps1 loaded (the tool's DLLs, no tool window)
#   batool.sh ps '<powershell>'        the same for one line of PowerShell
#   batool.sh build <program dir>      same as build.sh
# Settings (environment): BATOOL_DIR = folder of the BA Tool installation (default: newest C:\Ouman\OuflexBATool_*),
#   BATOOL_WORK = work folder (default C:\agentwork), HRUN_TICKS = how long hrun waits, x 0.3 s (default 330).
# From PowerShell, without bash: powershell -NoProfile -ExecutionPolicy Bypass -File win\cli.ps1 <verb> ...
set -euo pipefail
S=$(cd "$(dirname "$0")" && pwd)
w(){ if command -v cygpath >/dev/null 2>&1; then cygpath -w "$1"; elif command -v wslpath >/dev/null 2>&1; then wslpath -w "$1"; else printf '%s\n' "$1"; fi; }
u(){ if command -v cygpath >/dev/null 2>&1; then cygpath -u "$1"; elif command -v wslpath >/dev/null 2>&1; then wslpath -u "$1"; else printf '%s\n' "$1"; fi; }
cli(){ powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$(w "$S/win/cli.ps1")" "$@" </dev/null | tr -d '\r'; }   # </dev/null: keeps the stdin of a calling loop
tmp(){ local t; t=$(mktemp); mv "$t" "$t.$1"; echo "$t.$1"; }
v=${1:-}; [ $# -gt 0 ] && shift
case "$v" in
  check|setup|hstop|hwait) cli "$v" "$@" ;;
  hstart) cli hstart "$@" ;;
  hrun)   inst=$1; f=$2; shift 2; cli hrun "$inst" "$(w "$f")" "$@" ;;
  gui)    t=$(tmp txt); printf '%s\n' "$@" > "$t"; out=$(cli gui "$(w "$t")") || true; rm -f "$t"
          printf '%s\n' "$out" | sed '$d'; u "$(printf '%s\n' "$out" | tail -1)" ;;
  shot)   if [ -n "${1:-}" ]; then cli shot "$(w "$1")" >/dev/null && echo "$1"; else u "$(cli shot | tail -1)"; fi ;;
  dlg)    cli dlg "$@" ;;
  run)    cli run "$(w "$1")" ;;
  ps)     t=$(tmp ps1); printf '\xef\xbb\xbf%s\n' "$1" > "$t"; cli run "$(w "$t")" || true; rm -f "$t" ;;   # with BOM: Windows PowerShell reads it as UTF-8
  build)  cli build "$(w "$1")" ;;
  *) sed -n 2,15p "$0"; exit 2 ;;
esac
