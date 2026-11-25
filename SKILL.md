---
name: ouflex-ba-tool
description: Drive Ouman Ouflex BA Tool (ProjectManager.exe / ApplicationBuilder.exe, the programming tool of the Ouflex A / C / M controllers) by script on the Windows machine it is installed on - place function blocks, wire pins, set constants, set values and measurements, save and check applications, build a whole project from a plan, without hand clicking. Use whenever the task is to build, change, inspect or verify an Ouflex function block program, to read a BA Tool project (`.flprj`, `Device.bin`, `.ouear`, `.ouepr`), or when the user mentions Ouman, Ouflex, BA Tool, Application Builder or "the programming tool" of an Ouflex controller.
---

# Ouflex BA Tool, scripted

BA Tool has no scripting interface. This skill runs the real tool inside a small host process that executes
PowerShell on the tool's UI thread, so the editor's own code places blocks and saves files. That is undocumented
behaviour of one tool version (2.130.14.1); on another version prove every step again.
Read `reference/findings.md` before changing how anything is built; it records what was proven and what was only
tried.

## First use on a machine

Run `scripts/batool.sh check` before anything else, and again whenever something basic fails. It prints one line
per requirement. Fix every TODO yourself where you can: `scripts/batool.sh setup` makes the work folder
`C:\agentwork`, compiles the host into the tool folder, reads the block library of the user's own installation
into `reference/` (`blocks.json`, `primitive-pins.txt`, `primitive-docs.txt`; they are Ouman's data and are not
shipped), and creates the empty base project. Ask the user only for what needs their hands: installing BA Tool or
Python, activating the tool's licence, an administrator shell if the tool folder is not writable, answering a
Windows Firewall question (Cancel is fine). Tell them exactly what to do and wait.

Tell the user once: **keep hands off keyboard and mouse while a command runs.** Tool windows open, move and close
on their desktop; `gui.sh` commands click and type there.

Never connect to a controller, load a program into one or answer a firmware dialog on your own. That is the
user's decision and the user's hands (findings, "Real controller").

## Where things are

- Everything runs on the Windows machine that has BA Tool, in the user's desktop session, from Git Bash. Tool
  folder: `BATOOL_DIR`, default the newest `C:\Ouman\OuflexBATool_*`. Work folder: `C:\agentwork`
  (`BATOOL_WORK`).
- `scripts/`:

| Script | Does |
|---|---|
| `batool.sh check` / `setup` | readiness, one line each / make what is missing |
| `hstart.sh <instance> <exe> [args]` | (re)start a hosted tool instance, e.g. `hstart.sh ab ApplicationBuilder.exe 'C:\agentwork\apps\X.ouear' mode=1 lang=en-GB` or `hstart.sh pm ProjectManager.exe` |
| `HNAME=<instance> hrun.sh <x.ps1>` | run PowerShell **on the UI thread of that hosted instance**, with `win/prelude.ps1` loaded first. `hrun.sh -c '<powershell>'` for one line. This is the main tool |
| `HNAME=<instance> hwait.sh [name]` | keep waiting for a script `hrun.sh` reported as TIMEOUT (it keeps running in the host) |
| `batool.sh hstop [instance]` | stop one hosted instance, or all |
| `gui.sh 'cmd' ...` | mouse and keyboard on the desktop, then a screenshot (prints the PNG path; Read it). Commands: `click x y`, `dclick`, `rclick`, `drag x1 y1 x2 y2`, `move`, `keys <SendKeys>`, `text <literal>`, `sleep ms`, `activate <title part>`, `windows`, `fg`, `ps <powershell>` |
| `batool.sh dlg list` / `dlg file <path>` / `dlg button <id>` | standard dialogs of the hosted tool (Save As, message boxes) by control id: no position, no typing. 1 OK/Save, 2 Cancel, 6 Yes, 7 No |
| `batool.sh run <x.ps1>` / `ps '<powershell>'` | plain PowerShell with `win/lib.ps1` loaded: the tool's DLLs without a tool window, for reading project files |
| `build.sh <program dir>` | build and verify a whole program, see below |

