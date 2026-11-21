// tb_core.sv - Verilator (--binary --timing) testbench for rv32i_core.
//
// Harvard simulation memories (both preloaded with the same image), tohost
// based termination (riscv-tests convention), a putchar port for C programs,
// optional random data-memory back-pressure, and a Spike-format retire trace.
//
// Plusargs:
//   +hex=<file>        word-hex image for 0x8000_0000 (required)
//   +tohost=<hex>      tohost address (default 80001000)
//   +max_cycles=<n>    timeout (default 10,000,000)
//   +trace=<file>      write Spike --log-commits style retire trace
//   +pipetrace=<file>  write per-cycle stage occupancy (scripts/pipeview.py)
//   +stall_pct=<n>     % of dmem requests that see gnt=0 for a cycle (default 0)
//   +verilator+seed+<n> seed for stall injection
module tb_core;
  localparam int MEM_WORDS = 1 << 20;            // 4 MiB per memory
  localparam logic [31:0] MEM_BASE = 32'h8000_0000;
  localparam logic [31:0] CONSOLE  = 32'h1000_0000;

  logic clk = 1'b0;
  logic rst_n = 1'b0;
  always #5 clk = ~clk;

  logic        imem_en;
  logic [31:0] imem_addr, imem_rdata;
  logic        dmem_req, dmem_we, dmem_gnt;
  logic [31:0] dmem_addr, dmem_wdata, dmem_rdata;
  logic [3:0]  dmem_be;

  rv32i_core #(.RESET_PC(MEM_BASE)) u_core (
    .clk, .rst_n,
    .imem_en, .imem_addr, .imem_rdata,
    .dmem_req, .dmem_we, .dmem_addr, .dmem_be, .dmem_wdata, .dmem_gnt, .dmem_rdata,
    .irq_timer (1'b0)
  );

  logic [31:0] imem [MEM_WORDS];
  logic [31:0] dmem [MEM_WORDS];

  function automatic logic in_ram(input logic [31:0] a);
    return (a >= MEM_BASE) && (a < MEM_BASE + 4*MEM_WORDS);
  endfunction
  function automatic int widx(input logic [31:0] a);
    return int'((a - MEM_BASE) >> 2);
  endfunction

  // ---------------- instruction memory: sync read ----------------
  always_ff @(posedge clk) begin
    if (imem_en) imem_rdata <= in_ram(imem_addr) ? imem[widx(imem_addr)] : 32'h0000_0013;
  end

  // ---------------- data memory: sync read/write + random stalls ----------------
  int unsigned stall_pct = 0;
  logic [31:0] tohost = 32'h8000_1000;
  logic        stall_now;

  always_ff @(posedge clk) begin
    stall_now <= (stall_pct != 0) && (($urandom % 100) < stall_pct);
  end
  assign dmem_gnt = ~stall_now;

  longint unsigned cycles = 0;
  int exit_code = -1;
  int trace_fd = 0;
  int pipe_fd = 0;
  longint unsigned max_cycles = 10_000_000;

  always_ff @(posedge clk) begin
    if (rst_n && dmem_req && dmem_gnt) begin
      if (dmem_we) begin
        if (in_ram(dmem_addr)) begin
          for (int b = 0; b < 4; b++)
            if (dmem_be[b]) dmem[widx(dmem_addr)][8*b +: 8] <= dmem_wdata[8*b +: 8];
        end
        if (dmem_addr == CONSOLE) begin
          for (int b = 0; b < 4; b++)
            if (dmem_be[b]) $write("%c", dmem_wdata[8*b +: 8]);
          $fflush();
        end
        if (dmem_addr == tohost && dmem_wdata != 0 && exit_code < 0)
          exit_code = int'(dmem_wdata);
      end else begin
        dmem_rdata <= in_ram(dmem_addr) ? dmem[widx(dmem_addr)] : 32'b0;
      end
    end
  end

  // ---------------- retire trace (Spike --log-commits format) ----------------
  rv_tracer u_tracer (.clk(clk), .rst_n(rst_n), .fd(trace_fd));

  // ---------------- control ----------------
  string hexfile, tracefile, pipefile;
  initial begin
    if (!$value$plusargs("hex=%s", hexfile)) $fatal(1, "need +hex=<file>");
    void'($value$plusargs("tohost=%h", tohost));
    void'($value$plusargs("max_cycles=%d", max_cycles));
    void'($value$plusargs("stall_pct=%d", stall_pct));
    if ($value$plusargs("trace=%s", tracefile)) trace_fd = $fopen(tracefile, "w");
    if ($value$plusargs("pipetrace=%s", pipefile)) pipe_fd = $fopen(pipefile, "w");
    $readmemh(hexfile, imem);
    $readmemh(hexfile, dmem);
    repeat (3) @(posedge clk);
    rst_n = 1'b1;
  end

  // ---------------- hazard coverage counters ----------------
  longint unsigned c_retire = 0, c_lu = 0, c_fwd_mem = 0, c_fwd_wb = 0, c_redirect = 0,
                   c_taken = 0, c_trap = 0, c_mstall = 0, c_fwd_stall = 0, c_irq = 0,
                   c_mispred = 0, c_idpred = 0, c_jalr = 0;
  always @(posedge clk) if (rst_n && exit_code < 0) begin
    if (u_core.wb_valid) c_retire++;
    if (u_core.load_use) c_lu++;
    if (u_core.ex_valid && !u_core.stall_mem && (u_core.fwd_a_sel == 1 || u_core.fwd_b_sel == 1)) c_fwd_mem++;
    if (u_core.ex_valid && !u_core.stall_mem && (u_core.fwd_a_sel == 2 || u_core.fwd_b_sel == 2)) c_fwd_wb++;
    if (u_core.redirect) c_redirect++;
    // taken = architecturally taken branches/jumps; mispred = EX control
    // redirects (2-cycle); id_pred = ID predecode redirects (1-cycle)
    if (u_core.ex_valid && !u_core.stall_mem && u_core.jump_taken && !u_core.ex_trap) c_taken++;
    if (u_core.redirect && !u_core.ex_trap && !u_core.ex_mret_go) c_mispred++;
    if (u_core.id_pred && !u_core.stall_id && !u_core.redirect) c_idpred++;
    if (u_core.redirect && !u_core.ex_trap && !u_core.ex_mret_go && u_core.ex_is_jalr) c_jalr++;
    if (u_core.ex_trap && !u_core.stall_mem) c_trap++;
    if (u_core.stall_mem) c_mstall++;
    if (u_core.stall_mem && u_core.ex_valid && (u_core.fwd_a_sel != 0 || u_core.fwd_b_sel != 0)) c_fwd_stall++;
  end

  int drain = 0;

  // ---------------- optional per-cycle pipeline trace (+pipetrace=<file>) ----------------
  // One line per cycle, values sampled before the clock edge:
  //   <cycle> <pc_f> <imem_en> <id_v> <id_pc> <ex_v> <ex_pc> <mem_v> <mem_pc>
  //   <wb_v> <wb_pc> <fwd_a> <fwd_b> <load_use> <redirect> <id_pred> <stall_mem>
  always @(posedge clk) if (rst_n && pipe_fd != 0 && drain < 4 && cycles < max_cycles) begin
    $fwrite(pipe_fd, "%0d %08x %0d %0d %08x %0d %08x %0d %08x %0d %08x %0d %0d %0d %0d %0d %0d\n",
            cycles, u_core.pc_f, u_core.imem_en, u_core.id_valid, u_core.id_pc,
            u_core.ex_valid, u_core.ex_pc, u_core.mem_valid, u_core.mem_pc,
            u_core.wb_valid, u_core.wb_pc, u_core.fwd_a_sel, u_core.fwd_b_sel,
            u_core.load_use, u_core.redirect, u_core.id_pred, u_core.stall_mem);
  end

  always @(posedge clk) begin
    if (rst_n && exit_code < 0) cycles <= cycles + 1;
    if (exit_code >= 0) drain <= drain + 1;
    // run a few extra cycles so the tohost store itself reaches WB / the trace
    if (exit_code >= 0 && drain == 4) begin
      // let the tohost store drain from the trace, then report
      if (trace_fd != 0) $fclose(trace_fd);
      if (pipe_fd != 0) $fclose(pipe_fd);
      $display("");
      $display("TOHOST=%0d cycles=%0d", exit_code, cycles);
      $display("COV retired=%0d load_use=%0d fwd_mem=%0d fwd_wb=%0d redirect=%0d taken=%0d mispred=%0d jalr=%0d id_pred=%0d trap=%0d mem_stall=%0d fwd_during_stall=%0d",
               c_retire, c_lu, c_fwd_mem, c_fwd_wb, c_redirect, c_taken, c_mispred, c_jalr, c_idpred, c_trap, c_mstall, c_fwd_stall);
      if (exit_code == 1) $display("RESULT: PASS");
      else                $display("RESULT: FAIL (test %0d)", exit_code >> 1);
      $finish;
    end
    if (cycles >= max_cycles) begin
      if (trace_fd != 0) $fclose(trace_fd);
      if (pipe_fd != 0) $fclose(pipe_fd);
      $display("RESULT: TIMEOUT after %0d cycles (pc_f=%08x)", cycles, u_core.pc_f);
      $finish;
    end
  end
endmodule
