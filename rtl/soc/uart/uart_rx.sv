// uart_rx.sv - UART receiver with 2-flop synchronizer, 16x oversampling and
// 3-sample majority vote at mid-bit.
// Author: Maitri Salunke
//
// rxd_async comes from another clock domain (the remote transmitter), so it
// passes through a two-flop synchronizer before any logic looks at it. A
// falling edge on the synchronized line while idle starts a frame; the start
// bit is re-checked at mid-bit (7th/8th/9th tick of the bit, majority of 3) to reject glitches. The stop bit
// is checked at its middle and the receiver returns to idle immediately, which
// gives half a bit of slack for back-to-back frames with baud mismatch.
module uart_rx (
  input  logic       clk,
  input  logic       rst_n,
  input  logic       tick16,
  input  logic       rx_en,
  input  logic       parity_en,
  input  logic       parity_odd,
  input  logic       rxd_async,
  output logic       rx_valid,     // one-cycle pulse: frame finished
  output logic [7:0] rx_data,
  output logic       frame_err,    // qualifies rx_valid
  output logic       parity_err    // qualifies rx_valid
);
  typedef enum logic [2:0] {S_IDLE, S_START, S_DATA, S_PARITY, S_STOP} state_t;
  state_t     state;
  logic       sync1, sync2, prev;
  logic [3:0] tcnt;
  logic [2:0] bitidx;
  logic       s7, s8;      // earlier two of the three mid-bit samples
  logic       par_bit;

  // two-flop synchronizer (reset to idle-high)
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      sync1 <= 1'b1;
      sync2 <= 1'b1;
      prev  <= 1'b1;
    end else begin
      sync1 <= rxd_async;
      sync2 <= sync1;
      prev  <= sync2;
    end
  end

  wire maj        = (s7 & s8) | (s7 & sync2) | (s8 & sync2);
  wire sample_now = tick16 && (tcnt == 4'd8);
  wire bit_end    = tick16 && (tcnt == 4'd15);
  wire exp_par    = ^rx_data ^ parity_odd;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state      <= S_IDLE;
      tcnt       <= '0;
      bitidx     <= '0;
      s7         <= 1'b1;
      s8         <= 1'b1;
      rx_data    <= '0;
      par_bit    <= 1'b0;
      rx_valid   <= 1'b0;
      frame_err  <= 1'b0;
      parity_err <= 1'b0;
    end else begin
      rx_valid   <= 1'b0;
      frame_err  <= 1'b0;
      parity_err <= 1'b0;
      if (tick16 && state != S_IDLE) begin
        tcnt <= tcnt + 4'd1;
        if (tcnt == 4'd6) s7 <= sync2;
        if (tcnt == 4'd7) s8 <= sync2;
      end
      unique case (state)
        S_IDLE: begin
          tcnt <= '0;
          if (rx_en && prev && !sync2) state <= S_START;
        end
        S_START: begin
          if (sample_now && maj) state <= S_IDLE;      // glitch: false start
          else if (bit_end) begin
            state  <= S_DATA;
            bitidx <= '0;
          end
        end
        S_DATA: begin
          if (sample_now) rx_data <= {maj, rx_data[7:1]};   // LSB first
          if (bit_end) begin
            if (bitidx == 3'd7) state <= parity_en ? S_PARITY : S_STOP;
            else                bitidx <= bitidx + 3'd1;
          end
        end
        S_PARITY: begin
          if (sample_now) par_bit <= maj;
          if (bit_end)    state   <= S_STOP;
        end
        S_STOP: begin
          if (sample_now) begin
            state      <= S_IDLE;
            rx_valid   <= 1'b1;
`ifdef MUT_RX_NO_FRAME_CHECK
            frame_err  <= 1'b0;                        // MUTATION: stop bit ignored
`else
            frame_err  <= !maj;
`endif
            parity_err <= parity_en && (par_bit != exp_par);
          end
        end
        default: state <= S_IDLE;
      endcase
    end
  end
endmodule
