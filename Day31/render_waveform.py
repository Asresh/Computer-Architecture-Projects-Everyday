#!/usr/bin/env python3
"""Render mshr_file.vcd (captured from a real iverilog run) to
docs/mshr_file_waveform.png.

This is a genuine simulator capture: the VCD that `make icarus` produced is
parsed and the Phase-1 directed window is drawn with matplotlib.  Nothing is
hand-modeled -- every address, MSHR id, fill tag, replayed word and per-entry
state shown is read straight out of the VCD.

Each cycle the testbench applies one access / one fill and the DUT's
combinational outputs settle; every non-clock signal is sampled once per cycle
at its settled pre-edge instant (the same point the self-checking testbench
validates), exactly as a waveform viewer shows one value per clock.
"""
import os
import re
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import Polygon

VCD = "mshr_file.vcd"
OUT = os.path.join("docs", "mshr_file_waveform.png")

# The testbench prints PHASE1_T0 = 40000 ps, so cycle c0 applies its inputs at
# the negedge at t = 40 ns (settle -> sample at 44, rising edge at 45); cell k
# spans [40 + 10k, 50 + 10k].
NCELL   = 16
T_FIRST = 40
T_STEP  = 10

WORDS = 4          # words per block (must match the TB config)

C_BG      = "#ffffff"
C_GRID    = "#e6e6e6"
C_HI      = "#1f77b4"     # logic-1 level
C_LO      = "#9aa0a6"     # logic-0 level
C_BUS     = "#eef4fb"
C_BUS_ED  = "#5b7fa6"
C_IDLE    = "#f2f2f2"
C_IDLE_ED = "#c8c8c8"
C_PRIM    = "#d95f02"     # primary miss  (memory transaction issued)
C_SEC     = "#2ca02c"     # secondary merge (free ride)
C_STALL   = "#d62728"     # req_ready = 0
C_FETCH   = "#f0ad4e"     # MSHR waiting on memory
C_FILLED  = "#4c9f70"     # MSHR filled, replaying
C_TXT     = "#1a1a1a"


# --------------------------------------------------------------------------
# VCD parsing
# --------------------------------------------------------------------------
def parse_vcd(path):
    id2name, changes = {}, {}
    cur_t, in_defs = 0.0, True
    PS_PER_NS = 1000.0
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            if in_defs:
                if line.startswith("$var"):
                    toks = line.split()
                    sym, name = toks[3], toks[4]
                    id2name.setdefault(sym, name)
                    changes.setdefault(sym, [])
                elif line.startswith("$enddefinitions"):
                    in_defs = False
                continue
            if line[0] == "#":
                cur_t = int(line[1:]) / PS_PER_NS
            elif line[0] in "01xzXZ":
                sym = line[1:]
                if sym in changes:
                    changes[sym].append((cur_t, line[0]))
            elif line[0] in "bB":
                m = re.match(r"[bB]([01xzXZ]+)\s+(\S+)", line)
                if m and m.group(2) in changes:
                    changes[m.group(2)].append((cur_t, m.group(1)))
    return id2name, changes


def val_at(series, t):
    v = None
    for (ct, cv) in series:
        if ct <= t + 1e-9:
            v = cv
        else:
            break
    return v


def to_int(bits):
    if bits is None or any(c in "xzXZ" for c in bits):
        return None
    return int(bits, 2)


# --------------------------------------------------------------------------
# Drawing primitives
# --------------------------------------------------------------------------
def draw_clock(ax, y, h, t0, t1):
    """Real clock: 10 ns period, rising edge at 45, 55, ... (from the VCD)."""
    xs, ys = [], []
    t = T_FIRST
    while t <= t1:
        xs += [t, t + 5, t + 5, t + 10]
        ys += [y, y, y + h, y + h]
        t += 10
    # the VCD clock is low from the negedge to the next posedge (+5 ns)
    ax.plot(xs, ys, color=C_HI, lw=1.3, solid_joinstyle="miter")


