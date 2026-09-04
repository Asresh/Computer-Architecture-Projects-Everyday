// Author: Asresh Kuricheti
// Outstanding coherence transaction tracker.
//
//   allocate(id, targets) ---> [ associative transaction table ] ---> completion
//                                      ^          |
//                                      |          +--> pending-agent masks
//                          snoop acknowledgements +--> timeout/protocol checks

`timescale 1ns/1ps

module coherence_transaction_tracker #(
    parameter integer ENTRIES        = 4,
    parameter integer NUM_AGENTS     = 4,
    parameter integer TXN_ID_WIDTH   = 8,
    parameter integer TIMEOUT_CYCLES = 16,
    parameter integer AGENT_WIDTH    = (NUM_AGENTS <= 1) ? 1 : $clog2(NUM_AGENTS),
    parameter integer COUNT_WIDTH    = (ENTRIES <= 1) ? 1 : $clog2(ENTRIES + 1),
    parameter integer AGE_WIDTH      = (TIMEOUT_CYCLES <= 2) ? 1 : $clog2(TIMEOUT_CYCLES)
) (
    input  logic                              clk,
    input  logic                              rst_n,

    input  logic                              alloc_valid,
    output logic                              alloc_ready,
    input  logic [TXN_ID_WIDTH-1:0]           alloc_txn_id,
    input  logic [NUM_AGENTS-1:0]             alloc_targets,

    input  logic                              ack_valid,
    input  logic [TXN_ID_WIDTH-1:0]           ack_txn_id,
    input  logic [AGENT_WIDTH-1:0]            ack_agent,

    output logic                              completion_valid,
    input  logic                              completion_ready,
    output logic [TXN_ID_WIDTH-1:0]           completion_txn_id,

    output logic                              full,
    output logic [COUNT_WIDTH-1:0]            outstanding_count,
    output logic [ENTRIES-1:0]                valid_entries,
    output logic [ENTRIES*NUM_AGENTS-1:0]     pending_masks_flat,
    output logic                              protocol_error,
    output logic                              timeout_error
);

    logic [ENTRIES-1:0]            valid_q;
    logic [TXN_ID_WIDTH-1:0]       txn_id_q [0:ENTRIES-1];
    logic [NUM_AGENTS-1:0]         pending_q [0:ENTRIES-1];
    logic [AGE_WIDTH-1:0]          age_q [0:ENTRIES-1];

    logic free_found;
    logic alloc_duplicate;
    logic ack_match;
    integer free_index;
    integer completion_index;
    integer ack_index;
    integer i;

    always_comb begin
        free_found          = 1'b0;
        free_index          = 0;
        alloc_duplicate     = 1'b0;
        ack_match           = 1'b0;
        ack_index           = 0;
        completion_valid    = 1'b0;
        completion_index    = 0;
        completion_txn_id   = '0;
        outstanding_count   = '0;
        valid_entries       = valid_q;
        pending_masks_flat  = '0;

        for (i = 0; i < ENTRIES; i = i + 1) begin
            pending_masks_flat[i*NUM_AGENTS +: NUM_AGENTS] = pending_q[i];
            if (valid_q[i]) begin
                outstanding_count = outstanding_count + 1'b1;
                if (txn_id_q[i] == alloc_txn_id)
                    alloc_duplicate = 1'b1;
                if (!ack_match && (txn_id_q[i] == ack_txn_id)) begin
                    ack_match = 1'b1;
                    ack_index = i;
                end
                if (!completion_valid && (pending_q[i] == '0)) begin
                    completion_valid  = 1'b1;
                    completion_index  = i;
                    completion_txn_id = txn_id_q[i];
                end
            end else if (!free_found) begin
                free_found = 1'b1;
                free_index = i;
            end
        end

        full        = !free_found;
        alloc_ready = free_found && (!alloc_valid || !alloc_duplicate);
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            valid_q        <= '0;
            protocol_error <= 1'b0;
            timeout_error  <= 1'b0;
            for (i = 0; i < ENTRIES; i = i + 1) begin
                txn_id_q[i]  <= '0;
                pending_q[i] <= '0;
                age_q[i]     <= '0;
            end
        end else begin
            if (alloc_valid && alloc_duplicate)
                protocol_error <= 1'b1;

            if (ack_valid) begin
                if (!ack_match || (ack_agent >= NUM_AGENTS)) begin
                    protocol_error <= 1'b1;
                end else if (!pending_q[ack_index][ack_agent]) begin
                    protocol_error <= 1'b1;
                end else begin
                    pending_q[ack_index][ack_agent] <= 1'b0;
                end
            end

            for (i = 0; i < ENTRIES; i = i + 1) begin
                if (completion_valid && completion_ready && (completion_index == i)) begin
                    valid_q[i]   <= 1'b0;
                    pending_q[i] <= '0;
                    age_q[i]     <= '0;
                end else if (valid_q[i] && (pending_q[i] != '0)) begin
                    if (age_q[i] >= TIMEOUT_CYCLES-1) begin
                        age_q[i]    <= age_q[i];
                        timeout_error <= 1'b1;
                    end else begin
                        age_q[i] <= age_q[i] + 1'b1;
                    end
                end
            end

            if (alloc_valid && alloc_ready) begin
                valid_q[free_index]   <= 1'b1;
                txn_id_q[free_index]  <= alloc_txn_id;
                pending_q[free_index] <= alloc_targets;
                age_q[free_index]     <= '0;
            end
        end
    end

endmodule
