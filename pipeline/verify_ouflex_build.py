#!/usr/bin/env python3
"""Compare what BA Tool read back (dumps from Dump-App / Dump-Device / Dump-Modbus / projdump, taken after a reload)
against <out>/expected.json, which make_ouflex_build.py derives from the program's plan alone.

  verify_ouflex_build.py <program dir> app <APP> <dump.txt>      exit 1 and list every difference
  verify_ouflex_build.py <program dir> device <dump.txt>
  verify_ouflex_build.py <program dir> modbus <dump.txt> <map.tsv> prints the plan-vs-built table (markdown) too
  verify_ouflex_build.py <program dir> file <file.dump.txt>       the saved Device.bin read without the tool
The program.json "out" of <program dir> names the folder holding expected.json.
"""
import json, os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
MODES = ("app", "device", "modbus", "file")
if len(sys.argv) < 3 or sys.argv[1] in MODES:
    raise SystemExit("usage: verify_ouflex_build.py <program dir> app|device|modbus|file ...; give a program directory (a folder with program.json and plan.json), e.g. examples/dh-ex2")
PDIR = os.path.abspath(sys.argv.pop(1))
_cfg = json.load(open(os.path.join(PDIR, "program.json"), encoding="utf-8")) if os.path.exists(os.path.join(PDIR, "program.json")) else {}
EXP = json.load(open(os.path.join(PDIR, _cfg.get("out", "build"), "expected.json"), encoding="utf-8"))


def rows(path, tag=None):
    out = []
    for line in open(path, encoding="utf-8-sig"):
        line = line.rstrip("\r\n")
        if not line:
            continue
        f = line.split("|")
        if tag is None or f[0] == tag:
            out.append(f)
    return out


def fnum(s):
    try:
        return float(str(s).replace(",", "."))
    except ValueError:
        return None


def same(a, b):
    x, y = fnum(a), fnum(b)
    if x is not None and y is not None:
        return abs(x - y) < 1e-6
    return str(a) == str(b)


