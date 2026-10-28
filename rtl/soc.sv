// Simulation SoC: a core plus on-chip memories and memory-mapped I/O.
//
// Memory map
//   0x0000_0000  instruction ROM (IMEM_KB), loaded from +imem=<hex>
//   0x1000_0000  data RAM (DMEM_KB), loaded from +dmem=<hex>  (.rodata/.data/.bss/stack)
//   0x2000_0000  UART TX data (write a byte to print it) / status on read (bit 0 = ready)
//   0x2000_0010  LEDs (read/write, 8 bits)
//   0x2000_0020  cycle counter, low / high word
//   0x2000_0028  instructions-retired counter, low / high word
//   0x2000_0030  cycles lost to load-use stalls
//   0x2000_0034  branch/jump flushes (each costs 2 cycles)
//
// PIPELINED selects the 5-stage core or the single-cycle core.
module soc
  import rv32i_pkg::*;
#(
  parameter int PIPELINED = 1,
  parameter int IMEM_KB   = 64,
  parameter int DMEM_KB   = 64
) (
  input  logic        clk,
  input  logic        rst,
  output logic        halted,
  output logic        uart_valid,
  output logic [7:0]  uart_data,
  output logic [7:0]  leds,

  // retirement trace, passed through for the testbench
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

  output logic [63:0] cycles,
  output logic [63:0] instret,
  output logic [31:0] stall_cycles,
  output logic [31:0] flushes
);
  localparam int IMEM_WORDS = IMEM_KB * 256;
  localparam int DMEM_WORDS = DMEM_KB * 256;
  localparam int IW = $clog2(IMEM_WORDS);
  localparam int DW = $clog2(DMEM_WORDS);

  logic [31:0] imem_addr, imem_rdata, dmem_addr, dmem_wdata, dmem_rdata;
  logic [3:0]  dmem_wstrb;
  logic        dmem_re, perf_stall, perf_flush;

  if (PIPELINED != 0) begin : g_core
    core_pipe u_core (.*);
  end else begin : g_core
    core_single u_core (.*);
  end

  // ---- memories ----
  logic [31:0] imem [0:IMEM_WORDS-1];
  logic [31:0] dmem [0:DMEM_WORDS-1];

  initial begin
    string f;
    for (int i = 0; i < IMEM_WORDS; i++) imem[i] = NOP;
    for (int i = 0; i < DMEM_WORDS; i++) dmem[i] = 32'b0;
    if ($value$plusargs("imem=%s", f)) $readmemh(f, imem);
    if ($value$plusargs("dmem=%s", f)) $readmemh(f, dmem);
  end

  // Instruction fetch: out-of-range addresses read as illegal (all zeros) so the core halts.
  assign imem_rdata = (imem_addr[31:IW+2] == '0) ? imem[imem_addr[IW+1:2]] : 32'b0;

  logic in_dmem, in_mmio;
  assign in_dmem = (dmem_addr[31:28] == 4'h1) && (dmem_addr[27:DW+2] == '0);
  assign in_mmio = (dmem_addr[31:8] == 24'h2000_00);

  always_ff @(posedge clk) begin
    if (in_dmem) begin
      for (int b = 0; b < 4; b++)
        if (dmem_wstrb[b]) dmem[dmem_addr[DW+1:2]][8*b +: 8] <= dmem_wdata[8*b +: 8];
    end
  end

  // ---- MMIO ----
  logic [31:0] mmio_rdata;
  always_comb begin
    unique case (dmem_addr[7:0])
      8'h00, 8'h04: mmio_rdata = 32'h1;  // UART always ready
      8'h10:        mmio_rdata = {24'b0, leds};
      8'h20:        mmio_rdata = cycles[31:0];
      8'h24:        mmio_rdata = cycles[63:32];
      8'h28:        mmio_rdata = instret[31:0];
      8'h2c:        mmio_rdata = instret[63:32];
      8'h30:        mmio_rdata = stall_cycles;
      8'h34:        mmio_rdata = flushes;
      default:      mmio_rdata = 32'b0;
    endcase
  end

  assign dmem_rdata = in_dmem ? dmem[dmem_addr[DW+1:2]] : in_mmio ? mmio_rdata : 32'b0;

  // UART: a store to 0x2000_0000 emits its low byte (SB, SH or SW all work).
  assign uart_valid = in_mmio && dmem_addr[7:0] == 8'h00 && dmem_wstrb[0];
  assign uart_data  = dmem_wdata[7:0];

  always_ff @(posedge clk) begin
    if (rst) begin
      leds         <= 8'b0;
      cycles       <= 64'b0;
      instret      <= 64'b0;
      stall_cycles <= 32'b0;
      flushes      <= 32'b0;
    end else begin
      if (in_mmio && dmem_addr[7:0] == 8'h10 && dmem_wstrb[0]) leds <= dmem_wdata[7:0];
      if (!halted) cycles <= cycles + 64'd1;
      if (rvfi_valid) instret <= instret + 64'd1;
      if (perf_stall) stall_cycles <= stall_cycles + 32'd1;
      if (perf_flush) flushes <= flushes + 32'd1;
    end
  end
endmodule
