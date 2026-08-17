// Author: Asresh Kuricheti
//
// Store-set memory-dependence predictor
//
//   load/store PC -> SSIT -> store-set ID -> LFST -> youngest in-flight store tag
//                         ^ violations train and merge sets
`timescale 1ns/1ps
module store_set_predictor #(
    parameter int PC_WIDTH      = 32,
    parameter int SSIT_ENTRIES  = 64,
    parameter int NUM_STORE_SETS = 16,
    parameter int ROB_TAG_WIDTH = 8,
    parameter int SSIT_INDEX_WIDTH = $clog2(SSIT_ENTRIES),
    parameter int SSID_WIDTH       = $clog2(NUM_STORE_SETS)
) (
    input  logic                     clk,
    input  logic                     reset_n,
    input  logic                     flush,

    input  logic                     lookup_valid,
    input  logic [PC_WIDTH-1:0]      load_pc,
    output logic                     dependence_predicted,
    output logic [ROB_TAG_WIDTH-1:0] predicted_store_tag,
    output logic                     lookup_ssid_valid,
    output logic [SSID_WIDTH-1:0]    lookup_ssid,

    input  logic                     store_dispatch_valid,
    input  logic [PC_WIDTH-1:0]      store_pc,
    input  logic [ROB_TAG_WIDTH-1:0] store_tag,

    input  logic                     store_retire_valid,
    input  logic [ROB_TAG_WIDTH-1:0] store_retire_tag,

    input  logic                     violation_valid,
    input  logic [PC_WIDTH-1:0]      violation_load_pc,
    input  logic [PC_WIDTH-1:0]      violation_store_pc
);
    logic [SSIT_ENTRIES-1:0] ssit_valid_q;
    logic [SSID_WIDTH-1:0] ssit_id_q [0:SSIT_ENTRIES-1];
    logic [NUM_STORE_SETS-1:0] lfst_valid_q;
    logic [ROB_TAG_WIDTH-1:0] lfst_tag_q [0:NUM_STORE_SETS-1];
    logic [SSID_WIDTH-1:0] next_ssid_q;

    logic [SSIT_INDEX_WIDTH-1:0] lookup_index;
    logic [SSIT_INDEX_WIDTH-1:0] dispatch_index;
    logic [SSIT_INDEX_WIDTH-1:0] violation_load_index;
    logic [SSIT_INDEX_WIDTH-1:0] violation_store_index;
    integer i;

    function automatic logic [SSIT_INDEX_WIDTH-1:0] pc_index(
        input logic [PC_WIDTH-1:0] pc
    );
        pc_index = pc[2 +: SSIT_INDEX_WIDTH] ^
                   pc[2 + SSIT_INDEX_WIDTH +: SSIT_INDEX_WIDTH];
    endfunction

    initial begin
        if (SSIT_ENTRIES < 2 || (SSIT_ENTRIES & (SSIT_ENTRIES-1)) != 0)
            $error("SSIT_ENTRIES must be a power of two and at least two");
        if (NUM_STORE_SETS < 2 || (NUM_STORE_SETS & (NUM_STORE_SETS-1)) != 0)
            $error("NUM_STORE_SETS must be a power of two and at least two");
        if (PC_WIDTH < 2 + 2*SSIT_INDEX_WIDTH)
            $error("PC_WIDTH is too small for the folded PC hash");
    end

    always_comb begin
        lookup_index = pc_index(load_pc);
        dispatch_index = pc_index(store_pc);
        violation_load_index = pc_index(violation_load_pc);
        violation_store_index = pc_index(violation_store_pc);

        lookup_ssid_valid = lookup_valid && ssit_valid_q[lookup_index];
        lookup_ssid = lookup_ssid_valid ? ssit_id_q[lookup_index] : '0;
        dependence_predicted = lookup_ssid_valid && lfst_valid_q[lookup_ssid];
        predicted_store_tag = dependence_predicted ? lfst_tag_q[lookup_ssid] : '0;
    end

    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            ssit_valid_q <= '0;
            lfst_valid_q <= '0;
            next_ssid_q <= '0;
            for (i = 0; i < SSIT_ENTRIES; i = i + 1)
                ssit_id_q[i] <= '0;
            for (i = 0; i < NUM_STORE_SETS; i = i + 1)
                lfst_tag_q[i] <= '0;
        end else begin
            // A pipeline recovery removes in-flight stores, but retains learning.
            if (flush) begin
                lfst_valid_q <= '0;
            end else begin
                // Retiring an older store must not clear a newer store in the set.
                if (store_retire_valid) begin
                    for (i = 0; i < NUM_STORE_SETS; i = i + 1)
                        if (lfst_valid_q[i] && lfst_tag_q[i] == store_retire_tag)
                            lfst_valid_q[i] <= 1'b0;
                end

                // A detected ordering violation trains or merges the two PCs.
                if (violation_valid) begin
                    if (!ssit_valid_q[violation_load_index] &&
                        !ssit_valid_q[violation_store_index]) begin
                        ssit_valid_q[violation_load_index] <= 1'b1;
                        ssit_valid_q[violation_store_index] <= 1'b1;
                        ssit_id_q[violation_load_index] <= next_ssid_q;
                        ssit_id_q[violation_store_index] <= next_ssid_q;
                        next_ssid_q <= next_ssid_q + 1'b1;
                    end else if (!ssit_valid_q[violation_load_index]) begin
                        ssit_valid_q[violation_load_index] <= 1'b1;
                        ssit_id_q[violation_load_index] <= ssit_id_q[violation_store_index];
                    end else if (!ssit_valid_q[violation_store_index]) begin
                        ssit_valid_q[violation_store_index] <= 1'b1;
                        ssit_id_q[violation_store_index] <= ssit_id_q[violation_load_index];
                    end else if (ssit_id_q[violation_load_index] !=
                                 ssit_id_q[violation_store_index]) begin
                        // Merge the load's complete store set into the store's set.
                        for (i = 0; i < SSIT_ENTRIES; i = i + 1)
                            if (ssit_valid_q[i] &&
                                ssit_id_q[i] == ssit_id_q[violation_load_index])
                                ssit_id_q[i] <= ssit_id_q[violation_store_index];

                        if (!lfst_valid_q[ssit_id_q[violation_store_index]] &&
                            lfst_valid_q[ssit_id_q[violation_load_index]]) begin
                            lfst_valid_q[ssit_id_q[violation_store_index]] <= 1'b1;
                            lfst_tag_q[ssit_id_q[violation_store_index]] <=
                                lfst_tag_q[ssit_id_q[violation_load_index]];
                        end
                        lfst_valid_q[ssit_id_q[violation_load_index]] <= 1'b0;
                    end
                end

                // Dispatch updates the youngest in-flight store for a trained PC.
                // This assignment is last so a newly dispatched store wins over
                // retirement or set-merge maintenance in the same cycle.
                if (store_dispatch_valid && ssit_valid_q[dispatch_index]) begin
                    lfst_valid_q[ssit_id_q[dispatch_index]] <= 1'b1;
                    lfst_tag_q[ssit_id_q[dispatch_index]] <= store_tag;
                end
            end
        end
    end
endmodule
