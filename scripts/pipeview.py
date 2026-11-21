#!/usr/bin/env python3
"""pipeview.py - draw an IF/ID/EX/MEM/WB occupancy chart from a tb_core
+pipetrace=<file> log (one line per cycle, see tb/tb_core.sv).

usage: pipeview.py --pipe <trace> --elf <elf> --out <png|svg> [--max-pc HEX]

docs/media/pipeline.png was made with:
  riscv64-elf-gcc -march=rv32i_zicsr -mabi=ilp32 -static -nostdlib -nostartfiles \
    -Tsw/common/link.ld sw/pipe_demo/pipe_demo.S -o build/pipe/pipe_demo.elf
  python3 scripts/elf2hex.py build/pipe/pipe_demo.elf build/pipe/pipe_demo.hex   # prints tohost
  build/sim/Vtb_core +hex=build/pipe/pipe_demo.hex +tohost=80000040 \
    +pipetrace=build/pipe/pipe_demo.pipe
  python3 scripts/pipeview.py --pipe build/pipe/pipe_demo.pipe \
    --elf build/pipe/pipe_demo.elf --out docs/media/pipeline.png --max-pc 80000024

Instances are followed through the pipeline with the same rules the RTL uses:
stall_mem freezes IF..MEM, load_use holds IF/ID and bubbles EX, an ID
predecode (id_pred) squashes the pc+4 fetch, and an EX redirect kills ID and
the fetch in flight. Each step is checked against the PCs in the trace.
Needs matplotlib.
"""
import argparse, os, re, subprocess, sys

STAGES = ["IF", "ID", "EX", "MEM", "WB"]
COLORS = {"IF": "#2a78d6", "ID": "#eb6834", "EX": "#1baf7a", "MEM": "#eda100", "WB": "#6250d6"}
INK, INK2, MUTED, GRID, SURF = "#0b0b0b", "#52514e", "#9a9893", "#e4e3df", "#fcfcfb"


def load_trace(path):
    rows = []
    for line in open(path):
        f = line.split()
        if len(f) != 17:
            continue
        rows.append(dict(
            pc_f=int(f[1], 16), imem_en=int(f[2]),
            id_v=int(f[3]), id_pc=int(f[4], 16), ex_v=int(f[5]), ex_pc=int(f[6], 16),
            mem_v=int(f[7]), mem_pc=int(f[8], 16), wb_v=int(f[9]), wb_pc=int(f[10], 16),
            fwd_a=int(f[11]), fwd_b=int(f[12]), load_use=int(f[13]), redirect=int(f[14]),
            id_pred=int(f[15]), stall_mem=int(f[16])))
    return rows


def disasm(elf):
    prefix = os.environ.get("RISCV_PREFIX", "riscv64-elf-")
    out = subprocess.check_output([prefix + "objdump", "-d", "-M", "numeric,no-aliases", elf], text=True)
    d = {}
    for line in out.splitlines():
        m = re.match(r"\s*([0-9a-f]+):\s+([0-9a-f]{8})\s+(\S+)\s*([^#<]*)", line)
        if m:
            d[int(m.group(1), 16)] = (int(m.group(2), 16), (m.group(3) + " " + m.group(4).strip()).strip())
    return d


