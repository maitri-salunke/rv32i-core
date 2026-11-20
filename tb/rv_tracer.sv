// rv_tracer.sv - prints one line per retired instruction in the same format as
// `spike --log-commits`, using hierarchical references into the core's WB stage.
//   core   0: 3 0x<pc> (0x<insn>) [x<rd> 0x<val>] [mem 0x<addr> [0x<sdata>]]
module rv_tracer (
  input logic clk,
  input logic rst_n,
  input int   fd
);
  logic        v, rd_we, is_load, is_store;
  logic [31:0] pc, insn, val, addr, sraw;
  logic [4:0]  rd;
  logic [2:0]  f3;

  assign v        = tb_core.u_core.wb_valid;
  assign pc       = tb_core.u_core.wb_pc;
  assign insn     = tb_core.u_core.wb_insn_t;
  assign rd_we    = tb_core.u_core.wb_rd_we;
  assign rd       = tb_core.u_core.wb_rd;
  assign val      = tb_core.u_core.wb_value;
  assign is_load  = tb_core.u_core.wb_is_load;
  assign is_store = tb_core.u_core.wb_is_store_t;
  assign addr     = tb_core.u_core.wb_result;
  assign sraw     = tb_core.u_core.wb_st_raw_t;
  assign f3       = tb_core.u_core.wb_funct3;

  always @(posedge clk) begin
    if (rst_n && fd != 0 && v) begin
      $fwrite(fd, "core   0: 3 0x%08x (0x%08x)", pc, insn);
      if (rd_we && rd != 5'd0) begin
        if (rd < 10) $fwrite(fd, " x%0d  0x%08x", rd, val);
        else         $fwrite(fd, " x%0d 0x%08x", rd, val);
      end
      if (is_load) $fwrite(fd, " mem 0x%08x", addr);
      if (is_store) begin
        case (f3[1:0])
          2'b00:   $fwrite(fd, " mem 0x%08x 0x%02x", addr, sraw[7:0]);
          2'b01:   $fwrite(fd, " mem 0x%08x 0x%04x", addr, sraw[15:0]);
          default: $fwrite(fd, " mem 0x%08x 0x%08x", addr, sraw);
        endcase
      end
      $fwrite(fd, "\n");
    end
  end
endmodule
