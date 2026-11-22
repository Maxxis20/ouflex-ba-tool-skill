#!/usr/bin/env python3
"""DH-ex2: Finnish Energy example connection 2 (publication K1/2013, p. 63) - small house district heating substation
with one domestic hot water circuit (TC1: TE1 -> TV1) and one heating circuit (TC2: TE2A + TE2B -> TV2).

Writes plan.json next to this file. Applications run OUTDOOR -> TC1_DHW -> TC2_HEAT -> ALARM.

    python make_plan.py
    python ../../pipeline/check_plan.py .

Description of operation: DESCRIPTION.md (same directory). Tags follow the drawing (TE1, TE2A, TE2B, TV1, TV2, P1, P2).
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.normpath(os.path.join(HERE, "..", "..", "pipeline")))

from oufplan import Plan, wire, const, setv, net, io, measure  # noqa: E402

P = Plan("DH-ex2", title="District heating substation, example connection 2: domestic hot water (TC1) and one heating circuit (TC2)")

# ---------------------------------------------------------------------------------------------- I/O
P.io("UI 1", "TE2B_IN", "in", "NTC", "TE2B outdoor temperature")
P.io("UI 2", "TE1_IN", "in", "NTC", "TE1 domestic hot water temperature")
P.io("UI 3", "TE2A_IN", "in", "NTC", "TE2A heating network supply temperature")
P.io("AO 1", "TV1_OUT", "out", "AO 0-10V", "TV1 domestic hot water control valve 0..100 %")
P.io("AO 2", "TV2_OUT", "out", "AO 0-10V", "TV2 heating control valve 0..100 %")
P.io("R1", "P1_OUT", "out", "relay", "P1 domestic hot water circulation pump")
P.io("R2", "P2_OUT", "out", "relay", "P2 heating network pump")
P.io("R3", "ALARM_OUT", "out", "relay", "HS common alarm (energised = alarm)")

P.measure_io("TE2B", "UI 1", "°C", 1, "TE2B outdoor temperature, raw")
P.measure_io("TE1", "UI 2", "°C", 1, "TE1 domestic hot water temperature")
P.measure_io("TE2A", "UI 3", "°C", 1, "TE2A heating supply temperature")

TOUT_LO, TOUT_HI = -45.0, 50.0      # outdoor sensor plausible range (constants)
TS_LO, TS_HI = -20.0, 120.0         # water sensor plausible range (constants)


def pid_pins(enable, sp, meas, p, i):
    return {"Enable": enable, "SetPoint": sp, "Measure": meas, "DeadBand": const(0.5), "Reverse": const(1),
            "P": p, "I": i, "D": const(0.0), "CtrlSpace": const(1.0), "Min": const(0.0), "Max": const(100.0),
            "Balance": const(0.0), "BreakBand": const(0.0), "Hold": const(0),
            "StageUpDelay": const(0.0), "StageDownDelay": const(0.0)}


PID_WHY = ("vendor: Pid 5.1 'If Enable input is 0, PID regulator is inactive and output is 0%', 'Reverse ... 1 = Heating', "
           "P 'P-area' in °C (2..500), I 'I time in seconds' (5..300); Feedback unconnected, U32 stage pins untouched")


def sensor_check(a, point, label, fault_measure, fault_display, fault_net, lo=TS_LO, hi=TS_HI):
    """Range check of an NTC input: below lo or above hi = sensor fault (status + net, no delay: control reacts at once)."""
    a.block("tslo", "LessThan", label=label, pins={"A": io(point), "B": const(lo)},
            why="vendor: LessThan 'if A < B, Output = 1' - below the plausible range = sensor fault (open circuit)")
    a.block("tshi", "GreaterThan", pins={"A": io(point), "B": const(hi)},
            why="vendor: GreaterThan 'if A > B, Output = 1' - above the plausible range = sensor fault (short circuit)")
    a.block("tsbad", "Or", pins={"Input1": wire("tslo.Output"), "Input2": wire("tshi.Output")},
            why="vendor: Or 'If some input is 1, output is 1'; unused inputs untouched (excluded)") \
        .out("Output", measure(fault_measure, "", None, fault_display), net(fault_net))


def temp_alarm(a, point, hi, lo, dly, gate=None):
    """High / low limit alarm on a temperature with an entry delay. gate = block output that must be 1 (None = always armed)."""
    a.block("ahi", "GreaterThan", label="Temperature alarm: above the high limit or below the low limit, delayed",
            pins={"A": io(point), "B": hi}, why="vendor: GreaterThan 'if A > B, Output = 1'")
    a.block("alo", "LessThan", pins={"A": io(point), "B": lo}, why="vendor: LessThan 'if A < B, Output = 1'")
    a.block("aor", "Or", pins={"Input1": wire("ahi.Output"), "Input2": wire("alo.Output")}, why="vendor: Or")
    src = "aor.Output"
    if gate:
        a.block("aand", "And", pins={"Input1": wire("aor.Output"), "Input2": wire(gate)},
                why="vendor: And 'If all inputs are 1, output is 1' - alarm only while the controller is active")
        src = "aand.Output"
    return a.block("adly", "OnDelay", pins={"Enable": const(1), "Input": wire(src), "DelayTime": dly},
                   why="vendor: OnDelay 0->1 after DelayTime s, 1->0 immediate; Enable=1 explicitly (Enable=0 passes the input through)")


# ------------------------------------------------------------------------------------------ OUTDOOR
a = P.app("OUTDOOR", "TE2B outdoor temperature: range check, fallback value, slow filter")
sensor_check(a, "UI 1", "TE2B outdoor sensor check", "TE2B_FAULT", "TE2B outdoor sensor fault", "TOUT_FAULT", TOUT_LO, TOUT_HI)
a.block("tsub", "SwitchAn", label="Outdoor temperature for control: fallback value on a fault, slow filter",
        pins={"Select": wire("tsbad.Output"), "Input0": io("UI 1"),
              "Input1": setv("TOUT_FALLBACK", 0.0, -30.0, 20.0, "°C", "Outdoor fallback temperature", 1,
                             why="used while TE2B is faulty; site dependent")},
        why="vendor: SwitchAn 'If Select = 0, Output = Input0. If Select = 1, Output = Input1' - substitute value on fault")
a.block("tflt", "SignalFilter",
        pins={"Enable": const(1), "Input": wire("tsub.Output"),
              "TimeConstant": setv("TOUT_FILT_T", 900.0, 10.0, 21600.0, "s", "Outdoor filter time constant", 0,
                                   why="building inertia; tuned at commissioning")},
        why="vendor: SignalFilter 'first-order low-pass'; TimeConstant in seconds; Enable set 1 explicitly") \
    .out("Output", measure("TE2B_F", "°C", 1, "TE2B outdoor temperature, filtered"), net("TOUT_F"))

# ------------------------------------------------------------------------------------------ TC1_DHW
d = P.app("TC1_DHW", "TC1 domestic hot water: TV1 keeps TE1 at the set value (58 °C); P1 circulation; temperature alarm")
sensor_check(d, "UI 2", "TE1 sensor check", "TE1_FAULT", "TE1 hot water sensor fault", "DHW_TS_FAULT")
d.block("run", "SwitchBin", label="TC1 control: P1 runs while hot water is in use, TV1 keeps TE1 at the set value",
        pins={"Select": setv("DHW_ENABLE", 1, None, None, "", "Domestic hot water in use", why="operator switches DHW off for service"),
              "Input0": const(0), "Input1": const(1)},
        why="vendor: SwitchBin 'If Select = 0, Output = Input0' - binary set value brought to a block output") \
    .out("Output", measure("P1_RUN", "", None, "P1 hot water circulation pump command"), io("R1"))
d.block("pen", "SwitchBin",
        pins={"Select": wire("tsbad.Output"), "Input0": wire("run.Output"), "Input1": const(0)},
        why="vendor: SwitchBin -> controller enable = in use AND NOT TE1 fault (Pid disabled = output 0 % = valve closed)")
d.block("tc1", "Pid",
        pins=pid_pins(wire("pen.Output"),
                      setv("DHW_SP", 58.0, 50.0, 65.0, "°C", "Domestic hot water set value", 1, why="K2 example: 58 °C"),
                      io("UI 2"),
                      setv("DHW_PID_P", 60.0, 2.0, 500.0, "°C", "TC1 proportional band", 1, why="tuned at commissioning"),
                      setv("DHW_PID_I", 15.0, 5.0, 300.0, "s", "TC1 integral time", 0, why="tuned at commissioning; must not be 0 (vendor)")),
        why=PID_WHY) \
    .out("Output", measure("TV1", "%", 0, "TV1 hot water valve position"), io("AO 1"))
temp_alarm(d, "UI 2",
           setv("DHW_HI_LIM", 65.0, 55.0, 90.0, "°C", "Hot water high alarm limit", 1, why="scalding limit; operator"),
           setv("DHW_LO_LIM", 50.0, 30.0, 58.0, "°C", "Hot water low alarm limit", 1, why="legionella limit; operator"),
           setv("DHW_ALM_DLY", 300.0, 10.0, 3600.0, "s", "Hot water alarm delay", 0, why="operator"), gate="pen.Output") \
    .out("Output", measure("DHW_TEMP_ALM", "", None, "Hot water temperature alarm"), net("DHW_TEMP_ALM"))

# ----------------------------------------------------------------------------------------- TC2_HEAT
h = P.app("TC2_HEAT", "TC2 heating: supply set value from the outdoor curve, TV2 keeps TE2A at it; P2; summer stop; temperature alarm")
h.block("sstart", "LessThan", label="Summer stop: P2 stops when it is warm outdoors, heating resumes when it is cold",
        pins={"A": net("TOUT_F"), "B": setv("SUM_START", 16.0, 0.0, 30.0, "°C", "Heating resumes below outdoor", 1, why="seasonal; operator")},
        why="vendor: LessThan 'if A < B, Output = 1'")
h.block("sstop", "GreaterThan",
        pins={"A": net("TOUT_F"), "B": setv("SUM_STOP", 18.0, 5.0, 30.0, "°C", "Summer stop above outdoor", 1, why="seasonal; operator")},
        why="vendor: GreaterThan 'if A > B, Output = 1'")
h.block("sdly", "OnDelay",
        pins={"Enable": const(1), "Input": wire("sstop.Output"),
              "DelayTime": setv("SUM_DLY", 3600.0, 0.0, 86400.0, "s", "Summer stop delay", 0, why="operator")},
        why="vendor: OnDelay 0->1 after DelayTime s; Enable=1 explicitly")
h.block("slat", "RS_FlipFlop", pins={"R": wire("sstart.Output"), "S": wire("sdly.Output")},
        why="vendor: RS_FlipFlop 'If both S and R are 1, Output is 0' (heating wins); both 0 'remain its state' = hysteresis") \
    .out("Output", measure("SUMMER", "", None, "Summer stop active"))
h.block("run", "SwitchBin",
        pins={"Select": setv("HEAT_ENABLE", 1, None, None, "", "Heating in use", why="operator switches heating off for service"),
              "Input0": const(0), "Input1": wire("slat.OutputNeg")},
        why="vendor: SwitchBin 'If Select = 0, Output = Input0' -> run = in use AND NOT summer stop; RS OutputNeg 'is inverse of Output'") \
    .out("Output", measure("P2_RUN", "", None, "P2 heating pump command"), io("R2"))
sensor_check(h, "UI 3", "TE2A sensor check", "TE2A_FAULT", "TE2A supply sensor fault", "HEAT_TS_FAULT")
h.block("pen", "SwitchBin",
        pins={"Select": wire("tsbad.Output"), "Input0": wire("run.Output"), "Input1": const(0)},
        why="vendor: SwitchBin -> controller enable = run AND NOT TE2A fault (Pid disabled = output 0 % = valve closed)")
h.block("curve", "Curve_3p", label="TC2 control: curve gives the set value, TV2 keeps TE2A at it",
        pins={"Input": net("TOUT_F"),
              "Out_n20": setv("CRV_N20", 58.0, 10.0, 95.0, "°C", "Curve: supply at -20 °C outdoor", 1, why="operator adjusts the heating curve"),
              "Out_0": setv("CRV_0", 41.0, 10.0, 95.0, "°C", "Curve: supply at 0 °C outdoor", 1, why="operator adjusts the heating curve"),
              "Out_p20": setv("CRV_P20", 20.0, 10.0, 95.0, "°C", "Curve: supply at +20 °C outdoor", 1, why="operator adjusts the heating curve"),
              "Min": setv("TS_MIN", 18.0, 10.0, 50.0, "°C", "Minimum supply temperature", 1, why="commissioning / operator"),
              "Max": setv("TS_MAX", 70.0, 20.0, 90.0, "°C", "Maximum supply temperature", 1, why="commissioning; protects the radiators")},
        why="vendor: Curve_3p 'curve is defined at 3 points: -20 °C, 0 °C and +20 °C', 'cut the top and bottom of curve with "
            "minimum and maximum limits'; the cut Output is the set value") \
    .out("Output", measure("HEAT_SP", "°C", 1, "Heating supply set value"))
h.block("tc2", "Pid",
        pins=pid_pins(wire("pen.Output"), wire("curve.Output"), io("UI 3"),
                      setv("HEAT_PID_P", 40.0, 2.0, 500.0, "°C", "TC2 proportional band", 1, why="tuned at commissioning"),
                      setv("HEAT_PID_I", 60.0, 5.0, 300.0, "s", "TC2 integral time", 0, why="tuned at commissioning; must not be 0 (vendor)")),
        why=PID_WHY) \
    .out("Output", measure("TV2", "%", 0, "TV2 heating valve position"), io("AO 2"))
temp_alarm(h, "UI 3",
           setv("HEAT_HI_LIM", 80.0, 40.0, 110.0, "°C", "Heating supply high alarm limit", 1, why="protects the heating network; operator"),
           setv("HEAT_LO_LIM", 8.0, 2.0, 30.0, "°C", "Heating supply low alarm limit", 1, why="freezing risk; operator"),
           setv("HEAT_ALM_DLY", 600.0, 10.0, 3600.0, "s", "Heating supply alarm delay", 0, why="operator")) \
    .out("Output", measure("HEAT_TEMP_ALM", "", None, "Heating supply temperature alarm"), net("HEAT_TEMP_ALM"))

# -------------------------------------------------------------------------------------------- ALARM
al = P.app("ALARM", "HS common alarm relay: OR of all alarm status bits (runs last)")
al.block("alm", "Or", label="Common alarm (HS): any sensor fault or temperature alarm",
         pins={"Input1": net("TOUT_FAULT"), "Input2": net("DHW_TS_FAULT"), "Input3": net("DHW_TEMP_ALM"),
               "Input4": net("HEAT_TS_FAULT"), "Input5": net("HEAT_TEMP_ALM")},
         why="vendor: Or 'If some input is 1, output is 1'; Input6..8 untouched (excluded)") \
    .out("Output", measure("ALARM_SUM", "", None, "Common alarm"), io("R3"))

for name, text, src in [
    ("TOUT_FAULT", "TE2B outdoor sensor fault", "OUTDOOR/tsbad.Output"),
    ("DHW_TS_FAULT", "TE1 hot water sensor fault", "TC1_DHW/tsbad.Output"),
    ("DHW_TEMP_ALM", "Hot water temperature high / low", "TC1_DHW/adly.Output"),
    ("HEAT_TS_FAULT", "TE2A supply sensor fault", "TC2_HEAT/tsbad.Output"),
    ("HEAT_TEMP_ALM", "Heating supply temperature high / low", "TC2_HEAT/adly.Output"),
]:
    P.alarms.append({"name": name, "text": text, "source": src, "in_alarm_sum": True, "latching": False, "net": True,
                     "ouman_alarm_object": "none: alarm objects are not supported by the build yet; status bit + common alarm relay"})

P.left_out += [
    {"item": "Pump exercise in summer stop", "reason": "kept simple; add an OnOffPulse block if wanted"},
    {"item": "Valve fault position, set value consistency checks, setpoint offset, sensor fault delay", "reason": "kept simple"},
    {"item": "Supply deviation alarm", "reason": "replaced by high / low limit alarms on TE1 and TE2A (same structure in both circuits)"},
    {"item": "Time programs / night setback, room compensation", "reason": "not in the K2 example; time programs unsolved in the build helpers"},
    {"item": "Alarm objects, acknowledgement, latching", "reason": "alarm objects are unsolved in the tool; status bits and one common relay"},
    {"item": "Pressure switch PS / expansion alarm, PI/TI gauges, energy meter", "reason": "local instruments in the drawing, not connected to the control centre"},
    {"item": "DHW anticipation (flow / primary feed-forward)", "reason": "not in the K2 example; plain PI on TE1"},
]
P.notes += [
    "Modbus: set values 1000+n, analog measurements 1100+n, binary status 1150+n; all Holding registers; the exported document shows each number +1.",
    "Execution order: OUTDOOR, TC1_DHW, TC2_HEAT, ALARM; every net is read by a later application (same cycle, no feedback).",
    "Heating set value = Curve_3p Output (curve cut with TS_MIN / TS_MAX inside the block).",
    "AO scaling assumed 0..100 % = 0..10 V.",
]

P.write(os.path.join(HERE, "plan.json"), generator="examples/dh-ex2/make_plan.py")
