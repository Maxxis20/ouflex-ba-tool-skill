# cli.ps1 - entry point on the Windows machine that has Ouflex BA Tool. Called by the bash wrappers in ..\, or directly:
#   powershell -NoProfile -ExecutionPolicy Bypass -File cli.ps1 <verb> [arguments]
# Verbs:
#   check                          what is ready on this machine and what is not, one line each (OK / TODO / INFO)
#   setup [force]                  work folder, compile the host into the tool folder, read the block library, make the base project
#   hstart <instance> <exe> [args] (re)start a hosted tool instance, e.g. hstart ab ApplicationBuilder.exe C:\agentwork\apps\X.ouear mode=1 lang=en-GB
#   hrun <instance> <file.ps1> [ticks]   run a script on the UI thread of that instance (prelude.ps1 loaded first); ticks x 0.3 s = how long to wait
#   hwait <instance> [script] [ticks]    keep waiting for a script that hrun reported as TIMEOUT
#   hstop [instance]               stop one hosted instance, or all of them
#   gui <commands.txt>             mouse and keyboard commands, one per line, then a screenshot (prints its path last)
#   shot [png]                     screenshot of the primary screen
#   dlg list | file <path> | button <id>   standard dialogs of the hosted tool (Save As, message boxes), by control id
#   run <file.ps1>                 plain PowerShell with lib.ps1 loaded (the tool's DLLs, no tool window): read project files
#   build <program dir>            build and verify a whole program (build.ps1)
# Must run in your own desktop session: the tool's windows open there.
param([string]$Verb = '', [Parameter(ValueFromRemainingArguments = $true)][string[]]$Rest)
$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch {}
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. "$here\env.ps1"
. "$here\hostlib.ps1"
$Rest = @($Rest | ? { $null -ne $_ })
$ref = Join-Path $BT_SKILL 'reference'
$base = "$BT_WORK\base\OuflexA_empty"
function Arg([int]$i, $default = '') { if ($Rest.Count -gt $i) { $Rest[$i] } else { $default } }
function Need-Tool { if (-not $BT_DIR) { 'BA Tool not found. Looked for C:\Ouman\OuflexBATool_* and the registered install location; set BATOOL_DIR to its folder.'; exit 1 } }
function Host-Stale { (Test-Path "$BT_DIR\$BT_HOST") -and ((Get-Item "$here\AgentHost.cs").LastWriteTimeUtc -gt (Get-Item "$BT_DIR\$BT_HOST").LastWriteTimeUtc) }
function Base-Ready { (Test-Path "$base\Devices\Device1\Device.bin") -and @(Get-ChildItem "$base\*.flprj" -ErrorAction SilentlyContinue).Count }

