#!/usr/bin/env python3
"""Render dm_cache.vcd (captured from a real iverilog run) to
docs/dm_cache_waveform.png.

This is a GENUINE simulator capture: we parse the VCD that `make icarus`
produced and draw the directed window with matplotlib. Nothing is
hand-modeled -- every state, address, and data value shown is read back out
of the VCD the testbench dumped.

The window (0..335 ns) covers, in order:
  * reset,
  * a COMPULSORY MISS on addr 8 -> ALLOCATE (4 refill beats) -> re-LOOKUP hit,
  * a plain read HIT,
  * a store HIT that dirties the line, and a read-back,
  * a CONFLICT MISS on addr 40 (same line, different tag) whose victim is
    dirty -> WRITEBACK (4 beats) -> ALLOCATE (4 beats) -> re-LOOKUP hit.
"""
import os
import re
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

VCD = "dm_cache.vcd"
OUT = os.path.join("docs", "dm_cache_waveform.png")

T_END = 335  # end of the directed writeback window
STATE = {0: "IDLE", 1: "LOOKUP", 2: "WR-BACK", 3: "ALLOC"}


def parse_vcd(path):
    """Return (name->symbol map, {sym: [(time_ns, value_str)]})."""
    name2sym = {}
    changes = {}
    cur_t = 0.0
    in_defs = True
    PS_PER_NS = 1000.0  # timescale 1ns/1ps
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
            elif line[0] in "01xzXZ":
                sym = line[1:]
                changes.setdefault(sym, []).append((cur_t, line[0]))
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


def to_int(bits):
    if bits is None or any(c in "xzXZ" for c in bits):
        return None
    return int(bits, 2)


def main():
    name2sym, changes = parse_vcd(VCD)

    def series(name):
        return changes.get(name2sym.get(name, ""), [])

    clk       = series("clk")
    rst_n     = series("rst_n")
    cpu_req   = series("cpu_req")
    cpu_we    = series("cpu_we")
    cpu_ready = series("cpu_ready")
    cpu_hit   = series("cpu_hit")
    mem_req   = series("mem_req")
    mem_we    = series("mem_we")
    dbg_state = series("dbg_state")
    cpu_addr  = series("cpu_addr")
    cpu_rdata = series("cpu_rdata")
    mem_addr  = series("mem_addr")

    fine = [x * 0.1 for x in range(0, T_END * 10 + 1)]
    ts   = list(range(0, T_END + 1))

    scal = [("clk",       clk,       "#1f77b4"),
            ("rst_n",     rst_n,     "#8c564b"),
            ("cpu_req",   cpu_req,   "#2ca02c"),
            ("cpu_we",    cpu_we,    "#98df8a"),
            ("cpu_ready", cpu_ready, "#d62728"),
            ("cpu_hit",   cpu_hit,   "#e377c2"),
            ("mem_req",   mem_req,   "#ff7f0e"),
            ("mem_we",    mem_we,    "#ffbb78")]

    n_bus = 4
    fig, axes = plt.subplots(len(scal) + n_bus, 1,
                             figsize=(15, 12), sharex=True)
    fig.suptitle("Day7 - direct-mapped write-back / write-allocate cache  "
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

    b0 = len(scal)
    bus_axis(axes[b0 + 0], dbg_state, "state", "#17becf",
             lambda v: STATE.get(v, str(v)))
    bus_axis(axes[b0 + 1], cpu_addr,  "cpu_addr", "#9467bd", lambda v: f"{v}")
    bus_axis(axes[b0 + 2], mem_addr,  "mem_addr", "#7f7f7f", lambda v: f"{v}")
    bus_axis(axes[b0 + 3], cpu_rdata, "cpu_rdata", "#bcbd22",
             lambda v: f"{v:08x}")

    axes[-1].set_xlabel("time (ns)   -   1 clock = 10 ns")
    axes[-1].set_xlim(0, T_END)
    axes[-1].set_xticks(range(0, T_END + 1, 20))
    for ax in axes:
        ax.grid(axis="x", color="0.85", linewidth=0.5)

    cap = ("Captured directed window. addr 8 (index 2) misses cold: state goes "
           "LOOKUP->ALLOC, mem_req bursts 4 refill words, then a re-LOOKUP "
           "returns the block (cpu_ready, cpu_hit=0 = the original access "
           "missed). The next read HITS (cpu_hit=1). A store hit dirties the "
           "line. Then addr 40 maps to the SAME line with a different tag: its "
           "dirty victim is flushed (state WR-BACK, mem_we=1, 4 beats) before "
           "the new block is ALLOC'd (4 beats) -- classic write-back + "
           "write-allocate eviction. Genuine iverilog capture, not hand-drawn.")
    fig.text(0.5, 0.005, cap, ha="center", fontsize=8, wrap=True, color="0.25")

    fig.tight_layout(rect=[0, 0.05, 1, 0.965])
    os.makedirs("docs", exist_ok=True)
    fig.savefig(OUT, dpi=130)
    print(f"wrote {OUT}")


if __name__ == "__main__":
    main()
