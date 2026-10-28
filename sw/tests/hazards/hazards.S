# Directed pipeline-hazard tests.
#
# Each case sets up a specific hazard (a forwarding path, a load-use stall, a flush) and checks
# the architectural result. The same file runs on the single-cycle core (where there are no
# hazards, so it checks plain ISA behaviour) and the pipelined core. Uses the riscv-tests
# protocol: gp = case number, ECALL with gp = 1 on pass.
#
# Cases are grouped:
#   10-19  ALU -> ALU forwarding (EX/MEM -> EX, MEM/WB -> EX, register file bypass)
#   20-29  load-use stalls
#   30-39  stores that need forwarded data
#   40-49  branches and jumps (flushes, forwarding into compares and JALR)
#   50-59  x0 and miscellaneous corner cases

#include "riscv_test.h"

#define CHECK(n, reg, val)  li gp, n; li t6, val; bne reg, t6, fail

RVTEST_RV32U
RVTEST_CODE_BEGIN

  # ---------------------------------------------------------------- ALU -> ALU forwarding
  # 10: EX/MEM -> EX on rs1 (distance 1)
  li a0, 5
  addi a1, a0, 3
  CHECK(10, a1, 8)

  # 11: EX/MEM -> EX on rs2
  li a0, 7
  sub a1, zero, a0
  CHECK(11, a1, -7)

  # 12: MEM/WB -> EX on rs1 (distance 2)
  li a0, 9
  nop
  addi a1, a0, 1
  CHECK(12, a1, 10)

  # 13: MEM/WB -> EX on rs2
  li a0, 11
  nop
  sub a1, zero, a0
  CHECK(13, a1, -11)

  # 14: register file WB -> ID bypass (distance 3)
  li a0, 13
  nop
  nop
  addi a1, a0, 2
  CHECK(14, a1, 15)

  # 15: both operands forwarded from different stages (rs1 from MEM/WB, rs2 from EX/MEM)
  li a0, 100
  li a1, 23
  sub a2, a0, a1
  CHECK(15, a2, 77)

  # 16: priority: the youngest producer must win when both EX/MEM and MEM/WB write a0
  li a0, 1
  li a0, 2
  addi a1, a0, 0
  CHECK(16, a1, 2)

  # 17: same register on both operands, forwarded
  li a0, 21
  add a1, a0, a0
  CHECK(17, a1, 42)

  # 18: a long dependent chain (every instruction forwards from the previous one)
  li a0, 1
  slli a0, a0, 1
  addi a0, a0, 1
  slli a0, a0, 1
  addi a0, a0, 1
  slli a0, a0, 1
  xori a0, a0, 0x5
  CHECK(18, a0, 0xb)

  # 19: LUI/AUIPC results forwarded (operand A from zero / PC)
  lui a0, 0x12345
  addi a0, a0, 0x678
  CHECK(19, a0, 0x12345678)

  # ---------------------------------------------------------------- load-use stalls
  la s0, tdat

  # 20: load then immediate use on rs1 (one bubble)
  lw a0, 0(s0)
  addi a1, a0, 1
  CHECK(20, a1, 0x11223345)

  # 21: load then use on rs2
  lw a0, 4(s0)
  sub a1, zero, a0
  CHECK(21, a1, 1)

  # 22: load then use at distance 2 (no stall needed: MEM/WB forwarding)
  lw a0, 0(s0)
  nop
  addi a1, a0, 1
  CHECK(22, a1, 0x11223345)

  # 23: load -> load: the second load's address depends on the first
  la a0, ptr
  lw a1, 0(a0)
  lw a2, 0(a1)
  CHECK(23, a2, 0x11223344)

  # 24: load-use into both operands
  lw a0, 8(s0)
  add a1, a0, a0
  CHECK(24, a1, 14)

  # 25: signed byte load feeding an ALU op
  lb a0, 7(s0)
  addi a1, a0, 0
  CHECK(25, a1, -1)

  # ---------------------------------------------------------------- stores needing forwarded data
  la s1, scratch

  # 30: store data forwarded from the previous ALU instruction (EX/MEM -> EX on rs2)
  li a0, 0x55
  sw a0, 0(s1)
  lw a1, 0(s1)
  CHECK(30, a1, 0x55)

  # 31: store address forwarded (rs1)
  la a2, scratch
  addi a2, a2, 4
  li a0, 0x66
  sw a0, 0(a2)
  lw a1, 4(s1)
  CHECK(31, a1, 0x66)

  # 32: load then store of the loaded value (load-use on store data)
  lw a0, 0(s0)
  sw a0, 8(s1)
  lw a1, 8(s1)
  CHECK(32, a1, 0x11223344)

  # 33: store then load of the same address back-to-back (memory ordering)
  li a0, 0x77
  sw a0, 12(s1)
  lw a1, 12(s1)
  CHECK(33, a1, 0x77)

  # 34: byte store into a word then word load (byte enables)
  li a0, -1
  sw zero, 16(s1)
  sb a0, 17(s1)
  lw a1, 16(s1)
  CHECK(34, a1, 0xff00)

  # ---------------------------------------------------------------- branches and jumps
  # 40: taken branch: the two instructions after it must not execute
  li a0, 0
  beq zero, zero, 1f
  addi a0, a0, 1
  addi a0, a0, 2
