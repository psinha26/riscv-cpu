// 5-stage pipelined RV32I core: IF -> ID -> EX -> MEM -> WB.
//
//   IF   fetch at PC; next PC = PC + 4 (predict not-taken)
//   ID   decode, read registers (with WB->ID bypass), generate the immediate
//   EX   forwarding muxes, ALU, branch compare, jump target; redirect or trap here
//   MEM  load/store through the data port (byte enables, sign extension), MMIO
//   WB   write the register file; report the retired instruction on rvfi_*
//
// Hazards are handled by hazard_unit (forwarding, one-cycle load-use stall, two-instruction
// flush on taken branches and jumps). Same ports as core_single.
module core_pipe
  import rv32i_pkg::*;
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

  output logic        perf_stall,   // a load-use bubble was inserted this cycle
  output logic        perf_flush    // a taken branch/jump flushed two instructions this cycle
);
  // Hazard control (driven by hazard_unit below).
  logic stall, bubble_ex, flush_id, load_use;
  logic ex_redirect, ex_trap_any;
  logic [31:0] ex_target;
  logic fetch_stop;  // a trap is in flight: stop fetching new instructions

  // =========================================================================================
  // IF
  // =========================================================================================
  logic [31:0] pc;
  assign imem_addr = pc;

  always_ff @(posedge clk) begin
    if (rst)                         pc <= RESET_PC;
    else if (ex_redirect)            pc <= ex_target;
    else if (!stall && !fetch_stop && !ex_trap_any) pc <= pc + 32'd4;
  end

  // IF/ID
  logic        id_valid;
  logic [31:0] id_pc, id_insn;
  always_ff @(posedge clk) begin
    if (rst || flush_id || fetch_stop) begin
      id_valid <= 1'b0;
      id_insn  <= NOP;
      id_pc    <= 32'b0;
    end else if (!stall) begin
      id_valid <= 1'b1;
      id_insn  <= imem_rdata;
      id_pc    <= pc;
    end
  end

  // =========================================================================================
  // ID
  // =========================================================================================
  logic [4:0]  d_rs1, d_rs2, d_rd;
  logic        d_uses_rs1, d_uses_rs2, d_reg_we, d_b_imm, d_mem_re, d_mem_we;
  logic        d_is_branch, d_is_jal, d_is_jalr, d_is_halt, d_illegal;
  logic [2:0]  d_imm_fmt, d_mem_funct3;
  logic [3:0]  d_alu_op;
  logic [1:0]  d_a_sel, d_wb_sel;
  logic [31:0] d_imm, d_rs1_val, d_rs2_val;

  decoder u_dec (
    .insn(id_insn), .rs1(d_rs1), .rs2(d_rs2), .rd(d_rd), .uses_rs1(d_uses_rs1), .uses_rs2(d_uses_rs2),
    .reg_we(d_reg_we), .imm_fmt(d_imm_fmt), .alu_op(d_alu_op), .a_sel(d_a_sel), .b_imm(d_b_imm),
    .wb_sel(d_wb_sel), .mem_re(d_mem_re), .mem_we(d_mem_we), .mem_funct3(d_mem_funct3),
    .is_branch(d_is_branch), .is_jal(d_is_jal), .is_jalr(d_is_jalr), .is_halt(d_is_halt), .illegal(d_illegal)
  );
  imm_gen u_imm (.insn(id_insn), .fmt(d_imm_fmt), .imm(d_imm));

  logic        wb_valid, wb_reg_we;
  logic [4:0]  wb_rd;
  logic [31:0] wb_data;
  regfile #(.BYPASS(1'b1)) u_rf (
    .clk, .we(wb_valid && wb_reg_we), .waddr(wb_rd), .wdata(wb_data),
    .raddr1(d_rs1), .raddr2(d_rs2), .rdata1(d_rs1_val), .rdata2(d_rs2_val)
  );

  // ID/EX
  logic        ex_valid, ex_reg_we, ex_b_imm, ex_mem_re, ex_mem_we;
  logic        ex_is_branch, ex_is_jal, ex_is_jalr, ex_is_halt, ex_illegal;
  logic [31:0] ex_pc, ex_insn, ex_imm, ex_rs1_val, ex_rs2_val;
  logic [4:0]  ex_rs1, ex_rs2, ex_rd;
  logic [3:0]  ex_alu_op;
  logic [1:0]  ex_a_sel, ex_wb_sel;
  logic [2:0]  ex_mem_funct3;

  always_ff @(posedge clk) begin
    if (rst || bubble_ex) begin
      ex_valid     <= 1'b0;
      ex_reg_we    <= 1'b0;
      ex_mem_re    <= 1'b0;
      ex_mem_we    <= 1'b0;
      ex_is_branch <= 1'b0;
      ex_is_jal    <= 1'b0;
      ex_is_jalr   <= 1'b0;
      ex_is_halt   <= 1'b0;
      ex_illegal   <= 1'b0;
      ex_rd        <= 5'd0;
      ex_rs1       <= 5'd0;
      ex_rs2       <= 5'd0;
      ex_pc        <= 32'b0;
      ex_insn      <= NOP;
    end else begin
      ex_valid      <= id_valid;
      ex_pc         <= id_pc;
      ex_insn       <= id_insn;
      ex_rs1        <= d_rs1;
      ex_rs2        <= d_rs2;
      ex_rd         <= d_rd;
      ex_rs1_val    <= d_rs1_val;
      ex_rs2_val    <= d_rs2_val;
      ex_imm        <= d_imm;
      ex_alu_op     <= d_alu_op;
      ex_a_sel      <= d_a_sel;
      ex_b_imm      <= d_b_imm;
      ex_wb_sel     <= d_wb_sel;
      ex_reg_we     <= d_reg_we;
      ex_mem_re     <= d_mem_re;
      ex_mem_we     <= d_mem_we;
      ex_mem_funct3 <= d_mem_funct3;
      ex_is_branch  <= d_is_branch;
      ex_is_jal     <= d_is_jal;
      ex_is_jalr    <= d_is_jalr;
      ex_is_halt    <= d_is_halt;
      ex_illegal    <= d_illegal;
    end
  end

  // =========================================================================================
  // EX
  // =========================================================================================
  logic [1:0]  fwd_a, fwd_b;
  logic        mem_valid, mem_reg_we;
  logic [4:0]  mem_rd;
  logic [31:0] mem_fwd_val;  // result of the instruction in MEM, if it isn't a load

  logic [31:0] rs1_fwd, rs2_fwd;
  always_comb begin
    unique case (fwd_a)
      2'd1:    rs1_fwd = mem_fwd_val;
      2'd2:    rs1_fwd = wb_data;
      default: rs1_fwd = ex_rs1_val;
    endcase
    unique case (fwd_b)
      2'd1:    rs2_fwd = mem_fwd_val;
      2'd2:    rs2_fwd = wb_data;
      default: rs2_fwd = ex_rs2_val;
    endcase
  end

  logic [31:0] op_a, op_b, alu_y;
  always_comb begin
    unique case (ex_a_sel)
      A_PC:    op_a = ex_pc;
      A_ZERO:  op_a = 32'b0;
      default: op_a = rs1_fwd;
    endcase
  end
  assign op_b = ex_b_imm ? ex_imm : rs2_fwd;
  alu u_alu (.op(ex_alu_op), .a(op_a), .b(op_b), .y(alu_y));

  logic br_taken;
  branch_unit u_br (.funct3(ex_insn[14:12]), .a(rs1_fwd), .b(rs2_fwd), .taken(br_taken));

  logic        jump;
  logic [31:0] ex_pc4;
  assign ex_pc4    = ex_pc + 32'd4;
  assign ex_target = ex_is_jalr ? {alu_y[31:1], 1'b0} : ex_pc + ex_imm;
  assign jump      = ex_valid && (ex_is_jal || ex_is_jalr || (ex_is_branch && br_taken));

  // Misalignment checks (address computed here, so traps are known before MEM).
  logic [3:0]  unused_strb;
  logic [31:0] unused_wdata, unused_ld;
  logic        mis_mem;
  lsu u_chk (
    .funct3(ex_mem_funct3), .addr(alu_y), .store_data(32'b0), .load_word(32'b0),
    .wstrb(unused_strb), .wdata(unused_wdata), .load_data(unused_ld), .misaligned(mis_mem)
  );

  logic [1:0] ex_trap;
  always_comb begin
    if (!ex_valid)                                              ex_trap = TRAP_NONE;
    else if (ex_illegal)                                        ex_trap = TRAP_ILLEGAL;
    else if (((ex_mem_re || ex_mem_we) && mis_mem) || (jump && ex_target[1:0] != 2'b00))
                                                                ex_trap = TRAP_MISALIGNED;
    else if (ex_is_halt)                                        ex_trap = TRAP_ECALL;
    else                                                        ex_trap = TRAP_NONE;
  end
  assign ex_trap_any = (ex_trap != TRAP_NONE);
  assign ex_redirect = jump && !ex_trap_any;

  // Once a trap reaches EX nothing younger may execute.
  always_ff @(posedge clk) begin
    if (rst)              fetch_stop <= 1'b0;
    else if (ex_trap_any) fetch_stop <= 1'b1;
  end

  // EX/MEM
  logic [31:0] mem_pc, mem_insn, mem_alu, mem_store, mem_pc4;
  logic [1:0]  mem_wb_sel, mem_trap;
  logic        mem_mem_re, mem_mem_we;
  logic [2:0]  mem_funct3;

  always_ff @(posedge clk) begin
    if (rst) begin
      mem_valid  <= 1'b0;
      mem_reg_we <= 1'b0;
      mem_mem_re <= 1'b0;
      mem_mem_we <= 1'b0;
      mem_trap   <= TRAP_NONE;
      mem_rd     <= 5'd0;
    end else begin
      mem_valid  <= ex_valid;
      mem_pc     <= ex_pc;
      mem_insn   <= ex_insn;
      mem_rd     <= ex_rd;
      mem_alu    <= alu_y;
      mem_store  <= rs2_fwd;
      mem_pc4    <= ex_pc4;
      mem_wb_sel <= ex_wb_sel;
      mem_funct3 <= ex_mem_funct3;
      mem_trap   <= ex_trap;
      // A trapping instruction has no side effects.
      mem_reg_we <= ex_valid && ex_reg_we && !ex_trap_any;
      mem_mem_re <= ex_valid && ex_mem_re && !ex_trap_any;
      mem_mem_we <= ex_valid && ex_mem_we && !ex_trap_any;
    end
  end
  assign mem_fwd_val = (mem_wb_sel == WB_PC4) ? mem_pc4 : mem_alu;

  // =========================================================================================
  // MEM
  // =========================================================================================
  logic [3:0]  st_strb;
  logic [31:0] st_data, ld_data;
  logic        unused_mis;
  lsu u_lsu (
    .funct3(mem_funct3), .addr(mem_alu), .store_data(mem_store), .load_word(dmem_rdata),
    .wstrb(st_strb), .wdata(st_data), .load_data(ld_data), .misaligned(unused_mis)
  );
  assign dmem_addr  = mem_alu;
  assign dmem_re    = mem_mem_re;
  assign dmem_wstrb = mem_mem_we ? st_strb : 4'b0000;
  assign dmem_wdata = st_data;

  logic [31:0] mem_result;
  always_comb begin
    unique case (mem_wb_sel)
      WB_MEM:  mem_result = ld_data;
      WB_PC4:  mem_result = mem_pc4;
      default: mem_result = mem_alu;
    endcase
  end

  // MEM/WB
  logic [31:0] wb_pc, wb_insn, wb_mem_addr, wb_mem_wdata;
  logic [1:0]  wb_trap;
  logic        wb_mem_re;
  logic [3:0]  wb_mem_wstrb;
  always_ff @(posedge clk) begin
    if (rst) begin
      wb_valid     <= 1'b0;
      wb_reg_we    <= 1'b0;
      wb_trap      <= TRAP_NONE;
      wb_mem_re    <= 1'b0;
      wb_mem_wstrb <= 4'b0;
      wb_rd        <= 5'd0;
    end else begin
      wb_valid     <= mem_valid;
      wb_pc        <= mem_pc;
      wb_insn      <= mem_insn;
      wb_rd        <= mem_rd;
      wb_reg_we    <= mem_reg_we;
      wb_data      <= mem_result;
      wb_trap      <= mem_trap;
      wb_mem_addr  <= mem_alu;
      wb_mem_re    <= dmem_re;
      wb_mem_wstrb <= dmem_wstrb;
      wb_mem_wdata <= st_data;
    end
  end

  // =========================================================================================
  // WB: the register file write happens in u_rf; report the retired instruction.
  // =========================================================================================
  always_ff @(posedge clk) begin
    if (rst)                               halted <= 1'b0;
    else if (wb_valid && wb_trap != TRAP_NONE) halted <= 1'b1;
  end

  logic wb_writes;
  assign wb_writes      = wb_reg_we && wb_rd != 5'd0;
  assign rvfi_valid     = wb_valid && !halted;
  assign rvfi_pc        = wb_pc;
  assign rvfi_insn      = wb_insn;
  assign rvfi_trap      = wb_trap;
  assign rvfi_rd        = wb_writes ? wb_rd : 5'd0;
  assign rvfi_rd_wdata  = wb_writes ? wb_data : 32'b0;
  assign rvfi_mem_addr  = wb_mem_addr;
  assign rvfi_mem_re    = wb_mem_re;
  assign rvfi_mem_wstrb = wb_mem_wstrb;
  assign rvfi_mem_wdata = wb_mem_wdata;

  // =========================================================================================
  // Hazards
  // =========================================================================================
  hazard_unit u_haz (
    .id_valid, .id_rs1(d_rs1), .id_rs2(d_rs2), .id_uses_rs1(d_uses_rs1), .id_uses_rs2(d_uses_rs2),
    .ex_valid, .ex_rs1, .ex_rs2, .ex_rd, .ex_mem_re, .ex_redirect, .ex_trap(ex_trap_any),
    .mem_valid, .mem_rd, .mem_reg_we,
    .wb_valid, .wb_rd, .wb_reg_we,
    .fwd_a, .fwd_b, .stall, .bubble_ex, .flush_id, .load_use
  );

  assign perf_stall = stall;
  assign perf_flush = ex_redirect;
endmodule
