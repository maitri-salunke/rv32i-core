// apb_bridge.sv - core data-bus -> AMBA 3 APB master.
//
// Core bus: req/we/addr/be/wdata held stable until gnt; read data is
// returned the cycle after gnt (same contract as the SRAM).
// APB:  IDLE -> SETUP (PSEL) -> ACCESS (PSEL+PENABLE, wait for PREADY) -> IDLE
// Minimum 3 cycles per access (the core's MEM stage is frozen meanwhile).
// Sub-word writes are performed as full-word writes of the byte-laned data
// (peripheral registers here are word-wide). PSLVERR is recorded in
// err_o for debug but does not raise an exception.
module apb_bridge (
  input  logic        clk,
  input  logic        rst_n,
  // core side
  input  logic        req,
  input  logic        we,
  input  logic [31:0] addr,
  input  logic [31:0] wdata,
  output logic        gnt,
  output logic [31:0] rdata,
  output logic        err_o,
  // APB master
  output logic        psel,
  output logic        penable,
  output logic        pwrite,
  output logic [31:0] paddr,
  output logic [31:0] pwdata,
  input  logic [31:0] prdata,
  input  logic        pready,
  input  logic        pslverr
);
  typedef enum logic [1:0] {IDLE, SETUP, ACCESS} st_t;
  st_t st;

  assign psel    = (st == SETUP) | (st == ACCESS);
  assign penable = (st == ACCESS);
  assign pwrite  = we;
  assign paddr   = addr;
  assign pwdata  = wdata;
  assign gnt     = (st == ACCESS) & pready;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      st <= IDLE; rdata <= 32'b0; err_o <= 1'b0;
    end else begin
      unique case (st)
        IDLE:    if (req) st <= SETUP;
        SETUP:   st <= ACCESS;
        default: if (pready) begin
                   st    <= IDLE;
                   rdata <= prdata;
                   err_o <= pslverr;
                 end
      endcase
    end
  end
endmodule
