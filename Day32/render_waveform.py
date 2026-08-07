#!/usr/bin/env python3
"""Render dram_scheduler.vcd (captured from a real iverilog run) to
docs/dram_scheduler_waveform.png.

This is a genuine simulator capture: the VCD that `make icarus` produced is
parsed and the Phase-1 directed window is drawn with matplotlib.  Nothing is
hand-modeled -- every command, bank/row/column address, tag, timer value and
queue occupancy shown is read straight out of the VCD.

Every non-clock signal is sampled once per cycle at its settled pre-edge
instant (the same point the self-checking testbench validates), exactly as a
waveform viewer shows one value per clock.
"""
import os
import re
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import Polygon

VCD = "dram_scheduler.vcd"
OUT = os.path.join("docs", "dram_scheduler_waveform.png")

# The testbench prints PHASE1_T0 = 40000 ps, so cycle c0 applies its inputs at
# the negedge at t = 40 ns (settle -> sample at 44, rising edge at 45); cell k
# spans [40 + 10k, 50 + 10k].
NCELL   = 16
T_FIRST = 40
T_STEP  = 10

NBANKS = 4

C_BG      = "#ffffff"
C_GRID    = "#e6e6e6"
C_HI      = "#1f77b4"
C_BUS     = "#eef4fb"
C_BUS_ED  = "#5b7fa6"
C_IDLE    = "#f2f2f2"
C_IDLE_ED = "#c8c8c8"
C_ACT     = "#d95f02"      # activate  - open a row
C_PRE     = "#d62728"      # precharge - close a row
C_COL     = "#2ca02c"      # column access - the actual data transfer
C_BYP     = "#7d3c98"      # column access issued out of order
C_OPEN    = "#4c9f70"      # bank holding an open row
C_BUSY    = "#f0ad4e"      # bank / data bus inside a timing window
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
def draw_clock(ax, y, h, t1):
    xs, ys = [], []
    t = T_FIRST
    while t <= t1:
        xs += [t, t + 5, t + 5, t + 10]
        ys += [y, y, y + h, y + h]
        t += 10
    ax.plot(xs, ys, color=C_HI, lw=1.3, solid_joinstyle="miter")


def draw_bit(ax, y, h, edges, vals):
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


def draw_bus(ax, y, h, edges, labels, colors=None, edgecols=None, fs=6.6):
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


