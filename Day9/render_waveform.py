#!/usr/bin/env python3
"""Render rr_arbiter.vcd (captured from a real iverilog run) to
docs/rr_arbiter_waveform.png.

This is a GENUINE simulator capture. `make icarus` runs the self-checking
testbench, which dumps rr_arbiter.vcd; this script parses that VCD and draws the
first ~230 ns directed window with matplotlib. Every request mask, grant, index,
and pointer value shown is read straight out of the VCD -- nothing is
hand-modeled.

The window covers, in order:
   * reset,
   * idle (no requests),
   * a single persistent requester (lane 2),
   * eight cycles of FULL contention (req = 1111) where the grant marches
     0,1,2,3,0,1,... -- the round-robin fairness rotation,
   * two requesters (lanes 1 and 3) whose grants alternate as the pointer moves,
   * a pointer-wrap case.
so you can watch `base` (the rotate pointer) chase each grant and guarantee that
no requester is ever starved.
"""
import os
import re
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

VCD = "rr_arbiter.vcd"
OUT = os.path.join("docs", "rr_arbiter_waveform.png")

N          = 4
T_END      = 230                  # ns; covers the directed window
PS_PER_NS  = 1000.0               # timescale 1ns/1ps


def parse_vcd(path, t_stop_ns):
    """Return (name->symbol, {sym:[(t_ns,value)]}) parsing only up to t_stop.

    name->symbol keeps the FIRST occurrence of each name; the top-level TB nets
    (grant, req, grant_valid, grant_idx, rst_n, clk) appear before the DUT's
    copies and carry identical values, while `base` is unique to the DUT.
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

    clk   = series("clk")
    rst_n = series("rst_n")
    gvld  = series("grant_valid")
    req   = series("req")
    grant = series("grant")
    gidx  = series("grant_idx")
    base  = series("base")

    fine = [x * 0.1 for x in range(0, T_END * 10 + 1)]
    ts   = list(range(0, T_END + 1))

    scal = [("clk",         clk,   "#1f77b4"),
            ("rst_n",       rst_n, "#8c564b"),
            ("grant_valid", gvld,  "#d62728")]

    def bin_str(v):
        if v is None:
            return "x"
        return format(v, "0{}b".format(N))

    def gnt_str(v):
        # compact one-hot binary (or dashes when idle); the granted lane number
        # is shown separately on the grant_idx row.
        if v is None:
            return "x"
        if v == 0:
            return "-" * N
        return format(v, "0{}b".format(N))

    #  label, series, color, formatter
    buses = [("req",       req,   "#9467bd", bin_str),
             ("grant",     grant, "#2ca02c", gnt_str),
             ("grant_idx", gidx,  "#e377c2", lambda v: "-" if v is None else str(v)),
             ("base ptr",  base,  "#17becf", lambda v: "-" if v is None else str(v))]

    fig, axes = plt.subplots(len(scal) + len(buses), 1,
                             figsize=(16, 9), sharex=True)
    fig.suptitle("Day9 - round-robin (rotating-priority) arbiter, N=4 "
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

    cap = ("Captured directed window. After reset and an idle stretch, lane 2 "
           "requests alone and is granted every cycle. When all four lines go "
           "high (req=1111), the grant marches lane 3->0->1->2->3->... in strict "
           "rotation: each served lane drops to lowest priority as `base ptr` "
           "advances past it, so every requester wins once per N=4 cycles (no "
           "starvation). With only lanes 1 and 3 requesting, grants alternate as "
           "the pointer sweeps by, and the final vectors show the pointer "
           "wrapping 3->0. Genuine iverilog capture, not hand-drawn.")
    fig.text(0.5, 0.005, cap, ha="center", fontsize=8, wrap=True, color="0.25")

    fig.tight_layout(rect=[0, 0.06, 1, 0.965])
    os.makedirs("docs", exist_ok=True)
    fig.savefig(OUT, dpi=130)
    print("wrote {}".format(OUT))


if __name__ == "__main__":
    main()
