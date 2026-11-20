#!/usr/bin/env python3
"""extract_metrics.py runs/<tag> - summarize an OpenLane2 run: per-corner
setup WNS/TNS and the implied Fmax, hold WNS, area, utilization, cell count,
DRC/LVS/antenna, and write runs/<tag>/summary.md."""
import json, os, sys, glob

run = sys.argv[1]
m = json.load(open(os.path.join(run, "final", "metrics.json")))
cfg = json.load(open(glob.glob(os.path.join(run, "resolved.json"))[0])) if glob.glob(os.path.join(run, "resolved.json")) else {}
T = float(cfg.get("CLOCK_PERIOD", 0) or 0)

def g(k, d="n/a"):
    return m.get(k, d)

corners = sorted({k.split("corner:")[1] for k in m if "timing__setup__ws__corner:" in k})
lines = [f"# OpenLane2 run `{os.path.basename(run)}`  (CLOCK_PERIOD = {T} ns)", "",
         "| corner | setup WNS (ns) | setup TNS (ns) | Fmax = 1/(T - WNS) | hold WNS (ns) |",
         "|---|---|---|---|---|"]
for c in corners:
    ws = g(f"timing__setup__ws__corner:{c}")
    tns = g(f"timing__setup__tns__corner:{c}")
    hws = g(f"timing__hold__ws__corner:{c}")
    fmax = f"{1000.0 / (T - ws):.1f} MHz" if isinstance(ws, (int, float)) and T else "n/a"
    lines.append(f"| {c} | {ws:.3f} | {tns:.3f} | {fmax} | {hws:.3f} |")
keys = [("die area (um^2)", "design__die__area"), ("core area (um^2)", "design__core__area"),
        ("std-cell area (um^2)", "design__instance__area__stdcell"),
        ("utilization", "design__instance__utilization"),
        ("std cells (excl. fill/tap)", "design__instance__count__stdcell"),
        ("all instances", "design__instance__count"),
        ("flip-flops (sequential cells)", "design__instance__count__class:sequential_cell"),
        ("Magic DRC errors", "magic__drc_error__count"), ("KLayout DRC errors", "klayout__drc_error__count"),
        ("LVS errors", "design__lvs_error__count"), ("antenna violating nets", "antenna__violating__nets"),
        ("antenna violating pins", "antenna__violating__pins"),
        ("max slew violations", "design__max_slew_violation__count"),
        ("max cap violations", "design__max_cap_violation__count"),
        ("power total (W, nom tt)", "power__total"), ("wire length (um)", "route__wirelength")]
lines += ["", "| metric | value |", "|---|---|"]
for name, k in keys:
    lines.append(f"| {name} | {g(k)} |")
out = "\n".join(lines) + "\n"
open(os.path.join(run, "summary.md"), "w").write(out)
print(out)
