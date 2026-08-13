// ---------------------------------------------------------------------------
// tb_dram_scheduler.sv - Day 32
//
// Self-checking testbench for the FR-FCFS DRAM memory-access scheduler.
//
// It contains FOUR independent checkers:
//
//   1. GOLDEN MODEL - a behavioural re-implementation of the scheduling policy
//      (queue, per-bank row-buffer state, timers, bypass cap).  Every cycle the
//      DUT's ten outputs AND its full internal state (queue payloads, bank
//      state, both timer sets, the cap counter) are compared against it.
//
//   2. DRAM DEVICE MODEL - a checker written from the DEVICE's point of view,
//      which knows nothing about the queue.  It tracks per-bank open/closed
//      state and its own timers and flags any illegal command: a column access
//      to a precharged bank, an ACT on an already-open bank, a PRE on an idle
//      bank, or any tRCD / tRP / tCCD / tBURST violation.
//
//   3. TRANSACTION TRACKER - every accepted request is recorded by tag and
//      must be retired by EXACTLY ONE column command whose bank / column /
//      write-enable match, issued while the DEVICE has that request's row
//      open (the "did the access hit the right row?" property).
//
//   4. STARVATION BOUND - residency (accept -> column command) is measured for
//      every request; with a finite ROWHIT_CAP it must be bounded, which is
//      exactly the property plain FR-FCFS does not have.
//
// Phase 1  - directed 16-cycle window (the waveform in docs/)
// Phase 2  - directed starvation / bypass-cap window
// Phase 3  - directed queue-full back-pressure window
// Phase 4  - 4000 randomised cycles with locality-biased traffic
// ---------------------------------------------------------------------------

