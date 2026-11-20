# rv32i-core design notes

This document walks through the design one stage at a time, then the hazard
unit, the CSR/trap path, the verification flow and the physical-design flow.
All measured numbers live
in the README results table (and the logs it points to); this file explains
*why* they come out the way they do.

Source map:

| File | Role |
|---|---|
| `rtl/core/rv32i_core.sv` | pipeline registers, IF/EX/MEM/WB datapath, top-level wiring |
| `rtl/core/rv32i_decode.sv` | ID-stage decoder (control signals, immediates, illegal detect) |
| `rtl/core/rv32i_regfile.sv` | 31x32 flop register file, 2R1W, write-first bypass |
| `rtl/core/rv32i_alu.sv` | ALU |
| `rtl/core/rv32i_hazard.sv` | forwarding selects, load-use interlock, stall/flush |
| `rtl/core/rv32i_csr.sv` | machine-mode CSRs, counters, trap entry / `mret` |
| `rtl/core/rv32i_defs.svh` | shared constants (opcodes, ALU ops, CSR addresses) |
| `rtl/soc/*` | SoC wrapper: RAMs, APB bridge, APB timer, APB UART |

---

## 1. Memory interface contract

Both memories behave like synchronous SRAM macros: the address (and enable)
is presented in cycle N, data is available in cycle N+1. This choice shapes the
pipeline:

* The **instruction memory's output register is the IF/ID instruction
  register.** `imem_addr` is driven straight from the `pc_f` flop, so the
  path into the memory macro starts at a flop (good for timing). Holding the
  instruction in ID during a stall means de-asserting `imem_en`, so the macro
  keeps its output.
* The **data memory is accessed in MEM** from the EX/MEM register
  (`dmem_addr`, `dmem_wdata`, `dmem_be` are flop outputs). Read data appears
  in WB, where it is aligned and sign-extended.
* `dmem_gnt` gives the data side back-pressure. When MEM holds an access and
  `gnt` is low, IF..MEM freeze and WB receives a bubble. The SRAM always
  grants; the APB bridge grants only when the APB transfer completes.

## 2. The five stages

### IF
`pc_f` is the only state. Next-PC priority: `redirect` (from EX) >
hold (`stall_id`) > ID prediction (`id_pred_target`) > `pc_f + 4`. There is
no dynamic predictor; the static predecode in ID (below) is the only source
of a non-sequential fetch apart from EX.

### ID
`id_valid`/`id_pc` are registered next to the memory's output word. The
decoder (`rv32i_decode.sv`) is purely combinational and produces: source and
destination register indices plus "is this source really read" bits
(`rs1_used`, `rs2_used`, which keep the load-use check from stalling on
immediate fields), the immediate, ALU op, operand selects, write-back select,
instruction class flags, and `illegal`. An illegal instruction has all side
effects masked in the decoder and raises the exception later, in EX.

The register file is read here. It has a write-first bypass: if WB writes
the register being read in the same cycle, the new value is returned. That
closes the WB-to-ID hazard without a forwarding path.

**Static branch predecode (BTFN).** A few gates next to the decoder look
only at the instruction word and `id_pc`:

* `JAL` is always taken; a conditional branch is predicted taken iff its
  B-immediate is negative (`insn[31]`, i.e. a backward branch, typically a
  loop). Forward branches are predicted not-taken; `JALR` is not predicted.
* The target is `id_pc + imm`, with its own 32-bit adder and its own
  immediate mux (J- or B-immediate, chosen by opcode bit 2), so it does not
  wait for the full decoder.
* When `id_pred` is set and ID is not stalled, `pc_f` loads the target and
  the instruction being fetched (at `pc+4`) is squashed by clearing
  `id_valid`. A predicted-taken jump therefore costs **1 bubble** instead of
  2.
* The prediction travels down as `ex_pred`. EX remains the only place that
  decides correctness (section 3).

What this deliberately does **not** do: it reads no registers and compares
nothing in ID, so there is no new forwarding path into ID and nothing from
the EX/MEM/WB result network feeds the new logic. Its inputs are the
instruction word (the memory output, the same input the decoder and the
load-use check already use), `id_pc` and `id_valid`.

### EX
Everything that decides control flow happens here:

1. **Forwarding muxes** choose each operand from the ID/EX register, the
   EX/MEM result, or the WB value (see section 3).
2. **ALU**, operand A from rs1/PC/zero (AUIPC uses PC, LUI uses zero) and
   operand B from rs2/immediate.
