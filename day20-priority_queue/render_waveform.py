#!/usr/bin/env python3
"""Render docs/priority_queue_waveform.png from the captured priority_queue.vcd.

Parses the VCD produced by the Icarus Verilog run and draws a cycle-accurate
timing diagram of the DIRECTED region: reset, five out-of-order ENQUEUEs (incl.
a duplicate key 20 to show price-time / FIFO ordering), the sorted EXTRACT-MIN
drain (10, 20, 20, ...), a mid-stream smaller insert (key 5), and a DEQ on the
empty queue that latches `underflow`.  Each row is a probed signal; `op` is
decoded to NOP / ENQ / DEQ, and the peek bus {min_key : min_data} plus `count`
track the live minimum after every single-cycle operation.

This is a REAL captured trace from the Icarus Verilog simulation VCD, not a
hand-drawn diagram.
"""
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import Rectangle

VCD = "priority_queue.vcd"

# leaf name -> friendly label (first occurrence in the tb scope is the DUT probe)
WANT = {
    "clk": "clk",
    "rst_n": "rst_n",
    "op": "op",
    "enq_key": "enq_key",
    "enq_data": "enq_data",
    "min_key": "min_key",
    "min_data": "min_data",
    "count": "count",
    "min_valid": "min_valid",
    "empty": "empty",
    "full": "full",
    "underflow": "underflow",
}


def parse_vcd(path):
    with open(path) as f:
        text = f.read()
    header, _, body = text.partition("$enddefinitions")
    id_of, width = {}, {}
    for line in header.splitlines():
        s = line.strip()
        if s.startswith("$var"):
            p = s.split()
            w, vid, name = int(p[2]), p[3], p[4]
            if name in WANT and WANT[name] not in id_of:
                id_of[WANT[name]] = vid
                width[WANT[name]] = w
    id2lab = {v: k for k, v in id_of.items()}
    changes = {lab: [] for lab in id_of}
    t = 0
    for line in body.splitlines():
        s = line.strip()
        if not s:
            continue
        if s[0] == "#":
            t = int(s[1:])
        elif s[0] in "01xzXZ":
            if s[1:] in id2lab:
                changes[id2lab[s[1:]]].append((t, s[0]))
        elif s[0] in "bB":
            p = s.split()
            if len(p) == 2 and p[1] in id2lab:
                changes[id2lab[p[1]]].append((t, p[0][1:]))
    return changes, width


def val_at(seq, t):
    v = "x"
    for (tt, val) in seq:
        if tt <= t:
            v = val
        else:
            break
    return v


def to_int(bits):
    try:
        return int(bits, 2)
    except (ValueError, TypeError):
        return None


def scalar(bits):
    iv = to_int(bits)
    return "x" if iv is None else str(iv)


def op_name(bits):
    iv = to_int(bits)
    return {0: "NOP", 1: "ENQ", 2: "DEQ", 3: "NOP"}.get(iv, "x")


