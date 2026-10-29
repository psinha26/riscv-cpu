// Hazard unit for the 5-stage pipeline: forwarding selects, the load-use stall, and flushes.
//
// Forwarding (data hazards resolved without stalling)
//   An instruction in EX reads rs1/rs2. If an older instruction that writes the same register
//   is in MEM (EX/MEM register) or WB (MEM/WB register), take its result instead of the stale
//   register-file value read in ID. The youngest producer wins (EX/MEM over MEM/WB).
//   A result 3 or more instructions old is already in the register file (WB writes before ID
//   reads in the same cycle: see regfile BYPASS).
//
//   The forwarding *decision* is made one stage early, while the instruction is still in ID:
//   whatever is in EX now will be in MEM next cycle, and whatever is in MEM will be in WB. The
//   core registers fwd_a/fwd_b into ID/EX, so EX only sees a ready-made mux select. This takes
//   the register-number comparators off the EX critical path (forwarding mux -> ALU/compare ->
//   redirect); see docs/results/timing_ladder.json. If the ID instruction stalls, it is simply
//   re-evaluated next cycle.
//
// Load-use stall
//   A load's data only exists at the end of MEM, too late for an instruction directly behind
//   it in EX. If the instruction in ID needs the register a load in EX is about to write,
//   hold IF and ID for one cycle and send a bubble into EX. Next cycle the load is in WB and
//   its data is forwarded from MEM/WB.
//
// Control hazards
//   Branches and jumps are resolved in EX and checked against the prediction made in IF (by
//   the BTB, or "not taken" when there is none). On a misprediction the two younger
//   instructions (in IF and ID) are flushed and fetch restarts at the right PC. A trap
//   (ECALL, EBREAK, illegal, misaligned) in EX also flushes everything younger and stops
//   fetching. ex_redirect is the misprediction signal.
module hazard_unit (
  // instruction in ID
  input  logic       id_valid,
  input  logic [4:0] id_rs1,
  input  logic [4:0] id_rs2,
  input  logic       id_uses_rs1,
  input  logic       id_uses_rs2,
  // instruction in EX (ID/EX register)
  input  logic       ex_valid,
  input  logic [4:0] ex_rd,
  input  logic       ex_reg_we,
  input  logic       ex_mem_re,
  input  logic       ex_redirect,   // branch/jump mispredicted: fetch restarts this cycle
  input  logic       ex_trap,       // trapping instruction in EX
  // instruction in MEM (EX/MEM register)
  input  logic       mem_valid,
  input  logic [4:0] mem_rd,
  input  logic       mem_reg_we,

  // Forwarding selects for the ID instruction, to be registered into ID/EX:
  // 0: register file, 1: from MEM (EX/MEM), 2: from WB (MEM/WB) -- as seen once it is in EX.
  output logic [1:0] fwd_a,
  output logic [1:0] fwd_b,
  output logic       stall,         // hold PC and IF/ID
  output logic       bubble_ex,     // load a bubble into ID/EX
  output logic       flush_id,      // load a bubble into IF/ID
  output logic       load_use
);
  function automatic logic [1:0] fwd_sel(input logic [4:0] rs);
    if (ex_valid && ex_reg_we && ex_rd != 5'd0 && ex_rd == rs)          fwd_sel = 2'd1;  // EX -> MEM next
    else if (mem_valid && mem_reg_we && mem_rd != 5'd0 && mem_rd == rs) fwd_sel = 2'd2;  // MEM -> WB next
    else                                                                fwd_sel = 2'd0;
  endfunction

  assign fwd_a = fwd_sel(id_rs1);
  assign fwd_b = fwd_sel(id_rs2);

  assign load_use = ex_valid && ex_mem_re && ex_rd != 5'd0 && id_valid &&
                    ((id_uses_rs1 && id_rs1 == ex_rd) || (id_uses_rs2 && id_rs2 == ex_rd));

  // A redirect or trap squashes the instruction in ID, which makes any load-use stall on it moot.
  logic kill;
  assign kill      = ex_redirect || ex_trap;
  assign flush_id  = kill;
  assign bubble_ex = kill || load_use;
  assign stall     = load_use && !kill;
endmodule