3. **Branch compare** on the forwarded operands (eq, signed lt, unsigned
   lt), with a separate adder for `pc + imm`. JALR's target is the ALU sum
   with bit 0 cleared.
4. **Load/store checks**: misaligned detection and store-data lane
   replication / byte enables, done here so MEM only drives flops.
5. **CSR read and write** (section 4).
6. **Exception and interrupt detection.** A trap, `mret`, any `JALR`, or a
   JAL/branch whose ID prediction was wrong (`ex_mispredict`) raises
   `redirect`, which loads `pc_f` and kills the two younger instructions in
   ID and IF. A correctly predicted JAL or branch raises nothing in EX.

### MEM
Drives the data bus from the EX/MEM register. The address is word-aligned on
the bus; the low two bits travel on to WB for load alignment.

### WB
Selects the result (ALU/PC+4/CSR value carried down the pipe, or aligned load
data), writes the register file and pulses `retire` to the instret counter.

## 3. Hazard unit (`rv32i_hazard.sv`)

### Data hazards: forwarding
Two forwarding sources feed each EX operand, youngest first:

| Priority | Source | Covers |
|---|---|---|
| 1 | EX/MEM `mem_result` | producer is 1 instruction ahead (ALU, LUI/AUIPC, JAL link, CSR read) |
| 2 | WB `wb_value` | producer is 2 ahead, **including load data** |
| (3) | register file write-first bypass | producer is 3 ahead (it is in WB while the consumer is in ID) |

A source is forwarded only from a valid instruction that writes a non-zero
`rd`. The MEM source has priority because it is younger: in `add x1,..;
add x1,..; add x2,x1,..` the second `add` wins.

The forwarded operands feed the ALU, the branch comparator, the store data
and the CSR source. This is why the forwarding mux sits at the head of the
longest paths in the design (see section 6).

### Load-use interlock
A load's data only exists in WB, so a consumer directly behind the load
cannot be served by forwarding. When EX holds a load whose `rd` matches a
source **actually used** by the ID instruction, `load_use` holds IF and ID
for one cycle and injects a bubble into EX. On the next cycle the load is in
MEM and the bubble is in EX; one cycle later the load is in WB and the
consumer in EX takes the value through the WB forwarding path.
**Penalty: 1 cycle**, also for load-to-store-data and load-to-branch.

### Control hazards: predecode in ID, correction in EX
Branches still *resolve* in EX, but fetch no longer always guesses
"sequential". The ID predecode (section 2) redirects fetch for JAL and
backward branches. Penalties:

| Case | Prediction | Outcome | Cost |
|---|---|---|---|
| JAL | taken (ID) | always right | 1 cycle |
| backward branch | taken (ID) | taken | 1 cycle |
| backward branch | taken (ID) | not taken | 2 cycles (EX redirects to `pc+4`) |
| forward branch | not taken | not taken | 0 |
| forward branch | not taken | taken | 2 cycles (EX redirects to target) |
| JALR, trap, `mret` | none | - | 2 cycles |

The EX check is
`ex_mispredict = ex_valid & (jalr | (jal & ~ex_pred) | (branch & (br_cond ^ ex_pred)))`.
For a mispredicted branch the correct PC follows from the *prediction*
alone: predicted taken means the fix is `pc+4`, predicted not-taken means
the fix is the target. So the redirect-PC mux is selected by
`ex_is_branch & ex_pred`, a flop output, and the late compare result
`br_cond` only decides *whether* to redirect, exactly as before. Without that
observation the compare would also have selected the redirect address and
added a mux level after the comparator.

Priority keeps the two redirect sources from fighting: an EX redirect beats
an ID prediction in the same cycle (the ID instruction is squashed anyway),
and a stalled ID (`load_use` or a memory freeze) does not predict until it
can advance, so the instruction that made the prediction is never the one
that gets squashed. `ex_pred` is written into the ID/EX register on the
same enable as the other data fields; whenever the slot becomes valid in EX
the prediction really did redirect fetch, because a valid hand-off implies
ID was neither stalled nor flushed. A predicted target that is 2-byte
misaligned is fetched harmlessly (that fetch is younger than the jump) and
the jump traps in EX as before.

A JALR, trap or `mret` still clears `id_valid` and puts a bubble in ID/EX:
**2 cycles**.

