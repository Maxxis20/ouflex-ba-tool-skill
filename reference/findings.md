# What is known about BA Tool 2.130.14 internals

Status words: **proven** = done in the tool, saved, reloaded, passed the tool's own check.
**seen** = observed once, not round-tripped. **untested** = a guess from names.

## How to read this

- Everything runs on the Windows machine that has BA Tool, in the desktop session of the person logged on. Script
  names are those in `scripts/` (`hstart.sh`, `hrun.sh`, `gui.sh`, `batool.sh`, `build.sh`); helper names are
  functions in `scripts/win/prelude.ps1`.
- Worked out on BA Tool 2.130.14.1, English user interface, between 2026-11-10 and 2026-11-12, on one Windows 11
  machine. Dates in the text say when a fact was last seen true.
- `C:\agentwork` is the work folder. Paths under it in the text are examples from that machine.

## Files

- Project = folder with `Project1.flprj` and `Devices\Device1\Device.bin`. Both are .NET
  BinaryFormatter graphs. The `.flprj` is locked while the project is open and then lists as 0 bytes.
  (proven)
- `Device.bin` root is `COuflexA`. `m_Applications` (`CApplicationCollection`) is the top-level
  canvas: its `m_ObjectList` holds the physical points (`UI 1`…`UI 16`, `DI 1`, `DI 2`, `AO 1`…`AO 6`,
  `TR 1`…`TR 4`, `R1`…`R6`, …) and its `m_RuntimeComponents` holds the applications. (proven)
- The drawing is stored separately from the logic, as a "VG.net" blob (Prodige vector graphics):
  the top-level one in `COuflexA.m_Data["ApplicationPicture"]`, each application's in its library data
  (`m_ContainerPicture`). **The drawing is authoritative.** A runtime component with no matching
  symbol in the drawing is dropped when the project opens, and without the blob all applications
  vanish. Editing `Device.bin` data alone therefore does not work. (proven, the hard way)
- Library: `OuFlexLibrary\OumanComponents\Primitives\<folder>\<Name>.ouepr` (blocks),
  `...\Applications\*.ouear` (whole applications). `Template\NewApplication.ouear` is the empty
  application. 165 of the 179 primitives of 2.130.14.1 carry documentation text.

## Two programs

- `ProjectManager.exe` is the main window. Its Applications page is a canvas of physical points
  and application blocks.
- Opening an application for editing makes ProjectManager export it to
  `Devices\Device1\<AppName>.ouear`, start
  `ApplicationBuilder.exe "<that file>" mode=1 lang=en-GB` as a **separate process**, wait for it to
  exit, then read the file back. Block-level work therefore happens in a hosted ApplicationBuilder
  on a `.ouear` file. (proven)

## Object model (namespaces abbreviated)

The tool's classes carry BACnet names (`CBacnetSoftpointObject`, `CBacnetScheduleObject`, `PROPERTY_PRESENT_VALUE`,
object type numbers). That is BA Tool's internal object model only: the Ouflex A does not offer BACnet (Modbus and its
own web UI only, see "Protocols"). The names appear here because scripts call them.

- Block instance: `CRuntimeComponent` (`VariableName`, `ComponentId`, `XCordinate`, `YCordinate`,
  `ExecutionOrder`) wrapping `CPrimitiveData`. Its `m_ObjectList` holds the pins.
- Pin: `CBacnetSoftpointObject` (`VariableName`, `IoType` Input/Output, `ValueType` — `Enum` for
  booleans, `Float` for analogs, `PresentValue` as string, `State` Active/Inactive, `Hidden`).
- Wire, data side: the input pin's `ReferenceObject` is the source pin object, and the input pin's
  `State` is `Active`. `ReferenceObjectFullId` then reads `<componentId>.<pinId>`. (proven)
- Wire, drawing side: a `ConnectorLine` element inside the canvas's `Content` picture, with
  `StartPin` = the output pin graphic and `EndPin` = the input pin graphic. (proven)
- Graphics: `ComponentSymbol` / `ExtendableComponentSymbol` (And, Or … with variable input count)
  per block, with `InputPins`, `OutputPins`, `HiddenInputs`, `HiddenOutputs`. Each graphic pin has
  `DataObject` (the softpoint), `GetLinePoint` (where a wire attaches), `ConnectedLines`, `IsFree`.

## Recipes that are proven

All run with `HNAME=<builder instance> hrun.sh`; helper names are from `win/prelude.ps1`.

- Canvas of the open application: `$cv = AppCanvas`. Data: `GF $cv 'm_DataComponent'`.
- Place a block the way a drag from the library does:
  `Add-Prim $cv 'OumanComponents' 'And' 300 120` → returns the symbol. It uses the canvas's library
  handler (`GetLibraryItem`, `ImportComponentToContainer`) and the canvas's 4-argument
  `AddComponent(byte[] symbol, Vector location, string varName, data)`. Names are assigned by the
  tool (`And`, `And2`, …).
- Find things: `Sym $cv 'And'` (symbol by component name), `SPin $sym 'Output'` (graphic pin by pin
  variable name).
- Wire output pin `$po` to input pin `$pi`:
  ```powershell
  $cl = [Activator]::CreateInstance($lineType)        # OuFlex.ApplicationBuilder.GraphicsItem.ConnectorLine
  $cl.ActiveHost = <the canvas host, e.g. copied from an existing element>
  $cl.StartPin = UW $po; $cl.EndPin = UW $pi
  $cl.StartPoint = $po.GetLinePoint; $cl.EndPoint = $pi.GetLinePoint
  (Content $cv).Elements.Add($cl); $cl.DrawLine(); $cl.IsActive = $true
  $po.ConnectedLines.Add($cl); $pi.ConnectedLines.Add($cl)
  $pi.DataObject.ReferenceObject = $po.DataObject
  $pi.DataObject.State = 'Active'
  ```
  Compared field by field against a wire drawn with the mouse: identical apart from the element
  name, which is not kept on reload anyway.
- Check: `CM $cv 'CheckAll' @($false,$false)` → True/False without dialogs.
- Save: `CM (FindCtl $form 'ApplicationEditor' | select -First 1) 'fastSave' $null`.
- In ProjectManager: `CM $form 'openProject' (,'C:\...\Project1.flprj')` opens a project;
  `TopCanvas` is the Applications canvas; adding an empty application there with the 5-argument
  `AddComponent(data, symbolBytes, pictureBytes, doc, Vector)` after
  `Open-Container "$r\Template\NewApplication.ouear"` shows the block on the canvas. (seen, not saved)

## Recipes added 2026-11-10 (helpers in `win/prelude.ps1`)

