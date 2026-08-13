#!/usr/bin/env python3
"""Render btb_ras.vcd (captured from a real iverilog run) to
docs/btb_ras_waveform.png.

This is a genuine simulator capture: the VCD that `make icarus` produced is
parsed and the directed-scenario window is drawn with matplotlib. Nothing is
hand-modeled -- every predict output, RAS depth, and RAS top shown is read
straight out of the VCD.
"""
import os
import re
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

VCD = "btb_ras.vcd"
OUT = os.path.join("docs", "btb_ras_waveform.png")
T0, T1 = 34, 152          # ns window: the directed scenario (c0..c10)


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


TYPE = {0: "COND", 1: "JUMP", 2: "CALL", 3: "RET"}


def main():
    id2name, changes = parse_vcd(VCD)
    name2sym = {}
    for sym, name in id2name.items():
        name2sym.setdefault(name, sym)

    def series(name):
        return changes.get(name2sym.get(name, ""), [])

    clk      = series("clk")
    rst_n    = series("rst_n")
    p_pc     = series("p_pc")
    p_hit    = series("p_hit")
    p_type   = series("p_type")
    p_target = series("p_target")
    p_rasu   = series("p_ras_used")
    u_valid  = series("u_valid")
    u_type   = series("u_type")
    ras_cnt  = series("ras_count")
    ras_top  = series("ras_top_o")
    unf      = series("unf_sticky")

    fine = [x * 0.2 for x in range(int(T0 / 0.2), int(T1 / 0.2) + 1)]
    ts   = list(range(T0, T1 + 1))

    fig, axes = plt.subplots(12, 1, figsize=(16, 11.5), sharex=True)
    fig.suptitle("Day26 - Branch Target Buffer (BTB) + Return Address Stack "
                 "(RAS)   (captured from iverilog VCD; directed scenario)",
                 fontsize=13, fontweight="bold")

    def digital(ax, s, label, color):
        cv = [1 if (val_at(s, t) == "1") else 0 for t in fine]
        ax.step(fine, cv, where="post", color=color, linewidth=1.4)
        ax.set_ylabel(label, rotation=0, ha="right", va="center")
        ax.set_ylim(-0.3, 1.3)
        ax.set_yticks([])

    def bus(ax, s, label, color, fmt, gate=None):
        ax.axhline(0.5, color=color, linewidth=1.0, alpha=0.30)
        prev = object()
        for t in ts:
            if gate is not None and val_at(gate, t) != "1":
                v = "__gap__"
                if v != prev:
                    prev = v
                continue
            v = to_int(val_at(s, t))
            if v != prev:
                if v is not None:
                    ax.text(t + 0.4, 0.5, fmt(v), va="center", ha="left",
                            fontsize=7.5, family="monospace", color=color)
                    ax.axvline(t, color=color, linewidth=0.7, alpha=0.45)
                prev = v
        ax.set_ylabel(label, rotation=0, ha="right", va="center")
        ax.set_ylim(0, 1)
        ax.set_yticks([])

    hexf = lambda v: f"{v & 0xFFFFFFFF:03X}"

    digital(axes[0], clk,    "clk",         "#1f77b4")
    digital(axes[1], rst_n,  "rst_n",       "#8c564b")
    bus(axes[2], p_pc,       "predict PC",  "#ff7f0e", hexf)
    digital(axes[3], p_hit,  "BTB hit",     "#d62728")
    bus(axes[4], p_type,     "pred type",   "#9467bd", lambda v: TYPE.get(v, "?"))
    bus(axes[5], p_target,   "pred target", "#2ca02c", hexf)
    digital(axes[6], p_rasu, "RAS-used",    "#e377c2")
    bus(axes[7], u_type,     "upd type",    "#17becf",
        lambda v: TYPE.get(v, "?"), gate=u_valid)
    bus(axes[8], ras_cnt,    "RAS depth",   "#7f7f7f", lambda v: str(v))
    bus(axes[9], ras_top,    "RAS top",     "#bcbd22", hexf)
    digital(axes[10], unf,   "underflow",   "#d62728")
    digital(axes[11], u_valid, "upd valid", "#1f77b4")

    axes[-1].set_xlabel("time (ns)")
    axes[-1].set_xlim(T0, T1)
    axes[-1].set_xticks(range(T0, T1 + 1, 5))
    for ax in axes:
        ax.grid(axis="x", color="0.88", linewidth=0.5)

    cap = ("Real iverilog capture of the directed scenario. Around 45ns a taken "
           "JUMP is learned at PC 0x100 (next cycle 'BTB hit' rises with target "
           "0x400). Two CALLs push the RAS to depth 2 ('RAS depth', 'RAS top'). "
           "When PC 0x120 (a RET) is fetched, 'RAS-used' rises and 'pred target' "
           "is supplied from the RAS top (0x110 then 0x10C) as each RET resolve "
           "pops the stack. Once the RAS empties, the RET prediction falls back "
           "to its stored BTB target (0x555); a conditional branch resolving "
           "not-taken evicts its entry (0x104 goes from hit to miss); and a RET "
           "popped from an empty stack latches the sticky 'underflow' flag. "
           "Every value shown is read out of the VCD, not modeled.")
    fig.text(0.5, 0.004, cap, ha="center", fontsize=8, wrap=True, color="0.25")

    fig.tight_layout(rect=[0, 0.055, 1, 0.965])
    os.makedirs("docs", exist_ok=True)
    fig.savefig(OUT, dpi=130)
    print(f"wrote {OUT}")


if __name__ == "__main__":
    main()
