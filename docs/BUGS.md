# Bug log

This log records only defects that actually happened. Each entry says what
found it.

## 1. Pipeline hazard bugs found by the Spike / random flow

**None so far.** No riscv-tests run, Spike commit-log comparison or random
program has found a mismatch in the core RTL. That covers the 54 riscv-tests
with and without back-pressure and more than 10 M random instructions with
and without back-pressure (see the README results table).

The one non-obvious hazard in this design, losing a WB-to-EX forward while
the pipe is frozen by data-memory back-pressure, was handled in the original
RTL (the ID/EX operand registers capture the forwarded values while stalled;
see DESIGN.md section 3). It was never observed as a failure, so it is not
listed as a found bug.

To show the flow *would* catch hazard bugs, section 3 lists deliberately
injected mutants. Those are not bugs that were found.

## 2. Other real defects found and fixed during bring-up

| # | Area | Symptom | Root cause | Fix | Found by |
|---|---|---|---|---|---|
| 1 | RTL portability | Yosys: `syntax error, unexpected TOK_IMPORT` at `rv32i_decode.sv:5` | The Yosys native SV front end (used by OpenLane2) accepts neither `module m import pkg::*; (...)` nor an `import` inside the module body | Replaced the package with `rv32i_defs.svh` (plain `localparam`s) `` `include``d in each module body | `yosys read_verilog -sv` before PD |
| 2 | SoC test software | UART output garbled after the 19th character; loopback check reported 4 errors | The test enabled UART `LOOPBACK` (which forces the `txd` pin high and routes TX into RX) while the TX FIFO still held the end of the greeting, so those bytes went into the RX FIFO | Drain TX (`TX_EMPTY && !TX_BUSY`) and flush RX (`CTRL.RX_CLR`) before entering loopback | `make test-soc`, then an APB/UART-pop monitor (`+define+APB_MON`) proved the bus and UART were correct |
| 3 | Testbench | Spike never terminated on random programs (5.9 M lines of `j .` in the log) | The program defined only a `tohost` word in `.data`. I did not isolate which of the two differences from riscv-tests mattered | Define both `tohost` and `fromhost` (64-bit, 64-byte aligned) in a `.tohost` section as riscv-tests does. The runner also puts a timeout on Spike | first `run_random.py` attempt |
| 4 | Testbench | Spike-vs-RTL diffs on every riscv-test were length mismatches | Spike keeps spinning in `write_tohost` after the test ends; the RTL bench stopped at the first `tohost` store, and the trace sometimes missed that store | The bench drains 4 cycles after `tohost`; `cmp_commit.py` cuts both logs at the first store to the ELF's own `tohost` address | `run_isa.py --spike` |
| 5 | Test plan | Four rv32mi tests were listed as excluded with guessed reasons | `csr`, `illegal`, `instret_overflow` and `zicntr` detect missing features and pass on an M-only core | Ran every excluded test and read its source; only `breakpoint` (needs Sdtrig `tselect`) and `pmpaddr` (needs PMP) stay excluded in rv32mi | rerun of excluded tests |
| 6 | Testbench | The SoC bench printed a long integer instead of `RESULT: FAIL` | `$display(cond ? "A" : "B")` with string literals evaluates to a number in Verilator | `if/else` around two `$display`s | visual check of `make test-soc` output |

## 3. Injected mutants (verification-flow sanity check, not real bugs)

`make mutation` copies the RTL, applies one classic hazard bug, rebuilds and
reruns the random/Spike flow on 6 programs (seeds 900-905). Only seeds
divisible by 3 (900 and 903) run with data-memory back-pressure.

| Mutant | Description | Detected |
|---|---|---|
| `no_operand_capture_on_mem_stall` | ID/EX does not latch forwarded operands while frozen | 2/6 programs: both back-pressure programs, 0 of the 4 without (the bug cannot occur without stalls) |
| `load_use_ignores_rs2` | interlock only checks rs1 | 6/6 |
| `fwd_priority_wb_over_mem` | WB forward takes priority over the younger MEM result | 6/6 |
| `no_id_flush_on_redirect` | taken branch does not kill the instruction in ID | 6/6 |
| `regfile_no_write_bypass` | register file returns the old value when read and written in the same cycle | 6/6 |
| `no_fetch_squash_after_id_predict` | ID-predicted jump does not squash the `pc+4` fetch behind it | 6/6 |
| `mispredict_ignores_prediction` | EX redirects on "branch taken" instead of "outcome != prediction" | 6/6 |
| `mispredict_redirects_to_target` | a predicted-taken branch that is not taken is "corrected" to its target | 6/6 |

Raw output: `build/mutation/summary.txt`.