- **Wire** (proven): `Wire $cv $src $dst`. `$src` = block `OutputPin`, `EditorInputPin` (interface input),
  `EditorPhysicalInputPin` (UI/DI on the device canvas) or `EditorPropertypin` (global pin); `$dst` = block
  `InputPin`, `EditorOutputPin` or `EditorPhysicalOutputPin`. Host comes from the canvas field `host`
  (a mouse-drawn wire has `ActiveHost` = that object; after reload every element's ActiveHost is null).
  Data side: input-side dst gets `ReferenceObject`=src softpoint, `State` Active. Output-side dst
  (interface output, physical output): `syncronizeDiagram_Data()` sets dst `ParentObject`=src and
  src `ReferenceObject`=dst. An output driving more than one *object* (interface out, measurement,
  physical out) becomes `OBJECT_MPLEX` with `m_MultipleRefObjects`; this is rebuilt from the drawing on reload.
- **Constant** (proven, bool and float): `Set-Const $cv (SPin $sym 'B1') 2.5`. Recipe: canvas
  `m_selectedElement`=pin, call `InputPin_set_Delete_constValue_Click(inputPinConstValueItem, EventArgs)`
  (the menu handler, no dialog; same call again removes it), then `DataObject.PresentValue`="2.5"
  (invariant culture string; the symbol text follows the PresentValue event), then
  `setConstValueSymbolWidth(symbol,pin)`. Result: pin State Active, `IsConstValue` True, ReferenceObject
  null, `ConstValueSymbol.ShowSymbol` True. `m_Objects_Constvalues` stays empty (not used for this).
- **Interface pins** (proven): `Add-InPin $cv 'Name' 'Enum'|'Float' x y`, `Add-OutPin ...` → click the
  real buttons `addInputPinButton`/`addOutputButton` (`PerformClick`), then set `VariableName`,
  `DisplayName.SetTextToAllLang()`, `NameChangedByUser`, `ValueType` (Digital=`Enum`, Analog=`Float`;
  dialog also offers U32), `Location`. Default type is Float. Graphic `EditorInputPin`/`EditorOutputPin`
  directly in Content; the symbol preview on the left updates by itself.
- **Extendable blocks** (proven): unused inputs are `State` Inactive and are fine for CheckAll. A
  non-extendable required input left Inactive fails: "FOLLOWING PINS ARE NOT CONNECTED (app) / Add.A".
  Hide pins (block menu "Hidden pins", lists only unused pins): data softpoint `Hidden`=true, then canvas
  `updateComponent(symbol)` rebuilds the symbol (wires, consts, set values survive). `Hide-Pins $cv $sym @('B5','B6')`.
  `ExtendableDestinationPictureParameters` counts and `CRuntimeComponent.m_ViewedInputs` do not change.
- **Cyclic wire** (proven): accepted by mouse and by script; CheckAll True; automatic order runs the
  earlier block first (Or=1, Not=3 for Or→Not→Or), so the loop carries last cycle's value.
- **Execution order** (proven): container `AutoExecutionOrderGenerating` (default True) renumbers on
  save. Set it False, then `CRuntimeComponent.SetExecutionOrder(n)` (others shift on save; in-session
  numbers may show duplicates). `GetComponentsInExecOrder()` gives the order.
- **Set value** (proven): `Add-SetValue $cv $pin 'Raja2' 40 0 100 '%' 'Raja 2'` → container
  `AddSetvalue(pinSoftpoint)` creates `CAnalogSetpointObject` (pin ReferenceObject = it, State Active), then
  the pin's `SetPointSymbol` must get `DataObject`, `ShowSymbol`, `Visible` and bounds left of the pin, or
  the next diagram sync **deletes the set value**. Fields: `MinValue`, `MaxValue`, `UnitStr` (the `m_Unit`
  enum is derived on save, `%`=8, `C`=72, `kW`=10), `PresentValue` (default), `DisplayName`,
  `AccessRightLevel` (Normal=5), `ManualControlMode` (AllowedWithServiceCode), `PositionPointType` SP.
  Menu "Add setting value" opens the Properties dialog modally. Fan-out: one set value referenced from
  several pins (`ReferenceObject`=same object + Show-PinSym) survives reload and CheckAll;
  `GetCombatibleSetpoints(pin)` lists the candidates; `ParentObject` ends up as the last pin (seen, GUI path not found).
  An anonymous constant has no object, no name and no Modbus register; a set value is an object with one.
- **Measurement** (proven): `Add-Measure $cv $outPin 'SummaM' 'kW' 2` → `AddMeasure(pinSoftpoint)` creates
  `CAnalogMeasureObject` (Float pin) or `CBinaryMeasureObject` (Enum pin) + `MeasureSymbol` right of the pin.
  Default display name = pin description; `ManualControlMode` AllowedControlRoom; `TrendLogBufferSize` 10000.
  Shows up in the Modbus export under "<app> / Mittaukset" with a data and a manual-control register.
- **Labels** (proven): `Add-Label $cv 'text' x y` → canvas `AddComment()` (menu "Add comment", no dialog)
  makes a `Comment` element; set `CommentText`, `AdjustCommentSize()`, `Location`. Works on both canvases.
- **Global pins** (seen, one application only): canvas menu "New global pin" asks for a name and makes an
  `EditorPropertypin` (`m_DataId`=name, `m_PropertyId` 85, `m_GlobalPoint` True, text `g_<name>`). It reads
  the device-level global point of that name (an object with `Global`=True, "Device level global" in
  Properties). Wiring it to an input resolves `ReferenceObject` to that object; survives reload.
  Cross-application use (seen 2026-11-11 in a project made by hand): an `Add` in one application whose input `A` has
  `ReferenceObject` = the device point `UI 11` (`COu6000UnivInput`, `m_Global` True) with no device wire, and the application
  shows no input pin for it on the device canvas. A measure inside an application can carry the flag too
  (`CBinaryMeasureObject`, `m_Global` True).
- **Globals by code** (proven 2026-11-12, also on a real controller):
  - Writer: `MG $cv NAME` sets `Global` = True on a named object of the application (a measure on the output).
    Works in the standalone Application Builder; the flag survives import into the project.
  - Reader: `GLP $cv NAME x y` = `MyCanvas.AddPropertyPin(Vector, 85, $null)` + `GlobalPoint`=True, `DataId`=NAME,
    `PinInfo.VariableName`=NAME, `PinText`='g_NAME' (what `newGlobalPinToolStripMenuItem_Click` does after its name
    dialog). Wire it like any source (`W $cv '%NAME' 'blk.pin'`), then `syncronizeDiagram_Data` writes the name into the
    input's `ReferenceGlobal`; `ReferenceObject` stays null in the standalone application and CheckAll is still True.
  - The link is by name. After import and reopen `MyCanvas.handleGlobalPoints` resolves `ReferenceObject` to the object
    with that name and Global = True in whichever application has it; the reading application shows no pin on the
    device canvas and there is no device wire. `CheckReDefinedGlobals` on the device reports a name defined twice.
  - On the controller: a `Not` reading `g_PUMP_FAULT` from another application followed the signal both ways
    (flipped through Modbus). Process monitoring shows the input as `PUMP_FAULT.M`.
  - One measure per output pin, so two plan nets on the same output are one global.
  - **Trap: an application with global pins must not be reopened on its own.** In the standalone Application Builder the
    names cannot resolve: a modal "Info: Errors in opening: Reference pin error <NAME> (ERROR)" comes up (it can sit
    behind another window, so the host never reports "timer armed"), and after OK the global pin and its links are gone
    from the session. The saved file is intact as long as nobody saves again. The build therefore reads such an
    application back from the session that built it and proves the round trip at device level.
  - Helper names: `GLP` (not `GP`, which is PowerShell's Get-ItemProperty alias and fails with "A positional parameter
    cannot be found"). Check a new helper name with `Get-Alias` first.
  - A hidden dialog can be read without seeing it: `batool.sh dlg list` prints the title, text and buttons of every
    standard dialog a hosted tool has open, `batool.sh dlg button 1` presses OK.
  - Build: program.json `"net_transport": "global"` (default `"wire"`); the generator writes `<out>/signals.md`, the
    cross-reference of who writes and who reads each global. Dumps: `GP|`, `G|` (application), `GL|` (device), `FGL|` (file).

### Device level (hosted ProjectManager on a project copy)

- Save: `Save-Project` (= `saveToolStripMenuItem_Click`). Reopen with `openProject`. (proven)
- `TopCanvas` is null while another page (Devices …) is shown; click "Applications" first.
- Content element on the device canvas is `Picture001` (ComponentPicture), not `Content`; `Content` helper handles both.
- Import an app (proven): `CM (TopCanvas) 'ImportComponentFromFile' @('C:\...\x.ouear',(Vec x y))` →
  ComponentSymbol named after the app; interface pins are its InputPins/OutputPins. Wire physical points
  with `Wire` (`PhysPin $cv 'UI 3'`). A mouse wire here first asks "Select the copying direction"
  (display name, enum texts, unit, point id, field device; checked = app pin → physical point); the scripted
  wire copies nothing.
- Physical point menu: Properties, Add alarm, Restore default settings, Copy/Paste settings, Show all reference pins.
  Properties: Display name, Status texts, Field device, Device type (+ parameter popup), Sensor fault alarm
  (needs an alarm first), Polarity (Closing NO / Opening NC), Informative measurement, Physical type
  (Analog/Digital; UI8 also Pulse), Unit, Decimals, Min/Max value (= engineering scaling), Point ID,
  Manual control, Calibration factor/offset, Internal Modbus register, Trend enabled/interval/size.
- `Set-IoType $cv 'UI 6' 'Analog' 'TX_IN' 'TX_IN{1,500,7,1,2,10}' 0 10 'bar' 'Paine'` (proven).
  Writes `PhysicalType` (drives ObjectType ANALOG/BINARY_INPUT, ValueType, point type M/I, enums 0=Off,1=On),
  `DeviceType` (a `CDeviceType`; set `.DeviceType` to an `EDeviceType` name, params via
  `SetDevTypeParams('<TYPE>{a,b,..}', ioType)` or `Set-DevParam $cv name 'Min_mA_Limit' 4`, then assign
  back), `Polarity` on the point itself (setting it on the DeviceType copy is lost), `MinPresentValue`,
  `MaxPresentValue`, `UnitStr`. Sensor fault limits `m_SensorFaultLow/HighLimit` are recomputed (min+1/max−1).
  Base UI types: NOT_IN_USE RAW OHM NTC10 NI1000 PT1000 TX_IN(0–10 V) FLEX_LIN NI1000DIN NTC1_8 NTC20 NTC2_2;
  digital = DIGITAL_AN_IN{onV,offV}. No mA on the base unit.
- UI8 module (proven): Devices page → "Modbus RTU master 3 (COM1, RJ45 at the end of the device)" → Add
  device → IO-CARDS → FLEX UI8 → name, address (DIP), "Check all points automatic". Creates `CBusDeviceObject`
  FLEXUI8, alarm `MB3_ADDR1_FLEXUI8__Error`, and `MB3_ADDR1_FLEXUI8_UI1..8` (`COu6000UnivInput`, IsBusPoint,
  adds `mA_SIGNAL` and Pulse). Not on the canvas until placed: canvas `AddBusPoint(point, Vector, out alarm)`
  (what a drag from Object browser > Bus points does). mA: `Set-IoType ... 'mA_SIGNAL'` + `Min_mA_Limit`/`Max_mA_Limit`.
  Adding the device by script: proven, see "Adding a bus device by code" below.
- Capacity check / "build" (seen): form `buildDeviceToolStripMenuItem_Click` runs offline, shows
  "13% of the programming capacity used", writes no files. Builder canvas `BuildAll(List)` → True, no messages.

### Modbus map

- Each process object has `ModbusInterface` (`CMobusInterface`): `ModbusRegister` (0-based; `ModbusRegisterSifted`
  is the 1-based number the documents show), `ManualControlRegister`, `PollRegister`, `AddressFormat`
  (S16/U16/U32…), `Using`, `RegisterInDescrFile`. Registers are assigned automatically and sequentially
  (physical 201…, manual regs 251…, measurements, set values 300…); user-set values are kept (set
  `ModbusRegisterSifted`=401 → document shows 401, survives reload). (proven)
- Export (proven): Device > Create > "Modbus interface document (html)". `Start-ModbusExport` posts the menu
  item's Click delegate (PerformClick on a closed menu does nothing). The Save As dialog and the question after it
  ("... is created! Do you want to open the file location?") are standard Windows dialogs and are answered by control
  id, without mouse or keyboard: `batool.sh dlg file 'C:\...\x.html'`, then `batool.sh dlg button 7` (No). The export
  marks the project modified.
  `Get-ModbusMap <html>` parses its `var data` block into rows (Section, Group, description, technicalname,
  registertype, addressformat, modbus reg, Manual reg, unit, decimals, Limits, enum, Read/Write).
  Calling `CDescriptionFileCreator.createModbusInterfaceHtml` directly throws NullReference (dead end).
- Other exports on the same menu: Modbus interface pdf, Modbus slave template, CSV pointlist, EH-net /
  Ounet / Ouman Trend templates, Json template; Device > Modbus > Export registers to Excel / Reset modbus registers.

## Recipes added 2026-11-10, whole-program build (helpers in `win/prelude.ps1`, build section)

- **Block name** (proven): `CRuntimeComponent.VariableName='tank_lo'` renames the block; the symbol's
  `ComponentName`, the label ("tank_lo | Or") and pin `FullVariableName` follow; survives reload.
- **Names are unique per application, case-insensitive, across blocks, interface pins, set values and
  measures** (proven): renaming an interface pin to `TANK_BAD` next to block `tank_bad` opens a modal
  "Variable name TANK_BAD is reserved" and the name is not changed. Check with `NameTaken` before any rename.
- **Application name** (proven): container `TypeName` = technical name, `DisplayName.SetTextToAllLang()`;
  `ApplicationObject` becomes `App_<name>`; the device-canvas symbol and its runtime component take the name on import.
- **Symbol size** (measured, 28 block types): width 165, height 35.3 + 16.0 × max(visible inputs, outputs).
  Extendable And/Or show 8 inputs (163 px), Add/Subtract 9 (179 px). Constant, set value and measurement
  symbols are 15 × 15 icons beside the pin.
- **Vendor blocks with their own objects** (proven): `Override` arrives with a measurement on `Output`,
  `RunTimeCounter` with set value `RunTimeSet` + measurement `RunTime`, `StateSync` with a set value on `LocalIn`
  (so `LocalIn` is not free). Delete without a dialog through the pin menu handlers with `m_selectedElement` = pin:
  `InputPin_Add_Delete_SetValue_Click(inputPinSetValueItem)`, `outPutPinAddDeleteMeasure_Click(outputPinMeasureItem)`
  (`Drop-Builtins`). The *add* direction of the set value handler opens the Properties dialog: never call it on a free pin.
- **Library default constants** (seen): many inputs arrive `State` Active with a constant shown (OnDelay
  Enable=1, DelayTime=1; CountUp RisingEdge=1; Limit Max=100; SignalFilter TimeConstant=5 ...). Such a pin is not
  `IsFree`: `W`/`SETV` remove the constant first (`Clear-Const`). `Hide-Pins` refuses Active pins.
- **Required inputs** (proven by CheckAll messages on a probe with some thirty block types): left unconnected these
  fail "FOLLOWING PINS ARE NOT CONNECTED": Add.A, Subtract.A, Compensator.Input, CountUp.Input, Integrator.Input,
  Limit.Input, Not.Input, On/OffDelay.Input, Pulse.Input, SignalFilter.Input, RunTimeCounter.Indication,
  StateSync.RemoteIn, Greater/Less(OrEqual).A+B, RS/SR R+S, Xor both, **Override Input+OverrideEnable+OverrideValue**,
  **SwitchAn/SwitchBin Select+Input0+Input1**. Optional (Inactive is fine): extendable inputs, CountUp Reset/Max,
  StateSync SyncSpace, MinBuffer Reset. A pass-through Override/SwitchBin therefore needs constants 0 on the unused pins.
- **Binary objects**: an Enum pin gets `CBinarySetpointObject` / `CBinaryMeasureObject`, which have no
  Min/Max/Unit/`m_Desimals` (the old `Add-Measure` threw on `m_Desimals`; fixed with `HasF`).
- **Hidden pins** are not in the symbol's `HiddenInputs`/`HiddenOutputs` (both stay empty); read `Hidden` from the
  block's `CPrimitiveData.m_ObjectList`.
- **Zoom / fit** (proven): canvas `ShowAll()` fits the whole diagram; `SetZoom('20%',$false)` sets a zoom.
- **Pages of ProjectManager** (proven): `(GF (Cfg) 'Tabs').Selected = i` shows tab item i = `m_ConfigForms[i+1]`:
  0 Applications, 1 Local HMI, 2 Object editor, 3 Alarm routing, 4 System settings, 5 Devices (`Show-Page`).
- **Adding a bus device by code** (proven, FLEX UI8): `Devices.SearchDevicesInDirectory(list, TemplatePath\Devices,
  connector.CurrentProtocol, false)` gives the template `CDevice` (FullName 'FLEX UI8'); the connector is the
  Devices tree node whose `Tag` is the `CBusConnector` with `ShortName` 'MB3'. `Devices.AddDevice(dev, conn, false, false)`
  opens the modal `DeviceProperties` dialog, so it is posted with `BeginInvoke`; the next script fills
  `textBoxDeviceId`, `numericUpDownAddress`, `checkBoxAutoCheck` and clicks `okButton` (`Add-BusDevice-Start`,
  `-Confirm`, `-Result`). Result identical to the GUI: `FLEXUI8`, `MB3_ADDR1_FLEXUI8__Error`, `..._UI1..8`; survives reload.
  PowerShell cannot touch a `DeviceProperties` object at all ("cancelButton differs only in letter casing from
  CancelButton"), so the dialog is driven from a small C# class (`Load-UiX`, `[UiX]::...`) by type and control name.
- **First visit of the Devices page** starts `Ouman6000` and raises a Windows Firewall prompt; Cancel is fine.
- **Physical point polarity** is the point's `Polarity` property (BACnet-style name in the tool's object model) (`Normal` = "Closing (NO)", `Reverse` = "Opening (NC)",
  i.e. Reverse inverts the present value). A plan that inverts NC contacts in logic leaves all points Normal.
- **Modbus slave map** (proven by IL): every point is a Holding register; the string "Holding" is hard-coded in every
  `CDescriptionFileCreator` writer and `CMobusInterface` has no register-type field. Per point: `ModbusRegister`
  (protocol address), `AddressFormat` (LoS8, LoU8, HiS8, HiU8, U16, S16, U32, S32, Float, ...), `Using`,
  `RegisterInDescrFile`, `ManualControlRegister`. Fixed system registers seen: 2..7 (date/time), 14 (ack all alarms);
  automatic numbering starts at 201. `ModbusInterface` is null until the first export (or register reset).
- **Save only writes when the project is marked modified** (proven): scripted changes (set execution order, Modbus
  registers ...) do not mark it, `saveToolStripMenuItem_Click` then silently writes nothing (Device.bin timestamp
  unchanged). `Mark-Modified` = `CGlobalSettings.InvokeProjectDataChangedEvent(null,'',null,true)` (title gets `*`);
  `Save-Project` now calls it first.
- **Device-level execution order** (proven): `CApplicationCollection` also has `AutoExecutionOrderGenerating`; while it
  is True, saving runs `MyCanvas.DoExecutionOrder` (from `HandleBeforeSaving`) and renumbers the applications
  (the first save of a program with seven applications changed their order). Set it False and `SetExecutionOrder` per application (`DEO`), save
  (marked modified): the file keeps the order, the flag reloads False and later saves keep it.
- **Measurement source in the saved file**: an output feeding two objects (measurement + interface output) keeps
  `ReferenceObject` null in Device.bin; the measurement's `ParentObject` names the pin. The file's `FullVariableName`
  carries the application prefix (`APP1.tank_lo.Output`).
- **Reading the saved project without the tool** (proven): `win/projdump.ps1` (run through `batool.sh run`, the build's
  filecheck stage does it) deserialises Device.bin with lib.ps1 (`Load-Bin`) and lists applications, blocks, wires, constants, set values, measures and interface pins.
- **Modbus registers set by code** (proven, survives reload and re-export): after one export, `ModbusInterface`
  exists; set `ModbusRegister` (the export shows it +1), `AddressFormat` (S16/U16/S32), `Using=False` removes a point
  from the document. Physical points (DI 1, UI 8) take the same fields.
- **IL reading** (tool, in prelude): `IL-Refs <MethodInfo>` lists the calls, fields and strings a method body references —
  enough to follow a menu handler to the call that does the work. Tokens of compiler-generated lambdas (`<>c`) resolved
  to nonsense once; treat those as unread.
- Helper names must not shadow PowerShell aliases (aliases win over functions): `SV` is Set-Variable, so the
  set value helper is `SETV`.
- PowerShell 5.1 reads a dot-sourced `.ps1` without BOM as ANSI: generated scripts are written UTF-8 *with* BOM.

## Recipes added 2026-11-10 night, general pipeline and the example programs

- **Block probe** (proven, `pipeline/block_probe.json`): one of each of 35 further block types placed by script in
  `C:\agentwork\apps\probe2.ouear`, vendor built-ins dropped as the build does, then CheckAll. Results:
  - Vendor built-ins on arrival (beyond Override/RunTimeCounter/StateSync): **Pid** set values on P, I, D + measures on
    Output, Diff; **Curve_3p** set values on all 5 parameter pins + measures on all 4 outputs; **Curve_5p** set values on
    all 10 parameter pins + 4 measures; **Thermostat** set value Setpoint + measure Output; **MotorDriverV/3p** set values
    OpenTime, CloseTime; **P_control** set values SetPoint, P + measures Output, Diff; **Deadband** measure Output.
  - After the drop, a pin either keeps its library constant (Curve_3p/5p pins, Pid D) or is left empty and becomes
    required (Pid P and I, Thermostat Setpoint, MotorDriverV/3p OpenTime/CloseTime, P_control P). The plan must source
    these explicitly; `check_plan.py` P9 knows them.
  - Required inputs (CheckAll "NOT CONNECTED"): Pid SetPoint/Measure/P/I, Linearization/SignalSplitter/Limit/Integrator/
    Absolute/Deadband/RampUpDown/RampAnalogDelay/RisingEdgeDetect/OffDelay/OnOffDelay Input, Thermostat Input+Setpoint,
    Max/Min Input1, Multiply/Divide A, Compare/Equal A+B, MotorDriver3p also DeadBand, the alarm blocks' Input / SetPoint+
    Measurement. **Not** required: Curve_3p/5p (not even Input), StartDelay, PrioritySelect, Average, SequencingModule,
    OnOffPulse, SensorWatchAn, Pid Feedback and its U32 stage pins.
  - Alarm blocks (AnalogAlarm, BinaryAlarm, DeviationAlarm) carry hidden pins (EvState, AckTrans, ...Wr) and entry/exit
    delay defaults of 5 s; not used yet (alarm objects unsolved).
- **Block names equal to a library type are reserved** (seen, dh2 build): renaming a block to `pid` opened the modal
  "Variable name pid is reserved." although nothing in the application had that name, so `NameTaken` cannot see it. The
  generator now treats every type name and library file stem (case-insensitive) as taken and appends `_b`
  (`pid` → `pid_b`); `check_plan.py` reports it as INFO. Dismiss such a dialog with `batool.sh dlg button 1` or a click on OK.
- **A reused vendor set value keeps the vendor's unit** (proven by the ahu1 verify): `Pid.P` arrives with unit °C; the plan
  said '' and `SETV` only wrote non-empty units, so the read-back showed °C. `Set-SVFields` now writes the plan's unit
  whenever it differs, '' included.
- **Hide-Pins on an output whose vendor measure was dropped** (proven, dh2): Curve_3p `Output` stays `State` Active after
  its built-in measure is removed, and Hide-Pins refused it ("Output is in use"). Only inputs are refused now; outputs are
  hidden when they have no line and no measure symbol.
- **Empty base project**: `C:\agentwork\base\OuflexA_empty` is the untouched result of New project with one Ouflex A (system
  applications LedHandler2 + ButtonClickHandler). Device.bin keeps the folder path it was made in as a string only, so the
  folder can be copied and used elsewhere. `setup` makes it and every build copies it.
- **New project by code** (proven 2026-11-22): `New-Project-Start` posts the Click handler of `newToolStripMenuItem`, which opens
  four modal forms one after the other; `New-Project-Step name dir type` answers whichever is open, one per `hrun`:
  `NewProjectForm` (`PrjNameTextBox`, `PrjDirectoryTextBox`, `buttonOk`), `AddNewDeviceDialog` (`radNew` = Create new device,
  `btnOK`; its other choices download from a device, a file or a server), `SelectDevTypeForm` (`DevTypesListBox`, items
  such as "Ouflex A (Template/Ouflex A.dev)", `okButton`), `DeviceProperties` (`buttonOk`). Then `Save-Project` writes
  `<dir>\<name>\<name>.flprj` and `Devices\Device1\Device.bin`. `SelectDevTypeForm` cannot be touched from PowerShell
  (members that differ only in letter case), hence the small C# class `UiP`.
- **Default physical points of a new project** (read from Device.bin): UI = Analog NTC10 −50..130 °C; DI = Digital DIGITAL_IN;
  AO = Analog TX_OUT 0..100 %; R = Digital DIGITAL_OUT; TR = TreeStateControl. An application output of 0..100 % on an AO
  is therefore the documented range of the point (that 0..100 % maps to 0..10 V is the point's scaling, not tested on hardware).

## Wire shapes and page layout (measured 2026-11-11)

- The tool draws every wire itself; there are no waypoints. `ConnectorLine.DrawLine()` recomputes the shape from the two pins.
  Forward (end right of start, `forwardPoints`): start → dx/3 level → slant over the middle third → dx/3 level → end.
  Backward (`backwardPoints`, 8 points): out 30, bulge to +60, back level at the mid height of the two ends, bulge, in.
- So tidiness is decided by placement only. `pipeline/ouflayout.py` places blocks, interface pins and labels for these shapes
  (called by `make_ouflex_build.py`; plan x/y are not used for application pages). Clean shapes: neighbour columns (the slant
  stays in the 135 wide channel) or a level wire. `python pipeline/ouflayout.py <dir> --png <dir> -v` previews without the tool.
- Measured sizes: symbol 165 wide, height 35.34 + 16 per visible pin row, first pin row 42.84 below the top; interface pin
  85 × 15, line point 7.5 below its top (input: right end, output: left end); constant box 30 left of the pin, set value
  mark 16, measure mark 16 right of the output; comment about 43 high.
- Some unused pins stay visible after `HU` (CountUp, Pulse, StateSync …): `pipeline/sticky_pins.json`, refreshed from the
  build dumps with `python pipeline/ouflayout.py --learn`.
- A feedback reader that does not lead back to the writer is placed right of the writer, so the wire is drawn forward.
  Execution order is set separately (`EO`) and does not change.

## Drawing a wire by hand (for ground truth)

Wires can only be drawn in Connect mode: toolbar button `linkButton` ("Connect", next to the zoom
box). Then the snap dots appear on the pins and a drag from dot to dot makes the wire. Screen
position of a pin: element `DeviceBounds` centre → `$cv.PointToScreen(...)`.

## Dead ends

- `MyCanvas.addLink()` does not create a wire (returns True, adds nothing).
- Removing the drawing blob to make the tool regenerate it: physical points come back, applications
  are deleted.
- Starting the host with a WinForms timer created before the tool's `Main`: the tool throws
  "Thread exception mode cannot be changed once any Controls are created". The host arms its timer
  from `Application.Idle` instead.
- First launch of the host raises a Windows Firewall prompt (the tool opens listening sockets).
  Cancel is fine; nothing here needs the network.

- `CDescriptionFileCreator.createModbusInterfaceHtml(file,false)` on a fresh instance: NullReference.
- Opening a library application copy (`HeatingControl.ouear`) in a hosted builder: an "Error" window,
  host never armed. Byte search of library `.ouear` files for SetPointSync/StateSync is inconclusive
  (contents are nested blobs).
- `ToolStripMenuItem.PerformClick()` on an item of a closed menu: nothing happens.
- PowerShell gotchas inside `hrun`: a function return or `$()` unrolls collections (an empty `List` arrives
  as nothing → PSObject conversion error; use `Inv1`); `MI` is the Move-Item alias; a `throw` aborts the
  whole script and discards earlier output.

## Things that can silently corrupt a project

- A set value whose `SetPointSymbol` has no DataObject is deleted by the next diagram sync/save.
- A scripted change is lost on save unless the project is marked modified (see Mark-Modified).
- Any Modbus export (and possibly saving) assigns registers to new points: adding points between exports
  shifts nothing already assigned, but `Reset modbus registers` renumbers everything.
- The mouse wire on the device canvas copies names/units between the app pin and the physical point
  (direction dialog, remembers last choice).
- In-session data after scripted edits is not identical to what reload rebuilds (MPLEX, ParentObject);
  always round-trip before trusting the data side.

## Protocols

- Ouflex speaks **Modbus** (TCP slave, RTU bus) only. **No MQTT, no BACnet** (2026-11-24). The `CBacnet...`
  class names (`CBacnetSoftpointObject`, `CBacnetEthernetPortConfig`, `Polarity`) are the tool's internal object
  model, not a BACnet interface on the controller. Data to an HMI/SCADA goes over Modbus TCP.

## Simulation without a controller (works, 2026-11-24)

BA Tool ships a simulator: `ApplicationDebugger.exe` (Application Builder > Tools > Debug starts it as
`ApplicationDebugger.exe "<app.ouear>" lang=..`) loads **one application** into a virtual device and shows live
values on the function-block canvas. The toolbar button "Debug" in Application Builder is something else: a
trace-log viewer (`TraceDebug`).

- Device types in the debugger (`deviceTypeComboBox`, hidden): Virtual Ouflex C (default) / Virtual Ouflex A.
  Load starts `Template\OuflexCVirtual\VirtualOuflexC.exe devicetype=0 onlyui disable_exit`, a window "Virtual
  device" with the Ouflex C panel (display + UP/OK/Down/ESC: the local HMI, Finnish menus), talking over the named
  pipe `OuflexCVirtualDevicePipe`. `Template\OuflexAVirtual\platform\exe\OuflexA.exe` exists too (not tried).
  `OuFlex_C_VirtualUI\Ouflex C.exe` started alone exits at once.
- Host it like the other tools: `hstart.sh dbg ApplicationDebugger.exe '<app.ouear>' lang=en-GB`. Form
  `ApplicationDebugger.DebuggerForm`; helpers `Sim-*` in `win/prelude.ps1`.
- **Load** = `loadButton_Click` (log "Starting the virtual device / Loading complete!"). **Run** = `runButton_Click`
  (toggle: Run/Stop; `m_ProgramState` IDLE/LOADING/RUNNING/WAITING/HALTED/UNLOADING). **Reset** =
  `resetButton_Click` = `Ou6000Connection.RestoreDefaultValues`: values back to defaults and the program
  **HALTED**: Run again before writing inputs (a write right after Reset was lost). Step/breakpoints exist.
- **Read**: `m_LoadedApplication.m_ObjectList` holds every point of the application (interface pins
  `CBacnetSoftpointObject` with `IoType` Input/Output, set values `CAnalogSetpointObject`/`CBinarySetpointObject`,
  measurements `CAnalog/BinaryMeasureObject`); `PresentValue` (string, `,` decimal on a fi-FI Windows) is live, polled
  from the virtual device. Block pins: `m_Components[i].m_ComponentData.m_ObjectList`.
- **Write** (inputs and set values): what the canvas "Set value" dialog (double-click a value box) ends in:
  `DebuggerForm.myCanvas1_OnObjectValueChanged(<point object>, 'PresentValue', '<value>')` → `set_PresentValue` +
  `CDeviceConnection.WriteProperty`. Pass the bare object (`.psobject.BaseObject`), else nothing happens and no
  error. Setting `PresentValue` directly only changes the local copy (the next poll overwrites it). `12.5` with a
  dot is accepted.
- **Time**: combo "Timer factor" (0.2…10 offered) → `Ou6000Connection.ChangeTickTimerSpeed(Single.TryParse(text))`;
  **100 works** (a 3600 s OnDelay fired after 36 s wall clock). Each driver call is ~3 s = 300 s simulated at 100.
- Proven on dh2 `C1`: curve −20/0/+20 → 58/41/20, 12.5 °C → 27.875; summer stop after `C1_SUM_DLY`, pump and
  valve to 0; PID valve 100 % at supply 0 / setpoint 41.
- **Scenario runner**: `pipeline/sim_test.py <app.ouear (Windows path)> <scenario.json> [--factor] [--attach]`, scenario
  format (set / wait / expect / until / note), Reset+Run per case. Example `examples/dh2/sim-C1.json`.
- **Reset is asynchronous**: the state reads RUNNING for a moment, then HALTED. `Sim-Reset` waits for
  HALTED, `Sim-Run` presses Run only when not RUNNING and waits for RUNNING. Without that a scenario ran on a
  halted program and "passed" on stale values. Reset restores written set values to their defaults.
- **Out-of-range write is clamped** to the set value's limit (simulator): `C1_EXER_OFF` (min 3600) written 600
  reads back 3600. The real controller is not checked.
- **Call overhead is simulated time**: at factor 100 each ~3 s driver call is ~5 min. After Reset the inputs are 0,
  so a delay that 0 already triggers (deviation 0 vs setpoint 41) starts at Run, before the first write: start a
  case from a quiet state, then step.
- **Factor after a reload**: a (re)load starts the virtual device at factor 1, and the combo passes the speed on only
  when its text changes, so setting "100" again did nothing (all delay cases failed after a `Sim-Week` reload).
  `Sim-Factor` now sets another value first.
- **Reset keeps block states** (2026-11-24, a process simulator): Reset restores set values to their defaults, but internal states
  stay (an `Integrator` still held −50 from the previous case, so a level started at 0 instead of 50 %). A scenario
  with integrators, ramps or counters needs `"reload_each_case": true` (`sim_test.py` loads the application again).
- **A block's own output wired to its own input reads 0** in the simulator (a `SwitchAn` hold showed `Input1=0` while
  its output was 100). A hold needs two blocks: the switch, and a pass-through `SwitchAn` (Select 0) declared after it
  whose output feeds the switch (one cycle old). Feedback from a later block works.
- **Writes are checked**: `sim_test.py` reads every written point back and writes again what did not arrive.
- **Short pulses fall between polls**: at factor 100 one ~3 s read is ~5 min simulated, so a 120 s exercise pulse
  can pass unseen; the scenario uses a 900 s pulse.
- dh2 C1 scenario `examples/dh2/sim-C1.json`: 9 cases (curve/offset/limits, summer stop with latch, sensor
  fault, disable, deviation alarm, pump exercise, clamp, night setback, comfort), RESULT OK in ~8 min wall clock
  (2026-11-24, log `build/out/sim-C1.txt`).
- Not yet: device level (several applications, physical I/O, Modbus), the Virtual Ouflex A, the virtual panel
  driven by script.

## Web UI pages (proven 2026-11-24)

The Web UI runs on the controller itself. Its pages ("charts") are built on ProjectManager's "Web UI configuration" page
(`OuFlexConfiguratorPlugins.Chart.ChartEditor`).

- **Editor**:
  - It is the controller's own web UI, run by the virtual Ouflex A (`Template\OuflexAVirtual`, process
    `OuflexA.exe`, its own web server on port 8080) inside an EO WebControl.
  - Pages sync between the project and that device through `OumanAPI` (`GetCharts`, `GetChart`, `SaveChart`,
    `RemoveChart`, `RenameChart`).
  - "Preview" (`toolStripButtonPreview_Click`) opens `…?fullscreen=1/#/charts` in a `PreviewForm`. The virtual
    device runs the project's program, so the preview shows live values (dh2: setpoints 41 / 28 °C, pumps on,
    valves 100 %).
  - Only one editor may run (one `OuflexA.exe`).
