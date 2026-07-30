#!/usr/bin/env python3
"""Render reorder_buffer.vcd (captured from a real iverilog run) to
docs/reorder_buffer_waveform.png.

This is a GENUINE simulator capture. `make icarus` runs the self-checking
testbench, which dumps reorder_buffer.vcd; this script parses that VCD and draws
the directed window (t = 40..270 ns) with matplotlib. Every allocate, out-of-
order completion, in-order retirement, stall, count value, and the final flush
shown here is read straight out of the VCD -- nothing is hand-modeled.

The window covers, in order:
   * reset released,
   * three instructions allocate in program order (tags 0,1,2; dest x1,x2,x3;
     count 1->2->3),
   * tag1 COMPLETES out of order while the head (tag0) is still pending --
     retire_valid stays low (head-of-line stall),
   * tag0 completes -> retire_valid asserts; A (tag0) then B (tag1) retire in
     order, then the head stalls on C (tag2) which has not completed,
   * D allocates (tag3) while C completes; C then D retire in order -> empty,
   * the buffer fills to full (count climbs to 8, full=1, alloc_ready=0), then a
     single-cycle FLUSH squashes everything (count -> 0, empty=1).
so you can watch out-of-order completion, strictly in-order retirement, the
head-of-line stall, backpressure at full, and single-cycle squash.
"""
import os
import re
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

VCD       = "reorder_buffer.vcd"
OUT       = os.path.join("docs", "reorder_buffer_waveform.png")
T_START   = 40                     # ns; start of directed window
T_END     = 270                    # ns; end of directed window
PS_PER_NS = 1000.0                 # timescale 1ns/1ps


def parse_vcd(path, t_stop_ns):
    """Return (name->symbol, {sym:[(t_ns,value)]}) up to t_stop.

    Keeps the FIRST occurrence of each name; the top-level TB nets are declared
    before the DUT's copies and carry identical values.
    """
    name2sym = {}
    changes = {}
    in_defs = True
    cur_t = 0.0
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            if in_defs:
                if line.startswith("$var"):
                    toks = line.split()
                    sym, name = toks[3], toks[4]
                    name2sym.setdefault(name, sym)
                    changes.setdefault(sym, [])
                elif line.startswith("$enddefinitions"):
                    in_defs = False
                continue
            if line[0] == "#":
                cur_t = int(line[1:]) / PS_PER_NS
                if cur_t > t_stop_ns + 1:
                    break
            elif line[0] in "01xzXZ":
                changes.setdefault(line[1:], []).append((cur_t, line[0]))
            elif line[0] in "bB":
                m = re.match(r"[bB]([01xzXZ]+)\s+(\S+)", line)
                if m:
                    changes.setdefault(m.group(2), []).append((cur_t, m.group(1)))
    return name2sym, changes


def val_at(series, t):
    v = None
    for (ct, cv) in series:
        if ct <= t + 1e-9:
            v = cv
        else:
            break
    return v


def to_uint(bits):
    if bits is None or any(c in "xzXZ" for c in bits):
        return None
    return int(bits, 2)


