// =============================================================
// mem_io_chiplet.v
// Chiplet-2: SRAM array, March C- MBIST engine, and the arbitration wrapper.
// Phase 3: synthesis-ready -- instr_mem has a real load port, and the
// fault-injection ports exist only when compiled with -DSIM.
// =============================================================
`timescale 1ns/1ps



// -------------------------------------------------------------
// SRAM Array: 256 x 32-bit, single port
// -------------------------------------------------------------
module sram_array (
    input         clk,
    input         we,
    input  [7:0]  addr,
    input  [31:0] din,
    output reg [31:0] dout
`ifdef SIM
    ,
    // --- Verification-only stuck-at fault injection ---
    // Exists only when compiled with -DSIM, so synthesis never builds
    // these muxes into the SRAM path. In the netlist, faults come from
    // the ATPG tool's fault models instead.
    input         fault_en,
    input  [7:0]  fault_addr,
    input  [31:0] fault_val
`endif
);
    reg [31:0] mem [0:255];
    integer i;
    initial begin
        for (i = 0; i < 256; i = i + 1)
            mem[i] = 32'd0;
    end

`ifdef SIM
    wire fault_hit = fault_en && (addr == fault_addr);
`else
    wire fault_hit = 1'b0;
`endif

    always @(posedge clk) begin
        if (we && !fault_hit)
            mem[addr] <= din;        // stuck cell ignores writes when faulted
`ifdef SIM
        if (fault_hit)
            dout <= fault_val;       // stuck-at value regardless of contents
        else
`endif
            dout <= mem[addr];
    end
endmodule


