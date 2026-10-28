/* Linker script matching the SoC memory map (rtl/soc.sv).
 * Code goes in the 64 KB instruction ROM at 0x0; everything the program loads or stores
 * (.rodata, .data, .bss, stack) goes in the 64 KB data RAM at 0x1000_0000, because the core's
 * load/store port can only reach data RAM and MMIO (a Harvard architecture).
 * The simulator preloads both memories from hex files, so .data needs no copy loop. */
OUTPUT_ARCH("riscv")
ENTRY(_start)

MEMORY
{
  ROM (rx)  : ORIGIN = 0x00000000, LENGTH = 64K
  RAM (rwx) : ORIGIN = 0x10000000, LENGTH = 64K
}

SECTIONS
{
  .text : {
    *(.text.init)
    *(.text .text.*)
  } > ROM

  .rodata : { *(.rodata .rodata.* .srodata .srodata.*) } > RAM
  .data : {
    *(.data .data.*)
    __global_pointer$ = . + 0x800;
    *(.sdata .sdata.*)
  } > RAM
  .bss (NOLOAD) : {
    __bss_start = .;
    *(.sbss .sbss.* .bss .bss.* COMMON)
    . = ALIGN(4);
    __bss_end = .;
  } > RAM

  __stack_top = ORIGIN(RAM) + LENGTH(RAM);
  /DISCARD/ : { *(.comment) *(.riscv.attributes) *(.note*) *(.eh_frame*) }
}
