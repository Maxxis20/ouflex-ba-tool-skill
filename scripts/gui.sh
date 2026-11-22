#!/usr/bin/env bash
# gui.sh 'cmd1' 'cmd2' ... : mouse and keyboard on this machine's desktop, then a screenshot. Prints what the commands
# said and, last, the path of the PNG (Read it). Positions are screen pixels as in the screenshot.
#   click x y | dclick x y | rclick x y | move x y | drag x1 y1 x2 y2
#   keys <SendKeys string, e.g. ^a or {ENTER}> | text <literal text> | sleep <ms>
#   activate <part of a window title> | windows | fg | ps <powershell>
# Take a screenshot first (gui.sh fg) and click by what it shows: windows are where the user left them.
exec "$(dirname "$0")/batool.sh" gui "$@"
