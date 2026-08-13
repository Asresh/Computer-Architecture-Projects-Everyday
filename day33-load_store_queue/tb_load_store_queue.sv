// ---------------------------------------------------------------------------
// tb_load_store_queue.sv - Day 33
//
// Self-checking testbench for the out-of-order Load/Store Queue.
//
// It contains FIVE independent checkers:
//
//   1. GOLDEN MODEL - a behavioural re-implementation of the LSQ that defines
//      age with GLOBAL SEQUENCE NUMBERS rather than circular pointers.  "Store
//      S is older than load L" is literally `s_seq < l_seq` in the model and
//      `rel(S) < L.sq_boundary - sq_head` in the DUT; the two formulations
//      share nothing but the answer.  Every cycle all 31 outputs AND the full
//      per-entry state of both queues are compared against it.
//
//   2. VALUE CORRECTNESS (the end-to-end property).  A reference memory is
//      updated only when a store RETIRES.  Because ops retire in program
//      order, every store older than a retiring load has already landed in
//      that memory and no younger store has -- so at the instant a load
//      commits, ref_mem[addr] IS its architectural value.  Every committed
//      load is checked against it.  This is what proves the disambiguation
//      machinery works: a missed violation shows up here as a wrong value.
//
//   3. RECOVERY-POINTER CHECK.  The testbench records the (lq_ptr, sq_ptr)
//      checkpoint at every dispatch.  When the DUT reports a violation, its
//      mov_lq_ptr / mov_sq_ptr must equal the checkpoint recorded when the
//      offending load was dispatched -- checked against the testbench's own
//      records, not the DUT's.
//
//   4. IN-ORDER DRAIN.  Stores may execute out of order but must reach memory
//      in program order; the sequence number of each mem_we is checked to be
//      strictly increasing.
//
//   5. FORWARD PROGRESS.  Replays rewind the program counter, so a livelock
//      would show up as a program that never advances.  The number of
//      committed ops and the replay count are reported.
//
// Phase 1 - directed 16-cycle window: speculate -> violate -> squash ->
//           replay -> forward -> retire   (this is the waveform in docs/)
// Phase 2 - directed corner cases (full, youngest-match, covered-forward,
//           oldest-of-several violators, same-cycle bypass, flush gating,
//           execute-into-a-squashed-slot, dual commit, no-op flush, wrap)
// Phase 3 - 4000 randomised cycles over an aliasing address pool with random
//           out-of-order execution, random branch-mispredict flushes and full
//           violation-driven replay
//
// The DUT is parameterised for any power-of-two depths >= 2, and phases 1 and 3
// follow the parameters.  The phase-2 directed vectors do not: case (b) needs
// three older stores resident at once to prove the YOUNGEST match wins, so the
// directed phase assumes LQ_DEPTH >= 4 and SQ_DEPTH >= 4.  At depth 2 those two
// hardcoded expectations fail while every lockstep golden-model comparison still
// passes.
// ---------------------------------------------------------------------------