- `scripts/win/`: `cli.ps1` (the one PowerShell entry point behind the wrappers), `AgentHost.cs` (the host;
  `setup` compiles it into the tool folder, where it must sit), `prelude.ps1` (helpers available in every `hrun`
  script), `lib.ps1` (helpers for `run`), `build.ps1` (the build stages), `catalogue.ps1` (reads the block
  library), `projdump.ps1` (reads a saved project without the tool).
- `reference/primitive-pins.txt`: every library block with all pins (direction, name, type, default, text).
  `reference/primitive-docs.txt`: the documentation text stored in the block files. Both made by `setup`.
- `reference/design-rules.md`: what to build - choosing blocks from the vendor documentation (never from the
  name), constant or set value or measurement, fan-out. Read it before designing a program.
- `pipeline/`: the Python side (plan library, checker, build script generator, page layout, verifier).

## Rules that keep it working

- One command at a time, and one agent on the desktop: two drivers type into each other's windows.
- A modal dialog opened *by your script* blocks it, so `hrun.sh` prints `TIMEOUT`. Look with
  `batool.sh dlg list` and a screenshot (`gui.sh fg`), dismiss the dialog, then carry on. A modal opened by a call
  you *posted* (`$form.BeginInvoke`) does not block the host: the next `hrun` runs inside the dialog's message
  loop and can fill and close it (how a bus module is added and how a new project is made).
- PowerShell wraps .NET objects. When passing tool objects into reflection calls use the `UW` helper or the `CM`
  helper (which unwraps), otherwise `Invoke` fails with a PSObject conversion error.
- Work on copies under `C:\agentwork` until a step is proven, and back up a project folder before the hosted tool
  opens it. Never point a build at the user's only copy of a project.
- Scripts you write for `hrun.sh` are read as UTF-8. Scripts that PowerShell itself loads (dot-sourced files) need
  a UTF-8 BOM as soon as they hold non-ASCII text; the generator writes its files that way.

## The loop

1. `hstart.sh` the instance you need.
2. Write a small `.ps1`, run it with `hrun.sh`, read the output.
3. When something visual matters, `gui.sh fg` and Read the screenshot.
4. To learn how the tool represents something new, do it once with real input through `gui.sh`, inspect the
   resulting objects with `hrun.sh`, then reproduce it in code and compare field by field.
5. Prove every construct by save → restart the instance on the saved file → inspect → `Check`.

## Building a whole program

A program is a **program directory**: `program.json` (name, Windows work paths, base project, bus modules, Modbus
rule, I/O kinds, required fills, output folder) + `plan.json` + a generator that writes the plan. One command
builds it from nothing and verifies it:

    scripts/build.sh examples/dh-ex2                      # district heating + hot water (worked example, a few minutes)
    scripts/build.sh examples/dh2                         # two heating circuits, time programs (night setback)
    STAGES="gen apps" APPS=ALARM scripts/build.sh <dir>   # single stages, single applications
    STAGES=deliver scripts/build.sh <dir>                 # copy the built project to paths.deliver, open, check