`load_use` is deliberately **not** gated by `redirect`, even though a
misaligned load in EX can trap while its consumer sits in ID. Every consumer
gives `redirect` priority instead: the PC takes the redirect target, `id_valid`
is cleared and `ex_valid` is cleared. The original RTL did gate `load_use` with
`~redirect`, which put branch resolution in front of `imem_en`; removing it
was the timing fix in section 6. The random generator's `trap_then_use`
pattern covers exactly this case.

### Structural / back-pressure: memory stall
When `dmem_req & ~dmem_gnt`, everything from IF to MEM freezes and WB gets a
bubble. One subtle point: during the freeze the instruction in WB retires,
so if the frozen EX instruction was taking an operand from WB, that value
would disappear from the forwarding network. The ID/EX operand registers
therefore **capture the forwarded values on every stalled cycle**
(`ex_rs1_val <= fwd_a`). Mutation testing (section 5.4) shows the random
tests catch the bug if this capture is removed.

## 4. CSR and trap path (`rv32i_csr.sv`)

Implemented CSRs (M-mode only): `mstatus` (MIE, MPIE; MPP hard-wired to M),
`misa` (read-only RV32I), `mie` (MSIE/MTIE/MEIE), `mtvec` (direct mode),
`mscratch`, `mepc`, `mcause`, `mtval`, `mip` (MTIP from the SoC timer),
`mcycle[h]`, `minstret[h]`, the user read-only shadows `cycle[h]`/`instret[h]`,
and `mvendorid/marchid/mimpid/mhartid` (read as 0). Any other address, or a
write to a read-only CSR, raises an illegal-instruction exception.

**Why CSRs execute in EX.** Nothing after EX can fault (memories do not raise
errors), so once an instruction reaches EX, every older instruction is sure to
retire. A CSR read/write in EX is therefore precise, and the next instruction
(in EX one cycle later) already sees the new value. That covers the
`csrw mepc` then `mret` pair.

**instret read semantics.** An instruction in EX should read the number of
instructions retired before it. Up to two older instructions are still in
MEM/WB, so the read returns `minstret + mem_valid + wb_valid`. A write
to `minstret` is pre-compensated in the same way, so after the writing
instruction retires the counter equals the written value, matching the spec
rule that the write takes precedence over the writer's own increment.

**Trap entry** (taken on the EX instruction, `ex_trap`):
* sources: illegal instruction (decoder or CSR unit), ECALL (cause 11),
  EBREAK (3), load/store misaligned (4/6, `mtval` = address),
  instruction-address-misaligned on a taken jump/branch (0, `mtval` = target),
  and the machine timer interrupt (cause 7 with bit 31 set) when
  `mstatus.MIE & mie.MTIE & mip.MTIP`;
* effects: `mepc` = EX PC, `mcause`, `mtval`, `MPIE <= MIE`, `MIE <= 0`,
  PC <= `mtvec`, ID and IF flushed, and the trapping instruction does not go
  on to MEM (so a faulting store never writes memory);
* `mret`: PC <= `mepc`, `MIE <= MPIE`, `MPIE <= 1`.

The interrupted instruction did not execute, so an interrupt handler returns
to `mepc` itself, while an exception handler that wants to skip the faulting
instruction returns to `mepc + 4`.

## 5. Verification flow

### 5.1 Testbench (`tb/tb_core.sv`)
Verilator `--binary --timing`. Harvard 4 MiB memories loaded from the same
image, termination through the riscv-tests `tohost` protocol, a putchar
address at `0x1000_0000`, optional **random `dmem_gnt` back-pressure**
(`+stall_pct=`), hazard coverage counters, and `tb/rv_tracer.sv`, which
prints every retired instruction in exactly the `spike --log-commits`
format (`pc`, instruction word, `rd` write, memory address and store data).

### 5.2 riscv-tests
`scripts/run_isa.py` builds `rv32ui-p-*` and `rv32mi-p-*` with
`-march=rv32i_zicsr`, runs each on the RTL, and also runs Spike on the same
ELF and diffs the commit logs. It runs twice: once with ideal memory and once
with 30% data-memory back-pressure. Exclusions, each confirmed by running the
test and reading its source, are listed in the README.

