#!/usr/bin/env python3
"""oufplan: write an Ouflex build plan from Python (the plan JSON that make_ouflex_build.py consumes).

A program generator (examples/<name>/make_plan.py) builds the plan with this API and writes plan.json:

    from oufplan import Plan, wire, const, setv, tprg, net, io, measure
    P = Plan("dh2", title="District heating substation, two heating circuits")
    P.io("UI 1", "TOUT", "in", "NTC", "Outdoor temperature")
    a = P.app("C1", "Heating circuit 1")
    f = a.block("tout_f", "SignalFilter", col=0, label="Outdoor temperature",
                pins={"Input": io("UI 1"), "TimeConstant": setv("TOUT_FILT_T", 600, 10, 3600, "s", "Outdoor filter time")},
                why="vendor: first-order low-pass with TimeConstant in seconds")
    f.out("Output", measure("TOUT_F", "°C", 1, "Outdoor temperature, filtered"), net("TOUT_F"))
    P.write("plan.json")

Pin sources (one per input pin; pins not given are left untouched):
    wire("blk.Pin")  output of a block in the same application
    const(v)         anonymous typed constant (Enum pins: 0/1)
    setv(NAME, default, min, max, unit, display, decimals=None)  named set value; setv(NAME) again on another pin = fan-out
    net(NAME)        signal written by another application (device-level wire between applications)
    io("UI 3")       physical input point
    tprg(NAME, default, week, display, states)  time program (schedule) on an Enum block input; week = 7 day strings
                     Monday..Sunday, 'HH:MM=v,HH:MM=v'; a state holds until the next entry, across midnight and days
Output targets: measure(...), net(NAME), io("AO 1").

Execution order = declaration order inside an application; a wire from a block declared later is flagged
feedback (one cycle old). Applications run in declaration order. Layout: blocks are stacked per column `col`
using the measured symbol height (35.3 + 16 * max(visible inputs, outputs), width 165), so nothing overlaps.
Modbus offsets are assigned in declaration order: set values table 4x, analog measures 3x, binary measures 1x
(the program config maps tables to registers).
"""
import json
import os
from collections import OrderedDict, defaultdict

BLOCKS_JSON = os.environ.get("OUMAN_BLOCKS", os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "reference", "blocks.json"))
if not os.path.exists(BLOCKS_JSON):
    raise SystemExit("block catalogue missing (" + os.path.normpath(BLOCKS_JSON) + "): run scripts/batool.sh setup, it reads the block library of your own BA Tool installation")
_REF = json.load(open(BLOCKS_JSON, encoding="utf-8"))
CURRENT = {b["type"]: b for b in _REF["blocks"] if b["current"] and not b["beta"] and b["library"] == "OumanComponents"}

SYM_W, COL_W, X0, Y0, GAP, LABEL_H = 165, 320, 60, 60, 34, 26


def sym_height(typ):
    b = CURRENT[typ]
    ins = sum(1 for p in b["pins"] if p["dir"] == "in" and not p["hidden"] and p["category"] == "Pin")
    outs = sum(1 for p in b["pins"] if p["dir"] == "out" and not p["hidden"] and p["category"] == "Pin")
    return 35.3 + 16.0 * max(ins, outs, 1)


def wire(ref):
    return {"wire": ref}


def const(v):
    return {"const": v}


def net(name):
    return {"net": name}


def io(point):
    return {"io": point}


def setv(name, default=None, min=None, max=None, unit="", display="", decimals=None, why="", local=False):
    d = {"setvalue": name}
    if default is not None:
        d["_def"] = {"default": default, "min": min, "max": max, "unit": unit, "display": display, "decimals": decimals, "why": why, "local": local}
    return d


def week(days, *, weekend=None):
    """7 day strings Monday..Sunday from one weekday string (and an optional weekend string)."""
    return [days] * 5 + [weekend if weekend is not None else days] * 2


def tprg(name, default, week, display="", states=None, why="", kind="On_Off"):
    if len(week) != 7:
        raise ValueError(f"time program {name}: week needs 7 days (Monday..Sunday)")
    for d in week:
        for e in filter(None, d.split(",")):
            t, v = e.split("=")
            h, m = (int(x) for x in t.split(":"))
            if not (0 <= h < 24 and 0 <= m < 60):
                raise ValueError(f"time program {name}: bad time {t}")
    return {"tprg": name, "_def": {"default": default, "week": list(week), "display": display, "states": states, "why": why, "type": kind}}


def measure(name, unit="", decimals=None, display="", why=""):
    return {"measure": name, "_def": {"unit": unit, "decimals": decimals, "display": display, "why": why}}