def draw_bit(ax, y, h, edges, vals):
    """One-bit signal drawn as a real level line with vertical transitions."""
    xs, ys = [], []
    prev = None
    for k, v in enumerate(vals):
        lvl = y + h if v == "1" else y
        if prev is not None and lvl != prev:
            xs.append(edges[k]); ys.append(prev)
        xs.append(edges[k]);     ys.append(lvl)
        xs.append(edges[k + 1]); ys.append(lvl)
        prev = lvl
    ax.plot(xs, ys, color=C_HI, lw=1.5, solid_joinstyle="miter")
    ax.axhline(y, xmin=0, xmax=1, color=C_GRID, lw=0.4, zorder=0)


def draw_bus(ax, y, h, edges, labels, colors=None, edgecols=None, fs=6.3):
    """Bus row: one hexagon per cycle with a text value."""
    for k, lab in enumerate(labels):
        x0, x1 = edges[k], edges[k + 1]
        m = 0.9
        fc = (colors[k] if colors else None) or C_BUS
        ec = (edgecols[k] if edgecols else None) or C_BUS_ED
        if lab is None or lab == "":
            fc, ec = C_IDLE, C_IDLE_ED
        pts = [(x0, y + h / 2), (x0 + m, y + h), (x1 - m, y + h),
               (x1, y + h / 2), (x1 - m, y), (x0 + m, y)]
        ax.add_patch(Polygon(pts, closed=True, facecolor=fc, edgecolor=ec,
                             lw=0.8, zorder=2))
        if lab:
            ax.text((x0 + x1) / 2, y + h / 2, lab, ha="center", va="center",
                    fontsize=fs, color=C_TXT, zorder=3, linespacing=1.15,
                    fontfamily="DejaVu Sans Mono")


