#!/usr/bin/env python3
"""run_random.py --n N [--seed S] - generate N random programs, run each on
the RTL (Verilator) and on Spike, and diff the commit logs instruction by
instruction. Every 3rd program also runs with 25% random data-memory
back-pressure (dmem_gnt low) to exercise the pipeline-freeze path.
Traces are deleted after a match; mismatching cases are kept in
build/random/fail_<seed>/. Summary is written to build/random/summary.txt."""
import argparse, os, shutil, subprocess, sys, time
from concurrent.futures import ThreadPoolExecutor

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PFX = os.environ.get("RISCV_PREFIX", "riscv64-elf-")
SPIKE_ARGS = ["--isa=rv32i_zicsr", "--priv=m", "--pmpregions=0",
              "-m0x80000000:0x400000", "--log-commits"]

def one(seed, sim, spike, outdir, body, outer, mix):
    d = os.path.join(outdir, f"s{seed}")
    os.makedirs(d, exist_ok=True)
    S, elf, hexf = (os.path.join(d, x) for x in ("t.S", "t.elf", "t.hex"))
    subprocess.check_call([sys.executable, os.path.join(ROOT, "scripts/gen_random.py"),
                           str(seed), S, "--body", str(body), "--outer", str(outer),
                           "--mix", mix])
    subprocess.check_call([PFX + "gcc", "-march=rv32i_zicsr", "-mabi=ilp32", "-nostdlib",
                           "-nostartfiles", "-static", "-Wl,--no-warn-rwx-segments", "-T", os.path.join(ROOT, "sw/common/link.ld"),
                           S, "-o", elf])
    tohost = subprocess.check_output([sys.executable, os.path.join(ROOT, "scripts/elf2hex.py"),
                                      elf, hexf], text=True).strip()
    stall = 25 if seed % 3 == 0 else 0
    r = subprocess.run([sim, f"+hex={hexf}", f"+tohost={tohost}", "+max_cycles=20000000",
                        f"+stall_pct={stall}", f"+verilator+seed+{seed}",
                        f"+trace={d}/rtl.trace"], capture_output=True, text=True)
    res = next((l for l in r.stdout.splitlines() if l.startswith("RESULT")), "NO RESULT")
    cov = {}
    for l in r.stdout.splitlines():
        if l.startswith("COV "):
            cov = {k: int(v) for k, v in (t.split("=") for t in l.split()[1:])}
    with open(os.path.join(d, "spike.log"), "w") as lf:
        try:
            subprocess.run([spike] + SPIKE_ARGS + [elf], stdout=subprocess.DEVNULL,
                           stderr=lf, timeout=600)
        except subprocess.TimeoutExpired:
            res += " (spike timeout)"
    c = subprocess.run([sys.executable, os.path.join(ROOT, "scripts/cmp_commit.py"),
                        os.path.join(d, "spike.log"), os.path.join(d, "rtl.trace"), tohost],
                       capture_output=True, text=True)
    ok = c.returncode == 0 and "PASS" in res
    n = int(c.stdout.split()[1]) if c.stdout.startswith("MATCH") else 0
    if ok:
        shutil.rmtree(d)
    else:
        shutil.rmtree(os.path.join(outdir, f"fail_{seed}"), ignore_errors=True)
        os.rename(d, os.path.join(outdir, f"fail_{seed}"))
    return seed, ok, n, stall, res, c.stdout.strip(), cov

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--n", type=int, default=10)
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--sim", default=os.path.join(ROOT, "build/sim/Vtb_core"))
    ap.add_argument("--spike", required=True)
    ap.add_argument("--body", type=int, default=1200)
    ap.add_argument("--outer", type=int, default=40)
    ap.add_argument("-j", type=int, default=4)
    ap.add_argument("--mix", choices=["default", "branch"], default="default")
    a = ap.parse_args()
    outdir = os.path.join(ROOT, "build", "random")
    os.makedirs(outdir, exist_ok=True)
    t0 = time.time()
    seeds = range(a.seed, a.seed + a.n)
    tot = 0; fails = []; cov = {}
    with ThreadPoolExecutor(max_workers=min(a.j, 4)) as ex:
        for seed, ok, n, stall, res, msg, c in ex.map(
                lambda s: one(s, a.sim, a.spike, outdir, a.body, a.outer, a.mix), seeds):
            tot += n
            for k, v in c.items():
                cov[k] = cov.get(k, 0) + v
            if not ok:
                fails.append(seed)
                print(f"seed {seed} (stall {stall}%): FAIL {res}\n{msg}", flush=True)
    summ = (f"random programs ({a.mix} mix): {a.n} (seeds {a.seed}..{a.seed + a.n - 1}), "
            f"failed: {len(fails)} {fails if fails else ''}\n"
            f"retired instructions compared against Spike: {tot}\n"
            f"hazard events (RTL coverage): " + " ".join(f"{k}={v}" for k, v in cov.items()) + "\n"
            f"wall time: {time.time() - t0:.0f} s\n")
    print(summ, end="")
    with open(os.path.join(outdir, "summary.txt"), "a") as f:
        f.write(time.strftime("%Y-%m-%d %H:%M ") + summ)
    sys.exit(1 if fails else 0)

if __name__ == "__main__":
    main()