- **Storage**: `COuman6000.ChartData` is a `Dictionary<string,string>`, page name → page JSON. It is null in a
  project that has no pages yet. "Add chart from library" = `File.ReadAllText(Template\Cloud\Charts\*.json)` →
  `AddChart(name, json, invokeChanged)` → `SaveCharts` → `UpdateChartToTabs`. Library pages: `AHU301`,
  `Heat distribution`.
- **Page JSON**:
  - `surface` (size, grid, background).
  - `component.components`: id → `{id, type, props, links, states}`. Types seen: Pipe, Pipe T-joint, Triangle,
    Heat exchanger, Two way valve, Three way valve, Pump, Speed controlled pump, Pressure tank, Circuit,
    Heating curve, Measurement, Setting, Adjust, Control, Indication, Alarm, Setting icon, Text, Outdoor wall,
    Damper, Filter, Radiator, Time program, Rect.
  - `link`: the registry.
  - `extraData`.
- **Links**: physical points by object name (`UI 4`, `AO 1`, `R1`); application points as `<app>.<point>`
  (`C1.C1_SP`). A component lists them in `links`, and `states` maps roles (`displayValue`, `alarm`,
  `indication`). The heating curve takes `supplyN`/`outsideN` (a fixed outside value is written as a number),
  `pointCount`, `min`, `max`, `parallelShift`, `currentOutside` and `currentSupply`. The setting icon is a list
  of set values the user can edit.
