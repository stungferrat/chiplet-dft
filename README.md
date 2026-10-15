# Design and Verification of a Low-Power Scan-Based Test Architecture for Chiplets

A two-chiplet system in Verilog: an RV32I pipelined core on one die (tested
with scan + ATPG), an SRAM memory die on the other (tested with MBIST), joined
by a UCIe-inspired die-to-die link. Scope and decisions are recorded in
`docs/mom_2026-08-24_phase1_review.md`.

```
docs/                         Project-level diagrams
  guide_target_architecture.jpeg  Guide's target DFT architecture (test controller,
                                  scan, MISR, low-power gating) - NOT yet built
  methodology_block_diagram.png Phase 1 methodology diagram, used in the PPT
  PROJECT_HISTORY.md            START HERE: decisions, timeline, open items
  mom_2026-08-24_phase1_review.md  Minutes of the Phase 1 review: agreed scope,
                                  open decisions, action items

phase1/                       Phase 1 deliverable - frozen, do not edit
  rtl/                          Design, one file per logical block
  tb/
    tb_chiplet_soc_full.v         T1-T8, includes the MBIST tests
    tb_chiplet_soc_cpu.v          T1-T6, MBIST stripped for the presentation
  waveforms/                    SimVision captures used in the Phase 1 report

phase2/                       Phase 2 - real interconnect handshake
  rtl/                          Same four blocks, with the link rewritten
  tb/tb_chiplet_soc.v           T1-T6 plus cycle-count instrumentation
  WALKTHROUGH.md                READ THIS - full code tour and explanation
  phase1_to_phase2.diff         Exactly what changed between the phases
  regression_log.txt            Saved run at link latency 1, 2, 3 and 5

phase3/                       Phase 3 - DFT build (in progress)
  rtl/                          Synthesis-ready: instr_mem load port,
                                fault-injection ports only under -DSIM
  tb/tb_chiplet_soc.v           T1-T8: loads programs through the port,
                                includes the MBIST tests. Needs -DSIM.
  tb/tb_core_verify.v           Model-checked regression (312 programs + MBIST edges)
  verif/gen_tests.py            Reference model + directed/random test generator
  verif/vectors/                Pre-generated tests (no Python needed to run them)
  verif/mutation_check.py       Proves the regression catches deliberate bugs
  verif/run_xcelium_verify.sh   Runs the model-checked regression on Xcelium
  phase2_to_phase3.diff         What changed from Phase 2
  regression_log.txt            Saved run at link latency 1, 2, 3 and 5
```

## Running

```sh
# Phase 3 (current) -- note -DSIM, required
iverilog -g2012 -DSIM -o sim.out phase3/rtl/*.v phase3/tb/tb_chiplet_soc.v
vvp sim.out

# Phase 2
iverilog -g2012 -o sim.out phase2/rtl/*.v phase2/tb/tb_chiplet_soc.v
vvp sim.out

# Phase 2 with a slower link (no RTL edit needed)
iverilog -g2012 -Ptb_chiplet_soc_top.LINK_LATENCY=3 \
         -o sim3.out phase2/rtl/*.v phase2/tb/tb_chiplet_soc.v
vvp sim3.out

# Phase 1, full testbench including MBIST
iverilog -g2012 -o p1.out phase1/rtl/*.v phase1/tb/tb_chiplet_soc_full.v
vvp p1.out
```

Invoke `vvp sim.out`, not `./sim.out` — on MSYS2 the generated wrapper has a
CRLF shebang and fails with `bad interpreter: /ucrt64/bin/vvp^M`.

Both testbenches are self-checking: they end in `ALL TESTS PASSED` or
`N CHECK(S) FAILED`. You do not need to read a waveform to know whether it
passed.

## Current status

| | Checks | Result |
|---|---|---|
| Phase 3, model-checked: 312 programs + 7 MBIST cases, latency 1/2/3/5 | 89,838 values each | all pass (after BNE fix + illegal-instruction NOPs) |
| Phase 3, 1,012 programs, different seed, latency 1/3 | | all pass |
| Phase 3, deliberate-bug check | 11 bugs | all 11 caught |
| Phase 3 new tests run on the *old* decoder | 312 programs | 184 fail, as they should |
| Phase 3, latency 1/2/3/5 (T1–T8) | 16 each | all pass |
| Phase 1, full TB (T1–T8) | 16 | all pass |
| Phase 1, CPU TB (T1–T6) | 14 | all pass |
| Phase 2, latency 1/2/3/5 | 14 each | all pass |

Phase 2's headline result: raising `LINK_LATENCY` scales the pipeline's stall
cycles exactly linearly while every checked value stays identical — proof that
the link really controls the CPU. Details in `phase2/WALKTHROUGH.md`.

## Known gaps

Read `phase2/WALKTHROUGH.md` section 8 before any review or viva. The short
version:

- **"UCIe-inspired" is architectural, not protocol compliance.** The mainband /
  sideband split and the transaction handshake are real; link training,
  packetization, serialization and lane management are not implemented.
- **A subset of RV32I, not full RV32I.** The core implements `ADD SUB AND OR
  XOR SLT SLL SRL SRA`, `ADDI ANDI ORI XORI SLTI SLLI SRLI SRAI`, `LW`, `SW`,
  `BEQ`, `BNE`, `JAL`. Not implemented: `JALR`, `LUI`, `AUIPC`, `SLTU`/`SLTIU`,
  `BLT`/`BGE`/`BLTU`/`BGEU`, byte/halfword loads and stores, `FENCE`/`ECALL`.
  Any unsupported instruction executes as a **NOP** (checked by test D11). The
  RISC-V spec says it should raise an illegal-instruction exception; this core
  has no exception logic, so the NOP is a deliberate simplification.
- **Single clock domain, by design.** Agreed at the 24 Aug review for the whole
  project. A real die-to-die link would usually cross clock domains; this one
  deliberately does not.
- **No synthesis results.** The old Genus reports were stale — they predated the
  interconnect and `area.rep` did not even contain Chiplet-1 or the link — so
  they were deleted rather than left to be quoted by mistake. Re-run synthesis
  before using any area, power or gate-count number.
- **No coverage measurement.** The directed tests are reasonable for this scope,
  but coverage is currently a claim, not a number.
