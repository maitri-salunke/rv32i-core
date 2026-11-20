// apb_uart.sv - AMBA 3 APB UART peripheral (PREADY / PSLVERR)
// Author: Maitri Salunke
//
// Register map: see docs/REGISTERS.md
//   0x00 DATA      W: push TX FIFO   R: pop RX FIFO
//   0x04 STATUS    RO FIFO flags/levels, TX busy
//   0x08 CTRL      RW enables, parity, loopback; W1 FIFO clears
//   0x0C BAUD      RW 16-bit divisor (bit = 16*(DIV+1) PCLK cycles)
//   0x10 INT_EN    RW interrupt enables
//   0x14 INT_STAT  level bits RO, sticky error bits W1C
//   0x18 RX_THR    RW RX FIFO level threshold for the RX interrupt
// Any other address -> PSLVERR. Writes to STATUS -> PSLVERR.
// Every access is extended by WAIT_STATES cycles of PREADY = 0.
module apb_uart #(
  parameter int          ADDR_W      = 12,
  parameter int          FIFO_DEPTH  = 16,
  parameter int          WAIT_STATES = 1,
  parameter logic [15:0] BAUD_RESET  = 16'd26,
  localparam int         LW          = $clog2(FIFO_DEPTH + 1)
) (
  input  logic              pclk,
  input  logic              presetn,
  // APB slave
  input  logic              psel,
  input  logic              penable,
  input  logic              pwrite,
/* verilator lint_off UNUSEDSIGNAL */
  input  logic [ADDR_W-1:0] paddr,     // [1:0] ignored (word aligned)
  input  logic [31:0]       pwdata,    // upper bits ignored by narrow registers
/* verilator lint_on UNUSEDSIGNAL */
  output logic [31:0]       prdata,
  output logic              pready,
  output logic              pslverr,
  // serial
  input  logic              rxd,
  output logic              txd,
  // interrupt (level, active high)
  output logic              irq
);

  // ---------------------------------------------------------------- addresses
  localparam logic [4:0] A_DATA = 5'h00, A_STATUS = 5'h04, A_CTRL   = 5'h08,
                         A_BAUD = 5'h0C, A_INT_EN = 5'h10, A_INT_ST = 5'h14,
                         A_RXTHR = 5'h18;

  // ---------------------------------------------------------------- APB timing
  localparam int WW = (WAIT_STATES > 0) ? $clog2(WAIT_STATES + 1) : 1;
  logic [WW-1:0] wcnt;
  wire access = psel && penable;

  always_ff @(posedge pclk or negedge presetn) begin
    if (!presetn)                wcnt <= '0;
    else if (access && !pready)  wcnt <= wcnt + 1'b1;
    else                         wcnt <= '0;
  end

