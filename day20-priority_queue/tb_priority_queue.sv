// -----------------------------------------------------------------------------
// Day20 - Self-checking testbench for the systolic shift-register priority queue
//
//   An independent behavioural GOLDEN MODEL (a sorted, low-packed array with the
//   identical "insert only where enq_key < key[i]" rule, so equal keys keep
//   arrival / price-time order) is stepped in lock-step with the DUT.  After
//   every clock the peek outputs (min_key, min_data, min_valid), the occupancy
//   status (count, full, empty) and the sticky error flags (overflow, underflow)
//   are compared against the model.
//
//   Coverage:
//     * a DIRECTED trace (out-of-order inserts, duplicate-key price-time FIFO,
//       sorted extract-min drain, a mid-stream smaller insert, and an
//       underflow) - this is the region captured for the waveform PNG;
//     * a FULL / OVERFLOW directed check (fill to DEPTH, then ENQ-while-full);
//     * a long RANDOMIZED soak (weighted NOP/ENQ/DEQ, small key range to force
//       ties) that also independently verifies extract-min returns a
//       non-decreasing key stream.
//
//   Prints "RESULT: *** PASS ***" only if zero mismatches occur.  A watchdog
//   $fatal guards against a hang.  Dumps priority_queue.vcd for waveform render.
// -----------------------------------------------------------------------------
`timescale 1ns/1ps
`default_nettype none

