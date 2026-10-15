// =============================================================
// riscv_pipeline_top.v
// Chiplet-1: RV32I 5-stage pipeline core and its submodules.
// Phase 2: the interconnect carries a real req/ready handshake.
// See ../WALKTHROUGH.md for the full explanation.
// =============================================================
`timescale 1ns/1ps



// -------------------------------------------------------------
// ALU
// -------------------------------------------------------------
module alu (
    input  [31:0] a,
    input  [31:0] b,
    input  [3:0]  alu_ctrl,
    output reg [31:0] result,
    output        zero
);
    // alu_ctrl encoding
    localparam ALU_ADD = 4'b0000;
    localparam ALU_SUB = 4'b0001;
    localparam ALU_AND = 4'b0010;
    localparam ALU_OR  = 4'b0011;
    localparam ALU_XOR = 4'b0100;
    localparam ALU_SLT = 4'b0101;
    localparam ALU_SLL = 4'b0110;
    localparam ALU_SRL = 4'b0111;
    localparam ALU_SRA = 4'b1000;

    always @(*) begin
        case (alu_ctrl)
            ALU_ADD: result = a + b;
            ALU_SUB: result = a - b;
            ALU_AND: result = a & b;
            ALU_OR : result = a | b;
            ALU_XOR: result = a ^ b;
            ALU_SLT: result = ($signed(a) < $signed(b)) ? 32'd1 : 32'd0;
            ALU_SLL: result = a << b[4:0];
            ALU_SRL: result = a >> b[4:0];
            ALU_SRA: result = $signed(a) >>> b[4:0];
            default: result = 32'd0;
        endcase
    end

    assign zero = (result == 32'd0);
endmodule


// -------------------------------------------------------------
// Register File (32 x 32-bit, x0 hardwired to 0)
// -------------------------------------------------------------
module register_file (
    input         clk,
    input         we,
    input  [4:0]  ra1,
    input  [4:0]  ra2,
    input  [4:0]  wa,
    input  [31:0] wd,
    output [31:0] rd1,
    output [31:0] rd2
);
    reg [31:0] regs [0:31];
    integer i;

    initial begin
        for (i = 0; i < 32; i = i + 1)
            regs[i] = 32'd0;
    end

    // Write-through bypass: if WB is writing the same register being read
    // in ID this cycle, forward the write data directly (avoids stale read
    // since write is synchronous but read is combinational).
    assign rd1 = (ra1 == 5'd0) ? 32'd0 :
                 (we && (wa == ra1)) ? wd : regs[ra1];
    assign rd2 = (ra2 == 5'd0) ? 32'd0 :
                 (we && (wa == ra2)) ? wd : regs[ra2];

    always @(posedge clk) begin
        if (we && (wa != 5'd0))
            regs[wa] <= wd;
    end
endmodule


// -------------------------------------------------------------
// Instruction Memory (simple ROM, word addressed)
// -------------------------------------------------------------
module instr_mem (
    input  [31:0] addr,
    output [31:0] instr
);
    reg [31:0] mem [0:255];
    integer j;

    initial begin
        // Default: fill with NOPs (ADDI x0,x0,0)
        for (j = 0; j < 256; j = j + 1)
            mem[j] = 32'h00000013;
        // Test program can be loaded via $readmemh from testbench
    end

    assign instr = mem[addr[9:2]];
endmodule


// -------------------------------------------------------------
// NOTE: the old local data_mem module has been removed. Chiplet-1
// no longer owns a local data memory -- mem_we/mem_addr/mem_wdata
// are driven out to the interconnect and Chiplet-2's SRAM instead.
// See mem_rdata_in / mem_we / mem_addr / mem_wdata top-level ports.
// -------------------------------------------------------------

// -------------------------------------------------------------
// Control Unit (combinational decode of opcode)
// -------------------------------------------------------------
module control_unit (
    input  [6:0] opcode,
    output reg reg_write,
    output reg mem_read,
    output reg mem_write,
    output reg mem_to_reg,
    output reg alu_src,      // 0 = reg, 1 = immediate
    output reg branch,
    output reg branch_ne,    // 1 for BNE, 0 for BEQ (only valid if branch=1)
    output reg jump,
    output reg [1:0] alu_op  // 00 = load/store(add), 01 = branch(sub),
                              // 10 = R-type/I-type (use funct), 11 = unused
);
    localparam OP_RTYPE  = 7'b0110011;
    localparam OP_ITYPE  = 7'b0010011;
    localparam OP_LOAD   = 7'b0000011;
    localparam OP_STORE  = 7'b0100011;
    localparam OP_BRANCH = 7'b1100011;
    localparam OP_JAL    = 7'b1101111;

    always @(*) begin
        // defaults
        reg_write  = 1'b0;
        mem_read   = 1'b0;
        mem_write  = 1'b0;
        mem_to_reg = 1'b0;
        alu_src    = 1'b0;
        branch     = 1'b0;
        branch_ne  = 1'b0;
        jump       = 1'b0;
        alu_op     = 2'b00;

        case (opcode)
            OP_RTYPE: begin
                reg_write = 1'b1;
                alu_op    = 2'b10;
            end
            OP_ITYPE: begin
                reg_write = 1'b1;
                alu_src   = 1'b1;
                alu_op    = 2'b10;
            end
            OP_LOAD: begin
                reg_write  = 1'b1;
                alu_src    = 1'b1;
                mem_read   = 1'b1;
                mem_to_reg = 1'b1;
                alu_op     = 2'b00;
            end
            OP_STORE: begin
                alu_src   = 1'b1;
                mem_write = 1'b1;
                alu_op    = 2'b00;
            end
            OP_BRANCH: begin
                branch = 1'b1;
                alu_op = 2'b01;
            end
            OP_JAL: begin
                reg_write = 1'b1;
                jump      = 1'b1;
            end
            default: ; // NOP / unsupported -> all zero
        endcase
    end
endmodule


// -------------------------------------------------------------
// ALU Control (derives alu_ctrl from alu_op + funct3/funct7)
// -------------------------------------------------------------
module alu_control (
    input  [1:0] alu_op,
    input  [2:0] funct3,
    input        funct7_b5,   // bit 5 of funct7 (distinguishes ADD/SUB, SRL/SRA)
    input        is_itype,    // I-type immediate ops (ANDI/ORI/ADDI) don't use funct7
    output reg [3:0] alu_ctrl
);
    always @(*) begin
        case (alu_op)
            2'b00: alu_ctrl = 4'b0000; // load/store -> ADD
            2'b01: alu_ctrl = 4'b0001; // branch -> SUB (compare)
            2'b10: begin
                case (funct3)
                    3'b000: alu_ctrl = (funct7_b5 && !is_itype) ? 4'b0001 : 4'b0000; // SUB : ADD
                    3'b111: alu_ctrl = 4'b0010; // AND
                    3'b110: alu_ctrl = 4'b0011; // OR
                    3'b100: alu_ctrl = 4'b0100; // XOR
                    3'b010: alu_ctrl = 4'b0101; // SLT
                    3'b001: alu_ctrl = 4'b0110; // SLL
                    3'b101: alu_ctrl = funct7_b5 ? 4'b1000 : 4'b0111; // SRA : SRL
                    default: alu_ctrl = 4'b0000;
                endcase
            end
            default: alu_ctrl = 4'b0000;
        endcase
    end
endmodule


// -------------------------------------------------------------
// Immediate Generator
// -------------------------------------------------------------
module imm_gen (
    input  [31:0] instr,
    output reg [31:0] imm_out
);
    wire [6:0] opcode = instr[6:0];
    localparam OP_LOAD   = 7'b0000011;
    localparam OP_ITYPE  = 7'b0010011;
    localparam OP_STORE  = 7'b0100011;
    localparam OP_BRANCH = 7'b1100011;
    localparam OP_JAL    = 7'b1101111;

    always @(*) begin
        case (opcode)
            OP_LOAD, OP_ITYPE:
                imm_out = {{20{instr[31]}}, instr[31:20]};
            OP_STORE:
                imm_out = {{20{instr[31]}}, instr[31:25], instr[11:7]};
            OP_BRANCH:
                imm_out = {{19{instr[31]}}, instr[31], instr[7], instr[30:25], instr[11:8], 1'b0};
            OP_JAL:
                imm_out = {{11{instr[31]}}, instr[31], instr[19:12], instr[20], instr[30:21], 1'b0};
            default:
                imm_out = 32'd0;
        endcase
    end
endmodule


// -------------------------------------------------------------
// Hazard Detection Unit (load-use stall)
// -------------------------------------------------------------
module hazard_unit (
    input        id_ex_mem_read,
    input  [4:0] id_ex_rd,
    input  [4:0] if_id_rs1,
    input  [4:0] if_id_rs2,
    output       stall // 1 = stall IF/ID and PC, bubble ID/EX
);
    assign stall = id_ex_mem_read &&
                   ((id_ex_rd == if_id_rs1) || (id_ex_rd == if_id_rs2)) &&
                   (id_ex_rd != 5'd0);
endmodule


// -------------------------------------------------------------
// Forwarding Unit
// -------------------------------------------------------------
module forwarding_unit (
    input  [4:0] ex_rs1,
    input  [4:0] ex_rs2,
    input  [4:0] mem_rd,
    input        mem_reg_write,
    input  [4:0] wb_rd,
    input        wb_reg_write,
    output reg [1:0] fwd_a, // 00=reg, 01=fwd from MEM stage, 10=fwd from WB stage
    output reg [1:0] fwd_b
);
    always @(*) begin
        // Forward A (rs1)
        if (mem_reg_write && (mem_rd != 5'd0) && (mem_rd == ex_rs1))
            fwd_a = 2'b01;
        else if (wb_reg_write && (wb_rd != 5'd0) && (wb_rd == ex_rs1))
            fwd_a = 2'b10;
        else
            fwd_a = 2'b00;

        // Forward B (rs2)
        if (mem_reg_write && (mem_rd != 5'd0) && (mem_rd == ex_rs2))
            fwd_b = 2'b01;
        else if (wb_reg_write && (wb_rd != 5'd0) && (wb_rd == ex_rs2))
            fwd_b = 2'b10;
        else
            fwd_b = 2'b00;
    end
endmodule


// -------------------------------------------------------------
// TOP LEVEL PIPELINE
// -------------------------------------------------------------
module riscv_pipeline_top (
    input         clk,
    input         rst_n,

    // -----------------------------------------------------------
    // Cross-chiplet data memory interface.
    // LW/SW no longer hit a local array -- they now go out to the
    // UCIe-inspired interconnect, which carries them to Chiplet-2's
    // SRAM. This is what makes the interconnect load-bearing during
    // normal functional operation, not just a test-only connection.
    // -----------------------------------------------------------
    output        mem_we,
    output [31:0] mem_addr,
    output [31:0] mem_wdata,
    input  [31:0] mem_rdata_in,

    // ---- Phase 2: real link handshake ----
    // mem_req   : "I have a memory transaction outstanding."
    //             Held high, with addr/we/wdata stable, until the
    //             link says it is done.
    // mem_ready : driven by the interconnect. High for exactly one
    //             cycle, meaning "this transaction completes at the
    //             next clock edge; for a load, mem_rdata_in is
    //             valid NOW." The CPU freezes while it is low.
    output        mem_req,
    input         mem_ready
);

    // ===========================================================
    // IF STAGE
    // ===========================================================
    // Forward-declared here (used by mem_wait below, before the
    // EX/MEM pipeline register block where it's normally declared
    // alongside its siblings). Genus's read_hdl requires a signal
    // be declared before its first use, unlike simulators which
    // tolerate forward references within a module. Only the
    // declaration moved -- the reg is still driven from the same
    // EX/MEM always block further down, unchanged.
    reg ex_mem_mem_read;
    reg ex_mem_mem_write;   // same reason: mem_req now reads it too

    reg  [31:0] pc;
    wire [31:0] pc_next;
    wire [31:0] if_instr;
    wire        stall;
    wire        pc_write;
    wire        branch_taken;
    wire [31:0] branch_target;

    // -----------------------------------------------------------
    // mem_wait: freeze the pipeline while a memory transaction is
    // outstanding across the link.
    //
    // PHASE 1 (what this replaces): mem_wait came from a local
    // one-shot flag, "reg mem_wait_done", that unconditionally
    // granted every load exactly one wait cycle. That hard-coded
    // the SRAM's latency into the CPU and meant the interconnect
    // could not influence the core at all -- the link's own
    // c1_mem_ready output was tied to 1'b1 and left unconnected.
    //
    // PHASE 2 (now): the link tells the CPU when it is done. The
    // number of wait cycles is whatever the interconnect takes,
    // so link latency is now a property of the LINK, not a
    // constant baked into the pipeline.
    //
    // Loads AND stores both claim the link. In Phase 1 only loads
    // ever waited, so a store was fire-and-forget: the CPU issued
    // it and moved on the very next cycle, never learning whether
    // the far die had taken it. That is only survivable because
    // the Phase 1 "link" was a wire -- with real latency, the next
    // instruction could issue a second transaction on top of one
    // still in flight. Including mem_write here is what makes the
    // link's backpressure apply to the whole memory interface.
    // -----------------------------------------------------------
    assign mem_req = ex_mem_mem_read || ex_mem_mem_write;

    wire mem_wait = mem_req && !mem_ready;

    assign pc_write = ~stall & ~mem_wait;

    instr_mem u_imem (
        .addr  (pc),
        .instr (if_instr)
    );

    assign pc_next = branch_taken ? branch_target : (pc + 32'd4);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            pc <= 32'd0;
        else if (pc_write)
            pc <= pc_next;
    end

    // IF/ID pipeline register
    reg [31:0] if_id_instr;
    reg [31:0] if_id_pc;
    wire       if_id_flush;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            if_id_instr <= 32'h00000013; // NOP
            if_id_pc    <= 32'd0;
        end else if (if_id_flush) begin
            // Synchronous flush (branch/jump taken) -- same NOP
            // insertion as reset, but kept as its own branch since
            // synthesis tools require the async-reset condition to
            // stand alone, not OR'd with a synchronous condition.
            if_id_instr <= 32'h00000013; // NOP
            if_id_pc    <= 32'd0;
        end else if (pc_write) begin
            if_id_instr <= if_instr;
            if_id_pc    <= pc;
        end
    end

    // ===========================================================
    // ID STAGE
    // ===========================================================
    wire [6:0] id_opcode  = if_id_instr[6:0];
    wire [4:0] id_rd_addr = if_id_instr[11:7];
    wire [2:0] id_funct3  = if_id_instr[14:12];
    wire [4:0] id_rs1     = if_id_instr[19:15];
    wire [4:0] id_rs2     = if_id_instr[24:20];
    wire       id_funct7_b5 = if_id_instr[30];

    wire        id_reg_write, id_mem_read, id_mem_write, id_mem_to_reg;
    wire        id_alu_src, id_branch, id_branch_ne, id_jump;
    wire [1:0]  id_alu_op;

    control_unit u_ctrl (
        .opcode     (id_opcode),
        .reg_write  (id_reg_write),
        .mem_read   (id_mem_read),
        .mem_write  (id_mem_write),
        .mem_to_reg (id_mem_to_reg),
        .alu_src    (id_alu_src),
        .branch     (id_branch),
        .branch_ne  (id_branch_ne),
        .jump       (id_jump),
        .alu_op     (id_alu_op)
    );

    wire [31:0] id_imm;
    imm_gen u_imm (
        .instr   (if_id_instr),
        .imm_out (id_imm)
    );

    wire [31:0] id_rd1, id_rd2;
    wire        wb_reg_write_w;
    wire [4:0]  wb_rd_w;
    wire [31:0] wb_wd_w;

    register_file u_rf (
        .clk (clk),
        .we  (wb_reg_write_w),
        .ra1 (id_rs1),
        .ra2 (id_rs2),
        .wa  (wb_rd_w),
        .wd  (wb_wd_w),
        .rd1 (id_rd1),
        .rd2 (id_rd2)
    );

    // Hazard detection (needs ID/EX rd + mem_read, and current IF/ID rs1/rs2)
    wire ex_mem_read_hz;
    wire [4:0] ex_rd_hz;
    hazard_unit u_hazard (
        .id_ex_mem_read (ex_mem_read_hz),
        .id_ex_rd       (ex_rd_hz),
        .if_id_rs1      (id_rs1),
        .if_id_rs2      (id_rs2),
        .stall          (stall)
    );

    assign if_id_flush = branch_taken; // flush IF/ID on taken branch/jump

    // ID/EX pipeline register
    reg        id_ex_reg_write, id_ex_mem_read, id_ex_mem_write, id_ex_mem_to_reg;
    reg        id_ex_alu_src, id_ex_branch, id_ex_branch_ne, id_ex_jump;
    reg [1:0]  id_ex_alu_op;
    reg [31:0] id_ex_rd1, id_ex_rd2, id_ex_imm, id_ex_pc;
    reg [4:0]  id_ex_rs1, id_ex_rs2, id_ex_rd;
    reg [2:0]  id_ex_funct3;
    reg        id_ex_funct7_b5;
    reg        id_ex_is_itype;

    wire id_ex_bubble = stall || branch_taken;
    wire id_ex_freeze = mem_wait;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            id_ex_reg_write  <= 1'b0;
            id_ex_mem_read   <= 1'b0;
            id_ex_mem_write  <= 1'b0;
            id_ex_mem_to_reg <= 1'b0;
            id_ex_alu_src    <= 1'b0;
            id_ex_branch     <= 1'b0;
            id_ex_branch_ne  <= 1'b0;
            id_ex_jump       <= 1'b0;
            id_ex_alu_op     <= 2'b00;
            id_ex_rd1        <= 32'd0;
            id_ex_rd2        <= 32'd0;
            id_ex_imm        <= 32'd0;
            id_ex_pc         <= 32'd0;
            id_ex_rs1        <= 5'd0;
            id_ex_rs2        <= 5'd0;
            id_ex_rd         <= 5'd0;
            id_ex_funct3     <= 3'd0;
            id_ex_funct7_b5  <= 1'b0;
            id_ex_is_itype   <= 1'b0;
        end else if (id_ex_freeze) begin
            // Hold everything: the instruction already decoded into
            // ID/EX must wait its turn -- EX/MEM is frozen too (see
            // mem_wait below), so there's no room downstream yet.
            // Do NOT bubble here, or this already-decoded instruction
            // is lost for good and never re-decoded (IF/ID is frozen
            // too, so nothing re-fills it).
        end else if (id_ex_bubble) begin
            // Synchronous bubble insertion (stall/branch only) --
            // kept as its own branch, separate from the async reset
            // condition above, per synthesis tool requirements.
            id_ex_reg_write  <= 1'b0;
            id_ex_mem_read   <= 1'b0;
            id_ex_mem_write  <= 1'b0;
            id_ex_mem_to_reg <= 1'b0;
            id_ex_alu_src    <= 1'b0;
            id_ex_branch     <= 1'b0;
            id_ex_branch_ne  <= 1'b0;
            id_ex_jump       <= 1'b0;
            id_ex_alu_op     <= 2'b00;
            id_ex_rd1        <= 32'd0;
            id_ex_rd2        <= 32'd0;
            id_ex_imm        <= 32'd0;
            id_ex_pc         <= 32'd0;
            id_ex_rs1        <= 5'd0;
            id_ex_rs2        <= 5'd0;
            id_ex_rd         <= 5'd0;
            id_ex_funct3     <= 3'd0;
            id_ex_funct7_b5  <= 1'b0;
            id_ex_is_itype   <= 1'b0;
        end else begin
            id_ex_reg_write  <= id_reg_write;
            id_ex_mem_read   <= id_mem_read;
            id_ex_mem_write  <= id_mem_write;
            id_ex_mem_to_reg <= id_mem_to_reg;
            id_ex_alu_src    <= id_alu_src;
            id_ex_branch     <= id_branch;
            id_ex_branch_ne  <= id_branch_ne;
            id_ex_jump       <= id_jump;
            id_ex_alu_op     <= id_alu_op;
            id_ex_rd1        <= id_rd1;
            id_ex_rd2        <= id_rd2;
            id_ex_imm        <= id_imm;
            id_ex_pc         <= if_id_pc;
            id_ex_rs1        <= id_rs1;
            id_ex_rs2        <= id_rs2;
            id_ex_rd         <= id_rd_addr;
            id_ex_funct3     <= id_funct3;
            id_ex_funct7_b5  <= id_funct7_b5;
            id_ex_is_itype   <= (id_opcode == 7'b0010011);
        end
    end

    assign ex_mem_read_hz = id_ex_mem_read;
    assign ex_rd_hz       = id_ex_rd;

    // ===========================================================
    // EX STAGE
    // ===========================================================
    wire [3:0] ex_alu_ctrl;
    alu_control u_alu_ctrl (
        .alu_op     (id_ex_alu_op),
        .funct3     (id_ex_funct3),
        .funct7_b5  (id_ex_funct7_b5),
        .is_itype   (id_ex_is_itype),
        .alu_ctrl   (ex_alu_ctrl)
    );

    // Forwarding
    wire [1:0] fwd_a, fwd_b;
    wire       mem_reg_write_fwd;
    wire [4:0] mem_rd_fwd;

    forwarding_unit u_fwd (
        .ex_rs1        (id_ex_rs1),
        .ex_rs2        (id_ex_rs2),
        .mem_rd        (mem_rd_fwd),
        .mem_reg_write (mem_reg_write_fwd),
        .wb_rd         (wb_rd_w),
        .wb_reg_write  (wb_reg_write_w),
        .fwd_a         (fwd_a),
        .fwd_b         (fwd_b)
    );

    reg [31:0] mem_alu_result_fwd; // from EX/MEM reg (declared below, forward decl via wire)
    wire [31:0] ex_fwd_mem_data;
    wire [31:0] ex_fwd_wb_data;

    assign ex_fwd_mem_data = mem_alu_result_fwd;
    assign ex_fwd_wb_data  = wb_wd_w;

    wire [31:0] ex_operand_a_pref =
        (fwd_a == 2'b01) ? ex_fwd_mem_data :
        (fwd_a == 2'b10) ? ex_fwd_wb_data  : id_ex_rd1;

    wire [31:0] ex_operand_b_pref =
        (fwd_b == 2'b01) ? ex_fwd_mem_data :
        (fwd_b == 2'b10) ? ex_fwd_wb_data  : id_ex_rd2;

    wire [31:0] ex_alu_in_b = id_ex_alu_src ? id_ex_imm : ex_operand_b_pref;

    wire [31:0] ex_alu_result;
    wire        ex_alu_zero;

    alu u_alu (
        .a         (ex_operand_a_pref),
        .b         (ex_alu_in_b),
        .alu_ctrl  (ex_alu_ctrl),
        .result    (ex_alu_result),
        .zero      (ex_alu_zero)
    );

    // Branch resolution (in EX stage)
    wire ex_branch_hit = id_ex_branch && (id_ex_branch_ne ? ~ex_alu_zero : ex_alu_zero);
    assign branch_taken  = ex_branch_hit || id_ex_jump;
    // JAL and branch targets are both PC-relative, so this is a single
    // computation -- no need to distinguish jump vs branch here.
    assign branch_target = id_ex_pc + id_ex_imm;
    wire [31:0] ex_pc_plus4 = id_ex_pc + 32'd4;

    // ===========================================================
    // EX/MEM pipeline register
    // ===========================================================
    // ex_mem_mem_read is forward-declared near the top of the
    // module (needed by mem_wait, above the EX/MEM register block)
    reg        ex_mem_reg_write, ex_mem_mem_to_reg;  // ex_mem_mem_write forward-declared above
    reg        ex_mem_jump;
    reg [31:0] ex_mem_alu_result, ex_mem_rd2, ex_mem_pc_plus4;
    reg [4:0]  ex_mem_rd;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ex_mem_reg_write  <= 1'b0;
            ex_mem_mem_read   <= 1'b0;
            ex_mem_mem_write  <= 1'b0;
            ex_mem_mem_to_reg <= 1'b0;
            ex_mem_jump       <= 1'b0;
            ex_mem_alu_result <= 32'd0;
            ex_mem_rd2        <= 32'd0;
            ex_mem_pc_plus4   <= 32'd0;
            ex_mem_rd         <= 5'd0;
        end else if (mem_wait) begin
            // Hold everything: the transaction's address/control info
            // must stay stable until the link completes it.
            //
            // This branch used to clear ex_mem_mem_write ("don't
            // re-issue a write during the wait"). That was dead code
            // in Phase 1 -- mem_wait only ever asserted for loads,
            // and a load has ex_mem_mem_write=0 already. It is
            // removed because it becomes actively wrong once stores
            // also wait: clearing the write enable mid-transaction
            // would make the store request vanish before the link
            // ever accepted it. Single-pulsing the SRAM write is the
            // interconnect's job now (see c2_func_we there), not the
            // CPU's.
        end else begin
            ex_mem_reg_write  <= id_ex_reg_write;
            ex_mem_mem_read   <= id_ex_mem_read;
            ex_mem_mem_write  <= id_ex_mem_write;
            ex_mem_mem_to_reg <= id_ex_mem_to_reg;
            ex_mem_jump       <= id_ex_jump;
            ex_mem_alu_result <= ex_alu_result;
            ex_mem_rd2        <= ex_operand_b_pref; // store data (post-forward)
            ex_mem_pc_plus4   <= ex_pc_plus4;
            ex_mem_rd         <= id_ex_rd;
        end
    end

    always @(*) begin
        mem_alu_result_fwd = ex_mem_alu_result;
    end
    assign mem_reg_write_fwd = ex_mem_reg_write;
    assign mem_rd_fwd        = ex_mem_rd;

    // ===========================================================
    // MEM STAGE
    // Data memory request now drives the top-level interconnect
    // ports instead of a local data_mem instance. mem_rdata_in
    // is whatever comes back across the link (Chiplet-2's SRAM,
    // once wired up in chiplet_soc_top).
    // ===========================================================
    assign mem_we    = ex_mem_mem_write;
    assign mem_addr  = ex_mem_alu_result;
    assign mem_wdata = ex_mem_rd2;
    wire [31:0] mem_rdata = mem_rdata_in;

    // ===========================================================
    // MEM/WB pipeline register
    // ===========================================================
    reg        mem_wb_reg_write, mem_wb_mem_to_reg, mem_wb_jump;
    reg [31:0] mem_wb_alu_result, mem_wb_mem_rdata, mem_wb_pc_plus4;
    reg [4:0]  mem_wb_rd;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mem_wb_reg_write  <= 1'b0;
            mem_wb_mem_to_reg <= 1'b0;
            mem_wb_jump       <= 1'b0;
            mem_wb_alu_result <= 32'd0;
            mem_wb_mem_rdata  <= 32'd0;
            mem_wb_pc_plus4   <= 32'd0;
            mem_wb_rd         <= 5'd0;
        end else if (mem_wait) begin
            // Data not valid yet this cycle -- don't capture, just hold.
        end else begin
            mem_wb_reg_write  <= ex_mem_reg_write;
            mem_wb_mem_to_reg <= ex_mem_mem_to_reg;
            mem_wb_jump       <= ex_mem_jump;
            mem_wb_alu_result <= ex_mem_alu_result;
            mem_wb_mem_rdata  <= mem_rdata;
            mem_wb_pc_plus4   <= ex_mem_pc_plus4;
            mem_wb_rd         <= ex_mem_rd;
        end
    end

    // ===========================================================
    // WB STAGE
    // ===========================================================
    assign wb_wd_w        = mem_wb_jump ? mem_wb_pc_plus4 :
                             (mem_wb_mem_to_reg ? mem_wb_mem_rdata : mem_wb_alu_result);
    assign wb_reg_write_w = mem_wb_reg_write;
    assign wb_rd_w        = mem_wb_rd;

endmodule
