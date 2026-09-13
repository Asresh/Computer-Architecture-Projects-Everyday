// Author: Asresh Kuricheti
// Single-entry directory-based coherence home agent.
//
//   requester ---> [ directory + transaction FSM ] ---> response
//                         |                 ^
//                         +--> probes       +--> memory refill

`timescale 1ns/1ps

module coherence_home_agent #(
    parameter integer NUM_AGENTS   = 4,
    parameter integer ADDR_WIDTH   = 32,
    parameter integer DATA_WIDTH   = 64,
    parameter integer TXN_ID_WIDTH = 8,
    parameter integer AGENT_WIDTH  = (NUM_AGENTS <= 1) ? 1 : $clog2(NUM_AGENTS)
) (
    input  logic                         clk,
    input  logic                         rst_n,

    input  logic                         req_valid,
    output logic                         req_ready,
    input  logic [AGENT_WIDTH-1:0]       req_src,
    input  logic [TXN_ID_WIDTH-1:0]      req_txn_id,
    input  logic [ADDR_WIDTH-1:0]        req_addr,
    input  logic                         req_unique,

    output logic                         probe_valid,
    input  logic                         probe_ready,
    output logic [AGENT_WIDTH-1:0]       probe_target,
    output logic [ADDR_WIDTH-1:0]        probe_addr,
    output logic                         probe_invalidate,
    input  logic                         probe_ack_valid,
    input  logic [AGENT_WIDTH-1:0]       probe_ack_src,

    output logic                         mem_read_valid,
    input  logic                         mem_read_ready,
    output logic [ADDR_WIDTH-1:0]        mem_read_addr,
    input  logic                         mem_data_valid,
    input  logic [DATA_WIDTH-1:0]        mem_read_data,

    output logic                         rsp_valid,
    input  logic                         rsp_ready,
    output logic [AGENT_WIDTH-1:0]       rsp_dst,
    output logic [TXN_ID_WIDTH-1:0]      rsp_txn_id,
    output logic [DATA_WIDTH-1:0]        rsp_data,
    output logic                         rsp_grant_unique,

    output logic                         busy,
    output logic                         line_valid,
    output logic [ADDR_WIDTH-1:0]        line_addr,
    output logic [NUM_AGENTS-1:0]        line_sharers,
    output logic                         line_unique,
    output logic [2:0]                   state_debug,
    output logic                         protocol_error
);

    localparam logic [2:0] ST_IDLE     = 3'd0;
    localparam logic [2:0] ST_PROBE    = 3'd1;
    localparam logic [2:0] ST_MEM_REQ  = 3'd2;
    localparam logic [2:0] ST_MEM_WAIT = 3'd3;
    localparam logic [2:0] ST_RESPONSE = 3'd4;

    logic [2:0] state_q;
    logic line_valid_q;
    logic [ADDR_WIDTH-1:0] line_addr_q;
    logic [DATA_WIDTH-1:0] line_data_q;
    logic [NUM_AGENTS-1:0] sharers_q;
    logic unique_q;

    logic [AGENT_WIDTH-1:0] req_src_q;
    logic [TXN_ID_WIDTH-1:0] req_txn_id_q;
    logic [ADDR_WIDTH-1:0] req_addr_q;
    logic req_unique_q;
    logic need_memory_q;
    logic [NUM_AGENTS-1:0] pending_probes_q;
    logic probe_wait_q;
    logic [AGENT_WIDTH-1:0] probe_target_q;

    integer i;
    integer selected_probe;
    logic probe_found;
    logic request_hit;
    logic [NUM_AGENTS-1:0] requester_mask;
    logic [NUM_AGENTS-1:0] acknowledged_mask;

    always_comb begin
        requester_mask = '0;
        if (req_src < NUM_AGENTS)
            requester_mask[req_src] = 1'b1;
        acknowledged_mask = '0;
        if (probe_ack_src < NUM_AGENTS)
            acknowledged_mask[probe_ack_src] = 1'b1;

        request_hit = line_valid_q && (line_addr_q == req_addr);
        req_ready = (state_q == ST_IDLE) && (req_src < NUM_AGENTS);
        busy = (state_q != ST_IDLE);

        probe_found = 1'b0;
        selected_probe = 0;
        for (i = 0; i < NUM_AGENTS; i = i + 1) begin
            if (!probe_found && pending_probes_q[i]) begin
                probe_found = 1'b1;
                selected_probe = i;
            end
        end

        probe_valid = (state_q == ST_PROBE) && !probe_wait_q && probe_found;
        probe_target = selected_probe[AGENT_WIDTH-1:0];
        probe_addr = need_memory_q ? line_addr_q : req_addr_q;
        probe_invalidate = need_memory_q || req_unique_q;

        mem_read_valid = (state_q == ST_MEM_REQ);
        mem_read_addr = req_addr_q;

        rsp_valid = (state_q == ST_RESPONSE);
        rsp_dst = req_src_q;
        rsp_txn_id = req_txn_id_q;
        rsp_data = line_data_q;
        rsp_grant_unique = req_unique_q;

        line_valid = line_valid_q;
        line_addr = line_addr_q;
        line_sharers = sharers_q;
        line_unique = unique_q;
        state_debug = state_q;
    end

    always_ff @(posedge clk or negedge rst_n) begin
        logic [NUM_AGENTS-1:0] other_sharers;
        if (!rst_n) begin
            state_q          <= ST_IDLE;
            line_valid_q     <= 1'b0;
            line_addr_q      <= '0;
            line_data_q      <= '0;
            sharers_q        <= '0;
            unique_q         <= 1'b0;
            req_src_q        <= '0;
            req_txn_id_q     <= '0;
            req_addr_q       <= '0;
            req_unique_q     <= 1'b0;
            need_memory_q    <= 1'b0;
            pending_probes_q <= '0;
            probe_wait_q     <= 1'b0;
            probe_target_q   <= '0;
            protocol_error   <= 1'b0;
        end else begin
            if (probe_ack_valid) begin
                if ((state_q != ST_PROBE) || !probe_wait_q ||
                    (probe_ack_src != probe_target_q)) begin
                    protocol_error <= 1'b1;
                end else begin
                    pending_probes_q[probe_ack_src] <= 1'b0;
                    probe_wait_q <= 1'b0;
                    if ((pending_probes_q & ~acknowledged_mask) == '0) begin
                        if (need_memory_q) begin
                            sharers_q <= '0;
                            unique_q <= 1'b0;
                            line_valid_q <= 1'b0;
                            state_q <= ST_MEM_REQ;
                        end else begin
                            sharers_q <= ({{(NUM_AGENTS-1){1'b0}}, 1'b1} << req_src_q);
                            if (!req_unique_q)
                                sharers_q <= sharers_q |
                                    ({{(NUM_AGENTS-1){1'b0}}, 1'b1} << req_src_q);
                            unique_q <= req_unique_q;
                            state_q <= ST_RESPONSE;
                        end
                    end
                end
            end

            if ((state_q == ST_PROBE) && probe_valid && probe_ready) begin
                probe_wait_q <= 1'b1;
                probe_target_q <= probe_target;
            end

            if ((state_q == ST_IDLE) && req_valid) begin
                if (req_src >= NUM_AGENTS) begin
                    protocol_error <= 1'b1;
                end else begin
                    req_src_q    <= req_src;
                    req_txn_id_q <= req_txn_id;
                    req_addr_q   <= req_addr;
                    req_unique_q <= req_unique;
                    other_sharers = sharers_q & ~requester_mask;

                    if (!request_hit) begin
                        need_memory_q <= 1'b1;
                        pending_probes_q <= line_valid_q ? sharers_q : '0;
                        probe_wait_q <= 1'b0;
                        if (line_valid_q && (sharers_q != '0))
                            state_q <= ST_PROBE;
                        else
                            state_q <= ST_MEM_REQ;
                    end else if (req_unique && (other_sharers != '0)) begin
                        need_memory_q <= 1'b0;
                        pending_probes_q <= other_sharers;
                        probe_wait_q <= 1'b0;
                        state_q <= ST_PROBE;
                    end else if (!req_unique && unique_q && (other_sharers != '0)) begin
                        need_memory_q <= 1'b0;
                        pending_probes_q <= other_sharers;
                        probe_wait_q <= 1'b0;
                        state_q <= ST_PROBE;
                    end else begin
                        need_memory_q <= 1'b0;
                        if (req_unique) begin
                            sharers_q <= requester_mask;
                            unique_q <= 1'b1;
                        end else begin
                            sharers_q <= sharers_q | requester_mask;
                            unique_q <= 1'b0;
                        end
                        state_q <= ST_RESPONSE;
                    end
                end
            end

            if ((state_q == ST_MEM_REQ) && mem_read_valid && mem_read_ready)
                state_q <= ST_MEM_WAIT;

            if ((state_q == ST_MEM_WAIT) && mem_data_valid) begin
                line_valid_q <= 1'b1;
                line_addr_q <= req_addr_q;
                line_data_q <= mem_read_data;
                sharers_q <= ({{(NUM_AGENTS-1){1'b0}}, 1'b1} << req_src_q);
                unique_q <= req_unique_q;
                need_memory_q <= 1'b0;
                state_q <= ST_RESPONSE;
            end else if ((state_q != ST_MEM_WAIT) && mem_data_valid) begin
                protocol_error <= 1'b1;
            end

            if ((state_q == ST_RESPONSE) && rsp_valid && rsp_ready)
                state_q <= ST_IDLE;
        end
    end

endmodule
