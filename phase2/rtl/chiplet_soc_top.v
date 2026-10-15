// =============================================================
// chiplet_soc_top.v
// Top level: instantiates both chiplets and the interconnect between them.
// Phase 2: the interconnect carries a real req/ready handshake.
// See ../WALKTHROUGH.md for the full explanation.
// =============================================================
`timescale 1ns/1ps

module chiplet_soc_top #(
    // Die-to-die link latency, in clocks, for one mainband
    // transaction. 1 reproduces Phase 1 timing exactly; larger
    // values model a slower link. Exposed here so the testbench
    // can sweep it without editing RTL.
    parameter LINK_LATENCY = 1
) (
    input  clk,
    input  rst_n,
    // ---- Chiplet-2 test/debug, exposed at top level, now routed ----
    // ---- through the interconnect's sideband channel ----
    input         test_mode,
    input         bist_start,
    output        bist_busy,
    output        bist_done,
    output        bist_pass,
    output [7:0]  bist_fail_addr,
    // ---- Verification-only fault injection (tie off for synthesis) ----
    input         fault_en,
    input  [7:0]  fault_addr,
    input  [31:0] fault_val
);
    // -----------------------------------------------------------
    // Chiplet-1 : RV32I core
    // -----------------------------------------------------------
    wire        c1_mem_we;
    wire [31:0] c1_mem_addr;
    wire [31:0] c1_mem_wdata;
    wire [31:0] c1_mem_rdata;
    wire        c1_mem_req;
    wire        c1_mem_ready;
    riscv_pipeline_top u_chiplet1 (
        .clk          (clk),
        .rst_n        (rst_n),
        .mem_we       (c1_mem_we),
        .mem_addr     (c1_mem_addr),
        .mem_wdata    (c1_mem_wdata),
        .mem_rdata_in (c1_mem_rdata),
        .mem_req      (c1_mem_req),
        .mem_ready    (c1_mem_ready)
    );
    // -----------------------------------------------------------
    // UCIe-inspired interconnect (mainband + sideband)
    // -----------------------------------------------------------
    wire        c2_func_we;
    wire [7:0]  c2_func_addr;
    wire [31:0] c2_func_din;
    wire [31:0] c2_func_dout;

    wire        c2_test_mode;
    wire        c2_bist_start;
    wire        c2_bist_busy;
    wire        c2_bist_done;
    wire        c2_bist_pass;
    wire [7:0]  c2_bist_fail_addr;

    chiplet_interconnect #(.LATENCY(LINK_LATENCY)) u_link (
        .clk               (clk),
        .rst_n             (rst_n),

        // Mainband
        .c1_mem_req        (c1_mem_req),
        .c1_mem_we         (c1_mem_we),
        .c1_mem_addr       (c1_mem_addr),
        .c1_mem_wdata      (c1_mem_wdata),
        .c1_mem_rdata      (c1_mem_rdata),
        .c1_mem_ready      (c1_mem_ready),   // now load-bearing
        .c2_func_we        (c2_func_we),
        .c2_func_addr      (c2_func_addr),
        .c2_func_din       (c2_func_din),
        .c2_func_dout      (c2_func_dout),

        // Sideband -- host/Test Controller side (this level's ports)
        .sb_test_mode      (test_mode),
        .sb_bist_start     (bist_start),
        .sb_bist_busy      (bist_busy),
        .sb_bist_done      (bist_done),
        .sb_bist_pass      (bist_pass),
        .sb_bist_fail_addr (bist_fail_addr),

        // Sideband -- Chiplet-2 side
        .c2_test_mode      (c2_test_mode),
        .c2_bist_start     (c2_bist_start),
        .c2_bist_busy      (c2_bist_busy),
        .c2_bist_done      (c2_bist_done),
        .c2_bist_pass      (c2_bist_pass),
        .c2_bist_fail_addr (c2_bist_fail_addr),

        .link_test_mode    (1'b0),
        .link_low_power    (1'b0)
    );
    // -----------------------------------------------------------
    // Chiplet-2 : Memory/IO chiplet with MBIST
    // -----------------------------------------------------------
    mem_io_wrapper u_chiplet2 (
        .clk            (clk),
        .rst_n          (rst_n),
        .func_we        (c2_func_we),
        .func_addr      (c2_func_addr),
        .func_din       (c2_func_din),
        .func_dout      (c2_func_dout),
        .test_mode      (c2_test_mode),
        .bist_start     (c2_bist_start),
        .bist_busy      (c2_bist_busy),
        .bist_done      (c2_bist_done),
        .bist_pass      (c2_bist_pass),
        .bist_fail_addr (c2_bist_fail_addr),
        .fault_en       (fault_en),
        .fault_addr     (fault_addr),
        .fault_val      (fault_val)
    );
endmodule
