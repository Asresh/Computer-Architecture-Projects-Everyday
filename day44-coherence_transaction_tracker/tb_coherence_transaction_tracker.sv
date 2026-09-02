// Author: Asresh Kuricheti
// Self-checking directed and randomized verification.
//
//   stimulus ---> DUT outputs ---> cycle-accurate reference model ---> compare
//       |                                                        |
//       +-------------------------- VCD --------------------------+

`timescale 1ns/1ps

module tb_coherence_transaction_tracker;
    localparam integer ENTRIES        = 4;
    localparam integer NUM_AGENTS     = 4;
    localparam integer TXN_ID_WIDTH   = 6;
    localparam integer TIMEOUT_CYCLES = 8;
    localparam integer AGENT_WIDTH    = 2;
    localparam integer COUNT_WIDTH    = 3;

    logic clk;
    logic rst_n;
    logic alloc_valid;
    logic alloc_ready;
    logic [TXN_ID_WIDTH-1:0] alloc_txn_id;
    logic [NUM_AGENTS-1:0] alloc_targets;
    logic ack_valid;
    logic [TXN_ID_WIDTH-1:0] ack_txn_id;
    logic [AGENT_WIDTH-1:0] ack_agent;
    logic completion_valid;
    logic completion_ready;
    logic [TXN_ID_WIDTH-1:0] completion_txn_id;
    logic full;
    logic [COUNT_WIDTH-1:0] outstanding_count;
    logic [ENTRIES-1:0] valid_entries;
    logic [ENTRIES*NUM_AGENTS-1:0] pending_masks_flat;
    logic protocol_error;
    logic timeout_error;

    logic ref_valid [0:ENTRIES-1];
    logic [TXN_ID_WIDTH-1:0] ref_id [0:ENTRIES-1];
    logic [NUM_AGENTS-1:0] ref_pending [0:ENTRIES-1];
    integer ref_age [0:ENTRIES-1];
    logic ref_protocol_error;
    logic ref_timeout_error;

    integer checks;
    integer cycle_number;
    integer seed;
    integer i;

    coherence_transaction_tracker #(
        .ENTRIES(ENTRIES),
        .NUM_AGENTS(NUM_AGENTS),
        .TXN_ID_WIDTH(TXN_ID_WIDTH),
        .TIMEOUT_CYCLES(TIMEOUT_CYCLES)
    ) dut (.*);

    always #5 clk = ~clk;

    task automatic fail(input string message);
        begin
            $display("FAIL cycle %0d: %s", cycle_number, message);
            $display("RESULT: *** FAIL ***");
            $finish;
        end
    endtask

    task automatic clear_reference;
        integer k;
        begin
            for (k = 0; k < ENTRIES; k = k + 1) begin
                ref_valid[k]   = 1'b0;
                ref_id[k]      = '0;
                ref_pending[k] = '0;
                ref_age[k]     = 0;
            end
            ref_protocol_error = 1'b0;
            ref_timeout_error  = 1'b0;
        end
    endtask

    task automatic apply_cycle(
        input logic av,
        input logic [TXN_ID_WIDTH-1:0] aid,
        input logic [NUM_AGENTS-1:0] targets,
        input logic kv,
        input logic [TXN_ID_WIDTH-1:0] kid,
        input logic [AGENT_WIDTH-1:0] agent,
        input logic cr
    );
        integer k;
        integer free_idx;
        integer ack_idx;
        integer comp_idx;
        integer count;
        logic free_seen;
        logic duplicate;
        logic ack_seen;
        logic comp_seen;
        logic expected_ready;
        logic [ENTRIES-1:0] expected_valid;
        logic [ENTRIES*NUM_AGENTS-1:0] expected_pending;
        begin
            @(negedge clk);
            alloc_valid       = av;
            alloc_txn_id      = aid;
            alloc_targets     = targets;
            ack_valid         = kv;
            ack_txn_id        = kid;
            ack_agent         = agent;
            completion_ready  = cr;
            #1;

            free_idx = 0;
            ack_idx = 0;
            comp_idx = 0;
            count = 0;
            free_seen = 1'b0;
            duplicate = 1'b0;
            ack_seen = 1'b0;
            comp_seen = 1'b0;
            expected_valid = '0;
            expected_pending = '0;
            for (k = 0; k < ENTRIES; k = k + 1) begin
                expected_valid[k] = ref_valid[k];
                expected_pending[k*NUM_AGENTS +: NUM_AGENTS] = ref_pending[k];
                if (ref_valid[k]) begin
                    count = count + 1;
                    if (ref_id[k] == aid)
                        duplicate = 1'b1;
                    if (!ack_seen && (ref_id[k] == kid)) begin
                        ack_seen = 1'b1;
                        ack_idx = k;
                    end
                    if (!comp_seen && (ref_pending[k] == '0)) begin
                        comp_seen = 1'b1;
                        comp_idx = k;
                    end
                end else if (!free_seen) begin
                    free_seen = 1'b1;
                    free_idx = k;
                end
            end
            expected_ready = free_seen && (!av || !duplicate);

            checks = checks + 9;
            if (alloc_ready !== expected_ready) fail("alloc_ready mismatch");
            if (full !== !free_seen) fail("full mismatch");
            if (outstanding_count !== count[COUNT_WIDTH-1:0]) fail("outstanding_count mismatch");
            if (valid_entries !== expected_valid) fail("valid_entries mismatch");
            if (pending_masks_flat !== expected_pending) fail("pending mask mismatch");
            if (completion_valid !== comp_seen) fail("completion_valid mismatch");
            if (comp_seen && (completion_txn_id !== ref_id[comp_idx])) fail("completion ID mismatch");
            if (protocol_error !== ref_protocol_error) fail("protocol_error mismatch");
            if (timeout_error !== ref_timeout_error) fail("timeout_error mismatch");

            @(posedge clk);
            #1;
            cycle_number = cycle_number + 1;

            if (av && duplicate)
                ref_protocol_error = 1'b1;
            if (kv && (!ack_seen || (agent >= NUM_AGENTS)))
                ref_protocol_error = 1'b1;
            else if (kv && !ref_pending[ack_idx][agent])
                ref_protocol_error = 1'b1;

            // Age uses pre-edge pending state, just like nonblocking RTL.
            for (k = 0; k < ENTRIES; k = k + 1) begin
                if (comp_seen && cr && (comp_idx == k)) begin
                    ref_valid[k] = 1'b0;
                    ref_pending[k] = '0;
                    ref_age[k] = 0;
                end else if (ref_valid[k] && (ref_pending[k] != '0)) begin
                    if (ref_age[k] >= TIMEOUT_CYCLES-1)
                        ref_timeout_error = 1'b1;
                    else
                        ref_age[k] = ref_age[k] + 1;
                end
            end

            if (kv && ack_seen && (agent < NUM_AGENTS) && ref_pending[ack_idx][agent])
                ref_pending[ack_idx][agent] = 1'b0;

            if (av && expected_ready) begin
                ref_valid[free_idx] = 1'b1;
                ref_id[free_idx] = aid;
                ref_pending[free_idx] = targets;
                ref_age[free_idx] = 0;
            end
        end
    endtask

    initial begin
        #100000;
        $display("RESULT: *** FAIL *** (timeout)");
        $finish;
    end

    initial begin
        $dumpfile("coherence_transaction_tracker.vcd");
        $dumpvars(0, tb_coherence_transaction_tracker);

        clk = 1'b0;
        rst_n = 1'b0;
        alloc_valid = 1'b0;
        alloc_txn_id = '0;
        alloc_targets = '0;
        ack_valid = 1'b0;
        ack_txn_id = '0;
        ack_agent = '0;
        completion_ready = 1'b0;
        checks = 0;
        cycle_number = 0;
        seed = 32'h44c0ffee;
        clear_reference();

        repeat (3) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;

        // Directed: two transactions, acknowledgements arrive out of order.
        apply_cycle(1, 6'h0a, 4'b1011, 0, 0, 0, 0);
        apply_cycle(1, 6'h14, 4'b0100, 0, 0, 0, 0);
        apply_cycle(0, 0, 0, 1, 6'h0a, 3, 0);
        apply_cycle(0, 0, 0, 1, 6'h14, 2, 1);
        apply_cycle(0, 0, 0, 0, 0, 0, 1); // retire transaction 0x14
        apply_cycle(0, 0, 0, 1, 6'h0a, 0, 0);
        apply_cycle(0, 0, 0, 1, 6'h0a, 1, 1);
        apply_cycle(0, 0, 0, 0, 0, 0, 1); // retire transaction 0x0a

        // Zero-target requests complete without waiting for an acknowledgement.
        apply_cycle(1, 6'h21, 4'b0000, 0, 0, 0, 0);
        apply_cycle(0, 0, 0, 0, 0, 0, 1);

        // Directed error checks: duplicate ID, duplicate ack, and timeout.
        apply_cycle(1, 6'h2a, 4'b0001, 0, 0, 0, 0);
        apply_cycle(1, 6'h2a, 4'b0010, 0, 0, 0, 0);
        apply_cycle(0, 0, 0, 1, 6'h2a, 0, 0);
        apply_cycle(0, 0, 0, 1, 6'h2a, 0, 0);
        apply_cycle(1, 6'h31, 4'b1000, 0, 0, 0, 0);
        repeat (TIMEOUT_CYCLES + 1)
            apply_cycle(0, 0, 0, 0, 0, 0, 0);

        // Randomized traffic stresses table-full, alias, ack, and retire cases.
        repeat (500) begin
            apply_cycle(
                $urandom(seed) % 2,
                $urandom(seed) % 64,
                $urandom(seed) % 16,
                $urandom(seed) % 2,
                $urandom(seed) % 64,
                $urandom(seed) % NUM_AGENTS,
                $urandom(seed) % 2
            );
        end

        // One idle cycle exposes the final registered state to the checker/VCD.
        apply_cycle(0, 0, 0, 0, 0, 0, 1);
        $display("Completed %0d cycles and %0d self-checks", cycle_number, checks);
        $display("RESULT: *** PASS ***");
        $finish;
    end

endmodule
