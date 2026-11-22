#!/usr/bin/env python3
"""Page layout for Ouflex BA Tool applications: where blocks, interface pins and labels go.

BA Tool draws every wire itself and the shape cannot be chosen (measured 2026-11-11, ConnectorLine.forwardPoints /
backwardPoints): a forward wire is  start -> 1/3 of dx horizontal -> diagonal over the middle third -> 1/3 horizontal -> end;
a wire whose end is left of its start runs back as a hexagon through the mid height of its two ends. So a page is tidy
only when the blocks are placed for those shapes. This module does that:

  * blocks stay in their label groups (bands, one under the other) and in columns on one global grid;
  * interface pins are placed like blocks, next to the block that uses them, instead of in lanes at the page edges;
  * positions are chosen by a search that scores the wires as the tool will draw them: a wire through a block or label
    costs most, then wires crossing each other, then bends and long spans.

    python pipeline/ouflayout.py <program dir> [--png <dir>]     # report per application, optional preview pictures
    python pipeline/ouflayout.py --learn                         # refresh sticky_pins.json from the build dumps under examples/

make_ouflex_build.py calls layout_app() and writes the result into the build scripts and expected.json.
"""
import json
import math
import os
import random
import sys
import zlib
from collections import defaultdict, OrderedDict

HERE = os.path.dirname(os.path.abspath(__file__))
BLOCKS_JSON = os.environ.get("OUMAN_BLOCKS", os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "reference", "blocks.json"))
if not os.path.exists(BLOCKS_JSON):
    raise SystemExit("block catalogue missing (" + os.path.normpath(BLOCKS_JSON) + "): run scripts/batool.sh setup, it reads the block library of your own BA Tool installation")
STICKY_JSON = os.path.join(HERE, "sticky_pins.json")

# ---- measured geometry (BA Tool 2.130.14, canvas units) ----
BW, HEAD, ROW, PIN0 = 165, 35.34, 16, 42.84      # symbol width; height = HEAD + ROW * max(inputs, outputs); first pin row
PINW, PINH, PIN_LP = 85, 15, 7.5                 # interface pin element; its line point is PIN_LP below its top
CONSTW, SVW, MSW = 31, 17, 18                    # constant box / set value mark left of an input, measure mark right of an output
LABEL_H, LABEL_CH = 44, 8.4                      # comment height, width per character (approx.)
# ---- grid ----
CHANNEL = 135                                    # free space between columns: all diagonals of neighbour wires run here
PITCH = BW + CHANNEL
X0, Y0, GRID = 48, 16, 16
BAND_HEAD, BAND_GAP = 48, 48                     # label row above a band's blocks, space under a band
GAP_BB, GAP_BP, GAP_PP = 16, 12, 1                # vertical gaps: block-block, block-pin, pin-pin
PAD = 6                                          # clearance used when testing a wire against a box
# ---- cost weights ----
W_HIT, W_CROSS, W_OVERLAP, W_DY, W_SPAN, W_BACK, W_Y, W_COL = 1000, 60, 200, 0.3, 30, 150, 0.03, 10
W_DIAG, W_SPAN_DIAG, W_RUN = 800, 100, 0.3            # slanted wire over more than one column; per column; backward run per px
W_LABEL = 120                                    # a wire across a label text
SA_MOVES, SA_T0, SA_T1, SA_RUNS = 60000, 400.0, 4.0, 3      # annealing: moves per run, start/end temperature, runs

_REF = None


def ref_blocks():
    global _REF
    if _REF is None:
        ref = json.load(open(BLOCKS_JSON, encoding="utf-8"))["blocks"]
        _REF = {b["type"]: b for b in ref if b.get("current") and not b.get("beta")}
    return _REF


def sticky_pins():
    if os.path.exists(STICKY_JSON):
        return json.load(open(STICKY_JSON, encoding="utf-8"))["sticky"]
    return {}


def lib_pins(typ):
    pins = [p for p in ref_blocks()[typ]["pins"] if p["category"] == "Pin" and not p["hidden"]]
    return [p["name"] for p in pins if p["dir"] == "in"], [p["name"] for p in pins if p["dir"] == "out"]


# ============================================================================================================
# model
# ============================================================================================================
class Node:
    __slots__ = ("id", "kind", "band", "w", "h", "col", "y", "ins", "outs", "boxes_rel", "order", "win", "wout")

    def __init__(self, id, kind, band, order):
        self.id, self.kind, self.band, self.order = id, kind, band, order
        self.col, self.y = 0, 0
        self.ins, self.outs = {}, {}          # pin name -> y offset of its line point
        self.boxes_rel = []                    # extra boxes (constant, set value, measure marks): (dx0, dy0, dx1, dy1)
        self.win, self.wout = [], []
        if kind == "B":
            self.w = BW
        else:
            self.w, self.h = PINW, PINH

    def x(self):
        return X0 + self.col * PITCH + (BW - PINW if self.kind == "I" else 0)


class Wire:
    __slots__ = ("s", "sp", "d", "dp", "back", "pts", "bb")

    def __init__(self, s, sp, d, dp, back=False):
        self.s, self.sp, self.d, self.dp, self.back = s, sp, d, dp, back
        self.pts = self.bb = None


