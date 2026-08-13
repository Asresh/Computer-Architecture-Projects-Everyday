#!/usr/bin/env python3
"""Render pipeline.vcd (captured from a real iverilog run) to
docs/pipeline_waveform.png.

This is a genuine simulator capture: the VCD that `make icarus` produced is
parsed and the directed-program window is drawn with matplotlib. Nothing is
hand-modeled -- every stage PC, forwarding select, stall, and flush shown is
read straight out of the VCD.
"""
import os
import re
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

VCD = "pipeline.vcd"
OUT = os.path.join("docs", "pipeline_waveform.png")
T0, T1 = 0, 330          # ns window (reset + start of the directed program)


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
                    # append width-qualified index if vector name has [msb:lsb]
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
        name2sym.setdefault(name, sym)

    def series(name):
        return changes.get(name2sym.get(name, ""), [])

    clk   = series("clk")
    rst_n = series("rst_n")
    stall = series("dbg_stall")
    flush = series("dbg_flush")
    fwd_a = series("dbg_fwd_a")
    fwd_b = series("dbg_fwd_b")
    pc_ex = series("dbg_pc_ex")
    wb_we = series("dbg_wb_we")
    wb_rd = series("dbg_wb_rd")
    wb_dt = series("dbg_wb_data")

    fine = [x * 0.2 for x in range(int(T0 / 0.2), int(T1 / 0.2) + 1)]
    ts   = list(range(T0, T1 + 1))

    fig, axes = plt.subplots(9, 1, figsize=(15, 10.5), sharex=True)
    fig.suptitle("Day25 - 5-stage pipelined RV32I core  "
                 "(captured from iverilog VCD; directed hazard program)",
                 fontsize=13, fontweight="bold")

    def digital(ax, s, label, color):
        cv = [1 if (val_at(s, t) == "1") else 0 for t in fine]
        ax.step(fine, cv, where="post", color=color, linewidth=1.4)
        ax.set_ylabel(label, rotation=0, ha="right", va="center")
        ax.set_ylim(-0.3, 1.3)
        ax.set_yticks([])

    digital(axes[0], clk,   "clk",   "#1f77b4")
    digital(axes[1], rst_n, "rst_n", "#8c564b")
    digital(axes[2], stall, "stall (load-use)", "#d62728")
    digital(axes[3], flush, "flush (branch)",   "#e377c2")

    def bus(ax, s, label, color, fmt):
        ax.axhline(0.5, color=color, linewidth=1.0, alpha=0.30)
        prev = object()
        for t in ts:
            v = to_int(val_at(s, t))
            if v != prev:
                if v is not None:
                    ax.text(t + 0.5, 0.5, fmt(v), va="center", ha="left",
                            fontsize=7.5, family="monospace", color=color)
                    ax.axvline(t, color=color, linewidth=0.7, alpha=0.45)
                prev = v
        ax.set_ylabel(label, rotation=0, ha="right", va="center")
        ax.set_ylim(0, 1)
        ax.set_yticks([])

    fwd_fmt = lambda v: {0: "RF", 1: "M/WB", 2: "EX/M"}.get(v, str(v))
    bus(axes[4], fwd_a, "fwdA", "#2ca02c", fwd_fmt)
    bus(axes[5], fwd_b, "fwdB", "#17becf", fwd_fmt)
    bus(axes[6], pc_ex, "EX pc", "#ff7f0e", lambda v: f"{v & 0xFFFFFFFF:03X}")
    bus(axes[7], wb_rd, "WB rd", "#9467bd", lambda v: f"x{v}")
    bus(axes[8], wb_dt, "WB data", "#7f7f7f", lambda v: f"{v & 0xFFFFFFFF:X}")

    axes[-1].set_xlabel("time (ns)")
    axes[-1].set_xlim(T0, T1)
    axes[-1].set_xticks(range(T0, T1 + 1, 10))
    for ax in axes:
        ax.grid(axis="x", color="0.88", linewidth=0.5)

    cap = ("Real iverilog capture of the directed hazard program on the "
           "5-stage pipeline. 'fwdA/fwdB' show the EX operand source each "
           "cycle: RF (register file), EX/M (EX/MEM bypass), or M/WB (MEM/WB "
           "bypass) -- the bypass network feeding back-to-back dependent "
           "instructions. 'stall' pulses high for the one-cycle load-use "
           "bubble; 'flush' pulses high when a taken branch/jump redirects the "
           "PC and squashes the two younger instructions. 'EX pc' is the byte "
           "PC of the instruction in EX; 'WB data' is the value retiring into "
           "'WB rd'. Every value here is read out of the VCD, not modeled.")
    fig.text(0.5, 0.005, cap, ha="center", fontsize=8, wrap=True, color="0.25")

    fig.tight_layout(rect=[0, 0.05, 1, 0.96])
    os.makedirs("docs", exist_ok=True)
    fig.savefig(OUT, dpi=130)
    print(f"wrote {OUT}")

    # Report where the interesting events land (sanity for the window).
    def edges(s):
        return [t for (t, v) in s if v == "1" and T0 <= t <= T1]
    print("stall high-edges in window (ns):", edges(stall)[:8])
    print("flush high-edges in window (ns):", edges(flush)[:8])


if __name__ == "__main__":
    main()
