// =============================================================
// chiplet_interconnect.v
// UCIe-inspired die-to-die link, split into two logical channels
// matching the real UCIe architecture:
//
//   MAINBAND : high-speed functional data path. Carries
//              Chiplet-1's (RV32I core) load/store traffic to
//              Chiplet-2's (mem_io_chiplet) SRAM.
//
//   SIDEBAND : low-speed, always-on control/test/debug path.
//              Carries MBIST control (test_mode, bist_start) and
//              status (bist_busy/done/pass/fail_addr) between the
//              top-level Test Controller and Chiplet-2's MBIST
//              engine. This is what a real UCIe link uses for
//              DFx (Design-for-test/debug/telemetry): link
//              training, register access, compliance/debug
//              access -- kept logically and, in RTL, physically
//              separate from mainband functional traffic.
//
// Single clock domain for now (Phase 1 simplification). Both
// channels are "always ready" thin plumbing today; a future phase
// can add real handshaking / multi-cycle sideband framing without
// touching either chiplet's port list.
//
// link_test_mode / link_low_power remain reserved for a future
// phase (interconnect self-test, low-power link gating).
// =============================================================
`timescale 1ns/1ps

module chiplet_interconnect (
    input         clk,
    input         rst_n,

    // ===========================================================
    // MAINBAND -- functional data path
    // ===========================================================
    // ---- Chiplet-1 side : CPU's data-memory request ----
    input         c1_mem_we,
    input  [31:0] c1_mem_addr,   // byte address from the CPU (word-aligned)
    input  [31:0] c1_mem_wdata,
    output [31:0] c1_mem_rdata,
    output        c1_mem_ready,  // link/other-die ready

    // ---- Chiplet-2 side : mem_io_wrapper's functional port ----
    output        c2_func_we,
    output [7:0]  c2_func_addr,
    output [31:0] c2_func_din,
    input  [31:0] c2_func_dout,

    // ===========================================================
    // SIDEBAND -- test / debug / DFx path (UCIe-style)
    // ===========================================================
    // ---- Host / Test Controller side ----
    input         sb_test_mode,
    input         sb_bist_start,
    output        sb_bist_busy,
    output        sb_bist_done,
    output        sb_bist_pass,
    output [7:0]  sb_bist_fail_addr,

    // ---- Chiplet-2 side : mem_io_wrapper's test port ----
    output        c2_test_mode,
    output        c2_bist_start,
    input         c2_bist_busy,
    input         c2_bist_done,
    input         c2_bist_pass,
    input  [7:0]  c2_bist_fail_addr,

    // ---- Reserved for a future phase ----
    input         link_test_mode,
    input         link_low_power
);

    // -----------------------------------------------------------
    // MAINBAND
    // -----------------------------------------------------------
    // Word-align the CPU's 32-bit byte address down to the 8-bit
    // word address Chiplet-2's 256-entry SRAM expects -- same
    // addr[9:2] convention the old local data_mem used, so timing
    // and byte offsets stay consistent with the rest of the core.
    assign c2_func_addr = c1_mem_addr[9:2];
    assign c2_func_we   = c1_mem_we;
    assign c2_func_din  = c1_mem_wdata;
    assign c1_mem_rdata = c2_func_dout;

    // Single clock domain, Phase 1: the link never stalls the CPU.
    // Kept as a real port (not tied off inside the CPU) so later
    // low-power idle states or multi-cycle lane arbitration can
    // drive this without touching riscv_pipeline_top again.
    assign c1_mem_ready = 1'b1;

    // -----------------------------------------------------------
    // SIDEBAND
    // -----------------------------------------------------------
    // Phase 1: pure pass-through, single clock domain, no framing/
    // packetization yet. Kept as separate named ports (rather than
    // reusing the mainband signals) so this channel can later grow
    // its own clock domain, arbitration, or packet format without
    // disturbing the functional memory path above.
    assign c2_test_mode  = sb_test_mode;
    assign c2_bist_start = sb_bist_start;

    assign sb_bist_busy      = c2_bist_busy;
    assign sb_bist_done      = c2_bist_done;
    assign sb_bist_pass      = c2_bist_pass;
    assign sb_bist_fail_addr = c2_bist_fail_addr;

    // link_test_mode / link_low_power intentionally unused for now.

endmodule
