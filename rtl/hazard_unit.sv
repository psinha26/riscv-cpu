// Hazard unit for the 5-stage pipeline: forwarding selects, the load-use stall, and flushes.
//
// Forwarding (data hazards resolved without stalling)
//   An instruction in EX reads rs1/rs2. If an older instruction that writes the same register
//   is in MEM (EX/MEM register) or WB (MEM/WB register), take its result instead of the stale
//   register-file value read in ID. The youngest producer wins (EX/MEM over MEM/WB).
//   A result 3 or more instructions old is already in the register file (WB writes before ID
//   reads in the same cycle: see regfile BYPASS).
//
// Load-use stall
//   A load's data only exists at the end of MEM, too late for an instruction directly behind
//   it in EX. If the instruction in ID needs the register a load in EX is about to write,
//   hold IF and ID for one cycle and send a bubble into EX. Next cycle the load is in WB and
//   its data is forwarded from MEM/WB.
//
// Control hazards
//   Branches and jumps are predicted not-taken and resolved in EX. On a taken branch, JAL or
//   JALR the two younger instructions (in IF and ID) are flushed. A trap (ECALL, EBREAK,
//   illegal, misaligned) in EX also flushes everything younger and stops fetching.
module hazard_unit (
  // instruction in ID
  input  logic       id_valid,
  input  logic [4:0] id_rs1,
  input  logic [4:0] id_rs2,
  input  logic       id_uses_rs1,
  input  logic       id_uses_rs2,
  // instruction in EX (ID/EX register)
  input  logic       ex_valid,
  input  logic [4:0] ex_rs1,
  input  logic [4:0] ex_rs2,
  input  logic [4:0] ex_rd,
  input  logic       ex_mem_re,
  input  logic       ex_redirect,   // taken branch / jump resolved this cycle
  input  logic       ex_trap,       // trapping instruction in EX
  // instruction in MEM (EX/MEM register)
  input  logic       mem_valid,
  input  logic [4:0] mem_rd,
  input  logic       mem_reg_we,
  // instruction in WB (MEM/WB register)
  input  logic       wb_valid,
  input  logic [4:0] wb_rd,
  input  logic       wb_reg_we,

  output logic [1:0] fwd_a,         // 0: register file, 1: from MEM (EX/MEM), 2: from WB (MEM/WB)
  output logic [1:0] fwd_b,
  output logic       stall,         // hold PC and IF/ID
  output logic       bubble_ex,     // load a bubble into ID/EX
  output logic       flush_id,      // load a bubble into IF/ID
  output logic       load_use
);
  function automatic logic [1:0] fwd_sel(input logic [4:0] rs);
    if (mem_valid && mem_reg_we && mem_rd != 5'd0 && mem_rd == rs)      fwd_sel = 2'd1;
    else if (wb_valid && wb_reg_we && wb_rd != 5'd0 && wb_rd == rs)     fwd_sel = 2'd2;
    else                                                                fwd_sel = 2'd0;
  endfunction

  assign fwd_a = fwd_sel(ex_rs1);
  assign fwd_b = fwd_sel(ex_rs2);

  assign load_use = ex_valid && ex_mem_re && ex_rd != 5'd0 && id_valid &&
                    ((id_uses_rs1 && id_rs1 == ex_rd) || (id_uses_rs2 && id_rs2 == ex_rd));

  // A redirect or trap squashes the instruction in ID, which makes any load-use stall on it moot.
  logic kill;
  assign kill      = ex_redirect || ex_trap;
  assign flush_id  = kill;
  assign bubble_ex = kill || load_use;
  assign stall     = load_use && !kill;
endmodule
