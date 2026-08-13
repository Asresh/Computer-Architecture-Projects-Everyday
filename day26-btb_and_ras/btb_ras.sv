// ============================================================================
// Day 26 : Branch Target Buffer (BTB) + Return Address Stack (RAS)
//          fetch-stage target predictor
// ----------------------------------------------------------------------------
// A direction predictor (Day 6 bimodal, Day 24 gshare) answers "is this branch
// taken?" -- but the fetch engine also needs "if taken, WHERE does it go?",
// one cycle before the branch is even decoded. That is the job of the Branch
// Target Buffer: a small, PC-indexed cache of {tag, target, type} learned from
// resolved branches. On a hit the BTB hands fetch a predicted target in the
// same cycle the PC is presented, so the front end can redirect speculatively.
//
// Returns (ret) are special: a single call site is reached from many places, so
// its return address changes every call and a BTB target is useless. Those are
// predicted instead by a Return Address Stack -- a small LIFO that a call pushes
// (link = pc+4) and a return pops. This mirrors the call/return nesting of real
// programs and predicts returns almost perfectly.
//
// This is a classic *taken-cache* BTB: an entry existing for a PC IS the
// taken prediction (there is no separate direction bit here -- pair it with a
// Day 6 / Day 24 direction predictor in a real front end). A conditional branch
// that resolves not-taken evicts its entry, so the BTB self-corrects.
//
//   PREDICT port  (combinational, fetch stage) : PC in -> {hit, taken, target}
//   UPDATE port   (synchronous,  resolve stage): learn/evict entry, push/pop RAS
//
// Notes on style: array-index reads/writes (arr[idx]) are used, but there are
// NO data-dependent *bit*-selects (all pc slices are constant ranges); the
// design is reset-safe and lint-clean.
// ============================================================================

