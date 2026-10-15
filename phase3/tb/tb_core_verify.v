// =============================================================
// tb_core_verify.v
// Model-checked regression for chiplet_soc_top.
//
// PART 1 -- CPU + link. For every test produced by
// ../verif/gen_tests.py (directed + random programs):
//   1. hold the core in reset and load the program through the
//      instr_mem load port
//   2. preload the SRAM and clear the register file
//   3. release reset and run until the program has reached its
//      final "JAL x0,0" (jump-to-self)
//   4. compare ALL 31 registers and ALL 256 SRAM words against the
//      reference model's prediction
//
// PART 2 -- MBIST. Clean pass, then stuck faults at the first,
// middle and last addresses with several stuck values. MBIST must
// fail and name exactly the faulty address.
//
// PART 3 -- after MBIST, functional mode must work again.
//
// Run from phase3/verif (vectors are read from ./vectors):
//   iverilog -g2012 -DSIM -o v.out ../rtl/*.v ../tb/tb_core_verify.v
//   vvp v.out
// Must be compiled with -DSIM.
//
// NOTE: SRAM preload and register-file clear use hierarchical
// writes, so this testbench is RTL-only. Gate-level simulation
// will need a different method (see WALKTHROUGH, known gaps).
// =============================================================
`timescale 1ns/1ps

`ifndef VEC_DIR
  `define VEC_DIR "vectors"
`endif

module tb_core_verify;

