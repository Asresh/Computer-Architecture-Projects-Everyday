// Author: Asresh Kuricheti
//
// Dual-issue instruction fetch queue
//
//   fetch lanes --> [ circular queue: PC | instruction | prediction ] --> decode
//                         ^ flush discards all speculative entries
`timescale 1ns/1ps
module instruction_fetch_queue #(
    parameter int DEPTH = 8,
    parameter int PC_WIDTH = 32,
    parameter int INSTR_WIDTH = 32
) (
    input  logic                   clk,
    input  logic                   reset_n,
    input  logic                   flush,

    input  logic [1:0]             enq_valid,
    output logic [1:0]             enq_ready,
    input  logic [PC_WIDTH-1:0]    enq_pc [0:1],
    input  logic [INSTR_WIDTH-1:0] enq_instr [0:1],
    input  logic [1:0]             enq_pred_taken,
    input  logic [PC_WIDTH-1:0]    enq_pred_target [0:1],

    output logic [1:0]             deq_valid,
    input  logic [1:0]             deq_ready,
    output logic [PC_WIDTH-1:0]    deq_pc [0:1],
    output logic [INSTR_WIDTH-1:0] deq_instr [0:1],
    output logic [1:0]             deq_pred_taken,
    output logic [PC_WIDTH-1:0]    deq_pred_target [0:1],

    output logic [$clog2(DEPTH+1)-1:0] occupancy,
    output logic                   empty,
    output logic                   full
);
    localparam int PTR_W = (DEPTH <= 2) ? 1 : $clog2(DEPTH);
    localparam int CNT_W = $clog2(DEPTH + 1);

    logic [PC_WIDTH-1:0]    pc_mem [0:DEPTH-1];
    logic [INSTR_WIDTH-1:0] instr_mem [0:DEPTH-1];
    logic                   pred_taken_mem [0:DEPTH-1];
    logic [PC_WIDTH-1:0]    pred_target_mem [0:DEPTH-1];
    logic [PTR_W-1:0]       head_q, tail_q;
    logic [CNT_W-1:0]       count_q;

    logic [1:0] pop_count, push_count;
    logic [CNT_W:0] capacity_after_pop;
    integer head_plus_one, tail_plus_one;

    initial begin
        if (DEPTH < 2) $error("DEPTH must be at least two");
    end

    always_comb begin
        head_plus_one = (head_q == DEPTH-1) ? 0 : head_q + 1;
        tail_plus_one = (tail_q == DEPTH-1) ? 0 : tail_q + 1;

        deq_valid[0] = (count_q >= 1);
        deq_valid[1] = (count_q >= 2);
        deq_pc[0] = deq_valid[0] ? pc_mem[head_q] : '0;
        deq_instr[0] = deq_valid[0] ? instr_mem[head_q] : '0;
        deq_pred_taken[0] = deq_valid[0] ? pred_taken_mem[head_q] : 1'b0;
        deq_pred_target[0] = deq_valid[0] ? pred_target_mem[head_q] : '0;
        deq_pc[1] = deq_valid[1] ? pc_mem[head_plus_one] : '0;
        deq_instr[1] = deq_valid[1] ? instr_mem[head_plus_one] : '0;
        deq_pred_taken[1] = deq_valid[1] ? pred_taken_mem[head_plus_one] : 1'b0;
        deq_pred_target[1] = deq_valid[1] ? pred_target_mem[head_plus_one] : '0;

        pop_count = 0;
        if (deq_valid[0] && deq_ready[0]) begin
            pop_count = 1;
            if (deq_valid[1] && deq_ready[1]) pop_count = 2;
        end

        capacity_after_pop = DEPTH - count_q + pop_count;
        enq_ready[0] = !flush && (capacity_after_pop >= 1);
        enq_ready[1] = !flush && (capacity_after_pop >= 2);
        push_count = 0;
        if (enq_valid[0] && enq_ready[0]) begin
            push_count = 1;
            if (enq_valid[1] && enq_ready[1]) push_count = 2;
        end

        occupancy = count_q;
        empty = (count_q == 0);
        full = (count_q == DEPTH);
    end

    function automatic [PTR_W-1:0] advance_ptr(
        input logic [PTR_W-1:0] ptr,
        input logic [1:0] amount
    );
        integer sum;
        begin
            sum = ptr + amount;
            if (sum >= DEPTH) sum = sum - DEPTH;
            advance_ptr = sum[PTR_W-1:0];
        end
    endfunction

    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            head_q <= '0;
            tail_q <= '0;
            count_q <= '0;
        end else if (flush) begin
            head_q <= '0;
            tail_q <= '0;
            count_q <= '0;
        end else begin
            if (push_count >= 1) begin
                pc_mem[tail_q] <= enq_pc[0];
                instr_mem[tail_q] <= enq_instr[0];
                pred_taken_mem[tail_q] <= enq_pred_taken[0];
                pred_target_mem[tail_q] <= enq_pred_target[0];
            end
            if (push_count == 2) begin
                pc_mem[tail_plus_one] <= enq_pc[1];
                instr_mem[tail_plus_one] <= enq_instr[1];
                pred_taken_mem[tail_plus_one] <= enq_pred_taken[1];
                pred_target_mem[tail_plus_one] <= enq_pred_target[1];
            end
            head_q <= advance_ptr(head_q, pop_count);
            tail_q <= advance_ptr(tail_q, push_count);
            count_q <= count_q + push_count - pop_count;
        end
    end
endmodule
