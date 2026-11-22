# catalogue.ps1 <reference dir> <pin_roles.json> : read every block of the installed BA Tool library and write
#   blocks.json          the block catalogue the Python pipeline needs (types, versions, pins)
#   primitive-pins.txt   every block with all its pins, one line per pin, for reading
#   primitive-docs.txt   the documentation text stored inside the block files
# These three files are made from Ouman's library on this machine. They are not part of the skill and must not be
# published: .gitignore keeps them out. Run by `setup`; needs no tool window (the library files are read with the
# tool's own DLLs in a plain PowerShell).
param([string]$RefDir, [string]$RolesFile = '')
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\lib.ps1"
if (-not $r) { 'FAIL BA Tool not found'; exit 1 }
Add-Type -AssemblyName System.Windows.Forms
$LH = [Reflection.Assembly]::LoadFrom("$r\LibraryHandler.dll")
$H = $LH.GetType('OuFlexTool.ApplicationBuilder.Data.CAppBuilderLibraryHandler')
$m7 = $H.GetMethods() | ? { $_.Name -eq 'OpenPrimitiveFromFile' -and $_.GetParameters().Count -eq 7 }
# multi-language string -> ordered table language -> text (empty texts left out)
function MLD($ml) { $h = [ordered]@{}; if ($null -eq $ml) { return $h }; foreach ($fl in (Get-AllFields $ml.GetType())) { $v = $fl.GetValue($ml); if ($v -is [System.Collections.IDictionary]) { foreach ($k in @($v.Keys)) { if ($v[$k]) { $h[$k] = [string]$v[$k] } } } }; $h }
# html body -> plain text. Only real html tags are removed: the texts hold conditions such as "A < B" and "Input > Max".
$TAGS = 'p|br|div|span|b|i|u|s|strong|em|font|table|tbody|thead|tr|td|th|ul|ol|li|h\d|a|img|html|head|body|meta|title|link|sub|sup|hr|pre|code|center|small|big|blockquote|o:p'
function Strip($txt) {
  $t = [regex]::Replace($txt, '(?is)<(script|style)\b.*?</\1>', '')
  $t = [regex]::Replace($t, '(?is)<!--.*?-->|<![a-z][^>]*>|<\?xml[^>]*>', '')
  $t = [regex]::Replace($t, '(?i)<br\s*/?>|</p>|</tr>|</h\d>|</li>|</div>', "`n")
  $t = [regex]::Replace($t, '(?i)</t[dh]>', ' | ')
  $t = [regex]::Replace($t, "(?i)</?(?:$TAGS)(?:\s[^<>]*)?/?>", '')
  $t = [System.Net.WebUtility]::HtmlDecode($t)
  $t = [regex]::Replace($t, '[ \t ]+', ' ')
  [regex]::Replace($t, '(\s*\n\s*)+', "`n").Trim()
}
$rb = New-Object Windows.Forms.RichTextBox
function RtfText($rtf) { try { $rb.Rtf = $rtf; [regex]::Replace(($rb.Text -replace "`r", ''), '(\s*\n\s*)+', "`n").Trim() } catch { '' } }
function Norm($s) { ([regex]::Replace("$s", '\s+', ' ')).Trim() }
function Num($s) { $s = "$s"; if ($s -match '^-?\d+,\d+$') { $s.Replace(',', '.') } else { $s } }
function VKey($v) { $p = @("$v".Split('.') | % { if ($_ -match '^\d+$') { [int]$_ } else { 0 } }); '{0:D6}.{1:D6}.{2:D6}' -f $(if ($p.Count -gt 0) { $p[0] } else { 0 }), $(if ($p.Count -gt 1) { $p[1] } else { 0 }), $(if ($p.Count -gt 2) { $p[2] } else { 0 }) }

