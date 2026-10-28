// 32 x 32-bit register file: two asynchronous read ports, one synchronous write port.
// x0 always reads as zero. With BYPASS=1 a read of the register being written in the same
// cycle returns the new value (write-before-read), so WB and ID never conflict in the pipeline.
module regfile #(
  parameter bit BYPASS = 1'b1
) (
  input  logic        clk,
  input  logic        we,
  input  logic [4:0]  waddr,
  input  logic [31:0] wdata,
  input  logic [4:0]  raddr1,
  input  logic [4:0]  raddr2,
  output logic [31:0] rdata1,
  output logic [31:0] rdata2
);
  logic [31:0] regs [1:31];

  always_ff @(posedge clk) begin
    if (we && waddr != 5'd0) regs[waddr] <= wdata;
  end

  always_comb begin
    if (raddr1 == 5'd0)                              rdata1 = 32'b0;
    else if (BYPASS && we && waddr == raddr1)        rdata1 = wdata;
    else                                             rdata1 = regs[raddr1];
    if (raddr2 == 5'd0)                              rdata2 = 32'b0;
    else if (BYPASS && we && waddr == raddr2)        rdata2 = wdata;
    else                                             rdata2 = regs[raddr2];
  end
endmodule
