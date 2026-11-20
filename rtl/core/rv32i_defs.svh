// rv32i_defs.svh - shared constants for the RV32I pipeline.
// Included inside each module body. Plain localparams (no package, struct or
// enum) because the Yosys native front end used by OpenLane2 does not accept
// package imports; this form reads identically in Yosys, Verilator, Icarus.

  // Each module uses a subset of these constants.
  /* verilator lint_off UNUSEDPARAM */

  // ---------------- opcodes (insn[6:0]) ----------------
  localparam logic [6:0] OP_LUI    = 7'b0110111;
  localparam logic [6:0] OP_AUIPC  = 7'b0010111;
  localparam logic [6:0] OP_JAL    = 7'b1101111;
  localparam logic [6:0] OP_JALR   = 7'b1100111;
  localparam logic [6:0] OP_BRANCH = 7'b1100011;
  localparam logic [6:0] OP_LOAD   = 7'b0000011;
  localparam logic [6:0] OP_STORE  = 7'b0100011;
  localparam logic [6:0] OP_IMM    = 7'b0010011;
  localparam logic [6:0] OP_REG    = 7'b0110011;
  localparam logic [6:0] OP_FENCE  = 7'b0001111;
  localparam logic [6:0] OP_SYSTEM = 7'b1110011;

  // ---------------- ALU operations ----------------
  localparam logic [3:0] ALU_ADD  = 4'd0;
  localparam logic [3:0] ALU_SUB  = 4'd1;
  localparam logic [3:0] ALU_SLL  = 4'd2;
  localparam logic [3:0] ALU_SLT  = 4'd3;
  localparam logic [3:0] ALU_SLTU = 4'd4;
  localparam logic [3:0] ALU_XOR  = 4'd5;
  localparam logic [3:0] ALU_SRL  = 4'd6;
  localparam logic [3:0] ALU_SRA  = 4'd7;
  localparam logic [3:0] ALU_OR   = 4'd8;
  localparam logic [3:0] ALU_AND  = 4'd9;

  // ---------------- operand A select ----------------
  localparam logic [1:0] OPA_RS1  = 2'd0;
  localparam logic [1:0] OPA_PC   = 2'd1;
  localparam logic [1:0] OPA_ZERO = 2'd2;

  // ---------------- write-back select ----------------
  localparam logic [1:0] WB_ALU = 2'd0;
  localparam logic [1:0] WB_MEM = 2'd1;
  localparam logic [1:0] WB_PC4 = 2'd2;
  localparam logic [1:0] WB_CSR = 2'd3;

  // ---------------- exception causes (mcause) ----------------
  localparam logic [3:0] EXC_INSN_MISALIGNED  = 4'd0;
  localparam logic [3:0] EXC_ILLEGAL_INSN     = 4'd2;
  localparam logic [3:0] EXC_BREAKPOINT       = 4'd3;
  localparam logic [3:0] EXC_LOAD_MISALIGNED  = 4'd4;
  localparam logic [3:0] EXC_STORE_MISALIGNED = 4'd6;
  localparam logic [3:0] EXC_ECALL_M          = 4'd11;
  localparam logic [3:0] IRQ_M_TIMER          = 4'd7;

  // ---------------- CSR addresses ----------------
  localparam logic [11:0] CSR_MSTATUS   = 12'h300;
  localparam logic [11:0] CSR_MISA      = 12'h301;
  localparam logic [11:0] CSR_MIE       = 12'h304;
  localparam logic [11:0] CSR_MTVEC     = 12'h305;
  localparam logic [11:0] CSR_MSCRATCH  = 12'h340;
  localparam logic [11:0] CSR_MEPC      = 12'h341;
  localparam logic [11:0] CSR_MCAUSE    = 12'h342;
  localparam logic [11:0] CSR_MTVAL     = 12'h343;
  localparam logic [11:0] CSR_MIP       = 12'h344;
  localparam logic [11:0] CSR_MCYCLE    = 12'hB00;
  localparam logic [11:0] CSR_MINSTRET  = 12'hB02;
  localparam logic [11:0] CSR_MCYCLEH   = 12'hB80;
  localparam logic [11:0] CSR_MINSTRETH = 12'hB82;
  localparam logic [11:0] CSR_CYCLE     = 12'hC00;
  localparam logic [11:0] CSR_INSTRET   = 12'hC02;
  localparam logic [11:0] CSR_CYCLEH    = 12'hC80;
  localparam logic [11:0] CSR_INSTRETH  = 12'hC82;
  localparam logic [11:0] CSR_MVENDORID = 12'hF11;
  localparam logic [11:0] CSR_MARCHID   = 12'hF12;
  localparam logic [11:0] CSR_MIMPID    = 12'hF13;
  localparam logic [11:0] CSR_MHARTID   = 12'hF14;

  /* verilator lint_on UNUSEDPARAM */
