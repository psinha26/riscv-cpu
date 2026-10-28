// Wrapper exposing the datapath building blocks side by side for unit testing
// (tb/unit/unit_tests.cpp drives every port and checks against C++ reference functions).
module unit_top
  import rv32i_pkg::*;
(
  input  logic        clk,
  // ALU
  input  logic [3:0]  alu_op,
  input  logic [31:0] alu_a,
  input  logic [31:0] alu_b,
  output logic [31:0] alu_y,
  // immediate generator
  input  logic [31:0] imm_insn,
  input  logic [2:0]  imm_fmt,
  output logic [31:0] imm,
  // branch unit
  input  logic [2:0]  br_funct3,
  output logic        br_taken,
  // register file (with bypass, as used by the pipeline)
  input  logic        rf_we,
  input  logic [4:0]  rf_waddr,
  input  logic [31:0] rf_wdata,
  input  logic [4:0]  rf_raddr1,
  input  logic [4:0]  rf_raddr2,
  output logic [31:0] rf_rdata1,
  output logic [31:0] rf_rdata2,
  // hazard unit
  input  logic        hz_id_valid,
  input  logic [4:0]  hz_id_rs1,
  input  logic [4:0]  hz_id_rs2,
  input  logic        hz_id_uses_rs1,
  input  logic        hz_id_uses_rs2,
  input  logic        hz_ex_valid,
  input  logic [4:0]  hz_ex_rs1,
  input  logic [4:0]  hz_ex_rs2,
  input  logic [4:0]  hz_ex_rd,
  input  logic        hz_ex_mem_re,
  input  logic        hz_ex_redirect,
  input  logic        hz_ex_trap,
  input  logic        hz_mem_valid,
  input  logic [4:0]  hz_mem_rd,
  input  logic        hz_mem_reg_we,
  input  logic        hz_wb_valid,
  input  logic [4:0]  hz_wb_rd,
  input  logic        hz_wb_reg_we,
  output logic [1:0]  hz_fwd_a,
  output logic [1:0]  hz_fwd_b,
  output logic        hz_stall,
  output logic        hz_bubble_ex,
  output logic        hz_flush_id,
  output logic        hz_load_use
);
  alu u_alu (.op(alu_op), .a(alu_a), .b(alu_b), .y(alu_y));
  imm_gen u_imm (.insn(imm_insn), .fmt(imm_fmt), .imm);
  branch_unit u_br (.funct3(br_funct3), .a(alu_a), .b(alu_b), .taken(br_taken));
  regfile #(.BYPASS(1'b1)) u_rf (
    .clk, .we(rf_we), .waddr(rf_waddr), .wdata(rf_wdata), .raddr1(rf_raddr1), .raddr2(rf_raddr2),
    .rdata1(rf_rdata1), .rdata2(rf_rdata2)
  );
  hazard_unit u_hz (
    .id_valid(hz_id_valid), .id_rs1(hz_id_rs1), .id_rs2(hz_id_rs2), .id_uses_rs1(hz_id_uses_rs1),
    .id_uses_rs2(hz_id_uses_rs2), .ex_valid(hz_ex_valid), .ex_rs1(hz_ex_rs1), .ex_rs2(hz_ex_rs2),
    .ex_rd(hz_ex_rd), .ex_mem_re(hz_ex_mem_re), .ex_redirect(hz_ex_redirect), .ex_trap(hz_ex_trap),
    .mem_valid(hz_mem_valid), .mem_rd(hz_mem_rd), .mem_reg_we(hz_mem_reg_we), .wb_valid(hz_wb_valid),
    .wb_rd(hz_wb_rd), .wb_reg_we(hz_wb_reg_we), .fwd_a(hz_fwd_a), .fwd_b(hz_fwd_b), .stall(hz_stall),
    .bubble_ex(hz_bubble_ex), .flush_id(hz_flush_id), .load_use(hz_load_use)
  );
endmodule