`ifdef MUT_PREADY_HANG
  // MUTATION: never complete a write to RX_THR
  assign pready = (wcnt == WW'(WAIT_STATES)) &&
                  !(psel && pwrite && paddr[4:0] == A_RXTHR);
`else
  assign pready = (wcnt == WW'(WAIT_STATES));
`endif

  wire [4:0] reg_addr  = {paddr[4:2], 2'b00};
  wire       hi_zero   = (ADDR_W <= 5) ? 1'b1 : (paddr[ADDR_W-1:5] == '0);
  wire       mapped    = hi_zero && (reg_addr <= A_RXTHR);
  wire       ro_write  = pwrite && (reg_addr == A_STATUS);
`ifdef MUT_NO_PSLVERR
  wire       err       = ro_write;                  // MUTATION: unmapped accepted
`else
  wire       err       = !mapped || ro_write;
`endif
  wire       xfer      = access && pready;          // completing transfer
  wire       wr_ok     = xfer &&  pwrite && !err;
  wire       rd_ok     = xfer && !pwrite && !err;

  assign pslverr = xfer && err;

  // ---------------------------------------------------------------- registers
  logic        tx_en, rx_en, par_en, par_odd, loopback;
  logic [15:0] baud_div;
  logic [5:0]  int_en;
  logic        st_rx_ovf, st_frame, st_parity, st_tx_ovf;
  logic [LW-1:0] rx_thr;

  // FIFO / datapath wires
  logic          tx_full, tx_empty, rx_full, rx_empty;
  logic [LW-1:0] tx_level, rx_level;
  logic [7:0]    tx_head, rx_head;
  logic          tx_pop, tx_busy, tick16;
  logic          rx_valid, rx_ferr, rx_perr;
  logic [7:0]    rx_byte;
  logic          txd_int;

  wire wr_data   = wr_ok && (reg_addr == A_DATA);
  wire rd_data   = rd_ok && (reg_addr == A_DATA);
  wire wr_ctrl   = wr_ok && (reg_addr == A_CTRL);
  wire wr_baud   = wr_ok && (reg_addr == A_BAUD);
  wire wr_int_en = wr_ok && (reg_addr == A_INT_EN);
  wire wr_int_st = wr_ok && (reg_addr == A_INT_ST);
  wire wr_rxthr  = wr_ok && (reg_addr == A_RXTHR);

  wire tx_fifo_clr = wr_ctrl && pwdata[8];
  wire rx_fifo_clr = wr_ctrl && pwdata[9];

  wire rx_good   = rx_valid && !rx_ferr && !rx_perr;
`ifdef MUT_RX_OVF_NOSET
  wire rx_ovf_ev = 1'b0;                            // MUTATION: overflow never flagged
`else
  wire rx_ovf_ev = rx_good && rx_full && !rd_data;
`endif
  wire tx_ovf_ev = wr_data && tx_full && !tx_pop;

  always_ff @(posedge pclk or negedge presetn) begin
    if (!presetn) begin
`ifdef MUT_CTRL_RESET
      {loopback, par_odd, par_en, rx_en, tx_en} <= 5'b00001;  // MUTATION: wrong reset
`else
      {loopback, par_odd, par_en, rx_en, tx_en} <= 5'b00011;
`endif
      baud_div <= BAUD_RESET;
      int_en   <= '0;
      rx_thr   <= LW'(1);
    end else begin
      if (wr_ctrl)   {loopback, par_odd, par_en, rx_en, tx_en} <= pwdata[4:0];
      if (wr_baud)   baud_div <= pwdata[15:0];
      if (wr_int_en) int_en   <= pwdata[5:0];
      if (wr_rxthr)  rx_thr   <= pwdata[LW-1:0];
    end
  end

  // sticky status: set has priority over W1C clear in the same cycle
  always_ff @(posedge pclk or negedge presetn) begin
    if (!presetn) begin
      {st_tx_ovf, st_parity, st_frame, st_rx_ovf} <= '0;
    end else begin
`ifdef MUT_W1C_AS_RW
      // MUTATION: INT_STAT behaves as plain RW (write 0 clears)
      if (wr_int_st) {st_tx_ovf, st_parity, st_frame, st_rx_ovf} <= pwdata[5:2];
`else
      if (wr_int_st) begin
        if (pwdata[2]) st_rx_ovf <= 1'b0;
        if (pwdata[3]) st_frame  <= 1'b0;
        if (pwdata[4]) st_parity <= 1'b0;
        if (pwdata[5]) st_tx_ovf <= 1'b0;
      end
`endif
      if (rx_ovf_ev)                     st_rx_ovf <= 1'b1;
      if (rx_valid && rx_ferr)           st_frame  <= 1'b1;
      if (rx_valid && rx_perr && !rx_ferr) st_parity <= 1'b1;
      if (tx_ovf_ev)                     st_tx_ovf <= 1'b1;
    end
  end

`ifdef MUT_RX_THR_GT
  wire lvl_rx = (rx_level > rx_thr);                // MUTATION: > instead of >=
`else
  wire lvl_rx = (rx_level >= rx_thr);
`endif
  wire lvl_tx = tx_empty;

  wire [5:0] int_stat = {st_tx_ovf, st_parity, st_frame, st_rx_ovf, lvl_tx, lvl_rx};
  assign irq = |(int_stat & int_en);

  // ---------------------------------------------------------------- read mux
  logic [31:0] rmux;
  always_comb begin
    rmux = '0;
    unique case (reg_addr)
      A_DATA:   rmux = {24'h0, rx_empty ? 8'h00 : rx_head};
`ifdef MUT_STATUS_SWAP
      A_STATUS: rmux = {11'h0, 5'(rx_level), 3'h0, 5'(tx_level), 3'h0,
                        tx_busy, rx_empty, rx_full, tx_full, tx_empty};  // MUTATION
`else
      A_STATUS: rmux = {11'h0, 5'(rx_level), 3'h0, 5'(tx_level), 3'h0,
                        tx_busy, rx_empty, rx_full, tx_empty, tx_full};
`endif
      A_CTRL:   rmux = {27'h0, loopback, par_odd, par_en, rx_en, tx_en};
      A_BAUD:   rmux = {16'h0, baud_div};
      A_INT_EN: rmux = {26'h0, int_en};
      A_INT_ST: rmux = {26'h0, int_stat};
      A_RXTHR:  rmux = {27'h0, 5'(rx_thr)};
      default:  rmux = '0;
    endcase
  end
  assign prdata = (rd_ok) ? rmux : 32'h0;

  // ---------------------------------------------------------------- datapath
  uart_baud_gen u_baud (
    .clk(pclk), .rst_n(presetn), .restart(wr_baud),
    .divisor(baud_div), .tick16(tick16)
  );

  uart_fifo #(.WIDTH(8), .DEPTH(FIFO_DEPTH)) u_txf (
    .clk(pclk), .rst_n(presetn), .clr(tx_fifo_clr),
    .push(wr_data), .wdata(pwdata[7:0]), .pop(tx_pop), .rdata(tx_head),
    .full(tx_full), .empty(tx_empty), .level(tx_level)
  );

  uart_fifo #(.WIDTH(8), .DEPTH(FIFO_DEPTH)) u_rxf (
    .clk(pclk), .rst_n(presetn), .clr(rx_fifo_clr),
    .push(rx_good), .wdata(rx_byte), .pop(rd_data), .rdata(rx_head),
    .full(rx_full), .empty(rx_empty), .level(rx_level)
  );

  uart_tx u_tx (
    .clk(pclk), .rst_n(presetn), .tick16(tick16), .tx_en(tx_en),
    .parity_en(par_en), .parity_odd(par_odd),
    .fifo_empty(tx_empty), .fifo_data(tx_head), .fifo_pop(tx_pop),
    .txd(txd_int), .busy(tx_busy)
  );

`ifdef MUT_LOOPBACK_BROKEN
  wire rx_in = rxd;                                 // MUTATION: loopback ignored
`else
  wire rx_in = loopback ? txd_int : rxd;
`endif

  uart_rx u_rx (
    .clk(pclk), .rst_n(presetn), .tick16(tick16), .rx_en(rx_en),
    .parity_en(par_en), .parity_odd(par_odd), .rxd_async(rx_in),
    .rx_valid(rx_valid), .rx_data(rx_byte),
    .frame_err(rx_ferr), .parity_err(rx_perr)
  );

  assign txd = loopback ? 1'b1 : txd_int;

endmodule
