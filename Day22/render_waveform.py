#!/usr/bin/env python3
"""
render_waveform.py -- render a REAL captured waveform for the Day22
Newton-Raphson pipelined reciprocal unit.

Parses recip_nr_pipelined.vcd (produced by the Icarus run) and plots the
opening window: reset de-assertion, the first back-to-back reciprocal launches
(x = 1,2,3,4,5,7,...), the fixed 7-cycle pipeline latency, and the first
results emerging one-per-cycle. The 47-bit unsigned output Y = round(2^46 / x)
is decoded and shown as the recovered real reciprocal value 1/x = Y / 2^46
(log y-axis, since 1/x spans several decades over the input corners).

Output: docs/recip_nr_pipelined_waveform.png
"""
import os, re
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

VCD   = "recip_nr_pipelined.vcd"
SCALE = float(1 << 46)     # output Q-scale: Y = round(2^46 / x)

WANT = ["clk", "rst_n", "in_valid", "x", "out_valid", "div0", "y"]


def parse_vcd(path):
    id_of, width_of = {}, {}
    with open(path) as f:
        lines = f.readlines()
    for ln in lines:
        m = re.match(r"\$var\s+\w+\s+(\d+)\s+(\S+)\s+([^\s\[]+)(\s*\[[^\]]*\])?\s+\$end", ln)
        if m:
            width, sym, name = int(m.group(1)), m.group(2), m.group(3)
            if name in WANT and name not in id_of:
                id_of[name] = sym
                width_of[sym] = width
    sym_to_name = {v: k for k, v in id_of.items()}
    series = {n: [] for n in id_of}
    t = 0
    for ln in lines:
        ln = ln.strip()
        if not ln:
            continue
        if ln.startswith("#"):
            t = int(ln[1:]); continue
        if ln[0] in "01xz":
            val, sym = ln[0], ln[1:]
            if sym in sym_to_name:
                series[sym_to_name[sym]].append((t, 0 if val in "xz" else int(val)))
        elif ln[0] == "b":
            parts = ln.split()
            bits, sym = parts[0][1:], parts[1]
            if sym in sym_to_name:
                clean = bits.replace("x", "0").replace("z", "0")
                series[sym_to_name[sym]].append((t, int(clean, 2) if clean else 0))
    return series


def sample(s, t):
    v = 0
    for (tt, vv) in s:
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
    NCYC   = 22
    times  = list(range(0, NCYC * PERIOD + 1, 250))
    xs_ns  = [t / 1000.0 for t in times]

    digital = ["clk", "rst_n", "in_valid", "out_valid", "div0"]
    order   = digital + ["x", "y"]

    fig, axes = plt.subplots(len(order), 1, figsize=(15, 9.5), sharex=True)
    fig.suptitle("Day22  Fully-Pipelined Newton-Raphson Reciprocal (1/x)  "
                 "(REAL captured Icarus waveform, opening window)\n"
                 "reset -> back-to-back launches x = 1,2,3,4,5,7,255,... -> "
                 "fixed 7-cycle latency -> first reciprocals stream out 1/cycle",
                 fontsize=12, fontweight="bold")

    for ax, name in zip(axes, order):
        s = series.get(name, [])
        vals = [sample(s, t) for t in times]
        if name in digital:
            ax.step(xs_ns, vals, where="post", color="#1f77b4", linewidth=1.6)
            ax.set_ylim(-0.4, 1.4); ax.set_yticks([0, 1])
            ax.set_ylabel(name, rotation=0, ha="right", va="center", fontsize=10)
        elif name == "x":
            ax.step(xs_ns, vals, where="post", color="#2ca02c", linewidth=1.6)
            hi = max(vals) if max(vals) > 0 else 1
            ax.set_ylim(-0.05 * hi, 1.15 * hi)
            ax.set_ylabel("x  (input)", rotation=0, ha="right", va="center", fontsize=10)
        else:  # y -> decode to real reciprocal 1/x = Y / 2^46 (only when valid)
            ovs   = series.get("out_valid", [])
            recip = [(v / SCALE) if (v > 0 and sample(ovs, t) == 1) else float("nan")
                     for v, t in zip(vals, times)]
            ax.step(xs_ns, recip, where="post", color="#d62728", linewidth=1.6)
            ax.set_yscale("log")
            ax.set_ylabel("1/x = y/2^46", rotation=0, ha="right", va="center", fontsize=10)
        ax.grid(True, axis="x", linestyle=":", alpha=0.4)
        for c in range(NCYC + 1):
            ax.axvline(c * PERIOD / 1000.0, color="gray", alpha=0.12, linewidth=0.7)

    # mark the 7-cycle latency between first launch and first result
    iv = series.get("in_valid", [])
    ov = series.get("out_valid", [])
    t_launch = next((t for (t, v) in iv if v == 1), None)
    t_result = next((t for (t, v) in ov if v == 1), None)
    if t_launch is not None and t_result is not None:
        for ax in (axes[2], axes[3]):
            ax.axvline(t_launch / 1000.0, color="green",  linestyle="--", alpha=0.7)
            ax.axvline(t_result / 1000.0, color="red",    linestyle="--", alpha=0.7)
        axes[3].annotate("LATENCY = 7 cycles",
                         xy=(t_result / 1000.0, 0.5), xytext=(t_launch / 1000.0 + 4, 0.5),
                         fontsize=9, color="black",
                         arrowprops=dict(arrowstyle="<->", color="black"))

    axes[-1].set_xlabel("time (ns)   [1 clock = 10 ns]", fontsize=10)
    plt.tight_layout(rect=[0, 0, 1, 0.94])
    os.makedirs("docs", exist_ok=True)
    out = "docs/recip_nr_pipelined_waveform.png"
    fig.savefig(out, dpi=110, bbox_inches="tight")
    print("wrote", out)


if __name__ == "__main__":
    main()
