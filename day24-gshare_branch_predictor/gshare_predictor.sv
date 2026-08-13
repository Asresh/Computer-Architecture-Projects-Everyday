// gshare_predictor.sv
// -----------------------------------------------------------------------------
// gshare correlating branch predictor.
//
// A Global History Register (GHR) of the last GHIST_BITS branch outcomes is
// XOR-folded with the branch PC to index a Pattern History Table (PHT) of 2-bit
// saturating counters. Unlike a bimodal predictor (which indexes by PC alone),
// gshare lets the *pattern of recent branches* select the counter, so two
// dynamic instances of the same static branch that occur under different
// histories learn independent predictions. This is what lets gshare nail
// correlated / alternating branches that a bimodal predictor cannot.
//
// The module keeps the classic split between a combinational PREDICT port
// (fetch stage) and a synchronous UPDATE port (resolve stage). Because the
// index that must be trained is the one computed from the history *as it stood
// when the branch was fetched*, the update port takes a `ghist_update`
// snapshot — exactly the branch-history checkpoint a real pipeline carries
// alongside the in-flight branch. Updating with that snapshot (rather than the
// current GHR) keeps training aligned with prediction even with a branch
// in flight.
//
// Synthesizable, reset-safe, lint-friendly. Debug taps expose the GHR, the two
// indices, and the pre-update counter for observation and verification.
// -----------------------------------------------------------------------------

`default_nettype none

module gshare_predictor #(
    parameter int XLEN        = 32,      // program-counter width
    parameter int INDEX_BITS  = 4,       // PHT holds 2**INDEX_BITS counters
    parameter int GHIST_BITS  = 4,       // global history register width
    parameter logic [1:0] RESET_STATE = 2'b01  // cold-start counter = weakly N
) (
    input  wire                   clk,
    input  wire                   rst_n,

    // ---- Predict port (combinational, fetch stage) ----
    input  wire [XLEN-1:0]        pc_predict,
    output wire                   predict_taken,

    // ---- Update port (synchronous, resolve stage) ----
    input  wire                   update_en,
    input  wire [XLEN-1:0]        pc_update,
    input  wire [GHIST_BITS-1:0]  ghist_update,   // GHR snapshot from fetch
    input  wire                   actual_taken,

    // ---- Debug / observation taps ----
    output wire [GHIST_BITS-1:0]  dbg_ghr,            // current GHR (snapshot this)
    output wire [INDEX_BITS-1:0]  dbg_predict_index,
    output wire [INDEX_BITS-1:0]  dbg_update_index,
    output wire [1:0]             dbg_update_counter  // pre-update value
);

    localparam int DEPTH = 1 << INDEX_BITS;

    // Pattern History Table: DEPTH 2-bit saturating counters.
    logic [1:0] pht [DEPTH-1:0];

    // Global History Register.
    logic [GHIST_BITS-1:0] ghr;

    // ------------------------------------------------------------------
    // Index folding: XOR the word-aligned low PC bits with the history.
    // RV32 instructions are word aligned, so pc[1:0] carry no information
    // and are dropped. When GHIST_BITS < INDEX_BITS the history is
    // zero-extended into the low bits (upper index bits come from the PC
    // only); when GHIST_BITS > INDEX_BITS the extra history is truncated.
    // ------------------------------------------------------------------
    function automatic [INDEX_BITS-1:0] fold_index
            (input logic [XLEN-1:0] pc, input logic [GHIST_BITS-1:0] hist);
        logic [INDEX_BITS-1:0] pc_idx;
        logic [INDEX_BITS-1:0] hist_ext;
        begin
            pc_idx   = pc[INDEX_BITS+1:2];
            hist_ext = hist;   // resizing assignment: zero-extend or truncate
            fold_index = pc_idx ^ hist_ext;
        end
    endfunction

    wire [INDEX_BITS-1:0] pidx = fold_index(pc_predict, ghr);
    wire [INDEX_BITS-1:0] uidx = fold_index(pc_update,  ghist_update);

    // ---- Combinational prediction: MSB of the selected counter ----
    assign predict_taken = pht[pidx][1];

    // ---- Saturating next-state for the trained counter ----
    logic [1:0] cur, nxt;
    always_comb begin
        cur = pht[uidx];
        if (actual_taken)
            nxt = (cur == 2'b11) ? 2'b11 : (cur + 2'b01);   // toward strongly-taken
        else
            nxt = (cur == 2'b00) ? 2'b00 : (cur - 2'b01);   // toward strongly-not
    end

    // ---- State: PHT + GHR ----
    integer i;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (i = 0; i < DEPTH; i = i + 1)
                pht[i] <= RESET_STATE;
            ghr <= '0;
        end else if (update_en) begin
            pht[uidx] <= nxt;
            // Shift the resolved outcome into the (speculation-free) GHR.
            ghr <= {ghr[GHIST_BITS-2:0], actual_taken};
        end
    end

    // ---- Debug taps ----
    assign dbg_ghr            = ghr;
    assign dbg_predict_index  = pidx;
    assign dbg_update_index   = uidx;
    assign dbg_update_counter = cur;

endmodule

`default_nettype wire
