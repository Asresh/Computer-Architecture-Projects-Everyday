#!/usr/bin/env python3
"""Render regfile.vcd (captured from a real iverilog run) to
docs/regfile_waveform.png.

This is a genuine simulator capture: we parse the VCD that `make icarus`
produced and draw the directed-corner-case window with matplotlib. Nothing is
hand-modeled -- every value shown is read back out of the VCD.
"""
import os
import re
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

VCD = "regfile.vcd"
OUT = os.path.join("docs", "regfile_waveform.png")


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
    # First occurrence of each name is the top-level (tb_regfile) signal.
    name2sym = {}
    for sym, name in id2name.items():
        name2sym.setdefault(name, sym)

    def series(name):
        return changes.get(name2sym.get(name, ""), [])

    clk    = series("clk")
    rst_n  = series("rst_n")
    we     = series("we")
    waddr  = series("waddr")
    wdata  = series("wdata")
    raddr1 = series("raddr1")
    rdata1 = series("rdata1")
    raddr2 = series("raddr2")
    rdata2 = series("rdata2")

    # Directed window: reset + the first ~10 directed cycles (~120 ns).
    T_END = 120
    ts = list(range(0, T_END + 1))
    fine = [x * 0.1 for x in range(0, T_END * 10 + 1)]

    rows = [
        ("clk",    clk),
        ("rst_n",  rst_n),
        ("we",     we),
    ]
    fig, axes = plt.subplots(9, 1, figsize=(14, 9.5), sharex=True)
    fig.suptitle("Day2 - RV32I register file  (captured from iverilog VCD)",
                 fontsize=13, fontweight="bold")

    colors = {"clk": "#1f77b4", "rst_n": "#8c564b", "we": "#2ca02c"}

    # --- scalar rows ---
    for idx, (label, s) in enumerate(rows):
        ax = axes[idx]
        cv = [1 if (val_at(s, t) == "1") else 0 for t in fine]
        ax.step(fine, cv, where="post", color=colors[label], linewidth=1.4)
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
                    ax.text(t + 0.4, 0.5, fmt(v), va="center", ha="left",
                            fontsize=7.5, family="monospace", color=color)
                    ax.axvline(t, color=color, linewidth=0.8, alpha=0.5)
                prev = v
        ax.set_ylabel(label, rotation=0, ha="right", va="center")
        ax.set_ylim(0, 1)
        ax.set_yticks([])

    reg = lambda v: f"x{v}"
    hx  = lambda v: f"{v & 0xFFFFFFFF:08X}"

    bus_axis(axes[3], waddr,  "waddr",  "#9467bd", reg)
    bus_axis(axes[4], wdata,  "wdata",  "#e377c2", hx)
    bus_axis(axes[5], raddr1, "raddr1", "#ff7f0e", reg)
    bus_axis(axes[6], rdata1, "rdata1", "#17becf", hx)
    bus_axis(axes[7], raddr2, "raddr2", "#d62728", reg)
    bus_axis(axes[8], rdata2, "rdata2", "#bcbd22", hx)

    axes[-1].set_xlabel("time (ns)")
    axes[-1].set_xlim(0, T_END)
    axes[-1].set_xticks(range(0, T_END + 1, 10))
    for ax in axes:
        ax.grid(axis="x", color="0.85", linewidth=0.5)

    cap = ("Directed window: synchronous reset clears the file (reads -> 0), "
           "write x5=DEADBEEF then read-back, x0 write dropped (reads 0), "
           "same-cycle write-forwarding of x7=12345678 to rdata1, dual-port "
           "reads of x7/x9, and back-to-back overwrite of x5.")
    fig.text(0.5, 0.005, cap, ha="center", fontsize=8, wrap=True, color="0.25")

    fig.tight_layout(rect=[0, 0.03, 1, 0.97])
    os.makedirs("docs", exist_ok=True)
    fig.savefig(OUT, dpi=130)
    print(f"wrote {OUT}")


if __name__ == "__main__":
    main()
