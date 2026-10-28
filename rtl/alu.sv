// Arithmetic/logic unit.
// ADD, SUB, SLT and SLTU share one parallel-prefix adder: subtraction is a + ~b + 1, and the
// comparisons come from the same subtraction (unsigned: no carry out means a < b; signed: if
// the signs differ, a < b exactly when a is negative, otherwise look at the difference's sign).
module alu
(
  input  logic [3:0]  op,
  input  logic [31:0] a,
  input  logic [31:0] b,
  output logic [31:0] y
);
  `include "rv32i_defs.svh"

  logic [4:0] shamt;
  assign shamt = b[4:0];

  logic        sub;
  logic [31:0] sum;
  logic        cout, lt_u, lt_s;
  assign sub = (op == ALU_SUB) || (op == ALU_SLT) || (op == ALU_SLTU);
  prefix_adder #(.W(32)) u_add (.a(a), .b(sub ? ~b : b), .cin(sub), .sum(sum), .cout(cout));
  assign lt_u = ~cout;
  assign lt_s = (a[31] ^ b[31]) ? a[31] : sum[31];

  always_comb begin
    unique case (op)
      ALU_ADD, ALU_SUB: y = sum;
      ALU_SLL:  y = a << shamt;
      ALU_SLT:  y = {31'b0, lt_s};
      ALU_SLTU: y = {31'b0, lt_u};
      ALU_XOR:  y = a ^ b;
      ALU_SRL:  y = a >> shamt;
      ALU_SRA:  y = $unsigned($signed(a) >>> shamt);
      ALU_OR:   y = a | b;
      ALU_AND:  y = a & b;
      default:  y = 32'b0;
    endcase
  end
endmodule
