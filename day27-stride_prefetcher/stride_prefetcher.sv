// ============================================================================
// stride_prefetcher.sv  --  Day 27
//
// Stride Prefetcher based on a Reference Prediction Table (RPT), the classic
// Chen & Baer scheme ("Effective Hardware-Based Data Prefetching for High
// Performance Processors", IEEE TC 1995).
//
// The prefetcher watches the stream of data-memory *access* records
// {load-PC, data-address}. For each static load PC it learns the constant
// *stride* between successive addresses (e.g. a[i], a[i+1], a[i+2] ... walking
// an array with element size STRIDE bytes) and, once confident, predicts the
// next address `addr + LOOKAHEAD*stride` so the line can be fetched into the
// cache *before* the demand miss. This is the memory-hierarchy counterpart to
// the direct-mapped / set-associative caches of Days 7 & 23: the caches react
// to misses; the prefetcher hides them.
//
// RPT : direct-mapped, PC-indexed, tag-checked. Each entry holds
//         valid, tag, last_addr, stride, and a 2-bit confidence STATE.
//
// Confidence FSM (per entry), driven each hit by whether the freshly observed
// stride equals the stored stride (`match`):
//
//      INIT      : match -> STEADY     | miss -> TRANSIENT (learn new stride)
//      TRANSIENT : match -> STEADY     | miss -> NO_PRED   (learn new stride)
//      STEADY    : match -> STEADY     | miss -> INIT      (learn new stride)
//      NO_PRED   : match -> TRANSIENT  | miss -> NO_PRED   (learn new stride)
//
// A prefetch is issued only from the STEADY state (and only when stride != 0),
// i.e. after two consecutive confirmations of a non-zero stride. This gives the
// familiar "two-warm-up-then-predict" behaviour and immunity to a single
// irregular access (STEADY tolerates one miss by dropping to INIT, not by
// immediately mispredicting).
//
// All look-up / prediction outputs are combinational functions of the current
// request and the *current* table contents; the table is updated synchronously
// on the clock edge. Table indexing is by a computed index (an array read, not
// a variable bit-select); PC is sliced with constant part-selects only.
// Reset-safe, lint-friendly, fully parameterised.
// ============================================================================

`timescale 1ns / 1ps

module stride_prefetcher #(
    parameter int PC_WIDTH   = 32,   // load-PC width
    parameter int ADDR_WIDTH = 32,   // data-address / stride width
    parameter int IDX_WIDTH  = 4,    // log2(#RPT entries)  -> SETS = 16
    parameter int PC_ALIGN   = 2,    // low PC bits dropped (word-aligned insns)
    parameter int LOOKAHEAD  = 1     // prefetch distance in strides
) (
    input  logic                    clk,
    input  logic                    rst_n,

    // ---- access record (one memory reference observed this cycle) ----------
    input  logic                    req_valid,   // an access is presented
    input  logic [PC_WIDTH-1:0]     req_pc,      // PC of the load
    input  logic [ADDR_WIDTH-1:0]   req_addr,    // data address referenced

    // ---- prefetch prediction (combinational, this cycle's request) ---------
    output logic                    pf_valid,    // issue a prefetch
    output logic [ADDR_WIDTH-1:0]   pf_addr,     // predicted next address

    // ---- observability (also independently checked by the testbench) -------
    output logic                    dbg_hit,     // RPT hit (valid & tag match)
    output logic [1:0]              dbg_state,   // current entry state @lookup
    output logic [ADDR_WIDTH-1:0]   dbg_stride   // current entry stride @lookup
);

    // ---- confidence states -------------------------------------------------
    localparam logic [1:0] S_INIT  = 2'd0;
    localparam logic [1:0] S_TRANS = 2'd1;
    localparam logic [1:0] S_STEADY= 2'd2;
    localparam logic [1:0] S_NOPRED= 2'd3;

    localparam int SETS     = (1 << IDX_WIDTH);
    localparam int TAG_WIDTH= PC_WIDTH - IDX_WIDTH - PC_ALIGN;

    // ---- RPT storage -------------------------------------------------------
    logic                    v_q      [SETS];
    logic [TAG_WIDTH-1:0]    tag_q    [SETS];
    logic [ADDR_WIDTH-1:0]   last_q   [SETS];
    logic [ADDR_WIDTH-1:0]   stride_q [SETS];
    logic [1:0]              state_q  [SETS];

    // ---- index / tag decode (constant part-selects only) -------------------
    logic [IDX_WIDTH-1:0]  idx;
    logic [TAG_WIDTH-1:0]  req_tag;
    assign idx     = req_pc[PC_ALIGN +: IDX_WIDTH];
    assign req_tag = req_pc[PC_WIDTH-1 -: TAG_WIDTH];

    // ---- combinational look-up of the indexed entry ------------------------
    logic                   hit;
    logic [ADDR_WIDTH-1:0]  obs_stride;   // freshly observed stride
    logic                   match;        // observed == stored stride

    assign hit        = v_q[idx] && (tag_q[idx] == req_tag);
    assign obs_stride = req_addr - last_q[idx];              // modular 2's-comp
    assign match      = hit && (obs_stride == stride_q[idx]);

    // ---- prefetch decision (STEADY + non-zero stride) ----------------------
    assign pf_valid = req_valid && hit &&
                      (state_q[idx] == S_STEADY) && (stride_q[idx] != '0);
    assign pf_addr  = req_addr + (stride_q[idx] * LOOKAHEAD);

    // ---- observability -----------------------------------------------------
    assign dbg_hit    = req_valid && hit;
    assign dbg_state  = state_q[idx];
    assign dbg_stride = stride_q[idx];

    // ---- next-state helper -------------------------------------------------
    function automatic logic [1:0] next_state(input logic [1:0] s,
                                              input logic       m);
        unique case (s)
            S_INIT  : next_state = m ? S_STEADY : S_TRANS;
            S_TRANS : next_state = m ? S_STEADY : S_NOPRED;
            S_STEADY: next_state = m ? S_STEADY : S_INIT;
            S_NOPRED: next_state = m ? S_TRANS  : S_NOPRED;
            default : next_state = S_INIT;
        endcase
    endfunction

    // ---- synchronous table update ------------------------------------------
    integer i;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (i = 0; i < SETS; i = i + 1) begin
                v_q[i]      <= 1'b0;
                tag_q[i]    <= '0;
                last_q[i]   <= '0;
                stride_q[i] <= '0;
                state_q[i]  <= S_INIT;
            end
        end else if (req_valid) begin
            if (!hit) begin
                // allocate (direct-mapped: overwrite any conflicting entry)
                v_q[idx]      <= 1'b1;
                tag_q[idx]    <= req_tag;
                last_q[idx]   <= req_addr;
                stride_q[idx] <= '0;
                state_q[idx]  <= S_INIT;
            end else begin
                last_q[idx]  <= req_addr;
                state_q[idx] <= next_state(state_q[idx], match);
                // on a mismatch we (re)learn the freshly observed stride
                if (!match)
                    stride_q[idx] <= obs_stride;
            end
        end
    end

endmodule