def tint(hexcol, f=0.82):
    """Blend a colour towards white so it can carry black text."""
    r = int(hexcol[1:3], 16); g = int(hexcol[3:5], 16); b = int(hexcol[5:7], 16)
    r = int(r + (255 - r) * f); g = int(g + (255 - g) * f); b = int(b + (255 - b) * f)
    return "#%02x%02x%02x" % (r, g, b)


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

    rv    = bits("req_valid")
    rrdy  = bits("req_ready")
    rbank = ints("dbg_reqbank")
    rrow  = ints("dbg_reqrow")
    rcol  = ints("dbg_reqcol")
    rid   = ints("req_id")

    cv    = bits("cmd_valid")
    cop   = ints("cmd_op")
    cbank = ints("cmd_bank")
    crow  = ints("cmd_row")
    ccol  = ints("cmd_col")
    cid   = ints("cmd_id")
    cwe   = bits("cmd_we")
    cbyp  = bits("cmd_bypass")

    qcnt  = ints("q_count")
    cap   = ints("dbg_cap")
    bact  = ints("bank_active")
    brow  = [ints("dbg_row%d" % b) for b in range(NBANKS)]
    btmr  = [ints("dbg_tmr%d" % b) for b in range(NBANKS)]
    dtmr  = bits("dbg_dtmr")

    # ---- request row -------------------------------------------------------
    req_lab, req_col, req_ec = [], [], []
    for k in range(NCELL):
        if rv[k] != "1":
            req_lab.append(""); req_col.append(None); req_ec.append(None)
        else:
            req_lab.append("b%d r%d c%d\n#%d" %
                           (rbank[k], rrow[k], rcol[k], rid[k]))
            req_col.append(C_BUS); req_ec.append(C_BUS_ED)

    # ---- DRAM command row --------------------------------------------------
    cmd_lab, cmd_col, cmd_ec = [], [], []
    for k in range(NCELL):
        if cv[k] != "1":
            cmd_lab.append("NOP"); cmd_col.append(C_IDLE); cmd_ec.append(C_IDLE_ED)
        elif cop[k] == 1:
            cmd_lab.append("ACT b%d\nrow%d" % (cbank[k], crow[k]))
            cmd_col.append(tint(C_ACT)); cmd_ec.append(C_ACT)
        elif cop[k] == 0:
            cmd_lab.append("PRE b%d" % cbank[k])
            cmd_col.append(tint(C_PRE)); cmd_ec.append(C_PRE)
        else:
            tail = " BYPASS" if cbyp[k] == "1" else ""
            cmd_lab.append("%s b%d c%d\n#%d%s" %
                           ("WR" if cwe[k] == "1" else "RD",
                            cbank[k], ccol[k], cid[k], tail))
            base = C_BYP if cbyp[k] == "1" else C_COL
            cmd_col.append(tint(base)); cmd_ec.append(base)

    # ---- per-bank row-buffer state ----------------------------------------
    bank_lab, bank_col, bank_ec = [], [], []
    for b in range(NBANKS):
        lab, col, ec = [], [], []
        for k in range(NCELL):
            open_now = ((bact[k] >> b) & 1) == 1
            busy     = (btmr[b][k] or 0) > 0
            if open_now:
                lab.append("row%d open%s" % (brow[b][k], "\nbusy %d" % btmr[b][k]
                                             if busy else ""))
                col.append(tint(C_BUSY) if busy else tint(C_OPEN))
                ec.append(C_BUSY if busy else C_OPEN)
            else:
                lab.append("closed%s" % ("\nbusy %d" % btmr[b][k] if busy else ""))
                col.append(tint(C_BUSY) if busy else C_IDLE)
                ec.append(C_BUSY if busy else C_IDLE_ED)
        bank_lab.append(lab); bank_col.append(col); bank_ec.append(ec)

    # ---- shared data bus ---------------------------------------------------
    dq_lab, dq_col, dq_ec = [], [], []
    for k in range(NCELL):
        if cv[k] == "1" and cop[k] == 2:
            dq_lab.append("xfer #%d" % cid[k])
            dq_col.append(tint(C_COL)); dq_ec.append(C_COL)
        elif dtmr[k] == "1":
            dq_lab.append("busy\ntBURST")
            dq_col.append(tint(C_BUSY)); dq_ec.append(C_BUSY)
        else:
            dq_lab.append(""); dq_col.append(None); dq_ec.append(None)

    q_lab   = ["%d" % (qcnt[k] or 0) for k in range(NCELL)]
    cap_lab = ["%d" % (cap[k] or 0) for k in range(NCELL)]

    # ----------------------------------------------------------------------
    # Layout
    # ----------------------------------------------------------------------
    BIT_H, BUS_H, GAP = 0.62, 0.98, 0.30
    rows = [
        ("clk",                 "clk", None),
        ("incoming request",    "bus", (req_lab, req_col, req_ec)),
        ("req_ready",           "bit", rrdy),
        ("SEP",                 "sep", None),
        ("DRAM command bus",    "bus", (cmd_lab, cmd_col, cmd_ec)),
        ("cmd_bypass",          "bit", cbyp),
        ("shared DQ bus",       "bus", (dq_lab, dq_col, dq_ec)),
        ("SEP",                 "sep", None),
        ("bank0 row buffer",    "bus", (bank_lab[0], bank_col[0], bank_ec[0])),
        ("bank1 row buffer",    "bus", (bank_lab[1], bank_col[1], bank_ec[1])),
        ("bank2 row buffer",    "bus", (bank_lab[2], bank_col[2], bank_ec[2])),
        ("bank3 row buffer",    "bus", (bank_lab[3], bank_col[3], bank_ec[3])),
        ("SEP",                 "sep", None),
        ("queue occupancy",     "bus", (q_lab, None, None)),
        ("bypass cap counter",  "bus", (cap_lab, None, None)),
    ]

    total_h = 0.0
    for (_, kind, _) in rows:
        total_h += (0.18 if kind == "sep" else
                    (BIT_H if kind in ("bit", "clk") else BUS_H) + GAP)

    fig_h = total_h * 0.42 + 2.35
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
            draw_clock(ax, y, h, edges[-1])
        elif kind == "bit":
            draw_bit(ax, y, h, edges, payload)
        else:
            lab, col, ec = payload
            draw_bus(ax, y, h, edges, lab, col, ec)

    for k in range(NCELL + 1):
        ax.plot([edges[k], edges[k]], [0, total_h], color=C_GRID, lw=0.5,
                zorder=0)
    for k in range(NCELL):
        ax.text((edges[k] + edges[k + 1]) / 2, total_h + 0.22, "c%d" % k,
                ha="center", va="bottom", fontsize=7.2, color="#666666")

    ax.set_xlim(edges[0] - 19.0, edges[-1] + 0.6)
    ax.set_ylim(-1.85, total_h + 1.05)
    ax.axis("off")

    ax.text(edges[0] - 18.5, total_h + 0.72,
            "Day32  FR-FCFS DRAM Memory-Access Scheduler  -  captured from the "
            "Icarus Verilog run (dram_scheduler.vcd), Phase-1 directed window",
            fontsize=10.4, color=C_TXT, ha="left", va="bottom", weight="bold")

    caption = (
        "Five requests arrive: A=bank0/row5/col0, B=bank0/row5/col1, "
        "C=bank1/row9, D=bank0/row7 (a conflict), E=bank0/row5 (a hit, younger "
        "than D).   c0 the queue is still empty at the command bus, so NOP.   "
        "c1 A activates row5 in bank0; c3 C activates row9 in bank1 WHILE bank0 "
        "is still in tRCD - that overlap is bank-level parallelism.\n"
        "c4/c6 A and B transfer back to back: each is a row-buffer HIT costing "
        "one command, and the gaps at c5/c7 are the shared DQ bus serving the "
        "previous burst (tBURST=2), not the banks.   c8 C transfers from the "
        "other bank.\n"
        "c9 D is now the oldest request, but it needs row7 while row5 is open "
        "and still has a customer (E), so the scheduler refuses to precharge.   "
        "c10 E's column access is issued AHEAD of the older D - cmd_bypass=1, "
        "and the bypass-cap counter ticks to 1.   This one reorder is the whole "
        "of FR-FCFS: E cost 1 command instead of 3.\n"
        "c12 with no hits left, bank0 finally precharges for D; c13-c14 are "
        "tRP dead time; c15 row7 activates.  D's transfer lands at c18 - "
        "3 commands and ~9 cycles, versus 1 command for a hit.   Bank state is "
        "the REGISTERED value at the start of each cycle, so a command issued "
        "in cycle c first shows up in c+1."
    )
    ax.text(edges[0] - 18.5, -0.30, caption, fontsize=7.9, color="#333333",
            ha="left", va="top", linespacing=1.55)

    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    plt.tight_layout()
    plt.savefig(OUT, dpi=185, facecolor=C_BG, bbox_inches="tight")
    print("wrote", OUT)


if __name__ == "__main__":
    main()