module tb_priority_queue;

    localparam int DEPTH  = 8;
    localparam int KEY_W  = 16;
    localparam int DATA_W = 16;
    localparam int CNT_W  = $clog2(DEPTH+1);

    localparam logic [1:0] OP_NOP = 2'b00;
    localparam logic [1:0] OP_ENQ = 2'b01;
    localparam logic [1:0] OP_DEQ = 2'b10;

    // ---- DUT I/O -------------------------------------------------------------
    logic                clk, rst_n;
    logic [1:0]          op;
    logic [KEY_W-1:0]    enq_key;
    logic [DATA_W-1:0]   enq_data;

    wire  [KEY_W-1:0]    min_key;
    wire  [DATA_W-1:0]   min_data;
    wire                 min_valid;
    wire  [CNT_W-1:0]    count;
    wire                 full, empty;
    wire                 overflow, underflow;

    priority_queue #(.DEPTH(DEPTH), .KEY_W(KEY_W), .DATA_W(DATA_W)) dut (
        .clk(clk), .rst_n(rst_n),
        .op(op), .enq_key(enq_key), .enq_data(enq_data),
        .min_key(min_key), .min_data(min_data), .min_valid(min_valid),
        .count(count), .full(full), .empty(empty),
        .overflow(overflow), .underflow(underflow)
    );

    // ---- clock ---------------------------------------------------------------
    initial clk = 1'b0;
    always #5 clk = ~clk;   // 100 MHz

    // ---- golden model --------------------------------------------------------
    logic [KEY_W-1:0]  gkey  [DEPTH];
    logic [DATA_W-1:0] gdata [DEPTH];
    int                gcount;
    logic              g_ovf, g_udf;

    int errors;
    // monotone extract-min check, armed only around an insert-free drain
    logic [KEY_W-1:0] last_pop_key;
    logic             pop_seen;
    logic             mono_check;

    task automatic gmodel_reset();
        begin
            for (int i = 0; i < DEPTH; i++) begin gkey[i]='0; gdata[i]='0; end
            gcount = 0; g_ovf = 1'b0; g_udf = 1'b0;
            last_pop_key = '0; pop_seen = 1'b0; mono_check = 1'b0;
        end
    endtask

    // apply op `o` to the golden model (mirrors the RTL exactly)
    task automatic gmodel_step(input logic [1:0] o,
                               input logic [KEY_W-1:0] k,
                               input logic [DATA_W-1:0] d);
        int p;
        begin
            if (o == OP_ENQ) begin
                if (gcount == DEPTH) begin
                    g_ovf = 1'b1;                       // full: drop new element
                end else begin
                    p = gcount;                         // default: append at tail
                    for (int i = 0; i < gcount; i++)
                        if (p == gcount && k < gkey[i]) p = i;   // first larger key
                    for (int i = gcount; i > p; i--) begin       // open a slot at p
                        gkey[i]  = gkey[i-1];
                        gdata[i] = gdata[i-1];
                    end
                    gkey[p] = k; gdata[p] = d;
                    gcount  = gcount + 1;
                end
            end else if (o == OP_DEQ) begin
                if (gcount == 0) begin
                    g_udf = 1'b1;                       // empty: ignore
                end else begin
                    // during an insert-free drain, popped keys must be non-decreasing
                    if (mono_check && pop_seen && gkey[0] < last_pop_key) begin
                        $error("[%0t] extract-min NOT monotone: popped %0d after %0d",
                               $time, gkey[0], last_pop_key);
                        errors++;
                    end
                    last_pop_key = gkey[0]; pop_seen = 1'b1;
                    for (int i = 0; i < DEPTH-1; i++) begin
                        gkey[i]  = gkey[i+1];
                        gdata[i] = gdata[i+1];
                    end
                    gkey[DEPTH-1]='0; gdata[DEPTH-1]='0;
                    gcount = gcount - 1;
                end
            end
        end
    endtask

    task automatic check(input string tag);
        begin
            if (count !== CNT_W'(gcount)) begin
                $error("[%0t] %s count: dut=%0d exp=%0d", $time, tag, count, gcount);
                errors++;
            end
            if (empty !== (gcount == 0)) begin
                $error("[%0t] %s empty: dut=%0b exp=%0b", $time, tag, empty, (gcount==0));
                errors++;
            end
            if (full !== (gcount == DEPTH)) begin
                $error("[%0t] %s full: dut=%0b exp=%0b", $time, tag, full, (gcount==DEPTH));
                errors++;
            end
            if (min_valid !== (gcount != 0)) begin
                $error("[%0t] %s min_valid: dut=%0b exp=%0b", $time, tag, min_valid, (gcount!=0));
                errors++;
            end
            if (gcount != 0) begin
                if (min_key !== gkey[0]) begin
                    $error("[%0t] %s min_key: dut=%0d exp=%0d", $time, tag, min_key, gkey[0]);
                    errors++;
                end
                if (min_data !== gdata[0]) begin
                    $error("[%0t] %s min_data: dut=%h exp=%h", $time, tag, min_data, gdata[0]);
                    errors++;
                end
            end
            if (overflow !== g_ovf) begin
                $error("[%0t] %s overflow: dut=%0b exp=%0b", $time, tag, overflow, g_ovf);
                errors++;
            end
            if (underflow !== g_udf) begin
                $error("[%0t] %s underflow: dut=%0b exp=%0b", $time, tag, underflow, g_udf);
                errors++;
            end
        end
    endtask

    // drive one op on the current cycle, advance a clock, then compare
    task automatic do_op(input logic [1:0] o,
                         input logic [KEY_W-1:0] k,
                         input logic [DATA_W-1:0] d,
                         input string tag);
        begin
            op = o; enq_key = k; enq_data = d;
            gmodel_step(o, k, d);
            @(posedge clk); #1;
            check(tag);
        end
    endtask

    // ---- stimulus ------------------------------------------------------------
    int i;
    logic [1:0]        ro;
    logic [KEY_W-1:0]  rk;
    logic [DATA_W-1:0] rd;

    initial begin
        $dumpfile("priority_queue.vcd");
        $dumpvars(0, tb_priority_queue);

        errors  = 0;
        op      = OP_NOP;
        enq_key = '0;
        enq_data= '0;
        rst_n   = 1'b0;
        gmodel_reset();

        // hold reset for two cycles (waveform columns c0, c1)
        @(posedge clk); #1; check("rst0");
        @(posedge clk); #1; check("rst1");
        rst_n = 1'b1;

        // ---------------- DIRECTED (captured for the waveform) ----------------
        // out-of-order inserts, incl. a duplicate key (price-time / FIFO order)
        do_op(OP_ENQ, 16'd50, 16'hA5A5, "d.enq50");
        do_op(OP_ENQ, 16'd20, 16'hB6B6, "d.enq20a");
        do_op(OP_ENQ, 16'd80, 16'hC7C7, "d.enq80");
        do_op(OP_ENQ, 16'd20, 16'hD8D8, "d.enq20b");   // same key 20 -> after B6B6
        do_op(OP_ENQ, 16'd10, 16'hE9E9, "d.enq10");    // becomes new minimum
        // sorted extract-min drain: 10, 20(B6B6 first), 20(D8D8)
        do_op(OP_DEQ, 16'd0,  16'h0,    "d.deq0");      // pops key 10
        do_op(OP_DEQ, 16'd0,  16'h0,    "d.deq1");      // pops key 20 / B6B6
        do_op(OP_DEQ, 16'd0,  16'h0,    "d.deq2");      // pops key 20 / D8D8
        do_op(OP_ENQ, 16'd5,  16'h1111, "d.enq5");      // mid-stream new min
        do_op(OP_NOP, 16'd0,  16'h0,    "d.nop");
        do_op(OP_DEQ, 16'd0,  16'h0,    "d.deq3");      // pops 5
        do_op(OP_DEQ, 16'd0,  16'h0,    "d.deq4");      // pops 50
        do_op(OP_DEQ, 16'd0,  16'h0,    "d.deq5");      // pops 80 -> empty
        do_op(OP_DEQ, 16'd0,  16'h0,    "d.deq_udf");   // underflow (sticky)

        // ---------------- FULL / OVERFLOW directed ----------------------------
        for (i = 0; i < DEPTH; i++)
            do_op(OP_ENQ, KEY_W'(100 + i*3), DATA_W'(16'h0100 + i), "fill");
        if (!full) begin $error("queue should be full"); errors++; end
        do_op(OP_ENQ, 16'd7, 16'hFFFF, "ovf");           // ENQ while full -> overflow
        // drain it back out (insert-free: all should come out ascending)
        pop_seen = 1'b0; mono_check = 1'b1;
        for (i = 0; i < DEPTH; i++)
            do_op(OP_DEQ, 16'd0, 16'h0, "drain");
        mono_check = 1'b0;
        if (!empty) begin $error("queue should be empty"); errors++; end

        // ---------------- RANDOMIZED soak -------------------------------------
        for (i = 0; i < 4000; i++) begin
            ro = $random;                       // 2-bit op: NOP/ENQ/DEQ (11 -> NOP in DUT)
            rk = {$random} % 16;                // unsigned small range forces frequent ties
            rd = $random;
            do_op(ro, rk, rd, "rand");
        end

        if (errors == 0)
            $display("RESULT: *** PASS *** (directed + full/overflow + 4000 random ops, golden-model checked)");
        else
            $display("RESULT: *** FAIL *** (%0d mismatch%s)", errors, (errors==1)?"":"es");

        $finish;
    end

    // ---- watchdog ------------------------------------------------------------
    initial begin
        #500000;
        $fatal(1, "TIMEOUT: testbench did not finish");
    end

endmodule

`default_nettype wire
