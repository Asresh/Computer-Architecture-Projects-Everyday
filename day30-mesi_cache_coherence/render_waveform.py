#!/usr/bin/env python3
"""Render mesi_cache.vcd (captured from a real iverilog run) to
docs/mesi_cache_waveform.png.

This is a genuine simulator capture: the VCD that `make icarus` produced is
parsed and the Phase-1 directed MESI life-cycle is drawn with matplotlib.
Nothing is hand-modeled -- every address, bus command, snoop response, flushed
value and line state shown is read straight out of the VCD.

Each cycle the testbench drives one CPU access / one remote bus transaction and
completes whatever the cache asked for on the bus; the cache's combinational
outputs are read in that same cycle and the line state updates on the following
rising edge. Every non-clock signal is sampled once per cycle at its settled
pre-edge instant (the same point the self-checking testbench validates), exactly
as a waveform viewer shows one value per clock.
"""
import os
import re
import textwrap
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

VCD = "mesi_cache.vcd"
OUT = os.path.join("docs", "mesi_cache_waveform.png")

# 16 directed cycles. The testbench prints PHASE1_T0 = 40000 ps, so cycle c0
# applies its inputs at the negedge at t=40 ns (#4 settle -> sample at 44,
# rising edge at 45); cell k spans [40+10k, 50+10k].
NCELL   = 16
T_FIRST = 40
T_STEP  = 10
T0, T1  = 34, T_FIRST + NCELL * T_STEP + 6

ST_NAME  = {0: "I", 1: "S", 2: "E", 3: "M"}
ST_COLOR = {0: "#9e9e9e", 1: "#1f77b4", 2: "#2ca02c", 3: "#d62728"}
CMD_NAME = {0: "BusRd", 1: "BusRdX", 2: "BusUpgr", 3: "BusWB"}
FSM_NAME = {0: "IDLE", 1: "WB", 2: "FILL", 3: "UPGR"}


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


