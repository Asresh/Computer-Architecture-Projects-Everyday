// tb_branch_predictor.sv - Day6
//
// Self-checking testbench for the bimodal 2-bit saturating-counter branch
// predictor. An independent behavioral golden model (a plain array of 2-bit
// counters updated with the textbook saturating rule) shadows the DUT. Every
// prediction the DUT makes is compared against the golden model, and after
// every training step the DUT's counter (observed through dbg_update_counter
// on the following prediction) is checked too.
//
// Stimulus:
//   * Directed phase 1 - train ONE branch through the full FSM: WN -> WT ->
//     ST across repeated taken outcomes, then feed a single not-taken and
//     confirm the 2-bit hysteresis keeps the prediction "taken" (the classic
//     loop-exit case), then confirm a second not-taken finally flips it.
//   * Directed phase 2 - two branches at different indices trained in
//     opposite directions, proving per-PC independence (no aliasing within
//     the addressed set).
//   * Randomized phase - thousands of (pc, outcome) pairs; the golden model
//     and DUT must agree on every prediction.
//
// Prints "RESULT: *** PASS ***" only if every check passed. Has a global
// timeout watchdog and dumps branch_predictor.vcd.

`timescale 1ns/1ps

module tb_branch_predictor;

    localparam int XLEN        = 32;
    localparam int INDEX_BITS  = 4;
    localparam logic [1:0] RST = 2'b01;
    localparam int NUM_ENTRIES = 1 << INDEX_BITS;

    logic                  clk;
    logic                  rst_n;
    logic [XLEN-1:0]       pc_predict;
    logic                  predict_taken;
    logic                  update_en;
    logic [XLEN-1:0]       pc_update;
    logic                  actual_taken;
    logic [INDEX_BITS-1:0] dbg_predict_index;
    logic [INDEX_BITS-1:0] dbg_update_index;
    logic [1:0]            dbg_update_counter;

    branch_predictor #(
        .XLEN(XLEN), .INDEX_BITS(INDEX_BITS), .RESET_STATE(RST)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .pc_predict(pc_predict), .predict_taken(predict_taken),
        .update_en(update_en), .pc_update(pc_update),
        .actual_taken(actual_taken),
        .dbg_predict_index(dbg_predict_index),
        .dbg_update_index(dbg_update_index),
        .dbg_update_counter(dbg_update_counter)
    );

    // ---- Clock ----
    initial clk = 1'b0;
    always #5 clk = ~clk;

    // ---- Golden reference model ----
    logic [1:0] gold [NUM_ENTRIES-1:0];
    int errors;

    function automatic logic [INDEX_BITS-1:0] idx_of(input logic [XLEN-1:0] pc);
        return pc[INDEX_BITS+1 : 2];
    endfunction

    function automatic logic gold_predict(input logic [XLEN-1:0] pc);
        return gold[idx_of(pc)][1];
    endfunction

    // Saturating update of the golden counter.
    task automatic gold_update(input logic [XLEN-1:0] pc, input logic taken);
        logic [INDEX_BITS-1:0] k;
        k = idx_of(pc);
        if (taken) begin
            if (gold[k] != 2'b11) gold[k] = gold[k] + 2'b01;
        end else begin
            if (gold[k] != 2'b00) gold[k] = gold[k] - 2'b01;
        end
    endtask

    // ---- Checks ----
    // Compare the DUT prediction for `pc` against the golden model.
    task automatic check_predict(input logic [XLEN-1:0] pc,
                                  input string tag);
        logic exp;
        pc_predict = pc;
        #1; // let the combinational prediction settle
        exp = gold_predict(pc);
        if (predict_taken !== exp) begin
            errors = errors + 1;
            $display("[%0t] FAIL %s: pc=%08x idx=%0d predict=%b exp=%b (gold ctr=%02b)",
                     $time, tag, pc, idx_of(pc), predict_taken, exp, gold[idx_of(pc)]);
        end
    endtask

    // Drive one synchronous training step on the update port and advance the
    // golden model in lockstep. Also verifies the DUT exposed the expected
    // pre-update counter value on dbg_update_counter.
    task automatic train(input logic [XLEN-1:0] pc, input logic taken,
                         input string tag);
        logic [1:0] exp_ctr;
        exp_ctr    = gold[idx_of(pc)];
        pc_update    = pc;
        actual_taken = taken;
        update_en    = 1'b1;
        #1;
        if (dbg_update_index !== idx_of(pc)) begin
            errors = errors + 1;
            $display("[%0t] FAIL %s: update index=%0d exp=%0d",
                     $time, tag, dbg_update_index, idx_of(pc));
        end
        if (dbg_update_counter !== exp_ctr) begin
            errors = errors + 1;
            $display("[%0t] FAIL %s: pre-update ctr=%02b exp=%02b",
                     $time, tag, dbg_update_counter, exp_ctr);
        end
        @(posedge clk);           // commit the write
        #1;
        update_en = 1'b0;
        gold_update(pc, taken);   // keep the golden model in lockstep
    endtask

    // ---- Test program ----
    int    j;
    logic [XLEN-1:0] rpc;
    logic  rtk;
    localparam logic [XLEN-1:0] PC_A = 32'h0000_0040; // idx = (0x40>>2)&0xF = 0
    localparam logic [XLEN-1:0] PC_B = 32'h0000_0044; // idx = 1
    localparam logic [XLEN-1:0] PC_C = 32'h0000_0058; // idx = 6

    initial begin
        errors      = 0;
        update_en   = 1'b0;
        actual_taken= 1'b0;
        pc_predict  = '0;
        pc_update   = '0;
        rst_n       = 1'b0;
        for (j = 0; j < NUM_ENTRIES; j = j + 1) gold[j] = RST;

        repeat (2) @(posedge clk);
        #1 rst_n = 1'b1;
        @(posedge clk);

        // Cold state: every counter is weakly not-taken -> predict NOT taken.
        check_predict(PC_A, "cold-A");
        check_predict(PC_C, "cold-C");

        // -------- Directed phase 1: train PC_A up through the FSM --------
        // WN(01) --taken--> WT(10): now predicts taken.
        train(PC_A, 1'b1, "A t1");
        check_predict(PC_A, "A->WT");           // expect taken
        // WT(10) --taken--> ST(11): strongly taken.
        train(PC_A, 1'b1, "A t2");
        check_predict(PC_A, "A->ST");           // expect taken
        // A run of takens keeps it pinned at ST (saturation).
        train(PC_A, 1'b1, "A t3");
        train(PC_A, 1'b1, "A t4");
        check_predict(PC_A, "A sat");           // still taken

        // The hysteresis case: one surprising NOT-taken (loop exit).
        // ST(11) --not-taken--> WT(10): prediction STAYS taken.
        train(PC_A, 1'b0, "A miss1");
        check_predict(PC_A, "A hysteresis");    // expect STILL taken
        // A second not-taken finally flips it: WT(10) --nt--> WN(01) predict NT.
        train(PC_A, 1'b0, "A miss2");
        check_predict(PC_A, "A flipped");       // expect NOT taken

        // -------- Directed phase 2: independence across indices --------
        // Train PC_C strongly taken while PC_A is not-taken; they must not
        // interfere (different PHT indices).
        train(PC_C, 1'b1, "C t1");
        train(PC_C, 1'b1, "C t2");
        check_predict(PC_C, "C taken");         // taken
        check_predict(PC_A, "A still NT");      // unchanged, not taken

        // -------- Randomized phase --------
        for (j = 0; j < 4000; j = j + 1) begin
            rpc = {24'h0, $random} & 32'h0000_003C; // vary index bits only
            rtk = $random;
            check_predict(rpc, "rand-pred");
            train(rpc, rtk, "rand-train");
        end

        if (errors == 0)
            $display("RESULT: *** PASS *** (all predictions matched golden model, %0d random steps)", j);
        else
            $display("RESULT: *** FAIL *** (%0d mismatches)", errors);
        $finish;
    end

    // ---- Waveform dump ----
    initial begin
        $dumpfile("branch_predictor.vcd");
        $dumpvars(0, tb_branch_predictor);
    end

    // ---- Timeout watchdog ----
    initial begin
        #500000;
        $display("RESULT: *** FAIL *** (timeout)");
        $finish;
    end

endmodule
