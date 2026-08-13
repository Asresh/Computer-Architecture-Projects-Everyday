// ---------------------------------------------------------------------------
// load_store_queue.sv - Day 33
//
// Out-of-order Load/Store Queue with speculative memory disambiguation:
// store-to-load forwarding, memory-order-violation detection, and pointer
// checkpoint recovery.
//
// This is the memory side of the out-of-order core the earlier days built the
// rest of.  Day 28 (rename) removed false register dependencies; Day 29 (issue
// queue) launches instructions as soon as their REGISTER operands are ready;
// Day 12 (ROB) retires them in order.  None of that machinery works for memory
// because a load's dependence on a store is not visible at rename time -- it
// depends on two addresses that are themselves computed by the instructions
// being scheduled.  The LSQ is the structure that discovers those dependences
// late, at execute time, and repairs the guesses that turn out wrong.
//
// Three jobs:
//
//   1. STORE-TO-LOAD FORWARDING.  A load searches the store queue for the
//      YOUNGEST store that is older than itself and hits the same address.  If
//      it finds one, the value comes from the queue, not the cache -- the
//      store has not been written to memory yet and will not be until it
//      retires, so memory does not have the right answer.
//
//   2. SPECULATIVE DISAMBIGUATION.  If an older store has not computed its
//      address yet, the load cannot know whether it aliases.  Blocking would
//      be correct and slow (it serialises the memory stream behind the oldest
//      unknown store).  This design speculates: the load executes anyway and
//      reports `ld_spec` so the core can see it took the gamble.
//
//   3. MEMORY-ORDER-VIOLATION DETECTION.  Every store, when its address
//      finally resolves, searches the LOAD queue backwards in time for a
//      YOUNGER load that already executed and hit the same address.  That load
//      read stale data -- the gamble lost.  The LSQ raises `mov_valid` with
//      the OLDEST such load's ROB tag plus the pointer checkpoint needed to
//      squash it and everything younger.
//
// Age is expressed entirely with wrap-extended circular pointers.  Each load,
// at dispatch, snapshots the store-queue tail (`lq_sqb`): that single pointer
// is the exact boundary between "stores older than me" and "stores younger
// than me", and it is what both the forwarding search and the violation search
// compare against -- one predicate, used from both directions.
//
// Everything is synthesizable, reset-safe, and free of data-dependent
// variable bit-selects.  LQ_DEPTH and SQ_DEPTH must be powers of two >= 2.
// ---------------------------------------------------------------------------

