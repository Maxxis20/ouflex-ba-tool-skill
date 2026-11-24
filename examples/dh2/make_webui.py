#!/usr/bin/env python3
"""dh2: Web UI page (BA Tool "Web UI configuration" chart) for the two heating circuits.

Writes webui/heating.json next to this file: the chart JSON the Ouflex web UI draws (surface + components). Links
name points as the web UI does: physical points by object name ("UI 4", "AO 1", "R1"), application points as
"<application>.<point>" ("C1.C1_SP"). The link registry (object ids) is left empty here; the build fills it from the
project (WEBP in scripts/win/prelude.ps1), because object ids exist only there.

Texts are {"en", "fi", "sv"}; the generator (make_ouflex_build.py) puts the program.json webui.language text into
the page, since a chart Text component holds one string.

    python3 make_webui.py
"""
import json
import os

HERE = os.path.dirname(os.path.abspath(__file__))
RED, BLUE = "#ff2424", "#24B4FF"          # the editor's presets redPipe / bluePipe: supply red, return blue
_n = [0]


def cid(t):
    _n[0] += 1
    return f"{t}-dh2{_n[0]:03d}"


def comp(t, props, links=(), states=None):
    return {"id": cid(t), "type": t, "props": props, "links": list(links), "states": states or {}}


def pipe(points, thick=20, color=RED):
    """one point per corner: the editor draws the bend itself, and a user can drag or add points (right click) later"""
    return comp("Pipe", {"color": color, "thickness": thick, "points": points, "x": points[0][0], "y": points[0][1]})


def tjoint(x, y, rot=0):
    return comp("Pipe T-joint", {"x": x, "y": y, "internalLink": "", "rotation": rot, "width": 50, "height": 50, "thickness": 20, "color": RED})


def box(t, x, y, link, bg, alarm=None):
    st = {"displayValue": link}
    lk = [link]
    if alarm:
        st["alarm"] = alarm
        lk.append(alarm)
    return comp(t, {"x": x, "y": y, "internalLink": "", "rotation": 0, "font": 0, "fontSize": 20, "fontColor": "#000000",
                    "width": 90, "height": 45, "background": bg, "border": "#000000"}, lk, st)


def text(x, y, txt, size=26):
    return comp("Text", {"x": x, "y": y, "internalLink": "", "rotation": 0, "text": txt, "font": 0, "fontSize": size,
                         "fontColor": "#000000", "padding": 0, "verticalAlignment": 0, "horizontalAlignment": 0,
                         "fill": "rgba(0,0,0,0)", "stroke": "rgba(0,0,0,0)", "width": 90, "height": 45})


def alarm(x, y, link):
    return comp("Alarm", {"x": x, "y": y, "internalLink": "", "rotation": 0, "size": 45}, [link])


SUP_Y, RET_Y = 120, 855          # primary supply / return mains


