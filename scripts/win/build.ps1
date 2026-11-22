# build.ps1 - build one Ouflex program in BA Tool from its plan, from nothing, and verify it. Dot-sourced by cli.ps1
# (`cli.ps1 build <program dir>`, or ..\build.sh <program dir>).
#   <program dir> holds program.json and the plan (plan.json). Outputs: <program dir>\<out>\ (build scripts, expected.json)
#   and <out>\out\ (dumps read back from the tool, *.verify.txt, screenshots, the Modbus document).
# Environment:
#   STAGES      default "gen apps device modbus filecheck shots"; add "deliver" to copy the built project to paths.deliver
#   APPS        limit the apps stage to these applications, e.g. "TC1_DHW ALARM"
#   KEEP_GOING  1 = do not stop at the first difference
#   KEEP_OPEN   1 = leave the hosted tool windows open at the end (the open project stays locked until they are closed)
#   VERIFY      off = write the dumps only and skip the Python comparison (for a machine without Python: copy <out>\out
#               elsewhere and run pipeline/verify_ouflex_build.py there)
# Stops at the first failed script or failed verification and says what differs. Every helper the generated scripts
# call is idempotent, so a rerun after a failure adds only what is missing.
# Uses hosted instances 'ab' (ApplicationBuilder) and 'pm' (ProjectManager). The device stage stops every hosted
# instance: a ProjectManager that still has a project open keeps it locked. paths.project is removed and made again.

function Read-Json([string]$path) {
  Add-Type -AssemblyName System.Web.Extensions
  $s = New-Object System.Web.Script.Serialization.JavaScriptSerializer; $s.MaxJsonLength = [int]::MaxValue; $s.RecursionLimit = 200
  $s.DeserializeObject([IO.File]::ReadAllText($path, [Text.Encoding]::UTF8))
}
function Q([string]$s) { "'" + ($s -replace "'", "''") + "'" }

