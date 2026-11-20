#!/usr/bin/env python3
"""cpi.py --sim Vtb_core --elf dhrystone.elf
Runs Dhrystone on the RTL with ideal 1-cycle memories and reports
  CPI = delta(mcycle) / delta(minstret) over the timed Dhrystone loop,
both read by the program itself via csrr, plus DMIPS/MHz and the stall
breakdown from the testbench hazard counters (whole program).
Also checks Dhrystone's own "should be" self-check values."""
import argparse, os, re, subprocess, sys
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

ap = argparse.ArgumentParser()
ap.add_argument("--sim", required=True)
ap.add_argument("--elf", required=True)
a = ap.parse_args()
hexf = a.elf[:-4] + ".hex"
tohost = subprocess.check_output([sys.executable, os.path.join(ROOT, "scripts/elf2hex.py"),
                                  a.elf, hexf], text=True).strip()
out = subprocess.run([a.sim, f"+hex={hexf}", f"+tohost={tohost}", "+max_cycles=200000000"],
                     capture_output=True, text=True).stdout
m = re.search(r"STATS mcycle=(\d+) minstret=(\d+) runs=(\d+)", out)
if not m or "RESULT: PASS" not in out:
    print(out); sys.exit("cpi: run failed")
cyc, ins, runs = map(int, m.groups())
cov = dict(t.split("=") for t in re.search(r"COV (.*)", out).group(1).split())
cov = {k: int(v) for k, v in cov.items()}
checks = [("Int_Glob:", "5"), ("Bool_Glob:", "1"), ("Ch_1_Glob:", "A"), ("Ch_2_Glob:", "B"),
          ("Arr_1_Glob[8]:", "7"), ("Arr_2_Glob[8][7]:", str(runs + 10))]
bad = [k for k, v in checks if not re.search(re.escape(k) + r"\s+" + re.escape(v) + r"\s", out)]
cpi = cyc / ins
dmips_mhz = runs / cyc * 1e6 / 1757
rep = [f"Dhrystone 2.2, {runs} runs, gcc -O2 -march=rv32i_zicsr (libgcc soft mul/div), ideal 1-cycle memories",
       f"timed loop: mcycle={cyc} minstret={ins}  CPI={cpi:.3f}  IPC={1/cpi:.3f}",
       f"Dhrystones/s/MHz={runs / cyc * 1e6:.1f}  DMIPS/MHz={dmips_mhz:.3f}  instructions/run={ins / runs:.1f}",
       "whole program (testbench counters): " + " ".join(f"{k}={v}" for k, v in cov.items()),
       f"  -> per retired instr: load-use stalls {cov['load_use'] / cov['retired']:.3f}, "
       f"control-flow bubbles {(2 * cov['mispred'] + cov['id_pred']) / cov['retired']:.3f} cycles "
       f"(EX redirect 2x{cov['mispred']} = {2 * cov['mispred'] / cov['retired']:.3f}, "
       f"ID predecode 1x{cov['id_pred']} = {cov['id_pred'] / cov['retired']:.3f})",
       f"  -> taken branches/jumps {cov['taken']}; redirected in ID {cov['id_pred']}, "
       f"corrected in EX {cov['mispred']} (JALR {cov['jalr']}, "
       f"JAL/branch mispredictions {cov['mispred'] - cov['jalr']} = "
       f"{2 * (cov['mispred'] - cov['jalr']) / cov['retired']:.3f} cycles/instr)",
       "self-check: " + ("all 'should be' values match" if not bad else f"MISMATCH {bad}")]
print("\n".join(rep))
os.makedirs(os.path.join(ROOT, "build"), exist_ok=True)
open(os.path.join(ROOT, "build", "cpi.txt"), "w").write("\n".join(rep) + "\n")
sys.exit(1 if bad else 0)
