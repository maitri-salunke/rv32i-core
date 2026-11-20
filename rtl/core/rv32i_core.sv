// rv32i_core.sv - 5-stage in-order RV32I_Zicsr pipeline (IF ID EX MEM WB).
//
// Memory interfaces model synchronous SRAMs (address/enable in cycle N, data
// valid in cycle N+1), so the instruction memory's output register doubles as
// the IF/ID instruction register and the data memory's output is consumed in WB.
//
//   IF : pc_f drives imem_addr directly (registered output).
//   ID : decode imem_rdata, read register file (WB write-first bypass).
//        Static predecode: JAL and backward conditional branches redirect
//        fetch to pc+imm from ID (1-cycle bubble); forward branches are
//        predicted not-taken (BTFN). JALR is not predicted.
//   EX : forwarding muxes, ALU, branch compare, jump target, CSR access,
//        exception/interrupt detection. EX corrects mispredictions (and
//        handles JALR, traps, mret) with the 2-cycle redirect.
//   MEM: drive dmem request from the EX/MEM register (store data pre-aligned
//        in EX). dmem_gnt=0 freezes the pipe.
//   WB : align/sign-extend load data, write the register file, count retire.
module rv32i_core
#(
  parameter logic [31:0] RESET_PC = 32'h8000_0000
)(
  input  logic        clk,
  input  logic        rst_n,

  // instruction memory (sync read)
  output logic        imem_en,
  output logic [31:0] imem_addr,
  input  logic [31:0] imem_rdata,

  // data memory (request in MEM, read data valid the cycle after grant)
  output logic        dmem_req,
  output logic        dmem_we,
  output logic [31:0] dmem_addr,
  output logic [3:0]  dmem_be,
  output logic [31:0] dmem_wdata,
  input  logic        dmem_gnt,
  input  logic [31:0] dmem_rdata,

  input  logic        irq_timer
);
  `include "rv32i_defs.svh"

  // ==========================================================================
  // Hazard / control wires
  // ==========================================================================
  logic [1:0]  fwd_a_sel, fwd_b_sel;
  logic        stall_mem, redirect, load_use, stall_id;
  logic        ex_redirect_req;
  logic [31:0] redirect_pc;
  logic        id_pred;          // ID predecode: predicted-taken JAL/branch
  logic [31:0] id_pred_target;

  // ==========================================================================
  // IF
  // ==========================================================================
  logic [31:0] pc_f;

  assign imem_addr = pc_f;
  assign imem_en   = ~stall_id;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)          pc_f <= RESET_PC;
    else if (redirect)   pc_f <= redirect_pc;
    else if (!stall_id)  pc_f <= id_pred ? id_pred_target : pc_f + 32'd4;
  end

  // ==========================================================================
  // IF/ID  (instruction word itself lives in the imem output register)
  // ==========================================================================
  logic        id_valid;
  logic [31:0] id_pc;
  logic [31:0] id_insn;

  assign id_insn = imem_rdata;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      id_valid <= 1'b0;
      id_pc    <= 32'b0;
    end else if (redirect) begin
      id_valid <= 1'b0;
    end else if (!stall_id) begin
      id_valid <= ~id_pred;   // squash the pc+4 fetch behind a predicted-taken jump
      id_pc    <= pc_f;
    end
  end

  // ==========================================================================
  // ID
  // ==========================================================================
  // ---- static branch predecode (independent of the register file and of
  // forwarding: only the instruction word and id_pc) ----
  logic        pd_is_jal, pd_is_br;
  logic [31:0] pd_imm;

  assign pd_is_jal = (id_insn[6:0] == OP_JAL);
  assign pd_is_br  = (id_insn[6:0] == OP_BRANCH);
  // JAL (opcode bit 2 set) uses the J-immediate, branches the B-immediate.
  assign pd_imm    = id_insn[2] ?
      {{12{id_insn[31]}}, id_insn[19:12], id_insn[20], id_insn[30:21], 1'b0} :
      {{20{id_insn[31]}}, id_insn[7], id_insn[30:25], id_insn[11:8], 1'b0};
  // JAL always taken; conditional branch taken iff backward (imm sign bit).
  assign id_pred        = id_valid & (pd_is_jal | (pd_is_br & id_insn[31]));
  assign id_pred_target = id_pc + pd_imm;

  logic [4:0]  d_rs1, d_rs2, d_rd;
  logic        d_rs1_used, d_rs2_used, d_rd_we;
  logic [31:0] d_imm;
  logic [3:0]  d_alu_op;
  logic [1:0]  d_opa_sel, d_wb_sel;
  logic        d_opb_imm;
  logic        d_is_branch, d_is_jal, d_is_jalr, d_is_load, d_is_store;
  logic [2:0]  d_funct3;
  logic        d_is_csr, d_is_ecall, d_is_ebreak, d_is_mret, d_illegal;
  logic [31:0] rf_rd1, rf_rd2;

  // WB-stage register-file write port (driven below)
  logic        wb_valid, wb_rd_we;
  logic [4:0]  wb_rd;
  logic [31:0] wb_value;

  rv32i_decode u_decode (
    .insn      (id_insn),
    .rs1       (d_rs1),      .rs2      (d_rs2),     .rd       (d_rd),
    .rs1_used  (d_rs1_used), .rs2_used (d_rs2_used), .rd_we   (d_rd_we),
    .imm       (d_imm),      .alu_op   (d_alu_op),
    .opa_sel   (d_opa_sel),  .opb_imm  (d_opb_imm), .wb_sel   (d_wb_sel),
    .is_branch (d_is_branch),.is_jal   (d_is_jal),  .is_jalr  (d_is_jalr),
    .is_load   (d_is_load),  .is_store (d_is_store),.funct3   (d_funct3),
    .is_csr    (d_is_csr),   .is_ecall (d_is_ecall),.is_ebreak(d_is_ebreak),
    .is_mret   (d_is_mret),  .illegal  (d_illegal)
  );

  rv32i_regfile u_rf (
    .clk (clk),
    .ra1 (d_rs1), .ra2 (d_rs2),
    .rd1 (rf_rd1), .rd2 (rf_rd2),
    .we  (wb_valid & wb_rd_we), .wa (wb_rd), .wd (wb_value)
  );

  // ==========================================================================
  // ID/EX
  // ==========================================================================
  logic        ex_valid;
  logic [31:0] ex_pc;
  logic [4:0]  ex_rs1, ex_rs2, ex_rd;
  logic        ex_rd_we;
  logic [31:0] ex_imm;
  logic [3:0]  ex_alu_op;
  logic [1:0]  ex_opa_sel, ex_wb_sel;
  logic        ex_opb_imm;
  logic        ex_is_branch, ex_is_jal, ex_is_jalr, ex_is_load, ex_is_store;
  logic [2:0]  ex_funct3;
  logic        ex_is_csr, ex_is_ecall, ex_is_ebreak, ex_is_mret, ex_illegal;
  logic        ex_pred;      // fetch was already redirected to pc+imm in ID
  logic [31:0] ex_rs1_val, ex_rs2_val;
  logic [31:0] ex_insn;      // for mtval on illegal instruction
  logic [31:0] fwd_a, fwd_b;

  // Only the valid bit sees flush/interlock. The data fields load whenever the
  // pipe is not frozen (a squashed or stalled slot is simply marked invalid),
  // which keeps the late redirect/load_use signals off ~150 flop enables.
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)          ex_valid <= 1'b0;
    else if (!stall_mem) ex_valid <= id_valid & ~redirect & ~load_use;
  end

  always_ff @(posedge clk) begin
    if (stall_mem) begin
      // Pipe is frozen. The forwarding source in WB retires this cycle and
      // will be gone next cycle, so latch the forwarded operands now.
      ex_rs1_val <= fwd_a;
      ex_rs2_val <= fwd_b;
    end else begin
      ex_pc        <= id_pc;
      ex_insn      <= id_insn;
      ex_rs1       <= d_rs1;
      ex_rs2       <= d_rs2;
      ex_rd        <= d_rd;
      ex_rd_we     <= d_rd_we;
      ex_imm       <= d_imm;
      ex_alu_op    <= d_alu_op;
      ex_opa_sel   <= d_opa_sel;
      ex_opb_imm   <= d_opb_imm;
      ex_wb_sel    <= d_wb_sel;
      ex_is_branch <= d_is_branch;
      ex_is_jal    <= d_is_jal;
      ex_is_jalr   <= d_is_jalr;
      ex_is_load   <= d_is_load;
      ex_is_store  <= d_is_store;
      ex_funct3    <= d_funct3;
      ex_is_csr    <= d_is_csr;
      ex_is_ecall  <= d_is_ecall;
      ex_is_ebreak <= d_is_ebreak;
      ex_is_mret   <= d_is_mret;
      ex_illegal   <= d_illegal;
      ex_pred      <= id_pred;
      ex_rs1_val   <= rf_rd1;
      ex_rs2_val   <= rf_rd2;
    end
  end

  // ==========================================================================
  // EX
  // ==========================================================================
  logic        mem_valid, mem_rd_we;
  logic [4:0]  mem_rd;
  logic [31:0] mem_result;

  always_comb begin
    unique case (fwd_a_sel)
      2'd1:    fwd_a = mem_result;
      2'd2:    fwd_a = wb_value;
      default: fwd_a = ex_rs1_val;
    endcase
    unique case (fwd_b_sel)
      2'd1:    fwd_b = mem_result;
      2'd2:    fwd_b = wb_value;
      default: fwd_b = ex_rs2_val;
    endcase
  end

  logic [31:0] alu_a, alu_b, alu_y;
  always_comb begin
    unique case (ex_opa_sel)
      OPA_PC:   alu_a = ex_pc;
      OPA_ZERO: alu_a = 32'b0;
      default:  alu_a = fwd_a;
    endcase
    alu_b = ex_opb_imm ? ex_imm : fwd_b;
  end

  rv32i_alu u_alu (.op(ex_alu_op), .a(alu_a), .b(alu_b), .y(alu_y));

  // ---- branch / jump ----
  logic        br_eq, br_lt, br_ltu, br_cond, jump_taken;
  logic [31:0] br_target, jump_target, pc_plus4;

  assign br_eq  = (fwd_a == fwd_b);
  assign br_lt  = ($signed(fwd_a) < $signed(fwd_b));
  assign br_ltu = (fwd_a < fwd_b);

  always_comb begin
    unique case (ex_funct3)
      3'b000:  br_cond = br_eq;
      3'b001:  br_cond = ~br_eq;
      3'b100:  br_cond = br_lt;
      3'b101:  br_cond = ~br_lt;
      3'b110:  br_cond = br_ltu;
      default: br_cond = ~br_ltu;   // 3'b111
    endcase
  end

  assign br_target   = ex_pc + ex_imm;
  assign pc_plus4    = ex_pc + 32'd4;
  assign jump_taken  = ex_is_jal | ex_is_jalr | (ex_is_branch & br_cond);
  assign jump_target = ex_is_jalr ? {alu_y[31:1], 1'b0} : br_target;

  // ---- load/store address checks and store alignment ----
  logic        ld_misaligned, st_misaligned;
  logic [31:0] st_wdata;
  logic [3:0]  st_be;

  always_comb begin
    ld_misaligned = 1'b0;
    st_misaligned = 1'b0;
    unique case (ex_funct3[1:0])
      2'b00: begin  // byte
        st_wdata = {4{fwd_b[7:0]}};
        st_be    = 4'b0001 << alu_y[1:0];
      end
      2'b01: begin  // half
        st_wdata = {2{fwd_b[15:0]}};
        st_be    = alu_y[1] ? 4'b1100 : 4'b0011;
        ld_misaligned = ex_is_load  & alu_y[0];
        st_misaligned = ex_is_store & alu_y[0];
      end
      default: begin // word
        st_wdata = fwd_b;
        st_be    = 4'b1111;
        ld_misaligned = ex_is_load  & (alu_y[1:0] != 2'b00);
        st_misaligned = ex_is_store & (alu_y[1:0] != 2'b00);
      end
    endcase
  end

  // ---- CSR ----
  logic [31:0] csr_rdata, csr_src, mtvec, mepc;
  logic        csr_illegal, csr_wr_req, irq_pending;

  assign csr_src    = ex_funct3[2] ? {27'b0, ex_rs1} : fwd_a;
  assign csr_wr_req = (ex_funct3[1:0] == 2'b01) | (ex_rs1 != 5'd0);

  // ---- exceptions / interrupts (precise: taken on the EX instruction) ----
  logic        ex_exc, ex_trap, ex_irq, ex_mret_go;
  logic [3:0]  exc_cause;
  logic [31:0] exc_tval;

  always_comb begin
    ex_exc    = 1'b1;
    exc_cause = EXC_ILLEGAL_INSN;
    exc_tval  = 32'b0;
    if (ex_illegal || (ex_is_csr && csr_illegal)) begin
      exc_cause = EXC_ILLEGAL_INSN;   exc_tval = ex_insn;
    end else if (ex_is_ecall) begin
      exc_cause = EXC_ECALL_M;        exc_tval = 32'b0;
    end else if (ex_is_ebreak) begin
      exc_cause = EXC_BREAKPOINT;     exc_tval = ex_pc;
    end else if (ld_misaligned) begin
      exc_cause = EXC_LOAD_MISALIGNED;  exc_tval = alu_y;
    end else if (st_misaligned) begin
      exc_cause = EXC_STORE_MISALIGNED; exc_tval = alu_y;
    end else if (jump_taken && jump_target[1]) begin
      exc_cause = EXC_INSN_MISALIGNED;  exc_tval = jump_target;
    end else begin
      ex_exc = 1'b0;
    end
  end

  assign ex_irq     = ex_valid & irq_pending;
  assign ex_trap    = ex_valid & (ex_exc | irq_pending);
  assign ex_mret_go = ex_valid & ex_is_mret & ~ex_trap;

  // Control-flow correction: JALR always; JAL/branch only when the ID
  // prediction was wrong. For a mispredicted branch the correct PC follows
  // from the prediction alone (predicted taken -> pc+4, else the target), so
  // the late compare result br_cond selects only whether to redirect, never
  // where to.
  logic ex_mispredict;
  assign ex_mispredict   = ex_valid & (ex_is_jalr | (ex_is_jal & ~ex_pred) |
                                       (ex_is_branch & (br_cond ^ ex_pred)));
  assign ex_redirect_req = ex_trap | ex_mret_go | ex_mispredict;
  assign redirect_pc     = ex_trap    ? mtvec :
                           ex_mret_go ? mepc  :
                           (ex_is_branch & ex_pred) ? pc_plus4 : jump_target;

  rv32i_csr u_csr (
    .clk         (clk),
    .rst_n       (rst_n),
    .addr        (ex_imm[11:0]),
    .op          (ex_funct3[1:0]),
    .src         (csr_src),
    .wr_req      (csr_wr_req),
    .csr_we      (ex_valid & ex_is_csr & csr_wr_req & ~ex_trap & ~stall_mem),
    .rdata       (csr_rdata),
    .illegal     (csr_illegal),
    .trap_take   (ex_trap & ~stall_mem),
    .trap_irq    (ex_irq),
    .trap_cause  (ex_irq ? IRQ_M_TIMER : exc_cause),
    .trap_epc    (ex_pc),
    .trap_tval   (ex_irq ? 32'b0 : exc_tval),
    .mret_take   (ex_mret_go & ~stall_mem),
    .mtvec_o     (mtvec),
    .mepc_o      (mepc),
    .irq_timer   (irq_timer),
    .irq_pending (irq_pending),
    .retire      (wb_valid),
    .mem_valid   (mem_valid),
    .wb_valid    (wb_valid)
  );

  logic [31:0] ex_result;
  always_comb begin
    unique case (ex_wb_sel)
      WB_PC4:  ex_result = pc_plus4;
      WB_CSR:  ex_result = csr_rdata;
      default: ex_result = alu_y;     // ALU result, or address for loads
    endcase
  end

  // ==========================================================================
  // EX/MEM
  // ==========================================================================
  logic        mem_is_load, mem_is_store;
  logic [2:0]  mem_funct3;
  logic [31:0] mem_wdata;
  logic [3:0]  mem_be;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      mem_valid <= 1'b0;
    end else if (!stall_mem) begin
      mem_valid    <= ex_valid & ~ex_trap;
      mem_rd       <= ex_rd;
      mem_rd_we    <= ex_rd_we;
      mem_result   <= ex_result;
      mem_is_load  <= ex_is_load;
      mem_is_store <= ex_is_store;
      mem_funct3   <= ex_funct3;
      mem_wdata    <= st_wdata;
      mem_be       <= st_be;
    end
  end

  // ==========================================================================
  // MEM
  // ==========================================================================
  assign dmem_req   = mem_valid & (mem_is_load | mem_is_store);
  assign dmem_we    = mem_is_store;
  assign dmem_addr  = {mem_result[31:2], 2'b00};
  assign dmem_be    = mem_is_store ? mem_be : 4'b1111;
  assign dmem_wdata = mem_wdata;

  // ==========================================================================
  // MEM/WB
  // ==========================================================================
  logic        wb_is_load;
  logic [2:0]  wb_funct3;
  logic [31:0] wb_result;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      wb_valid <= 1'b0;
    end else begin
      wb_valid <= mem_valid & ~stall_mem;
      if (!stall_mem) begin
        wb_rd      <= mem_rd;
        wb_rd_we   <= mem_rd_we;
        wb_result  <= mem_result;
        wb_is_load <= mem_is_load;
        wb_funct3  <= mem_funct3;
      end
    end
  end

  // ==========================================================================
  // WB : load alignment / extension
  // ==========================================================================
  /* verilator lint_off UNUSEDSIGNAL */
  logic [31:0] ld_shifted;   // upper half unused by design
  /* verilator lint_on UNUSEDSIGNAL */
  logic [31:0] ld_value;
  assign ld_shifted = dmem_rdata >> {wb_result[1:0], 3'b000};

  always_comb begin
    unique case (wb_funct3)
      3'b000:  ld_value = {{24{ld_shifted[7]}},  ld_shifted[7:0]};   // LB
      3'b001:  ld_value = {{16{ld_shifted[15]}}, ld_shifted[15:0]};  // LH
      3'b100:  ld_value = {24'b0, ld_shifted[7:0]};                  // LBU
      3'b101:  ld_value = {16'b0, ld_shifted[15:0]};                 // LHU
      default: ld_value = dmem_rdata;                                // LW
    endcase
  end

  assign wb_value = wb_is_load ? ld_value : wb_result;

  // ==========================================================================
  // Hazard unit
  // ==========================================================================
  rv32i_hazard u_hazard (
    .id_valid        (id_valid),
    .id_rs1          (d_rs1),
    .id_rs2          (d_rs2),
    .id_rs1_used     (d_rs1_used),
    .id_rs2_used     (d_rs2_used),
    .ex_valid        (ex_valid),
    .ex_is_load      (ex_is_load),
    .ex_rd           (ex_rd),
    .ex_rs1          (ex_rs1),
    .ex_rs2          (ex_rs2),
    .ex_redirect_req (ex_redirect_req),
    .mem_valid       (mem_valid),
    .mem_rd_we       (mem_rd_we),
    .mem_rd          (mem_rd),
    .mem_req         (dmem_req),
    .mem_gnt         (dmem_gnt),
    .wb_valid        (wb_valid),
    .wb_rd_we        (wb_rd_we),
    .wb_rd           (wb_rd),
    .fwd_a           (fwd_a_sel),
    .fwd_b           (fwd_b_sel),
    .stall_mem       (stall_mem),
    .redirect        (redirect),
    .load_use        (load_use),
    .stall_id        (stall_id)
  );

`ifndef SYNTHESIS
  // ==========================================================================
  // Simulation-only retire information (consumed by tb/rv_tracer.sv).
  // Carries the instruction word and memory access info to WB.
  // ==========================================================================
  /* verilator lint_off UNUSEDSIGNAL */
  logic [31:0] mem_pc, wb_pc;
  logic [31:0] mem_insn_t, wb_insn_t;
  logic [31:0] mem_st_raw_t, wb_st_raw_t;
  logic        wb_is_store_t;
  /* verilator lint_on UNUSEDSIGNAL */
  always_ff @(posedge clk) begin
    if (!stall_mem) begin
      mem_pc       <= ex_pc;
      wb_pc        <= mem_pc;
      mem_insn_t   <= ex_insn;
      mem_st_raw_t <= fwd_b;
      wb_insn_t    <= mem_insn_t;
      wb_st_raw_t  <= mem_st_raw_t;
      wb_is_store_t<= mem_is_store;
    end
  end

`endif

endmodule
