// -----------------------------------------------------------------------------
// Day29 - Out-of-Order Issue Queue / Reservation Stations
//         (broadcast CAM wakeup + age-matrix oldest-first select)
// -----------------------------------------------------------------------------
// The *scheduler* of an out-of-order core: the structure that holds renamed
// instructions until their operands become available and then launches them,
// oldest-ready-first, regardless of program order. It is the direct consumer of
// the Day28 rename stage (which leaves only true RAW dependences) and the
// producer for the Day12 reorder buffer (which puts the results back in order).
//
// Three mechanisms, all of them classic:
//
//  1) ALLOCATE (dispatch)
//     A renamed instruction is written into any free entry - position in the
//     queue carries NO meaning, because program order is tracked separately by
//     the age matrix. The allocator simply isolates the lowest free entry
//     (`free & -free`). `disp_ready` (= not full) is the backpressure signal.
//
//  2) WAKEUP (associative / CAM)
//     Every completing instruction broadcasts its destination tag on one of
//     NWAKE result buses. Every entry compares BOTH of its source tags against
//     ALL broadcast tags in parallel - ENTRIES x 2 x NWAKE comparators - and
//     latches the matching operand as ready. This is the "reservation station
//     snoops the common data bus" of Tomasulo's algorithm, done with physical
//     register tags instead of station ids.
//
//     The match is also applied COMBINATIONALLY into the request vector (and to
//     an instruction being dispatched in the very same cycle), so a consumer can
//     issue in the same cycle its producer's tag is broadcast. That closes the
//     back-to-back dependent-issue loop that makes `add x2,x1,x1 ; add x3,x2,x2`
//     run at one instruction per cycle - and it is precisely why the
//     wakeup->select->broadcast loop is the critical path of every real
//     out-of-order core.
//
//  3) SELECT (age matrix, oldest-ready-first)
//     Among all entries whose operands are ready, exactly one must be picked,
//     and picking the OLDEST is what keeps the machine from starving an
//     instruction and from stalling the in-order retire head.
//
//     Program order is kept in an ENTRIES x ENTRIES bit matrix:
//         age[i][j] = 1  <=>  entry i is OLDER than entry j
//     On allocating entry a:  age[a] <= 0            (a is younger than all)
//                             age[j] <= age[j] | a   (every other entry is
//                                                     older than a)
//     Both updates are one-hot ORs - no variable indexing anywhere.
//
//     Selection is then one AND-OR level, fully parallel:
//         grant[i] = req[i] & ~|( req & older_column[i] )
//     i.e. "entry i is granted if it requests and no OTHER requesting entry is
//     older than it". Because the matrix encodes a strict total order over the
//     live entries, exactly one requester satisfies this - the grant is
//     inherently one-hot, with no priority-encoder chain and no starvation.
//
// Deallocation: an entry is freed the cycle it actually issues
// (issue_valid & issue_ready). If the function unit refuses (issue_ready = 0)
// the entry simply stays and re-arbitrates next cycle. `flush` (branch
// mispredict / exception) clears the whole queue in one cycle.
//
// Documented simplifications: non-speculative wakeup (no load-miss replay /
// no scheduler squash-and-retry), single dispatch + single issue port, and an
// entry freed in cycle T is re-allocatable from cycle T+1 (the free mask is
// taken from registered valid bits).
//
// Style: parameterised, reset-safe, lint-clean, no data-dependent variable
// bit-selects - every index is a genvar / loop constant.
// -----------------------------------------------------------------------------