def main():
    id2name, changes = parse_vcd(VCD)
    name2sym = {}
    for sym, name in id2name.items():
        name2sym.setdefault(name, sym)   # top (tb) scope seen first -> wins

    def series(name):
        return changes.get(name2sym.get(name, ""), [])

    clk = series("clk")

    samp  = [T_FIRST + 4 + T_STEP * k for k in range(NCELL)]
    edges = [T_FIRST + T_STEP * k for k in range(NCELL + 1)]

    def cell_bits(name):
        s = series(name)
        return [val_at(s, t) for t in samp]

    def cell_ints(name):
        s = series(name)
        return [to_int(val_at(s, t)) for t in samp]

    creq   = cell_bits("cpu_req")
    cwe    = cell_bits("cpu_we")
    caddr  = cell_ints("cpu_addr")
    crdy   = cell_bits("cpu_ready")
    crdat  = cell_ints("cpu_rdata")
    fsm    = cell_ints("dbg_fsm")
    breq   = cell_bits("bus_req")
    bcmd   = cell_ints("bus_cmd")
    baddr  = cell_ints("bus_addr")
    bwdat  = cell_ints("bus_wdata")
    bdone  = cell_bits("bus_done")
    bshr   = cell_bits("bus_shared")
    sval   = cell_bits("snp_valid")
    scmd   = cell_ints("snp_cmd")
    saddr  = cell_ints("snp_addr")
    shit   = cell_bits("snp_hit")
    sflush = cell_bits("snp_flush")
    sdata  = cell_ints("snp_data")
    st0    = cell_ints("st0")

    # gates
    g_wb = ["1" if (breq[k] == "1" and bcmd[k] == 3) else "0" for k in range(NCELL)]

    fine = [x * 0.2 for x in range(int(T0 / 0.2), int(T1 / 0.2) + 1)]

    NROW = 19
    fig, axes = plt.subplots(NROW, 1, figsize=(17, 14.2), sharex=True)
    fig.suptitle("Day30 - MESI Snooping Cache-Coherence Controller: the full "
                 "I/S/E/M life-cycle of one line   "
                 "(captured from iverilog VCD; directed Phase-1 window)",
                 fontsize=13, fontweight="bold")

    def clkrow(ax):
        cv = [1 if (val_at(clk, t) == "1") else 0 for t in fine]
        ax.step(fine, cv, where="post", color="#1f77b4", linewidth=1.4)
        ax.set_ylabel("clk", rotation=0, ha="right", va="center")
        ax.set_ylim(-0.3, 1.3); ax.set_yticks([])

    def digrow(ax, cells, label, color):
        ys = [1 if c == "1" else 0 for c in cells]
        ax.step(edges, ys + [ys[-1]], where="post", color=color, linewidth=1.5)
        ax.set_ylabel(label, rotation=0, ha="right", va="center")
        ax.set_ylim(-0.3, 1.3); ax.set_yticks([])

    def busrow(ax, cells, label, color, fmt, gate=None):
        ax.axhline(0.5, color=color, linewidth=1.0, alpha=0.28)
        for k in range(NCELL):
            if gate is not None and gate[k] != "1":
                continue
            v = cells[k]
            if v is None:
                continue
            xc = edges[k] + T_STEP / 2.0
            ax.text(xc, 0.5, fmt(v), va="center", ha="center",
                    fontsize=8, family="monospace", color=color)
            ax.axvline(edges[k], color=color, linewidth=0.6, alpha=0.35)
        ax.set_ylabel(label, rotation=0, ha="right", va="center")
        ax.set_ylim(0, 1); ax.set_yticks([])

    def staterow(ax, cells, label):
        """The MESI state of one line, drawn as a colour-coded value track."""
        for k in range(NCELL):
            v = cells[k]
            if v is None:
                continue
            col = ST_COLOR.get(v, "0.5")
            ax.add_patch(plt.Rectangle((edges[k], 0.08), T_STEP, 0.84,
                                       facecolor=col, alpha=0.20,
                                       edgecolor=col, linewidth=1.0))
            ax.text(edges[k] + T_STEP / 2.0, 0.5, ST_NAME.get(v, "?"),
                    va="center", ha="center", fontsize=10,
                    fontweight="bold", family="monospace", color=col)
        ax.set_ylabel(label, rotation=0, ha="right", va="center")
        ax.set_ylim(0, 1); ax.set_yticks([])

    hexf = lambda v: f"{v:03X}"
    wrdf = lambda v: f"{v:08X}"
    cmdf = lambda v: CMD_NAME.get(v, "?")
    fsmf = lambda v: FSM_NAME.get(v, "?")

    r = 0
    clkrow(axes[r]);                                                      r += 1
    digrow (axes[r], creq,  "cpu_req",     "#1f77b4");                    r += 1
    digrow (axes[r], cwe,   "cpu_we",      "#1f77b4");                    r += 1
    busrow (axes[r], caddr, "cpu_addr",    "#1f77b4", hexf, gate=creq);   r += 1
    digrow (axes[r], crdy,  "cpu_ready",   "#2ca02c");                    r += 1
    busrow (axes[r], crdat, "cpu_rdata",   "#2ca02c", wrdf, gate=crdy);   r += 1
    busrow (axes[r], fsm,   "miss FSM",    "#7f7f7f", fsmf);              r += 1
    digrow (axes[r], breq,  "bus_req",     "#ff7f0e");                    r += 1
    busrow (axes[r], bcmd,  "bus_cmd",     "#ff7f0e", cmdf, gate=breq);   r += 1
    busrow (axes[r], baddr, "bus_addr",    "#ff7f0e", hexf, gate=breq);   r += 1
    busrow (axes[r], bwdat, "bus_wdata",   "#ff7f0e", wrdf, gate=g_wb);   r += 1
    digrow (axes[r], bdone, "bus_done",    "#ff7f0e");                    r += 1
    digrow (axes[r], bshr,  "bus_shared",  "#8c564b");                    r += 1
    digrow (axes[r], sval,  "snp_valid",   "#9467bd");                    r += 1
    busrow (axes[r], scmd,  "snp_cmd",     "#9467bd", cmdf, gate=sval);   r += 1
    busrow (axes[r], saddr, "snp_addr",    "#9467bd", hexf, gate=sval);   r += 1
    digrow (axes[r], shit,  "snp_hit",     "#9467bd");                    r += 1
    busrow (axes[r], sdata, "snp_flush\ndata", "#d62728", wrdf, gate=sflush)
    r += 1

    # the star of the show: the MESI state of set 0
    staterow(axes[r], st0, "line 0\nMESI");                               r += 1

    # cycle-number ruler drawn over the state row's axis frame
    axr = axes[-1]
    for k in range(NCELL):
        axr.annotate(f"c{k}", xy=(edges[k] + T_STEP / 2.0, -0.34),
                     xycoords=("data", "axes fraction"), ha="center",
                     va="top", fontsize=8, color="0.35")

    axes[-1].set_xlabel("time (ns)                    cycle:", labelpad=16)
    axes[-1].set_xlim(T0, T1)
    axes[-1].set_xticks(range(T_FIRST, T1 + 1, T_STEP))
    for ax in axes:
        ax.grid(axis="x", color="0.90", linewidth=0.5)

    cap = ("Real iverilog capture of the Phase-1 directed life-cycle (compact "
           "demo config ADDR_W=16, LINES=4, one word per coherence block; "
           "A=0x000 and B=0x010 both map to set 0). c1 loads A: line 0 is "
           "Invalid, so the cache issues BusRd. c3 completes it with "
           "bus_shared=0 -- nobody else has a copy -- so the line is filled in "
           "EXCLUSIVE, not Shared. c4 stores to A and hits in E: cpu_ready goes "
           "high in the same cycle with bus_req FLAT AT ZERO -- the silent E->M "
           "upgrade that is the entire reason the E state exists (an MSI "
           "protocol would have had to broadcast an invalidate here). c6 the "
           "other core issues BusRd for A: we hit in M, so snp_hit and "
           "snp_flush assert and we supply the dirty word DEADBEEF on the bus "
           "(memory was stale); the line drops M->S. c7 stores to A again, now "
           "only Shared, so this time the write DOES need the bus: BusUpgr "
           "(c8-c9) invalidates the other copy and the line goes S->M -- note "
           "BusUpgr carries no data, because we already have the line. c10 "
           "loads B, which conflicts with the now-dirty A in set 0: the "
           "replacement must write the victim back first, so bus_cmd=BusWB with "
           "bus_wdata=11112222 (c11-c12) before the BusRd for B is even issued "
           "(c13-c14). That fill returns bus_shared=1, so B lands in SHARED. "
           "c15 the other core upgrades its own copy of B: snp_hit asserts but "
           "snp_flush does NOT (our copy is clean) and the line is invalidated, "
           "S->I, closing the loop. Note the 'line 0 MESI' track is sampled "
           "pre-edge like every other row, so a transition caused in cycle N "
           "first appears in cycle N+1 (the store in c4 hits the line while it "
           "still reads E, and it reads M from c5). Every value shown is read "
           "out of the VCD, not modeled.")
    fig.text(0.5, 0.004, textwrap.fill(cap, 200), ha="center", fontsize=8,
             color="0.25")

    fig.tight_layout(rect=[0, 0.085, 1, 0.965])
    os.makedirs("docs", exist_ok=True)
    fig.savefig(OUT, dpi=130)
    print(f"wrote {OUT}")


if __name__ == "__main__":
    main()
