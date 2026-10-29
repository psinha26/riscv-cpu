# Branch target buffer aliasing test.
#
# The BTB is indexed by pc[5:2] and tagged with an 8-bit partial tag (pc[13:6]), so two
# branches exactly 16 KB apart map to the same entry with the same tag: the predictor cannot
# tell them apart. Branch A trains the entry with its target; then branch B, 16 KB later,
# hits A's entry and is predicted taken to A's target. The core must notice in EX that the
# predicted target is wrong and redirect to B's real target. If it doesn't, execution
# continues at A's target and the test fails. (Without a BTB, this is just two taken branches.)

#include "riscv_test.h"

RVTEST_RV32U
RVTEST_CODE_BEGIN

  li s0, 3              # train A three times so its counter is strongly taken
  li s1, 0              # path log: each landing adds a distinct bit
train:
  j branch_a            # (JAL into the aligned block below)
after_a:
  addi s0, s0, -1
  bnez s0, train

  li gp, 2
  j branch_b            # now execute B, which aliases A's BTB entry
after_b:
  li t0, 0x10           # B must have landed on target_b (bit 4), never target_a again
  andi t1, s1, 0x30
  bne t1, t0, fail
  RVTEST_PASS

fail:
  RVTEST_FAIL

  .balign 0x4000
branch_a:
  beqz zero, target_a   # always taken: trains the shared BTB entry
  j fail
target_a:
  ori s1, s1, 0x1
  j after_a

  .balign 0x4000        # branch_b is exactly 16 KB after branch_a
branch_b:
  beqz zero, target_b   # always taken, but predicted with A's target
  j fail
  nop
  nop
target_b:
  ori s1, s1, 0x10
  andi s1, s1, 0x10     # clear the training bits so after_b sees only B's landing
  j after_b

RVTEST_CODE_END

  .data
RVTEST_DATA_BEGIN
RVTEST_DATA_END