`timescale 1ns / 1ps

module load_store_queue #(
    parameter int ADDRW    = 32,  // byte address width (word-granular accesses)
    parameter int DATAW    = 32,  // data width
    parameter int LQ_DEPTH = 8,   // load-queue entries  (power of two, >= 2)
    parameter int SQ_DEPTH = 8,   // store-queue entries (power of two, >= 2)
    parameter int ROBW     = 6    // ROB tag width
) (
    input  logic                        clk,
    input  logic                        rst_n,

    // ---- dispatch: memory ops enter in PROGRAM ORDER, one per cycle -------
    input  logic                        disp_valid,
    input  logic                        disp_is_store,
    input  logic [ROBW-1:0]             disp_rob,
    output logic                        disp_ready,
    output logic [$clog2(LQ_DEPTH)-1:0] disp_lq_idx,   // slot the op will take
    output logic [$clog2(SQ_DEPTH)-1:0] disp_sq_idx,

    // ---- load execute: address ready, arrives OUT of program order --------
    input  logic                        ld_valid,
    input  logic [$clog2(LQ_DEPTH)-1:0] ld_idx,
    input  logic [ADDRW-1:0]            ld_addr,
    input  logic [DATAW-1:0]            ld_mem_data,   // D-cache data, same cycle
    output logic                        ld_done,
    output logic [DATAW-1:0]            ld_data,       // forwarded or from cache
    output logic                        ld_fwd,        // came from the store queue
    output logic [$clog2(SQ_DEPTH)-1:0] ld_fwd_idx,    // which store supplied it
    output logic                        ld_mem_req,    // needs the D-cache
    output logic                        ld_spec,       // an older store's address
                                                       // was still unknown

    // ---- store execute: address + data, OUT of program order --------------
    input  logic                        st_valid,
    input  logic [$clog2(SQ_DEPTH)-1:0] st_idx,
    input  logic [ADDRW-1:0]            st_addr,
    input  logic [DATAW-1:0]            st_data,

    // ---- memory-order violation (squash request to the ROB) ---------------
    output logic                        mov_valid,
    output logic [ROBW-1:0]             mov_rob,       // oldest offending load
    output logic [$clog2(LQ_DEPTH)-1:0] mov_lq_idx,
    output logic [$clog2(LQ_DEPTH):0]   mov_lq_ptr,    // recovery checkpoint:
    output logic [$clog2(SQ_DEPTH):0]   mov_sq_ptr,    // feed back as flush_*

    // ---- commit: in program order, driven by the ROB ----------------------
    input  logic                        commit_load,
    input  logic                        commit_store,
    output logic                        lq_head_ready, // head load has executed
    output logic [ROBW-1:0]             lq_head_rob,
    output logic [ADDRW-1:0]            lq_head_addr,
    output logic [DATAW-1:0]            lq_head_data,
    output logic                        sq_head_ready, // head store has addr+data
    output logic [ROBW-1:0]             sq_head_rob,
    output logic                        mem_we,        // retiring store -> memory
    output logic [ADDRW-1:0]            mem_addr,
    output logic [DATAW-1:0]            mem_data,

    // ---- flush to a checkpoint (branch mispredict or a violation squash) --
    input  logic                        flush,
    input  logic [$clog2(LQ_DEPTH):0]   flush_lq_ptr,  // keep everything older
    input  logic [$clog2(SQ_DEPTH):0]   flush_sq_ptr,

    // ---- status; the tail pointers ARE the branch checkpoint --------------
    output logic [$clog2(LQ_DEPTH):0]   lq_tail_ptr,
    output logic [$clog2(SQ_DEPTH):0]   sq_tail_ptr,
    output logic [$clog2(LQ_DEPTH):0]   lq_count,
    output logic [$clog2(SQ_DEPTH):0]   sq_count,
    output logic                        lq_full,
    output logic                        sq_full,
    output logic                        lq_empty,
    output logic                        sq_empty
);

    // ---- derived widths ----------------------------------------------------
    localparam int LQIW = $clog2(LQ_DEPTH);      // slot-index width
    localparam int SQIW = $clog2(SQ_DEPTH);
    localparam int LQPW = LQIW + 1;              // wrap-extended pointer width
    localparam int SQPW = SQIW + 1;

    // =======================================================================
    // State
    // =======================================================================
    // Load queue.  lq_sqb is the store-queue tail pointer snapshotted at
    // dispatch: stores strictly older than this load are exactly those with a
    // pointer in [sq_head, lq_sqb).  lq_fwd/lq_fwdi remember where the value
    // came from so a later store can tell whether it actually invalidated it.
    logic                  lq_valid [LQ_DEPTH];
    logic                  lq_exec  [LQ_DEPTH];   // address computed, load done
    logic [ADDRW-1:0]      lq_addr  [LQ_DEPTH];
    logic [DATAW-1:0]      lq_data  [LQ_DEPTH];   // result (a real core writes
                                                  // this to the PRF instead)
    logic [ROBW-1:0]       lq_rob   [LQ_DEPTH];
    logic [SQPW-1:0]       lq_sqb   [LQ_DEPTH];   // "older than me" boundary
    logic                  lq_fwd_q [LQ_DEPTH];   // value came from a store
    logic [SQIW-1:0]       lq_fwdi  [LQ_DEPTH];   // ... from this store slot
    logic [SQPW-1:0]       lq_fwdp  [LQ_DEPTH];   // ... at this queue POINTER.
                                                  // The slot index alone is not
                                                  // enough: the covering store
                                                  // may retire and leave the
                                                  // queue while this load is
                                                  // still exposed to squashes,
                                                  // and then its slot index no
                                                  // longer ranks against
                                                  // sq_head.  See the violation
                                                  // search below.

    // Store queue.  Address and data resolve together here; a real machine
    // splits STA/STD and must also cope with an address-known/data-unknown
    // store (which blocks forwarding rather than allowing it).
    logic                  sq_valid [SQ_DEPTH];
    logic                  sq_exec  [SQ_DEPTH];
    logic [ADDRW-1:0]      sq_addr  [SQ_DEPTH];
    logic [DATAW-1:0]      sq_data  [SQ_DEPTH];
    logic [ROBW-1:0]       sq_rob   [SQ_DEPTH];

    logic [LQPW-1:0]       lq_head, lq_tail;
    logic [SQPW-1:0]       sq_head, sq_tail;

    logic [LQIW-1:0]       lq_head_i, lq_tail_i;
    logic [SQIW-1:0]       sq_head_i, sq_tail_i;

    assign lq_head_i = lq_head[LQIW-1:0];
    assign lq_tail_i = lq_tail[LQIW-1:0];
    assign sq_head_i = sq_head[SQIW-1:0];
    assign sq_tail_i = sq_tail[SQIW-1:0];

    // Occupancy from wrap-extended pointers: one extra bit distinguishes full
    // from empty when the index halves are equal.
    assign lq_count    = lq_tail - lq_head;
    assign sq_count    = sq_tail - sq_head;
    assign lq_full     = (lq_count == LQPW'(LQ_DEPTH));
    assign sq_full     = (sq_count == SQPW'(SQ_DEPTH));
    assign lq_empty    = (lq_count == '0);
    assign sq_empty    = (sq_count == '0);
    assign lq_tail_ptr = lq_tail;
    assign sq_tail_ptr = sq_tail;

    // =======================================================================
    // Port firing.  A flush cycle is a dead cycle for every port: the squash
    // wins and whatever was in flight is re-issued after recovery.  Execute
    // ports are also gated on the target entry still being valid, which is
    // what makes a flush racing an in-flight execute harmless.
    // =======================================================================
    logic disp_fire, ld_fire, st_fire, cmt_ld_fire, cmt_st_fire;

    assign disp_ready  = !flush && (disp_is_store ? !sq_full : !lq_full);
    assign disp_fire   = disp_valid && disp_ready;
    assign disp_lq_idx = lq_tail_i;
    assign disp_sq_idx = sq_tail_i;

    assign ld_fire     = ld_valid && !flush && lq_valid[ld_idx];
    assign st_fire     = st_valid && !flush && sq_valid[st_idx];

    assign lq_head_ready = !lq_empty && lq_valid[lq_head_i] && lq_exec[lq_head_i];
    assign sq_head_ready = !sq_empty && sq_valid[sq_head_i] && sq_exec[sq_head_i];
    assign lq_head_rob   = lq_rob [lq_head_i];
    assign lq_head_addr  = lq_addr[lq_head_i];
    assign lq_head_data  = lq_data[lq_head_i];
    assign sq_head_rob   = sq_rob [sq_head_i];

    assign cmt_ld_fire = commit_load  && !flush && lq_head_ready;
    assign cmt_st_fire = commit_store && !flush && sq_head_ready;

    // A retiring store is the only thing that ever writes memory.
    assign mem_we   = cmt_st_fire;
    assign mem_addr = sq_addr[sq_head_i];
    assign mem_data = sq_data[sq_head_i];

    // =======================================================================
    // Same-cycle store-execute bypass
    //
    // The load search reads REGISTERED store-queue state, so a store resolving
    // its address in the very same cycle would be invisible to it -- and the
    // violation search below reads registered LOAD state, so it would not see
    // that cycle's load either.  Between them the pair would slip through
    // undetected.  Bypassing the executing store into the load's search closes
    // the hole from the load side, which is the cheap side: the load simply
    // forwards from a store that resolved this cycle.
    // =======================================================================
    logic             sq_e_exec [SQ_DEPTH];
    logic [ADDRW-1:0] sq_e_addr [SQ_DEPTH];
    logic [DATAW-1:0] sq_e_data [SQ_DEPTH];

    always_comb begin
        for (int i = 0; i < SQ_DEPTH; i++) begin
            logic byp;
            byp          = st_fire && (st_idx == SQIW'(i));
            sq_e_exec[i] = sq_exec[i] || byp;
            sq_e_addr[i] = byp ? st_addr : sq_addr[i];
            sq_e_data[i] = byp ? st_data : sq_data[i];
        end
    end

    // =======================================================================
    // Load execute: search the store queue
    //
    // Older-than-me test.  ld_nolder = lq_sqb - sq_head is the exact number of
    // stores older than this load that are still in the queue (retired ones
    // have already left through the head and are in memory).  An entry is
    // older iff its distance from the head is below that count -- no sequence
    // numbers, no age matrix, and correct across arbitrary pointer wrap.
    //
    // Among the matches the YOUNGEST wins: it is the last write to that
    // address before the load, and it supersedes every older one.
    // =======================================================================
    logic [SQPW-1:0]     ld_nolder;
    logic [SQ_DEPTH-1:0] sq_older, sq_match, sq_unknown;
    logic                fwd_hit;
    logic [SQIW-1:0]     fwd_idx, fwd_rel;
    logic [SQPW-1:0]     fwd_ptr;
    logic [DATAW-1:0]    fwd_data;

    always_comb begin
        ld_nolder = lq_sqb[ld_idx] - sq_head;
        fwd_hit   = 1'b0;
        fwd_idx   = '0;
        fwd_rel   = '0;
        fwd_data  = '0;
        for (int i = 0; i < SQ_DEPTH; i++) begin
            logic [SQIW-1:0] rel;
            rel           = SQIW'(i) - sq_head_i;               // age rank
            sq_older[i]   = sq_valid[i] && ({1'b0, rel} < ld_nolder);
            sq_match[i]   = sq_older[i] &&  sq_e_exec[i] &&
                            (sq_e_addr[i] == ld_addr);
            sq_unknown[i] = sq_older[i] && !sq_e_exec[i];
            if (sq_match[i] && (!fwd_hit || (rel > fwd_rel))) begin
                fwd_hit  = 1'b1;
                fwd_rel  = rel;
                fwd_idx  = SQIW'(i);
                fwd_data = sq_e_data[i];
            end
        end
    end

    // Wrap-extended pointer of the store that supplied the value.  Unlike a
    // slot index this stays meaningful after that store has retired.
    assign fwd_ptr    = sq_head + {1'b0, fwd_rel};

    assign ld_done    = ld_fire;
    assign ld_fwd     = ld_fire &&  fwd_hit;
    assign ld_mem_req = ld_fire && !fwd_hit;
    assign ld_fwd_idx = fwd_idx;
    assign ld_data    = fwd_hit ? fwd_data : ld_mem_data;
    // The speculation flag: at least one older store had no address yet, so
    // this result is a guess that the store searches below may overturn.
    assign ld_spec    = ld_fire && (|sq_unknown);

    // =======================================================================
    // Store execute: search the load queue for a violation
    //
    // Same predicate, read from the other end: store S is older than load L
    // iff S's age rank is below L's own ld_nolder boundary.  A younger load
    // that already executed and hit this address read a value that predates
    // this store -- unless it forwarded from a store that is itself YOUNGER
    // than S, in which case S was already superseded and the load is fine.
    //
    // That last exception CANNOT be evaluated with slot indices ranked against
    // sq_head.  In the interesting case the covering store F is OLDER than S,
    // and since stores retire in order and S has not retired, F may already
    // have retired and left the queue -- at which point `F_slot - sq_head` has
    // wrapped and ranks F as the youngest entry instead of an absent one, which
    // reads as "covered" and silently drops a real violation.
    //
    // Rank both stores against the load's OWN dispatch boundary instead.  That
    // boundary is frozen at dispatch and every store older than the load sits
    // within SQ_DEPTH below it, so `boundary - pointer` is a stable age
    // distance (bigger = older) that no head movement can disturb, and F is
    // covering exactly when it is no older than S.
    //
    // The OLDEST violator is reported, because squashing it necessarily
    // squashes every younger load with it.
    // =======================================================================
    logic [SQIW-1:0]     st_rel;
    logic [SQPW-1:0]     st_ptr;
    logic [LQ_DEPTH-1:0] lq_vio;
    logic                vio_hit;
    logic [LQIW-1:0]     vio_idx, vio_rel;
    logic [ROBW-1:0]     vio_rob;
    logic [SQPW-1:0]     vio_sqb;

    always_comb begin
        st_rel  = st_idx - sq_head_i;
        st_ptr  = sq_head + {1'b0, st_rel};
        vio_hit = 1'b0;
        vio_idx = '0;
        vio_rel = '0;
        vio_rob = '0;
        vio_sqb = '0;
        for (int l = 0; l < LQ_DEPTH; l++) begin
            logic [SQPW-1:0] nold, dist_s, dist_f;
            logic [LQIW-1:0] lrel;
            logic            st_older, covered;
            nold      = lq_sqb[l] - sq_head;
            lrel      = LQIW'(l) - lq_head_i;
            st_older  = ({1'b0, st_rel} < nold);
            // Age distances below this load's boundary; bigger = older.
            dist_s    = lq_sqb[l] - st_ptr;
            dist_f    = lq_sqb[l] - lq_fwdp[l];
            covered   = lq_fwd_q[l] && (dist_f <= dist_s);
            lq_vio[l] = lq_valid[l] && lq_exec[l] && st_older &&
                        (lq_addr[l] == st_addr) && !covered;
            if (lq_vio[l] && (!vio_hit || (lrel < vio_rel))) begin
                vio_hit = 1'b1;
                vio_rel = lrel;
                vio_idx = LQIW'(l);
                vio_rob = lq_rob[l];
                vio_sqb = lq_sqb[l];
            end
        end
    end

    assign mov_valid  = st_fire && vio_hit;
    assign mov_rob    = vio_rob;
    assign mov_lq_idx = vio_idx;
    // Recovery checkpoint: rewind the load queue to the offending load itself
    // (it is refetched) and the store queue to the boundary it recorded.
    assign mov_lq_ptr = lq_head + {1'b0, vio_rel};
    assign mov_sq_ptr = vio_sqb;

    // =======================================================================
    // Sequential state
    // =======================================================================
    logic [LQPW-1:0] lq_keep;
    logic [SQPW-1:0] sq_keep;
    assign lq_keep = flush_lq_ptr - lq_head;   // entries surviving the squash
    assign sq_keep = flush_sq_ptr - sq_head;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            lq_head <= '0;
            lq_tail <= '0;
            sq_head <= '0;
            sq_tail <= '0;
            for (int i = 0; i < LQ_DEPTH; i++) begin
                lq_valid[i] <= 1'b0;
                lq_exec [i] <= 1'b0;
                lq_addr [i] <= '0;
                lq_data [i] <= '0;
                lq_rob  [i] <= '0;
                lq_sqb  [i] <= '0;
                lq_fwd_q[i] <= 1'b0;
                lq_fwdi [i] <= '0;
                lq_fwdp [i] <= '0;
            end
            for (int i = 0; i < SQ_DEPTH; i++) begin
                sq_valid[i] <= 1'b0;
                sq_exec [i] <= 1'b0;
                sq_addr [i] <= '0;
                sq_data [i] <= '0;
                sq_rob  [i] <= '0;
            end
        end else begin
            // ---- dispatch (program order) ---------------------------------
            if (disp_fire) begin
                if (disp_is_store) begin
                    sq_valid[sq_tail_i] <= 1'b1;
                    sq_exec [sq_tail_i] <= 1'b0;
                    sq_rob  [sq_tail_i] <= disp_rob;
                    sq_tail             <= sq_tail + SQPW'(1);
                end else begin
                    lq_valid[lq_tail_i] <= 1'b1;
                    lq_exec [lq_tail_i] <= 1'b0;
                    lq_fwd_q[lq_tail_i] <= 1'b0;
                    lq_rob  [lq_tail_i] <= disp_rob;
                    // The whole disambiguation scheme rests on this one line:
                    // freeze the store-queue tail as the load's age boundary.
                    lq_sqb  [lq_tail_i] <= sq_tail;
                    lq_tail             <= lq_tail + LQPW'(1);
                end
            end

            // ---- load execute ---------------------------------------------
            if (ld_fire) begin
                lq_exec [ld_idx] <= 1'b1;
                lq_addr [ld_idx] <= ld_addr;
                lq_data [ld_idx] <= ld_data;
                lq_fwd_q[ld_idx] <= fwd_hit;
                lq_fwdi [ld_idx] <= fwd_idx;
                lq_fwdp [ld_idx] <= fwd_ptr;
            end

            // ---- store execute --------------------------------------------
            if (st_fire) begin
                sq_exec[st_idx] <= 1'b1;
                sq_addr[st_idx] <= st_addr;
                sq_data[st_idx] <= st_data;
            end

            // ---- commit ----------------------------------------------------
            if (cmt_ld_fire) begin
                lq_valid[lq_head_i] <= 1'b0;
                lq_head             <= lq_head + LQPW'(1);
            end
            if (cmt_st_fire) begin
                sq_valid[sq_head_i] <= 1'b0;
                sq_head             <= sq_head + SQPW'(1);
            end

            // ---- flush: rewind both tails to the checkpoint ----------------
            // Last in the block so it overrides every port above; entries at
            // or beyond the checkpoint are invalidated in one cycle.
            if (flush) begin
                lq_tail <= flush_lq_ptr;
                sq_tail <= flush_sq_ptr;
                for (int i = 0; i < LQ_DEPTH; i++)
                    if ({1'b0, LQIW'(i) - lq_head_i} >= lq_keep)
                        lq_valid[i] <= 1'b0;
                for (int i = 0; i < SQ_DEPTH; i++)
                    if ({1'b0, SQIW'(i) - sq_head_i} >= sq_keep)
                        sq_valid[i] <= 1'b0;
            end
        end
    end

endmodule
