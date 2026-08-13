// -----------------------------------------------------------------------------
// Day31 - Self-checking testbench for the non-blocking-cache MSHR file.
// -----------------------------------------------------------------------------
// The testbench plays THREE roles:
//
//   1. the CACHE / CORE  - issues missing word accesses (address + destination
//                          register), holds a request until req_ready, and
//                          randomly back-pressures the replay write-back port;
//   2. the NEXT-LEVEL MEMORY - accepts fill requests (with its own random
//                          ready back-pressure), holds each one for a RANDOM
//                          latency and returns them OUT OF ORDER, tagged with
//                          the MSHR id.  Each returned block is built from a
//                          deterministic reference function, so every replayed
//                          word has a known architecturally-correct value;
//   3. an INDEPENDENT golden model - the MSHR file re-expressed as plain
//                          behavioural bookkeeping (per-entry target LISTS
//                          with explicit merge/drain counts), written from the
//                          port spec rather than copied from the RTL.
//
// Every cycle the DUT's combinational outputs are sampled at the settled
// pre-edge instant and compared against the model:
//     req_ready / req_primary / req_secondary / req_id
//     mem_req_valid / mem_req_addr / mem_req_id
//     rpl_valid / rpl_dst / rpl_data / rpl_id / rpl_last
//     full / n_valid / n_outstanding / err_fill
// followed by the FULL per-entry state {valid, done, blk, ntgt, nrpl}, the
// whole target list {dst, woff} and every filled data word.
//
// On top of the lockstep comparison it checks four properties that are
// statements about a lockup-free cache, not about this implementation:
//
//   A. NO DUPLICATE FETCH - at most one memory transaction may ever be in
//      flight for a given block address.  A secondary miss must ride the
//      existing one.  (Violating this is the classic MSHR bug: two fills for
//      one block, two writes into the same cache line.)
//   B. EVERY ACCEPTED ACCESS REPLAYS EXACTLY ONCE - a scoreboard of accepted
//      (dst, block, word) tuples is drained by the replay port; nothing may be
//      lost, duplicated or invented, and an entry must be exactly empty when
//      rpl_last frees it.
//   C. VALUE CORRECTNESS - each replayed word equals ref_word(block, offset),
//      i.e. the MSHR picked the right word out of the right block for the
//      right waiting target.
//   D. PER-BLOCK REPLAY ORDER - the targets of one MSHR replay in the order
//      they were merged (a block's waiting loads write back oldest-first).
//
// Phase 1  - a 16-cycle directed window (rendered as the waveform) covering
//            primary miss, secondary merge, 3-deep MLP, out-of-order fill,
//            replay + entry free, entry reuse, MSHR-file-full stall and bus
//            back-pressure.
// Phase 1b - the remaining corners: TARGET-LIST-FULL stall, the same-cycle
//            LATE MERGE (a merge on the exact edge its fill lands), a miss to
//            a block that is mid-replay, and a bad fill tag -> err_fill.
// Phase 2  - 4000 randomised cycles with random request / fill / ready
//            pressure over a small block pool (so merging happens constantly).
//
//   RESULT: *** PASS ***   is printed only if every assertion held.
// -----------------------------------------------------------------------------

