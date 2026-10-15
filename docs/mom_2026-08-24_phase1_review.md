# Design and Verification of a Low-Power Scan-Based Test Architecture for Chiplets

**Date:** 24 August 2026
**Meeting type:** Phase 1 Review with Project Guide

## 1. Purpose

Present Phase 1 work and agree on the plan of work until the next review.

## 2. Approach Finalized

The project will follow a heterogeneous chiplet approach — one compute chiplet
(Chiplet-1: RISC-V RV32I, tested with scan + ATPG) and one memory chiplet
(Chiplet-2: pure SRAM, tested with MBIST). This gives correct fault coverage,
since scan alone can't catch memory faults, and better reflects real chiplet
systems. Both chiplets are designed separately but share the same UCIe link,
test controller, and MISR-based reporting.

## 3. Key Points Discussed

- Title and block diagram are finalized — no changes needed.
- Reaching the gate-level netlist stage is a sufficient milestone for the next
  review.
- Chiplet-2 open decisions: MBIST-only vs. MBIST + scan insertion, and
  single-port vs. dual-port SRAM.
- UCIe interfacing for Chiplet-2 is confirmed.
- Flow to follow: RTL → Synthesis → Gate-level netlist → Scan stitching →
  Coverage/switching check → Low-power optimization. Register files need
  special care during scan stitching.
- Entire project (both chiplets) uses a single clock domain.

## 4. Action Items

| # | Action Item | Target |
|---|---|---|
| 1 | Complete RTL for both chiplets (RV32I core + SRAM memory) | Before next review |
| 2 | Decide MBIST-only vs. MBIST + Scan for memory chiplet | Before synthesis |
| 3 | Decide single-port vs. dual-port SRAM configuration | Before synthesis |
| 4 | Run synthesis to get gate-level netlist for both chiplets | Before next review |
| 5 | Perform scan stitching (careful with register files) | After synthesis |
| 6 | Maintain single clock domain across full design | Ongoing |

## 5. Future Scope (Not Immediate)

Fault repair (memory chiplet) and physical design are planned for later phases,
after RTL/synthesis/scan work is reviewed. Design should stay clean enough to
add these later without rework.

## 6. Next Steps

Next meeting will review RTL status, synthesis results and gate-level netlist.
