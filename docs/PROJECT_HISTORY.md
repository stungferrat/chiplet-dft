# Project history and decisions

How the project got to where it is, and *why* things are the way they are.
Read this before changing the design. For the code itself, see
`phase2/WALKTHROUGH.md`; for current status and known gaps, see `README.md`.

## The project

**Design and Verification of a Low-Power Scan-Based Test Architecture for
Chiplets.** The target architecture is the guide's block diagram,
`docs/guide_target_architecture.jpeg`: a test controller, scan chains,
low-power scan gating, a MISR with a golden signature, and pass/fail
diagnosis.

| Part | What it is | How it is tested |
|---|---|---|
| Chiplet-1 | 5-stage pipelined RV32I core (a subset; see README) | Scan + ATPG |
| Chiplet-2 | 256 x 32 SRAM + March C- MBIST controller | MBIST for the array, scan for its logic |
| Link | UCIe-*inspired* die-to-die interconnect (mainband + sideband) | Deferred |

## Decisions and the reasons for them

- **Compute + memory, not two compute chiplets.** The guide's diagram was
  drawn for two compute chiplets. We chose compute + memory because it is
  more realistic. Consequence: Chiplet-2's SRAM uses MBIST, not scan,
  because scanning 8,192 memory flops is impractical and scan does not
  target memory faults.
- **Scan on Chiplet-2's logic as well.** MBIST alone cannot detect a fault
  in the MBIST controller itself, which could then report "pass" on a bad
  memory. Scanning the small controller logic closes that gap.
- **Single clock domain, including scan.** A fixed requirement from the
  guide, not a shortcut.
- **One shared MISR, chiplets tested one after the other.** The scheduler
  tests Chiplet-1, resets the MISR, then tests Chiplet-2. A mismatch
  therefore identifies the failing chiplet. Only one chiplet shifts at a
  time, which lowers peak test power: a low-power argument in its own right.
- **Single-port SRAM.** The CPU issues one memory request at a time, so a
  second port would never be used. Dual-port memory also needs extra MBIST
  fault models.
- **Scan chains are inserted by Genus during synthesis, not written in
  RTL.** MBIST, the test controller and the MISR *are* hand-written RTL.
- **The register file needs care during scan stitching** (the guide flagged
  this). It is the largest flop group in Chiplet-1 and the main source of
  shift power.
- **Interconnect fault testing is deferred.**

## The 7-step plan

1. RTL fixes for synthesis: `instr_mem` load port, fault-injection ports
   simulation-only. **Done.**
2. New DFT RTL: test controller, MISR + comparator, low-power scan gating.
   **Next.**
3. Thorough functional verification: every instruction, random programs
   checked against a reference model, coverage via Xcelium. **Done except
   the coverage number.**
4. Genus synthesis + clock gating + scan insertion, per chiplet.
5. Golden signature from the fault-free netlist.
6. ATPG + fault coverage (Modus).
7. Low-power result: test power with vs. without gating.

## Timeline

### Phase 1 (Sep 2026)
- Code review found that **the instruction after every `LW` was silently
  dropped** (ID/EX was bubbled instead of held during the memory wait).
  Fixed by splitting `id_ex_freeze` from `id_ex_bubble`. `SRA`/`SRAI`
  added.
- An experimental packetized interconnect was built and then reverted. The
  Phase 1 report used the simple version (14/14 checks pass).
- Lesson: OneDrive sync silently reverted files more than once. That is
  why the project now lives in git.

### Phase 2 (Oct 10)
- The "interconnect" was only wires: `c1_mem_ready` was tied to 1 and left
  unconnected. It now has a real `req`/`ready` handshake with a
  `LINK_LATENCY` parameter, and the CPU freezes for exactly as long as the
  link says.
- Proof: wait cycles scale linearly with latency (T4: 3 / 6 / 9 / 15 at
  latency 1 / 2 / 3 / 5) while every checked value stays identical.
- Bugs found along the way: stores never waited for the link; gating the
  write enable dropped the write; `LATENCY = 0` underflowed the counter.

### Phase 3 (Oct 12 onward)
- **Oct 12:** `instr_mem` got a hardware load port. Without it, synthesis
  treats the program as constant and removes most of the core (very likely
  why the old Sep 15 synthesis report had no `u_chiplet1`). Fault-injection
  ports exist only under `-DSIM`.
- **Oct 13, first lab day.** Tools: Xcelium 22.09, Genus 21.1, Conformal
  21.1, `imc` (Incisive 15.2). `slow.lib` has scan flops. **Modus is not
  installed**; the lab will install it on request for one month only, so
  request it once the scan-inserted netlist is ready. The regression
  passed on Xcelium.
- **Oct 13, verification hardening.** A Python reference model plus random
  programs found that **`BNE` executed as `BEQ`** (fixed in phase3 only;
  phase1/phase2 still have it). 5 of 5 deliberately planted bugs caught.
- **Oct 15:** unsupported instructions now execute as NOPs (they used to
  run as other instructions, e.g. `SLTU` as `ADD`). Stronger `x0` tests.
  312/312 programs pass; 11 of 11 planted bugs caught. See
  `phase3/changes_2026-10-15.diff` and `phase3/verif/verify_log.txt`.

## Open items

- Coverage number from Xcelium (`phase3/verif/run_xcelium_verify.sh`, then
  `imc -load cov_work/scope/verify`).
- First trial synthesis (`phase3/syn/genus_trial.tcl`). It has never been
  run.
- `instr_mem` is 256 words (8,192 flops) and would dominate Chiplet-1's
  area. Proposal: cut to 128 words and keep it out of scan.
- Step 2 DFT RTL.

## Lab notes

College Cadence lab: run `csh`, then `source /home/install/cshrc`. Work folder
`cadence/Digital2026/<USN>`. Library: `/home/cadence/Desktop/rcfiles/lib/slow.lib`.
Files copied from Windows need line endings stripped (see
`phase3/LAB_CHECKLIST.md`). If Xcelium says "Permission denied", the folder is
owned by root; fix the ownership. In the lab, run `git clone` or `git pull`
instead of copying zips.
