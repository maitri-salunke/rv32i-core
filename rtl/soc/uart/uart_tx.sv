// uart_tx.sv - UART transmitter (start, 8 data LSB first, optional parity, 1 stop)
// Author: Maitri Salunke
//
// A new frame starts only on a tick16 boundary so every bit, including the
// start bit, is exactly 16 ticks long.
module uart_tx (
  input  logic       clk,
  input  logic       rst_n,
  input  logic       tick16,
  input  logic       tx_en,
  input  logic       parity_en,
  input  logic       parity_odd,
  input  logic       fifo_empty,
  input  logic [7:0] fifo_data,
  output logic       fifo_pop,
  output logic       txd,
  output logic       busy
);
  typedef enum logic [2:0] {S_IDLE, S_START, S_DATA, S_PARITY, S_STOP} state_t;
  state_t     state;
  logic [3:0] tcnt;     // ticks within current bit
  logic [2:0] bitidx;
  logic [7:0] shreg;
  logic       par;

  wire last_tick = tick16 && (tcnt == 4'd15);
  wire load      = (state == S_IDLE) && tx_en && !fifo_empty && tick16;

  assign fifo_pop = load;
  assign busy     = (state != S_IDLE);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state  <= S_IDLE;
      tcnt   <= '0;
      bitidx <= '0;
      shreg  <= '0;
      par    <= 1'b0;
      txd    <= 1'b1;
    end else begin
      if (tick16 && state != S_IDLE) tcnt <= tcnt + 4'd1;
      unique case (state)
        S_IDLE: begin
          txd <= 1'b1;
          if (load) begin
            state  <= S_START;
            shreg  <= fifo_data;
`ifdef MUT_PARITY_INV
            par    <= ~(^fifo_data ^ parity_odd);   // MUTATION: parity sense inverted
`else
            par    <= ^fifo_data ^ parity_odd;
`endif
            tcnt   <= '0;
            txd    <= 1'b0;
          end
        end
        S_START: if (last_tick) begin
          state  <= S_DATA;
          bitidx <= '0;
`ifdef MUT_TX_MSB_FIRST
          txd    <= shreg[7];                       // MUTATION: MSB first
`else
          txd    <= shreg[0];
`endif
        end
        S_DATA: if (last_tick) begin
          if (bitidx == 3'd7) begin
            if (parity_en) begin
              state <= S_PARITY;
              txd   <= par;
            end else begin
              state <= S_STOP;
              txd   <= 1'b1;
            end
          end else begin
            bitidx <= bitidx + 3'd1;
`ifdef MUT_TX_MSB_FIRST
            txd    <= shreg[3'd6 - bitidx];
`else
            txd    <= shreg[bitidx + 3'd1];
`endif
          end
        end
        S_PARITY: if (last_tick) begin
          state <= S_STOP;
          txd   <= 1'b1;
        end
`ifdef MUT_TX_STOP_SHORT
        S_STOP: if (tick16 && tcnt == 4'd7) begin   // MUTATION: half-length stop bit
          state <= S_IDLE;
          tcnt  <= '0;
        end
`else
        S_STOP: if (last_tick) begin
          state <= S_IDLE;
        end
`endif
        default: state <= S_IDLE;
      endcase
    end
  end
endmodule
