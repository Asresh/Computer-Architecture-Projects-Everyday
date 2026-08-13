#!/usr/bin/env python3
"""Render alu.vcd (captured from a real iverilog run) to docs/alu_waveform.png.

This is a genuine simulator capture: we parse the VCD that `make icarus`
produced and draw the directed-corner-case window with matplotlib. Nothing is
hand-modeled -- every value shown is read back out of the VCD.
"""
import os
import re
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

VCD = "alu.vcd"
OUT = os.path.join("docs", "alu_waveform.png")

OPNAMES = {0: "ADD", 1: "SUB", 2: "SLL", 3: "SLT", 4: "SLTU",
           5: "XOR", 6: "SRL", 7: "SRA", 8: "OR", 9: "AND"}


def parse_vcd(path):
    """Return (id->name map, {name: [(time, value_str)]})."""
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
                    # $var wire 32 ! a [31:0] $end
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
    name2sym = {}
    for sym, name in id2name.items():
        name2sym.setdefault(name, sym)

    def series(name):
        return changes.get(name2sym.get(name, ""), [])

    clk = series("clk")
    a = series("a")
    b = series("b")
    op = series("alu_op")
    res = series("result")
    zero = series("zero")

    # Directed window: first 14 checks, each 2 ns -> show 0..30 ns.
    T_END = 30
    ts = list(range(0, T_END + 1))

    fig, axes = plt.subplots(6, 1, figsize=(13, 8.5), sharex=True)
    fig.suptitle("Day1 - Single-cycle RISC-V ALU  (captured from iverilog VCD)",
                 fontsize=13, fontweight="bold")

    # --- clk : real digital waveform sampled finely ---
    axc = axes[0]
    fine = [x * 0.1 for x in range(0, T_END * 10 + 1)]
    cv = [1 if (val_at(clk, t) == "1") else 0 for t in fine]
    axc.step(fine, cv, where="post", color="#1f77b4", linewidth=1.4)
    axc.set_ylabel("clk", rotation=0, ha="right", va="center")
    axc.set_ylim(-0.3, 1.3)
    axc.set_yticks([])

    # --- zero flag ---
    axz = axes[1]
    zv = [1 if (val_at(zero, t) == "1") else 0 for t in fine]
    axz.step(fine, zv, where="post", color="#2ca02c", linewidth=1.4)
    axz.set_ylabel("zero", rotation=0, ha="right", va="center")
    axz.set_ylim(-0.3, 1.3)
    axz.set_yticks([0, 1])

    def bus_axis(ax, s, label, color, fmt):
        # Draw a bus: horizontal band with value labels, transitions as X.
        last = None
        seg_start = 0
        vals = []
        for t in ts:
            v = to_int(val_at(s, t))
            vals.append((t, v))
        ax.axhline(0.5, color=color, linewidth=1.0, alpha=0.35)
        prev = object()
        for (t, v) in vals:
            if v != prev:
                if v is not None:
                    ax.text(t + 0.15, 0.5, fmt(v), va="center", ha="left",
                            fontsize=7.5, family="monospace", color=color)
                    ax.axvline(t, color=color, linewidth=0.8, alpha=0.5)
                prev = v
        ax.set_ylabel(label, rotation=0, ha="right", va="center")
        ax.set_ylim(0, 1)
        ax.set_yticks([])

    bus_axis(axes[2], op, "alu_op",
             "#9467bd", lambda v: OPNAMES.get(v, "?"))
    bus_axis(axes[3], a, "a", "#d62728", lambda v: f"{v & 0xFFFFFFFF:08X}")
    bus_axis(axes[4], b, "b", "#ff7f0e", lambda v: f"{v & 0xFFFFFFFF:08X}")
    bus_axis(axes[5], res, "result",
             "#17becf", lambda v: f"{v & 0xFFFFFFFF:08X}")

    axes[-1].set_xlabel("time (ns)")
    axes[-1].set_xlim(0, T_END)
    axes[-1].set_xticks(range(0, T_END + 1, 2))
    for ax in axes:
        ax.grid(axis="x", color="0.85", linewidth=0.5)

    cap = ("Directed corner cases: 0+0 (zero flag set), 0xFFFFFFFF+1 wrap to 0, "
           "7-7=0 (BEQ), signed vs. unsigned SLT, SLL into MSB, "
           "logical vs. arithmetic right shift of 0x80000000.")
    fig.text(0.5, 0.005, cap, ha="center", fontsize=8, wrap=True, color="0.25")

    fig.tight_layout(rect=[0, 0.03, 1, 0.97])
    os.makedirs("docs", exist_ok=True)
    fig.savefig(OUT, dpi=130)
    print(f"wrote {OUT}")


if __name__ == "__main__":
    main()