def verify_app(app, path):
    e = EXP["apps"][app]
    d = rows(path)
    diffs, notes = [], []
    by = {}
    for f in d:
        by.setdefault(f[0], []).append(f)
    text = open(path, encoding="utf-8-sig").read()
    if "check=True" not in text:
        diffs.append("CheckAll is not True: " + " / ".join(l.strip() for l in text.splitlines() if l.startswith(("check=", "  msg"))))
    a = by.get("APP", [[None, None]])[0]
    if a[1] != app:
        diffs.append(f"application technical name {a[1]!r}, expected {app!r}")
    # blocks
    got = {f[1]: f for f in by.get("B", [])}
    for n, b in e["blocks"].items():
        g = got.get(n)
        if not g:
            diffs.append(f"block {n} missing"); continue
        if g[2] != "OumanComponents." + b["lib"]: diffs.append(f"block {n} type {g[2]} != {b['lib']}")
        if g[3] != b["version"]: diffs.append(f"block {n} version {g[3]} != {b['version']}")
        if (int(g[4]), int(g[5])) != (b["x"], b["y"]): diffs.append(f"block {n} at {g[4]},{g[5]} != {b['x']},{b['y']}")
        if int(g[6]) != b["exec"]: diffs.append(f"block {n} exec {g[6]} != {b['exec']}")
    for n in got:
        if n not in e["blocks"]: diffs.append(f"extra block {n}")
    # overlaps between block symbols
    # An application that reads globals is dumped from the session that built it (it cannot be reopened alone), and there
    # the symbols still have their full height: hidden pins shrink a block only on reload. The overlap test would be wrong.
    session_read = bool(e.get("globalpins"))
    if session_read: notes.append("read from the building session (reads globals): block overlap not tested, sizes are pre-reload")
    bx = [] if session_read else [(n, int(g[4]), int(g[5]), int(g[7]), int(g[8])) for n, g in got.items()]
    for i in range(len(bx)):
        for j in range(i + 1, len(bx)):
            n1, x1, y1, w1, h1 = bx[i]; n2, x2, y2, w2, h2 = bx[j]
            if x1 < x2 + w2 and x2 < x1 + w1 and y1 < y2 + h2 and y2 < y1 + h1:
                diffs.append(f"blocks overlap: {n1} and {n2}")
    # wires (input side), constants, set value pins
    w = {f[1]: f for f in by.get("W", [])}
    for dst, src in e["wires"].items():
        g = w.get(dst)
        if not g: diffs.append(f"wire {src} -> {dst} missing"); continue
        if g[2] != src: diffs.append(f"wire into {dst} comes from {g[2]}, expected {src}")
        if g[3] == "lines=0": diffs.append(f"wire into {dst} has no drawn line")
    for dst in w:
        if dst not in e["wires"]: diffs.append(f"extra wire into {dst} from {w[dst][2]}")
    k = {f[1]: f[2] for f in by.get("K", [])}
    for dst, v in e["consts"].items():
        if dst not in k: diffs.append(f"constant {dst}={v} missing")
        elif not same(k[dst], v): diffs.append(f"constant {dst}={k[dst]}, expected {v}")
    lib_default = {dst: v for dst, v in k.items() if dst not in e["consts"]}
    notes.append(f"{len(lib_default)} library default constants on pins the plan leaves untouched")
    svp = {f[1]: f[2] for f in by.get("SVP", [])}
    for dst, n in e["setvalue_pins"].items():
        if svp.get(dst) != n: diffs.append(f"set value pin {dst} -> {svp.get(dst)}, expected {n}")
    for dst in svp:
        if dst not in e["setvalue_pins"]: diffs.append(f"extra set value {svp[dst]} on {dst}")
    # set values
    sv = {f[1]: f for f in by.get("SV", [])}
    for n, s in e["setvalues"].items():
        g = sv.get(n)
        if not g: diffs.append(f"set value {n} missing"); continue
        kind = "CBinarySetpointObject" if s["type"] == "Enum" else "CAnalogSetpointObject"
        if g[2] != kind: diffs.append(f"set value {n} is {g[2]}, expected {kind}")
        if not same(g[3], s["default"]): diffs.append(f"set value {n} default {g[3]} != {s['default']}")
        if s["type"] == "Float":
            if not same(g[4], s["min"]) or not same(g[5], s["max"]): diffs.append(f"set value {n} range {g[4]}..{g[5]} != {s['min']}..{s['max']}")
            if g[6] != s["unit"]: diffs.append(f"set value {n} unit {g[6]!r} != {s['unit']!r}")
            if not same(g[7], s["decimals"]): diffs.append(f"set value {n} decimals {g[7]} != {s['decimals']}")
    for n in sv:
        if n not in e["setvalues"]: diffs.append(f"extra set value object {n}")
    # measures
    msp = {f[1]: f[2] for f in by.get("MSP", [])}
    for src, n in e["measure_pins"].items():
        if msp.get(src) != n: diffs.append(f"measure on {src} is {msp.get(src)}, expected {n}")
    for src in msp:
        if src not in e["measure_pins"]: diffs.append(f"extra measure {msp[src]} on {src}")
    ms = {f[1]: f for f in by.get("MS", [])}
    for n, m in e["measures"].items():
        g = ms.get(n)
        if not g: diffs.append(f"measure {n} missing"); continue
        if m["decimals"] is not None:
            if g[3] != m["unit"]: diffs.append(f"measure {n} unit {g[3]!r} != {m['unit']!r}")
            if not same(g[4], m["decimals"]): diffs.append(f"measure {n} decimals {g[4]} != {m['decimals']}")
    for n in ms:
        if n not in e["measures"]: diffs.append(f"extra measure object {n}")
    # interface pins
    ip = {f[1]: f for f in by.get("IP", [])}
    for n, p in e["inpins"].items():
        g = ip.get(n)
        if not g or g[2] != "EditorInputPin": diffs.append(f"interface input {n} missing"); continue
        if g[3] != p["type"]: diffs.append(f"interface input {n} type {g[3]} != {p['type']}")
    for n, p in e["outpins"].items():
        g = ip.get(n)
        if not g or g[2] != "EditorOutputPin": diffs.append(f"interface output {n} missing"); continue
        if g[3] != p["type"]: diffs.append(f"interface output {n} type {g[3]} != {p['type']}")
        if g[4] != p["src"]: diffs.append(f"interface output {n} fed by {g[4]!r}, expected {p['src']}")
    for n in ip:
        if n not in e["inpins"] and n not in e["outpins"]: diffs.append(f"extra interface pin {n}")
    # global pins and global objects
    gp = {f[1]: f for f in by.get("GP", [])}
    for n in e.get("globalpins", {}):
        if n not in gp: diffs.append(f"global pin g_{n} missing")
        elif gp[n][4] == "lines=0": diffs.append(f"global pin g_{n} has no drawn line")
    for n in gp:
        if n not in e.get("globalpins", {}): diffs.append(f"extra global pin g_{n}")
    gl = {f[1] for f in by.get("G", [])}
    if gl != set(e.get("globals", [])): diffs.append(f"objects marked global {sorted(gl)}, expected {sorted(e.get('globals', []))}")
    # labels
    lab = [(int(f[1]), int(f[2]), "|".join(f[3:])) for f in by.get("L", [])]
    for l in e["labels"]:
        if (l["x"], l["y"], l["text"]) not in lab: diffs.append(f"label {l['text']!r} at {l['x']},{l['y']} missing")
    if len(lab) != len(e["labels"]): diffs.append(f"{len(lab)} labels, expected {len(e['labels'])}")
    hidden = len(by.get("H", []))
    lines = int(by.get("LINES", [["", "0"]])[0][1])
    n_out_wires = sum(1 for p in e["outpins"].values())
    notes.append(f"{hidden} pins hidden; {lines} drawn lines (expected {len(e['wires']) + n_out_wires})")
    if lines != len(e["wires"]) + n_out_wires:
        diffs.append(f"{lines} drawn lines, expected {len(e['wires']) + n_out_wires}")
    counts = {"blocks": (len(got), len(e["blocks"])), "wires": (len(w), len(e["wires"])), "consts": (len(set(k) & set(e["consts"])), len(e["consts"])),
              "setvalues": (len(sv), len(e["setvalues"])), "measures": (len(ms), len(e["measures"])),
              "inpins": (sum(1 for f in ip.values() if f[2] == "EditorInputPin"), len(e["inpins"])),
              "outpins": (sum(1 for f in ip.values() if f[2] == "EditorOutputPin"), len(e["outpins"])), "labels": (len(lab), len(e["labels"])),
              "globalpins": (len(gp), len(e.get("globalpins", {}))), "globals": (len(gl), len(e.get("globals", [])))}
    return diffs, notes, counts


