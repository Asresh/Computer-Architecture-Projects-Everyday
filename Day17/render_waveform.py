#!/usr/bin/env python3
"""Render docs/bitonic_sorter_waveform.png from the captured bitonic_sorter.vcd.

Parses the VCD produced by the Icarus Verilog run, reconstructs each probed
signal, and draws a cycle-accurate timing diagram of reset plus the first few
directed launches: an already-sorted vector, a reverse-sorted vector, an
all-equal vector, an alternating vector and two descending launches. It shows
the input handshake (in_valid, dir_asc) and the packed input vector alongside
the sorted output (out_valid, out_keys) that emerges a fixed 7 cycles later
(the pipeline latency LAYERS+1 for N=8), demonstrating one-vector-per-cycle
throughput.

This is a REAL captured trace from the Icarus Verilog simulation VCD, not a
hand-drawn diagram.
"""
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import Rectangle

VCD = "bitonic_sorter.vcd"
WIDTH = 16
N = 8

# leaf name -> friendly label (first occurrence = tb scope)
WANT = {
    "clk": "clk",
    "in_valid": "in_valid",
    "dir_asc": "dir_asc",
    "in_keys": "in_keys",
    "out_valid": "out_valid",
    "out_keys": "out_keys",
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
    = least-significant slice), returned as a compact 'v0 v1 .. v7' string."""
    iv = to_int(bits)
    if iv is None:
        return "x"
    lanes = [(iv >> (i * WIDTH)) & ((1 << WIDTH) - 1) for i in range(N)]
    return " ".join(str(x) for x in lanes)


def main():
    changes, width = parse_vcd(VCD)

    clk_seq = changes.get("clk", [])
    edges = [t for (t, v) in clk_seq if v == "1"]
    NCYC = 22  # reset + the first directed launches and their sorted outputs
    edges = edges[:NCYC]

    labels = ["clk", "in_valid", "dir_asc", "in_keys", "out_valid", "out_keys"]
    is_bus = {"in_keys": True, "out_keys": True,
              "clk": False, "in_valid": False, "dir_asc": False,
              "out_valid": False}

    ncol = len(edges)
    row_h = 1.0
    fig_w = max(15, 1.15 * ncol)
    fig_h = 0.95 * len(labels) + 2.6
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
                        fontsize=6.6, family="monospace",
                        color=C_TXT if active else "#7a848d", rotation=0)

    ytop = len(labels) * (row_h + 0.45)
    for c in range(ncol + 1):
        ax.axvline(c, color="#dde3ea", lw=0.6, zorder=0)
    for c in range(ncol):
        ax.text(c + 0.5, ytop + 0.05, "c{}".format(c), ha="center", va="bottom",
                fontsize=8, color="#5a6673")

    notes = [
        (1, "reset\n(rst_n=0)"),
        (5, "launch A\n(already-sorted\nvector, asc)"),
        (6, "launch B\nreverse -> asc"),
        (7, "launch C\nall-equal"),
        (11, "result A out\n(6 cols after\nlaunch A; see note)"),
        (12, "result B\nascending"),
        (17, "descending\nlaunches / drain"),
    ]
    for cyc, txt in notes:
        if cyc < ncol:
            ax.text(cyc + 0.5, -1.7, txt, ha="center", va="top", fontsize=7.2,
                    color="#3a4a5e",
                    bbox=dict(boxstyle="round,pad=0.25", fc="#f2f6fb",
                              ec="#c2cbd4", lw=0.7))

    ax.set_xlim(-3.4, ncol + 0.2)
    ax.set_ylim(-3.1, ytop + 0.7)
    ax.axis("off")
    ax.set_title(
        "Day17 - Pipelined Bitonic Sorting Network (N=8, WIDTH=16): captured "
        "simulation timing (Icarus Verilog VCD)\n"
        "packed input vector (in_keys, lane0..lane7) and its fully-sorted "
        "output (out_keys); 7-stage pipeline (LAYERS+1), so a launch sampled at "
        "column c5 emerges at c11 (6 sample-columns later, as the launch is "
        "captured on the same rising edge it is observed); one vector in / one "
        "sorted vector out per clock",
        fontsize=11, color=C_TXT, pad=14)

    fig.tight_layout()
    fig.savefig("docs/bitonic_sorter_waveform.png", dpi=140,
                bbox_inches="tight", facecolor="white")
    print("wrote docs/bitonic_sorter_waveform.png")


if __name__ == "__main__":
    main()