class Page:
    """One application. spec = {"name", "blocks": [{id, type, label, exec, pins: {pin: (kind, ref)}, outs: {pin: [(kind, ref)]}}]}
    pin kinds: ("wire", "blk.pin", feedback?) ("in", name) ("const",) ("sv",);  out kinds: ("out", name) ("ms",)."""

    def __init__(self, spec, sticky=None):
        sticky = sticky_pins() if sticky is None else sticky
        self.name = spec["name"]
        self.nodes, self.wires, self.bands = OrderedDict(), [], []
        blocks = sorted(spec["blocks"], key=lambda b: b["exec"])
        for b in blocks:
            if b["label"] not in self.bands:
                self.bands.append(b["label"])
        used_out = defaultdict(set)
        for b in blocks:
            for pn, src in b["pins"].items():
                if src[0] == "wire":
                    sb, sp = src[1].rsplit(".", 1)
                    used_out[sb].add(sp)
            for pn in b["outs"]:
                used_out[b["id"]].add(pn)
        for b in blocks:
            n = Node(b["id"], "B", self.bands.index(b["label"]), b["exec"])
            li, lo = lib_pins(b["type"])
            st = set(sticky.get(b["type"], []))
            vis_i = [p for p in li if p in b["pins"] or p in st]
            vis_o = [p for p in lo if p in used_out[b["id"]] or p in st]
            for p in b["pins"]:
                if p not in vis_i:
                    vis_i.append(p)
            for p in used_out[b["id"]]:
                if p not in vis_o:
                    vis_o.append(p)
            n.h = HEAD + ROW * max(len(vis_i), len(vis_o), 1)
            n.ins = {p: PIN0 + ROW * i for i, p in enumerate(vis_i)}
            n.outs = {p: PIN0 + ROW * i for i, p in enumerate(vis_o)}
            for pn, src in b["pins"].items():
                if src[0] in ("const", "sv"):
                    w = CONSTW if src[0] == "const" else SVW
                    n.boxes_rel.append((-w, n.ins[pn] - 8, 0, n.ins[pn] + 8))
            for pn, outs in b["outs"].items():
                if any(o[0] == "ms" for o in outs):
                    n.boxes_rel.append((BW, n.outs[pn] - 8, BW + MSW, n.outs[pn] + 8))
            self.nodes[("B", b["id"])] = n
        for b in blocks:
            n = self.nodes[("B", b["id"])]
            for pn, src in b["pins"].items():
                if src[0] == "wire":
                    sb, sp = src[1].rsplit(".", 1)
                    self.wires.append(Wire(self.nodes[("B", sb)], sp, n, pn, back=len(src) > 2 and bool(src[2])))
                elif src[0] == "in":
                    k = ("I", src[1])
                    if k not in self.nodes:
                        p = Node(src[1], "I", n.band, n.order)
                        p.outs = {"": PIN_LP}
                        self.nodes[k] = p
                    self.wires.append(Wire(self.nodes[k], "", n, pn))
            for pn, outs in b["outs"].items():
                for o in outs:
                    if o[0] == "out":
                        k = ("O", o[1])
                        if k not in self.nodes:
                            p = Node(o[1], "O", n.band, n.order)
                            p.ins = {"": PIN_LP}
                            self.nodes[k] = p
                            self.wires.append(Wire(n, pn, p, ""))
        self.N = list(self.nodes.values())
        for w in self.wires:
            w.s.wout.append(w)
            w.d.win.append(w)
        self.band_top = [0] * len(self.bands)
        self.band_h = [0] * len(self.bands)
        # A feedback wire (the reader runs before the writer) only has to be drawn backwards when the reader also leads
        # back to the writer. Otherwise the reader can simply stand to the right of the writer: position is not execution order.
        for w in self.wires:
            if w.back and not self.reaches(w.d, w.s):
                w.back = False

    def reaches(self, a, b):
        seen, stack = {a}, [a]
        while stack:
            m = stack.pop()
            if m is b:
                return True
            for w in m.wout:
                if not w.back and w.d not in seen:
                    seen.add(w.d)
                    stack.append(w.d)
        return False

    # ---------------- geometry ----------------
    def ay(self, n):
        return self.band_top[n.band] + BAND_HEAD + n.y

    def rect(self, n):
        x, y = n.x(), self.ay(n)
        return (x, y, x + n.w, y + n.h)

    def boxes(self, n):
        x, y = n.x(), self.ay(n)
        out = [(x, y, x + n.w, y + n.h)]
        for (a, b, c, d) in n.boxes_rel:
            out.append((x + a, y + b, x + c, y + d))
        return out

    def label_boxes(self):
        return [(X0, self.band_top[i] + 2, X0 + LABEL_CH * len(t) + 16, self.band_top[i] + LABEL_H - 4) for i, t in enumerate(self.bands)]

    def route(self, w):
        s, d = w.s, w.d
        sx = s.x() + (BW - 1 if s.kind == "B" else PINW)
        sy = self.ay(s) + s.outs[w.sp]
        ex = d.x() + (1 if d.kind == "B" else 0)
        ey = self.ay(d) + d.ins[w.dp]
        if ex > sx:
            t = (ex - sx) / 3.0
            pts = [(sx, sy), (sx + t, sy), (ex - t, ey), (ex, ey)]
        else:
            ym = (sy + ey) / 2.0
            pts = [(sx, sy), (sx + 30, sy), (sx + 60, (sy + ym) / 2), (sx + 30, ym), (ex - 30, ym), (ex - 60, (ym + ey) / 2), (ex - 30, ey), (ex, ey)]
        w.pts = pts
        xs, ys = [p[0] for p in pts], [p[1] for p in pts]
        w.bb = (min(xs), min(ys), max(xs), max(ys))

    def route_all(self):
        for w in self.wires:
            self.route(w)

    # ---------------- cost ----------------
    def wire_hits(self, w, skip=None):
        """Number of foreign boxes (nodes, labels) the wire passes through."""
        hits = 0
        bb = w.bb
        for n in self.N:
            if n is w.s or n is w.d or n is skip:
                continue
            x, y = n.x(), self.ay(n)
            if x - CONSTW - PAD > bb[2] or x + n.w + MSW + PAD < bb[0] or y - PAD > bb[3] or y + n.h + PAD < bb[1]:
                continue
            if any(poly_hits_box(w.pts, bx) for bx in self.boxes(n)):
                hits += 1
        for bx in self._labels:
            if not (bx[0] > bb[2] or bx[2] < bb[0] or bx[1] > bb[3] or bx[3] < bb[1]) and poly_hits_box(w.pts, bx):
                hits += W_LABEL / W_HIT
        return hits

    def wire_own(self, w):
        """Shape cost. Clean shapes: neighbour columns (the slant stays in the channel) or a level line over any distance."""
        dy = abs(w.pts[-1][1] - w.pts[0][1])
        if w.pts[-1][0] > w.pts[0][0]:
            span = w.d.col - w.s.col - 1
            if span <= 0:
                return W_DY * dy
            if dy < 1:
                return W_SPAN * span
            return W_DIAG + W_SPAN_DIAG * span + W_DY * dy
        return W_BACK + W_DY * dy + W_RUN * abs(w.pts[0][0] - w.pts[-1][0])

    def wire_cross(self, w, others):
        c = 0.0
        for o in others:
            if o is w or (o.s is w.s and o.sp == w.sp):
                continue
            a, b = w.bb, o.bb
            if a[0] > b[2] or a[2] < b[0] or a[1] > b[3] or a[3] < b[1]:
                continue
            k = poly_cross(w.pts, o.pts)
            if k:
                c += k
        return c

    def node_cost(self, n):
        mine = n.win + n.wout
        c = W_Y * n.y + W_COL * n.col
        for w in mine:
            c += W_HIT * self.wire_hits(w) + self.wire_own(w) + self.wire_cross(w, self.wires)
        bxs = self.boxes(n)
        x, y = n.x(), self.ay(n)
        lo, hi, top, bot = x - CONSTW - PAD, x + n.w + MSW + PAD, y - PAD, y + n.h + PAD
        for w in self.wires:
            if w.s is n or w.d is n:
                continue
            bb = w.bb
            if lo > bb[2] or hi < bb[0] or top > bb[3] or bot < bb[1]:
                continue
            if any(poly_hits_box(w.pts, bx) for bx in bxs):
                c += W_HIT
        return c

    def total(self):
        self._labels = self.label_boxes()
        self.route_all()
        hits = round(sum(self.wire_hits(w) for w in self.wires), 2)
        cross = 0.0
        for i, w in enumerate(self.wires):
            cross += self.wire_cross(w, self.wires[i + 1:])
        own = sum(self.wire_own(w) for w in self.wires)
        bent = sum(1 for w in self.wires if abs(w.pts[-1][1] - w.pts[0][1]) > 1)
        back = sum(1 for w in self.wires if w.pts[-1][0] <= w.pts[0][0])
        return {"hits": hits, "cross": round(cross / W_CROSS, 1), "bent": bent, "back": back, "wires": len(self.wires),
                "cost": round(W_HIT * hits + cross + own + sum(W_Y * n.y + W_COL * n.col for n in self.N))}

    # ---------------- legality ----------------
    def col_range(self, n, maxcol):
        lo, hi = 0, maxcol
        for w in n.win:
            if not w.back:
                lo = max(lo, w.s.col + 1)
        for w in n.wout:
            if not w.back:
                hi = min(hi, w.d.col - 1)
        return lo, hi

    def free(self, n, col, y, ignore=()):
        if y < 0 or y + n.h > self.band_h[n.band]:
            return False
        for m in self.cells[(n.band, col)]:
            if m is n or m in ignore:
                continue
            g = GAP_BB if (n.kind == "B" and m.kind == "B") else GAP_PP if (n.kind != "B" and m.kind != "B") else GAP_BP
            if y < m.y + m.h + g and m.y < y + n.h + g:
                return False
        return True

    def move(self, n, col, y):
        self.cells[(n.band, n.col)].remove(n)
        n.col, n.y = col, y
        self.cells[(n.band, col)].append(n)
        for w in n.win + n.wout:
            self.route(w)

    def snap(self, n, y):
        if n.kind == "B":
            return int(round(y / GRID)) * GRID
        return int(round((y - 3) / GRID)) * GRID + 3

    # ---------------- initial placement ----------------
    def topo(self):
        indeg = {n: sum(1 for w in n.win if not w.back) for n in self.N}
        ready = sorted([n for n in self.N if indeg[n] == 0], key=lambda n: n.order)
        out = []
        while ready:
            n = ready.pop(0)
            out.append(n)
            for w in n.wout:
                if not w.back:
                    indeg[w.d] -= 1
                    if indeg[w.d] == 0:
                        ready.append(w.d)
        assert len(out) == len(self.N), f"{self.name}: wire cycle without a feedback mark"
        return out

    def push_set(self, n, dc):
        """n and the nodes that have to move along when n shifts one column (right: what it drives; left: what drives it)."""
        S, stack = {n}, [n]
        while stack:
            m = stack.pop()
            for w in (m.wout if dc > 0 else m.win):
                if w.back:
                    continue
                o = w.d if dc > 0 else w.s
                if o not in S and (o.col <= m.col + 1 if dc > 0 else o.col >= m.col - 1):
                    S.add(o)
                    stack.append(o)
        return S

    def try_group(self, g, dc, dy, T=None, rng=None):
        """Move the nodes of g by (dc columns, dy); keep it when the cost drops (or by the annealing rule). True = kept."""
        start = [(m.col, m.y) for m in g]
        if any(c + dc < 0 for c, _ in start) or not all(self.free(m, c + dc, y + dy, ignore=g) for m, (c, y) in zip(g, start)):
            return False
        gs = set(g)
        for m in g:                                            # column order towards the rest must hold
            for w in m.win:
                if not w.back and w.s not in gs and w.s.col >= m.col + dc:
                    return False
            for w in m.wout:
                if not w.back and w.d not in gs and w.d.col <= m.col + dc:
                    return False
        c0 = self.group_cost(g)
        for m, (c, y) in zip(g, start):
            self.move(m, c + dc, y + dy)
        d = self.group_cost(g) - c0
        if d < -1e-6 or (T is not None and d > 0 and rng.random() < math.exp(-d / T)) or (T is not None and d == 0):
            return True
        for m, (c, y) in zip(g, start):
            self.move(m, c, y)
        return False

    def initial(self):
        order = self.topo()
        depth = {}
        for n in order:
            depth[n] = max([depth[w.s] + 1 for w in n.win if not w.back] or [0])
        for n in reversed(order):                                  # sources next to their first user
            outs = [depth[w.d] for w in n.wout if not w.back]
            if outs and not any(not w.back for w in n.win):
                depth[n] = min(outs) - 1
        for n in self.N:
            n.col = depth[n]
        # shorten the wires: move single nodes, or push a node with everything it drives / pull it with everything driving it
        def obj():
            return sum(w.d.col - w.s.col - 1 for w in self.wires if not w.back) + 0.01 * sum(m.col for m in self.N)
        for _ in range(30):
            changed = False
            for n in order:
                best, bo = None, obj()
                lo = max([w.s.col + 1 for w in n.win if not w.back] or [min(m.col for m in self.N) - 1])
                hi = min([w.d.col - 1 for w in n.wout if not w.back] or [max(m.col for m in self.N) + 1])
                c0 = n.col
                for c in range(lo, hi + 1):
                    n.col = c
                    if obj() < bo - 1e-9:
                        best, bo = ("one", c), obj()
                n.col = c0
                for dc in (1, -1):
                    S = self.push_set(n, dc)
                    for m in S:
                        m.col += dc
                    if obj() < bo - 1e-9:
                        best, bo = ("push", dc), obj()
                    for m in S:
                        m.col -= dc
                if best:
                    changed = True
                    if best[0] == "one":
                        n.col = best[1]
                    else:
                        for m in self.push_set(n, best[1]):
                            m.col += best[1]
            if not changed:
                break
        comp = {}                                                   # every connected group of nodes starts at the left edge
        for n in self.N:
            if n in comp:
                continue
            grp, stack = [n], [n]
            comp[n] = grp
            while stack:
                m = stack.pop()
                for o in [w.d for w in m.wout if not w.back] + [w.s for w in m.win if not w.back]:
                    if o not in comp:
                        comp[o] = grp
                        grp.append(o)
                        stack.append(o)
            base = min(m.col for m in grp)
            for m in grp:
                m.col -= base
        depth = {n: n.col for n in self.N}
        order = sorted(self.N, key=lambda n: (n.order, {"I": 0, "B": 1, "O": 2}[n.kind]))
        base = min(depth.values())
        self.cells = defaultdict(list)
        coly = defaultdict(int)
        for n in order:
            n.col = depth[n] - base
            k = (n.band, n.col)
            n.y = self.snap(n, coly[k] + (3 if n.kind != "B" else 0))
            if n.y < coly[k]:
                n.y += GRID
            coly[k] = n.y + n.h + GAP_BB
            self.cells[k].append(n)
        for b in range(len(self.bands)):
            hs = [n.y + n.h for n in self.N if n.band == b]
            self.band_h[b] = (int(max(hs)) // GRID + 12) * GRID
        self.stack_bands(final=False)

    def stack_bands(self, final):
        y = Y0
        for b in range(len(self.bands)):
            if final:
                ns = [n for n in self.N if n.band == b]
                top = min(n.y for n in ns)
                top = (int(top) // GRID) * GRID
                for n in ns:
                    n.y -= top
                self.band_h[b] = (int(max(n.y + n.h for n in ns)) // GRID + 1) * GRID
            self.band_top[b] = y
            y += BAND_HEAD + self.band_h[b] + BAND_GAP
        self._labels = self.label_boxes()
        self.route_all()

    # ---------------- search ----------------
    def cand_ys(self, n, col):
        ys = {n.y, n.y - GRID, n.y + GRID, n.y - 2 * GRID, n.y + 2 * GRID, self.snap(n, 0)}
        top = self.band_top[n.band] + BAND_HEAD
        for w in n.win:
            ys.add(self.snap(n, self.ay(w.s) + w.s.outs[w.sp] - n.ins[w.dp] - top))
        for w in n.wout:
            ys.add(self.snap(n, self.ay(w.d) + w.d.ins[w.dp] - n.outs[w.sp] - top))
        ys.update(self.snap(n, y) for y in range(0, int(self.band_h[n.band]), GRID))
        return ys

    def improve_node(self, n, maxcol):
        lo, hi = self.col_range(n, maxcol)
        if n.kind == "O":
            hi = min(hi, n.win[0].s.col + 2)
        if n.kind == "I":
            lo = max(lo, min(w.d.col for w in n.wout) - 2)
        best, bc = (n.col, n.y), self.node_cost(n)
        start = best
        for col in range(lo, hi + 1):
            for y in sorted(self.cand_ys(n, col)):
                if (col, y) == start or not self.free(n, col, y):
                    continue
                self.move(n, col, y)
                c = self.node_cost(n)
                if c < bc - 1e-6:
                    best, bc = (col, y), c
        if (n.col, n.y) != best:
            self.move(n, *best)
        return best != start

    def satellites(self, n):
        sat = []
        for w in n.win:
            if w.s.kind == "I" and len(w.s.wout) == 1:
                sat.append(w.s)
        for w in n.wout:
            if w.d.kind == "O":
                sat.append(w.d)
        return sat

    def group_cost(self, g):
        return sum(self.node_cost(m) for m in g)

    def improve_group(self, n, maxcol):
        g = [n] + self.satellites(n)
        if len(g) == 1:
            return False
        lo, hi = self.col_range(n, maxcol)
        for m in g[1:]:                                    # satellites move along; the block's other neighbours bound it
            pass
        lo = max([0] + [w.s.col + 1 for w in n.win if not w.back and w.s not in g])
        hi = min([maxcol] + [w.d.col - 1 for w in n.wout if not w.back and w.d not in g])
        dys = {0}
        top = self.band_top[n.band] + BAND_HEAD
        for w in n.win:
            if w.s not in g:
                dys.add(self.snap(n, self.ay(w.s) + w.s.outs[w.sp] - n.ins[w.dp] - top) - n.y)
        for w in n.wout:
            if w.d not in g:
                dys.add(self.snap(n, self.ay(w.d) + w.d.ins[w.dp] - n.outs[w.sp] - top) - n.y)
        for k in (1, 2, 3, 4, 6, 8):
            dys.add(k * GRID)
            dys.add(-k * GRID)
        start = [(m.col, m.y) for m in g]
        best, bc = (0, 0), self.group_cost(g)
        for dc in (-1, 0, 1):
            if not (lo <= n.col + dc <= hi) or any(m.col + dc < 0 or m.col + dc > maxcol for m in g):
                continue
            for dy in sorted(dys):
                if (dc, dy) == (0, 0):
                    continue
                if not all(self.free(m, c + dc, y + dy, ignore=g) for m, (c, y) in zip(g, start)):
                    continue
                for m, (c, y) in zip(g, start):
                    self.move(m, c + dc, y + dy)
                c2 = self.group_cost(g)
                if c2 < bc - 1e-6:
                    best, bc = (dc, dy), c2
                for m, (c, y) in zip(g, start):
                    self.move(m, c, y)
        if best != (0, 0):
            for m, (c, y) in zip(g, start):
                self.move(m, c + best[0], y + best[1])
            return True
        return False

    def sweeps(self, n=10):
        for it in range(n):
            maxcol = max(m.col for m in self.N) + 1
            changed = 0
            for m in sorted(self.N, key=lambda m: (m.band, m.col, m.y)):
                changed += self.improve_node(m, maxcol)
            for m in sorted((m for m in self.N if m.kind == "B"), key=lambda m: (m.band, m.col, m.y)):
                changed += self.improve_group(m, maxcol)
                for dc in (1, -1):
                    g = list(self.push_set(m, dc))
                    if len(g) > 1:
                        changed += self.try_group(g, dc, 0)
            if not changed:
                break

    def snapshot(self):
        return [(n.col, n.y) for n in self.N]

    def restore(self, snap):
        self.cells = defaultdict(list)
        for n, (c, y) in zip(self.N, snap):
            n.col, n.y = c, y
            self.cells[(n.band, c)].append(n)
        self.route_all()

    def anneal(self, rng, moves):
        maxcol = max(n.col for n in self.N) + 1
        blocks = [n for n in self.N if n.kind == "B"]
        for i in range(moves):
            T = SA_T0 * (SA_T1 / SA_T0) ** (i / moves)
            r = rng.random()
            if r < 0.08:
                dc = rng.choice((1, -1))
                self.try_group(list(self.push_set(rng.choice(self.N), dc)), dc, 0, T, rng)
                continue
            if r < 0.35:
                n = rng.choice(blocks)
                g = [n] + self.satellites(n)
            else:
                n = rng.choice(self.N)
                g = [n]
            if len(g) == 1:
                lo, hi = self.col_range(n, maxcol)
                if hi < lo:
                    continue
                col = rng.randint(lo, hi)
                ys = sorted(self.cand_ys(n, col))
                y = rng.choice(ys)
                if (col, y) == (n.col, n.y) or not self.free(n, col, y):
                    continue
                old = (n.col, n.y)
                c0 = self.node_cost(n)
                self.move(n, col, y)
                d = self.node_cost(n) - c0
                if d > 0 and rng.random() >= math.exp(-d / T):
                    self.move(n, *old)
            else:
                lo = max([0] + [w.s.col + 1 for w in n.win if not w.back and w.s not in g])
                hi = min([maxcol] + [w.d.col - 1 for w in n.wout if not w.back and w.d not in g])
                dc = rng.choice((-1, 0, 0, 1))
                dy = rng.choice((-6, -4, -3, -2, -1, 0, 1, 2, 3, 4, 6)) * GRID
                if (dc, dy) == (0, 0) or not (lo <= n.col + dc <= hi) or any(m.col + dc < 0 or m.col + dc > maxcol for m in g):
                    continue
                start = [(m.col, m.y) for m in g]
                if not all(self.free(m, c + dc, y + dy, ignore=g) for m, (c, y) in zip(g, start)):
                    continue
                c0 = self.group_cost(g)
                for m, (c, y) in zip(g, start):
                    self.move(m, c + dc, y + dy)
                d = self.group_cost(g) - c0
                if d > 0 and rng.random() >= math.exp(-d / T):
                    for m, (c, y) in zip(g, start):
                        self.move(m, c, y)

    def optimise(self, log=None):
        self.initial()
        t0 = self.total()
        self.sweeps()
        best, bc = self.snapshot(), self.total()["cost"]
        if log:
            log(f"  greedy: {self.total()}")
        for run in range(SA_RUNS):
            rng = random.Random(zlib.crc32(self.name.encode()) + run)
            self.restore(best)
            self.anneal(rng, SA_MOVES)
            self.sweeps()
            t = self.total()
            if log:
                log(f"  anneal {run + 1}: {t}")
            if t["cost"] < bc:
                best, bc = self.snapshot(), t["cost"]
        self.restore(best)
        # drop empty columns, close the bands up, then repair what closing up disturbed
        used = sorted({n.col for n in self.N})
        remap = {c: i for i, c in enumerate(used)}
        for n in self.N:
            n.col = remap[n.col]
        self.restore(self.snapshot())
        for _ in range(3):
            self.stack_bands(final=True)
            for b in range(len(self.bands)):
                self.band_h[b] += 2 * GRID
            before = self.snapshot()
            self.sweeps(3)
            if self.snapshot() == before:
                break
        self.stack_bands(final=True)
        return t0, self.total()

    def hit_list(self):
        out = []
        for w in self.wires:
            for n in self.N:
                if n is w.s or n is w.d:
                    continue
                if any(poly_hits_box(w.pts, bx) for bx in self.boxes(n)):
                    out.append(f"{w.s.id}.{w.sp} -> {w.d.id}.{w.dp} through {n.id}")
            for bx, t in zip(self._labels, self.bands):
                if poly_hits_box(w.pts, bx):
                    out.append(f"{w.s.id}.{w.sp} -> {w.d.id}.{w.dp} through label {t!r}")
        return out

    # ---------------- result ----------------
    def result(self):
        r = {"blocks": {}, "inpins": {}, "outpins": {}, "labels": []}
        for n in self.N:
            pos = (int(round(n.x())), int(round(self.ay(n))))
            r[{"B": "blocks", "I": "inpins", "O": "outpins"}[n.kind]][n.id] = pos
        for i, t in enumerate(self.bands):
            if t:
                r["labels"].append({"text": t, "x": X0, "y": self.band_top[i]})
        return r


# ============================================================================================================
# segment tests
# ============================================================================================================
def seg_hits_box(p, q, bx):
    x0, y0, x1, y1 = bx[0] - PAD, bx[1] - PAD, bx[2] + PAD, bx[3] + PAD
    (ax, ay), (cx, cy) = p, q
    if max(ax, cx) < x0 or min(ax, cx) > x1 or max(ay, cy) < y0 or min(ay, cy) > y1:
        return False
    dx, dy = cx - ax, cy - ay
    t0, t1 = 0.0, 1.0
    for pp, qq in ((-dx, ax - x0), (dx, x1 - ax), (-dy, ay - y0), (dy, y1 - ay)):
        if pp == 0:
            if qq < 0:
                return False
        else:
            t = qq / pp
            if pp < 0:
                if t > t1:
                    return False
                t0 = max(t0, t)
            else:
                if t < t0:
                    return False
                t1 = min(t1, t)
    return t0 <= t1


def poly_hits_box(pts, bx):
    for i in range(len(pts) - 1):
        if seg_hits_box(pts[i], pts[i + 1], bx):
            return True
    return False


def seg_cross(p, q, r, s):
    """0 = apart, W_CROSS = proper crossing, W_OVERLAP = lying on each other."""
    d1x, d1y = q[0] - p[0], q[1] - p[1]
    d2x, d2y = s[0] - r[0], s[1] - r[1]
    den = d1x * d2y - d1y * d2x
    ex, ey = r[0] - p[0], r[1] - p[1]
    if abs(den) < 1e-9:
        if abs(ex * d1y - ey * d1x) > 1.5 * max(1.0, abs(d1x) + abs(d1y)):      # parallel, apart (scaled distance)
            return 0
        if abs(d1x) >= abs(d1y):
            a0, a1, b0, b1 = sorted((p[0], q[0])) + sorted((r[0], s[0]))
        else:
            a0, a1, b0, b1 = sorted((p[1], q[1])) + sorted((r[1], s[1]))
        return W_OVERLAP if min(a1, b1) - max(a0, b0) > 4 else 0
    t = (ex * d2y - ey * d2x) / den
    u = (ex * d1y - ey * d1x) / den
    return W_CROSS if 0.001 < t < 0.999 and 0.001 < u < 0.999 else 0


def poly_cross(a, b):
    c = 0
    for i in range(len(a) - 1):
        for j in range(len(b) - 1):
            c += seg_cross(a[i], a[i + 1], b[j], b[j + 1])
    return c


# ============================================================================================================
# from a plan application
# ============================================================================================================
def spec_from_plan(a, in_name, out_name, fill=None):
    """in_name(src) / out_name(target) give the interface pin name for a plan pin source / output target, or None."""
    fill = fill or {}
    blocks = []
    labs = sorted(a.get("labels", []), key=lambda l: l["y"])

    def band(b):          # oufplan labels are positional: a block without its own label belongs to the label above it
        if b.get("label"):
            return b["label"]
        over = [l["text"] for l in labs if l["x"] == b["x"] and l["y"] <= b["y"]] or [l["text"] for l in labs if l["y"] <= b["y"]]
        return over[-1] if over else ""
    for b in a["blocks"]:
        pins = OrderedDict()
        for pn, src in b["pins"].items():
            if "wire" in src:
                pins[pn] = ("wire", src["wire"], bool(src.get("feedback")))
            elif in_name(src):
                pins[pn] = ("in", in_name(src))
            elif "setvalue" in src:
                pins[pn] = ("sv",)
            else:
                pins[pn] = ("const",)
        for pn in fill.get(b["type"], {}):
            pins.setdefault(pn, ("const",))
        outs = OrderedDict()
        for pn, targets in b["out"].items():
            outs[pn] = [("ms",) if "measure" in o else ("out", out_name(o)) for o in targets if "measure" in o or out_name(o)]
        blocks.append({"id": b["id"], "type": b["type"], "label": band(b), "exec": b["exec"], "pins": pins, "outs": outs})
    return {"name": a["name"], "blocks": blocks}


def layout_manual(page, man):
    """Hand layout (program dir layout.json, one entry per application) for pages where the flow should read like a drawing:
      {"columns": [["@IN_PIN", "blk", ...], ...],      top-down order per column; "@NAME" = interface pin
       "align": {"blk": "Pin"},                        input pin to put level with its source (default: first placed source)
       "dy": {"blk": 48}, "y": {"blk": 400},           offset from the aligned position / absolute y
       "to": {"@IN_PIN": "blk.Pin"},                   consumer pin an input interface pin is level with (default: its first)
       "labels": [{"text": "...", "above": "blk"}]}
    Blocks and output pins are placed column by column, left to right: level with the source when that is free, else below
    the previous node of the column. Input interface pins are placed last, level with their consumer."""
    key = lambda n: n.id if n.kind == "B" else "@" + n.id
    by = {key(n): n for n in page.N}
    cols = man["columns"]
    listed = [k for c in cols for k in c]
    miss = [k for k in by if k not in listed] + [k + " (unknown)" for k in listed if k not in by]
    if miss or len(set(listed)) != len(listed):
        raise SystemExit(f"layout.json {page.name}: nodes missing / unknown / twice: {miss}")
    lab = {l["above"]: l["text"] for l in man.get("labels", [])}
    align, dy, fixed, to = man.get("align", {}), man.get("dy", {}), man.get("y", {}), man.get("to", {})
    page.bands, page.band_top, page.band_h = [""], [-BAND_HEAD], [0]
    placed = set()
    for n in page.N:
        n.band = 0
    for ci, c in enumerate(cols):
        cur = Y0
        for k in c:
            n = by[k]
            n.col = ci
            if n.kind == "I":
                continue
            ws = [w for w in n.win if key(w.s) in placed]
            want = align.get(k)
            w = next((w for w in ws if w.dp == want), None) if want else (sorted(ws, key=lambda w: n.ins[w.dp])[0] if ws else None)
            lo = cur + (LABEL_H + 4 if k in lab else 0)
            if k in fixed:
                y = fixed[k]
            elif w is not None:
                y = max(w.s.y + w.s.outs[w.sp] - n.ins[w.dp] + dy.get(k, 0), lo)
            else:
                y = lo + dy.get(k, 0)
            n.y = y
            placed.add(k)
            cur = y + n.h + (GAP_BB if n.kind == "B" else GAP_BP)
    for k, n in by.items():
        if n.kind != "I":
            continue
        if k in fixed:
            n.y = fixed[k]
            continue
        ref = to.get(k)
        w = next((w for w in n.wout if f"{w.d.id}.{w.dp}" == ref), None) if ref else n.wout[0]
        n.y = w.d.y + w.d.ins[w.dp] - PIN_LP + dy.get(k, 0)
    labels = [{"text": t, "x": int(by[k].x()), "y": int(round(by[k].y - LABEL_H - 2))} for k, t in lab.items()]
    page.bands = [l["text"] for l in labels]
    page.band_top = [-BAND_HEAD] * max(1, len(labels))
    boxes = [(l["x"], l["y"] + 2, l["x"] + LABEL_CH * len(l["text"]) + 16, l["y"] + LABEL_H - 4) for l in labels]
    page.label_boxes = lambda: boxes
    t = page.total()
    r = {"blocks": {}, "inpins": {}, "outpins": {}, "labels": labels}
    for n in page.N:
        r[{"B": "blocks", "I": "inpins", "O": "outpins"}[n.kind]][n.id] = (int(round(n.x())), int(round(n.y)))
    r["stats"] = {"initial": t, "final": t, "manual": True}
    r["page"] = page
    return r


def layout_app(a, in_name, out_name, fill=None, log=None, manual=None):
    page = Page(spec_from_plan(a, in_name, out_name, fill))
    if manual:
        return layout_manual(page, manual)
    before, after = page.optimise(log=log)
    r = page.result()
    r["stats"] = {"initial": before, "final": after}
    r["page"] = page
    return r


# ============================================================================================================
# preview picture, learning, CLI
# ============================================================================================================
def render(page, path, scale=0.6):
    from PIL import Image, ImageDraw
    W = int((max(n.x() + n.w for n in page.N) + 60) * scale)
    H = int((max(page.ay(n) + n.h for n in page.N) + 40) * scale)
    im = Image.new("RGB", (W, H), "white")
    d = ImageDraw.Draw(im)
    S = lambda v: v * scale
    for bx, t in zip(page.label_boxes(), page.bands):
        d.text((S(bx[0]), S(bx[1]) + 4), t, fill=(200, 0, 0))
    for n in page.N:
        for i, bx in enumerate(page.boxes(n)):
            d.rectangle([S(v) for v in bx], outline="black", fill=(255, 250, 200) if n.kind != "B" else (235, 235, 235) if i else (255, 255, 255))
        x, y = n.x(), page.ay(n)
        if n.kind == "B":
            d.rectangle([S(x), S(y), S(x + n.w), S(y + 30)], fill=(210, 225, 255), outline="black")
        d.text((S(x) + 3, S(y) + 1), n.id[:22], fill="black")
    for w in page.wires:
        d.line([(S(px), S(py)) for px, py in w.pts], fill=(0, 90, 200) if w.pts[-1][0] > w.pts[0][0] else (200, 0, 150), width=1)
    im.save(path)


def learn():
    """sticky pins = pins the tool keeps visible although the plan does not use them (read from the build dumps)."""
    import glob
    sticky = defaultdict(set)
    seen = 0
    for pj in glob.glob(os.path.join(HERE, "..", "examples", "**", "program.json"), recursive=True):
        import make_ouflex_build as mb
        cfg = mb.load_program(os.path.dirname(pj))
        gen = mb.Gen(cfg)
        for a in gen.apps:
            dump = os.path.join(cfg["out_path"], "out", a["name"] + ".dump.txt")
            if not os.path.exists(dump):
                continue
            hidden = defaultdict(set)
            for l in open(dump, encoding="utf-8-sig"):
                f = l.rstrip("\n").split("|")
                if f[0] == "H":
                    blk, pin = f[1].rsplit(".", 1)
                    hidden[blk].add(pin)
            used_out = defaultdict(set)
            for b in a["blocks"]:
                for src in b["pins"].values():
                    if "wire" in src:
                        sb, sp = src["wire"].rsplit(".", 1)
                        used_out[sb].add(sp)
            for b in a["blocks"]:
                seen += 1
                tn = gen.block_name[(a["name"], b["id"])]
                li, lo = lib_pins(b["type"])
                planned = set(b["pins"]) | set(cfg["required_fill"].get(b["type"], {})) | set(b["out"]) | used_out[b["id"]]
                for p in li + lo:
                    if p not in hidden[tn] and p not in planned:
                        sticky[b["type"]].add(p)
    out = {"_source": "ouflayout.py --learn: pins left visible by the tool on blocks where the plan does not use them (from */out/*.dump.txt)",
           "sticky": {t: sorted(v) for t, v in sorted(sticky.items())}}
    json.dump(out, open(STICKY_JSON, "w", encoding="utf-8"), ensure_ascii=False, indent=1)
    print(f"sticky_pins.json: {len(sticky)} block types with sticky pins, from {seen} built blocks")


def main():
    if "--learn" in sys.argv:
        return learn()
    import make_ouflex_build as mb
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    png = None
    if "--png" in sys.argv:
        png = sys.argv[sys.argv.index("--png") + 1]
        args.remove(png)
        os.makedirs(png, exist_ok=True)
    only = None
    if "--app" in sys.argv:
        only = sys.argv[sys.argv.index("--app") + 1]
        args.remove(only)
    if not args:
        raise SystemExit("give a program directory (a folder with program.json and plan.json), e.g. examples/dh-ex2")
    cfg = mb.load_program(args[0])
    gen = mb.Gen(cfg)
    for a in sorted(gen.apps, key=lambda a: a["order"]):
        if only and a["name"] != only:
            continue
        r = gen.layout(a, log=print if "-v" in sys.argv else None)
        s = r["stats"]
        print(f"{a['name']}: {len(a['blocks'])} blocks, {s['final']['wires']} wires | stacked: {s['initial']} | placed: {s['final']}")
        if "-v" in sys.argv:
            for h in r["page"].hit_list():
                print("   hit:", h)
        if png:
            render(r["page"], os.path.join(png, a["name"] + ".png"))


if __name__ == "__main__":
    sys.path.insert(0, HERE)
    main()
