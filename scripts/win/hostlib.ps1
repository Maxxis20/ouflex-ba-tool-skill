# hostlib.ps1 - hosted tool instances, screenshots, mouse and keyboard, standard dialogs. Dot-sourced by cli.ps1 after env.ps1.
# Everything here runs in your own desktop session, in a plain PowerShell outside the tool.
$BT_PRELUDE = Join-Path $PSScriptRoot 'prelude.ps1'

function Host-Dir([string]$name) { "$BT_WORK\host-$name" }
# the host processes of one instance, or of all instances
function Host-Procs([string]$name = '') {
  $all = @(Get-CimInstance Win32_Process -Filter "Name='$BT_HOST'" -ErrorAction SilentlyContinue)
  if (-not $name) { return $all }
  $re = '--name"?\s+"?' + [regex]::Escape($name) + '("|\s|$)'
  @($all | ? { $_.CommandLine -match $re })
}
function Host-Stop([string]$name = '') {
  $p = @(Host-Procs $name); foreach ($x in $p) { Stop-Process -Id $x.ProcessId -Force -ErrorAction SilentlyContinue }
  if ($p.Count) { Start-Sleep -Milliseconds 700 }
  "stopped $($p.Count) hosted instance(s)"
}
function QArg([string]$a) { if ($a -match '[\s"]') { '"' + (($a -replace '"', '\"') -replace '\\$', '\\') + '"' } else { $a } }
# (re)start a hosted instance: the tool's exe is loaded into the host process, which then runs scripts on the tool's UI thread
function Host-Start([string]$name, [string]$exe, [string[]]$targs = @()) {
  if (-not $BT_DIR) { return 'FATAL BA Tool not found: set BATOOL_DIR to its folder' }
  if (-not (Test-Path "$BT_DIR\$BT_HOST")) { return "FATAL $BT_DIR\$BT_HOST missing: run setup" }
  [void](Host-Stop $name)
  $hd = Host-Dir $name
  New-Item -ItemType Directory -Force "$hd\stage", "$hd\in", "$hd\out" | Out-Null
  Remove-Item "$hd\host.log", "$hd\in\*.ps1", "$hd\stage\*.ps1" -ErrorAction SilentlyContinue
  $al = @('--work', $BT_WORK, '--name', $name, '--exe', $exe) + @($targs) | % { QArg $_ }
  Start-Process "$BT_DIR\$BT_HOST" -WorkingDirectory $BT_DIR -ArgumentList $al
  $i = 0
  while (-not ((Test-Path "$hd\host.log") -and ("$(Get-Content "$hd\host.log" -ErrorAction SilentlyContinue)" -match 'timer armed|FATAL')) -and $i -lt 120) { Start-Sleep -Milliseconds 500; $i++ }
  if (Test-Path "$hd\host.log") { (Get-Content "$hd\host.log") -join "`n" } else { 'FATAL the host wrote no log (did it start? a Windows Firewall or licence window may be waiting on screen)' }
}
function Host-Wait([string]$name, [string]$script = '', [int]$ticks = 330) {
  $hd = Host-Dir $name
  if (-not $script) { $script = "$(Get-Content "$hd\last.txt" -ErrorAction SilentlyContinue)".Trim() }
  if (-not $script) { return 'ERR: nothing to wait for' }
  $i = 0
  while (-not (Test-Path "$hd\out\$script.done") -and $i -lt $ticks) { Start-Sleep -Milliseconds 300; $i++ }
  if (Test-Path "$hd\out\$script.done") { [IO.File]::ReadAllText("$hd\out\$script.txt", [Text.Encoding]::UTF8) }
  else { "TIMEOUT (script still running, or a modal dialog is open, or the host is gone): $script" }
}
# run PowerShell text on the UI thread of a hosted instance, prelude.ps1 loaded first; returns what it printed
function Host-Run([string]$name, [string]$code, [string]$tag = 'snippet', [int]$ticks = 330) {
  if (-not @(Host-Procs $name).Count) { return "ERR: no hosted instance '$name' is running: start it with hstart" }
  $hd = Host-Dir $name
  $n = (Get-Date -Format HHmmssfff) + '_' + ($tag -replace '[^\w.-]', '_')
  $text = ". '" + ($BT_PRELUDE -replace "'", "''") + "'`r`n" + $code
  [IO.File]::WriteAllText("$hd\stage\$n.ps1", $text, (New-Object Text.UTF8Encoding $false))
  [IO.File]::WriteAllText("$hd\last.txt", $n)
  Move-Item "$hd\stage\$n.ps1" "$hd\in\$n.ps1"
  Host-Wait $name $n $ticks
}

