# From a functional idea to a built BA Tool project

Worked reference: `examples/dh-ex2` (district heating substation: domestic hot water and one heating circuit). It
holds `DESCRIPTION.md`, `make_plan.py`, `plan.json`, `layout.json`, `program.json`; a build adds `build/` (scripts,
`expected.json`, `out/` with dumps, verification results, screenshots, Modbus document).

## Steps

1. **Describe it.** Write `DESCRIPTION.md` first in the style of a description of operation: purpose, I/O list,
   control functions, set values (unit, default, min, max), measurements, alarms as status points, sensor fault
   handling, Modbus rule, and "deliberately left out".
2. **Choose blocks from the vendor text** (`design-rules.md`): `reference/primitive-docs.txt` and
   `reference/primitive-pins.txt`. Cite the sentence a choice rests on (`why=` in the generator); list in the
   description what rests on behaviour the text does not state. Check `pipeline/block_probe.json`: which pins the
   tool's check requires and which set values / measures a block brings with it.
3. **Write the generator** `make_plan.py` with `pipeline/oufplan.py`: `P.io(...)`, `a = P.app(...)`,
   `a.block(id, type, col, pins={...}, label=..., why=...)`, `.out(pin, measure(...), net(...), io(...))`.
   Declare blocks in data-flow order (that is the execution order); repeated structures are functions called twice.
4. **Check the plan**: `python pipeline/check_plan.py <dir>` until OK.
5. **Write `program.json`**: copy the example's; change `name` and the `paths` (`apps`, `project`, `modbus_doc`,
   optional `deliver`), keep `base` = `new`; add `modules` only for bus I/O.
6. **Build**: `scripts/build.sh <dir>` (gen, apps, device, modbus, filecheck, shots). It stops at the first
   failure with the difference; every helper is idempotent, so fix and rerun (a single stage with `STAGES=...`,
   single applications with `APPS=...`).
7. **Deliver**: `STAGES=deliver scripts/build.sh <dir>` copies the built project to `paths.deliver`, opens the
   copy and checks it. The device stage stops all hosted instances.

`python` here is whatever `batool.sh check` reports as Python 3 (`python`, `python3` or `py`).

## program.json

| Key | Meaning |
|---|---|
| `name` | program name (default: folder name) |
| `plan`, `out` | plan file (default `plan.json`), output folder (default `build`) |
| `paths.apps` | folder for the application files (`<APP>.ouear`), one per application |
| `paths.project` | the built project folder. Removed and made again by every device stage |
| `paths.base` | `new`: the build makes a new project by code, named like the last folder of `paths.project`. Or the folder of an empty project that is copied to `paths.project` (`C:\agentwork\base\OuflexA_empty` from `setup`). Or the same as `paths.project`: build in place in a project that is still empty, no copy |
| `device_type` | controller type for `paths.base` = `new`, as the tool lists it; default `Ouflex A` |
| `paths.modbus_doc` | exported Modbus document, without `.html` (default `<project>_modbus`) |
| `paths.deliver` | optional: where `STAGES=deliver` copies the result |
| `paths.flprj` | optional: project file name; default the `.flprj` found in the project folder |
| `modules` | bus I/O modules: template, connector, name, address, object pattern |
| `modbus` | register rule: base, offset per table, formats |
| `io_kinds` | extra I/O kinds or overrides of the defaults at the top of `make_ouflex_build.py` |
| `required_fill` | constants for inputs the tool's check requires but the plan leaves untouched |
| `net_transport` | `wire` (default) or `global`, see below |

## Pitfalls actually hit

- Vendor blocks bring their own set values and measures (Pid P/I/D + Output/Diff, Curve_3p/5p all parameters +
  outputs, Thermostat, MotorDriverV/3p, P_control, Deadband, Override, RunTimeCounter, StateSync). The build drops
  those the plan does not use; some pins are then empty and required (Pid P and I). Source every parameter you rely
  on explicitly.
- Required inputs are not predictable from pin roles: Max/Min Input1 is required, Average Input1 is not; Curve_3p
  Input is not required. Trust `block_probe.json`, extend it with a probe (see findings.md) for a new block type.
- U32 pins (Pid PreviousStage/NextStgS, NextStage) cannot be given constants or set values by the helpers; leave
  them untouched (the tool's check accepts that) and use one PID + `SignalSplitter` for sequences.
- A set value on an extendable input (And/Or/Add/Min/Max) is flagged by the checker: route the value through a
  non-extendable block (e.g. `SwitchAn` with Select 0, `Compensator`) or wire it.
- Names are case-insensitively unique per application across blocks, interface pins, set values and measures. A
  net named like a measure gets `_N` on its interface pin.
- New-project defaults: AO = TX_OUT 0..100 %; UI = NTC10 −50..130 °C. Configure every used point explicitly in the
  plan's I/O kind so the verification checks it.
- Any empty project with the right controller type works as `base`. A project built from a copy keeps the base's
  project name in the tool's title bar; `new` gives it its own name.
- `make_ouflex_build.py` can take minutes when one application grows (about 5 min for 91 blocks, in the layout
  search). It is not hung.
- Do not edit a build script while it runs.

## Page layout

- Without `layout.json` the generator searches a layout itself (`pipeline/ouflayout.py`).
- **Hand layout**: `<program dir>/layout.json`, one entry per application (`columns`, `align`, `dy`, `to`,
  `labels`; see `ouflayout.layout_manual`). Used instead of the search when present. Rule that gives clean pages:
  one row per function, neighbour columns for links, and a long wire only as a level line through a corridor kept
  free (input interface pin level with its consumer). `"_device": {"apps": {APP: [x, y]}}` places the application
  symbols on the device canvas (inputs column x 3, outputs x 919): keep the diagonal third of every wire clear of
  other symbols.
- Preview without the tool: `python pipeline/ouflayout.py <dir> --png <dir> -v` (needs the Pillow package).

## A project of your own to build into

- `paths.base` = `new` covers the usual case. `setup` also makes `C:\agentwork\base\OuflexA_empty` (one Ouflex A)
  to copy from. To make a project yourself, by code, on a fresh `hstart.sh pm ProjectManager.exe`:
  `hrun.sh -c "New-Project-Start"`, then `hrun.sh -c "New-Project-Step 'Name' 'C:\agentwork\proj' 'Ouflex A'"`
  repeated until it prints `NEWPROJECT done` (each call answers the dialog that is open; the last one saves).
  Device types offered: the list the step prints when the name does not match.
- With `paths.base` = `paths.project` the build works in place in that project.
- By hand it is Project > New project, name, directory, OK; "Add new device": Create new device; pick the type;
  OK; then Project > Save project.

## Signals between applications

- Default (`"net_transport": "wire"`): a net is an interface output, a device wire and an interface input; every
  net is a line on the device page.
- `"net_transport": "global"`: no interface pins and no device wires for plan nets; the writer's output gets a
  measure marked global, readers get `g_<name>` pins. The plan does not change. Read `<out>/signals.md` to see who
  reads what, since the connections are no longer drawn. Physical I/O stays wired on the device page.

## Outputs

- **Outputs the plan drives are set to automatic** (`IOA`): TR 1–4 are in manual in a new project and a point in
  manual ignores the program.
- A triac used as a plain on/off output: io kind `"triac"`.
