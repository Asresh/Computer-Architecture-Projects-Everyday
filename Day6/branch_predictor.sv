// branch_predictor.sv - Day6
//
// Bimodal (PC-indexed) dynamic branch predictor built from an array of
// 2-bit saturating counters -- the "gshare-less" baseline every branch
// predictor is measured against.
//
// A Pattern History Table (PHT) holds 2**INDEX_BITS two-bit saturating
// counters. The counter is indexed by the low branch-address bits (the byte
// offset PC[1:0] is dropped because RV32 instructions are word aligned):
//
//     index = pc[INDEX_BITS+1 : 2]
//
// Each counter is a 4-state saturating FSM:
//
//     00 = Strongly  Not-Taken (SN)
//     01 = Weakly    Not-Taken (WN)
//     10 = Weakly    Taken     (WT)
//     11 = Strongly  Taken     (ST)
//
// Prediction is the counter MSB: taken when counter >= 2 (10 or 11).
// After a branch resolves, the counter at its index moves one step toward
// the actual outcome (taken -> +1 saturating at 11, not-taken -> -1
// saturating at 00). The two-bit hysteresis is the whole point: a single
// surprising outcome only weakens the prediction, it does not flip it, so a
// mostly-taken loop branch mispredicts only on the one iteration it exits.
//
// The predict port (fetch stage) and the update port (execute/retire stage)
// are independent so the same table can be queried for one PC while being
// trained by another -- exactly how it sits in a pipeline.
//
// Synthesizable, reset-safe, parameterized, and lint clean.

`timescale 1ns/1ps

module branch_predictor #(
    parameter int XLEN       = 32,  // program-counter width
    parameter int INDEX_BITS = 4,   // PHT has 2**INDEX_BITS counters
    // Counter reset state. 2'b01 = weakly not-taken is the conventional
    // cold-start value (predict not-taken until proven otherwise).
    parameter logic [1:0] RESET_STATE = 2'b01
) (
    input  logic            clk,
    input  logic            rst_n,

    // ---- Prediction port (combinational, fetch stage) ----
    input  logic [XLEN-1:0] pc_predict,
    output logic            predict_taken,

    // ---- Update port (synchronous, resolve stage) ----
    input  logic            update_en,
    input  logic [XLEN-1:0] pc_update,
    input  logic            actual_taken,

    // ---- Debug / observation (for waveform + verification) ----
    output logic [INDEX_BITS-1:0] dbg_predict_index,
    output logic [INDEX_BITS-1:0] dbg_update_index,
    output logic [1:0]            dbg_update_counter // counter value BEFORE update
);

    localparam int NUM_ENTRIES = 1 << INDEX_BITS;

    // Pattern History Table of 2-bit saturating counters.
    logic [1:0] pht [NUM_ENTRIES-1:0];

    // Word-aligned index extraction (drop the byte offset PC[1:0]).
    logic [INDEX_BITS-1:0] pidx;
    logic [INDEX_BITS-1:0] uidx;

    assign pidx = pc_predict[INDEX_BITS+1 : 2];
    assign uidx = pc_update [INDEX_BITS+1 : 2];

    // ---- Prediction: taken iff the selected counter's MSB is set ----
    assign predict_taken = pht[pidx][1];

    // ---- Saturating next-state for the counter being updated ----
    logic [1:0] cur;
    logic [1:0] nxt;

    assign cur = pht[uidx];

    always_comb begin
        nxt = cur;
        if (actual_taken) begin
            // move toward Strongly Taken (11), saturate
            if (cur != 2'b11)
                nxt = cur + 2'b01;
        end else begin
            // move toward Strongly Not-Taken (00), saturate
            if (cur != 2'b00)
                nxt = cur - 2'b01;
        end
    end

    // ---- Synchronous state ----
    integer i;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (i = 0; i < NUM_ENTRIES; i = i + 1)
                pht[i] <= RESET_STATE;
        end else if (update_en) begin
            pht[uidx] <= nxt;
        end
    end

    // ---- Debug taps ----
    assign dbg_predict_index  = pidx;
    assign dbg_update_index   = uidx;
    assign dbg_update_counter = cur;

endmodule
