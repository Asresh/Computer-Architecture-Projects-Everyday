// Author: Asresh Kuricheti
//
// Self-checking verification architecture:
//   directed/random operations -> DUT SSIT/LFST -> prediction
//                              -> independent cycle model -> compare
`timescale 1ns/1ps
module tb_store_set_predictor;
    localparam int PC_WIDTH = 16;
    localparam int SSIT_ENTRIES = 16;
    localparam int NUM_STORE_SETS = 8;
    localparam int ROB_TAG_WIDTH = 6;
    localparam int SSIT_INDEX_WIDTH = $clog2(SSIT_ENTRIES);
    localparam int SSID_WIDTH = $clog2(NUM_STORE_SETS);
    localparam int RANDOM_CYCLES = 800;

    logic clk = 0;
    logic reset_n, flush;
    logic lookup_valid;
    logic [PC_WIDTH-1:0] load_pc;
    logic dependence_predicted;
    logic [ROB_TAG_WIDTH-1:0] predicted_store_tag;
    logic lookup_ssid_valid;
    logic [SSID_WIDTH-1:0] lookup_ssid;
    logic store_dispatch_valid;
    logic [PC_WIDTH-1:0] store_pc;
    logic [ROB_TAG_WIDTH-1:0] store_tag;
    logic store_retire_valid;
    logic [ROB_TAG_WIDTH-1:0] store_retire_tag;
    logic violation_valid;
    logic [PC_WIDTH-1:0] violation_load_pc, violation_store_pc;

    logic [SSIT_ENTRIES-1:0] ref_ssit_valid;
    logic [SSID_WIDTH-1:0] ref_ssit_id [0:SSIT_ENTRIES-1];
    logic [NUM_STORE_SETS-1:0] ref_lfst_valid;
    logic [ROB_TAG_WIDTH-1:0] ref_lfst_tag [0:NUM_STORE_SETS-1];
    logic [SSID_WIDTH-1:0] ref_next_ssid;
    integer errors, cycle, seed, i;
    integer li, si, di;
    logic [SSID_WIDTH-1:0] source_id, target_id;

    store_set_predictor #(
        .PC_WIDTH(PC_WIDTH),
        .SSIT_ENTRIES(SSIT_ENTRIES),
        .NUM_STORE_SETS(NUM_STORE_SETS),
        .ROB_TAG_WIDTH(ROB_TAG_WIDTH)
    ) dut (.*);

    always #5 clk = ~clk;

    function automatic integer pc_index(input logic [PC_WIDTH-1:0] pc);
        pc_index = pc[2 +: SSIT_INDEX_WIDTH] ^
                   pc[2 + SSIT_INDEX_WIDTH +: SSIT_INDEX_WIDTH];
    endfunction

    task automatic fail(input string message);
        begin
            $display("ERROR cycle %0d: %s", cycle, message);
            errors = errors + 1;
        end
    endtask

    task automatic check_lookup(input logic [PC_WIDTH-1:0] pc);
        integer index;
        logic expected_ssid_valid;
        logic [SSID_WIDTH-1:0] expected_ssid;
        logic expected_dependence;
        logic [ROB_TAG_WIDTH-1:0] expected_tag;
        begin
            @(negedge clk);
            lookup_valid = 1'b1;
            load_pc = pc;
            #1;
            index = pc_index(pc);
            expected_ssid_valid = ref_ssit_valid[index];
            expected_ssid = expected_ssid_valid ? ref_ssit_id[index] : '0;
            expected_dependence = expected_ssid_valid && ref_lfst_valid[expected_ssid];
            expected_tag = expected_dependence ? ref_lfst_tag[expected_ssid] : '0;
            if (lookup_ssid_valid !== expected_ssid_valid) fail("SSIT-valid mismatch");
            if (lookup_ssid !== expected_ssid) fail("store-set ID mismatch");
            if (dependence_predicted !== expected_dependence) fail("dependence mismatch");
            if (predicted_store_tag !== expected_tag) fail("predicted store tag mismatch");
        end
    endtask

    task automatic model_edge;
        integer j;
        logic dispatch_was_trained;
        logic [SSID_WIDTH-1:0] dispatch_id_before_edge;
        begin
            di = pc_index(store_pc);
            dispatch_was_trained = ref_ssit_valid[di];
            dispatch_id_before_edge = ref_ssit_id[di];
            if (flush) begin
                ref_lfst_valid = '0;
            end else begin
                if (store_retire_valid)
                    for (j = 0; j < NUM_STORE_SETS; j = j + 1)
                        if (ref_lfst_valid[j] && ref_lfst_tag[j] == store_retire_tag)
                            ref_lfst_valid[j] = 1'b0;

                li = pc_index(violation_load_pc);
                si = pc_index(violation_store_pc);
                if (violation_valid) begin
                    if (!ref_ssit_valid[li] && !ref_ssit_valid[si]) begin
                        ref_ssit_valid[li] = 1'b1;
                        ref_ssit_valid[si] = 1'b1;
                        ref_ssit_id[li] = ref_next_ssid;
                        ref_ssit_id[si] = ref_next_ssid;
                        ref_next_ssid = ref_next_ssid + 1'b1;
                    end else if (!ref_ssit_valid[li]) begin
                        ref_ssit_valid[li] = 1'b1;
                        ref_ssit_id[li] = ref_ssit_id[si];
                    end else if (!ref_ssit_valid[si]) begin
                        ref_ssit_valid[si] = 1'b1;
                        ref_ssit_id[si] = ref_ssit_id[li];
                    end else if (ref_ssit_id[li] != ref_ssit_id[si]) begin
                        source_id = ref_ssit_id[li];
                        target_id = ref_ssit_id[si];
                        for (j = 0; j < SSIT_ENTRIES; j = j + 1)
                            if (ref_ssit_valid[j] && ref_ssit_id[j] == source_id)
                                ref_ssit_id[j] = target_id;
                        if (!ref_lfst_valid[target_id] && ref_lfst_valid[source_id]) begin
                            ref_lfst_valid[target_id] = 1'b1;
                            ref_lfst_tag[target_id] = ref_lfst_tag[source_id];
                        end
                        ref_lfst_valid[source_id] = 1'b0;
                    end
                end

                // Dispatch uses the mapping visible at the start of the DUT edge.
                if (store_dispatch_valid && dispatch_was_trained) begin
                    ref_lfst_valid[dispatch_id_before_edge] = 1'b1;
                    ref_lfst_tag[dispatch_id_before_edge] = store_tag;
                end
            end
        end
    endtask

    task automatic drive_cycle(
        input logic do_flush,
        input logic do_dispatch,
        input logic [PC_WIDTH-1:0] dispatch_pc,
        input logic [ROB_TAG_WIDTH-1:0] dispatch_tag,
        input logic do_retire,
        input logic [ROB_TAG_WIDTH-1:0] retire_tag,
        input logic do_violation,
        input logic [PC_WIDTH-1:0] violating_load,
        input logic [PC_WIDTH-1:0] violating_store
    );
        begin
            @(negedge clk);
            flush = do_flush;
            store_dispatch_valid = do_dispatch;
            store_pc = dispatch_pc;
            store_tag = dispatch_tag;
            store_retire_valid = do_retire;
            store_retire_tag = retire_tag;
            violation_valid = do_violation;
            violation_load_pc = violating_load;
            violation_store_pc = violating_store;
            @(posedge clk);
            model_edge();
            cycle = cycle + 1;
            #1;
        end
    endtask

    initial begin
        $dumpfile("store_set_predictor.vcd");
        $dumpvars(0, tb_store_set_predictor);
        errors = 0;
        cycle = 0;
        seed = 32'h38c0ffee;
        ref_ssit_valid = '0;
        ref_lfst_valid = '0;
        ref_next_ssid = '0;
        for (i = 0; i < SSIT_ENTRIES; i = i + 1)
            ref_ssit_id[i] = '0;
        for (i = 0; i < NUM_STORE_SETS; i = i + 1)
            ref_lfst_tag[i] = '0;

        reset_n = 0;
        flush = 0;
        lookup_valid = 0;
        load_pc = 0;
        store_dispatch_valid = 0;
        store_pc = 0;
        store_tag = 0;
        store_retire_valid = 0;
        store_retire_tag = 0;
        violation_valid = 0;
        violation_load_pc = 0;
        violation_store_pc = 0;
        repeat (3) @(posedge clk);
        reset_n = 1;

        // Directed sequence: learn, predict, overwrite youngest, retire, flush.
        check_lookup(16'h0100);
        drive_cycle(0, 0, 0, 0, 0, 0, 1, 16'h0100, 16'h0200);
        drive_cycle(0, 1, 16'h0200, 6'h15, 0, 0, 0, 0, 0);
        check_lookup(16'h0100);
        drive_cycle(0, 1, 16'h0200, 6'h16, 1, 6'h15, 0, 0, 0);
        check_lookup(16'h0100);
        drive_cycle(0, 0, 0, 0, 1, 6'h16, 0, 0, 0);
        check_lookup(16'h0100);
        drive_cycle(0, 1, 16'h0200, 6'h17, 0, 0, 0, 0, 0);
        drive_cycle(1, 0, 0, 0, 0, 0, 0, 0, 0);
        check_lookup(16'h0100);

        // Train a second set, then merge the first set into it.
        drive_cycle(0, 0, 0, 0, 0, 0, 1, 16'h0300, 16'h0400);
        drive_cycle(0, 1, 16'h0400, 6'h21, 0, 0, 0, 0, 0);
        drive_cycle(0, 0, 0, 0, 0, 0, 1, 16'h0100, 16'h0400);
        check_lookup(16'h0100);
        check_lookup(16'h0300);

        // Randomized SSIT learning, LFST updates, retirement, merge, and flush.
        for (i = 0; i < RANDOM_CYCLES; i = i + 1) begin
            drive_cycle(($urandom(seed) % 101) == 0,
                        ($urandom(seed) % 3) == 0,
                        16'h1000 + (($urandom(seed) % 32) * 16'h0004),
                        $urandom(seed),
                        ($urandom(seed) % 5) == 0,
                        $urandom(seed),
                        ($urandom(seed) % 7) == 0,
                        16'h1000 + (($urandom(seed) % 32) * 16'h0004),
                        16'h1000 + (($urandom(seed) % 32) * 16'h0004));
            check_lookup(16'h1000 + (($urandom(seed) % 32) * 16'h0004));
        end

        lookup_valid = 0;
        if (errors == 0) begin
            $display("Checked %0d directed/randomized predictor cycles", cycle);
            $display("RESULT: *** PASS ***");
        end else begin
            $display("RESULT: *** FAIL *** (%0d errors)", errors);
            $fatal(1);
        end
        $finish;
    end

    initial begin
        #100000;
        $fatal(1, "TIMEOUT: testbench did not complete");
    end
endmodule