def main():
    changes, width = parse_vcd(VCD)

    clk_seq = changes.get("clk", [])
    edges = [t for (t, v) in clk_seq if v == "1"]
    NCYC = 16   # reset + the directed insert/extract/underflow trace
    edges = edges[:NCYC]

    labels = ["clk", "rst_n", "op", "enq_key", "enq_data",
              "count", "min_valid", "min_key", "min_data",
              "empty", "full", "underflow"]
    # how each row is drawn: None = single-bit wave, otherwise a value box
    kind_of = {
        "clk": None, "rst_n": None, "min_valid": None,
        "empty": None, "full": None, "underflow": None,
        "op": "op", "enq_key": "num", "enq_data": "hex",
        "count": "num", "min_key": "num", "min_data": "hex",
    }

    ncol = len(edges)
    row_h = 1.0
    fig_w = max(15, 1.35 * ncol)
    fig_h = 0.9 * len(labels) + 2.8
    fig, ax = plt.subplots(figsize=(fig_w, fig_h))

    C_HI = "#2e7d32"
    C_LO = "#9aa4ad"
    C_BUS = "#e8eef5"
    C_BUSE = "#3f6fb0"
    C_TXT = "#10233b"

    for r, lab in enumerate(labels):
        y = (len(labels) - 1 - r) * (row_h + 0.42)
        ax.text(-0.4, y + row_h / 2, lab, ha="right", va="center",
                fontsize=11, family="monospace", color=C_TXT)
        seq = changes.get(lab, [])
        for c, t in enumerate(edges):
            x = c
            if lab == "clk":
                ax.plot([x, x + 0.5, x + 0.5, x + 1.0],
                        [y, y, y + row_h, y + row_h], color="#456", lw=1.6)
                continue
            raw = val_at(seq, t)
            kind = kind_of[lab]
            if kind is None:
                hi = (raw == "1")
                col = C_HI if hi else C_LO
                yy = y + (row_h if hi else 0.0)
                ax.plot([x, x + 1.0], [yy, yy], color=col, lw=2.4)
                ax.plot([x, x], [y, y + row_h], color=col, lw=0.8, alpha=0.5)
            else:
                if kind == "op":
                    txt = op_name(raw)
                    active = txt in ("ENQ", "DEQ")
                elif kind == "hex":
                    iv = to_int(raw)
                    txt = "x" if iv is None else "{:04X}".format(iv)
                    active = iv is not None
                else:
                    txt = scalar(raw)
                    active = txt != "x"
                ec = C_BUSE if active else "#c2cbd4"
                fc = "#dfeaf7" if (kind == "op" and active) else C_BUS
                ax.add_patch(Rectangle((x + 0.05, y + 0.12), 0.90, row_h - 0.24,
                                       facecolor=fc, edgecolor=ec, lw=1.2))
                ax.text(x + 0.5, y + row_h / 2, txt, ha="center", va="center",
                        fontsize=8.5, family="monospace",
                        color=C_TXT if active else "#7a848d")

    ytop = len(labels) * (row_h + 0.42)
    for c in range(ncol + 1):
        ax.axvline(c, color="#dde3ea", lw=0.6, zorder=0)
    for c in range(ncol):
        ax.text(c + 0.5, ytop + 0.05, "c{}".format(c), ha="center", va="bottom",
                fontsize=8, color="#5a6673")

    notes = [
        (1,  "reset\nrst_n=0\ncount=0"),
        (3,  "ENQ 50,20,80\nout-of-order\ninserts"),
        (5,  "ENQ dup key 20\nthen ENQ 10\nmin -> 10"),
        (7,  "DEQ: pops 10\nthen 20/B6B6\n(price-time FIFO)"),
        (10, "ENQ 5 mid-drain\nmin -> 5\nO(1) insert"),
        (13, "drain 5,50,80\n-> empty"),
        (15, "DEQ on empty\nunderflow latched"),
    ]
    for cyc, txt in notes:
        if cyc < ncol:
            ax.text(cyc + 0.5, -1.9, txt, ha="center", va="top", fontsize=7.2,
                    color="#3a4a5e",
                    bbox=dict(boxstyle="round,pad=0.25", fc="#f2f6fb",
                              ec="#c2cbd4", lw=0.7))

    ax.set_xlim(-3.4, ncol + 0.2)
    ax.set_ylim(-3.6, ytop + 0.7)
    ax.axis("off")
    ax.set_title(
        "Day20 - Systolic Shift-Register Priority Queue "
        "(DEPTH=8, KEY_W=16): captured simulation timing (Icarus Verilog VCD)\n"
        "one op/cycle (op = NOP/ENQ/DEQ); cell[0] always holds the minimum, so "
        "{min_key : min_data} + count are the live extract-min peek.  Duplicate "
        "key 20 retires B6B6 before D8D8 (price-time FIFO); a mid-drain ENQ 5 "
        "inserts in a single cycle; DEQ on the empty queue latches underflow.",
        fontsize=11, color=C_TXT, pad=14)

    fig.tight_layout()
    fig.savefig("docs/priority_queue_waveform.png", dpi=140,
                bbox_inches="tight", facecolor="white")
    print("wrote docs/priority_queue_waveform.png")


if __name__ == "__main__":
    main()
