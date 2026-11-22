#!/usr/bin/env python3
"""Plan JSON -> PowerShell build scripts for Ouman Ouflex BA Tool, for any program directory.

    python pipeline/make_ouflex_build.py <program dir>

A program directory holds `program.json` (see PROGRAM_DEFAULTS below and examples/*/program.json) and the plan
(`plan.json`, or the file named by program.json "plan"). Outputs go to program.json "out" (default <dir>/build):
  apps/<APP>_<n>.ps1   application builder scripts, <= MAX_OPS operations each, run in order
  dev_1_modules.ps1    nothing to run (modules are added by the build through the Devices dialog); listed for the record
  dev_2_io.ps1         module points on the canvas, I/O configuration
  dev_3_import.ps1     import the applications in execution order
  dev_4_wires.ps1      device wires (physical points <-> applications, application -> application nets)
  modbus_set.ps1       Modbus register assignment (rule: program.json "modbus")
  expected.json        what verify_ouflex_build.py compares against (per app, device level, Modbus, plus the program config)

Generated scripts call only the helpers in scripts/win/prelude.ps1 (B, IP, W, K, SETV, SVL,
MS, LB, HU, EO, AppName, BP, IOC, IOP, IMP, DW, DEO, MBR ...); every helper is idempotent, so any script can be rerun
after a failure. The runner is scripts/build.sh <program dir>.
"""
import copy
import json
import math
import os
import shutil
import sys
from collections import defaultdict, OrderedDict

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ouflayout

HERE = os.path.dirname(os.path.abspath(__file__))
BLOCKS_JSON = os.environ.get("OUMAN_BLOCKS", os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "reference", "blocks.json"))
if not os.path.exists(BLOCKS_JSON):
    raise SystemExit("block catalogue missing (" + os.path.normpath(BLOCKS_JSON) + "): run scripts/batool.sh setup, it reads the block library of your own BA Tool installation")
MAX_OPS = 150
# ---- naming (names are case-insensitively unique; a clash opens a modal dialog in the tool) ----
# priority: set values and measures keep their plan names (they are the Modbus-visible names);
# a net or I/O interface pin that clashes with one of them gets PIN_SUFFIX; a block id that clashes gets BLOCK_SUFFIX.
PIN_SUFFIX_NET, PIN_SUFFIX_IO, BLOCK_SUFFIX = "_N", "_IO", "_b"
# ---- layout ----
# Application pages are laid out by ouflayout.py (blocks in label bands on a column grid, interface pins next to the
# blocks that use them, positions scored against the wire shapes the tool draws). Plan x/y are not used for the pages.
DEV_APP_X, DEV_APP_Y0, DEV_APP_GAP = 480, 3, 40     # application column on the device canvas
# I/O kinds: plan io.kind -> how the physical point is configured and the interface pin's value type.
# phys/devtype/min/max/unit/decimals None = leave the point as it is. An io entry may override min/max/unit/decimals.
IO_KINDS = {
    "4-20mA":     {"phys": "Analog", "devtype": "mA_SIGNAL", "min": 4, "max": 20, "unit": "mA", "decimals": 2, "params": {"Min_mA_Limit": 4, "Max_mA_Limit": 20}, "vt": "Float"},
    "NTC":        {"phys": "Analog", "devtype": "NTC10", "unit": "°C", "decimals": 1, "vt": "Float"},
    "0-10V":      {"phys": "Analog", "devtype": "TX_IN", "min": 0, "max": 10, "unit": "V", "decimals": 1, "vt": "Float"},
    "pulse":      {"phys": "Pulse", "devtype": "PULSE", "unit": "pulssia", "decimals": 0, "vt": "Float"},   # UI 13..16, DI 1/2: cumulative count
    "contact NO": {"phys": "Digital", "vt": "Enum"},
    "contact NC": {"phys": "Digital", "vt": "Enum"},
    "relay":      {"vt": "Enum"},
    "triac":      {"vt": "Enum"},        # TR n used as an on/off output
    "AO 0-10V":   {"vt": "Float"},
}
PROGRAM_DEFAULTS = {
    "plan": "plan.json",
    "out": "build",
    # Windows paths: apps = application files; project = the built project;
    # base = "new" (a new project made by code) or the pristine empty project copied to `project` before the device
    # stage; deliver = optional final copy
    "paths": {},
    "modules": [],          # bus I/O modules: {template, connector, name, address, prefix, channels, object, x, y0, step}
    "polarity": "Normal",   # physical input polarity (NC contacts are inverted in logic, so Normal)
    "modbus": {"base": 1000, "areas": {"4x": 0, "0x": 50, "3x": 100, "1x": 150}, "formats": {"Int32": "S32", "default": "S16"}, "local_off_bus": True},
    "required_fill": {},    # {type: {pin: value}}: constants for inputs CheckAll requires but the plan leaves untouched
    "io_kinds": {},
    # how a net (a signal from one application to another) travels:
    #   "wire"   interface output pin -> device wire -> interface input pin (every net is a line on the device page)
    #   "global" the writer's output carries a measure marked "Device level global"; each reader has a global pin
    #            (g_<name>) that refers to it by name. No interface pins, no device wires for nets.
    "net_transport": "wire",
}