`timescale 1ns / 1ps

module tb_dram_scheduler;

    // =========================================================================
    // Configuration (must match the DUT instantiation below)
    // =========================================================================
    localparam int ROWW       = 8;
    localparam int BANKW      = 2;
    localparam int COLW       = 4;
    localparam int IDW        = 4;
    localparam int QDEPTH     = 8;
    localparam int T_RCD      = 3;
    localparam int T_RP       = 3;
    localparam int T_CCD      = 2;
    localparam int T_BURST    = 2;
    localparam int ROWHIT_CAP = 4;

    localparam int NBANKS = 2**BANKW;
    localparam int ADDRW  = ROWW + BANKW + COLW;
    localparam int CNTW   = $clog2(QDEPTH+1);
    localparam int NID    = 2**IDW;

    localparam integer OP_PRE = 0;
    localparam integer OP_ACT = 1;
    localparam integer OP_COL = 2;

    // Residency bound: an entry waits for at most QDEPTH-1 older requests, and
    // each of those departs after at most ROWHIT_CAP bypasses (>= T_BURST
    // cycles each) plus its own PRE+ACT+COL turnaround.  300 is comfortably
    // above that; the measured maximum is printed at the end.
    localparam integer RESIDENCY_BOUND = 300;

    // =========================================================================
    // DUT
    // =========================================================================
    logic                  clk, rst_n;
    logic                  req_valid, req_ready, req_we;
    logic [ADDRW-1:0]      req_addr;
    logic [IDW-1:0]        req_id;

    logic                  cmd_valid, cmd_we, cmd_bypass;
    logic [1:0]            cmd_op;
    logic [BANKW-1:0]      cmd_bank;
    logic [ROWW-1:0]       cmd_row;
    logic [COLW-1:0]       cmd_col;
    logic [IDW-1:0]        cmd_id;

    logic [CNTW-1:0]       q_count;
    logic                  q_full, q_empty;
    logic [NBANKS-1:0]     bank_active;
    logic [NBANKS*ROWW-1:0] bank_open_row;

    dram_scheduler #(
        .ROWW(ROWW), .BANKW(BANKW), .COLW(COLW), .IDW(IDW),
        .QDEPTH(QDEPTH), .T_RCD(T_RCD), .T_RP(T_RP), .T_CCD(T_CCD),
        .T_BURST(T_BURST), .ROWHIT_CAP(ROWHIT_CAP)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .req_valid(req_valid), .req_ready(req_ready), .req_we(req_we),
        .req_addr(req_addr), .req_id(req_id),
        .cmd_valid(cmd_valid), .cmd_op(cmd_op), .cmd_bank(cmd_bank),
        .cmd_row(cmd_row), .cmd_col(cmd_col), .cmd_we(cmd_we),
        .cmd_id(cmd_id), .cmd_bypass(cmd_bypass),
        .q_count(q_count), .q_full(q_full), .q_empty(q_empty),
        .bank_active(bank_active), .bank_open_row(bank_open_row)
    );

    always #5 clk = ~clk;

    // Flattened probes so the waveform renderer finds everything in the top
    // scope of the VCD.
    wire [ROWW-1:0] dbg_row0 = bank_open_row[0*ROWW +: ROWW];
    wire [ROWW-1:0] dbg_row1 = bank_open_row[1*ROWW +: ROWW];
    wire [ROWW-1:0] dbg_row2 = bank_open_row[2*ROWW +: ROWW];
    wire [ROWW-1:0] dbg_row3 = bank_open_row[3*ROWW +: ROWW];
    wire [1:0]      dbg_tmr0 = dut.bnk_tmr[0];
    wire [1:0]      dbg_tmr1 = dut.bnk_tmr[1];
    wire [1:0]      dbg_tmr2 = dut.bnk_tmr[2];
    wire [1:0]      dbg_tmr3 = dut.bnk_tmr[3];
    wire            dbg_dtmr = dut.dbus_tmr;
    wire [2:0]      dbg_cap  = dut.cap_cnt;
    wire [ROWW-1:0] dbg_reqrow  = req_addr[ADDRW-1 -: ROWW];
    wire [BANKW-1:0] dbg_reqbank = req_addr[COLW +: BANKW];
    wire [COLW-1:0] dbg_reqcol  = req_addr[COLW-1:0];

    // =========================================================================
    // Bookkeeping
    // =========================================================================
    integer errors, checks, cyc;
    integer trace_on;

    // free-tag pool (a tag is busy from accept until its column command)
    integer pool [0:NID-1];
    integer pool_n;

    integer n_req, n_col, n_act, n_pre, n_bypass, n_stall;
    integer max_res, tot_res;
    integer saw_boost_pre, saw_cap_max;

    task automatic chk(input string nm, input integer got, input integer exp);
        begin
            checks = checks + 1;
            if (got !== exp) begin
                errors = errors + 1;
                $display("  ** MISMATCH c%0d t=%0t : %s  got=%0d exp=%0d",
                         cyc, $time, nm, got, exp);
                if (errors > 25) begin
                    $display("  too many errors - stopping");
                    $finish;
                end
            end
        end
    endtask

    task automatic fail(input string nm);
        begin
            checks = checks + 1;
            errors = errors + 1;
            $display("  ** PROPERTY VIOLATION c%0d t=%0t : %s", cyc, $time, nm);
            if (errors > 25) begin
                $display("  too many errors - stopping");
                $finish;
            end
        end
    endtask

    function automatic [ADDRW-1:0] mkaddr(input integer row,
                                          input integer bank,
                                          input integer col);
        mkaddr = {row[ROWW-1:0], bank[BANKW-1:0], col[COLW-1:0]};
    endfunction

    function automatic string opname(input integer op);
        case (op)
            OP_PRE:  opname = "PRE";
            OP_ACT:  opname = "ACT";
            OP_COL:  opname = "COL";
            default: opname = "???";
        endcase
    endfunction

    // =========================================================================
    // 1. GOLDEN MODEL - independent behavioural copy of the policy
    // =========================================================================
    integer g_bank [0:QDEPTH-1];
    integer g_row  [0:QDEPTH-1];
    integer g_col  [0:QDEPTH-1];
    integer g_id   [0:QDEPTH-1];
    integer g_we   [0:QDEPTH-1];
    integer g_cnt;

    integer g_act  [0:NBANKS-1];
    integer g_orow [0:NBANKS-1];
    integer g_tmr  [0:NBANKS-1];
    integer g_dtmr, g_cap;

    // predicted outputs for this cycle
    integer p_valid, p_op, p_sel, p_bank, p_row, p_col, p_we, p_id, p_bypass;
    integer p_ready, p_deq, p_enq;

    task automatic golden_eval;
        integer i, j, b, hitp [0:NBANKS-1];
        integer colok [0:QDEPTH-1];
        integer othok [0:QDEPTH-1];
        integer ready_i, hit_i;
        integer boost, head_oth_raw, found;
        begin
            // rows that still have a customer -> do not precharge them
            for (b = 0; b < NBANKS; b = b + 1) begin
                hitp[b] = 0;
                for (j = 0; j < g_cnt; j = j + 1)
                    if (g_act[b] && (g_bank[j] == b) && (g_row[j] == g_orow[b]))
                        hitp[b] = 1;
            end

            for (i = 0; i < QDEPTH; i = i + 1) begin
                colok[i] = 0;
                othok[i] = 0;
                if (i < g_cnt) begin
                    b       = g_bank[i];
                    ready_i = (g_tmr[b] == 0);
                    hit_i   = (g_act[b] && (g_orow[b] == g_row[i]));
                    colok[i] = (ready_i &&  hit_i && (g_dtmr == 0)) ? 1 : 0;
                    othok[i] = (ready_i && !hit_i &&
                                (!g_act[b] || !hitp[b])) ? 1 : 0;
                end
            end

            boost        = ((g_cap == ROWHIT_CAP) && (g_cnt != 0)) ? 1 : 0;
            head_oth_raw = 0;
            if (g_cnt > 0) begin
                b = g_bank[0];
                head_oth_raw = ((g_tmr[b] == 0) &&
                                !(g_act[b] && (g_orow[b] == g_row[0]))) ? 1 : 0;
            end

            p_valid = 0;
            p_op    = OP_PRE;
            p_sel   = 0;

            if (boost && (colok[0] || head_oth_raw)) begin
                p_valid = 1;
                p_sel   = 0;
                b       = g_bank[0];
                p_op    = colok[0] ? OP_COL : (g_act[b] ? OP_PRE : OP_ACT);
            end else begin
                found = 0;
                for (i = QDEPTH-1; i >= 0; i = i - 1)
                    if (colok[i]) begin p_sel = i; found = 1; end
                if (found) begin
                    p_valid = 1;
                    p_op    = OP_COL;
                end else begin
                    for (i = QDEPTH-1; i >= 0; i = i - 1)
                        if (othok[i]) begin p_sel = i; found = 1; end
                    if (found) begin
                        p_valid = 1;
                        b       = g_bank[p_sel];
                        p_op    = g_act[b] ? OP_PRE : OP_ACT;
                    end
                end
            end

            p_bank   = g_bank[p_sel];
            p_row    = g_row[p_sel];
            p_col    = g_col[p_sel];
            p_we     = g_we[p_sel];
            p_id     = g_id[p_sel];
            p_bypass = (p_valid && (p_op == OP_COL) && (p_sel != 0)) ? 1 : 0;

            p_deq    = (p_valid && (p_op == OP_COL)) ? 1 : 0;
            p_ready  = ((g_cnt < QDEPTH) || p_deq) ? 1 : 0;
            p_enq    = (req_valid && p_ready) ? 1 : 0;
        end
    endtask

    task automatic golden_update;
        integer i, b, nxt;
        integer n_bank [0:QDEPTH-1];
        integer n_row  [0:QDEPTH-1];
        integer n_col  [0:QDEPTH-1];
        integer n_id   [0:QDEPTH-1];
        integer n_we   [0:QDEPTH-1];
        begin
            nxt = g_cnt - p_deq + p_enq;

            for (i = 0; i < QDEPTH; i = i + 1) begin
                n_bank[i] = g_bank[i];  n_row[i] = g_row[i];
                n_col[i]  = g_col[i];   n_id[i]  = g_id[i];
                n_we[i]   = g_we[i];
            end
            for (i = 0; i < QDEPTH; i = i + 1) begin
                if (p_deq && (i >= p_sel) && ((i+1) < g_cnt)) begin
                    n_bank[i] = g_bank[i+1];  n_row[i] = g_row[i+1];
                    n_col[i]  = g_col[i+1];   n_id[i]  = g_id[i+1];
                    n_we[i]   = g_we[i+1];
                end else if (p_enq && (i == (nxt-1))) begin
                    n_bank[i] = dbg_reqbank;  n_row[i] = dbg_reqrow;
                    n_col[i]  = dbg_reqcol;   n_id[i]  = req_id;
                    n_we[i]   = req_we;
                end
            end
            for (i = 0; i < QDEPTH; i = i + 1) begin
                g_bank[i] = n_bank[i];  g_row[i] = n_row[i];
                g_col[i]  = n_col[i];   g_id[i]  = n_id[i];
                g_we[i]   = n_we[i];
            end
            g_cnt = nxt;

            for (b = 0; b < NBANKS; b = b + 1) begin
                if (p_valid && (p_bank == b)) begin
                    if (p_op == OP_ACT) begin
                        g_act[b]  = 1;
                        g_orow[b] = p_row;
                        g_tmr[b]  = T_RCD - 1;
                    end else if (p_op == OP_PRE) begin
                        g_act[b]  = 0;
                        g_tmr[b]  = T_RP - 1;
                    end else begin
                        g_tmr[b]  = T_CCD - 1;
                    end
                end else if (g_tmr[b] != 0) begin
                    g_tmr[b] = g_tmr[b] - 1;
                end
            end

            if (p_deq)            g_dtmr = T_BURST - 1;
            else if (g_dtmr != 0) g_dtmr = g_dtmr - 1;

            if (p_deq) begin
                if (p_sel == 0)            g_cap = 0;
                else if (g_cap != ROWHIT_CAP) g_cap = g_cap + 1;
            end
        end
    endtask

    // ---- compare every output and the whole DUT state -----------------------
    task automatic check_outputs;
        integer i, b;
        begin
            chk("cmd_valid",  cmd_valid,  p_valid);
            chk("cmd_bypass", cmd_bypass, p_bypass);
            chk("req_ready",  req_ready,  p_ready);
            chk("q_count",    q_count,    g_cnt);
            chk("q_full",     q_full,     (g_cnt == QDEPTH) ? 1 : 0);
            chk("q_empty",    q_empty,    (g_cnt == 0) ? 1 : 0);

            if (p_valid) begin
                chk("cmd_op",   cmd_op,   p_op);
                chk("cmd_bank", cmd_bank, p_bank);
                chk("cmd_id",   cmd_id,   p_id);
                if (p_op == OP_ACT) chk("cmd_row", cmd_row, p_row);
                if (p_op == OP_COL) begin
                    chk("cmd_col", cmd_col, p_col);
                    chk("cmd_we",  cmd_we,  p_we);
                end
            end

            for (b = 0; b < NBANKS; b = b + 1) begin
                chk("bank_active",   bank_active[b],                g_act[b]);
                chk("bank_open_row", bank_open_row[b*ROWW +: ROWW], g_orow[b]);
                chk("bnk_tmr",       dut.bnk_tmr[b],                g_tmr[b]);
            end
            chk("dbus_tmr", dut.dbus_tmr, g_dtmr);
            chk("cap_cnt",  dut.cap_cnt,  g_cap);

            for (i = 0; i < QDEPTH; i = i + 1)
                if (i < g_cnt) begin
                    chk("q_bank", dut.q_bank[i], g_bank[i]);
                    chk("q_row",  dut.q_row[i],  g_row[i]);
                    chk("q_col",  dut.q_col[i],  g_col[i]);
                    chk("q_id",   dut.q_id[i],   g_id[i]);
                    chk("q_we",   dut.q_we[i],   g_we[i]);
                end
        end
    endtask

    // =========================================================================
    // 2. DRAM DEVICE MODEL - protocol legality, from the device's side
    // =========================================================================
    integer d_act [0:NBANKS-1];
    integer d_row [0:NBANKS-1];
    integer d_tmr [0:NBANKS-1];
    integer d_dtmr;

    task automatic device_check;
        integer b;
        begin
            if (cmd_valid) begin
                b = cmd_bank;
                if (d_tmr[b] != 0)
                    fail($sformatf("DEVICE: %s to busy bank %0d", opname(cmd_op), b));
                case (cmd_op)
                    OP_ACT: begin
                        if (d_act[b]) fail("DEVICE: ACT on an already-active bank");
                    end
                    OP_PRE: begin
                        if (!d_act[b]) fail("DEVICE: PRE on an idle bank");
                    end
                    default: begin
                        if (!d_act[b]) fail("DEVICE: column access to a closed bank");
                        if (d_dtmr != 0) fail("DEVICE: data-bus (tBURST) violation");
                    end
                endcase
            end
        end
    endtask

    task automatic device_update;
        integer b;
        begin
            for (b = 0; b < NBANKS; b = b + 1) begin
                if (cmd_valid && (cmd_bank == b)) begin
                    if (cmd_op == OP_ACT) begin
                        d_act[b] = 1; d_row[b] = cmd_row; d_tmr[b] = T_RCD-1;
                    end else if (cmd_op == OP_PRE) begin
                        d_act[b] = 0; d_tmr[b] = T_RP-1;
                    end else begin
                        d_tmr[b] = T_CCD-1;
                    end
                end else if (d_tmr[b] != 0) begin
                    d_tmr[b] = d_tmr[b] - 1;
                end
            end
            if (cmd_valid && (cmd_op == OP_COL)) d_dtmr = T_BURST-1;
            else if (d_dtmr != 0)                d_dtmr = d_dtmr - 1;
        end
    endtask

    // =========================================================================
    // 3. TRANSACTION TRACKER + 4. STARVATION BOUND
    // =========================================================================
    integer t_live [0:NID-1];
    integer t_bank [0:NID-1];
    integer t_row  [0:NID-1];
    integer t_col  [0:NID-1];
    integer t_we   [0:NID-1];
    integer t_at   [0:NID-1];
    integer t_out;                       // live transactions

    task automatic track_accept(input integer id, input integer bank,
                                input integer row, input integer col,
                                input integer we);
        begin
            if (t_live[id]) fail("TRACKER: tag reused while still outstanding");
            t_live[id] = 1; t_bank[id] = bank; t_row[id] = row;
            t_col[id]  = col; t_we[id] = we;   t_at[id]  = cyc;
            t_out      = t_out + 1;
            n_req      = n_req + 1;
        end
    endtask

    // Called with the DEVICE state as it was BEFORE this command was applied,
    // i.e. the row that is genuinely open in the array right now.
    task automatic track_retire(input integer id);
        integer res;
        begin
            if (!t_live[id]) begin
                fail("TRACKER: column command for an unknown / already-retired tag");
            end else begin
                if (t_bank[id] != cmd_bank) fail("TRACKER: column bank mismatch");
                if (t_col[id]  != cmd_col)  fail("TRACKER: column address mismatch");
                if (t_we[id]   != cmd_we)   fail("TRACKER: write-enable mismatch");
                // The access must land in the row the request actually wanted.
                if (!d_act[cmd_bank] || (d_row[cmd_bank] != t_row[id]))
                    fail("TRACKER: column access hit the WRONG row");
                res     = cyc - t_at[id];
                tot_res = tot_res + res;
                if (res > max_res) max_res = res;
                if (res > RESIDENCY_BOUND) fail("STARVATION: residency bound exceeded");
                t_live[id] = 0;
                t_out      = t_out - 1;
                pool[pool_n] = id;          // the tag is free once the request retires
                pool_n       = pool_n + 1;
            end
        end
    endtask

    // =========================================================================
    // Stimulus plumbing: a pending request that retries until accepted
    // =========================================================================
    integer pend_v, pend_we, pend_row, pend_bank, pend_col, pend_id;

    task automatic pool_init;
        integer i;
        begin
            pool_n = 0;
            for (i = 0; i < NID; i = i + 1) begin
                pool[pool_n] = i;
                pool_n = pool_n + 1;
            end
        end
    endtask

    task automatic new_req(input integer we, input integer row,
                           input integer bank, input integer col);
        begin
            if (pend_v)      fail("TB: overwrote a request that was not accepted");
            if (pool_n == 0) fail("TB: ran out of request tags");
            pool_n    = pool_n - 1;
            pend_id   = pool[pool_n];
            pend_v    = 1;
            pend_we   = we;
            pend_row  = row;
            pend_bank = bank;
            pend_col  = col;
        end
    endtask

    task automatic drive_inputs;
        begin
            req_valid = (pend_v != 0);
            req_we    = (pend_we != 0);
            req_addr  = mkaddr(pend_row, pend_bank, pend_col);
            req_id    = pend_id[IDW-1:0];
        end
    endtask

    // =========================================================================
    // One cycle
    // =========================================================================
    task automatic step_body;
        integer b;
        string  s_req, s_cmd;
        begin
            golden_eval();
            check_outputs();
            device_check();

            if (trace_on) begin
                if (req_valid)
                    s_req = $sformatf("REQ b%0d row%0d col%0d id%0d",
                                      dbg_reqbank, dbg_reqrow, dbg_reqcol, req_id);
                else
                    s_req = "-";
                if (!cmd_valid)
                    s_cmd = "NOP";
                else if (cmd_op == OP_ACT)
                    s_cmd = $sformatf("ACT b%0d row%0d", cmd_bank, cmd_row);
                else if (cmd_op == OP_PRE)
                    s_cmd = $sformatf("PRE b%0d", cmd_bank);
                else
                    s_cmd = $sformatf("COL b%0d col%0d id%0d %s%s",
                                      cmd_bank, cmd_col, cmd_id,
                                      cmd_we ? "WR" : "RD",
                                      cmd_bypass ? " BYPASS" : "");
                $display("  c%-2d | %-26s rdy=%0d | %-24s | q=%0d cap=%0d act=%b rows=%0d,%0d,%0d,%0d",
                         cyc, s_req, req_ready, s_cmd,
                         q_count, dbg_cap, bank_active,
                         dbg_row0, dbg_row1, dbg_row2, dbg_row3);
            end

            // ---- statistics / properties on this cycle's command ------------
            if (cmd_valid) begin
                if (cmd_op == OP_ACT) n_act = n_act + 1;
                if (cmd_op == OP_PRE) begin
                    n_pre = n_pre + 1;
                    // A precharge issued while a request for the open row is
                    // still queued can only be the fairness boost firing.
                    for (b = 0; b < g_cnt; b = b + 1)
                        if ((g_bank[b] == cmd_bank) && g_act[cmd_bank] &&
                            (g_row[b] == g_orow[cmd_bank]))
                            saw_boost_pre = 1;
                end
                if (cmd_op == OP_COL) begin
                    n_col = n_col + 1;
                    if (cmd_bypass) n_bypass = n_bypass + 1;
                    track_retire(cmd_id);
                end
            end
            if (dbg_cap == ROWHIT_CAP)   saw_cap_max = 1;
            if (req_valid && !req_ready) n_stall = n_stall + 1;
            if (req_valid && req_ready)
                track_accept(req_id, pend_bank, pend_row, pend_col, pend_we);

            golden_update();
            device_update();
            if (req_valid && req_ready) pend_v = 0;

            cyc = cyc + 1;
            @(posedge clk);            // DUT state advances here
            @(negedge clk);            // ready for the next drive
        end
    endtask

    task automatic step;
        begin
            drive_inputs();
            #4;                        // settle, 1 ns before the rising edge
            step_body();
        end
    endtask

    task automatic drain;
        integer guard;
        begin
            guard = 0;
            while (((g_cnt != 0) || pend_v) && (guard < 400)) begin
                step();
                guard = guard + 1;
            end
            chk("drained", g_cnt, 0);
            chk("no_live_transactions", t_out, 0);
        end
    endtask

    task automatic reset_all;
        integer i;
        begin
            req_valid = 0; req_we = 0; req_addr = 0; req_id = 0;
            pend_v = 0; pend_we = 0; pend_row = 0; pend_bank = 0;
            pend_col = 0; pend_id = 0;
            rst_n = 0;
            repeat (3) @(negedge clk);
            rst_n = 1;
            @(negedge clk);
            for (i = 0; i < QDEPTH; i = i + 1) begin
                g_bank[i] = 0; g_row[i] = 0; g_col[i] = 0;
                g_id[i] = 0;   g_we[i] = 0;
            end
            g_cnt = 0; g_dtmr = 0; g_cap = 0; d_dtmr = 0;
            for (i = 0; i < NBANKS; i = i + 1) begin
                g_act[i] = 0; g_orow[i] = 0; g_tmr[i] = 0;
                d_act[i] = 0; d_row[i] = 0; d_tmr[i] = 0;
            end
            for (i = 0; i < NID; i = i + 1) t_live[i] = 0;
            t_out = 0;
            pool_init();
        end
    endtask

    // =========================================================================
    // Stimulus
    // =========================================================================
    integer i, k, r, rb, rr, rc, guard;
    integer last_row [0:NBANKS-1];

    initial begin
        clk = 0;
        errors = 0; checks = 0; cyc = 0; trace_on = 0;
        n_req = 0; n_col = 0; n_act = 0; n_pre = 0; n_bypass = 0; n_stall = 0;
        max_res = 0; tot_res = 0; saw_boost_pre = 0; saw_cap_max = 0;
        for (i = 0; i < NBANKS; i = i + 1) last_row[i] = 0;

        $dumpfile("dram_scheduler.vcd");
        $dumpvars(0, tb_dram_scheduler);

        reset_all();

        $display("");
        $display("=====================================================================");
        $display(" Day32 - FR-FCFS DRAM Memory-Access Scheduler");
        $display("   %0d banks, %0d-entry queue, tRCD=%0d tRP=%0d tCCD=%0d tBURST=%0d, cap=%0d",
                 NBANKS, QDEPTH, T_RCD, T_RP, T_CCD, T_BURST, ROWHIT_CAP);
        $display("=====================================================================");
        $display("");

        // ---- reset state -------------------------------------------------
        chk("reset_q_empty",  q_empty,     1);
        chk("reset_cmd",      cmd_valid,   0);
        chk("reset_banks",    bank_active, 0);
        chk("reset_ready",    req_ready,   1);

        // -----------------------------------------------------------------
        // Phase 1 - directed 16-cycle window (this is the waveform)
        // -----------------------------------------------------------------
        $display("--- Phase 1: directed 16-cycle window (this is the waveform) --------");
        trace_on = 1;
        $display("PHASE1_T0 = %0t", $time);

        // c0 : A -> bank0 row5 col0 (queue empty, nothing to schedule yet)
        new_req(0, 5, 0, 0);   step();
        // c1 : B -> bank0 row5 col1  ... A activates row5 in bank0
        new_req(0, 5, 0, 1);   step();
        // c2 : C -> bank1 row9 col0  (a different bank: parallelism)
        new_req(0, 9, 1, 0);   step();
        // c3 : bank1 activates while bank0 is still in tRCD
        step();
        // c4 : A's column access - the first row hit
        step();
        // c5 : D -> bank0 row7 col3  (will conflict with the open row5)
        new_req(1, 7, 0, 3);   step();
        // c6 : E -> bank0 row5 col2  (a hit, younger than D)
        new_req(0, 5, 0, 2);   step();
        // c7..c15 : no new traffic - watch FR-FCFS drain it
        for (k = 7; k < 16; k = k + 1) step();

        trace_on = 0;
        drain();
        chk("p1_all_retired", t_out, 0);
        $display("    after phase 1: %0d requests, %0d COL, %0d ACT, %0d PRE, %0d bypass",
                 n_req, n_col, n_act, n_pre, n_bypass);
        $display("");

        // -----------------------------------------------------------------
        // Phase 2 - starvation / bypass-cap window
        // -----------------------------------------------------------------
        $display("--- Phase 2: bypass cap (the fairness mechanism) --------------------");
        begin : phase2
            integer victim_id, victim_at;
            // Open row 1 of bank 2 and let one access complete ...
            new_req(0, 1, 2, 0);   step();
            while (!(cmd_valid && (cmd_op == OP_COL))) step();
            // ... queue three more hits to that same open row ...
            for (k = 0; k < 3; k = k + 1) begin
                new_req(0, 1, 2, k);   step();
            end
            // ... then the VICTIM: same bank, a DIFFERENT row.  It can only be
            // served by throwing the open row away.
            new_req(0, 2, 2, 5);
            victim_id = pend_id;
            step();
            victim_at = cyc;
            // From here on, keep the open row permanently in demand.  Plain
            // FR-FCFS would service the endless stream of younger hits and
            // never precharge, starving the victim forever.
            guard = 0;
            while (t_live[victim_id] && (guard < 200)) begin
                if (!pend_v && (pool_n > 2)) new_req(0, 1, 2, guard[3:0]);
                step();
                guard = guard + 1;
            end
            if (t_live[victim_id]) fail("victim never scheduled (starvation)");
            $display("    victim retired after %0d cycles (bound %0d); cap saturated=%0d, boosted precharge=%0d",
                     cyc - victim_at, RESIDENCY_BOUND, saw_cap_max, saw_boost_pre);
            chk("cap_saturated", saw_cap_max,   1);
            chk("cap_fired",     saw_boost_pre, 1);
            drain();
        end
        $display("");

        // -----------------------------------------------------------------
        // Phase 3 - queue-full back-pressure
        // -----------------------------------------------------------------
        $display("--- Phase 3: queue-full back-pressure -------------------------------");
        begin : phase3
            integer saw_full, base_req;
            saw_full = 0;
            base_req   = n_req;
            // Worst-case traffic: every request a row conflict in one bank, so
            // the queue fills faster than it drains.
            for (k = 0; k < 40; k = k + 1) begin
                if (!pend_v && (pool_n > 2)) new_req(k[0], (k % 5), 3, k[3:0]);
                step();
                if (q_full) saw_full = 1;
            end
            chk("saw_queue_full", saw_full, 1);
            drain();
            $display("    %0d requests pushed through a full queue, %0d ready-stall cycles",
                     n_req - base_req, n_stall);
        end
        $display("");

        // -----------------------------------------------------------------
        // Phase 4 - randomised traffic
        // -----------------------------------------------------------------
        $display("--- Phase 4: 4000 randomised cycles ---------------------------------");
        begin : phase4
            integer base_req;
            base_req = n_req;
            for (k = 0; k < 4000; k = k + 1) begin
                if (!pend_v && (pool_n > 2) && (({$random} % 100) < 70)) begin
                    rb = {$random} % NBANKS;
                    // locality-biased: mostly re-use this bank's last row
                    if (({$random} % 100) < 60) rr = last_row[rb];
                    else                        rr = {$random} % 6;
                    rc = {$random} % (2**COLW);
                    last_row[rb] = rr;
                    new_req({$random} % 2, rr, rb, rc);
                end
                step();
            end
            drain();
            $display("    %0d requests issued in phase 4", n_req - base_req);
        end
        $display("");

        // -----------------------------------------------------------------
        // Summary
        // -----------------------------------------------------------------
        chk("final_all_retired", t_out, 0);
        chk("final_queue_empty", q_count, 0);
        if (n_bypass == 0) fail("no reordering ever happened - FR-FCFS untested");
        if (n_pre    == 0) fail("no row conflict ever happened - test too easy");

        $display("=====================================================================");
        $display(" requests        : %0d", n_req);
        $display(" commands        : %0d COL, %0d ACT, %0d PRE  (%0d total)",
                 n_col, n_act, n_pre, n_col + n_act + n_pre);
        $display(" row-buffer hits : %0d / %0d = %0d%%  (a request needing no ACT)",
                 n_col - n_act, n_col, (100*(n_col - n_act))/((n_col == 0) ? 1 : n_col));
        $display(" reordered (bypass) column commands : %0d", n_bypass);
        $display(" residency       : max %0d cycles, mean %0d (bound %0d)",
                 max_res, tot_res/((n_req == 0) ? 1 : n_req), RESIDENCY_BOUND);
        $display(" ready-stall cycles : %0d", n_stall);
        $display(" assertions      : %0d", checks);
        $display("=====================================================================");
        if (errors == 0)
            $display("RESULT: *** PASS *** (%0d checks, 0 mismatches)", checks);
        else
            $display("RESULT: *** FAIL *** (%0d checks, %0d mismatches)", checks, errors);
        $display("");
        $finish;
    end

    // global timeout
    initial begin
        #900000;
        $display("RESULT: *** FAIL *** timeout");
        $finish;
    end

endmodule
