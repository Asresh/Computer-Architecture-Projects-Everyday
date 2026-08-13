#!/usr/bin/env python3
"""Render branch_predictor.vcd (captured from a real iverilog run) to
docs/branch_predictor_waveform.png.

This is a GENUINE simulator capture: we parse the VCD that `make icarus`
produced and draw the directed-training window with matplotlib. Nothing is
hand-modeled -- every prediction, index, and saturating-counter value shown is
read back out of the VCD the testbench dumped.

The window covers reset plus the two directed phases: PC_A being trained up
through the FSM (WN -> WT -> ST), the single-mispredict hysteresis case (a
not-taken outcome that only weakens the counter to WT so the prediction stays
"taken"), the second not-taken that finally flips it, and PC_C being trained
taken at an independent index.
"""
import os
import re
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

VCD = "branch_predictor.vcd"
OUT = os.path.join("docs", "branch_predictor_waveform.png")

# Directed window in ns (random phase begins just after this).
T_END = 106


def parse_vcd(path):
    """Return (sym->name map, {sym: [(time_ns, value_str)]})."""
    id2name = {}
    changes = {}
    cur_t = 0.0
    in_defs = True
    PS_PER_NS = 1000.0  # timescale 1ns/1ps -> 1000 ps ticks per ns
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


STATE = {0: "SN", 1: "WN", 2: "WT", 3: "ST"}  # 2-bit counter -> name


def main():
    id2name, changes = parse_vcd(VCD)
    # First occurrence of each name is the top-level tb signal.
    name2sym = {}
    for sym, name in id2name.items():
        name2sym.setdefault(name, sym)

    def series(name):
        return changes.get(name2sym.get(name, ""), [])

    clk        = series("clk")
    rst_n      = series("rst_n")
    update_en  = series("update_en")
    actual     = series("actual_taken")
    predict    = series("predict_taken")
    pidx       = series("dbg_predict_index")
    uidx       = series("dbg_update_index")
    uctr       = series("dbg_update_counter")

    fine = [x * 0.1 for x in range(0, T_END * 10 + 1)]
    ts   = list(range(0, T_END + 1))

    scal = [("clk", clk, "#1f77b4"),
            ("rst_n", rst_n, "#8c564b"),
            ("update_en", update_en, "#7f7f7f"),
            ("actual_taken", actual, "#2ca02c"),
            ("predict_taken", predict, "#d62728")]

    fig, axes = plt.subplots(8, 1, figsize=(14, 9.5), sharex=True)
    fig.suptitle("Day6 - bimodal 2-bit saturating-counter branch predictor  "
                 "(captured from iverilog VCD)", fontsize=13, fontweight="bold")

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
            v = to_int(val_at(s, t))
            if v != prev:
                if v is not None:
                    ax.text(t + 0.4, 0.5, fmt(v), va="center", ha="left",
                            fontsize=8, family="monospace", color=color)
                    ax.axvline(t, color=color, linewidth=0.7, alpha=0.45)
                prev = v
        ax.set_ylabel(label, rotation=0, ha="right", va="center", fontsize=9)
        ax.set_ylim(0, 1)
        ax.set_yticks([])

    bus_axis(axes[5], pidx, "predict idx", "#9467bd", lambda v: f"{v}")
    bus_axis(axes[6], uidx, "update idx",  "#ff7f0e", lambda v: f"{v}")
    bus_axis(axes[7], uctr, "counter",     "#17becf",
             lambda v: f"{v:02b} {STATE[v]}")

    axes[-1].set_xlabel("time (ns)")
    axes[-1].set_xlim(0, T_END)
    axes[-1].set_xticks(range(0, T_END + 1, 10))
    for ax in axes:
        ax.grid(axis="x", color="0.85", linewidth=0.5)

    cap = ("Captured directed window. After reset every counter = WN (predict "
           "not-taken). PC_A (idx 0) is trained taken: WN->WT->ST, so "
           "predict_taken rises and stays high. The 'counter' row shows the "
           "PRE-update value at the update index; watch it climb 01->10->11, "
           "then a single not-taken drops ST->WT WITHOUT flipping the "
           "prediction (2-bit hysteresis), and a second not-taken finally "
           "flips it to WN. PC_C (idx 6) trains taken independently.")
    fig.text(0.5, 0.005, cap, ha="center", fontsize=8, wrap=True, color="0.25")

    fig.tight_layout(rect=[0, 0.055, 1, 0.965])
    os.makedirs("docs", exist_ok=True)
    fig.savefig(OUT, dpi=130)
    print(f"wrote {OUT}")


if __name__ == "__main__":
    main()
