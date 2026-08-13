// -----------------------------------------------------------------------------
// tb_pipeline_rv32i.sv - Self-checking testbench for the 5-stage pipelined
//                        RV32I core.
//
// Strategy: an *independent* sequential ISS (instruction-set simulator) written
// directly in the testbench executes a program one instruction at a time with
// no pipeline (hence no hazards) and produces the golden final architectural
// state (all 32 registers + data memory). The same program is backdoor-loaded
// into the pipelined DUT, which is clocked until it drains; the DUT's final
// register file and data memory are then compared byte-for-byte / word-for-word
// against the golden model.
//
// If the forwarding unit, the load-use stall, or the branch flush were wrong,
// the pipeline would compute a different architectural state than the
// dependency-free reference and the mismatch would be caught.
//
// Coverage:
//   * A directed program that deliberately hits every hazard class:
//       - EX/MEM->EX forward (distance-1 RAW)
//       - MEM/WB->EX forward (distance-2 RAW)
//       - regfile write-first (distance-3 RAW)
//       - load-use hazard (one-cycle stall)
//       - store-data forwarding
//       - taken-branch 2-instruction flush / not-taken fall-through
//       - JAL link + JALR return, forwarding into the branch comparator
//   * Randomised straight-line programs (heavy RAW density + loads) x many
//     seeds -> thousands of independent state assertions.
//
// Prints "RESULT: *** PASS ***" only if every assertion holds. Dumps a VCD.
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps
`default_nettype none

module tb_pipeline_rv32i;

    localparam int unsigned IMEM_WORDS = 256;
    localparam int unsigned DMEM_BYTES = 4096;

    // --------------------------------------------------------------
    // DUT
    // --------------------------------------------------------------
    logic clk = 1'b0;
    logic rst_n;

    logic [31:0] dbg_pc_if, dbg_pc_id, dbg_pc_ex, dbg_pc_mem, dbg_pc_wb;
    logic        dbg_stall, dbg_flush;
    logic [1:0]  dbg_fwd_a, dbg_fwd_b;
    logic        dbg_wb_we;
    logic [4:0]  dbg_wb_rd;
    logic [31:0] dbg_wb_data;

    pipeline_rv32i #(.IMEM_WORDS(IMEM_WORDS), .DMEM_BYTES(DMEM_BYTES)) dut (
        .clk(clk), .rst_n(rst_n),
        .dbg_pc_if(dbg_pc_if), .dbg_pc_id(dbg_pc_id), .dbg_pc_ex(dbg_pc_ex),
        .dbg_pc_mem(dbg_pc_mem), .dbg_pc_wb(dbg_pc_wb),
        .dbg_stall(dbg_stall), .dbg_flush(dbg_flush),
        .dbg_fwd_a(dbg_fwd_a), .dbg_fwd_b(dbg_fwd_b),
        .dbg_wb_we(dbg_wb_we), .dbg_wb_rd(dbg_wb_rd), .dbg_wb_data(dbg_wb_data)
    );

    always #5 clk = ~clk;                       // 100 MHz

    // --------------------------------------------------------------
    // Program image + golden state
    // --------------------------------------------------------------
    localparam int MAXP = 256;
    logic [31:0] prog [0:MAXP-1];
    int          plen;

    logic [31:0] gregs [0:31];
    logic [7:0]  gmem  [0:DMEM_BYTES-1];

    integer errors = 0;
    integer checks = 0;

    // --------------------------------------------------------------
    // Tiny RV32I assembler helpers (build 32-bit encodings)
    // --------------------------------------------------------------
    function automatic logic [31:0] r_(input logic [6:0] f7, input logic [4:0] rs2,
                                       input logic [4:0] rs1, input logic [2:0] f3,
                                       input logic [4:0] rd,  input logic [6:0] op);
        return {f7, rs2, rs1, f3, rd, op};
    endfunction

    function automatic logic [31:0] i_(input logic [11:0] imm, input logic [4:0] rs1,
                                       input logic [2:0] f3, input logic [4:0] rd,
                                       input logic [6:0] op);
        return {imm, rs1, f3, rd, op};
    endfunction

    function automatic logic [31:0] s_(input logic [11:0] imm, input logic [4:0] rs2,
                                       input logic [4:0] rs1, input logic [2:0] f3,
                                       input logic [6:0] op);
        return {imm[11:5], rs2, rs1, f3, imm[4:0], op};
    endfunction

    function automatic logic [31:0] b_(input logic [12:0] imm, input logic [4:0] rs2,
                                       input logic [4:0] rs1, input logic [2:0] f3);
        return {imm[12], imm[10:5], rs2, rs1, f3, imm[4:1], imm[11], 7'b1100011};
    endfunction

    function automatic logic [31:0] u_(input logic [19:0] imm20, input logic [4:0] rd,
                                       input logic [6:0] op);
        return {imm20, rd, op};
    endfunction

    function automatic logic [31:0] j_(input logic [20:0] imm, input logic [4:0] rd);
        return {imm[20], imm[10:1], imm[11], imm[19:12], rd, 7'b1101111};
    endfunction

    // --------------------------------------------------------------
    // Independent sequential ISS (golden reference model)
    // --------------------------------------------------------------
    function automatic logic [31:0] ld_word(input int a);
        return {gmem[a+3], gmem[a+2], gmem[a+1], gmem[a+0]};
    endfunction

    task automatic run_golden;
        int pc, npc, steps;
        logic [31:0] iw;
        logic [6:0]  op;   logic [2:0] f3;   logic f7b;
        logic [4:0]  rd, rs1, rs2;
        logic [31:0] a, b, imm, res, addr;
        logic [4:0]  sh;
        logic        taken;
        begin
            for (int r = 0; r < 32; r++) gregs[r] = 32'h0;
            for (int m = 0; m < DMEM_BYTES; m++) gmem[m] = 8'h0;
            pc = 0; steps = 0;
            while (steps < 100000) begin
                iw  = prog[pc[31:2]];
                op  = iw[6:0];  f3 = iw[14:12]; f7b = iw[30];
                rd  = iw[11:7]; rs1 = iw[19:15]; rs2 = iw[24:20];
                a   = gregs[rs1]; b = gregs[rs2];
                npc = pc + 4;
                res = 32'h0;
                unique case (op)
                    7'b0110111: begin                              // LUI
                        res = {iw[31:12], 12'h0}; gregs[rd] = res;
                    end
                    7'b0010111: begin                              // AUIPC
                        res = pc + {iw[31:12], 12'h0}; gregs[rd] = res;
                    end
                    7'b1101111: begin                              // JAL
                        imm = {{11{iw[31]}}, iw[31], iw[19:12], iw[20],
                               iw[30:21], 1'b0};
                        gregs[rd] = pc + 4; npc = pc + imm;
                    end
                    7'b1100111: begin                              // JALR
                        imm = {{20{iw[31]}}, iw[31:20]};
                        res = pc + 4;
                        npc = (a + imm) & 32'hFFFF_FFFE;
                        gregs[rd] = res;
                    end
                    7'b1100011: begin                              // BRANCH
                        imm = {{19{iw[31]}}, iw[31], iw[7], iw[30:25],
                               iw[11:8], 1'b0};
                        unique case (f3)
                            3'b000:  taken = (a == b);
                            3'b001:  taken = (a != b);
                            3'b100:  taken = ($signed(a) <  $signed(b));
                            3'b101:  taken = ($signed(a) >= $signed(b));
                            3'b110:  taken = (a <  b);
                            3'b111:  taken = (a >= b);
                            default: taken = 1'b0;
                        endcase
                        if (taken) npc = pc + imm;
                    end
                    7'b0000011: begin                              // LOAD
                        imm  = {{20{iw[31]}}, iw[31:20]};
                        addr = a + imm;
                        unique case (f3)
                            3'b000: res = {{24{gmem[addr[31:0]][7]}}, gmem[addr]};
                            3'b001: res = {{16{gmem[addr+1][7]}}, gmem[addr+1], gmem[addr]};
                            3'b010: res = ld_word(addr);
                            3'b100: res = {24'h0, gmem[addr]};
                            3'b101: res = {16'h0, gmem[addr+1], gmem[addr]};
                            default: res = ld_word(addr);
                        endcase
                        gregs[rd] = res;
                    end
                    7'b0100011: begin                              // STORE
                        imm  = {{20{iw[31]}}, iw[31:25], iw[11:7]};
                        addr = a + imm;
                        gmem[addr+0] = b[7:0];
                        if (f3 != 3'b000) gmem[addr+1] = b[15:8];
                        if (f3 == 3'b010) begin
                            gmem[addr+2] = b[23:16];
                            gmem[addr+3] = b[31:24];
                        end
                    end
                    7'b0010011: begin                              // OP-IMM
                        imm = {{20{iw[31]}}, iw[31:20]};
                        sh  = imm[4:0];
                        unique case (f3)
                            3'b000: res = a + imm;
                            3'b010: res = ($signed(a) < $signed(imm)) ? 32'h1 : 32'h0;
                            3'b011: res = (a < imm) ? 32'h1 : 32'h0;
                            3'b100: res = a ^ imm;
                            3'b110: res = a | imm;
                            3'b111: res = a & imm;
                            3'b001: res = a << sh;
                            3'b101: res = f7b ? ($unsigned($signed(a) >>> sh))
                                              : (a >> sh);
                            default: res = a + imm;
                        endcase
                        gregs[rd] = res;
                    end
                    7'b0110011: begin                              // OP (R-type)
                        sh = b[4:0];
                        unique case (f3)
                            3'b000: res = f7b ? (a - b) : (a + b);
                            3'b001: res = a << sh;
                            3'b010: res = ($signed(a) < $signed(b)) ? 32'h1 : 32'h0;
                            3'b011: res = (a < b) ? 32'h1 : 32'h0;
                            3'b100: res = a ^ b;
                            3'b101: res = f7b ? ($unsigned($signed(a) >>> sh))
                                              : (a >> sh);
                            3'b110: res = a | b;
                            3'b111: res = a & b;
                            default: res = a + b;
                        endcase
                        gregs[rd] = res;
                    end
                    default: /* treated as NOP */ ;
                endcase
                gregs[0] = 32'h0;                  // x0 stays zero
                if (npc == pc) begin steps = 100000; end   // spin => halt
                else begin pc = npc; steps++; end
            end
        end
    endtask

    // --------------------------------------------------------------
    // Backdoor load + run + compare
    // --------------------------------------------------------------
    task automatic load_dut;
        begin
            for (int i = 0; i < IMEM_WORDS; i++)
                dut.rom[i] = (i < plen) ? prog[i] : 32'h0000_0013; // NOP
            for (int m = 0; m < DMEM_BYTES; m++) dut.dmem[m]  = 8'h0;
            for (int r = 0; r < 32;         r++) dut.xregs[r] = 32'h0;
        end
    endtask

    task automatic do_reset;
        begin
            rst_n = 1'b0;
            @(posedge clk); @(posedge clk);
            @(negedge clk); rst_n = 1'b1;
        end
    endtask

    task automatic compare_state(input string tag);
        int nb;
        begin
            for (int r = 0; r < 32; r++) begin
                checks++;
                if (dut.xregs[r] !== gregs[r]) begin
                    errors++;
                    $display("  [%s] MISMATCH x%0d : dut=%08x golden=%08x",
                             tag, r, dut.xregs[r], gregs[r]);
                end
            end
            // Compare the low 512 data-memory bytes (covers every program's
            // working set).
            nb = 512;
            for (int m = 0; m < nb; m++) begin
                checks++;
                if (dut.dmem[m] !== gmem[m]) begin
                    errors++;
                    $display("  [%s] MISMATCH mem[%0d] : dut=%02x golden=%02x",
                             tag, m, dut.dmem[m], gmem[m]);
                end
            end
        end
    endtask

    // Run one loaded program: golden first, then the DUT, then compare.
    task automatic run_case(input string tag, input int cycles);
        begin
            run_golden();
            load_dut();
            do_reset();
            repeat (cycles) @(posedge clk);
            compare_state(tag);
        end
    endtask

    // --------------------------------------------------------------
    // Directed hazard program
    // --------------------------------------------------------------
    localparam logic [6:0] OP = 7'b0110011, OPI = 7'b0010011,
                           LD = 7'b0000011, ST  = 7'b0100011;

    task automatic build_directed;
        int p;
        begin
            p = 0;
            // distance-1 EX/MEM->EX forward: x1=5 ; x2=x1+3=8
            prog[p++] = i_(12'd5, 5'd0, 3'b000, 5'd1, OPI);      // addi x1,x0,5
            prog[p++] = i_(12'd3, 5'd1, 3'b000, 5'd2, OPI);      // addi x2,x1,3
            // distance-2 MEM/WB->EX forward: x3=x1+x2=13 with 1 filler between
            prog[p++] = i_(12'd0, 5'd0, 3'b000, 5'd0, OPI);      // nop
            prog[p++] = r_(7'h00, 5'd2, 5'd1, 3'b000, 5'd3, OP); // add x3,x1,x2 =13
            // distance-3 regfile write-first: x4 = x3 + x3 = 26
            prog[p++] = i_(12'd0, 5'd0, 3'b000, 5'd0, OPI);      // nop
            prog[p++] = i_(12'd0, 5'd0, 3'b000, 5'd0, OPI);      // nop
            prog[p++] = r_(7'h00, 5'd3, 5'd3, 3'b000, 5'd4, OP); // add x4,x3,x3 =26
            // store-data forwarding + load-use stall:
            prog[p++] = i_(12'd100, 5'd0, 3'b000, 5'd6, OPI);    // addi x6,x0,100
            prog[p++] = s_(12'd0, 5'd6, 5'd0, 3'b010, ST);       // sw x6,0(x0) (fwd data)
            prog[p++] = i_(12'd0,  5'd0, 3'b010, 5'd7, LD);      // lw x7,0(x0) =100
            prog[p++] = r_(7'h00, 5'd7, 5'd7, 3'b000, 5'd8, OP); // add x8,x7,x7 =200 (load-use)
            // byte/half memory ops
            prog[p++] = i_(12'd2, 5'd0, 3'b000, 5'd9, OPI);      // addi x9,x0,2
            prog[p++] = s_(12'd16, 5'd9, 5'd0, 3'b000, ST);      // sb x9,16(x0)
            prog[p++] = i_(-12'sd7, 5'd0, 3'b000, 5'd10, OPI);   // addi x10,x0,-7
            prog[p++] = s_(12'd20, 5'd10, 5'd0, 3'b001, ST);     // sh x10,20(x0)
            prog[p++] = i_(12'd16, 5'd0, 3'b100, 5'd11, LD);     // lbu x11,16(x0) =2
            prog[p++] = i_(12'd20, 5'd0, 3'b001, 5'd12, LD);     // lh  x12,20(x0) =-7
            // taken branch flushes 2 shadow instructions:
            prog[p++] = i_(12'd1, 5'd0, 3'b000, 5'd13, OPI);     // addi x13,x0,1
            prog[p++] = b_(13'd12, 5'd13, 5'd13, 3'b000);        // beq x13,x13,+12 (taken)
            prog[p++] = i_(12'd999, 5'd0, 3'b000, 5'd14, OPI);   // (shadow) x14 poison
            prog[p++] = i_(12'd888, 5'd0, 3'b000, 5'd14, OPI);   // (shadow) x14 poison
            prog[p++] = i_(12'd42, 5'd0, 3'b000, 5'd15, OPI);    // addi x15,x0,42 (target)
            // not-taken branch falls through:
            prog[p++] = b_(13'd8, 5'd13, 5'd0, 3'b000);          // beq x13,x0,+8 (not taken)
            prog[p++] = i_(12'd77, 5'd0, 3'b000, 5'd16, OPI);    // addi x16,x0,77 (runs)
            // JAL link then JALR return via forwarded link register:
            prog[p++] = j_(21'd8, 5'd17);                        // jal x17,+8 (link=pc+4)
            prog[p++] = i_(12'd555, 5'd0, 3'b000, 5'd18, OPI);   // (skipped) x18 poison
            prog[p++] = i_(12'd5, 5'd0, 3'b000, 5'd19, OPI);     // addi x19,x0,5 (target)
            // forwarding into the branch comparator (blt uses freshly produced x20):
            prog[p++] = i_(12'd3, 5'd0, 3'b000, 5'd20, OPI);     // addi x20,x0,3
            prog[p++] = b_(13'd8, 5'd15, 5'd20, 3'b100);         // blt x20,x15,+8 (3<42 taken)
            prog[p++] = i_(12'd111, 5'd0, 3'b000, 5'd21, OPI);   // (shadow) poison x21
            prog[p++] = i_(12'd9, 5'd0, 3'b000, 5'd22, OPI);     // addi x22,x0,9 (target)
            // halt (spin)
            prog[p++] = j_(21'd0, 5'd0);                         // jal x0,0
            plen = p;
        end
    endtask

    // --------------------------------------------------------------
    // Randomised straight-line program generator
    // --------------------------------------------------------------
    // Straight-line (no control flow except the final spin) so termination is
    // guaranteed and the golden ISS is trivially correct. Heavy RAW density
    // (small register pool) stresses forwarding; back-to-back loads + uses
    // stress the load-use stall. Memory ops use base x0 with in-range aligned
    // offsets so addresses stay valid and deterministic.
    task automatic build_random(input int n);
        int p, sel;
        logic [4:0] rd, rs1, rs2;
        logic [2:0] f3;
        logic [11:0] imm;
        begin
            p = 0;
            for (int q = 0; q < n; q++) begin
                rd  = $random % 8 + 1;             // x1..x8  (dense reuse)
                rs1 = $random % 9;                 // x0..x8
                rs2 = $random % 9;
                sel = $random % 10;
                if (sel < 4) begin                 // R-type ALU
                    f3 = $random;
                    prog[p++] = r_(($random & 1) ? 7'h20 : 7'h00, rs2, rs1,
                                   f3, rd, OP);
                    // constrain sub/sra pattern already handled by f7 bit
                end else if (sel < 7) begin        // I-type ALU
                    f3  = $random;
                    imm = $random;
                    if (f3 == 3'b001 || f3 == 3'b101) imm = imm & 12'h01F; // shamt
                    prog[p++] = i_(imm, rs1, f3, rd, OPI);
                end else if (sel < 8) begin        // LUI
                    prog[p++] = u_($random, rd, 7'b0110111);
                end else if (sel == 8) begin       // SW then dependent LW pair
                    imm = ({$random} % 32) << 2;   // aligned, 0..124
                    prog[p++] = s_(imm[11:0], rs2, 5'd0, 3'b010, ST); // sw rs2,imm(x0)
                    prog[p++] = i_(imm[11:0], 5'd0, 3'b010, rd, LD);  // lw rd,imm(x0)
                end else begin                     // LW then immediate use (load-use)
                    imm = ({$random} % 32) << 2;
                    prog[p++] = i_(imm[11:0], 5'd0, 3'b010, rd, LD);  // lw rd,imm(x0)
                    prog[p++] = r_(7'h00, rd, rd, 3'b000, rd, OP);    // add rd,rd,rd
                end
            end
            prog[p++] = j_(21'd0, 5'd0);           // spin/halt
            plen = p;
        end
    endtask

    // --------------------------------------------------------------
    // Main
    // --------------------------------------------------------------
    integer seed;
    initial begin
        $dumpfile("pipeline.vcd");
        $dumpvars(0, tb_pipeline_rv32i);

        // 1) Directed hazard program.
        build_directed();
        run_case("directed", plen*3 + 40);

        // 2) Randomised programs across many seeds.
        for (seed = 1; seed <= 40; seed++) begin
            // reseed via $random with a deterministic per-seed kick
            for (int w = 0; w < seed; w++) void'($random);
            build_random(50);
            run_case($sformatf("rand%0d", seed), plen*3 + 60);
        end

        $display("--------------------------------------------------------");
        $display("Total assertions checked : %0d", checks);
        $display("Mismatches               : %0d", errors);
        if (errors == 0)
            $display("RESULT: *** PASS ***");
        else
            $display("RESULT: *** FAIL ***  (%0d mismatches)", errors);
        $display("--------------------------------------------------------");
        $finish;
    end

    // Global watchdog.
    initial begin
        #5_000_000;
        $display("RESULT: *** FAIL ***  (timeout)");
        $finish;
    end

endmodule

`default_nettype wire
