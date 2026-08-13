// -----------------------------------------------------------------------------
// Day31 - Non-Blocking (Lockup-Free) Cache MSHR File
// -----------------------------------------------------------------------------
// The structure that turns a BLOCKING cache (Day7 / Day23: one miss and the
// whole pipeline freezes until the line comes back) into a LOCKUP-FREE cache
// (Kroft, ISCA 1981).  A miss no longer stalls the machine: its bookkeeping is
// parked in a Miss Status Holding Register and the cache keeps accepting new
// accesses.  That single change is what buys
//
//   * hit-under-miss   - hits sail past an outstanding miss;
//   * miss-under-miss  - several independent misses are in flight at once,
//                        i.e. MEMORY-LEVEL PARALLELISM.  N MSHRs overlap N
//                        DRAM round trips, so an L-cycle memory latency costs
//                        L cycles total instead of N*L;
//   * secondary-miss merging - a second access to a block that is ALREADY
//                        being fetched does NOT launch a duplicate memory
//                        transaction.  It is merged into the existing MSHR as
//                        an extra TARGET.
//
// An MSHR entry holds, for one in-flight cache block:
//
//     valid  - entry allocated
//     blk    - the block address being fetched (the CAM key)
//     done   - fill data has come back, entry is now replaying
//     data   - the returned block (WORDS words)
//     targets[NTARGET] - the sub-entries: for each waiting access, WHERE the
//                        data has to go ({dst register id, word offset}).  The
//                        target list is the reason a secondary miss is free.
//     ntgt / nrpl       - targets recorded / targets already replayed
//
// Three independent ports, all one action per cycle:
//
//   1. LOOKUP/ALLOCATE  (combinational, from the cache tag stage on a miss)
//        fully-associative compare of req_blk against every valid entry
//          hit  + room            -> SECONDARY: merge a target, no bus traffic
//          miss + free entry      -> PRIMARY  : allocate + issue the fill
//          otherwise              -> req_ready = 0, the cache blocks.  Those
//                                    are the two structural hazards that make
//                                    a lockup-free cache eventually lock up:
//                                    MSHR-file full, and target-list full.
//   2. FILL RETURN      (tagged, OUT OF ORDER)  memory returns fill_id, so the
//        block that comes back first wins - allocation order is irrelevant.
//        That is precisely what makes the parallelism usable.
//   3. REPLAY           (to the core's write-back port)  one target per cycle,
//        oldest-first within an entry, word-selected out of the filled block.
//        rpl_last frees the MSHR.
//
// Notes / documented simplifications
//   * An entry stops accepting new targets the moment its fill lands
//     (`!done`).  A miss to a block that is mid-replay therefore stalls rather
//     than merging into a list that is already being drained.  Real designs do
//     the same; it keeps ntgt monotone while nrpl is advancing.
//   * The one exception is the SAME-CYCLE LATE MERGE: the lookup sees
//     `done == 0` while the fill is landing on that very edge.  The target is
//     appended and `done` rises together, so the new target replays out of the
//     freshly written block.  Correct by construction, and exercised by the TB.
//   * An entry freed by a replay in cycle C is reusable in cycle C+1, not in
//     cycle C (the free-entry pick reads the registered valid bits).
//   * mem_req_valid does NOT depend on mem_req_ready (no combinational loop);
//     req_ready does, so a busy bus back-pressures the allocate.
//
// Style: reset-safe, lint-friendly, no data-dependent variable BIT-selects
// (array element indexing only), all state in one always_ff.
// -----------------------------------------------------------------------------

