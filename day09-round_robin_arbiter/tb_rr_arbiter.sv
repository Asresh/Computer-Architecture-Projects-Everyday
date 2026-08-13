// tb_rr_arbiter.sv - Day9
// Self-checking testbench for the round-robin (rotating-priority) arbiter.
//
// Strategy: an INDEPENDENT behavioural reference model re-implements the
// rotating-priority rule from scratch and tracks its own copy of the base
// pointer. Every cycle we compare the DUT's grant / grant_valid / grant_idx
// against the reference. Directed vectors exercise the corner cases (idle,
// single requester, full contention showing a fair rotation, pointer wrap); a
// long randomized phase then hammers the arbiter with pseudo-random request
// masks.
//
// A fairness monitor additionally asserts that, whenever a requester keeps its
// request continuously asserted, it is granted within N cycles (no starvation).
//
// Prints "RESULT: *** PASS ***" only if every check passes; dumps rr_arbiter.vcd.

`timescale 1ns/1ps

module tb_rr_arbiter;

    localparam int N    = 4;
    localparam int IDXW = (N > 1) ? $clog2(N) : 1;

    logic            clk;
    logic            rst_n;
    logic [N-1:0]    req;
    logic [N-1:0]    grant;
    logic            grant_valid;
    logic [IDXW-1:0] grant_idx;

    // DUT ---------------------------------------------------------------------
    rr_arbiter #(.N(N)) dut (
        .clk         (clk),
        .rst_n       (rst_n),
        .req         (req),
        .grant       (grant),
        .grant_valid (grant_valid),
        .grant_idx   (grant_idx)
    );

    // Clock: 10 ns period ------------------------------------------------------
    initial clk = 1'b0;
    always #5 clk = ~clk;

    // ---- Independent reference model ----------------------------------------
    // Mirrors the rotating-priority rule with its own pointer `ref_base`.
    int          ref_base;
    int          errors;
    int          checks;
    int          wait_cnt [N];   // per-lane held-request wait counter

    // Compute the reference grant for a given request mask and base pointer.
    task automatic ref_grant(input  logic [N-1:0] r,
                             input  int           b,
                             output logic         v,
                             output int           idx);
        v   = 1'b0;
        idx = b;
        for (int i = 0; i < N; i++) begin
            int j;
            j = b + i;
            if (j >= N) j = j - N;
            if (r[j] && !v) begin
                v   = 1'b1;
                idx = j;
            end
        end
    endtask

    // Check the DUT outputs against the reference for the CURRENT cycle, run the
    // fairness monitor, then advance the reference pointer exactly as the DUT
    // will on this edge.
    task automatic check_and_step(input logic [N-1:0] r);
        logic         exp_v;
        int           exp_idx;
        logic [N-1:0] exp_grant;

        ref_grant(r, ref_base, exp_v, exp_idx);
        exp_grant = exp_v ? (logic'(1) << exp_idx) : '0;

        checks++;
        if (grant_valid !== exp_v) begin
            errors++;
            $display("  [%0t] MISMATCH grant_valid: dut=%b exp=%b (req=%b base=%0d)",
                     $time, grant_valid, exp_v, r, ref_base);
        end
        if (grant !== exp_grant) begin
            errors++;
            $display("  [%0t] MISMATCH grant: dut=%b exp=%b (req=%b base=%0d)",
                     $time, grant, exp_grant, r, ref_base);
        end
        if (exp_v && (grant_idx !== exp_idx[IDXW-1:0])) begin
            errors++;
            $display("  [%0t] MISMATCH grant_idx: dut=%0d exp=%0d (req=%b base=%0d)",
                     $time, grant_idx, exp_idx, r, ref_base);
        end
        // Grant must always be one-hot-or-zero and a subset of req.
        if (exp_v && ((grant & (grant - 1'b1)) != '0)) begin
            errors++;
            $display("  [%0t] MISMATCH grant not one-hot: %b", $time, grant);
        end
        if ((grant & ~r) != '0) begin
            errors++;
            $display("  [%0t] MISMATCH granted an unrequested lane: grant=%b req=%b",
                     $time, grant, r);
        end

        // Fairness / no-starvation: a lane that requests but is not granted this
        // cycle has its wait counter bumped; the rotating scheme must serve it
        // within N cycles of continuous request.
        for (int k = 0; k < N; k++) begin
            if (r[k] && !grant[k]) begin
                wait_cnt[k]++;
                if (wait_cnt[k] > N) begin
                    errors++;
                    $display("  [%0t] STARVATION: lane %0d waited %0d cycles (req held)",
                             $time, k, wait_cnt[k]);
                end
            end else begin
                wait_cnt[k] = 0;
            end
        end

        // Advance the reference pointer for the upcoming clock edge.
        if (exp_v) ref_base = (exp_idx == N - 1) ? 0 : exp_idx + 1;
    endtask

    // Drive `req`, let the combinational grant settle, sample & check just
    // before the edge, then step the clock.
    task automatic drive_cycle(input logic [N-1:0] r);
        req = r;
        #1;                 // combinational grant settles after req change
        check_and_step(r);  // sample DUT + reference at this point
        @(posedge clk);     // clock edge updates both pointers
        #1;                 // settle after the edge
    endtask

    // ---- Stimulus -----------------------------------------------------------
    int unsigned rnd;
    initial begin
        $dumpfile("rr_arbiter.vcd");
        $dumpvars(0, tb_rr_arbiter);

        errors   = 0;
        checks   = 0;
        ref_base = 0;
        req      = '0;
        rst_n    = 1'b0;
        for (int k = 0; k < N; k++) wait_cnt[k] = 0;

        // Hold reset a couple of cycles.
        repeat (2) @(posedge clk);
        #1 rst_n = 1'b1;
        #1;

        $display("Day9 round-robin arbiter TB (N=%0d)", N);

        // --- Directed: idle (no requests) ---
        drive_cycle(4'b0000);
        drive_cycle(4'b0000);

        // --- Directed: single persistent requester (lane 2 only) ---
        repeat (3) drive_cycle(4'b0100);

        // --- Directed: FULL contention -> must rotate fairly ---
        // Holding all four requests high hands out grants in strict rotation,
        // demonstrating fairness (each lane served once per N cycles).
        for (int c = 0; c < 8; c++) drive_cycle(4'b1111);

        // --- Directed: two requesters, grants alternate as base rotates ---
        for (int c = 0; c < 6; c++) drive_cycle(4'b1010);

        // --- Directed: pointer-wrap check ---
        // Serve lane 3 (pointer wraps to 0), then request only lane 0.
        drive_cycle(4'b1000);
        drive_cycle(4'b0001);

        // --- Randomized phase (deterministic xorshift32 seed) ---
        rnd = 32'hC0FFEE99;
        for (int c = 0; c < 400; c++) begin
            rnd ^= rnd << 13;
            rnd ^= rnd >> 17;
            rnd ^= rnd << 5;
            drive_cycle(rnd[N-1:0]);
        end

        // --- Back to idle ---
        drive_cycle(4'b0000);

        // ---- Verdict --------------------------------------------------------
        $display("Checks run: %0d", checks);
        if (errors == 0)
            $display("RESULT: *** PASS *** (%0d checks, 0 mismatches)", checks);
        else
            $display("RESULT: *** FAIL *** (%0d mismatches)", errors);

        $finish;
    end

    // ---- Global timeout -----------------------------------------------------
    initial begin
        #200000;
        $display("RESULT: *** FAIL *** (timeout)");
        $finish;
    end

endmodule
