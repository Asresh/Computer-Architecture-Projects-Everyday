#!/usr/bin/env python3
"""Render docs/smem_bank_conflict_unit_waveform.png from the captured
smem_bank_conflict_unit.vcd.

Parses the VCD produced by the Icarus run, reconstructs each probed signal, and
draws a cycle-accurate timing diagram of the first directed scenarios: reset,
then the directed warp requests (conflict-free stride, N-way conflict, full
broadcast, even-lane mask, 2-way conflict, mixed broadcast+conflict, empty
warp, single lane). For each request the diagram shows the input request
(req_valid, lane_active) alongside the registered response one cycle later
(resp_valid, n_phases, conflict, n_active, n_unique, n_bcast).

This is a REAL captured trace from the Icarus Verilog simulation VCD, not a
hand-drawn diagram.
"""
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import Rectangle

VCD = "smem_bank_conflict_unit.vcd"

# leaf name -> friendly label (first occurrence = tb scope)
WANT = {
    "clk": "clk",
    "req_valid": "req_valid",
    "lane_active": "lane_active",
    "resp_valid": "resp_valid",
    "n_phases": "n_phases",
    "conflict": "conflict",
    "n_active": "n_active",
    "n_unique": "n_unique",
    "n_bcast": "n_bcast",
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


def main():
    changes, width = parse_vcd(VCD)

    # Sample on each clock rising edge (0 -> 1 transition of clk). Times in the
    # VCD are in ps; deriving edges from clk avoids hard-coding the timescale.
    clk_seq = changes.get("clk", [])
    edges = [t for (t, v) in clk_seq if v == "1"]
    NCYC = 20  # reset + the eight directed requests occupy the first ~20 cycles
    edges = edges[:NCYC]

    labels = ["clk", "req_valid", "lane_active", "resp_valid",
              "n_phases", "conflict", "n_active", "n_unique", "n_bcast"]
    is_bus = {"lane_active": True, "n_phases": True, "n_active": True,
              "n_unique": True, "n_bcast": True,
              "clk": False, "req_valid": False, "resp_valid": False,
              "conflict": False}

    ncol = len(edges)
    row_h = 1.0
    fig_w = max(12, 1.05 * ncol)
    fig_h = 0.85 * len(labels) + 2.2
    fig, ax = plt.subplots(figsize=(fig_w, fig_h))

    C_HI = "#2e7d32"
    C_LO = "#9aa4ad"
    C_BUS = "#e8eef5"
    C_BUSE = "#3f6fb0"
    C_TXT = "#10233b"

    for r, lab in enumerate(labels):
        y = (len(labels) - 1 - r) * (row_h + 0.35)
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
                iv = to_int(raw)
                if lab == "lane_active":
                    w = width.get(lab, 8)
                    txt = format(iv, "0{}b".format(w)) if iv is not None else "x"
                else:
                    txt = str(iv) if iv is not None else "x"
                nonzero = (iv not in (None, 0))
                fc = C_BUS
                ec = C_BUSE if nonzero else "#c2cbd4"
                ax.add_patch(Rectangle((x + 0.03, y + 0.12), 0.94, row_h - 0.24,
                                       facecolor=fc, edgecolor=ec, lw=1.2))
                ax.text(x + 0.5, y + row_h / 2, txt, ha="center", va="center",
                        fontsize=8.5, family="monospace",
                        color=C_TXT if nonzero else "#7a848d")

    ytop = len(labels) * (row_h + 0.35)
    for c in range(ncol + 1):
        ax.axvline(c, color="#dde3ea", lw=0.6, zorder=0)
    for c in range(ncol):
        ax.text(c + 0.5, ytop + 0.05, "c{}".format(c), ha="center", va="bottom",
                fontsize=8, color="#5a6673")

    # annotate the directed scenarios. Sampling is post-edge, so each request's
    # lane_active and its registered response land in the same column.
    notes = [
        (2, "reset"),
        (5, "cfree stride1\n8 banks -> 1 phase"),
        (7, "N-way conflict\n-> 8 phases"),
        (9, "broadcast all\n-> 1 phase"),
        (11, "even mask\n4 lanes -> 1 phase"),
        (13, "2-way conflict\n-> 2 phases"),
        (15, "mixed bcast+conf\n-> 5 phases"),
        (17, "empty warp\n-> 0 phases"),
        (19, "single lane\n-> 1 phase"),
    ]
    for cyc, txt in notes:
        if cyc < ncol:
            ax.text(cyc + 0.5, -1.55, txt, ha="center", va="top", fontsize=7.4,
                    color="#3a4a5e",
                    bbox=dict(boxstyle="round,pad=0.25", fc="#f2f6fb",
                              ec="#c2cbd4", lw=0.7))

    ax.set_xlim(-3.2, ncol + 0.2)
    ax.set_ylim(-2.9, ytop + 0.7)
    ax.axis("off")
    ax.set_title(
        "Day16 - GPU Shared-Memory Bank-Conflict Unit: captured simulation "
        "timing (Icarus Verilog VCD)\n"
        "warp request (lane_active) and its registered response "
        "(n_phases = serialization factor, conflict, n_active/n_unique/n_bcast), "
        "sampled at each clock edge",
        fontsize=11, color=C_TXT, pad=14)

    fig.tight_layout()
    fig.savefig("docs/smem_bank_conflict_unit_waveform.png", dpi=140,
                bbox_inches="tight", facecolor="white")
    print("wrote docs/smem_bank_conflict_unit_waveform.png")


if __name__ == "__main__":
    main()
