#!/usr/bin/env python3
"""Render docs/prefix_scan_waveform.png from the captured prefix_scan.vcd.

Parses the VCD produced by the Icarus Verilog run, reconstructs each probed
signal, and draws a cycle-accurate timing diagram of reset plus the first
directed launches: an all-zeros vector, a unit ramp (whose inclusive scan is
the triangular numbers), an all-ones vector (inclusive scan = 1,2,..,8), an
alternating vector, a descending vector and single-hot vectors.  It shows the
input handshake (in_valid) and the packed input vector alongside BOTH the
inclusive-scan output (out_valid_i / out_i, latency LOG2+1 = 4 cycles) and the
exclusive-scan output (out_valid_e / out_e, latency LOG2+2 = 5 cycles),
demonstrating one-vector-per-cycle throughput at fixed data-independent
latency.

This is a REAL captured trace from the Icarus Verilog simulation VCD, not a
hand-drawn diagram.
"""
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import Rectangle

VCD = "prefix_scan.vcd"
WIDTH = 16
N = 8

# leaf name -> friendly label (first occurrence in tb scope)
WANT = {
    "clk": "clk",
    "rst_n": "rst_n",
    "in_valid": "in_valid",
    "in_data": "in_data",
    "o_valid_i": "out_valid_i",
    "o_data_i": "out_i",
    "o_valid_e": "out_valid_e",
    "o_data_e": "out_e",
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
    """last value at or before time t (string of bits or single bit)."""
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
    except ValueError:
        return None


def unpack(bits):
    """Split a packed N*WIDTH bit string into N unsigned lane values (lane0
    = least-significant slice), returned as a compact space-separated string."""
    iv = to_int(bits)
    if iv is None:
        return "x"
    lanes = [(iv >> (i * WIDTH)) & ((1 << WIDTH) - 1) for i in range(N)]
    return " ".join(str(x) for x in lanes)


def main():
    changes, width = parse_vcd(VCD)

    clk_seq = changes.get("clk", [])
    edges = [t for (t, v) in clk_seq if v == "1"]
    NCYC = 20  # reset + the first directed launches and their scanned outputs
    edges = edges[:NCYC]

    labels = ["clk", "rst_n", "in_valid", "in_data",
              "out_valid_i", "out_i", "out_valid_e", "out_e"]
    is_bus = {"in_data": True, "out_i": True, "out_e": True,
              "clk": False, "rst_n": False, "in_valid": False,
              "out_valid_i": False, "out_valid_e": False}

    ncol = len(edges)
    row_h = 1.0
    fig_w = max(16, 1.25 * ncol)
    fig_h = 0.95 * len(labels) + 2.8
    fig, ax = plt.subplots(figsize=(fig_w, fig_h))

    C_HI = "#2e7d32"
    C_LO = "#9aa4ad"
    C_BUS = "#e8eef5"
    C_BUSE = "#3f6fb0"
    C_TXT = "#10233b"

    for r, lab in enumerate(labels):
        y = (len(labels) - 1 - r) * (row_h + 0.45)
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
            if not is_bus[lab]:
                hi = (raw == "1")
                col = C_HI if hi else C_LO
                yy = y + (row_h if hi else 0.0)
                ax.plot([x, x + 1.0], [yy, yy], color=col, lw=2.4)
                ax.plot([x, x], [y, y + row_h], color=col, lw=0.8, alpha=0.5)
            else:
                txt = unpack(raw)
                active = txt not in ("x",)
                fc = C_BUS
                ec = C_BUSE if active else "#c2cbd4"
                ax.add_patch(Rectangle((x + 0.03, y + 0.12), 0.94, row_h - 0.24,
                                       facecolor=fc, edgecolor=ec, lw=1.2))
                ax.text(x + 0.5, y + row_h / 2, txt, ha="center", va="center",
                        fontsize=6.0, family="monospace",
                        color=C_TXT if active else "#7a848d", rotation=0)

    ytop = len(labels) * (row_h + 0.45)
    for c in range(ncol + 1):
        ax.axvline(c, color="#dde3ea", lw=0.6, zorder=0)
    for c in range(ncol):
        ax.text(c + 0.5, ytop + 0.05, "c{}".format(c), ha="center", va="bottom",
                fontsize=8, color="#5a6673")

    notes = [
        (1, "reset\n(rst_n=0)"),
        (5, "launch: ramp\n1 2 3..8\n(in_valid=1)"),
        (6, "launch:\nall-ones"),
        (9, "inclusive of\nramp out\n(4 cols later):\n1 3 6 10 15..36"),
        (10, "exclusive of\nramp out\n(5 cols later):\n0 1 3 6 10.."),
        (14, "single-hot /\noverflow-wrap\nlaunches"),
    ]
    for cyc, txt in notes:
        if cyc < ncol:
            ax.text(cyc + 0.5, -1.9, txt, ha="center", va="top", fontsize=7.0,
                    color="#3a4a5e",
                    bbox=dict(boxstyle="round,pad=0.25", fc="#f2f6fb",
                              ec="#c2cbd4", lw=0.7))

    ax.set_xlim(-3.6, ncol + 0.2)
    ax.set_ylim(-3.5, ytop + 0.7)
    ax.axis("off")
    ax.set_title(
        "Day18 - Kogge-Stone Parallel Prefix-Sum / Inclusive+Exclusive Scan "
        "(N=8, WIDTH=16): captured simulation timing (Icarus Verilog VCD)\n"
        "packed input vector (in_data, lane0..lane7); inclusive scan (out_i) "
        "emerges LOG2+1 = 4 sample-columns after launch, exclusive scan "
        "(out_e) LOG2+2 = 5 columns after; one vector in / one scanned vector "
        "out per clock (fully pipelined, data-independent latency)",
        fontsize=11, color=C_TXT, pad=14)

    fig.tight_layout()
    fig.savefig("docs/prefix_scan_waveform.png", dpi=140,
                bbox_inches="tight", facecolor="white")
    print("wrote docs/prefix_scan_waveform.png")


if __name__ == "__main__":
    main()
