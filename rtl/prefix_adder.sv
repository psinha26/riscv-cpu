// Kogge-Stone parallel-prefix adder: sum = a + b + cin.
//
// A ripple-carry adder's carry crosses all W bits one after another; synthesized for Sky130 it
// was the critical path of the whole core (~29 majority gates in series, ~10 ns). Here every
// carry is computed in log2(W) levels of (generate, propagate) combining:
//   (G, P)[i] at distance d  =  (G[i] | P[i] & G[i-d],  P[i] & P[i-d])
// so a 32-bit add takes 5 levels instead of 32, at the cost of more (but parallel) gates.
module prefix_adder #(
  parameter int W = 32
) (
  input  logic [W-1:0] a,
  input  logic [W-1:0] b,
  input  logic         cin,
  output logic [W-1:0] sum,
  output logic         cout
);
  localparam int LEVELS = $clog2(W);

  logic [W-1:0] p0;
  // (generate, propagate) after each level of the tree, level l in bits [l*W +: W]. Kept as flat
  // vectors (not 2-D arrays) for older synthesis front ends; split_var tells Verilator the bits
  // are independent signals (otherwise it reports a false combinational loop).
  logic [(LEVELS+1)*W-1:0] g /* verilator split_var */, p /* verilator split_var */;

  assign p0 = a ^ b;
  // Fold the carry-in into bit 0's generate so the tree needs no extra input.
  assign g[W-1:0] = {a[W-1:1] & b[W-1:1], (a[0] & b[0]) | (p0[0] & cin)};
  assign p[W-1:0] = p0;

  for (genvar l = 0; l < LEVELS; l++) begin : g_level
    localparam int D = 1 << l;
    for (genvar i = 0; i < W; i++) begin : g_bit
      if (i >= D) begin : g_comb
        assign g[(l+1)*W + i] = g[l*W + i] | (p[l*W + i] & g[l*W + i - D]);
        assign p[(l+1)*W + i] = p[l*W + i] & p[l*W + i - D];
      end else begin : g_pass
        assign g[(l+1)*W + i] = g[l*W + i];
        assign p[(l+1)*W + i] = p[l*W + i];
      end
    end
  end

  // Carry into bit i is the group generate of bits [i-1:0] (with cin folded into bit 0).
  logic [W-1:0] carry;
  assign carry = {g[LEVELS*W +: W-1], cin};
  assign sum   = p0 ^ carry;
  assign cout  = g[LEVELS*W + W-1];
endmodule