def verify_device(path):
    e = EXP["device"]
    d = rows(path)
    by = {}
    for f in d:
        by.setdefault(f[0], []).append(f)
    diffs, notes = [], []
    apps = [f for f in by.get("APP", [])]
    ours = sorted([f for f in apps if f[1] in e["apps"]], key=lambda f: int(f[2]))
    if [f[1] for f in ours] != e["apps"]: diffs.append(f"applications in execution order {[f[1] for f in ours]}, expected {e['apps']}")
    notes.append("device applications: " + ", ".join(f"{f[1]}#{f[2]}" for f in apps))
    dw = {}
    for f in by.get("DW", []):
        if f[2]:
            dw[f[1]] = f[2]
    for dst, src in e["wires"].items():
        if dw.get(dst) != src: diffs.append(f"device wire into {dst}: {dw.get(dst)!r}, expected {src}")
    for dst, src in dw.items():
        app = dst.split(".")[0]
        if (app in e["apps"] or (dst.startswith("#") and src.split(".")[0] in e["apps"])) and dst not in e["wires"]: diffs.append(f"extra device wire {src} -> {dst}")
    unw = [f[1] for f in by.get("DW", []) if not f[2] and f[1].split(".")[0] in e["apps"]]
    if unw: diffs.append("unconnected application inputs: " + ", ".join(unw))
    io = {f[1]: f for f in by.get("IO", [])}
    for obj, x in e["io"].items():
        g = io.get(obj)
        if not g: diffs.append(f"physical point {obj} not on the canvas"); continue
        if x["phys"] and g[2] != x["phys"]: diffs.append(f"{obj} physical type {g[2]} != {x['phys']}")
        if x["devtype"] and g[3] != x["devtype"]: diffs.append(f"{obj} device type {g[3]} != {x['devtype']}")
        if x["min"] is not None and not (same(g[4], x["min"]) and same(g[5], x["max"])): diffs.append(f"{obj} range {g[4]}..{g[5]} != {x['min']}..{x['max']}")
        if x["unit"] and g[6] != x["unit"]: diffs.append(f"{obj} unit {g[6]!r} != {x['unit']!r}")
        if x["decimals"] is not None and not same(g[7], x["decimals"]): diffs.append(f"{obj} decimals {g[7]} != {x['decimals']}")
        if x["polarity"] and g[8] != x["polarity"]: diffs.append(f"{obj} polarity {g[8]} != {x['polarity']}")
        for k, v in x["params"].items():
            if f"{k}={v}" not in g[9].split(","): diffs.append(f"{obj} parameter {k} not {v}: {g[9]}")
        if "|".join(g[12:]) != x["display"]: diffs.append(f"{obj} display name {'|'.join(g[12:])!r} != {x['display']!r}")
    # globals: every reader input refers to the name the plan gives it and the name resolves to the writer's object
    want = {(app, g): w for app, m in e.get("global_readers", {}).items() for g, w in m.items()}
    seen = set()
    for f in by.get("GL", []):
        key = (f[1], f[3])
        if key not in want: diffs.append(f"{f[1]}/{f[2]} reads global {f[3]}, not in the plan"); continue
        seen.add(key)
        if f[4] != f"{want[key]}.{f[3]}": diffs.append(f"{f[1]}/{f[2]}: global {f[3]} resolves to {f[4]!r}, expected {want[key]}.{f[3]}")
        elif f[5] != "True": diffs.append(f"{f[1]}/{f[2]}: {f[4]} is not marked global")
    for key in want:
        if key not in seen: diffs.append(f"{key[0]} has no input reading global {key[1]}")
    if want: notes.append(f"globals: {len(by.get('GL', []))} inputs read {len({k[1] for k in want})} globals")
    man = {f[1]: f[2] for f in by.get("MAN", [])}
    for obj in e.get("auto_outputs", []):
        if man.get(obj) != "False": diffs.append(f"output {obj} manual control ON = {man.get(obj)} (a point in manual ignores the program)")
    for c in e.get("module_points", e.get("ui8_channels", [])):
        if c not in io: diffs.append(f"module point {c} not on the canvas")
    text = open(path, encoding="utf-8-sig").read()
    for f in by.get("CHECK", []):
        if f[1] in e["apps"] and f[2] != "True": diffs.append(f"CheckAll {f[1]} = {f[2]}: {f[3]}")
    notes += [l for l in text.splitlines() if l.startswith(("CHECK|", "CAPACITY|"))]
    return diffs, notes