def main():
    id2name, changes = parse_vcd(VCD)
    name2sym = {}
    for sym, name in id2name.items():
        name2sym.setdefault(name, sym)   # top (tb) scope seen first -> wins

    def series(name):
        return changes.get(name2sym.get(name, ""), [])

    samp  = [T_FIRST + 4 + T_STEP * k for k in range(NCELL)]
    edges = [T_FIRST + T_STEP * k for k in range(NCELL + 1)]

    def bits(name):
        s = series(name)
        return [val_at(s, t) for t in samp]

    def ints(name):
        s = series(name)
        return [to_int(val_at(s, t)) for t in samp]

    rv   = bits("req_valid")
    ra   = ints("req_addr")
    rd   = ints("req_dst")
    rrdy = bits("req_ready")
    rpri = bits("req_primary")
    rsec = bits("req_secondary")
    rid  = ints("req_id")

    mrdy = bits("mem_req_ready")
    mv   = bits("mem_req_valid")
    ma   = ints("mem_req_addr")
    mid  = ints("mem_req_id")

    fv   = bits("fill_valid")
    fid  = ints("fill_id")

    pv   = bits("rpl_valid")
    pdst = ints("rpl_dst")
    pdat = ints("rpl_data")
    plast= bits("rpl_last")

    fullv = bits("full")
    nout  = ints("n_outstanding")

    vq = [bits("dbg_v%d" % i) for i in range(4)]
    dq = [bits("dbg_d%d" % i) for i in range(4)]

    # ---- derived label rows ----
    req_lab, req_col, req_ec = [], [], []
    for k in range(NCELL):
        if rv[k] != "1":
            req_lab.append(""); req_col.append(None); req_ec.append(None)
        else:
            req_lab.append("blk%d.w%d" % (ra[k] // WORDS, ra[k] % WORDS))
            req_col.append(C_BUS); req_ec.append(C_BUS_ED)

    dst_lab = ["x%d" % rd[k] if rv[k] == "1" else "" for k in range(NCELL)]

    out_lab, out_col, out_ec = [], [], []
    for k in range(NCELL):
        if rv[k] != "1":
            out_lab.append(""); out_col.append(None); out_ec.append(None)
        elif rpri[k] == "1":
            out_lab.append("PRIMARY\nid%d" % rid[k])
            out_col.append("#fde3cf"); out_ec.append(C_PRIM)
        elif rsec[k] == "1":
            out_lab.append("MERGE\nid%d" % rid[k])
            out_col.append("#d8f0dd"); out_ec.append(C_SEC)
        else:
            reason = "file full" if fullv[k] == "1" else "bus busy"
            out_lab.append("STALL\n%s" % reason)
            out_col.append("#fadbdc"); out_ec.append(C_STALL)

    mem_lab, mem_col, mem_ec = [], [], []
    for k in range(NCELL):
        if mv[k] == "1" and mrdy[k] == "1":
            mem_lab.append("blk%d\n-> id%d" % (ma[k], mid[k]))
            mem_col.append("#fde3cf"); mem_ec.append(C_PRIM)
        elif mv[k] == "1":
            mem_lab.append("refused")
            mem_col.append("#fadbdc"); mem_ec.append(C_STALL)
        else:
            mem_lab.append(""); mem_col.append(None); mem_ec.append(None)

    fill_lab, fill_col, fill_ec = [], [], []
    for k in range(NCELL):
        if fv[k] == "1":
            fill_lab.append("id%d" % fid[k])
            fill_col.append("#e8e2f7"); fill_ec.append("#7d6bb0")
        else:
            fill_lab.append(""); fill_col.append(None); fill_ec.append(None)

    rpl_lab, rpl_col, rpl_ec = [], [], []
    for k in range(NCELL):
        if pv[k] == "1":
            tail = "\nLAST" if plast[k] == "1" else ""
            rpl_lab.append("x%d<=%08X%s" % (pdst[k], pdat[k], tail))
            rpl_col.append("#d8f0dd" if plast[k] == "1" else "#eaf6ee")
            rpl_ec.append(C_FILLED)
        else:
            rpl_lab.append(""); rpl_col.append(None); rpl_ec.append(None)

    mshr_lab, mshr_col, mshr_ec = [], [], []
    for i in range(4):
        lab, col, ec = [], [], []
        for k in range(NCELL):
            if vq[i][k] != "1":
                lab.append(""); col.append(None); ec.append(None)
            elif dq[i][k] == "1":
                lab.append("FILLED"); col.append("#dcefe4"); ec.append(C_FILLED)
            else:
                lab.append("FETCH"); col.append("#fdeccd"); ec.append(C_FETCH)
        mshr_lab.append(lab); mshr_col.append(col); mshr_ec.append(ec)

    mlp_lab = ["%d" % nout[k] for k in range(NCELL)]
    mlp_col = ["#dbe9f6" if (nout[k] or 0) > 1 else C_IDLE for k in range(NCELL)]
    mlp_ec  = [C_BUS_ED   if (nout[k] or 0) > 1 else C_IDLE_ED for k in range(NCELL)]

    # ----------------------------------------------------------------------
    # Layout
    # ----------------------------------------------------------------------
    BIT_H, BUS_H, GAP = 0.62, 0.98, 0.30
    rows = [
        ("clk",             "clk",  None),
        ("req_valid",       "bit",  rv),
        ("req_addr",        "bus",  (req_lab, req_col, req_ec)),
        ("req_dst",         "bus",  (dst_lab, None, None)),
        ("lookup result",   "bus",  (out_lab, out_col, out_ec)),
        ("req_ready",       "bit",  rrdy),
        ("SEP",             "sep",  None),
        ("mem_req_ready",   "bit",  mrdy),
        ("mem fetch out",   "bus",  (mem_lab, mem_col, mem_ec)),
        ("fill return in",  "bus",  (fill_lab, fill_col, fill_ec)),
        ("SEP",             "sep",  None),
        ("rpl_valid",       "bit",  pv),
        ("replay to core",  "bus",  (rpl_lab, rpl_col, rpl_ec)),
        ("SEP",             "sep",  None),
        ("MSHR0",           "bus",  (mshr_lab[0], mshr_col[0], mshr_ec[0])),
        ("MSHR1",           "bus",  (mshr_lab[1], mshr_col[1], mshr_ec[1])),
        ("MSHR2",           "bus",  (mshr_lab[2], mshr_col[2], mshr_ec[2])),
        ("MSHR3",           "bus",  (mshr_lab[3], mshr_col[3], mshr_ec[3])),
        ("MLP (n_outstanding)", "bus", (mlp_lab, mlp_col, mlp_ec)),
        ("full",            "bit",  fullv),
    ]

    total_h = 0.0
    for (_, kind, _) in rows:
        total_h += (0.18 if kind == "sep" else
                    (BIT_H if kind in ("bit", "clk") else BUS_H) + GAP)

    fig_h = total_h * 0.42 + 2.05
    fig, ax = plt.subplots(figsize=(17.2, fig_h), facecolor=C_BG)
    ax.set_facecolor(C_BG)

    y = total_h
    for (name, kind, payload) in rows:
        if kind == "sep":
            y -= 0.18
            ax.plot([edges[0], edges[-1]], [y + 0.09, y + 0.09],
                    color="#cfcfcf", lw=0.7, ls=(0, (4, 3)), zorder=1)
            continue
        h = BIT_H if kind in ("bit", "clk") else BUS_H
        y -= (h + GAP)
        ax.text(edges[0] - 2.0, y + h / 2, name, ha="right", va="center",
                fontsize=7.6, color=C_TXT)
        if kind == "clk":
            draw_clock(ax, y, h, edges[0], edges[-1])
        elif kind == "bit":
            draw_bit(ax, y, h, edges, payload)
        else:
            lab, col, ec = payload
            draw_bus(ax, y, h, edges, lab, col, ec)

    # cycle grid + numbers
    for k in range(NCELL + 1):
        ax.plot([edges[k], edges[k]], [0, total_h], color=C_GRID, lw=0.5,
                zorder=0)
    for k in range(NCELL):
        ax.text((edges[k] + edges[k + 1]) / 2, total_h + 0.22, "c%d" % k,
                ha="center", va="bottom", fontsize=7.2, color="#666666")

    ax.set_xlim(edges[0] - 15.5, edges[-1] + 0.6)
    ax.set_ylim(-1.55, total_h + 1.05)
    ax.axis("off")

    ax.text(edges[0] - 15.0, total_h + 0.72,
            "Day31  Non-Blocking (Lockup-Free) Cache MSHR File  -  captured from "
            "the Icarus Verilog run (mshr_file.vcd), Phase-1 directed window",
            fontsize=10.4, color=C_TXT, ha="left", va="bottom", weight="bold")

    caption = (
        "c0 blk5 misses -> PRIMARY, MSHR0 allocated and one fetch issued.   "
        "c1 blk5 again -> SECONDARY: merged as a second target, mem_req stays "
        "LOW (no duplicate fetch).   c2-c3 two more primaries -> 3 fetches in "
        "flight at once (MLP=3), the whole point of a lockup-free cache.\n"
        "c4 the blk6 fill returns FIRST, out of allocation order.   c5 its "
        "single target replays and LAST frees MSHR1.   c6 a new miss reuses "
        "that entry.   c7 blk5 fills; c8-c9 replay BOTH of its targets in "
        "merge order (x1<=word0, then x2<=word2) before freeing MSHR0.\n"
        "c11 the file fills up; c12 the next miss STALLS (full=1) - the point "
        "where a non-blocking cache finally blocks.   c13-c14 blk7 returns and "
        "replays.   c15 a miss while the bus refuses (mem_req_ready=0): "
        "mem_req_valid still asserts, but req_ready does not.\n"
        "The MSHR0-3 rows show the REGISTERED entry state at the start of each "
        "cycle, so an allocation made in cycle c first appears in c+1."
    )
    ax.text(edges[0] - 15.0, -0.30, caption, fontsize=7.9, color="#333333",
            ha="left", va="top", linespacing=1.55)

    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    plt.tight_layout()
    plt.savefig(OUT, dpi=185, facecolor=C_BG, bbox_inches="tight")
    print("wrote", OUT)


if __name__ == "__main__":
    main()
