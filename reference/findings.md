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
- **Physical point polarity** is the BACnet `Polarity` property (`Normal` = "Closing (NO)", `Reverse` = "Opening (NC)",
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

## Still to work out

Alarms (`AddAlarmPoint`, "Add alarm" on points/outputs, sensor fault alarm); global points across two
applications on the device canvas; local/remote pattern (SetPointSync /
StateSync) and how vendor library apps attach set values; offline simulation (`ApplicationDebugger.exe`,
`OuFlex_C_VirtualUI\Ouflex C.exe` exist, `VirtualDevice` is empty; not tried). Also open (2026-11-10 night): constants and
wires on U32 pins (Pid PreviousStage/NextStgS chain, untested; both examples leave them untouched and CheckAll accepts it);
alarm blocks (AnalogAlarm/BinaryAlarm/DeviationAlarm, they create alarm objects); time programs; creating a project with
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
