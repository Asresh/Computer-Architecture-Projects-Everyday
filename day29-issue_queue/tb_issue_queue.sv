// -----------------------------------------------------------------------------
// Day29 - Self-checking testbench for the Out-of-Order Issue Queue.
// -----------------------------------------------------------------------------
// Lock-steps issue_queue against an INDEPENDENT behavioural golden model held
// entirely in the testbench. The model does NOT use an age matrix: it stamps
// every allocated entry with a monotonically increasing dispatch SEQUENCE
// NUMBER and selects the ready entry with the smallest sequence number. So the
// RTL's O(1) matrix arbitration is checked against a plain "minimum age"
// definition of oldest-first - two genuinely different implementations of the
// same specification.
//
// Every cycle the testbench:
//   1. drives one dispatch attempt, both wakeup buses, issue_ready and flush,
//   2. samples the DUT's combinational outputs at the settled pre-edge instant,
//   3. compares disp_ready / issue_valid / issue_idx / payload / occupancy /
//      per-entry request vector / per-entry valid vector against the model,
//   4. asserts the grant vector is one-hot whenever issue_valid is high,
//   5. advances the DUT (rising edge) and the model identically.
//
// The DUT instance is a COMPACT demo configuration (ENTRIES=6, TAGW=5, two
// wakeup buses) so the directed Phase-1 scenario - allocate, in-order issue,
// same-cycle wakeup->select, out-of-order issue past a stalled older entry,
// oldest-first arbitration between two simultaneously-woken entries, dual-bus
// wakeup, FU backpressure, fill-to-full, and flush - fits in one renderable
// 16-cycle window. Phase 2 then pounds it with 5000 randomised cycles.
//
//   RESULT: *** PASS ***   is printed only if every assertion held.
// -----------------------------------------------------------------------------