def main():
    name2sym, changes = parse_vcd(VCD, T_END)

    def series(name):
        return changes.get(name2sym.get(name, ""), [])

    clk    = series("clk")
    rst_n  = series("rst_n")
    a_v    = series("alloc_valid")
    a_r    = series("alloc_ready")
    a_dst  = series("alloc_dest")
    a_tag  = series("alloc_tag")
    c_v    = series("cmpl_valid")
    c_tag  = series("cmpl_tag")
    c_dat  = series("cmpl_data")
    r_rdy  = series("retire_ready")
    r_v    = series("retire_valid")
    r_tag  = series("retire_tag")
    r_dst  = series("retire_dest")
    r_dat  = series("retire_data")
    flush  = series("flush")
    full   = series("full")
    empty  = series("empty")
    cnt    = series("count")

    fine = [T_START + x * 0.1 for x in range(0, (T_END - T_START) * 10 + 1)]
    ts   = list(range(T_START, T_END + 1))

    #  scalar rows : label, series, color
    scal = [("clk",          clk,   "#1f77b4"),
            ("rst_n",        rst_n, "#8c564b"),
            ("alloc_valid",  a_v,   "#9467bd"),
            ("alloc_ready",  a_r,   "#c5b0d5"),
            ("cmpl_valid",   c_v,   "#ff7f0e"),
            ("retire_ready", r_rdy, "#c7c7c7"),
            ("retire_valid", r_v,   "#d62728"),
            ("flush",        flush, "#e377c2"),
            ("full",         full,  "#7f7f7f"),
            ("empty",        empty, "#bcbd22")]

    def hexf(v):
        return "-" if v is None else "0x{:X}".format(v)

    def decf(v):
        return "-" if v is None else str(v)

    def regf(v):
        return "-" if v is None else "x{:d}".format(v)

    #  bus rows : label, series, color, formatter
    buses = [("alloc_dest",  a_dst, "#9467bd", regf),
             ("alloc_tag",   a_tag, "#9467bd", decf),
             ("cmpl_tag",    c_tag, "#ff7f0e", decf),
             ("cmpl_data",   c_dat, "#ff7f0e", hexf),
             ("retire_tag",  r_tag, "#d62728", decf),
             ("retire_dest", r_dst, "#d62728", regf),
             ("retire_data", r_dat, "#d62728", hexf),
             ("count",       cnt,   "#17becf", decf)]

    fig, axes = plt.subplots(len(scal) + len(buses), 1,
                             figsize=(19, 12), sharex=True)
    fig.suptitle("Day12 - reorder buffer (out-of-order complete, in-order "
                 "retire), NUM_ENTRIES=8  (captured from iverilog VCD)",
                 fontsize=13, fontweight="bold")

    for idx, (label, s, color) in enumerate(scal):
        ax = axes[idx]
        cv = [1 if (val_at(s, t) == "1") else 0 for t in fine]
        ax.step(fine, cv, where="post", color=color, linewidth=1.4)
        ax.set_ylabel(label, rotation=0, ha="right", va="center", fontsize=9)
        ax.set_ylim(-0.3, 1.3)
        ax.set_yticks([0, 1] if label != "clk" else [])

    def bus_axis(ax, s, label, color, fmt):
        ax.axhline(0.5, color=color, linewidth=1.0, alpha=0.30)
        prev = object()
        for t in ts:
            v = to_uint(val_at(s, t))
            if v != prev:
                ax.text(t + 0.6, 0.5, fmt(v), va="center", ha="left",
                        fontsize=8, family="monospace", color=color)
                ax.axvline(t, color=color, linewidth=0.7, alpha=0.45)
                prev = v
        ax.set_ylabel(label, rotation=0, ha="right", va="center", fontsize=9)
        ax.set_ylim(0, 1)
        ax.set_yticks([])

    b0 = len(scal)
    for k, (label, s, color, fmt) in enumerate(buses):
        bus_axis(axes[b0 + k], s, label, color, fmt)

    axes[-1].set_xlabel("time (ns)   -   1 clock = 10 ns")
    axes[-1].set_xlim(T_START, T_END)
    axes[-1].set_xticks(range(T_START, T_END + 1, 10))
    for ax in axes:
        ax.grid(axis="x", color="0.85", linewidth=0.5)

    cap = ("Captured directed window. Three instructions allocate in program "
           "order (tags 0,1,2 -> dest x1,x2,x3; count 1->2->3). tag1 COMPLETES "
           "out of order while the head tag0 is still pending -- retire_valid "
           "stays low (head-of-line stall). Once tag0 completes, A(tag0) then "
           "B(tag1) retire IN ORDER; the head then stalls on tag2 until it "
           "completes. D allocates (tag3) as C completes; C then D retire in "
           "order to empty. Finally the buffer fills to full (count=8, full=1, "
           "alloc_ready=0) and a single-cycle FLUSH squashes it (count->0, "
           "empty=1). Genuine iverilog capture, not hand-drawn.")
    fig.text(0.5, 0.005, cap, ha="center", fontsize=8, wrap=True, color="0.25")

    fig.tight_layout(rect=[0, 0.055, 1, 0.97])
    os.makedirs("docs", exist_ok=True)
    fig.savefig(OUT, dpi=130)
    print("wrote {}".format(OUT))


if __name__ == "__main__":
    main()
