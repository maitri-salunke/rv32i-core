// uart_baud_gen.sv - 16x oversampling tick generator
// Author: Maitri Salunke
//
// tick16 pulses once every (divisor + 1) clock cycles, so one UART bit lasts
// 16 * (divisor + 1) clocks. Example: 50 MHz clock, divisor 26 -> 115 741 baud.
// A write to the BAUD register restarts the count (restart input).
module uart_baud_gen (
  input  logic        clk,
  input  logic        rst_n,
  input  logic        restart,
  input  logic [15:0] divisor,
  output logic        tick16
);
  logic [15:0] cnt;

`ifdef MUT_BAUD_OFF_BY_ONE
  // MUTATION: terminal count one short (period = divisor clocks, min 1)
  wire terminal = (cnt + 16'd1 >= divisor);
`else
  wire terminal = (cnt >= divisor);
`endif

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      cnt    <= '0;
      tick16 <= 1'b0;
    end else if (restart) begin
      cnt    <= '0;
      tick16 <= 1'b0;
    end else if (terminal) begin
      cnt    <= '0;
      tick16 <= 1'b1;
    end else begin
      cnt    <= cnt + 16'd1;
      tick16 <= 1'b0;
    end
  end
endmodule