`timescale 1ns / 1ps

module tb_issue_queue;

    // ---- Compact demo configuration ----
    localparam int ENTRIES = 6;
    localparam int TAGW    = 5;
    localparam int OPW     = 8;
    localparam int NWAKE   = 2;
    localparam int IDXW    = $clog2(ENTRIES);       // 3
    localparam int CNTW    = $clog2(ENTRIES + 1);   // 3

    // ---- DUT I/O ----
    logic                  clk, rst_n;
    logic                  disp_valid, disp_ready;
    logic [OPW-1:0]        disp_op;
    logic [TAGW-1:0]       disp_pdst;
    logic                  disp_pdst_valid;
    logic [TAGW-1:0]       disp_psrc1, disp_psrc2;
    logic                  disp_src1_ready, disp_src2_ready;
    logic [NWAKE-1:0]      wake_valid;
    logic [NWAKE*TAGW-1:0] wake_tag;
    logic                  issue_valid, issue_ready;
    logic [OPW-1:0]        issue_op;
    logic [TAGW-1:0]       issue_pdst;
    logic                  issue_pdst_valid;
    logic [IDXW-1:0]       issue_idx;
    logic                  flush;
    logic [CNTW-1:0]       dbg_count;
    logic [ENTRIES-1:0]    dbg_valid, dbg_ready1, dbg_ready2, dbg_req;

    // Individually named wakeup-bus signals (nicer in the VCD / waveform).
    logic                  w0v, w1v;
    logic [TAGW-1:0]       w0t, w1t;
    assign wake_valid = {w1v, w0v};
    assign wake_tag   = {w1t, w0t};

    issue_queue #(
        .ENTRIES(ENTRIES), .TAGW(TAGW), .OPW(OPW), .NWAKE(NWAKE)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .disp_valid(disp_valid), .disp_ready(disp_ready),
        .disp_op(disp_op), .disp_pdst(disp_pdst),
        .disp_pdst_valid(disp_pdst_valid),
        .disp_psrc1(disp_psrc1), .disp_src1_ready(disp_src1_ready),
        .disp_psrc2(disp_psrc2), .disp_src2_ready(disp_src2_ready),
        .wake_valid(wake_valid), .wake_tag(wake_tag),
        .issue_valid(issue_valid), .issue_ready(issue_ready),
        .issue_op(issue_op), .issue_pdst(issue_pdst),
        .issue_pdst_valid(issue_pdst_valid), .issue_idx(issue_idx),
        .flush(flush),
        .dbg_count(dbg_count), .dbg_valid(dbg_valid),
        .dbg_ready1(dbg_ready1), .dbg_ready2(dbg_ready2), .dbg_req(dbg_req)
    );

    // ---- Clock : 10 ns period ----
    initial clk = 1'b0;
    always #5 clk = ~clk;

    // -------------------------------------------------------------------------
    // Independent golden model  (sequence-number "oldest ready" scheduler)
    // -------------------------------------------------------------------------
    integer g_vld [0:ENTRIES-1];
    integer g_r1  [0:ENTRIES-1];
    integer g_r2  [0:ENTRIES-1];
    integer g_s1  [0:ENTRIES-1];
    integer g_s2  [0:ENTRIES-1];
    integer g_dst [0:ENTRIES-1];
    integer g_pdv [0:ENTRIES-1];
    integer g_op  [0:ENTRIES-1];
    integer g_seq [0:ENTRIES-1];
    integer seq_ctr;

    // Expected (combinational) values for the current cycle.
    integer e_disp_ready, e_alloc_ok, e_alloc_idx;
    integer e_count, e_reqmask, e_vldmask;
    integer e_issue_valid, e_sel;
    integer e_issue_idx, e_issue_op, e_issue_pdst, e_issue_pdv;
    integer e_h1 [0:ENTRIES-1];
    integer e_h2 [0:ENTRIES-1];

    integer checks, errors, cyc;

    function automatic integer wake_hit(input integer t);
        begin
            wake_hit = 0;
            if (w0v && (w0t == t[TAGW-1:0])) wake_hit = 1;
            if (w1v && (w1t == t[TAGW-1:0])) wake_hit = 1;
        end
    endfunction

    task automatic golden_eval;
        integer i;
        begin
            e_count = 0; e_reqmask = 0; e_vldmask = 0;
            e_alloc_ok = 0; e_alloc_idx = 0;

            for (i = 0; i < ENTRIES; i = i + 1) begin
                if (g_vld[i]) begin
                    e_count   = e_count + 1;
                    e_vldmask = e_vldmask | (1 << i);
                end
            end
            // lowest free entry
            for (i = ENTRIES - 1; i >= 0; i = i - 1) begin
                if (!g_vld[i]) begin e_alloc_ok = 1; e_alloc_idx = i; end
            end
            e_disp_ready = e_alloc_ok;

            for (i = 0; i < ENTRIES; i = i + 1) begin
                e_h1[i] = (g_r1[i] || wake_hit(g_s1[i])) ? 1 : 0;
                e_h2[i] = (g_r2[i] || wake_hit(g_s2[i])) ? 1 : 0;
                if (g_vld[i] && e_h1[i] && e_h2[i]) e_reqmask = e_reqmask | (1 << i);
            end

            e_issue_valid = (e_reqmask != 0) ? 1 : 0;
            e_sel = -1;
            for (i = 0; i < ENTRIES; i = i + 1) begin
                if (((e_reqmask >> i) & 1) &&
                    ((e_sel < 0) || (g_seq[i] < g_seq[e_sel]))) e_sel = i;
            end

            if (e_sel < 0) begin
                e_issue_idx = 0; e_issue_op = 0; e_issue_pdst = 0; e_issue_pdv = 0;
            end else begin
                e_issue_idx  = e_sel;
                e_issue_op   = g_op[e_sel];
                e_issue_pdst = g_dst[e_sel];
                e_issue_pdv  = g_pdv[e_sel];
            end
        end
    endtask

    task automatic golden_update;
        integer i, a;
        begin
            if (flush) begin
                for (i = 0; i < ENTRIES; i = i + 1) g_vld[i] = 0;
            end else begin
                if (e_issue_valid && issue_ready) g_vld[e_sel] = 0;
                for (i = 0; i < ENTRIES; i = i + 1) begin
                    g_r1[i] = e_h1[i];
                    g_r2[i] = e_h2[i];
                end
                if (disp_valid && e_alloc_ok) begin
                    a = e_alloc_idx;
                    g_vld[a] = 1;
                    g_op [a] = disp_op;
                    g_dst[a] = disp_pdst;
                    g_pdv[a] = disp_pdst_valid;
                    g_s1 [a] = disp_psrc1;
                    g_s2 [a] = disp_psrc2;
                    g_r1 [a] = (disp_src1_ready || wake_hit(disp_psrc1)) ? 1 : 0;
                    g_r2 [a] = (disp_src2_ready || wake_hit(disp_psrc2)) ? 1 : 0;
                    g_seq[a] = seq_ctr;
                    seq_ctr  = seq_ctr + 1;
                end
            end
        end
    endtask

    task automatic chk(input string what, input integer got, input integer exp);
        begin
            checks = checks + 1;
            if (got !== exp) begin
                errors = errors + 1;
                $display("  [FAIL] cyc=%0d %s got=%0d exp=%0d", cyc, what, got, exp);
            end
        end
    endtask

    task automatic check_outputs;
        integer i, ones;
        begin
            chk("disp_ready",  disp_ready,  e_disp_ready);
            chk("issue_valid", issue_valid, e_issue_valid);
            chk("dbg_count",   dbg_count,   e_count);
            chk("dbg_req",     dbg_req,     e_reqmask);
            chk("dbg_valid",   dbg_valid,   e_vldmask);
            chk("issue_idx",   issue_idx,   e_issue_idx);
            chk("issue_op",    issue_op,    e_issue_op);
            chk("issue_pdst",  issue_pdst,  e_issue_pdst);
            chk("issue_pdstv", issue_pdst_valid, e_issue_pdv);

            // the age matrix must always produce a one-hot grant
            ones = 0;
            for (i = 0; i < ENTRIES; i = i + 1) if (dut.grant[i]) ones = ones + 1;
            chk("grant_onehot", ones, e_issue_valid);
        end
    endtask

    // -------------------------------------------------------------------------
    // Stimulus helpers
    // -------------------------------------------------------------------------
    task automatic idle_inputs;
        begin
            disp_valid = 1'b0; disp_op = '0; disp_pdst = '0; disp_pdst_valid = 1'b0;
            disp_psrc1 = '0; disp_src1_ready = 1'b1;
            disp_psrc2 = '0; disp_src2_ready = 1'b1;
            w0v = 1'b0; w0t = '0; w1v = 1'b0; w1t = '0;
            issue_ready = 1'b1; flush = 1'b0;
        end
    endtask

    task automatic drv(input integer dv,   input integer op,  input integer pd,
                       input integer pdvv, input integer s1,  input integer r1i,
                       input integer s2,   input integer r2i, input integer ir,
                       input integer a0v,  input integer a0t, input integer a1v,
                       input integer a1t,  input integer fl);
        begin
            disp_valid      = dv[0];
            disp_op         = op[OPW-1:0];
            disp_pdst       = pd[TAGW-1:0];
            disp_pdst_valid = pdvv[0];
            disp_psrc1      = s1[TAGW-1:0];
            disp_src1_ready = r1i[0];
            disp_psrc2      = s2[TAGW-1:0];
            disp_src2_ready = r2i[0];
            issue_ready     = ir[0];
            w0v             = a0v[0];
            w0t             = a0t[TAGW-1:0];
            w1v             = a1v[0];
            w1t             = a1t[TAGW-1:0];
            flush           = fl[0];
        end
    endtask

    integer trace_on;

    // One cycle: inputs are already driven and we are sitting at a negedge.
    task automatic step;
        begin
            #4;                       // settle: sample 1 ns before the rising edge
            golden_eval();
            check_outputs();
            if (trace_on) begin
                $display("  c%0d disp=%0d/%0d op=%02h | wake=%0d:%0d %0d:%0d | req=%b | iss=%0d rdy=%0d idx=%0d op=%02h | cnt=%0d flush=%0d",
                         cyc, disp_valid, disp_ready, disp_op,
                         w0v, w0t, w1v, w1t, dbg_req,
                         issue_valid, issue_ready, issue_idx, issue_op,
                         dbg_count, flush);
            end
            golden_update();
            cyc = cyc + 1;
            @(posedge clk);           // DUT state advances here
            @(negedge clk);           // ready for the next drive
        end
    endtask

    // -------------------------------------------------------------------------
    // Random stimulus support
    // -------------------------------------------------------------------------
    localparam int TAGPOOL = 16;      // small tag pool -> frequent CAM hits
    integer seed;

    function automatic integer rnd_tag;
        begin
            rnd_tag = 1 + ({$random(seed)} % TAGPOOL);
        end
    endfunction

    function automatic integer rnd_pct(input integer pct);
        begin
            rnd_pct = (({$random(seed)} % 100) < pct) ? 1 : 0;
        end
    endfunction

    // -------------------------------------------------------------------------
    // Main
    // -------------------------------------------------------------------------
    integer k;

    initial begin
        $dumpfile("issue_queue.vcd");
        $dumpvars(0, tb_issue_queue);

        checks = 0; errors = 0; cyc = 0; seq_ctr = 0; seed = 32'h0DA9_0029;
        trace_on = 1;
        for (k = 0; k < ENTRIES; k = k + 1) begin
            g_vld[k] = 0; g_r1[k] = 0; g_r2[k] = 0; g_s1[k] = 0; g_s2[k] = 0;
            g_dst[k] = 0; g_pdv[k] = 0; g_op[k] = 0; g_seq[k] = 0;
        end

        idle_inputs();
        rst_n = 1'b0;
        repeat (3) @(negedge clk);    // t = 30 ns
        rst_n = 1'b1;
        @(negedge clk);               // t = 40 ns : first driven cycle

        $display("");
        $display("Day29 - Out-of-Order Issue Queue (ENTRIES=%0d, TAGW=%0d, NWAKE=%0d)",
                 ENTRIES, TAGW, NWAKE);
        $display("=====================================================================");
        $display("Phase 1 : directed scheduler life-cycle");
        $display("---------------------------------------------------------------------");

        //     dv  op    pdst pdv  s1  r1  s2  r2  ir  w0v w0t w1v w1t fl
        // c0  dispatch A (both operands ready)
        drv( 1, 'hA1,  8,  1,  1,  1,  2,  1,  1,  0,  0,  0,  0,  0); step();
        // c1  dispatch B (waits on p8 = A's result) ; A is the only ready entry -> issues
        drv( 1, 'hB2,  9,  1,  8,  0,  2,  1,  1,  0,  0,  0,  0,  0); step();
        // c2  dispatch C (waits on p9 and p8) ; nothing ready -> no issue
        drv( 1, 'hC3, 10,  1,  9,  0,  8,  0,  1,  0,  0,  0,  0,  0); step();
        // c3  broadcast p8 : B wakes AND is selected in the SAME cycle (back-to-back)
        drv( 1, 'hD4, 11,  1,  3,  1,  4,  1,  1,  1,  8,  0,  0,  0); step();
        // c4  dispatch E (waits on p11) ; C still stalled -> younger D issues out of order
        drv( 1, 'hE5, 12,  1, 11,  0,  4,  1,  1,  0,  0,  0,  0,  0); step();
        // c5  dual broadcast p9 + p11 : C and E both become ready -> OLDER C wins
        drv( 1, 'hF6, 13,  1, 20,  0, 21,  0,  1,  1,  9,  1, 11,  0); step();
        // c6  FU refuses (issue_ready = 0) : E is granted but not accepted -> stays
        drv( 1, 'h17, 14,  1, 22,  0,  4,  1,  0,  0,  0,  0,  0,  0); step();
        // c7  FU accepts again -> E issues now
        drv( 0, 'h00,  0,  0,  0,  1,  0,  1,  1,  0,  0,  0,  0,  0); step();
        // c8..c11  fill the queue with operand-starved instructions
        drv( 1, 'h18, 15,  1, 23,  0, 24,  0,  1,  0,  0,  0,  0,  0); step();
        drv( 1, 'h19, 16,  1, 23,  0, 24,  0,  1,  0,  0,  0,  0,  0); step();
        drv( 1, 'h1A, 17,  1, 23,  0, 24,  0,  1,  0,  0,  0,  0,  0); step();
        drv( 1, 'h1B, 18,  1, 23,  0, 24,  0,  1,  0,  0,  0,  0,  0); step();
        // c12  queue is FULL : disp_ready = 0, the offered instruction is refused
        drv( 1, 'h1C, 19,  1, 23,  0, 24,  0,  1,  0,  0,  0,  0,  0); step();
        // c13  flush (branch mispredict) : the whole queue is squashed in one cycle
        drv( 1, 'h1D, 20,  1,  1,  1,  2,  1,  1,  0,  0,  0,  0,  1); step();
        // c14  fresh dispatch after the flush
        drv( 1, 'h1E, 21,  1,  1,  1,  2,  1,  1,  0,  0,  0,  0,  0); step();
        // c15  it is the only entry and it is ready -> issues
        drv( 0, 'h00,  0,  0,  0,  1,  0,  1,  1,  0,  0,  0,  0,  0); step();

        idle_inputs();
        $display("  Phase 1 complete : %0d checks, %0d errors", checks, errors);

        // ---------------------------------------------------------------------
        $display("---------------------------------------------------------------------");
        $display("Phase 2 : 5000 randomised cycles (random dispatch / dual wakeup /");
        $display("          FU backpressure / occasional flush)");
        trace_on = 0;
        for (k = 0; k < 5000; k = k + 1) begin
            drv(rnd_pct(70),                 // dispatch offered
                {$random(seed)} % 256,       // op payload
                rnd_tag(),                   // pdst
                rnd_pct(90),                 // writes a register
                rnd_tag(), rnd_pct(45),      // src1 tag / already ready
                rnd_tag(), rnd_pct(45),      // src2 tag / already ready
                rnd_pct(80),                 // FU accepts
                rnd_pct(40), rnd_tag(),      // wakeup bus 0
                rnd_pct(40), rnd_tag(),      // wakeup bus 1
                (({$random(seed)} % 300) == 0) ? 1 : 0);   // rare flush
            step();
        end
        idle_inputs();

        // drain: no dispatch, wake everything, FU always accepts
        for (k = 0; k < 40; k = k + 1) begin
            drv(0, 0, 0, 0, 0, 1, 0, 1, 1, 1, rnd_tag(), 1, rnd_tag(), 0);
            step();
        end
        idle_inputs();
        repeat (2) @(negedge clk);

        $display("---------------------------------------------------------------------");
        $display("Total cycles : %0d", cyc);
        $display("Assertions   : %0d", checks);
        $display("Errors       : %0d", errors);
        if (errors == 0) $display("RESULT: *** PASS ***");
        else             $display("RESULT: *** FAIL ***");
        $display("");
        $finish;
    end

    // ---- Watchdog ----
    initial begin
        #2000000;
        $display("RESULT: *** FAIL *** (timeout)");
        $finish;
    end

endmodule