class Block:
    def __init__(self, app, bid, typ, col, pins, label, why, note):
        if typ not in CURRENT:
            raise ValueError(f"{app.name}/{bid}: {typ} is not a current OumanComponents block")
        r = CURRENT[typ]
        self.app, self.id, self.type, self.col = app, bid, typ, col
        self.d = OrderedDict(id=bid, exec=None, lib=r["library"], type=typ, version=r["version"], file=r["file"].rsplit("\\", 1)[-1],
                             x=None, y=None, label=label or "", why=why, pins=OrderedDict(), out=OrderedDict(), flags=[], note=note)
        for p, s in (pins or {}).items():
            self.pin(p, s)

    def pin(self, name, src):
        if name in self.d["pins"]:
            raise ValueError(f"{self.app.name}/{self.id}.{name}: second source")
        self.d["pins"][name] = src
        return self

    def out(self, pin, *targets):
        lst = self.d["out"].setdefault(pin, [])
        for t in targets:
            lst.append(t)
        return self

    def __getitem__(self, pin):        # b["Output"] -> "blk.Output" for wire()
        return f"{self.id}.{pin}"


class App:
    def __init__(self, plan, name, doc):
        self.plan, self.name, self.doc = plan, name, doc
        self.blocks, self.labels = [], []
        self.coly = defaultdict(lambda: Y0)

    def block(self, bid, typ, col=0, pins=None, label=None, why="", note=""):
        if any(b.id.upper() == bid.upper() for b in self.blocks):
            raise ValueError(f"{self.name}: duplicate block {bid}")
        b = Block(self, bid, typ, col, pins, label, why, note)
        x = X0 + col * COL_W
        y = self.coly[col]
        if label:
            self.labels.append({"text": label, "x": x, "y": int(y)})
            y += LABEL_H
        b.d["x"], b.d["y"] = x, int(round(y))
        self.coly[col] = y + sym_height(typ) + GAP
        self.blocks.append(b)
        return b

    def label(self, text, col=0):
        x = X0 + col * COL_W
        self.labels.append({"text": text, "x": x, "y": int(self.coly[col])})
        self.coly[col] += LABEL_H

    def skip(self, col, dy):
        self.coly[col] += dy


