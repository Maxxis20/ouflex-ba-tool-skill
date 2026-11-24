#!/usr/bin/env python3
"""Structure check of an Ouflex build plan against the block catalogue alone.

    python pipeline/check_plan.py <plan.json | program dir>      # exit 1 on any violation

  P1 every block type is a current OumanComponents block of blocks.json; lib/version/file match
  P2 every pin named in pins/out exists on that block with the right direction (input / output)
  P3 types: wire / net / io / set value feed a pin of the same value type (Float / Enum / U32); Enum constants 0 or 1;
     constants numeric; no constant or set value on a U32 pin
  P4 one source per input pin; wire sources are outputs of a block in the same application
  P5 nets: exactly one writer, readers declared = readers found, read in another application than the writer,
     feedback flag correct for the application order
  P6 set values: defined once, every pin listed carries it, all its pins one type, default within min..max,
     not on an extendable input unless flagged, unit/decimals given for Float; Modbus offsets unique per table
  P7 measures: source output exists and carries it; io-measures on a declared point; Modbus offsets unique per table
  P8 I/O: real Ouflex A points (or a module point declared by the program), each once, every input read only,
     every output driven by exactly one pin, io sources only on inputs
  P9 required inputs: the inputs the tool's CheckAll is known to require (proven, findings.md) are sourced;
     unsourced signal inputs of block types never probed are listed as WARN (CheckAll decides)
  P10 execution order 1..n; a wire from a later block is flagged feedback and only then
  P11 layout: no two block symbols overlap (measured size), labels do not sit on a block
  P12 names: block ids, set values, measures, nets and io pins are case-insensitively unique where they share a
     namespace (the build renames clashes, which this reports as INFO)
"""
import json
import os
import sys
from collections import defaultdict

BLOCKS_JSON = os.environ.get("OUMAN_BLOCKS", os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "reference", "blocks.json"))
if not os.path.exists(BLOCKS_JSON):
    raise SystemExit("block catalogue missing (" + os.path.normpath(BLOCKS_JSON) + "): run scripts/batool.sh setup, it reads the block library of your own BA Tool installation")
REF = json.load(open(BLOCKS_JSON, encoding="utf-8"))
CUR = {b["type"]: b for b in REF["blocks"] if b["current"] and not b["beta"] and b["library"] == "OumanComponents"}
EXTENDABLE = {"And": "Input1", "Or": "Input1", "Nand": "Input1", "Nor": "Input1", "Add": "A", "Subtract": "A", "Multiply": "A",
              "Divide": "A", "Average": "Input1", "Min": "Input1", "Max": "Input1"}
# CheckAll "FOLLOWING PINS ARE NOT CONNECTED" when left untouched (proven on probes and on the
# example programs, findings.md). Types listed with an empty set were probed and need nothing beyond defaults.
REQUIRED = {"Add": {"A"}, "Subtract": {"A"}, "Compensator": {"Input"}, "CountUp": {"Input"}, "Integrator": {"Input"},
            "Limit": {"Input"}, "Not": {"Input"}, "OnDelay": {"Input"}, "OffDelay": {"Input"}, "Pulse": {"Input"},
            "SignalFilter": {"Input"}, "RunTimeCounter": {"Indication"}, "StateSync": {"RemoteIn"},
            "GreaterThan": {"A", "B"}, "GreaterOrEqual": {"A", "B"}, "LessThan": {"A", "B"}, "LessOrEqual": {"A", "B"},
            "RS_FlipFlop": {"R", "S"}, "SR_FlipFlop": {"R", "S"}, "Xor": {"Input1", "Input2"},
            "Override": {"Input", "OverrideEnable", "OverrideValue"}, "SwitchAn": {"Select", "Input0", "Input1"},
            "SwitchBin": {"Select", "Input0", "Input1"}, "And": set(), "Or": set(), "MinBuffer": {"Input"},
            "OnOffPulse": set(), "StartDelay": set()}
