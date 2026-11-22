# projdump.ps1 (run with `batool.sh run`; lib.ps1 is loaded first): read a saved project's Device.bin with the tool's DLLs,
# without the tool running, and write its logic as lines to $DUMPOUT. Set $PROJ (project folder) and $DUMPOUT in a
# small script that then dot-sources this file; the build does exactly that:
#   FA|app|order                       application (runtime component of the device)
#   FB|app|block|library|version|exec  block
#   FW|app|dst block.pin|source        wire into an input (source = block.pin or @interfacepin or #physical or app.pin)
#   FK|app|dst block.pin|value         constant on an input
#   FSVP|app|block.pin|setvalue        set value on an input
#   FSV|app|name|type|default|min|max|unit|decimals
#   FMS|app|name|type|unit|decimals ; FMSP|app|block.pin|measure (from the measure's ParentObject)
#   FIP|app|name|In/Out|valuetype
#   FGL|app|dst block.pin|global name|object it resolved to in the file (app.name)
$proj = if($PROJ){ $PROJ } elseif($env:PROJ){ $env:PROJ } else { throw 'projdump: set $PROJ to the project folder' }
$dumpout = if($DUMPOUT){ $DUMPOUT } else { Join-Path $proj 'file.dump.txt' }
$dev = Load-Bin "$proj\Devices\Device1\Device.bin"
function Fld($o,$n){ try { GF $o $n } catch { $null } }
function Ref($sp,$app){ if(-not $sp){ return '' }; $p=Fld $sp 'm_ParentDataComponent'; if(-not $p){ try { $p=$sp.ParentDataComponent } catch {} }
  $pn = if($p){ $p.GetType().Name } else { '' }
  if($pn -eq 'CPrimitiveData'){ return $sp.FullVariableName }
  if($pn -eq 'CApplicationData'){ if($p.TypeName -eq $app){ return '@'+$sp.VariableName }; return $p.TypeName+'.'+$sp.VariableName }
  return '#'+$sp.VariableName }
$out = New-Object Collections.Generic.List[string]
$top = GF $dev 'm_Applications'
foreach($a in (GF $top 'm_RuntimeComponents')){ $ad=$a.ComponentData; $an=$a.VariableName; $out.Add("FA|$an|$($a.ExecutionOrder)")
  foreach($o in (GF $ad 'm_ObjectList')){ $tn=$o.GetType().Name
    if($tn -match 'SetpointObject$'){ $an2=$tn -eq 'CAnalogSetpointObject'; $out.Add("FSV|$an|$($o.VariableName)|$tn|$($o.PresentValue)|$(if($an2){$o.MinValue})|$(if($an2){$o.MaxValue})|$(if($an2){$o.UnitStr})|$(if($an2){Fld $o 'm_Desimals'})") }
    elseif($tn -match 'MeasureObject$'){ $an2=$tn -eq 'CAnalogMeasureObject'; $out.Add("FMS|$an|$($o.VariableName)|$tn|$(if($an2){$o.UnitStr})|$(if($an2){Fld $o 'm_Desimals'})")
      $po=$o.ParentObject; if($po){ $out.Add("FMSP|$an|$(($po.FullVariableName) -replace "^$an\.",'')|$($o.VariableName)") } }
    elseif($tn -eq 'CBacnetSoftpointObject'){ $r=$o.ReferenceObject; $out.Add("FIP|$an|$($o.VariableName)|$($o.IoType)|$($o.ValueType)|$(if("$($o.IoType)" -eq 'Input'){ Ref $r '' })") } }
  foreach($c in (GF $ad 'm_RuntimeComponents')){ $pd=$c.ComponentData; $bn=$c.VariableName
    $out.Add("FB|$an|$bn|$($c.LibraryFullName)|$($c.LibraryItemVersion)|$($c.ExecutionOrder)")
    foreach($p in (GF $pd 'm_ObjectList')){ if($p.GetType().Name -ne 'CBacnetSoftpointObject'){ continue }; $r=$p.ReferenceObject; $f="$bn.$($p.VariableName)"
      if("$($p.IoType)" -eq 'Input'){
        $rg=$null; try { $rg=$p.ReferenceGlobal } catch {}
        if($rg){ $out.Add("FW|$an|$f|%$rg"); $out.Add("FGL|$an|$f|$rg|$(if($r){ Ref $r '' })") }
        elseif($r -and $r.GetType().Name -match 'SetpointObject$'){ $out.Add("FSVP|$an|$f|$($r.VariableName)") }
        elseif($r){ $out.Add("FW|$an|$f|$(Ref $r $an)") }
        elseif("$($p.State)" -eq 'Active'){ $out.Add("FK|$an|$f|$($p.PresentValue)") } }
      } } }   # measurements are found from their ParentObject above: an output feeding two objects keeps no ReferenceObject in the file
New-Item -ItemType Directory -Force (Split-Path $dumpout) | Out-Null
[IO.File]::WriteAllLines($dumpout,$out,(New-Object Text.UTF8Encoding $false))
"wrote $dumpout lines=$($out.Count)"
