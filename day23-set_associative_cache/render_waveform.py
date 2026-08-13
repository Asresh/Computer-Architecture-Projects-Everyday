#!/usr/bin/env python3
"""Render sa_cache.vcd (captured from a real iverilog run) to
docs/sa_cache_waveform.png.

This is a GENUINE simulator capture: we parse the VCD that `make icarus`
produced and draw the directed window with matplotlib. Nothing is
hand-modeled -- every state, way, address and data value shown is read back
out of the VCD the testbench dumped.

Directed window (0..T_END ns), all accesses hitting SET 0:
  * reset,
  * LD 0  : compulsory MISS -> ALLOC (4 refill beats) -> re-LOOKUP hit (way0),
  * LD 1  : read HIT in the same block,
  * ST 2  : store HIT that dirties way0,
  * LD 16 / LD 32 / LD 48 : three more compulsory misses fill ways 1,2,3
            (set now full; tree-PLRU order established),
  * LD 64 : full-set miss whose PLRU victim (way0) is DIRTY -> WRITEBACK
            (4 beats flush 0xDEADBEEF) -> ALLOCATE (4 beats) -> re-LOOKUP hit,
  * LD 2  : re-fetch of the evicted tag proves the flushed store survived
            (cpu_rdata = 0xDEADBEEF).
"""
import os
import re
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

VCD = "sa_cache.vcd"
OUT = os.path.join("docs", "sa_cache_waveform.png")

T_END = 700  # ns; covers the full directed window
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
    dbg_way   = series("dbg_way")
    cpu_addr  = series("cpu_addr")
    mem_addr  = series("mem_addr")
    cpu_rdata = series("cpu_rdata")

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

    bus = [("state",     dbg_state, "#17becf", lambda v: STATE.get(v, str(v))),
           ("way",       dbg_way,   "#2ca02c", lambda v: f"w{v}"),
           ("cpu_addr",  cpu_addr,  "#9467bd", lambda v: f"{v}"),
           ("mem_addr",  mem_addr,  "#7f7f7f", lambda v: f"{v}"),
           ("cpu_rdata", cpu_rdata, "#bcbd22", lambda v: f"{v:08x}")]

    fig, axes = plt.subplots(len(scal) + len(bus), 1,
                             figsize=(16, 12), sharex=True)
    fig.suptitle("Day23 - 4-way set-associative write-back cache, tree-PLRU  "
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
                    ax.text(t + 0.5, 0.5, fmt(v), va="center", ha="left",
                            fontsize=8, family="monospace", color=color)
                    ax.axvline(t, color=color, linewidth=0.7, alpha=0.45)
                prev = v
        ax.set_ylabel(label, rotation=0, ha="right", va="center", fontsize=9)
        ax.set_ylim(0, 1)
        ax.set_yticks([])

    b0 = len(scal)
    for j, (label, s, color, fmt) in enumerate(bus):
        bus_axis(axes[b0 + j], s, label, color, fmt)

    axes[-1].set_xlabel("time (ns)   -   1 clock = 10 ns")
    axes[-1].set_xlim(0, T_END)
    axes[-1].set_xticks(range(0, T_END + 1, 20))
    for ax in axes:
        ax.grid(axis="x", color="0.85", linewidth=0.5)

    cap = ("Captured directed window (all accesses map to SET 0). LD 0 misses "
           "cold: state LOOKUP->ALLOC, mem_req bursts 4 refill words, re-LOOKUP "
           "returns way0 (cpu_ready, cpu_hit=0). LD 1 HITS (cpu_hit=1). ST 2 "
           "dirties way0. LD 16/32/48 fill ways 1,2,3 (set full). LD 64's "
           "tree-PLRU victim is the DIRTY way0: state WR-BACK (mem_we=1, 4 beats "
           "flush 0xDEADBEEF) then ALLOC (4 beats) -- write-back + write-allocate "
           "eviction. LD 2 re-fetches the evicted block: cpu_rdata=deadbeef, so "
           "the flushed store survived. Genuine iverilog capture, not hand-drawn.")
    fig.text(0.5, 0.005, cap, ha="center", fontsize=8, wrap=True, color="0.25")

    fig.tight_layout(rect=[0, 0.055, 1, 0.965])
    os.makedirs("docs", exist_ok=True)
    fig.savefig(OUT, dpi=130)
    print(f"wrote {OUT}")


if __name__ == "__main__":
    main()
