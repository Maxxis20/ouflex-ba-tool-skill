#!/usr/bin/env python3
"""Run an acceptance scenario against one Ouflex application in the BA Tool simulator.

    python pipeline/sim_test.py 'C:\\agentwork\\apps\\dh2\\C1.ouear' examples/dh2/sim-C1.json
    python pipeline/sim_test.py <app.ouear (Windows path)> <scenario.json> [--factor 100] [--attach] [-v]

No controller needed: ApplicationDebugger.exe loads the application into the virtual Ouflex C
(VirtualOuflexC.exe) that ships with BA Tool. The debugger is hosted (instance `dbg`) and driven with the
Sim-* helpers in win/prelude.ps1. One application at a time: points are the application's own interface
pins, set values and measurements (names as in the plan), not device I/O.

Scenario format: {"name", "factor"?, "cases": [{"name", "steps": [...]}]}
with steps {"set": {pt: v}}, {"wait": "40s"|"4m"|"1h"}, {"expect": {pt: v}, "tol"?: x},
{"until": {pt: v}, "max": "60s"}, {"note": "..."}, {"week": {TPRG: "on"|"off"|[7 day strings]}},
{"changes": [pt, ...], "within": "10s"}. true/false = 1/0.
Each case starts with Reset + Run (Reset restores set values, not block states such as integrators: give the scenario
"reload_each_case": true to load the application again before every case). A time program follows the Windows clock and is evaluated only when the program starts, so
"week" (first step of a case) rewrites the program's week in the loaded application ("on" = 1 all week, "off" = 0),
loads it again and restarts.
Time runs `factor` times faster than the wall clock (combo "Timer factor", any number, 100 proven); the
~3 s per driver call is simulated time too, so waits are lower bounds and expects check "at least that late".
Device-level points are not supported here.
"""
import argparse
import json
import os
import re
import subprocess
import sys
import tempfile
import time

SK = os.environ.get("BATOOL_SCRIPTS") or os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "scripts"))


def secs(s):
    m = re.fullmatch(r"\s*([\d.]+)\s*(ms|s|m|h)?\s*", str(s))
    if not m:
        raise ValueError(f"bad duration {s!r}")
    return float(m.group(1)) * {"ms": 0.001, "s": 1, "m": 60, "h": 3600, None: 1}[m.group(2)]


def ps_lit(v):
    if isinstance(v, bool):
        return "1" if v else "0"
    if isinstance(v, (int, float)):
        return repr(v)
    return "'" + str(v).replace("'", "''") + "'"


class Sim:
    def __init__(self, verbose=False):
        self.verbose = verbose
        self.env = dict(os.environ, HNAME="dbg")

    def ps(self, body):
        with tempfile.NamedTemporaryFile("w", suffix=".ps1", delete=False, encoding="utf-8") as f:  # no BOM: hrun prepends a line
            f.write(body + "\n")
            path = f.name
        try:
            out = subprocess.run(["bash", f"{SK}/hrun.sh", path], env=self.env, capture_output=True, text=True, timeout=180).stdout
        finally:
            os.unlink(path)
        if self.verbose:
            sys.stderr.write(out)
        if "TIMEOUT" in out or "ERR:" in out:
            raise RuntimeError(out.strip()[-800:])
        return out

    def get(self, names):
        out = self.ps("Sim-Get " + ",".join(ps_lit(n) for n in names))
        vals = {}
        for line in out.splitlines():
            if line.startswith("VAL|"):
                _, n, v = line.split("|", 2)
                vals[n] = v
        missing = [n for n in names if n not in vals]
        if missing:
            raise RuntimeError(f"no such point(s): {missing}")
        return vals

    def set(self, values):
        """write, read back, write again what did not arrive (a write was seen to get lost); returns what still differs"""
        for attempt in range(3):
            self.ps("\n".join(f"Sim-Set {ps_lit(n)} {ps_lit(v)}" for n, v in values.items()))
            got = self.get(list(values))
            bad = {n: got[n] for n, v in values.items() if not match(got[n], v, 1e-6)}
            if not bad:
                return {}
            values = {n: values[n] for n in bad}
            sys.stderr.write(f"   (write not taken: {bad}, retry)\n")
        return bad