- **The registry is required**: with an empty `link.links` the boxes stay blank. Each entry is `{type
  (PhysicalPoint/Setvalue/Measure), objectType (BACnet type number), id (object identifier), pId 85, deviceId
  255, pointId (<name>.M/.SP/.C/.S/.I), technicalName, uId, displayName, allowManualControl}`. The ids are
  the project objects' `ObjectIdentifier` (they match the web UI's `HIERARGY.ZIP`), so `WEBP` fills the
  registry from the project at build time and a page file needs links only.
- **Languages**:
  - Point names, units and state texts on a page come from the device in the user's language. Proven in
    Finnish: the setting-icon popup lists "Lämmityspiiri 1 kesäkatkaisuraja" etc. and "Päällä" in the enum
    dropdown.
  - The device hierarchy (`HIERARGY.ZIP`) carries all 15 languages of every point.
  - A `Text` component and the page name hold one string, so the generator picks `program.json`
    `webui.language`.
- **PowerShell + Newtonsoft**:
  - Assigning a string to a JObject index goes through `JToken.Parse` (use `JValue.CreateString`).
  - A function returning a JToken must return `,$x`, or PowerShell unrolls it to nothing.
  - Newtonsoft is loaded only once the Web UI page was opened: `Web-Json` loads it from the tool folder.