def load_program(pdir):
    pdir = os.path.abspath(pdir)
    cfg = copy.deepcopy(PROGRAM_DEFAULTS)
    pj = os.path.join(pdir, "program.json")
    if os.path.exists(pj):
        user = json.load(open(pj, encoding="utf-8"))
        for k, v in user.items():
            if isinstance(v, dict) and isinstance(cfg.get(k), dict):
                cfg[k].update(v)
            else:
                cfg[k] = v
    cfg["dir"] = pdir
    cfg["plan_path"] = os.path.normpath(os.path.join(pdir, cfg["plan"]))
    cfg["out_path"] = os.path.normpath(os.path.join(pdir, cfg["out"]))
    cfg.setdefault("name", os.path.basename(pdir))
    for k in ("apps", "project", "base"):
        if k not in cfg["paths"]:
            raise SystemExit(f"program.json: paths.{k} missing")
    return cfg


def ps(s):
    return "'" + str(s).replace("'", "''") + "'"


def num(v):
    if isinstance(v, bool):
        return "1" if v else "0"
    if isinstance(v, int):
        return str(v)
    r = repr(float(v))
    return r[:-2] if r.endswith(".0") else r


def nul(v):
    return "$null" if v is None else (num(v) if isinstance(v, (int, float)) else str(v))


def dec_of_scale(scale):
    return int(round(math.log10(scale))) if scale else 0


def disp(o, *keys):
    for k in keys:
        if o.get(k):
            return o[k]
    return ""


def write_bom(path, text):
    with open(path, "w", encoding="utf-8-sig", newline="\r\n") as f:   # Windows PowerShell 5.1 reads BOM-less files as ANSI
        f.write(text)


def chunks(ops):
    out, cur = [], []
    for o in ops:
        cur.append(o)
        if len(cur) >= MAX_OPS:
            out.append(cur); cur = []
    if cur:
        out.append(cur)
    return out


