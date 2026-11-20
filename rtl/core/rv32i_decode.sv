// rv32i_decode.sv - purely combinational RV32I + Zicsr decoder (ID stage).
// Produces control for EX/MEM/WB and flags illegal encodings so that the
// EX stage can raise a precise illegal-instruction exception.
module rv32i_decode
(
  input  logic [31:0] insn,

  output logic [4:0]  rs1,
  output logic [4:0]  rs2,
  output logic [4:0]  rd,
  output logic        rs1_used,
  output logic        rs2_used,
  output logic        rd_we,
  output logic [31:0] imm,
  output logic [3:0]  alu_op,
  output logic [1:0]  opa_sel,
  output logic        opb_imm,     // 1: operand B = imm, 0: rs2
  output logic [1:0]  wb_sel,
  output logic        is_branch,
  output logic        is_jal,
  output logic        is_jalr,
  output logic        is_load,
  output logic        is_store,
  output logic [2:0]  funct3,
  output logic        is_csr,
  output logic        is_ecall,
  output logic        is_ebreak,
  output logic        is_mret,
  output logic        illegal
);
  `include "rv32i_defs.svh"

  logic [6:0] opcode;
  logic [6:0] funct7;
  logic [31:0] imm_i, imm_s, imm_b, imm_u, imm_j;

  assign opcode = insn[6:0];
  assign funct3 = insn[14:12];
  assign funct7 = insn[31:25];
  assign rs1    = insn[19:15];
  assign rs2    = insn[24:20];
  assign rd     = insn[11:7];

  assign imm_i = {{20{insn[31]}}, insn[31:20]};
  assign imm_s = {{20{insn[31]}}, insn[31:25], insn[11:7]};
  assign imm_b = {{19{insn[31]}}, insn[31], insn[7], insn[30:25], insn[11:8], 1'b0};
  assign imm_u = {insn[31:12], 12'b0};
  assign imm_j = {{11{insn[31]}}, insn[31], insn[19:12], insn[20], insn[30:21], 1'b0};

  always_comb begin
    rs1_used  = 1'b0;
    rs2_used  = 1'b0;
    rd_we     = 1'b0;
    imm       = imm_i;
    alu_op    = ALU_ADD;
    opa_sel   = OPA_RS1;
    opb_imm   = 1'b1;
    wb_sel    = WB_ALU;
    is_branch = 1'b0;
    is_jal    = 1'b0;
    is_jalr   = 1'b0;
    is_load   = 1'b0;
    is_store  = 1'b0;
    is_csr    = 1'b0;
    is_ecall  = 1'b0;
    is_ebreak = 1'b0;
    is_mret   = 1'b0;
    illegal   = 1'b0;

    // RV32I without C: insn[1:0] must be 2'b11
    if (insn[1:0] != 2'b11) illegal = 1'b1;

    unique case (opcode)
      OP_LUI: begin
        rd_we = 1'b1; imm = imm_u; opa_sel = OPA_ZERO;
      end
      OP_AUIPC: begin
        rd_we = 1'b1; imm = imm_u; opa_sel = OPA_PC;
      end
      OP_JAL: begin
        rd_we = 1'b1; imm = imm_j; is_jal = 1'b1; wb_sel = WB_PC4;
      end
      OP_JALR: begin
        rd_we = 1'b1; rs1_used = 1'b1; imm = imm_i; is_jalr = 1'b1; wb_sel = WB_PC4;
        if (funct3 != 3'b000) illegal = 1'b1;
      end
      OP_BRANCH: begin
        rs1_used = 1'b1; rs2_used = 1'b1; imm = imm_b; is_branch = 1'b1;
        if (funct3 == 3'b010 || funct3 == 3'b011) illegal = 1'b1;
      end
      OP_LOAD: begin
        rd_we = 1'b1; rs1_used = 1'b1; imm = imm_i; is_load = 1'b1; wb_sel = WB_MEM;
        if (funct3 == 3'b011 || funct3 == 3'b110 || funct3 == 3'b111) illegal = 1'b1;
      end
      OP_STORE: begin
        rs1_used = 1'b1; rs2_used = 1'b1; imm = imm_s; is_store = 1'b1;
        if (funct3[2] || funct3[1:0] == 2'b11) illegal = 1'b1;
      end
      OP_IMM: begin
        rd_we = 1'b1; rs1_used = 1'b1; imm = imm_i;
        unique case (funct3)
          3'b000: alu_op = ALU_ADD;
          3'b010: alu_op = ALU_SLT;
          3'b011: alu_op = ALU_SLTU;
          3'b100: alu_op = ALU_XOR;
          3'b110: alu_op = ALU_OR;
          3'b111: alu_op = ALU_AND;
          3'b001: begin
            alu_op = ALU_SLL;
            if (funct7 != 7'b0000000) illegal = 1'b1;
          end
          default: begin // 3'b101
            if (funct7 == 7'b0000000)      alu_op = ALU_SRL;
            else if (funct7 == 7'b0100000) alu_op = ALU_SRA;
            else                           illegal = 1'b1;
          end
        endcase
      end
      OP_REG: begin
        rd_we = 1'b1; rs1_used = 1'b1; rs2_used = 1'b1; opb_imm = 1'b0;
        if (funct7 == 7'b0000000) begin
          unique case (funct3)
            3'b000: alu_op = ALU_ADD;
            3'b001: alu_op = ALU_SLL;
            3'b010: alu_op = ALU_SLT;
            3'b011: alu_op = ALU_SLTU;
            3'b100: alu_op = ALU_XOR;
            3'b101: alu_op = ALU_SRL;
            3'b110: alu_op = ALU_OR;
            default: alu_op = ALU_AND;
          endcase
        end else if (funct7 == 7'b0100000 && funct3 == 3'b000) begin
          alu_op = ALU_SUB;
        end else if (funct7 == 7'b0100000 && funct3 == 3'b101) begin
          alu_op = ALU_SRA;
        end else begin
          illegal = 1'b1;
        end
      end
      OP_FENCE: begin
        // FENCE is a no-op on this single-hart in-order core. FENCE.I
        // (Zifencei) is not implemented and traps as illegal.
        if (funct3 != 3'b000) illegal = 1'b1;
      end
      OP_SYSTEM: begin
        if (funct3 == 3'b000) begin
          if (insn == 32'h0000_0073)      is_ecall  = 1'b1;
          else if (insn == 32'h0010_0073) is_ebreak = 1'b1;
          else if (insn == 32'h3020_0073) is_mret   = 1'b1;
          else if (insn == 32'h1050_0073) begin end      // WFI as NOP
          else                            illegal   = 1'b1;
        end else if (funct3 == 3'b100) begin
          illegal = 1'b1;
        end else begin
          // CSRRW/S/C (funct3[2]=0, rs1 register) and CSRRWI/SI/CI (zimm)
          is_csr   = 1'b1;
          rd_we    = 1'b1;
          wb_sel   = WB_CSR;
          rs1_used = ~funct3[2];       // zimm form reads no register
          imm      = imm_i;            // imm[11:0] = CSR address; zimm = rs1 field
        end
      end
      default: illegal = 1'b1;
    endcase

    // Never let an illegal instruction have architectural side effects.
    if (illegal) begin
      rd_we = 1'b0; is_load = 1'b0; is_store = 1'b0; is_branch = 1'b0;
      is_jal = 1'b0; is_jalr = 1'b0; is_csr = 1'b0;
      is_ecall = 1'b0; is_ebreak = 1'b0; is_mret = 1'b0;
    end
  end

endmodule
