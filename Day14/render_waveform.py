#!/usr/bin/env python3
"""Render docs/simt_reconvergence_stack_waveform.png from the captured
simt_reconvergence_stack.vcd.

Parses the VCD produced by the Icarus run, reconstructs each probed signal, and
draws a cycle-accurate timing diagram of the directed divergence scenario: seed
the full warp, a uniform branch (no split), a DIVERGENT branch that pushes the
two paths, the taken path running to its reconvergence PC and popping, a NESTED
divergence on the sibling path, and finally the drain back to a single fully
reconverged group. This is a REAL captured trace, not a hand-drawn diagram.

The testbench separates each active op with a NOP hold cycle, so we sample only
the cycles where a real operation is issued (the first N non-NOP ops, which are
exactly the directed sequence that runs before the randomized stream).
"""
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import Rectangle

VCD = "simt_reconvergence_stack.vcd"
NCOL = 12                      # directed ops to show

# leaf name -> friendly label (first occurrence = tb scope)
WANT = {
    "op": "op", "active_mask": "active_mask", "active_pc": "active_pc",
    "tos_rpc": "tos_rpc", "sp": "sp", "diverged": "diverged",
    "at_reconv": "at_reconv", "empty": "empty", "full": "full", "err": "err",
}
OP_NAME = {0: "NOP", 1: "PUSH", 2: "SETPC", 3: "DIVERGE", 4: "POP"}


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


def bits_to_uint(v):
    if v is None or any(c in "xzXZ" for c in v):
        return None
    return int(v, 2)


def main():
    changes, width = parse_vcd(VCD)

    # All op-value change events; find rising edges where op != NOP.
    op_seq = sorted(changes["op"])
    # Sample points: each time op transitions to a non-NOP value, sample a
    # little after so the resulting registered state is visible.
    sample_ts, sample_ops = [], []
    for (t, v) in op_seq:
        iv = bits_to_uint(v)
        if iv not in (None, 0):
            sample_ts.append(t + 6000)   # ~0.5 cycle after the capturing edge
            sample_ops.append(iv)
        if len(sample_ts) >= NCOL:
            break

    rows = ["clk", "op", "active_mask", "active_pc", "tos_rpc", "sp",
            "diverged", "at_reconv", "empty", "full", "err"]
    digital = {"diverged", "at_reconv", "empty", "full", "err"}
    ncol = len(sample_ts)

    fig, ax = plt.subplots(figsize=(15.8, 8.6))
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

        if name in digital:
            seq = sorted(changes.get(name, []))
            prev = None
            for k, tq in enumerate(sample_ts):
                v = val_at(seq, tq)
                lvl = 1 if v == "1" else 0
                yy = y + (2.0 if lvl else 0.0)
                ax.plot([k, k + 1], [yy, yy],
                        color="#2ca02c" if lvl else "#bbb", lw=2.0)
                if prev is not None and prev != lvl:
                    ax.plot([k, k], [y, y + 2.0], color="#2ca02c", lw=1.3)
                prev = lvl
            continue

        # value rows (op / mask / pc / rpc / sp)
        if name == "op":
            seq = op_seq
        else:
            seq = sorted(changes.get(name, []))
        for k, tq in enumerate(sample_ts):
            v = val_at(seq, tq)
            iv = bits_to_uint(v)
            if name == "op":
                txt = OP_NAME.get(sample_ops[k], "?")
                col = "#e9dcf7" if sample_ops[k] == 3 else "#eef3fb"
            elif name == "active_mask":
                txt = "x" if iv is None else format(iv, "08b")
                col = "#eaf6ea"
            elif name == "sp":
                txt = "x" if iv is None else str(iv)
                col = "#fdf3e2"
            elif name == "tos_rpc":
                txt = "x" if iv is None else ("NONE" if iv == 0xFFFF
                                              else f"{iv:04X}")
                col = "#f2f2f2"
            else:  # active_pc
                txt = "x" if iv is None else f"{iv:04X}"
                col = "#f2f2f2"
            # highlight a value that just changed vs previous column
            prevv = bits_to_uint(val_at(seq, sample_ts[k - 1])) if k else None
            changed = (k == 0) or (iv != prevv) or \
                      (name == "op")
            ax.add_patch(Rectangle((k, y), 1.0, 2.0, facecolor=col,
                         edgecolor="#c9c9c9", lw=0.7))
            ax.text(k + 0.5, y + 1.0, txt, ha="center", va="center",
                    fontsize=8.5 if name != "active_mask" else 8,
                    fontfamily="monospace",
                    fontweight="bold" if changed else "normal",
                    color="#6a1b9a" if (name == "op" and sample_ops[k] == 3)
                    else "#111")

    for k in range(ncol + 1):
        ax.axvline(k, color="#ececec", lw=0.6, zorder=0)

    ax.set_yticks(yticks)
    ax.set_yticklabels(ylabels, fontsize=10.5, fontfamily="monospace")
    ax.set_xticks([k + 0.5 for k in range(ncol)])
    ax.set_xticklabels([f"c{k}" for k in range(ncol)], fontsize=8, color="#777")
    ax.set_xlim(-0.05, ncol + 0.05)
    ax.set_ylim(-1.0, n * 3.0 + 0.6)
    for sp in ("top", "right", "bottom", "left"):
        ax.spines[sp].set_visible(False)
    ax.set_title(
        "Day 14 - SIMT reconvergence (PDOM) stack, directed divergence scenario "
        "(real Icarus VCD capture)\n"
        "seed warp FF -> uniform branch -> DIVERGE (mask FF splits to taken 0F, "
        "sp 1->3) -> taken runs to rpc & pops -> nested DIVERGE on sibling F0 -> "
        "drain back to a single reconverged group",
        fontsize=10.5, pad=14)
    fig.tight_layout()
    fig.savefig("docs/simt_reconvergence_stack_waveform.png", dpi=130,
                bbox_inches="tight", facecolor="white")
    print("wrote docs/simt_reconvergence_stack_waveform.png")


if __name__ == "__main__":
    main()
