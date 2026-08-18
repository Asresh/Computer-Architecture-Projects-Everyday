// Author: Asresh Kuricheti
//
// Fully-associative victim cache datapath:
//   L1 victim lookup -> parallel tag compare -> hit data / atomic line swap
//                                           -> replacement -> lower-level eviction
`timescale 1ns/1ps
module victim_cache #(
    parameter int ADDR_WIDTH = 32,
    parameter int DATA_WIDTH = 64,
    parameter int ENTRIES    = 4,
    parameter int PTR_WIDTH  = (ENTRIES <= 1) ? 1 : $clog2(ENTRIES)
) (
    input  logic                      clk,
    input  logic                      reset_n,

    input  logic                      access_valid,
    input  logic [ADDR_WIDTH-1:0]     access_addr,
    output logic                      hit,
    output logic [DATA_WIDTH-1:0]     hit_data,
    output logic                      hit_dirty,
    output logic [PTR_WIDTH-1:0]      hit_way,
    input  logic                      take_hit,

    input  logic                      insert_valid,
    input  logic [ADDR_WIDTH-1:0]     insert_addr,
    input  logic [DATA_WIDTH-1:0]     insert_data,
    input  logic                      insert_dirty,

    output logic                      evict_valid,
    output logic [ADDR_WIDTH-1:0]     evict_addr,
    output logic [DATA_WIDTH-1:0]     evict_data,
    output logic                      evict_dirty,
    output logic [PTR_WIDTH:0]        occupancy
);
    logic [ENTRIES-1:0] valid_q;
    logic [ADDR_WIDTH-1:0] addr_q [0:ENTRIES-1];
    logic [DATA_WIDTH-1:0] data_q [0:ENTRIES-1];
    logic [ENTRIES-1:0] dirty_q;
    logic [PTR_WIDTH-1:0] replace_ptr_q;

    logic [PTR_WIDTH-1:0] insert_way;
    logic found_invalid;
    logic atomic_swap;
    integer i;

    initial begin
        if (ENTRIES < 2 || (ENTRIES & (ENTRIES - 1)) != 0)
            $error("ENTRIES must be a power of two and at least two");
    end

    always_comb begin
        hit = 1'b0;
        hit_data = '0;
        hit_dirty = 1'b0;
        hit_way = '0;
        for (i = 0; i < ENTRIES; i = i + 1) begin
            if (!hit && access_valid && valid_q[i] && addr_q[i] == access_addr) begin
                hit = 1'b1;
                hit_data = data_q[i];
                hit_dirty = dirty_q[i];
                hit_way = i[PTR_WIDTH-1:0];
            end
        end

        insert_way = replace_ptr_q;
        found_invalid = 1'b0;
        for (i = 0; i < ENTRIES; i = i + 1) begin
            if (!found_invalid && !valid_q[i]) begin
                insert_way = i[PTR_WIDTH-1:0];
                found_invalid = 1'b1;
            end
        end

        atomic_swap = access_valid && hit && take_hit && insert_valid;
        evict_valid = insert_valid && !atomic_swap && valid_q[insert_way];
        evict_addr = evict_valid ? addr_q[insert_way] : '0;
        evict_data = evict_valid ? data_q[insert_way] : '0;
        evict_dirty = evict_valid && dirty_q[insert_way];

        occupancy = '0;
        for (i = 0; i < ENTRIES; i = i + 1)
            occupancy = occupancy + valid_q[i];
    end

    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            valid_q <= '0;
            dirty_q <= '0;
            replace_ptr_q <= '0;
            for (i = 0; i < ENTRIES; i = i + 1) begin
                addr_q[i] <= '0;
                data_q[i] <= '0;
            end
        end else begin
            // A victim hit can be consumed alone or atomically exchanged for
            // the conflicting L1 line without displacing another entry.
            if (access_valid && hit && take_hit) begin
                if (insert_valid) begin
                    valid_q[hit_way] <= 1'b1;
                    addr_q[hit_way] <= insert_addr;
                    data_q[hit_way] <= insert_data;
                    dirty_q[hit_way] <= insert_dirty;
                end else begin
                    valid_q[hit_way] <= 1'b0;
                    dirty_q[hit_way] <= 1'b0;
                end
            end

            // A normal L1 eviction fills an invalid slot first, then replaces
            // the round-robin slot. Atomic swap was handled above.
            if (insert_valid && !(access_valid && hit && take_hit)) begin
                valid_q[insert_way] <= 1'b1;
                addr_q[insert_way] <= insert_addr;
                data_q[insert_way] <= insert_data;
                dirty_q[insert_way] <= insert_dirty;
                if (valid_q[insert_way])
                    replace_ptr_q <= replace_ptr_q + 1'b1;
            end
        end
    end
endmodule