def track(rows):
    """Return instances [{pc, cells:{cycle: stage or 'stall'}, fate}] and per-cycle stage->instance."""
    insts, occ = [], []
    prev = None
    for c, r in enumerate(rows):
        cur = {}
        def new(pc):
            insts.append(dict(pc=pc, cells={}, fate=None, born=c))
            return len(insts) - 1
        if prev is None:
            cur["IF"] = new(r["pc_f"])
        else:
            p, pr = prev, rows[c - 1]
            frozen = pr["stall_mem"]
            hold_id = (pr["load_use"] or frozen) and not pr["redirect"]
            # IF
            cur["IF"] = p["IF"] if hold_id else new(r["pc_f"])
            # ID
            if r["id_v"]:
                cur["ID"] = p.get("ID") if hold_id else p["IF"]
            # EX
            if r["ex_v"]:
                cur["EX"] = p.get("EX") if frozen else p.get("ID")
            if r["mem_v"]:
                cur["MEM"] = p.get("MEM") if frozen else p.get("EX")
            if r["wb_v"]:
                cur["WB"] = p.get("WB") if frozen else p.get("MEM")
            # fates of instances that left the pipe without moving on
            live = set(v for v in cur.values() if v is not None)
            for st in STAGES[:-1]:
                i = p.get(st)
                if i is not None and i not in live and insts[i]["fate"] is None:
                    if pr["redirect"]:
                        insts[i]["fate"] = "flushed by EX redirect"
                    elif st == "IF" and pr["id_pred"]:
                        insts[i]["fate"] = "squashed by ID predecode"
                    else:
                        insts[i]["fate"] = "dropped"
        pcs = {"IF": r["pc_f"], "ID": r["id_pc"], "EX": r["ex_pc"], "MEM": r["mem_pc"], "WB": r["wb_pc"]}
        for st, i in cur.items():
            if i is None:
                sys.exit(f"pipeview: cycle {c}: {st} valid but no instance to fill it")
            if insts[i]["pc"] != pcs[st]:
                sys.exit(f"pipeview: cycle {c}: {st} pc {pcs[st]:08x} != tracked {insts[i]['pc']:08x}")
            held = prev is not None and prev.get(st) == i
            insts[i]["cells"][c] = (st, held)
        occ.append(cur)
        prev = cur
    return insts, occ


