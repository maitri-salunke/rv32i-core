// apb_timer.sv - 32-bit APB timer with compare interrupt (zero wait states).
//
//   0x00 COUNT   RW  free-running up-counter (advances every PRESCALE+1 clocks when EN)
//   0x04 CMP     RW  compare value; writing CMP clears the MATCH flag
//   0x08 CTRL    RW  [0] EN, [1] IRQ_EN, [31:16] PRESCALE
//   0x0C STATUS  RW1C [0] MATCH (sticky, set when COUNT == CMP while EN)
// irq = IRQ_EN & MATCH (level). Unmapped offsets read 0 and set PSLVERR.
module apb_timer (
  input  logic        pclk,
  input  logic        presetn,
  input  logic        psel,
  input  logic        penable,
  input  logic        pwrite,
  /* verilator lint_off UNUSEDSIGNAL */
  input  logic [11:0] paddr,
  /* verilator lint_on UNUSEDSIGNAL */
  input  logic [31:0] pwdata,
  output logic [31:0] prdata,
  output logic        pready,
  output logic        pslverr,
  output logic        irq
);
  logic [31:0] count, cmp;
  logic [15:0] prescale, pre_cnt;
  logic        en, irq_en, match;

  wire        xfer   = psel & penable;
  wire [3:0]  off    = paddr[3:0];
  wire        mapped = (paddr[11:4] == 8'h0);
  wire        wr     = xfer & pwrite & mapped;
  wire        tick   = en & (pre_cnt == prescale);

  assign pready  = 1'b1;
  assign pslverr = xfer & ~mapped;
  assign irq     = irq_en & match;

  always_comb begin
    prdata = 32'b0;
    if (xfer && !pwrite && mapped) begin
      unique case (off)
        4'h0: prdata = count;
        4'h4: prdata = cmp;
        4'h8: prdata = {prescale, 14'b0, irq_en, en};
        4'hC: prdata = {31'b0, match};
        default: prdata = 32'b0;
      endcase
    end
  end

  always_ff @(posedge pclk or negedge presetn) begin
    if (!presetn) begin
      count <= 32'b0; cmp <= 32'hFFFF_FFFF; prescale <= 16'b0; pre_cnt <= 16'b0;
      en <= 1'b0; irq_en <= 1'b0; match <= 1'b0;
    end else begin
      if (en) pre_cnt <= tick ? 16'b0 : pre_cnt + 16'd1;
      if (tick) count <= count + 32'd1;
      if (en && count == cmp) match <= 1'b1;
      if (wr) begin
        unique case (off)
          4'h0: count <= pwdata;
          4'h4: begin cmp <= pwdata; match <= 1'b0; end
          4'h8: begin en <= pwdata[0]; irq_en <= pwdata[1]; prescale <= pwdata[31:16]; pre_cnt <= 16'b0; end
          4'hC: if (pwdata[0]) match <= 1'b0;
          default: ;
        endcase
      end
    end
  end
endmodule
