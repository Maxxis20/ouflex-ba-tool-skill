$ErrorActionPreference='Continue'
# prelude.ps1 - helpers for scripts that run inside a hosted tool instance (hrun). $r = the tool's folder (the host sits in it), $w = the work folder.
$r=[AppDomain]::CurrentDomain.BaseDirectory.TrimEnd('\'); $w=$(if($env:BATOOL_WORK){ $env:BATOOL_WORK.TrimEnd('\') } else { 'C:\agentwork' })
$BFA=[Reflection.BindingFlags]'Instance,Public,NonPublic,DeclaredOnly'
$BFS=[Reflection.BindingFlags]'Static,Public,NonPublic,DeclaredOnly'
function TN($t){ if($t.IsGenericType){ $t.Name.Split('`')[0]+'<'+(($t.GetGenericArguments()|%{TN $_}) -join ',')+'>' } else { $t.Name } }
function GF($o,$name){ $t=$o.GetType(); while($t){ $f=$t.GetField($name,$BFA); if($f){ return ,$f.GetValue($o) }; $t=$t.BaseType }; throw "no field $name on $($o.GetType().Name)" }
function SF($o,$name,$v){ $t=$o.GetType(); while($t){ $f=$t.GetField($name,$BFA); if($f){ $f.SetValue($o,$v); return }; $t=$t.BaseType }; throw "no field $name" }
function Fields($o){ $t=$o.GetType(); while($t -and $t -ne [object]){ foreach($f in $t.GetFields($BFA)){ $v=$f.GetValue($o); "{0,-28} {1,-45} {2}" -f $t.Name,$f.Name,$(if($null -eq $v){'null'}elseif($v -is [string] -or $v.GetType().IsPrimitive -or $v.GetType().IsEnum){"$v"}elseif($v -is [System.Collections.ICollection]){(TN $v.GetType())+" count=$($v.Count)"}else{TN $v.GetType()}) }; $t=$t.BaseType } }
function Kids($c,[int]$depth=0,[int]$max=6){ foreach($k in $c.Controls){ ('  '*$depth)+$k.GetType().Name+" name='"+$k.Name+"' vis="+$k.Visible+" text='"+($k.Text -replace "`r?`n",' ').Substring(0,[Math]::Min(40,$k.Text.Length))+"'"; if($depth -lt $max){ Kids $k ($depth+1) $max } } }
function FindCtl($c,$typeName){ $res=@(); foreach($k in $c.Controls){ if($k.GetType().Name -eq $typeName){ $res+=$k }; $res+=@(FindCtl $k $typeName) }; $res }
$form=[System.Windows.Forms.Application]::OpenForms | select -First 1
function AppCanvas(){ @(AllCanvases) | ? { $_.Visible -and (GF $_ 'm_DataComponent') -and (GF $_ 'm_DataComponent').GetType().Name -eq 'CApplicationData' } | select -First 1 }
function TopCanvas(){ @(FindCtl $form 'MyCanvas') | ? { (GF $_ 'm_DataComponent') -and (GF $_ 'm_DataComponent').GetType().Name -eq 'CApplicationCollection' } | select -First 1 }
function AllCanvases(){ $l=@(); foreach($f in [System.Windows.Forms.Application]::OpenForms){ $l+=@(FindCtl $f 'MyCanvas') }; $l }
$LHT=[AppDomain]::CurrentDomain.GetAssemblies() | ? { $_.GetName().Name -eq 'LibraryHandler' } | % { $_.GetType('OuFlexTool.ApplicationBuilder.Data.CAppBuilderLibraryHandler') }
function Vec($x,$y){ $vt=([AppDomain]::CurrentDomain.GetAssemblies() | ? { $_.GetName().Name -eq 'Prodige.Drawing' }).GetType('Prodige.Drawing.Vector'); [Activator]::CreateInstance($vt,[object[]]@([single]$x,[single]$y)) }
function Open-Container($file){ $m=$LHT.GetMethods() | ? { $_.Name -eq 'OpenBaseContainerFromFile' -and $_.GetParameters().Count -eq 5 }; $a=@($file,$null,$null,$null,$null); $rc=$m.Invoke($null,$a); if($rc -ne 0){ throw "open container rc=$rc" }; ,$a }
function Open-Prim($rel){ $m=$LHT.GetMethods() | ? { $_.Name -eq 'OpenPrimitiveFromFile' -and $_.GetParameters().Count -eq 7 }; $a=@("$r\OuFlexLibrary\OumanComponents\Primitives\$rel.ouepr",$null,$null,$null,$null,$null,$null); $rc=$m.Invoke($null,$a); if($rc -ne 0){ throw "open prim $rel rc=$rc" }; ,$a }
function MethodsOf($t,$pat='.'){ ($t.GetMethods($BFA -bor [Reflection.BindingFlags]::Static) | ? { -not $_.IsSpecialName -and $_.Name -match $pat } | % { $(if($_.IsStatic){'s '}else{''})+$_.Name+'('+(($_.GetParameters()|%{ (TN $_.ParameterType)+' '+$_.Name }) -join ', ')+')'+':'+(TN $_.ReturnType) } | sort -Unique) -join "`n" }

function UW($x){ if($x -is [psobject]){ $x.PSObject.BaseObject } else { $x } }
function CM($o,$name,$a){ $o=UW $o; $args2=New-Object object[] (@($a).Count); if($null -ne $a){ $i=0; foreach($x in @($a)){ $args2[$i]=UW $x; $i++ } }; if($null -eq $a){ $args2=New-Object object[] 0 }; $ms=@($o.GetType().GetMethods([Reflection.BindingFlags]'Instance,Public,NonPublic') | ? { $_.Name -eq $name -and $_.GetParameters().Count -eq $args2.Length }); if($ms.Count -eq 0){ throw "no method $name/$($args2.Length) on $($o.GetType().Name)" }; ,$ms[0].Invoke($o,$args2) }
function Content($cv){ $cv.Picture.Elements | ? { $_.Name -eq 'Content' -or $_.GetType().Name -eq 'ComponentPicture' } | select -First 1 }  # 'Content' in builder, 'Picture001' on the device canvas
function Symbols($cv){ (Content $cv).Elements | ? { $_.GetType().Name -match 'ComponentSymbol$' } }
function Sym($cv,$compName){ Symbols $cv | ? { $_.ComponentName -eq $compName } | select -First 1 }
function SPin($sym,$pinVar){ foreach($p in @($sym.InputPins)+@($sym.OutputPins)+@($sym.HiddenInputs)+@($sym.HiddenOutputs)){ if($p -and $p.DataObject -and $p.DataObject.VariableName -eq $pinVar){ return ,$p } }; throw "no pin $pinVar on $($sym.ComponentName)" }

function LH($cv){ GF $cv 'm_AppbuilderLibraryHandler' }
function Add-Prim($cv,$libName,$typeName,$x,$y){
  $lh=LH $cv; $item=$lh.GetLibraryItem($libName,$typeName); if(-not $item){ throw "no lib item $libName/$typeName" }
  $m=$lh.GetType().GetMethod('ImportComponentToContainer'); $a=@($item,$null,$null); $rc=$m.Invoke($lh,$a); if($rc -ne 0){ throw "import $typeName rc=$rc" }
  $am=$cv.GetType().GetMethods($BFA) | ? { $_.Name -eq 'AddComponent' -and $_.GetParameters().Count -eq 4 -and $_.GetParameters()[0].ParameterType -eq [byte[]] }
  ,$am.Invoke($cv,[object[]]@($a[1],(Vec $x $y),$null,$a[2]))
}
function Inv1($o,$name,$arg){ $o=UW $o; $m=@($o.GetType().GetMethods([Reflection.BindingFlags]'Instance,Public,NonPublic') | ? { $_.Name -eq $name -and $_.GetParameters().Count -eq 1 })[0]; $aa=[object[]]::new(1); $aa[0]=$arg; if($arg -is [psobject]){ $aa[0]=$arg.PSObject.BaseObject }; ,$m.Invoke($o,$aa) }  # not via UW or $(): both unroll collections
# data-level check with messages: prints check=True/False and the tool's messages
function Check($cv){ $l=[System.Collections.Generic.List[string]]::new(); $ok=Inv1 (GF $cv 'm_DataComponent') 'CheckAll' $l; "check=$ok"; $l | ? { $_ } | % { "  msg: $_" } }
function Save-App(){ CM (FindCtl $form 'ApplicationEditor' | select -First 1) 'fastSave' $null | out-null }
function InvStr($v){ if($v -is [bool]){ if($v){'1'}else{'0'} } else { [Convert]::ToString($v,[Globalization.CultureInfo]::InvariantCulture) } }
# multilingual text: a string goes to all 15 languages; a hashtable @{'en-GB'=..;'fi-FI'=..;'sv-SE'=..} puts en-GB (else its first
# value) in every language, then each given language over it. ML-Base = the text to match by (en-GB).
function ML-Base($v){ if($v -is [System.Collections.IDictionary]){ if($v.Contains('en-GB')){ "$($v['en-GB'])" } else { "$(@($v.Values)[0])" } } else { "$v" } }
function Set-ML($mls,$v){ if($null -eq $mls -or -not $v){ return }; $mls.SetTextToAllLang((ML-Base $v)); if($v -is [System.Collections.IDictionary]){ foreach($k in $v.Keys){ if($v[$k]){ $mls.SetString("$($v[$k])","$k") } } } }
function ML-En($mls){ if(-not $mls){ return '' }; $d=GF $mls 'm_Strings'; if($d.ContainsKey('en-GB')){ $d['en-GB'] } else { "$mls" } }   # the English text, whatever the document language
function ML-Str($mls){ if(-not $mls){ return '' }; ((GF $mls 'm_Strings').GetEnumerator() | sort Key | % { "$($_.Key)=$($_.Value)" }) -join '^' }
function TXL($o){ if($o -and (HasF $o 'm_DisplayName') -and $o.DisplayName){ "TX|$($o.VariableName)|$(ML-Str $o.DisplayName)" } }   # every language of a display name
function STL($o){ if($o -and (HasF $o 'm_ActiveText')){ $a=GF $o 'm_InactiveText'; $b=GF $o 'm_ActiveText'; if($a -and $b){ $da=GF $a 'm_Strings'; $db=GF $b 'm_Strings'
    "ST|$($o.VariableName)|" + (($da.Keys | sort | % { "$_=$($da[$_])/$($db[$_])" }) -join '^') } } }   # state texts off/on per language
# constant on an unwired input pin (graphic pin from SPin); same as menu "Add constant value" + the Set value dialog
function Set-Const($cv,$pin,$value){ $pin=UW $pin; $c=$pin.ConstValueSymbol
  if(-not $c.ShowSymbol){ $old=GF $cv 'm_selectedElement'; SF $cv 'm_selectedElement' $pin; CM $cv 'InputPin_set_Delete_constValue_Click' @((GF $cv 'inputPinConstValueItem'),[EventArgs]::Empty) | out-null; SF $cv 'm_selectedElement' $old }
  if(-not $c.ShowSymbol){ throw "const not shown on $($pin.DataObject.VariableName) (wired?)" }
  $pin.DataObject.PresentValue=(InvStr $value); CM $cv 'setConstValueSymbolWidth' @($c,$pin) | out-null }
function Clear-Const($cv,$pin){ $pin=UW $pin; if($pin.ConstValueSymbol.ShowSymbol){ $old=GF $cv 'm_selectedElement'; SF $cv 'm_selectedElement' $pin; CM $cv 'InputPin_set_Delete_constValue_Click' @((GF $cv 'inputPinConstValueItem'),[EventArgs]::Empty) | out-null; SF $cv 'm_selectedElement' $old } }
# wire: $src = output-side graphic pin (block OutputPin or EditorInputPin), $dst = input-side (block InputPin or EditorOutputPin)
function Wire($cv,$src,$dst){ $src=UW $src; $dst=UW $dst
  if(-not $dst.IsFree){ throw "dst $($dst.DataObject.VariableName) not free (wired or const)" }
  $lt=$src.GetType().Assembly.GetType('OuFlex.ApplicationBuilder.GraphicsItem.ConnectorLine'); $cl=[Activator]::CreateInstance($lt)
  $cl.ActiveHost=(GF $cv 'host'); $cl.StartPin=$src; $cl.EndPin=$dst; $cl.StartPoint=$src.GetLinePoint; $cl.EndPoint=$dst.GetLinePoint
  (Content $cv).Elements.Add($cl); $cl.DrawLine(); $cl.IsActive=$true
  $src.ConnectedLines.Add($cl) | out-null; $dst.ConnectedLines.Add($cl) | out-null
  if($dst.GetType().Name -match '^Editor(Physical)?OutputPin$'){ CM $cv 'syncronizeDiagram_Data' $null | out-null }  # sets dst ParentObject; MPLEX on src is rebuilt from the drawing on reload
  else { $dst.DataObject.ReferenceObject=$src.DataObject; $dst.DataObject.State='Active' }; ,$cl }
# application interface pins ("Add input"/"Add output" buttons). $vt: 'Enum' = Digital, 'Float' = Analog (default Float). Returns the EditorInputPin/EditorOutputPin graphic.
function Add-IfPin($cv,$btn,$type,$name,$vt,$x,$y){
  $before=@((Content $cv).Elements | ? { $_.GetType().Name -eq $type })
  (FindCtl $form 'Button' | ? { $_.Name -eq $btn } | select -First 1).PerformClick()
  $e=@((Content $cv).Elements | ? { $_.GetType().Name -eq $type -and $before -notcontains $_ })[0]; if(-not $e){ throw "no new $type" }
  $o=$e.DataObject; $o.VariableName=$name; if($o.VariableName -ne $name){ throw "interface pin name $name refused (reserved?)" }; $o.DisplayName.SetTextToAllLang($name); $o.NameChangedByUser=$true; if($vt){ $o.ValueType=$vt }
  if($null -ne $x){ $e.Location=(Vec $x $y) }; ,$e }
function Add-InPin($cv,$name,$vt,$x,$y){ Add-IfPin $cv 'addInputPinButton' 'EditorInputPin' $name $vt $x $y }
function Add-OutPin($cv,$name,$vt,$x,$y){ Add-IfPin $cv 'addOutputButton' 'EditorOutputPin' $name $vt $x $y }
function IfPin($cv,$name){ (Content $cv).Elements | ? { $_.GetType().Name -match '^Editor(Input|Output)Pin$' -and $_.DataObject.VariableName -eq $name } | select -First 1 }
# show a pin-attached symbol (SetPointSymbol / MeasureSymbol ...) left of an input pin or right of an output pin, bound to $obj
function Show-PinSym($pin,$s,$obj,[switch]$right){ $s.DataObject=$obj; $s.ShowSymbol=$true; $s.Visible=$true; $b=$s.Bounds
  $x= if($right){ $pin.Locat.X + $pin.Bounds.Width } else { $pin.Locat.X - $b.Width }
  $s.Bounds=(New-Object $b.GetType() ([single]$x),([single]$pin.Locat.Y),$b.Width,$b.Height) }
# named set value (menu "Add setting value") on an unwired block input. Returns the CAnalogSetpointObject (or binary for Enum pins).
function HasF($o,$name){ $t=$o.GetType(); while($t){ if($t.GetField($name,$BFA)){ return $true }; $t=$t.BaseType }; $false }
function Add-SetValue($cv,$pin,$name,$value,$min,$max,$unit,$display,$decimals){ $pin=UW $pin; if(-not $pin.IsFree){ throw "pin not free" }
  $o=Inv1 (GF $cv 'm_DataComponent') 'AddSetvalue' $pin.DataObject
  Show-PinSym $pin $pin.SetPointSymbol $o
  if($name){ $o.VariableName=$name; $o.NameChangedByUser=$true; if($o.VariableName -ne $name){ throw "set value name $name refused" } }; if($display){ Set-ML $o.DisplayName $display }
  $an=HasF $o 'm_MinValue'   # CAnalogSetpointObject; the binary one (Enum pin) has no min/max/unit/decimals
  if($an){ if($null -ne $min){ $o.MinValue=$min }; if($null -ne $max){ $o.MaxValue=$max }; if($unit){ $o.UnitStr=$unit }; if($null -ne $decimals){ SF $o 'm_Desimals' ([byte]$decimals) } }
  if($null -ne $value){ $o.PresentValue=(InvStr $value) }; ,$o }
# measurement (menu "Add measurement") on a block output pin. Returns CAnalogMeasureObject (binary type for Enum pins).
function Add-Measure($cv,$pin,$name,$unit,$decimals,$display){ $pin=UW $pin
  $o=Inv1 (GF $cv 'm_DataComponent') 'AddMeasure' $pin.DataObject
  Show-PinSym $pin $pin.MeasureSymbol $o -right
  if($name){ $o.VariableName=$name; $o.NameChangedByUser=$true }; if($display){ Set-ML $o.DisplayName $display }
  if($name -and $o.VariableName -ne $name){ throw "measure name $name refused" }
  if(HasF $o 'm_Desimals'){ if($unit){ $o.UnitStr=$unit }; if($null -ne $decimals){ SF $o 'm_Desimals' ([byte]$decimals) } }; ,$o }
# hide unused inputs/outputs of a block (menu "Hidden pins"); only Inactive pins should be hidden. Returns the (rebuilt) symbol.
function Hide-Pins($cv,$sym,[string[]]$names,[bool]$hide=$true){ $name=$sym.ComponentName; $pd=$sym.InputPins[0].DataObject.ParentDataComponent
  # an output whose vendor measure was dropped (Curve_3p Output ...) stays State Active: only inputs are refused
  (GF $pd 'm_ObjectList') | ? { $names -contains $_.VariableName } | % { if($hide -and $_.State -eq 'Active' -and "$($_.IoType)" -ne 'Output'){ throw "$($_.VariableName) is in use" }; $_.Hidden=$hide }
  CM $cv 'updateComponent' @($sym) | out-null; ,(Sym $cv $name) }
# free text label on the canvas (menu "Add comment"); works in the builder and on the device canvas
function Add-Label($cv,$text,$x,$y){ $before=@((Content $cv).Elements | ? { $_.GetType().Name -eq 'Comment' })
  CM $cv 'AddComment' $null | out-null
  $c=@((Content $cv).Elements | ? { $_.GetType().Name -eq 'Comment' -and $before -notcontains $_ })[0]; if(-not $c){ throw "no comment created" }
  $c.CommentText=$text; $c.AdjustCommentSize(); if($null -ne $x){ $c.Location=(Vec $x $y) }; ,$c }
# ---- device level (ProjectManager, $cv = TopCanvas) ----
function DevObj($cv,$name){ (GF (GF $cv 'm_DataComponent') 'm_ObjectList') | ? { $_.VariableName -eq $name } | select -First 1 }
function PhysPin($cv,$name){ (Content $cv).Elements | ? { $_.GetType().Name -match '^EditorPhysical' -and $_.DataObject.VariableName -eq $name } | select -First 1 }
# configure a universal input/output (COu6000UnivInput/Output). $phys 'Analog'|'Digital'. $devType: EDeviceType name, e.g. NTC10, PT1000, NI1000, TX_IN (voltage), RAW, OHM, FLEX_LIN, DIGITAL_AN_IN.
# $params: full device-type string as DeviceTypeStr prints it, e.g. 'TX_IN{1,500,7,1,0,10}' (active,minChange,adSpeed,samples,minV,maxV). $polarity 'Normal' (NO) | 'Reverse' (NC).
function Set-IoType($cv,$name,$phys,$devType,$params,$min,$max,$unit,$display,$polarity){ $u=DevObj $cv $name; if(-not $u){ throw "no point $name" }
  if($phys){ $u.PhysicalType=$phys }
  if($devType -or $params){ $dt=$u.DeviceType; if($devType){ $dt.DeviceType=$devType }; if($params){ $dt.SetDevTypeParams($params,$u.IoType) }; $u.DeviceType=$dt }
  if($polarity){ $u.Polarity=$polarity }
  if($null -ne $min){ $u.MinPresentValue=$min }; if($null -ne $max){ $u.MaxPresentValue=$max }; if($unit){ $u.UnitStr=$unit }
  if($display){ Set-ML $u.DisplayName $display }; ,$u }
# one device-type parameter by name (EDevTypeParameter: MinChannelChange, ADConverterSpeed, SampleCount, MinVoltLimit, MaxVoltLimit, Min_mA_Limit, Max_mA_Limit, VoltIn0ffState, VoltInOnState, PulseScaling ...)
function Set-DevParam($cv,$name,$param,$value){ $u=DevObj $cv $name; $dt=$u.DeviceType; $e=$dt.GetUIParams()[0].Parameter.GetType(); $p=$dt.GetParam([Enum]::Parse($e,$param)); if(-not $p){ throw "no param $param on $($dt.DeviceType)" }; $p.Value=$value; $u.DeviceType=$dt }
function Get-DevParams($cv,$name){ $u=DevObj $cv $name; "$name $($u.DeviceType.DeviceType) " + (($u.DeviceType.GetUIParams() | % { "$($_.Parameter)=$($_.Value)" }) -join '; ') }
# Modbus interface document (Device > Create > Modbus interface document (html)). Opens a Save As dialog, so it is posted
# asynchronously; finish with: batool.sh dlg file 'C:\...\x.html', then batool.sh dlg button 7 ("open the file location?" -> No).
# NOTE: the export assigns Modbus registers to new points and marks the project modified.
function MenuClickHandler($itemName){ $mi=$null
  foreach($ms in (FindCtl $form 'MenuStrip')){ foreach($i in $ms.Items){ foreach($j in @($i.DropDownItems)){ if($j.Name -eq $itemName){ $mi=$j }; foreach($k in @($j.DropDownItems)){ if($k.Name -eq $itemName){ $mi=$k } } } } }
  if(-not $mi){ throw "no menu item $itemName" }
  $ev=[Windows.Forms.ToolStripItem].GetField('EventClick',[Reflection.BindingFlags]'Static,NonPublic').GetValue($null)
  ([System.ComponentModel.Component].GetProperty('Events',$BFA).GetValue($mi))[$ev] }
# PerformClick on a closed menu does nothing, so the item's Click delegate is posted instead (runs after this script returns)
function Start-MenuItem($itemName){ $h=MenuClickHandler $itemName; $form.BeginInvoke($h,[object[]]@($null,[EventArgs]::Empty)) | out-null; "posted $itemName" }
function Start-ModbusExport(){ Start-MenuItem 'modbusInterfaceToolStripMenuItem' }
# Modbus interface document without the Save As dialog (what the menu handler does after it): the device's CDescriptionFileCreator
function Export-ModbusHtml([string]$path){ $t=(MenuClickHandler 'modbusInterfaceToolStripMenuItem').Target; $dev=GF $t 'm_CurrentDevice'; if(-not $dev){ throw 'no current device' }
  $conv=@($dev.OnlineConnection.DeviceDataConverters) | ? { $_.GetType().Name -eq 'CDescriptionFileCreator' } | select -First 1; if(-not $conv){ throw 'no CDescriptionFileCreator' }
  $conv.OuFlexDevice=$dev; [void]$conv.createModbusInterfaceHtml($path,$true); if(-not (Test-Path $path)){ throw "Modbus document $path not written" }; "wrote $path $((Get-Item $path).Length)" }
# ---- SD card files (Device > "Load applications to zip file"), no mouse and no typing. Three hrun calls:
#   Start-CardExport            posts the menu item; the tool then opens a native Browse For Folder dialog
#   Card-Folder 'C:\x\card'     (runs inside that dialog's message loop) selects the folder with BFFM_SETSELECTION, presses OK;
#                               the tool writes the files unpacked into it and shows "Data loaded successfully"
#   Card-Done 'C:\x\card'       presses that message's button and lists the files
# Dialogs are found by class #32770 among this process's own windows, so a translated title does not matter.
function Init-CardNative(){ if(-not ('CardN' -as [type])){ Add-Type -TypeDefinition @'
using System;using System.Text;using System.Collections.Generic;using System.Runtime.InteropServices;
public static class CardN{
 public delegate bool EP(IntPtr h,IntPtr l);
 [DllImport("user32.dll")] static extern bool EnumWindows(EP f,IntPtr l);
 [DllImport("user32.dll",CharSet=CharSet.Unicode)] static extern int GetClassName(IntPtr h,StringBuilder s,int n);
 [DllImport("user32.dll",CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr h,StringBuilder s,int n);
 [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
 [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h,out uint p);
 [DllImport("user32.dll",CharSet=CharSet.Unicode)] public static extern IntPtr SendMessage(IntPtr h,uint m,IntPtr w,string l);
 [DllImport("user32.dll")] public static extern IntPtr GetDlgItem(IntPtr h,int id);
 [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h,uint m,IntPtr w,IntPtr l);
 public static List<IntPtr> Dialogs(uint pid){ var r=new List<IntPtr>(); EnumWindows((h,l)=>{ uint p; GetWindowThreadProcessId(h,out p);
   if(p==pid && IsWindowVisible(h)){ var c=new StringBuilder(64); GetClassName(h,c,64); if(c.ToString()=="#32770") r.Add(h); } return true; },IntPtr.Zero); return r; }
 public static string Title(IntPtr h){ var s=new StringBuilder(256); GetWindowText(h,s,256); return s.ToString(); }
}
'@ } }
function Card-Dialog(){ Init-CardNative; $d=@([CardN]::Dialogs([uint32]$PID)); if($d.Count -ne 1){ throw "expected one open dialog, found $($d.Count): $(($d | % { [CardN]::Title($_) }) -join ' | ')" }; $d[0] }
function Start-CardExport(){ Start-MenuItem 'loadApplicationsToDeviceToolStripMenuItem' }
function Card-Folder([string]$dir){ $h=Card-Dialog; $t=[CardN]::Title($h)
  if(Test-Path $dir){ if(@(Get-ChildItem $dir -Force).Count){ throw "card folder $dir is not empty" } } else { New-Item -ItemType Directory -Force $dir | Out-Null }
  if([CardN]::GetDlgItem($h,1) -eq [IntPtr]::Zero){ throw "dialog '$t' has no OK button" }
  [void][CardN]::SendMessage($h,0x467,[IntPtr]1,$dir)          # BFFM_SETSELECTIONW, wParam TRUE = lParam is a path
  [void][CardN]::PostMessage([CardN]::GetDlgItem($h,1),0x00F5,[IntPtr]::Zero,[IntPtr]::Zero); "selected $dir in '$t', OK pressed" }
function Card-Done([string]$dir){ $h=Card-Dialog; $t=[CardN]::Title($h); $b=[CardN]::GetDlgItem($h,2); if($b -eq [IntPtr]::Zero){ $b=[CardN]::GetDlgItem($h,1) }
  [void][CardN]::PostMessage($b,0x00F5,[IntPtr]::Zero,[IntPtr]::Zero); $f=@(Get-ChildItem $dir -File)
  "closed '$t'; $($f.Count) card files in ${dir}: $(($f | % Name) -join ', ')" }
# parse the exported html ('var data' block) into rows: Section, Group, then the columns of that table's header
function Get-ModbusMap($html){ $t=Get-Content -Raw -Encoding UTF8 $html; $i=$t.IndexOf("var data = '"); $j=$t.IndexOf("';",$i)
  $sec=''; $grp=''; $hdr=$null
  foreach($l in ($t.Substring($i+12,$j-$i-12) -split "\\n'\+\r?\n'")){ $k=$l.Substring(0,2); $v=$l.Substring(2)
    switch -regex ($k){ '^!\|' { $sec=$v; $grp='' } '^#\d' { $grp=$v } '^~\|' { $hdr=$v -split ';' }
      '^%\|' { $f=$v -split ';'; $o=[ordered]@{Section=$sec;Group=$grp}; for($n=0;$n -lt $hdr.Count;$n++){ $o[$hdr[$n]]=$f[$n] }; [pscustomobject]$o } } } }
# scripted changes do not mark the project modified, and Save writes Device.bin only when it is: mark it first
function Mark-Modified(){ $gs=[AppDomain]::CurrentDomain.GetAssemblies() | % { try { $_.GetTypes() } catch {} } | ? { $_.Name -eq 'CGlobalSettings' } | select -First 1
  ($gs.GetMethods($BFA -bor [Reflection.BindingFlags]::Static) | ? { $_.Name -eq 'InvokeProjectDataChangedEvent' } | select -First 1).Invoke($null,[object[]]@($null,'',$null,$true)) | out-null }
function Save-Project(){ Mark-Modified; CM $form 'saveToolStripMenuItem_Click' @($null,[EventArgs]::Empty) | out-null }
function DumpLine($cl){ $t=$cl.GetType(); while($t -and $t.Name -ne 'Picture'){ foreach($f in $t.GetFields($BFA)){ $v=$f.GetValue($cl); "{0,-14} {1,-22} {2}" -f $t.Name,$f.Name,$(if($null -eq $v){'null'}elseif($v -is [Array]){ '['+(($v|%{"$_"}) -join ' ; ')+']' }elseif($v -is [System.Collections.ICollection]){ (TN $v.GetType())+" n="+$v.Count }elseif($v.GetType().Name -match 'Pin|Symbol'){ $v.GetType().Name+":"+$v.Name+" data="+$(try{$v.DataObject.VariableName}catch{''}) }else{"$v"}) }; $t=$t.BaseType }; "name="+$cl.Name+" bounds="+$cl.Bounds+" subs="+(($cl.Elements|%{$_.GetType().Name}) -join ',')+" parent="+$cl.Parent.Name }

# ==== whole-program build helpers (generated scripts from pipeline/make_ouflex_build.py call only these) ====
# Every helper is idempotent: it looks for its result first and only adds what is missing, so a script can be rerun
# after a failure. Failures print "FAIL <op> : <reason>" and the script carries on; Build-Summary prints the counts.
# Names are case-insensitively unique per application: a clash opens a modal "Variable name X is reserved" dialog,
# so every rename is checked with NameTaken first.
$global:BS=@{add=0;skip=0;fail=0}
function BFail($what,$e){ $global:BS.fail++; "FAIL $what : $($e.Exception.Message)" }
function Build-Summary($tag){ "SUMMARY $tag add=$($global:BS.add) skip=$($global:BS.skip) fail=$($global:BS.fail)"; $global:BS=@{add=0;skip=0;fail=0} }
function DC($cv){ GF $cv 'm_DataComponent' }
function RC($cv,$name){ (GF (DC $cv) 'm_RuntimeComponents') | ? { $_.VariableName -eq $name } | select -First 1 }
function ObjByName($cv,$name){ (GF (DC $cv) 'm_ObjectList') | ? { $_.VariableName -eq $name } | select -First 1 }
function NameTaken($cv,$name){ $n=$name.ToUpperInvariant(); $d=DC $cv
  foreach($o in (GF $d 'm_ObjectList')){ if("$($o.VariableName)".ToUpperInvariant() -eq $n){ return $true } }
  foreach($c in (GF $d 'm_RuntimeComponents')){ if("$($c.VariableName)".ToUpperInvariant() -eq $n){ return $true } }; $false }
# 'block.pin' -> graphic pin of that block; '@NAME' -> interface pin NAME
function GlobPin($cv,$name){ (Content $cv).Elements | ? { $_.GetType().Name -eq 'EditorPropertypin' -and $_.GlobalPoint -and $_.DataId -eq $name } | select -First 1 }
function GPin($cv,$ref){ if($ref.StartsWith('%')){ $p=GlobPin $cv $ref.Substring(1); if(-not $p){ throw "no global pin $ref" }; return ,$p }
  if($ref.StartsWith('@')){ $p=IfPin $cv $ref.Substring(1); if(-not $p){ throw "no interface pin $ref" }; return ,$p }
  $i=$ref.LastIndexOf('.'); $b=$ref.Substring(0,$i); $s=Sym $cv $b; if(-not $s){ throw "no block $b" }; ,(SPin $s $ref.Substring($i+1)) }
# a pin context-menu handler run on $pin (no dialog for: delete set value, add/delete measure, add/delete constant)
function PinMenu($cv,$pin,$handler,$item){ $old=GF $cv 'm_selectedElement'; SF $cv 'm_selectedElement' (UW $pin); try { CM $cv $handler @((GF $cv $item),[EventArgs]::Empty) | out-null } finally { SF $cv 'm_selectedElement' $old } }
# vendor primitives that arrive with their own objects: Override (measure on Output), RunTimeCounter (set value RunTimeSet,
# measure RunTime), StateSync (set value on LocalIn). Remove those not on a $keep pin.
function Drop-Builtins($cv,$sym,[string[]]$keep){ $sym=UW $sym; $n=0
  foreach($p in @($sym.InputPins)+@($sym.HiddenInputs)){ if($p -and $p.SetPointSymbol -and $p.SetPointSymbol.ShowSymbol -and $p.DataObject.ReferenceObject -and -not ($keep -contains $p.DataObject.VariableName)){ PinMenu $cv $p 'InputPin_Add_Delete_SetValue_Click' 'inputPinSetValueItem'; $n++ } }
  foreach($p in @($sym.OutputPins)+@($sym.HiddenOutputs)){ if($p -and $p.MeasureSymbol -and $p.MeasureSymbol.ShowSymbol -and -not ($keep -contains $p.DataObject.VariableName)){ PinMenu $cv $p 'outPutPinAddDeleteMeasure_Click' 'outputPinMeasureItem'; $n++ } }; $n }
function AppName($cv,$name,$display){ try { $d=DC $cv; if($d.TypeName -ne $name){ $d.TypeName=$name; $global:BS.add++ } else { $global:BS.skip++ }; if($display){ Set-ML $d.DisplayName $display } } catch { BFail "AppName $name" $_ } }
# block: B $cv id type x y @(pins whose built-in set value/measure the plan reuses)
function B($cv,$id,$type,$x,$y,[string[]]$keep){ try { if(Sym $cv $id){ $global:BS.skip++; return }
  if(NameTaken $cv $id){ throw "name $id taken" }
  $s=Add-Prim $cv 'OumanComponents' $type $x $y; (RC $cv (UW $s).ComponentName).VariableName=$id
  if((UW $s).ComponentName -ne $id){ throw "rename to $id failed" }
  $d=Drop-Builtins $cv $s $keep; if($d){ "note B $id dropped $d built-in object(s)" }; $global:BS.add++ } catch { BFail "B $id" $_ } }
# interface pin: IP $cv in|out NAME Enum|Float x y
function IP($cv,$dir,$name,$vt,$x,$y){ try { if(IfPin $cv $name){ $global:BS.skip++; return }; if(NameTaken $cv $name){ throw "name $name taken" }
  if($dir -eq 'in'){ Add-InPin $cv $name $vt $x $y | out-null } else { Add-OutPin $cv $name $vt $x $y | out-null }; $global:BS.add++ } catch { BFail "IP $name" $_ } }
# wire: W $cv 'src.pin'|'@IN' 'dst.pin'|'@OUT'. A library default constant on dst is removed first.
function W($cv,$src,$dst){ try { $s=UW (GPin $cv $src); $d=UW (GPin $cv $dst)
  if($s.GetType().Name -eq 'EditorPropertypin'){ if($d.DataObject.ReferenceGlobal -eq $s.DataId -and $d.ConnectedLines.Count){ $global:BS.skip++; return }
    if($d.ConstValueSymbol -and $d.ConstValueSymbol.ShowSymbol){ Clear-Const $cv $d }
    Wire $cv $s $d | out-null; CM $cv 'syncronizeDiagram_Data' $null | out-null   # the tool writes the name into the input's ReferenceGlobal
    if($d.DataObject.ReferenceGlobal -ne $s.DataId){ throw "ReferenceGlobal is '$($d.DataObject.ReferenceGlobal)'" }; $global:BS.add++; return }
  if($d.GetType().Name -match '^Editor(Physical)?OutputPin$'){ if(@($d.ConnectedLines | ? { [object]::ReferenceEquals($_.StartPin,$s) }).Count){ $global:BS.skip++; return } }
  elseif($d.DataObject.ReferenceObject -and [object]::ReferenceEquals($d.DataObject.ReferenceObject,$s.DataObject)){ $global:BS.skip++; return }
  if($d.ConstValueSymbol -and $d.ConstValueSymbol.ShowSymbol){ Clear-Const $cv $d }
  Wire $cv $s $d | out-null; $global:BS.add++ } catch { BFail "W $src>$dst" $_ } }
# typed constant on an input: K $cv 'blk.pin' value
function K($cv,$dst,$v){ try { $d=UW (GPin $cv $dst); if($d.DataObject.ReferenceObject){ throw "pin is wired" }
  if($d.ConstValueSymbol.ShowSymbol -and $d.DataObject.PresentValue -eq (InvStr $v)){ $global:BS.skip++; return }; Set-Const $cv $d $v; $global:BS.add++ } catch { BFail "K $dst" $_ } }
function Set-SVFields($o,$def,$min,$max,$unit,$disp,$dec){ if($disp){ Set-ML $o.DisplayName $disp }
  if(HasF $o 'm_MinValue'){ $o.MinValue=$min; $o.MaxValue=$max; if($null -ne $unit -and "$($o.UnitStr)" -ne $unit){ $o.UnitStr=$unit }; if($null -ne $dec){ SF $o 'm_Desimals' ([byte]$dec) } }  # '' clears a vendor unit (Pid P arrives with °C)
  $o.PresentValue=(InvStr $def) }
# named set value on an input (not "SV": that is the Set-Variable alias): SETV $cv 'blk.pin' NAME default min max unit display decimals (reuses a vendor built-in on that pin)
function SETV($cv,$dst,$name,$def,$min,$max,$unit,$disp,$dec){ try { $d=UW (GPin $cv $dst); $o=$d.DataObject.ReferenceObject
  if($o -and $o.GetType().Name -match 'SetpointObject$'){ if($o.VariableName -ne $name){ if(NameTaken $cv $name){ throw "name $name taken" }; $o.VariableName=$name; $o.NameChangedByUser=$true; $global:BS.add++ } else { $global:BS.skip++ } }
  elseif($o){ throw "pin is wired" }
  else { if($d.ConstValueSymbol.ShowSymbol){ Clear-Const $cv $d }; if(NameTaken $cv $name){ throw "name $name taken" }
    $o=Inv1 (DC $cv) 'AddSetvalue' $d.DataObject; Show-PinSym $d $d.SetPointSymbol $o; $o.VariableName=$name; $o.NameChangedByUser=$true; if($o.VariableName -ne $name){ throw "name refused" }; $global:BS.add++ }
  Set-SVFields $o $def $min $max $unit $disp $dec } catch { BFail "SETV $name" $_ } }
# the same set value on a further pin (fan-out): SVL $cv 'blk.pin' NAME
function SVL($cv,$dst,$name){ try { $d=UW (GPin $cv $dst); $o=ObjByName $cv $name; if(-not $o){ throw "no set value $name" }
  if([object]::ReferenceEquals($d.DataObject.ReferenceObject,$o)){ $global:BS.skip++; return }; if($d.DataObject.ReferenceObject){ throw "pin is wired" }
  if($d.ConstValueSymbol.ShowSymbol){ Clear-Const $cv $d }; $d.DataObject.ReferenceObject=$o; $d.DataObject.State='Active'; Show-PinSym $d $d.SetPointSymbol $o; $global:BS.add++ } catch { BFail "SVL $name" $_ } }
# measurement on an output: MS $cv 'blk.pin' NAME unit decimals display (reuses a vendor built-in on that pin)
function MS($cv,$src,$name,$unit,$dec,$disp){ try { $p=UW (GPin $cv $src)
  if($p.MeasureSymbol.ShowSymbol -and $p.MeasureSymbol.DataObject){ $o=$p.MeasureSymbol.DataObject; if($o.VariableName -eq $name){ $global:BS.skip++ } else { if(NameTaken $cv $name){ throw "name $name taken" }; $o.VariableName=$name; $o.NameChangedByUser=$true; $global:BS.add++ } }
  else { if(NameTaken $cv $name){ throw "name $name taken" }; $o=Inv1 (DC $cv) 'AddMeasure' $p.DataObject; Show-PinSym $p $p.MeasureSymbol $o -right; $o.VariableName=$name; $o.NameChangedByUser=$true; if($o.VariableName -ne $name){ throw "name refused" }; $global:BS.add++ }
  if($disp){ Set-ML $o.DisplayName $disp }; if(HasF $o 'm_Desimals'){ if($unit){ $o.UnitStr=$unit }; if($null -ne $dec){ SF $o 'm_Desimals' ([byte]$dec) } } } catch { BFail "MS $name" $_ } }
# global pin (canvas menu "New global pin", without its name dialog): GLP $cv NAME x y (not "GP": that is the Get-ItemProperty alias). Reads the object called NAME that has
# "Device level global" = True anywhere in the device; the link is by name and is resolved when the project is opened.
function GLP($cv,$name,$x,$y){ try { if(GlobPin $cv $name){ $global:BS.skip++; return }
  $p=UW (CM $cv 'AddPropertyPin' @((Vec $x $y),[uint32]85,$null)); $p.GlobalPoint=$true; $p.DataId=$name; $p.PinInfo.VariableName=$name; $p.PinText='g_'+$name
  $p.Location=(Vec $x $y); $global:BS.add++ } catch { BFail "GLP $name" $_ } }
# mark a measure (or any named object of the application) as device level global: MG $cv NAME
function MG($cv,$name){ try { $o=ObjByName $cv $name; if(-not $o){ throw "no object $name" }; if($o.Global){ $global:BS.skip++ } else { $o.Global=$true; if(-not $o.Global){ throw "Global refused" }; $global:BS.add++ } } catch { BFail "MG $name" $_ } }
function LB($cv,$text,$x,$y){ try { if(@((Content $cv).Elements | ? { $_.GetType().Name -eq 'Comment' -and $_.CommentText -eq $text }).Count){ $global:BS.skip++; return }; Add-Label $cv $text $x $y | out-null; $global:BS.add++ } catch { BFail "LB $text" $_ } }
# ---- time programs (schedule objects) ----
# A time program sits on a BLOCK input pin (not an interface pin: syncronizeDiagram_Data keeps an object only when GetSymbol
# finds it on a block pin's SetPoint/ConnectPoint/Time/Measure symbol, so one on an EditorInputPin is dropped and never saved).
# Same steps as the pin menu "Add time program" (MyCanvas.addTimeprogramToolStripMenuItem_Click) without its dialogs.
function TP-Types(){ if(-not $global:__tpT){ $a=[AppDomain]::CurrentDomain.GetAssemblies() | ? { $_.GetName().Name -eq 'BacnetObjectClasses' } | select -First 1; $h=@{}
    foreach($n in 'DP_TimeValue','OUFLEX_Time','DPValue','EValueType','ETimeprogramType'){ $h[$n]=$a.GetTypes() | ? { $_.Name -eq $n } | select -First 1 }; $global:__tpT=$h }; $global:__tpT }
function TP-Entry($hhmm,$v,[string]$type){ $T=TP-Types; $h,$m=$hhmm.Split(':')
  $tm=[Activator]::CreateInstance($T.OUFLEX_Time,[object[]]@([byte]$h,[byte]$m,[byte]0,[byte]0))
  if($type -eq 'Value'){ $vt=[Enum]::Parse($T.EValueType,'Float'); $val=[single]$v } else { $vt=[Enum]::Parse($T.EValueType,'Enum'); $val=[uint32]$v }   # what WeeklyScheduleUserControl.EnumValueToDPValue writes
  $dv=[Activator]::CreateInstance($T.DPValue,[object[]]@($vt,[int16]0,[byte]0,$val)); [Activator]::CreateInstance($T.DP_TimeValue,[object[]]@($tm,$dv)) }
# week: 7 strings Monday..Sunday, each 'HH:MM=v,HH:MM=v' ('' = no switching that day). Text of a day as Dump-App prints it.
function TP-Week($s){ $d=GF (GF $s 'm_WeeklySchedule') 'm_WeeklySchedule'; (0..6 | % { ((GF $d[$_] 'm_TimeValues') | % { $t=$_.Time; '{0:D2}:{1:D2}={2}' -f [int]$t.Hour,[int]$t.Minute,$(if($_.Value.ValueType -eq 8){ InvStr $_.Value.FloatValue } else { $_.Value.U32Value }) }) -join ',' }) -join ';' }
function TP-SetWeek($s,[string[]]$week,[string]$type){ if($week.Count -ne 7){ throw "week needs 7 days, got $($week.Count)" }; $d=GF (GF $s 'm_WeeklySchedule') 'm_WeeklySchedule'
  for($i=0;$i -lt 7;$i++){ $l=GF $d[$i] 'm_TimeValues'; $l.Clear(); foreach($e in ($week[$i] -split ',' | ? { $_ })){ $k,$v=$e.Split('='); $l.Add((TP-Entry $k.Trim() $v.Trim() $type)) } } }
# TPRG $cv 'blk.pin' NAME default @(7 days) display @(@{off texts},@{on texts}) [On_Off|Value]
function TPRG($cv,$dst,$name,$def,[string[]]$week,$disp,$states,[string]$type='On_Off'){ try { $p=UW (GPin $cv $dst); $po=$p.DataObject; $s=$po.ReferenceObject
  if($s -and $s.GetType().Name -ne 'CBacnetScheduleObject'){ throw "pin is wired" }
  if(-not $s){ if($p.ConstValueSymbol.ShowSymbol){ Clear-Const $cv $p }; if(NameTaken $cv $name){ throw "name $name taken" }
    $s=Inv1 (DC $cv) 'AddTimeProgram' $po; if(-not $s){ throw "AddTimeProgram refused (not a free input pin?)" }
    $s.PositionInUse=$true; $s.PositionTable=$po.PositionTable.Clone(); $po.PositionCopied=$true
    (GF $cv 'host').ActiveDesigner.Recorder.PropertySet($p.TimeSymbol,'ShowSymbol',$true); $p.TimeSymbol.DataObject=$s
    CM $cv 'syncronizeDiagram_Data' $null | out-null; $global:BS.add++ } else { $global:BS.skip++ }
  if($s.VariableName -ne $name){ $s.VariableName=$name; $s.NameChangedByUser=$true; if($s.VariableName -ne $name){ throw "name $name refused" } }
  SF $s 'm_TimeProgramType' ([Enum]::Parse((TP-Types).ETimeprogramType,$type)); SF $s 'm_DefaultValue' (InvStr $def); $s.PresentValue=(InvStr $def)
  if($disp){ Set-ML $s.DisplayName $disp }
  if($states){ $L1=GF $s 'm_States'; $L2=GF $s 'm_Enums'; for($i=0;$i -lt 2;$i++){ if($L1 -and $i -lt $L1.Count){ Set-ML (GF $L1[$i] 'm_Text') $states[$i] }; if($L2 -and $i -lt $L2.Count -and -not [object]::ReferenceEquals($L1,$L2)){ Set-ML (GF $L2[$i] 'm_Text') $states[$i] } } }
  TP-SetWeek $s $week $type
  if(-not @((GF (DC $cv) 'm_ObjectList') | ? { [object]::ReferenceEquals($_,$s) }).Count){ throw "schedule $name not in the object list" } } catch { BFail "TPRG $name" $_ } }
function TPL($o){ if($o -and $o.GetType().Name -eq 'CBacnetScheduleObject'){ $L=GF $o 'm_States'; $st=(@(for($i=0;$i -lt $L.Count;$i++){ ML-Str (GF $L[$i] 'm_Text') })) -join '|'
    "TP|$($o.VariableName)|$(GF $o 'm_TimeProgramType')|$(GF $o 'm_DefaultValue')|$(TP-Week $o)|$(ML-En $o.DisplayName)"; TXL $o; "TS|$($o.VariableName)|$st" } }
# hide every pin that is not used: inputs Inactive, free and unwired; outputs with no wire and no measurement
function HU($cv){ try { foreach($s in @(Symbols $cv)){ $n=$s.ComponentName; $names=@()
    foreach($p in @($s.InputPins)){ if($p -and $p.DataObject.State -eq 'Inactive' -and $p.IsFree -and -not $p.DataObject.ReferenceObject -and $p.ConnectedLines.Count -eq 0){ $names+=$p.DataObject.VariableName } }
    foreach($p in @($s.OutputPins)){ if($p -and $p.ConnectedLines.Count -eq 0 -and -not $p.MeasureSymbol.ShowSymbol){ $names+=$p.DataObject.VariableName } }
    if($names.Count){ Hide-Pins $cv $s $names | out-null; $global:BS.add++ } } } catch { BFail "HU $n" $_ } }
# execution order as planned (automatic ordering off)
function EO($cv,[string[]]$ids){ try { $d=DC $cv; $d.AutoExecutionOrderGenerating=$false; $i=1; foreach($id in $ids){ $c=RC $cv $id; if(-not $c){ throw "no block $id" }; $c.SetExecutionOrder($i); $i++ }; $global:BS.add++ } catch { BFail "EO" $_ } }
function PinRef($sp){ if(-not $sp){ return '' }; $pd=$sp.ParentDataComponent; if($pd -and $pd.GetType().Name -eq 'CPrimitiveData'){ return $sp.FullVariableName }; '@'+$sp.VariableName }
# machine-readable dump of the open application (read back after a reload): B|W|K|SV|SVP|MS|IP|L|EX lines
function Dump-App($cv){ $d=DC $cv; "APP|$($d.TypeName)|$($d.DisplayName)|auto=$($d.AutoExecutionOrderGenerating)"
  $ord=@{}; $i=1; foreach($c in @($d.GetComponentsInExecOrder())){ $ord[$c.VariableName]=$c.ExecutionOrder }
  foreach($c in (GF $d 'm_RuntimeComponents')){ $s=Sym $cv $c.VariableName; "B|$($c.VariableName)|$($c.LibraryFullName)|$($c.LibraryItemVersion)|$([int]$s.Location.X)|$([int]$s.Location.Y)|$($c.ExecutionOrder)|$([int]$s.Bounds.Width)|$([int]$s.Bounds.Height)" }
  foreach($s in @(Symbols $cv)){ foreach($p in @($s.InputPins)+@($s.HiddenInputs)){ if(-not $p){ continue }; $o=$p.DataObject; $r=$o.ReferenceObject; $f="$($s.ComponentName).$($o.VariableName)"
      if($o.ReferenceGlobal){ "W|$f|%$($o.ReferenceGlobal)|lines=$($p.ConnectedLines.Count)" }
      elseif($r -and $r.GetType().Name -match 'SetpointObject$'){ "SVP|$f|$($r.VariableName)" }
      elseif($r -and $r.GetType().Name -eq 'CBacnetScheduleObject'){ "TPP|$f|$($r.VariableName)|sym=$($p.TimeSymbol.ShowSymbol)" }
      elseif($r){ "W|$f|$(PinRef $r)|lines=$($p.ConnectedLines.Count)" }
      elseif($p.ConstValueSymbol -and $p.ConstValueSymbol.ShowSymbol){ "K|$f|$($o.PresentValue)" }
    }
    foreach($p in @($s.OutputPins)+@($s.HiddenOutputs)){ if(-not $p){ continue }; $o=$p.DataObject; if($p.MeasureSymbol.ShowSymbol -and $p.MeasureSymbol.DataObject){ "MSP|$($s.ComponentName).$($o.VariableName)|$($p.MeasureSymbol.DataObject.VariableName)" } } }
  foreach($c in (GF $d 'm_RuntimeComponents')){ foreach($o in (GF $c.ComponentData 'm_ObjectList')){ if($o.Hidden){ "H|$($c.VariableName).$($o.VariableName)" } } }
  foreach($o in (GF $d 'm_ObjectList')){ $tn=$o.GetType().Name
    if($tn -match 'SetpointObject$'){ $an=HasF $o 'm_MinValue'; "SV|$($o.VariableName)|$tn|$($o.PresentValue)|$(if($an){$o.MinValue})|$(if($an){$o.MaxValue})|$(if($an){$o.UnitStr})|$(if($an){GF $o 'm_Desimals'})|$(ML-En $o.DisplayName)"; TXL $o; STL $o }
    elseif($tn -match 'MeasureObject$'){ $an=HasF $o 'm_Desimals'; "MS|$($o.VariableName)|$tn|$(if($an){$o.UnitStr})|$(if($an){GF $o 'm_Desimals'})|$(ML-En $o.DisplayName)"; TXL $o; STL $o }
    elseif($tn -eq 'CBacnetScheduleObject'){ TPL $o }
    elseif($tn -eq 'CBacnetSoftpointObject'){ $e=IfPin $cv $o.VariableName; $src=''; if($e -and $e.GetType().Name -eq 'EditorOutputPin'){ $src=PinRef $o.ParentObject }; "IP|$($o.VariableName)|$(if($e){$e.GetType().Name})|$($o.ValueType)|$src|$(if($e){[int]$e.Location.X})|$(if($e){[int]$e.Location.Y})" } }
  foreach($e in (Content $cv).Elements){ if($e.GetType().Name -eq 'EditorPropertypin' -and $e.GlobalPoint){ "GP|$($e.DataId)|$([int]$e.Location.X)|$([int]$e.Location.Y)|lines=$($e.ConnectedLines.Count)" } }
  foreach($o in (GF $d 'm_ObjectList')){ if($o.Global){ "G|$($o.VariableName)|$($o.GetType().Name)" } }
  foreach($e in (Content $cv).Elements){ if($e.GetType().Name -eq 'Comment'){ "L|$([int]$e.Location.X)|$([int]$e.Location.Y)|$($e.CommentText)" } }
  "LINES|"+@((Content $cv).Elements | ? { $_.GetType().Name -eq 'ConnectorLine' }).Count }

# ==== device-level build helpers (hosted ProjectManager, $cv = TopCanvas) ====
function Cfg(){ FindCtl $form 'OuFlexConfigurator' | select -First 1 }
# left-hand pages: tab item index 0 = Applications, 4 = System settings, 5 = Devices (item i shows m_ConfigForms[i+1])
function Show-Page([int]$i){ $t=GF (Cfg) 'Tabs'; $t.Selected=$i }
function Open-Project($flprj){ CM $form 'openProject' (,$flprj) | out-null; Show-Page 0; "opened "+$form.Text }
# forms PowerShell cannot adapt (DeviceProperties: CLS casing clash cancelButton/CancelButton) are driven by type name
function Load-UiX(){ if(-not ('UiX' -as [type])){ Add-Type -ReferencedAssemblies System.Windows.Forms,System.Drawing -TypeDefinition @"
using System; using System.Text; using System.Windows.Forms; using System.Linq;
public static class UiX {
  public static Form F(string type){ foreach(Form f in Application.OpenForms){ if(f.GetType().Name==type) return f; } return null; }
  public static string Forms(){ var sb=new StringBuilder(); foreach(Form f in Application.OpenForms) sb.AppendLine(f.GetType().FullName+" '"+f.Text+"' modal="+f.Modal); return sb.ToString(); }
  public static string Dump(string type){ var f=F(type); if(f==null) return "no form "+type; var sb=new StringBuilder(); D(f,0,sb); return sb.ToString(); }
  static void D(Control c,int d,StringBuilder sb){ foreach(Control k in c.Controls){ string x=""; var cb=k as CheckBox; if(cb!=null) x=" checked="+cb.Checked; var nu=k as NumericUpDown; if(nu!=null) x=" val="+nu.Value;
      sb.AppendLine(new string(' ',2*d)+k.GetType().Name+" name='"+k.Name+"' text='"+k.Text.Replace("\r"," ").Replace("\n"," ")+"' vis="+k.Visible+x); D(k,d+1,sb); } }
  public static Control C(string type,string name){ var f=F(type); if(f==null) throw new Exception("no form "+type); var r=f.Controls.Find(name,true); if(r.Length==0) throw new Exception("no control "+name); return r[0]; }
  public static string SetText(string type,string name,string v){ var c=C(type,name); var nu=c as NumericUpDown; if(nu!=null) nu.Value=decimal.Parse(v,System.Globalization.CultureInfo.InvariantCulture); else c.Text=v; return name+"="+c.Text; }
  public static string SetChecked(string type,string name,bool v){ var c=(CheckBox)C(type,name); c.Checked=v; return name+" checked="+c.Checked; }
  public static string Click(string type,string name){ var b=(Button)C(type,name); b.PerformClick(); return "clicked "+name; }
}
"@ } }
# Add a bus device by code (Devices page > connector > Add device), step 1: posts Devices.AddDevice(template, connector),
# which opens the modal DeviceProperties dialog. The host keeps running scripts during the modal loop, so step 2
# (Add-BusDevice-Confirm, a separate hrun) fills the dialog and presses OK.
function Add-BusDevice-Start($template,$connShort){ Show-Page 5; $dv=(GF (Cfg) 'm_ConfigForms')[6]; $tv=GF $dv 'treeView'
  $con=($tv.Nodes | ? { $_.Tag -and $_.Tag.GetType().Name -eq 'CBusConnector' -and $_.Tag.ShortName -eq $connShort }).Tag; if(-not $con){ throw "no connector $connShort" }
  $gs=[AppDomain]::CurrentDomain.GetAssemblies() | % { try { $_.GetTypes() } catch {} } | ? { $_.Name -eq 'CGlobalSettings' } | select -First 1
  $m=$dv.GetType().GetMethod('SearchDevicesInDirectory',$BFA); $list=[Activator]::CreateInstance($m.GetParameters()[0].ParameterType)
  $m.Invoke($dv,[object[]]@($list,($gs.GetProperty('TemplatePath').GetValue($null)+'\Devices'),$con.CurrentProtocol,$false)) | out-null
  $dev=$list | ? { $_.FullName -eq $template } | select -First 1; if(-not $dev){ throw "no device template $template" }
  $am=$dv.GetType().GetMethod('AddDevice',$BFA); $ft=[Func`5].MakeGenericType(@($am.GetParameters()|%{$_.ParameterType})+@([int]))
  $global:__addDev=$form.BeginInvoke([Delegate]::CreateDelegate($ft,$dv,$am),[object[]]@((UW $dev),(UW $con),$false,$false)); "posted AddDevice $template on $connShort" }
function Add-BusDevice-Confirm($name,$address,[bool]$autoCheck=$true){ Load-UiX
  if(-not [UiX]::F('DeviceProperties')){ return "FAIL no DeviceProperties dialog: "+[UiX]::Forms() }
  if($name){ [UiX]::SetText('DeviceProperties','textBoxDeviceId',$name) }; if($address){ [UiX]::SetText('DeviceProperties','numericUpDownAddress',"$address") }
  [UiX]::SetChecked('DeviceProperties','checkBoxAutoCheck',$autoCheck); [UiX]::Click('DeviceProperties','okButton') }
function Add-BusDevice-Result(){ $r=$global:__addDev; if(-not $r){ return 'no pending AddDevice' }; if(-not $r.IsCompleted){ return 'AddDevice still running' }; try { "AddDevice rc="+$form.EndInvoke($r) } catch { "FAIL AddDevice: $($_.Exception.InnerException.Message)" } finally { Show-Page 0 } }
# bus point (e.g. UI8 channel) onto the device canvas, as a drag from Object browser > Bus points does
function BP($cv,$name,$x,$y){ try { if(PhysPin $cv $name){ $global:BS.skip++; return }; $o=DevObj $cv $name; if(-not $o){ throw "no point $name" }
  $al=$null; if(-not $cv.AddBusPoint($o,(Vec $x $y),[ref]$al)){ throw "AddBusPoint false" }; $global:BS.add++ } catch { BFail "BP $name" $_ } }
# physical point configuration: IOC $cv point phys devtype min max unit decimals display polarity ('' / $null = leave)
function IOC($cv,$name,$phys,$devType,$min,$max,$unit,$dec,$disp,$pol){ try { $u=DevObj $cv $name; if(-not $u){ throw "no point $name" }
  if($phys -and "$($u.PhysicalType)" -ne $phys){ $u.PhysicalType=$phys }
  if($devType -and "$($u.DeviceType.DeviceType)" -ne $devType){ $dt=$u.DeviceType; $dt.DeviceType=$devType; $u.DeviceType=$dt }
  if($pol){ $u.Polarity=$pol }; if($null -ne $min){ $u.MinPresentValue=$min }; if($null -ne $max){ $u.MaxPresentValue=$max }; if($unit){ $u.UnitStr=$unit }
  if($null -ne $dec -and (HasF $u 'm_Desimals')){ SF $u 'm_Desimals' ([byte]$dec) }; if($disp){ Set-ML $u.DisplayName $disp }; $global:BS.add++ } catch { BFail "IOC $name" $_ } }
function IOP($cv,$name,$param,$v){ try { Set-DevParam $cv $name $param $v; $global:BS.add++ } catch { BFail "IOP $name.$param" $_ } }
# import an application file at (x, $global:DevY); advances $global:DevY under it
function IMP($cv,$name,$file,$x,$gap){ try { $s=Sym $cv $name
  if(-not $s){ $s=CM $cv 'ImportComponentFromFile' @($file,(Vec $x $global:DevY)); if(-not $s -or (UW $s).ComponentName -ne $name){ throw "import gave '$((UW $s).ComponentName)'" }; $global:BS.add++ } else { $global:BS.skip++ }
  $s=UW $s; $global:DevY=[int]($s.Location.Y+$s.Bounds.Height+$gap) } catch { BFail "IMP $name" $_ } }
# device wire: '#POINT' (physical point) or 'APP.PIN' (application interface pin)
function DPin($cv,$ref){ if($ref.StartsWith('#')){ $p=PhysPin $cv $ref.Substring(1); if(-not $p){ throw "no physical pin $ref" }; return ,$p }
  $i=$ref.IndexOf('.'); $s=Sym $cv $ref.Substring(0,$i); if(-not $s){ throw "no application $($ref.Substring(0,$i))" }; ,(SPin $s $ref.Substring($i+1)) }
function DW($cv,$src,$dst){ try { $s=UW (DPin $cv $src); $d=UW (DPin $cv $dst)
  if($d.GetType().Name -match '^EditorPhysicalOutputPin$'){ if(@($d.ConnectedLines | ? { [object]::ReferenceEquals($_.StartPin,$s) }).Count){ $global:BS.skip++; return } }
  elseif($d.DataObject.ReferenceObject -and [object]::ReferenceEquals($d.DataObject.ReferenceObject,$s.DataObject)){ $global:BS.skip++; return }
  Wire $cv $s $d | out-null; $global:BS.add++ } catch { BFail "DW $src>$dst" $_ } }
# output point in automatic: IOA $cv 'TR 3'. TR 1..4 come with "Manual control ON" = Yes in a new project, and a point in manual
# ignores the program (seen on a controller 2026-11-12: TR 3 wired to a constant 1 stayed Off until this was set to No)
function IOA($cv,$name){ try { $u=DevObj $cv $name; if(-not $u){ throw "no point $name" }; if($u.ManualControlOn){ $u.ManualControlOn=$false; $global:BS.add++ } else { $global:BS.skip++ } } catch { BFail "IOA $name" $_ } }
function AppData($cv,$app){ $c=(GF (DC $cv) 'm_RuntimeComponents') | ? { $_.VariableName -eq $app } | select -First 1; if($c){ $c.ComponentData } }
# CheckAll of every application inside the project, then the capacity check (button "Check capacity")
function Check-Project($cv){ foreach($c in (GF (DC $cv) 'm_RuntimeComponents')){ $l=[System.Collections.Generic.List[string]]::new(); $ok=Inv1 $c.ComponentData 'CheckAll' $l; "CHECK|$($c.VariableName)|$ok|"+(($l | ? { $_ }) -join ' ; ') } }
function Capacity(){ $b=FindCtl $form 'Button' | ? { $_.Name -eq 'buttonCheckSize' } | select -First 1; $b.PerformClick(); "CAPACITY|"+(FindCtl $form 'Label' | ? { $_.Name -eq 'labelUsed' } | select -First 1).Text }
function Dump-Device($cv){ $d=DC $cv; Dump-RtuSlave
  foreach($c in (GF $d 'm_RuntimeComponents')){ $s=Sym $cv $c.VariableName; "APP|$($c.VariableName)|$($c.ExecutionOrder)|$(if($s){[int]$s.Location.X})|$(if($s){[int]$s.Location.Y})|$(if($s){[int]$s.Bounds.Height})|in=$(@($s.InputPins).Count)|out=$(@($s.OutputPins).Count)" }
  foreach($s in @(Symbols $cv)){ foreach($p in @($s.InputPins)){ if(-not $p){ continue }; $r=$p.DataObject.ReferenceObject; $src=''; if($r){ $src=$(if($r.ParentDataComponent -and $r.ParentDataComponent.GetType().Name -eq 'CApplicationData'){ "$($r.ParentDataComponent.TypeName).$($r.VariableName)" } else { '#'+$r.VariableName }) }; "DW|$($s.ComponentName).$($p.DataObject.VariableName)|$src|lines=$($p.ConnectedLines.Count)" } }
  foreach($e in (Content $cv).Elements){ if($e.GetType().Name -eq 'EditorPhysicalOutputPin' -and $e.ConnectedLines.Count){ foreach($l in $e.ConnectedLines){ $sp=$l.StartPin; "DW|#$($e.DataObject.VariableName)|$($sp.DataObject.ParentDataComponent.TypeName).$($sp.DataObject.VariableName)|lines=$($e.ConnectedLines.Count)" } } }
  foreach($c in (GF $d 'm_RuntimeComponents')){ foreach($b in (GF $c.ComponentData 'm_RuntimeComponents')){ foreach($o in (GF $b.ComponentData 'm_ObjectList')){ if($o.GetType().Name -eq 'CBacnetSoftpointObject' -and $o.ReferenceGlobal){ $r=$o.ReferenceObject; "GL|$($c.VariableName)|$($b.VariableName).$($o.VariableName)|$($o.ReferenceGlobal)|$(if($r){ "$($r.ParentDataComponent.TypeName).$($r.VariableName)" })|$(if($r){ $r.Global })" } } } }
  foreach($e in (Content $cv).Elements){ if($e.GetType().Name -eq 'EditorPhysicalOutputPin'){ "MAN|$($e.DataObject.VariableName)|$($e.DataObject.ManualControlOn)" } }
  foreach($e in (Content $cv).Elements){ if($e.GetType().Name -match '^EditorPhysical'){ $u=$e.DataObject; $dt=$u.DeviceType; "IO|$($u.VariableName)|$($u.PhysicalType)|$(if($dt){$dt.DeviceType})|$($u.MinPresentValue)|$($u.MaxPresentValue)|$($u.UnitStr)|$(if(HasF $u 'm_Desimals'){GF $u 'm_Desimals'})|$($u.Polarity)|$(if($dt){($dt.GetUIParams() | % { "$($_.Parameter)=$($_.Value)" }) -join ','})|$([int]$e.Location.X)|$([int]$e.Location.Y)|$(ML-En $u.DisplayName)" ; TXL $u } } }
# Modbus RTU slave port of the device (Ouflex M_BA: COM2, A1/B1): RTUS $cv address baud parity(None|Even|Odd) stopbits
function RtuSlave(){ Show-Page 5; $dv=(GF (Cfg) 'm_ConfigForms')[6]; $tv=GF $dv 'treeView'; $r=($tv.Nodes | ? { $_.Tag -and $_.Tag.GetType().Name -eq 'CModbusRTUSlaveConfig' } | select -First 1).Tag; Show-Page 0; ,$r }
function RTUS($cv,[int]$addr,[int]$baud,[string]$parity='None',[int]$stop=1){ try { $s=RtuSlave; if(-not $s){ throw 'device has no Modbus RTU slave port' }; $p=GF $s 'm_RefSerPort'
  if($s.Address -eq $addr -and (GF $p 'm_BaudRate') -eq $baud -and "$(GF $p 'm_Parity')" -eq $parity -and (GF $p 'm_StopBits') -eq $stop -and $s.Enabled){ $global:BS.skip++; return }
  $s.Enabled=$true; $s.Address=$addr; SF $p 'm_BaudRate' ([uint32]$baud); SF $p 'm_Parity' ([Enum]::Parse((GF $p 'm_Parity').GetType(),$parity)); SF $p 'm_StopBits' ([Convert]::ChangeType($stop,(GF $p 'm_StopBits').GetType()))
  $global:BS.add++ } catch { BFail "RTUS" $_ } }
function Dump-RtuSlave(){ $s=RtuSlave; if($s){ $p=GF $s 'm_RefSerPort'; "RTUS|$($s.Enabled)|$($s.Address)|$(GF $p 'm_BaudRate')|$(GF $p 'm_DataBits')|$(GF $p 'm_Parity')|$(GF $p 'm_StopBits')|$(GF $p 'm_InterfaceName')|$(GF $p 'm_Connectors')" } }
# Modbus register of a set value / measure (in application $app) or of a physical point ($app ''): MBR $cv app name reg fmt using
function MBR($cv,$app,$name,$reg,$fmt,[bool]$using){ try { if($app){ $ad=AppData $cv $app; if(-not $ad){ throw "no application $app" }; $o=(GF $ad 'm_ObjectList') | ? { $_.VariableName -eq $name } | select -First 1 } else { $o=DevObj $cv $name }
  if(-not $o){ throw "no object $app/$name" }; $mi=$o.ModbusInterface; if(-not $mi){ throw "no ModbusInterface on $name (export once first)" }
  $mi.Using=$using; if($null -ne $reg){ $mi.ModbusRegister=[uint16]$reg }; if($fmt){ $mi.AddressFormat=$fmt }; $global:BS.add++ } catch { BFail "MBR $app/$name" $_ } }
function Dump-Modbus($cv){ foreach($c in (GF (DC $cv) 'm_RuntimeComponents')){ foreach($o in (GF $c.ComponentData 'm_ObjectList')){ $mi=$o.ModbusInterface; if($mi){ "MB|$($c.VariableName)|$($o.VariableName)|$($o.GetType().Name)|$($mi.Using)|$($mi.ModbusRegister)|$($mi.ModbusRegisterSifted)|$($mi.AddressFormat)|$($mi.ManualControlRegister)|$(if(HasF $o 'm_Desimals'){GF $o 'm_Desimals'})" } } }
  foreach($o in (GF (DC $cv) 'm_ObjectList')){ $mi=$o.ModbusInterface; if($mi -and $o.VariableName -match '^(UI|DI|R)\s?\d|FLEXUI8_UI'){ "MB||$($o.VariableName)|$($o.GetType().Name)|$($mi.Using)|$($mi.ModbusRegister)|$($mi.ModbusRegisterSifted)|$($mi.AddressFormat)|$($mi.ManualControlRegister)|$(if(HasF $o 'm_Desimals'){GF $o 'm_Desimals'})" } } }
# write the output of a script block to a UTF-8 file (dumps are read from files, not from the script's printed output)
function ToFile($path,[scriptblock]$sb){ $t=(& $sb | Out-String -Width 2000); [IO.File]::WriteAllText($path,$t,(New-Object Text.UTF8Encoding $false)); "wrote $path ($($t.Length) chars)" }
# zoom so the whole page fits the canvas window (ShowAll alone fits the width only), for screenshots
function Fit-Page($cv){ $els=@((Content $cv).Elements | ? { $_.GetType().Name -match 'Symbol$|^Editor|^Comment$' }); if(-not $els.Count){ return 'empty' }
  $x0=($els | % { $_.Bounds.X } | measure -Minimum).Minimum; $y0=($els | % { $_.Bounds.Y } | measure -Minimum).Minimum
  $x1=($els | % { $_.Bounds.X+$_.Bounds.Width } | measure -Maximum).Maximum; $y1=($els | % { $_.Bounds.Y+$_.Bounds.Height } | measure -Maximum).Maximum
  $z=[Math]::Max(5,[Math]::Min(100,[Math]::Floor(100*[Math]::Min(($cv.ClientSize.Width-20)/($x1-$x0+40),($cv.ClientSize.Height-20)/($y1-$y0+40)))))
  CM $cv 'SetZoom' @("$z%",$false) | out-null
  $m=$cv.GetType().GetMethod('PanWithElements'); $l=[Activator]::CreateInstance($m.GetParameters()[0].ParameterType); foreach($e in $els){ $l.Add($e) }; $m.Invoke($cv,@(,$l)) | out-null; "zoom $z%" }
# device level: applications run in the given order after the project's own ones (automatic ordering off; with it on,
# saving re-sorts by data flow, which can turn a planned one-cycle-old net into a direct one)
function DEO($cv,[string[]]$apps){ try { $d=DC $cv; $all=@((GF $d 'm_RuntimeComponents') | sort ExecutionOrder); $others=@($all | ? { $apps -notcontains $_.VariableName } | % { $_.VariableName })
  $d.AutoExecutionOrderGenerating=$false; $i=1; foreach($n in @($others)+@($apps)){ $c=RC $cv $n; if(-not $c){ throw "no application $n" }; $c.SetExecutionOrder($i); $i++ }; $global:BS.add++ } catch { BFail "DEO" $_ } }

# ---- reading the tool's code ----
# IL-Refs <MethodInfo>: list the calls, field accesses, strings and types a method body references, in order (a poor man's decompiler)
function IL-Refs($m){ $b=$m.GetMethodBody(); if(-not $b){ return "no body" }; $il=$b.GetILAsByteArray(); $mod=$m.Module
  if(-not $global:__ops1){ $global:__ops1=@{}; $global:__ops2=@{}; foreach($f in [Reflection.Emit.OpCodes].GetFields()){ $o=$f.GetValue($null); if($o.Size -eq 1){ $global:__ops1[[int]($o.Value -band 0xff)]=$o } else { $global:__ops2[[int]($o.Value -band 0xff)]=$o } } }
  $i=0; $out=[Collections.Generic.List[string]]::new()
  while($i -lt $il.Length){ $at=$i; $c=[int]$il[$i]; $i++; if($c -eq 0xFE){ $op=$global:__ops2[[int]$il[$i]]; $i++ } else { $op=$global:__ops1[$c] }
    $ot=$op.OperandType.ToString(); $sz=switch($ot){ 'InlineNone'{0} 'ShortInlineBrTarget'{1} 'ShortInlineI'{1} 'ShortInlineVar'{1} 'InlineVar'{2} 'InlineI8'{8} 'InlineR'{8} 'ShortInlineR'{4} 'InlineSwitch'{ 4+4*[BitConverter]::ToInt32($il,$i) } default {4} }
    if($ot -in 'InlineMethod','InlineField','InlineType','InlineTok','InlineString'){ $tok=[BitConverter]::ToInt32($il,$i)
      try{ $s=switch($ot){ 'InlineMethod'{ $r=$mod.ResolveMethod($tok); $r.DeclaringType.Name+'.'+$r.Name } 'InlineField'{ $r=$mod.ResolveField($tok); 'fld '+$r.DeclaringType.Name+'.'+$r.Name } 'InlineType'{ 'type '+$mod.ResolveType($tok).Name } 'InlineString'{ 'str "'+$mod.ResolveString($tok)+'"' } default { 'tok' } } } catch { $s="?$tok" }
      $out.Add(("{0:X4} {1} {2}" -f $at,$op.Name,$s)) }
    $i+=$sz }
  $out }
# IL-Dump <MethodInfo>: every instruction with its operand (branch targets, locals, constants, references); write it to a file (ToFile) and copy it out
function IL-Dump($m){ $b=$m.GetMethodBody(); if(-not $b){ return "no body" }; $il=$b.GetILAsByteArray(); $mod=$m.Module; [void](IL-Refs $m)
  $out=[Collections.Generic.List[string]]::new(); $out.Add("LOCALS "+(($b.LocalVariables | % { "$($_.LocalIndex):$(TN $_.LocalType)" }) -join ' ')); $i=0
  while($i -lt $il.Length){ $at=$i; $c=[int]$il[$i]; $i++; if($c -eq 0xFE){ $op=$global:__ops2[[int]$il[$i]]; $i++ } else { $op=$global:__ops1[$c] }
    $ot=$op.OperandType.ToString(); $s=''
    switch($ot){ 'InlineNone'{ } 'ShortInlineBrTarget'{ $s='-> {0:X4}' -f ($i+1+[int][sbyte]([int]$il[$i]-256*([int]$il[$i] -gt 127))); $i+=1 } 'InlineBrTarget'{ $s='-> {0:X4}' -f ($i+4+[BitConverter]::ToInt32($il,$i)); $i+=4 }
      'ShortInlineI'{ $s="$([int]$il[$i]-256*([int]$il[$i] -gt 127))"; $i+=1 } 'ShortInlineVar'{ $s="$($il[$i])"; $i+=1 } 'InlineVar'{ $s="$([BitConverter]::ToUInt16($il,$i))"; $i+=2 }
      'InlineI'{ $s="$([BitConverter]::ToInt32($il,$i))"; $i+=4 } 'InlineI8'{ $s="$([BitConverter]::ToInt64($il,$i))"; $i+=8 } 'InlineR'{ $s="$([BitConverter]::ToDouble($il,$i))"; $i+=8 } 'ShortInlineR'{ $s="$([BitConverter]::ToSingle($il,$i))"; $i+=4 }
      'InlineSwitch'{ $n=[BitConverter]::ToInt32($il,$i); $base=$i+4+4*$n; $s='['+((0..($n-1) | % { '{0:X4}' -f ($base+[BitConverter]::ToInt32($il,$i+4+4*$_)) }) -join ',')+']'; $i=$base }
      default { $tok=[BitConverter]::ToInt32($il,$i); $i+=4
        try{ $s=switch($ot){ 'InlineMethod'{ $r=$mod.ResolveMethod($tok); $r.DeclaringType.Name+'.'+$r.Name+'/'+$r.GetParameters().Count } 'InlineField'{ $r=$mod.ResolveField($tok); $r.DeclaringType.Name+'.'+$r.Name } 'InlineType'{ $mod.ResolveType($tok).Name } 'InlineString'{ '"'+$mod.ResolveString($tok)+'"' } 'InlineTok'{ "$($mod.ResolveMember($tok).Name)" } default { "tok $tok" } } } catch { $s="?$tok" } } }
    $out.Add(("{0:X4} {1} {2}" -f $at,$op.Name,$s)) }
  foreach($h in $b.ExceptionHandlingClauses){ $out.Add(("EH {0} try {1:X4}+{2:X} handler {3:X4}+{4:X}" -f $h.Flags,$h.TryOffset,$h.TryLength,$h.HandlerOffset,$h.HandlerLength)) }
  $out }
function FindMethod($asm,$type,$name){ $t=([AppDomain]::CurrentDomain.GetAssemblies() | ? { $_.GetName().Name -eq $asm }).GetType($type); @($t.GetMethods($BFA -bor [Reflection.BindingFlags]::Static) | ? { $_.Name -eq $name }) }

# ---- simulation: ApplicationDebugger.exe + virtual Ouflex C (proven 2026-11-24, see findings "Simulation") ----
# Host the debugger on one application: hstart.sh dbg ApplicationDebugger.exe 'C:\...\APP.ouear' lang=en-GB
# Load starts VirtualOuflexC.exe; Reset leaves the program HALTED (Run again, then write inputs).
function DbgForm(){ $d=[System.Windows.Forms.Application]::OpenForms | ? { $_.GetType().Name -eq 'DebuggerForm' } | select -First 1; if(-not $d){ throw 'no DebuggerForm: hstart.sh dbg ApplicationDebugger.exe <app.ouear>' }; $d }
function DbgCall($name){ $d=DbgForm; $d.GetType().GetMethod($name,$BFA).Invoke($d,[object[]]@($null,[EventArgs]::Empty)) | out-null }
function Sim-State(){ "$(GF (DbgForm) 'm_ProgramState')" }
function Sim-Objects(){ $l=GF (GF (DbgForm) 'm_LoadedApplication') 'm_ObjectList'; foreach($x in $l){ $x } }
function Sim-Obj($name){ $o=Sim-Objects | ? { $_.VariableName -eq $name } | select -First 1; if(-not $o){ throw "no point $name" }; $o }
# write = what the canvas "Set value" dialog does: set_PresentValue + CDeviceConnection.WriteProperty (inputs, set values)
function Sim-Set($name,$value){ $d=DbgForm; $o=UW (Sim-Obj $name); $d.GetType().GetMethod('myCanvas1_OnObjectValueChanged',$BFA).Invoke($d,[object[]]@($o,'PresentValue',(InvStr $value))) | out-null; "SET|$name|$(InvStr $value)" }
function Sim-Get([string[]]$names){ foreach($o in Sim-Objects){ $n=$o.VariableName; if($n -and (-not $names -or $names -contains $n)){ "VAL|$n|$(("$($o.PresentValue)") -replace ',','.')" } } }
# the speed goes to the device on a text change only, and a (re)load starts the device at 1: change it twice so it is applied
function Sim-Factor($x){ $cb=GF (DbgForm) 'toolStripComboBoxTickTimerFactor'; $v=(InvStr $x); $cb.Text=$(if($v -eq '1'){'2'}else{'1'}); $cb.Text=$v; "FACTOR|$($cb.Text)" }
function Sim-Log(){ ((GF (DbgForm) 'richTextBox1').Text -replace '\r?\n',' / ') }
function Sim-Load(){ DbgCall 'loadButton_Click'; "LOAD|$(Sim-Log)" }
function Sim-Wait($want,[int]$ms=8000){ $t0=[DateTime]::Now; while(((Sim-State) -notmatch $want) -and ([DateTime]::Now-$t0).TotalMilliseconds -lt $ms){ [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 100 }; Sim-State }
# Reset is asynchronous (RUNNING for a moment, then HALTED); Run is a toggle, so press it only when not RUNNING and wait for RUNNING
function Sim-Run(){ if((Sim-State) -ne 'RUNNING'){ DbgCall 'runButton_Click' }; $s=Sim-Wait '^RUNNING$'; if($s -ne 'RUNNING'){ throw "Sim-Run: state $s" }; "STATE|$s" }
# time program in the simulator: the virtual device evaluates it from the Windows clock only when the program starts, and a written
# value is not taken. Sim-Week rewrites the loaded application's week (7 days 'HH:MM=v,...', Monday first) and loads again.
function Sim-Week($name,[string[]]$week){ $o=UW (Sim-Obj $name); if($o.GetType().Name -ne 'CBacnetScheduleObject'){ throw "$name is not a time program" }
  TP-SetWeek $o $week "$(GF $o 'm_TimeProgramType')"; "WEEK|$name|$(TP-Week $o)"; Sim-Load }
function Sim-Reset(){ DbgCall 'resetButton_Click'; $s=Sim-Wait '^(HALTED|IDLE|WAITING)$'; "STATE|$s" }

# ---- local HMI (row display) menu, ProjectManager page 1 "Local HMI / SMS" (proven 2026-11-24, see findings "Local HMI") ----
# Paths name menus by their text in ANY language ('Heating circuit 1/Settings'); '' = main level. Source rows are found by
# point name (or curve block name) under the application, so nothing depends on the project's document language.
function Hmi-Ui(){ Show-Page 1; $ui=FindCtl $form 'CommonUIConfig' | select -First 1; if(-not $ui){ throw 'no Local HMI page (project open?)' }
  $lt=GF $ui 'multitreeLocalUi'; if(-not $lt.Parent){ (GF $ui 'splitContainer4').Panel1.Controls.Add($lt); $lt.Dock='Fill' }; $ui }  # the hosted tool can leave the tree detached
function Hmi-Name($it){ "$($it.DisplayName)" }
function Hmi-Has($it,[string]$name){ if((Hmi-Name $it) -eq $name){ return $true }; $d=GF $it 'm_DisplayName'; if($d){ foreach($v in (GF $d 'm_Strings').Values){ if($v -eq $name){ return $true } } }; $false }
function Hmi-Sub($it){ $r=GF $it 'm_ObjectPropertyRef'; if($r -and $r.BacnetObject -and $r.BacnetObject.GetType().Name -eq 'CSVObject'){ ,$r.BacnetObject } }
function Hmi-Obj($it){ $r=GF $it 'm_ObjectPropertyRef'; if($r -and $r.BacnetObject -and $r.BacnetObject.GetType().Name -ne 'CSVObject'){ ,$r.BacnetObject } }
function Hmi-Items($menu){ foreach($x in (GF $menu 'm_SubOrdinateList')){ $x } }
function Hmi-Menu($ui,[string]$path){ $m=GF $ui 'm_LocalMenu'; foreach($p in ($path -split '/')){ if(-not $p){ continue }
    $it=Hmi-Items $m | ? { Hmi-Has $_ $p } | select -First 1; if(-not $it){ throw "no menu '$p' in '$path'" }; $m=Hmi-Sub $it; if(-not $m){ throw "'$p' is not a menu" } }; ,$m }
function Hmi-TNode($nodes,$tag){ foreach($n in $nodes){ if([object]::ReferenceEquals($n.Tag,$tag)){ return ,$n }; $r=Hmi-TNode $n.Nodes $tag; if($r){ return ,$r } } }
function Hmi-Nodes($ui,$menu){ $lt=GF $ui 'multitreeLocalUi'; $menu=UW $menu; if([object]::ReferenceEquals($menu,(UW (GF $ui 'm_LocalMenu')))){ return ,$lt.Nodes }
  $n=Hmi-TNode $lt.Nodes (UW (GF $menu 'm_ParentDispItem')); if(-not $n){ throw 'menu not in the tree' }; ,$n.Nodes }
function Hmi-Refresh($ui){ foreach($m in 'updateLocalTreeView','reloadMenusToVirtualUI'){ try { CM $ui $m $null | out-null } catch {} }; Mark-Modified }
function Hmi-MLS(){ if(-not $global:__mlsT){ $global:__mlsT=[AppDomain]::CurrentDomain.GetAssemblies() | % { $_.GetType('OuFlex.Common.CMultilangString') } | ? { $_ } | select -First 1 }; [Activator]::CreateInstance($global:__mlsT) }
# own text of a menu row/folder: $tx = string (all languages) or @{'en-GB'=..;'fi-FI'=..;'sv-SE'=..} (see Set-ML)
function Hmi-Text($it,$tx){ if(-not $tx){ return }; $m=Hmi-MLS; Set-ML $m $tx; $it.DisplayNameConfig='OwnName'; $it.DisplayName=$m }
function Hmi-Src($ui,[string]$app,[string]$key){ $src=GF $ui 'multiselectTreeView'; $an=@($src.Nodes) | ? { $_.Text -eq $app -or (Hmi-Has $_.Tag $app) } | select -First 1
  if(-not $an){ throw "no application $app in the generated HMI" }
  $f={ param($nodes) foreach($n in $nodes){ $o=Hmi-Obj $n.Tag; if(($o -and $o.VariableName -eq $key) -or ("$(GF $n.Tag 'm_MenuType')" -eq 'CurveView' -and (Hmi-Has $n.Tag $key))){ return ,$n }; $r=& $f $n.Nodes; if($r){ return ,$r } } }
  $n=& $f $an.Nodes; if(-not $n){ throw "no row $key under $app" }; ,$n }
# HF <parent path> <text>: folder (submenu); HD <parent path> <app> <point|curve block> [text]: drop a generated row there and give it
# its own text. Paths name menus by their text in any language. HST <app> <point> <off text> <on text>: state texts of a binary point
# (object level: display and Web UI). Texts: string or language hashtable (Set-ML).
function HF([string]$parent,$tx){ try { $ui=Hmi-Ui; $m=Hmi-Menu $ui $parent; $b=ML-Base $tx
    if(Hmi-Items $m | ? { Hmi-Has $_ $b }){ $global:BS.skip++; return }
    $asm=$m.GetType().Assembly; $it=[Activator]::CreateInstance($asm.GetType('OuFlexTool.ApplicationBuilder.Data.BacnetObjectClasses.UIConfig.CDisplayItem'))
    $it.AllowUserAddRemoveSubMenus=$true; $it.Protected=$false; $it.ObjectPropertyRef.BacnetObject=[Activator]::CreateInstance($m.GetType())
    CM $m 'CreateMenuItem' (,$it) | out-null; Hmi-Text $it $tx; Hmi-Refresh $ui; $global:BS.add++ } catch { BFail "HF $parent/$(ML-Base $tx)" $_ } }
function HD([string]$parent,[string]$app,[string]$key,$tx){ try { $ui=Hmi-Ui; $m=Hmi-Menu $ui $parent; $b=ML-Base $tx
    if(Hmi-Items $m | ? { $o=Hmi-Obj $_; ($o -and $o.VariableName -eq $key) -or ($b -and (Hmi-Has $_ $b)) }){ $global:BS.skip++; return }
    $sn=Hmi-Src $ui $app $key; $a=New-Object object[] 4; $a[0]=(UW $sn); $a[1]=(Hmi-Nodes $ui $m); $a[2]=(UW $m); $a[3]=$true
    $tn=$ui.GetType().GetMethod('HandleDropFromGeneratedUi',$BFA).Invoke($ui,$a); if(-not $tn){ throw 'drop returned nothing' }
    Hmi-Text $tn.Tag $tx; Hmi-Refresh $ui; $global:BS.add++ } catch { BFail "HD $parent <- $app/$key" $_ } }
function Hmi-Remove([string]$path){ $ui=Hmi-Ui; $parts=$path -split '/'; $par=if($parts.Count -gt 1){ ($parts[0..($parts.Count-2)]) -join '/' }else{ '' }; $m=Hmi-Menu $ui $par; $it=Hmi-Items $m | ? { Hmi-Has $_ $parts[-1] } | select -First 1
  if(-not $it){ return "HMI|no $path" }; $m.RemoveMenuItem($it) | out-null; Hmi-Refresh $ui; "HMI|removed $path" }
function HST([string]$app,[string]$var,$off,$on){ try { Show-Page 0; $cv=TopCanvas; $ad=AppData $cv $app; if(-not $ad){ throw "no application $app" }
    $o=(GF $ad 'm_ObjectList') | ? { $_.VariableName -eq $var } | select -First 1; if(-not $o){ throw "no point $var" }; if(-not (HasF $o 'm_ActiveText')){ throw "$var is not binary" }
    $na=Hmi-MLS; Set-ML $na $off; $nb=Hmi-MLS; Set-ML $nb $on
    if((ML-Str (GF $o 'm_InactiveText')) -eq (ML-Str $na) -and (ML-Str (GF $o 'm_ActiveText')) -eq (ML-Str $nb)){ $global:BS.skip++; return }
    SF $o 'm_InactiveText' $na; SF $o 'm_ActiveText' $nb; Mark-Modified; $global:BS.add++ } catch { BFail "HST $app/$var" $_ } }
# Dump-Hmi: HMI|depth|kind|object|text (en-GB)|all languages (lang=text^..., own texts only)|state texts (binary rows: lang=off/on^...)
# kind: sys (protected main menu, not expanded), menu, curve, cpt (curve point), row
function Dump-Hmi(){ $ui=Hmi-Ui; $s={ param($menu,$d,$inCurve) foreach($it in (Hmi-Items $menu)){ $sub=Hmi-Sub $it; $o=Hmi-Obj $it; $mt="$(GF $it 'm_MenuType')"
      $own="$(GF $it 'm_DisplayNameConfig')" -eq 'OwnName'; $dn=GF $it 'm_DisplayName'
      if($d -eq 0 -and (GF $it 'm_Protected')){ "HMI|0|sys||$(Hmi-Name $it)||"; continue }
      $k=if($mt -eq 'CurveView'){ 'curve' } elseif($sub){ 'menu' } elseif($inCurve){ 'cpt' } else { 'row' }
      $en=if($own -and $dn){ (GF $dn 'm_Strings')['en-GB'] }else{ '' }
      "HMI|$d|$k|$(if($o){$o.VariableName})|$en|$(if($own){ ML-Str $dn })|$(if($o -and $k -eq 'row'){ (STL $o) -replace '^ST\|[^|]*\|','' })"
      if($sub){ & $s $sub ($d+1) ($k -eq 'curve') } } }
  & $s (GF $ui 'm_LocalMenu') 0 $false }
# ---- Web UI pages (ProjectManager "Web UI configuration" charts), proven 2026-11-24, see findings "Web UI" ----
# A page is the chart JSON the device's web UI draws; it lives in the project as COuman6000.ChartData[name]. Links name points
# like the web UI: physical "UI 4"/"AO 1"/"R1", application "C1.C1_SP". The page's link registry (object ids) is filled from the
# project here, so a page file needs links only.
function Web-Json(){ if(-not ('Newtonsoft.Json.Linq.JObject' -as [type])){ $dir=Split-Path ((([AppDomain]::CurrentDomain.GetAssemblies() | ? { $_.GetName().Name -eq 'ProjectManager' }) | select -First 1).Location); [void][Reflection.Assembly]::LoadFrom("$dir\Newtonsoft.Json.dll") } }   # loaded by the tool only once the Web UI page was opened
function Web-Dev(){ foreach($f in (GF (Cfg) 'm_ConfigForms').Values){ if($f -and (HasF $f 'm_CurrentDevice')){ $d=GF $f 'm_CurrentDevice'; if($d -and ($d.GetType().GetProperty('ChartData'))){
        if($null -eq $d.ChartData){ $d.ChartData=New-Object 'System.Collections.Generic.Dictionary[string,string]' }   # a project without pages has none yet
        return ,$d } } }; throw 'no device with charts (project open?)' }
function Web-Obj($ref){ Show-Page 0; $cv=TopCanvas; if($ref.Contains('.')){ $a,$p=$ref.Split('.',2); $ad=AppData $cv $a; if(-not $ad){ return $null }; ,((GF $ad 'm_ObjectList') | ? { $_.VariableName -eq $p } | select -First 1) } else { ,(DevObj $cv $ref) } }
function Web-Entry($ref){ $o=Web-Obj $ref; if(-not $o){ return $null }; $tn=$o.GetType().Name
  $type=if($tn -match 'SetpointObject$'){ 'Setvalue' } elseif($tn -match 'MeasureObject$'){ 'Measure' } elseif($tn -eq 'CBacnetScheduleObject'){ 'Timeprogram' } else { 'PhysicalPoint' }   # Timeprogram: as the vendor page AHU301 (objectType 17, pointId .TP)
  $suf=switch -regex ($ref){ '\.' { if($type -eq 'Setvalue'){ '.SP' } elseif($type -eq 'Timeprogram'){ '.TP' } else { '.M' }; break } '^AO' { '.C'; break } '^(R|TR) ?\d' { '.S'; break } '^(DI|PFI)' { '.I'; break } default { '.M' } }
  $e=[Newtonsoft.Json.Linq.JObject]::new(); $S={ param($v) ,([Newtonsoft.Json.Linq.JValue]::CreateString("$v")) }   # a plain string would go through JToken.Parse; ',' or PowerShell unrolls the JToken
  $e.Add('type',(& $S $type)); $e.Add('objectType',[Newtonsoft.Json.Linq.JValue]::new([long][int]$o.ObjectType)); $e.Add('id',(& $S $o.ObjectIdentifier))
  $e.Add('pId',[Newtonsoft.Json.Linq.JValue]::new([long]85)); $e.Add('deviceId',[Newtonsoft.Json.Linq.JValue]::new([long]255)); $e.Add('pointId',(& $S "$($o.VariableName)$suf"))
  $e.Add('technicalName',(& $S $ref)); $e.Add('uId',(& $S $ref)); $e.Add('displayName',(& $S $o.DisplayName)); $e.Add('allowManualControl',[Newtonsoft.Json.Linq.JValue]::new([bool]($type -notin 'Setvalue','Timeprogram'))); ,$e }
function Web-Links($j){ $l=[System.Collections.Generic.List[string]]::new(); foreach($p in @($j.SelectToken('component.components').Properties())){ $a=$p.Value.SelectToken('links'); if($a){ for($i=0;$i -lt $a.Count;$i++){ $s=$a[$i].ToString(); if($s -and -not $l.Contains($s)){ $l.Add($s) } } } }; ,$l }
# WEBP <page name> <json file (Windows path)>: put the page into the project (replaces a page of that name), registry filled from the project
function WEBP([string]$name,[string]$file){ try { Web-Json; $j=[Newtonsoft.Json.Linq.JObject]::Parse([IO.File]::ReadAllText($file,[Text.Encoding]::UTF8))
    $reg=[Newtonsoft.Json.Linq.JObject]::new(); $ids=[Newtonsoft.Json.Linq.JArray]::new(); $miss=@()
    foreach($r in (Web-Links $j)){ $e=Web-Entry $r; if($e){ $reg.Add($r,$e); $ids.Add([Newtonsoft.Json.Linq.JValue]::CreateString($r)) } else { $miss+=$r } }
    if($miss){ throw "no such point(s): $($miss -join ', ')" }
    $lk=[Newtonsoft.Json.Linq.JObject]::new(); $lk.Add('allIds',$ids); $lk.Add('links',$reg); $j.Remove('link') | out-null; $j.Add('link',$lk)
    $txt=$j.ToString([Newtonsoft.Json.Formatting]::None); $d=Web-Dev
    if($d.ChartData.ContainsKey($name) -and $d.ChartData[$name] -eq $txt){ $global:BS.skip++; return }
    $d.ChartData.Remove($name) | out-null; $d.AddChart($name,$txt,$true) | out-null; Mark-Modified; $global:BS.add++ } catch { BFail "WEBP $name" $_ } }
# Dump-Web: WEB|page|components|links ; WL|page|link|registry id|object id now|type   (registry id = object id: the link resolves)
function Dump-Web(){ Web-Json; $d=Web-Dev; foreach($k in @($d.ChartData.Keys)){ if($k -eq 'OumanTrend'){ continue }; $j=[Newtonsoft.Json.Linq.JObject]::Parse($d.ChartData[$k]); $reg=$j.SelectToken('link.links'); $ls=Web-Links $j
    "WEB|$k|$(@($j.SelectToken('component.components').Properties()).Count)|$($ls.Count)"
    foreach($r in $ls){ $e=$reg.SelectToken("['$r']"); $o=Web-Obj $r; "WL|$k|$r|$(if($e){$e.SelectToken('id').ToString()})|$(if($o){$o.ObjectIdentifier})|$(if($e){$e.SelectToken('type').ToString()})" } } }
# ---- Trends (proven 2026-11-24, see findings "Trends") ----
# The device has 200 trend logs (CTrendObject Trend_1..200; the first ones preassigned to the physical points). A log is in use when its
# reference (the point's FullVariableName: "UI 4", "C1.C1_SP") resolves and that point has TrendLogEnabled. Groups for the web UI's
# trend view are the JSON array ChartData["OumanTrend"] (at most 30 points per group, one graph per y axis).
function Trend-Logs($cv){ foreach($x in (GF (DC $cv) 'm_ObjectList')){ if($x.GetType().Name -eq 'CTrendObject'){ $x } } }
function Trend-Ref($ref){ $o=Web-Obj $ref; if(-not $o){ throw "no point $ref" }; $o }
# TRD <point> <interval s> <log length>: a trend log on the point (reuses the one already pointing at it); returns nothing, counts add/skip
function TRD([string]$ref,[int]$interval,[int]$length){ try { $o=Trend-Ref $ref; Show-Page 0; $cv=TopCanvas; $full="$($o.FullVariableName)"; if(-not $full){ $full=$o.VariableName }
    $log=Trend-Logs $cv | ? { "$(GF $_ 'm_TrendRefObjectVariableName')" -eq $full } | select -First 1
    $same=$log -and $o.TrendLogEnabled -and (GF $log 'm_TrendLogEnabled') -and (GF $log 'm_TrendSampleInterval') -eq $interval -and (GF $log 'm_TrendLogBufferSize') -eq $length
    if($same){ $global:BS.skip++; return }
    if(-not $log){ $log=Trend-Logs $cv | ? { $_.IsFree } | select -First 1; if(-not $log){ throw 'no free trend log (200 in use)' } }
    $o.TrendLogEnabled=$true; SF $o 'm_TrendSampleInterval' ([uint16]$interval); SF $o 'm_TrendLogBufferSize' $length
    SF $log 'm_TrendRefObjectVariableName' $full; SF $log 'm_TrendLogEnabled' $true; SF $log 'm_TrendSampleInterval' ([uint16]$interval); SF $log 'm_TrendLogBufferSize' $length
    if($log.IsFree){ throw "trend log for $full did not take" }; Mark-Modified; $global:BS.add++ } catch { BFail "TRD $ref" $_ } }
function Trend-LogOf($cv,$ref){ $o=Trend-Ref $ref; $full="$($o.FullVariableName)"; if(-not $full){ $full=$o.VariableName }; Trend-Logs $cv | ? { "$(GF $_ 'm_TrendRefObjectVariableName')" -eq $full -and -not $_.IsFree } | select -First 1 }
# TGRP <group name> <axes>: axes = @( @{name='°C'; points=@('UI 4','C1.C1_SP')}, @{name='%'; points=@('C1.C1_VALVE')} ); replaces a group of that name
function TGRP([string]$name,$axes){ try { Web-Json; Show-Page 0; $cv=TopCanvas; $d=Web-Dev; $J=[Newtonsoft.Json.Linq.JObject]; $V={ param($v) ,([Newtonsoft.Json.Linq.JValue]::CreateString("$v")) }
    if($d.ChartData.ContainsKey('OumanTrend') -and $d.ChartData['OumanTrend']){ $arr=[Newtonsoft.Json.Linq.JArray]::Parse($d.ChartData['OumanTrend']) } else { $arr=[Newtonsoft.Json.Linq.JArray]::new() }   # not $arr=if(..): PowerShell unrolls an empty JArray to $null
    $g=$J::new(); $g.Add('uid',(& $V ("dh"+[guid]::NewGuid().ToString('N').Substring(0,12)))); $g.Add('name',(& $V $name))
    $data=[Newtonsoft.Json.Linq.JArray]::new(); $graphs=[Newtonsoft.Json.Linq.JArray]::new(); $n=0; $ai=0; $pos=@(@('left',0),@('right',0),@('left',50),@('right',50))
    foreach($ax in $axes){ $ids=[Newtonsoft.Json.Linq.JArray]::new()
      foreach($r in $ax.points){ $o=Trend-Ref $r; $log=Trend-LogOf $cv $r; if(-not $log){ throw "no trend log on $r (TRD first)" }; $n++
        $e=$J::new(); $e.Add('id',[Newtonsoft.Json.Linq.JValue]::new([long]$log.ObjectIdentifier)); $e.Add('name',(& $V $o.DisplayName)); $e.Add('color',(& $V ''))
        $e.Add('technicalName',(& $V $r)); $e.Add('pointId',(& $V ("$($o.VariableName)" + $(if($r.Contains('.')){ if($o.GetType().Name -match 'Setpoint'){'.SP'}else{'.M'} } elseif($r -match '^AO'){'.C'} elseif($r -match '^(R|TR) ?\d'){'.S'} elseif($r -match '^(DI|PFI)'){'.I'} else {'.M'}))))
        $data.Add($e); $ids.Add([Newtonsoft.Json.Linq.JValue]::new([long]$log.ObjectIdentifier)) }
      $y=$J::new(); $y.Add('id',(& $V "yAxis-$($ai+1)")); $y.Add('name',(& $V $ax.name)); $y.Add('position',(& $V $pos[$ai % 4][0])); $y.Add('offset',[Newtonsoft.Json.Linq.JValue]::new([long]$pos[$ai % 4][1])); $y.Add('min',(& $V '')); $y.Add('max',(& $V ''))
      $gr=$J::new(); $gr.Add('type',(& $V 'line')); $gr.Add('data',$ids); $gr.Add('yAxis',$y); $gr.Add('enabled',[Newtonsoft.Json.Linq.JValue]::new($true)); $graphs.Add($gr); $ai++ }
    if($n -gt 30){ throw "$n points: a group takes at most 30" }
    $g.Add('data',$data); $g.Add('graphs',$graphs)
    $old=@($arr | ? { $_.SelectToken('name').ToString() -eq $name }); if($old){ $g['uid']=$old[0].SelectToken('uid'); foreach($x in $old){ $x.Remove() } }
    $arr.Add($g); $txt=$arr.ToString([Newtonsoft.Json.Formatting]::None)
    if($d.ChartData.ContainsKey('OumanTrend') -and $d.ChartData['OumanTrend'] -eq $txt){ $global:BS.skip++; return }
    $d.ChartData['OumanTrend']=$txt; Mark-Modified; $global:BS.add++ } catch { BFail "TGRP $name" $_ } }
# Dump-Trend: TL|log|id|ref|interval|length|enabled|point trend on   (logs in use) ; TG|group|axis|technicalName|log id|log ref now
function Dump-Trend(){ Web-Json; Show-Page 0; $cv=TopCanvas
  foreach($l in (Trend-Logs $cv)){ if(-not $l.IsFree){ $r="$(GF $l 'm_TrendRefObjectVariableName')"; $o=Web-Obj $r; "TL|$($l.VariableName)|$($l.ObjectIdentifier)|$r|$(GF $l 'm_TrendSampleInterval')|$(GF $l 'm_TrendLogBufferSize')|$(GF $l 'm_TrendLogEnabled')|$(if($o){$o.TrendLogEnabled})" } }
  $d=Web-Dev; if($d.ChartData.ContainsKey('OumanTrend')){ $byId=@{}; foreach($l in (Trend-Logs $cv)){ $byId["$($l.ObjectIdentifier)"]=$l }
    foreach($g in [Newtonsoft.Json.Linq.JArray]::Parse($d.ChartData['OumanTrend'])){ $gn=$g.SelectToken('name').ToString(); $names=@{}; foreach($e in $g.SelectToken('data')){ $names[$e.SelectToken('id').ToString()]=$e.SelectToken('technicalName').ToString() }
      foreach($gr in $g.SelectToken('graphs')){ $an=$gr.SelectToken('yAxis.name').ToString(); foreach($i in $gr.SelectToken('data')){ $id=$i.ToString(); $l=$byId[$id]; "TG|$gn|$an|$($names[$id])|$id|$(if($l -and -not $l.IsFree){ GF $l 'm_TrendRefObjectVariableName' })" } } } } }

# ==== new project by code (Project > New project and the dialogs that follow) ====
# The dialogs are modal, but the host keeps running scripts inside their message loop, so each step is its own hrun:
#   hrun: New-Project-Start                                  (a freshly started ProjectManager instance, no project open)
#   hrun, repeated until it prints "NEWPROJECT done":  New-Project-Step 'Name' 'C:\agentwork\proj' 'Ouflex A'
# Result: <dir>\<Name>\<Name>.flprj and Devices\Device1\Device.bin, saved. Some of these forms cannot be touched from
# PowerShell (members that differ only in letter case), so they are driven from a small C# class by type and control name.
function Load-UiP(){ if(-not ('UiP' -as [type])){ Add-Type -ReferencedAssemblies System.Windows.Forms,System.Drawing -TypeDefinition @"
using System; using System.Text; using System.Windows.Forms;
public static class UiP {
  static Form F(string type){ foreach(Form f in Application.OpenForms){ if(f.GetType().Name==type) return f; } return null; }
  static Control C(string type,string name){ var f=F(type); if(f==null) throw new Exception("no form "+type); var r=f.Controls.Find(name,true); if(r.Length==0) throw new Exception("no control "+name+" on "+type); return r[0]; }
  public static bool Has(string type){ return F(type)!=null; }
  public static string Text(string type,string name,string v){ var c=C(type,name); c.Text=v; return name+"="+c.Text; }
  public static string Radio(string type,string name){ var r=(RadioButton)C(type,name); r.Checked=true; return name+" checked="+r.Checked; }
  public static string Click(string type,string name){ ((Button)C(type,name)).PerformClick(); return "clicked "+name; }
  public static string Pick(string type,string name,string prefix){ var lb=(ListBox)C(type,name);
    for(int i=0;i<lb.Items.Count;i++){ if(lb.Items[i].ToString().StartsWith(prefix)){ lb.SelectedIndex=i; return "selected "+lb.Items[i]; } }
    var sb=new StringBuilder("FAIL no device type starting '"+prefix+"'; offered:"); foreach(object o in lb.Items) sb.Append(" ["+o+"]"); return sb.ToString(); }
}
"@ } }
function New-Project-Start(){ Start-MenuItem 'newToolStripMenuItem' }
function New-Project-Step($name,$dir,$devType='Ouflex A'){ Load-UiP
  if([UiP]::Has('NewProjectForm')){ [UiP]::Text('NewProjectForm','PrjNameTextBox',$name); [UiP]::Text('NewProjectForm','PrjDirectoryTextBox',$dir); [UiP]::Click('NewProjectForm','buttonOk'); return }
  if([UiP]::Has('AddNewDeviceDialog')){ [UiP]::Radio('AddNewDeviceDialog','radNew'); [UiP]::Click('AddNewDeviceDialog','btnOK'); return }
  if([UiP]::Has('SelectDevTypeForm')){ $s=[UiP]::Pick('SelectDevTypeForm','DevTypesListBox',"$devType ("); $s
    if($s -match '^FAIL'){ [UiP]::Click('SelectDevTypeForm','cancelButton') } else { [UiP]::Click('SelectDevTypeForm','okButton') }; return }
  if([UiP]::Has('DeviceProperties')){ [UiP]::Click('DeviceProperties','buttonOk'); return }
  if($form.Text -match [regex]::Escape("$dir\$name") -and (TopCanvas)){ Save-Project; "NEWPROJECT done: "+$form.Text } else { 'NEWPROJECT waiting: '+$form.Text } }
