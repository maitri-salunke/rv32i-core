// rv32i_regfile.sv - 31 x 32-bit flop-based register file (x0 hard-wired).
// Two asynchronous read ports (ID stage) and one synchronous write port (WB).
// Write-first bypass: a read of the register being written this cycle
// returns the new value, which closes the WB->ID hazard without forwarding.
module rv32i_regfile (
  input  logic        clk,
  input  logic [4:0]  ra1,
  input  logic [4:0]  ra2,
  output logic [31:0] rd1,
  output logic [31:0] rd2,
  input  logic        we,
  input  logic [4:0]  wa,
  input  logic [31:0] wd
);
  logic [31:0] regs [1:31];

  always_ff @(posedge clk) begin
    if (we && wa != 5'd0) regs[wa] <= wd;
  end

  always_comb begin
    if (ra1 == 5'd0)                rd1 = 32'b0;
    else if (we && wa == ra1)       rd1 = wd;
    else                            rd1 = regs[ra1];
    if (ra2 == 5'd0)                rd2 = 32'b0;
    else if (we && wa == ra2)       rd2 = wd;
    else                            rd2 = regs[ra2];
  end
endmodule