`ifndef SIM
    ERROR_compile_this_testbench_with_DSIM missing_define ();
`endif

    parameter LINK_LATENCY = 1;
    parameter MAX_TESTS    = 1024;

    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg        rst_n, test_mode, bist_start;
    reg        fault_en;
    reg [7:0]  fault_addr;
    reg [31:0] fault_val;
    reg        imem_we;
    reg [7:0]  imem_waddr;
    reg [31:0] imem_wdata;
    wire       bist_busy, bist_done, bist_pass;
    wire [7:0] bist_fail_addr;

    chiplet_soc_top #(.LINK_LATENCY(LINK_LATENCY)) dut (
        .clk            (clk),
        .rst_n          (rst_n),
        .test_mode      (test_mode),
        .bist_start     (bist_start),
        .bist_busy      (bist_busy),
        .bist_done      (bist_done),
        .bist_pass      (bist_pass),
        .bist_fail_addr (bist_fail_addr),
        .imem_we        (imem_we),
        .imem_waddr     (imem_waddr),
        .imem_wdata     (imem_wdata),
        .fault_en       (fault_en),
        .fault_addr     (fault_addr),
        .fault_val      (fault_val)
    );

    // ---- test vectors from gen_tests.py ----
    reg [31:0] v_count    [0:0];
    reg [31:0] v_prog     [0:MAX_TESTS*256-1];
    reg [31:0] v_mem_init [0:MAX_TESTS*256-1];
    reg [31:0] v_exp_regs [0:MAX_TESTS*32-1];
    reg [31:0] v_exp_mem  [0:MAX_TESTS*256-1];
    reg [31:0] v_steps    [0:MAX_TESTS-1];

    integer num_tests, t, i, n_bad, failed_tests, total_checks, errors;
    integer failed_before;

    // -----------------------------------------------------------
    task hold_reset;
        begin
            rst_n      = 1'b0;
            test_mode  = 1'b0;
            bist_start = 1'b0;
            fault_en   = 1'b0;
            fault_addr = 8'd0;
            fault_val  = 32'd0;
            imem_we    = 1'b0;
            repeat (3) @(posedge clk);
        end
    endtask

    // Program load through the real port, one word per clock, driven
    // on the falling edge so it is stable at the DUT's rising edge.
    task load_program;
        input integer base;
        begin
            for (i = 0; i < 256; i = i + 1) begin
                @(negedge clk);
                imem_we    = 1'b1;
                imem_waddr = i[7:0];
                imem_wdata = v_prog[base + i];
            end
            @(negedge clk);
            imem_we = 1'b0;
        end
    endtask

    // -----------------------------------------------------------
    task run_cpu_test;
        input integer k;
        integer ncycles;
        begin
            hold_reset;
            load_program(k * 256);
            for (i = 0; i < 256; i = i + 1)
                dut.u_chiplet2.u_array.mem[i] = v_mem_init[k * 256 + i];
            for (i = 0; i < 32; i = i + 1)
                dut.u_chiplet1.u_rf.regs[i] = 32'd0;
            @(negedge clk);
            rst_n = 1'b1;

            // Generous bound: a load costs at most LINK_LATENCY + 1 wait
            // + 1 hazard stall, a taken branch 2 flush cycles. The
            // program ends in a jump-to-self, so overrunning is harmless.
            ncycles = v_steps[k] * (LINK_LATENCY + 4) + 60;
            repeat (ncycles) @(posedge clk);

            n_bad = 0;
            for (i = 1; i < 32; i = i + 1) begin
                total_checks = total_checks + 1;
                if (dut.u_chiplet1.u_rf.regs[i] !== v_exp_regs[k * 32 + i]) begin
                    if (n_bad < 6)
                        $display("  test %0d: x%0d = %h, expected %h",
                                 k, i, dut.u_chiplet1.u_rf.regs[i], v_exp_regs[k * 32 + i]);
                    n_bad = n_bad + 1;
                end
            end
            for (i = 0; i < 256; i = i + 1) begin
                total_checks = total_checks + 1;
                if (dut.u_chiplet2.u_array.mem[i] !== v_exp_mem[k * 256 + i]) begin
                    if (n_bad < 6)
                        $display("  test %0d: sram[%0d] = %h, expected %h",
                                 k, i, dut.u_chiplet2.u_array.mem[i], v_exp_mem[k * 256 + i]);
                    n_bad = n_bad + 1;
                end
            end
            if (n_bad != 0) begin
                $display("FAIL test %0d (%0d mismatches) -- see vectors/manifest.txt for its name", k, n_bad);
                failed_tests = failed_tests + 1;
            end
        end
    endtask

    // -----------------------------------------------------------
    task mbist_case;
        input        inject;
        input [7:0]  faddr;
        input [31:0] fval;
        input        exp_pass;
        integer guard;
        begin
            hold_reset;
            @(negedge clk);
            rst_n      = 1'b1;
            fault_en   = inject;
            fault_addr = faddr;
            fault_val  = fval;
            test_mode  = 1'b1;
            @(negedge clk) bist_start = 1'b1;
            @(negedge clk) bist_start = 1'b0;
            guard = 0;
            while (bist_done !== 1'b1 && guard < 20000) begin
                @(posedge clk);
                guard = guard + 1;
            end
            total_checks = total_checks + 1;
            if (bist_done !== 1'b1) begin
                $display("FAIL MBIST fault_en=%0b addr=%0d val=%h: never finished", inject, faddr, fval);
                errors = errors + 1;
            end else if (bist_pass !== exp_pass) begin
                $display("FAIL MBIST fault_en=%0b addr=%0d val=%h: pass=%0b, expected %0b",
                         inject, faddr, fval, bist_pass, exp_pass);
                errors = errors + 1;
            end else if (!exp_pass && bist_fail_addr !== faddr) begin
                $display("FAIL MBIST fault at %0d val=%h: reported fail_addr=%0d",
                         faddr, fval, bist_fail_addr);
                errors = errors + 1;
            end else begin
                $display("PASS MBIST fault_en=%0b addr=%3d val=%h -> pass=%0b fail_addr=%0d",
                         inject, faddr, fval, bist_pass, bist_fail_addr);
            end
            fault_en  = 1'b0;
            test_mode = 1'b0;
        end
    endtask

    // -----------------------------------------------------------
    initial begin
        errors = 0;
        failed_tests = 0;
        total_checks = 0;

        $readmemh({`VEC_DIR, "/count.hex"},        v_count);
        num_tests = v_count[0];
        if (num_tests > MAX_TESTS) begin
            $display("ERROR: %0d tests but MAX_TESTS = %0d", num_tests, MAX_TESTS);
            $finish;
        end
        $readmemh({`VEC_DIR, "/prog_all.hex"},     v_prog,     0, num_tests * 256 - 1);
        $readmemh({`VEC_DIR, "/mem_init_all.hex"}, v_mem_init, 0, num_tests * 256 - 1);
        $readmemh({`VEC_DIR, "/exp_regs_all.hex"}, v_exp_regs, 0, num_tests * 32 - 1);
        $readmemh({`VEC_DIR, "/exp_mem_all.hex"},  v_exp_mem,  0, num_tests * 256 - 1);
        $readmemh({`VEC_DIR, "/steps_all.hex"},    v_steps,    0, num_tests - 1);

        $display("=========================================");
        $display(" Model-checked regression, link latency %0d", LINK_LATENCY);
        $display(" %0d CPU tests from %s", num_tests, `VEC_DIR);
        $display("=========================================");

        // ---- PART 1: CPU + link vs reference model ----
        for (t = 0; t < num_tests; t = t + 1)
            run_cpu_test(t);
        $display("CPU tests: %0d of %0d passed", num_tests - failed_tests, num_tests);
        errors = errors + failed_tests;

        // ---- PART 2: MBIST ----
        // CPU runs a jump-to-self program so it never touches the SRAM.
        for (i = 0; i < 256; i = i + 1) v_prog[i] = (i == 0) ? 32'h0000006F : 32'h00000013;
        hold_reset;
        load_program(0);
        mbist_case(1'b0, 8'd0,   32'h00000000, 1'b1);   // healthy memory
        mbist_case(1'b1, 8'd0,   32'h00000000, 1'b0);   // first address, stuck-at-0
        mbist_case(1'b1, 8'd0,   32'hFFFFFFFF, 1'b0);   // first address, stuck-at-1
        mbist_case(1'b1, 8'd128, 32'hDEADBEEF, 1'b0);   // middle, mixed bits
        mbist_case(1'b1, 8'd255, 32'h00000000, 1'b0);   // last address, stuck-at-0
        mbist_case(1'b1, 8'd255, 32'hFFFFFFFF, 1'b0);   // last address, stuck-at-1
        mbist_case(1'b1, 8'd10,  32'h00000001, 1'b0);   // single stuck bit

        // ---- PART 3: functional mode works again after MBIST ----
        // (re-read the first program, PART 2 overwrote v_prog[0..255])
        $readmemh({`VEC_DIR, "/prog_all.hex"}, v_prog, 0, num_tests * 256 - 1);
        failed_before = failed_tests;   // (not n_bad: run_cpu_test resets n_bad)
        run_cpu_test(0);
        if (failed_tests != failed_before) begin
            $display("FAIL: CPU test 0 fails after MBIST -- test_mode did not hand the SRAM back");
            errors = errors + 1;
        end else
            $display("PASS functional mode restored after MBIST");

        $display("=========================================");
        $display(" %0d individual value checks", total_checks);
        if (errors == 0) $display(" ALL TESTS PASSED");
        else             $display(" %0d FAILURE(S)", errors);
        $display("=========================================");
        $finish;
    end

endmodule
