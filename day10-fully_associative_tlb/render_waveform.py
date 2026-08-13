#!/usr/bin/env python3
"""Render tlb.vcd (captured from a real iverilog run) to docs/tlb_waveform.png.

This is a GENUINE simulator capture. `make icarus` runs the self-checking
testbench, which dumps tlb.vcd; this script parses that VCD and draws the first
~195 ns directed window with matplotlib. Every request/fill VPN, hit/miss line,
translated PPN, and victim-way value shown is read straight out of the VCD --
nothing is hand-modeled.

The window covers, in order (ENTRIES = 4, fully associative):
   * reset,
   * a cold miss on page A (empty TLB),
   * fills of A,B,C,D that fill every way,
   * hits on B then A that re-order recency (making C the least-recently-used),
   * a fill of E while the TLB is full -> `fill_way` points at way 2 (C, the
     true-LRU victim) and C is evicted,
   * a follow-up lookup of C that now MISSES (proof the LRU victim was dropped),
   * a single-page invalidate of B and a refill of B into the freed way,
   * a full flush, after which A misses again.
so you can watch `fill_way` track the true-LRU victim and see the eviction land.
"""
import os
import re
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

VCD       = "tlb.vcd"
OUT       = os.path.join("docs", "tlb_waveform.png")
T_END     = 195                    # ns; covers the directed window
PS_PER_NS = 1000.0                 # timescale 1ns/1ps


def parse_vcd(path, t_stop_ns):
    """Return (name->symbol, {sym:[(t_ns,value)]}) up to t_stop.

    name->symbol keeps the FIRST occurrence of each name; the top-level TB nets
    are declared before the DUT's connected copies and carry identical values.
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
    reqv   = series("req_valid")
    hit    = series("hit")
    miss   = series("miss")
    fillv  = series("fill_valid")
    invv   = series("inv_valid")
    flush  = series("flush_all")
    reqvpn = series("req_vpn")
    ppn    = series("resp_ppn")
    fvpn   = series("fill_vpn")
    fway   = series("fill_way")

    fine = [x * 0.1 for x in range(0, T_END * 10 + 1)]
    ts   = list(range(0, T_END + 1))

    # scalar rows: (label, series, color)
    scal = [("clk",         clk,   "#1f77b4"),
            ("rst_n",       rst_n, "#8c564b"),
            ("req_valid",   reqv,  "#7f7f7f"),
            ("hit",         hit,   "#2ca02c"),
            ("miss",        miss,  "#d62728"),
            ("fill_valid",  fillv, "#9467bd"),
            ("inv_valid",   invv,  "#bcbd22"),
            ("flush_all",   flush, "#17becf")]

    def hexs(v):
        return "-" if v is None else "0x{:X}".format(v)

    # bus rows: (label, series, color, formatter, gate_series, gate_hi)
    buses = [("req_vpn",   reqvpn, "#9467bd", hexs, reqv,  True),
             ("resp_ppn",  ppn,    "#2ca02c", hexs, hit,   True),
             ("fill_vpn",  fvpn,   "#e377c2", hexs, fillv, True),
             ("fill_way",  fway,   "#ff7f0e",
              (lambda v: "-" if v is None else str(v)), None, False)]

    fig, axes = plt.subplots(len(scal) + len(buses), 1,
                             figsize=(16, 11), sharex=True)
    fig.suptitle("Day10 - fully-associative TLB, ENTRIES=4, true-LRU refill "
                 "(captured from iverilog VCD)",
                 fontsize=13, fontweight="bold")

    for idx, (label, s, color) in enumerate(scal):
        ax = axes[idx]
        cv = [1 if (val_at(s, t) == "1") else 0 for t in fine]
        ax.step(fine, cv, where="post", color=color, linewidth=1.4)
        ax.set_ylabel(label, rotation=0, ha="right", va="center", fontsize=9)
        ax.set_ylim(-0.3, 1.3)
        ax.set_yticks([0, 1] if label != "clk" else [])

    def gate_hi(gate, t):
        if gate is None:
            return True
        return val_at(gate, t) == "1"

    def bus_axis(ax, s, label, color, fmt, gate):
        ax.axhline(0.5, color=color, linewidth=1.0, alpha=0.30)
        prev = object()
        for t in ts:
            shown = fmt(to_uint(val_at(s, t))) if gate_hi(gate, t) else "-"
            if shown != prev:
                ax.text(t + 0.4, 0.5, shown, va="center", ha="left",
                        fontsize=8, family="monospace", color=color)
                ax.axvline(t, color=color, linewidth=0.7, alpha=0.45)
                prev = shown
        ax.set_ylabel(label, rotation=0, ha="right", va="center", fontsize=9)
        ax.set_ylim(0, 1)
        ax.set_yticks([])

    b0 = len(scal)
    for k, (label, s, color, fmt, gate, _hi) in enumerate(buses):
        bus_axis(axes[b0 + k], s, label, color, fmt, gate)

    axes[-1].set_xlabel("time (ns)   -   1 clock = 10 ns")
    axes[-1].set_xlim(0, T_END)
    axes[-1].set_xticks(range(0, T_END + 1, 10))
    for ax in axes:
        ax.grid(axis="x", color="0.85", linewidth=0.5)

    cap = ("Captured directed window. After reset, page A misses on the empty "
           "TLB; A,B,C,D are filled into all four ways. Hits on B then A promote "
           "them, leaving C least-recently-used. When E is filled into the full "
           "TLB, fill_way points at way 2 (C, the true-LRU victim) and C is "
           "evicted -- the very next lookup of C MISSES. B is then invalidated "
           "and refilled into the freed way, and a full flush makes A miss "
           "again. resp_ppn / req_vpn / fill_vpn are shown (hex) only while their "
           "valid line is high. Genuine iverilog capture, not hand-drawn.")
    fig.text(0.5, 0.005, cap, ha="center", fontsize=8, wrap=True, color="0.25")

    fig.tight_layout(rect=[0, 0.055, 1, 0.965])
    os.makedirs("docs", exist_ok=True)
    fig.savefig(OUT, dpi=130)
    print("wrote {}".format(OUT))


if __name__ == "__main__":
    main()