`timescale 1ns / 1ps

module tb_load_store_queue;

    // =======================================================================
    // Configuration (must match the DUT instantiation below)
    // =======================================================================
    localparam int ADDRW    = 32;
    localparam int DATAW    = 32;
    localparam int LQ_DEPTH = 8;
    localparam int SQ_DEPTH = 8;
    localparam int ROBW     = 6;

    localparam int LQIW  = $clog2(LQ_DEPTH);
    localparam int SQIW  = $clog2(SQ_DEPTH);
    localparam int LQPW  = LQIW + 1;
    localparam int SQPW  = SQIW + 1;
    localparam int LQMOD = 2 * LQ_DEPTH;      // pointer modulus
    localparam int SQMOD = 2 * SQ_DEPTH;

    localparam int NADDR = 8;                 // aliasing address pool
    localparam int BASE  = 32'h0000_0100;

    localparam int NPROG = 3000;              // program length
    localparam int NRAND = 4000;              // randomised cycles

    // =======================================================================
    // DUT interface
    // =======================================================================
    logic                clk, rst_n;

    logic                disp_valid, disp_is_store;
    logic [ROBW-1:0]     disp_rob;
    logic                disp_ready;
    logic [LQIW-1:0]     disp_lq_idx;
    logic [SQIW-1:0]     disp_sq_idx;

    logic                ld_valid;
    logic [LQIW-1:0]     ld_idx;
    logic [ADDRW-1:0]    ld_addr;
    logic [DATAW-1:0]    ld_mem_data;
    logic                ld_done;
    logic [DATAW-1:0]    ld_data;
    logic                ld_fwd;
    logic [SQIW-1:0]     ld_fwd_idx;
    logic                ld_mem_req;
    logic                ld_spec;

    logic                st_valid;
    logic [SQIW-1:0]     st_idx;
    logic [ADDRW-1:0]    st_addr;
    logic [DATAW-1:0]    st_data;

    logic                mov_valid;
    logic [ROBW-1:0]     mov_rob;
    logic [LQIW-1:0]     mov_lq_idx;
    logic [LQPW-1:0]     mov_lq_ptr;
    logic [SQPW-1:0]     mov_sq_ptr;

    logic                commit_load, commit_store;
    logic                lq_head_ready;
    logic [ROBW-1:0]     lq_head_rob;
    logic [ADDRW-1:0]    lq_head_addr;
    logic [DATAW-1:0]    lq_head_data;
    logic                sq_head_ready;
    logic [ROBW-1:0]     sq_head_rob;
    logic                mem_we;
    logic [ADDRW-1:0]    mem_addr;
    logic [DATAW-1:0]    mem_data;

    logic                flush;
    logic [LQPW-1:0]     flush_lq_ptr;
    logic [SQPW-1:0]     flush_sq_ptr;

    logic [LQPW-1:0]     lq_tail_ptr;
    logic [SQPW-1:0]     sq_tail_ptr;
    logic [LQPW-1:0]     lq_count;
    logic [SQPW-1:0]     sq_count;
    logic                lq_full, sq_full, lq_empty, sq_empty;

    load_store_queue #(
        .ADDRW    (ADDRW),
        .DATAW    (DATAW),
        .LQ_DEPTH (LQ_DEPTH),
        .SQ_DEPTH (SQ_DEPTH),
        .ROBW     (ROBW)
    ) dut (
        .clk (clk), .rst_n (rst_n),
        .disp_valid (disp_valid), .disp_is_store (disp_is_store),
        .disp_rob (disp_rob), .disp_ready (disp_ready),
        .disp_lq_idx (disp_lq_idx), .disp_sq_idx (disp_sq_idx),
        .ld_valid (ld_valid), .ld_idx (ld_idx), .ld_addr (ld_addr),
        .ld_mem_data (ld_mem_data), .ld_done (ld_done), .ld_data (ld_data),
        .ld_fwd (ld_fwd), .ld_fwd_idx (ld_fwd_idx), .ld_mem_req (ld_mem_req),
        .ld_spec (ld_spec),
        .st_valid (st_valid), .st_idx (st_idx), .st_addr (st_addr),
        .st_data (st_data),
        .mov_valid (mov_valid), .mov_rob (mov_rob), .mov_lq_idx (mov_lq_idx),
        .mov_lq_ptr (mov_lq_ptr), .mov_sq_ptr (mov_sq_ptr),
        .commit_load (commit_load), .commit_store (commit_store),
        .lq_head_ready (lq_head_ready), .lq_head_rob (lq_head_rob),
        .lq_head_addr (lq_head_addr), .lq_head_data (lq_head_data),
        .sq_head_ready (sq_head_ready), .sq_head_rob (sq_head_rob),
        .mem_we (mem_we), .mem_addr (mem_addr), .mem_data (mem_data),
        .flush (flush), .flush_lq_ptr (flush_lq_ptr),
        .flush_sq_ptr (flush_sq_ptr),
        .lq_tail_ptr (lq_tail_ptr), .sq_tail_ptr (sq_tail_ptr),
        .lq_count (lq_count), .sq_count (sq_count),
        .lq_full (lq_full), .sq_full (sq_full),
        .lq_empty (lq_empty), .sq_empty (sq_empty)
    );

    // =======================================================================
    // Clock / bookkeeping
    // =======================================================================
    integer errors, checks, cyc_no;
    integer n_fwd, n_spec, n_vio, n_replay, n_flush, n_commit;

    initial clk = 1'b0;
    always #5 clk = ~clk;

    task automatic chk(input string nm, input integer got, input integer exp);
        begin
            checks = checks + 1;
            if (got !== exp) begin
                errors = errors + 1;
                $display("  ** MISMATCH c%0d t=%0t : %s  got=%0d exp=%0d",
                         cyc_no, $time, nm, got, exp);
                if (errors > 25) begin
                    $display("  too many errors - stopping");
                    $finish;
                end
            end
        end
    endtask

    // =======================================================================
    // Reference memory.  Written ONLY when a store retires; ld_mem_data is a
    // combinational read of it, so a load that does not forward sees exactly
    // what the D-cache would give it.
    // =======================================================================
    logic [DATAW-1:0] ref_mem [NADDR];

    function automatic integer aidx(input logic [ADDRW-1:0] a);
        aidx = ((a - BASE) >> 2) % NADDR;
    endfunction

    function automatic [ADDRW-1:0] mkaddr(input integer k);
        mkaddr = BASE + (k % NADDR) * 4;
    endfunction

    always_comb ld_mem_data = ref_mem[aidx(ld_addr)];

    // =======================================================================
    // GOLDEN MODEL  (checker 1)
    //
    // Same entries, same slots, but age is a global sequence number.  Nothing
    // here does circular-pointer arithmetic to decide who is older than whom.
    // The pointer fields (g_lqptr / g_lqsqb) exist only because two of the
    // DUT's OUTPUTS are pointers; they play no part in any decision.
    // =======================================================================
    bit               g_lqv  [LQ_DEPTH];
    bit               g_lqe  [LQ_DEPTH];
    integer           g_lqs  [LQ_DEPTH];   // program sequence number
    logic [ADDRW-1:0] g_lqa  [LQ_DEPTH];
    logic [DATAW-1:0] g_lqd  [LQ_DEPTH];
    logic [ROBW-1:0]  g_lqr  [LQ_DEPTH];
    bit               g_lqf  [LQ_DEPTH];   // forwarded
    integer           g_lqfs [LQ_DEPTH];   // seq of the store it forwarded from
    integer           g_lqfi [LQ_DEPTH];   // slot of that store
    integer           g_lqptr[LQ_DEPTH];   // its own queue pointer at dispatch
    integer           g_lqsqb[LQ_DEPTH];   // store-queue pointer at dispatch

    bit               g_sqv  [SQ_DEPTH];
    bit               g_sqe  [SQ_DEPTH];
    integer           g_sqs  [SQ_DEPTH];
    logic [ADDRW-1:0] g_sqa  [SQ_DEPTH];
    logic [DATAW-1:0] g_sqd  [SQ_DEPTH];
    logic [ROBW-1:0]  g_sqr  [SQ_DEPTH];

    integer g_lq_head, g_lq_tail, g_sq_head, g_sq_tail, g_seq;

    // Expected outputs
    bit               e_disp_ready;
    integer           e_disp_lq_idx, e_disp_sq_idx;
    bit               e_ld_done, e_ld_fwd, e_ld_mem_req, e_ld_spec;
    logic [DATAW-1:0] e_ld_data;
    integer           e_ld_fwd_idx;
    bit               e_mov_valid;
    logic [ROBW-1:0]  e_mov_rob;
    integer           e_mov_lq_idx, e_mov_lq_ptr, e_mov_sq_ptr;
    bit               e_lq_hrdy, e_sq_hrdy, e_mem_we;
    logic [ROBW-1:0]  e_lq_hrob, e_sq_hrob;
    logic [ADDRW-1:0] e_lq_haddr, e_mem_addr;
    logic [DATAW-1:0] e_lq_hdata, e_mem_data;

    // Fire signals recomputed by the model (never read from the DUT)
    bit     g_disp_fire, g_ld_fire, g_st_fire, g_cmt_ld, g_cmt_st;
    integer g_disp_slot, g_disp_seq;

    // Same-cycle store-execute bypass, modelled independently
    bit               ge_exec [SQ_DEPTH];
    logic [ADDRW-1:0] ge_addr [SQ_DEPTH];
    logic [DATAW-1:0] ge_data [SQ_DEPTH];

    // The seq threshold that accompanies a flush (a checkpoint is one program
    // point, so ONE threshold squashes the right entries in both queues).
    integer flush_seq;

    task automatic golden_eval;
        integer i, l, best, best_seq, vbest, vbest_seq, ld_seq, st_seq;
        integer lqh, sqh, lq_cnt, sq_cnt;
        bit     unk, covered;
        begin
            lq_cnt = g_lq_tail - g_lq_head;
            sq_cnt = g_sq_tail - g_sq_head;
            lqh    = g_lq_head % LQ_DEPTH;
            sqh    = g_sq_head % SQ_DEPTH;

            // ---- dispatch ------------------------------------------------
            e_disp_ready  = !flush &&
                            (disp_is_store ? (sq_cnt != SQ_DEPTH)
                                           : (lq_cnt != LQ_DEPTH));
            e_disp_lq_idx = g_lq_tail % LQ_DEPTH;
            e_disp_sq_idx = g_sq_tail % SQ_DEPTH;
            g_disp_fire   = disp_valid && e_disp_ready;

            // ---- port firing ---------------------------------------------
            g_st_fire = st_valid && !flush && g_sqv[st_idx];
            g_ld_fire = ld_valid && !flush && g_lqv[ld_idx];

            // ---- effective store state (same-cycle bypass) ---------------
            for (i = 0; i < SQ_DEPTH; i = i + 1) begin
                if (g_st_fire && (st_idx == i)) begin
                    ge_exec[i] = 1'b1;
                    ge_addr[i] = st_addr;
                    ge_data[i] = st_data;
                end else begin
                    ge_exec[i] = g_sqe[i];
                    ge_addr[i] = g_sqa[i];
                    ge_data[i] = g_sqd[i];
                end
            end

            // ---- load search: youngest older matching store, by SEQ ------
            ld_seq   = g_lqs[ld_idx];
            best     = -1;
            best_seq = -1;
            unk      = 1'b0;
            for (i = 0; i < SQ_DEPTH; i = i + 1) begin
                if (g_sqv[i] && (g_sqs[i] < ld_seq)) begin
                    if (!ge_exec[i]) begin
                        unk = 1'b1;
                    end else if ((ge_addr[i] === ld_addr) &&
                                 (g_sqs[i] > best_seq)) begin
                        best     = i;
                        best_seq = g_sqs[i];
                    end
                end
            end
            e_ld_done    = g_ld_fire;
            e_ld_fwd     = g_ld_fire && (best >= 0);
            e_ld_mem_req = g_ld_fire && (best <  0);
            e_ld_spec    = g_ld_fire && unk;
            e_ld_fwd_idx = (best >= 0) ? best : 0;
            e_ld_data    = (best >= 0) ? ge_data[best] : ld_mem_data;

            // ---- store search: oldest younger executed aliasing load -----
            st_seq    = g_sqs[st_idx];
            vbest     = -1;
            vbest_seq = 0;
            for (l = 0; l < LQ_DEPTH; l = l + 1) begin
                if (g_lqv[l] && g_lqe[l] && (g_lqs[l] > st_seq) &&
                    (g_lqa[l] === st_addr)) begin
                    // Superseded: it took its value from a store that is
                    // itself younger than this one, so this one is invisible.
                    covered = g_lqf[l] && (g_lqfs[l] >= st_seq);
                    if (!covered && ((vbest < 0) || (g_lqs[l] < vbest_seq)))
                    begin
                        vbest     = l;
                        vbest_seq = g_lqs[l];
                    end
                end
            end
            e_mov_valid  = g_st_fire && (vbest >= 0);
            e_mov_rob    = (vbest >= 0) ? g_lqr[vbest]    : {ROBW{1'b0}};
            e_mov_lq_idx = (vbest >= 0) ? vbest           : 0;
            e_mov_lq_ptr = (vbest >= 0) ? g_lqptr[vbest]  : 0;
            e_mov_sq_ptr = (vbest >= 0) ? g_lqsqb[vbest]  : 0;

            // ---- commit ---------------------------------------------------
            e_lq_hrdy  = (lq_cnt != 0) && g_lqv[lqh] && g_lqe[lqh];
            e_sq_hrdy  = (sq_cnt != 0) && g_sqv[sqh] && g_sqe[sqh];
            e_lq_hrob  = g_lqr[lqh];
            e_lq_haddr = g_lqa[lqh];
            e_lq_hdata = g_lqd[lqh];
            e_sq_hrob  = g_sqr[sqh];
            g_cmt_ld   = commit_load  && !flush && e_lq_hrdy;
            g_cmt_st   = commit_store && !flush && e_sq_hrdy;
            e_mem_we   = g_cmt_st;
            e_mem_addr = g_sqa[sqh];
            e_mem_data = g_sqd[sqh];
        end
    endtask

    task automatic golden_update;
        integer i, lqh, sqh, ndrop;
        begin
            g_disp_slot = -1;
            g_disp_seq  = -1;
            lqh = g_lq_head % LQ_DEPTH;
            sqh = g_sq_head % SQ_DEPTH;

            if (g_disp_fire) begin
                if (disp_is_store) begin
                    i          = g_sq_tail % SQ_DEPTH;
                    g_sqv [i]  = 1'b1;
                    g_sqe [i]  = 1'b0;
                    g_sqs [i]  = g_seq;
                    g_sqr [i]  = disp_rob;
                    g_disp_slot = i;
                    g_sq_tail  = g_sq_tail + 1;
                end else begin
                    i          = g_lq_tail % LQ_DEPTH;
                    g_lqv [i]  = 1'b1;
                    g_lqe [i]  = 1'b0;
                    g_lqf [i]  = 1'b0;
                    g_lqs [i]  = g_seq;
                    g_lqr [i]  = disp_rob;
                    g_lqptr[i] = g_lq_tail % LQMOD;
                    g_lqsqb[i] = g_sq_tail % SQMOD;
                    g_disp_slot = i;
                    g_lq_tail  = g_lq_tail + 1;
                end
                g_disp_seq = g_seq;
                g_seq      = g_seq + 1;
            end

            if (g_ld_fire) begin
                g_lqe [ld_idx] = 1'b1;
                g_lqa [ld_idx] = ld_addr;
                g_lqd [ld_idx] = e_ld_data;
                g_lqf [ld_idx] = e_ld_fwd;
                g_lqfi[ld_idx] = e_ld_fwd_idx;
                g_lqfs[ld_idx] = e_ld_fwd ? g_sqs[e_ld_fwd_idx] : 0;
            end

            if (g_st_fire) begin
                g_sqe[st_idx] = 1'b1;
                g_sqa[st_idx] = st_addr;
                g_sqd[st_idx] = st_data;
            end

            if (g_cmt_ld) begin
                g_lqv[lqh] = 1'b0;
                g_lq_head  = g_lq_head + 1;
            end
            if (g_cmt_st) begin
                ref_mem[aidx(g_sqa[sqh])] = g_sqd[sqh];
                g_sqv[sqh] = 1'b0;
                g_sq_head  = g_sq_head + 1;
            end

            if (flush) begin
                ndrop = 0;
                for (i = 0; i < LQ_DEPTH; i = i + 1)
                    if (g_lqv[i] && (g_lqs[i] >= flush_seq)) begin
                        g_lqv[i] = 1'b0;
                        ndrop    = ndrop + 1;
                    end
                g_lq_tail = g_lq_tail - ndrop;
                ndrop = 0;
                for (i = 0; i < SQ_DEPTH; i = i + 1)
                    if (g_sqv[i] && (g_sqs[i] >= flush_seq)) begin
                        g_sqv[i] = 1'b0;
                        ndrop    = ndrop + 1;
                    end
                g_sq_tail = g_sq_tail - ndrop;
            end
        end
    endtask

    // =======================================================================
    // Output + full-state comparison
    // =======================================================================
    integer last_drain_seq;

    task automatic check_all;
        integer i, lq_cnt, sq_cnt;
        begin
            lq_cnt = g_lq_tail - g_lq_head;
            sq_cnt = g_sq_tail - g_sq_head;

            chk("disp_ready",   disp_ready,   e_disp_ready);
            chk("disp_lq_idx",  disp_lq_idx,  e_disp_lq_idx);
            chk("disp_sq_idx",  disp_sq_idx,  e_disp_sq_idx);

            chk("ld_done",      ld_done,      e_ld_done);
            chk("ld_fwd",       ld_fwd,       e_ld_fwd);
            chk("ld_mem_req",   ld_mem_req,   e_ld_mem_req);
            chk("ld_spec",      ld_spec,      e_ld_spec);
            if (e_ld_done) begin
                chk("ld_data",    ld_data,    e_ld_data);
                if (e_ld_fwd) chk("ld_fwd_idx", ld_fwd_idx, e_ld_fwd_idx);
            end

            chk("mov_valid",    mov_valid,    e_mov_valid);
            if (e_mov_valid) begin
                chk("mov_rob",    mov_rob,    e_mov_rob);
                chk("mov_lq_idx", mov_lq_idx, e_mov_lq_idx);
                chk("mov_lq_ptr", mov_lq_ptr, e_mov_lq_ptr);
                chk("mov_sq_ptr", mov_sq_ptr, e_mov_sq_ptr);
            end

            chk("lq_head_ready", lq_head_ready, e_lq_hrdy);
            chk("sq_head_ready", sq_head_ready, e_sq_hrdy);
            if (e_lq_hrdy) begin
                chk("lq_head_rob",  lq_head_rob,  e_lq_hrob);
                chk("lq_head_addr", lq_head_addr, e_lq_haddr);
                chk("lq_head_data", lq_head_data, e_lq_hdata);
            end
            if (e_sq_hrdy) chk("sq_head_rob", sq_head_rob, e_sq_hrob);

            chk("mem_we", mem_we, e_mem_we);
            if (e_mem_we) begin
                chk("mem_addr", mem_addr, e_mem_addr);
                chk("mem_data", mem_data, e_mem_data);
            end

            chk("lq_count",    lq_count,    lq_cnt);
            chk("sq_count",    sq_count,    sq_cnt);
            chk("lq_full",     lq_full,     (lq_cnt == LQ_DEPTH));
            chk("sq_full",     sq_full,     (sq_cnt == SQ_DEPTH));
            chk("lq_empty",    lq_empty,    (lq_cnt == 0));
            chk("sq_empty",    sq_empty,    (sq_cnt == 0));
            chk("lq_tail_ptr", lq_tail_ptr, g_lq_tail % LQMOD);
            chk("sq_tail_ptr", sq_tail_ptr, g_sq_tail % SQMOD);

            // ---- full internal state ---------------------------------------
            for (i = 0; i < LQ_DEPTH; i = i + 1) begin
                chk("lq_valid", dut.lq_valid[i], g_lqv[i]);
                if (g_lqv[i]) begin
                    chk("lq_exec", dut.lq_exec[i], g_lqe[i]);
                    chk("lq_rob",  dut.lq_rob [i], g_lqr[i]);
                    chk("lq_sqb",  dut.lq_sqb [i], g_lqsqb[i]);
                    if (g_lqe[i]) begin
                        chk("lq_addr",  dut.lq_addr [i], g_lqa[i]);
                        chk("lq_data",  dut.lq_data [i], g_lqd[i]);
                        chk("lq_fwd_q", dut.lq_fwd_q[i], g_lqf[i]);
                        if (g_lqf[i])
                            chk("lq_fwdi", dut.lq_fwdi[i], g_lqfi[i]);
                    end
                end
            end
            for (i = 0; i < SQ_DEPTH; i = i + 1) begin
                chk("sq_valid", dut.sq_valid[i], g_sqv[i]);
                if (g_sqv[i]) begin
                    chk("sq_exec", dut.sq_exec[i], g_sqe[i]);
                    chk("sq_rob",  dut.sq_rob [i], g_sqr[i]);
                    if (g_sqe[i]) begin
                        chk("sq_addr", dut.sq_addr[i], g_sqa[i]);
                        chk("sq_data", dut.sq_data[i], g_sqd[i]);
                    end
                end
            end
            chk("lq_head", dut.lq_head, g_lq_head % LQMOD);
            chk("sq_head", dut.sq_head, g_sq_head % SQMOD);

            // ---- checker 2: value correctness at retirement ---------------
            // Every store older than this load has already retired into
            // ref_mem, and no younger one has, so this comparison is the
            // architectural definition of the load's result.
            if (g_cmt_ld)
                chk("P2 load value at commit",
                    lq_head_data, ref_mem[aidx(lq_head_addr)]);

            // ---- checker 4: stores drain in program order -----------------
            if (g_cmt_st) begin
                checks = checks + 1;
                if (!(g_sqs[g_sq_head % SQ_DEPTH] > last_drain_seq)) begin
                    errors = errors + 1;
                    $display("  ** P4 out-of-order store drain c%0d seq=%0d last=%0d",
                             cyc_no, g_sqs[g_sq_head % SQ_DEPTH], last_drain_seq);
                end
                last_drain_seq = g_sqs[g_sq_head % SQ_DEPTH];
            end
        end
    endtask

    // =======================================================================
    // Program / replay engine  (checkers 3 and 5)
    // =======================================================================
    bit               p_is_store [NPROG];
    logic [ADDRW-1:0] p_addr     [NPROG];
    logic [DATAW-1:0] p_data     [NPROG];
    bit               p_execd    [NPROG];
    integer           p_slot     [NPROG];
    integer           ck_lq      [NPROG];   // checkpoint taken at dispatch
    integer           ck_sq      [NPROG];
    integer           ck_seq     [NPROG];

    integer tb_lq_prog [LQ_DEPTH];
    integer tb_sq_prog [SQ_DEPTH];

    integer disp_pc, commit_pc;
    bit     pend_flush;
    integer pend_prog;

    // =======================================================================
    // Cycle engine
    // =======================================================================
    task automatic clear_inputs;
        begin
            disp_valid    = 1'b0;
            disp_is_store = 1'b0;
            disp_rob      = '0;
            ld_valid      = 1'b0;
            ld_idx        = '0;
            ld_addr       = mkaddr(0);
            st_valid      = 1'b0;
            st_idx        = '0;
            st_addr       = mkaddr(0);
            st_data       = '0;
            commit_load   = 1'b0;
            commit_store  = 1'b0;
            flush         = 1'b0;
            flush_lq_ptr  = '0;
            flush_sq_ptr  = '0;
            flush_seq     = 32'h7fff_ffff;
        end
    endtask

    // A directed test that wants to inspect the DUT's combinational response
    // itself calls peek() to walk to the same settled pre-edge instant cyc()
    // uses, and then still calls cyc() to close the cycle.  at_sample records
    // that the walk already happened so cyc() does not advance time twice.
    bit at_sample = 1'b0;

    task automatic peek;
        begin
            #4;
            at_sample = 1'b1;
        end
    endtask

    // Advance one cycle: sample + check + advance the model at the settled
    // pre-edge instant, then hand the next cycle back to the caller.
    task automatic cyc(input bit track);
        begin
            if (!at_sample) #4;
            at_sample = 1'b0;
            golden_eval();
            check_all();
            if (mov_valid) n_vio = n_vio + 1;
            if (ld_fwd)    n_fwd = n_fwd + 1;
            if (ld_spec)   n_spec = n_spec + 1;
            if (flush)     n_flush = n_flush + 1;
            golden_update();
            if (track) tb_bookkeep();
            cyc_no = cyc_no + 1;
            @(negedge clk);
            clear_inputs();
        end
    endtask

    // Maintain the program-order picture of what is in flight.
    task automatic tb_bookkeep;
        integer p, i;
        begin
            if (g_disp_fire) begin
                p             = disp_pc;
                p_slot [p]    = g_disp_slot;
                p_execd[p]    = 1'b0;
                ck_seq [p]    = g_disp_seq;
                if (p_is_store[p]) tb_sq_prog[g_disp_slot] = p;
                else               tb_lq_prog[g_disp_slot] = p;
                disp_pc       = disp_pc + 1;
            end
            if (g_ld_fire) p_execd[tb_lq_prog[ld_idx]] = 1'b1;
            if (g_st_fire) p_execd[tb_sq_prog[st_idx]] = 1'b1;
            if (g_cmt_ld) begin
                // g_lq_head is a free-running integer, so wrap it into the
                // slot array before indexing.
                chk("commit order (load)",
                    tb_lq_prog[(g_lq_head - 1) % LQ_DEPTH], commit_pc);
                commit_pc = commit_pc + 1;
                n_commit  = n_commit + 1;
            end
            if (g_cmt_st) begin
                chk("commit order (store)",
                    tb_sq_prog[(g_sq_head - 1) % SQ_DEPTH], commit_pc);
                commit_pc = commit_pc + 1;
                n_commit  = n_commit + 1;
            end
            // ---- checker 3: the reported recovery checkpoint --------------
            if (mov_valid) begin
                p = tb_lq_prog[mov_lq_idx];
                chk("P3 mov_lq_ptr vs recorded checkpoint", mov_lq_ptr, ck_lq[p]);
                chk("P3 mov_sq_ptr vs recorded checkpoint", mov_sq_ptr, ck_sq[p]);
            end
            if (flush) begin
                for (i = pend_prog; i < disp_pc; i = i + 1) p_execd[i] = 1'b0;
                disp_pc  = pend_prog;
                n_replay = n_replay + 1;
            end
        end
    endtask

    task automatic reset_all;
        integer i;
        begin
            rst_n = 1'b0;
            clear_inputs();
            for (i = 0; i < LQ_DEPTH; i = i + 1) begin
                g_lqv[i] = 0; g_lqe[i] = 0; g_lqf[i] = 0;
                g_lqs[i] = 0; g_lqa[i] = 0; g_lqd[i] = 0; g_lqr[i] = 0;
                g_lqfs[i] = 0; g_lqfi[i] = 0; g_lqptr[i] = 0; g_lqsqb[i] = 0;
                tb_lq_prog[i] = -1;
            end
            for (i = 0; i < SQ_DEPTH; i = i + 1) begin
                g_sqv[i] = 0; g_sqe[i] = 0;
                g_sqs[i] = 0; g_sqa[i] = 0; g_sqd[i] = 0; g_sqr[i] = 0;
                tb_sq_prog[i] = -1;
            end
            g_lq_head = 0; g_lq_tail = 0;
            g_sq_head = 0; g_sq_tail = 0;
            g_seq     = 1;
            last_drain_seq = 0;
            pend_flush = 0; pend_prog = 0;
            repeat (3) @(negedge clk);
            rst_n = 1'b1;
            @(negedge clk);
        end
    endtask

    // =======================================================================
    // Stimulus
    // =======================================================================
    integer PHASE1_T0;
    integer i, k, p, cand_l, cand_s, n, r;
    integer m_lq, m_sq, m_prog;
    integer NL, NS;
    integer lcand [16];
    integer scand [16];

    initial begin
        $dumpfile("load_store_queue.vcd");
        $dumpvars(0, tb_load_store_queue);

        errors = 0; checks = 0; cyc_no = 0;
        n_fwd = 0; n_spec = 0; n_vio = 0; n_replay = 0; n_flush = 0;
        n_commit = 0;
        disp_pc = 0; commit_pc = 0;

        for (i = 0; i < NADDR; i = i + 1) ref_mem[i] = 32'hAA00_0000 + i;
        for (i = 0; i < NPROG; i = i + 1) begin
            p_is_store[i] = 0; p_addr[i] = mkaddr(0); p_data[i] = 0;
            p_execd[i] = 0; p_slot[i] = 0;
            ck_lq[i] = 0; ck_sq[i] = 0; ck_seq[i] = 0;
        end

        $display("=========================================================");
        $display(" Day 33 - Out-of-Order Load/Store Queue");
        $display("   LQ_DEPTH=%0d  SQ_DEPTH=%0d  address pool=%0d",
                 LQ_DEPTH, SQ_DEPTH, NADDR);
        $display("=========================================================");

        reset_all();

        // ------------------------------------------------------------------
        // PHASE 1 - the directed 16-cycle window rendered in docs/
        //
        //   S0 store  @A0        (address unknown for a long time)
        //   L1 load   @A0        <- speculates past S0 and reads stale memory
        //   S2 store  @A2
        //   L3 load   @A2        <- forwards from S2
        //   then S0 resolves  -> memory-order violation on L1 -> squash,
        //   replay L1, this time it forwards from S0, and both retire.
        // ------------------------------------------------------------------
        $display("\n[Phase 1] directed speculate/violate/squash/replay window");
        PHASE1_T0 = $time;
        $display("  PHASE1_T0 = %0t", PHASE1_T0);

        cyc(0);                                             // c0 idle

        disp_valid = 1; disp_is_store = 1; disp_rob = 6'd1;  // c1  S0
        cyc(0);
        disp_valid = 1; disp_is_store = 0; disp_rob = 6'd2;  // c2  L1
        cyc(0);
        disp_valid = 1; disp_is_store = 1; disp_rob = 6'd3;  // c3  S2
        cyc(0);
        disp_valid = 1; disp_is_store = 0; disp_rob = 6'd4;  // c4  L3
        cyc(0);

        ld_valid = 1; ld_idx = 0; ld_addr = mkaddr(0);       // c5  L1 executes
        cyc(0);
        if (!(n_spec > 0)) begin
            $display("  ** L1 should have been flagged speculative"); errors++;
        end

        st_valid = 1; st_idx = 1;                            // c6  S2 executes
        st_addr = mkaddr(2); st_data = 32'h3333_0002;
        cyc(0);

        ld_valid = 1; ld_idx = 1; ld_addr = mkaddr(2);       // c7  L3 forwards
        cyc(0);

        st_valid = 1; st_idx = 0;                            // c8  S0 resolves
        st_addr = mkaddr(0); st_data = 32'h7777_0000;
        peek();
        m_lq = mov_lq_ptr; m_sq = mov_sq_ptr;
        chk("P1 violation raised",     mov_valid,  1);
        chk("P1 offending load = L1",  mov_rob,    2);
        chk("P1 offending slot",       mov_lq_idx, 0);
        chk("P1 recovery lq_ptr",      m_lq,       0);
        chk("P1 recovery sq_ptr",      m_sq,       1);
        cyc(0);

        flush = 1; flush_lq_ptr = m_lq[LQPW-1:0];            // c9  squash
        flush_sq_ptr = m_sq[SQPW-1:0];
        flush_seq = g_lqs[0];
        cyc(0);
        chk("P1 loads squashed",       lq_count, 0);
        chk("P1 S0 survives the flush", sq_count, 1);

        disp_valid = 1; disp_is_store = 0; disp_rob = 6'd5;  // c10 replay L1
        cyc(0);

        ld_valid = 1; ld_idx = 0; ld_addr = mkaddr(0);       // c11 now forwards
        peek();
        chk("P1 replayed load forwards",   ld_fwd,  1);
        chk("P1 replayed load not spec",   ld_spec, 0);
        chk("P1 replayed load value",      ld_data, 32'h7777_0000);
        cyc(0);

        commit_store = 1;                                    // c12 S0 retires
        cyc(0);
        commit_load = 1;                                     // c13 L1 retires
        cyc(0);
        cyc(0);                                              // c14 idle
        cyc(0);                                              // c15 idle
        $display("  phase 1 done: checks=%0d errors=%0d", checks, errors);

        // ------------------------------------------------------------------
        // PHASE 2 - directed corner cases
        // ------------------------------------------------------------------
        $display("\n[Phase 2] directed corner cases");

        // (a) queue-full back-pressure, per queue independently
        reset_all();
        for (i = 0; i < LQ_DEPTH; i = i + 1) begin
            disp_valid = 1; disp_is_store = 0; disp_rob = i[ROBW-1:0];
            cyc(0);
        end
        chk("(a) lq_full",                 lq_full,    1);
        disp_valid = 1; disp_is_store = 0;
        peek(); chk("(a) load dispatch blocked",  disp_ready, 0);
        cyc(0);
        disp_valid = 1; disp_is_store = 1;
        peek(); chk("(a) store dispatch still ok", disp_ready, 1);
        cyc(0);
        for (i = 0; i < SQ_DEPTH - 1; i = i + 1) begin
            disp_valid = 1; disp_is_store = 1; disp_rob = i[ROBW-1:0];
            cyc(0);
        end
        chk("(a) sq_full", sq_full, 1);
        disp_valid = 1; disp_is_store = 1;
        peek(); chk("(a) store dispatch blocked", disp_ready, 0);
        cyc(0);

        // (b) forward from the YOUNGEST of several matching older stores
        reset_all();
        for (i = 0; i < 3; i = i + 1) begin
            disp_valid = 1; disp_is_store = 1; disp_rob = i[ROBW-1:0];
            cyc(0);
        end
        disp_valid = 1; disp_is_store = 0; disp_rob = 6'd9;   // the load
        cyc(0);
        for (i = 0; i < 3; i = i + 1) begin                   // all three alias
            st_valid = 1; st_idx = i[SQIW-1:0];
            st_addr = mkaddr(1); st_data = 32'h1000 + i;
            cyc(0);
        end
        ld_valid = 1; ld_idx = 0; ld_addr = mkaddr(1);
        peek();
        chk("(b) forwarded",            ld_fwd,     1);
        chk("(b) youngest store wins",  ld_fwd_idx, 2);
        chk("(b) forwarded value",      ld_data,    32'h1002);
        cyc(0);

        // (c) "covered" forward: an OLDER store resolving later must not
        //     squash a load that took its value from a YOUNGER store.
        reset_all();
        disp_valid = 1; disp_is_store = 1; disp_rob = 6'd1; cyc(0);  // Sa (old)
        disp_valid = 1; disp_is_store = 1; disp_rob = 6'd2; cyc(0);  // Sb
        disp_valid = 1; disp_is_store = 0; disp_rob = 6'd3; cyc(0);  // L
        st_valid = 1; st_idx = 1; st_addr = mkaddr(3); st_data = 32'hB;
        cyc(0);                                                      // Sb first
        ld_valid = 1; ld_idx = 0; ld_addr = mkaddr(3);
        peek(); chk("(c) load forwards from Sb", ld_fwd_idx, 1);
        cyc(0);
        st_valid = 1; st_idx = 0; st_addr = mkaddr(3); st_data = 32'hA;
        peek(); chk("(c) covered - no violation", mov_valid, 0);
        cyc(0);

        // (d) several violators -> the OLDEST is reported
        reset_all();
        disp_valid = 1; disp_is_store = 1; disp_rob = 6'd1; cyc(0);  // S
        disp_valid = 1; disp_is_store = 0; disp_rob = 6'd2; cyc(0);  // L1
        disp_valid = 1; disp_is_store = 0; disp_rob = 6'd3; cyc(0);  // L2
        ld_valid = 1; ld_idx = 1; ld_addr = mkaddr(4); cyc(0);       // L2 first
        ld_valid = 1; ld_idx = 0; ld_addr = mkaddr(4); cyc(0);       // then L1
        st_valid = 1; st_idx = 0; st_addr = mkaddr(4); st_data = 32'hC;
        peek();
        chk("(d) violation",          mov_valid,  1);
        chk("(d) oldest load wins",   mov_rob,    2);
        chk("(d) oldest slot",        mov_lq_idx, 0);
        cyc(0);

        // (e) same-cycle store-execute / load-execute bypass
        reset_all();
        disp_valid = 1; disp_is_store = 1; disp_rob = 6'd1; cyc(0);
        disp_valid = 1; disp_is_store = 0; disp_rob = 6'd2; cyc(0);
        st_valid = 1; st_idx = 0; st_addr = mkaddr(5); st_data = 32'hE5;
        ld_valid = 1; ld_idx = 0; ld_addr = mkaddr(5);
        peek();
        chk("(e) bypassed forward",       ld_fwd,    1);
        chk("(e) bypassed value",         ld_data,   32'hE5);
        chk("(e) no spurious violation",  mov_valid, 0);
        cyc(0);

        // (f) a flush cycle is dead for every port
        reset_all();
        disp_valid = 1; disp_is_store = 1; disp_rob = 6'd1; cyc(0);
        disp_valid = 1; disp_is_store = 0; disp_rob = 6'd2; cyc(0);
        st_valid = 1; st_idx = 0; st_addr = mkaddr(6); st_data = 32'hF6; cyc(0);
        ld_valid = 1; ld_idx = 0; ld_addr = mkaddr(6); cyc(0);
        n = lq_count; k = sq_count;
        flush = 1; flush_lq_ptr = lq_tail_ptr; flush_sq_ptr = sq_tail_ptr;
        flush_seq = g_seq;                       // a no-op checkpoint: keep all
        disp_valid = 1; disp_is_store = 0; disp_rob = 6'd7;
        ld_valid = 1; ld_idx = 0; ld_addr = mkaddr(7);
        st_valid = 1; st_idx = 0; st_addr = mkaddr(7); st_data = 32'h77;
        commit_load = 1; commit_store = 1;
        peek();
        chk("(f) no dispatch during flush", disp_ready, 0);
        chk("(f) no load done",             ld_done,    0);
        chk("(f) no violation",             mov_valid,  0);
        chk("(f) no memory write",          mem_we,     0);
        cyc(0);
        chk("(f) no-op flush keeps LQ", lq_count, n);
        chk("(f) no-op flush keeps SQ", sq_count, k);

        // (g) execute into a slot the previous cycle squashed
        reset_all();
        disp_valid = 1; disp_is_store = 1; disp_rob = 6'd1; cyc(0);
        disp_valid = 1; disp_is_store = 0; disp_rob = 6'd2; cyc(0);
        flush = 1; flush_lq_ptr = 0; flush_sq_ptr = sq_tail_ptr;
        flush_seq = g_lqs[0];                    // squash the load only
        cyc(0);
        chk("(g) load squashed", lq_count, 0);
        ld_valid = 1; ld_idx = 0; ld_addr = mkaddr(0);
        peek(); chk("(g) execute into a dead slot ignored", ld_done, 0);
        cyc(0);

        // (h) simultaneous load + store retirement (load is the older op)
        reset_all();
        disp_valid = 1; disp_is_store = 0; disp_rob = 6'd1; cyc(0);
        disp_valid = 1; disp_is_store = 1; disp_rob = 6'd2; cyc(0);
        ld_valid = 1; ld_idx = 0; ld_addr = mkaddr(2); cyc(0);
        st_valid = 1; st_idx = 0; st_addr = mkaddr(2); st_data = 32'h5A5A;
        cyc(0);
        commit_load = 1; commit_store = 1;
        peek();
        chk("(h) memory write on dual commit", mem_we, 1);
        cyc(0);
        chk("(h) both queues drained", lq_count + sq_count, 0);

        // (i) pointer wraparound: three laps of both queues
        reset_all();
        for (i = 0; i < 3 * LQ_DEPTH + 5; i = i + 1) begin
            disp_valid = 1; disp_is_store = (i % 2); disp_rob = i[ROBW-1:0];
            cyc(0);
            if (i % 2) begin
                st_valid = 1; st_idx = ((i / 2) % SQ_DEPTH);
                st_addr = mkaddr(i); st_data = 32'h9000 + i;
            end else begin
                ld_valid = 1; ld_idx = ((i / 2) % LQ_DEPTH);
                ld_addr = mkaddr(i);
            end
            cyc(0);
            if (i % 2) commit_store = 1; else commit_load = 1;
            cyc(0);
        end
        chk("(i) queues empty after the laps", lq_count + sq_count, 0);
        $display("  phase 2 done: checks=%0d errors=%0d", checks, errors);

        // ------------------------------------------------------------------
        // PHASE 3 - randomised, with real replay
        // ------------------------------------------------------------------
        $display("\n[Phase 3] %0d randomised cycles", NRAND);
        reset_all();
        disp_pc = 0; commit_pc = 0; pend_flush = 0; pend_prog = 0;

        // Build the program.  A small address pool with a hot subset makes
        // aliasing (and therefore forwarding and violations) frequent.
        for (i = 0; i < NPROG; i = i + 1) begin
            p_is_store[i] = (({$random} % 100) < 45);
            r = ({$random} % 100);
            if (r < 55) p_addr[i] = mkaddr({$random} % 3);
            else        p_addr[i] = mkaddr({$random} % NADDR);
            p_data[i] = {$random};
        end

        for (k = 0; k < NRAND; k = k + 1) begin
            // ---- flush cycle: drive live-looking traffic that must all be
            //      ignored, then roll the program counter back
            if (pend_flush) begin
                flush         = 1'b1;
                flush_lq_ptr  = ck_lq [pend_prog][LQPW-1:0];
                flush_sq_ptr  = ck_sq [pend_prog][SQPW-1:0];
                flush_seq     = ck_seq[pend_prog];
                disp_valid    = 1'b1;
                disp_is_store = ({$random} % 2);
                ld_valid      = 1'b1;
                ld_idx        = ({$random} % LQ_DEPTH);
                st_valid      = 1'b1;
                st_idx        = ({$random} % SQ_DEPTH);
                commit_load   = 1'b1;
                commit_store  = 1'b1;
                pend_flush    = 1'b0;
                cyc(1);
            end else begin
                // ---- dispatch -----------------------------------------
                if ((disp_pc < NPROG) && (({$random} % 100) < 75)) begin
                    disp_valid    = 1'b1;
                    disp_is_store = p_is_store[disp_pc];
                    disp_rob      = g_seq[ROBW-1:0];
                    ck_lq[disp_pc] = g_lq_tail % LQMOD;
                    ck_sq[disp_pc] = g_sq_tail % SQMOD;
                end

                // ---- pick one un-executed load and one un-executed store
                NL = 0; NS = 0;
                for (p = commit_pc; p < disp_pc; p = p + 1) begin
                    if (!p_execd[p]) begin
                        if (p_is_store[p]) begin
                            if (NS < 16) begin scand[NS] = p; NS = NS + 1; end
                        end else begin
                            if (NL < 16) begin lcand[NL] = p; NL = NL + 1; end
                        end
                    end
                end
                // Loads run eagerly, stores lag: that is what creates the
                // unknown-address windows the whole design exists for.
                if ((NL > 0) && (({$random} % 100) < 70)) begin
                    cand_l   = lcand[{$random} % NL];
                    ld_valid = 1'b1;
                    ld_idx   = p_slot[cand_l][LQIW-1:0];
                    ld_addr  = p_addr[cand_l];
                end
                if ((NS > 0) && (({$random} % 100) < 40)) begin
                    cand_s   = scand[{$random} % NS];
                    st_valid = 1'b1;
                    st_idx   = p_slot[cand_s][SQIW-1:0];
                    st_addr  = p_addr[cand_s];
                    st_data  = p_data[cand_s];
                end

                // ---- retire in program order, up to a (load, store) pair
                if (commit_pc < disp_pc) begin
                    if (!p_is_store[commit_pc]) begin
                        commit_load = 1'b1;
                        // Pair the next store with it ONLY if this load will
                        // really retire this cycle (it has executed).  Asking
                        // for both while the head load is still in flight would
                        // retire the store ahead of it, i.e. the testbench
                        // itself would break program order.
                        if (p_execd[commit_pc] &&
                            ((commit_pc + 1) < disp_pc) &&
                            p_is_store[commit_pc + 1])
                            commit_store = 1'b1;
                    end else begin
                        commit_store = 1'b1;
                    end
                end

                cyc(1);

                // ---- schedule a recovery ------------------------------
                if (mov_valid) begin
                    // violation squash: rewind to the offending load
                    pend_flush = 1'b1;
                    pend_prog  = m_prog;
                end else if ((disp_pc > commit_pc) && (({$random} % 400) == 0))
                begin
                    // an unrelated branch mispredict: rewind to a random
                    // in-flight program point
                    pend_flush = 1'b1;
                    pend_prog  = commit_pc + ({$random} % (disp_pc - commit_pc));
                end
            end
        end

        // Drain what is left so the final state is clean.
        for (k = 0; k < 200; k = k + 1) begin
            if (pend_flush) begin
                flush        = 1'b1;
                flush_lq_ptr = ck_lq [pend_prog][LQPW-1:0];
                flush_sq_ptr = ck_sq [pend_prog][SQPW-1:0];
                flush_seq    = ck_seq[pend_prog];
                pend_flush   = 1'b0;
            end else begin
                NL = 0; NS = 0;
                for (p = commit_pc; p < disp_pc; p = p + 1) begin
                    if (!p_execd[p]) begin
                        if (p_is_store[p]) begin
                            if (NS < 16) begin scand[NS] = p; NS = NS + 1; end
                        end else begin
                            if (NL < 16) begin lcand[NL] = p; NL = NL + 1; end
                        end
                    end
                end
                if (NL > 0) begin
                    cand_l   = lcand[0];
                    ld_valid = 1'b1;
                    ld_idx   = p_slot[cand_l][LQIW-1:0];
                    ld_addr  = p_addr[cand_l];
                end
                if (NS > 0) begin
                    cand_s   = scand[0];
                    st_valid = 1'b1;
                    st_idx   = p_slot[cand_s][SQIW-1:0];
                    st_addr  = p_addr[cand_s];
                    st_data  = p_data[cand_s];
                end
                if (commit_pc < disp_pc) begin
                    if (!p_is_store[commit_pc]) commit_load  = 1'b1;
                    else                        commit_store = 1'b1;
                end
            end
            cyc(1);
            if (mov_valid) begin
                pend_flush = 1'b1;
                pend_prog  = m_prog;
            end
        end

        // ------------------------------------------------------------------
        $display("\n---------------------------------------------------------");
        $display(" cycles simulated : %0d", cyc_no);
        $display(" assertions       : %0d", checks);
        $display(" store->load fwd  : %0d", n_fwd);
        $display(" speculative loads: %0d", n_spec);
        $display(" violations       : %0d", n_vio);
        $display(" squash / replays : %0d", n_replay);
        $display(" memory ops retired: %0d  (program reached %0d)",
                 n_commit, commit_pc);
        $display("---------------------------------------------------------");

        // checker 5: forward progress
        checks = checks + 1;
        if (n_commit < 500) begin
            errors = errors + 1;
            $display("  ** P5 forward progress: only %0d ops retired", n_commit);
        end
        checks = checks + 1;
        if (n_vio == 0) begin
            errors = errors + 1;
            $display("  ** stimulus produced no memory-order violations");
        end

        if (errors == 0)
            $display("RESULT: *** PASS ***  (%0d assertions)", checks);
        else
            $display("RESULT: *** FAIL ***  (%0d errors / %0d assertions)",
                     errors, checks);
        $finish;
    end

    // The offending load's program index, latched combinationally so the
    // recovery code above can use it in the same cycle mov_valid is seen.
    always_comb m_prog = tb_lq_prog[mov_lq_idx];

    // =======================================================================
    // Watchdog
    // =======================================================================
    initial begin
        #2_000_000;
        $display("RESULT: *** FAIL ***  timeout");
        $finish;
    end

    // =======================================================================
    // Flattened debug taps for the waveform renderer (unpacked arrays are not
    // dumped by $dumpvars, so the first few entries are mirrored here).
    // encoding:  sq = {valid, exec, addr_word[7:0], data[7:0]}
    //            lq = {valid, exec, fwd, addr_word[7:0], data[7:0]}
    // =======================================================================
    logic [17:0] dbg_sq0, dbg_sq1, dbg_sq2, dbg_sq3;
    logic [18:0] dbg_lq0, dbg_lq1, dbg_lq2, dbg_lq3;
    logic [LQPW-1:0] dbg_lqh, dbg_lqt;
    logic [SQPW-1:0] dbg_sqh, dbg_sqt;

    assign dbg_sq0 = {dut.sq_valid[0], dut.sq_exec[0],
                      dut.sq_addr[0][9:2], dut.sq_data[0][7:0]};
    assign dbg_sq1 = {dut.sq_valid[1], dut.sq_exec[1],
                      dut.sq_addr[1][9:2], dut.sq_data[1][7:0]};
    assign dbg_sq2 = {dut.sq_valid[2], dut.sq_exec[2],
                      dut.sq_addr[2][9:2], dut.sq_data[2][7:0]};
    assign dbg_sq3 = {dut.sq_valid[3], dut.sq_exec[3],
                      dut.sq_addr[3][9:2], dut.sq_data[3][7:0]};
    assign dbg_lq0 = {dut.lq_valid[0], dut.lq_exec[0], dut.lq_fwd_q[0],
                      dut.lq_addr[0][9:2], dut.lq_data[0][7:0]};
    assign dbg_lq1 = {dut.lq_valid[1], dut.lq_exec[1], dut.lq_fwd_q[1],
                      dut.lq_addr[1][9:2], dut.lq_data[1][7:0]};
    assign dbg_lq2 = {dut.lq_valid[2], dut.lq_exec[2], dut.lq_fwd_q[2],
                      dut.lq_addr[2][9:2], dut.lq_data[2][7:0]};
    assign dbg_lq3 = {dut.lq_valid[3], dut.lq_exec[3], dut.lq_fwd_q[3],
                      dut.lq_addr[3][9:2], dut.lq_data[3][7:0]};
    assign dbg_lqh = dut.lq_head;
    assign dbg_lqt = dut.lq_tail;
    assign dbg_sqh = dut.sq_head;
    assign dbg_sqt = dut.sq_tail;

endmodule
