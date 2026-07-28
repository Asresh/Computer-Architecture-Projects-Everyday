#!/usr/bin/env python3
"""Render decoder.vcd (captured from a real iverilog run) to
docs/decoder_waveform.png.

This is a genuine simulator capture: we parse the VCD that `make icarus`
produced and draw the directed showcase window with matplotlib. Nothing is
hand-modeled -- every control line and immediate shown is read back out of the
VCD.
"""
import os
import re
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

VCD = "decoder.vcd"
OUT = os.path.join("docs", "decoder_waveform.png")

ALU = {0: "ADD", 1: "SUB", 2: "SLL", 3: "SLT", 4: "SLTU",
       5: "XOR", 6: "SRL", 7: "SRA", 8: "OR", 9: "AND"}
RES = {0: "ALU", 1: "MEM", 2: "PC+4"}


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
    # First occurrence of each name is the top-level (tb_decoder) signal.
    name2sym = {}
    for sym, name in id2name.items():
        name2sym.setdefault(name, sym)

    def series(name):
        return changes.get(name2sym.get(name, ""), [])

    clk        = series("clk")
    reg_write  = series("reg_write")
    alu_src    = series("alu_src")
    mem_read   = series("mem_read")
    mem_write  = series("mem_write")
    branch     = series("branch")
    jump       = series("jump")
    instr      = series("instr")
    alu_ctrl   = series("alu_ctrl")
    result_src = series("result_src")
    imm        = series("imm")

    # Directed showcase: 8 instructions, one every 2 ns -> window 0..16 ns.
    T_END = 16
    ts = list(range(0, T_END + 1))
    fine = [x * 0.1 for x in range(0, T_END * 10 + 1)]

    scal = [("clk", clk, "#1f77b4"), ("reg_write", reg_write, "#2ca02c"),
            ("alu_src", alu_src, "#8c564b"), ("mem_read", mem_read, "#e377c2"),
            ("mem_write", mem_write, "#7f7f7f"), ("branch", branch, "#bcbd22"),
            ("jump", jump, "#17becf")]

    nrows = len(scal) + 4       # + instr, alu_ctrl, result_src, imm
    fig, axes = plt.subplots(nrows, 1, figsize=(13, 10.5), sharex=True)
    fig.suptitle("Day3 - RV32I decoder + immgen  (captured from iverilog VCD)",
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
                    ax.text(t + 0.12, 0.5, fmt(v), va="center", ha="left",
                            fontsize=7.0, family="monospace", color=color)
                    ax.axvline(t, color=color, linewidth=0.8, alpha=0.5)
                prev = v
        ax.set_ylabel(label, rotation=0, ha="right", va="center")
        ax.set_ylim(0, 1)
        ax.set_yticks([])

    hx = lambda v: f"{v & 0xFFFFFFFF:08X}"
    bus_axis(axes[len(scal) + 0], instr,      "instr",
             "#d62728", hx)
    bus_axis(axes[len(scal) + 1], alu_ctrl,   "alu_ctrl",
             "#9467bd", lambda v: ALU.get(v, "?"))
    bus_axis(axes[len(scal) + 2], result_src, "result_src",
             "#ff7f0e", lambda v: RES.get(v, "?"))
    bus_axis(axes[len(scal) + 3], imm,        "imm",
             "#1f77b4", hx)

    axes[-1].set_xlabel("time (ns)")
    axes[-1].set_xlim(0, T_END)
    axes[-1].set_xticks(range(0, T_END + 1, 2))
    for ax in axes:
        ax.grid(axis="x", color="0.85", linewidth=0.5)

    cap = ("Directed showcase, one instruction per 2 ns: addi (imm=0000000A, "
           "alu_src), add / sub (R-type, alu_src=0), lw (mem_read, result MEM, "
           "imm=00000004), sw (mem_write, imm=00000008), beq (branch, alu_ctrl "
           "SUB, imm=00000010), jal (jump, result PC+4, imm=00000020), "
           "lui (imm=ABCDE000).")
    fig.text(0.5, 0.005, cap, ha="center", fontsize=8, wrap=True, color="0.25")

    fig.tight_layout(rect=[0, 0.04, 1, 0.97])
    os.makedirs("docs", exist_ok=True)
    fig.savefig(OUT, dpi=130)
    print(f"wrote {OUT}")


if __name__ == "__main__":
    main()
