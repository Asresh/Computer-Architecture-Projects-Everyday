// -----------------------------------------------------------------------------
// Day20 - Systolic Shift-Register Priority Queue (hardware min-heap)
//
//   Single-cycle, O(1) ENQUEUE and EXTRACT-MIN dynamic ordered set.  DEPTH
//   register cells hold {key, data}, kept packed at the low indices and sorted
//   ascending by key so that cell[0] is *always* the current minimum (peek is
//   free, extract-min is a one-cycle left shift).  Every cell decides, in
//   parallel from purely local neighbour information, whether to keep its own
//   value, take the newly inserted element, or shift in its left neighbour -
//   the classic systolic / shift-register priority-queue dataflow.  One
//   operation is accepted every clock (fully pipelined, 1 op/cycle, fixed
//   single-cycle latency, data-independent) - the ultra-low-latency substrate
//   behind streaming Top-K selection (GPU `topk` / CUB `DeviceSelect`) and,
//   above all, the HFT order-book / matching-engine best-price queue where a
//   new order must be inserted and the best price extracted in one cycle.
//
//   Ordering is a *min-queue*: a smaller key = higher priority.  Equal keys are
//   inserted AFTER existing equal keys (a new element is placed only where
//   `enq_key < key[i]`), so entries with the same priority retire in arrival
//   order - exact price-time (FIFO-at-price) priority for a limit order book.
//
// Interface
//   op = 2'b00 NOP | 2'b01 ENQ (insert {enq_key,enq_data}) | 2'b10 DEQ
//        (extract & discard current min) | 2'b11 reserved -> treated as NOP.
//   min_key/min_data/min_valid continuously PEEK the current minimum.
//   overflow / underflow are sticky (set until reset) - ENQ-while-full drops
//   the new element, DEQ-while-empty is ignored; neither corrupts the queue.
//
//   Fully synthesizable, reset-safe, latch-free, no variable bit-selects
//   (all cell indexing is via constant genvar / loop indices).
// -----------------------------------------------------------------------------
`timescale 1ns/1ps
`default_nettype none