PROBE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "block_probe.json")
BUILTIN_SV = {}
if os.path.exists(PROBE):        # CheckAll on one of each further block type (see its _source)
    _pr = json.load(open(PROBE))
    for t, pins in _pr["required"].items():
        REQUIRED[t] = set(pins) | REQUIRED.get(t, set())
    BUILTIN_SV = {t: set(p) for t, p in _pr["builtin_setvalues"].items()}
POINTS = {f"UI {i}" for i in range(1, 17)} | {"DI 1", "DI 2"} | {f"AO {i}" for i in range(1, 7)} | {f"TR {i}" for i in range(1, 5)} | {f"R{i}" for i in range(1, 7)}
FLOAT_KINDS = {"NTC", "4-20mA", "0-10V", "AO 0-10V", "pulse"}


def main(arg):
    path = os.path.join(arg, "plan.json") if os.path.isdir(arg) else arg
    if os.path.isdir(arg) and os.path.exists(os.path.join(arg, "program.json")):
        cfg = json.load(open(os.path.join(arg, "program.json")))
        if cfg.get("plan"):
            path = os.path.normpath(os.path.join(arg, cfg["plan"]))
    else:
        cfg = {}
    if not os.path.isdir(arg) and os.path.exists(os.path.join(os.path.dirname(os.path.abspath(arg)), "program.json")):
        cfg = json.load(open(os.path.join(os.path.dirname(os.path.abspath(arg)), "program.json")))
    extra_points = set()
    for m in cfg.get("modules", []):
        extra_points |= {f"{m['prefix']}{i}" for i in range(1, m["channels"] + 1)}
    P = json.load(open(path, encoding="utf-8"))
    bad, warn, info, counts = [], [], [], defaultdict(int)
    fail = lambda c, m: bad.append(f"{c}: {m}")
    apps = P["applications"]
    order = {a["name"]: a["order"] for a in apps}
    BLK = {(a["name"], b["id"]): b for a in apps for b in a["blocks"]}
    SV = {s["name"]: s for s in P["setvalues"]}
    TP = {t["name"]: t for t in P.get("timeprograms") or []}
    MS = {m["name"]: m for m in P["measures"]}
    NETS = {n["name"]: n for n in P["nets"]}
    IO = {}
    for i in P["io"]:
        if i["point"] in IO:
            fail("P8", f"io {i['point']} assigned twice")
        IO[i["point"]] = i

    def pdef(t, name, d=None):
        return next((p for p in CUR[t]["pins"] if p["name"] == name and (d is None or p["dir"] == d)), None)

    def io_type(pt):
        return "Float" if IO[pt]["kind"] in FLOAT_KINDS else "Enum"

    sv_pins = defaultdict(list)
    readers = defaultdict(list)
    writers = defaultdict(list)
    drive = defaultdict(list)
    for (an, bid), b in BLK.items():
        t = b["type"]
        counts["P1 blocks"] += 1
        if t not in CUR:
            fail("P1", f"{an}/{bid}: {t} is not a current OumanComponents block"); continue
        r = CUR[t]
        if b["version"] != r["version"] or b.get("lib", r["library"]) != r["library"] or b["file"] != r["file"].rsplit("\\", 1)[-1]:
            fail("P1", f"{an}/{bid}: {t} {b['version']} {b['file']} != {r['version']} {r['file']}")
        for pn, s in b["pins"].items():
            counts["P2 input pins"] += 1
            d = pdef(t, pn, "in")
            if not d:
                fail("P2", f"{an}/{bid}.{pn}: not an input of {t}"); continue
            keys = [k for k in ("wire", "const", "setvalue", "tprg", "net", "io") if k in s]
            if len(keys) != 1:
                fail("P4", f"{an}/{bid}.{pn}: {len(keys)} sources"); continue
            k = keys[0]
            counts[f"P4 sources {k}"] += 1
            if k == "wire":
                sb, sp = s["wire"].rsplit(".", 1)
                src = BLK.get((an, sb))
                sd = src and pdef(src["type"], sp, "out")
                if not sd:
                    fail("P4", f"{an}/{bid}.{pn}: wire source {s['wire']} is not a block output in {an}")
                elif sd["type"] != d["type"]:
                    fail("P3", f"{an}/{bid}.{pn} ({d['type']}) <- {s['wire']} ({sd['type']})")
                elif (src["exec"] >= b["exec"]) != bool(s.get("feedback")):
                    fail("P10", f"{an}/{bid}.{pn} <- {s['wire']}: exec {src['exec']}->{b['exec']}, feedback flag {s.get('feedback')}")
            elif k == "const":
                if not isinstance(s["const"], (int, float)) or isinstance(s["const"], bool):
                    fail("P3", f"{an}/{bid}.{pn}: constant {s['const']!r} not numeric")
                elif d["type"] == "Enum" and s["const"] not in (0, 1):
                    fail("P3", f"{an}/{bid}.{pn}: Enum constant {s['const']}")
                elif d["type"] == "U32":
                    fail("P3", f"{an}/{bid}.{pn}: constant on a U32 pin (not proven)")
                if t in EXTENDABLE and pn != EXTENDABLE[t] and f"const-on-extendable:{pn}" not in b.get("flags", []):
                    fail("P6", f"{an}/{bid}.{pn}: constant on an extendable input, not flagged")
            elif k == "setvalue":
                sv_pins[s["setvalue"]].append(f"{an}/{bid}.{pn}")
                sv = SV.get(s["setvalue"])
                if not sv:
                    fail("P6", f"{an}/{bid}.{pn}: unknown set value {s['setvalue']}")
                elif sv["type"] != d["type"]:
                    fail("P3", f"{an}/{bid}.{pn} ({d['type']}) <- set value {sv['name']} ({sv['type']})")
                if d["type"] == "U32":
                    fail("P6", f"{an}/{bid}.{pn}: set value on a U32 pin")
                if t in EXTENDABLE and f"setvalue-on-extendable:{pn}" not in b.get("flags", []):
                    fail("P6", f"{an}/{bid}.{pn}: set value on an extendable input, not flagged")
            elif k == "tprg":
                tp = TP.get(s["tprg"])
                if not tp or tp["pin"] != f"{an}/{bid}.{pn}":
                    fail("P6", f"{an}/{bid}.{pn}: time program {s['tprg']} not declared on this pin")
                elif tp["type"] == "On_Off" and d["type"] != "Enum":
                    fail("P3", f"{an}/{bid}.{pn} ({d['type']}) <- On/Off time program {s['tprg']}")
                elif tp["name"] in SV or tp["name"] in MS:
                    fail("P6", f"time program {tp['name']} has the name of a set value or measure")
            elif k == "net":
                readers[s["net"]].append((f"{an}/{bid}.{pn}", d["type"], bool(s.get("feedback"))))
            elif k == "io":
                pt = s["io"]
                if pt not in IO:
                    fail("P8", f"{an}/{bid}.{pn}: io {pt} not declared")
                elif IO[pt]["dir"] != "in":
                    fail("P8", f"{an}/{bid}.{pn}: reads output point {pt}")
                elif io_type(pt) != d["type"]:
                    fail("P3", f"{an}/{bid}.{pn} ({d['type']}) <- io {pt} ({io_type(pt)})")
        for pn, outs in b["out"].items():
            d = pdef(t, pn, "out")
            if not d:
                fail("P2", f"{an}/{bid}.{pn}: not an output of {t}"); continue
            for o in outs:
                if "net" in o:
                    writers[o["net"]].append((f"{an}/{bid}.{pn}", d["type"]))
                elif "io" in o:
                    drive[o["io"]].append(f"{an}/{bid}.{pn}")
                    if o["io"] in IO and io_type(o["io"]) != d["type"]:
                        fail("P3", f"{an}/{bid}.{pn} ({d['type']}) -> io {o['io']} ({io_type(o['io'])})")
                elif "measure" in o:
                    m = MS.get(o["measure"])
                    if not m or m["source"] != f"{an}/{bid}.{pn}":
                        fail("P7", f"{an}/{bid}.{pn}: measure {o['measure']} not declared with this source")
                    if d["type"] == "U32":
                        fail("P7", f"{an}/{bid}.{pn}: measure on a U32 output")
        # P9 required inputs
        if t in REQUIRED:
            filled = [p for p in REQUIRED[t] if p not in b["pins"] and p in cfg.get("required_fill", {}).get(t, {})]
            if filled:
                info.append(f"P9 {an}/{bid} ({t}): {filled} filled with constants by program.json required_fill")
            miss = sorted(p for p in REQUIRED[t] if p not in b["pins"] and p not in filled)
            if miss:
                fail("P9", f"{an}/{bid} ({t}): required inputs not sourced: {miss}")
        else:
            un = [p["name"] for p in CUR[t]["pins"] if p["dir"] == "in" and p["category"] == "Pin" and not p["hidden"] and p["role"] == "signal"
                  and p["name"] not in b["pins"] and not (t in EXTENDABLE and p["name"] != EXTENDABLE[t])]
            if un:
                warn.append(f"P9 {an}/{bid} ({t}, never probed): unsourced signal inputs {un} - CheckAll decides")
    # P5 nets
    for n, x in NETS.items():
        counts["P5 nets"] += 1
        w = writers.get(n, [])
        if [a for a, _ in w] != [x["writer"]]:
            fail("P5", f"net {n}: writers {w} vs declared {x['writer']}")
        rs = readers.get(n, [])
        if sorted(r for r, _, _ in rs) != sorted(x["readers"]):
            fail("P5", f"net {n}: readers differ")
        if not rs:
            fail("P5", f"net {n}: no reader")
        wa = x["writer"].split("/")[0]
        for r, rt, fb in rs:
            ra = r.split("/")[0]
            if ra == wa:
                fail("P5", f"net {n} read in its own application {wa}: use a wire")
            if fb != (order[wa] >= order[ra]):
                fail("P5", f"net {n} -> {r}: feedback flag {fb} wrong")
            if w and w[0][1] != rt:
                fail("P3", f"net {n}: {w[0][1]} into {r} ({rt})")
    for n in set(writers) | set(readers):
        if n not in NETS:
            fail("P5", f"net {n} not declared")
    # P6 set values
    offs = defaultdict(set)
    for n, s in SV.items():
        counts["P6 set values"] += 1
        if sorted(sv_pins.get(n, [])) != sorted(s["pins"]):
            fail("P6", f"set value {n}: pins {sv_pins.get(n)} vs declared {s['pins']}")
        if not s["pins"]:
            fail("P6", f"set value {n}: on no pin")
        if s["type"] == "Float":
            if s["min"] is None or s["max"] is None or not (s["min"] <= s["default"] <= s["max"]):
                fail("P6", f"set value {n}: default {s['default']} outside {s['min']}..{s['max']}")
            if s.get("decimals") is None:
                fail("P6", f"set value {n}: decimals missing")
        elif s["default"] not in (0, 1):
            fail("P6", f"set value {n}: Enum default {s['default']}")
        if not (s.get("display") or s.get("display_fi")):
            fail("P6", f"set value {n}: no display name")
        mb = s.get("modbus")
        if mb:
            if mb["offset"] in offs[mb["table"]]:
                fail("P6", f"set value {n}: Modbus {mb['table']} {mb['offset']} used twice")
            offs[mb["table"]].add(mb["offset"])
    # P7 measures
    for n, m in MS.items():
        counts["P7 measures"] += 1
        if m["source"].startswith("io:"):
            if m["source"][3:] not in IO:
                fail("P7", f"measure {n}: io {m['source']} not declared")
        else:
            an, rest = m["source"].split("/")
            bid, pn = rest.rsplit(".", 1)
            if {"measure": n} not in BLK.get((an, bid), {}).get("out", {}).get(pn, []):
                fail("P7", f"measure {n}: source {m['source']} does not carry it")
        mb = m.get("modbus")
        if mb:
            if mb["offset"] in offs[mb["table"]]:
                fail("P7", f"measure {n}: Modbus {mb['table']} {mb['offset']} used twice")
            offs[mb["table"]].add(mb["offset"])
    # P8 I/O
    for p, i in IO.items():
        counts["P8 io points"] += 1
        if p not in POINTS and p not in extra_points:
            fail("P8", f"io {p} is not an Ouflex A point (nor a declared module point)")
        if i["dir"] == "out" and len(drive.get(p, [])) != 1:
            fail("P8", f"output {p} driven by {drive.get(p, [])}")
        if i["dir"] == "in" and drive.get(p):
            fail("P8", f"input {p} driven by {drive[p]}")
        if i["dir"] == "out" and i.get("used_by"):
            fail("P8", f"output {p} read by {i['used_by']}")
    for p in drive:
        if p not in IO:
            fail("P8", f"io {p} driven but not declared")
    # P10 exec
    for a in apps:
        ex = sorted(b["exec"] for b in a["blocks"])
        if ex != list(range(1, len(ex) + 1)):
            fail("P10", f"{a['name']}: exec not 1..n")
        counts["P10 feedback wires"] += sum(1 for b in a["blocks"] for s in b["pins"].values() if s.get("feedback") and "wire" in s)
    # P11 layout
    for a in apps:
        rects = []
        for b in a["blocks"]:
            if b["type"] not in CUR:
                continue
            ins = sum(1 for p in CUR[b["type"]]["pins"] if p["dir"] == "in" and not p["hidden"] and p["category"] == "Pin")
            outs = sum(1 for p in CUR[b["type"]]["pins"] if p["dir"] == "out" and not p["hidden"] and p["category"] == "Pin")
            rects.append((b["x"], b["y"], b["x"] + 165, b["y"] + 35.3 + 16 * max(ins, outs, 1), b["id"]))
        for i in range(len(rects)):
            for j in range(i + 1, len(rects)):
                r, s = rects[i], rects[j]
                if r[0] < s[2] and s[0] < r[2] and r[1] < s[3] and s[1] < r[3]:
                    fail("P11", f"{a['name']}: {r[4]} overlaps {s[4]}")
        for l in a.get("labels", []):
            for r in rects:
                if r[0] <= l["x"] < r[2] and r[1] <= l["y"] + 8 < r[3]:
                    fail("P11", f"{a['name']}: label {l['text']!r} on block {r[4]}")
    # P12 names
    typenames = {b["type"].upper() for b in REF["blocks"]} | {b["file"].rsplit("\\", 1)[-1].rsplit(".", 1)[0].upper() for b in REF["blocks"]}
    for (an, bid), b in BLK.items():
        if bid.upper() in typenames:
            info.append(f"P12 {an}/{bid}: block id equals a library type name, reserved in the tool (the build renames it {bid}_b)")
    for a in apps:
        seen = defaultdict(list)
        for b in a["blocks"]:
            seen[b["id"].upper()].append("block " + b["id"])
        for s in SV.values():
            if any(p.startswith(a["name"] + "/") for p in s["pins"]):
                seen[s["name"].upper()].append("set value " + s["name"])
        for m in MS.values():
            if m["source"].startswith(a["name"] + "/"):
                seen[m["name"].upper()].append("measure " + m["name"])
        for k, v in seen.items():
            if len(v) > 1 and any(x.startswith("block") for x in v):
                info.append(f"P12 {a['name']}: {v} (the build renames the block)")
            elif len(v) > 1:
                fail("P12", f"{a['name']}: name clash {v}")
    for k in sorted(counts):
        print(f"  {k}: {counts[k]}")
    for w in warn:
        print("  WARN " + w)
    for i in info[:12]:
        print("  INFO " + i)
    if len(info) > 12:
        print(f"  INFO ... {len(info) - 12} more")
    if bad:
        print(f"\n{len(bad)} violation(s):")
        for b in bad:
            print("  " + b)
        return 1
    print("\nOK: plan is structurally complete and consistent")
    return 0


if __name__ == "__main__":
    if len(sys.argv) < 2:
        raise SystemExit("give a program directory (a folder with program.json and plan.json), e.g. examples/dh-ex2")
    sys.exit(main(sys.argv[1]))
