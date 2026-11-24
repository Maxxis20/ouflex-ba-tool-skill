# dh2 — District heating substation, two heating circuits

Description of operation. Controller: one Ouman Ouflex A base unit, no expansion module.
Generated plan: `plan.json` from `make_plan.py` (do not edit the JSON by hand).

## 1. Purpose

The substation heats a building from district heating through two heat exchanger circuits:

- **C1** radiator circuit
- **C2** floor heating circuit

There is no domestic hot water. For each circuit the controller calculates a supply water setpoint
from the filtered outdoor temperature (heating curve), controls a 0–10 V valve actuator with a PID
controller, runs the circulation pump, lowers the setpoint at night by a time program (night
setback), stops the circuit in summer, exercises the pump during summer stop and raises alarms. The primary supply and return temperatures are measured only.

The program has four applications. They run in this order:

| Order | Application | Content |
|---|---|---|
| 1 | `COMMON` | outdoor sensor range check, fallback value, slow filter |
| 2 | `C1` | heating circuit 1, radiators |
| 3 | `C2` | heating circuit 2, floor heating (built by the same generator function as C1, with other defaults) |
| 4 | `ALARM` | common alarm relay |

Every signal passed between applications is read by a later application. It is therefore from the
same cycle, and there is no feedback between applications.

## 2. I/O list

| Point | Signal | Type | Range / meaning |
|---|---|---|---|
| UI 1 | `TOUT_IN` outdoor temperature | NTC10, AI | °C; plausible range −45…+50 °C |
| UI 2 | `TP_SUP_IN` DH primary supply temperature | NTC10, AI | °C; measurement only |
| UI 3 | `TP_RET_IN` DH primary return temperature | NTC10, AI | °C; measurement only |
| UI 4 | `C1_TS_IN` C1 supply temperature | NTC10, AI | °C; plausible range −20…+120 °C |
| UI 5 | `C2_TS_IN` C2 supply temperature | NTC10, AI | °C; plausible range −20…+120 °C |
| AO 1 | `C1_VLV_OUT` C1 control valve | 0–10 V, AO | 0…100 % (0 % = closed). The AO point is configured TX_OUT, 0…100 % (the Ouflex A default, set explicitly by the build); that 0…100 % gives 0…10 V is the point's scaling, not tested on a controller |
| AO 2 | `C2_VLV_OUT` C2 control valve | 0–10 V, AO | as AO 1 |
| R1 | `C1_PUMP_OUT` C1 circulation pump | relay, DO | 1 = run |
| R2 | `C2_PUMP_OUT` C2 circulation pump | relay, DO | 1 = run |
| R3 | `ALARM_OUT` common alarm | relay, DO | 1 = alarm (energised on alarm) |

## 3. Control functions

### 3.1 Outdoor temperature (COMMON)

- **Range check.** The raw value is a fault when it is below −45 °C or above +50 °C. These are
  constants.
- **Fallback.** During a fault, the set value `TOUT_FALLBACK` replaces the raw value at once.
- **Filter.** The value (raw or substitute) goes through a first-order low-pass filter with the time
  constant `TOUT_FILT_T`. The result `TOUT_F` drives both circuits.
- **Fault status.** `TOUT_FAULT` is set when the fault has lasted 10 s, and clears as soon as the
  reading is plausible again.

### 3.2 Supply setpoint (per circuit)

1. A three-point heating curve (`Curve_3p`) gives the supply temperature from `TOUT_F`. The set
   values `Cn_CRV_N20`, `Cn_CRV_0` and `Cn_CRV_P20` are the supply temperatures at −20, 0 and
   +20 °C outdoor. The block corrects the 0 °C point automatically so that it stays between 2 °C
   below and 7 °C above the straight line through the end points.
2. The offset `Cn_SP_OFFSET` is added to the uncut curve value (`CurveOut`). This is a parallel
   shift.
