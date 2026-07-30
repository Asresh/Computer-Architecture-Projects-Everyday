// ---------------------------------------------------------------------------
// reorder_buffer.sv - Day12
//
// A simplified Reorder Buffer (ROB): the structure that lets an out-of-order
// processor EXECUTE and COMPLETE instructions in any order while still
// COMMITTING (retiring) their architectural results strictly in program order.
//
// Three decoupled ports operate on a circular queue of in-flight entries:
//
//   * ALLOCATE (dispatch)  - one entry reserved per instruction, in program
//                            order, at the tail. Returns the entry's tag.
//   * COMPLETE (writeback) - a functional unit marks an arbitrary entry done
//                            and writes its result. OUT OF ORDER.
//   * RETIRE   (commit)    - only the HEAD entry commits, and only once its
//                            done bit is set. IN ORDER. A younger entry that
//                            finished early must wait behind an unfinished
//                            older one (the head stalls).
//
// A `flush` squashes the whole buffer in one cycle, modelling recovery from a
// branch mispredict / exception.
//
// Fully synthesizable, parameterized, reset-safe. Circular pointers carry an
// extra wrap bit so full and empty are distinguishable without a spare slot.
// ---------------------------------------------------------------------------
`default_nettype none
`timescale 1ns/1ps

module reorder_buffer #(
    parameter int NUM_ENTRIES = 8,           // ROB depth (power of two)
    parameter int DATA_WIDTH  = 32,          // result payload width
    parameter int REG_ADDR_W  = 5            // destination register id width
) (
    input  wire                                clk,
    input  wire                                rst_n,      // async, active-low

    // ---- Allocate / dispatch (in program order) ------------------------
    input  wire                                alloc_valid,
    output wire                                alloc_ready, // = not full
    input  wire [REG_ADDR_W-1:0]               alloc_dest,
    output wire [$clog2(NUM_ENTRIES)-1:0]      alloc_tag,   // slot handed out

    // ---- Complete / writeback (out of order) ---------------------------
    input  wire                                cmpl_valid,
    input  wire [$clog2(NUM_ENTRIES)-1:0]      cmpl_tag,
    input  wire [DATA_WIDTH-1:0]               cmpl_data,

    // ---- Retire / commit (in program order, head only) -----------------
    input  wire                                retire_ready, // downstream sink
    output wire                                retire_valid, // head done & !empty
    output wire [$clog2(NUM_ENTRIES)-1:0]      retire_tag,
    output wire [REG_ADDR_W-1:0]               retire_dest,
    output wire [DATA_WIDTH-1:0]               retire_data,

    // ---- Squash everything (branch mispredict / exception) -------------
    input  wire                                flush,

    // ---- Status --------------------------------------------------------
    output wire                                full,
    output wire                                empty,
    output wire [$clog2(NUM_ENTRIES):0]        count
);

    localparam int TAG_W = $clog2(NUM_ENTRIES);
    localparam int PTR_W = TAG_W + 1;         // extra MSB = wrap/phase bit

    // Circular-queue pointers (index = low TAG_W bits, MSB = wrap phase).
    logic [PTR_W-1:0] head_ptr, tail_ptr;

    // Entry storage.
    logic [DATA_WIDTH-1:0] data_q [NUM_ENTRIES];
    logic [REG_ADDR_W-1:0] dest_q [NUM_ENTRIES];
    logic                  done_q [NUM_ENTRIES];
    logic                  valid_q[NUM_ENTRIES];

    wire [TAG_W-1:0] head_idx = head_ptr[TAG_W-1:0];
    wire [TAG_W-1:0] tail_idx = tail_ptr[TAG_W-1:0];

    // Empty : pointers fully equal.  Full : same index, opposite wrap phase.
    assign empty = (head_ptr == tail_ptr);
    assign full  = (head_idx == tail_idx) && (head_ptr[TAG_W] != tail_ptr[TAG_W]);
    assign count = tail_ptr - head_ptr;       // 0 .. NUM_ENTRIES

    // Allocate hands out the tail slot when there is room.
    assign alloc_ready = ~full;
    assign alloc_tag   = tail_idx;

    // Retire only the head, and only once it is complete.
    assign retire_valid = ~empty & valid_q[head_idx] & done_q[head_idx];
    assign retire_tag   = head_idx;
    assign retire_dest  = dest_q[head_idx];
    assign retire_data  = data_q[head_idx];

    wire alloc_fire  = alloc_valid  & alloc_ready;
    wire retire_fire = retire_valid & retire_ready;

    integer i;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            head_ptr <= '0;
            tail_ptr <= '0;
            for (i = 0; i < NUM_ENTRIES; i = i + 1) begin
                valid_q[i] <= 1'b0;
                done_q [i] <= 1'b0;
            end
        end else if (flush) begin
            // Single-cycle squash of the whole window.
            head_ptr <= '0;
            tail_ptr <= '0;
            for (i = 0; i < NUM_ENTRIES; i = i + 1) begin
                valid_q[i] <= 1'b0;
                done_q [i] <= 1'b0;
            end
        end else begin
            // Allocate at the tail (program order).
            if (alloc_fire) begin
                dest_q [tail_idx] <= alloc_dest;
                done_q [tail_idx] <= 1'b0;
                valid_q[tail_idx] <= 1'b1;
                tail_ptr          <= tail_ptr + 1'b1;
            end
            // Out-of-order completion: mark any live entry done + write result.
            if (cmpl_valid) begin
                done_q[cmpl_tag] <= 1'b1;
                data_q[cmpl_tag] <= cmpl_data;
            end
            // Retire the head (in order). Ordered last so a same-cycle
            // head collision resolves in favour of freeing the slot.
            if (retire_fire) begin
                valid_q[head_idx] <= 1'b0;
                done_q [head_idx] <= 1'b0;
                head_ptr          <= head_ptr + 1'b1;
            end
        end
    end

`ifndef SYNTHESIS
    // Sanity: never complete a slot that is not currently allocated.
    always @(posedge clk) begin
        if (rst_n && !flush && cmpl_valid && !valid_q[cmpl_tag])
            $error("%0t: completion to unallocated tag %0d", $time, cmpl_tag);
    end
`endif

endmodule

`default_nettype wire
