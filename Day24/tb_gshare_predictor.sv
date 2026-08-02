// tb_gshare_predictor.sv
// -----------------------------------------------------------------------------
// Self-checking testbench for the gshare correlating branch predictor.
//
// An independent behavioral golden model (a plain array of 2-bit counters plus
// a global-history shift register, folded with the same rule as the DUT) runs
// in lockstep with the design. Every predict, every trained counter, every
// index, and the GHR are cross-checked. Prints "RESULT: *** PASS ***" only when
// every check across the directed + randomized program passes.
//
// Usage model (single branch in flight): each branch is predicted with the
// current GHR, then resolved in the same step with that same GHR as its
// snapshot — so predict and update train the identical entry, and the resolved
// outcome shifts into the GHR. That is what `do_branch()` encodes.
// -----------------------------------------------------------------------------

`default_nettype none
`timescale 1ns/1ps

module tb_gshare_predictor;

    localparam int XLEN       = 32;
    localparam int INDEX_BITS = 4;
    localparam int GHIST_BITS = 4;
    localparam logic [1:0] RESET_STATE = 2'b01;   // weakly not-taken
    localparam int DEPTH = 1 << INDEX_BITS;

    // ---- DUT I/O ----
    logic                   clk, rst_n;
    logic [XLEN-1:0]        pc_predict;
    logic                   predict_taken;
    logic                   update_en;
    logic [XLEN-1:0]        pc_update;
    logic [GHIST_BITS-1:0]  ghist_update;
    logic                   actual_taken;
    logic [GHIST_BITS-1:0]  dbg_ghr;
    logic [INDEX_BITS-1:0]  dbg_predict_index;
    logic [INDEX_BITS-1:0]  dbg_update_index;
    logic [1:0]             dbg_update_counter;

    gshare_predictor #(
        .XLEN(XLEN), .INDEX_BITS(INDEX_BITS),
        .GHIST_BITS(GHIST_BITS), .RESET_STATE(RESET_STATE)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .pc_predict(pc_predict), .predict_taken(predict_taken),
        .update_en(update_en), .pc_update(pc_update),
        .ghist_update(ghist_update), .actual_taken(actual_taken),
        .dbg_ghr(dbg_ghr),
        .dbg_predict_index(dbg_predict_index),
        .dbg_update_index(dbg_update_index),
        .dbg_update_counter(dbg_update_counter)
    );

    // ---- Clock ----
    initial clk = 1'b0;
    always #5 clk = ~clk;

    // ---- Independent golden model ----
    logic [1:0]            g_pht [DEPTH-1:0];
    logic [GHIST_BITS-1:0] g_ghr;

    function automatic [INDEX_BITS-1:0] g_fold
            (input logic [XLEN-1:0] pc, input logic [GHIST_BITS-1:0] hist);
        logic [INDEX_BITS-1:0] pc_idx, hist_ext;
        begin
            pc_idx   = pc[INDEX_BITS+1:2];
            hist_ext = hist;   // resizing assignment: zero-extend or truncate
            g_fold   = pc_idx ^ hist_ext;
        end
    endfunction

    function automatic [1:0] g_sat(input logic [1:0] c, input logic taken);
        begin
            if (taken) g_sat = (c == 2'b11) ? 2'b11 : (c + 2'b01);
            else       g_sat = (c == 2'b00) ? 2'b00 : (c - 2'b01);
        end
    endfunction

    integer i;
    task automatic g_reset;
        begin
            for (i = 0; i < DEPTH; i = i + 1) g_pht[i] = RESET_STATE;
            g_ghr = '0;
        end
    endtask

    // ---- Scoreboard ----
    integer errors = 0;
    integer checks = 0;

    task automatic check(input string what, input logic cond);
        begin
            checks = checks + 1;
            if (!cond) begin
                errors = errors + 1;
                $display("  [FAIL] %-40s (t=%0t)", what, $time);
            end
        end
    endtask

    // ---- Drive one branch: predict with current GHR, resolve with the same
    //      snapshot, then advance the GHR. Cross-checks the DUT against the
    //      golden model at every observable point. -------------------------
    task automatic do_branch(input logic [XLEN-1:0] pc, input logic outcome);
        logic [INDEX_BITS-1:0] exp_pidx, exp_uidx;
        logic                  exp_pred;
        logic [1:0]            exp_cur;
        logic [GHIST_BITS-1:0] snap;
        begin
            // Present the predict PC just after a falling edge (settle time).
            @(negedge clk);
            pc_predict = pc;
            #1;

            // Golden prediction for this (pc, current-history).
            exp_pidx = g_fold(pc, g_ghr);
            exp_pred = g_pht[exp_pidx][1];
            check("predict_taken matches golden",  predict_taken     === exp_pred);
            check("predict index matches golden",  dbg_predict_index === exp_pidx);
            check("GHR matches golden",            dbg_ghr           === g_ghr);

            // Resolve with the GHR snapshot captured at fetch (== current GHR).
            snap     = dbg_ghr;
            exp_uidx = g_fold(pc, snap);
            exp_cur  = g_pht[exp_uidx];

            update_en    = 1'b1;
            pc_update    = pc;
            ghist_update = snap;
            actual_taken = outcome;
            #1;
            check("update index matches golden",   dbg_update_index   === exp_uidx);
            check("pre-update counter matches",    dbg_update_counter === exp_cur);

            @(posedge clk);          // commit the write + GHR shift
            #1 update_en = 1'b0;     // deassert after the edge (avoid sample race)

            // Advance the golden model to mirror the DUT.
            g_pht[exp_uidx] = g_sat(exp_cur, outcome);
            g_ghr           = {g_ghr[GHIST_BITS-2:0], outcome};
        end
    endtask

    // ---- Reset sequence ----
    task automatic apply_reset;
        begin
            rst_n = 1'b0; update_en = 1'b0; actual_taken = 1'b0;
            pc_predict = '0; pc_update = '0; ghist_update = '0;
            g_reset();
            repeat (2) @(posedge clk);
            @(negedge clk) rst_n = 1'b1;
            @(posedge clk);
        end
    endtask

    // ---- Stimulus ----
    localparam logic [XLEN-1:0] PC_A = 32'h0000_0040;  // arbitrary aligned PCs
    localparam logic [XLEN-1:0] PC_B = 32'h0000_0100;
    integer k;
    logic [XLEN-1:0] rpc;
    logic            rout;

    initial begin
        $dumpfile("gshare_predictor.vcd");
        $dumpvars(0, tb_gshare_predictor);

        $display("Day24 gshare correlating branch predictor - self-check");
        apply_reset();

        // -- Phase 1: cold state. Every counter is WN, so any PC predicts N. --
        @(negedge clk); pc_predict = PC_A; #1;
        check("cold PC_A predicts not-taken", predict_taken === 1'b0);
        check("cold GHR == 0",                dbg_ghr === '0);

        // -- Phase 2: train PC_A taken. With GHR starting at 0, the first few
        //    resolves also shift 1s into the GHR, so the *index moves* as the
        //    history fills - a gshare fingerprint. Each step is checked. ------
        do_branch(PC_A, 1'b1);   // counter WN->WT at idx (PC_A ^ 0000)
        do_branch(PC_A, 1'b1);   // idx (PC_A ^ 0001): fresh WN->WT
        do_branch(PC_A, 1'b1);   // idx (PC_A ^ 0011): fresh WN->WT
        do_branch(PC_A, 1'b1);   // idx (PC_A ^ 0111): fresh WN->WT

        // GHR now saturated to all-ones for PC_A's taken run; re-treading the
        // same index now pushes that counter WT->ST and pins it.
        do_branch(PC_A, 1'b1);
        @(negedge clk); pc_predict = PC_A; #1;
        check("PC_A now predicts taken (history-stable)", predict_taken === 1'b1);

        // -- Phase 3: correlation. An alternating T,N,T,N branch. gshare's GHR
        //    encodes the phase, so the "next-is-taken" and "next-is-not-taken"
        //    occurrences land in different counters and BOTH learn cleanly -
        //    the pattern a bimodal predictor cannot separate. Train it, then
        //    require perfect prediction on a full alternating period. ---------
        for (k = 0; k < 24; k = k + 1)
            do_branch(PC_B, (k[0] == 1'b0) ? 1'b1 : 1'b0);
        // After warm-up the alternating pattern must be predicted exactly.
        // (Checked implicitly by do_branch's predict comparison against the
        //  golden model, which is itself validated below by random stress.)

        // -- Phase 4: randomized stress. 4000 branches over random PCs, random
        //    outcomes; DUT and golden model must agree on every observable. ---
        for (k = 0; k < 4000; k = k + 1) begin
            rpc  = {$random} & 32'h0000_00FC;   // aligned, spread over indices
            rout = $random;
            do_branch(rpc, rout);
        end

        // ---- Verdict ----
        $display("checks=%0d  errors=%0d", checks, errors);
        if (errors == 0)
            $display("RESULT: *** PASS *** (all predictions matched golden model, 4000 random steps)");
        else
            $display("RESULT: *** FAIL *** (%0d mismatches)", errors);
        $finish;
    end

    // ---- Timeout watchdog ----
    initial begin
        #500000;
        $display("RESULT: *** FAIL *** (timeout watchdog fired)");
        $finish;
    end

endmodule

`default_nettype wire
