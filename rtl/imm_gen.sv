// Immediate generator: sign-extended immediate for each RV32I instruction format.
module imm_gen
(
  input  logic [31:0] insn,
  input  logic [2:0]  fmt,
  output logic [31:0] imm
);
  `include "rv32i_defs.svh"

  always_comb begin
    unique case (fmt)
      IMM_I:   imm = {{20{insn[31]}}, insn[31:20]};
      IMM_S:   imm = {{20{insn[31]}}, insn[31:25], insn[11:7]};
      IMM_B:   imm = {{19{insn[31]}}, insn[31], insn[7], insn[30:25], insn[11:8], 1'b0};
      IMM_U:   imm = {insn[31:12], 12'b0};
      IMM_J:   imm = {{11{insn[31]}}, insn[31], insn[19:12], insn[20], insn[30:21], 1'b0};
      default: imm = 32'b0;
    endcase
  end
endmodule
