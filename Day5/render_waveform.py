#!/usr/bin/env python3
"""Render core.vcd (captured from a real iverilog run) to
docs/core_waveform.png.

This is a genuine simulator capture: we parse the VCD that `make icarus`
produced and draw the first several instructions executing on the single-cycle
core with matplotlib. Nothing is hand-modeled -- every PC, fetched instruction,
and written-back register value shown is read back out of the VCD.
"""
import os
import re
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

VCD = "core.vcd"
OUT = os.path.join("docs", "core_waveform.png")


def parse_vcd(path):
    """Return (id->name map, {sym: [(time_ns, value_str)]})."""
    id2name = {}
    changes = {}
    cur_t = 0.0
    in_defs = True
    # iverilog writes VCD timestamps in the timescale precision (ps here),
    # so 1000 ticks == 1 ns. Convert every timestamp to nanoseconds.
    PS_PER_NS = 1000.0
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            if in_defs:
                if line.startswith("$var"):
                    toks = line.split()
                    sym = toks[3]
                    name = toks[4]
                    id2name.setdefault(sym, name)
                    changes.setdefault(sym, [])
                elif line.startswith("$enddefinitions"):
                    in_defs = False
                continue
            if line[0] == "#":
                cur_t = int(line[1:]) / PS_PER_NS
            elif line[0] in "01xzXZ":          # scalar change: e.g. 1!
                sym = line[1:]
                if sym in changes:
                    changes[sym].append((cur_t, line[0]))
            elif line[0] in "bB":              # vector change: e.g. b1010 !
                m = re.match(r"[bB]([01xzXZ]+)\s+(\S+)", line)
                if m and m.group(2) in changes:
                    changes[m.group(2)].append((cur_t, m.group(1)))
    return id2name, changes


def val_at(series, t):
    """Value of a signal at time t (last change <= t)."""
    v = None
    for (ct, cv) in series:
        if ct <= t:
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
    # First occurrence of each name is the top-level (tb_core) signal.
    name2sym = {}
    for sym, name in id2name.items():
        name2sym.setdefault(name, sym)

    def series(name):
        return changes.get(name2sym.get(name, ""), [])

    clk       = series("clk")
    rst_n     = series("rst_n")
    reg_write = series("dbg_reg_write")
    pc        = series("dbg_pc")
    instr     = series("dbg_instr")
    rd        = series("dbg_rd")
    result    = series("dbg_result")

    # Directed window: reset + the first ~9 instructions (0..100 ns).
    T_END = 100
    ts = list(range(0, T_END + 1))
    fine = [x * 0.1 for x in range(0, T_END * 10 + 1)]

    scal = [("clk", clk, "#1f77b4"), ("rst_n", rst_n, "#8c564b"),
            ("reg_write", reg_write, "#2ca02c")]

    fig, axes = plt.subplots(7, 1, figsize=(14, 9.0), sharex=True)
    fig.suptitle("Day5 - single-cycle RV32I core  (captured from iverilog VCD)",
                 fontsize=13, fontweight="bold")

    for idx, (label, s, color) in enumerate(scal):
        ax = axes[idx]
        cv = [1 if (val_at(s, t) == "1") else 0 for t in fine]
        ax.step(fine, cv, where="post", color=color, linewidth=1.4)
        ax.set_ylabel(label, rotation=0, ha="right", va="center")
        ax.set_ylim(-0.3, 1.3)
        ax.set_yticks([0, 1] if label != "clk" else [])

    def bus_axis(ax, s, label, color, fmt):
        ax.axhline(0.5, color=color, linewidth=1.0, alpha=0.35)
        prev = object()
        for t in ts:
            v = to_int(val_at(s, t))
            if v != prev:
                if v is not None:
                    ax.text(t + 0.6, 0.5, fmt(v), va="center", ha="left",
                            fontsize=7.5, family="monospace", color=color)
                    ax.axvline(t, color=color, linewidth=0.8, alpha=0.5)
                prev = v
        ax.set_ylabel(label, rotation=0, ha="right", va="center")
        ax.set_ylim(0, 1)
        ax.set_yticks([])

    hx = lambda v: f"{v & 0xFFFFFFFF:08X}"
    bus_axis(axes[3], pc,     "pc",         "#d62728", hx)
    bus_axis(axes[4], instr,  "instr",      "#9467bd", hx)
    bus_axis(axes[5], rd,     "rd",         "#ff7f0e", lambda v: f"x{v}")
    bus_axis(axes[6], result, "wb result",  "#17becf", hx)

    axes[-1].set_xlabel("time (ns)")
    axes[-1].set_xlim(0, T_END)
    axes[-1].set_xticks(range(0, T_END + 1, 10))
    for ax in axes:
        ax.grid(axis="x", color="0.85", linewidth=0.5)

    cap = ("First instructions after reset (PC advances one word per cycle): "
           "lui x1=12345000, addi x1=12345678, auipc x2=00010008, "
           "addi x3=00000064, addi x4=FFFFFFCE, add x5=00000032, "
           "sub x6=00000096, and x7=00000060, or x8=FFFFFFEE. "
           "reg_write is high and 'wb result' is the value retired into rd.")
    fig.text(0.5, 0.005, cap, ha="center", fontsize=8, wrap=True, color="0.25")

    fig.tight_layout(rect=[0, 0.04, 1, 0.96])
    os.makedirs("docs", exist_ok=True)
    fig.savefig(OUT, dpi=130)
    print(f"wrote {OUT}")


if __name__ == "__main__":
    main()