New program: read `reference/new-program.md` (steps and the traps actually hit). Plans are written with
`pipeline/oufplan.py` (blocks, pin sources, Modbus offsets; nets and I/O derived) and checked with
`python pipeline/check_plan.py <dir>` against `reference/blocks.json` and `pipeline/block_probe.json` (required
pins learned from the tool's own check). The example's `make_plan.py` + `DESCRIPTION.md` are the reference for
style; do not copy the example when asked to design something from a description of your own.

| Piece | Does |
|---|---|
| `pipeline/make_ouflex_build.py <dir>` | plan JSON → `<out>/`: `apps/<APP>_<n>.ps1` (≤150 operations each), `dev_2_io`, `dev_3_import`, `dev_4_wires`, `modbus_set.ps1`, `expected.json` (includes the program config). Naming rules and layout are constants at its top; I/O kinds have defaults there and program.json can add or override them |
| `win/prelude.ps1` build helpers | `B` block, `IP` interface pin, `W` wire, `K` constant, `SETV`/`SVL` set value (+fan-out), `TPRG` time program, `MS` measure, `LB` label, `HU` hide unused pins, `EO` execution order, `AppName`; device: `BP` bus point, `IOC`/`IOP` I/O config, `IMP` import app, `DW` device wire, `MBR` Modbus register; `Dump-App`, `Dump-Device`, `Dump-Modbus`, `Check-Project`, `Capacity`. All idempotent: a rerun after a failure adds only what is missing |
| `scripts/build.sh <dir>` | stages `gen apps device modbus hmi webui filecheck shots` + optional `deliver` (`STAGES=`, `APPS=`, `KEEP_GOING=1`). Per application: fresh `NewApplication.ouear` → scripts → `Check` → save → restart on the file → `Dump-App` → verify → screenshot. Then device level in a new project made by code (`paths.base` = `new`) or on a fresh copy of `paths.base` (bus modules from program.json, I/O, import, wires, save, reopen, `Dump-Device`), then Modbus (export, `modbus_set`, save, reopen, export, `Get-ModbusMap`), then `hmi` (program.json `"hmi"`: the controller's display menu, `hmi_set.ps1`, save, reopen, `Dump-Hmi`) and `webui` (`"webui"`/`"trends"`: Web UI pages with their link registry, trend logs and groups, `web_set.ps1`, save, reopen, `Dump-Web`/`Dump-Trend`), each only when program.json has it, then `filecheck` (`win/projdump.ps1` reads the saved Device.bin without the tool). Stops at the first `FAIL`, `TIMEOUT` or difference. The device stage stops every hosted instance |
| `pipeline/verify_ouflex_build.py <dir> app\|device\|modbus\|hmi\|webui\|file ...` | compares the read-back dumps with `expected.json` (plan only): blocks (type, version, x/y, execution order, overlaps), wires, constants, set values, measures, interface pins, labels, drawn lines; device wires, I/O config, application order, the tool's check; Modbus plan-vs-built table; display menu (order, depth, texts per language, state texts); Web UI links resolved, trend logs and groups |

Rules the pipeline depends on: names are case-insensitively unique per application and a clash opens a modal
dialog, so the generator resolves clashes up front (set value / measure names win, net pins get `_N`, I/O pins
`_IO`, blocks `_b`); generated `.ps1` files carry a UTF-8 BOM; scripted changes are saved only after
`Mark-Modified` (inside `Save-Project`); the device-level application order is forced with `DEO` (otherwise the
first save re-sorts it). Outputs land in `<out>/out/` (dumps, `*.verify.txt`, screenshots, the exported Modbus
document, `modbus.verify.txt` = plan-vs-built table). `paths.project` is removed and made again by every device
stage. An empty project to copy instead of making a new one: `C:\agentwork\base\OuflexA_empty` (an untouched New
project with one Ouflex A, made by `setup`).

## Time programs (schedules)

A time program is not a block. The tool attaches it to an Enum **block input pin**, which then shows a clock (for
example `SwitchAn.Select`, switching a setback amount in and out). Never put it on an application interface pin: the
tool drops it from the object list at the next sync, so it is not saved.
- In a plan: `tprg(NAME, default, week, display, ["Off text", "On text"])` from `pipeline/oufplan.py`. The week is 7
  strings, Monday first, `'06:00=1,22:00=0'`. A state holds until the next entry,
  across midnight.
- The apps stage writes it with `TPRG` after the constants. It is checked after reopen and again in the saved file.
- State texts come from texts.json `states`.
- By hand: `TPRG $cv 'blk.pin' NAME default @(7 days) display @(off, on)`.
Details, including the Modbus registers the tool gives each program: findings, "Time programs".

## Ouflex M_BA (MB-A): Modbus RTU slave, programmed from a MicroSD card

Device type "Ouflex M_BA" in New project (`New-Project-Step <name> <dir> 'Ouflex M_BA'`). I/O UI 1..15, InternalSensor,
Y1..Y4, R1..R6. A Modbus RTU **slave** on COM2, terminals A1/B1 (default address 1, 9600 8N1), besides RTU master 1 on
COM4 (A2/B2), master 2 and a TCP master.
- **Slave port in a build**: `program.json` `"rtu_slave": {"address": 2, "baud": 19200, "parity": "None", "stop": 1}`.
  The device stage sets it (`RTUS`) and checks it after reopen.
- **Fixed registers**: `setv(..., reg=1001)` and `measure(..., reg=1102)` in a plan. Every point is a holding register;
  an S16 carries value × 10^decimals. Set values are writable, measurements read-only.
- **Stored values**: the device stores the present value of every set value, so a master should write commands on
  change, not cyclically (no heartbeat into a set value).

Programming a device (proven on an MB-A):
1. Build and check the program as usual (`scripts/build.sh <program dir>`, then the simulator).
2. **Card files**, three `hrun` calls on a `pm` instance with the project open, no mouse:
   `Start-CardExport` (Device > "Load applications to zip file"; the tool opens a Browse For Folder dialog),
   `Card-Folder 'C:\work\card'` (selects that empty folder in the dialog and presses OK; the tool writes the files),
   `Card-Done 'C:\work\card'` (closes "Data loaded successfully" and lists the files). An MB-A project gives 23 files:
   firmware, `config.cfg`, `mbs_tcp.mbs` (the slave register map), menus, texts and `tooldata.7z` (the project).
3. **Card**: FAT32, one partition, the files in the **root**. Windows' own format offers FAT32 only up to 32 GB; a 64 GB
   card formatted FAT32 elsewhere worked. exFAT is untested.
4. **Device**: power off, insert the card, power on. The MB-A loads the project; the display menu shows the program's
   folder. Check the slave settings on the display (System settings).
5. **Wiring**: RS-485 two-wire, A1 = D+, B1 = D− (proven; the tool names only A1/B1), daisy chain, 120 Ω only at the
   two bus ends.

Proven on a device with a PLC as master: the slave answers FC 03 and FC 16 with one register, about one request per
second without trouble (FC 06 not tried). Unproven: which function code the MB-A's own RTU master writes with.
Details: findings, "Ouflex M_BA".

## More helpers (`win/prelude.ps1`)

- **Simulator**, no controller needed: `hstart.sh dbg ApplicationDebugger.exe '<app.ouear>' lang=en-GB`, then
  `Sim-Load`, `Sim-Run`, `Sim-Set`, `Sim-Get`, `Sim-Reset` and `Sim-Factor 100` (time 100× faster).
- **Time programs in the simulator**: the virtual device evaluates a program from the PC clock only at Load or
  Reset, so set its state with `Sim-Week NAME @(7 days)`.
- **Display menu** of the controller (build stage `hmi`): `HF` folder, `HD` row dropped from an application's
  generated menu, `HST` state texts, `Dump-Hmi`.
- **Web UI pages** (build stage `webui`): `WEBP <name> <page.json>` fills the page's link registry from the project. `Dump-Web` reads
  it back.
- **Trends** (build stage `webui`): `TRD` trend log per point, `TGRP` groups, `Dump-Trend`.

Model and limits of each: findings, sections "Simulation without a controller", "Local HMI", "Web UI pages" and
"Trends".

A built project is a file on disk, checked against its plan. Whether the program does what the plant needs is
engineering: say plainly what was verified (structure, the tool's own check) and what was not (behaviour on a
controller).
