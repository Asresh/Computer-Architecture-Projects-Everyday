#!/usr/bin/env python3
"""
render_waveform.py -- render a REAL captured waveform for the Day21 CORDIC engine.

Parses cordic_pipelined.vcd (produced by the Icarus run) and plots the opening
window of the simulation: reset de-assertion, the first back-to-back ROTATION
(cos/sin) launches, the fixed pipeline latency, and the first results emerging.
Signed buses are decoded from Q2.13 fixed point to real values.

Output: docs/cordic_pipelined_waveform.png
"""
import os
import re
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

VCD   = "cordic_pipelined.vcd"
FRAC  = 13
SCALE = float(1 << FRAC)

# Signals we want (VCD identifier -> friendly name), resolved from the header.
WANT = ["clk", "rst_n", "in_valid", "mode", "z_in", "out_valid",
        "out_mode", "x_out", "y_out", "z_out"]


def parse_vcd(path):
    id_of = {}          # friendly name -> vcd symbol
    width_of = {}       # symbol -> width
    with open(path) as f:
        lines = f.readlines()

    # --- header: $var declarations ---
    for ln in lines:
        m = re.match(r"\$var\s+\w+\s+(\d+)\s+(\S+)\s+([^\s\[]+)(\s*\[[^\]]*\])?\s+\$end", ln)
        if m:
            width, sym, name = int(m.group(1)), m.group(2), m.group(3)
            if name in WANT and name not in id_of:
                id_of[name] = sym
                width_of[sym] = width

    sym_to_name = {v: k for k, v in id_of.items()}

    # --- body: value changes, timestamped ---
    series = {n: [] for n in id_of}   # name -> list of (time, intvalue)
    t = 0
    in_dump = False
    for ln in lines:
        ln = ln.strip()
        if not ln:
            continue
        if ln.startswith("#"):
            t = int(ln[1:])
            continue
        if ln in ("$dumpvars", "$end"):
            in_dump = True
            continue
        # scalar change: e.g. "1!" or "0#"
        if ln[0] in "01xz":
            val, sym = ln[0], ln[1:]
            if sym in sym_to_name:
                v = 0 if val in "xz" else int(val)
                series[sym_to_name[sym]].append((t, v))
        # vector change: e.g. "b1010 %"
        elif ln[0] == "b":
            parts = ln.split()
            bits, sym = parts[0][1:], parts[1]
            if sym in sym_to_name:
                bits_clean = bits.replace("x", "0").replace("z", "0")
                v = int(bits_clean, 2) if bits_clean else 0
                w = width_of[id_of[sym_to_name[sym]]]
                if v >= (1 << (w - 1)):    # two's-complement sign-extend
                    v -= (1 << w)
                series[sym_to_name[sym]].append((t, v))
    return series


def sample(series_list, t):
    """Value of a (time,val) step series at time t (last change <= t)."""
    v = 0
    for (tt, vv) in series_list:
        if tt <= t:
            v = vv
        else:
            break
    return v


def main():
    if not os.path.exists(VCD):
        raise SystemExit("VCD not found; run `make` first to produce " + VCD)
    series = parse_vcd(VCD)

    PERIOD = 10000          # ps (10 ns)
    T0     = 0
    NCYC   = 24
    # dense time grid for step plotting
    times = list(range(T0, T0 + NCYC * PERIOD + 1, 250))

    digital = ["clk", "rst_n", "in_valid", "mode", "out_valid", "out_mode"]
    buses   = ["z_in", "x_out", "y_out", "z_out"]
    order   = digital + buses

    fig, axes = plt.subplots(len(order), 1, figsize=(15, 9), sharex=True)
    fig.suptitle("Day21  Fully-Pipelined Dual-Mode CORDIC  "
                 "(REAL captured Icarus waveform, opening window)\n"
                 "reset -> back-to-back ROTATION launches -> fixed latency "
                 "(ITERS+1 = 15 cyc) -> first cos/sin results",
                 fontsize=12, fontweight="bold")

    xs_ns = [t / 1000.0 for t in times]
    for ax, name in zip(axes, order):
        s = series.get(name, [])
        vals = [sample(s, t) for t in times]
        if name in digital:
            ax.step(xs_ns, vals, where="post", color="#1f77b4", linewidth=1.6)
            ax.set_ylim(-0.4, 1.4)
            ax.set_yticks([0, 1])
        else:
            real = [v / SCALE for v in vals]
            ax.step(xs_ns, real, where="post", color="#d62728", linewidth=1.6)
            lo, hi = min(real), max(real)
            pad = 0.15 * (hi - lo) if hi > lo else 0.5
            ax.set_ylim(lo - pad, hi + pad)
        ax.set_ylabel(name, rotation=0, ha="right", va="center", fontsize=10)
        ax.grid(True, axis="x", linestyle=":", alpha=0.4)
        for c in range(NCYC + 1):
            ax.axvline(c * PERIOD / 1000.0, color="gray", alpha=0.12, linewidth=0.7)

    axes[-1].set_xlabel("time (ns)   [1 clock = 10 ns]", fontsize=10)
    # annotate the pipeline-fill region
    axes[0].annotate("", xy=(0, 1.7), xytext=(0, 1.7))
    plt.tight_layout(rect=[0, 0, 1, 0.95])

    os.makedirs("docs", exist_ok=True)
    out = "docs/cordic_pipelined_waveform.png"
    fig.savefig(out, dpi=110, bbox_inches="tight")
    print("wrote", out)


if __name__ == "__main__":
    main()