function Init-Native {
  if ('BtNative' -as [type]) { return }
  Add-Type -AssemblyName System.Windows.Forms, System.Drawing
  Add-Type @"
using System; using System.Text; using System.Collections.Generic; using System.Runtime.InteropServices;
public static class BtNative {
  public delegate bool EnumProc(IntPtr h, IntPtr l);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern void mouse_event(uint f, uint dx, uint dy, uint d, UIntPtr e);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc f, IntPtr l);
  [DllImport("user32.dll")] static extern bool EnumChildWindows(IntPtr p, EnumProc f, IntPtr l);
  [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetClassName(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern IntPtr GetDlgItem(IntPtr h, int id);
  [DllImport("user32.dll")] public static extern int GetDlgCtrlID(IntPtr h);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern IntPtr SendMessage(IntPtr h, uint m, IntPtr w, string l);
  [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
  public static string Cls(IntPtr h){ var s=new StringBuilder(256); GetClassName(h,s,256); return s.ToString(); }
  public static string Txt(IntPtr h){ var s=new StringBuilder(1024); GetWindowText(h,s,1024); return s.ToString(); }
  public static uint Pid(IntPtr h){ uint p; GetWindowThreadProcessId(h,out p); return p; }
  // visible standard dialogs (file dialogs, message boxes) that belong to one process
  public static List<IntPtr> Dialogs(uint pid){ var r=new List<IntPtr>(); EnumWindows((h,l)=>{ if(Pid(h)==pid && IsWindowVisible(h) && Cls(h)=="#32770") r.Add(h); return true; }, IntPtr.Zero); return r; }
  public static List<IntPtr> Kids(IntPtr d){ var r=new List<IntPtr>(); EnumChildWindows(d,(h,l)=>{ r.Add(h); return true; }, IntPtr.Zero); return r; }
}
"@
  [void][BtNative]::SetProcessDPIAware()
}
# screenshot as PNG: the whole primary screen, or (with a process id) that process's main window cut to the screen's work area
function Screen-Shot([string]$png, [int]$procId = 0) {
  Init-Native
  $b = [Windows.Forms.Screen]::PrimaryScreen.Bounds
  if ($procId) {
    $h = (Get-Process -Id $procId -ErrorAction SilentlyContinue).MainWindowHandle
    $r = New-Object BtNative+RECT
    if ($h -and $h -ne [IntPtr]::Zero -and [BtNative]::GetWindowRect($h, [ref]$r)) {
      $wa = [Windows.Forms.Screen]::FromHandle($h).WorkingArea
      $x = [Drawing.Rectangle]::Intersect($wa, [Drawing.Rectangle]::FromLTRB($r.L, $r.T, $r.R, $r.B))
      if ($x.Width -gt 50 -and $x.Height -gt 50) { $b = $x }
    }
  }
  New-Item -ItemType Directory -Force (Split-Path $png) | Out-Null
  $bmp = New-Object Drawing.Bitmap $b.Width, $b.Height
  $g = [Drawing.Graphics]::FromImage($bmp); $g.CopyFromScreen($b.Location, [Drawing.Point]::Empty, $b.Size); $g.Dispose()
  $bmp.Save($png, [Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose()
  $png
}
function Mouse-Click([int]$x, [int]$y, [string]$btn = 'l', [int]$n = 1) {
  [void][BtNative]::SetCursorPos($x, $y); Start-Sleep -Milliseconds 120
  $d = 2; $u = 4; if ($btn -eq 'r') { $d = 8; $u = 16 }
  for ($i = 0; $i -lt $n; $i++) { [BtNative]::mouse_event($d, 0, 0, 0, [UIntPtr]::Zero); Start-Sleep -Milliseconds 40; [BtNative]::mouse_event($u, 0, 0, 0, [UIntPtr]::Zero); Start-Sleep -Milliseconds 60 }
}
# mouse and keyboard commands, one per line (see gui.sh for the list); prints a log line where a command has something to say
function Gui-Run([string[]]$lines) {
  Init-Native
  foreach ($line in $lines) {
    $line = "$line".Trim(); if (-not $line -or $line.StartsWith('#')) { continue }
    $p = $line.Split(' ', 2); $c = $p[0]; $a = if ($p.Count -gt 1) { $p[1] } else { '' }
    try {
      switch ($c) {
        'click'  { $q = $a.Split(' '); Mouse-Click ([int]$q[0]) ([int]$q[1]) }
        'dclick' { $q = $a.Split(' '); Mouse-Click ([int]$q[0]) ([int]$q[1]) 'l' 2 }
        'rclick' { $q = $a.Split(' '); Mouse-Click ([int]$q[0]) ([int]$q[1]) 'r' }
        'move'   { $q = $a.Split(' '); [void][BtNative]::SetCursorPos([int]$q[0], [int]$q[1]) }
        'drag'   {
          $q = @($a.Split(' ') | % { [int]$_ }); [void][BtNative]::SetCursorPos($q[0], $q[1]); Start-Sleep -Milliseconds 150
          [BtNative]::mouse_event(2, 0, 0, 0, [UIntPtr]::Zero)
          for ($i = 1; $i -le 12; $i++) { [void][BtNative]::SetCursorPos([int]($q[0] + ($q[2] - $q[0]) * $i / 12), [int]($q[1] + ($q[3] - $q[1]) * $i / 12)); Start-Sleep -Milliseconds 40 }
          Start-Sleep -Milliseconds 150; [BtNative]::mouse_event(4, 0, 0, 0, [UIntPtr]::Zero)
        }
        'keys'   { [Windows.Forms.SendKeys]::SendWait($a) }
        'text'   { [Windows.Forms.SendKeys]::SendWait([regex]::Replace($a, '[+^%~(){}\[\]]', '{$0}')) }
        'sleep'  { Start-Sleep -Milliseconds ([int]$a) }
        'fg'     { 'fg: ' + [BtNative]::Txt([BtNative]::GetForegroundWindow()) }
        'activate' {
          $pr = Get-Process | ? { $_.MainWindowTitle -like "*$a*" } | select -First 1
          if ($pr) { [void][BtNative]::SetForegroundWindow($pr.MainWindowHandle); "activated $($pr.MainWindowTitle)" } else { "no window $a" }
        }
        'windows' { Get-Process | ? { $_.MainWindowTitle } | % { "win: $($_.ProcessName) | $($_.MainWindowTitle)" } }
        'ps'     { (Invoke-Expression $a | Out-String).TrimEnd() }
        default  { "unknown: $line" }
      }
    } catch { "ERR $c : $($_.Exception.Message)" }
    Start-Sleep -Milliseconds 150
  }
}
# ---- standard Windows dialogs opened by a hosted tool (Save As, message boxes). Found by window handle and control id,
# so neither the screen size nor the tool's language matters, and nothing is typed or clicked with the mouse.
function Dlg-All([string]$name = '') {
  Init-Native
  foreach ($p in @(Host-Procs $name)) { foreach ($d in [BtNative]::Dialogs([uint32]$p.ProcessId)) { , $d } }
}
function Dlg-List([string]$name = '') {
  $n = 0
  foreach ($d in @(Dlg-All $name)) {
    $n++; "DIALOG '" + [BtNative]::Txt($d) + "'"
    foreach ($k in [BtNative]::Kids($d)) {
      $c = [BtNative]::Cls($k); $t = [BtNative]::Txt($k); $id = [BtNative]::GetDlgCtrlID($k)
      if ($c -eq 'Button' -and $t) { "   button $id '$t'" } elseif ($c -eq 'Static' -and $t) { "   text '$t'" } elseif ($c -eq 'Edit') { "   edit $id '$t'" }
    }
  }
  if (-not $n) { 'no standard dialog open' }
}
# press a button of the open dialog by its control id: 1 OK/Save/Open, 2 Cancel, 6 Yes, 7 No
function Dlg-Button([int]$id, [string]$name = '') {
  foreach ($d in @(Dlg-All $name)) {
    $b = [BtNative]::GetDlgItem($d, $id)
    if ($b -ne [IntPtr]::Zero) { [void][BtNative]::PostMessage($b, 0x00F5, [IntPtr]::Zero, [IntPtr]::Zero); return "pressed $id in '" + [BtNative]::Txt($d) + "'" }
  }
  "no dialog with button $id"
}
# fill the file name of an open Save As / Open dialog and confirm it
function Dlg-File([string]$path, [string]$name = '') {
  foreach ($d in @(Dlg-All $name)) {
    $e = [BtNative]::Kids($d) | ? { [BtNative]::Cls($_) -eq 'Edit' } | select -First 1
    $b = [BtNative]::GetDlgItem($d, 1)
    if ($e -and $b -ne [IntPtr]::Zero) {
      [void][BtNative]::SendMessage($e, 0x000C, [IntPtr]::Zero, $path); Start-Sleep -Milliseconds 200
      [void][BtNative]::PostMessage($b, 0x00F5, [IntPtr]::Zero, [IntPtr]::Zero); return "file name set, confirmed '" + [BtNative]::Txt($d) + "'"
    }
  }
  'no file dialog open'
}
function Dlg-Wait([scriptblock]$test, [int]$seconds = 20) { $i = 0; while ($i -lt $seconds * 4) { if (& $test) { return $true }; Start-Sleep -Milliseconds 250; $i++ }; $false }
# Python 3 that really runs (the Windows Store stub named python.exe prints nothing useful and does not count)
function Find-Python {
  $c = @(); if ($env:BATOOL_PYTHON) { $c += $env:BATOOL_PYTHON }; $c += 'python', 'python3', 'py'
  foreach ($x in $c) { if ((Get-Command $x -ErrorAction SilentlyContinue) -and ("$(try { & $x --version 2>&1 } catch { '' })" -match '^Python 3')) { return $x } }
  $null
}
