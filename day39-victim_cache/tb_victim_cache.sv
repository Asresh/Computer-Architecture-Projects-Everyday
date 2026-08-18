// Author: Asresh Kuricheti
//
// Self-checking verification architecture:
//   directed/random cache traffic -> DUT associative store -> observed response
//                                 -> independent entry model -> exact comparison
`timescale 1ns/1ps
module tb_victim_cache;
    localparam int ADDR_WIDTH = 12;
    localparam int DATA_WIDTH = 32;
    localparam int ENTRIES = 4;
    localparam int PTR_WIDTH = $clog2(ENTRIES);
    localparam int RANDOM_CYCLES = 600;

    logic clk = 1'b0;
    logic reset_n;
    logic access_valid;
    logic [ADDR_WIDTH-1:0] access_addr;
    logic hit;
    logic [DATA_WIDTH-1:0] hit_data;
    logic hit_dirty;
    logic [PTR_WIDTH-1:0] hit_way;
    logic take_hit;
    logic insert_valid;
    logic [ADDR_WIDTH-1:0] insert_addr;
    logic [DATA_WIDTH-1:0] insert_data;
    logic insert_dirty;
    logic evict_valid;
    logic [ADDR_WIDTH-1:0] evict_addr;
    logic [DATA_WIDTH-1:0] evict_data;
    logic evict_dirty;
    logic [PTR_WIDTH:0] occupancy;

    logic [ENTRIES-1:0] ref_valid;
    logic [ADDR_WIDTH-1:0] ref_addr [0:ENTRIES-1];
    logic [DATA_WIDTH-1:0] ref_data [0:ENTRIES-1];
    logic [ENTRIES-1:0] ref_dirty;
    logic [PTR_WIDTH-1:0] ref_replace_ptr;
    integer errors, cycle, seed, i;

    victim_cache #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .DATA_WIDTH(DATA_WIDTH),
        .ENTRIES(ENTRIES)
    ) dut (.*);

    always #5 clk = ~clk;

    task automatic fail(input string message);
        begin
            $display("ERROR cycle %0d: %s", cycle, message);
            errors = errors + 1;
        end
    endtask

    task automatic observe_and_model;
        integer j;
        integer expected_hit_way;
        integer expected_insert_way;
        integer expected_occupancy;
        logic expected_hit;
        logic expected_evict;
        logic found_invalid;
        logic do_swap;
        begin
            expected_hit = 1'b0;
            expected_hit_way = 0;
            for (j = 0; j < ENTRIES; j = j + 1)
                if (!expected_hit && ref_valid[j] && ref_addr[j] == access_addr) begin
                    expected_hit = access_valid;
                    expected_hit_way = j;
                end

            expected_insert_way = ref_replace_ptr;
            found_invalid = 1'b0;
            for (j = 0; j < ENTRIES; j = j + 1)
                if (!found_invalid && !ref_valid[j]) begin
                    expected_insert_way = j;
                    found_invalid = 1'b1;
                end

            do_swap = expected_hit && take_hit && insert_valid;
            expected_evict = insert_valid && !do_swap && ref_valid[expected_insert_way];

            #1;
            if (hit !== expected_hit) fail("hit mismatch");
            if (expected_hit) begin
                if (hit_way !== expected_hit_way[PTR_WIDTH-1:0]) fail("hit-way mismatch");
                if (hit_data !== ref_data[expected_hit_way]) fail("hit-data mismatch");
                if (hit_dirty !== ref_dirty[expected_hit_way]) fail("hit-dirty mismatch");
            end else if (hit_data !== '0 || hit_dirty !== 1'b0)
                fail("miss response must be zero/clean");

            if (evict_valid !== expected_evict) fail("eviction-valid mismatch");
            if (expected_evict) begin
                if (evict_addr !== ref_addr[expected_insert_way]) fail("eviction-address mismatch");
                if (evict_data !== ref_data[expected_insert_way]) fail("eviction-data mismatch");
                if (evict_dirty !== ref_dirty[expected_insert_way]) fail("eviction-dirty mismatch");
            end

            expected_occupancy = 0;
            for (j = 0; j < ENTRIES; j = j + 1)
                expected_occupancy = expected_occupancy + ref_valid[j];
            if (occupancy !== expected_occupancy[PTR_WIDTH:0]) fail("pre-edge occupancy mismatch");

            @(posedge clk);
            if (expected_hit && take_hit) begin
                if (insert_valid) begin
                    ref_valid[expected_hit_way] = 1'b1;
                    ref_addr[expected_hit_way] = insert_addr;
                    ref_data[expected_hit_way] = insert_data;
                    ref_dirty[expected_hit_way] = insert_dirty;
                end else begin
                    ref_valid[expected_hit_way] = 1'b0;
                    ref_dirty[expected_hit_way] = 1'b0;
                end
            end
            if (insert_valid && !(expected_hit && take_hit)) begin
                if (ref_valid[expected_insert_way])
                    ref_replace_ptr = ref_replace_ptr + 1'b1;
                ref_valid[expected_insert_way] = 1'b1;
                ref_addr[expected_insert_way] = insert_addr;
                ref_data[expected_insert_way] = insert_data;
                ref_dirty[expected_insert_way] = insert_dirty;
            end
            cycle = cycle + 1;
            #1;
            expected_occupancy = 0;
            for (j = 0; j < ENTRIES; j = j + 1)
                expected_occupancy = expected_occupancy + ref_valid[j];
            if (occupancy !== expected_occupancy[PTR_WIDTH:0]) fail("post-edge occupancy mismatch");
        end
    endtask

    task automatic drive(
        input logic do_access,
        input logic [ADDR_WIDTH-1:0] lookup_addr,
        input logic do_take,
        input logic do_insert,
        input logic [ADDR_WIDTH-1:0] new_addr,
        input logic [DATA_WIDTH-1:0] new_data,
        input logic new_dirty
    );
        begin
            @(negedge clk);
            access_valid = do_access;
            access_addr = lookup_addr;
            take_hit = do_take;
            insert_valid = do_insert;
            insert_addr = new_addr;
            insert_data = new_data;
            insert_dirty = new_dirty;
            observe_and_model();
        end
    endtask

    initial begin
        $dumpfile("victim_cache.vcd");
        $dumpvars(0, tb_victim_cache);
        errors = 0;
        cycle = 0;
        seed = 32'h39c0ffee;
        ref_valid = '0;
        ref_dirty = '0;
        ref_replace_ptr = '0;
        for (i = 0; i < ENTRIES; i = i + 1) begin
            ref_addr[i] = '0;
            ref_data[i] = '0;
        end

        reset_n = 1'b0;
        access_valid = 1'b0;
        access_addr = '0;
        take_hit = 1'b0;
        insert_valid = 1'b0;
        insert_addr = '0;
        insert_data = '0;
        insert_dirty = 1'b0;
        repeat (3) @(posedge clk);
        reset_n = 1'b1;

        // Directed: miss, fills, hit, consume, reuse, atomic swap, full eviction.
        drive(1, 12'h100, 0, 0, 0, 0, 0);
        drive(0, 0, 0, 1, 12'h100, 32'haaaa_0001, 0);
        drive(0, 0, 0, 1, 12'h200, 32'hbbbb_0002, 1);
        drive(1, 12'h100, 0, 0, 0, 0, 0);
        drive(1, 12'h100, 1, 0, 0, 0, 0);
        drive(0, 0, 0, 1, 12'h300, 32'hcccc_0003, 0);
        drive(1, 12'h200, 1, 1, 12'h400, 32'hdddd_0004, 1);
        drive(1, 12'h200, 0, 0, 0, 0, 0);
        drive(1, 12'h400, 0, 0, 0, 0, 0);
        drive(0, 0, 0, 1, 12'h500, 32'heeee_0005, 0);
        drive(0, 0, 0, 1, 12'h600, 32'hffff_0006, 1);
        drive(0, 0, 0, 1, 12'h700, 32'h7777_0007, 0);

        // Randomized associative lookups, removals, inserts, swaps, and evictions.
        for (i = 0; i < RANDOM_CYCLES; i = i + 1) begin
            drive(($urandom(seed) % 5) != 0,
                  (($urandom(seed) % 16) + 1) << 4,
                  ($urandom(seed) % 3) == 0,
                  ($urandom(seed) % 2) == 0,
                  (($urandom(seed) % 16) + 1) << 4,
                  $urandom(seed),
                  ($urandom(seed) & 1));
        end

        access_valid = 1'b0;
        insert_valid = 1'b0;
        take_hit = 1'b0;
        if (errors == 0) begin
            $display("Checked %0d directed/randomized victim-cache cycles", cycle);
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
