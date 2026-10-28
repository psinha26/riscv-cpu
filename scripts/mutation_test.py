#!/usr/bin/env python3
"""Mutation testing: does the verification actually catch bugs?

Each mutation injects one realistic hardware bug into a copy of the RTL (break a forwarding
path, drop the load-use stall, ...), rebuilds the pipelined simulator and runs the test suites.
A mutation is "killed" if at least one test fails. A surviving mutation means a hole in the
tests.

  python3 scripts/mutation_test.py [--suite rv32ui|hazards|all]
"""
import argparse
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

# (name, file, regex, replacement)
MUTATIONS = [
    ("no EX/MEM -> EX forwarding", "hazard_unit.sv", r"fwd_sel = 2'd1;", "fwd_sel = 2'd0;"),
    ("no MEM/WB -> EX forwarding", "hazard_unit.sv", r"fwd_sel = 2'd2;", "fwd_sel = 2'd0;"),
    ("forwarding priority reversed", "hazard_unit.sv",
     r"if \(ex_valid && ex_reg_we && ex_rd != 5'd0 && ex_rd == rs\)",
     "if (ex_valid && ex_reg_we && ex_rd != 5'd0 && ex_rd == rs && !(mem_valid && mem_reg_we && mem_rd == rs))"),
    ("forward from x0", "hazard_unit.sv", r"ex_rd != 5'd0 && ", ""),
    ("no load-use stall", "hazard_unit.sv", r"assign load_use = ex_valid", "assign load_use = 1'b0 && ex_valid"),
    ("load-use ignores rs2", "hazard_unit.sv", r"\|\| \(id_uses_rs2 && id_rs2 == ex_rd\)", ""),
    ("no flush of ID on taken branch", "hazard_unit.sv", r"assign flush_id  = kill;", "assign flush_id  = ex_trap;"),
    ("no bubble into EX on taken branch", "hazard_unit.sv", r"assign bubble_ex = kill \|\| load_use;",
     "assign bubble_ex = ex_trap || load_use;"),
    ("register file has no WB->ID bypass", "core_pipe.sv", r"regfile #\(.BYPASS\(1'b1\)\)", "regfile #(.BYPASS(1'b0))"),
    ("store data not forwarded", "core_pipe.sv", r"mem_store  <= rs2_fwd;", "mem_store  <= ex_rs2_val;"),
    ("JALR does not clear bit 0", "core_pipe.sv", r"\{alu_y\[31:1\], 1'b0\}", "alu_y"),
    ("SRA behaves as SRL", "alu.sv", r"ALU_SRA:  y = \$unsigned\(\$signed\(a\) >>> shamt\);", "ALU_SRA:  y = a >> shamt;"),
    ("SLT compares unsigned", "alu.sv", r"ALU_SLT:  y = \{31'b0, lt_s\};", "ALU_SLT:  y = {31'b0, lt_u};"),
    ("adder drops a carry (bit 16)", "prefix_adder.sv", r"assign carry = \{g\[LEVELS\*W \+: W-1\], cin\};",
     "assign carry = {g[LEVELS*W+16 +: W-17], 1'b0, g[LEVELS*W +: 15], cin};"),
    ("LB zero-extends", "lsu.sv", r"\{\{24\{shifted\[7\]\}\}, shifted\[7:0\]\};    // LB", "{24'b0, shifted[7:0]};    // LB"),
    ("SH writes the wrong lanes", "lsu.sv", r"wstrb = off\[1\] \? 4'b1100 : 4'b0011;", "wstrb = 4'b0011;"),
    ("B-immediate bit 11 dropped", "imm_gen.sv", r"insn\[31\], insn\[7\], insn\[30:25\]", "insn[31], 1'b0, insn[30:25]"),
    ("BGEU acts as BGE", "branch_unit.sv", r"3'b111:  taken = !lt_u;", "3'b111:  taken = !lt_s;"),
]


def build(rtl_dir: Path, out: Path):
    files = [rtl_dir / f for f in ["prefix_adder.sv", "branch_predictor.sv", "alu.sv", "imm_gen.sv", "branch_unit.sv", "regfile.sv", "lsu.sv",
                                    "decoder.sv", "hazard_unit.sv", "core_single.sv", "core_pipe.sv", "soc.sv"]]
    cmd = ["verilator", "--cc", "--exe", "--build", "-j", "0", "-O1", "--x-assign", "fast", "--x-initial", "fast",
           "--trace", "-Wno-fatal", "-Wno-lint", "-Wno-style", f"-I{rtl_dir}", "--top-module", "soc", "-GPIPELINED=1",
           "-CFLAGS", f"-I{ROOT / 'sim'}", "--Mdir", str(out), *map(str, files),
           str(ROOT / "tb/tb_soc.cpp"), str(ROOT / "sim/iss.cpp")]
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0 or not (out / "Vsoc").exists():
        raise RuntimeError("build failed:\n" + r.stdout[-2000:] + r.stderr[-2000:])
    return out / "Vsoc"


def tests(suite):
    build_dir = ROOT / "build"
    out = []
    if suite in ("rv32ui", "all"):
        out += sorted(p for p in (build_dir / "tests").glob("*.imem.hex"))
    if suite in ("hazards", "all"):
        out += sorted(p for p in (build_dir / "hazards").glob("*.imem.hex"))
    if not out:
        sys.exit("no test images found; run `make test` (and `make hazards`) first")
    return out


def run_all(sim, images):
    failed = []
    for img in images:
        base = str(img)[: -len(".imem.hex")]
        r = subprocess.run([str(sim), "--imem", f"{base}.imem.hex", "--dmem", f"{base}.dmem.hex", "--mode", "test",
                            "--quiet", "--max-cycles", "200000"], capture_output=True)
        if r.returncode != 0:
            failed.append(Path(base).name)
    return failed


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--suite", default="all", choices=["rv32ui", "hazards", "all"])
    a = ap.parse_args()
    images = tests(a.suite)
    with tempfile.TemporaryDirectory() as td:
        td = Path(td)
        base_sim = build(ROOT / "rtl", td / "base")
        base_fail = run_all(base_sim, images)
        if base_fail:
            sys.exit(f"unmutated design fails: {base_fail}")
        print(f"unmutated design passes all {len(images)} tests\n")
        survivors = 0
        for name, fname, pat, rep in MUTATIONS:
            rtl = td / "rtl"
            if rtl.exists():
                shutil.rmtree(rtl)
            shutil.copytree(ROOT / "rtl", rtl)
            src = (rtl / fname).read_text()
            new, n = re.subn(pat, rep, src)
            if n == 0:
                sys.exit(f"mutation '{name}' did not apply (pattern not found in {fname})")
            (rtl / fname).write_text(new)
            sim = build(rtl, td / "mut")
            failed = run_all(sim, images)
            survivors += not failed
            shown = ", ".join(failed[:6]) + (" ..." if len(failed) > 6 else "")
            print(f"{'KILLED ' if failed else 'SURVIVED'} {name:38} {len(failed):3}/{len(images)} tests fail  {shown}")
        print(f"\n{len(MUTATIONS) - survivors}/{len(MUTATIONS)} injected bugs caught")
        sys.exit(1 if survivors else 0)


if __name__ == "__main__":
    main()
