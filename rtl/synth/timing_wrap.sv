// Timing-analysis wrapper (synthesis estimates only, never simulated).
//
// The cores' memories are external, so in a bare synthesis run a path that goes *through* a
// memory (single-cycle: PC -> imem -> decode -> ALU -> dmem -> writeback) is cut at the ports
// and looks short. This wrapper closes each memory loop with a zero-delay stand-in
// (rdata = addr ^ key), so the full register-to-register chain is timed. SRAM access time is
// therefore not included for either core, which flatters the single-cycle design (it has two
// memory accesses in series per cycle, the pipeline has one per stage).
module timing_wrap #(
  parameter int PIPELINED  = 1,
  parameter int BP_ENTRIES = 0
) (
  input  logic        clk,
  input  logic        rst,
  input  logic [31:0] ikey,
  input  logic [31:0] dkey,
  output logic [31:0] observe
);
  logic [31:0] imem_addr, imem_rdata, dmem_addr, dmem_wdata, dmem_rdata;
  logic [3:0]  dmem_wstrb;
  logic        dmem_re, halted, perf_stall, perf_flush, perf_branch;
  logic        rvfi_valid, rvfi_mem_re;
  logic [31:0] rvfi_pc, rvfi_insn, rvfi_rd_wdata, rvfi_mem_addr, rvfi_mem_wdata;
  logic [1:0]  rvfi_trap;
  logic [4:0]  rvfi_rd;
  logic [3:0]  rvfi_mem_wstrb;

  assign imem_rdata = imem_addr ^ ikey;
  assign dmem_rdata = dmem_addr ^ dkey;

  if (PIPELINED != 0) begin : g_core
    core_pipe #(.BP_ENTRIES(BP_ENTRIES)) u_core (.*);
  end else begin : g_core
    core_single u_core (.*);
  end

  // Keep every output live so nothing is optimized away.
  assign observe = rvfi_rd_wdata ^ rvfi_pc ^ rvfi_mem_wdata ^ dmem_wdata ^ {dmem_wstrb, 28'b0} ^
                   {31'b0, halted ^ dmem_re ^ perf_stall ^ perf_flush ^ perf_branch ^ rvfi_valid};
endmodule
