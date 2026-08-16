// Author: Asresh Kuricheti
//
// Self-checking verification structure:
//   directed + random stimulus --> DUT --> compare every visible entry/status
//                                  ^ independent circular-queue reference model
`timescale 1ns/1ps
module tb_instruction_fetch_queue;
    localparam int DEPTH = 8;
    localparam int CYCLES = 500;

    logic clk = 0;
    logic reset_n, flush;
    logic [1:0] enq_valid, enq_ready;
    logic [31:0] enq_pc [0:1], enq_instr [0:1];
    logic [1:0] enq_pred_taken;
    logic [31:0] enq_pred_target [0:1];
    logic [1:0] deq_valid, deq_ready;
    logic [31:0] deq_pc [0:1], deq_instr [0:1];
    logic [1:0] deq_pred_taken;
    logic [31:0] deq_pred_target [0:1];
    logic [$clog2(DEPTH+1)-1:0] occupancy;
    logic empty, full;

    logic [31:0] ref_pc [0:DEPTH-1], ref_instr [0:DEPTH-1];
    logic ref_taken [0:DEPTH-1];
    logic [31:0] ref_target [0:DEPTH-1];
    integer ref_head, ref_tail, ref_count;
    integer errors, accepted, delivered, cycle, seed;
    integer expected_pop, expected_push, idx1;

    instruction_fetch_queue #(.DEPTH(DEPTH)) dut (.*);
    always #5 clk = ~clk;

    task automatic fail(input string msg);
        begin
            $display("ERROR cycle %0d: %s", cycle, msg);
            errors = errors + 1;
        end
    endtask

    task automatic check_outputs;
        integer second;
        begin
            second = (ref_head + 1) % DEPTH;
            if (occupancy !== ref_count) fail("occupancy mismatch");
            if (empty !== (ref_count == 0)) fail("empty mismatch");
            if (full !== (ref_count == DEPTH)) fail("full mismatch");
            if (deq_valid[0] !== (ref_count >= 1)) fail("lane 0 valid mismatch");
            if (deq_valid[1] !== (ref_count >= 2)) fail("lane 1 valid mismatch");
            if (ref_count >= 1) begin
                if (deq_pc[0] !== ref_pc[ref_head]) fail("lane 0 PC mismatch");
                if (deq_instr[0] !== ref_instr[ref_head]) fail("lane 0 instruction mismatch");
                if (deq_pred_taken[0] !== ref_taken[ref_head]) fail("lane 0 prediction mismatch");
                if (deq_pred_target[0] !== ref_target[ref_head]) fail("lane 0 target mismatch");
            end
            if (ref_count >= 2) begin
                if (deq_pc[1] !== ref_pc[second]) fail("lane 1 PC mismatch");
                if (deq_instr[1] !== ref_instr[second]) fail("lane 1 instruction mismatch");
                if (deq_pred_taken[1] !== ref_taken[second]) fail("lane 1 prediction mismatch");
                if (deq_pred_target[1] !== ref_target[second]) fail("lane 1 target mismatch");
            end
        end
    endtask

    task automatic model_edge;
        begin
            if (flush) begin
                ref_head = 0;
                ref_tail = 0;
                ref_count = 0;
            end else begin
                expected_pop = 0;
                if ((ref_count >= 1) && deq_ready[0]) begin
                    expected_pop = 1;
                    if ((ref_count >= 2) && deq_ready[1]) expected_pop = 2;
                end
                expected_push = 0;
                if (enq_valid[0] && enq_ready[0]) begin
                    expected_push = 1;
                    if (enq_valid[1] && enq_ready[1]) expected_push = 2;
                end
                if (expected_push >= 1) begin
                    ref_pc[ref_tail] = enq_pc[0];
                    ref_instr[ref_tail] = enq_instr[0];
                    ref_taken[ref_tail] = enq_pred_taken[0];
                    ref_target[ref_tail] = enq_pred_target[0];
                end
                if (expected_push == 2) begin
                    idx1 = (ref_tail + 1) % DEPTH;
                    ref_pc[idx1] = enq_pc[1];
                    ref_instr[idx1] = enq_instr[1];
                    ref_taken[idx1] = enq_pred_taken[1];
                    ref_target[idx1] = enq_pred_target[1];
                end
                ref_head = (ref_head + expected_pop) % DEPTH;
                ref_tail = (ref_tail + expected_push) % DEPTH;
                ref_count = ref_count + expected_push - expected_pop;
                accepted = accepted + expected_push;
                delivered = delivered + expected_pop;
            end
        end
    endtask

    task automatic drive_cycle(
        input logic do_flush,
        input logic [1:0] ev,
        input logic [1:0] dr,
        input logic [31:0] tag
    );
        begin
            @(negedge clk);
            flush = do_flush;
            enq_valid = ev;
            deq_ready = dr;
            enq_pc[0] = tag;
            enq_pc[1] = tag + 4;
            enq_instr[0] = 32'h1000_0000 ^ tag;
            enq_instr[1] = 32'h2000_0000 ^ tag;
            enq_pred_taken = {tag[3], tag[2]};
            enq_pred_target[0] = tag + 32'h40;
            enq_pred_target[1] = tag + 32'h80;
            #1 check_outputs();
            @(posedge clk);
            model_edge();
            cycle = cycle + 1;
        end
    endtask

    initial begin
        $dumpfile("instruction_fetch_queue.vcd");
        $dumpvars(0, tb_instruction_fetch_queue);
        errors = 0; accepted = 0; delivered = 0; cycle = 0; seed = 32'h36f37c01;
        ref_head = 0; ref_tail = 0; ref_count = 0;
        reset_n = 0; flush = 0; enq_valid = 0; deq_ready = 0;
        enq_pc[0] = 0; enq_pc[1] = 0; enq_instr[0] = 0; enq_instr[1] = 0;
        enq_pred_taken = 0; enq_pred_target[0] = 0; enq_pred_target[1] = 0;
        repeat (3) @(posedge clk);
        reset_n = 1;

        // Directed: fill with dual fetch, stall, drain two, wrap, and flush.
        drive_cycle(0, 2'b11, 2'b00, 32'h1000);
        drive_cycle(0, 2'b11, 2'b00, 32'h1008);
        drive_cycle(0, 2'b11, 2'b00, 32'h1010);
        drive_cycle(0, 2'b11, 2'b00, 32'h1018);
        drive_cycle(0, 2'b11, 2'b00, 32'h1020); // full: rejected
        drive_cycle(0, 2'b11, 2'b11, 32'h1028); // simultaneous pop/push
        drive_cycle(0, 2'b00, 2'b11, 32'h0000);
        drive_cycle(0, 2'b00, 2'b01, 32'h0000);
        drive_cycle(1, 2'b11, 2'b11, 32'h2000); // redirect kills both sides
        drive_cycle(0, 2'b01, 2'b00, 32'h3000);
        drive_cycle(0, 2'b00, 2'b11, 32'h0000); // lane 1 cannot pop alone

        for (integer n = 0; n < CYCLES; n = n + 1) begin
            drive_cycle(($urandom(seed) % 67) == 0,
                        ($urandom(seed) % 4),
                        ($urandom(seed) % 4),
                        32'h4000 + n*8);
        end

        // Flush remaining speculation so conservation can be checked thereafter.
        drive_cycle(1, 2'b00, 2'b00, 0);
        #1 check_outputs();
        if (errors == 0) begin
            $display("Accepted=%0d Delivered=%0d (flushes may discard entries)", accepted, delivered);
            $display("RESULT: *** PASS ***");
        end else begin
            $display("RESULT: *** FAIL *** (%0d errors)", errors);
            $fatal(1);
        end
        $finish;
    end

    initial begin
        #20000;
        $fatal(1, "TIMEOUT: testbench did not complete");
    end
endmodule
