# Phase 2 — Code Walkthrough

Read this next to the RTL. Everything below refers to the files in `phase2/rtl/`
and `phase2/tb/`. Phase 1's RTL in `phase1/rtl/` is untouched, so you can diff
the two directly — see `phase1_to_phase2.diff` in this folder.

---

## 1. Build and run

```sh
cd "C:/Users/Dell/OneDrive/Desktop/final year"

# Phase 2, default 1-cycle link
iverilog -g2012 -o sim.out phase2/rtl/*.v phase2/tb/tb_chiplet_soc.v
vvp sim.out

# Phase 2, slower link -- no RTL edit needed
iverilog -g2012 -Ptb_chiplet_soc_top.LINK_LATENCY=3          -o sim3.out phase2/rtl/*.v phase2/tb/tb_chiplet_soc.v
vvp sim3.out

# Phase 1 for comparison (full testbench, T1-T8 including MBIST)
iverilog -g2012 -o p1.out phase1/rtl/*.v phase1/tb/tb_chiplet_soc_full.v
vvp p1.out
```

Note: on MSYS2, `./sim.out` may fail with `bad interpreter: /ucrt64/bin/vvp^M`
(a CRLF line ending in the generated wrapper). Always invoke `vvp sim.out`
rather than running the output file directly.

`regression_log.txt` in this folder is a saved run at latency 1, 2, 3 and 5.

---

## 2. Design hierarchy

```
chiplet_soc_top                      <- top level, owns both dies + the link
├── u_chiplet1 : riscv_pipeline_top  <- CHIPLET 1 : RV32I 5-stage core
│   ├── u_imem  : instr_mem          <- 256 x 32 instruction ROM
│   ├── u_rf    : register_file      <- 32 x 32 registers
│   ├── u_alu   : alu
│   ├── u_ctrl  : control_unit       <- opcode decode
│   ├── u_alu_ctrl : alu_control
│   ├── u_imm   : imm_gen            <- immediate extraction + sign extend
│   ├── u_hz    : hazard_unit        <- load-use stall detection
│   └── u_fwd   : forwarding_unit    <- EX/MEM and MEM/WB forwarding
├── u_link     : chiplet_interconnect <- UCIe-inspired die-to-die link
└── u_chiplet2 : mem_io_wrapper      <- CHIPLET 2 : memory die
    ├── u_array : sram_array         <- 256 x 32 SRAM, registered read
    └── u_bist  : march_c_minus_bist <- MBIST engine (March C-)
```

There is **no local data memory in Chiplet-1**. Every `LW`/`SW` leaves the die,
crosses the interconnect, and hits Chiplet-2's SRAM. That is what makes the link
load-bearing during normal operation rather than a test-only connection.

---

## 3. Chiplet-1: the pipeline

Standard 5 stages — IF, ID, EX, MEM, WB — separated by four register banks
named after the boundary they sit on: `if_id_*`, `id_ex_*`, `ex_mem_*`,
`mem_wb_*`. To follow any instruction, track its values through those four
prefixes in order.

### Instruction set actually implemented

Read `control_unit` to confirm: `LW`, `SW`, `BEQ`, `BNE`, `JAL`, and the R/I-type
ALU ops. **`JALR` is not implemented.** Don't claim it in a report.

### Hazards — two separate mechanisms, often confused

**`stall` (from `hazard_unit`)** — the classic load-use hazard. A load is in EX
and the instruction behind it in ID wants the register the load is about to
write. Forwarding cannot save you: the data is not back from memory yet. One
bubble fixes it.

```verilog
assign stall = id_ex_mem_read &&
               ((id_ex_rd == if_id_rs1) || (id_ex_rd == if_id_rs2)) &&
               (id_ex_rd != 5'd0);
```

**`mem_wait`** — nothing to do with data dependencies. The memory access itself
is not finished. This is the signal Phase 2 rewrote; see section 5.

