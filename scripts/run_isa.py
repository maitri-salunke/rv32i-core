#!/usr/bin/env python3
"""run_isa.py - build riscv-tests (rv32ui-p, rv32mi-p) and run them on the
Verilator model. Writes build/isa/results.txt and exits non-zero on failure.

usage: run_isa.py --tests <riscv-tests dir> --sim <Vtb_core> [--stall-pct N]
"""
import argparse, glob, os, subprocess, sys
from concurrent.futures import ThreadPoolExecutor

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CC = os.environ.get("RISCV_PREFIX", "riscv64-elf-") + "gcc"

# Tests excluded on purpose, with the reason printed in the report.
EXCLUDE = {
    # Each reason was confirmed by running the test and reading its source.
    "rv32ui/fence_i": "self-modifying code: needs Zifencei + I/D coherence (Harvard memories; FENCE.I traps)",
    "rv32ui/ma_data": "requires hardware misaligned load/store (core raises misaligned exceptions instead)",
    "rv32mi/breakpoint": "assumes Sdtrig trigger CSRs (tselect/tdata1/2) exist; core has none and traps",
    "rv32mi/pmpaddr": "assumes PMP is implemented (test header says so); core has no PMP",
}

def build(src, outdir, tests_dir):
    name = os.path.splitext(os.path.basename(src))[0]
    suite = os.path.basename(os.path.dirname(src))
    elf = os.path.join(outdir, f"{suite}-p-{name}.elf")
    cmd = [CC, "-march=rv32i_zicsr", "-mabi=ilp32", "-static", "-mcmodel=medany",
           "-fvisibility=hidden", "-nostdlib", "-nostartfiles",
           f"-I{tests_dir}/env/p", f"-I{tests_dir}/isa/macros/scalar",
           f"-T{tests_dir}/env/p/link.ld", src, "-o", elf]
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        return None, r.stderr.strip().splitlines()[-1] if r.stderr else "build failed"
    return elf, None

SPIKE_ARGS = ["--isa=rv32i_zicsr_zicntr", "--priv=m", "--pmpregions=0",
              "-m0x80000000:0x400000", "--log-commits"]

def run(elf, sim, stall_pct, spike):
    hexf = elf[:-4] + ".hex"
    tohost = subprocess.check_output([sys.executable, os.path.join(ROOT, "scripts/elf2hex.py"),
                                      elf, hexf], text=True).strip()
    r = subprocess.run([sim, f"+hex={hexf}", f"+tohost={tohost}", "+max_cycles=200000",
                        f"+stall_pct={stall_pct}", f"+trace={elf[:-4]}.trace"],
                       capture_output=True, text=True)
    res = "NO RESULT"
    for line in r.stdout.splitlines():
        if line.startswith("RESULT:"):
            res = line[len("RESULT: "):]
    cmp = ""
    if spike:
        with open(elf[:-4] + ".spike", "w") as lf:
            subprocess.run([spike] + SPIKE_ARGS + [elf], stdout=subprocess.DEVNULL, stderr=lf)
        c = subprocess.run([sys.executable, os.path.join(ROOT, "scripts/cmp_commit.py"),
                            elf[:-4] + ".spike", elf[:-4] + ".trace", tohost],
                           capture_output=True, text=True)
        cmp = "spike:" + (c.stdout.splitlines()[0] if c.stdout else "ERR")
        if c.returncode != 0:
            for l in c.stdout.splitlines()[1:]:
                if l.startswith("  spike") or l.startswith("  rtl"):
                    cmp += " |" + l.split(")", 1)[-1].strip() + "|"
    return res, cmp

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--tests", required=True)
    ap.add_argument("--sim", required=True)
    ap.add_argument("--stall-pct", type=int, default=0)
    ap.add_argument("--spike", default="", help="spike binary: also diff commit logs")
    a = ap.parse_args()
    outdir = os.path.join(ROOT, "build", "isa")
    os.makedirs(outdir, exist_ok=True)
    srcs = []
    for suite in ("rv32ui", "rv32mi"):
        srcs += sorted(glob.glob(os.path.join(a.tests, "isa", suite, "*.S")))

    def job(src):
        key = os.path.basename(os.path.dirname(src)) + "/" + os.path.basename(src)[:-2]
        if key in EXCLUDE:
            return key, "EXCLUDED", EXCLUDE[key]
        elf, err = build(src, outdir, a.tests)
        if elf is None:
            return key, "BUILD-FAIL", err
        res, cmp = run(elf, a.sim, a.stall_pct, a.spike)
        return key, res, cmp

    with ThreadPoolExecutor(max_workers=4) as ex:
        results = list(ex.map(job, srcs))

    lines = []
    summary = {}
    for key, res, note in results:
        suite = key.split("/")[0]
        s = summary.setdefault(suite, [0, 0, 0])
        if res == "EXCLUDED":
            s[2] += 1
        else:
            s[1] += 1
            if res == "PASS":
                s[0] += 1
        lines.append(f"{key:28s} {res:12s} {note}")
    lines.append("")
    for suite, (p, t, x) in summary.items():
        lines.append(f"{suite}-p: {p}/{t} pass ({x} excluded, {p}/{t+x} of all tests in suite)")
    lines.append(f"(dmem stall injection: {a.stall_pct}%)")
    if a.spike:
        nm = sum(1 for r in results if r[2].startswith("spike:MATCH"))
        nt = sum(1 for r in results if r[2].startswith("spike:"))
        ni = sum(int(r[2].split()[1]) for r in results if r[2].startswith("spike:MATCH"))
        lines.append(f"Spike commit-log diff: {nm}/{nt} tests identical ({ni} retired instructions compared)")
    report = "\n".join(lines)
    print(report)
    with open(os.path.join(outdir, f"results_stall{a.stall_pct}.txt"), "w") as f:
        f.write(report + "\n")
    bad = [r for r in results if r[1] not in ("PASS", "EXCLUDED")]
    sys.exit(1 if bad else 0)

if __name__ == "__main__":
    main()