def match(got, want, tol):
    try:
        g = float(got)
    except ValueError:
        return str(got) == str(want)
    w = float(want) if not isinstance(want, bool) else (1.0 if want else 0.0)
    return abs(g - w) <= tol


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("app", help="application .ouear path (Windows path)")
    ap.add_argument("scenario")
    ap.add_argument("--factor", type=float, help="timer factor (default: scenario 'factor' or 10)")
    ap.add_argument("--attach", action="store_true", help="debugger already hosted and loaded: skip start + load")
    ap.add_argument("-v", "--verbose", action="store_true")
    a = ap.parse_args()
    sc = json.load(open(a.scenario, encoding="utf-8"))
    factor = a.factor or sc.get("factor", 10)
    sim = Sim(a.verbose)

    if not a.attach:
        subprocess.run(["bash", f"{SK}/hstart.sh", "dbg", "ApplicationDebugger.exe", a.app, "lang=en-GB"], check=True,
                       capture_output=not a.verbose)
        out = sim.ps("Sim-Load")
        if "Loading complete" not in out:
            sys.exit(f"load failed: {out.strip()}")
    print(sim.ps(f"Sim-Factor {ps_lit(factor)}").strip())

    fails = 0
    for case in sc["cases"]:
        print(f"== {case['name']}")
        if sc.get("reload_each_case"):           # Reset restores set values but not block states (integrators, ramps)
            for attempt in range(4):              # the old virtual device can still hold eventlog.bin for a moment
                try:
                    out = sim.ps("Sim-Load")
                except RuntimeError as e:
                    out = str(e)
                if "Loading complete" in out:
                    break
                time.sleep(4)
            else:
                raise RuntimeError(f"reload failed: {out.strip()[-300:]}")
            sim.ps(f"Sim-Factor {ps_lit(factor)}")
        sim.ps("Sim-Reset | out-null; Sim-Run")
        time.sleep(3)              # a write right after Run was sometimes lost (seen 2026-11-24): let the device settle
        t_mark = time.time()  # wall clock of the last set: waits count from here
        ok = True
        for st in case["steps"]:
            if "week" in st:
                for n, w in st["week"].items():
                    days = ["00:00=1"] * 7 if w == "on" else ["00:00=0"] * 7 if w == "off" else w
                    out = sim.ps(f"Sim-Week {ps_lit(n)} @(" + ",".join(ps_lit(d) for d in days) + ")")
                    if "Loading complete" not in out:
                        raise RuntimeError(f"reload after week change failed: {out.strip()}")
                    print(f"   week {n} = {w}")
                sim.ps("Sim-Factor " + ps_lit(factor) + "; Sim-Reset | out-null; Sim-Run")
                time.sleep(1)
                t_mark = time.time()
            if "note" in st:
                print(f"   # {st['note']}")
            if "set" in st:
                lost = sim.set(st["set"])
                t_mark = time.time()
                print(f"   set {st['set']}" + (f"  FAIL write not taken: {lost}" if lost else ""))
                ok &= not lost
            if "wait" in st:
                due = t_mark + secs(st["wait"]) / factor
                time.sleep(max(0, due - time.time()))
                t_mark = max(due, time.time())
            if "expect" in st:
                tol = st.get("tol", 0.01)
                got = sim.get(list(st["expect"]))
                bad = {n: (got[n], w) for n, w in st["expect"].items() if not match(got[n], w, tol)}
                print(f"   {'ok  ' if not bad else 'FAIL'} expect {st['expect']}" + (f"  got {got}" if bad else ""))
                ok &= not bad
            if "changes" in st:                       # {"changes": [pts], "within": "10s"}: each point must take another value
                names = list(st["changes"]); before = sim.get(names)
                time.sleep(secs(st.get("within", "10s")) / factor)
                after = sim.get(names)
                same = [n for n in names if after[n] == before[n]]
                print(f"   {'ok  ' if not same else 'FAIL'} changes {names}" + (f"  unchanged {same} = {[after[n] for n in same]}" if same else ""))
                ok &= not same
                t_mark = time.time()
            if "until" in st:
                limit = time.time() + secs(st.get("max", "60s")) / factor + 4
                while True:
                    got = sim.get(list(st["until"]))
                    if all(match(got[n], w, st.get("tol", 0.01)) for n, w in st["until"].items()):
                        print(f"   ok   until {st['until']}")
                        break
                    if time.time() > limit:
                        print(f"   FAIL until {st['until']} within {st.get('max', '60s')}  got {got}")
                        ok = False
                        break
                    time.sleep(0.5)
                t_mark = time.time()
        print(f"   {'PASS' if ok else 'FAIL'}")
        fails += not ok
    print(f"RESULT {'OK' if not fails else f'{fails} case(s) failed'} ({len(sc['cases'])} cases, factor {factor:g})")
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