`forwarding_unit` handles the cases that *do not* need a stall, routing results
back from MEM or WB into EX. Priority matters: MEM is checked before WB, because
when both match, MEM holds the newer value.

### The freeze machinery

When `mem_wait` is high, four things hold their state:

| Location | Effect |
|---|---|
| `pc_write = ~stall & ~mem_wait` | PC stops advancing |
| `id_ex_freeze = mem_wait` | ID/EX holds |
| `else if (mem_wait)` in EX/MEM block | EX/MEM holds, address stays stable |
| `else if (mem_wait)` in MEM/WB block | MEM/WB does not capture invalid data |

The comment in the ID/EX block is worth reading carefully — on a freeze it must
**hold**, not bubble. Bubbling there destroys an already-decoded instruction
that nothing will re-fetch, because IF/ID is frozen too. That is a genuinely
subtle bug and the code already gets it right.

---

## 4. Chiplet-2: the memory die

`sram_array` reads are **registered**:

```verilog
always @(posedge clk) begin
    if (we && !(fault_en && (addr == fault_addr))) mem[addr] <= din;
    if (fault_en && (addr == fault_addr)) dout <= fault_val;
    else                                  dout <= mem[addr];
end
```

Two consequences:

1. **Read data appears one cycle after the address.** This is the entire reason
   `mem_wait` exists.
2. Because `dout <= mem[addr]` is non-blocking, a simultaneous read and write to
   the same address returns the **old** value (read-before-write). Safe.

`fault_en`/`fault_addr`/`fault_val` are a verification-only stuck-at fault
injector. Tie `fault_en` low for synthesis.

`mem_io_wrapper` arbitrates the array between normal traffic and the MBIST
engine with `test_mode`: when high, MBIST owns the array; when low, the
functional port does.

---

## 5. What Phase 2 actually changed

This is the core of it. Five edits, each verified before the next.

### Before

```verilog
// in riscv_pipeline_top
reg mem_wait_done;
wire mem_wait = ex_mem_mem_read && !mem_wait_done;   // always exactly 1 cycle

// in chiplet_interconnect
assign c1_mem_ready = 1'b1;                          // link can never stall
assign c2_func_we   = c1_mem_we;

// in chiplet_soc_top
.c1_mem_ready (),                                    // left dangling
```

The CPU faked the memory latency with a local one-shot flag. The link's own
`c1_mem_ready` output was hardwired to 1 **and not even connected**. So the
"interconnect" could not influence the core in any way — it was wires.

### After

