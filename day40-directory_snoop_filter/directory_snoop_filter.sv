// Author: Asresh Kuricheti
// Directory-based snoop filter: tag directory -> targeted coherence probes.
`timescale 1ns/1ps
module directory_snoop_filter #(
    parameter integer ADDR_WIDTH  = 32,
    parameter integer LINE_OFFSET = 6,
    parameter integer SETS        = 8,
    parameter integer CORES       = 4,
    parameter integer INDEX_WIDTH = $clog2(SETS),
    parameter integer CORE_WIDTH  = $clog2(CORES),
    parameter integer COUNT_WIDTH = $clog2(SETS + 1)
) (
    input  wire                     clk,
    input  wire                     reset_n,
    input  wire                     req_valid,
    input  wire [1:0]               req_op,
    input  wire [CORE_WIDTH-1:0]    req_core,
    input  wire [ADDR_WIDTH-1:0]    req_addr,
    output reg                      rsp_valid,
    output reg                      rsp_hit,
    output reg  [CORES-1:0]         snoop_mask,
    output reg                      replacement,
    output reg  [ADDR_WIDTH-1:0]    replaced_addr,
    output reg  [CORES-1:0]         post_sharers,
    output reg                      post_owner_valid,
    output reg  [CORE_WIDTH-1:0]    post_owner,
    output reg  [COUNT_WIDTH-1:0]   entry_count
);
    localparam integer TAG_WIDTH = ADDR_WIDTH - LINE_OFFSET - INDEX_WIDTH;
    localparam [1:0] READ_SHARED = 2'b00;
    localparam [1:0] READ_UNIQUE = 2'b01;
    localparam [1:0] EVICT       = 2'b10;

    reg [TAG_WIDTH-1:0] tags [0:SETS-1];
    reg [CORES-1:0] sharers [0:SETS-1];
    reg [CORE_WIDTH-1:0] owners [0:SETS-1];
    reg valid [0:SETS-1];
    reg owner_valid [0:SETS-1];

    wire [INDEX_WIDTH-1:0] req_index = req_addr[LINE_OFFSET +: INDEX_WIDTH];
    wire [TAG_WIDTH-1:0] req_tag = req_addr[ADDR_WIDTH-1 -: TAG_WIDTH];
    wire [CORES-1:0] requester_bit = {{(CORES-1){1'b0}}, 1'b1} << req_core;
    wire tag_hit = valid[req_index] && (tags[req_index] == req_tag);

    integer i;
    always @* begin
        entry_count = {COUNT_WIDTH{1'b0}};
        for (i = 0; i < SETS; i = i + 1)
            entry_count = entry_count + valid[i];
    end

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            rsp_valid        <= 1'b0;
            rsp_hit          <= 1'b0;
            snoop_mask       <= {CORES{1'b0}};
            replacement      <= 1'b0;
            replaced_addr    <= {ADDR_WIDTH{1'b0}};
            post_sharers     <= {CORES{1'b0}};
            post_owner_valid <= 1'b0;
            post_owner       <= {CORE_WIDTH{1'b0}};
            for (i = 0; i < SETS; i = i + 1) begin
                valid[i]       <= 1'b0;
                tags[i]        <= {TAG_WIDTH{1'b0}};
                sharers[i]     <= {CORES{1'b0}};
                owner_valid[i] <= 1'b0;
                owners[i]      <= {CORE_WIDTH{1'b0}};
            end
        end else begin
            rsp_valid        <= req_valid;
            rsp_hit          <= 1'b0;
            snoop_mask       <= {CORES{1'b0}};
            replacement      <= 1'b0;
            replaced_addr    <= {ADDR_WIDTH{1'b0}};
            post_sharers     <= {CORES{1'b0}};
            post_owner_valid <= 1'b0;
            post_owner       <= {CORE_WIDTH{1'b0}};

            if (req_valid) begin
                rsp_hit <= tag_hit;
                case (req_op)
                    READ_SHARED: begin
                        if (tag_hit) begin
                            if (owner_valid[req_index] &&
                                (owners[req_index] != req_core))
                                snoop_mask <= {{(CORES-1){1'b0}}, 1'b1}
                                              << owners[req_index];
                            sharers[req_index] <= sharers[req_index] | requester_bit;
                            owner_valid[req_index] <= 1'b0;
                            post_sharers <= sharers[req_index] | requester_bit;
                        end else begin
                            if (valid[req_index]) begin
                                replacement   <= 1'b1;
                                snoop_mask    <= sharers[req_index];
                                replaced_addr <= {tags[req_index], req_index,
                                                  {LINE_OFFSET{1'b0}}};
                            end
                            valid[req_index]       <= 1'b1;
                            tags[req_index]        <= req_tag;
                            sharers[req_index]     <= requester_bit;
                            owner_valid[req_index] <= 1'b0;
                            post_sharers           <= requester_bit;
                        end
                    end

                    READ_UNIQUE: begin
                        if (tag_hit)
                            snoop_mask <= sharers[req_index] & ~requester_bit;
                        else if (valid[req_index]) begin
                            replacement   <= 1'b1;
                            snoop_mask    <= sharers[req_index];
                            replaced_addr <= {tags[req_index], req_index,
                                              {LINE_OFFSET{1'b0}}};
                        end
                        valid[req_index]       <= 1'b1;
                        tags[req_index]        <= req_tag;
                        sharers[req_index]     <= requester_bit;
                        owner_valid[req_index] <= 1'b1;
                        owners[req_index]      <= req_core;
                        post_sharers           <= requester_bit;
                        post_owner_valid       <= 1'b1;
                        post_owner             <= req_core;
                    end

                    EVICT: begin
                        if (tag_hit && sharers[req_index][req_core]) begin
                            sharers[req_index] <= sharers[req_index] & ~requester_bit;
                            post_sharers <= sharers[req_index] & ~requester_bit;
                            if ((sharers[req_index] & ~requester_bit) == {CORES{1'b0}})
                                valid[req_index] <= 1'b0;
                            if (owner_valid[req_index] &&
                                (owners[req_index] == req_core))
                                owner_valid[req_index] <= 1'b0;
                            else begin
                                post_owner_valid <= owner_valid[req_index];
                                post_owner       <= owners[req_index];
                            end
                        end
                    end

                    default: begin
                        // Reserved requests are acknowledged without changing state.
                    end
                endcase
            end
        end
    end
endmodule