- **Build** (proven on dh2):
  - `program.json` `"webui": {"language", "pages": [{"name": {en, fi, sv}, "file"}]}`. The page file is
    written by `make_webui.py`.
  - The generator localises texts, checks every link against the plan and writes `web_set.ps1`.
  - `build.sh` stage `webui` runs `WEBP`, saves and reopens, then `Dump-Web` and
    `verify_ouflex_build.py webui`.
  - dh2 page "Lämmitys": 48 components, 53 links, all resolving after reopen.
- **Drawing conventions** (from the vendor library and the editor code, `charteditor/static/js/main.*.js`):
  - A pump drawn at rotation 0 points right. On a circuit's return leg the vendor uses `rotation: "180"` (flow
    back to the heat exchanger).
  - Pipe colour presets: red `#ff2424` (supply), blue `#24B4FF` (return), light blue `#9DCEDA`, grey,
    orange `#FFBC24`. A loop is two pipes, supply and return, split at the consumer.
  - A Pipe is one polyline: **one point per corner**, and the editor draws the bend. A user adds points by
    right-clicking the pipe and drags them. Do not approximate curves with many points: the bend gets baked in
    and the pipe becomes a pain to edit (tried, reverted).
  - The local editor has no bend component (only Pipe, T-joint, X-joint) and no gradients. Gradients
    exist only in the online OuNet builder. The heat exchanger's red-to-white gradient is fixed.
  - Tee joints sat slightly off on our mains. Branches that start on the main's centre line, with the last
    branch drawn as the main's own bend, look cleaner.
- Time program component: see "Time programs". Not yet: several pages with navigation between them (`internalLink`).

## Trends (proven 2026-11-24)

- **Trend logs**: a device has 200 trend log objects (`CTrendObject` `Trend_1`..`Trend_200`, BACnet ids from 102).
  `CTrendConfigObject`: `MaxTrendPoints` 200, `LogMaxCapasity` 17500000. A new project preassigns 34 of them to
  the physical points (UI 1..16, DI, AO, R, TR ...) at 60 s and 10000 samples; physical points also default to
  `TrendOn` with group "Inputs" (Process monitoring). Application points default to `TrendLogEnabled` False.
- **A log is in use** (`IsFree` False) when its `m_TrendRefObjectVariableName` resolves through
  `ProjectApp.GetObjectByFullName` and that point has `TrendLogEnabled`. Otherwise `IsFree` clears the reference.
  The reference is the point's `FullVariableName`: `C1.C1_SP` for an application point, the object name (`UI 4`)
  for a physical one. Settings on the log: `m_TrendSampleInterval` (s, UInt16), `m_TrendLogBufferSize` (samples),
  `m_TrendLogEnabled`, `m_TrendProperty` (PRESENT_VALUE). The same fields exist on the point.
- **Groups** (what the web UI's trend view shows) are `ChartData["OumanTrend"]`, a JSON array of
  `{uid, name, data: [{id: <log id>, name, color, technicalName, pointId}], graphs: [{type: "line",
  data: [<log ids>], yAxis: {id, name, position left|right, offset 0|50, min, max}, enabled}]}`. That is one
  graph per y axis, at most 30 points per group. Format from the device web app (`www/js/bundle-min.js`:
  `createGroup`, `pointsDropped`, `saveTrendConfiguration`). The trend editor in the web UI writes the logs to the
  device (`Logenable`, `Interval`, `Loglength`, `Refobj`, `Refprop`, `Refdev`). The tool then reads the device
  back into the project (`GetTrendObjects`: `config.cfg` + `object_values.bin`, `ReadAllSettingsOffline`).
- **Helpers**:
  - `TRD <point> <interval> <length>` takes the point's log or a free one, enables trending on the point and
    sets both sides.
  - `TGRP <name> @(@{name=<axis>; points=@(...)}, ...)` replaces a group by name.
  - `Dump-Trend` prints `TL|log|id|ref|interval|length|enabled|point on` and
    `TG|group|axis|point|log id|log ref now`.
- **Build**:
  - `program.json` `"trends": {interval, length, groups: [{name: {en,fi,sv}, axes: [{name, points}]}]}`.
  - Generated into `web_set.ps1`; stage `webui`; `verify_ouflex_build.py webui` checks the logs and groups
    after save and reopen.
  - dh2: 14 points logged (9 new logs; UI 1..5 had theirs), groups "Lämmityspiiri 1/2" (°C, %, on/off axes)
    and "Kaukolämpö". OK, and the saved-file check stays OK.
  - The device's trend editor (Finnish UI) lists the group with its points by their Finnish names, "163/200
    linkable points left".
- **Curves not seen**: the virtual Ouflex A shows the groups but never delivers trend history (the chart spins
  even after minutes of logging at 60 s and a refresh). The configuration is proven; the curves need a real
  controller.
- **Virtual device in use**: killing ProjectManager (hstart restart) leaves `OuflexA.exe` running. The next Web
  UI page then says "Virtual device is already in use" (modal). Kill `OuflexA.exe` first.

## Time programs (proven 2026-11-24)

A time program (schedule) is no block: it is an object the tool attaches to a block's Enum **input pin** (pin menu
"Add time program", the pin shows a clock). Blocks only consume a state (`TimeProgPredictBin/An` pre-heat, `WeekDayDetect`,
`DateTime`).

