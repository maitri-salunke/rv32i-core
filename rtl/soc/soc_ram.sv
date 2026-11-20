// soc_ram.sv - behavioural synchronous single-port RAM with byte enables
// (stand-in for an SRAM macro). Read data appears the cycle after en.
module soc_ram #(
  parameter int    WORDS = 16384,          // 64 KiB
  parameter string INIT  = ""
)(
  input  logic                     clk,
  input  logic                     en,
  input  logic                     we,
  input  logic [3:0]               be,
  input  logic [$clog2(WORDS)-1:0] addr,
  input  logic [31:0]              wdata,
  output logic [31:0]              rdata
);
  logic [31:0] mem [WORDS];
  initial if (INIT != "") $readmemh(INIT, mem);
  always_ff @(posedge clk) begin
    if (en) begin
      if (we) begin
        for (int b = 0; b < 4; b++) if (be[b]) mem[addr][8*b +: 8] <= wdata[8*b +: 8];
      end else begin
        rdata <= mem[addr];
      end
    end
  end
endmodule
