// uart_fifo.sv - synchronous FIFO with occupancy count
// Author: Maitri Salunke
//
// Single-clock FIFO. Read data is the current head (first-word fall-through),
// so the APB read path can return it combinationally and pop on the access
// phase handshake. Push when full and pop when empty are ignored; the parent
// is responsible for flagging overflow. A push to a full FIFO in the same
// cycle as a pop is accepted (level unchanged).
module uart_fifo #(
  parameter int WIDTH = 8,
  parameter int DEPTH = 16,
  localparam int AW = $clog2(DEPTH),
  localparam int LW = $clog2(DEPTH + 1)
) (
  input  logic             clk,
  input  logic             rst_n,
  input  logic             clr,      // synchronous flush
  input  logic             push,
  input  logic [WIDTH-1:0] wdata,
  input  logic             pop,
  output logic [WIDTH-1:0] rdata,
  output logic             full,
  output logic             empty,
  output logic [LW-1:0]    level
);

  logic [WIDTH-1:0] mem [DEPTH];
  logic [AW-1:0]    wptr, rptr;
  logic             do_push, do_pop;

  assign full    = (level == LW'(DEPTH));
  assign empty   = (level == '0);
  assign do_push = push && (!full || pop);   // full + simultaneous pop: accept
  assign do_pop  = pop  && !empty;
  assign rdata   = mem[rptr];

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      wptr  <= '0;
      rptr  <= '0;
      level <= '0;
    end else if (clr) begin
      wptr  <= '0;
      rptr  <= '0;
      level <= '0;
    end else begin
      if (do_push) wptr <= (wptr == AW'(DEPTH - 1)) ? '0 : wptr + 1'b1;
      if (do_pop)  rptr <= (rptr == AW'(DEPTH - 1)) ? '0 : rptr + 1'b1;
      unique case ({do_push, do_pop})
        2'b10:   level <= level + 1'b1;
`ifdef MUT_FIFO_LEVEL
        2'b01:   level <= level - 1'b1;
        2'b11:   level <= level - 1'b1;   // MUTATION: simultaneous push+pop miscounted
`else
        2'b01:   level <= level - 1'b1;
`endif
        default: level <= level;
      endcase
    end
  end

  // Storage has no reset (synthesizes to plain flops / latch-free RAM).
  always_ff @(posedge clk) begin
    if (do_push) mem[wptr] <= wdata;
  end

endmodule
