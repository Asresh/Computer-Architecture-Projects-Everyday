// -----------------------------------------------------------------------------
// tb_core.sv - Self-checking testbench for the single-cycle RV32I core
//
// Strategy:
//   * The core runs the directed program preloaded in imem.sv. That program
//     was assembled and executed by an independent Python ISS (not the DUT),
//     which produced the golden PC trace, the golden final register state, and
//     the golden data-memory contents embedded below.
//   * Per-instruction PC progression: after reset, the PC executing each cycle
//     is sampled at the negedge and compared to the golden trace (which walks
//     the arithmetic prologue, the 5-iteration sum loop, the six branch forms,
//     and the jal/jalr call before spinning at the halt).
//   * Final architectural state: after the program reaches its halt spin, all
//     32 registers (x0 pinned to 0) and the touched data-memory words are
//     compared to the golden values via hierarchical references into the DUT.
//   * A watchdog timeout guards a hung simulation.
//   * A VCD waveform is dumped for inspection / rendering.
//
// On success the TB prints exactly:  RESULT: *** PASS ***
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps
`default_nettype none

module tb_core;

    localparam int unsigned NTR  = 61;   // meaningful PC-trace length
    localparam int unsigned NRUN = 66;   // cycles to run (trace + halt spin)

    logic        clk = 1'b0;
    logic        rst_n;
    wire [31:0]  dbg_pc, dbg_instr, dbg_result;
    wire         dbg_reg_write;
    wire [4:0]   dbg_rd;

    always #5 clk = ~clk;

    integer errors = 0;
    integer checks = 0;

    core dut (
        .clk           (clk),
        .rst_n         (rst_n),
        .dbg_pc        (dbg_pc),
        .dbg_instr     (dbg_instr),
        .dbg_reg_write (dbg_reg_write),
        .dbg_rd        (dbg_rd),
        .dbg_result    (dbg_result)
    );

    // ------------------------------------------------------------------
    // Golden PC trace (byte addresses), from the independent ISS.
    // ------------------------------------------------------------------
    logic [31:0] exp_pc [0:NTR-1];
    // Golden final register file (x0..x31), from the independent ISS.
    logic [31:0] exp_reg [0:31];

    task automatic load_golden();
        integer j;
        // prologue: sequential 0x00..0x84
        for (j = 0; j < 34; j = j + 1) exp_pc[j] = j * 4;          // 0x00..0x84
        // sum loop body (0x88,0x8C,0x90) x5 iterations
        exp_pc[34]=32'h88; exp_pc[35]=32'h8C; exp_pc[36]=32'h90;
        exp_pc[37]=32'h88; exp_pc[38]=32'h8C; exp_pc[39]=32'h90;
        exp_pc[40]=32'h88; exp_pc[41]=32'h8C; exp_pc[42]=32'h90;
        exp_pc[43]=32'h88; exp_pc[44]=32'h8C; exp_pc[45]=32'h90;
        exp_pc[46]=32'h88; exp_pc[47]=32'h8C; exp_pc[48]=32'h90;
        // branch chain (each taken skips its poison addi), then jal/jalr
        exp_pc[49]=32'h94; exp_pc[50]=32'h9C; exp_pc[51]=32'hA0;
        exp_pc[52]=32'hA4; exp_pc[53]=32'hAC; exp_pc[54]=32'hB4;
        exp_pc[55]=32'hBC; exp_pc[56]=32'hC8; exp_pc[57]=32'hCC;
        exp_pc[58]=32'hC0; exp_pc[59]=32'hC4; exp_pc[60]=32'hC4;

        exp_reg[0]=32'h00000000; exp_reg[1]=32'h12345678;
        exp_reg[2]=32'h00010008; exp_reg[3]=32'h00000064;
        exp_reg[4]=32'hFFFFFFCE; exp_reg[5]=32'h000000C0;
        exp_reg[6]=32'h0000002A; exp_reg[7]=32'h00000060;
        exp_reg[8]=32'hFFFFFFEE; exp_reg[9]=32'hFFFFFFAA;
        exp_reg[10]=32'h00000064; exp_reg[11]=32'h12345678;
        exp_reg[12]=32'hFFFFFFCE; exp_reg[13]=32'h00000001;
        exp_reg[14]=32'h00000000; exp_reg[15]=32'h00000001;
        exp_reg[16]=32'h00000001; exp_reg[17]=32'hFFFFFF9B;
        exp_reg[18]=32'h000000F4; exp_reg[19]=32'h00000678;
        exp_reg[20]=32'h00000C80; exp_reg[21]=32'h00012345;
        exp_reg[22]=32'hFFFFFFF3; exp_reg[23]=32'h12345678;
        exp_reg[24]=32'h00000078; exp_reg[25]=32'h00000012;
        exp_reg[26]=32'h00000064; exp_reg[27]=32'h000000CE;
        exp_reg[28]=32'h0000000F; exp_reg[29]=32'h00000006;
        exp_reg[30]=32'h00000006; exp_reg[31]=32'h00000007;
    endtask

    integer k, r;
    logic [31:0] exp;

    initial begin
        $dumpfile("core.vcd");
        $dumpvars(0, tb_core);

        load_golden();

        // ---------------- Reset ----------------
        // Hold reset low across a rising edge (clears PC/regs/memory), then
        // deassert OFF the clock edge to avoid a reset-release race.
        rst_n = 1'b0;
        @(negedge clk);          // a posedge with rst_n=0 has already set pc<=0
        rst_n = 1'b1;            // deassert at the negedge (off-edge)

        // ---------------- Per-instruction PC progression ----------------
        // pc now holds 0 (the first instruction). Each iteration samples the
        // PC executing this cycle, then a rising edge advances to the next.
        for (k = 0; k < NRUN; k = k + 1) begin
            #1;                  // settle after the (neg)edge
            exp = (k < NTR) ? exp_pc[k] : 32'h0000_00C4;   // after halt: spin
            checks = checks + 1;
            if (dbg_pc !== exp) begin
                errors = errors + 1;
                $display("[FAIL] cycle %0d PC got=%h exp=%h (instr=%h)",
                         k, dbg_pc, exp, dbg_instr);
            end
            @(negedge clk);      // next cycle's stable point (posedge advanced pc)
        end

        // ---------------- Final register file ----------------
        for (r = 0; r < 32; r = r + 1) begin
            checks = checks + 1;
            if (dut.u_rf.regs[r] !== exp_reg[r]) begin
                errors = errors + 1;
                $display("[FAIL] final x%0d got=%h exp=%h",
                         r, dut.u_rf.regs[r], exp_reg[r]);
            end
        end

        // ---------------- Final data memory (touched words + zeros) --------
        check_mem(0,  32'h12345678);   // sw x1,0(x0)
        check_mem(1,  32'h00000000);   // untouched
        check_mem(2,  32'h00000064);   // sh x3,8(x0)   -> low half = 100
        check_mem(3,  32'h0000CE00);   // sb x4,13(x0)  -> byte lane 1 = 0xCE
        check_mem(4,  32'h0000000F);   // sw x28,16(x0) -> sum = 15
        check_mem(5,  32'h00000000);   // untouched

        // ---------------- Verdict ----------------
        if (errors == 0)
            $display("RESULT: *** PASS *** (%0d checks)", checks);
        else
            $display("RESULT: *** FAIL *** (%0d errors / %0d checks)",
                     errors, checks);
        $finish;
    end

    task automatic check_mem(input integer widx, input [31:0] expv);
        checks = checks + 1;
        if (dut.u_lsu.mem[widx] !== expv) begin
            errors = errors + 1;
            $display("[FAIL] final mem word %0d got=%h exp=%h",
                     widx, dut.u_lsu.mem[widx], expv);
        end
    endtask

    // Watchdog timeout.
    initial begin
        #5_000_000;
        $display("RESULT: *** FAIL *** (timeout)");
        $finish;
    end

endmodule

`default_nettype wire
