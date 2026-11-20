#!/usr/bin/env python3
"""mutation.py - sanity-check the verification flow: inject classic pipeline
hazard and branch-prediction bugs into a copy of the RTL one at a time and confirm the Spike
commit-log comparison catches each. Not part of the design; results go to
build/mutation/summary.txt."""
import os, re, shutil, subprocess, sys
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SPIKE = sys.argv[1]
N = int(sys.argv[2]) if len(sys.argv) > 2 else 6

MUTANTS = {
  "no_operand_capture_on_mem_stall": ("rv32i_core.sv",
      "      ex_rs1_val <= fwd_a;\n      ex_rs2_val <= fwd_b;\n", ""),
  "load_use_ignores_rs2": ("rv32i_hazard.sv",
      "((id_rs1_used & (id_rs1 == ex_rd)) |\n                      (id_rs2_used & (id_rs2 == ex_rd)));",
      "((id_rs1_used & (id_rs1 == ex_rd)));"),
  "fwd_priority_wb_over_mem": ("rv32i_hazard.sv",
      "    if (mem_fw && mem_rd == ex_rs1)     fwd_a = 2'd1;\n    else if (wb_fw && wb_rd == ex_rs1)  fwd_a = 2'd2;",
      "    if (wb_fw && wb_rd == ex_rs1)       fwd_a = 2'd2;\n    else if (mem_fw && mem_rd == ex_rs1) fwd_a = 2'd1;"),
  "no_id_flush_on_redirect": ("rv32i_core.sv",
      "    end else if (redirect) begin\n      id_valid <= 1'b0;\n    end else if (!stall_id) begin",
      "    end else if (!stall_id) begin"),
  "regfile_no_write_bypass": ("rv32i_regfile.sv",
      "    else if (we && wa == ra1)       rd1 = wd;\n", ""),
  # static predecode (ID) and its EX correction
  "no_fetch_squash_after_id_predict": ("rv32i_core.sv",
      "id_valid <= ~id_pred;", "id_valid <= 1'b1;"),
  "mispredict_ignores_prediction": ("rv32i_core.sv",
      "(ex_is_branch & (br_cond ^ ex_pred))", "(ex_is_branch & br_cond)"),
  "mispredict_redirects_to_target": ("rv32i_core.sv",
      "(ex_is_branch & ex_pred) ? pc_plus4 : jump_target", "jump_target"),
}

def main():
    out = os.path.join(ROOT, "build", "mutation"); os.makedirs(out, exist_ok=True)
    lines = []
    for name, (fn, old, new) in MUTANTS.items():
        d = os.path.join(out, name); shutil.rmtree(d, ignore_errors=True)
        shutil.copytree(os.path.join(ROOT, "rtl", "core"), os.path.join(d, "rtl", "core"))
        p = os.path.join(d, "rtl", "core", fn); s = open(p).read()
        assert old in s, name
        open(p, "w").write(s.replace(old, new))
        subprocess.check_call(["verilator", "--binary", "--timing", "-j", "4", "-O3", "-Wno-fatal",
            "-Wno-WIDTHTRUNC", "-Wno-WIDTHEXPAND", "--top-module", "tb_core", "-Mdir",
            os.path.join(d, "obj"), "-o", "../Vtb_core"] +
            [("+incdir+" + os.path.join(d, l.strip()[8:])) if l.startswith("+incdir+") else
             os.path.join(d, l.strip()) for l in open(os.path.join(ROOT, "rtl/core/core.f"))] +
            [os.path.join(ROOT, "tb/rv_tracer.sv"), os.path.join(ROOT, "tb/tb_core.sv")],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        r = subprocess.run([sys.executable, os.path.join(ROOT, "scripts/run_random.py"),
                            "--n", str(N), "--seed", "900", "--sim", os.path.join(d, "Vtb_core"),
                            "--spike", SPIKE], capture_output=True, text=True)
        m = re.search(r"failed: (\d+)", r.stdout)
        lines.append(f"{name:36s} detected in {m.group(1) if m else '?'}/{N} random programs")
        print(lines[-1], flush=True)
    open(os.path.join(out, "summary.txt"), "w").write("\n".join(lines) + "\n")

if __name__ == "__main__":
    main()