$roles = $null
if ($RolesFile -and (Test-Path $RolesFile)) { $roles = (Get-Content -Raw -Encoding UTF8 $RolesFile | ConvertFrom-Json).roles }
$FOLDERS = 'Math and logic components', 'Time based components', 'Process and loop components', 'Switch and conversion components', 'Counter components', 'Alarms', 'Other components'
$lib = "$r\OuFlexLibrary"
$all = New-Object System.Collections.ArrayList; $failed = 0; $idx = 0
foreach ($f in (Get-ChildItem $lib -Recurse -Filter *.ouepr | sort FullName)) {
  $a = @($f.FullName, $null, $null, $null, $null, $null, $null)
  try { [void]$m7.Invoke($null, $a) } catch { $failed++; continue }
  $p = $a[2]; $doc = $a[3]; if (-not $p) { $failed++; continue }
  $pins = New-Object System.Collections.ArrayList
  foreach ($o in (GF $p 'm_ObjectList')) {
    if ($o.GetType().Name -ne 'CBacnetSoftpointObject') { continue }
    $en = @(); try { foreach ($e in $o.Enums) { $en += ("$e") } } catch {}
    $disp = MLD (GF $o 'm_DisplayName'); $desc = MLD (GF $o 'm_Description')
    $cat = "$($o.ObjectCategory)"; $min = "$($o.MinValue)"; $max = "$($o.MaxValue)"; $ranged = -not ($min -eq '0' -and $max -eq '0')
    [void]$pins.Add([ordered]@{
        name = $o.VariableName; dir = $(switch ("$($o.IoType)") { 'Input' { 'in' } 'Output' { 'out' } default { 'internal' } }); type = "$($o.ValueType)"
        default = (Num $o.PresentValue); unit = "$($o.UnitStr)".Trim(); min = $(if ($ranged) { Num $min } else { $null }); max = $(if ($ranged) { Num $max } else { $null })
        decimals = [int]$o.Desimals; hidden = [bool]$o.Hidden; internal = [bool]$o.InternalPin; category = $cat
        role = $(if ($cat -eq 'PrimitiveParameter') { 'state' } else { 'signal' })
        display_en = "$($disp['en-GB'])"; description_en = "$($desc['en-GB'])"; display_fi = "$($disp['fi-FI'])"; description_fi = "$($desc['fi-FI'])"; enums = $en
      })
  }
  $html = [ordered]@{}; $rtf = [ordered]@{}
  if ($doc) {
    $h = MLD (GF $doc 'm_BodyAsHtml'); foreach ($k in @($h.Keys)) { $t = Strip $h[$k]; if ($t.Length -gt 0) { $html[$k] = $t } }
    $h = MLD (GF $doc 'm_BodyAsRtf'); foreach ($k in @($h.Keys)) { $t = RtfText $h[$k]; if ($t.Length -gt 0 -and (Norm $t) -ne (Norm $html[$k])) { $rtf[$k] = $t } }
  }
  $libname = "$(GF $p 'm_LibraryName')"; $ver = ((GF $p 'm_VersionNumber') -join '.'); $folder = $f.Directory.Name
  $dn = MLD (GF $p 'm_DisplayName'); $ds = MLD (GF $p 'm_Descritpion')
  $page = if ($libname -eq 'OumanBetaApplications') { 99 } else { $i = [array]::IndexOf($FOLDERS, $folder); if ($i -lt 0) { 50 } else { $i } }
  [void]$all.Add([ordered]@{
      id = "$($p.TypeName)@$ver"; type = "$($p.TypeName)"; version = $ver; version_string = "$(GF $p 'm_Version')"; current = $true; superseded_by = $null
      library = $libname; beta = ($libname -eq 'OumanBetaApplications'); folder = $folder; file = $f.FullName.Substring("$lib\".Length)
      code_type = "$(GF $p 'm_PrimitiveCodeType')"; name_en = "$($dn['en-GB'])"; description_en = "$($ds['en-GB'])"; description_fi = "$($ds['fi-FI'])"
      has_doc = [bool]($html.Count -or $rtf.Count); pins = $pins; _doc = $html; _rtf = $rtf
      _sort = ('{0:D2}{4}{1}{4}{2}{4}{3:D5}' -f $page, "$($p.TypeName)".ToLowerInvariant(), (VKey $ver), $idx, [string][char]1)   # char 1 sorts before every letter: "average" before "averageextended"
    })
  $idx++
}
if (-not $all.Count) { "FAIL no block could be read from $lib ($failed failed)"; exit 1 }
# the newest version of a type inside one library is the current one
$latest = @{}
foreach ($b in $all) { $k = $b.library + '|' + $b.type; if (-not $latest.ContainsKey($k) -or (VKey $b.version) -gt (VKey $latest[$k].version)) { $latest[$k] = $b } }
foreach ($b in $all) { $c = $latest[$b.library + '|' + $b.type]; if (-not [object]::ReferenceEquals($c, $b)) { $b.current = $false; $b.superseded_by = $c.id } }
if ($roles) { foreach ($b in $all) { $rr = $roles.($b.id); if ($rr) { foreach ($p in $b.pins) { $x = $rr.($p.name); if ($x) { $p.role = "$x" } } } } }
$sd = New-Object 'System.Collections.Generic.SortedDictionary[string,object]' ([StringComparer]::Ordinal)   # by page, type, version
foreach ($b in $all) { $sd[$b._sort] = $b }
$cat = @($sd.Values)

$tool = 'Ouman Ouflex BA Tool ' + (Get-Item "$r\ProjectManager.exe").VersionInfo.FileVersion
$utf8 = New-Object Text.UTF8Encoding $false
New-Item -ItemType Directory -Force $RefDir | Out-Null

# ---- primitive-pins.txt
$L = New-Object Collections.Generic.List[string]
$L.Add("# ${tool}: all block pins. Made on this machine from the installed library by scripts/win/catalogue.ps1; vendor data, do not publish.")
$L.Add('# Columns: dir name type default [unit] [range] [hidden] [role] :: English text || Finnish text')
$L.Add('# Enum(0/1) = boolean; Enum with values = index.'); $L.Add('')
foreach ($b in $cat) {
  $status = if ($b.current) { 'current' } else { "old, superseded by $($b.superseded_by)" }
  $L.Add("## $($b.folder) / $($b.type) $($b.version) ($status) [$($b.library)] :: $($b.description_en)" + $(if ($b.description_fi -and $b.description_fi -ne $b.description_en) { " || $($b.description_fi)" } else { '' }))
  foreach ($p in $b.pins) {
    $bool = ($p.type -eq 'Enum' -and -not ($p.enums.Count -gt 2))
    $t = $p.type + $(if ($bool) { '(0/1)' } else { '' })
    $extra = @(); if ($p.unit) { $extra += "unit=$($p.unit)" }; if ($null -ne $p.min) { $extra += "range=$($p.min)..$($p.max)" }; if ($p.hidden) { $extra += 'hidden' }; if ($p.role -ne 'signal') { $extra += $p.role }
    $en = $p.display_en
    if ($p.description_en -and (Norm $p.description_en).TrimEnd('.').ToLower() -ne (Norm $en).TrimEnd('.').ToLower()) { $en = if ($en -and $en -ne $p.name) { "${en}: $($p.description_en)" } else { $p.description_en } }
    if ($p.enums.Count) { $j = 0; $en += ' [' + (($p.enums | % { "$j=$_"; $j++ }) -join ', ') + ']' }
    $fi = if ($p.description_fi) { $p.description_fi } else { $p.display_fi }
    $L.Add(("   {0,-3} {1,-22} {2,-10} def={3,-8} {4} :: {5}" -f $p.dir, $p.name, $t, $p.default, ($extra -join ' '), $en) + $(if ($fi -and (Norm $fi) -ne (Norm $en)) { " || $fi" } else { '' }))
  }
  $L.Add('')
}
[IO.File]::WriteAllText("$RefDir\primitive-pins.txt", (($L -join "`n").TrimEnd() + "`n"), $utf8)

# ---- primitive-docs.txt
$L = New-Object Collections.Generic.List[string]; $nd = 0
$L.Add("# ${tool}: documentation text stored in the block files, English first, then Finnish. Made on this machine by")
$L.Add('# scripts/win/catalogue.ps1; vendor text, do not publish. "RTF body" = the same help kept in a second format, listed when it differs.'); $L.Add('')
foreach ($b in $cat) {
  $d = $b._doc; $x = $b._rtf; if (-not $d.Count -and -not $x.Count) { continue }
  $nd++; $L.Add("######## $($b.folder) / $($b.type) $($b.version)" + $(if ($b.current) { '' } else { ' (old)' }))
  if ($d['en-GB']) { $L.Add('[en-GB]'); $L.Add($d['en-GB']) }
  if ($d['fi-FI'] -and $d['fi-FI'] -ne $d['en-GB']) { $L.Add('[fi-FI]'); $L.Add($d['fi-FI']) }
  if (-not $d['en-GB'] -and -not $d['fi-FI']) { foreach ($k in @($d.Keys)) { $L.Add("[$k]"); $L.Add($d[$k]); break } }
  foreach ($k in @($x.Keys)) { if ($k -in 'en-GB', 'fi-FI' -or -not $d.Count) { $L.Add("[$k, RTF body]"); $L.Add($x[$k]) } }
  $L.Add('')
}
[IO.File]::WriteAllText("$RefDir\primitive-docs.txt", (($L -join "`n").TrimEnd() + "`n"), $utf8)

# ---- blocks.json
foreach ($b in $cat) { $b.Remove('_doc'); $b.Remove('_rtf'); $b.Remove('_sort') }
$json = ConvertTo-Json -InputObject ([ordered]@{ tool = $tool; generated_by = 'scripts/win/catalogue.ps1'; blocks = $cat }) -Depth 6 -Compress
[IO.File]::WriteAllText("$RefDir\blocks.json", $json, $utf8)
"catalogue: $($cat.Count) blocks ($(@($cat | ? { $_.current -and -not $_.beta }).Count) current), $nd with documentation text, $failed unreadable -> $RefDir"
