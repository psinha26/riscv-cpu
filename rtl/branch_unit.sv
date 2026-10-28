// Branch condition evaluation (funct3 of a B-type instruction).
// Equality is an XOR-reduce; the magnitude comparisons come from a parallel-prefix
// subtractor (a - b = a + ~b + 1), which is much faster than the ripple compare a plain
// `a < b` synthesizes to.
module branch_unit (
  input  logic [2:0]  funct3,
  input  logic [31:0] a,
  input  logic [31:0] b,
  output logic        taken
);
  logic [31:0] diff;
  logic        cout, eq, lt_u, lt_s;
  prefix_adder #(.W(32)) u_sub (.a(a), .b(~b), .cin(1'b1), .sum(diff), .cout(cout));
  assign eq   = (a == b);
  assign lt_u = ~cout;
  assign lt_s = (a[31] ^ b[31]) ? a[31] : diff[31];

  always_comb begin
    unique case (funct3)
      3'b000:  taken = eq;     // BEQ
      3'b001:  taken = !eq;    // BNE
      3'b100:  taken = lt_s;   // BLT
      3'b101:  taken = !lt_s;  // BGE
      3'b110:  taken = lt_u;   // BLTU
      3'b111:  taken = !lt_u;  // BGEU
      default: taken = 1'b0;   // 010/011: illegal, caught by the decoder
    endcase
  end
endmodule
