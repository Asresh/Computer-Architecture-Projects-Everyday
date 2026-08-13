// ---------------------------------------------------------------------------
// tb_reorder_buffer.sv - self-checking testbench for the Day12 ROB.
//
// The golden reference is an INDEPENDENT behavioural model built from ordered
// SystemVerilog queues (refq_*) plus a predicted next-tag counter -- a very
// different description from the DUT's circular-pointer RTL. Every cycle, all
// combinational DUT outputs (alloc_ready/alloc_tag, retire_valid/tag/dest/data,
// full/empty/count) are compared against the queue model BEFORE the clock edge;
// then the same fire decisions are applied to both.
//
// Coverage:
//   * directed scenario  - out-of-order completion, in-order retirement, a
//     head-of-line stall (younger entry done, older not), fill-to-full, and a
//     full squash;
//   * randomized scenario - thousands of cycles of random allocate / complete
//     (to a live, not-yet-done entry) / retire / occasional flush.
//
// A watchdog aborts on hang. Prints "RESULT: *** PASS ***" only if zero
// mismatches were seen. Dumps reorder_buffer.vcd.
// ---------------------------------------------------------------------------
`default_nettype none
`timescale 1ns/1ps

module tb_reorder_buffer;

    localparam int NUM_ENTRIES = 8;
    localparam int DATA_WIDTH  = 32;
    localparam int REG_ADDR_W  = 5;
    localparam int TAG_W       = $clog2(NUM_ENTRIES);

    // ---- DUT I/O -------------------------------------------------------
    logic                    clk, rst_n;
    logic                    alloc_valid;
    wire                     alloc_ready;
    logic [REG_ADDR_W-1:0]   alloc_dest;
    wire  [TAG_W-1:0]        alloc_tag;
    logic                    cmpl_valid;
    logic [TAG_W-1:0]        cmpl_tag;
    logic [DATA_WIDTH-1:0]   cmpl_data;
    logic                    retire_ready;
    wire                     retire_valid;
    wire  [TAG_W-1:0]        retire_tag;
    wire  [REG_ADDR_W-1:0]   retire_dest;
    wire  [DATA_WIDTH-1:0]   retire_data;
    logic                    flush;
    wire                     full, empty;
    wire  [TAG_W:0]          count;

    reorder_buffer #(
        .NUM_ENTRIES(NUM_ENTRIES),
        .DATA_WIDTH (DATA_WIDTH),
        .REG_ADDR_W (REG_ADDR_W)
    ) dut (
        .clk         (clk),
        .rst_n       (rst_n),
        .alloc_valid (alloc_valid),
        .alloc_ready (alloc_ready),
        .alloc_dest  (alloc_dest),
        .alloc_tag   (alloc_tag),
        .cmpl_valid  (cmpl_valid),
        .cmpl_tag    (cmpl_tag),
        .cmpl_data   (cmpl_data),
        .retire_ready(retire_ready),
        .retire_valid(retire_valid),
        .retire_tag  (retire_tag),
        .retire_dest (retire_dest),
        .retire_data (retire_data),
        .flush       (flush),
        .full        (full),
        .empty       (empty),
        .count       (count)
    );

    // ---- Clock ---------------------------------------------------------
    localparam int CLKP = 10;
    initial clk = 1'b0;
    always #(CLKP/2) clk = ~clk;

    // ---- Independent golden model (parallel ordered queues) ------------
    // refq_*[0] is the head (oldest), back is the tail (youngest).
    integer                refq_tag  [$];
    integer                refq_dest [$];
    logic [DATA_WIDTH-1:0] refq_data [$];
    bit                    refq_done [$];
    int unsigned           next_tag;     // predicted tag for the next allocate
    integer                errors;

    function int  q_size();   return refq_tag.size();            endfunction
    function bit  mdl_full();  return (refq_tag.size() == NUM_ENTRIES); endfunction
    function bit  mdl_empty(); return (refq_tag.size() == 0);          endfunction

    // Compare DUT combinational outputs against the model's current state.
    task check_outputs(input string label);
        integer h_tag, h_dest;
        if (alloc_ready !== ~mdl_full())
            begin errors++; $error("%0t [%s] alloc_ready=%b exp=%b", $time, label, alloc_ready, ~mdl_full()); end
        if (full !== mdl_full())
            begin errors++; $error("%0t [%s] full=%b exp=%b", $time, label, full, mdl_full()); end
        if (empty !== mdl_empty())
            begin errors++; $error("%0t [%s] empty=%b exp=%b", $time, label, empty, mdl_empty()); end
        if (count !== q_size())
            begin errors++; $error("%0t [%s] count=%0d exp=%0d", $time, label, count, q_size()); end
        // tail slot handed out must equal predicted next tag
        if (alloc_tag !== next_tag[TAG_W-1:0])
            begin errors++; $error("%0t [%s] alloc_tag=%0d exp=%0d", $time, label, alloc_tag, next_tag[TAG_W-1:0]); end
        // retire_valid + head payload
        if (q_size() == 0) begin
            if (retire_valid !== 1'b0)
                begin errors++; $error("%0t [%s] retire_valid=1 on empty", $time, label); end
        end else begin
            if (retire_valid !== refq_done[0])
                begin errors++; $error("%0t [%s] retire_valid=%b exp head.done=%b", $time, label, retire_valid, refq_done[0]); end
            if (refq_done[0]) begin
                h_tag  = refq_tag[0];
                h_dest = refq_dest[0];
                if (retire_tag !== h_tag[TAG_W-1:0])
                    begin errors++; $error("%0t [%s] retire_tag=%0d exp=%0d", $time, label, retire_tag, h_tag); end
                if (retire_dest !== h_dest[REG_ADDR_W-1:0])
                    begin errors++; $error("%0t [%s] retire_dest=%0d exp=%0d", $time, label, retire_dest, h_dest); end
                if (retire_data !== refq_data[0])
                    begin errors++; $error("%0t [%s] retire_data=%h exp=%h", $time, label, retire_data, refq_data[0]); end
            end
        end
    endtask

    // Advance the model by one cycle using the same fire conditions the DUT uses.
    task model_step(input bit do_alloc, input integer a_dest,
                              input bit do_cmpl,  input integer c_tag,
                              input logic [DATA_WIDTH-1:0] c_data,
                              input bit do_retire_rdy, input bit do_flush);
        bit alloc_fire, retire_fire;
        int idx;
        if (do_flush) begin
            refq_tag.delete(); refq_dest.delete(); refq_data.delete(); refq_done.delete();
            next_tag = 0;
            return;
        end
        alloc_fire  = do_alloc && !mdl_full();
        retire_fire = do_retire_rdy && (q_size() > 0) && refq_done[0];
        if (retire_fire) begin
            void'(refq_tag.pop_front());
            void'(refq_dest.pop_front());
            void'(refq_data.pop_front());
            void'(refq_done.pop_front());
        end
        if (alloc_fire) begin
            refq_tag.push_back(next_tag);
            refq_dest.push_back(a_dest);
            refq_data.push_back('0);
            refq_done.push_back(1'b0);
            next_tag = (next_tag + 1) % NUM_ENTRIES;
        end
        if (do_cmpl) begin
            for (idx = 0; idx < q_size(); idx++) begin
                if (refq_tag[idx] == c_tag && !refq_done[idx]) begin
                    refq_done[idx] = 1'b1;
                    refq_data[idx] = c_data;
                    break;
                end
            end
        end
    endtask

    // Drive one cycle: apply inputs, check pre-edge, clock, update model.
    task step(input bit a_v, input integer a_dest,
                        input bit c_v, input integer c_tag,
                        input logic [DATA_WIDTH-1:0] c_data,
                        input bit r_rdy, input bit fl, input string label);
        @(negedge clk);
        alloc_valid  = a_v;
        alloc_dest   = a_dest[REG_ADDR_W-1:0];
        cmpl_valid   = c_v;
        cmpl_tag     = c_tag[TAG_W-1:0];
        cmpl_data    = c_data;
        retire_ready = r_rdy;
        flush        = fl;
        #1;                            // let combinational logic settle
        check_outputs(label);
        @(posedge clk);                // DUT commits
        #1;
        model_step(a_v, a_dest, c_v, c_tag, c_data, r_rdy, fl);
    endtask

    // Pick a live, not-yet-completed tag from the model (or return -1).
    integer cands[$];
    function int pick_incomplete_tag();
        int k;
        cands.delete();
        for (k = 0; k < q_size(); k++)
            if (!refq_done[k]) cands.push_back(refq_tag[k]);
        if (cands.size() == 0) return -1;
        return cands[$urandom_range(cands.size()-1)];
    endfunction

    // ---- Watchdog ------------------------------------------------------
    initial begin
        #200000;
        $display("RESULT: *** FAIL *** (timeout / watchdog)");
        $fatal(1, "watchdog");
    end

    // ---- Stimulus ------------------------------------------------------
    integer n, rr, rt;
    bit     ra, rc, rf;
    logic [DATA_WIDTH-1:0] rd;
    integer ht;
    initial begin
        $dumpfile("reorder_buffer.vcd");
        $dumpvars(0, tb_reorder_buffer);

        errors      = 0;
        next_tag    = 0;
        alloc_valid = 0; alloc_dest = 0;
        cmpl_valid  = 0; cmpl_tag   = 0; cmpl_data = 0;
        retire_ready= 0; flush      = 0;

        // Reset
        rst_n = 1'b0;
        repeat (3) @(negedge clk);
        rst_n = 1'b1;
        @(negedge clk);
        check_outputs("post-reset");

        // ================= DIRECTED SCENARIO =========================
        // Allocate three instructions in program order (tags 0,1,2).
        step(1, 1, 0, 0, 32'h0,         0, 0, "alloc A(x1)=tag0");
        step(1, 2, 0, 0, 32'h0,         0, 0, "alloc B(x2)=tag1");
        step(1, 3, 0, 0, 32'h0,         0, 0, "alloc C(x3)=tag2");

        // Complete tag1 (B) OUT OF ORDER. Head (tag0) still not done ->
        // retire_valid must stay 0 (head-of-line stall).
        step(0, 0, 1, 1, 32'hB0B0_B0B0, 1, 0, "cmpl tag1 (OOO, head stalls)");

        // Complete tag0 (A). Now head is done -> retire_valid asserts.
        step(0, 0, 1, 0, 32'hA0A0_A0A0, 1, 0, "cmpl tag0 (head now done)");

        // Retire in order: A (tag0), then B (tag1, already done), then stall
        // on C (tag2) which is not complete yet.
        step(0, 0, 0, 0, 32'h0,         1, 0, "retire A(tag0)");
        step(0, 0, 0, 0, 32'h0,         1, 0, "retire B(tag1)");
        step(0, 0, 0, 0, 32'h0,         1, 0, "stall: C(tag2) not done");

        // Allocate D (tag3) while C is still pending; complete C, retire C, D.
        step(1, 4, 1, 2, 32'hC0C0_C0C0, 1, 0, "alloc D(x4)=tag3 + cmpl tag2");
        step(0, 0, 1, 3, 32'hD0D0_D0D0, 1, 0, "cmpl tag3 + retire C(tag2)");
        step(0, 0, 0, 0, 32'h0,         1, 0, "retire D(tag3) -> empty");

        // ---- Fill toward full to exercise wrap + full/empty flags -----
        for (n = 0; n < NUM_ENTRIES; n++)
            step(1, (n+1), 0, 0, 32'h0, 0, 0, "fill");
        // Now full: alloc_ready must be 0; try to over-allocate (ignored).
        step(1, 9, 0, 0, 32'h0, 0, 0, "over-allocate when full");

        // ---- Squash the whole window in one cycle ---------------------
        step(0, 0, 0, 0, 32'h0, 0, 1, "FLUSH (squash all)");
        step(0, 0, 0, 0, 32'h0, 0, 0, "post-flush empty");

        // ================= RANDOMIZED SCENARIO =======================
        for (n = 0; n < 4000; n++) begin
            ra = $urandom_range(1);                 // maybe allocate
            rr = $urandom_range(1);                 // maybe accept retire
            rf = ($urandom_range(63) == 0);         // rare flush
            rt = pick_incomplete_tag();
            rc = (rt >= 0) && ($urandom_range(1));  // maybe complete a live entry
            rd = $urandom;
            if (rf) begin ra = 0; rc = 0; end        // flush alone, keep it clean
            step(ra, $urandom_range(31),
                 rc, (rt < 0) ? 0 : rt, rd,
                 rr[0], rf, "rand");
        end

        // Drain: keep retiring, completing the current head until empty.
        for (n = 0; (n < 4*NUM_ENTRIES) && (q_size() > 0); n++) begin
            ht = (!refq_done[0]) ? refq_tag[0] : -1;
            step(0, 0, (ht >= 0), (ht < 0) ? 0 : ht, 32'hDEAD_0000 | n,
                 1, 0, "drain");
        end

        // ---- Verdict ---------------------------------------------------
        repeat (2) @(negedge clk);
        if (errors == 0)
            $display("RESULT: *** PASS *** (directed + 4000 random cycles matched the golden model)");
        else
            $display("RESULT: *** FAIL *** (%0d mismatches)", errors);
        $finish;
    end

endmodule

`default_nettype wire
