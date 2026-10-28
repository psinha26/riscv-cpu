// Instruction decoder / control unit for RV32I.
// Produces every control signal the datapath needs; anything outside RV32I (CSR instructions,
// FENCE.I, malformed encodings) is flagged illegal and halts the core.
module decoder
  import rv32i_pkg::*;
(
  input  logic [31:0] insn,
  output logic [4:0]  rs1,
  output logic [4:0]  rs2,
  output logic [4:0]  rd,
  output logic        uses_rs1,    // instruction reads rs1 (for hazard detection)
  output logic        uses_rs2,    // instruction reads rs2
  output logic        reg_we,      // writes rd
  output logic [2:0]  imm_fmt,
  output logic [3:0]  alu_op,
  output logic [1:0]  a_sel,       // ALU operand A: rs1 / pc / zero
  output logic        b_imm,       // ALU operand B: 1 = immediate, 0 = rs2
  output logic [1:0]  wb_sel,      // writeback: ALU / load data / pc+4
  output logic        mem_re,
  output logic        mem_we,
  output logic [2:0]  mem_funct3,  // size (bits 1:0) and unsigned (bit 2) for loads/stores
  output logic        is_branch,
  output logic        is_jal,
  output logic        is_jalr,
  output logic        is_halt,     // ECALL or EBREAK
  output logic        illegal
);
  logic [6:0] opcode, funct7;
  logic [2:0] funct3;
  assign opcode = insn[6:0];
  assign funct3 = insn[14:12];
  assign funct7 = insn[31:25];
  assign rs1    = insn[19:15];
  assign rs2    = insn[24:20];
  assign rd     = insn[11:7];
  assign mem_funct3 = funct3;

  // ALU operation for OP / OP-IMM given funct3 and the "alternate" bit (insn[30]).
  function automatic logic [3:0] arith_op(input logic [2:0] f3, input logic alt, input logic is_reg);
    unique case (f3)
      3'b000:  arith_op = (is_reg && alt) ? ALU_SUB : ALU_ADD;
      3'b001:  arith_op = ALU_SLL;
      3'b010:  arith_op = ALU_SLT;
      3'b011:  arith_op = ALU_SLTU;
      3'b100:  arith_op = ALU_XOR;
      3'b101:  arith_op = alt ? ALU_SRA : ALU_SRL;
      3'b110:  arith_op = ALU_OR;
      default: arith_op = ALU_AND;
    endcase
  endfunction

  always_comb begin
    // Defaults: a harmless no-op.
    uses_rs1  = 1'b0;
    uses_rs2  = 1'b0;
    reg_we    = 1'b0;
    imm_fmt   = IMM_I;
    alu_op    = ALU_ADD;
    a_sel     = A_RS1;
    b_imm     = 1'b1;
    wb_sel    = WB_ALU;
    mem_re    = 1'b0;
    mem_we    = 1'b0;
    is_branch = 1'b0;
    is_jal    = 1'b0;
    is_jalr   = 1'b0;
    is_halt   = 1'b0;
    illegal   = 1'b0;

    if (insn[1:0] != 2'b11) begin
      illegal = 1'b1;  // compressed instructions are not supported
    end else begin
      unique case (opcode)
        OP_LUI: begin
          reg_we = 1'b1; imm_fmt = IMM_U; a_sel = A_ZERO;
        end
        OP_AUIPC: begin
          reg_we = 1'b1; imm_fmt = IMM_U; a_sel = A_PC;
        end
        OP_JAL: begin
          reg_we = 1'b1; imm_fmt = IMM_J; a_sel = A_PC; wb_sel = WB_PC4; is_jal = 1'b1;
        end
        OP_JALR: begin
          reg_we = 1'b1; uses_rs1 = 1'b1; wb_sel = WB_PC4; is_jalr = 1'b1;
          illegal = (funct3 != 3'b000);
        end
        OP_BRANCH: begin
          uses_rs1 = 1'b1; uses_rs2 = 1'b1; imm_fmt = IMM_B; a_sel = A_PC; is_branch = 1'b1;
          illegal = (funct3 == 3'b010) || (funct3 == 3'b011);
        end
        OP_LOAD: begin
          reg_we = 1'b1; uses_rs1 = 1'b1; mem_re = 1'b1; wb_sel = WB_MEM;
          // valid: LB LH LW LBU LHU
          illegal = (funct3 == 3'b011) || (funct3 == 3'b110) || (funct3 == 3'b111);
        end
        OP_STORE: begin
          uses_rs1 = 1'b1; uses_rs2 = 1'b1; imm_fmt = IMM_S; mem_we = 1'b1;
          illegal = (funct3[2] == 1'b1) || (funct3[1:0] == 2'b11);  // valid: SB SH SW
        end
        OP_IMM: begin
          reg_we = 1'b1; uses_rs1 = 1'b1;
          alu_op = arith_op(funct3, insn[30], 1'b0);
          if (funct3 == 3'b001)      illegal = (funct7 != 7'b0000000);
          else if (funct3 == 3'b101) illegal = (funct7 != 7'b0000000) && (funct7 != 7'b0100000);
        end
        OP_REG: begin
          reg_we = 1'b1; uses_rs1 = 1'b1; uses_rs2 = 1'b1; b_imm = 1'b0;
          alu_op = arith_op(funct3, insn[30], 1'b1);
          if (funct3 == 3'b000 || funct3 == 3'b101)
            illegal = (funct7 != 7'b0000000) && (funct7 != 7'b0100000);
          else
            illegal = (funct7 != 7'b0000000);
        end
        OP_FENCE: begin
          illegal = (funct3 != 3'b000);  // FENCE is a no-op; FENCE.I is not supported
        end
        OP_SYSTEM: begin
          if (insn == 32'h0000_0073 || insn == 32'h0010_0073) is_halt = 1'b1;  // ECALL / EBREAK
          else illegal = 1'b1;  // CSR instructions are out of scope
        end
        default: illegal = 1'b1;
      endcase
    end

    // An illegal instruction must have no side effects.
    if (illegal) begin
      reg_we = 1'b0; mem_re = 1'b0; mem_we = 1'b0;
      is_branch = 1'b0; is_jal = 1'b0; is_jalr = 1'b0;
    end
  end
endmodule
