// Author: Asresh Kuricheti
//
// Programmable hardware performance monitor (PMU)
//
//   microarchitectural events --> selector bank --> event counters --> snapshot/read
//   clock + retired instructions ----------------> fixed counters --> overflow IRQ
`timescale 1ns/1ps
module hardware_performance_monitor #(
    parameter int NUM_EVENTS       = 8,
    parameter int NUM_COUNTERS     = 4,
    parameter int COUNTER_WIDTH    = 32,
    parameter int RETIRE_WIDTH     = 3,
    parameter int EVENT_SEL_WIDTH  = (NUM_EVENTS <= 1) ? 1 : $clog2(NUM_EVENTS),
    parameter int CFG_INDEX_WIDTH  = (NUM_COUNTERS <= 1) ? 1 : $clog2(NUM_COUNTERS),
    parameter int READ_INDEX_WIDTH = (NUM_COUNTERS + 2 <= 2) ? 1 : $clog2(NUM_COUNTERS + 2)
) (
    input  logic                        clk,
    input  logic                        reset_n,
    input  logic                        clear,
    input  logic                        clear_overflow,
    input  logic                        global_enable,
    input  logic                        freeze,

    input  logic [NUM_EVENTS-1:0]       event_i,
    input  logic [RETIRE_WIDTH-1:0]     retired_i,

    input  logic                        cfg_valid,
    input  logic [CFG_INDEX_WIDTH-1:0]  cfg_index,
    input  logic [EVENT_SEL_WIDTH-1:0]  cfg_event_sel,
    input  logic                        cfg_counter_enable,

    input  logic                        snapshot,
    input  logic                        read_snapshot,
    input  logic [READ_INDEX_WIDTH-1:0] read_index,
    output logic [COUNTER_WIDTH-1:0]    read_value,

    output logic [COUNTER_WIDTH-1:0]    cycle_count,
    output logic [COUNTER_WIDTH-1:0]    instruction_count,
    output logic [NUM_COUNTERS+1:0]     overflow,
    output logic                        overflow_irq
);
    localparam logic [COUNTER_WIDTH-1:0] COUNTER_MAX = {COUNTER_WIDTH{1'b1}};

    logic [EVENT_SEL_WIDTH-1:0] event_sel_q [0:NUM_COUNTERS-1];
    logic [NUM_COUNTERS-1:0] counter_enable_q;
    logic [COUNTER_WIDTH-1:0] event_counter_q [0:NUM_COUNTERS-1];
    logic [COUNTER_WIDTH-1:0] cycle_count_q, instruction_count_q;
    logic [NUM_COUNTERS+1:0] overflow_q;

    logic [COUNTER_WIDTH-1:0] snapshot_counter_q [0:NUM_COUNTERS-1];
    logic [COUNTER_WIDTH-1:0] snapshot_cycle_q, snapshot_instruction_q;
    logic [COUNTER_WIDTH:0] instruction_sum;
    integer i;

    initial begin
        if (NUM_EVENTS < 1) $error("NUM_EVENTS must be at least one");
        if (NUM_COUNTERS < 1) $error("NUM_COUNTERS must be at least one");
        if (COUNTER_WIDTH < RETIRE_WIDTH) $error("COUNTER_WIDTH must cover RETIRE_WIDTH");
    end

    always_comb begin
        instruction_sum = {1'b0, instruction_count_q} + retired_i;
        cycle_count = cycle_count_q;
        instruction_count = instruction_count_q;
        overflow = overflow_q;
        overflow_irq = |overflow_q;

        read_value = '0;
        if (read_index == 0) begin
            read_value = read_snapshot ? snapshot_cycle_q : cycle_count_q;
        end else if (read_index == 1) begin
            read_value = read_snapshot ? snapshot_instruction_q : instruction_count_q;
        end else if ((read_index >= 2) && (read_index < NUM_COUNTERS + 2)) begin
            read_value = read_snapshot ? snapshot_counter_q[read_index-2]
                                       : event_counter_q[read_index-2];
        end
    end

    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            cycle_count_q <= '0;
            instruction_count_q <= '0;
            overflow_q <= '0;
            counter_enable_q <= '0;
            snapshot_cycle_q <= '0;
            snapshot_instruction_q <= '0;
            for (i = 0; i < NUM_COUNTERS; i = i + 1) begin
                event_sel_q[i] <= '0;
                event_counter_q[i] <= '0;
                snapshot_counter_q[i] <= '0;
            end
        end else if (clear) begin
            cycle_count_q <= '0;
            instruction_count_q <= '0;
            overflow_q <= '0;
            for (i = 0; i < NUM_COUNTERS; i = i + 1)
                event_counter_q[i] <= '0;
        end else begin
            if (clear_overflow)
                overflow_q <= '0;

            if (cfg_valid && (cfg_index < NUM_COUNTERS)) begin
                event_sel_q[cfg_index] <= cfg_event_sel;
                counter_enable_q[cfg_index] <= cfg_counter_enable;
            end

            if (snapshot) begin
                snapshot_cycle_q <= cycle_count_q;
                snapshot_instruction_q <= instruction_count_q;
                for (i = 0; i < NUM_COUNTERS; i = i + 1)
                    snapshot_counter_q[i] <= event_counter_q[i];
            end

            if (global_enable && !freeze) begin
                cycle_count_q <= cycle_count_q + {{(COUNTER_WIDTH-1){1'b0}}, 1'b1};
                if (cycle_count_q == COUNTER_MAX)
                    overflow_q[NUM_COUNTERS] <= 1'b1;

                instruction_count_q <= instruction_sum[COUNTER_WIDTH-1:0];
                if (instruction_sum[COUNTER_WIDTH])
                    overflow_q[NUM_COUNTERS+1] <= 1'b1;

                for (i = 0; i < NUM_COUNTERS; i = i + 1) begin
                    if (counter_enable_q[i] && (event_sel_q[i] < NUM_EVENTS) &&
                        event_i[event_sel_q[i]]) begin
                        event_counter_q[i] <= event_counter_q[i] +
                                              {{(COUNTER_WIDTH-1){1'b0}}, 1'b1};
                        if (event_counter_q[i] == COUNTER_MAX)
                            overflow_q[i] <= 1'b1;
                    end
                end
            end
        end
    end
endmodule