class Plan:
    def __init__(self, name, title="", target="Ouman Ouflex A base unit"):
        self.name, self.title, self.target = name, title, target
        self.apps, self.ios, self.io_measures, self.notes = [], OrderedDict(), [], []
        self.alarms, self.left_out = [], []

    def app(self, name, doc=""):
        a = App(self, name, doc)
        self.apps.append(a)
        return a

    def io(self, point, pin, direction, kind, description, **extra):
        if point in self.ios:
            raise ValueError(f"io {point} assigned twice")
        d = OrderedDict(point=point, pin=pin, description=description, description_fi=description, dir=direction, kind=kind)
        d.update(extra)
        self.ios[point] = d

    def measure_io(self, name, point, unit="", decimals=None, display=""):
        self.io_measures.append({"name": name, "point": point, "unit": unit, "decimals": decimals, "display": display})

    # ------------------------------------------------------------------ assemble
    def build(self):
        setvalues, measures, nets, tprgs = OrderedDict(), OrderedDict(), OrderedDict(), OrderedDict()
        sv_off = m3 = m1 = 0
        used_by, driven_by = defaultdict(list), defaultdict(list)
        apps_out = []
        for order, a in enumerate(self.apps, 1):
            idx = {b.id: i for i, b in enumerate(a.blocks, 1)}
            for b in a.blocks:
                b.d["exec"] = idx[b.id]
                for pn, s in b.d["pins"].items():
                    ref = f"{a.name}/{b.id}.{pn}"
                    if "wire" in s:
                        sb = s["wire"].split(".")[0]
                        if sb not in idx:
                            raise ValueError(f"{ref}: wire from unknown block {s['wire']}")
                        if idx[sb] >= idx[b.id]:
                            s["feedback"] = True
                            b.d["flags"].append(f"feedback:{pn}")
                    elif "setvalue" in s:
                        n = s["setvalue"]
                        if "_def" in s:
                            if n in setvalues:
                                raise ValueError(f"set value {n} defined twice")
                            dd = s.pop("_def")
                            ptype = next(p["type"] for p in CURRENT[b.type]["pins"] if p["name"] == pn)
                            sv = OrderedDict(name=n, display=dd["display"], display_fi=dd["display"], unit=dd["unit"], type=ptype,
                                             default=dd["default"], min=dd["min"] if ptype == "Float" else 0, max=dd["max"] if ptype == "Float" else 1,
                                             decimals=dd["decimals"] if ptype == "Float" else None, pins=[], fanout=None, why_settable=dd["why"])
                            if dd["local"]:
                                sv["modbus"] = None
                            else:
                                sv["modbus"] = {"table": "4x", "offset": sv_off, "writable": True}
                                sv_off += 1
                            setvalues[n] = sv
                        elif n not in setvalues:
                            raise ValueError(f"{ref}: set value {n} used before it is defined")
                        setvalues[n]["pins"].append(f"{a.name}/{b.id}.{pn}")
                    elif "tprg" in s:
                        n = s["tprg"]
                        ptype = next(p["type"] for p in CURRENT[b.type]["pins"] if p["name"] == pn)
                        if ptype != "Enum" and s["_def"]["type"] == "On_Off":
                            raise ValueError(f"{ref}: an On/Off time program needs an Enum pin, {pn} is {ptype}")
                        if n in tprgs or n in setvalues:
                            raise ValueError(f"time program {n} defined twice")
                        dd = s.pop("_def")
                        tprgs[n] = OrderedDict(name=n, display=dd["display"], type=dd["type"], default=dd["default"], week=dd["week"],
                                               states=dd["states"], pin=ref, why=dd["why"])
                    elif "io" in s:
                        used_by[s["io"]].append(ref)
                for pn, outs in b.d["out"].items():
                    ptype = next((p["type"] for p in CURRENT[b.type]["pins"] if p["name"] == pn and p["dir"] == "out"), None)
                    if ptype is None:
                        raise ValueError(f"{a.name}/{b.id}.{pn}: not an output of {b.type}")
                    for t in outs:
                        if "measure" in t:
                            n = t["measure"]
                            dd = t.pop("_def")
                            if n in measures:
                                raise ValueError(f"measure {n} twice")
                            binary = ptype == "Enum"
                            mb = {"table": "1x" if binary else "3x", "offset": m1 if binary else m3, "writable": False}
                            if binary:
                                m1 += 1
                            else:
                                m3 += 1
                            measures[n] = OrderedDict(name=n, display=dd["display"], display_fi=dd["display"], unit=dd["unit"], decimals=None if binary else dd["decimals"],
                                                      type=ptype, source=f"{a.name}/{b.id}.{pn}", modbus=mb, why=dd["why"])
                        elif "net" in t:
                            n = t["net"]
                            if n in nets:
                                raise ValueError(f"net {n} written twice")
                            nets[n] = OrderedDict(name=n, type=ptype, writer=f"{a.name}/{b.id}.{pn}", readers=[], feedback=False)
                        elif "io" in t:
                            driven_by[t["io"]].append(f"{a.name}/{b.id}.{pn}")
            apps_out.append(OrderedDict(name=a.name, order=order, doc=a.doc, blocks=[b.d for b in a.blocks], labels=a.labels))
        for m in self.io_measures:
            k = self.ios[m["point"]]["kind"]
            binary = k.startswith("contact")
            mb = {"table": "1x" if binary else "3x", "offset": m1 if binary else m3, "writable": False}
            if binary:
                m1 += 1
            else:
                m3 += 1
            measures[m["name"]] = OrderedDict(name=m["name"], display=m["display"], display_fi=m["display"], unit=m["unit"], decimals=None if binary else m["decimals"],
                                              type="Enum" if binary else "Float", source="io:" + m["point"], modbus=mb, why="physical point")
        order = {a.name: i for i, a in enumerate(self.apps)}
        for a in self.apps:
            for b in a.blocks:
                for pn, s in b.d["pins"].items():
                    if "net" in s:
                        n = s["net"]
                        if n not in nets:
                            raise ValueError(f"{a.name}/{b.id}.{pn}: net {n} has no writer")
                        nets[n]["readers"].append(f"{a.name}/{b.id}.{pn}")
                        if order[nets[n]["writer"].split("/")[0]] >= order[a.name]:
                            s["feedback"] = True
                            nets[n]["feedback"] = True
        ios = []
        for p, d in self.ios.items():
            d = OrderedDict(d)
            d["used_by"] = used_by.get(p, [])
            d["driven_by"] = driven_by.get(p, [])
            ios.append(d)
        by_type = defaultdict(int)
        for a in apps_out:
            for b in a["blocks"]:
                by_type[b["type"]] += 1
        return OrderedDict(
            format="ouflex-plan", version=2, generated_by=self.generator, program=self.name, title=self.title,
            block_reference="Ouman Ouflex BA Tool 2.130.14 (blocks.json)", target=self.target,
            legend={"pins": "{wire: 'blk.pin'} | {const: v} | {setvalue: NAME} | {tprg: NAME} | {net: NAME} | {io: 'UI 3'}; feedback: true = one cycle old",
                    "out": "per output pin a list of {net}|{io}|{measure}", "exec": "declaration order inside the application"},
            stats={"applications": len(apps_out), "blocks": sum(len(a["blocks"]) for a in apps_out), "blocks_by_type": dict(sorted(by_type.items(), key=lambda x: -x[1])),
                   "setvalues": len(setvalues), "timeprograms": len(tprgs), "measures": len(measures), "io": len(ios), "nets": len(nets)},
            applications=apps_out, nets=list(nets.values()), setvalues=list(setvalues.values()), timeprograms=list(tprgs.values()), measures=list(measures.values()), io=ios,
            alarms=self.alarms, left_out=self.left_out, notes=self.notes)

    generator = ""

    def write(self, path, generator=""):
        self.generator = generator
        plan = self.build()
        with open(path, "w", encoding="utf-8") as f:
            json.dump(plan, f, ensure_ascii=False, indent=1)
        s = plan["stats"]
        print(f"wrote {path}: {s['applications']} applications, {s['blocks']} blocks, {s['setvalues']} set values, {s['timeprograms']} time programs, {s['measures']} measures, {s['io']} I/O, {s['nets']} nets")
        return plan