def regs_used(text):
    """rs1/rs2 actually read by an instruction, from no-alias numeric disassembly."""
    op, _, args = text.partition(" ")
    a = [x.strip() for x in re.split(r"[,()]", args) if x.strip()]
    xs = [x for x in a if re.fullmatch(r"x\d+", x)]
    if op in ("lui", "auipc", "jal") or not xs:
        return []
    if op in ("sw", "sh", "sb"):          # "sw rs2,imm(rs1)" -> [rs1, rs2]
        return [xs[1], xs[0]]
    if op.startswith("b"):
        return xs[:2]
    if op.startswith("l") or op == "jalr" or op.endswith("i") or op.startswith("csr"):
        return xs[1:2]
    return xs[1:3]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--pipe", required=True)
    ap.add_argument("--elf", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--max-pc", type=lambda s: int(s, 16), default=None,
                    help="hide instances above this PC (e.g. the final spin loop)")
    args = ap.parse_args()

    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    from matplotlib.patches import FancyBboxPatch

    rows = load_trace(args.pipe)
    dis = disasm(args.elf)
    insts, occ = track(rows)
    # stop once the last shown instruction has retired
    shown = [i for i, n in enumerate(insts) if args.max_pc is None or n["pc"] <= args.max_pc]
    ncyc = max(max(insts[i]["cells"]) for i in shown) + 1
    shown = [i for i in shown if insts[i]["born"] < ncyc]
    yof = {i: k for k, i in enumerate(shown)}
    notes = {}

    def label(i):
        n = insts[i]
        return f"{n['pc'] & 0xffff:04x}  {dis.get(n['pc'], (0, '?'))[1]}"

    W, H = 0.92, 0.72
    fig_w = 3.6 + 0.52 * ncyc
    fig_h = 1.8 + 0.42 * len(shown)
    fig, ax = plt.subplots(figsize=(fig_w, fig_h), dpi=150)
    fig.patch.set_facecolor(SURF)
    ax.set_facecolor(SURF)
    plt.rcParams["font.family"] = "DejaVu Sans"

    for c in range(ncyc + 1):
        ax.axvline(c - 0.5, color=GRID, lw=0.6, zorder=0)

    for i in shown:
        n = insts[i]
        y = yof[i]
        squashed = n["fate"] is not None
        for c, (st, held) in n["cells"].items():
            if c >= ncyc:
                continue
            col = COLORS[st]
            if squashed:
                fc, ec, tc, hatch = "#eeedea", MUTED, MUTED, None
            elif held:
                fc, ec, tc, hatch = SURF, col, col, "////"
            else:
                fc, ec, tc, hatch = col, SURF, "white", None
            ax.add_patch(FancyBboxPatch((c - W / 2, y - H / 2), W, H,
                                        boxstyle="round,pad=0,rounding_size=0.12",
                                        fc=fc, ec=ec, lw=1.2, hatch=hatch, zorder=2))
            ax.text(c, y, st, ha="center", va="center", fontsize=8.5,
                    color=tc if not held else INK2, weight="bold", zorder=3)
        if squashed:
            notes.setdefault(i, []).append(n["fate"])

    # load-use bubbles, forwarding arrows, ID predictions, EX redirects
    for c, r in enumerate(rows[:ncyc]):
        if c and rows[c - 1]["load_use"] and not rows[c - 1]["stall_mem"] and not r["ex_v"]:
            stalled = occ[c].get("ID")
            if stalled in yof:
                ax.text(c, yof[stalled] + 0.5, "bubble", ha="center", va="center", fontsize=7,
                        color=INK2, zorder=4,
                        bbox=dict(boxstyle="round,pad=0.15", fc=SURF, ec=COLORS["EX"], lw=0.8, ls="--"))
                notes.setdefault(stalled, []).append("load-use: 1 stall cycle, bubble into EX")
        idi = occ[c].get("ID")
        if r["id_pred"] and not r["load_use"] and not r["stall_mem"] and not r["redirect"] and idi in yof:
            notes.setdefault(idi, []).append("backward branch, predicted taken in ID")
        ex = occ[c].get("EX")
        if not r["ex_v"] or r["stall_mem"] or ex not in yof:
            continue
        if r["redirect"]:
            notes.setdefault(ex, []).append("falls through: EX corrects the prediction")
        used = regs_used(dis.get(insts[ex]["pc"], (0, ""))[1])
        for sel, k in ((r["fwd_a"], 0), (r["fwd_b"], 1)):
            if not sel or len(used) <= k:
                continue
            st = "MEM" if sel == 1 else "WB"
            prod = occ[c].get(st)
            if prod not in yof:
                continue
            y0, y1 = yof[prod], yof[ex]
            ax.annotate("", xy=(c - W / 2 + 0.06, y1 - 0.2), xytext=(c - W / 2 + 0.06, y0 + 0.2),
                        arrowprops=dict(arrowstyle="-|>", color=INK, lw=1.4,
                                        connectionstyle="arc3,rad=0.45", shrinkA=0, shrinkB=0),
                        zorder=5)
            what = " (load data)" if st == "WB" and dis.get(insts[prod]["pc"], (0, "l"))[1][0] == "l" else ""
            notes.setdefault(ex, []).append(f"{used[k]} forwarded {st}\u2192EX{what}")

    for i, ts in notes.items():
        muted = insts[i]["fate"] is not None
        ax.text(min(max(insts[i]["cells"]), ncyc - 1) + 0.6, yof[i], ";  ".join(ts), ha="left", va="center", fontsize=8,
                color=MUTED if muted else INK, style="italic" if muted else "normal")

    # legend: held (stall) cell, squashed cell, forwarding arrow
    lx, ly = -0.45, -1.15
    def key(x, fc, ec, hatch, text):
        ax.add_patch(FancyBboxPatch((x, ly - 0.22), 0.55, 0.44, boxstyle="round,pad=0,rounding_size=0.08",
                                    fc=fc, ec=ec, lw=1.0, hatch=hatch, clip_on=False))
        ax.text(x + 0.7, ly, text, ha="left", va="center", fontsize=8, color=INK2)
    key(lx, SURF, INK2, "////", "stage held (stall)")
    key(lx + 4.2, "#eeedea", MUTED, None, "squashed / flushed fetch")
    ax.annotate("", xy=(lx + 10.3, ly), xytext=(lx + 9.6, ly),
                arrowprops=dict(arrowstyle="-|>", color=INK, lw=1.4))
    ax.text(lx + 10.45, ly, "forwarding path", ha="left", va="center", fontsize=8, color=INK2)

    ax.set_yticks(range(len(shown)))
    ax.set_yticklabels([label(i) for i in shown], fontsize=8.5, family="DejaVu Sans Mono")
    for t, i in zip(ax.get_yticklabels(), shown):
        t.set_color(MUTED if insts[i]["fate"] else INK)
    ax.set_xticks(range(ncyc))
    ax.set_xticklabels([str(c) for c in range(ncyc)], fontsize=8, color=INK2)
    ax.set_xlabel("cycle", fontsize=9, color=INK2)
    ax.set_xlim(-0.6, ncyc - 0.4)
    ax.set_ylim(len(shown) - 0.4, -1.6)
    ax.tick_params(length=0)
    for s in ax.spines.values():
        s.set_visible(False)
    fig.tight_layout()
    fig.savefig(args.out, facecolor=SURF, bbox_inches="tight", pad_inches=0.15)
    print("wrote", args.out)


if __name__ == "__main__":
    main()
