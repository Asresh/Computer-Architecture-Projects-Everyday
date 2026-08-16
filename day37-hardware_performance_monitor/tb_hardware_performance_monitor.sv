// Author: Asresh Kuricheti
//
// Self-checking verification structure:
//   directed + random events --> DUT --> live/snapshot reads + overflow checks
//                                ^ independent cycle-accurate PMU reference model
`timescale 1ns/1ps
module tb_hardware_performance_monitor;
    localparam int NUM_EVENTS = 8;
    localparam int NUM_COUNTERS = 4;
    localparam int COUNTER_WIDTH = 8;
    localparam int RETIRE_WIDTH = 3;
    localparam int RANDOM_CYCLES = 500;

    logic clk = 0;
    logic reset_n, clear, clear_overflow, global_enable, freeze;
    logic [NUM_EVENTS-1:0] event_i;
    logic [RETIRE_WIDTH-1:0] retired_i;
    logic cfg_valid;
    logic [$clog2(NUM_COUNTERS)-1:0] cfg_index;
    logic [$clog2(NUM_EVENTS)-1:0] cfg_event_sel;
    logic cfg_counter_enable;
    logic snapshot, read_snapshot;
    logic [$clog2(NUM_COUNTERS+2)-1:0] read_index;
    logic [COUNTER_WIDTH-1:0] read_value, cycle_count, instruction_count;
    logic [NUM_COUNTERS+1:0] overflow;
    logic overflow_irq;

    logic [COUNTER_WIDTH-1:0] ref_event [0:NUM_COUNTERS-1];
    logic [COUNTER_WIDTH-1:0] ref_snapshot_event [0:NUM_COUNTERS-1];
    logic [$clog2(NUM_EVENTS)-1:0] ref_sel [0:NUM_COUNTERS-1];
    logic [NUM_COUNTERS-1:0] ref_counter_enable;
    logic [COUNTER_WIDTH-1:0] ref_cycle, ref_instruction;
    logic [COUNTER_WIDTH-1:0] ref_snapshot_cycle, ref_snapshot_instruction;
    logic [NUM_COUNTERS+1:0] ref_overflow;
    integer errors, cycle, seed, i;
    integer unsigned next_instruction;
    logic [COUNTER_WIDTH-1:0] expected_read;

    hardware_performance_monitor #(
        .NUM_EVENTS(NUM_EVENTS),
        .NUM_COUNTERS(NUM_COUNTERS),
        .COUNTER_WIDTH(COUNTER_WIDTH),
        .RETIRE_WIDTH(RETIRE_WIDTH)
    ) dut (.*);

    always #5 clk = ~clk;

    task automatic fail(input string msg);
        begin
            $display("ERROR cycle %0d: %s", cycle, msg);
            errors = errors + 1;
        end
    endtask

    task automatic check_outputs;
        begin
            if (cycle_count !== ref_cycle) fail("cycle counter mismatch");
            if (instruction_count !== ref_instruction) fail("instruction counter mismatch");
            if (overflow !== ref_overflow) fail("overflow vector mismatch");
            if (overflow_irq !== (|ref_overflow)) fail("overflow IRQ mismatch");

            expected_read = '0;
            if (read_index == 0)
                expected_read = read_snapshot ? ref_snapshot_cycle : ref_cycle;
            else if (read_index == 1)
                expected_read = read_snapshot ? ref_snapshot_instruction : ref_instruction;
            else if ((read_index >= 2) && (read_index < NUM_COUNTERS + 2))
                expected_read = read_snapshot ? ref_snapshot_event[read_index-2]
                                              : ref_event[read_index-2];
            if (read_value !== expected_read) fail("read port mismatch");
        end
    endtask

    task automatic model_edge;
        integer j;
        begin
            if (clear) begin
                ref_cycle = '0;
                ref_instruction = '0;
                ref_overflow = '0;
                for (j = 0; j < NUM_COUNTERS; j = j + 1)
                    ref_event[j] = '0;
            end else begin
                if (clear_overflow)
                    ref_overflow = '0;

                if (snapshot) begin
                    ref_snapshot_cycle = ref_cycle;
                    ref_snapshot_instruction = ref_instruction;
                    for (j = 0; j < NUM_COUNTERS; j = j + 1)
                        ref_snapshot_event[j] = ref_event[j];
                end

                if (global_enable && !freeze) begin
                    if (ref_cycle == {COUNTER_WIDTH{1'b1}})
                        ref_overflow[NUM_COUNTERS] = 1'b1;
                    ref_cycle = ref_cycle + 1'b1;

                    next_instruction = ref_instruction + retired_i;
                    if (next_instruction > {COUNTER_WIDTH{1'b1}})
                        ref_overflow[NUM_COUNTERS+1] = 1'b1;
                    ref_instruction = next_instruction[COUNTER_WIDTH-1:0];

                    for (j = 0; j < NUM_COUNTERS; j = j + 1) begin
                        if (ref_counter_enable[j] && (ref_sel[j] < NUM_EVENTS) &&
                            event_i[ref_sel[j]]) begin
                            if (ref_event[j] == {COUNTER_WIDTH{1'b1}})
                                ref_overflow[j] = 1'b1;
                            ref_event[j] = ref_event[j] + 1'b1;
                        end
                    end
                end

                // RTL nonblocking assignments make new programming effective next cycle.
                if (cfg_valid && (cfg_index < NUM_COUNTERS)) begin
                    ref_sel[cfg_index] = cfg_event_sel;
                    ref_counter_enable[cfg_index] = cfg_counter_enable;
                end
            end
        end
    endtask

    task automatic drive_cycle(
        input logic do_clear,
        input logic do_clear_overflow,
        input logic do_enable,
        input logic do_freeze,
        input logic [NUM_EVENTS-1:0] events,
        input logic [RETIRE_WIDTH-1:0] retired,
        input logic do_cfg,
        input integer cfg_slot,
        input integer cfg_event,
        input logic cfg_en,
        input logic do_snapshot,
        input logic use_snapshot,
        input integer read_slot
    );
        begin
            @(negedge clk);
            clear = do_clear;
            clear_overflow = do_clear_overflow;
            global_enable = do_enable;
            freeze = do_freeze;
            event_i = events;
            retired_i = retired;
            cfg_valid = do_cfg;
            cfg_index = cfg_slot;
            cfg_event_sel = cfg_event;
            cfg_counter_enable = cfg_en;
            snapshot = do_snapshot;
            read_snapshot = use_snapshot;
            read_index = read_slot;
            #1 check_outputs();
            @(posedge clk);
            model_edge();
            cycle = cycle + 1;
        end
    endtask

    initial begin
        $dumpfile("hardware_performance_monitor.vcd");
        $dumpvars(0, tb_hardware_performance_monitor);
        errors = 0;
        cycle = 0;
        seed = 32'h37c0ffee;
        ref_cycle = '0;
        ref_instruction = '0;
        ref_overflow = '0;
        ref_counter_enable = '0;
        ref_snapshot_cycle = '0;
        ref_snapshot_instruction = '0;
        for (i = 0; i < NUM_COUNTERS; i = i + 1) begin
            ref_event[i] = '0;
            ref_snapshot_event[i] = '0;
            ref_sel[i] = '0;
        end

        reset_n = 0;
        clear = 0;
        clear_overflow = 0;
        global_enable = 0;
        freeze = 0;
        event_i = '0;
        retired_i = '0;
        cfg_valid = 0;
        cfg_index = '0;
        cfg_event_sel = '0;
        cfg_counter_enable = 0;
        snapshot = 0;
        read_snapshot = 0;
        read_index = 0;
        repeat (3) @(posedge clk);
        reset_n = 1;

        // Directed: map four counters to cache miss, branch miss, stall, and load events.
        for (i = 0; i < NUM_COUNTERS; i = i + 1)
            drive_cycle(0, 0, 0, 0, '0, 0, 1, i, i, 1, 0, 0, i+2);

        drive_cycle(0, 0, 1, 0, 8'b0000_0001, 2, 0, 0, 0, 0, 0, 0, 2);
        drive_cycle(0, 0, 1, 0, 8'b0000_1011, 3, 0, 0, 0, 0, 0, 0, 3);
        drive_cycle(0, 0, 1, 1, 8'b0000_1111, 4, 0, 0, 0, 0, 0, 0, 4); // frozen
        drive_cycle(0, 0, 1, 0, 8'b0000_0100, 1, 0, 0, 0, 0, 1, 0, 5); // atomic snapshot
        drive_cycle(0, 0, 1, 0, 8'b0000_1000, 2, 0, 0, 0, 0, 0, 1, 0); // read frozen snapshot
        drive_cycle(0, 0, 1, 0, 8'b0000_0010, 1, 1, 1, 6, 1, 0, 0, 3); // reprogram slot 1
        drive_cycle(0, 0, 1, 0, 8'b0100_0000, 1, 0, 0, 0, 0, 0, 0, 3);
        drive_cycle(1, 0, 1, 0, 8'hff, 7, 0, 0, 0, 0, 0, 0, 0); // clear wins

        // Force wraparound and sticky overflow in event, cycle, and instruction counters.
        drive_cycle(0, 0, 0, 0, '0, 0, 1, 0, 0, 1, 0, 0, 2);
        for (i = 0; i < 260; i = i + 1)
            drive_cycle(0, 0, 1, 0, 8'b0000_0001, 7, 0, 0, 0, 0,
                        (i == 120), 0, (i % (NUM_COUNTERS+2)));
        drive_cycle(0, 1, 0, 0, '0, 0, 0, 0, 0, 0, 0, 0, 0);

        // Randomized configuration, gating, snapshots, events, reads, and clears.
        for (i = 0; i < RANDOM_CYCLES; i = i + 1) begin
            drive_cycle(($urandom(seed) % 211) == 0,
                        ($urandom(seed) % 97) == 0,
                        ($urandom(seed) % 5) != 0,
                        ($urandom(seed) % 11) == 0,
                        $urandom(seed),
                        $urandom(seed) % 5,
                        ($urandom(seed) % 23) == 0,
                        $urandom(seed) % NUM_COUNTERS,
                        $urandom(seed) % NUM_EVENTS,
                        $urandom(seed) & 1,
                        ($urandom(seed) % 31) == 0,
                        $urandom(seed) & 1,
                        $urandom(seed) % (NUM_COUNTERS + 2));
        end

        @(negedge clk);
        #1 check_outputs();
        if (errors == 0) begin
            $display("Checked %0d directed/randomized PMU cycles", cycle);
            $display("RESULT: *** PASS ***");
        end else begin
            $display("RESULT: *** FAIL *** (%0d errors)", errors);
            $fatal(1);
        end
        $finish;
    end

    initial begin
        #30000;
        $fatal(1, "TIMEOUT: testbench did not complete");
    end
endmodule
