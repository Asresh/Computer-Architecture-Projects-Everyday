#!/usr/bin/env python3
"""Render issue_queue.vcd (captured from a real iverilog run) to
docs/issue_queue_waveform.png.

This is a genuine simulator capture: the VCD that `make icarus` produced is
parsed and the Phase-1 directed scheduler life-cycle is drawn with matplotlib.
Nothing is hand-modeled -- every request vector, wakeup broadcast, granted
entry index, issued payload and occupancy count shown is read straight out of
the VCD.

Each cycle the testbench drives one dispatch attempt / both wakeup buses /
issue_ready / flush; the queue's combinational outputs are read in that same
cycle and the entry state updates on the following rising edge. Every non-clock
signal is sampled once per cycle at its settled pre-edge instant (the same point
the self-checking testbench validates), exactly as a waveform viewer shows one
value per clock.
"""
import os
import re
import textwrap
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

VCD = "issue_queue.vcd"
OUT = os.path.join("docs", "issue_queue_waveform.png")

# 16 directed cycles. c0 applies its inputs at the negedge at t=40 ns
# (#4 settle -> sample at 44, rising edge at 45); cell k spans [40+10k, 50+10k].
NCELL   = 16
T_FIRST = 40
T_STEP  = 10
T0, T1  = 34, T_FIRST + NCELL * T_STEP + 6

ENTRIES = 6


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