`timescale 1ns / 1ps

module mshr_file #(
    parameter int ADDR_W  = 32,  // WORD address width (not byte)
    parameter int DATA_W  = 32,
    parameter int WORDS   = 4,   // words per cache block
    parameter int NMSHR   = 4,   // outstanding misses supported == max MLP
    parameter int NTARGET = 4,   // sub-entries (waiting accesses) per block
    parameter int DST_W   = 5    // destination register / ROB tag width
) (
    input  logic                     clk,
    input  logic                     rst_n,

    // ---- 1. miss lookup / allocate (from the cache tag stage) --------------
    input  logic                     req_valid,
    input  logic [ADDR_W-1:0]        req_addr,   // word address that missed
    input  logic [DST_W-1:0]         req_dst,    // where the word must land
    output logic                     req_ready,  // 0 => cache must stall
    output logic                     req_primary,   // new MSHR allocated
    output logic                     req_secondary, // merged into an MSHR
    output logic [$clog2(NMSHR)-1:0] req_id,

    // ---- 2a. fill request to the next level --------------------------------
    input  logic                     mem_req_ready,
    output logic                     mem_req_valid,
    output logic [ADDR_W-$clog2(WORDS)-1:0] mem_req_addr,
    output logic [$clog2(NMSHR)-1:0] mem_req_id,

    // ---- 2b. fill return, tagged and OUT OF ORDER --------------------------
    input  logic                     fill_valid,
    input  logic [$clog2(NMSHR)-1:0] fill_id,
    input  logic [WORDS*DATA_W-1:0]  fill_data,

    // ---- 3. replay to the core write-back port -----------------------------
    input  logic                     rpl_ready,
    output logic                     rpl_valid,
    output logic [DST_W-1:0]         rpl_dst,
    output logic [DATA_W-1:0]        rpl_data,
    output logic [$clog2(NMSHR)-1:0] rpl_id,
    output logic                     rpl_last,   // frees the MSHR this cycle

    // ---- status ------------------------------------------------------------
    output logic                     full,          // no free MSHR
    output logic [$clog2(NMSHR):0]   n_valid,       // entries in use
    output logic [$clog2(NMSHR):0]   n_outstanding, // fills still in flight
    output logic                     err_fill       // sticky: bad fill tag
);

    // ---- derived widths ----------------------------------------------------
    localparam int WOFF_W  = (WORDS  > 1) ? $clog2(WORDS) : 1;
    localparam int ID_W    = (NMSHR  > 1) ? $clog2(NMSHR) : 1;
    localparam int BADDR_W = ADDR_W - WOFF_W;
    localparam int TC_W    = $clog2(NTARGET + 1);   // holds 0..NTARGET
    localparam int CNT_W   = $clog2(NMSHR + 1);

    // =========================================================================
    // Architectural state.  Target and block-data arrays are FLATTENED to one
    // dimension (index i*STRIDE + j) so every access is a plain array select.
    // =========================================================================
    logic               vld_q  [NMSHR];
    logic               done_q [NMSHR];
    logic [BADDR_W-1:0] blk_q  [NMSHR];
    logic [TC_W-1:0]    ntgt_q [NMSHR];
    logic [TC_W-1:0]    nrpl_q [NMSHR];
    logic [DATA_W-1:0]  dat_q  [NMSHR*WORDS];
    logic [DST_W-1:0]   tdst_q [NMSHR*NTARGET];
    logic [WOFF_W-1:0]  twof_q [NMSHR*NTARGET];

    // ---- split the flat fill bus into words (constant slices) --------------
    logic [DATA_W-1:0] fillw [WORDS];
    genvar gw;
    generate
        for (gw = 0; gw < WORDS; gw = gw + 1) begin : g_fillword
            assign fillw[gw] = fill_data[gw*DATA_W +: DATA_W];
        end
    endgenerate

    // ---- request address split (constant part-selects) ---------------------
    logic [WOFF_W-1:0]  req_woff;
    logic [BADDR_W-1:0] req_blk;
    assign req_woff = req_addr[WOFF_W-1:0];
    assign req_blk  = req_addr[ADDR_W-1:WOFF_W];

    // =========================================================================
    // Port 1 - fully-associative lookup + free-entry pick
    // =========================================================================
    logic            cam_hit;
    logic [ID_W-1:0] cam_idx;
    logic            free_any;
    logic [ID_W-1:0] free_idx;

    always_comb begin
        cam_hit = 1'b0;
        cam_idx = {ID_W{1'b0}};
        for (int i = 0; i < NMSHR; i++) begin
            if (!cam_hit && vld_q[i] && (blk_q[i] == req_blk)) begin
                cam_hit = 1'b1;
                cam_idx = i[ID_W-1:0];
            end
        end
        // At most one entry can ever match: a primary allocate only happens on
        // a CAM miss, so no two valid entries hold the same block address.

        free_any = 1'b0;
        free_idx = {ID_W{1'b0}};
        for (int i = 0; i < NMSHR; i++) begin
            if (!free_any && !vld_q[i]) begin
                free_any = 1'b1;
                free_idx = i[ID_W-1:0];
            end
        end
    end

    // room left in the matched entry's target list, and it is not yet draining
    logic mergeable;
    assign mergeable = cam_hit && !done_q[cam_idx] && (ntgt_q[cam_idx] != NTARGET);

    assign req_secondary = req_valid && mergeable;
    assign req_primary   = req_valid && !cam_hit && free_any && mem_req_ready;
    assign req_ready     = req_secondary || req_primary;
    assign req_id        = cam_hit ? cam_idx : free_idx;

    // The fill request is presented on any CAM-missing request that has an
    // entry to sit in; mem_req_ready only decides whether it is TAKEN.
    assign mem_req_valid = req_valid && !cam_hit && free_any;
    assign mem_req_addr  = req_blk;
    assign mem_req_id    = free_idx;

    // =========================================================================
    // Port 3 - replay select: lowest entry that is filled and still owes
    // targets; within an entry, targets replay in arrival order.
    // =========================================================================
    logic            rsel_any;
    logic [ID_W-1:0] rsel_i;

    always_comb begin
        rsel_any = 1'b0;
        rsel_i   = {ID_W{1'b0}};
        for (int i = 0; i < NMSHR; i++) begin
            if (!rsel_any && vld_q[i] && done_q[i] && (nrpl_q[i] != ntgt_q[i])) begin
                rsel_any = 1'b1;
                rsel_i   = i[ID_W-1:0];
            end
        end
    end

    int ti;   // flat target index  (combinational temp)
    int di;   // flat block-word index

    always_comb begin
        rpl_valid = rsel_any;
        rpl_id    = rsel_i;
        rpl_dst   = {DST_W{1'b0}};
        rpl_data  = {DATA_W{1'b0}};
        rpl_last  = 1'b0;
        if (rsel_any) begin
            ti        = int'(rsel_i) * NTARGET + int'(nrpl_q[rsel_i]);
            di        = int'(rsel_i) * WORDS   + int'(twof_q[ti]);
            rpl_dst   = tdst_q[ti];
            rpl_data  = dat_q[di];
            rpl_last  = ((nrpl_q[rsel_i] + 1) == ntgt_q[rsel_i]);
        end
    end

    // =========================================================================
    // Status
    // =========================================================================
    always_comb begin
        n_valid       = {CNT_W{1'b0}};
        n_outstanding = {CNT_W{1'b0}};
        for (int i = 0; i < NMSHR; i++) begin
            if (vld_q[i])              n_valid       = n_valid       + 1;
            if (vld_q[i] && !done_q[i]) n_outstanding = n_outstanding + 1;
        end
    end
    assign full = !free_any;

    // =========================================================================
    // State update.  The three ports touch disjoint fields whenever they touch
    // the same entry, so no write conflict is possible:
    //   merge   needs !done , last-replay needs done  -> exclusive
    //   primary needs !vld  , last-replay needs vld   -> exclusive
    //   fill    needs !done , replay      needs done  -> exclusive
    //   fill + merge on one entry (late merge) write different fields.
    // =========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < NMSHR; i++) begin
                vld_q[i]  <= 1'b0;
                done_q[i] <= 1'b0;
                blk_q[i]  <= {BADDR_W{1'b0}};
                ntgt_q[i] <= {TC_W{1'b0}};
                nrpl_q[i] <= {TC_W{1'b0}};
            end
            for (int k = 0; k < NMSHR*WORDS;   k++) dat_q[k]  <= {DATA_W{1'b0}};
            for (int k = 0; k < NMSHR*NTARGET; k++) begin
                tdst_q[k] <= {DST_W{1'b0}};
                twof_q[k] <= {WOFF_W{1'b0}};
            end
            err_fill <= 1'b0;
        end else begin
            // ---- 3. replay accepted -> advance / free ----------------------
            if (rpl_valid && rpl_ready) begin
                if (rpl_last) begin
                    vld_q[rsel_i]  <= 1'b0;
                    done_q[rsel_i] <= 1'b0;
                    ntgt_q[rsel_i] <= {TC_W{1'b0}};
                    nrpl_q[rsel_i] <= {TC_W{1'b0}};
                end else begin
                    nrpl_q[rsel_i] <= nrpl_q[rsel_i] + 1;
                end
            end

            // ---- 2b. tagged fill return (any order) ------------------------
            if (fill_valid) begin
                if (vld_q[fill_id] && !done_q[fill_id]) begin
                    for (int w = 0; w < WORDS; w++)
                        dat_q[int'(fill_id)*WORDS + w] <= fillw[w];
                    done_q[fill_id] <= 1'b1;
                end else begin
                    err_fill <= 1'b1;   // fill for an unallocated/already-filled tag
                end
            end

            // ---- 1. secondary merge / primary allocate ---------------------
            if (req_secondary) begin
                tdst_q[int'(cam_idx)*NTARGET + int'(ntgt_q[cam_idx])] <= req_dst;
                twof_q[int'(cam_idx)*NTARGET + int'(ntgt_q[cam_idx])] <= req_woff;
                ntgt_q[cam_idx] <= ntgt_q[cam_idx] + 1;
            end else if (req_primary) begin
                vld_q[free_idx]  <= 1'b1;
                done_q[free_idx] <= 1'b0;
                blk_q[free_idx]  <= req_blk;
                tdst_q[int'(free_idx)*NTARGET] <= req_dst;
                twof_q[int'(free_idx)*NTARGET] <= req_woff;
                ntgt_q[free_idx] <= 1;
                nrpl_q[free_idx] <= {TC_W{1'b0}};
            end
        end
    end

`ifndef SYNTHESIS
    // ---- debug taps for the waveform / testbench ---------------------------
    // (constant-index views of the state array; not part of the interface)
    logic dbg_v0, dbg_v1, dbg_v2, dbg_v3;
    logic dbg_d0, dbg_d1, dbg_d2, dbg_d3;
    assign dbg_v0 = (NMSHR > 0) ? vld_q[0]  : 1'b0;
    assign dbg_v1 = (NMSHR > 1) ? vld_q[1]  : 1'b0;
    assign dbg_v2 = (NMSHR > 2) ? vld_q[2]  : 1'b0;
    assign dbg_v3 = (NMSHR > 3) ? vld_q[3]  : 1'b0;
    assign dbg_d0 = (NMSHR > 0) ? done_q[0] : 1'b0;
    assign dbg_d1 = (NMSHR > 1) ? done_q[1] : 1'b0;
    assign dbg_d2 = (NMSHR > 2) ? done_q[2] : 1'b0;
    assign dbg_d3 = (NMSHR > 3) ? done_q[3] : 1'b0;
`endif

endmodule