def verify_modbus(dump, maptsv):
    """dump: Dump-Modbus lines (object registers); maptsv: Get-ModbusMap rows exported as TSV"""
    reg = {}
    for f in rows(dump, "MB"):
        reg[f[2]] = {"app": f[1], "type": f[3], "using": f[4], "reg": int(f[5]), "shown": int(f[6]), "fmt": f[7], "dec": f[9]}
    doc = []
    for line in open(maptsv, encoding="utf-8-sig"):
        doc.append(line.rstrip("\r\n").split("\t"))
    hdr, doc = doc[0], doc[1:]
    docby = {}
    for r in doc:
        rec = dict(zip(hdr, r))
        tn = rec.get("technicalname", "") or rec.get("description", "")
        docby.setdefault(tn.split("/")[-1].strip().split(".")[0], []).append(rec)
    diffs, table = [], []
    table.append("| Point | Spec | Spec address | Spec scale/type | Built register (protocol) | Doc register | Format | Decimals | R/W | Status |")
    table.append("|---|---|---|---|---|---|---|---|---|---|")
    for m in EXP["modbus"]:
        n = m["name"]
        src = m.get("source", "")
        key = m.get("object") or (src[3:] if src.startswith("io:") else n)
        g = reg.get(key)
        if m.get("spec_table") is None:
            st = "local, off bus" if g and g["using"] == "False" else f"local but Using={g and g['using']}"
            if not g or g["using"] != "False": diffs.append(f"{n}: expected off the bus (Using=False), got {g}")
            table.append(f"| `{n}` | local | — | — | — | — | — | — | — | {st} |")
            continue
        if not g:
            diffs.append(f"{n}: no Modbus interface found"); table.append(f"| `{n}` | {m['spec_table']} {m['spec_offset']} | {m['spec_address']} | | — | — | — | — | — | MISSING |"); continue
        d = docby.get(key, [])
        dreg = d[0].get("modbus reg", "?") if d else "not in document"
        rw = d[0].get("Read/Write", "?") if d else "?"
        boolean = m["spec_table"] in ("0x", "1x")
        ok = g["reg"] == m["register"] and g["fmt"] == m["format"] and (boolean or same(g["dec"] or 0, m["decimals"]))
        if boolean: g = dict(g, dec="—")
        if not ok: diffs.append(f"{n}: register {g['reg']} {g['fmt']} dec {g['dec']}, expected {m['register']} {m['format']} dec {m['decimals']}")
        scale = m.get("spec_scale", 1)
        sf = "bit" if boolean else (m.get("spec_format") or "Int16")
        table.append(f"| `{n}` | {m['spec_table']} {m['spec_offset']} | {m['spec_address'] if m.get('spec_address') is None else format(m['spec_address'], '05d')} | {'' if boolean else '×' + str(scale) + ' '}{sf} | 4x {g['reg']} ({40001 + g['reg']}) | {dreg} | {g['fmt']} | {g['dec']} | {rw} | {'as rule' if ok else 'DIFFERS'} |")
    return diffs, table


