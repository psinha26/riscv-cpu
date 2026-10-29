// Top level for the chip layout flow (flow/config.json).
//
// The pipelined core with its 16-entry branch target buffer. Memories stay outside as ports
// (the project scope: an SRAM macro or bus would sit there), and the rvfi_* retirement trace,
// which only exists for the simulation testbench, is left unconnected so synthesis removes it.
module chip_top (
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
  output logic        perf_stall,
  output logic        perf_flush,
  output logic        perf_branch
);
  /* verilator lint_off PINCONNECTEMPTY */
  core_pipe #(.BP_ENTRIES(16), .BP_JALR(1'b0)) u_core (
    .clk, .rst,
    .imem_addr, .imem_rdata,
    .dmem_addr, .dmem_re, .dmem_wstrb, .dmem_wdata, .dmem_rdata,
    .halted,
    .rvfi_valid(), .rvfi_pc(), .rvfi_insn(), .rvfi_trap(), .rvfi_rd(), .rvfi_rd_wdata(),
    .rvfi_mem_addr(), .rvfi_mem_re(), .rvfi_mem_wstrb(), .rvfi_mem_wdata(),
    .perf_stall, .perf_flush, .perf_branch
  );
  /* verilator lint_on PINCONNECTEMPTY */
endmodule