### 5.3 Random programs vs Spike
`scripts/gen_random.py` writes constrained-random assembly aimed at hazards:
a small hot register set (dense RAW chains), load-then-use,
load-to-store-data, load-to-branch, back-to-back loads into the same `rd`,
store-then-load to the same address, address arithmetic fed by forwarded
values, forward branches, JAL/JALR with `auipc/addi/jalr` dependency chains,
bounded backward loops, CSR read-modify-write, `minstret` reads, and
synchronous traps (ECALL, EBREAK, illegal opcode, unimplemented CSR,
misaligned load/store/jump target) through a handler that reads
`mcause/mtval/mepc` and returns to `mepc+4`. The body is wrapped in an outer
loop so register values, and therefore branch outcomes, change between
iterations.

`--mix branch` (`make test-random MIX=branch`) re-weights the menu toward the
predecode: bounded data-dependent backward branches with all six
conditions (some fed by a load, so ID holds a predicted branch through a
load-use stall), backward branches that are never taken (predicted taken,
corrected in EX), backward JALs and JAL-at-a-JAL-target chains, hand-encoded
JAL/branches to `pc-2` or `pc+6` (the ID redirect goes to a misaligned PC and
EX must trap or correct it), and a jump directly behind ECALL/EBREAK/illegal
(an EX trap racing an ID prediction).

`scripts/run_random.py` runs each program on the RTL and on Spike
(`--isa=rv32i_zicsr --priv=m --pmpregions=0`) and compares the two commit
logs instruction by instruction (`scripts/cmp_commit.py`). Every third
program also runs with 25% random back-pressure. Both logs are cut at the
first store to `tohost`.

### 5.4 Checking the checker (mutation testing)
`scripts/mutation.py` injects classic pipeline bugs into a copy of the RTL,
one at a time, and reruns the random flow. A verification flow that misses
these bugs is not worth much. Results are in the README.

### 5.5 Performance
`make cpi` runs Dhrystone 2.2 (from riscv-tests, unmodified except for an
`#ifndef` guard on `NUMBER_OF_RUNS`), which reads `mcycle`/`minstret` around
the timed loop. CPI is the ratio of the two deltas. The testbench counters
split the stall cycles into load-use, ID-predecode (1 cycle each) and EX
redirect (2 cycles each: JALR, trap, `mret` and mispredictions)
contributions.

### 5.6 SoC
`make test-soc` runs C code on `soc_top`: it prints over the APB UART (decoded
from the `txd` pin by a bit-level receiver model), checks UART internal
loopback, and takes repeated APB-timer interrupts through
`mip.MTIP -> trap -> handler -> mret`.

## 6. Physical-design flow

* **Scope:** `rv32i_core` only. The register file is built from flops; the
  instruction and data memories sit outside the macro and are modelled by the
  SDC I/O delays (OpenLane2 default: 20% of the clock period on every input
  and output).
* **Tool:** OpenLane2 2.3.10 (`ghcr.io/efabless/openlane2:2.3.10`, native
  arm64 image) on Docker, sky130A, `sky130_fd_sc_hd`. `make pd` in `pd/`.
* **Flow:** Yosys synthesis, OpenROAD floorplan / placement / CTS / global +
  detailed routing, parasitic extraction, multi-corner OpenSTA (tt/ss/ff
  with nominal/min/max RC), Magic + KLayout DRC, Netgen LVS, antenna check.
* **Fmax** is reported as `1 / (T - WNS)` for each corner, which assumes the
  critical path stays the same at a different period. The README states the
  period each run was constrained to.
* **Runs:** `base` (original RTL), `fix` (timing fix, identical config) and
  `final` (fix + heuristic diode insertion and more antenna-repair
  iterations), all at 20 ns, then `pred` (the ID branch predecode with the
  `final` config). The README table compares them. The predecode cost 303
  logic cells and did not lower tt or ss Fmax (its adder starts at
  `imem_rdata` and ends at `pc_f`, outside the forwarding network); it left 2
  marginal antenna nets that `final` did not have.
* **Timing fix:** the baseline's worst path ran from `dmem_rdata` through
  load alignment, forwarding, the branch comparator and `redirect` into
  `load_use`, then `stall_id`, then the `imem_en` output, so two I/O budgets
  were charged to one combinational path. Taking `redirect` out of
  `load_use`, and out of the ID/EX data-field enables, removed it. tt WNS
  improved by 2.68 ns and ss WNS by 0.75 ns; ss TNS got worse because many
  paths now sit near the new limit. The new ss limiter is the high-fanout
  `wb_is_load` select into the forwarding network.
* **Open items:** ss setup at 20 ns, and the max-slew/max-cap violations
  (mostly at ss, increased by diode insertion).

---