module btb_ras #(
    parameter int XLEN       = 32,   // architectural address width
    parameter int BTB_SETS   = 16,   // direct-mapped BTB entries (power of two)
    parameter int RAS_DEPTH  = 8     // return-address stack depth  (power of two)
) (
    input  logic              clk,
    input  logic              rst_n,

    // ---------------- PREDICT port (combinational, fetch) ------------------
    input  logic [XLEN-1:0]   p_pc,        // fetch PC being looked up
    output logic              p_hit,       // BTB has an entry for p_pc
    output logic              p_taken,     // predicted taken (== p_hit here)
    output logic [1:0]        p_type,      // predicted branch type (see enum)
    output logic [XLEN-1:0]   p_target,    // predicted next PC when taken
    output logic              p_ras_used,  // target came from the RAS (a return)

    // ---------------- UPDATE port (synchronous, resolve) -------------------
    input  logic              u_valid,     // a branch resolved this cycle
    input  logic [XLEN-1:0]   u_pc,        // its PC
    input  logic              u_taken,     // did it actually go taken?
    input  logic [1:0]        u_type,      // its true type (see enum)
    input  logic [XLEN-1:0]   u_target,    // its actual taken target

    // ---------------- Observability (for the waveform / debug) -------------
    output logic [$clog2(RAS_DEPTH+1)-1:0] ras_count, // live RAS occupancy
    output logic [XLEN-1:0]   ras_top_o,   // current RAS top (0 when empty)
    output logic              ovf_sticky,  // RAS overflow ever occurred
    output logic              unf_sticky   // RAS underflow ever occurred
);
    // ---- branch-type encoding ------------------------------------------------
    localparam logic [1:0] T_COND = 2'b00; // conditional branch (beq/bne/...)
    localparam logic [1:0] T_JUMP = 2'b01; // unconditional direct jump (j)
    localparam logic [1:0] T_CALL = 2'b10; // call  (jal/jalr that links) -> push
    localparam logic [1:0] T_RET  = 2'b11; // return (jalr ra)            -> pop

    localparam int IDXW = $clog2(BTB_SETS);
    localparam int TAGW = XLEN - IDXW - 2;              // drop 2 byte-offset bits
    localparam int PTRW = $clog2(RAS_DEPTH);

    // ---- BTB storage (direct-mapped) ----------------------------------------
    logic                  btb_valid  [BTB_SETS];
    logic [TAGW-1:0]       btb_tag    [BTB_SETS];
    logic [XLEN-1:0]       btb_target [BTB_SETS];
    logic [1:0]            btb_type   [BTB_SETS];

    // ---- Return Address Stack ------------------------------------------------
    logic [XLEN-1:0]       ras [RAS_DEPTH];
    logic [PTRW:0]         ras_sp;                      // occupancy count 0..DEPTH

    // ======================================================================
    // PREDICT (combinational)
    // ======================================================================
    logic [IDXW-1:0] p_idx;
    logic [TAGW-1:0] p_tag;
    assign p_idx = p_pc[IDXW+1 : 2];                    // constant range slice
    assign p_tag = p_pc[XLEN-1  : IDXW+2];

    logic ras_ne;                                        // RAS non-empty
    assign ras_ne    = (ras_sp != '0);
    assign ras_top_o = ras_ne ? ras[ras_sp - 1'b1] : '0;
    assign ras_count = ras_sp;

    always_comb begin
        p_hit  = btb_valid[p_idx] && (btb_tag[p_idx] == p_tag);
        p_type = btb_type[p_idx];
        p_taken = p_hit;                                 // taken-cache semantics
        // A predicted return takes its target from the RAS top (if any);
        // everything else uses the stored BTB target.
        if (p_hit && (btb_type[p_idx] == T_RET) && ras_ne) begin
            p_target   = ras_top_o;
            p_ras_used = 1'b1;
        end else begin
            p_target   = btb_target[p_idx];
            p_ras_used = 1'b0;
        end
    end

    // ======================================================================
    // UPDATE (synchronous)
    // ======================================================================
    logic [IDXW-1:0] u_idx;
    logic [TAGW-1:0] u_tag;
    assign u_idx = u_pc[IDXW+1 : 2];
    assign u_tag = u_pc[XLEN-1  : IDXW+2];

    // does the resolving PC currently occupy its BTB set?
    logic u_hits_self;
    assign u_hits_self = btb_valid[u_idx] && (btb_tag[u_idx] == u_tag);

    integer i;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (i = 0; i < BTB_SETS; i++) begin
                btb_valid[i]  <= 1'b0;
                btb_tag[i]    <= '0;
                btb_target[i] <= '0;
                btb_type[i]   <= T_COND;
            end
            ras_sp     <= '0;
            ovf_sticky <= 1'b0;
            unf_sticky <= 1'b0;
        end else if (u_valid) begin
            // -------- BTB allocate / evict --------
            if (u_taken) begin
                // learn (or refresh) the taken target for this PC
                btb_valid[u_idx]  <= 1'b1;
                btb_tag[u_idx]    <= u_tag;
                btb_target[u_idx] <= u_target;
                btb_type[u_idx]   <= u_type;
            end else if (u_type == T_COND && u_hits_self) begin
                // a conditional branch went not-taken: evict its stale entry so
                // the taken-cache stops predicting it taken (self-correction).
                btb_valid[u_idx]  <= 1'b0;
            end

            // -------- RAS push / pop (architectural, at resolve) --------
            // A call pushes its link (return) address = pc+4; a return pops.
            // Overflow drops the push (deepest frame is kept); underflow is
            // ignored. Both set a sticky flag for observability.
            if (u_type == T_CALL) begin
                if (ras_sp < RAS_DEPTH[PTRW:0]) begin
                    ras[ras_sp] <= u_pc + 32'd4;
                    ras_sp      <= ras_sp + 1'b1;
                end else begin
                    ovf_sticky  <= 1'b1;
                end
            end else if (u_type == T_RET) begin
                if (ras_sp != '0) begin
                    ras_sp      <= ras_sp - 1'b1;
                end else begin
                    unf_sticky  <= 1'b1;
                end
            end
        end
    end

`ifndef SYNTHESIS
    // sanity: index/tag widths must partition the address space exactly
    initial begin
        if (IDXW + TAGW + 2 != XLEN)
            $error("btb_ras: IDXW(%0d)+TAGW(%0d)+2 != XLEN(%0d)",
                   IDXW, TAGW, XLEN);
    end
`endif
endmodule