// -------------------------------------------------------------
// March C- MBIST Controller
// Sequence (classic March C-):
//   M0: up  { w0 }
//   M1: up  { r0, w1 }
//   M2: up  { r1, w0 }
//   M3: down{ r0, w1 }
//   M4: down{ r1, w0 }
//   M5: up  { r0 }
// Detects: stuck-at, transition, coupling, some address faults
// -------------------------------------------------------------
module march_c_minus_bist (
    input        clk,
    input        rst_n,
    input        start,          // pulse to begin test
    output reg   busy,
    output reg   done,
    output reg   pass,           // valid when done=1
    output reg [7:0] fail_addr,  // first failing address (if any)

    // Memory-facing port (drives sram_array during test)
    output reg        mem_we,
    output reg [7:0]  mem_addr,
    output reg [31:0] mem_din,
    input      [31:0] mem_dout
);
    // FSM states
    localparam IDLE    = 4'd0;
    localparam M0_W0   = 4'd1; // write 0, ascending
    localparam M1_R0W1 = 4'd2; // read 0, write 1, ascending
    localparam M2_R1W0 = 4'd3; // read 1, write 0, ascending
    localparam M3_R0W1 = 4'd4; // read 0, write 1, descending
    localparam M4_R1W0 = 4'd5; // read 1, write 0, descending
    localparam M5_R0   = 4'd6; // read 0, ascending
    localparam DONE_ST = 4'd7;

    reg [3:0]  state;
    reg [8:0]  addr_ctr;      // 9 bits so it can hold 256 (overflow sentinel) safely
    reg [1:0]  sub_phase;     // 0=issue addr, 1=wait (array read latency), 2=check+write
    reg        fail_latched;

    wire [7:0] cur_addr = addr_ctr[7:0];
    wire       ascending_done  = (addr_ctr == 9'd255); // fires while processing the LAST address (255), no extra bogus cycle

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state        <= IDLE;
            busy         <= 1'b0;
            done         <= 1'b0;
            pass         <= 1'b0;
            fail_addr    <= 8'd0;
            fail_latched <= 1'b0;
            addr_ctr     <= 9'd0;
            sub_phase    <= 2'd0;
            mem_we       <= 1'b0;
            mem_addr     <= 8'd0;
            mem_din      <= 32'd0;
        end else begin
            mem_we <= 1'b0; // default deassert each cycle unless set below

            case (state)
                // -----------------------------------------------
                IDLE: begin
                    done <= 1'b0;
                    if (start) begin
                        busy         <= 1'b1;
                        pass         <= 1'b1;
                        fail_latched <= 1'b0;
                        addr_ctr     <= 9'd0;
                        state        <= M0_W0;
                    end
                end

                // M0: write 0 to all cells, ascending
                M0_W0: begin
                    mem_addr <= cur_addr;
                    mem_din  <= 32'd0;
                    mem_we   <= 1'b1;
                    if (ascending_done) begin
                        addr_ctr <= 9'd0;
                        state    <= M1_R0W1;
                    end else begin
                        addr_ctr <= addr_ctr + 9'd1;
                    end
                end

                // M1: read 0 then write 1, ascending
                M1_R0W1: begin
                    case (sub_phase)
                        2'd0: begin
                            mem_addr  <= cur_addr;
                            sub_phase <= 2'd1;
                        end
                        2'd1: begin
                            sub_phase <= 2'd2; // wait one cycle for array's registered dout
                        end
                        default: begin
                            if (mem_dout !== 32'd0) begin
                                pass         <= 1'b0;
                                fail_latched <= 1'b1;
                                if (!fail_latched) fail_addr <= cur_addr;
                            end
                            mem_addr <= cur_addr;
                            mem_din  <= {32{1'b1}};
                            mem_we   <= 1'b1;
                            sub_phase <= 2'd0;
                            if (ascending_done) begin
                                addr_ctr <= 9'd0;
                                state    <= M2_R1W0;
                            end else begin
                                addr_ctr <= addr_ctr + 9'd1;
                            end
                        end
                    endcase
                end

                // M2: read 1 then write 0, ascending
                M2_R1W0: begin
                    case (sub_phase)
                        2'd0: begin
                            mem_addr  <= cur_addr;
                            sub_phase <= 2'd1;
                        end
                        2'd1: begin
                            sub_phase <= 2'd2;
                        end
                        default: begin
                            if (mem_dout !== {32{1'b1}}) begin
                                pass         <= 1'b0;
                                fail_latched <= 1'b1;
                                if (!fail_latched) fail_addr <= cur_addr;
                            end
                            mem_addr <= cur_addr;
                            mem_din  <= 32'd0;
                            mem_we   <= 1'b1;
                            sub_phase <= 2'd0;
                            if (ascending_done) begin
                                addr_ctr <= 9'd255; // start descending from 255
                                state    <= M3_R0W1;
                            end else begin
                                addr_ctr <= addr_ctr + 9'd1;
                            end
                        end
                    endcase
                end

                // M3: read 0 then write 1, descending
                M3_R0W1: begin
                    case (sub_phase)
                        2'd0: begin
                            mem_addr  <= cur_addr;
                            sub_phase <= 2'd1;
                        end
                        2'd1: begin
                            sub_phase <= 2'd2;
                        end
                        default: begin
                            if (mem_dout !== 32'd0) begin
                                pass         <= 1'b0;
                                fail_latched <= 1'b1;
                                if (!fail_latched) fail_addr <= cur_addr;
                            end
                            mem_addr <= cur_addr;
                            mem_din  <= {32{1'b1}};
                            mem_we   <= 1'b1;
                            sub_phase <= 2'd0;
                            if (addr_ctr == 9'd0) begin
                                addr_ctr <= 9'd255;
                                state    <= M4_R1W0;
                            end else begin
                                addr_ctr <= addr_ctr - 9'd1;
                            end
                        end
                    endcase
                end

                // M4: read 1 then write 0, descending
                M4_R1W0: begin
                    case (sub_phase)
                        2'd0: begin
                            mem_addr  <= cur_addr;
                            sub_phase <= 2'd1;
                        end
                        2'd1: begin
                            sub_phase <= 2'd2;
                        end
                        default: begin
                            if (mem_dout !== {32{1'b1}}) begin
                                pass         <= 1'b0;
                                fail_latched <= 1'b1;
                                if (!fail_latched) fail_addr <= cur_addr;
                            end
                            mem_addr <= cur_addr;
                            mem_din  <= 32'd0;
                            mem_we   <= 1'b1;
                            sub_phase <= 2'd0;
                            if (addr_ctr == 9'd0) begin
                                addr_ctr <= 9'd0;
                                state    <= M5_R0;
                            end else begin
                                addr_ctr <= addr_ctr - 9'd1;
                            end
                        end
                    endcase
                end

                // M5: read 0, ascending (final check)
                M5_R0: begin
                    case (sub_phase)
                        2'd0: begin
                            mem_addr  <= cur_addr;
                            sub_phase <= 2'd1;
                        end
                        2'd1: begin
                            sub_phase <= 2'd2;
                        end
                        default: begin
                            if (mem_dout !== 32'd0) begin
                                pass         <= 1'b0;
                                fail_latched <= 1'b1;
                                if (!fail_latched) fail_addr <= cur_addr;
                            end
                            sub_phase <= 2'd0;
                            if (ascending_done) begin
                                state <= DONE_ST;
                            end else begin
                                addr_ctr <= addr_ctr + 9'd1;
                            end
                        end
                    endcase
                end

                DONE_ST: begin
                    busy  <= 1'b0;
                    done  <= 1'b1;
                    state <= IDLE;
                end

                default: state <= IDLE;
            endcase
        end
    end
endmodule


// -------------------------------------------------------------
// Memory/IO Chiplet top wrapper
// Muxes between functional access and MBIST access to the array.
// test_mode acts as the boundary-scan-style control input
// (placeholder for an IEEE1500 wrapper instruction later).
// -------------------------------------------------------------
module mem_io_wrapper (
    input         clk,
    input         rst_n,

    // Functional interface
    input         func_we,
    input  [7:0]  func_addr,
    input  [31:0] func_din,
    output [31:0] func_dout,

    // Test control
    input         test_mode,   // 1 = MBIST owns the array
    input         bist_start,
    output        bist_busy,
    output        bist_done,
    output        bist_pass,
    output [7:0]  bist_fail_addr
`ifdef SIM
    ,
    // Verification-only fault injection (simulation builds only)
    input         fault_en,
    input  [7:0]  fault_addr,
    input  [31:0] fault_val
`endif
);
    wire        bist_we;
    wire [7:0]  bist_addr;
    wire [31:0] bist_din;
    wire [31:0] array_dout;

    wire        arr_we   = test_mode ? bist_we   : func_we;
    wire [7:0]  arr_addr = test_mode ? bist_addr : func_addr;
    wire [31:0] arr_din  = test_mode ? bist_din  : func_din;

    sram_array u_array (
        .clk        (clk),
        .we         (arr_we),
        .addr       (arr_addr),
        .din        (arr_din),
        .dout       (array_dout)
`ifdef SIM
       ,.fault_en   (fault_en),
        .fault_addr (fault_addr),
        .fault_val  (fault_val)
`endif
    );

    march_c_minus_bist u_bist (
        .clk       (clk),
        .rst_n     (rst_n),
        .start     (bist_start),
        .busy      (bist_busy),
        .done      (bist_done),
        .pass      (bist_pass),
        .fail_addr (bist_fail_addr),
        .mem_we    (bist_we),
        .mem_addr  (bist_addr),
        .mem_din   (bist_din),
        .mem_dout  (array_dout)
    );

    assign func_dout = array_dout;

endmodule
