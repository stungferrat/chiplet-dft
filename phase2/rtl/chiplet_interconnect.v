// =============================================================
// chiplet_interconnect.v
// UCIe-inspired die-to-die link: mainband transaction engine + sideband.
// Phase 2: the interconnect carries a real req/ready handshake.
// See ../WALKTHROUGH.md for the full explanation.
// =============================================================
`timescale 1ns/1ps



module chiplet_interconnect (
    input         clk,
    input         rst_n,

    // ===========================================================
    // MAINBAND -- functional data path
    // ===========================================================
    // ---- Chiplet-1 side : CPU's data-memory request ----
    input         c1_mem_req,    // CPU has a transaction outstanding
    input         c1_mem_we,
    input  [31:0] c1_mem_addr,   // byte address from the CPU (word-aligned)
    input  [31:0] c1_mem_wdata,
    output [31:0] c1_mem_rdata,
    output        c1_mem_ready,  // 1 = transaction completes this cycle

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
    // Address/data are straight-through: the CPU holds them stable
    // for the whole transaction, so the far side sees a steady
    // address while the link counts out its latency.
    assign c2_func_addr = c1_mem_addr[9:2];
    assign c2_func_din  = c1_mem_wdata;
    assign c1_mem_rdata = c2_func_dout;

    // -----------------------------------------------------------
    // MAINBAND TRANSACTION ENGINE
    //
    // Phase 1 was "assign c1_mem_ready = 1'b1;" -- the link could
    // never stall the CPU, and the CPU faked the SRAM's latency
    // internally instead. This is the real thing: a transaction
    // occupies the link for LATENCY cycles, and the CPU is frozen
    // for exactly that long because c1_mem_ready stays low.
    //
    //   LATENCY = 1 reproduces Phase 1's timing exactly (one wait
    //             cycle per load), which is what lets the existing
    //             regression prove this refactor changed nothing.
    //   LATENCY > 1 models a slower die-to-die link. Same results,
    //             more cycles -- the proof that backpressure works.
    //
    // Protocol (one outstanding transaction at a time):
    //   idle          : busy=0, ready=0, waiting for c1_mem_req
    //   accept        : c1_mem_req seen -> busy=1, cnt=LATENCY-1
    //   count down    : busy=1, cnt>0, ready=0  (CPU frozen here)
    //   complete      : busy=1, cnt==0 -> ready=1 for one cycle;
    //                   read data is valid now, write is committed
    //                   at the coming edge, then back to idle.
    // -----------------------------------------------------------
    parameter LATENCY = 1;

    // LATENCY must be at least 1: a transaction cannot complete in
    // the same cycle it is accepted, because Chiplet-2's SRAM
    // registers its read. Clamped rather than trusted, because
    // LATENCY=0 fails in the nastiest possible way -- "cnt <=
    // LATENCY-1" underflows to 4'hF and the link waits 16 cycles
    // instead of 0. The functional tests still PASS (the answers
    // are right, just slow), so nothing catches it. Clamp, and say
    // so loudly in simulation.
    localparam integer LAT_EFF = (LATENCY < 1) ? 1 : LATENCY;

    // synthesis translate_off
    initial begin
        if (LATENCY < 1)
            $display("WARNING: chiplet_interconnect LATENCY=%0d is invalid; clamped to 1.",
                     LATENCY);
    end
    // synthesis translate_on

    reg       busy;
    reg [3:0] cnt;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            busy <= 1'b0;
            cnt  <= 4'd0;
        end else if (!busy) begin
            // Accept a new transaction. Nothing is registered from
            // the CPU: it holds addr/we/wdata stable until we
            // answer, which is what makes this safe.
            if (c1_mem_req) begin
                busy <= 1'b1;
                cnt  <= LAT_EFF - 1;
            end
        end else if (cnt != 4'd0) begin
            cnt <= cnt - 4'd1;
        end else begin
            busy <= 1'b0;   // completing this cycle
        end
    end

    assign c1_mem_ready = busy && (cnt == 4'd0);

    // Single-pulse the far-side write enable, on the completion
    // cycle only. The CPU holds c1_mem_we high for the whole
    // transaction, so passing it straight through would re-write
    // the same cell on every cycle of a multi-cycle access: the
    // final value is the same, but the waveform misrepresents the
    // traffic and it would be outright wrong if write data ever
    // changed mid-transaction.
    //
    // This gating REQUIRES that stores assert c1_mem_req (see
    // mem_req in riscv_pipeline_top). Without that the engine
    // never runs for a store, c1_mem_ready never rises, and the
    // write is silently dropped -- the T4 store check catches it.
    assign c2_func_we = c1_mem_we && c1_mem_ready;

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