`timescale 1ns / 1ps

module issue_queue #(
    parameter int ENTRIES = 8,                              // reservation stations
    parameter int TAGW    = 6,                              // physical-register tag width
    parameter int OPW     = 8,                              // opaque payload width
    parameter int NWAKE   = 2,                              // result/wakeup buses
    parameter int IDXW    = (ENTRIES > 1) ? $clog2(ENTRIES) : 1,
    parameter int CNTW    = $clog2(ENTRIES + 1)
) (
    input  logic                   clk,
    input  logic                   rst_n,

    // ---- Dispatch / allocate port (from rename) ----
    input  logic                   disp_valid,        // an instruction is offered
    output logic                   disp_ready,        // queue not full (backpressure)
    input  logic [OPW-1:0]         disp_op,           // payload (uop / imm / rob id)
    input  logic [TAGW-1:0]        disp_pdst,         // destination physical tag
    input  logic                   disp_pdst_valid,   // instruction writes a register
    input  logic [TAGW-1:0]        disp_psrc1,        // source-1 physical tag
    input  logic                   disp_src1_ready,   // src1 already available / unused
    input  logic [TAGW-1:0]        disp_psrc2,        // source-2 physical tag
    input  logic                   disp_src2_ready,   // src2 already available / unused

    // ---- Wakeup broadcast (from the function units) ----
    input  logic [NWAKE-1:0]       wake_valid,        // per-bus valid
    input  logic [NWAKE*TAGW-1:0]  wake_tag,          // per-bus destination tag (flat)

    // ---- Issue / select port (to the function units) ----
    output logic                   issue_valid,       // a ready instruction is selected
    input  logic                   issue_ready,       // the FU accepts it this cycle
    output logic [OPW-1:0]         issue_op,
    output logic [TAGW-1:0]        issue_pdst,
    output logic                   issue_pdst_valid,
    output logic [IDXW-1:0]        issue_idx,         // entry that was granted

    // ---- Pipeline control ----
    input  logic                   flush,             // mispredict/exception: drop all

    // ---- Debug / observability ----
    output logic [CNTW-1:0]        dbg_count,         // occupied entries
    output logic [ENTRIES-1:0]     dbg_valid,         // per-entry valid
    output logic [ENTRIES-1:0]     dbg_ready1,        // per-entry src1 ready (registered)
    output logic [ENTRIES-1:0]     dbg_ready2,        // per-entry src2 ready (registered)
    output logic [ENTRIES-1:0]     dbg_req            // per-entry request (post-bypass)
);

    // -------------------------------------------------------------------------
    // Entry state
    // -------------------------------------------------------------------------
    logic [ENTRIES-1:0] vld;                    // entry occupied
    logic [ENTRIES-1:0] rdy1, rdy2;             // registered operand-ready bits
    logic [ENTRIES-1:0] pdv;                    // writes a register
    logic [TAGW-1:0]    src1   [ENTRIES-1:0];
    logic [TAGW-1:0]    src2   [ENTRIES-1:0];
    logic [TAGW-1:0]    dst    [ENTRIES-1:0];
    logic [OPW-1:0]     opq    [ENTRIES-1:0];

    // age[i][j] = 1  <=>  entry i is older (dispatched earlier) than entry j.
    // age[i][i] is always 0 by construction (a row is cleared on its own
    // allocation and only ever ORed with one-hot masks of OTHER entries).
    logic [ENTRIES-1:0] age    [ENTRIES-1:0];

    // -------------------------------------------------------------------------
    // Allocate: isolate the lowest free entry
    // -------------------------------------------------------------------------
    logic [ENTRIES-1:0] freemask, lowest_free, alloc_oh;
    logic               alloc_en;

    assign freemask    = ~vld;
    assign lowest_free = freemask & (~freemask + {{(ENTRIES-1){1'b0}}, 1'b1});
    assign disp_ready  = |freemask;
    assign alloc_en    = disp_valid & disp_ready & ~flush;
    assign alloc_oh    = alloc_en ? lowest_free : {ENTRIES{1'b0}};

    // -------------------------------------------------------------------------
    // Wakeup: unpack the result buses and build the associative match
    // -------------------------------------------------------------------------
    logic [TAGW-1:0] wtag [NWAKE-1:0];

    genvar w;
    generate
        for (w = 0; w < NWAKE; w++) begin : g_wtag
            assign wtag[w] = wake_tag[w*TAGW +: TAGW];
        end
    endgenerate

    // The CAM itself: one comparator per (entry source, result bus) pair,
    // ENTRIES x 2 x NWAKE of them, all evaluated in parallel. Everything is
    // indexed by genvars, so this elaborates to plain comparator + OR trees.
    logic [ENTRIES*NWAKE-1:0] match1, match2;   // per-entry x per-bus tag match
    logic [NWAKE-1:0]         dmatch1, dmatch2; // same, for the dispatching uop

    logic [ENTRIES-1:0] hit1, hit2;     // CAM match this cycle
    logic [ENTRIES-1:0] r1_eff, r2_eff; // ready including this cycle's broadcast
    logic [ENTRIES-1:0] req;            // wants to issue
    logic [ENTRIES-1:0] grant;          // selected (one-hot)
    logic [ENTRIES-1:0] older_col [ENTRIES-1:0];
    logic [IDXW-1:0]    idx_const [ENTRIES-1:0];

    // Dispatch-cycle CAM: a tag broadcast in the very cycle an instruction is
    // written into the queue would otherwise be missed forever (the entry did
    // not exist yet when the tag went by).
    logic dr1_bypass, dr2_bypass;

    genvar b;
    generate
        for (b = 0; b < NWAKE; b++) begin : g_dcam
            assign dmatch1[b] = wake_valid[b] & (wtag[b] == disp_psrc1);
            assign dmatch2[b] = wake_valid[b] & (wtag[b] == disp_psrc2);
        end
    endgenerate

    assign dr1_bypass = disp_src1_ready | (|dmatch1);
    assign dr2_bypass = disp_src2_ready | (|dmatch2);

    genvar i, j, c;
    generate
        for (i = 0; i < ENTRIES; i++) begin : g_entry
            localparam logic [IDXW-1:0] ENT_IDX = i;
            assign idx_const[i] = ENT_IDX;

            // --- associative wakeup + same-cycle bypass into the request ---
            for (c = 0; c < NWAKE; c++) begin : g_cam
                assign match1[i*NWAKE + c] = wake_valid[c] & (wtag[c] == src1[i]);
                assign match2[i*NWAKE + c] = wake_valid[c] & (wtag[c] == src2[i]);
            end
            assign hit1[i]   = |match1[i*NWAKE +: NWAKE];
            assign hit2[i]   = |match2[i*NWAKE +: NWAKE];
            assign r1_eff[i] = rdy1[i] | hit1[i];
            assign r2_eff[i] = rdy2[i] | hit2[i];
            assign req[i]    = vld[i] & r1_eff[i] & r2_eff[i];

            // --- age matrix column: which entries are OLDER than i ---
            for (j = 0; j < ENTRIES; j++) begin : g_col
                assign older_col[i][j] = age[j][i];
            end

            // --- select: granted if no other requester is older ---
            assign grant[i] = req[i] & ~(|(req & older_col[i]));

            // --- entry payload / ready state ---
            always_ff @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    vld[i]   <= 1'b0;
                    rdy1[i]  <= 1'b0;
                    rdy2[i]  <= 1'b0;
                    pdv[i]   <= 1'b0;
                    src1[i]  <= {TAGW{1'b0}};
                    src2[i]  <= {TAGW{1'b0}};
                    dst[i]   <= {TAGW{1'b0}};
                    opq[i]   <= {OPW{1'b0}};
                end else if (flush) begin
                    vld[i]   <= 1'b0;
                end else if (alloc_oh[i]) begin
                    vld[i]   <= 1'b1;
                    opq[i]   <= disp_op;
                    dst[i]   <= disp_pdst;
                    pdv[i]   <= disp_pdst_valid;
                    src1[i]  <= disp_psrc1;
                    src2[i]  <= disp_psrc2;
                    // dispatch-cycle wakeup bypass: a tag broadcast in the same
                    // cycle this entry is written would otherwise be missed
                    // forever (the entry did not exist when it went by).
                    rdy1[i]  <= dr1_bypass;
                    rdy2[i]  <= dr2_bypass;
                end else begin
                    if (grant[i] & issue_valid & issue_ready) vld[i] <= 1'b0;
                    rdy1[i] <= r1_eff[i];
                    rdy2[i] <= r2_eff[i];
                end
            end

            // --- age matrix row ---
            always_ff @(posedge clk or negedge rst_n) begin
                if (!rst_n)              age[i] <= {ENTRIES{1'b0}};
                else if (flush)          age[i] <= {ENTRIES{1'b0}};
                else if (alloc_oh[i])    age[i] <= {ENTRIES{1'b0}};  // newest: older than nobody
                else                     age[i] <= age[i] | alloc_oh; // older than the new entry
            end
        end
    endgenerate

    // -------------------------------------------------------------------------
    // Issue port
    // -------------------------------------------------------------------------
    assign issue_valid = |req;

    always_comb begin
        issue_op         = {OPW{1'b0}};
        issue_pdst       = {TAGW{1'b0}};
        issue_pdst_valid = 1'b0;
        issue_idx        = {IDXW{1'b0}};
        for (int e = 0; e < ENTRIES; e++) begin
            if (grant[e]) begin
                issue_op         = opq[e];
                issue_pdst       = dst[e];
                issue_pdst_valid = pdv[e];
                issue_idx        = idx_const[e];
            end
        end
    end

    // -------------------------------------------------------------------------
    // Observability
    // -------------------------------------------------------------------------
    always_comb begin
        dbg_count = {CNTW{1'b0}};
        for (int e = 0; e < ENTRIES; e++) begin
            dbg_count = dbg_count + {{(CNTW-1){1'b0}}, vld[e]};
        end
    end

    assign dbg_valid  = vld;
    assign dbg_ready1 = rdy1;
    assign dbg_ready2 = rdy2;
    assign dbg_req    = req;

endmodule
