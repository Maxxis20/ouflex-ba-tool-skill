# env.ps1 - the settings everything on the Windows side shares. Dot-sourced by cli.ps1, lib.ps1 and catalogue.ps1.
#   BATOOL_DIR   folder of the BA Tool installation. Default: the newest C:\Ouman\OuflexBATool_* that holds
#                ProjectManager.exe, then the install location Windows has registered for the tool.
#   BATOOL_WORK  work folder, default C:\agentwork (hosted instances, application files, built projects, base project)
#   BATOOL_HOST  file name of the compiled host inside the tool folder, default AgentHost.exe
$BT_WORK = if ($env:BATOOL_WORK) { $env:BATOOL_WORK.TrimEnd('\') } else { 'C:\agentwork' }
$BT_HOST = if ($env:BATOOL_HOST) { $env:BATOOL_HOST } else { 'AgentHost.exe' }
$BT_SKILL = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
function Find-BaTool {
  if ($env:BATOOL_DIR) { return $env:BATOOL_DIR.TrimEnd('\') }
  $c = @(Get-ChildItem 'C:\Ouman' -Directory -Filter 'OuflexBATool_*' -ErrorAction SilentlyContinue | ? { Test-Path (Join-Path $_.FullName 'ProjectManager.exe') })
  if ($c.Count) { return ($c | sort { try { [version]($_.Name -replace '^OuflexBATool_', '') } catch { [version]'0.0' } } | select -Last 1).FullName }
  foreach ($k in 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*') {
    foreach ($p in @(Get-ItemProperty $k -ErrorAction SilentlyContinue | ? { "$($_.DisplayName)" -match 'Ouflex' -and $_.InstallLocation })) {
      $d = "$($p.InstallLocation)".TrimEnd('\'); if (Test-Path (Join-Path $d 'ProjectManager.exe')) { return $d }
    }
  }
  $null
}
$BT_DIR = Find-BaTool
function BaTool-Version { if ($BT_DIR -and (Test-Path "$BT_DIR\ProjectManager.exe")) { (Get-Item "$BT_DIR\ProjectManager.exe").VersionInfo.FileVersion } }
