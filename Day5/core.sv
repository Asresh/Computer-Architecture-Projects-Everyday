// -----------------------------------------------------------------------------
// core.sv - Single-cycle RV32I core (integer subset)
//
// Integrates the earlier days into one working single-cycle processor:
//   * imem.sv     - instruction memory (ROM), preloaded program   (Day 5)
//   * decoder.sv  - instruction decoder + immediate generator      (Day 3)
//   * regfile.sv  - 32x32 register file (read-first here)          (Day 2)
//   * alu.sv      - integer ALU                                    (Day 1)
//   * lsu.sv      - load/store unit + data memory                  (Day 4)
//   * PC + next-PC (branch/jump) logic                             (this file)
//
// One instruction completes per clock cycle: the combinational fetch/decode/
// read/execute/memory/write-back path settles within the cycle, and the PC,
// register file, and data memory all commit on the rising edge.
//
// Supported RV32I integer subset:
//   add sub and or xor sll srl sra slt sltu  (R-type)
//   addi slti sltiu xori ori andi slli srli srai  (I-type immediates)
//   lb lh lw lbu lhu / sb sh sw  (loads/stores)
//   beq bne blt bge bltu bgeu  (branches)
//   jal jalr  (jumps)   lui auipc  (upper immediates)
//
// Datapath notes:
//   * Operand A is muxed for the upper-immediate ops: LUI feeds 0 (so the ALU
//     computes 0+imm=imm) and AUIPC feeds the PC (PC+imm); everything else
//     feeds rs1.
//   * Operand B is rs2 or the immediate per the decoder's alu_src.
//   * Branch resolution reuses the ALU: the decoder maps beq/bne -> SUB (the
//     zero flag decides) and blt/bge/bltu/bgeu -> SLT/SLTU (the result LSB
//     decides).
//   * JALR reuses the ALU's rs1+imm; JAL and taken branches use a dedicated
//     PC+imm adder.
//   * The register file is instantiated read-first (WRITE_FIRST=0): in a
//     single-cycle core an instruction must read the OLD value of its own
//     destination, and same-cycle forwarding would form a combinational loop.
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps
`default_nettype none

module core #(
    parameter logic [31:0] RESET_PC = 32'h0000_0000
) (
    input  wire        clk,
    input  wire        rst_n,               // active-low synchronous reset

    // Debug/observation taps (for the testbench and waveform).
    output wire [31:0] dbg_pc,              // PC of the instruction executing now
    output wire [31:0] dbg_instr,           // fetched instruction word
    output wire        dbg_reg_write,       // register write-enable this cycle
    output wire [4:0]  dbg_rd,              // destination register index
    output wire [31:0] dbg_result           // value written back to rd
);

    // ---- opcode constants for datapath glue ----
    localparam logic [6:0] OP_JAL   = 7'b1101111, OP_JALR  = 7'b1100111,
                           OP_LUI   = 7'b0110111, OP_AUIPC = 7'b0010111;

    // ---- program counter ----
    reg  [31:0] pc;
    reg  [31:0] next_pc;

    // ---- fetch ----
    wire [31:0] instr;
    imem u_imem (.addr(pc), .instr(instr));

    // ---- instruction field extraction (continuous assigns) ----
    wire [6:0] opcode  = instr[6:0];
    wire [2:0] funct3  = instr[14:12];
    wire [4:0] rs1_idx = instr[19:15];
    wire [4:0] rs2_idx = instr[24:20];
    wire [4:0] rd_idx  = instr[11:7];

    wire is_lui   = (opcode == OP_LUI);
    wire is_auipc = (opcode == OP_AUIPC);
    wire is_jal   = (opcode == OP_JAL);
    wire is_jalr  = (opcode == OP_JALR);

    // ---- decode ----
    wire        reg_write, alu_src, mem_read, mem_write, branch, jump;
    wire [1:0]  result_src;
    wire [3:0]  alu_ctrl;
    wire [2:0]  imm_type;              // unused in the datapath, observed only
    wire [31:0] imm;

    decoder u_dec (
        .instr      (instr),
        .reg_write  (reg_write),
        .alu_src    (alu_src),
        .mem_read   (mem_read),
        .mem_write  (mem_write),
        .branch     (branch),
        .jump       (jump),
        .result_src (result_src),
        .alu_ctrl   (alu_ctrl),
        .imm_type   (imm_type),
        .imm        (imm)
    );

    // ---- register file (read-first for single-cycle) ----
    wire [31:0] rs1_data, rs2_data;
    reg  [31:0] rd_wdata;

    regfile #(.WRITE_FIRST(1'b0)) u_rf (
        .clk    (clk),
        .rst_n  (rst_n),
        .we     (reg_write),
        .waddr  (rd_idx),
        .wdata  (rd_wdata),
        .raddr1 (rs1_idx),
        .rdata1 (rs1_data),
        .raddr2 (rs2_idx),
        .rdata2 (rs2_data)
    );

    // ---- ALU with operand-A / operand-B muxes ----
    wire [31:0] alu_a = is_lui   ? 32'h0 :
                        is_auipc ? pc    : rs1_data;
    wire [31:0] alu_b = alu_src ? imm : rs2_data;
    wire [31:0] alu_result;
    wire        alu_zero;

    alu u_alu (
        .a      (alu_a),
        .b      (alu_b),
        .alu_op (alu_ctrl),
        .result (alu_result),
        .zero   (alu_zero)
    );

    // ---- data memory / load-store unit ----
    wire [31:0] load_data;

    lsu u_lsu (
        .clk       (clk),
        .rst_n     (rst_n),
        .mem_read  (mem_read),
        .mem_write (mem_write),
        .funct3    (funct3),
        .addr      (alu_result),    // effective address = rs1 + imm
        .wdata     (rs2_data),      // store data
        .rdata     (load_data)
    );

    // ---- write-back source mux ----
    localparam logic [1:0] RES_ALU = 2'b00, RES_MEM = 2'b01, RES_PC4 = 2'b10;
    wire [31:0] pc_plus4 = pc + 32'd4;

    always_comb begin
        case (result_src)
            RES_ALU : rd_wdata = alu_result;
            RES_MEM : rd_wdata = load_data;
            RES_PC4 : rd_wdata = pc_plus4;
            default : rd_wdata = alu_result;
        endcase
    end

    // ---- branch resolution (reuses the ALU) ----
    wire alu_lsb = alu_result[0];      // SLT/SLTU "less-than" bit
    reg  branch_take;
    always_comb begin
        case (funct3)
            3'b000 : branch_take = branch &  alu_zero;   // beq
            3'b001 : branch_take = branch & ~alu_zero;   // bne
            3'b100 : branch_take = branch &  alu_lsb;    // blt  (signed)
            3'b101 : branch_take = branch & ~alu_lsb;    // bge
            3'b110 : branch_take = branch &  alu_lsb;    // bltu (unsigned)
            3'b111 : branch_take = branch & ~alu_lsb;    // bgeu
            default: branch_take = 1'b0;
        endcase
    end

    // ---- next-PC selection ----
    wire [31:0] pc_plus_imm = pc + imm;                    // branch / jal target
    wire [31:0] jalr_target = {alu_result[31:1], 1'b0};    // (rs1+imm) & ~1

    always_comb begin
        if      (is_jalr)      next_pc = jalr_target;
        else if (is_jal)       next_pc = pc_plus_imm;
        else if (branch_take)  next_pc = pc_plus_imm;
        else                   next_pc = pc_plus4;
    end

    // ---- PC register ----
    always_ff @(posedge clk) begin
        if (!rst_n) pc <= RESET_PC;
        else        pc <= next_pc;
    end

    // ---- debug taps ----
    assign dbg_pc        = pc;
    assign dbg_instr     = instr;
    assign dbg_reg_write = reg_write;
    assign dbg_rd        = rd_idx;
    assign dbg_result    = rd_wdata;

endmodule

`default_nettype wire
