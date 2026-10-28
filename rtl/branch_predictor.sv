// Dynamic branch predictor: a direct-mapped branch target buffer (BTB) with a 2-bit
// saturating counter per entry.
//
// Lookup (IF, combinational): index the BTB with the fetch PC. On a tag hit, predict taken
// if the entry is an unconditional jump (JAL/JALR) or its counter is 2 or 3, and supply the
// stored target, so fetch continues down the predicted path with no bubble.
//
// Update (EX, when a branch or jump resolves): a taken branch/jump allocates or refreshes its
// entry (target, kind) and bumps the counter up; a not-taken branch that hits counts down.
// Counters saturate at 0 and 3, so one unusual outcome (a loop exit) doesn't flip a strongly
// biased branch.
//
// The core checks every prediction in EX and redirects on a wrong direction or target, so the
// predictor only affects speed, never correctness (aliasing between PCs that share an index and
// partial tag is harmless). ENTRIES = 0 removes it: predict not-taken, as in the textbook pipeline.
module branch_predictor #(
  parameter int ENTRIES  = 64,
  parameter int TAG_BITS = 8
) (
  input  logic        clk,
  input  logic        rst,
  // lookup (IF)
  input  logic [31:0] if_pc,
  output logic        pred_taken,
  output logic [31:0] pred_target,
  // update (EX)
  input  logic        upd_valid,    // a branch or jump resolved this cycle
  input  logic [31:0] upd_pc,
  input  logic        upd_taken,
  input  logic        upd_uncond,   // JAL/JALR: always taken
  input  logic [31:0] upd_target
);
  if (ENTRIES == 0) begin : g_none
    assign pred_taken  = 1'b0;
    assign pred_target = 32'b0;
  end else begin : g_btb
    localparam int IDX = $clog2(ENTRIES);

    logic                valid  [ENTRIES];
    logic                uncond [ENTRIES];
    logic [1:0]          ctr    [ENTRIES];
    logic [TAG_BITS-1:0] tag    [ENTRIES];
    logic [31:2]         target [ENTRIES];

    // ---- lookup ----
    logic [IDX-1:0]      ri;
    logic [TAG_BITS-1:0] rt;
    logic                hit;
    assign ri          = if_pc[IDX+1:2];
    assign rt          = if_pc[IDX+2 +: TAG_BITS];
    assign hit         = valid[ri] && tag[ri] == rt;
    assign pred_taken  = hit && (uncond[ri] || ctr[ri][1]);
    assign pred_target = {target[ri], 2'b00};

    // ---- update ----
    logic [IDX-1:0]      wi;
    logic [TAG_BITS-1:0] wt;
    logic                whit;
    assign wi   = upd_pc[IDX+1:2];
    assign wt   = upd_pc[IDX+2 +: TAG_BITS];
    assign whit = valid[wi] && tag[wi] == wt;

    always_ff @(posedge clk) begin
      if (rst) begin
        for (int i = 0; i < ENTRIES; i++) valid[i] <= 1'b0;
      end else if (upd_valid) begin
        if (upd_taken) begin
          valid[wi]  <= 1'b1;
          tag[wi]    <= wt;
          target[wi] <= upd_target[31:2];
          uncond[wi] <= upd_uncond;
          // A new entry starts weakly taken; an existing one counts up.
          ctr[wi]    <= !whit ? 2'b10 : (ctr[wi] == 2'b11 ? 2'b11 : ctr[wi] + 2'b01);
        end else if (whit) begin
          ctr[wi]    <= (ctr[wi] == 2'b00) ? 2'b00 : ctr[wi] - 2'b01;
        end
      end
    end
  end
endmodule
