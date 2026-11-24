#!/usr/bin/env python3
"""dh2: district heating substation, two heating circuits (C1 radiators, C2 floor heating), no DHW.

Writes plan.json next to this file. Both circuit applications come from one function, circuit(),
called twice with different defaults. Applications run COMMON -> C1 -> C2 -> ALARM.

    python make_plan.py
    python ../../pipeline/check_plan.py .

Description of operation: DESCRIPTION.md (same directory).
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.normpath(os.path.join(HERE, "..", "..", "pipeline")))

from oufplan import Plan, wire, const, setv, tprg, week, net, io, measure  # noqa: E402

P = Plan("dh2", title="District heating substation, two heating circuits, no domestic hot water")

# ---------------------------------------------------------------------------------------------- I/O
P.io("UI 1", "TOUT_IN", "in", "NTC", "Outdoor temperature")
P.io("UI 2", "TP_SUP_IN", "in", "NTC", "District heating primary supply temperature")
P.io("UI 3", "TP_RET_IN", "in", "NTC", "District heating primary return temperature")
P.io("UI 4", "C1_TS_IN", "in", "NTC", "Circuit 1 supply temperature")
P.io("UI 5", "C2_TS_IN", "in", "NTC", "Circuit 2 supply temperature")
P.io("AO 1", "C1_VLV_OUT", "out", "AO 0-10V", "Circuit 1 control valve 0..100 %",
     scale="0..100 % -> 0..10 V assumed; build owner confirms AO scaling")
P.io("AO 2", "C2_VLV_OUT", "out", "AO 0-10V", "Circuit 2 control valve 0..100 %",
     scale="0..100 % -> 0..10 V assumed; build owner confirms AO scaling")
P.io("R1", "C1_PUMP_OUT", "out", "relay", "Circuit 1 circulation pump start")
P.io("R2", "C2_PUMP_OUT", "out", "relay", "Circuit 2 circulation pump start")
P.io("R3", "ALARM_OUT", "out", "relay", "Common alarm relay (energised = alarm)")

P.measure_io("TOUT", "UI 1", "°C", 1, "Outdoor temperature, raw")
P.measure_io("TP_SUP", "UI 2", "°C", 1, "DH primary supply temperature")
P.measure_io("TP_RET", "UI 3", "°C", 1, "DH primary return temperature")

# Sensor plausibility limits: constants (nobody changes them after commissioning).
TOUT_LO, TOUT_HI = -45.0, 50.0
TS_LO, TS_HI = -20.0, 120.0
SENSOR_FAULT_DELAY = 10.0       # s, before a sensor fault is reported (substitution acts at once)
COMFORT_DAY = "06:00=1,22:00=0"   # time program default: comfort 06:00-22:00 every day; 22:00 setback holds over midnight until 06:00

# ------------------------------------------------------------------------------------------- COMMON
a = P.app("COMMON", "Outdoor temperature: range check, fallback value, slow filter; shared by both circuits")
a.block("tlo", "LessThan", col=0, label="Outdoor sensor check",
        pins={"A": io("UI 1"), "B": const(TOUT_LO)},
        why="vendor: LessThan 'if A < B, Output = 1' - reading below the plausible range = sensor fault")
a.block("thi", "GreaterThan", col=0,
        pins={"A": io("UI 1"), "B": const(TOUT_HI)},
        why="vendor: GreaterThan 'if A > B, Output = 1' - reading above the plausible range = sensor fault")
a.block("tbad", "Or", col=1, label="Outdoor fault",
        pins={"Input1": wire("tlo.Output"), "Input2": wire("thi.Output")},
        why="vendor: Or 'If some input is 1, output is 1'; unused inputs untouched (excluded)")
a.block("tsub", "SwitchAn", col=1, label="Fallback value",
        pins={"Select": wire("tbad.Output"), "Input0": io("UI 1"),
              "Input1": setv("TOUT_FALLBACK", 0.0, -30.0, 20.0, "°C", "Outdoor fallback temperature", 1,
                             why="used while the outdoor sensor is faulty; site dependent")},
        why="vendor: SwitchAn 'If Select = 0, Output = Input0. If Select = 1, Output = Input1' - substitute value on fault")
a.block("tflt", "SignalFilter", col=2, label="Outdoor filter",
        pins={"Enable": const(1), "Input": wire("tsub.Output"),
              "TimeConstant": setv("TOUT_FILT_T", 900.0, 10.0, 21600.0, "s", "Outdoor filter time constant", 0,
                                   why="building inertia; tuned at commissioning")},
        why="vendor: SignalFilter 'first-order low-pass'; TimeConstant 'sekunteina' (seconds). Enable set 1 explicitly (Enable=0 not stated)") \
    .out("Output", measure("TOUT_F", "°C", 1, "Outdoor temperature, filtered"), net("TOUT_F"))
a.block("tfd", "OnDelay", col=2, label="Outdoor fault status",
        pins={"Enable": const(1), "Input": wire("tbad.Output"), "DelayTime": const(SENSOR_FAULT_DELAY)},
        why="vendor: OnDelay '0 to 1 is seen after a delay', '1 to 0 reflected immediately'; Enable=1 explicitly since Enable=0 passes through") \
    .out("Output", measure("TOUT_FAULT", "", None, "Outdoor sensor fault"), net("TOUT_FAULT"))


# ------------------------------------------------------------------------------------------ circuits
def circuit(n, title, d, ts_point, vlv_point, pump_point):
    """One heating circuit application. n = 'C1' / 'C2'; d = defaults dict."""
    c = P.app(n, title)
    p = n + "_"
    tsio = io(ts_point)
    P.measure_io(p + "TS", ts_point, "°C", 1, f"Circuit {n[1]} supply temperature")

    # --- column 0: inputs and comparisons -------------------------------------------------------
    c.block("tslo", "LessThan", col=0, label="Supply sensor check",
            pins={"A": tsio, "B": const(TS_LO)},
            why="vendor: LessThan 'if A < B, Output = 1' - below plausible range = open circuit / fault")
    c.block("tshi", "GreaterThan", col=0,
            pins={"A": tsio, "B": const(TS_HI)},
            why="vendor: GreaterThan 'if A > B, Output = 1' - above plausible range = short circuit / fault")
    c.block("tsbad", "Or", col=0,
            pins={"Input1": wire("tslo.Output"), "Input2": wire("tshi.Output")},
            why="vendor: Or 'If some input is 1, output is 1'")
    c.block("tsfd", "OnDelay", col=0,
            pins={"Enable": const(1), "Input": wire("tsbad.Output"), "DelayTime": const(SENSOR_FAULT_DELAY)},
            why="vendor: OnDelay 0->1 delayed by DelayTime (s), 1->0 immediate; Enable=1 explicitly") \
        .out("Output", measure(p + "TS_FAULT", "", None, f"Circuit {n[1]} supply sensor fault"), net(p + "TS_FAULT"))

    c.block("sstop", "GreaterThan", col=0, label="Summer stop",
            pins={"A": net("TOUT_F"),
                  "B": setv(p + "SUM_STOP", d["sum_stop"], 5.0, 30.0, "°C", f"Circuit {n[1]} summer stop above", 1,
                            why="seasonal; operator adjusts")},
            why="vendor: GreaterThan 'if A > B, Output = 1' - outdoor above stop limit")
    c.block("sdly", "OnDelay", col=0,
            pins={"Enable": const(1), "Input": wire("sstop.Output"),
                  "DelayTime": setv(p + "SUM_DLY", 3600.0, 0.0, 86400.0, "s", f"Circuit {n[1]} summer stop delay", 0,
                                    why="operator adjusts")},
            why="vendor: OnDelay 0->1 after DelayTime s, a dip below the limit restarts the delay (ouman-answers OnDelay-1, medium)")
    c.block("sstart", "LessThan", col=0,
            pins={"A": net("TOUT_F"),
                  "B": setv(p + "SUM_START", d["sum_start"], 0.0, 30.0, "°C", f"Circuit {n[1]} heating resumes below", 1,
                            why="seasonal; operator adjusts; must be below the stop limit (checked)")},
            why="vendor: LessThan 'if A < B, Output = 1' - outdoor below restart limit")

    # --- column 1: curve and setpoint -----------------------------------------------------------
    tmin = setv(p + "TS_MIN", d["ts_min"], 10.0, 50.0, "°C", f"Circuit {n[1]} minimum supply temperature", 1,
                why="commissioning / operator")
    tmax = setv(p + "TS_MAX", d["ts_max"], 20.0, d["ts_max_hi"], "°C", f"Circuit {n[1]} maximum supply temperature", 1,
                why="commissioning; protects the heat emitters")
    c.block("curve", "Curve_3p", col=1, label="Heating curve",
            pins={"Input": net("TOUT_F"),
                  "Out_n20": setv(p + "CRV_N20", d["n20"], 10.0, 95.0, "°C", f"Circuit {n[1]} curve at -20 °C outdoor", 1,
                                  why="operator adjusts the heating curve"),
                  "Out_0": setv(p + "CRV_0", d["z0"], 10.0, 95.0, "°C", f"Circuit {n[1]} curve at 0 °C outdoor", 1,
                                why="operator adjusts the heating curve"),
                  "Out_p20": setv(p + "CRV_P20", d["p20"], 10.0, 95.0, "°C", f"Circuit {n[1]} curve at +20 °C outdoor", 1,
                                  why="operator adjusts the heating curve"),
                  "Min": tmin, "Max": tmax},
            why="vendor: Curve_3p 'curve is defined at 3 points: -20 °C, 0 °C and +20 °C', 'cut ... with minimum and maximum limits', "
                "'automatic adjustment of the curve convexity'; CurveOut (uncut) is used so the offset is added before the cut")
    c.block("offs", "SwitchAn", col=1,
            pins={"Select": const(0),
                  "Input0": setv(p + "SP_OFFSET", 0.0, -10.0, 10.0, "°C", f"Circuit {n[1]} setpoint offset", 1,
                                 why="operator parallel shift of the curve"),
                  "Input1": const(0.0)},
            why="vendor: SwitchAn Select=0 -> Output = Input0; pass-through puts the set value on a block output "
                "(a set value on an extendable Add input is avoided, design-rules)")
    c.block("pmin", "SwitchAn", col=1,
            pins={"Select": const(0), "Input0": setv(p + "TS_MIN"), "Input1": const(0.0)},
            why="vendor: SwitchAn Select=0 -> Output = Input0; minimum limit as a block output for the Max block")
    c.block("pmax", "SwitchAn", col=1,
            pins={"Select": const(0), "Input0": setv(p + "TS_MAX"), "Input1": const(0.0)},
            why="vendor: SwitchAn Select=0 -> Output = Input0; maximum limit as a block output for Min")

    c.block("nsb", "SwitchAn", col=1, label="Night setback",
            pins={"Select": tprg(p + "TPRG", 1, week(COMFORT_DAY), f"Circuit {n[1]} heating time program", ["Setback", "Comfort"],
                                 why="operator sets the comfort periods; 0 = setback, 1 = comfort"),
                  "Input0": setv(p + "SETBACK", d["setback"], 0.0, 30.0, "°C", f"Circuit {n[1]} night setback", 1,
                                 why="operator; how much the supply setpoint drops during setback"),
                  "Input1": const(0.0)},
            why="vendor: SwitchAn 'If Select = 0, Output = Input0. If Select = 1, Output = Input1' - setback amount while the "
                "time program is 0, nothing while it is 1; the time program sits on Select (an Enum block input)")

    # --- column 2: limits, set value consistency, enable ---------------------------------------
    c.block("spadd", "Add", col=2, label="Setpoint with limits",
            pins={"A": wire("curve.CurveOut"), "B1": wire("offs.Output")},
            why="vendor: Add 'Output = A + B1 + ...'; unconnected inputs excluded")
    c.block("spsb", "Subtract", col=2,
            pins={"A": wire("spadd.Output"), "B1": wire("nsb.Output")},
            why="vendor: Subtract 'Output = A - B1 - ...' - setback lowers the setpoint before the limits")
    c.block("splo", "Max", col=2,
            pins={"Input1": wire("spsb.Output"), "Input2": wire("pmin.Output")},
            why="vendor: Max 'Output = Input which has the maximum value' - minimum cut after the offset")
    c.block("sp", "Min", col=2,
            pins={"Input1": wire("splo.Output"), "Input2": wire("pmax.Output")},
            why="vendor: Min 'Output = Minimum input value' - maximum cut last, so Max wins if Min > Max") \
        .out("Output", measure(p + "SP", "°C", 1, f"Circuit {n[1]} supply setpoint"))

    c.block("slat", "RS_FlipFlop", col=2, label="Summer latch",
            pins={"S": wire("sdly.Output"), "R": wire("sstart.Output")},
            why="vendor: RS_FlipFlop 'If both S and R are 1, Output is 0' (reset dominant -> heating wins if limits overlap); "
                "both 0 'remain its state' = hysteresis") \
        .out("Output", measure(p + "SUMMER", "", None, f"Circuit {n[1]} summer stop active"))
    c.block("svmm", "GreaterThan", col=2, label="Set value check",
            pins={"A": setv(p + "TS_MIN"), "B": setv(p + "TS_MAX")},
            why="vendor: GreaterThan - minimum supply limit above maximum is inconsistent")
    c.block("svss", "GreaterOrEqual", col=2,
            pins={"A": setv(p + "SUM_START"), "B": setv(p + "SUM_STOP")},
            why="vendor: GreaterOrEqual 'if A >= B, Output = 1' - restart limit not below stop limit is inconsistent")
    c.block("sverr", "Or", col=2,
            pins={"Input1": wire("svmm.Output"), "Input2": wire("svss.Output")},
            why="vendor: Or") \
        .out("Output", measure(p + "SV_ERR", "", None, f"Circuit {n[1]} set value conflict"))

    # --- column 3: run logic, exercise, PID, deviation ------------------------------------------
    en = setv(p + "ENABLE", 1, None, None, "", f"Circuit {n[1]} enabled", why="operator switches the circuit off for service")
    c.block("run", "SwitchBin", col=3, label="Circuit run",
            pins={"Select": en, "Input0": const(0), "Input1": wire("slat.OutputNeg")},
            why="vendor: SwitchBin 'If Select = 0, Output = Input0' -> run = ENABLE AND NOT summer; "
                "RS OutputNeg 'is inverse of Output'")
    c.block("exen", "SwitchBin", col=3,
            pins={"Select": setv(p + "ENABLE"), "Input0": const(0), "Input1": wire("slat.Output")},
            why="vendor: SwitchBin -> exercise allowed only when enabled and in summer stop")
    c.block("exer", "OnOffPulse", col=3, label="Pump exercise",
            pins={"Enable": wire("exen.Output"),
                  "OnTime": setv(p + "EXER_ON", 120.0, 10.0, 1800.0, "s", f"Circuit {n[1]} pump exercise run time", 0,
                                 why="operator"),
                  "OffTime": setv(p + "EXER_OFF", 604800.0, 3600.0, 2592000.0, "s", f"Circuit {n[1]} pump exercise interval", 0,
                                  why="operator; default 7 days"),
                  "StartState": const(0), "Restart": const(0)},
            why="vendor: OnOffPulse 'Output is 1 for OnTime (in seconds) and 0 for OffTime (in seconds)', "
                "'If Enable = 0, Output = 0'; StartState=0 'pulsing is started by OffPulse'")
    c.block("pump", "Or", col=3,
            pins={"Input1": wire("run.Output"), "Input2": wire("exer.Output")},
            why="vendor: Or - pump runs when the circuit runs or during an exercise pulse") \
        .out("Output", measure(p + "PUMP", "", None, f"Circuit {n[1]} pump command"), io(pump_point))

    c.block("pen", "SwitchBin", col=3, label="Valve control",
            pins={"Select": wire("tsbad.Output"), "Input0": wire("run.Output"), "Input1": const(0)},
            why="vendor: SwitchBin -> PID enable = run AND NOT supply sensor fault")
    c.block("pid", "Pid", col=3,
            pins={"Enable": wire("pen.Output"), "SetPoint": wire("sp.Output"), "Measure": tsio,
                  "DeadBand": const(0.5), "Reverse": const(1),
                  "P": setv(p + "PID_P", d["pid_p"], 2.0, 500.0, "°C", f"Circuit {n[1]} PID proportional band", 1,
                            why="tuned at commissioning"),
                  "I": setv(p + "PID_I", d["pid_i"], 5.0, 300.0, "s", f"Circuit {n[1]} PID integral time", 0,
                            why="tuned at commissioning; must not be 0 (vendor)"),
                  "D": const(0.0), "CtrlSpace": const(1.0), "Min": const(0.0), "Max": const(100.0),
                  "Balance": const(0.0), "BreakBand": const(0.0), "Hold": const(0),
                  "StageUpDelay": const(0.0), "StageDownDelay": const(0.0)},
            why="vendor: Pid 5.1 'If Enable input is 0 ... output is 0%', 'Reverse ... 1 = Heating', P 'P-area' in °C (2..500), "
                "I 'I time in seconds' (5..300, 'ei saa asettaa nollaksi'); Feedback left unconnected ('If Feedback input is connected'), "
                "U32 stage pins untouched")
    c.block("fsel", "And", col=3,
            pins={"Input1": wire("run.Output"), "Input2": wire("tsbad.Output")},
            why="vendor: And 'If all inputs are 1, output is 1' - fault position only while the circuit runs")
    c.block("vlv", "SwitchAn", col=4, label="Valve output",
            pins={"Select": wire("fsel.Output"), "Input0": wire("pid.Output"),
                  "Input1": setv(p + "VLV_FAULT", d["vlv_fault"], 0.0, 100.0, "%", f"Circuit {n[1]} valve position on sensor fault", 0,
                                 why="site dependent")},
            why="vendor: SwitchAn Select=1 -> Input1 (fixed valve position on supply sensor fault)") \
        .out("Output", measure(p + "VALVE", "%", 0, f"Circuit {n[1]} valve position"), io(vlv_point))

    c.block("dev", "Subtract", col=4, label="Deviation alarm",
            pins={"A": tsio, "B1": wire("sp.Output")},
            why="vendor: Subtract 'Output = A - B1 - ...'")
    c.block("dabs", "Absolute", col=4,
            pins={"Input": wire("dev.Output")},
            why="vendor: Absolute 'If Input < 0, Output = -1 * Input' (used as |x|, not as a pass-through)")
    c.block("dgt", "GreaterThan", col=4,
            pins={"A": wire("dabs.Output"),
                  "B": setv(p + "DEV_LIM", d["dev_lim"], 1.0, 30.0, "°C", f"Circuit {n[1]} deviation alarm limit", 1,
                            why="operator")},
            why="vendor: GreaterThan 'if A > B, Output = 1'")
    c.block("dand", "And", col=4,
            pins={"Input1": wire("dgt.Output"), "Input2": wire("pen.Output")},
            why="vendor: And - deviation counts only while the valve is under PID control")
    c.block("ddly", "OnDelay", col=4,
            pins={"Enable": const(1), "Input": wire("dand.Output"),
                  "DelayTime": setv(p + "DEV_DLY", 1800.0, 60.0, 14400.0, "s", f"Circuit {n[1]} deviation alarm delay", 0,
                                    why="operator")},
            why="vendor: OnDelay 0->1 after DelayTime s, 1->0 immediate (alarm clears as soon as the deviation is gone)") \
        .out("Output", measure(p + "DEV_ALM", "", None, f"Circuit {n[1]} supply deviation alarm"), net(p + "DEV_ALM"))
    return c


circuit("C1", "Heating circuit 1, radiators",
        dict(n20=58.0, z0=41.0, p20=20.0, ts_min=18.0, ts_max=70.0, ts_max_hi=90.0, sum_stop=18.0, sum_start=16.0,
             pid_p=40.0, pid_i=60.0, vlv_fault=20.0, dev_lim=10.0, setback=10.0),
        "UI 4", "AO 1", "R1")
circuit("C2", "Heating circuit 2, floor heating",
        dict(n20=35.0, z0=28.0, p20=22.0, ts_min=20.0, ts_max=40.0, ts_max_hi=55.0, sum_stop=17.0, sum_start=15.0,
             pid_p=30.0, pid_i=90.0, vlv_fault=0.0, dev_lim=5.0, setback=3.0),
        "UI 5", "AO 2", "R2")

# -------------------------------------------------------------------------------------------- ALARM
al = P.app("ALARM", "Common alarm relay: OR of all alarm status bits (runs last, so every input is from this cycle)")
al.block("alm", "Or", col=0, label="Common alarm",
         pins={"Input1": net("TOUT_FAULT"), "Input2": net("C1_TS_FAULT"), "Input3": net("C1_DEV_ALM"),
               "Input4": net("C2_TS_FAULT"), "Input5": net("C2_DEV_ALM")},
         why="vendor: Or 'If some input is 1, output is 1'; Input6..8 untouched (excluded)") \
    .out("Output", measure("ALARM_SUM", "", None, "Common alarm"), io("R3"))

# ------------------------------------------------------------------------------------- documentation
for name, text, src in [
    ("TOUT_FAULT", "Outdoor sensor fault", "COMMON/tfd.Output"),
    ("C1_TS_FAULT", "Circuit 1 supply sensor fault", "C1/tsfd.Output"),
    ("C1_DEV_ALM", "Circuit 1 supply temperature deviation", "C1/ddly.Output"),
    ("C2_TS_FAULT", "Circuit 2 supply sensor fault", "C2/tsfd.Output"),
    ("C2_DEV_ALM", "Circuit 2 supply temperature deviation", "C2/ddly.Output"),
]:
    P.alarms.append({"name": name, "text": text, "source": src, "in_alarm_sum": True, "latching": False, "net": True,
                     "ouman_alarm_object": "none: alarm objects are not supported by the build yet; status bit + common alarm relay"})

P.left_out += [
    {"item": "Domestic hot water", "reason": "not part of this substation"},
    {"item": "Valve exercise", "reason": "opening the DH valve with the pump running in summer pushes primary-temperature water into "
                                          "the circuit (unsafe for floor heating); no documented exercise block; pump exercise only"},
    {"item": "Room temperature compensation", "reason": "no room sensor; a fixed setpoint offset set value instead"},
    {"item": "Alarm objects (AnalogAlarm, DeviationAlarm, BinaryAlarm), acknowledgement, alarm routing",
     "reason": "alarm objects are unsolved in the tool; alarms are status bits and one common relay, non-latching"},
    {"item": "Pump fault / run feedback input", "reason": "kept simple; no feedback contact assumed"},
    {"item": "Floor heating over-temperature safety thermostat", "reason": "must be hard-wired in the pump circuit, not software"},
    {"item": "Return temperature limitation, primary flow/energy metering", "reason": "primary temperatures are measurements only"},
    {"item": "Frost protection of the circuits in summer", "reason": "summer stop releases below the restart limit; no separate frost logic"},
    {"item": "Local/remote set value patterns, run-time counters, manual overrides", "reason": "SetPointSync/StateSync/RunTimeCounter/Override "
                                                                                             "arrive with vendor objects; avoided"},
]
P.notes += [
    "Modbus: set values 1000+n, analog measurements 1100+n, binary status 1150+n (n = table offset); all Holding registers; "
    "registers 2..7 and 14 are system registers; the exported document shows each number +1.",
    "Execution order: COMMON, C1, C2, ALARM. Circuits read TOUT_F from COMMON in the same cycle; ALARM reads every alarm net in the same cycle.",
    "Setpoint = min(max(CurveOut + offset - setback, TS_MIN), TS_MAX): offset and night setback applied before the limits; the maximum limit wins if TS_MIN > TS_MAX "
    "(status bit SV_ERR). Curve_3p Min/Max carry the same set values but its cut Output is not used.",
    "Summer stop: stop when filtered outdoor > SUM_STOP for SUM_DLY s; heating resumes at once when it is < SUM_START. "
    "Reset-dominant latch: overlapping limits give heating (status bit SV_ERR).",
    "Pid RevPDisable left at the library default (30 °C): the vendor texts of 4.2 and 5.1 contradict each other.",
    "AO scaling assumed 0..100 % = 0..10 V; confirm in the build.",
]

P.write(os.path.join(HERE, "plan.json"), generator="examples/dh2/make_plan.py")
