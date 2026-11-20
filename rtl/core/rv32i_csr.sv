// rv32i_csr.sv - minimal machine-mode Zicsr + trap CSRs.
//
// Implemented: mstatus(MIE,MPIE; MPP=M hard-wired), misa(RO), mie(MSIE/MTIE/MEIE),
// mtvec(direct), mscratch, mepc, mcause, mtval, mip(MTIP, RO), mcycle[h],
// minstret[h], cycle[h]/instret[h] (RO shadows), mvendorid/marchid/mimpid/
// mhartid (RO zero). Any other address raises illegal-instruction.
//
// CSR instructions execute in EX. Every instruction older than EX is already
// guaranteed to retire (nothing after EX can fault), so reading/writing here is
// precise. instret is read as minstret + instructions in MEM/WB, which makes a
// read in EX equal to the architectural count of instructions retired before it.
module rv32i_csr
(
  input  logic        clk,
  input  logic        rst_n,

  // CSR access from EX
  input  logic [11:0] addr,
  input  logic [1:0]  op,        // funct3[1:0]: 01=W, 10=S, 11=C
  input  logic [31:0] src,       // rs1 value or zimm
  input  logic        wr_req,    // instruction intends to write (W, or S/C with rs1!=0)
  input  logic        csr_we,    // commit the write this cycle
  output logic [31:0] rdata,
  output logic        illegal,

  // trap / return
  input  logic        trap_take,
  input  logic        trap_irq,
  input  logic [3:0]  trap_cause,
  /* verilator lint_off UNUSEDSIGNAL */
  input  logic [31:0] trap_epc,     // [1:0] ignored (IALIGN=32)
  /* verilator lint_on UNUSEDSIGNAL */
  input  logic [31:0] trap_tval,
  input  logic        mret_take,
  output logic [31:0] mtvec_o,
  output logic [31:0] mepc_o,

  // interrupts
  input  logic        irq_timer,
  output logic        irq_pending,

  // counters
  input  logic        retire,     // an instruction retires in WB this cycle
  input  logic        mem_valid,  // a valid instruction is in MEM
  input  logic        wb_valid    // a valid instruction is in WB
);
  `include "rv32i_defs.svh"

  logic        mstatus_mie, mstatus_mpie;
  logic        mie_msie, mie_mtie, mie_meie;
  logic [31:0] mtvec, mscratch, mepc, mtval;
  logic        mcause_irq;
  logic [3:0]  mcause_code;
  logic [63:0] mcycle, minstret;
  logic [63:0] instret_arch, instret_adj;
  logic [1:0]  inflight;
  logic [31:0] mstatus_v, mie_v, mip_v, mcause_v;
  logic [31:0] wdata;
  logic        known, read_only;

  assign inflight     = {1'b0, mem_valid} + {1'b0, wb_valid};
  assign instret_arch = minstret + {62'b0, inflight};
  // after the write edge: the MEM instruction (moving to WB) and the writer
  // itself will each still increment minstret once.
  assign instret_adj  = {63'b0, mem_valid} + 64'd1;
  assign mstatus_v = {19'b0, 2'b11, 3'b0, mstatus_mpie, 3'b0, mstatus_mie, 3'b0};
  assign mie_v     = {20'b0, mie_meie, 3'b0, mie_mtie, 3'b0, mie_msie, 3'b0};
  assign mip_v     = {24'b0, irq_timer, 7'b0};
  assign mcause_v  = {mcause_irq, 27'b0, mcause_code};

  assign mtvec_o     = mtvec;
  assign mepc_o      = mepc;
  assign irq_pending = mstatus_mie & mie_mtie & irq_timer;

  // ---------------- read mux ----------------
  always_comb begin
    known = 1'b1;
    rdata = 32'b0;
    unique case (addr)
      CSR_MSTATUS:   rdata = mstatus_v;
      CSR_MISA:      rdata = 32'h4000_0100;           // MXL=1 (32-bit), 'I'
      CSR_MIE:       rdata = mie_v;
      CSR_MTVEC:     rdata = mtvec;
      CSR_MSCRATCH:  rdata = mscratch;
      CSR_MEPC:      rdata = mepc;
      CSR_MCAUSE:    rdata = mcause_v;
      CSR_MTVAL:     rdata = mtval;
      CSR_MIP:       rdata = mip_v;
      CSR_MCYCLE,   CSR_CYCLE:    rdata = mcycle[31:0];
      CSR_MCYCLEH,  CSR_CYCLEH:   rdata = mcycle[63:32];
      CSR_MINSTRET, CSR_INSTRET:  rdata = instret_arch[31:0];
      CSR_MINSTRETH,CSR_INSTRETH: rdata = instret_arch[63:32];
      CSR_MVENDORID, CSR_MARCHID, CSR_MIMPID, CSR_MHARTID: rdata = 32'b0;
      default: known = 1'b0;
    endcase
  end

  assign read_only = (addr[11:10] == 2'b11);
  assign illegal   = ~known | (read_only & wr_req);

  always_comb begin
    unique case (op)
      2'b10:   wdata = rdata | src;
      2'b11:   wdata = rdata & ~src;
      default: wdata = src;
    endcase
  end

  // ---------------- state ----------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      mstatus_mie  <= 1'b0;
      mstatus_mpie <= 1'b0;
      mie_msie     <= 1'b0;
      mie_mtie     <= 1'b0;
      mie_meie     <= 1'b0;
      mtvec        <= 32'b0;
      mscratch     <= 32'b0;
      mepc         <= 32'b0;
      mtval        <= 32'b0;
      mcause_irq   <= 1'b0;
      mcause_code  <= 4'b0;
      mcycle       <= 64'b0;
      minstret     <= 64'b0;
    end else begin
      // free-running counters (a CSR write below takes precedence)
      mcycle <= mcycle + 64'd1;
      if (retire) minstret <= minstret + 64'd1;

      if (trap_take) begin
        mepc         <= {trap_epc[31:2], 2'b00};
        mcause_irq   <= trap_irq;
        mcause_code  <= trap_cause;
        mtval        <= trap_tval;
        mstatus_mpie <= mstatus_mie;
        mstatus_mie  <= 1'b0;
      end else if (mret_take) begin
        mstatus_mie  <= mstatus_mpie;
        mstatus_mpie <= 1'b1;
      end else if (csr_we) begin
        unique case (addr)
          CSR_MSTATUS: begin
            mstatus_mie  <= wdata[3];
            mstatus_mpie <= wdata[7];
          end
          CSR_MIE: begin
            mie_msie <= wdata[3];
            mie_mtie <= wdata[7];
            mie_meie <= wdata[11];
          end
          CSR_MTVEC:    mtvec    <= {wdata[31:2], 2'b00};
          CSR_MSCRATCH: mscratch <= wdata;
          CSR_MEPC:     mepc     <= {wdata[31:2], 2'b00};
          CSR_MCAUSE: begin
            mcause_irq  <= wdata[31];
            mcause_code <= wdata[3:0];
          end
          CSR_MTVAL:    mtval    <= wdata;
          CSR_MCYCLE:   mcycle   <= {mcycle[63:32], wdata};
          CSR_MCYCLEH:  mcycle   <= {wdata, mcycle[31:0]};
          // A write to instret takes precedence over the writing instruction's
          // own increment. The writer and the instruction ahead of it in MEM
          // will still bump the register as they retire, so pre-compensate.
          CSR_MINSTRET:  minstret <= {instret_arch[63:32], wdata} - instret_adj;
          CSR_MINSTRETH: minstret <= {wdata, instret_arch[31:0]} - instret_adj;
          default: ;
        endcase
      end
    end
  end

endmodule
