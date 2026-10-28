// Single-cycle RV32I core: every instruction completes in one clock.
// It is the simple, obviously-correct reference for the pipelined core, and the baseline for the
// single-cycle vs pipelined comparison (its critical path runs fetch -> decode -> ALU -> memory
// -> writeback in one cycle, so it clocks much slower).
//
// Memory ports are asynchronous-read / synchronous-write. The rvfi_* outputs describe the
// instruction retiring this cycle (pc, result, store) for the testbench's golden-model check.
module core_single
#(
  parameter logic [31:0] RESET_PC = 32'h0000_0000
) (
  input  logic        clk,
  input  logic        rst,

  output logic [31:0] imem_addr,
  input  logic [31:0] imem_rdata,

  output logic [31:0] dmem_addr,
  output logic        dmem_re,
  output logic [3:0]  dmem_wstrb,
  output logic [31:0] dmem_wdata,
  input  logic [31:0] dmem_rdata,

  output logic        halted,

  output logic        rvfi_valid,
  output logic [31:0] rvfi_pc,
  output logic [31:0] rvfi_insn,
  output logic [1:0]  rvfi_trap,
  output logic [4:0]  rvfi_rd,
  output logic [31:0] rvfi_rd_wdata,
  output logic [31:0] rvfi_mem_addr,
  output logic        rvfi_mem_re,
  output logic [3:0]  rvfi_mem_wstrb,
  output logic [31:0] rvfi_mem_wdata,

  output logic        perf_stall,
  output logic        perf_flush,
  output logic        perf_branch
);
  `include "rv32i_defs.svh"

  logic [31:0] pc, insn;
  assign imem_addr = pc;
  assign insn      = imem_rdata;

  // ---- decode ----
  logic [4:0]  rs1, rs2, rd;
  logic        uses_rs1, uses_rs2, reg_we, b_imm, mem_re, mem_we;
  logic        is_branch, is_jal, is_jalr, is_halt, illegal;
  logic [2:0]  imm_fmt, mem_funct3;
  logic [3:0]  alu_op;
  logic [1:0]  a_sel, wb_sel;
  logic [31:0] imm;

  decoder u_dec (
    .insn, .rs1, .rs2, .rd, .uses_rs1, .uses_rs2, .reg_we, .imm_fmt, .alu_op, .a_sel, .b_imm,
    .wb_sel, .mem_re, .mem_we, .mem_funct3, .is_branch, .is_jal, .is_jalr, .is_halt, .illegal
  );
  imm_gen u_imm (.insn, .fmt(imm_fmt), .imm);

  // ---- register read ----
  logic [31:0] rs1_val, rs2_val, wb_data;
  logic        rf_we;
  regfile #(.BYPASS(1'b0)) u_rf (
    .clk, .we(rf_we), .waddr(rd), .wdata(wb_data),
    .raddr1(rs1), .raddr2(rs2), .rdata1(rs1_val), .rdata2(rs2_val)
  );

  // ---- execute ----
  logic [31:0] op_a, op_b, alu_y;
  always_comb begin
    unique case (a_sel)
      A_PC:    op_a = pc;
      A_ZERO:  op_a = 32'b0;
      default: op_a = rs1_val;
    endcase
  end
  assign op_b = b_imm ? imm : rs2_val;
  alu u_alu (.op(alu_op), .a(op_a), .b(op_b), .y(alu_y));

  logic br_taken;
  branch_unit u_br (.funct3(insn[14:12]), .a(rs1_val), .b(rs2_val), .taken(br_taken));

  logic [31:0] pc_plus4, target, pc_imm;
  logic        redirect, unused_tgt_cout;
  assign pc_plus4 = pc + 32'd4;
  prefix_adder #(.W(32)) u_tgt (.a(pc), .b(imm), .cin(1'b0), .sum(pc_imm), .cout(unused_tgt_cout));
  assign target   = is_jalr ? {alu_y[31:1], 1'b0} : pc_imm;  // JALR: (rs1 + imm) & ~1
  assign redirect = is_jal || is_jalr || (is_branch && br_taken);

  // ---- memory ----
  logic [3:0]  st_strb;
  logic [31:0] st_data, ld_data;
  logic        misaligned_mem, misaligned_jump;
  lsu u_lsu (
    .funct3(mem_funct3), .addr(alu_y), .store_data(rs2_val), .load_word(dmem_rdata),
    .wstrb(st_strb), .wdata(st_data), .load_data(ld_data), .misaligned(misaligned_mem)
  );
  assign misaligned_jump = redirect && (target[1:0] != 2'b00);

  // Trap: the instruction retires but has no side effects, then the core halts.
  logic [1:0] trap;
  always_comb begin
    if (illegal)                                                trap = TRAP_ILLEGAL;
    else if (((mem_re || mem_we) && misaligned_mem) || misaligned_jump) trap = TRAP_MISALIGNED;
    else if (is_halt)                                           trap = TRAP_ECALL;
    else                                                        trap = TRAP_NONE;
  end

  logic active;
  assign active     = !halted;
  assign dmem_addr  = alu_y;
  assign dmem_re    = active && mem_re && trap == TRAP_NONE;
  assign dmem_wstrb = (active && mem_we && trap == TRAP_NONE) ? st_strb : 4'b0000;
  assign dmem_wdata = st_data;

  // ---- writeback ----
  always_comb begin
    unique case (wb_sel)
      WB_MEM:  wb_data = ld_data;
      WB_PC4:  wb_data = pc_plus4;
      default: wb_data = alu_y;
    endcase
  end
  assign rf_we = active && reg_we && trap == TRAP_NONE;

  // ---- next PC / halt ----
  always_ff @(posedge clk) begin
    if (rst) begin
      pc     <= RESET_PC;
      halted <= 1'b0;
    end else if (active) begin
      if (trap != TRAP_NONE) halted <= 1'b1;
      else                   pc <= redirect ? target : pc_plus4;
    end
  end

  // ---- retirement trace ----
  assign rvfi_valid     = active;
  assign rvfi_pc        = pc;
  assign rvfi_insn      = insn;
  assign rvfi_trap      = trap;
  assign rvfi_rd        = (rf_we && rd != 5'd0) ? rd : 5'd0;
  assign rvfi_rd_wdata  = (rf_we && rd != 5'd0) ? wb_data : 32'b0;
  assign rvfi_mem_addr  = alu_y;
  assign rvfi_mem_re    = dmem_re;
  assign rvfi_mem_wstrb = dmem_wstrb;
  assign rvfi_mem_wdata = st_data;

  assign perf_stall  = 1'b0;  // no hazards in a single-cycle design
  assign perf_flush  = 1'b0;
  assign perf_branch = active && trap == TRAP_NONE && (is_branch || is_jal || is_jalr);

  logic unused;
  assign unused = ^{uses_rs1, uses_rs2};
endmodule
