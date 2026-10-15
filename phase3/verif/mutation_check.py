"""
mutation_check.py -- does the regression actually catch bugs?

Makes throwaway copies of the RTL, each with ONE deliberate bug in a
hard-to-get-right area, runs tb_core_verify on each, and reports whether
the bug was caught. A good regression catches every one. Run from
phase3/verif:   python mutation_check.py
The real RTL in ../rtl is never modified.
"""
import os, shutil, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
RTL = os.path.join(HERE, "..", "rtl")
TB = os.path.join(HERE, "..", "tb", "tb_core_verify.v")

MUTANTS = [
    ("forwarding: WB checked before MEM (older value wins)", "riscv_pipeline_top.v",
     "        if (mem_reg_write && (mem_rd != 5'd0) && (mem_rd == ex_rs1))\n            fwd_a = 2'b01;\n        else if (wb_reg_write && (wb_rd != 5'd0) && (wb_rd == ex_rs1))\n            fwd_a = 2'b10;",
     "        if (wb_reg_write && (wb_rd != 5'd0) && (wb_rd == ex_rs1))\n            fwd_a = 2'b10;\n        else if (mem_reg_write && (mem_rd != 5'd0) && (mem_rd == ex_rs1))\n            fwd_a = 2'b01;", 1),
    ("hazard unit never stalls (load-use ignored)", "riscv_pipeline_top.v",
     "    assign stall = id_ex_mem_read &&", "    assign stall = 1'b0 && id_ex_mem_read &&", 1),
    ("register-file write-through bypass removed", "riscv_pipeline_top.v",
     "(we && (wa == ra1)) ? wd : regs[ra1]", "regs[ra1]", 1),
    ("CPU ignores the link's ready (no backpressure)", "riscv_pipeline_top.v",
     "    wire mem_wait = mem_req && !mem_ready;", "    wire mem_wait = 1'b0;", 3),
    ("forwarding ignores x0 guard", "riscv_pipeline_top.v",
     "        if (mem_reg_write && (mem_rd != 5'd0) && (mem_rd == ex_rs2))",
     "        if (mem_reg_write && (mem_rd == ex_rs2))", 1),
    # --- added with the illegal-instruction / x0 hardening ---
    ("forwarding from WB ignores x0 guard (rs1)", "riscv_pipeline_top.v",
     "        else if (wb_reg_write && (wb_rd != 5'd0) && (wb_rd == ex_rs1))",
     "        else if (wb_reg_write && (wb_rd == ex_rs1))", 1),
    ("forwarding from MEM ignores x0 guard (rs1)", "riscv_pipeline_top.v",
     "        if (mem_reg_write && (mem_rd != 5'd0) && (mem_rd == ex_rs1))\n            fwd_a = 2'b01;\n        else if (wb_reg_write",
     "        if (mem_reg_write && (mem_rd == ex_rs1))\n            fwd_a = 2'b01;\n        else if (wb_reg_write", 1),
    ("register-file bypass forwards writes to x0", "riscv_pipeline_top.v",
     "    assign rd1 = (ra1 == 5'd0) ? 32'd0 :\n                 (we",
     "    assign rd1 = (we", 1),
    ("decoder legality check bypassed entirely", "riscv_pipeline_top.v",
     "        if (legal) case (opcode)", "        if (1'b1) case (opcode)", 1),
    ("SLTU accepted (runs as ADD)", "riscv_pipeline_top.v",
     "legal = ((funct7 == 7'b0000000) && (funct3 != 3'b011)) ||",
     "legal = ((funct7 == 7'b0000000)) ||", 1),
    ("BLT/BGE/BLTU/BGEU accepted (run as BEQ)", "riscv_pipeline_top.v",
     "OP_BRANCH: legal = (funct3 == 3'b000) ||", "OP_BRANCH: legal = 1'b1 ||", 1),
]


def main():
    caught = 0
    for name, fname, old, new, latency in MUTANTS:
        tmp = tempfile.mkdtemp()
        for f in os.listdir(RTL):
            if f.endswith(".v"):
                shutil.copy(os.path.join(RTL, f), tmp)
        path = os.path.join(tmp, fname)
        src = open(path, encoding="utf-8").read()
        if src.count(old) != 1:
            print("SETUP ERROR, pattern not found: " + name)
            sys.exit(1)
        open(path, "w", encoding="utf-8", newline="\n").write(src.replace(old, new))
        out = os.path.join(tmp, "m.out")
        rtl = [os.path.join(tmp, f) for f in os.listdir(tmp) if f.endswith(".v")]
        subprocess.run(["iverilog", "-g2012", "-DSIM", "-Ptb_core_verify.LINK_LATENCY=%d" % latency,
                        "-o", out] + rtl + [TB], check=True, cwd=HERE)
        log = subprocess.run(["vvp", out], capture_output=True, text=True, cwd=HERE).stdout
        summary = [l.strip() for l in log.splitlines() if "CPU tests:" in l]
        ok = "ALL TESTS PASSED" not in log
        caught += ok
        print("%-8s %-52s %s" % ("CAUGHT" if ok else "MISSED", name, summary[0] if summary else ""))
        shutil.rmtree(tmp, ignore_errors=True)
    print("\n%d of %d deliberate bugs caught" % (caught, len(MUTANTS)))


if __name__ == "__main__":
    main()
