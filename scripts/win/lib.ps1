# lib.ps1 - the tool's DLLs in a plain PowerShell, no tool window: load and dump saved project files. Dot-sourced by `cli.ps1 run`.
if(-not $BT_DIR){ . "$PSScriptRoot\env.ps1" }
$r=$BT_DIR; $w=$BT_WORK; $global:BT_R=$r
if(-not $r){ throw 'BA Tool not found: set BATOOL_DIR to its folder' }
Set-Location $r; [Environment]::CurrentDirectory=$r
$global:__h=[ResolveEventHandler]{ param($s,$e) $n=(New-Object Reflection.AssemblyName $e.Name).Name; foreach($x in '.dll','.exe'){ $p=Join-Path $global:BT_R ($n+$x); if(Test-Path $p){ return [Reflection.Assembly]::LoadFrom($p) } }; $null }
[AppDomain]::CurrentDomain.add_AssemblyResolve($global:__h)
function Load-Bin($p){ $bf=New-Object Runtime.Serialization.Formatters.Binary.BinaryFormatter; $fs=[IO.File]::OpenRead($p); try{ ,$bf.Deserialize($fs) } finally { $fs.Close() } }
function Save-Bin($o,$p){ $bf=New-Object Runtime.Serialization.Formatters.Binary.BinaryFormatter; $fs=[IO.File]::Create($p); try{ $bf.Serialize($fs,$o) } finally { $fs.Close() } }
$global:compact=$true
$global:BFA=[Reflection.BindingFlags]'Instance,Public,NonPublic,DeclaredOnly'
function Get-AllFields($t){ $l=@(); while($t -and $t -ne [object]){ $l+=$t.GetFields($global:BFA) | ? { -not $_.IsNotSerialized }; $t=$t.BaseType }; $l }
function GF($o,$name){ $t=$o.GetType(); while($t){ $f=$t.GetField($name,$global:BFA); if($f){ return ,$f.GetValue($o) }; $t=$t.BaseType }; throw "no field $name" }
function SF($o,$name,$v){ $t=$o.GetType(); while($t){ $f=$t.GetField($name,$global:BFA); if($f){ $f.SetValue($o,$v); return }; $t=$t.BaseType }; throw "no field $name" }
function TN($t){ if($t.IsGenericType){ $t.Name.Split('`')[0]+'<'+(($t.GetGenericArguments()|%{TN $_}) -join ',')+'>' } else { $t.Name } }
function Is-Leaf($o){ $t=$o.GetType(); $t.IsPrimitive -or $t.IsEnum -or $o -is [string] -or $o -is [decimal] -or $o -is [datetime] -or $o -is [timespan] -or $o -is [guid] -or $t.Namespace -eq 'System.Drawing' -or $t.Namespace -eq 'System.Net' }
function Fmt-Leaf($o){ if($o -is [string]){ $s=$o; if($s.Length -gt 100){$s=$s.Substring(0,100)+"...(len $($o.Length))"}; '"'+($s -replace "`r?`n",'\n')+'"' } elseif($o -is [System.Drawing.Image]){ "<img>" } else { "$o" } }
function Dump($o,[int]$depth=2,[int]$maxItems=3,[string]$ind='',$skip=@()){
  if($null -eq $global:__ids){ $global:__ids=New-Object Runtime.Serialization.ObjectIDGenerator }
  if($null -eq $o){ return 'null' }
  if(Is-Leaf $o){ return (Fmt-Leaf $o) }
  $t=$o.GetType(); $first=$false; $id=$global:__ids.GetId($o,[ref]$first)
  if($t.FullName -eq 'OuFlex.Common.CMultilangString'){ $d=GF $o (Get-AllFields $t | ? { $_.FieldType.Name -like 'Dictionary*' } | select -First 1).Name; $k=@($d.Keys)|select -First 1; return "ML{"+(($d.GetEnumerator()|select -First 2|%{ $_.Key+'='+$_.Value }) -join '; ')+"}" }
  $hdr="<"+(TN $t)+" #$id>"
  if(-not $first){ return $hdr+' (seen)' }
  if($depth -le 0){ if($o -is [System.Collections.ICollection]){ return $hdr+" count=$($o.Count)" }; return $hdr }
  $sb=New-Object Text.StringBuilder; [void]$sb.Append($hdr)
  if($o -is [System.Collections.IDictionary]){ [void]$sb.Append(" count=$($o.Count)"); $i=0; foreach($k in @($o.Keys)){ if($i -ge $maxItems){ [void]$sb.Append("`n$ind  ..."); break }; [void]$sb.Append("`n$ind  [$k] = "+(Dump $o[$k] ($depth-1) $maxItems "$ind  " $skip)); $i++ }; return $sb.ToString() }
  if($o -is [System.Collections.IEnumerable]){ $c=0; if($o -is [System.Collections.ICollection]){$c=$o.Count}; [void]$sb.Append(" count=$c"); $et=$t.GetElementType(); if($et -and $et.IsPrimitive){ [void]$sb.Append(" ["+((@($o)|select -First 16) -join ',')+"]"); return $sb.ToString() }; $i=0; foreach($e in $o){ if($i -ge $maxItems){ [void]$sb.Append("`n$ind  ..."); break }; [void]$sb.Append("`n$ind  [$i] = "+(Dump $e ($depth-1) $maxItems "$ind  " $skip)); $i++ }; return $sb.ToString() }
  foreach($f in (Get-AllFields $t)){ if($skip -contains $f.Name){ continue }; $v=$f.GetValue($o); if($global:compact){ if($null -eq $v){continue}; if($v -is [string] -and $v -eq ''){continue}; if(($v -is [ValueType]) -and -not $v.GetType().IsEnum -and ($v -is [IConvertible]) -and ($v.GetType().IsPrimitive) -and ([double]$v -eq 0)){continue}; if($v -is [System.Collections.ICollection] -and $v.Count -eq 0){continue}; if($f.Name -eq 'm_PositionRefsNum'){continue}; if($v.GetType().Name -eq 'CMultilangString'){ $dd=Dump $v 1; if($dd -eq 'ML{}'){continue} } }; $n=$f.Name -replace '^<(.+)>k__BackingField$','$1'; [void]$sb.Append("`n$ind  $n : "+(Dump $v ($depth-1) $maxItems "$ind  " $skip)) }
  $sb.ToString()
}
