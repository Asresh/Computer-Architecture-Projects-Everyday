// -----------------------------------------------------------------------------
// tb_decoder.sv - Self-checking testbench for the RV32I decoder + immgen
//
// Strategy:
//   * A pure-software golden model recomputes every control line and the
//     immediate directly from the 32-bit instruction, using the same decode
//     rules as the RTL but written independently.
//   * Field-assembly helpers (enc_r/i/s/b/u/j) build legal encodings so the
//     directed list covers at least one instruction per opcode and, for the
//     R/I/LOAD/STORE/BRANCH groups, every funct3 (both bit30 variants where
//     they matter). A few deliberately illegal opcodes check the safe default.
//   * Randomized stimulus fuzzes 400 arbitrary 32-bit words; legal ones decode
//     normally, illegal ones must fall through to the NOP default -- every one
//     is checked against the golden model.
//   * A watchdog timeout guards against a hung simulation.
//   * A VCD waveform is dumped for inspection / rendering.
//
// On success the TB prints exactly:  RESULT: *** PASS ***
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps
`default_nettype none

module tb_decoder;

    // ---- opcode / ALU / imm encodings (mirror the DUT) ----
    localparam logic [6:0] OP_RTYPE  = 7'b0110011, OP_ITYPE  = 7'b0010011,
                           OP_LOAD   = 7'b0000011, OP_STORE  = 7'b0100011,
                           OP_BRANCH = 7'b1100011, OP_JAL    = 7'b1101111,
                           OP_JALR   = 7'b1100111, OP_LUI    = 7'b0110111,
                           OP_AUIPC  = 7'b0010111;

    localparam logic [3:0] ALU_ADD  = 4'b0000, ALU_SUB  = 4'b0001,
                           ALU_SLL  = 4'b0010, ALU_SLT  = 4'b0011,
                           ALU_SLTU = 4'b0100, ALU_XOR  = 4'b0101,
                           ALU_SRL  = 4'b0110, ALU_SRA  = 4'b0111,
                           ALU_OR   = 4'b1000, ALU_AND  = 4'b1001;

    localparam logic [2:0] IMM_NONE = 3'd0, IMM_I = 3'd1, IMM_S = 3'd2,
                           IMM_B    = 3'd3, IMM_U = 3'd4, IMM_J = 3'd5;

    // ---- DUT interface ----
    logic [31:0] instr;
    logic        reg_write, alu_src, mem_read, mem_write, branch, jump;
    logic [1:0]  result_src;
    logic [3:0]  alu_ctrl;
    logic [2:0]  imm_type;
    logic [31:0] imm;

    // Free-running clock: not needed by the combinational DUT, but it gives the
    // VCD a recognizable time base for the waveform image.
    logic clk = 1'b0;
    always #5 clk = ~clk;

    integer errors = 0;
    integer checks = 0;

    decoder dut (
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

    // ==================================================================
    // Instruction field-assembly helpers (build legal encodings).
    // ==================================================================
    function automatic [31:0] enc_r(input [6:0] f7, input [4:0] rs2, rs1,
                                    input [2:0] f3, input [4:0] rd,
                                    input [6:0] op);
        enc_r = {f7, rs2, rs1, f3, rd, op};
    endfunction

    function automatic [31:0] enc_i(input [11:0] immv, input [4:0] rs1,
                                    input [2:0] f3, input [4:0] rd,
                                    input [6:0] op);
        enc_i = {immv, rs1, f3, rd, op};
    endfunction

    function automatic [31:0] enc_s(input [11:0] immv, input [4:0] rs2, rs1,
                                    input [2:0] f3, input [6:0] op);
        enc_s = {immv[11:5], rs2, rs1, f3, immv[4:0], op};
    endfunction

    function automatic [31:0] enc_b(input [12:0] immv, input [4:0] rs2, rs1,
                                    input [2:0] f3, input [6:0] op);
        enc_b = {immv[12], immv[10:5], rs2, rs1, f3,
                 immv[4:1], immv[11], op};
    endfunction

    function automatic [31:0] enc_u(input [31:12] immv, input [4:0] rd,
                                    input [6:0] op);
        enc_u = {immv, rd, op};
    endfunction

    function automatic [31:0] enc_j(input [20:0] immv, input [4:0] rd,
                                    input [6:0] op);
        enc_j = {immv[20], immv[10:1], immv[11], immv[19:12], rd, op};
    endfunction

    // ==================================================================
    // Golden model: independent recomputation of the controls and immediate.
    // ==================================================================
    function automatic [3:0] g_r_alu(input [2:0] f3, input logic b30);
        case (f3)
            3'b000 : g_r_alu = b30 ? ALU_SUB : ALU_ADD;
            3'b001 : g_r_alu = ALU_SLL;
            3'b010 : g_r_alu = ALU_SLT;
            3'b011 : g_r_alu = ALU_SLTU;
            3'b100 : g_r_alu = ALU_XOR;
            3'b101 : g_r_alu = b30 ? ALU_SRA : ALU_SRL;
            3'b110 : g_r_alu = ALU_OR;
            3'b111 : g_r_alu = ALU_AND;
            default: g_r_alu = ALU_ADD;
        endcase
    endfunction

    function automatic [3:0] g_i_alu(input [2:0] f3, input logic b30);
        case (f3)
            3'b000 : g_i_alu = ALU_ADD;
            3'b001 : g_i_alu = ALU_SLL;
            3'b010 : g_i_alu = ALU_SLT;
            3'b011 : g_i_alu = ALU_SLTU;
            3'b100 : g_i_alu = ALU_XOR;
            3'b101 : g_i_alu = b30 ? ALU_SRA : ALU_SRL;
            3'b110 : g_i_alu = ALU_OR;
            3'b111 : g_i_alu = ALU_AND;
            default: g_i_alu = ALU_ADD;
        endcase
    endfunction

    function automatic [3:0] g_br_alu(input [2:0] f3);
        case (f3)
            3'b000, 3'b001: g_br_alu = ALU_SUB;
            3'b100, 3'b101: g_br_alu = ALU_SLT;
            3'b110, 3'b111: g_br_alu = ALU_SLTU;
            default:        g_br_alu = ALU_SUB;
        endcase
    endfunction

    // Packed control vector: {reg_write, alu_src, mem_read, mem_write, branch,
    // jump, result_src[1:0], alu_ctrl[3:0], imm_type[2:0]} = 15 bits.
    function automatic [14:0] gold_ctrl(input [31:0] ins);
        logic       rw, as, mr, mw, br, jp;
        logic [1:0] rs;
        logic [3:0] ac;
        logic [2:0] it;
        logic [6:0] op;
        logic [2:0] f3;
        logic       b30;
        op  = ins[6:0];
        f3  = ins[14:12];
        b30 = ins[30];
        rw = 0; as = 0; mr = 0; mw = 0; br = 0; jp = 0;
        rs = 2'b00; ac = ALU_ADD; it = IMM_NONE;
        case (op)
            OP_RTYPE : begin rw=1; as=0; rs=2'b00; it=IMM_NONE;
                             ac=g_r_alu(f3,b30); end
            OP_ITYPE : begin rw=1; as=1; rs=2'b00; it=IMM_I;
                             ac=g_i_alu(f3,b30); end
            OP_LOAD  : begin rw=1; as=1; mr=1; rs=2'b01; it=IMM_I; ac=ALU_ADD; end
            OP_STORE : begin as=1; mw=1; it=IMM_S; ac=ALU_ADD; end
            OP_BRANCH: begin br=1; as=0; it=IMM_B; ac=g_br_alu(f3); end
            OP_JAL   : begin rw=1; jp=1; rs=2'b10; it=IMM_J; ac=ALU_ADD; end
            OP_JALR  : begin rw=1; jp=1; as=1; rs=2'b10; it=IMM_I; ac=ALU_ADD; end
            OP_LUI   : begin rw=1; as=1; rs=2'b00; it=IMM_U; ac=ALU_ADD; end
            OP_AUIPC : begin rw=1; as=1; rs=2'b00; it=IMM_U; ac=ALU_ADD; end
            default  : ; // NOP defaults
        endcase
        gold_ctrl = {rw, as, mr, mw, br, jp, rs, ac, it};
    endfunction

    function automatic [31:0] gold_imm(input [31:0] ins);
        logic [2:0]  it;
        logic [14:0] c;
        c  = gold_ctrl(ins);
        it = c[2:0];                   // imm_type is the low 3 bits
        case (it)
            IMM_I  : gold_imm = {{20{ins[31]}}, ins[31:20]};
            IMM_S  : gold_imm = {{20{ins[31]}}, ins[31:25], ins[11:7]};
            IMM_B  : gold_imm = {{19{ins[31]}}, ins[31], ins[7],
                                 ins[30:25], ins[11:8], 1'b0};
            IMM_U  : gold_imm = {ins[31:12], 12'b0};
            IMM_J  : gold_imm = {{11{ins[31]}}, ins[31], ins[19:12],
                                 ins[20], ins[30:21], 1'b0};
            default: gold_imm = 32'b0;
        endcase
    endfunction

    // ==================================================================
    // Apply one instruction, settle, and check controls + immediate.
    // ==================================================================
    task automatic check(input [31:0] ins);
        logic [14:0] got_ctrl, exp_ctrl;
        logic [31:0] exp_imm;
        instr = ins;
        #1;                                   // settle combinational logic
        got_ctrl = {reg_write, alu_src, mem_read, mem_write, branch, jump,
                    result_src, alu_ctrl, imm_type};
        exp_ctrl = gold_ctrl(ins);
        exp_imm  = gold_imm(ins);
        checks = checks + 1;
        if (got_ctrl !== exp_ctrl) begin
            errors = errors + 1;
            $display("[FAIL] ctrl instr=%h got=%b exp=%b", ins, got_ctrl, exp_ctrl);
        end
        if (imm !== exp_imm) begin
            errors = errors + 1;
            $display("[FAIL] imm  instr=%h got=%h exp=%h", ins, imm, exp_imm);
        end
        #1;
    endtask

    integer i;
    logic [2:0] f3;

    initial begin
        $dumpfile("decoder.vcd");
        $dumpvars(0, tb_decoder);

        instr = 32'h0000_0013;   // canonical NOP (addi x0,x0,0)

        // ============ Directed showcase (drives the waveform window) ======
        check(enc_i(12'd10,  5'd1, 3'b000, 5'd2, OP_ITYPE)); // addi x2,x1,10
        check(enc_r(7'b0000000, 5'd3, 5'd2, 3'b000, 5'd4, OP_RTYPE)); // add x4,x2,x3
        check(enc_r(7'b0100000, 5'd3, 5'd2, 3'b000, 5'd5, OP_RTYPE)); // sub x5,x2,x3
        check(enc_i(12'd4,   5'd1, 3'b010, 5'd6, OP_LOAD));  // lw  x6,4(x1)
        check(enc_s(12'd8,   5'd6, 5'd1, 3'b010, OP_STORE)); // sw  x6,8(x1)
        check(enc_b(13'd16,  5'd4, 5'd5, 3'b000, OP_BRANCH));// beq x5,x4,+16
        check(enc_j(21'd32,  5'd1, OP_JAL));                 // jal x1,+32
        check(enc_u(20'hABCDE, 5'd7, OP_LUI));               // lui x7,0xABCDE

        // ============ Full opcode / funct3 coverage =======================
        // R-type: every funct3; funct3 000 and 101 with both bit30 values.
        check(enc_r(7'b0000000, 5'd3, 5'd2, 3'b000, 5'd1, OP_RTYPE)); // add
        check(enc_r(7'b0100000, 5'd3, 5'd2, 3'b000, 5'd1, OP_RTYPE)); // sub
        check(enc_r(7'b0000000, 5'd3, 5'd2, 3'b001, 5'd1, OP_RTYPE)); // sll
        check(enc_r(7'b0000000, 5'd3, 5'd2, 3'b010, 5'd1, OP_RTYPE)); // slt
        check(enc_r(7'b0000000, 5'd3, 5'd2, 3'b011, 5'd1, OP_RTYPE)); // sltu
        check(enc_r(7'b0000000, 5'd3, 5'd2, 3'b100, 5'd1, OP_RTYPE)); // xor
        check(enc_r(7'b0000000, 5'd3, 5'd2, 3'b101, 5'd1, OP_RTYPE)); // srl
        check(enc_r(7'b0100000, 5'd3, 5'd2, 3'b101, 5'd1, OP_RTYPE)); // sra
        check(enc_r(7'b0000000, 5'd3, 5'd2, 3'b110, 5'd1, OP_RTYPE)); // or
        check(enc_r(7'b0000000, 5'd3, 5'd2, 3'b111, 5'd1, OP_RTYPE)); // and

        // I-type OP-IMM: every funct3; srli / srai split on bit30.
        check(enc_i(12'h123, 5'd2, 3'b000, 5'd1, OP_ITYPE)); // addi
        check(enc_i(12'h5,   5'd2, 3'b001, 5'd1, OP_ITYPE)); // slli
        check(enc_i(12'hFFF, 5'd2, 3'b010, 5'd1, OP_ITYPE)); // slti (imm=-1)
        check(enc_i(12'h010, 5'd2, 3'b011, 5'd1, OP_ITYPE)); // sltiu
        check(enc_i(12'h0F0, 5'd2, 3'b100, 5'd1, OP_ITYPE)); // xori
        check(enc_i({7'b0000000,5'd7}, 5'd2, 3'b101, 5'd1, OP_ITYPE)); // srli
        check(enc_i({7'b0100000,5'd7}, 5'd2, 3'b101, 5'd1, OP_ITYPE)); // srai
        check(enc_i(12'h00F, 5'd2, 3'b110, 5'd1, OP_ITYPE)); // ori
        check(enc_i(12'h0FF, 5'd2, 3'b111, 5'd1, OP_ITYPE)); // andi

        // Loads: every funct3 that exists (lb/lh/lw/lbu/lhu).
        check(enc_i(12'd0,  5'd1, 3'b000, 5'd1, OP_LOAD));   // lb
        check(enc_i(12'd2,  5'd1, 3'b001, 5'd1, OP_LOAD));   // lh
        check(enc_i(12'd4,  5'd1, 3'b010, 5'd1, OP_LOAD));   // lw
        check(enc_i(12'd1,  5'd1, 3'b100, 5'd1, OP_LOAD));   // lbu
        check(enc_i(12'd6,  5'd1, 3'b101, 5'd1, OP_LOAD));   // lhu

        // Stores: sb / sh / sw.
        check(enc_s(12'd0,  5'd2, 5'd1, 3'b000, OP_STORE));  // sb
        check(enc_s(12'd2,  5'd2, 5'd1, 3'b001, OP_STORE));  // sh
        check(enc_s(12'hFFC,5'd2, 5'd1, 3'b010, OP_STORE));  // sw (imm=-4)

        // Branches: every funct3 (beq/bne/blt/bge/bltu/bgeu) + negative imm.
        check(enc_b(13'd8,    5'd2, 5'd1, 3'b000, OP_BRANCH)); // beq
        check(enc_b(13'd8,    5'd2, 5'd1, 3'b001, OP_BRANCH)); // bne
        check(enc_b(13'h1FF8, 5'd2, 5'd1, 3'b100, OP_BRANCH)); // blt (neg)
        check(enc_b(13'd12,   5'd2, 5'd1, 3'b101, OP_BRANCH)); // bge
        check(enc_b(13'd20,   5'd2, 5'd1, 3'b110, OP_BRANCH)); // bltu
        check(enc_b(13'd24,   5'd2, 5'd1, 3'b111, OP_BRANCH)); // bgeu

        // JALR / AUIPC / more LUI/JAL.
        check(enc_i(12'd0,   5'd1, 3'b000, 5'd1, OP_JALR));  // jalr x1,0(x1)
        check(enc_u(20'h00001, 5'd3, OP_AUIPC));             // auipc x3
        check(enc_j(21'h1FFFFE, 5'd0, OP_JAL));              // jal x0, negative
        check(enc_u(20'h80000, 5'd4, OP_LUI));               // lui MSB set

        // Illegal / unimplemented opcodes -> safe NOP default.
        check(32'h0000_0000);                                // all-zero
        check(32'hFFFF_FFFF);                                // all-one
        check({25'h0, 7'b1111111});                          // bogus opcode
        check({25'h0, 7'b0001111});                          // FENCE (unimpl.)
        check({25'h0, 7'b1110011});                          // SYSTEM (unimpl.)

        // ============ Randomized fuzz =====================================
        for (i = 0; i < 400; i = i + 1)
            check($random);

        // ============ Verdict =============================================
        if (errors == 0)
            $display("RESULT: *** PASS *** (%0d checks)", checks);
        else
            $display("RESULT: *** FAIL *** (%0d errors / %0d checks)",
                     errors, checks);
        $finish;
    end

    // Watchdog timeout.
    initial begin
        #2_000_000;
        $display("RESULT: *** FAIL *** (timeout)");
        $finish;
    end

endmodule

`default_nettype wire