3. During night setback the set value `Cn_SETBACK` is subtracted (section 3.8).
4. Then the minimum limit `Cn_TS_MIN` is applied (`Max` block), and the maximum limit `Cn_TS_MAX`
   last (`Min` block).

   **Order chosen:** the offset and the setback are applied before the limits, so the effective
   setpoint never leaves `TS_MIN…TS_MAX`; a large setback stops at `TS_MIN`. If `TS_MIN > TS_MAX` is entered, the maximum wins. This matters for floor
   heating, and status bit `Cn_SV_ERR` is raised. `Curve_3p`'s own Min/Max pins carry the same set
   values, but its cut `Output` is not used.

The effective setpoint is `Cn_SP`.

### 3.3 Summer stop and circuit run

- **Stop condition.** The circuit stops when `TOUT_F > Cn_SUM_STOP` has lasted `Cn_SUM_DLY`
  seconds. A dip below the limit restarts the delay.
- **Restart.** Heating resumes at once when `TOUT_F < Cn_SUM_START`.
- **Latch.** Between the two limits the state is held by a reset-dominant RS latch; this is the
  hysteresis.
- **Overlapping limits.** If `SUM_START >= SUM_STOP` is entered, heating wins and `Cn_SV_ERR` is
  raised.

The circuit runs (`run`) when `Cn_ENABLE = 1` and the summer stop is not active.

### 3.4 Circulation pump and pump exercise

- The pump relay is on whenever the circuit runs.
- During summer stop (and only while `Cn_ENABLE = 1`), the pump is also run for `Cn_EXER_ON`
  seconds every `Cn_EXER_OFF` seconds. The cycle starts with the off period, so entering summer
  stop does not kick the pump.
- During an exercise pulse the valve stays closed (PID disabled). Valve exercise is left out
  (section 9).

### 3.5 Valve control

- **PID enable.** A PID controller (`Pid` 5.1, heating direction `Reverse = 1`) controls the supply
  temperature to `Cn_SP`. It is enabled when the circuit runs and the supply sensor is plausible.
- **When disabled.** With the PID disabled (pump stopped, summer, circuit disabled, sensor fault)
  its output is 0 %, so the valve closes.
- **Supply sensor fault.** While the circuit runs and the supply sensor is faulty, the valve goes to
  the fixed position `Cn_VLV_FAULT`. Defaults: 20 % for radiators, 0 % for floor heating.
- **Tuning.** The proportional band `Cn_PID_P` (°C) and integral time `Cn_PID_I` (s) are set
  values. The other PID parameters are constants: dead band 0.5 °C, D = 0, control interval 1 s,
  output 0…100 %, start point (Balance) 0 %, no Hold. `Feedback` is not connected, and the U32
  stage pins are untouched. `RevPDisable` is left at the library default (30 °C).

### 3.6 Supply deviation alarm

`Cn_DEV_ALM` is set when |supply − setpoint| > `Cn_DEV_LIM` has lasted `Cn_DEV_DLY` seconds while
the PID is enabled. It clears at once when the deviation is gone or the PID is disabled. Each start
of the circuit restarts the delay, which also covers the warm-up.

### 3.7 Common alarm (ALARM)

`ALARM_SUM` = OR of `TOUT_FAULT`, `C1_TS_FAULT`, `C1_DEV_ALM`, `C2_TS_FAULT` and `C2_DEV_ALM`. It
drives relay R3. Alarms do not latch, and there is no acknowledgement. `Cn_SV_ERR` is a status
point, not an alarm.

### 3.8 Time program and night setback (per circuit)

