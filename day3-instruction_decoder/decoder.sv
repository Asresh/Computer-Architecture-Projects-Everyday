// -----------------------------------------------------------------------------
// decoder.sv - RV32I instruction decoder + immediate generator
//
// A synthesizable, purely combinational control unit for a single-cycle RISC-V
// core. It cracks a 32-bit instruction into:
//
//   * the datapath control lines a single-cycle core needs
//     (reg_write, alu_src, mem_read, mem_write, branch, jump, result_src,
//      alu_ctrl), and
//   * a sign-extended immediate produced by a format-aware immediate generator
//     (I / S / B / U / J), selected by imm_type.
//
// The ALU-control encoding matches the Day 1 ALU (alu.sv) so the two modules
// drop straight into the same datapath. The register-file operands come from
// the Day 2 register file. Illegal / unrecognized opcodes decode to a safe
// NOP-like default (no register write, no memory access, no control transfer).
//
// Purely combinational: no clock, no reset. Lint-friendly: every output is
// assigned on every path via up-front defaults, `default_nettype none.
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps
`default_nettype none

module decoder (
    input  wire [31:0] instr,       // 32-bit instruction word

    // ---- datapath control ----
    output reg         reg_write,   // write rd in the register file
    output reg         alu_src,     // 1: ALU operand B = immediate, 0: = rs2
    output reg         mem_read,    // data-memory load
    output reg         mem_write,   // data-memory store
    output reg         branch,      // conditional branch (B-type)
    output reg         jump,        // unconditional jump (JAL / JALR)
    output reg  [1:0]  result_src,  // write-back source: 00 ALU, 01 MEM, 10 PC+4
    output reg  [3:0]  alu_ctrl,    // ALU operation (Day 1 alu.sv encoding)

    // ---- immediate generator ----
    output reg  [2:0]  imm_type,    // 0 NONE, 1 I, 2 S, 3 B, 4 U, 5 J
    output reg  [31:0] imm          // sign-extended immediate
);

    // ------------------------------------------------------------------
    // RV32I base opcodes (instr[6:0]).
    // ------------------------------------------------------------------
    localparam logic [6:0] OP_RTYPE  = 7'b0110011; // add/sub/sll/.../and
    localparam logic [6:0] OP_ITYPE  = 7'b0010011; // addi/slti/.../andi
    localparam logic [6:0] OP_LOAD   = 7'b0000011; // lb/lh/lw/lbu/lhu
    localparam logic [6:0] OP_STORE  = 7'b0100011; // sb/sh/sw
    localparam logic [6:0] OP_BRANCH = 7'b1100011; // beq/bne/blt/bge/bltu/bgeu
    localparam logic [6:0] OP_JAL    = 7'b1101111; // jal
    localparam logic [6:0] OP_JALR   = 7'b1100111; // jalr
    localparam logic [6:0] OP_LUI    = 7'b0110111; // lui
    localparam logic [6:0] OP_AUIPC  = 7'b0010111; // auipc

    // ------------------------------------------------------------------
    // ALU control codes (identical to Day 1 alu.sv).
    // ------------------------------------------------------------------
    localparam logic [3:0] ALU_ADD  = 4'b0000, ALU_SUB  = 4'b0001,
                           ALU_SLL  = 4'b0010, ALU_SLT  = 4'b0011,
                           ALU_SLTU = 4'b0100, ALU_XOR  = 4'b0101,
                           ALU_SRL  = 4'b0110, ALU_SRA  = 4'b0111,
                           ALU_OR   = 4'b1000, ALU_AND  = 4'b1001;

    // ------------------------------------------------------------------
    // Immediate format selector.
    // ------------------------------------------------------------------
    localparam logic [2:0] IMM_NONE = 3'd0, IMM_I = 3'd1, IMM_S = 3'd2,
                           IMM_B    = 3'd3, IMM_U = 3'd4, IMM_J = 3'd5;

    wire [6:0] opcode = instr[6:0];
    wire [2:0] funct3 = instr[14:12];
    wire       bit30  = instr[30];        // funct7[5]: add/sub, srl/sra select

    // ------------------------------------------------------------------
    // ALU-control decode helpers.
    //   * R-type: full funct3 + bit30 (bit30 picks SUB vs ADD, SRA vs SRL).
    //   * I-type (OP-IMM): funct3; there is no SUBI, so funct3==000 is ADD.
    //     Only the shift-right immediate (funct3==101) uses bit30 (SRAI/SRLI).
    //   * Branch: the comparison the branch resolves on (SUB for eq/ne so the
    //     zero flag decides, SLT for lt/ge, SLTU for ltu/geu).
    // ------------------------------------------------------------------
    function automatic [3:0] r_alu(input [2:0] f3, input logic b30);
        case (f3)
            3'b000 : r_alu = b30 ? ALU_SUB : ALU_ADD;
            3'b001 : r_alu = ALU_SLL;
            3'b010 : r_alu = ALU_SLT;
            3'b011 : r_alu = ALU_SLTU;
            3'b100 : r_alu = ALU_XOR;
            3'b101 : r_alu = b30 ? ALU_SRA : ALU_SRL;
            3'b110 : r_alu = ALU_OR;
            3'b111 : r_alu = ALU_AND;
            default: r_alu = ALU_ADD;
        endcase
    endfunction

    function automatic [3:0] i_alu(input [2:0] f3, input logic b30);
        case (f3)
            3'b000 : i_alu = ALU_ADD;                 // addi
            3'b001 : i_alu = ALU_SLL;                 // slli
            3'b010 : i_alu = ALU_SLT;                 // slti
            3'b011 : i_alu = ALU_SLTU;                // sltiu
            3'b100 : i_alu = ALU_XOR;                 // xori
            3'b101 : i_alu = b30 ? ALU_SRA : ALU_SRL; // srai / srli
            3'b110 : i_alu = ALU_OR;                  // ori
            3'b111 : i_alu = ALU_AND;                 // andi
            default: i_alu = ALU_ADD;
        endcase
    endfunction

    function automatic [3:0] br_alu(input [2:0] f3);
        case (f3)
            3'b000, 3'b001: br_alu = ALU_SUB;   // beq  / bne
            3'b100, 3'b101: br_alu = ALU_SLT;   // blt  / bge
            3'b110, 3'b111: br_alu = ALU_SLTU;  // bltu / bgeu
            default:        br_alu = ALU_SUB;
        endcase
    endfunction

    // ------------------------------------------------------------------
    // Main control decode. Defaults describe a NOP so that any unmapped
    // opcode (or an unused branch/store funct3) is inert and never writes
    // architectural state.
    // ------------------------------------------------------------------
    always_comb begin
        reg_write  = 1'b0;
        alu_src    = 1'b0;
        mem_read   = 1'b0;
        mem_write  = 1'b0;
        branch     = 1'b0;
        jump       = 1'b0;
        result_src = 2'b00;
        alu_ctrl   = ALU_ADD;
        imm_type   = IMM_NONE;

        case (opcode)
            OP_RTYPE: begin
                reg_write  = 1'b1;
                alu_src    = 1'b0;              // both operands are registers
                result_src = 2'b00;             // ALU result
                imm_type   = IMM_NONE;
                alu_ctrl   = r_alu(funct3, bit30);
            end
            OP_ITYPE: begin
                reg_write  = 1'b1;
                alu_src    = 1'b1;              // operand B = immediate
                result_src = 2'b00;
                imm_type   = IMM_I;
                alu_ctrl   = i_alu(funct3, bit30);
            end
            OP_LOAD: begin
                reg_write  = 1'b1;
                alu_src    = 1'b1;              // address = rs1 + imm
                mem_read   = 1'b1;
                result_src = 2'b01;             // write-back = memory data
                imm_type   = IMM_I;
                alu_ctrl   = ALU_ADD;
            end
            OP_STORE: begin
                alu_src    = 1'b1;              // address = rs1 + imm
                mem_write  = 1'b1;
                imm_type   = IMM_S;
                alu_ctrl   = ALU_ADD;
            end
            OP_BRANCH: begin
                branch     = 1'b1;
                alu_src    = 1'b0;              // compare rs1 vs rs2
                imm_type   = IMM_B;
                alu_ctrl   = br_alu(funct3);
            end
            OP_JAL: begin
                reg_write  = 1'b1;
                jump       = 1'b1;
                result_src = 2'b10;             // link = PC + 4
                imm_type   = IMM_J;
                alu_ctrl   = ALU_ADD;
            end
            OP_JALR: begin
                reg_write  = 1'b1;
                jump       = 1'b1;
                alu_src    = 1'b1;              // target = rs1 + imm
                result_src = 2'b10;             // link = PC + 4
                imm_type   = IMM_I;
                alu_ctrl   = ALU_ADD;
            end
            OP_LUI: begin
                reg_write  = 1'b1;
                alu_src    = 1'b1;              // datapath forces operand A = 0
                result_src = 2'b00;             // result = 0 + imm = imm
                imm_type   = IMM_U;
                alu_ctrl   = ALU_ADD;
            end
            OP_AUIPC: begin
                reg_write  = 1'b1;
                alu_src    = 1'b1;              // datapath forces operand A = PC
                result_src = 2'b00;             // result = PC + imm
                imm_type   = IMM_U;
                alu_ctrl   = ALU_ADD;
            end
            default: begin
                // Illegal / unimplemented: keep the NOP defaults above.
            end
        endcase
    end

    // ------------------------------------------------------------------
    // Immediate generator. Each format's field slicing / sign-extension is a
    // continuous assign (like Day 1's shamt), so the always_comb below only
    // selects among whole 32-bit candidates -- no part-selects inside the
    // process. U/J shift the fields into place; I/S/B sign-extend from bit 31.
    // ------------------------------------------------------------------
    wire [31:0] imm_i_c = {{20{instr[31]}}, instr[31:20]};
    wire [31:0] imm_s_c = {{20{instr[31]}}, instr[31:25], instr[11:7]};
    wire [31:0] imm_b_c = {{19{instr[31]}}, instr[31], instr[7],
                           instr[30:25], instr[11:8], 1'b0};
    wire [31:0] imm_u_c = {instr[31:12], 12'b0};
    wire [31:0] imm_j_c = {{11{instr[31]}}, instr[31], instr[19:12],
                           instr[20], instr[30:21], 1'b0};

    always_comb begin
        case (imm_type)
            IMM_I  : imm = imm_i_c;
            IMM_S  : imm = imm_s_c;
            IMM_B  : imm = imm_b_c;
            IMM_U  : imm = imm_u_c;
            IMM_J  : imm = imm_j_c;
            default: imm = 32'b0;               // IMM_NONE (R-type / illegal)
        endcase
    end

endmodule

`default_nettype wire