function Build-Program([string]$pdir) {
  $ErrorActionPreference = 'Continue'
  if (-not (Test-Path (Join-Path $pdir 'program.json'))) { Write-Host "no program.json in $pdir"; return 1 }
  $pdir = (Resolve-Path $pdir).Path.TrimEnd('\')
  $pipe = Join-Path $BT_SKILL 'pipeline'
  $t0 = Get-Date
  $script:failed = $null
  function Say([string]$m) { Write-Host ('[{0,4}s] {1}' -f [int]((Get-Date) - $t0).TotalSeconds, $m) }
  function Stop-Build([string]$m) { Say "STOP: $m"; $script:failed = $m }
  $stages = @($(if ($env:STAGES) { $env:STAGES } else { 'gen apps device modbus filecheck shots' }) -split '\s+' | ? { $_ })
  function Has([string]$s) { $stages -contains $s }
  $keep = [bool]$env:KEEP_GOING
  $verify = "$env:VERIFY" -ne 'off'
  $py = Find-Python
  if (-not $py -and ($verify -or (Has 'gen'))) { Write-Host 'Python 3 not found: the generator and the verifier need it (or run with STAGES without gen and VERIFY=off)'; return 1 }
  $env:PYTHONIOENCODING = 'utf-8'; $env:PYTHONUTF8 = '1'

  $cfg = Read-Json (Join-Path $pdir 'program.json')
  $P = $cfg['paths']; if (-not $P) { Write-Host 'program.json has no "paths"'; return 1 }
  foreach ($k in 'apps', 'project', 'base') { if (-not $P[$k]) { Write-Host "program.json: paths.$k missing"; return 1 } }
  if ($P['project'] -notmatch '^[A-Za-z]:\\[^\\]+\\.') { Write-Host "program.json: paths.project must be a folder at least two levels below a drive (it is removed and made again): $($P['project'])"; return 1 }
  $name = if ($cfg['name']) { $cfg['name'] } else { Split-Path -Leaf $pdir }
  $B = Join-Path $pdir $(if ($cfg['out']) { $cfg['out'] } else { 'build' }); $O = Join-Path $B 'out'
  $WAPPS = $P['apps']; $WPROJ = $P['project']; $WORIG = $P['base']
  $WMB = if ($P['modbus_doc']) { $P['modbus_doc'] } else { "${WPROJ}_modbus" }
  $TPL = "$BT_DIR\Template\NewApplication.ouear"
  Say "program $name ($pdir) -> $WPROJ"

  # run a PowerShell snippet on a hosted instance; $false on FAIL / ERR / EXC / TIMEOUT lines
  function HRun([string]$inst, [string]$code, [string]$tag = 'snippet') {     # not "H": that is PowerShell's Get-History alias, and aliases win
    $out = Host-Run $inst $code $tag $(if ($env:TICKS) { [int]$env:TICKS } else { 330 })
    [IO.File]::WriteAllText((Join-Path $O "log_$tag.txt"), $out, (New-Object Text.UTF8Encoding $false))
    $script:last = $out
    $lines = @($out -split "`r?`n")
    if ($lines -match '^(FAIL|ERR:|EXC:|TIMEOUT)') {
      $lines | ? { $_ -match '^(FAIL|ERR|EXC|TIMEOUT|  )' } | select -First 30 | % { Write-Host $_ }
      if ($out -match 'TIMEOUT') { Write-Host ('a dialog may be open: ' + ((Dlg-List) -join ' ; ')); Write-Host ('screenshot ' + (Screen-Shot (Join-Path $O "timeout_$tag.png"))) }
      return $false
    }
    $lines | ? { $_ -match '^(SUMMARY|check=|note|posted|AddDevice|clicked|opened|CAPACITY|wrote|NEWPROJECT)' } | select -First 20 | % { Write-Host $_ }
    $true
  }
  function Start-Inst([string]$inst, [string]$exe, [string[]]$a = @()) { (Host-Start $inst $exe $a) -match 'timer armed' }
  function Verify([string[]]$a, [string]$file) {
    if (-not $verify) { Say "   not verified here (VERIFY=off): python pipeline/verify_ouflex_build.py <program dir> $($a -join ' ')"; return $true }
    $res = & $py (Join-Path $pipe 'verify_ouflex_build.py') $pdir @a 2>&1 | % { "$_" }; $rc = $LASTEXITCODE
    [IO.File]::WriteAllLines($file, [string[]]@($res), (New-Object Text.UTF8Encoding $false)); $res | % { Write-Host $_ }
    ($rc -eq 0) -or $keep
  }
  function Shot([string]$inst, [string]$png) {
    [void](HRun $inst "`$f=[System.Windows.Forms.Application]::OpenForms[0]; `$f.WindowState='Maximized'; `$f.TopMost=`$true; `$f.Activate(); `$f.TopMost=`$false; `$c=`$(if('$inst' -eq 'pm'){ TopCanvas } else { AppCanvas }); Fit-Page `$c" "shot_$png")
    Start-Sleep -Milliseconds 900
    $p = @(Host-Procs $inst) | select -First 1
    Say ('screenshot ' + (Screen-Shot (Join-Path $O "$png.png") $(if ($p) { [int]$p.ProcessId } else { 0 })))
  }
  function Flprj([string]$dir) { if ($P['flprj']) { return $P['flprj'] }; $f = Get-ChildItem "$dir\*.flprj" -ErrorAction SilentlyContinue | select -First 1; if ($f) { $f.Name } else { 'Project1.flprj' } }
  # Device > Create > Modbus interface document (html): the menu handler opens Save As, then asks whether to open the folder
  function Export-Modbus([string]$html, [string]$tag) {
    if (-not (HRun pm 'Start-ModbusExport' "mbx_$tag")) { return $false }
    if (-not (Dlg-Wait { (Dlg-File $html 'pm') -match 'confirmed' } 20)) { Write-Host ((Dlg-List 'pm') -join ' ; '); return $false }
    [void](Dlg-Wait { (Test-Path $html) -and ((Dlg-Button 7 'pm') -match 'pressed') } 40)      # "open the file location?" -> No
    Start-Sleep -Milliseconds 800
    Test-Path $html
  }

  New-Item -ItemType Directory -Force $O | Out-Null
  if (Has 'gen') {
    Say 'generate'
    & $py (Join-Path $pipe 'make_ouflex_build.py') $pdir 2>&1 | % { Write-Host "$_" }
    if ($LASTEXITCODE -ne 0) { Stop-Build 'generator failed'; return 1 }
    New-Item -ItemType Directory -Force $O | Out-Null
  }
  if (-not (Test-Path (Join-Path $B 'expected.json'))) { Stop-Build "no $B\expected.json: run the gen stage"; return 1 }
  $exp = Read-Json (Join-Path $B 'expected.json')
  $applist = if ($env:APPS) { @($env:APPS -split '\s+' | ? { $_ }) } else { @($exp['manifest'] | % { $_['app'] }) }

  if (Has 'apps') {
    New-Item -ItemType Directory -Force $WAPPS | Out-Null
    foreach ($app in $applist) {
      $m = $exp['manifest'] | ? { $_['app'] -eq $app } | select -First 1
      if (-not $m) { Stop-Build "no application $app in the plan"; return 1 }
      Say "== ${app}: fresh application file"
      $file = "$WAPPS\$app.ouear"
      Copy-Item $TPL $file -Force; Remove-Item "$file*.bak" -ErrorAction SilentlyContinue
      if (-not (Start-Inst ab 'ApplicationBuilder.exe' @($file, 'mode=1', 'lang=en-GB'))) { Stop-Build 'builder did not start'; return 1 }
      foreach ($sc in $m['scripts']) {
        Say "   $sc"
        if (-not (HRun ab (". " + (Q (Join-Path $B "apps\$sc"))) ($sc -replace '\.ps1$', ''))) { Stop-Build "$sc failed (a rerun is safe: every helper is idempotent)"; return 1 }
      }
      [void](HRun ab '$cv=AppCanvas; Check $cv; Save-App; "saved"' "${app}_save")
      if ($script:last -notmatch 'check=True') { Write-Host $script:last; Stop-Build "${app}: the tool's check is not True"; return 1 }
      # An application that reads globals cannot be reopened on its own: outside a project the names do not resolve, the
      # tool shows "Errors in opening: Reference pin error" and drops the links (the saved file stays intact). Such an
      # application is read back from the session that built it; its round trip is proven at device level instead.
      $gp = $exp['apps'][$app]['globalpins']
      if ($gp -and $gp.Count) { Say '   saved; reads globals, so read back without reopening (round trip checked at device level)' }
      else {
        Say '   saved; reopen and read back'
        if (-not (Start-Inst ab 'ApplicationBuilder.exe' @($file, 'mode=1', 'lang=en-GB'))) { Stop-Build 'builder did not restart'; return 1 }
      }
      $dump = Join-Path $O "$app.dump.txt"
      if (-not (HRun ab "`$cv=AppCanvas; ToFile $(Q $dump) { Dump-App `$cv; Check `$cv }" "${app}_dump")) { Stop-Build 'dump failed'; return 1 }
      if (-not (Verify @('app', $app, $dump) (Join-Path $O "$app.verify.txt"))) { Stop-Build "$app differs from the plan (see $O\$app.verify.txt)"; return 1 }
      if (Has 'shots') { Shot ab $app }
    }
  }
  if (Has 'device') {
    Say "== device level: base project $WORIG"
    [void](Host-Stop)
    $made = $false
    if ($WORIG -eq $WPROJ) { Say "   in place: $WPROJ is its own base, no copy" }
    elseif ($WORIG -eq 'new') {
      # a New project made by code, named like the project folder (findings: "New project by code")
      $n = 0; while ((Test-Path $WPROJ) -and $n -lt 15) { Remove-Item -Recurse -Force $WPROJ -ErrorAction SilentlyContinue; if (Test-Path $WPROJ) { Start-Sleep 1 }; $n++ }
      if (Test-Path $WPROJ) { Stop-Build "could not remove the old $WPROJ (open in a tool window?)"; return 1 }
      $pn = Split-Path -Leaf $WPROJ; $pd = Split-Path -Parent $WPROJ; $dt = if ($cfg['device_type']) { $cfg['device_type'] } else { 'Ouflex A' }
      New-Item -ItemType Directory -Force $pd | Out-Null
      Say "   new project $pn ($dt) in $pd"
      if (-not (Start-Inst pm 'ProjectManager.exe')) { Stop-Build 'ProjectManager did not start'; return 1 }
      if (-not (HRun pm 'New-Project-Start' 'np0')) { Stop-Build 'New project did not start'; return 1 }
      for ($i = 1; $i -le 10 -and -not $made; $i++) {
        Start-Sleep -Milliseconds 1500
        if (-not (HRun pm "New-Project-Step $(Q $pn) $(Q $pd) $(Q $dt)" "np$i")) { Stop-Build 'New project failed'; return 1 }
        if ($script:last -match 'NEWPROJECT done') { $made = $true }
      }
      if (-not $made -or -not (Test-Path "$WPROJ\Devices\Device1\Device.bin")) { Write-Host ((Dlg-List 'pm') -join ' ; '); Stop-Build "the new project was not made (reference/new-program.md says how to make one by hand and build in place)"; return 1 }
    }
    else {
      if (-not (Test-Path "$WORIG\Devices\Device1\Device.bin")) { Stop-Build "base project $WORIG missing: run setup, or make an empty project there by hand (reference/new-program.md)"; return 1 }
      $n = 0; while ((Test-Path $WPROJ) -and $n -lt 15) { Remove-Item -Recurse -Force $WPROJ -ErrorAction SilentlyContinue; if (Test-Path $WPROJ) { Start-Sleep 1 }; $n++ }
      if (Test-Path $WPROJ) { Stop-Build "could not remove the old $WPROJ (open in a tool window?)"; return 1 }
      New-Item -ItemType Directory -Force (Split-Path $WPROJ) | Out-Null
      Copy-Item -Recurse $WORIG $WPROJ
      if (-not (Test-Path "$WPROJ\Devices\Device1\Device.bin")) { Stop-Build 'could not make a fresh copy of the base project'; return 1 }
    }
    $flprj = "$WPROJ\$(Flprj $WPROJ)"
    if (-not $made) {
      if (-not (Start-Inst pm 'ProjectManager.exe')) { Stop-Build 'ProjectManager did not start'; return 1 }
      if (-not (HRun pm "Open-Project $(Q $flprj)" 'open')) { Stop-Build 'open failed'; return 1 }
    }
    foreach ($mod in @($exp['program']['modules'])) {
      if (-not $mod -or -not $mod['template']) { continue }
      $mn = $mod['name']; $first = "$($mod['object'])".Replace('{}', '1')
      Say "   add module $($mod['template']) on $($mod['connector']) (Devices.AddDevice + its properties dialog, by code)"
      if (-not (HRun pm "`$global:__addDev=`$null; if(DevObj (TopCanvas) $(Q $mn)){ 'note $mn present' } else { Add-BusDevice-Start $(Q $mod['template']) $(Q $mod['connector']) }" "mod_${mn}_a")) { Stop-Build 'module start failed'; return 1 }
      Start-Sleep 2
      if (-not (HRun pm "if(`$global:__addDev){ Add-BusDevice-Confirm $(Q $mn) $($mod['address']) `$true } else { 'note $mn present' }" "mod_${mn}_b")) { Stop-Build 'module dialog failed'; return 1 }
      Start-Sleep 2
      if (-not (HRun pm "Add-BusDevice-Result; if(-not (DevObj (TopCanvas) $(Q $first))){ 'FAIL module points missing' }" "mod_${mn}_c")) { Stop-Build 'module not added'; return 1 }
    }
    foreach ($sc in 'dev_2_io', 'dev_3_import', 'dev_4_wires') {
      Say "   $sc"
      if (-not (HRun pm (". " + (Q (Join-Path $B "$sc.ps1"))) $sc)) { Stop-Build "$sc failed"; return 1 }
    }
    $appre = (@($exp['device']['apps']) | % { [regex]::Escape($_) }) -join '|'
    if (-not (HRun pm "`$cv=TopCanvas; Check-Project `$cv | ? { `$_ -match '^CHECK\|($appre)\|' -and `$_ -notmatch '\|True\|' } | % { `"FAIL `$_`" }; Save-Project; 'saved'" 'dev_save')) { Stop-Build 'device check/save failed'; return 1 }
    Say '   saved; reopen and read back'
    if (-not (Start-Inst pm 'ProjectManager.exe')) { Stop-Build 'ProjectManager did not restart'; return 1 }
    if (-not (HRun pm "Open-Project $(Q $flprj)" 'reopen')) { Stop-Build 'reopen failed'; return 1 }
    $dump = Join-Path $O 'device.dump.txt'
    if (-not (HRun pm "`$cv=TopCanvas; ToFile $(Q $dump) { Dump-Device `$cv; Check-Project `$cv; Capacity }" 'dev_dump')) { Stop-Build 'device dump failed'; return 1 }
    if (-not (Verify @('device', $dump) (Join-Path $O 'device.verify.txt'))) { Stop-Build "device level differs from the plan (see $O\device.verify.txt)"; return 1 }
    if (Has 'shots') { Shot pm 'device' }
  }
  if (Has 'modbus') {
    Say '== Modbus: export once (assigns registers), set the plan''s registers, save, reopen, export, compare'
    $flprj = "$WPROJ\$(Flprj $WPROJ)"
    if (-not @(Host-Procs 'pm').Count) { if (-not (Start-Inst pm 'ProjectManager.exe')) { Stop-Build 'ProjectManager did not start'; return 1 } }
    [void](HRun pm "if(-not (TopCanvas)){ Open-Project $(Q $flprj) } else { 'open' }" 'mb0')
    New-Item -ItemType Directory -Force (Split-Path $WMB) | Out-Null
    Remove-Item "${WMB}*.html" -ErrorAction SilentlyContinue
    if (-not (Export-Modbus "${WMB}_pre.html" 'pre')) { Stop-Build "Modbus export ${WMB}_pre.html not written"; return 1 }
    if (-not (HRun pm (". " + (Q (Join-Path $B 'modbus_set.ps1')) + "; Save-Project; 'saved'") 'mbset')) { Stop-Build 'register assignment failed'; return 1 }
    if (-not (Start-Inst pm 'ProjectManager.exe')) { Stop-Build 'ProjectManager did not restart'; return 1 }
    if (-not (HRun pm "Open-Project $(Q $flprj)" 'mbreopen')) { Stop-Build 'reopen failed'; return 1 }
    if (-not (Export-Modbus "${WMB}.html" 'post')) { Stop-Build "Modbus export ${WMB}.html not written"; return 1 }
    $dump = Join-Path $O 'modbus.dump.txt'; $tsv = Join-Path $O 'modbus.tsv'
    if (-not (HRun pm "`$cv=TopCanvas; ToFile $(Q $dump) { Dump-Modbus `$cv }; `$r=@(Get-ModbusMap $(Q "${WMB}.html")); `$h=`$r[0].PSObject.Properties.Name; ToFile $(Q $tsv) { (`$h -join `"``t`"); foreach(`$x in `$r){ (`$h | % { `$x.`$_ }) -join `"``t`" } }" 'mbdump')) { Stop-Build 'modbus dump failed'; return 1 }
    Copy-Item "${WMB}.html" (Join-Path $O ((Split-Path -Leaf $WMB) + '.html')) -Force
    if (-not (Verify @('modbus', $dump, $tsv) (Join-Path $O 'modbus.verify.txt'))) { Stop-Build "Modbus map differs from the rule (see $O\modbus.verify.txt)"; return 1 }
  }
  if (Has 'filecheck') {
    Say '== saved project read with the tool''s DLLs, no tool window involved (projdump.ps1)'
    $dump = Join-Path $O 'file.dump.txt'; $tmp = Join-Path $O '_projdump.ps1'
    [IO.File]::WriteAllText($tmp, "`$PROJ=$(Q $WPROJ); `$DUMPOUT=$(Q $dump)`r`n. $(Q (Join-Path $PSScriptRoot 'projdump.ps1'))`r`n", (New-Object Text.UTF8Encoding $true))
    $res = & "$PSHOME\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'cli.ps1') run $tmp 2>&1 | % { "$_" }      # not $o: PowerShell names ignore case, that is $O
    Remove-Item $tmp -ErrorAction SilentlyContinue
    if (-not (@($res) -match 'wrote')) { $res | % { Write-Host $_ }; Stop-Build 'projdump failed'; return 1 }
    @($res) -match 'wrote' | % { Write-Host $_ }
    if (-not (Verify @('file', $dump) (Join-Path $O 'file.verify.txt'))) { Stop-Build "saved project differs from the plan (see $O\file.verify.txt)"; return 1 }
  }
  if (Has 'deliver') {
    $WDEL = $P['deliver']; if (-not $WDEL) { Stop-Build 'program.json has no paths.deliver'; return 1 }
    Say "== deliver: copy $WPROJ to $WDEL, open the copy, check"
    [void](Host-Stop); Start-Sleep 1
    if (Test-Path $WDEL) { Remove-Item -Recurse -Force $WDEL }
    New-Item -ItemType Directory -Force (Split-Path $WDEL) | Out-Null
    Copy-Item -Recurse $WPROJ $WDEL; Get-ChildItem $WDEL -Recurse -Filter *.bak | Remove-Item
    if (-not (Test-Path "$WDEL\Devices\Device1\Device.bin")) { Stop-Build 'copy failed'; return 1 }
    if (-not (Start-Inst pm 'ProjectManager.exe')) { Stop-Build 'ProjectManager did not start'; return 1 }
    $dump = Join-Path $O 'deliver.dump.txt'
    if (-not (HRun pm "Open-Project $(Q "$WDEL\$(Flprj $WDEL)"); `$cv=TopCanvas; ToFile $(Q $dump) { Check-Project `$cv; Capacity }" 'deliver')) { Stop-Build 'delivered copy did not open'; return 1 }
    Get-Content $dump | ? { $_ -match '^CHECK|^CAPACITY' } | % { Write-Host $_ }
  }
  # a ProjectManager that stays open keeps the project locked (its .flprj reads as 0 bytes): close the hosted windows
  if (-not $env:KEEP_OPEN) { [void](Host-Stop 'ab'); [void](Host-Stop 'pm') }
  Say "DONE ($($stages -join ' '))"
  0
}