**Edit 1 — new handshake ports on the CPU.**
`output mem_req` ("I have a transaction outstanding, addr/we/wdata are stable")
and `input mem_ready` ("it completes at the next edge; for a load, read data is
valid now").

**Edit 2 — `mem_wait` is now sourced from the link.**

```verilog
assign mem_req  = ex_mem_mem_read || ex_mem_mem_write;
wire   mem_wait = mem_req && !mem_ready;
```

`mem_wait_done` is gone. Latency is now a property of the *link*, not a constant
baked into the pipeline.

**Edit 3 — a real transaction engine in the interconnect.**

```verilog
parameter LATENCY = 1;
reg busy; reg [3:0] cnt;

always @(posedge clk or negedge rst_n)
    if (!rst_n)            begin busy <= 0; cnt <= 0; end
    else if (!busy)        begin if (c1_mem_req) begin busy <= 1; cnt <= LATENCY-1; end end
    else if (cnt != 0)     cnt  <= cnt - 1;
    else                   busy <= 0;

assign c1_mem_ready = busy && (cnt == 4'd0);
```

One outstanding transaction at a time. Nothing is registered from the CPU — it
holds address and data stable until the link answers, which is what makes that
safe.

`LATENCY` is clamped to a minimum of 1 via `LAT_EFF`, with a simulation warning.
`LATENCY = 0` is not merely useless, it is actively dangerous: `cnt <= LATENCY-1`
underflows to `4'hF` and the link waits **16** cycles instead of 0. Every
functional test still reports PASS — the answers are correct, just slow — so
nothing catches it. A reminder that a green regression proves what you checked,
and timing was not something these tests check.

**Edit 4 — single-pulse the far-side write enable.**
`assign c2_func_we = c1_mem_we && c1_mem_ready;` The CPU holds `mem_we` high for
the whole transaction, so passing it straight through would re-write the cell on
every cycle of a multi-cycle access.

**Edit 5 — connect it.** `.c1_mem_ready (c1_mem_ready)` in `chiplet_soc_top`,
instead of `()`.

### Cycle-by-cycle: one load at LATENCY=1

| Edge | `busy` | `cnt` | `ready` | `mem_wait` | What happens |
|---|---|---|---|---|---|
| A | 0 | – | 0 | goes 1 | EX/MEM captures the load; address goes out |
| B | 0 to 1 | 0 | 0 | 1 | Everything frozen. SRAM latches `dout <= mem[addr]` |
| C | 1 to 0 | 0 | **1** | 0 | MEM/WB captures valid read data. Done. |

At LATENCY=3, edge B simply repeats three times before C. Nothing else in the
design has to know or care — that is the whole point of a handshake.

---

## 6. The testbench

`phase2/tb/tb_chiplet_soc.v` is **self-checking**: `check_reg` and `check_sram` compare against
expected values, bump an `errors` counter on mismatch, and the run ends with
`ALL TESTS PASSED` or `N CHECK(S) FAILED`. You never have to read a waveform to
know whether it passed. Waveforms are for *diagnosing* a failure, not detecting
one.

### The six tests

| Test | Program | Proves |
|---|---|---|
| T1 | `LW` then dependent `ADD` | Load-use hazard + ALU consumer |
| T2 | Two back-to-back independent `LW` | Consecutive link transactions |
| T3 | `LW` then dependent `BEQ` | Branch resolves on a loaded value |
| T4 | `LW`, `SW`, `LW` to the **same** address | Store commits; reload sees new data, not stale |
| T5 | `ADDI` negative, then `SRAI` | Sign extension; `SRAI` is arithmetic, not logical |
| T6 | `JAL` over two instructions | Jump taken, link register correct, skips not executed |

Each test calls `do_reset`, reloads `instr_mem` and preloads the SRAM through
hierarchical references (`dut.u_chiplet1.u_imem.mem[i]`), runs `RUN_CYCLES`, then
checks final architectural state.

**One trap worth knowing:** `do_reset` deliberately does *not* wait an extra
clock after releasing reset. The program-loading code must land in `instr_mem`
before the first post-reset edge, or the CPU fetches leftovers from the previous
test. The comment in the task says so — do not "tidy" it.

### The instrumentation added in Phase 2

`cycles`, `memwait_cycles`, `stall_cycles`, printed per test by `report_cycles`.
These are not pass/fail checks — they are *expected* to change with latency, and
that is the evidence.

They are cleared **synchronously from reset**, not by a blocking assignment in
`do_reset`. That matters: `do_reset` is called immediately after
`repeat (N) @(posedge clk)`, so its body executes *at* a clock edge. A blocking
`cycles = 0` there lands in the active region and is then overwritten by the
counter block's already-scheduled non-blocking `cycles <= cycles + 1`, so the
counter never actually clears. (This bit us during development: T2 reported 241
cycles instead of 120.) Clearing on `!rst_n` is deterministic.

`RUN_CYCLES = 120` replaced a hard-coded `repeat (40)`. 40 was fine while loads
took a fixed 2 cycles, but at higher link latency the same program needs longer
to finish, and the checks would run before it had — false failures.

---

## 7. The result to put in the report

Same program, same expected values, only `LINK_LATENCY` changed:

| LINK_LATENCY | T1 wait | T2 wait | T4 wait | Checks |
|---|---|---|---|---|
| 1 | 1 | 2 | 3 | 14/14 PASS |
| 2 | 2 | 4 | 6 | 14/14 PASS |
| 3 | 3 | 6 | 9 | 14/14 PASS |
| 5 | 5 | 10 | 15 | 14/14 PASS |

Wait cycles scale **exactly linearly** with link latency — 1 memory op in T1,
2 in T2, 3 in T4 — while every checked value stays identical. That is the proof
of a working handshake: the link genuinely controls the CPU, and the CPU still
computes the right answer no matter how slow the link is.

Compare against Phase 1, where this table could not exist: latency was a
constant inside the CPU and the link's ready signal was not connected.

### A bug this found

In Phase 1, `mem_wait` keyed off `ex_mem_mem_read` only. **Stores waited zero
cycles** — fire-and-forget, the CPU never learned whether the far die accepted
the write. The counters made it visible: T4 has three memory operations but
reported only two wait cycles. Survivable when the "link" was a wire; with real
latency, the next instruction could issue a second transaction on top of one
still in flight. Fixed by Edit 2's `|| ex_mem_mem_write`. T4 now reports 3, 9
and 15.

---

## 8. Known gaps — be honest about these if asked

- **Single clock domain, by design.** Agreed at the 24 Aug review for the whole
  project, so this is a requirement, not a gap. Worth being able to say why it
  is a simplification: a real die-to-die link usually crosses clock domains and
  would need CDC logic (synchronizers, async FIFOs).
- **No link training, packetization or serialization.** Mainband is still a wide
  parallel bus, not lanes. "UCIe-inspired" refers to the architectural split
  (mainband vs. sideband) and now a real transaction protocol — not to UCIe
  electrical or packet compliance. Say it that way.
- **Sideband is still pass-through.** The MBIST control/status path is parallel
  wires. Giving it a narrow serialized packet format is the most genuinely
  UCIe-like thing left to add.
- **One outstanding transaction.** No pipelining, no multiple in flight.
- **`link_test_mode` and `link_low_power` are still unused.**
- **The synthesis reports in the parent folder are stale.** `area.rep`,
  `gates.rep`, `power.rep`, `check.rep` are dated Sep 15, before the
  interconnect work. `area.rep` lists only `u_chiplet2` — `u_chiplet1` and
  `u_link` are absent from the hierarchy, and `check.rep` shows 152 undriven
  hierarchical pins. **Re-run Genus before quoting any area/power/gate numbers.**
- **No coverage measurement.** Six directed tests is reasonable for this scope,
  but "we tested it" is currently a claim, not a number.
- **The Phase 2 testbench has no MBIST tests.** `phase1/tb/tb_chiplet_soc_full.v`
  has T7 (MBIST clean pass) and T8 (MBIST detects an injected stuck-at fault)
  which the Phase 2 testbench does not carry. Porting them across is a small,
  worthwhile job -- the MBIST engine is still in the design and currently goes
  unexercised by the Phase 2 regression.

---

## 9. Suggested order for your study day

1. Run the sim at latency 1 and 3. See the counters change, the values not.
2. Read `control_unit` and confirm the actual instruction set for yourself.
3. Trace T1 by hand through the four pipeline-register prefixes.
4. Read `hazard_unit`, then find every use of `mem_wait`. Convince yourself the
   two stall mechanisms are independent.
5. Hand-trace the table in section 5 against the `busy`/`cnt` FSM.
6. Break something on purpose and watch a test fail. A regression you have
   never seen fail is a regression you do not trust. Good ones to try:
   - Revert `mem_req` to `ex_mem_mem_read` only while leaving `c2_func_we`
     gated on `c1_mem_ready`. T4's store check fails: `sram[0]` still holds 55.
     This is a genuinely dropped write.
   - Put back `ex_mem_mem_write <= 1'b0;` in the EX/MEM `mem_wait` branch.
   - Remove the `!rst_n` clear from the counter block and zero them in
     `do_reset` instead. The counters stop resetting between tests.
   - Set `RUN_CYCLES` back to 40 and run at `LINK_LATENCY=5`.
