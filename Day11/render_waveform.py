#!/usr/bin/env python3
"""Render store_buffer.vcd (captured from a real iverilog run) to
docs/store_buffer_waveform.png.

This is a GENUINE simulator capture. `make icarus` runs the self-checking
testbench, which dumps store_buffer.vcd; this script parses that VCD and draws
the first 170 ns directed window with matplotlib. Every store, load lookup,
forward result, drain, and status value shown is read straight out of the VCD --
nothing is hand-modeled.

The window covers, in order:
   * reset,
   * three stores enqueued: [0x100]<=0xAAAA, then [0x100]<=0xBBBB (a YOUNGER
     store to the same address), then [0x200]<=0xC0DE  (count climbs 1->2->3),
   * load 0x100 -> forwards 0xBBBB   (the youngest of the two 0x100 stores wins,
     NOT the older 0xAAAA -- this is the whole point of the buffer),
   * load 0x200 -> forwards 0xC0DE,
   * load 0x300 -> MISS (ld_fwd_hit = 0; the load must go to memory),
   * two in-order drains to memory (0xAAAA then 0xBBBB leave, oldest first)
     while a concurrent load 0x100 still correctly forwards the not-yet-drained
     0xBBBB,
   * a simultaneous push + drain (count holds steady), then drain to empty.
so you can watch forwarding return the youngest match, misses fall through, and
the FIFO drain in program order.
"""
import os
import re
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

VCD       = "store_buffer.vcd"
OUT       = os.path.join("docs", "store_buffer_waveform.png")
T_END     = 170                    # ns; directed window
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

    clk     = series("clk")
    rst_n   = series("rst_n")
    st_v    = series("st_valid")
    st_r    = series("st_ready")
    st_a    = series("st_addr")
    st_d    = series("st_data")
    ld_v    = series("ld_valid")
    ld_a    = series("ld_addr")
    ld_hit  = series("ld_fwd_hit")
    ld_d    = series("ld_fwd_data")
    mreq    = series("mem_req")
    mrdy    = series("mem_ready")
    ma      = series("mem_addr")
    md      = series("mem_data")
    full    = series("full")
    empty   = series("empty")
    cnt     = series("count")

    fine = [x * 0.1 for x in range(0, T_END * 10 + 1)]
    ts   = list(range(0, T_END + 1))

    #  scalar rows : label, series, color
    scal = [("clk",         clk,   "#1f77b4"),
            ("rst_n",       rst_n, "#8c564b"),
            ("st_valid",    st_v,  "#9467bd"),
            ("st_ready",    st_r,  "#c5b0d5"),
            ("ld_valid",    ld_v,  "#ff7f0e"),
            ("ld_fwd_hit",  ld_hit,"#d62728"),
            ("mem_req",     mreq,  "#2ca02c"),
            ("mem_ready",   mrdy,  "#98df8a"),
            ("full",        full,  "#7f7f7f"),
            ("empty",       empty, "#bcbd22")]

    def hexf(v):
        return "-" if v is None else "0x{:X}".format(v)

    def decf(v):
        return "-" if v is None else str(v)

    #  bus rows : label, series, color, formatter
    buses = [("st_addr",     st_a, "#9467bd", hexf),
             ("st_data",     st_d, "#9467bd", hexf),
             ("ld_addr",     ld_a, "#ff7f0e", hexf),
             ("ld_fwd_data", ld_d, "#d62728", hexf),
             ("mem_addr",    ma,   "#2ca02c", hexf),
             ("mem_data",    md,   "#2ca02c", hexf),
             ("count",       cnt,  "#17becf", decf)]

    fig, axes = plt.subplots(len(scal) + len(buses), 1,
                             figsize=(17, 12), sharex=True)
    fig.suptitle("Day11 - store buffer with store-to-load forwarding, DEPTH=8 "
                 "(captured from iverilog VCD)",
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
                ax.text(t + 0.4, 0.5, fmt(v), va="center", ha="left",
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
    axes[-1].set_xlim(0, T_END)
    axes[-1].set_xticks(range(0, T_END + 1, 10))
    for ax in axes:
        ax.grid(axis="x", color="0.85", linewidth=0.5)

    cap = ("Captured directed window. After reset, three stores enqueue: "
           "[0x100]<=0xAAAA, then a YOUNGER [0x100]<=0xBBBB, then [0x200]<=0xC0DE "
           "(count 1->2->3). The load of 0x100 forwards 0xBBBB -- the youngest "
           "matching store, not the older 0xAAAA; the load of 0x200 forwards "
           "0xC0DE; the load of 0x300 MISSES (ld_fwd_hit=0). The oldest entries "
           "then drain to memory in program order (mem_addr/mem_data = 0x100/"
           "0xAAAA, then 0x100/0xBBBB) while a concurrent 0x100 load still "
           "forwards the not-yet-drained 0xBBBB, followed by a simultaneous "
           "push+drain (count steady) and drain to empty. Genuine iverilog "
           "capture, not hand-drawn.")
    fig.text(0.5, 0.005, cap, ha="center", fontsize=8, wrap=True, color="0.25")

    fig.tight_layout(rect=[0, 0.055, 1, 0.97])
    os.makedirs("docs", exist_ok=True)
    fig.savefig(OUT, dpi=130)
    print("wrote {}".format(OUT))


if __name__ == "__main__":
    main()
