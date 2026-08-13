#!/usr/bin/env python3
"""Render docs/systolic_array_waveform.png from the captured systolic_array.vcd.

Parses the VCD produced by the Icarus run, reconstructs each probed signal over
time, and draws a cycle-accurate digital timing diagram of one multiply pass
(the dense "seq x seq" directed case: reset already released, start latches the
operands, t streams 0..11 pulling in skewed edge operands, the interior PE
accumulator acc[0][0] fills its dot product 1..90, then done pulses with C
valid). This is a REAL captured trace, not hand-drawn.
"""
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import Rectangle

VCD = "systolic_array.vcd"
PERIOD = 10000          # ps per clock (timescale 1ns, half-period #5)
PASS_INDEX = 3          # 0:I*seq 1:seq*I 2:0*seq 3:seq*seq (dense)

# hierarchical leaf name -> friendly label
WANT = {
    "rst_n": "rst_n", "start": "start", "busy": "busy", "done": "done",
    "t": "t", "p_west0": "west_in[0]", "p_north0": "north_in[0]",
    "p_areg00": "a_reg[0][0]", "p_breg00": "b_reg[0][0]",
    "p_acc00": "acc[0][0]", "p_c00": "C[0][0]",
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
            if name in WANT and WANT[name] not in id_of:   # first occurrence
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
            if p[1] in id2lab:
                changes[id2lab[p[1]]].append((t, p[0][1:]))
    return changes, width


def val_at(seq, tq):
    cur = None
    for (tc, v) in seq:
        if tc <= tq:
            cur = v
        else:
            break
    return cur


def to_int(bits, w):
    if bits is None or any(c in "xzXZ" for c in bits):
        return None
    v = int(bits, 2)
    return v - (1 << w) if v >= (1 << (w - 1)) else v


def main():
    changes, width = parse_vcd(VCD)

    starts = [t for (t, v) in sorted(changes["start"]) if v == "1"]
    t_start = starts[PASS_INDEX]
    # sample just after each rising edge, from one cycle before start onward
    t0 = t_start - PERIOD
    times = [t0 + k * PERIOD + 1000 for k in range(16)]

    rows = ["clk", "start", "busy", "t", "west_in[0]", "north_in[0]",
            "a_reg[0][0]", "b_reg[0][0]", "acc[0][0]", "done", "C[0][0]"]
    digital = {"start", "busy", "done"}
    ncol = len(times)

    fig, ax = plt.subplots(figsize=(15.5, 8.4))
    n = len(rows)
    yticks, ylabels = [], []

    for r, name in enumerate(rows):
        y = (n - 1 - r) * 3.0
        yticks.append(y + 1.0)
        ylabels.append(name)

        if name == "clk":
            for k in range(ncol):
                ax.plot([k, k + 0.5, k + 0.5, k + 1.0],
                        [y, y, y + 2.0, y + 2.0], color="#1f77b4", lw=1.4)
            continue

        seq = sorted(changes.get(name, []))
        raw = [val_at(seq, tq) for tq in times]

        if name in digital:
            prev = None
            for k, v in enumerate(raw):
                lvl = 1 if v == "1" else 0
                yy = y + (2.0 if lvl else 0.0)
                ax.plot([k, k + 1], [yy, yy],
                        color="#2ca02c" if lvl else "#999", lw=2.0)
                if prev is not None and prev != lvl:
                    ax.plot([k, k], [y, y + 2.0], color="#2ca02c", lw=1.3)
                prev = lvl
        else:
            w = width.get(name, 32)
            busy_seq = sorted(changes["busy"])
            for k, v in enumerate(raw):
                unsigned = (name == "t")
                if v in ("0", "1"):
                    iv = int(v, 2)
                elif unsigned:
                    iv = None if (v is None or any(c in "xz" for c in v)) \
                        else int(v, 2)
                else:
                    iv = to_int(v, w)
                # the counter is meaningful only while the array streams
                if name == "t" and val_at(busy_seq, times[k]) != "1":
                    txt = ""
                else:
                    txt = "x" if iv is None else str(iv)
                changed = (k == 0) or (raw[k] != raw[k - 1])
                if name.startswith(("acc", "C")):
                    col = "#dfeafc" if iv not in (None, 0) else "#f0f4fb"
                elif name == "t":
                    col = "#f6efe0"
                else:
                    col = "#f4f4f4"
                ax.add_patch(Rectangle((k, y), 1.0, 2.0, facecolor=col,
                             edgecolor="#c9c9c9", lw=0.7))
                ax.text(k + 0.5, y + 1.0, txt, ha="center", va="center",
                        fontsize=9,
                        fontweight="bold" if changed else "normal",
                        color="#c0392b" if (changed and name.startswith("acc"))
                        else "#111")

    # cycle-t header (sampled value of t each column)
    tseq = sorted(changes.get("t", []))
    for k in range(ncol + 1):
        ax.axvline(k, color="#ececec", lw=0.6, zorder=0)
    for k in range(ncol):
        tv = val_at(tseq, times[k])
        lbl = "" if (tv is None or any(c in "xz" for c in tv)) else str(int(tv, 2))
        # only label while busy stream is active
        busy_v = val_at(sorted(changes["busy"]), times[k])
        ax.text(k + 0.5, n * 3.0 - 0.3, lbl if busy_v == "1" else "",
                ha="center", va="bottom", fontsize=8, color="#777")
    ax.text(-0.12, n * 3.0 - 0.3, "stream t:", ha="right", va="bottom",
            fontsize=8, color="#777")

    ax.set_yticks(yticks)
    ax.set_yticklabels(ylabels, fontsize=10.5, fontfamily="monospace")
    ax.set_xticks([])
    ax.set_xlim(-0.05, ncol + 0.05)
    ax.set_ylim(-1.0, n * 3.0 + 1.2)
    for sp in ("top", "right", "bottom", "left"):
        ax.spines[sp].set_visible(False)
    ax.set_title(
        "Day 13 - 4x4 output-stationary systolic array, dense pass A=B=[1..16] "
        "(real Icarus VCD capture)\n"
        "start latches A,B; stream t=0..11 feeds skewed edge operands; "
        "acc[0][0] accumulates 1->11->38->90; done pulses with C[0][0]=90 valid",
        fontsize=11, pad=14)
    fig.tight_layout()
    fig.savefig("docs/systolic_array_waveform.png", dpi=130,
                bbox_inches="tight", facecolor="white")
    print("wrote docs/systolic_array_waveform.png")


if __name__ == "__main__":
    main()