`timescale 1ns / 1ps

module tb_mshr_file;

    // ---- compact demo configuration ----
    localparam int ADDR_W  = 12;   // WORD address
    localparam int DATA_W  = 32;
    localparam int WORDS   = 4;
    localparam int NMSHR   = 4;
    localparam int NTARGET = 4;
    localparam int DST_W   = 5;

    localparam int WOFF_W  = 2;                 // $clog2(WORDS)
    localparam int ID_W    = 2;                 // $clog2(NMSHR)
    localparam int BADDR_W = ADDR_W - WOFF_W;   // 10
    localparam int NBLK    = 8;                 // small pool -> lots of merging
    localparam int BLKMAX  = 32;                // bound for the shadow arrays

    // =========================================================================
    // DUT
    // =========================================================================
    logic                    clk = 1'b0;
    logic                    rst_n;

    logic                    req_valid;
    logic [ADDR_W-1:0]       req_addr;
    logic [DST_W-1:0]        req_dst;
    logic                    req_ready;
    logic                    req_primary;
    logic                    req_secondary;
    logic [ID_W-1:0]         req_id;

    logic                    mem_req_ready;
    logic                    mem_req_valid;
    logic [BADDR_W-1:0]      mem_req_addr;
    logic [ID_W-1:0]         mem_req_id;

    logic                    fill_valid;
    logic [ID_W-1:0]         fill_id;
    logic [WORDS*DATA_W-1:0] fill_data;

    logic                    rpl_ready;
    logic                    rpl_valid;
    logic [DST_W-1:0]        rpl_dst;
    logic [DATA_W-1:0]       rpl_data;
    logic [ID_W-1:0]         rpl_id;
    logic                    rpl_last;

    logic                    full;
    logic [ID_W:0]           n_valid;
    logic [ID_W:0]           n_outstanding;
    logic                    err_fill;

    mshr_file #(
        .ADDR_W (ADDR_W),
        .DATA_W (DATA_W),
        .WORDS  (WORDS),
        .NMSHR  (NMSHR),
        .NTARGET(NTARGET),
        .DST_W  (DST_W)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .req_valid(req_valid), .req_addr(req_addr), .req_dst(req_dst),
        .req_ready(req_ready), .req_primary(req_primary),
        .req_secondary(req_secondary), .req_id(req_id),
        .mem_req_ready(mem_req_ready), .mem_req_valid(mem_req_valid),
        .mem_req_addr(mem_req_addr), .mem_req_id(mem_req_id),
        .fill_valid(fill_valid), .fill_id(fill_id), .fill_data(fill_data),
        .rpl_ready(rpl_ready), .rpl_valid(rpl_valid), .rpl_dst(rpl_dst),
        .rpl_data(rpl_data), .rpl_id(rpl_id), .rpl_last(rpl_last),
        .full(full), .n_valid(n_valid), .n_outstanding(n_outstanding),
        .err_fill(err_fill)
    );

    always #5 clk = ~clk;

    // =========================================================================
    // Bookkeeping
    // =========================================================================
    integer checks   = 0;
    integer errors   = 0;
    integer cyc      = 0;
    integer trace_on = 0;

    integer n_prim = 0, n_sec = 0, n_latemerge = 0;
    integer n_stall_full = 0, n_stall_tgt = 0, n_stall_drain = 0, n_stall_bus = 0;
    integer n_fills = 0, n_replays = 0, max_mlp = 0;
    integer n_accepted = 0, n_retired = 0;

    task automatic chk(input string nm, input integer got, input integer exp);
        begin
            checks = checks + 1;
            if (got !== exp) begin
                errors = errors + 1;
                if (errors <= 25)
                    $display("  ** MISMATCH c%0d %-22s got=%0d exp=%0d",
                             cyc, nm, got, exp);
            end
        end
    endtask

    task automatic chkh(input string nm, input [31:0] got, input [31:0] exp);
        begin
            checks = checks + 1;
            if (got !== exp) begin
                errors = errors + 1;
                if (errors <= 25)
                    $display("  ** MISMATCH c%0d %-22s got=%08h exp=%08h",
                             cyc, nm, got, exp);
            end
        end
    endtask

    // The architecturally-correct value of a word.  The memory model uses it to
    // build a fill; property C uses it to audit a replay.  A crossed-over block
    // or a wrong word offset therefore shows up as a data mismatch.
    function automatic [DATA_W-1:0] ref_word(input integer blk, input integer w);
        ref_word = 32'hFEED_0000 + (blk * 16) + w;
    endfunction

    // =========================================================================
    // GOLDEN MODEL - behavioural MSHR bookkeeping
    // =========================================================================
    bit     g_v  [NMSHR];
    bit     g_dn [NMSHR];
    integer g_blk[NMSHR];
    integer g_nt [NMSHR];              // targets recorded
    integer g_nr [NMSHR];              // targets already replayed
    integer g_td [NMSHR*NTARGET];      // target dst
    integer g_tw [NMSHR*NTARGET];      // target word offset
    integer g_dat[NMSHR*WORDS];        // returned block data
    bit     g_err;

    // expected combinational outputs
    bit     e_ready, e_prim, e_sec, e_mvalid, e_rvalid, e_rlast, e_full;
    integer e_id, e_maddr, e_mid, e_rdst, e_rid, e_rdata, e_nvalid, e_nout;

    // decisions shared between eval and update
    bit     gm_hit, gm_free, gm_mergeable, gm_rsel;
    integer gm_hidx, gm_fidx, gm_ridx, q_blk, q_woff;

    task automatic golden_eval;
        integer i, ti, di;
        begin
            q_blk  = req_addr >> WOFF_W;
            q_woff = req_addr & (WORDS - 1);

            // fully-associative lookup
            gm_hit = 0; gm_hidx = 0;
            for (i = 0; i < NMSHR; i = i + 1)
                if (!gm_hit && g_v[i] && g_blk[i] == q_blk) begin
                    gm_hit = 1; gm_hidx = i;
                end
            // free-entry pick
            gm_free = 0; gm_fidx = 0;
            for (i = 0; i < NMSHR; i = i + 1)
                if (!gm_free && !g_v[i]) begin
                    gm_free = 1; gm_fidx = i;
                end

            gm_mergeable = gm_hit && !g_dn[gm_hidx] && (g_nt[gm_hidx] < NTARGET);

            e_sec    = req_valid && gm_mergeable;
            e_prim   = req_valid && !gm_hit && gm_free && mem_req_ready;
            e_ready  = e_sec || e_prim;
            e_id     = gm_hit ? gm_hidx : gm_fidx;

            e_mvalid = req_valid && !gm_hit && gm_free;
            e_maddr  = q_blk;
            e_mid    = gm_fidx;

            // replay select: lowest filled entry that still owes targets
            gm_rsel = 0; gm_ridx = 0;
            for (i = 0; i < NMSHR; i = i + 1)
                if (!gm_rsel && g_v[i] && g_dn[i] && (g_nr[i] < g_nt[i])) begin
                    gm_rsel = 1; gm_ridx = i;
                end

            e_rvalid = gm_rsel;
            e_rid    = gm_ridx;
            e_rdst   = 0;
            e_rdata  = 0;
            e_rlast  = 0;
            if (gm_rsel) begin
                ti      = gm_ridx * NTARGET + g_nr[gm_ridx];
                di      = gm_ridx * WORDS   + g_tw[ti];
                e_rdst  = g_td[ti];
                e_rdata = g_dat[di];
                e_rlast = ((g_nr[gm_ridx] + 1) == g_nt[gm_ridx]);
            end

            e_full   = !gm_free;
            e_nvalid = 0;
            e_nout   = 0;
            for (i = 0; i < NMSHR; i = i + 1) begin
                if (g_v[i])             e_nvalid = e_nvalid + 1;
                if (g_v[i] && !g_dn[i]) e_nout   = e_nout   + 1;
            end
            if (e_nout > max_mlp) max_mlp = e_nout;
        end
    endtask

    task automatic golden_update;
        integer w, ti;
        begin
            // 3. replay accepted -> advance / free
            if (e_rvalid && rpl_ready) begin
                if (e_rlast) begin
                    g_v [gm_ridx] = 0;
                    g_dn[gm_ridx] = 0;
                    g_nt[gm_ridx] = 0;
                    g_nr[gm_ridx] = 0;
                end else begin
                    g_nr[gm_ridx] = g_nr[gm_ridx] + 1;
                end
                n_replays = n_replays + 1;
            end

            // 2b. tagged fill return
            if (fill_valid) begin
                if (g_v[fill_id] && !g_dn[fill_id]) begin
                    for (w = 0; w < WORDS; w = w + 1)
                        g_dat[fill_id*WORDS + w] = fill_data[w*DATA_W +: DATA_W];
                    g_dn[fill_id] = 1;
                    n_fills = n_fills + 1;
                end else begin
                    g_err = 1;
                end
            end

            // 1. merge / allocate
            if (e_sec) begin
                ti            = gm_hidx*NTARGET + g_nt[gm_hidx];
                g_td[ti]      = req_dst;
                g_tw[ti]      = q_woff;
                g_nt[gm_hidx] = g_nt[gm_hidx] + 1;
                n_sec         = n_sec + 1;
                if (fill_valid && fill_id == gm_hidx) n_latemerge = n_latemerge + 1;
            end else if (e_prim) begin
                ti             = gm_fidx*NTARGET;
                g_v  [gm_fidx] = 1;
                g_dn [gm_fidx] = 0;
                g_blk[gm_fidx] = q_blk;
                g_td [ti]      = req_dst;
                g_tw [ti]      = q_woff;
                g_nt [gm_fidx] = 1;
                g_nr [gm_fidx] = 0;
                n_prim         = n_prim + 1;
            end else if (req_valid) begin
                if      (gm_hit && g_dn[gm_hidx]) n_stall_drain = n_stall_drain + 1;
                else if (gm_hit)                  n_stall_tgt   = n_stall_tgt   + 1;
                else if (!gm_free)                n_stall_full  = n_stall_full  + 1;
                else                              n_stall_bus   = n_stall_bus   + 1;
            end
        end
    endtask

    // =========================================================================
    // Output + full-state comparison
    // =========================================================================
    task automatic check_outputs;
        integer i, k;
        begin
            chk("req_ready",     req_ready,     e_ready);
            chk("req_primary",   req_primary,   e_prim);
            chk("req_secondary", req_secondary, e_sec);
            if (req_valid) chk("req_id", req_id, e_id);

            chk("mem_req_valid", mem_req_valid, e_mvalid);
            if (e_mvalid) begin
                chk("mem_req_addr", mem_req_addr, e_maddr);
                chk("mem_req_id",   mem_req_id,   e_mid);
            end

            chk("rpl_valid", rpl_valid, e_rvalid);
            if (e_rvalid) begin
                chk ("rpl_dst",  rpl_dst,  e_rdst);
                chkh("rpl_data", rpl_data, e_rdata);
                chk ("rpl_id",   rpl_id,   e_rid);
                chk ("rpl_last", rpl_last, e_rlast);
            end

            chk("full",          full,          e_full);
            chk("n_valid",       n_valid,       e_nvalid);
            chk("n_outstanding", n_outstanding, e_nout);
            chk("err_fill",      err_fill,      g_err);

            // full architectural state
            for (i = 0; i < NMSHR; i = i + 1) begin
                chk("st_valid", dut.vld_q[i],  g_v[i]);
                chk("st_done",  dut.done_q[i], g_dn[i]);
                chk("st_ntgt",  dut.ntgt_q[i], g_nt[i]);
                chk("st_nrpl",  dut.nrpl_q[i], g_nr[i]);
                if (g_v[i]) begin
                    chk("st_blk", dut.blk_q[i], g_blk[i]);
                    for (k = 0; k < g_nt[i]; k = k + 1) begin
                        chk("st_tdst", dut.tdst_q[i*NTARGET+k], g_td[i*NTARGET+k]);
                        chk("st_twof", dut.twof_q[i*NTARGET+k], g_tw[i*NTARGET+k]);
                    end
                    if (g_dn[i])
                        for (k = 0; k < WORDS; k = k + 1)
                            chkh("st_data", dut.dat_q[i*WORDS+k], g_dat[i*WORDS+k]);
                end
            end
        end
    endtask

    // =========================================================================
    // PROPERTIES A-D  (scoreboards, independent of the golden model)
    // =========================================================================
    bit     blk_infl[BLKMAX];          // block address -> fetch in flight?
    integer sb_dst  [NMSHR*NTARGET];
    integer sb_blk  [NMSHR*NTARGET];
    integer sb_wof  [NMSHR*NTARGET];
    integer sb_wr   [NMSHR];           // targets merged into this entry
    integer sb_rd   [NMSHR];           // targets replayed out of this entry

    task automatic prop_on_accept(input integer idx, input integer blk,
                                  input integer wof, input integer dst);
        integer p;
        begin
            p          = idx*NTARGET + sb_wr[idx];
            sb_dst[p]  = dst;
            sb_blk[p]  = blk;
            sb_wof[p]  = wof;
            sb_wr[idx] = sb_wr[idx] + 1;
            n_accepted = n_accepted + 1;
        end
    endtask

    task automatic prop_on_replay(input integer idx, input integer dst,
                                  input [DATA_W-1:0] data, input bit last);
        integer p;
        begin
            checks = checks + 1;
            if (sb_rd[idx] >= sb_wr[idx]) begin
                errors = errors + 1;
                $display("  ** PROP-B c%0d replay from MSHR%0d with no pending target",
                         cyc, idx);
            end else begin
                p = idx*NTARGET + sb_rd[idx];
                chk ("propD_order_dst", dst,  sb_dst[p]);            // D
                chkh("propC_value",     data, ref_word(sb_blk[p], sb_wof[p])); // C
            end
            sb_rd[idx] = sb_rd[idx] + 1;
            n_retired  = n_retired + 1;
            if (last) begin
                chk("propB_drained", sb_rd[idx], sb_wr[idx]);        // B
                sb_rd[idx] = 0;
                sb_wr[idx] = 0;
            end
        end
    endtask

    // =========================================================================
    // ENVIRONMENT - next-level memory: random latency, out-of-order return
    // =========================================================================
    bit     pend_v  [NMSHR];
    integer pend_blk[NMSHR];
    integer pend_due[NMSHR];

    task automatic idle_inputs;
        begin
            req_valid     = 0;
            req_addr      = 0;
            req_dst       = 0;
            mem_req_ready = 1;
            fill_valid    = 0;
            fill_id       = 0;
            fill_data     = 0;
            rpl_ready     = 1;
        end
    endtask

    task automatic drive_fill(input integer id, input integer blk);
        integer w;
        begin
            fill_valid = 1;
            fill_id    = id[ID_W-1:0];
            for (w = 0; w < WORDS; w = w + 1)
                fill_data[w*DATA_W +: DATA_W] = ref_word(blk, w);
        end
    endtask

    task automatic set_req(input integer blk, input integer wof, input integer dst);
        begin
            req_valid = 1;
            req_addr  = (blk << WOFF_W) | wof;
            req_dst   = dst[DST_W-1:0];
        end
    endtask

    // Runs AFTER the outputs have been sampled: records what actually happened.
    task automatic env_update;
        integer b;
        begin
            // a fill request taken by memory this cycle
            if (mem_req_valid && mem_req_ready) begin
                b = mem_req_addr;
                checks = checks + 1;
                if (blk_infl[b]) begin                               // A
                    errors = errors + 1;
                    $display("  ** PROP-A c%0d duplicate memory fetch for block %0d",
                             cyc, b);
                end
                blk_infl[b]          = 1;
                pend_v  [mem_req_id] = 1;
                pend_blk[mem_req_id] = b;
                pend_due[mem_req_id] = cyc + 2 + ({$random} % 5);
            end

            // an access accepted into the MSHR file this cycle
            if (req_valid && req_ready)
                prop_on_accept(req_id, req_addr >> WOFF_W,
                               req_addr & (WORDS-1), req_dst);

            // a fill actually consumed by the DUT this cycle
            if (fill_valid && dut.vld_q[fill_id] && !dut.done_q[fill_id]) begin
                blk_infl[pend_blk[fill_id]] = 0;
                pend_v[fill_id]             = 0;
            end

            // a replay accepted this cycle
            if (rpl_valid && rpl_ready)
                prop_on_replay(rpl_id, rpl_dst, rpl_data, rpl_last);
        end
    endtask

    // =========================================================================
    // One cycle.  step_body() is everything after the settle delay, so a
    // directed test can insert extra probes at the same sampling instant.
    // =========================================================================
    task automatic step_body;
        begin
            golden_eval();
            check_outputs();
            if (trace_on)
                $display("  c%-2d req=%0d b%0d.w%0d d=%-2d | rdy=%0d P=%0d S=%0d id=%0d | mem: v=%0d blk=%0d id=%0d rdy=%0d | fill: v=%0d id=%0d | rpl: v=%0d dst=%-2d %08h id=%0d last=%0d | V=%0d%0d%0d%0d D=%0d%0d%0d%0d out=%0d full=%0d",
                         cyc, req_valid, req_addr>>WOFF_W, req_addr & (WORDS-1),
                         req_dst,
                         req_ready, req_primary, req_secondary, req_id,
                         mem_req_valid, mem_req_addr, mem_req_id, mem_req_ready,
                         fill_valid, fill_id,
                         rpl_valid, rpl_dst, rpl_data, rpl_id, rpl_last,
                         dut.vld_q[0], dut.vld_q[1], dut.vld_q[2], dut.vld_q[3],
                         dut.done_q[0], dut.done_q[1], dut.done_q[2], dut.done_q[3],
                         n_outstanding, full);
            golden_update();
            env_update();
            cyc = cyc + 1;
            @(posedge clk);           // DUT state advances here
            @(negedge clk);           // ready for the next drive
        end
    endtask

    task automatic step;
        begin
            #4;                       // settle: sample 1 ns before the rising edge
            step_body();
        end
    endtask

    // Keep returning fills / accepting replays until the file is empty.
    task automatic drain_all;
        integer guard, k2, id2;
        begin
            guard         = 0;
            req_valid     = 0;
            mem_req_ready = 1;
            rpl_ready     = 1;
            while (n_valid != 0 && guard < 200) begin
                fill_valid = 0;
                id2 = -1;
                for (k2 = 0; k2 < NMSHR; k2 = k2 + 1)
                    if (id2 < 0 && pend_v[k2] && dut.vld_q[k2] && !dut.done_q[k2])
                        id2 = k2;
                if (id2 >= 0) drive_fill(id2, pend_blk[id2]);
                step();
                guard = guard + 1;
            end
            fill_valid = 0;
            step();
            chk("drain_completed", n_valid, 0);
        end
    endtask

    task automatic reset_all;
        integer i;
        begin
            idle_inputs();
            rst_n = 0;
            repeat (3) @(negedge clk);
            rst_n = 1;
            @(negedge clk);
            for (i = 0; i < NMSHR; i = i + 1) begin
                g_v[i] = 0; g_dn[i] = 0; g_blk[i] = 0; g_nt[i] = 0; g_nr[i] = 0;
                pend_v[i] = 0; pend_blk[i] = 0; pend_due[i] = 0;
                sb_wr[i] = 0; sb_rd[i] = 0;
            end
            for (i = 0; i < NMSHR*NTARGET; i = i + 1) begin
                g_td[i] = 0; g_tw[i] = 0;
                sb_dst[i] = 0; sb_blk[i] = 0; sb_wof[i] = 0;
            end
            for (i = 0; i < NMSHR*WORDS; i = i + 1) g_dat[i] = 0;
            for (i = 0; i < BLKMAX;       i = i + 1) blk_infl[i] = 0;
            g_err = 0;
        end
    endtask

    // =========================================================================
    // Stimulus
    // =========================================================================
    integer i, k, blk, wof, dst, id, ready_id, r;

    initial begin
        $dumpfile("mshr_file.vcd");
        $dumpvars(0, tb_mshr_file);

        reset_all();

        $display("");
        $display("=====================================================================");
        $display(" Day31 - Non-Blocking (Lockup-Free) Cache MSHR File");
        $display("   NMSHR=%0d  NTARGET=%0d  WORDS=%0d/block  ADDR_W=%0d (word)",
                 NMSHR, NTARGET, WORDS, ADDR_W);
        $display("=====================================================================");
        $display("");
        $display("--- Phase 1: directed 16-cycle window (this is the waveform) --------");
        trace_on = 1;
        $display("PHASE1_T0 = %0t", $time);

        // c0 : PRIMARY miss, block 5 word 0 -> dst 1   (allocates MSHR0)
        set_req(5, 0, 1);                          step();
        // c1 : SECONDARY miss, block 5 word 2 -> dst 2 (merge, NO bus traffic)
        set_req(5, 2, 2);                          step();
        // c2 : PRIMARY miss, block 6 word 1 -> dst 3   (MSHR1, MLP = 2)
        set_req(6, 1, 3);                          step();
        // c3 : PRIMARY miss, block 7 word 3 -> dst 4   (MSHR2, MLP = 3)
        set_req(7, 3, 4);                          step();
        // c4 : no new access; the block-6 fill comes back FIRST (out of order)
        req_valid = 0;  drive_fill(1, 6);          step();
        // c5 : replay the block-6 target (dst 3, last -> frees MSHR1)
        fill_valid = 0;                            step();
        // c6 : PRIMARY miss, block 2 -> reuses the just-freed MSHR1
        set_req(2, 1, 6);                          step();
        // c7 : the block-5 fill returns (two targets waiting on it)
        req_valid = 0;  drive_fill(0, 5);          step();
        // c8 : replay block-5 target 0 (dst 1, word 0), last = 0
        fill_valid = 0;                            step();
        // c9 : replay block-5 target 1 (dst 2, word 2), last = 1 -> frees MSHR0
        step();
        // c10: PRIMARY miss, block 3 (takes the freed MSHR0)
        set_req(3, 0, 7);                          step();
        // c11: PRIMARY miss, block 4 (MSHR3) -> the file is now FULL
        set_req(4, 2, 8);                          step();
        // c12: PRIMARY miss, block 1 -> MSHR-FILE-FULL stall, req_ready = 0
        set_req(1, 0, 9);                          step();
        // c13: the block-7 fill returns
        req_valid = 0;  drive_fill(2, 7);          step();
        // c14: replay the block-7 target (dst 4, word 3)
        fill_valid = 0;                            step();
        // c15: a miss while the bus refuses -> back-pressure stall
        set_req(1, 0, 9);  mem_req_ready = 0;      step();

        trace_on = 0;
        $display("--- end of window ---------------------------------------------------");
        $display("");

        idle_inputs();
        drain_all();

        // --------------------------------------------------------------------
        $display("--- Phase 1b: target-list-full / late merge / mid-replay / bad fill -");

        // (a) TARGET-LIST-FULL: NTARGET accesses to one block, then one more.
        set_req(9, 0, 1);  step();                       // primary
        for (k = 1; k < NTARGET; k = k + 1) begin
            set_req(9, k % WORDS, k + 1);  step();       // secondaries
        end
        chk("target_list_is_full", dut.ntgt_q[0], NTARGET);
        set_req(9, 1, 20);                               // one merge too many
        #4;
        chk("stall_on_target_full",   req_ready,     0);
        chk("no_dup_fetch_on_tgtfull",mem_req_valid, 0);
        step_body();
        $display("    target list full  -> req_ready=0 and NO second fetch issued");
        req_valid = 0;
        drain_all();

        // (b) LATE MERGE: a merge on the exact edge the fill lands.
        set_req(10, 0, 11);  step();                     // primary -> MSHR0
        drive_fill(0, 10);                               // fill lands this edge
        set_req(10, 2, 12);                              // sees done==0 -> merges
        #4;
        chk("late_merge_accepted",  req_secondary, 1);
        chk("late_merge_no_stall",  req_ready,     1);
        step_body();
        fill_valid = 0;
        req_valid  = 0;
        chk("late_merge_recorded", dut.ntgt_q[0], 2);
        chk("late_merge_filled",   dut.done_q[0], 1);
        $display("    late merge        -> target appended on the same edge as the fill");

        // (c) a miss to a block that is now mid-replay must STALL, not merge
        set_req(10, 1, 13);
        #4;
        chk("mid_replay_stall",  req_ready,     0);
        chk("mid_replay_no_bus", mem_req_valid, 0);
        step_body();
        $display("    mid-replay access -> stalls (never merges into a draining list)");
        req_valid = 0;
        drain_all();

        // (d) a fill for an unallocated tag raises the sticky error flag
        chk("err_clean_before", err_fill, 0);
        drive_fill(3, 0);
        step();
        fill_valid = 0;
        step();
        chk("err_fill_sticky", err_fill, 1);
        $display("    stray fill tag    -> err_fill raised and latched");
        $display("");

        reset_all();
        n_accepted = 0;
        n_retired  = 0;

        // --------------------------------------------------------------------
        $display("--- Phase 2: 4000 randomised cycles ---------------------------------");
        for (i = 0; i < 4000; i = i + 1) begin
            // random access from the cache (small pool -> constant merging)
            r = {$random} % 100;
            if (r < 55) begin
                blk = {$random} % NBLK;
                wof = {$random} % WORDS;
                dst = 1 + ({$random} % 30);
                set_req(blk, wof, dst);
            end else begin
                req_valid = 0;
            end

            // random bus / write-back back-pressure
            mem_req_ready = (({$random} % 100) < 80);
            rpl_ready     = (({$random} % 100) < 75);

            // memory returns ONE due fill, picked out of order
            fill_valid = 0;
            ready_id   = -1;
            for (k = 0; k < NMSHR; k = k + 1) begin
                id = {$random} % NMSHR;                 // random probe -> OoO
                if (ready_id < 0 && pend_v[id] && cyc >= pend_due[id]
                    && dut.vld_q[id] && !dut.done_q[id])
                    ready_id = id;
            end
            if (ready_id < 0)
                for (k = 0; k < NMSHR; k = k + 1)
                    if (ready_id < 0 && pend_v[k] && cyc >= pend_due[k]
                        && dut.vld_q[k] && !dut.done_q[k])
                        ready_id = k;
            if (ready_id >= 0) drive_fill(ready_id, pend_blk[ready_id]);

            step();
        end

        req_valid = 0;
        drain_all();

        // --------------------------------------------------------------------
        chk("all_entries_free",    n_valid,       0);
        chk("nothing_outstanding", n_outstanding, 0);
        chk("no_fill_errors",      err_fill,      0);
        chk("scoreboard_drained",  n_accepted,    n_retired);

        $display("");
        $display("---------------------------------------------------------------------");
        $display("Primary misses    : %0d   (one memory transaction each)", n_prim);
        $display("Secondary merges  : %0d   (rode an existing fetch - ZERO extra traffic)",
                 n_sec);
        $display("  of which same-cycle late merges : %0d", n_latemerge);
        $display("Memory fills taken: %0d      Replays retired: %0d", n_fills, n_replays);
        $display("Peak MLP observed : %0d of %0d MSHRs fetching at once", max_mlp, NMSHR);
        $display("Stall cycles      : mshr-full=%0d  target-full=%0d  mid-replay=%0d  bus-busy=%0d",
                 n_stall_full, n_stall_tgt, n_stall_drain, n_stall_bus);
        if (n_prim + n_sec > 0)
            $display("Traffic saved     : %0d%% of accepted misses needed NO memory transaction",
                     (100*n_sec)/(n_prim+n_sec));
        $display("Accesses accepted : %0d   replayed: %0d   (must be equal)",
                 n_accepted, n_retired);
        $display("---------------------------------------------------------------------");
        $display("Total cycles : %0d", cyc);
        $display("Assertions   : %0d", checks);
        $display("Errors       : %0d", errors);
        if (errors == 0) $display("RESULT: *** PASS ***");
        else             $display("RESULT: *** FAIL ***");
        $display("");
        $finish;
    end

    // ---- Watchdog ----
    initial begin
        #4000000;
        $display("RESULT: *** FAIL *** (timeout)");
        $finish;
    end

endmodule
