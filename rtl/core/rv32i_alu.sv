// rv32i_alu.sv - RV32I integer ALU (EX stage).
module rv32i_alu
(
  input  logic [3:0]  op,
  input  logic [31:0] a,
  input  logic [31:0] b,
  output logic [31:0] y
);
  `include "rv32i_defs.svh"
  logic [31:0] sum;
  logic [32:0] diff;     // a - b with borrow, shared by SUB/SLT/SLTU
  logic        lt_s, lt_u;

  assign sum  = a + b;
  assign diff = {1'b0, a} - {1'b0, b};
  assign lt_u = diff[32];
  assign lt_s = (a[31] ^ b[31]) ? a[31] : diff[31];

  always_comb begin
    unique case (op)
      ALU_ADD:  y = sum;
      ALU_SUB:  y = diff[31:0];
      ALU_SLL:  y = a << b[4:0];
      ALU_SLT:  y = {31'b0, lt_s};
      ALU_SLTU: y = {31'b0, lt_u};
      ALU_XOR:  y = a ^ b;
      ALU_SRL:  y = a >> b[4:0];
      ALU_SRA:  y = $unsigned($signed(a) >>> b[4:0]);
      ALU_OR:   y = a | b;
      ALU_AND:  y = a & b;
      default:  y = sum;
    endcase
  end
endmodule