- **Model**:
  - `CBacnetScheduleObject` (the tool's class names follow a BACnet-style object model throughout; the Ouflex A itself
    offers Modbus and its web UI, not BACnet): `m_TimeProgramType` (`ETimeprogramType` On_Off / Max_Half_Min / Value),
    `m_DefaultValue` (a **string**), `m_States` (`CEnumItem` list, texts copied from the pin's enums, e.g. "Input0/Input1"
    on `SwitchAn.Select`), `m_WeeklySchedule` (`CWeeklySchedule.m_WeeklySchedule` = 7 `CDailySchedule`, index 0 =
    **Monday**, proven in the simulator), `m_ExceptionSchedule`, `m_ReferenceObjects`. `ObjectType` OBJECT_SCHEDULE (17).
  - Entry: `DP_TimeValue(OUFLEX_Time(byte h, m, s, hundredths), DPValue(EValueType, Int16 0, Byte 0, value))` in
    `CDailySchedule.m_TimeValues`. On/Off: `EValueType.Enum` (29) + UInt32 (read back `U32Value`); Value: `Float` (8) +
    Single (`FloatValue`). Types in assembly `BacnetObjectClasses` (`...PropertyStructs`, `...TimeProgramObjects`).
- **Handler** (`MyCanvas.addTimeprogramToolStripMenuItem_Click`): with no compatible program it calls
  `CBaseContainerData.AddTimeProgram(pin.DataObject)`. That needs IoType Input and no reference, adds the object, sets
  `pin.ReferenceObject`, `IsRefPropMainOwner` and `State` Active, and copies enums. Then the handler sets `PositionInUse`
  and `PositionTable` (a clone of the pin's), and pin `PositionCopied`. It sets `TimeSymbol.ShowSymbol` through the
  recorder and `TimeSymbol.DataObject` = the program, calls `syncronizeDiagram_Data`, and opens the modal property grid.
  With compatible programs it first shows the modal `AddSymbol` (reuse one).
- **Why the earlier attempt was not saved**: the static `MyCanvas.syncronizeDiagram_Data(data, elements, host, ref, ref)`
  removes every object of four categories (loop at IL 0x0BC5) unless `DontSyncronizeInDiagram` is set or
  `MyCanvas.GetSymbol(obj, elements)` finds it. `GetSymbol` searches **only `ComponentSymbol` pins** (block pins:
  SetPoint/ConnectPoint/Time/Measure symbols of inputs, Measure/ConnectPoint of outputs) plus alarm symbols of physical
  inputs. A program on an application interface pin (`EditorInputPin`) is never found, so the next sync (any `K`) drops
  it. **Put it on a block input**: then it survives every sync, the save and a restart (probe `TP3.ouear`: week, name,
  states, clock symbol, CheckAll True).
- **Helper** `TPRG $cv 'blk.pin' NAME default @(7 days) display @(off,on texts) [On_Off|Value]` does what the handler does
  without its dialogs and is idempotent (a rerun rewrites name, type, default, texts and week). A day is
  `'HH:MM=v,HH:MM=v'` (Monday first). `Dump-App` prints `TPP|blk.pin|name|sym=True`,
  `TP|name|type|default|week|en`, `TX|...` and `TS|name|off langs|on langs`; `projdump.ps1` prints `FTPP`/`FTP`.
- **A state holds until the next entry, across midnight** (checked in the simulator 2026-11-24: Monday `20:00=0`,
  Tuesday only `22:30=1`, default 1 → 0 on Tuesday 21:05, so the previous entry carried over, not the default).
  No 00:00 entry is needed: the dh2 week is `06:00=1,22:00=0` (an earlier build wrote a redundant `00:00=0`).
- **Web UI week editor** (clock component, preview on the virtual Ouflex A): lists the entries per weekday correctly
  (06:00 Normaali, 22:00 Pudotus) and the current value, and has Käsiajo (manual), Poikkeuskalenteri and
  Erikoispäivät tabs. Its day bars stay empty with one "Norm…" marker at hour 0, with or without a 00:00 entry; not
  explained (maybe the virtual device), not seen on a controller. The display's week view draws the bars correctly.
- **Simulator** (virtual Ouflex C, `ApplicationDebugger`):
  - The program runs on the Windows machine's **local** clock and weekday (a Tuesday-only program was 1 on a Tuesday; 17:45 UTC =
    19:45 local was already past).
  - It is evaluated **only when the program starts** (Load or Reset): a switch time passed while running (factor 1 for
    4 min, factor 100) changed nothing; Reset then gave the new value.
  - Writing the program's value (`Sim-Set`) is not taken.
  - So scenarios set the state by rewriting the week in the debugger's loaded application and loading again: `Sim-Week`,
    scenario step `{"week": {"C1_TPRG": "on"|"off"|[7 days]}}`.
  - Switching at the programmed times is not tested on a real controller.
- **Web UI**: component `{"type": "Time program", "props": {x, y, internalLink, rotation, size: "60", color: "#57564a"},
  "links": ["<app>.<program>"]}` (vendor page AHU301). Registry entry `type "Timeprogram"`, `objectType` 17, pointId
  `<name>.TP` (the vendor uses position ids `301.SC08.TP1`), `allowManualControl` false; `WEBP`/`Web-Entry` write it.
- **Build**: plan source `tprg(NAME, default, week, display, states)` (`oufplan.py`, Enum pin checked by `check_plan.py`).
  `make_ouflex_build.py` writes `TPRG` after every constant and set value. State texts come from texts.json `states`
  (applied by `TPRG`, not by the device-level `HST`). The verifier checks the pin, type, default, week and states in
  every language, and the saved file again.
- **Display menu**: the application's generated menu has a row per time program, so `HD <folder> <app> <NAME>`
  drops it like any point (dh2: "Time program" under each circuit, read back after reopen). How the row edits the
  week on the display was not looked at.
- **Modbus**: the tool gives each time program its own Holding block, outside the plan's registers. Document numbers
  for dh2 C1 (C2 = +362): 10001 current value (R), 10002 manual control (RW, −1 = automatic, 0/1 = state),
  10003 weekly program, 10123 exception calendar and 10243 special days (120 registers each). Not decoded or
  written.
- **dh2** (2026-11-24): `C1_TPRG`/`C2_TPRG` on `nsb.Select`, setback set values `Cn_SETBACK`. Built from nothing with
  every stage OK (apps incl. programs, device, Modbus, HMI 62 entries, Web UI links 362/363 `Timeprogram`, saved-file
  check). Simulator cases "3.8" (setback 41 → 31 °C, offset before, stop at TS_MIN; comfort no setback) pass.

## Ouflex M_BA (MB-A): device type, Modbus RTU slave, SD card files (seen 2026-11-24, tool only, no device)

- **Device type** in New project: **"Ouflex M_BA (Template/Ouflex M_BA.dev)"** (the list also offers M-Link, Ouflex A XL,
  Ouflex A, Ouflex AX). The start page names its software "Ouflex M BA 2.13.7"; firmware in `Template\Ouflex MBA bin`
  (`app_A_BA.bin`, `app_B_BA.bin`, `ncp473D.lin`, `start.bmp`). Made by code with the public helper `New-Project-Step
  <name> <dir> 'Ouflex M_BA'` (`prelude_public.ps1`; the same four dialogs as for an Ouflex A).
- **Device page I/O**: UI 1..15, InternalSensor, analog outputs Y1..Y4, relays R1..R6, Sounder.
- **Bus ports** (Devices page, `treeView` nodes):
  - `Modbus RTU slave (COM2 (A1/B1))`, a `CModbusRTUSlaveConfig`: `Enabled` True, `Address` 1, `DelayBetweenPackets`
    100, `m_ReplyTimeout` 1000. Its `m_RefSerPort` (`CBacnetSerialPortConfig`): COM2, connectors A1;B1, **9600 8N1**
    by default, `m_Parity` None/Even/Odd, `m_FlowControl` None/XonXoff.
  - `Modbus RTU master 1 (COM4 (A2/B2))` (MB1), `Modbus RTU master 2` (MB2, not in use), `Modbus TCP master`.
  - Set by code: `$slave.Address=2`, `SF $port 'm_BaudRate' ([uint32]19200)`, then `Save-Project`. Read back after
    reopen: address 2, 19200 8N1, COM2 A1;B1 (proven in the tool; behaviour on a device not tested).
- **Card export by code, no mouse** (proven 2026-11-25, helpers `Start-CardExport`, `Card-Folder`, `Card-Done` in
  `win/prelude.ps1`): the Browse For Folder dialog is a `#32770` window of the tool's own process. An `hrun` posted after
  `Start-CardExport` runs inside the dialog's message loop, so `SendMessage(dlg, BFFM_SETSELECTIONW 0x467, TRUE, path)`
  selects any existing folder (the path string is valid because it is the same process) and `BM_CLICK` on control 1
  presses OK. The files go straight into that folder. "Data loaded successfully" is a message box whose OK is control
  **2**. Dialogs are found by class among the process's windows, not by title (Windows translates the folder dialog's
  title). Traps met on the way: `FindWindow($null, ...)` from PowerShell never matches, because PowerShell passes `$null`
  to a string parameter as ""; the dialog is often not foreground (`gui.sh fg` prints an empty title); and the firmware
  files keep their original timestamps, so collecting an export from the Desktop by modification time misses 11 of 23.