module priority_queue #(
    parameter int DEPTH  = 8,   // number of queue entries (cells)
    parameter int KEY_W  = 16,  // priority/key width (unsigned; smaller = higher priority)
    parameter int DATA_W = 16   // payload width carried alongside each key
) (
    input  wire                       clk,
    input  wire                       rst_n,      // synchronous-use, active-low reset

    input  wire  [1:0]                op,         // 00 NOP / 01 ENQ / 10 DEQ / 11 NOP
    input  wire  [KEY_W-1:0]          enq_key,    // key   inserted on ENQ
    input  wire  [DATA_W-1:0]         enq_data,   // payload inserted on ENQ

    output wire  [KEY_W-1:0]          min_key,    // peek: smallest key currently held
    output wire  [DATA_W-1:0]         min_data,   // peek: payload paired with min_key
    output wire                       min_valid,  // queue is non-empty
    output wire  [$clog2(DEPTH+1)-1:0] count,     // number of valid entries
    output wire                       full,       // count == DEPTH
    output wire                       empty,      // count == 0
    output logic                      overflow,   // sticky: ENQ attempted while full
    output logic                      underflow   // sticky: DEQ attempted while empty
);

    localparam int CNT_W = $clog2(DEPTH+1);

    // op encoding
    localparam logic [1:0] OP_NOP = 2'b00;
    localparam logic [1:0] OP_ENQ = 2'b01;
    localparam logic [1:0] OP_DEQ = 2'b10;

    // ---- architectural state: sorted, low-packed register file of cells -----
    logic [KEY_W-1:0]  key_q  [DEPTH];
    logic [DATA_W-1:0] data_q [DEPTH];
    logic [CNT_W-1:0]  count_q;              // single source of truth for occupancy

    // valid[i] is derived from count (entries are always packed at [0 .. count-1])
    logic [DEPTH-1:0]  valid;
    always_comb
        for (int i = 0; i < DEPTH; i++)
            valid[i] = (CNT_W'(i) < count_q);

    // ---- status / peek outputs ----------------------------------------------
    assign empty     = (count_q == '0);
    assign full      = (count_q == CNT_W'(DEPTH));
    assign min_valid = ~empty;
    assign min_key   = key_q[0];
    assign min_data  = data_q[0];
    assign count     = count_q;

    // ---- operation firing (op that actually mutates state this cycle) -------
    wire enq_fire = (op == OP_ENQ) && ~full;
    wire deq_fire = (op == OP_DEQ) && ~empty;

    // ---- ENQUEUE: parallel sorted insert ------------------------------------
    // cond[i] : the new element belongs AT or BEFORE cell i.  Because the queue
    // is packed and sorted, cond is monotonic 0..0 1..1 - it flips to 1 at the
    // insertion point p (first empty cell, or first cell whose key is larger),
    // and the new element lands there while cells >= p shift one place right.
    logic [DEPTH-1:0] cond;
    always_comb
        for (int i = 0; i < DEPTH; i++)
            cond[i] = (~valid[i]) || (enq_key < key_q[i]);

    // ---- next-state ----------------------------------------------------------
    logic [KEY_W-1:0]  key_n  [DEPTH];
    logic [DATA_W-1:0] data_n [DEPTH];
    logic [CNT_W-1:0]  count_n;

    always_comb begin
        // default: hold
        for (int i = 0; i < DEPTH; i++) begin
            key_n[i]  = key_q[i];
            data_n[i] = data_q[i];
        end
        count_n = count_q;

        if (enq_fire) begin
            for (int i = 0; i < DEPTH; i++) begin
                logic cond_prev;                 // cond of the left neighbour (cond[-1] = 0)
                cond_prev = (i == 0) ? 1'b0 : cond[i-1];
                if (!cond[i]) begin
                    // before the insertion point: keep own value
                    key_n[i]  = key_q[i];
                    data_n[i] = data_q[i];
                end else if (!cond_prev) begin
                    // exactly the insertion point: accept the new element
                    key_n[i]  = enq_key;
                    data_n[i] = enq_data;
                end else begin
                    // after the insertion point: shift in the left neighbour
                    key_n[i]  = key_q[i-1];
                    data_n[i] = data_q[i-1];
                end
            end
            count_n = count_q + CNT_W'(1);
        end else if (deq_fire) begin
            // EXTRACT-MIN: pop cell[0], shift the whole array one place left
            for (int i = 0; i < DEPTH; i++) begin
                if (i == DEPTH-1) begin
                    key_n[i]  = '0;
                    data_n[i] = '0;
                end else begin
                    key_n[i]  = key_q[i+1];
                    data_n[i] = data_q[i+1];
                end
            end
            count_n = count_q - CNT_W'(1);
        end
    end

    // ---- sequential update ---------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < DEPTH; i++) begin
                key_q[i]  <= '0;
                data_q[i] <= '0;
            end
            count_q   <= '0;
            overflow  <= 1'b0;
            underflow <= 1'b0;
        end else begin
            for (int i = 0; i < DEPTH; i++) begin
                key_q[i]  <= key_n[i];
                data_q[i] <= data_n[i];
            end
            count_q <= count_n;
            // sticky error flags (rejected op does not disturb the queue)
            if ((op == OP_ENQ) &&  full ) overflow  <= 1'b1;
            if ((op == OP_DEQ) &&  empty) underflow <= 1'b1;
        end
    end

`ifdef FORMAL_OR_DEBUG
    // sanity: never both fire at once, count in range
    always_ff @(posedge clk) begin
        assert (!(enq_fire && deq_fire));
        assert (count_q <= CNT_W'(DEPTH));
    end
`endif

endmodule

`default_nettype wire