class Gen:
    def __init__(self, cfg):
        self.cfg = cfg
        self.P = json.load(open(cfg["plan_path"], encoding="utf-8"))
        P = self.P
        self.kinds = dict(IO_KINDS); self.kinds.update(cfg["io_kinds"])
        self.apps = P["applications"]
        self.IO = {i["point"]: i for i in P["io"]}
        self.SETV = {s["name"]: s for s in P["setvalues"]}
        self.MEAS = {m["name"]: m for m in P["measures"]}
        self.NETS = {n["name"]: n for n in P["nets"]}
        self.modules = cfg["modules"]
        reserved = {n.upper() for n in list(self.SETV) + list(self.MEAS)}
        self.net_pin = {n: (n + PIN_SUFFIX_NET if n.upper() in reserved else n) for n in self.NETS}
        self.io_pin = {}
        for p, i in self.IO.items():
            v = i["pin"]
            self.io_pin[p] = v + PIN_SUFFIX_IO if v.upper() in reserved else v
        pin_names = {v.upper() for v in list(self.net_pin.values()) + list(self.io_pin.values())}
        # a block named like a library block type ('pid' for Pid) opens the modal "Variable name pid is reserved" (seen 2026-11-10)
        ref = json.load(open(BLOCKS_JSON, encoding="utf-8"))["blocks"]
        pin_names |= {b["type"].upper() for b in ref} | {b["file"].rsplit("\\", 1)[-1].rsplit(".", 1)[0].upper() for b in ref}
        # global transport: one named, device-unique object per writer pin. A measure the plan already puts on that pin
        # is reused (a net that is an alias of that measure is read under the measure's name); otherwise a new measure named like the
        # net (with PIN_SUFFIX_NET where a set value or measure owns the name), kept off Modbus.
        self.use_globals = cfg.get("net_transport") == "global"
        self.net_global, self.new_global = {}, OrderedDict()      # net -> global name; name -> (writer, net)
        if self.use_globals:
            on_pin = {}
            for m in P["measures"]:
                on_pin.setdefault(m["source"], m["name"])
            for n in P["nets"]:
                w = n["writer"]
                if w not in on_pin:
                    on_pin[w] = self.net_pin[n["name"]]
                    self.new_global[on_pin[w]] = (w, n)
                self.net_global[n["name"]] = on_pin[w]
            seen = {}
            for g, w in ((g, n["writer"]) for n in P["nets"] for g in [self.net_global[n["name"]]]):
                if seen.setdefault(g.upper(), w) != w:
                    raise SystemExit(f"global name {g} would be defined on two outputs: {seen[g.upper()]} and {w}")
        self.block_name = {}
        for a in self.apps:
            for b in a["blocks"]:
                bid = b["id"]
                self.block_name[(a["name"], bid)] = bid + BLOCK_SUFFIX if (bid.upper() in reserved or bid.upper() in pin_names) else bid

    # physical point -> object name on the device canvas (module channels are named by the module)
    def obj(self, point):
        for m in self.modules:
            if point.startswith(m["prefix"]):
                return m["object"].format(int(point[len(m["prefix"]):]))
        return point

    def kind(self, point):
        k = self.IO[point]["kind"]
        if k not in self.kinds:
            raise SystemExit(f"io {point}: unknown kind {k!r} (add it to program.json io_kinds)")
        return self.kinds[k]

    def io_vt(self, point):
        return self.kind(point)["vt"]

    def bref(self, app, ref):           # 'blk.pin' in plan ids -> tool names
        blk, pin = ref.rsplit(".", 1)
        return f"{self.block_name[(app, blk)]}.{pin}"

    def net_name(self, net):            # name of the pin a block uses for a net (interface pin, or global)
        return self.net_global[net] if self.use_globals else self.net_pin[net]

    def in_name(self, src):
        return self.net_name(src["net"]) if "net" in src else self.io_pin[src["io"]] if "io" in src else None

    def out_name(self, src):            # with globals a net needs no pin on the writer's page: the measure symbol is the exit
        if "net" in src and self.use_globals:
            return None
        return self.in_name(src)

    def layout(self, a, log=None):
        lj = os.path.join(self.cfg["dir"], "layout.json")       # optional hand layout per application (ouflayout.layout_manual)
        man = json.load(open(lj, encoding="utf-8")).get(a["name"]) if os.path.exists(lj) else None
        return ouflayout.layout_app(a, self.in_name, self.out_name, self.cfg["required_fill"], log=log, manual=man)

    def build_app(self, a):
        app = a["name"]
        ops = []
        lay = self.layout(a)
        pos = lay["blocks"]
        ops.append(("app", f"AppName $cv {ps(app)} {ps(disp(a, 'display', 'name'))}"))
        exp = {"name": app, "blocks": {}, "wires": {}, "consts": {}, "setvalue_pins": {}, "setvalues": {}, "measure_pins": {},
               "measures": {}, "inpins": {}, "outpins": {}, "globalpins": {}, "globals": [], "labels": [], "exec": [], "layout": lay["stats"]}
        keep = defaultdict(list)
        for b in a["blocks"]:
            for pn, src in b["pins"].items():
                if "setvalue" in src:
                    keep[b["id"]].append(pn)
            for pn, outs in b["out"].items():
                if any("measure" in o or ("net" in o and self.use_globals) for o in outs):
                    keep[b["id"]].append(pn)
        for b in sorted(a["blocks"], key=lambda b: b["exec"]):
            n = self.block_name[(app, b["id"])]
            k = "@(" + ",".join(ps(x) for x in keep[b["id"]]) + ")" if keep[b["id"]] else "@()"
            x, y = pos[b["id"]]
            ops.append(("block", f"B $cv {ps(n)} {ps(b['type'])} {x} {y} {k}"))
            exp["blocks"][n] = {"type": b["type"], "lib": b["file"].rsplit(".", 1)[0], "version": b["version"], "x": x, "y": y, "exec": b["exec"]}
            exp["exec"].append(n)
        for l in lay["labels"]:
            ops.append(("label", f"LB $cv {ps(l['text'])} {l['x']} {l['y']}"))
            exp["labels"].append({"text": l["text"], "x": l["x"], "y": l["y"]})
        inpins, outpins = OrderedDict(), OrderedDict()
        for b in sorted(a["blocks"], key=lambda b: b["exec"]):
            for pn, src in b["pins"].items():
                nm = self.in_name(src)
                if nm and nm not in inpins:
                    inpins[nm] = self.NETS[src["net"]]["type"] if "net" in src else self.io_vt(src["io"])
            for pn, outs in b["out"].items():
                for o in outs:
                    nm = self.out_name(o)
                    if nm and nm not in outpins:
                        outpins[nm] = (self.NETS[o["net"]]["type"] if "net" in o else self.io_vt(o["io"]), self.bref(app, f"{b['id']}.{pn}"))
        gl_in = {self.net_global[n] for n in self.net_global} if self.use_globals else set()
        io_in = set(self.io_pin.values())
        for nm, vt in inpins.items():
            x, y = lay["inpins"][nm]
            if nm in gl_in and nm not in io_in:
                ops.append(("globalpin", f"GLP $cv {ps(nm)} {x} {y}"))
                exp["globalpins"][nm] = {"x": x, "y": y}
                continue
            ops.append(("inpin", f"IP $cv 'in' {ps(nm)} {ps(vt)} {x} {y}"))
            exp["inpins"][nm] = {"type": vt, "x": x, "y": y}
        for nm, (vt, src) in outpins.items():
            x, y = lay["outpins"][nm]
            ops.append(("outpin", f"IP $cv 'out' {ps(nm)} {ps(vt)} {x} {y}"))
            exp["outpins"][nm] = {"type": vt, "src": src, "x": x, "y": y}
        fill = self.cfg["required_fill"]
        for b in sorted(a["blocks"], key=lambda b: b["exec"]):
            for pn, src in b["pins"].items():
                dst = self.bref(app, f"{b['id']}.{pn}")
                if "wire" in src:
                    s = self.bref(app, src["wire"])
                    ops.append(("wire", f"W $cv {ps(s)} {ps(dst)}"))
                    exp["wires"][dst] = s
                elif "net" in src or "io" in src:
                    nm = self.in_name(src)
                    pre = "%" if nm in exp["globalpins"] else "@"
                    ops.append(("wire", f"W $cv {ps(pre + nm)} {ps(dst)}"))
                    exp["wires"][dst] = pre + nm
                elif "const" in src:
                    ops.append(("const", f"K $cv {ps(dst)} {num(src['const'])}"))
                    exp["consts"][dst] = src["const"]
                elif "setvalue" in src:
                    exp["setvalue_pins"][dst] = src["setvalue"]
            for pn, v in fill.get(b["type"], {}).items():
                if pn not in b["pins"]:
                    dst = self.bref(app, f"{b['id']}.{pn}")
                    ops.append(("const", f"K $cv {ps(dst)} {num(v)}"))
                    exp["consts"][dst] = v
                    exp.setdefault("deviations", []).append(f"{dst}: required by the tool, untouched in the plan -> constant {v}")
        for s in self.P["setvalues"]:
            pins = [p for p in s["pins"] if p.startswith(app + "/")]
            if not pins:
                continue
            for i, p in enumerate(pins):
                dst = self.bref(app, p.split("/", 1)[1])
                if i == 0:
                    mn, mx, unit, dec = (s["min"], s["max"], s["unit"], s["decimals"]) if s["type"] == "Float" else (0, 1, "", None)
                    ops.append(("setvalue", f"SETV $cv {ps(dst)} {ps(s['name'])} {num(s['default'])} {num(mn)} {num(mx)} {ps(unit)} {ps(disp(s, 'display', 'display_fi'))} {nul(dec)}"))
                else:
                    ops.append(("setvalue_link", f"SVL $cv {ps(dst)} {ps(s['name'])}"))
            exp["setvalues"][s["name"]] = {"type": s["type"], "default": s["default"], "min": s["min"], "max": s["max"], "unit": s["unit"],
                                           "decimals": s["decimals"], "pins": [self.bref(app, p.split("/", 1)[1]) for p in pins]}
        for b in a["blocks"]:
            for pn, outs in b["out"].items():
                src = self.bref(app, f"{b['id']}.{pn}")
                for o in outs:
                    if "measure" in o:
                        m = self.MEAS[o["measure"]]
                        dec = self.measure_decimals(m)
                        ops.append(("measure", f"MS $cv {ps(src)} {ps(m['name'])} {ps(m.get('unit') or '')} {nul(dec)} {ps(disp(m, 'display', 'display_fi'))}"))
                        exp["measures"][m["name"]] = {"src": src, "unit": m.get("unit") or "", "decimals": dec}
                        exp["measure_pins"][src] = m["name"]
                    elif "net" in o and self.use_globals:
                        g = self.net_global[o["net"]]
                        if g in self.new_global and g not in exp["measures"]:
                            ops.append(("measure", f"MS $cv {ps(src)} {ps(g)} '' $null {ps(self.NETS[o['net']].get('doc_fi') or g)}"))
                            exp["measures"][g] = {"src": src, "unit": "", "decimals": None}
                            exp["measure_pins"][src] = g
                        if g not in exp["globals"]:
                            exp["globals"].append(g)
                    elif "net" in o or "io" in o:
                        nm = self.net_pin[o["net"]] if "net" in o else self.io_pin[o["io"]]
                        ops.append(("wire_out", f"W $cv {ps(src)} {ps('@' + nm)}"))
        for g in exp["globals"]:            # after every measure exists (a reused one is made in the loop above, in any order)
            ops.append(("global", f"MG $cv {ps(g)}"))
        ops.append(("exec", "EO $cv @(" + ",".join(ps(x) for x in exp["exec"]) + ")"))
        ops.append(("hide", "HU $cv"))
        return ops, exp

    def measure_boolean(self, m):
        if m.get("type"):
            return m["type"] == "Enum"
        mb = m.get("modbus") or {}
        return (m.get("unit") or "") == "" and (mb.get("area") in ("discrete_input", "coil") or mb.get("table") in ("1x", "0x"))

    def measure_decimals(self, m):
        if self.measure_boolean(m):
            return None
        if "decimals" in m and m["decimals"] is not None:
            return m["decimals"]
        return dec_of_scale((m.get("modbus") or {}).get("scale"))

    def run(self):
        cfg, P = self.cfg, self.P
        OUT = cfg["out_path"]
        os.makedirs(OUT, exist_ok=True)
        shutil.rmtree(os.path.join(OUT, "apps"), ignore_errors=True)
        for f in os.listdir(OUT):
            if f.endswith(".ps1") or f == "expected.json":
                os.remove(os.path.join(OUT, f))
        os.makedirs(os.path.join(OUT, "apps"))
        expected = {"program": {k: cfg[k] for k in ("name", "paths", "modules", "modbus", "polarity")}, "plan_sha_source": P.get("source_hash_sha256"),
                    "plan": os.path.relpath(cfg["plan_path"], HERE), "apps": OrderedDict(), "device": {}, "naming": {
                        "net_pin": {k: v for k, v in self.net_pin.items() if k != v}, "io_pin": self.io_pin,
                        "block": {f"{a}/{b}": n for (a, b), n in self.block_name.items() if b != n}}}
        planname = os.path.basename(cfg["plan_path"])
        manifest = []
        for a in sorted(self.apps, key=lambda a: a["order"]):
            ops, exp = self.build_app(a)
            expected["apps"][a["name"]] = exp
            cs = chunks(ops)
            files = []
            for i, c in enumerate(cs, 1):
                fn = f"{a['name']}_{i}.ps1"
                body = [f"# generated by pipeline/make_ouflex_build.py from {planname} - {a['name']} part {i}/{len(cs)} ({len(c)} ops)",
                        "$cv=AppCanvas; if(-not $cv){ 'FAIL no application canvas'; return }"]
                body += [t for _, t in c]
                body.append(f"Build-Summary {ps(a['name'] + '_' + str(i))}")
                write_bom(os.path.join(OUT, "apps", fn), "\n".join(body) + "\n")
                files.append(fn)
            manifest.append({"app": a["name"], "order": a["order"], "scripts": files, "ops": len(ops)})
        # ---- device level ----
        pts = []
        for p, i in self.IO.items():
            k = dict(self.kind(p))
            for f in ("min", "max", "unit", "decimals"):
                if f in i:
                    k[f] = i[f]
            pts.append((p, self.obj(p), i, k))
        lines = ["# device level 1/3: module points on the canvas, I/O configuration", "$cv=TopCanvas; if(-not $cv){ 'FAIL no device canvas'; return }"]
        mod_points = []
        for m in self.modules:
            for n in range(1, m["channels"] + 1):
                lines.append(f"BP $cv {ps(m['object'].format(n))} {m['x']} {m['y0'] + m['step'] * (n - 1)}")
                mod_points.append(m["object"].format(n))
        for p, obj, i, k in pts:
            lines.append(f"IOC $cv {ps(obj)} {ps(k.get('phys') or '')} {ps(k.get('devtype') or '')} {nul(k.get('min'))} {nul(k.get('max'))} {ps(k.get('unit') or '')} {nul(k.get('decimals'))} {ps(disp(i, 'description', 'description_fi'))} {ps(cfg['polarity'] if i['dir'] == 'in' else '')}")
            for pk, v in k.get("params", {}).items():
                lines.append(f"IOP $cv {ps(obj)} {ps(pk)} {num(v)}")
            if i["dir"] == "out":
                lines.append(f"IOA $cv {ps(obj)}")       # a point left in manual ignores the program (TR n are in manual in a new project)
        lines.append("Build-Summary 'dev_io'")
        write_bom(os.path.join(OUT, "dev_2_io.ps1"), "\n".join(lines) + "\n")
        order = [a["name"] for a in sorted(self.apps, key=lambda a: a["order"])]
        lines = ["# device level 2/3: import the applications in execution order", "$cv=TopCanvas; if(-not $cv){ 'FAIL no device canvas'; return }",
                 f"$global:DevY={DEV_APP_Y0}"]
        lj = os.path.join(cfg["dir"], "layout.json")          # optional: "_device": {"apps": {APP: [x, y]}} places the application symbols
        devpos = (json.load(open(lj, encoding="utf-8")).get("_device", {}).get("apps", {})) if os.path.exists(lj) else {}
        for a in order:
            if a in devpos:
                lines.append(f"$global:DevY={int(devpos[a][1])}")
            lines.append(f"IMP $cv {ps(a)} {ps(cfg['paths']['apps'] + chr(92) + a + '.ouear')} {int(devpos[a][0]) if a in devpos else DEV_APP_X} {DEV_APP_GAP}")
        lines.append("DEO $cv @(" + ",".join(ps(a) for a in order) + ")")
        lines.append("Build-Summary 'dev_import'")
        write_bom(os.path.join(OUT, "dev_3_import.ps1"), "\n".join(lines) + "\n")
        lines = ["# device level 3/3: wires (physical points <-> applications, application -> application nets)", "$cv=TopCanvas; if(-not $cv){ 'FAIL no device canvas'; return }"]
        dwires = {}
        for p, obj, i, _ in pts:
            if i["dir"] == "in":
                for app in sorted({u.split("/")[0] for u in i["used_by"]}):
                    lines.append(f"DW $cv {ps('#' + obj)} {ps(app + '.' + self.io_pin[p])}")
                    dwires[f"{app}.{self.io_pin[p]}"] = "#" + obj
            else:
                for d in i["driven_by"]:
                    app = d.split("/")[0]
                    lines.append(f"DW $cv {ps(app + '.' + self.io_pin[p])} {ps('#' + obj)}")
                    dwires["#" + obj] = f"{app}.{self.io_pin[p]}"
        greaders = {}
        for n in P["nets"]:
            wapp = n["writer"].split("/")[0]
            if self.use_globals:
                for rapp in sorted({r.split("/")[0] for r in n["readers"]}):
                    greaders.setdefault(rapp, {})[self.net_global[n["name"]]] = wapp
                continue
            for rapp in sorted({r.split("/")[0] for r in n["readers"]}):
                lines.append(f"DW $cv {ps(wapp + '.' + self.net_pin[n['name']])} {ps(rapp + '.' + self.net_pin[n['name']])}")
                dwires[f"{rapp}.{self.net_pin[n['name']]}"] = f"{wapp}.{self.net_pin[n['name']]}"
        lines.append("Build-Summary 'dev_wires'")
        write_bom(os.path.join(OUT, "dev_4_wires.ps1"), "\n".join(lines) + "\n")
        expected["device"] = {
            "apps": order, "wires": dwires,
            "io": {obj: {"point": p, "phys": k.get("phys"), "devtype": k.get("devtype"), "min": k.get("min"), "max": k.get("max"), "unit": k.get("unit"),
                         "decimals": k.get("decimals"), "params": k.get("params", {}), "display": disp(i, "description", "description_fi"),
                         "polarity": cfg["polarity"] if i["dir"] == "in" else None} for p, obj, i, k in pts},
            "module_points": mod_points,
            "global_readers": greaders,          # reader application -> {global name: application that defines it}
            "auto_outputs": [obj for p, obj, i, k in pts if i["dir"] == "out"],
        }
        # ---- Modbus ----
        mbc = cfg["modbus"]
        fmts = mbc["formats"]
        mb = []
        lines = ["# Modbus registers (rule: program.json modbus = base + area offset per plan table + plan offset)", "$cv=TopCanvas; if(-not $cv){ 'FAIL no device canvas'; return }"]
        for s in P["setvalues"]:
            app = s["pins"][0].split("/")[0]
            m = s.get("modbus")
            if m:
                reg = mbc["base"] + mbc["areas"][m["table"]] + m["offset"]
                fmt = "U16" if s["type"] == "Enum" else fmts.get(m.get("format") or "default", fmts["default"])
                lines.append(f"MBR $cv {ps(app)} {ps(s['name'])} {reg} {ps(fmt)} $true")
                mb.append({"name": s["name"], "kind": "setvalue", "spec_table": m["table"], "spec_offset": m["offset"], "spec_address": m.get("address"),
                           "spec_scale": m.get("scale", 1), "register": reg, "format": fmt, "decimals": s["decimals"] if s["type"] == "Float" else 0, "writable": True})
            elif mbc.get("local_off_bus", True):
                lines.append(f"MBR $cv {ps(app)} {ps(s['name'])} $null $null $false")
                mb.append({"name": s["name"], "kind": "setvalue", "spec_table": None, "register": None, "using": False})
        if mbc.get("local_off_bus", True):
            for g, (w, n) in self.new_global.items():
                lines.append(f"MBR $cv {ps(w.split('/')[0])} {ps(g)} $null $null $false")
                mb.append({"name": g, "kind": "net", "spec_table": None, "register": None, "using": False})
        for m in P["measures"]:
            mm = m["modbus"]
            reg = mbc["base"] + mbc["areas"][mm["table"]] + mm["offset"]
            boolean = mm["table"] in ("1x", "0x")
            fmt = "U16" if boolean else fmts.get(mm.get("format") or "default", fmts["default"])
            if m["source"].startswith("io:"):
                lines.append(f"MBR $cv '' {ps(self.obj(m['source'][3:]))} {reg} {ps(fmt)} $true")
            else:
                lines.append(f"MBR $cv {ps(m['source'].split('/')[0])} {ps(m['name'])} {reg} {ps(fmt)} $true")
            mb.append({"name": m["name"], "kind": "measure", "source": m["source"], "object": self.obj(m["source"][3:]) if m["source"].startswith("io:") else m["name"],
                       "spec_table": mm["table"], "spec_offset": mm["offset"], "spec_address": mm.get("address"), "spec_scale": mm.get("scale", 1),
                       "spec_format": mm.get("format", "Int16" if not boolean else "bit"), "register": reg, "format": fmt,
                       "decimals": 0 if boolean else self.measure_decimals(m), "writable": False})
        lines.append("Build-Summary 'modbus'")
        write_bom(os.path.join(OUT, "modbus_set.ps1"), "\n".join(lines) + "\n")
        expected["modbus"] = mb
        expected["modbus_rule"] = {"base": mbc["base"], "areas": mbc["areas"]}
        expected["manifest"] = manifest
        with open(os.path.join(OUT, "expected.json"), "w", encoding="utf-8") as f:
            json.dump(expected, f, ensure_ascii=False, indent=1)
        if self.use_globals:
            self.write_signals(os.path.join(OUT, "signals.md"))
        tot = sum(m["ops"] for m in manifest)
        print(f"wrote {OUT}: {sum(len(m['scripts']) for m in manifest)} app scripts ({tot} ops), 3 device scripts, modbus_set.ps1, expected.json")
        for m in manifest:
            print(f"  {m['app']}: {m['ops']} ops in {len(m['scripts'])} script(s)")
        print("  renamed:", expected["naming"]["net_pin"], expected["naming"]["block"])