- **Time program `Cn_TPRG`.** An On/Off weekly time program (the tool's time program object, not a block),
  states **0 = Setback**, **1 = Comfort**. It sits on the `Select` input of the setback switch `nsb`.
- **Default week:** every day `06:00` Comfort and `22:00` Setback, so comfort runs 06:00–22:00. A state holds
  until the next entry, also over midnight, so the 22:00 setback lasts until 06:00 the next morning (checked in
  the simulator). The program's default value is 1 (Comfort).
- **Setback.** While the program is 0, `Cn_SETBACK` °C is subtracted from the curve value (after the offset,
  before the limits). While it is 1, nothing is subtracted. Defaults: 10 °C for the radiators, 3 °C for the
  floor heating, which reacts slowly and is not lowered much.
- **What setback does not touch.** Summer stop, the pump, the PID and the alarms work the same in both
  states. The deviation alarm sees the lowered setpoint, so a step to setback with a slow-cooling circuit
  can raise it if `Cn_DEV_DLY` is short; the default 1800 s covers it.
- **Where it is set.** In the display menu row "Time program" of each circuit, and on the Web UI page (the
  clock symbol next to the circuit's settings).

## 4. Set values

All set values are writable over the bus. The controller enforces min/max on bus writes; what it
does with an out-of-range write is not known, so the HMI validates before it writes.

| Name | Unit | Default C1 / C2 | Min | Max | Dec. | Meaning |
|---|---|---|---|---|---|---|
| `TOUT_FALLBACK` | °C | 0.0 | −30 | 20 | 1 | Outdoor value used while the outdoor sensor is faulty |
| `TOUT_FILT_T` | s | 900 | 10 | 21600 | 0 | Outdoor filter time constant |
| `Cn_SUM_STOP` | °C | 18.0 / 17.0 | 5 | 30 | 1 | Summer stop when filtered outdoor is above |
| `Cn_SUM_DLY` | s | 3600 | 0 | 86400 | 0 | Delay before summer stop |
| `Cn_SUM_START` | °C | 16.0 / 15.0 | 0 | 30 | 1 | Heating resumes when filtered outdoor is below |
| `Cn_CRV_N20` | °C | 58.0 / 35.0 | 10 | 95 | 1 | Curve: supply at −20 °C outdoor |
| `Cn_CRV_0` | °C | 41.0 / 28.0 | 10 | 95 | 1 | Curve: supply at 0 °C outdoor |
| `Cn_CRV_P20` | °C | 20.0 / 22.0 | 10 | 95 | 1 | Curve: supply at +20 °C outdoor |
| `Cn_TS_MIN` | °C | 18.0 / 20.0 | 10 | 50 | 1 | Minimum supply setpoint |
| `Cn_TS_MAX` | °C | 70.0 / 40.0 | 20 | 90 / 55 | 1 | Maximum supply setpoint |
| `Cn_SP_OFFSET` | °C | 0.0 | −10 | 10 | 1 | Parallel shift of the curve |
| `Cn_SETBACK` | °C | 10.0 / 3.0 | 0 | 30 | 1 | Supply setpoint drop during night setback (time program 0) |
| `Cn_ENABLE` | – | 1 | 0 | 1 | – | Circuit enabled (0 = pump off, valve closed, no exercise) |
| `Cn_EXER_ON` | s | 120 | 10 | 1800 | 0 | Pump exercise run time |
| `Cn_EXER_OFF` | s | 604800 (7 d) | 3600 | 2592000 | 0 | Pump exercise interval (off time) |
| `Cn_PID_P` | °C | 40.0 / 30.0 | 2 | 500 | 1 | PID proportional band (P-area) |
| `Cn_PID_I` | s | 60 / 90 | 5 | 300 | 0 | PID integral time |
| `Cn_VLV_FAULT` | % | 20 / 0 | 0 | 100 | 0 | Valve position during a supply sensor fault |
| `Cn_DEV_LIM` | °C | 10.0 / 5.0 | 1 | 30 | 1 | Deviation alarm limit |
| `Cn_DEV_DLY` | s | 1800 | 60 | 14400 | 0 | Deviation alarm delay |

`Cn` stands for `C1` and `C2`. That gives 2 + 2 × 18 = 38 set values.

**Time programs:**

| Name | Type | States | Default value | Default week (every day) |
|---|---|---|---|---|
| `Cn_TPRG` | On/Off | 0 = Setback, 1 = Comfort | 1 | 06:00 Comfort, 22:00 Setback |

**Fixed constants:**

| Constant | Value |
|---|---|
| Outdoor sensor plausible range | −45…+50 °C |
| Supply sensor plausible range | −20…+120 °C |
| Sensor fault report delay | 10 s |
| PID dead band | 0.5 °C |
| PID D | 0 |
| PID control interval (CtrlSpace) | 1 s |
| PID output limits | 0 / 100 % |
| PID Balance | 0 % |

## 5. Measurements and status points

| Name | Type | Unit | Meaning |
|---|---|---|---|
| `TOUT` | analog | °C | Outdoor temperature, raw |
| `TOUT_F` | analog | °C | Outdoor temperature, filtered (after fallback) |
| `TP_SUP`, `TP_RET` | analog | °C | DH primary supply / return temperature |
| `Cn_TS` | analog | °C | Circuit supply temperature |
| `Cn_SP` | analog | °C | Effective supply setpoint |
| `Cn_VALVE` | analog | % | Valve command |
| `Cn_PUMP` | status | – | Pump command (run or exercise) |
| `Cn_SUMMER` | status | – | Summer stop active |
| `Cn_SV_ERR` | status | – | Set value conflict (TS_MIN > TS_MAX or SUM_START ≥ SUM_STOP) |
| `TOUT_FAULT`, `Cn_TS_FAULT`, `Cn_DEV_ALM`, `ALARM_SUM` | status | – | Alarms (section 6) |

## 6. Alarms (status points)

Alarm objects (`AnalogAlarm`, `DeviationAlarm`, `BinaryAlarm`) are not supported by the build yet,
so each alarm is a binary status measurement. All of them feed the common alarm relay. None of them
latches.

| Status | Condition | Delay |
|---|---|---|
| `TOUT_FAULT` | outdoor reading < −45 °C or > +50 °C | 10 s |
| `C1_TS_FAULT`, `C2_TS_FAULT` | supply reading < −20 °C or > +120 °C | 10 s |
| `C1_DEV_ALM`, `C2_DEV_ALM` | \|supply − setpoint\| > `Cn_DEV_LIM` while the PID is enabled | `Cn_DEV_DLY` |
| `ALARM_SUM` → R3 | any of the above | – |

## 7. Sensor fault handling

- **Outdoor sensor.**
  - On an implausible reading, `TOUT_FALLBACK` is used at once instead of the raw value; it is
    still filtered, so the curve moves smoothly.
  - Both circuits keep heating on the fallback value. With the default of 0 °C, summer stop does
    not engage.
  - `TOUT_FAULT` follows after 10 s.
- **Supply sensor (per circuit).**
  - On an implausible reading the PID is disabled at once; it restarts from Balance when the
    sensor recovers.
  - While the circuit runs, the valve goes to `Cn_VLV_FAULT`. The pump keeps running.
  - The deviation alarm is suppressed, and `Cn_TS_FAULT` follows after 10 s.
- **Primary temperatures.** These are measurements only and are not checked.

A range check on the NTC value is used, not `SensorWatchAn`. `SensorWatchAn`'s flags are documented
for a physical input. In this build the point reaches the application through an interface pin, and
whether the flags work there is not stated.

## 8. Modbus map rule

- **Register types.** Every point is a Holding register; the tool hard-codes "Holding". Registers 2–7
  (date/time) and 14 (acknowledge all alarms) are system registers and are not used.
- **Numbering.** Each table maps to a register block, with n = the point's offset in its table:

  | Table | Registers | Range in this program |
  |---|---|---|
  | Set values | 1000 + n | 1000…1037 |
  | Analog measurements | 1100 + n | 1100…1109 |
  | Binary status | 1150 + n | 1150…1161 |

- **Exported document.** It shows each number +1; for example `TOUT_FALLBACK`, register 1000,
  appears as 1001.

| Reg. | Set value |
|---|---|
| 1000–1001 | `TOUT_FALLBACK`, `TOUT_FILT_T` |
| 1002–1019 | C1 set values, in the order `SUM_STOP`, `SUM_DLY`, `SUM_START`, `CRV_N20`, `CRV_0`, `CRV_P20`, `TS_MIN`, `TS_MAX`, `SP_OFFSET`, `SETBACK`, `ENABLE`, `EXER_ON`, `EXER_OFF`, `PID_P`, `PID_I`, `VLV_FAULT`, `DEV_LIM`, `DEV_DLY` |
| 1020–1037 | C2 set values, same order |

| Reg. | Analog measurement |
|---|---|
| 1100 | `TOUT_F` |
| 1101 | `C1_SP` |
| 1102 | `C1_VALVE` |
| 1103 | `C2_SP` |
| 1104 | `C2_VALVE` |
| 1105 | `TOUT` |
| 1106 | `TP_SUP` |
| 1107 | `TP_RET` |
| 1108 | `C1_TS` |
| 1109 | `C2_TS` |

| Reg. | Status |
|---|---|
| 1150 | `TOUT_FAULT` |
| 1151 | `C1_TS_FAULT` |
| 1152 | `C1_SUMMER` |
| 1153 | `C1_SV_ERR` |
| 1154 | `C1_PUMP` |
| 1155 | `C1_DEV_ALM` |
| 1156–1160 | same for C2 |
| 1161 | `ALARM_SUM` |

**Time programs.** The tool gives every time program its own Holding register block; the plan does not set
these. As exported (document numbering, i.e. +1 like the rest):

| Doc. reg. C1 / C2 | `Cn_TPRG` | R/W |
|---|---|---|
| 10001 / 10363 | current value (0 = Setback, 1 = Comfort) | R |
| 10002 / 10364 | manual control (−1 = Automatic, 0 = Setback, 1 = Comfort) | RW |
| 10003 / 10365 | weekly program (120 registers) | RW |
| 10123 / 10485 | exception calendar (120 registers) | RW |
| 10243 / 10605 | special days (120 registers) | RW |

The register layout inside the 120-register blocks is not decoded here. By its description the manual-control register can be used
to force a state (not tested).

## 9. Deliberately left out

- Domestic hot water.
- **Valve exercise.** Opening the DH valve with the pump running in summer sends primary-temperature
  water into the circuit, which is unsafe for floor heating. There is no `MotorExercise` block, so
  only the pump is exercised.
- Room temperature compensation (no room sensor); a fixed offset set value is used instead.
- Alarm objects, alarm acknowledgement, alarm routing and latching alarms.
- Pump fault / run feedback input.
- **Floor heating over-temperature safety thermostat.** It must be hard-wired, not done in software.
- Return temperature limitation and primary energy metering.
- Separate frost protection. The summer stop releases as soon as the outdoor temperature is below
  `SUM_START`.
- Local/remote set value patterns (`SetPointSync`/`StateSync`), run-time counters (`RunTimeCounter`)
  and manual overrides (`Override`). These blocks arrive with vendor objects that the build drops.

## 10. Block choices

Each entry quotes the vendor sentence that justifies the block (blocks.json `behaviour[].evidence`
or `doc_en`).

**Heating curve: `Curve_3p`**
- **Rule.** "In 3-point curve the curve is defined at 3 points: when outdoor temperature is -20 °C,
  0 °C and +20 °C. Additionally it is possible to cut the top and bottom of curve with minimum and
  maximum limits. There is also automatic adjustment of the curve convexity."
- **Rejected alternatives:**
  - `Curve_5p` documents no convexity guard and needs five more set values.
  - `Linearization` "is extrapolated using the y-slope", so it has no cut. Its unused points must be
    "left undefined" (unconnected), and whether a constant counts as defined is not stated.
  - `Compensator` is a straight line, "Output =( (Out2-Out1)*(Input-In1)/(In2-In1) ) + Out1", with
    no limits.

**Limits: `Max` then `Min`, not `Limit`**
- **Rule.** `Max`: "Output = Input which has the maximum value"; `Min`: "Output = Minimum input
  value"; for both, "If some input is not connected, it is excluded".
- **Why not `Limit`.** Its below-Min sentence is lost in the extracted text (ouman-answers Limit-1,
  confidence none), so the design must not depend on it.

**Set value pass-through: `SwitchAn` with Select = 0**
- **Rule.** "If Select = 0, Output = Input0."
- **Why.** A set value is needed as a block output for `Add`/`Max`/`Min`. A set value on an
  extendable input would make it Active and is avoided (design-rules). `Override` arrives with a
  vendor measurement, so it is avoided too.

**Valve PID: `Pid` 5.1 (file `Pid_v5`)**
- **Rule.** "If Enable input is 0, PID regulator is inactive and output is 0%." and "Reverse input
  defines control direction. 0 = Cooling, 1 = Heating." The fi pin text adds "Mittauksen noustessa
  lähtö laskee." (as the measurement rises, the output falls).
- **Units.** P is "P-area" in °C (2..500); I is "I time in seconds" (5..300, "Huom. ei saa asettaa
  nollaksi" — must not be set to zero).
- **Why version 5.1.** It is the current one; versions 1.5, 2.18, 3.1 and 4.2 are superseded and
  differ only in the stage/RevPDisable pins.
- **Why not the alternatives:**
  - `MotorDriverV` "drives voltage controlled actuator … based on the changes in Input and the set
    drive times". It emulates run time for an actuator whose voltage means speed. A position-type
    0–10 V actuator takes the PID output directly.
  - `MotorDriver3p` is for 3-point actuators ("Component can be used for 3-state motor control").
  - `HW_Pid` has undocumented pins (BoostPower, Anticip*), confidence low.

**Summer hysteresis: comparators + `RS_FlipFlop`, not `Thermostat`**
- **Rule.** RS: "If both set -input (S) and reset -input (R) are '1', Output is '0'" and "If both
  … are '0', Output remain it's state". Comparators: "if A > B, Output = '1'" / "if A < B, Output =
  '1'".
- **Why not `Thermostat`.** Its switching edges are lost in the damaged text (confidence low).
- **Why reset-dominant.** Overlapping limits then give heating.

**Delays: `OnDelay` with Enable = 1 set explicitly**
- **Rule.** "the input change from state '0' to '1' is seen after a delay which is dependent on the
  DelayTime parameter value"; "If Enable = '0'. Output follows the input state as such."

**Gating: `SwitchBin` as AND with a set value**
- **Rule.** "If Select = 0, Output = Input0." A set value on `Select` avoids a set value on an
  extendable `And` input.

**Pump exercise: `OnOffPulse`**
- **Rule.** "If Enable = '0', Output = '0'" and "Output is '1' for OnTime (in seconds) and '0' for
  OffTime (in seconds)"; "if StartState = '0', pulsing is started by OffPulse".

**Night setback: time program on `SwitchAn.Select`, then `Subtract`**
- **Rule.** `SwitchAn`: "If Select = 0, Output = Input0. If Select = 1, Output = Input1"; `Subtract`:
  "Output = A - B1 - …".
- **Why a block pin.** A time program is not a block; it is an object attached to an Enum **block** input
  (the pin's clock symbol). On an application interface pin the tool drops it again before saving
  (findings, "Time programs"). `Select` is such an input, and the switch turns the program's 0/1 into the
  setback amount or 0 in one block.
- **Why not `TimeProgPredictBin`/`TimeProgPredictAn`.** They pre-heat ahead of a program change; that is not
  needed for a supply setpoint.

**Deviation: `Subtract` + `Absolute`**
- **Rule.** "Output = A - B1 - …" and "If Input < 0, Output = -1 * Input". `Absolute` is used as a
  real absolute value, not as a pass-through.

**Outdoor filter: `SignalFilter`**
- **Rule.** "This component implement s first-order low-pass filtering"; TimeConstant "Suodatuksen
  aikavakio sekunteina" (filter time constant in seconds).

## 11. Behaviour resting on documentation only or not stated

None of this has been tested on a real controller. For each point the design is either right
either way or the risk is named.

**NTC reading on an open or short circuit**
- **Not stated.** Whether the Ouflex A input delivers an out-of-range value, clamps or holds it.
- **Risk.** If it clamps inside −45…+50 °C (outdoor) or −20…+120 °C (supply), the range check
  never fires.

**`Curve_3p`**
- **Not stated:**
  - Interpolation between points (linear assumed).
  - Behaviour outside −20…+20 °C. Either way the result is bounded by TS_MIN/TS_MAX.
  - "Whether the convexity correction moves CurveOut only or also the Out_0 parameter." The design
    uses `CurveOut`.
  - The meaning of MinLimitEffect/MaxLimitEffect (not used).
- **Open questions:**
  - "Output at outdoor -30 °C and +25 °C: extrapolated or held?"
  - "Set Out_0 15 °C above the straight line: what CurveOut appears at 0 °C?"

**`Pid` 5.1**
- **Not stated:**
  - Algorithm form and the P-area to gain conversion (so the default tuning is only a starting
    point).
  - Output inside the dead band.
  - First scan and retention.
  - The exact RevPDisable rule: the 4.2 and 5.1 texts contradict each other, so the pin is left at
    its library default.
  - The encoding of the U32 stage values (pins untouched; CheckAll decides).
- **Open questions:** "Step response (P only, then PI) to establish the gain conversion", "Output
  inside the deadband", "Output after power cycle".
- **Inferred:** that an untouched `Feedback` pin counts as "not connected" (platform P1, medium).

**`SignalFilter`**
- **Not stated:** first-scan value, `Enable = 0` behaviour, discretisation, TimeConstant = 0
  (answers SignalFilter-1…4, confidence none).
- **Effect if it starts at 0.** After power-up `TOUT_F` rises from 0 °C. The curve then over-heats
  briefly in summer or under-heats in winter until the filter settles. Min/Max still hold.

**`OnDelay`**
- **Inferred (medium, OnDelay-1):** that a one-cycle dropout restarts the delay.
- **Not determined (OnDelay-4, none):** delays of 86400 s (`SUM_DLY` max) and 14400 s.
- **Not stated:** whether DelayTime changed during a running delay is used.

**`OnOffPulse`**
- **Not stated:**
  - Timing resolution and drift, and whether OffTime = 604800 s (up to 2592000 s) works.
  - A live change of OnTime/OffTime.
  - Whether the cycle restarts after a power cycle (retention P4, low). If it does, frequent
    restarts postpone the exercise.

**`RS_FlipFlop`**
- **Not stated:** first scan and retention.
- **Effect if it starts at 0.** After power-up the circuit heats until the summer stop delay runs
  out again. That is the safe direction.

**`And` / `Or`**
- **Vendor:** "Unconnected inputs are excluded from operation".
- **Inferred (P1, medium):** that untouched extendable inputs are Inactive.

**`SwitchAn`**
- The en-GB pin text "(0 = Input1, 1 = Input2)" is a naming slip. The fi pin text and the legacy
  doc ("If Select = 0, Output = Input0") decide.

**Time program**
- **Checked in the simulator:** before a day's first entry the state of the previous entry holds (a Monday 20:00
  setback was still 0 on Tuesday 21:05, before Tuesday's only entry at 22:30; the default 1 was not used).
- **Not stated:** when the default value applies (a program without entries is the likely case, not tested).
  Daylight saving time and a clock that was never set (it is a real-time clock program).
- **Simulator:** the virtual Ouflex C evaluates the program from the Windows machine's local clock and weekday when the
  program starts (Load or Reset), not while it runs, and a written value is not taken. The scenarios test the
  setback logic with two copies of C1 whose weeks are all Comfort or all Setback.
- **Real controller:** switching at the programmed times is not tested on a controller.

**Set values**
- Behaviour on an out-of-range bus write is not known.

**AO scaling**
- AO points are TX_OUT 0…100 % (tool default, set explicitly); 0…100 % = 0…10 V on the terminal is not tested on a controller.

**Physical point used directly**
- `io("UI n")` on pins in several blocks of one application is assumed to be one interface pin
  fanned out. That is the build helpers' job.

## Build and verification

Built by script with `scripts/build.sh examples/dh2` (see `README.md`). Evidence in `build/out/`: per application
`<APP>.verify.txt` (read back after save and restart of the builder), `device.verify.txt` (after save and reopen of the
project, incl. the tool's check and capacity), `modbus.verify.txt` (exported Modbus document parsed, plan vs built),
`file.verify.txt` (saved Device.bin read with the vendor DLLs, tool not running), the Modbus document.
Build-time name changes: interface pins of nets that share a name with a measurement get `_N`; a block named like a
library type (`pid`) is renamed `pid_b` (the tool reserves type names). The behaviour of the blocks rests on the vendor
documentation listed above until tests on a real controller.
