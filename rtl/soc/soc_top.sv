// soc_top.sv - tiny SoC: rv32i_core + Harvard RAMs + APB bridge + UART + timer.
//
// Memory map (data side):
//   0x8000_0000 - 0x8000_FFFF  data RAM (64 KiB)    1-cycle, no wait
//   0x1000_0000 - 0x1000_0FFF  APB UART  (apb_uart, copied from ../apb-uart-uvm)
//   0x1000_1000 - 0x1000_1FFF  APB timer (apb_timer)
// Instruction side: 64 KiB instruction RAM at 0x8000_0000.
// The timer interrupt drives mip.MTIP; the UART interrupt is exported.
module soc_top #(
  parameter string IMEM_INIT = "",
  parameter string DMEM_INIT = ""
)(
  input  logic clk,
  input  logic rst_n,
  input  logic uart_rxd,
  output logic uart_txd,
  output logic uart_irq,
  output logic apb_err
);
  logic        imem_en, dmem_req, dmem_we, dmem_gnt;
  /* verilator lint_off UNUSEDSIGNAL */
  logic [31:0] imem_addr;            // 64 KiB: only [15:2] decoded
  /* verilator lint_on UNUSEDSIGNAL */
  logic [31:0] imem_rdata, dmem_addr, dmem_wdata, dmem_rdata;
  logic [3:0]  dmem_be;
  logic        timer_irq;

  rv32i_core u_core (
    .clk, .rst_n,
    .imem_en, .imem_addr, .imem_rdata,
    .dmem_req, .dmem_we, .dmem_addr, .dmem_be, .dmem_wdata, .dmem_gnt, .dmem_rdata,
    .irq_timer (timer_irq)
  );

  // ---------------- instruction RAM ----------------
  soc_ram #(.WORDS(16384), .INIT(IMEM_INIT)) u_imem (
    .clk, .en(imem_en), .we(1'b0), .be(4'b0), .addr(imem_addr[15:2]),
    .wdata(32'b0), .rdata(imem_rdata)
  );

  // ---------------- data-side decode ----------------
  logic sel_ram, sel_apb, rsel_apb_q;
  logic [31:0] ram_rdata, apb_rdata;
  logic        apb_gnt;

  assign sel_ram  = (dmem_addr[31:16] == 16'h8000);
  assign sel_apb  = (dmem_addr[31:16] == 16'h1000);
  assign dmem_gnt = sel_apb ? apb_gnt : 1'b1;   // unmapped: accept, read 0

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) rsel_apb_q <= 1'b0;
    else if (dmem_req && dmem_gnt) rsel_apb_q <= sel_apb;
  end
  assign dmem_rdata = rsel_apb_q ? apb_rdata : ram_rdata;

  soc_ram #(.WORDS(16384), .INIT(DMEM_INIT)) u_dmem (
    .clk, .en(dmem_req & sel_ram), .we(dmem_we), .be(dmem_be), .addr(dmem_addr[15:2]),
    .wdata(dmem_wdata), .rdata(ram_rdata)
  );

  // ---------------- APB ----------------
  logic        psel, penable, pwrite;
  /* verilator lint_off UNUSEDSIGNAL */
  logic [31:0] paddr;                // APB window: [15:12] selects slave
  /* verilator lint_on UNUSEDSIGNAL */
  logic [31:0] pwdata, prdata;
  logic        pready, pslverr;
  logic        psel_uart, psel_tmr;
  logic [31:0] prdata_uart, prdata_tmr;
  logic        pready_uart, pready_tmr, pslverr_uart, pslverr_tmr;

  apb_bridge u_bridge (
    .clk, .rst_n,
    .req(dmem_req & sel_apb), .we(dmem_we), .addr(dmem_addr), .wdata(dmem_wdata),
    .gnt(apb_gnt), .rdata(apb_rdata), .err_o(apb_err),
    .psel, .penable, .pwrite, .paddr, .pwdata, .prdata, .pready, .pslverr
  );

  assign psel_uart = psel & (paddr[15:12] == 4'h0);
  assign psel_tmr  = psel & (paddr[15:12] == 4'h1);
  assign prdata    = psel_tmr ? prdata_tmr  : prdata_uart;
  assign pready    = psel_tmr ? pready_tmr  : (psel_uart ? pready_uart : 1'b1);
  assign pslverr   = psel_tmr ? pslverr_tmr : (psel_uart ? pslverr_uart : psel);

  apb_uart #(.ADDR_W(12), .FIFO_DEPTH(16), .WAIT_STATES(1), .BAUD_RESET(16'd26)) u_uart (
    .pclk(clk), .presetn(rst_n),
    .psel(psel_uart), .penable, .pwrite, .paddr(paddr[11:0]), .pwdata,
    .prdata(prdata_uart), .pready(pready_uart), .pslverr(pslverr_uart),
    .rxd(uart_rxd), .txd(uart_txd), .irq(uart_irq)
  );

  apb_timer u_timer (
    .pclk(clk), .presetn(rst_n),
    .psel(psel_tmr), .penable, .pwrite, .paddr(paddr[11:0]), .pwdata,
    .prdata(prdata_tmr), .pready(pready_tmr), .pslverr(pslverr_tmr),
    .irq(timer_irq)
  );
endmodule
