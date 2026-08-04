#!/usr/bin/env python3
"""Render register_rename.vcd (captured from a real iverilog run) to
docs/register_rename_waveform.png.

This is a genuine simulator capture: the VCD that `make icarus` produced is
parsed and the Phase-1 directed life-cycle scenario is drawn with matplotlib.
Nothing is hand-modeled -- every RAT mapping, allocated / recycled physical
register, free count, stall and free-list return shown is read straight out of
the VCD.

Each request is presented for one clock; the rename unit is read combinationally
in that cycle and the RAT / free list update on the following rising edge. Every
non-clock signal is sampled once per cycle at its settled pre-edge instant (the
same point the self-checking testbench validates), exactly as a waveform viewer
shows one value per clock.
"""
import os
import re
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

VCD = "register_rename.vcd"
OUT = os.path.join("docs", "register_rename_waveform.png")

# 13 directed requests. Phase-1 c0 applies its inputs at the negedge at t=40 ns
# (#4 settle -> sample at 44, rising edge at 45); cell k is drawn over
# [40+10k, 50+10k].
NCELL   = 13
T_FIRST = 40
T_STEP  = 10
T0, T1  = 34, T_FIRST + NCELL * T_STEP + 6


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

    rvalid = cell_bits("rename_valid")
    rd     = cell_ints("rd")
    psrc1  = cell_ints("psrc1")
    psrc2  = cell_ints("psrc2")
    alloc  = cell_bits("alloc")
    pdst   = cell_ints("pdst")
    pold   = cell_ints("pold")
    stall  = cell_bits("stall")
    fv     = cell_bits("free_valid")
    fp     = cell_ints("free_preg")
    fcnt   = cell_ints("dbg_free_count")

    fine = [x * 0.2 for x in range(int(T0 / 0.2), int(T1 / 0.2) + 1)]

    fig, axes = plt.subplots(13, 1, figsize=(16, 12.5), sharex=True)
    fig.suptitle("Day28 - Explicit Register Renaming Unit (RAT + Free List)   "
                 "(captured from iverilog VCD; directed life-cycle)",
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

    archf = lambda v: f"x{v}"
    physf = lambda v: f"p{v}"
    decf  = lambda v: f"{v}"

    clkrow(axes[0])
    digrow(axes[1], rvalid, "rename_valid", "#1f77b4")
    busrow(axes[2], rd,    "rd (arch)",  "#8c564b", archf, gate=rvalid)
    busrow(axes[3], psrc1, "psrc1",      "#ff7f0e", physf, gate=rvalid)
    busrow(axes[4], psrc2, "psrc2",      "#ff7f0e", physf, gate=rvalid)
    digrow(axes[5], alloc, "alloc",      "#2ca02c")
    busrow(axes[6], pdst,  "pdst (new)", "#2ca02c", physf, gate=alloc)
    busrow(axes[7], pold,  "pold (free later)", "#9467bd", physf, gate=alloc)
    digrow(axes[8], stall, "stall",      "#d62728")
    digrow(axes[9], fv,    "free_valid", "#17becf")
    busrow(axes[10], fp,   "free_preg",  "#17becf", physf, gate=fv)
    busrow(axes[11], fcnt, "free_count", "#7f7f7f", decf)

    # cycle-number ruler
    axr = axes[12]
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
           "demo config NARCH=8, NPHYS=12 -> 4 free physicals {p8,p9,p10,p11}). "
           "c0 renames x1=x2+x3: alloc p8, old x1 mapping p1 saved as 'pold'. c1 "
           "(x1=x1+x4) shows both WAW and RAW-through-rename -- psrc1=p8 reads the "
           "just-installed mapping while a fresh p9 is allocated for the new x1. "
           "c2 allocs p10 (x5). c3 writes x0: rd=x0 so alloc stays low (x0 is "
           "never renamed). c4 allocs p11 -- the pool now empties (free_count 0). "
           "c5 requests another alloc with an empty pool -> STALL, no state "
           "change. c6/c7 are pure commits returning p1 then p10 to the pool. c8 "
           "renames AND frees in the same cycle (alloc p1 recycled + free p11): "
           "free_count holds. c9 recycles p10, c10 allocs p11 (pool empties "
           "again), c11 STALLs, c12 commits p9. Every value shown is read out of "
           "the VCD, not modeled.")
    fig.text(0.5, 0.004, cap, ha="center", fontsize=8, wrap=True, color="0.25")

    fig.tight_layout(rect=[0, 0.055, 1, 0.965])
    os.makedirs("docs", exist_ok=True)
    fig.savefig(OUT, dpi=130)
    print(f"wrote {OUT}")


if __name__ == "__main__":
    main()
