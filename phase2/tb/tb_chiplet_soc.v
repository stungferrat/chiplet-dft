// =============================================================
// tb_chiplet_soc_top.v
// Directed self-checking testbench for chiplet_soc_top.
//
// Covers the 4 highest-risk timing/hazard interactions between
// the load-use hazard stall and the mem_wait (SRAM registered
// read latency) stall:
//   T1: load immediately followed by a dependent ALU instruction
//   T2: two back-to-back loads (no data dependency)
//   T3: load immediately followed by a dependent branch
//   T4: store immediately after a load to the SAME address
//
// Each test resets the DUT, loads a fresh instruction stream
// into Chiplet-1's instr_mem, preloads Chiplet-2's SRAM where
// needed, runs it to completion, then checks architectural
// state (register file / SRAM contents) via hierarchical refs.
// =============================================================
`timescale 1ns/1ps

module tb_chiplet_soc_top;

    reg clk;
    reg rst_n;
    reg test_mode, bist_start;
    reg fault_en;
    reg [7:0] fault_addr;
    reg [31:0] fault_val;

    wire bist_busy, bist_done, bist_pass;
    wire [7:0] bist_fail_addr;

    integer errors;
    integer i;

    // -----------------------------------------------------------
    // Phase 2 instrumentation.
    //
    // RUN_CYCLES is how long each test is allowed to run. It used
    // to be a hard-coded "repeat (40)". That was fine while every
    // load finished in a fixed 2 cycles, but once the interconnect
    // has real multi-cycle latency the same program needs more
    // cycles to reach the same answer -- so a fixed 40 would start
    // checking the register file before the program had finished
    // and report false failures. Generous headroom instead: the
    // checks look at final architectural state, so running longer
    // than necessary is harmless (the program just executes NOPs).
    // -----------------------------------------------------------
    parameter RUN_CYCLES = 120;

    // Per-test activity counters. These are the Step 3 evidence:
    // raising link latency must leave every checked VALUE identical
    // while these counts go UP. That contrast is what proves the
    // link is really stalling the CPU rather than being ignored.
    integer cycles;         // cycles elapsed since reset released
    integer memwait_cycles; // cycles the CPU was frozen on memory
    integer stall_cycles;   // cycles frozen by the load-use hazard unit

    // Cleared synchronously from reset, NOT by a blocking assignment
    // inside do_reset. do_reset is called right after a "repeat
    // (N) @(posedge clk)", so its body runs AT a clock edge -- a
    // blocking "cycles = 0" there lands in the active region and is
    // then overwritten by this block's already-scheduled
    // non-blocking "cycles <= cycles + 1", so the counter would
    // never actually clear. Clearing on !rst_n keeps it
    // deterministic: do_reset holds rst_n low for 3 clocks.
    always @(posedge clk) begin
        if (!rst_n) begin
            cycles         <= 0;
            memwait_cycles <= 0;
            stall_cycles   <= 0;
        end else begin
            cycles <= cycles + 1;
            if (dut.u_chiplet1.mem_wait) memwait_cycles <= memwait_cycles + 1;
            if (dut.u_chiplet1.stall)    stall_cycles    <= stall_cycles + 1;
        end
    end

    // Override at compile time, no RTL edit needed, e.g.
    //   iverilog -Ptb_chiplet_soc_top.LINK_LATENCY=3 ...
    parameter LINK_LATENCY = 1;

    chiplet_soc_top #(.LINK_LATENCY(LINK_LATENCY)) dut (
        .clk            (clk),
        .rst_n          (rst_n),
        .test_mode      (test_mode),
        .bist_start     (bist_start),
        .bist_busy      (bist_busy),
        .bist_done      (bist_done),
        .bist_pass      (bist_pass),
        .bist_fail_addr (bist_fail_addr),
        .fault_en       (fault_en),
        .fault_addr     (fault_addr),
        .fault_val      (fault_val)
    );

    // 10ns period, matches genus_synth.tcl's create_clock period
    initial clk = 0;
    always #5 clk = ~clk;

    // ===========================================================
    // WAVEFORM / EPWAVE PROBES
    // ===========================================================
    // These aliases expose only the signals needed to analyze:
    //   1) 5-stage pipeline timing
    //   2) load-use hazard + stall
    //   3) SRAM registered-read latency + mem_wait
    //
    // The aliases keep the waveform names short and easy to find
    // in EPWave while leaving the DUT RTL unchanged.

    // ---- Figure 1: 5-stage pipeline timing ----
    wire [31:0] wave_pc          = dut.u_chiplet1.pc;
    wire [31:0] wave_if_id_pc    = dut.u_chiplet1.if_id_pc;
    wire [31:0] wave_id_ex_pc    = dut.u_chiplet1.id_ex_pc;
    wire [31:0] wave_ex_mem_alu  = dut.u_chiplet1.ex_mem_alu_result;
    wire [31:0] wave_mem_wb_alu  = dut.u_chiplet1.mem_wb_alu_result;
    wire [31:0] wave_if_id_instr = dut.u_chiplet1.if_id_instr;

    // Explicit stage-valid indicators make the five pipeline stages
    // immediately visible in EPWave. A stage is considered valid when
    // its pipeline register contains a real instruction/control action.
    wire wave_if_valid  = rst_n;
    wire wave_id_valid  = rst_n && (dut.u_chiplet1.if_id_instr != 32'h00000013);
    wire wave_ex_valid  = rst_n && (dut.u_chiplet1.id_ex_reg_write  ||
                                    dut.u_chiplet1.id_ex_mem_read   ||
                                    dut.u_chiplet1.id_ex_mem_write  ||
                                    dut.u_chiplet1.id_ex_branch     ||
                                    dut.u_chiplet1.id_ex_jump);
    wire wave_mem_valid = rst_n && (dut.u_chiplet1.ex_mem_reg_write  ||
                                    dut.u_chiplet1.ex_mem_mem_read   ||
                                    dut.u_chiplet1.ex_mem_mem_write  ||
                                    dut.u_chiplet1.ex_mem_jump);
    wire wave_wb_valid  = rst_n && dut.u_chiplet1.mem_wb_reg_write;

    // ---- Figure 2: load-use hazard + stall ----
    wire        wave_stall       = dut.u_chiplet1.stall;
    wire        wave_pc_write    = dut.u_chiplet1.pc_write;
    wire        wave_idex_memrd  = dut.u_chiplet1.id_ex_mem_read;
    wire [4:0]  wave_idex_rd     = dut.u_chiplet1.id_ex_rd;
    wire [4:0]  wave_id_rs1      = dut.u_chiplet1.id_rs1;
    wire [4:0]  wave_id_rs2      = dut.u_chiplet1.id_rs2;

    // ---- Figure 3: Chiplet-1 <-> interconnect <-> SRAM ----
    wire [31:0] wave_c1_mem_addr = dut.c1_mem_addr;
    wire        wave_c1_mem_we   = dut.c1_mem_we;
    wire [31:0] wave_c1_mem_wdata= dut.c1_mem_wdata;
    wire [31:0] wave_c1_mem_rdata= dut.c1_mem_rdata;
    wire [7:0]  wave_c2_addr     = dut.c2_func_addr;
    wire        wave_c2_we       = dut.c2_func_we;
    wire [31:0] wave_c2_din      = dut.c2_func_din;
    wire [31:0] wave_c2_dout     = dut.c2_func_dout;
    wire [31:0] wave_sram_dout   = dut.u_chiplet2.u_array.dout;
    wire        wave_ex_mem_read = dut.u_chiplet1.ex_mem_mem_read;
    wire        wave_mem_wait    = dut.u_chiplet1.mem_wait;

    // Clock/reset are included explicitly for all three figures.
    wire wave_clk   = clk;
    wire wave_rst_n = rst_n;

    // Generate a VCD for EPWave. The VCD contains the DUT plus the
    // short named probes above, so you can select the exact signals
    // for each figure without modifying the RTL again.
    initial begin
        $dumpfile("chiplet_waveforms.vcd");
        $dumpvars(0, tb_chiplet_soc_top);
    end

    // -----------------------------------------------------------
    // Helpers
    // -----------------------------------------------------------
    task do_reset;
        begin
            rst_n = 0;
            test_mode = 0;
            bist_start = 0;
            fault_en = 0;
            fault_addr = 0;
            fault_val = 0;
            repeat (3) @(posedge clk);  // also clears the activity counters
            rst_n = 1;
            // NOTE: deliberately no extra @(posedge clk) here. PC is still
            // 0 (held by reset) at this point; the program-loading tasks
            // that run right after this returns must land in instr_mem
            // BEFORE the first post-reset clock edge, or the CPU fetches
            // whatever was left over in memory[0] from the previous test.
        end
    endtask

    // Fills instr_mem with NOPs, then loads N words starting at index 0.
    // NOTE: instr_mem is word-addressed (256 entries), hierarchical
    // path follows chiplet_soc_top -> u_chiplet1(riscv_pipeline_top)
    // -> u_imem(instr_mem) -> mem[]
    task load_program;
        input integer n;
        input [31:0] w0, w1, w2, w3, w4;
        begin
            for (i = 0; i < 256; i = i + 1)
                dut.u_chiplet1.u_imem.mem[i] = 32'h00000013; // NOP
            if (n > 0) dut.u_chiplet1.u_imem.mem[0] = w0;
            if (n > 1) dut.u_chiplet1.u_imem.mem[1] = w1;
            if (n > 2) dut.u_chiplet1.u_imem.mem[2] = w2;
            if (n > 3) dut.u_chiplet1.u_imem.mem[3] = w3;
            if (n > 4) dut.u_chiplet1.u_imem.mem[4] = w4;
        end
    endtask

    // Preloads Chiplet-2's SRAM (word-addressed, 256 x 32)
    // Hierarchical path: chiplet_soc_top -> u_chiplet2(mem_io_wrapper)
    // -> u_array(sram_array) -> mem[]
    task preload_sram;
        input [7:0] waddr;
        input [31:0] wval;
        begin
            dut.u_chiplet2.u_array.mem[waddr] = wval;
        end
    endtask

    task clear_sram;
        begin
            for (i = 0; i < 256; i = i + 1)
                dut.u_chiplet2.u_array.mem[i] = 32'd0;
        end
    endtask

    // Prints the activity counts for the test just finished. Not a
    // pass/fail check -- these numbers are expected to change when
    // link latency changes, which is exactly the point.
    task report_cycles;
        input [383:0] label;
        begin
            $display("      [%0s] cycles=%0d  mem_wait=%0d  hazard_stall=%0d",
                     label, cycles, memwait_cycles, stall_cycles);
        end
    endtask

    task check_reg;
        input [4:0] rnum;
        input [31:0] expected;
        input [383:0] label;
        begin
            if (dut.u_chiplet1.u_rf.regs[rnum] !== expected) begin
                $display("FAIL [%0s]: x%0d = %0d (0x%h), expected %0d (0x%h)",
                    label, rnum, dut.u_chiplet1.u_rf.regs[rnum],
                    dut.u_chiplet1.u_rf.regs[rnum], expected, expected);
                errors = errors + 1;
            end else begin
                $display("PASS [%0s]: x%0d = %0d as expected", label, rnum, expected);
            end
        end
    endtask

    task check_sram;
        input [7:0] waddr;
        input [31:0] expected;
        input [383:0] label;
        begin
            if (dut.u_chiplet2.u_array.mem[waddr] !== expected) begin
                $display("FAIL [%0s]: sram[%0d] = %0d (0x%h), expected %0d (0x%h)",
                    label, waddr, dut.u_chiplet2.u_array.mem[waddr],
                    dut.u_chiplet2.u_array.mem[waddr], expected, expected);
                errors = errors + 1;
            end else begin
                $display("PASS [%0s]: sram[%0d] = %0d as expected", label, waddr, expected);
            end
        end
    endtask

    // -----------------------------------------------------------
    // Main sequence
    // -----------------------------------------------------------
    initial begin
        errors = 0;
        $display("=========================================");
        $display(" Link latency under test: %0d cycle(s)", LINK_LATENCY);
        $display("=========================================");

        // =========================================================
        // T1: LW x1,0(x2) ; ADD x3,x1,x4   -- load-use hazard, ALU consumer
        //   x2=0, x4=5, mem[0]=42  =>  x1=42, x3=47
        // =========================================================
        do_reset;
        clear_sram;
        preload_sram(8'd0, 32'd42);
        load_program(4,
            32'h00000113, // ADDI x2,x0,0
            32'h00500213, // ADDI x4,x0,5
            32'h00012083, // LW   x1,0(x2)
            32'h004081B3, // ADD  x3,x1,x4
            32'h00000013);
        repeat (RUN_CYCLES) @(posedge clk);
        report_cycles("T1");
        check_reg(1, 32'd42, "T1 load value");
        check_reg(3, 32'd47, "T1 load-use ADD");

        // =========================================================
        // T2: LW x1,0(x2) ; LW x3,4(x2)   -- back-to-back loads, no dependency
        //   x2=0, mem[0]=100, mem[1]=200  =>  x1=100, x3=200
        // =========================================================
        do_reset;
        clear_sram;
        preload_sram(8'd0, 32'd100);
        preload_sram(8'd1, 32'd200);
        load_program(3,
            32'h00000113, // ADDI x2,x0,0
            32'h00012083, // LW   x1,0(x2)
            32'h00412183, // LW   x3,4(x2)
            32'h00000013,
            32'h00000013);
        repeat (RUN_CYCLES) @(posedge clk);
        report_cycles("T2");
        check_reg(1, 32'd100, "T2 first load");
        check_reg(3, 32'd200, "T2 second load");

        // =========================================================
        // T3: LW x1,0(x2) ; BEQ x1,x5,+8 ; ADDI x6,x0,1 ; ADDI x6,x0,99
        //   x2=0, x5=42, mem[0]=42 => branch taken, x6 should land on 99
        //   (if branch mis-resolves due to the load-use+branch interaction,
        //    x6 would incorrectly end up as 1)
        // =========================================================
        do_reset;
        clear_sram;
        preload_sram(8'd0, 32'd42);
        begin : t3_load
            // load_program only takes 5 words; T3 needs 6, so load directly
            for (i = 0; i < 256; i = i + 1)
                dut.u_chiplet1.u_imem.mem[i] = 32'h00000013;
            dut.u_chiplet1.u_imem.mem[0] = 32'h00000113; // ADDI x2,x0,0
            dut.u_chiplet1.u_imem.mem[1] = 32'h02A00293; // ADDI x5,x0,42
            dut.u_chiplet1.u_imem.mem[2] = 32'h00012083; // LW   x1,0(x2)
            dut.u_chiplet1.u_imem.mem[3] = 32'h00508463; // BEQ  x1,x5,+8
            dut.u_chiplet1.u_imem.mem[4] = 32'h00100313; // ADDI x6,x0,1  (should be skipped)
            dut.u_chiplet1.u_imem.mem[5] = 32'h06300313; // ADDI x6,x0,99 (branch target)
        end
        repeat (RUN_CYCLES) @(posedge clk);
        report_cycles("T3");
        check_reg(1, 32'd42, "T3 load value");
        check_reg(6, 32'd99, "T3 branch-on-loaded-value taken correctly");

        // =========================================================
        // T4: LW x1,0(x2) ; SW x9,0(x2) ; LW x3,0(x2)
        //   -- store immediately after a load to the SAME address
        //   x2=0, x9=123, mem[0] preloaded=55
        //   => x1=55 (old value, captured before overwrite)
        //      sram[0]=123 (store took effect)
        //      x3=123 (reload sees the new value, not stale/corrupted)
        // =========================================================
        do_reset;
        clear_sram;
        preload_sram(8'd0, 32'd55);
        begin : t4_load
            for (i = 0; i < 256; i = i + 1)
                dut.u_chiplet1.u_imem.mem[i] = 32'h00000013;
            dut.u_chiplet1.u_imem.mem[0] = 32'h00000113; // ADDI x2,x0,0
            dut.u_chiplet1.u_imem.mem[1] = 32'h07B00493; // ADDI x9,x0,123
            dut.u_chiplet1.u_imem.mem[2] = 32'h00012083; // LW   x1,0(x2)
            dut.u_chiplet1.u_imem.mem[3] = 32'h00912023; // SW   x9,0(x2)
            dut.u_chiplet1.u_imem.mem[4] = 32'h00012183; // LW   x3,0(x2)
        end
        repeat (RUN_CYCLES) @(posedge clk);
        report_cycles("T4");
        check_reg(1, 32'd55, "T4 initial load (pre-store value)");
        check_sram(8'd0, 32'd123, "T4 store to same address");
        check_reg(3, 32'd123, "T4 reload sees updated value");

        // =========================================================
        // T5: SRAI -- arithmetic right shift must sign-extend, unlike SRL
        //   x2 = 0xFFFFFF00 (-256), SRAI x3,x2,4 => 0xFFFFFFF0 (-16)
        //   If SRAI were wrongly executing as SRL (logical), x3 would
        //   instead be 0x0FFFFFF0 -- the top bits would be 0, not 1.
        // =========================================================
        do_reset;
        clear_sram;
        begin : t5_load
            for (i = 0; i < 256; i = i + 1)
                dut.u_chiplet1.u_imem.mem[i] = 32'h00000013;
            // LUI x2,0xFFFFF  -> x2 = 0xFFFFF000
            dut.u_chiplet1.u_imem.mem[0] = 32'hFFFFF137;
            // ADDI x2,x2,0x100 (adds 0x100, giving 0xFFFFF100... use ORI instead for clean bits)
            // Simpler: ORI x2,x2,0xF00 doesn't work (imm sign-extends oddly for values >=0x800).
            // Use two LUI-free steps instead: ADDI x2,x0,-256 directly (imm is 12-bit signed, -256 fits)
            dut.u_chiplet1.u_imem.mem[0] = 32'hF0000113; // ADDI x2,x0,-256  -> x2 = 0xFFFFFF00
            dut.u_chiplet1.u_imem.mem[1] = 32'h40415193; // SRAI x3,x2,4     -> x3 = 0xFFFFFFF0
        end
        repeat (RUN_CYCLES) @(posedge clk);
        report_cycles("T5");
        check_reg(2, 32'hFFFFFF00, "T5 ADDI negative immediate");
        check_reg(3, 32'hFFFFFFF0, "T5 SRAI sign-extends");

        // =========================================================
        // T6: JAL -- unconditional jump + link.
        //   JAL x5,+12 at addr4 must: (a) jump to addr16, skipping the
        //   two ADDI x2 instructions in between, and (b) write x5 with
        //   the return address (addr4+4 = 8).
        //   NOTE: this core implements JAL only, not JALR (confirmed by
        //   reading control_unit -- only LW/SW/BEQ/BNE/JAL are decoded).
        //   There is nothing to test for JALR since it doesn't exist
        //   in this design.
        // =========================================================
        do_reset;
        clear_sram;
        begin : t6_load
            for (i = 0; i < 256; i = i + 1)
                dut.u_chiplet1.u_imem.mem[i] = 32'h00000013;
            dut.u_chiplet1.u_imem.mem[0] = 32'h00B00093; // ADDI x1,x0,11
            dut.u_chiplet1.u_imem.mem[1] = 32'h00C002EF; // JAL  x5,+12  (-> addr16)
            dut.u_chiplet1.u_imem.mem[2] = 32'h06300113; // ADDI x2,x0,99 (must be skipped)
            dut.u_chiplet1.u_imem.mem[3] = 32'h05800113; // ADDI x2,x0,88 (must be skipped)
            dut.u_chiplet1.u_imem.mem[4] = 32'h00700113; // ADDI x2,x0,7  (landing point)
        end
        repeat (RUN_CYCLES) @(posedge clk);
        report_cycles("T6");
        check_reg(1, 32'd11, "T6 pre-jump sanity");
        check_reg(5, 32'd8,  "T6 JAL link address");
        check_reg(2, 32'd7,  "T6 JAL target reached, skips not taken");

        // -----------------------------------------------------------
        $display("=========================================");
        if (errors == 0)
            $display("ALL TESTS PASSED");
        else
            $display("%0d CHECK(S) FAILED", errors);
        $display("=========================================");
        $finish;
    end

    // Watchdog
    initial begin
        #200000;   // headroom for 6 tests x RUN_CYCLES at higher link latency
        $display("TIMEOUT: simulation did not finish in time");
        $finish;
    end

endmodule