- **Third-party Modbus slave on a master port** (seen 2026-11-25 in the templates and types, nothing built): the generic
  device template is `Template\Devices\NewDevice.sdev` (typeName `CommonModbusDevice`) + `NewDevice.xml` (points:
  `addressindex`, `addressformat`, `scaling`, `type`, `modbusfunction`, `Enum`). Per point `CModbusData`:
  `ModbusFunction` (`EModbusFunctions` CoilStatus=1, InputStatus=2, HoldingRegister=3, InputRegister=4: the area read),
  `DataType` (U16, S16, U32, S32, Float, ...), `Swap` (NoSwap, SwapWord, SwapByte, SwapByteAndWord), `NumberOfRegisters`,
  `Scaling`, `Signed`, `WriteOnly`, `ReadAsMultiple`, `PollingInterval`. Which function code the master uses to write
  (05/06/15/16) is not a field: firmware's choice, unknown. Which word order `NoSwap` means is unproven (likely high
  word first). Bus points reach an application with canvas `AddBusPoint` (proven for FLEX UI8).
- **Which written values are stored** (from the code that writes the device object file,
  `OuFlexDevice.COuman6000Converter.createObjectFileLine` / `isSavingProperty`, per property flags):
  - flag 1 "saving" for: the **present value of every set value** (object category Setvalue), the present value of
    application points with IoType SetPoint (4), constants, measurements only when `StoreObjectToFile` is set, time
    programs, and the property list `m_SavingProperties` (MANUAL_CONTROL, MANUALCONTROL_VALUE, weekly/exception
    schedules, special days, description, language, lock code, ...);
  - flag 128 "save immediately" only for a set value whose `SaveAlwaaysImmediatelyAfterChanges` (sic) is True; the
    default is False, so the device stores written set values deferred. When and where (internal flash or the SD
    card) the device stores them is not in the tool;
  - so a value a Modbus master writes often (a heartbeat) into a set value is a stored value. Measurements are
    read-only on the slave, and a manual-control write is stored too.
- **SD card files**: Device > "Load applications to zip file" (`DeviceConnectionTool.loadDataToDeviceToolStripMenuItem_Click`
  → `loadAllToDevice`) asks first "keep the device's set values?" (not seen for a new project), builds
  `<project>\Devices\Device1\Temp\SD`, opens a native **Browse For Folder** dialog (no file box; selected by message, see "Card export by code")
  and writes the files **unpacked** into the chosen folder ("Device data is loaded to the folder ..."). For an
  empty MB-A project, 23 files: `app_A_BA.bin`, `app_B_BA.bin`, `ExtHMIFirm*.bin`, `IO-CardsSW.bin`, `OuflexIO.bin`,
  `ncp473D.lin`, `start.bmp`, fonts (`smallfont*.ehf`), `config.cfg`, `mbs_tcp.mbs`, `Menus.mns`, `menuIndexes.mnu`,
  `smsmenu_0.smnu`, `Texts_1.txt`, `Units_1.txt`, `HIERARGY.ZIP`, `POINTINFO.ZIP`, `descrFiles.zip`,
  `application_id.txt`, `tooldata.7z` (the project). Pick an empty folder: with Desktop selected the files land loose
  on the desktop. **On a device (proven 2026-11-25)**: the 23 files in the root of a FAT32 card (one MBR partition; a
  64 GB card formatted FAT32 worked), inserted with power off: at power-up the MB-A
  loaded the project and its display menu showed the application's HMI folder.
- **Modbus scaling of application points** (proven from the card file `mbs_tcp.mbs`, columns `<object id><datareg>
  <regbitmask><numberofreg><datatype><signed><propertyid><scaling><rw>`): an S16 register carries the value × 10^decimals
  of the point (PT1 with 2 decimals → scaling 100, 1 decimal → 10, binary → 1), signed for analog points. The html
  Modbus document leaves this out for application points.
- **Explicit registers**: `setv(..., reg=1001)` / `measure(..., reg=1102)` in a plan override the base + area + offset
  rule (`oufplan.py`, `make_ouflex_build.py`); RTU slave settings come from `program.json` `"rtu_slave"` (helper `RTUS`,
  checked as `RTUS|...` in the device dump).
- Device > Create > "Modbus slave template" makes an Ouflex `.dev` template of this device for **another Ouflex as
  master** (Template\Devices), not a list for a third-party master.

## Languages, Modbus export without a dialog, GUI keystrokes (proven 2026-11-24)

- **Translations end to end** (dh2, en/fi/sv):
  - Point names (set values, measurements, physical I/O), state texts and the display menu are written with
    `Set-ML`: English into all 15 languages, then each translation over it.
  - Read back per language (`TX`/`ST` lines, `Dump-Hmi`) and checked: apps 72 + 72 + 3, device 30, HMI 58
    entries + 14 state texts, all OK.
  - Document language sv-SE turns the virtual display Swedish, system menus included ("Systeminställningar",
    "Språk/ Language" row, Swedish state texts).
- A display name's `ToString()` follows the **document language** (ProjectManager in fi-FI gave Finnish I/O
  names), so dumps print `ML-En` (en-GB) where English is compared.
- **Modbus document without the Save As dialog**: the menu handler (`DeviceConnectionTool.createModbusInterfaceHtml`)
  takes the `CDescriptionFileCreator` from `m_CurrentDevice.OnlineConnection.DeviceDataConverters`, sets its
  `OuFlexDevice` and calls `createModbusInterfaceHtml(file, true)`. The dialog only supplies the path.
  `Export-ModbusHtml <path>` does that; `build.sh` uses it.
- **Do not type into dialogs by SendKeys.** What went wrong:
  - The clicked Save As layout changed between runs.
  - A leftover always-on-top "Virtual device" window (VirtualOuflexC, which outlives ApplicationDebugger) took
    the keys.
  - `SetForegroundWindow` reported success but Windows' foreground lock kept another window in front.
  - A late dialog let the keys reach Explorer, which then browsed folders on its own. Nothing was changed, but
    Enter in Explorer opens items.

  Prefer calling the code behind a dialog. The GUI runner now has `focuswin <title>` (FindWindow; pass
  `[NullString]::Value`, since PowerShell turns `$null` into `""`), and it skips `keys`/`text` when the window
  is not found.
- Each posted `Start-ModbusExport` queues its own Save As. Failed runs leave dialogs waiting; cancel them
  (`focuswin Save As` + ESC) before retrying.

## Licence (trial) check

- BA Tool licensing is TurboActivate (`OuFlex.Common.Helpers.CCommonHelpers.m_activate`). Unlicensed it runs a
  14-day trial. **Test**: when Application Builder opens an application in the function-block canvas, the trial is
  still on; once it ends the editor drops to a table view ("lite" mode). Read-only status from `hrun`:
  `CCommonHelpers.IsActivated($false)` / `IsTrial($false)` (2026-11-24 on the tool machine: False / True, canvas shown,
  dh2 apps built, saved and verified OK). Never call `UseTrial`/`ExtendTrial`/`Activate`, never patch the checks:
  a licence key or trial extension comes from Ouman.
- Application Builder toolbar has **HMI configurator**, **Import container from file**, **Object editor**.
  The HMI configurator is covered in "Local HMI" below.

## Local HMI (row display) menu (proven 2026-11-24)

Ouflex has two user interfaces: the **local row-based display** (the panel the simulator shows, menus of rows)
and the **Web UI**. This section is the local one; the Web UI is the ProjectManager page "Web UI configuration"
(`ChartEditor`: graphic pages "Add new chart / Add chart from library / Preview", plus a "Trend configuration"
tab), not worked out yet.

- **Two menu trees**. Every application carries an **automatically generated** menu
  (`CApplicationData.m_Menu`, `m_NoGenerateUI` False). The generator groups rows into Inputs ("Tulot"), Outputs
  ("Lähdöt", with ANALOGISET/DIGITAALISET header rows), Curves ("Säätökäyrät", one `CurveView` per Curve block with
  its 5 points), Set values ("Asetusarvot") and Software measurements ("Ohjelmalliset mittaukset"). Row text =
  the point's display name. The **device menu** (what the controller shows) is
  `CommonUIConfig.m_LocalMenu` on ProjectManager page 1 ("Local HMI / SMS"). It starts with the protected
  System settings (time, network, Modbus, serial ports, display, backup ...), Alarms and Point info submenus.
  **Nothing from the applications is in it until it is dragged there**: a freshly built project shows no
  application rows on the controller.
- Application Builder's HMI configurator (`toolStripButtonUIConfig_Click` → modal `UIConfigForm(app, null)`)
  shows only that application's generated tree; its device pane is empty. Build the device menu in
  ProjectManager.