def main():
    id2name, changes = parse_vcd(VCD)
    name2sym = {}
    for sym, name in id2name.items():
        name2sym.setdefault(name, sym)   # top (tb) scope seen first -> wins

    def series(name):
        return changes.get(name2sym.get(name, ""), [])

    clk = series("clk")

    samp  = [T_FIRST + 4 + T_STEP * k for k in range(NCELL)]
    edges = [T_FIRST + T_STEP * k for k in range(NCELL + 1)]

    def cell_bits(name):
        s = series(name)
        return [val_at(s, t) for t in samp]

    def cell_ints(name):
        s = series(name)
        return [to_int(val_at(s, t)) for t in samp]

    dv     = cell_bits("disp_valid")
    dr     = cell_bits("disp_ready")
    dop    = cell_ints("disp_op")
    w0v    = cell_bits("w0v")
    w0t    = cell_ints("w0t")
    w1v    = cell_bits("w1v")
    w1t    = cell_ints("w1t")
    req    = cell_ints("dbg_req")
    iv     = cell_bits("issue_valid")
    ir     = cell_bits("issue_ready")
    iidx   = cell_ints("issue_idx")
    iop    = cell_ints("issue_op")
    cnt    = cell_ints("dbg_count")
    fl     = cell_bits("flush")

    # dispatch is only accepted when valid & ready
    dacc = ["1" if (dv[k] == "1" and dr[k] == "1") else "0" for k in range(NCELL)]

    fine = [x * 0.2 for x in range(int(T0 / 0.2), int(T1 / 0.2) + 1)]

    fig, axes = plt.subplots(14, 1, figsize=(17, 13.0), sharex=True)
    fig.suptitle("Day29 - Out-of-Order Issue Queue: CAM wakeup + age-matrix "
                 "oldest-first select   "
                 "(captured from iverilog VCD; directed scheduler life-cycle)",
                 fontsize=13, fontweight="bold")

    def clkrow(ax):
        cv = [1 if (val_at(clk, t) == "1") else 0 for t in fine]
        ax.step(fine, cv, where="post", color="#1f77b4", linewidth=1.4)
        ax.set_ylabel("clk", rotation=0, ha="right", va="center")
        ax.set_ylim(-0.3, 1.3); ax.set_yticks([])

    def digrow(ax, cells, label, color):
        ys = [1 if c == "1" else 0 for c in cells]
        ax.step(edges, ys + [ys[-1]], where="post", color=color, linewidth=1.5)
        ax.set_ylabel(label, rotation=0, ha="right", va="center")
        ax.set_ylim(-0.3, 1.3); ax.set_yticks([])

    def busrow(ax, cells, label, color, fmt, gate=None):
        ax.axhline(0.5, color=color, linewidth=1.0, alpha=0.28)
        for k in range(NCELL):
            if gate is not None and gate[k] != "1":
                continue
            v = cells[k]
            if v is None:
                continue
            xc = edges[k] + T_STEP / 2.0
            ax.text(xc, 0.5, fmt(v), va="center", ha="center",
                    fontsize=8, family="monospace", color=color)
            ax.axvline(edges[k], color=color, linewidth=0.6, alpha=0.35)
        ax.set_ylabel(label, rotation=0, ha="right", va="center")
        ax.set_ylim(0, 1); ax.set_yticks([])

    opf   = lambda v: f"{v:02X}"
    tagf  = lambda v: f"p{v}"
    decf  = lambda v: f"{v}"
    entf  = lambda v: f"e{v}"
    maskf = lambda v: format(v, f"0{ENTRIES}b")

    clkrow(axes[0])
    digrow(axes[1], dv,  "disp_valid",  "#1f77b4")
    digrow(axes[2], dr,  "disp_ready",  "#d62728")
    busrow(axes[3], dop, "disp_op",     "#1f77b4", opf, gate=dacc)
    busrow(axes[4], w0t, "wake0_tag",   "#ff7f0e", tagf, gate=w0v)
    busrow(axes[5], w1t, "wake1_tag",   "#ff7f0e", tagf, gate=w1v)
    busrow(axes[6], req, "dbg_req[5:0]", "#9467bd", maskf)
    digrow(axes[7], iv,  "issue_valid", "#2ca02c")
    digrow(axes[8], ir,  "issue_ready", "#8c564b")
    busrow(axes[9], iidx, "issue_idx",  "#2ca02c", entf, gate=iv)
    busrow(axes[10], iop, "issue_op",   "#2ca02c", opf,  gate=iv)
    busrow(axes[11], cnt, "occupancy",  "#7f7f7f", decf)
    digrow(axes[12], fl, "flush",       "#d62728")

    # cycle-number ruler
    axr = axes[13]
    axr.set_ylim(0, 1); axr.set_yticks([])
    axr.set_ylabel("cycle", rotation=0, ha="right", va="center")
    for k in range(NCELL):
        axr.text(edges[k] + T_STEP / 2.0, 0.5, f"c{k}", va="center",
                 ha="center", fontsize=8, color="0.35")
        axr.axvline(edges[k], color="0.85", linewidth=0.6)

    axes[-1].set_xlabel("time (ns)")
    axes[-1].set_xlim(T0, T1)
    axes[-1].set_xticks(range(T_FIRST, T1 + 1, T_STEP))
    for ax in axes:
        ax.grid(axis="x", color="0.90", linewidth=0.5)

    cap = ("Real iverilog capture of the Phase-1 directed life-cycle (compact "
           "demo config ENTRIES=6, TAGW=5, NWAKE=2). c0 dispatches A(op A1, both "
           "operands ready); c1 dispatches B(waiting on p8) and issues A from e0. "
           "c2 dispatches C(waiting on p9 and p8) -- nothing is ready, dbg_req=0. "
           "c3 broadcasts p8 on wake0: B WAKES AND IS SELECTED IN THE SAME CYCLE "
           "(back-to-back dependent issue) -- req 000010 -> issue e1/op B2. c4 "
           "issues D from e2 OUT OF ORDER, past the older C in e0 that is still "
           "waiting on p9. c5 broadcasts p9 and p11 on BOTH result buses at once: "
           "C(e0) and E(e1) wake together (req 000011) and the age matrix picks "
           "the OLDER one -- e0/op C3. c6 drops issue_ready: E is still granted "
           "(issue_valid=1, e1) but the FU refuses, so the entry stays and "
           "re-arbitrates; c7 accepts it. c8-c11 fill the queue with "
           "operand-starved uops (occupancy 2->6), so at c12 disp_ready falls and "
           "the offered instruction is refused. c13 asserts flush: all six entries "
           "are squashed in one cycle (occupancy 6 -> 0 at c14). c14 dispatches "
           "fresh work into the emptied queue and c15 issues it from e0. Every "
           "value shown is read out of the VCD, not modeled.")
    fig.text(0.5, 0.004, textwrap.fill(cap, 200), ha="center", fontsize=8,
             color="0.25")

    fig.tight_layout(rect=[0, 0.075, 1, 0.965])
    os.makedirs("docs", exist_ok=True)
    fig.savefig(OUT, dpi=130)
    print(f"wrote {OUT}")


if __name__ == "__main__":
    main()
