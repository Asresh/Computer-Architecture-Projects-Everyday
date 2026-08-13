#!/usr/bin/env python3
"""Render stride_prefetcher.vcd (captured from a real iverilog run) to
docs/stride_prefetcher_waveform.png.

This is a genuine simulator capture: the VCD that `make icarus` produced is
parsed and the Phase-1 directed scenario is drawn with matplotlib. Nothing is
hand-modeled -- every RPT state, stride, hit and prefetch address shown is read
straight out of the VCD.

Each access is presented for one clock; the RPT is read combinationally in that
cycle and updated on the following rising edge. So every non-clock signal is
sampled once per cycle at its settled point (the same pre-edge instant the
self-checking testbench validates), exactly as a waveform viewer shows one
value per clock -- avoiding the 1 ns combinational sliver at the clock edge.
"""
import os
import re
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

VCD = "stride_prefetcher.vcd"
OUT = os.path.join("docs", "stride_prefetcher_waveform.png")

# 13 directed accesses: negedge (input change) at 40+10k, settled sample at
# 41+10k, cell drawn over [40+10k, 50+10k].
NCELL   = 13
T_FIRST = 40          # first cell left edge (ns)
T_STEP  = 10          # clock period (ns)
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


STATE = {0: "INIT", 1: "TRANS", 2: "STEADY", 3: "NOPRED"}


def main():
    id2name, changes = parse_vcd(VCD)
    name2sym = {}
    for sym, name in id2name.items():
        name2sym.setdefault(name, sym)   # top (tb) scope seen first -> wins

    def series(name):
        return changes.get(name2sym.get(name, ""), [])

    clk = series("clk")

    # per-cell settled sample times and drawing edges
    samp  = [41 + T_STEP * k for k in range(NCELL)]
    edges = [T_FIRST + T_STEP * k for k in range(NCELL + 1)]

    def cell_bits(name):
        s = series(name)
        return [val_at(s, t) for t in samp]

    def cell_ints(name):
        s = series(name)
        return [to_int(val_at(s, t)) for t in samp]

    rvalid = cell_bits("req_valid")
    rpc    = cell_ints("req_pc")
    raddr  = cell_ints("req_addr")
    hit    = cell_bits("dbg_hit")
    state  = cell_ints("dbg_state")
    stride = cell_ints("dbg_stride")
    pfv    = cell_bits("pf_valid")
    pfa    = cell_ints("pf_addr")

    fine = [x * 0.2 for x in range(int(T0 / 0.2), int(T1 / 0.2) + 1)]

    fig, axes = plt.subplots(10, 1, figsize=(16, 10.5), sharex=True)
    fig.suptitle("Day27 - Stride Prefetcher (Reference Prediction Table)   "
                 "(captured from iverilog VCD; directed scenario)",
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

    hexf = lambda v: f"{v & 0xFFFFFFFF:04X}"

    def strf(v):
        v &= 0xFFFFFFFF
        s = v - (1 << 32) if v >> 31 else v          # signed interpret
        return f"{s:+d}" if s else "0"

    clkrow(axes[0])
    digrow(axes[1], rvalid, "req_valid", "#1f77b4")
    busrow(axes[2], rpc,    "req PC",    "#ff7f0e", hexf, gate=rvalid)
    busrow(axes[3], raddr,  "req addr",  "#ff7f0e", hexf, gate=rvalid)
    digrow(axes[4], hit,    "RPT hit",   "#d62728")
    busrow(axes[5], state,  "state",     "#9467bd",
           lambda v: STATE.get(v, "?"), gate=rvalid)
    busrow(axes[6], stride, "stride",    "#7f7f7f", strf, gate=rvalid)
    digrow(axes[7], pfv,    "pf_valid",  "#2ca02c")
    busrow(axes[8], pfa,    "pf addr",   "#2ca02c", hexf, gate=pfv)

    # cycle-number ruler
    axr = axes[9]
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

    cap = ("Real iverilog capture of the Phase-1 directed scenario, sampled once "
           "per clock at the settled pre-edge instant. Load PC 0x0100 walks an "
           "array in +64-byte steps: c0 allocates (state INIT, RPT miss), c1 "
           "learns stride +64 (TRANSIENT), c2 confirms it (STEADY). From c3 on, "
           "'pf_valid' rises and 'pf addr' = req_addr + stride is issued one line "
           "ahead (0x10C0->0x1100, 0x1100->0x1140, 0x1140->0x1180). The c5 access "
           "to PC 0x0110 (its own entry, shown INIT) does not disturb A's stream "
           "-- per-PC independence. At c7 A's stride jumps to +192, so STEADY "
           "drops to INIT (c8) and re-locks on the new stride at c9 (0x1380-> "
           "0x1440). c10 re-references PC 0x0110 (a descending / negative-stride "
           "access); its entry is still INIT so no prefetch issues yet. At "
           "c11 PC 0x0001_0100 (same index, different tag) evicts A's entry (RPT "
           "miss), so at c12 A's next access also misses and re-allocates. Every "
           "value shown is read out of the VCD, not modeled.")
    fig.text(0.5, 0.004, cap, ha="center", fontsize=8, wrap=True, color="0.25")

    fig.tight_layout(rect=[0, 0.06, 1, 0.965])
    os.makedirs("docs", exist_ok=True)
    fig.savefig(OUT, dpi=130)
    print(f"wrote {OUT}")


if __name__ == "__main__":
    main()
