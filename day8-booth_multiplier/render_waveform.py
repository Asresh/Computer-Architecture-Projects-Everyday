#!/usr/bin/env python3
"""Render booth_mul.vcd (captured from a real iverilog run) to
docs/booth_mul_waveform.png.

This is a GENUINE simulator capture. `make icarus` runs the self-checking
testbench, which dumps booth_mul.vcd; this script parses that VCD and draws the
first ~620 ns directed window with matplotlib. Every state, counter value, and
bus value shown is read straight out of the VCD -- nothing is hand-modeled.

The window covers the eight directed multiplies the testbench issues first:
   7*6=42, -7*6=-42, 7*-6=-42, -7*-6=42, 0*123=0, 1*-128=-128,
   -128*-128=16384, 127*127=16129
so you can watch the radix-4 add/shift engine retire two multiplier bits per
RUN cycle (cnt 4->3->2->1), and see the signed product settle when `done`
pulses -- including the sign flips and the most-negative extremes.
"""
import os
import re
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

VCD = "booth_mul.vcd"
OUT = os.path.join("docs", "booth_mul_waveform.png")

T_END = 620                       # ns; covers the 8 directed multiplies
PS_PER_NS = 1000.0                # timescale 1ns/1ps
STATE = {0: "IDLE", 1: "RUN", 2: "DONE"}


def parse_vcd(path, t_stop_ns):
    """Return (name->symbol, {sym:[(t_ns,value)]}) parsing only up to t_stop."""
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


def to_sint(bits, width):
    u = to_uint(bits)
    if u is None:
        return None
    if u >= (1 << (width - 1)):
        u -= (1 << width)
    return u


def main():
    name2sym, changes = parse_vcd(VCD, T_END)

    def series(name):
        return changes.get(name2sym.get(name, ""), [])

    clk   = series("clk")
    rst_n = series("rst_n")
    start = series("start")
    busy  = series("busy")
    done  = series("done")

    state = series("state")           # dut FSM (2-bit enum)
    cnt   = series("cnt")             # iterations remaining
    mcand = series("multiplicand")    # 8-bit signed
    mplr  = series("multiplier")      # 8-bit signed
    accA  = series("A")               # 10-bit signed accumulator
    Qreg  = series("Q")               # 8-bit multiplier register
    prod  = series("product")         # 16-bit signed

    fine = [x * 0.1 for x in range(0, T_END * 10 + 1)]
    ts   = list(range(0, T_END + 1))

    scal = [("clk",   clk,   "#1f77b4"),
            ("rst_n", rst_n, "#8c564b"),
            ("start", start, "#2ca02c"),
            ("busy",  busy,  "#ff7f0e"),
            ("done",  done,  "#d62728")]

    buses = [("state", state, "#17becf", lambda v: STATE.get(v, str(v)), False, 2),
             ("cnt",   cnt,   "#7f7f7f", lambda v: str(v),               False, 4),
             ("mcand", mcand, "#9467bd", lambda v: str(v),               True,  8),
             ("mplr",  mplr,  "#e377c2", lambda v: str(v),               True,  8),
             ("A",     accA,  "#2ca02c", lambda v: str(v),               True, 10),
             ("Q",     Qreg,  "#8c564b", lambda v: str(v),               False, 8),
             ("product", prod, "#bcbd22", lambda v: str(v),              True, 16)]

    fig, axes = plt.subplots(len(scal) + len(buses), 1,
                             figsize=(16, 13), sharex=True)
    fig.suptitle("Day8 - radix-4 Booth signed multiplier "
                 "(captured from iverilog VCD)",
                 fontsize=13, fontweight="bold")

    for idx, (label, s, color) in enumerate(scal):
        ax = axes[idx]
        cv = [1 if (val_at(s, t) == "1") else 0 for t in fine]
        ax.step(fine, cv, where="post", color=color, linewidth=1.4)
        ax.set_ylabel(label, rotation=0, ha="right", va="center", fontsize=9)
        ax.set_ylim(-0.3, 1.3)
        ax.set_yticks([0, 1] if label != "clk" else [])

    def bus_axis(ax, s, label, color, fmt, signed, width):
        ax.axhline(0.5, color=color, linewidth=1.0, alpha=0.30)
        prev = object()
        for t in ts:
            raw = val_at(s, t)
            v = to_sint(raw, width) if signed else to_uint(raw)
            if v != prev:
                if v is not None:
                    ax.text(t + 0.5, 0.5, fmt(v), va="center", ha="left",
                            fontsize=8, family="monospace", color=color)
                    ax.axvline(t, color=color, linewidth=0.7, alpha=0.45)
                prev = v
        ax.set_ylabel(label, rotation=0, ha="right", va="center", fontsize=9)
        ax.set_ylim(0, 1)
        ax.set_yticks([])

    b0 = len(scal)
    for k, (label, s, color, fmt, signed, width) in enumerate(buses):
        bus_axis(axes[b0 + k], s, label, color, fmt, signed, width)

    axes[-1].set_xlabel("time (ns)   -   1 clock = 10 ns")
    axes[-1].set_xlim(0, T_END)
    axes[-1].set_xticks(range(0, T_END + 1, 20))
    for ax in axes:
        ax.grid(axis="x", color="0.85", linewidth=0.5)

    cap = ("Captured directed window. Each multiply loads on `start` (IDLE->RUN), "
           "then the FSM stays in RUN for WIDTH/2 = 4 cycles, retiring two "
           "multiplier bits per cycle as cnt counts 4->3->2->1 and the signed "
           "accumulator A grows via the recoded +/-M, +/-2M adds and arithmetic "
           "right shifts. On DONE, `done` pulses and `product` latches the signed "
           "result: 7*6=42, -7*6=-42, 7*-6=-42, -7*-6=42, 0*123=0, 1*-128=-128, "
           "-128*-128=16384, 127*127=16129. Genuine iverilog capture, not hand-drawn.")
    fig.text(0.5, 0.005, cap, ha="center", fontsize=8, wrap=True, color="0.25")

    fig.tight_layout(rect=[0, 0.055, 1, 0.965])
    os.makedirs("docs", exist_ok=True)
    fig.savefig(OUT, dpi=130)
    print(f"wrote {OUT}")


if __name__ == "__main__":
    main()
