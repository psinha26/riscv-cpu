#!/usr/bin/env python3
"""Split an RV32 ELF into the two $readmemh images the SoC loads.

  elf2hex.py prog.elf out_prefix      ->  out_prefix.imem.hex, out_prefix.dmem.hex

Reads the loadable segments (PT_LOAD) directly from the ELF, so no extra tools are needed:
bytes at 0x0000_0000.. go to instruction ROM, bytes at 0x1000_0000.. go to data RAM.
Output is one little-endian 32-bit word per line, starting at the memory's base address.
"""
import struct
import sys

IMEM_BASE, DMEM_BASE, MEM_BYTES = 0x00000000, 0x10000000, 64 * 1024


def segments(path):
    data = open(path, "rb").read()
    if data[:4] != b"\x7fELF" or data[4] != 1:
        sys.exit(f"{path}: not a 32-bit ELF")
    e_phoff, = struct.unpack_from("<I", data, 28)
    e_phentsize, e_phnum = struct.unpack_from("<HH", data, 42)
    for i in range(e_phnum):
        p_type, p_offset, _vaddr, p_paddr, p_filesz, _memsz = struct.unpack_from(
            "<IIIIII", data, e_phoff + i * e_phentsize)
        if p_type == 1 and p_filesz:  # PT_LOAD with file contents (.bss has none)
            yield p_paddr, data[p_offset:p_offset + p_filesz]


def main():
    elf, prefix = sys.argv[1], sys.argv[2]
    images = {"imem": bytearray(), "dmem": bytearray()}
    for addr, blob in segments(elf):
        for name, base in (("imem", IMEM_BASE), ("dmem", DMEM_BASE)):
            if base <= addr < base + MEM_BYTES:
                off = addr - base
                if off + len(blob) > MEM_BYTES:
                    sys.exit(f"{elf}: segment at {addr:#x} overflows {name}")
                img = images[name]
                img.extend(b"\0" * max(0, off + len(blob) - len(img)))
                img[off:off + len(blob)] = blob
                break
        else:
            sys.exit(f"{elf}: segment at {addr:#x} is outside ROM and RAM")
    for name, img in images.items():
        img.extend(b"\0" * (-len(img) % 4))
        with open(f"{prefix}.{name}.hex", "w") as f:
            for i in range(0, len(img), 4):
                f.write(f"{struct.unpack_from('<I', img, i)[0]:08x}\n")


if __name__ == "__main__":
    main()