- **Model**: `CSVObject` (a menu, itself a `CBaseBacnetObject`) holds `m_SubOrdinateList` of `CDisplayItem`
  rows. A submenu row's `ObjectPropertyRef.BacnetObject` is the child `CSVObject`. A value row's
  `ObjectPropertyRef` points to a point plus a property (`PROPERTY_PRESENT_VALUE`). Row fields: `m_DisplayName`
  (empty = the point's name), `m_Hidden`, `m_Protected`, `m_VisibleLevel`/`m_AccessRightLevel` (3/5 by default),
  visibility rules, prefix/suffix, `m_MenuType` (Submenu, CurveView ...).
- **Drag and drop** (the GUI way, "drag and drop from the program menu", folders and submenus can be made):
  the drop handler ends in `CommonUIConfig.HandleDropFromGeneratedUi(srcNode, toNodes, targetMenu, copy=true)`.
  It **deep-copies** the row or the whole submenu (a dropped folder keeps its children). The copy does not follow
  later changes in the application: drop again or use "Update object".
- **New folder** = what "Add submenu" does without its name dialog: new `CDisplayItem`
  (`AllowUserAddRemoveSubMenus`, `Protected` False), `ObjectPropertyRef.BacnetObject` = new `CSVObject`,
  `parent.CreateMenuItem(item)`, then the text. The main level takes at most **15** entries ("UI main level
  full!", `count < 15` in the IL), the 3 system menus included.
- **Texts and languages**:
  - Every text is a `CMultilangString` holding all **15 languages** (en-GB, fi-FI, sv-SE, et-EE, ru-RU, lv-LV,
    tr-TR, pl-PL, lt-LT, da-DK, fr-FR, de-DE, no-NO, cs-CZ, nl-NL). `SetTextToAllLang`, `SetString(text, lang)`.
  - A row shows the point's display name (`DisplayNameConfig` ObjectName) unless it is set to **OwnName** with
    its own `DisplayName`.
  - The display follows the project's **document language** (ProjectManager toolbar combo
    `comboBoxDocumentLanguage`, fi-FI in the base project). Proven: switched to en-GB, the virtual display shows
    "System settings", our English rows and states, plus a "Language: English/English" row. On fi-FI the
    "Kieli/ Language" row is hidden. The controller's own language is the device property `USER_LANGUAGE`.
  - The generated group names (Tulot, Asetusarvot ...) and the system menus come in the document language.
- **State texts** of binary points (`CBinarySetpointObject` / `CBinaryMeasureObject`): `m_InactiveText` and
  `m_ActiveText`, multilingual. Measurements default to Off/On in every language. A binary set value on a
  switch's Select pin got the **pin names "Input0/Input1"** (dh2 `C1_ENABLE` showed "Input1"). They are set on
  the point object, so the Web UI gets them too.
- **Curves**: a Curve_3p or **Curve_5p** block becomes a `CurveView` row. The display shows it as a table plus a
  graph (−20 = 58, 0 = 41, +20 = 20, min, max) and the points are editable there. Curve_5p, probed in an
  application: the view holds all 10 set values (Out1..Out5, the movable breakpoints In2..In4, Min, Max). Its
  look on the display has not been seen yet.
- **Helpers** (`win/prelude.ps1`, project open in `pm`). Paths name menus by their text in **any** language
  (`'Heating circuit 1/Settings'`, `''` = main level). Source rows are found by **point name** or curve block
  name under the application, so nothing depends on the document language. All are idempotent and count
  add/skip/fail like the build helpers.
  - `HF <parent> <en> [fi]` makes a folder.
  - `HD <parent> <app> <point|curve> [en] [fi]` drops a generated row and gives it its own text.
  - `HST <app> <point> <off en> <on en> [off fi] [on fi]` sets the state texts.
  - `Hmi-Remove <path>`.
  - `Dump-Hmi` prints `HMI|depth|kind|object|en|fi|states`.
  - en goes to every language and fi overrides fi-FI.
  - Generated scripts must carry a UTF-8 BOM (`write_bom`), or PowerShell 5.1 reads ä/ö as ANSI.
- **Build pipeline** (proven 2026-11-24 on dh2):
  - `program.json` `"hmi": {"menu": [...], "states": {...}}` → `make_ouflex_build.py` writes `hmi_set.ps1`
    and `expected.json` `hmi`.
  - `build.sh` stage `hmi` (after `modbus`) restarts `pm` (so no hidden "save changes?" prompt from another
    project), opens the build project, runs the script, saves, reopens and dumps.
  - Then `verify_ouflex_build.py hmi` checks order, depth, objects, texts, state texts and curve points.
  - dh2: 58 entries plus 14 state texts, RESULT OK. A rerun skips all 58.
- **Quirks**:
  - In the hosted ProjectManager the device tree `multitreeLocalUi` was found detached from its panel
    (`splitContainer4.Panel1` empty, middle pane blank). `Hmi-Ui` puts it back; it is display only.
  - Use `.psobject.BaseObject` for reflection arguments. PowerShell unrolls a `TreeNodeCollection` passed in
    an argument list, so build the `object[]` by hand.
  - Reopening the open project raises a modal "already open": open another project first.
- **Virtual display**: the "Start virtual display" button (`startVirtualUIButton_Click`) runs
  `OuFlex_C_VirtualUI\Ouman6000.exe` ("Virtual HMI" window) with the device menu. It opens at System settings.
  Calling `updateSelectedNodeToVirtualUI(node, false)` did not move it.
  - **Keys** (proven): focus the window by clicking its title bar, then send keys (`gui.sh 'keys {DOWN}'`).
    At the main level, Down/Up moves between the main menus (the icons on the left). Enter opens the menu or
    row (Right also opens a row). Down/Up moves the row cursor, ESC goes back.
  - **Never click inside the display**: a click is OK on that row and can open a value editor. Leaving the
    editor needs a long ESC, which SendKeys cannot do. Restart the preview instead (kill
    `m_VirtualOuman6000`, then press the button again); nothing is written.
  - Shown on the dh2 copy: "Heating circuit 1" with its rows (0.0 values: the preview is not connected to a
    running program); Settings > Asetusarvot with defaults and units (40.0 °C, 60 s, 18.0 °C, 3600 s); the curve
    view as a table (−20 = 58, 0 = 41, +20 = 20, min 18, max 70) plus a graph.
  - `MoveWindow` coordinates are scaled about 1.12 against screenshot pixels (display scaling).
- ProjectManager pages, as `m_ConfigForms` entries: Applications (`ApplicationManager`), Local HMI
  (`UIConfigurator`), Object editor, Alarm routing (`Users`), System settings, Devices, Web UI configuration
  (`ChartEditor`, `Show-Page 6`), Wiring diagram, then `ApplicationConfigurator`, `HierargyEditor` and
  `ProcessViewer` (Process monitoring, Device connection; mapping not checked).

## Still to work out

Alarms (`AddAlarmPoint`, "Add alarm" on points/outputs, sensor fault alarm); global points across two
applications on the device canvas; local/remote pattern (SetPointSync /
StateSync) and how vendor library apps attach set values; offline simulation (`ApplicationDebugger.exe`,
`OuFlex_C_VirtualUI\Ouflex C.exe` exist, `VirtualDevice` is empty; not tried). Also open (2026-11-10 night): constants and
wires on U32 pins (Pid PreviousStage/NextStgS chain, untested; both examples leave them untouched and CheckAll accepts it);
alarm blocks (AnalogAlarm/BinaryAlarm/DeviationAlarm, they create alarm objects); exception days of time programs; creating a project with
New project by code (only read from IL); no MotorExercise block exists in the 2.130.14 library catalogue.

### Real controller: read, load, force (seen 2026-11-11 and 2026-11-12 on one Ouflex A on a test table)

**Nothing in this skill connects to a controller, and an agent must not do it on its own. "Load all to device"
replaces the program in a live controller and restarts it; outputs change state. It is done only when the person
responsible for the plant asks for it, is present, and has a copy of what the controller runs now (read it first,
below). The login and every firmware question are for that person, never for the agent.**

- **Read a program from a controller**: Project > New project → dialog "Add new device" → "Download from device" →
  pick the type → "Authentication required" (the user types the login). The project `.flprj` is 0 bytes and locked
  while the project is open: close the project before copying the folder.
- **Load to a controller**: left menu "Device connection" → type the address into "Ip address" → Connect → login
  dialog → "Load all to device". Dialogs met: "Different application" (the device holds another program; Yes =
  overwrite) and "Device must be updated" (firmware older than the tool's; the tool will not load without it, the
  firmware goes in the same packet). The log ends "Device started normally." / "Applications loaded to device."
  A first load took 7 minutes over a slow link, a second load in the same tool session 1 minute and asked for
  neither login nor firmware.
- The first Connect of a tool session can fail ("Unable to connect to device") although the controller answers;
  the second attempt connected.
- Window positions change if someone maximizes the tool: take a screenshot before every click on these pages.
- A modal left open by the tool (the "Applications loaded to device." box) swallows every later click; if clicks
  seem to do nothing, take a screenshot and look for a dialog first.
- **Modbus TCP slave** (port 502, unit 1): holding registers only (FC4/FC2 = illegal function); address on the
  wire = `ModbusRegister` (0-based). A block read that touches an undefined register fails with exception 2, so
  read exact ranges. Set values are S16 scaled by decimals, S32 is high word first. FC43/14 returns vendor, model
  and firmware.
- **Force an output on the controller**: left menu "Process monitoring" → Connect (own connection, separate from
  Device connection; takes about 10 s) → select "Physical points", key Right to expand → right-click the point →
  Properties → "Manual control ON" = Yes (double-click the value) → click the "Current value" cell, open its
  drop-down, pick On → OK. The row gets a hand symbol and shows [On]. Leaving the page asks "Do you want to copy
  the changes made to the project?": No keeps the forces out of the project; they stay active in the controller.
  Yes reads the point settings from the controller into the open project.
- A program load resets forced outputs.
- **A point in manual ignores the program** (proven 2026-11-12): TR 1–4 (`COu6000BinOutput`, physical type
  `TreeStateControl`, each with a "Pair of Triac objects" partner) have `ManualControlOn` = True in a new project.
  TR 3 wired to a constant 1 stayed Off after the load until "Manual control ON" was set to No; then both TR 3 and
  TR 4 went On, also as a pair. The build therefore emits `IOA $cv '<point>'` (ManualControlOn = False) for every
  output the plan drives, and `Dump-Device` prints `MAN|<point>|<bool>` for the verify step. Relays R1–R6 are in
  automatic by default.
- **Ouman Access switch** (seen in the data model, not changed): the device object list holds one
  `CBacnetEthernetPortConfig` with `AccessIsUsing` (display name "Access is using"), `AccessName`, `AccessIp`,
  `DHCP_IsUsing`, `HostName`, `IpAddress`, `FTP_IsUsing`. System settings shows of this object only "Web UI auto
  logout time". In a project built from the empty base it is False. Whether a load pushes it to the controller is
  not known.

### Further blocks and inputs (2026-11-12)

- **Pulse inputs** (seen in the data model and built, no pulses applied): `SupportedPhysicalTypes` lists `Pulse`
  for UI 13–16, DI 1, DI 2 and every UI8 channel; UI 1–12 offer Analog/Digital only. Setting
  `PhysicalType='Pulse'` switches the device type to `PULSE` (params `MinChannelChange=5`, `PulseScaling=1`), the
  point stays an analog input with a Float value (`UI 13.P` on the device page), max 8388608, and has
  `PulseFactor` / `PulseInitialValue`. Plan io kind `pulse`. `PulseCounterScaled` (CounterIn ← the point,
  CounterSet ← a set value) and `PulseMeter` pass the tool's check with Enable left at its default; `B` drops one
  built-in object of PulseMeter. What the point value and the two blocks do with real pulses is not tested.
- `OnOffPulse@2.4` starts with the On pulse at `StartState` = 1, which is the default (vendor text; the enum
  labels "0=On, 1=Off" read the other way round). Seen on a controller: Enable 0 -> 1 gave the output at once.
  `OffTime` and `OnTime` take wires.
