// tb_soc.sv - SoC smoke test bench. Loads the same image into the I and D
// RAMs, decodes the UART txd line bit-by-bit (8N1) and prints the characters,
// and ends on a store to tohost.
module tb_soc;
  logic clk = 1'b0, rst_n = 1'b0;
  always #5 clk = ~clk;
  logic txd, uart_irq, apb_err;

  soc_top u_soc (.clk, .rst_n, .uart_rxd(1'b1), .uart_txd(txd), .uart_irq, .apb_err);

  string hexfile;
  logic [31:0] tohost = 32'h8000_1000;
  longint unsigned cycles = 0;
  int exit_code = -1;
  int nchars = 0;

  initial begin
    if (!$value$plusargs("hex=%s", hexfile)) $fatal(1, "need +hex=");
    void'($value$plusargs("tohost=%h", tohost));
    $readmemh(hexfile, u_soc.u_imem.mem);
    $readmemh(hexfile, u_soc.u_dmem.mem);
    repeat (3) @(posedge clk);
    rst_n = 1'b1;
  end

  // ---- tohost ----
  always @(posedge clk) begin
    cycles <= cycles + 1;
    if (rst_n && u_soc.dmem_req && u_soc.dmem_gnt && u_soc.dmem_we && u_soc.dmem_addr == tohost
        && u_soc.dmem_wdata != 0 && exit_code < 0)
      exit_code = int'(u_soc.dmem_wdata);
    if (exit_code >= 0) begin
      $display("\n[tb_soc] TOHOST=%0d after %0d cycles, %0d UART chars decoded", exit_code, cycles, nchars);
      if (exit_code == 1) $display("RESULT: PASS");
      else                $display("RESULT: FAIL");
      $finish;
    end
    if (cycles > 5_000_000) begin $display("RESULT: TIMEOUT"); $finish; end
  end

  // ---- UART receiver model on txd (bit period = 16*(BAUD+1) clocks) ----
  initial begin : uart_rx_model
    int bit_t; logic [7:0] ch;
    forever begin
      @(negedge txd);
      bit_t = 16 * (int'(u_soc.u_uart.baud_div) + 1);
      repeat (bit_t + bit_t / 2) @(posedge clk);   // middle of bit 0
      for (int i = 0; i < 8; i++) begin
        ch[i] = txd;
        repeat (bit_t) @(posedge clk);
      end
      if (txd !== 1'b1) $display("[tb_soc] UART framing error");
      $write("%c", ch); $fflush();
      nchars++;
    end
  end
`ifdef APB_MON
  // debug: +define+APB_MON prints every completed APB transfer
  always @(posedge clk) if (u_soc.psel && u_soc.penable && u_soc.pready)
    $display("[apb] %0d %s a=%08x w=%08x r=%08x err=%0d", cycles, u_soc.pwrite ? "WR" : "RD",
             u_soc.paddr, u_soc.pwdata, u_soc.prdata, u_soc.pslverr);
  always @(posedge clk) if (u_soc.u_core.wb_valid && u_soc.u_core.wb_is_load && u_soc.rsel_apb_q)
    $display("[apb]    WB load value %08x", u_soc.u_core.wb_value);
  always @(posedge clk) if (u_soc.u_uart.tx_pop)
    $display("[uart] %0d tx pop %02x '%c'", cycles, u_soc.u_uart.tx_head, u_soc.u_uart.tx_head);
`endif
endmodule
