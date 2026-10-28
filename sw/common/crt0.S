# Bare-metal C startup: set up the stack and global pointer, zero .bss, call main(),
# then halt with ECALL. main's return value stays in a0, which the testbench reports as the
# exit code (.data needs no copy loop: the simulator preloads data RAM from the hex image).
  .section .text.init
  .globl _start
_start:
  la   sp, __stack_top
  .option push
  .option norelax
  la   gp, __global_pointer$
  .option pop

  la   t0, __bss_start
  la   t1, __bss_end
1:
  bgeu t0, t1, 2f
  sw   zero, 0(t0)
  addi t0, t0, 4
  j    1b
2:
  call main
  ecall          # a0 = return value of main
3:
  j    3b
