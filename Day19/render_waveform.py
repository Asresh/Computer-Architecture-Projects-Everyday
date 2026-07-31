#!/usr/bin/env python3
"""Render docs/argmax_reduce_waveform.png from the captured argmax_reduce.vcd.

Parses the VCD produced by the Icarus Verilog run, reconstructs each probed
signal, and draws a cycle-accurate timing diagram of reset plus the first
directed launches of the argmax/argmin reduction tree: an ascending ramp
(argmax then argmin), a descending ramp, and an all-equal vector (tie broken
to the lowest lane).  It shows the input handshake (in_valid), the per-launch
`mode` bit (0=argmax / 1=argmin), the packed input vector (in_data, lane0..7),
and the pipelined result {out_valid, best_val, best_idx} which emerges a fixed
LAT = 1 + log2(LANES) = 4 sample-columns after each launch - one reduction in,
one {value,index} out per clock (fully pipelined, data-independent latency).

This is a REAL captured trace from the Icarus Verilog simulation VCD, not a
hand-drawn diagram.
"""
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import Rectangle

VCD = "argmax_reduce.vcd"
WIDTH = 16
N = 8

# leaf name -> friendly label (first occurrence in tb scope)
WANT = {
    "clk": "clk",
    "rst_n": "rst_n",
    "in_valid": "in_valid",
    "mode": "mode",
    "in_data": "in_data",
    "out_valid": "out_valid",
    "best_val": "best_val",
    "best_idx": "best_idx",
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


def scalar(bits):
    iv = to_int(bits)
    return "x" if iv is None else str(iv)


def main():
    changes, width = parse_vcd(VCD)

    clk_seq = changes.get("clk", [])
    edges = [t for (t, v) in clk_seq if v == "1"]
    NCYC = 16  # reset + the first directed launches and their reduced outputs
    edges = edges[:NCYC]

    labels = ["clk", "rst_n", "in_valid", "mode", "in_data",
              "out_valid", "best_val", "best_idx"]
    # bus rows carry a value string; the rest are single-bit waveforms
    is_bus = {"in_data": "vec", "best_val": "num", "best_idx": "num",
              "clk": None, "rst_n": None, "in_valid": None,
              "mode": None, "out_valid": None}

    ncol = len(edges)
    row_h = 1.0
    fig_w = max(15, 1.3 * ncol)
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
            kind = is_bus[lab]
            if kind is None:
                hi = (raw == "1")
                col = C_HI if hi else C_LO
                yy = y + (row_h if hi else 0.0)
                ax.plot([x, x + 1.0], [yy, yy], color=col, lw=2.4)
                ax.plot([x, x], [y, y + row_h], color=col, lw=0.8, alpha=0.5)
            else:
                txt = unpack(raw) if kind == "vec" else scalar(raw)
                active = txt not in ("x",)
                ec = C_BUSE if active else "#c2cbd4"
                ax.add_patch(Rectangle((x + 0.03, y + 0.12), 0.94, row_h - 0.24,
                                       facecolor=C_BUS, edgecolor=ec, lw=1.2))
                ax.text(x + 0.5, y + row_h / 2, txt, ha="center", va="center",
                        fontsize=6.4 if kind == "vec" else 8.5,
                        family="monospace",
                        color=C_TXT if active else "#7a848d")

    ytop = len(labels) * (row_h + 0.45)
    for c in range(ncol + 1):
        ax.axvline(c, color="#dde3ea", lw=0.6, zorder=0)
    for c in range(ncol):
        ax.text(c + 0.5, ytop + 0.05, "c{}".format(c), ha="center", va="bottom",
                fontsize=8, color="#5a6673")

    notes = [
        (1, "reset\n(rst_n=0)"),
        (5, "launch: ramp\n10 20..80\nmode=0 argmax"),
        (6, "launch: same\nmode=1 argmin"),
        (9, "argmax(ramp)\n(4 cols later)\nval=80 idx=7"),
        (10, "argmin(ramp)\nval=10 idx=0"),
        (13, "descending &\nall-equal tie\n-> idx0 launches"),
    ]
    for cyc, txt in notes:
        if cyc < ncol:
            ax.text(cyc + 0.5, -1.9, txt, ha="center", va="top", fontsize=7.0,
                    color="#3a4a5e",
                    bbox=dict(boxstyle="round,pad=0.25", fc="#f2f6fb",
                              ec="#c2cbd4", lw=0.7))

    ax.set_xlim(-3.4, ncol + 0.2)
    ax.set_ylim(-3.5, ytop + 0.7)
    ax.axis("off")
    ax.set_title(
        "Day19 - Pipelined Argmax/Argmin Reduction Tree "
        "(LANES=8, WIDTH=16): captured simulation timing (Icarus Verilog VCD)\n"
        "packed input vector (in_data, lane0..lane7) reduced under the per-launch "
        "mode bit (0=argmax / 1=argmin); the {best_val, best_idx} result emerges "
        "LAT = 1 + log2(8) = 4 sample-columns after launch - one reduction in / "
        "one {value,index} out per clock (fully pipelined, data-independent latency)",
        fontsize=11, color=C_TXT, pad=14)

    fig.tight_layout()
    fig.savefig("docs/argmax_reduce_waveform.png", dpi=140,
                bbox_inches="tight", facecolor="white")
    print("wrote docs/argmax_reduce_waveform.png")


if __name__ == "__main__":
    main()