def _signals(self, path):
    """Cross-reference of the signals that travel between applications as globals: they are not lines on any page."""
    P = self.P
    rows = OrderedDict()
    for n in P["nets"]:
        g = self.net_global[n["name"]]
        r = rows.setdefault(g, {"writer": n["writer"], "type": n["type"], "nets": [], "readers": [], "doc": n.get("doc_fi") or "", "fb": False})
        r["nets"].append(n["name"]); r["fb"] = r["fb"] or bool(n.get("feedback"))
        for x in n["readers"]:
            if x not in r["readers"]:
                r["readers"].append(x)
    L = [f"# {self.cfg['name']}: signals between applications (device level globals)", "",
         "Generated by `ouflex/make_ouflex_build.py`. Each signal is a measure on the writer's output with",
         "\"Device level global\" = True; a reader refers to it by name through a global pin `g_<name>`.",
         "These connections are not drawn on the device page. *Plan net* = the name the plan and the",
         "functional description use for it (several nets can be the same signal).", "",
         "| Global | Type | Written by | Plan net(s) | Read by | Note |", "|---|---|---|---|---|---|"]
    for g, r in rows.items():
        apps = OrderedDict()
        for x in r["readers"]:
            a, pin = x.split("/")
            apps.setdefault(a, []).append(pin)
        rd = "; ".join(f"{a}: " + ", ".join(f"`{p}`" for p in pins) for a, pins in apps.items())
        note = ("new measure, off Modbus" if g in self.new_global else "existing measure") + (" · one cycle old (feedback)" if r["fb"] else "")
        L.append(f"| `{g}` | {r['type']} | `{r['writer']}` | {', '.join(r['nets'])} | {rd} | {note} |")
    L += ["", f"{len(rows)} globals for {len(P['nets'])} plan nets; {len(self.new_global)} new measures."]
    with open(path, "w", encoding="utf-8") as f:
        f.write("\n".join(L) + "\n")


Gen.write_signals = _signals


def main():
    if len(sys.argv) < 2:
        raise SystemExit("give a program directory (a folder with program.json and plan.json), e.g. examples/dh-ex2")
    Gen(load_program(sys.argv[1])).run()


if __name__ == "__main__":
    main()
