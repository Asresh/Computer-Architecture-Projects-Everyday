// Author: Asresh Kuricheti
// Credit-based virtual-channel scheduler for a packet-switched interconnect.
//
//   requesters ---> [credit filter] ---> [round-robin select] ---> grant
//                         ^                         |
//                         |                         v
//                  returned credits <--- per-VC credit counters

`timescale 1ns/1ps

module credit_based_vc_scheduler #(
    parameter integer NUM_VCS      = 4,
    parameter integer BUFFER_DEPTH = 4,
    parameter integer VC_BITS      = (NUM_VCS <= 1) ? 1 : $clog2(NUM_VCS),
    parameter integer CREDIT_BITS  = $clog2(BUFFER_DEPTH + 1)
) (
    input  logic                         clk,
    input  logic                         rst_n,
    input  logic [NUM_VCS-1:0]           req_valid,
    input  logic                         grant_ready,
    input  logic                         credit_return_valid,
    input  logic [VC_BITS-1:0]           credit_return_vc,
    output logic                         grant_valid,
    output logic [NUM_VCS-1:0]           grant_onehot,
    output logic [VC_BITS-1:0]           grant_vc,
    output logic [NUM_VCS-1:0]           credit_available,
    output logic [NUM_VCS*CREDIT_BITS-1:0] credit_count_flat,
    output logic                         protocol_error
);

    logic [CREDIT_BITS-1:0] credit_count [0:NUM_VCS-1];
    logic [VC_BITS-1:0]     rr_pointer;
    integer                 offset;
    integer                 index;
    integer                 vc;

    always_comb begin
        grant_valid     = 1'b0;
        grant_onehot    = '0;
        grant_vc        = '0;
        credit_available = '0;
        credit_count_flat = '0;

        for (vc = 0; vc < NUM_VCS; vc = vc + 1) begin
            credit_available[vc] = (credit_count[vc] != 0);
            credit_count_flat[vc*CREDIT_BITS +: CREDIT_BITS] = credit_count[vc];
        end

        // Search once around the ring, beginning at the rotating priority.
        for (offset = 0; offset < NUM_VCS; offset = offset + 1) begin
            index = rr_pointer + offset;
            if (index >= NUM_VCS)
                index = index - NUM_VCS;
            if (!grant_valid && req_valid[index] && credit_available[index]) begin
                grant_valid          = 1'b1;
                grant_onehot[index]  = 1'b1;
                grant_vc             = index[VC_BITS-1:0];
            end
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rr_pointer    <= '0;
            protocol_error <= 1'b0;
            for (vc = 0; vc < NUM_VCS; vc = vc + 1)
                credit_count[vc] <= BUFFER_DEPTH[CREDIT_BITS-1:0];
        end else begin
            // A successful grant consumes one downstream buffer slot.
            if (grant_valid && grant_ready) begin
                if (grant_vc == NUM_VCS-1)
                    rr_pointer <= '0;
                else
                    rr_pointer <= grant_vc + 1'b1;
            end

            for (vc = 0; vc < NUM_VCS; vc = vc + 1) begin
                if ((grant_valid && grant_ready && (grant_vc == vc)) &&
                    (credit_return_valid && (credit_return_vc == vc))) begin
                    // One slot is consumed while another is returned: net zero.
                    credit_count[vc] <= credit_count[vc];
                end else if (grant_valid && grant_ready && (grant_vc == vc)) begin
                    credit_count[vc] <= credit_count[vc] - 1'b1;
                end else if (credit_return_valid && (credit_return_vc == vc)) begin
                    if (credit_count[vc] < BUFFER_DEPTH)
                        credit_count[vc] <= credit_count[vc] + 1'b1;
                    else
                        protocol_error <= 1'b1;
                end
            end

            if (credit_return_valid && (credit_return_vc >= NUM_VCS))
                protocol_error <= 1'b1;
        end
    end

endmodule