switch ($Verb) {
  'check' {
    if (-not $BT_DIR) { 'TODO  BA Tool not found (looked for C:\Ouman\OuflexBATool_* and the registered install location): install it, or set BATOOL_DIR to its folder'; }
    else {
      $v = BaTool-Version
      if ($v -eq '2.130.14.1') { "OK    BA Tool $v in $BT_DIR" } else { "INFO  BA Tool $v in $BT_DIR. This skill was worked out on 2.130.14.1: the tool's internals may differ, prove each step." }
      if (-not (Test-Path "$BT_DIR\$BT_HOST")) { "TODO  host $BT_HOST is not in the tool folder: run setup (compiles it there)" }
      elseif (Host-Stale) { "TODO  host $BT_HOST is older than its source: run setup" }
      else { "OK    host $BT_HOST is in the tool folder" }
      try { $t = "$BT_DIR\.write-test-$PID"; [IO.File]::WriteAllText($t, 'x'); Remove-Item $t; }
      catch { "INFO  the tool folder is not writable for this user: setup must be run once from an administrator shell to put the host there" }
      if (Test-Path "$BT_DIR\Template\NewApplication.ouear") { 'OK    empty application template found' } else { 'TODO  Template\NewApplication.ouear missing in the tool folder: builds start from it' }
    }
    if (Test-Path "$BT_WORK\apps") { "OK    work folder $BT_WORK" } else { "TODO  work folder $BT_WORK missing: run setup" }
    $miss = @('blocks.json', 'primitive-pins.txt', 'primitive-docs.txt' | ? { -not (Test-Path (Join-Path $ref $_)) })
    if ($miss.Count) { "TODO  reference files missing ($($miss -join ', ')): run setup (reads the block library of your own installation)" }
    else { 'OK    block catalogue and block texts in reference\ (made from your installation)' }
    if (Base-Ready) { "OK    base project $base" } else { "TODO  base project missing ($base): run setup (creates an empty project with one Ouflex A)" }
    $py = Find-Python
    if ($py) { "OK    Python 3 ($py)" } else { 'TODO  Python 3 not found (python, python3, py; the Windows Store stub does not count): the plan generator, checker and verifier need it. Ask the user to install it.' }
    $n = @(Host-Procs).Count; "INFO  $n hosted tool instance(s) running"
    Init-Native
    $g = [Drawing.Graphics]::FromHwnd([IntPtr]::Zero); $dpi = [int]$g.DpiX; $g.Dispose()
    $b = [Windows.Forms.Screen]::PrimaryScreen.Bounds
    if ($dpi -eq 96) { "OK    display scaling 100 %, screen $($b.Width)x$($b.Height)" }
    else { "INFO  display scaling is $([int]($dpi / 0.96)) %, screen $($b.Width)x$($b.Height). Builds do not click by position, so this is fine; for hand-placed gui clicks take the position from a fresh screenshot." }
    if ($b.Width -lt 1024 -or $b.Height -lt 768) { 'INFO  small screen: the tool windows may not fit' }
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    if ($id.IsSystem -or [Diagnostics.Process]::GetCurrentProcess().SessionId -eq 0) { 'TODO  this is not a desktop session: run from the logged-on desktop, the tool needs its windows' }
    'INFO  first start of the tool through the host can raise a Windows Firewall question. Cancel is fine: nothing here needs the network.'
  }
  'setup' {
    Need-Tool
    $force = (Arg 0) -eq 'force'
    New-Item -ItemType Directory -Force $BT_WORK, "$BT_WORK\apps", "$BT_WORK\proj", "$BT_WORK\base", "$BT_WORK\gui" | Out-Null
    "work folder $BT_WORK ready"
    # ---- the host: compiled from AgentHost.cs with the .NET Framework compiler that ships with Windows
    if ($force -or -not (Test-Path "$BT_DIR\$BT_HOST") -or (Host-Stale)) {
      [void](Host-Stop)
      $csc = "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
      if (-not (Test-Path $csc)) { "FAIL no C# compiler at $csc (.NET Framework 4 is part of Windows 10 and 11)" }
      else {
        $o = & $csc /nologo /target:winexe /platform:x64 "/out:$BT_DIR\$BT_HOST" "/r:$([psobject].Assembly.Location)" /r:System.Windows.Forms.dll "$here\AgentHost.cs" 2>&1
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path "$BT_DIR\$BT_HOST")) { "FAIL host not compiled (is the tool folder writable? try an administrator shell once):"; $o | % { "  $_" } }
        else { Copy-Item "$BT_DIR\ProjectManager.exe.config" "$BT_DIR\$BT_HOST.config" -Force; "host compiled: $BT_DIR\$BT_HOST" }
      }
    } else { "host $BT_HOST already in the tool folder" }
    # ---- reference files: read from the block library of this installation, never shipped with the skill
    if ($force -or @('blocks.json', 'primitive-pins.txt', 'primitive-docs.txt' | ? { -not (Test-Path (Join-Path $ref $_)) }).Count) {
      & "$PSHOME\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "$here\catalogue.ps1" $ref (Join-Path $BT_SKILL 'pipeline\pin_roles.json') 2>&1 | % { "$_" }
    } else { 'reference files already made' }
    # ---- base project: an untouched New project with one Ouflex A, copied by every build
    if ((Base-Ready) -and -not $force) { "base project already at $base" }
    elseif (-not (Test-Path "$BT_DIR\$BT_HOST")) { 'base project not made: no host' }
    else {
      if (Test-Path $base) { Remove-Item -Recurse -Force $base }
      $log = Host-Start 'setup' 'ProjectManager.exe'
      if ($log -notmatch 'timer armed') { "FAIL the tool did not start in the host: $log" }
      else {
        Host-Run 'setup' 'New-Project-Start' 'np0' 100
        $done = $false
        for ($i = 0; $i -lt 10 -and -not $done; $i++) {
          Start-Sleep -Milliseconds 1500
          $o = Host-Run 'setup' "New-Project-Step 'OuflexA_empty' '$BT_WORK\base' 'Ouflex A'" "np$($i + 1)" 100
          $o.TrimEnd(); if ($o -match 'NEWPROJECT done|FAIL|TIMEOUT|ERR:') { $done = $true }
        }
        [void](Host-Stop 'setup')
        if (Base-Ready) { "base project made: $base" }
        else { "FAIL base project not made. By hand: start the tool, Project > New project, name OuflexA_empty, directory $BT_WORK\base, Create new device, Ouflex A, OK, then Project > Save project and close the tool."; Dlg-List }
      }
    }
  }
  'hstart' { Need-Tool; if ($Rest.Count -lt 2) { 'usage: hstart <instance> <exe> [args]'; exit 2 }; Host-Start $Rest[0] $Rest[1] @($Rest | select -Skip 2) }
  'hrun' {
    if ($Rest.Count -lt 2) { 'usage: hrun <instance> <file.ps1> [ticks]'; exit 2 }
    $t = [int](Arg 2 $(if ($env:HRUN_TICKS) { $env:HRUN_TICKS } else { 330 }))
    Host-Run $Rest[0] ([IO.File]::ReadAllText($Rest[1], [Text.Encoding]::UTF8)) ([IO.Path]::GetFileNameWithoutExtension($Rest[1])) $t
  }
  'hwait' { if ($Rest.Count -lt 1) { 'usage: hwait <instance> [script] [ticks]'; exit 2 }; Host-Wait $Rest[0] (Arg 1) ([int](Arg 2 $(if ($env:HRUN_TICKS) { $env:HRUN_TICKS } else { 330 }))) }
  'hstop' { Host-Stop (Arg 0) }
  'gui' {
    if ($Rest.Count -lt 1) { 'usage: gui <commands.txt>'; exit 2 }
    Gui-Run @(Get-Content -Encoding UTF8 $Rest[0])
    Start-Sleep -Milliseconds $(if ($env:GUI_WAIT) { [int]$env:GUI_WAIT } else { 700 })
    Screen-Shot "$BT_WORK\gui\shot-$(Get-Date -Format HHmmss).png"
  }
  'shot' { $p = Arg 0; if (-not $p) { $p = "$BT_WORK\gui\shot-$(Get-Date -Format HHmmss).png" }; Screen-Shot $p }
  'dlg' {
    switch (Arg 0 'list') {
      'list' { Dlg-List }
      'file' { Dlg-File (Arg 1) }
      'button' { Dlg-Button ([int](Arg 1)) }
      default { 'usage: dlg list | file <path> | button <id>   (1 OK/Save, 2 Cancel, 6 Yes, 7 No)'; exit 2 }
    }
  }
  'run' {
    Need-Tool; if ($Rest.Count -lt 1) { 'usage: run <file.ps1>'; exit 2 }
    $f = $Rest[0]
    try { . "$here\lib.ps1"; & { . $f } *>&1 | % { ($_ | Out-String -Width 400).TrimEnd() } }
    catch { "EXC: $($_.Exception.Message)`n$($_.ScriptStackTrace)" }
  }
  'build' {
    Need-Tool; if ($Rest.Count -lt 1) { 'usage: build <program dir>   (a folder with program.json and plan.json, e.g. examples\dh-ex2)'; exit 2 }
    . "$here\build.ps1"
    $rc = @(Build-Program $Rest[0]) | select -Last 1
    exit ([int]$rc)
  }
  default { Get-Content $MyInvocation.MyCommand.Path | select -Skip 1 -First 16 | % { $_ -replace '^# ?', '' }; exit 2 }
}