def verify_file(path):
    """projdump.ps1 output: the saved Device.bin read with the vendor DLLs, no tool running"""
    by = {}
    for f in rows(path):
        by.setdefault(f[0], []).append(f)
    diffs, notes = [], []
    dev = EXP["device"]
    order = {f[1]: int(f[2]) for f in by.get("FA", [])}
    ours = sorted([a for a in order if a in EXP["apps"]], key=lambda a: order[a])
    if ours != dev["apps"]: diffs.append(f"applications in file {ours}, expected {dev['apps']}")
    for app, e in EXP["apps"].items():
        fb = {f[2]: f for f in by.get("FB", []) if f[1] == app}
        for n, b in e["blocks"].items():
            g = fb.get(n)
            if not g: diffs.append(f"{app}: block {n} missing in file"); continue
            if g[3] != "OumanComponents." + b["lib"] or g[4] != b["version"]: diffs.append(f"{app}: block {n} {g[3]} {g[4]}")
            if int(g[5]) != b["exec"]: diffs.append(f"{app}: block {n} exec {g[5]} != {b['exec']}")
        for n in fb:
            if n not in e["blocks"]: diffs.append(f"{app}: extra block {n} in file")
        fw = {f[2]: (f[3][len(app) + 1:] if f[3].startswith(app + ".") else f[3]) for f in by.get("FW", []) if f[1] == app}   # file names carry the app prefix
        for dst, src in e["wires"].items():
            if fw.get(dst) != src: diffs.append(f"{app}: wire into {dst} is {fw.get(dst)!r} in file, expected {src}")
        for dst in fw:
            if dst not in e["wires"]: diffs.append(f"{app}: extra wire into {dst} in file")
        fk = {f[2]: f[3] for f in by.get("FK", []) if f[1] == app}
        for dst, v in e["consts"].items():
            if dst not in fk or not same(fk[dst], v): diffs.append(f"{app}: constant {dst} = {fk.get(dst)} in file, expected {v}")
        extra_k = [d for d in fk if d not in e["consts"]]
        fsvp = {f[2]: f[3] for f in by.get("FSVP", []) if f[1] == app}
        if fsvp != e["setvalue_pins"]: diffs.append(f"{app}: set value pins in file {fsvp} != {e['setvalue_pins']}")
        fsv = {f[2]: f for f in by.get("FSV", []) if f[1] == app}
        for n, s in e["setvalues"].items():
            g = fsv.get(n)
            if not g: diffs.append(f"{app}: set value {n} missing in file"); continue
            if not same(g[4], s["default"]): diffs.append(f"{app}: set value {n} default {g[4]}")
            if s["type"] == "Float" and not (same(g[5], s["min"]) and same(g[6], s["max"]) and g[7] == s["unit"] and same(g[8], s["decimals"])):
                diffs.append(f"{app}: set value {n} fields {g[5:9]}")
        for n in fsv:
            if n not in e["setvalues"]: diffs.append(f"{app}: extra set value {n} in file")
        fmsp = {f[2]: f[3] for f in by.get("FMSP", []) if f[1] == app}
        if fmsp != e["measure_pins"]: diffs.append(f"{app}: measure pins in file {sorted(set(fmsp.items()) ^ set(e['measure_pins'].items()))}")
        fms = {f[2] for f in by.get("FMS", []) if f[1] == app}
        if fms != set(e["measures"]): diffs.append(f"{app}: measures in file differ: {sorted(fms ^ set(e['measures']))}")
        fip = {f[2]: f for f in by.get("FIP", []) if f[1] == app}
        for n, p in list(e["inpins"].items()) + list(e["outpins"].items()):
            if n not in fip or fip[n][4] != p["type"]: diffs.append(f"{app}: interface pin {n} {fip.get(n)}")
        if len(fip) != len(e["inpins"]) + len(e["outpins"]): diffs.append(f"{app}: {len(fip)} interface pins in file")
        for f in fip.values():
            dst = f"{app}.{f[2]}"
            if f[3] == "Input" and dev["wires"].get(dst) != f[5]: diffs.append(f"device wire into {dst} is {f[5]!r} in file, expected {dev['wires'].get(dst)}")
        for f in by.get("FGL", []):
            if f[1] == app:
                w = dev.get("global_readers", {}).get(app, {}).get(f[3])
                if f[4] != f"{w}.{f[3]}": diffs.append(f"{app}: global {f[3]} on {f[2]} resolves to {f[4]!r} in file, expected {w}.{f[3]}")
        notes.append(f"{app}: blocks {len(fb)}, wires {len(fw)}, constants {len(fk) - len(extra_k)} (+{len(extra_k)} library defaults), set values {len(fsv)}, measures {len(fms)}, interface pins {len(fip)}")
    return diffs, notes


def main():
    mode = sys.argv[1]
    if mode == "file":
        diffs, notes = verify_file(sys.argv[2])
    elif mode == "app":
        diffs, notes, counts = verify_app(sys.argv[2], sys.argv[3])
        print(f"{sys.argv[2]}: " + ", ".join(f"{k} {a}/{b}" for k, (a, b) in counts.items()))
    elif mode == "device":
        diffs, notes = verify_device(sys.argv[2])
    else:
        diffs, table = verify_modbus(sys.argv[2], sys.argv[3])
        notes = table
    for n in notes:
        print("  " + n)
    for d in diffs:
        print("  DIFF " + d)
    print("  RESULT " + ("OK" if not diffs else f"{len(diffs)} difference(s)"))
    sys.exit(1 if diffs else 0)


if __name__ == "__main__":
    main()