1:
  CHECK(40, a0, 0)

  # 41: branch comparing a just-computed value (forwarding into the branch unit)
  li a0, 3
  addi a0, a0, -3
  bnez a0, fail_41
  j 2f
fail_41:
  li gp, 41
  j fail
2:

  # 42: branch on a just-loaded value (load-use stall before a branch)
  lw a0, 4(s0)
  bltz a0, 3f
  li gp, 42
  j fail
3:

  # 43: back-to-back taken branches
  li a0, 0
  beqz zero, 4f
  li a0, 99
4:
  beqz zero, 5f
  li a0, 98
5:
  CHECK(43, a0, 0)

  # 44: not-taken branch followed by a taken branch
  li a0, 1
  beqz a0, fail
  bnez a0, 6f
  li gp, 44
  j fail
6:

  # 45: JAL writes the link register and flushes; the link is forwarded immediately
  jal a1, 7f
after_jal:
  li gp, 45
  j fail
7:
  la a2, after_jal
  li gp, 45
  bne a1, a2, fail

  # 46: JALR through a register computed one instruction earlier (forwarded target)
  la a0, 8f
  jalr a1, 0(a0)
  li gp, 46
  j fail
8:

  # 47: JALR with an odd target: bit 0 must be cleared (rv32ui never tests this)
  la a0, 9f
  addi a0, a0, 1
  jalr zero, 0(a0)
  li gp, 47
  j fail
9:

  # 48: JALR through a just-loaded pointer (load-use stall before a jump)
  la a0, fnptr
  lw a1, 0(a0)
  jalr ra, 0(a1)
  CHECK(48, a0, 0x48)   # target function sets a0

  # 49: a short counted loop (backward branch taken many times, then falls through)
  li a0, 0
  li a1, 10
10:
  addi a0, a0, 3
  addi a1, a1, -1
  bnez a1, 10b
  CHECK(49, a0, 30)

  # ---------------------------------------------------------------- x0 and corner cases
  # 50: writes to x0 must not be forwarded
  li a0, 5
  addi zero, a0, 1
  add a1, zero, zero
  CHECK(50, a1, 0)

  # 51: load into x0 must not stall-and-forward a value
  lw zero, 0(s0)
  add a1, zero, zero
  CHECK(51, a1, 0)

  # 52: JAL to x0 (plain jump) followed by use of the old ra
  li ra, 0x52
  j 11f
  li ra, 0
11:
  CHECK(52, ra, 0x52)

  RVTEST_PASS

target_fn:
  li a0, 0x48
  ret

fail:
  RVTEST_FAIL

RVTEST_CODE_END

  .data
RVTEST_DATA_BEGIN
  .align 4
tdat:    .word 0x11223344, 0xffffffff, 0x00000007, 0xff000000
ptr:     .word tdat
fnptr:   .word target_fn
scratch: .space 64
RVTEST_DATA_END