def circuit(n, X, last=False):
    """one heating circuit; X = left edge of its block (heat exchanger at X + 330). The last circuit's primary branches
    are drawn as the ends of the mains (page()), so the mains turn into them with one bend and do not run past."""
    a = f"C{n}"
    hx = X + 330
    bx = X + 300                  # primary supply branch (down to the heat exchanger)
    rx = X + 250                  # primary return branch (down to the return main)
    out = [] if last else [
        pipe([[bx, SUP_Y], [bx, 465], [hx + 30, 465]]),       # starts on the main's centre line: no tee needed
        pipe([[hx + 15, 585], [rx, 585], [rx, RET_Y]], color=BLUE),
    ]
    out += [
        comp("Two way valve", {"x": bx - 30, "y": 216, "internalLink": "", "rotation": "90", "width": 60, "height": 30}),
        box("Adjust", bx - 105, 210, f"AO {n}", "#EEE0FF"),
        comp("Heat exchanger", {"x": hx, "y": 420, "internalLink": "", "rotation": 0, "height": 200, "width": 90, "pipeWidth": 15}),
        # secondary loop, split at the circuit symbol: supply (red) up out of the exchanger and round to the circuit, return
        # (blue) from the circuit along the bottom, through the pump, back into the exchanger
        pipe([[hx + 45, 420], [hx + 45, 300], [hx + 495, 300], [hx + 495, 465]], thick=15),
        pipe([[hx + 495, 465], [hx + 495, 720], [hx + 45, 720], [hx + 45, 615]], thick=15, color=BLUE),
        comp("Pump", {"x": hx + 120, "y": 690, "internalLink": "", "rotation": "180", "width": 60},   # return leg flows back to the exchanger: right to left
             [f"{a}.{a}_PUMP"], {"indication": f"{a}.{a}_PUMP"}),
        box("Indication", hx + 105, 600, f"{a}.{a}_PUMP", "#8a8a8a"),
        box("Control", hx + 105, 645, f"R{n}", "#b5b5b5"),
        comp("Circuit", {"x": hx + 450, "y": 465, "internalLink": "", "rotation": 0, "size": 90, "text": str(n), "fontSize": 20}),
        text(hx + 165, 345, {"en": f"Heating circuit {n}", "fi": f"Lämmityspiiri {n}", "sv": f"Värmekrets {n}"}),
        # heating curve: 3 points at -20 / 0 / +20 °C outdoor, limits, offset, live outdoor and setpoint
        comp("Heating curve",
             {"width": 100, "height": 100, "xAxisName": {"en": "Outdoor °C", "fi": "Ulko °C", "sv": "Ute °C"},
              "yAxisName": {"en": "Supply °C", "fi": "Meno °C", "sv": "Framl. °C"}, "pointCount": "3", "invertXAxis": False,
              "x": hx + 60, "y": 190},
             [f"{a}.{a}_CRV_N20", f"{a}.{a}_CRV_0", f"{a}.{a}_CRV_P20", f"{a}.{a}_TS_MIN", f"{a}.{a}_TS_MAX",
              f"{a}.{a}_SP_OFFSET", "COMMON.TOUT_F", f"{a}.{a}_SP"],
             {"outside0": "-20", "supply0": f"{a}.{a}_CRV_N20", "outside1": "0", "supply1": f"{a}.{a}_CRV_0",
              "outside2": "20", "supply2": f"{a}.{a}_CRV_P20", "min": f"{a}.{a}_TS_MIN", "max": f"{a}.{a}_TS_MAX",
              "parallelShift": f"{a}.{a}_SP_OFFSET", "currentOutside": "COMMON.TOUT_F", "currentSupply": f"{a}.{a}_SP"}),
        box("Measurement", hx + 165, 195, f"{a}.{a}_SP", "#ffffff"),                       # supply setpoint
        box("Measurement", hx + 165, 240, f"UI {n + 3}", "#ffffff", f"{a}.{a}_DEV_ALM"),   # supply temperature + deviation alarm
        box("Setting", hx + 360, 450, f"{a}.{a}_SP_OFFSET", "#FFE600"),                   # setpoint offset
        comp("Setting icon", {"x": hx + 270, "y": 180, "internalLink": "", "rotation": 0, "width": 50, "height": 50},
             [f"{a}.{a}_{s}" for s in ("ENABLE", "SETBACK", "SUM_STOP", "SUM_DLY", "SUM_START", "PID_P", "PID_I", "VLV_FAULT",
                                       "EXER_ON", "EXER_OFF", "DEV_LIM", "DEV_DLY")]),
        # time program (comfort / night setback): opens the week editor; same props as the vendor page AHU301
        comp("Time program", {"x": hx + 330, "y": 175, "internalLink": "", "rotation": 0, "size": "55", "color": "#57564a"},
             [f"{a}.{a}_TPRG"]),
        alarm(hx + 270, 240, f"{a}.{a}_TS_FAULT"),
    ]
    return out


def page():
    comps = [
        comp("Triangle", {"x": 30, "y": SUP_Y - 22, "internalLink": "", "rotation": 90, "width": 45, "height": 45,
                          "background": "rgba(245,100,100,1)", "border": "rgba(245,100,100,1)"}),
        comp("Triangle", {"x": 29, "y": RET_Y - 23, "internalLink": "", "rotation": 270, "width": 45, "height": 45,
                          "background": "rgba(36,180,255,1)", "border": "rgba(36,180,255,1)"}),
        # mains: the supply main ends as circuit 2's branch, the return main starts as circuit 2's return (X = 650)
        pipe([[45, SUP_Y], [950, SUP_Y], [950, 465], [1010, 465]]),
        pipe([[995, 585], [900, 585], [900, RET_Y], [45, RET_Y]], color=BLUE),
        text(75, 20, {"en": "District heating", "fi": "Kaukolämpö", "sv": "Fjärrvärme"}),
        box("Measurement", 120, SUP_Y + 30, "UI 2", "#ffffff"),          # primary supply temperature
        box("Measurement", 120, RET_Y + 30, "UI 3", "#ffffff"),          # primary return temperature
        alarm(60, 300, "ALARM.ALARM_SUM"),
        comp("Outdoor wall", {"x": 1590, "y": 2, "internalLink": "", "rotation": 180, "width": 50, "height": 210}),
        box("Measurement", 1650, 75, "COMMON.TOUT_F", "#ffffff", "COMMON.TOUT_FAULT"),
    ]
    comps += circuit(1, 0) + circuit(2, 650, last=True)
    return {
        "surface": {"name": "", "props": {"background": "#ffffff", "backgroundImage": "", "gridSize": 15, "gridThreshold": 15,
                                          "width": 1800, "height": 950}},
        "component": {"selected": [], "allIds": [c["id"] for c in comps], "components": {c["id"]: c for c in comps}},
        "link": {"allIds": [], "links": {}},
        "extraData": "",
    }


if __name__ == "__main__":
    os.makedirs(os.path.join(HERE, "webui"), exist_ok=True)
    p = os.path.join(HERE, "webui", "heating.json")
    with open(p, "w", encoding="utf-8") as f:
        json.dump(page(), f, ensure_ascii=False, indent=1)
    print("wrote", p)
