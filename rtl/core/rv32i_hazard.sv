// rv32i_hazard.sv - forwarding select, load-use interlock and stall/flush control.
//
// Forwarding (into EX operands, priority youngest-first):
//   EX/MEM result  -> EX   (ALU/PC+4/CSR result of the instruction one ahead)
//   MEM/WB value   -> EX   (any result incl. load data, two ahead)
//   WB -> ID is handled inside the register file (write-first bypass).
// Load-use: a load in EX whose rd is a source of the instruction in ID stalls
//   IF/ID one cycle and injects a bubble into EX; the value is then forwarded
//   from WB. Penalty: 1 cycle.
// Control: branches/jumps/traps/mret resolve in EX (predict not-taken). A
//   redirect flushes ID and the in-flight fetch. Penalty: 2 cycles.
// Memory back-pressure (dmem_gnt=0 while MEM has an access) freezes IF..MEM
//   and bubbles WB.
module rv32i_hazard (
  // ID stage sources
  input  logic       id_valid,
  input  logic [4:0] id_rs1,
  input  logic [4:0] id_rs2,
  input  logic       id_rs1_used,
  input  logic       id_rs2_used,
  // EX stage
  input  logic       ex_valid,
  input  logic       ex_is_load,
  input  logic [4:0] ex_rd,
  input  logic [4:0] ex_rs1,
  input  logic [4:0] ex_rs2,
  input  logic       ex_redirect_req,  // EX wants to change PC (branch/jump/trap/mret)
  // MEM stage
  input  logic       mem_valid,
  input  logic       mem_rd_we,
  input  logic [4:0] mem_rd,
  input  logic       mem_req,
  input  logic       mem_gnt,
  // WB stage
  input  logic       wb_valid,
  input  logic       wb_rd_we,
  input  logic [4:0] wb_rd,

  output logic [1:0] fwd_a,     // 0: ID/EX register, 1: from MEM, 2: from WB
  output logic [1:0] fwd_b,
  output logic       stall_mem, // global freeze IF..MEM
  output logic       redirect,  // flush ID + fetch, load new PC
  output logic       load_use,  // stall IF/ID, bubble EX (redirect has priority at every user)
  output logic       stall_id   // IF/ID hold
);
  logic mem_fw, wb_fw;

  assign mem_fw = mem_valid & mem_rd_we & (mem_rd != 5'd0);
  assign wb_fw  = wb_valid  & wb_rd_we  & (wb_rd  != 5'd0);

  always_comb begin
    if (mem_fw && mem_rd == ex_rs1)     fwd_a = 2'd1;
    else if (wb_fw && wb_rd == ex_rs1)  fwd_a = 2'd2;
    else                                fwd_a = 2'd0;
    if (mem_fw && mem_rd == ex_rs2)     fwd_b = 2'd1;
    else if (wb_fw && wb_rd == ex_rs2)  fwd_b = 2'd2;
    else                                fwd_b = 2'd0;
  end

  assign stall_mem = mem_req & ~mem_gnt;
  assign redirect  = ex_redirect_req & ~stall_mem;
  // Timing: load_use deliberately does NOT depend on redirect. redirect is the
  // latest signal in the core (forwarded operand -> branch compare); every
  // consumer of load_use/stall_id already gives redirect priority, so gating
  // here only put branch resolution in front of imem_en and the PC/IF-ID
  // enables (it was the post-route critical path, see README "Timing fix").
  assign load_use  = id_valid & ex_valid & ex_is_load & (ex_rd != 5'd0) &
                     ((id_rs1_used & (id_rs1 == ex_rd)) |
                      (id_rs2_used & (id_rs2 == ex_rd)));
  assign stall_id  = stall_mem | load_use;
endmodule
