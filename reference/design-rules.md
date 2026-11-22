# Design rules for Ouflex programs (2026-11-10)

These are about *what* to build. How to build it is in `findings.md`.

## Choosing blocks

- Ouman block names differ from IEC names, and same-sounding blocks behave differently.
  Read the vendor documentation of every block before using it; never choose by name.
  Examples that bit: `RisingEdgeDetect` latches until Reset (not a one-scan pulse); `Divide` skips a
  zero divisor (A/0 = A); `Pid` Reverse 1 = heating and P is a proportional band; `OnDelay` with
  Enable 0 passes the input through; `StartDelay` counts from Reset 1→0; `Integrator` Enable 0
  clears the integral; `CountUp` Reset loads InitialValue.
- Block reference: `reference/primitive-docs.txt` (the documentation text stored in the block files) and
  `reference/primitive-pins.txt` (every pin with type, default and description). `setup` makes both from your
  own installation. A block choice may rest on what the vendor text says or on what was proven in the tool
  (`findings.md`), never on what a name suggests.
- Where the text is silent, the program must not depend on that behaviour, or must be right either way. List
  such points in the program's description.
- A custom block (Pawn or C) is justified only when the documented behaviour of the library blocks
  does not fit; cite the vendor sentence that rules each candidate out. Whether custom blocks build
  and run on a real controller is untested.
- Unused inputs of extendable blocks (And, Or, Add, Min, Max …) are left untouched; they are
  excluded from the calculation. A typed constant or a set value makes the pin Active, i.e.
  connected. A non-extendable input left empty fails the tool's check.
- Arithmetic with a constant: prefer a block whose constant sits on a normal parameter pin
  (e.g. `Compensator`) over a constant on an extendable input.

## Values: constant, set value or measurement

Decide by who writes the value:

| Who writes | Construct |
|---|---|
| nobody after commissioning | anonymous constant on the pin (no name, no register) |
| operator / HMI over the bus | named set value on the pin, with unit, min, max, default |
| bus and program | named set value plus the vendor's local/remote pattern (`SetPointSync` / `StateSync`); use only where truly needed. Pattern not yet proven in the tool |
| program only, HMI reads | no set value; a measurement on the block output |

- Set values are written over the bus and mapped straight onto block pins (limits, curve points,
  PID parameters). The controller enforces a set value's min/max on bus writes, so no clamp block
  and no write-back. What an out-of-range write does (reject, clamp, ignore) is not known; the HMI
  validates before writing and shows the read-back value.
- A pin is a sink. A value needed by several blocks comes from a block output that fans out, or
  from one set value referenced by several pins (proven). As a pass-through use `Override` (analog,
  enable untouched) or `SwitchBin` (binary, select untouched); never `Absolute`, which flips
  negative values.
- Consistency between set values (START above STOP …) stays in logic: the program uses a safe
  effective value and raises a status bit; it does not write registers.

## Pipeline for a whole program

Functional description → generator with `pipeline/oufplan.py` → `plan.json` → `pipeline/check_plan.py` →
`scripts/build.sh <program dir>`, which runs the generated scripts in the tool and lets
`pipeline/verify_ouflex_build.py` compare the built project with the plan. See `new-program.md` and the worked
example `examples/dh-ex2`.

Plan and BA Tool project are one diagram by construction, so the verification proves that the tool holds what
the plan says, not that the plan is right. The plan is checked by reading it against the description of
operation, and tests on a real controller settle what the documentation does not.

## Working habits that paid off

- One driver on the desktop at a time: two agents type into each other's windows.
- Learn a construct once through the real GUI, then reproduce it in code and compare field by field.
- Prove by save → restart on the saved file → inspect → the tool's own check. In-session state after
  scripted edits is not what a reload rebuilds.
- Work in copies under `C:\agentwork`; the user's project is installed last, after review.
- When extracting vendor documentation, also read the RTF bodies and do not strip text between
  `<` and `>`; the first extraction lost 24 documents and the `Limit` / `Thermostat` conditions.
