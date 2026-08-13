// ---------------------------------------------------------------------------
// dram_scheduler.sv - Day 32
//
// FR-FCFS DRAM memory-access scheduler (First-Ready, First-Come-First-Served)
// with per-bank row-buffer state, bank-level parallelism, a shared data bus,
// and a bounded-bypass cap that makes the policy starvation-free.
//
// The scheduler sits between the last-level cache / MSHR file (Day 31) and the
// DRAM devices.  It accepts memory requests in program order, holds them in an
// age-ordered queue, and emits ONE DRAM command per cycle on the command bus:
//
//     ACT  <bank,row>   open (activate) a row into the bank's row buffer
//     PRE  <bank>       close (precharge) the open row
//     COL  <bank,col>   the actual READ/WRITE column access - a "row hit"
//
// A request is complete when its COL command has been issued; a request whose
// row is already open costs ONE command, one whose bank is idle costs two
// (ACT+COL), and one that conflicts with an open row costs three
// (PRE+ACT+COL) plus tRP+tRCD of dead time.  Reordering to favour the cheap
// case is the entire point of FR-FCFS.
//
// Timing model (bank timers + one shared data-bus timer):
//     T_RCD    ACT -> COL to the same bank
//     T_RP     PRE -> ACT to the same bank
//     T_CCD    COL -> next command to the same bank
//     T_BURST  COL -> next COL to ANY bank (the shared DQ data bus)
//
// Everything is synthesizable, reset-safe, and free of data-dependent
// variable bit-selects.
// ---------------------------------------------------------------------------

`timescale 1ns / 1ps

module dram_scheduler #(
    // ---- address geometry -------------------------------------------------
    parameter int ROWW       = 8,   // row-address bits
    parameter int BANKW      = 2,   // bank-address bits (NBANKS = 2**BANKW)
    parameter int COLW       = 4,   // column-address bits
    parameter int IDW        = 4,   // request tag width
    // ---- queue ------------------------------------------------------------
    parameter int QDEPTH     = 8,   // transaction-queue entries
    // ---- DRAM timing (in clocks, each >= 1) -------------------------------
    parameter int T_RCD      = 3,   // ACT -> COL, same bank
    parameter int T_RP       = 3,   // PRE -> ACT, same bank
    parameter int T_CCD      = 2,   // COL -> any command, same bank
    parameter int T_BURST    = 2,   // COL -> COL, any bank (shared data bus)
    // ---- fairness ---------------------------------------------------------
    parameter int ROWHIT_CAP = 4    // max column commands that may bypass the
                                    // queue head before the head is boosted
) (
    input  logic                      clk,
    input  logic                      rst_n,

    // ---- request port (from the LLC / MSHR file) --------------------------
    input  logic                      req_valid,
    output logic                      req_ready,
    input  logic                      req_we,
    input  logic [ROWW+BANKW+COLW-1:0] req_addr,   // {row, bank, col}
    input  logic [IDW-1:0]            req_id,

    // ---- DRAM command bus (one command per cycle, always accepted) --------
    output logic                      cmd_valid,
    output logic [1:0]                cmd_op,      // OP_PRE / OP_ACT / OP_COL
    output logic [BANKW-1:0]          cmd_bank,
    output logic [ROWW-1:0]           cmd_row,     // meaningful for ACT
    output logic [COLW-1:0]           cmd_col,     // meaningful for COL
    output logic                      cmd_we,      // meaningful for COL
    output logic [IDW-1:0]            cmd_id,      // meaningful for COL
    output logic                      cmd_bypass,  // COL issued out of order

    // ---- status -----------------------------------------------------------
    output logic [$clog2(QDEPTH+1)-1:0] q_count,
    output logic                      q_full,
    output logic                      q_empty,
    output logic [(2**BANKW)-1:0]     bank_active,
    output logic [(2**BANKW)*ROWW-1:0] bank_open_row
);

    // ---- command opcodes ---------------------------------------------------
    localparam logic [1:0] OP_PRE = 2'd0;
    localparam logic [1:0] OP_ACT = 2'd1;
    localparam logic [1:0] OP_COL = 2'd2;

    // ---- derived sizes -----------------------------------------------------
    localparam int NBANKS = 2**BANKW;
    localparam int ADDRW  = ROWW + BANKW + COLW;
    localparam int IDXW   = (QDEPTH > 1) ? $clog2(QDEPTH) : 1;
    localparam int CNTW   = $clog2(QDEPTH+1);

    localparam int TMAX   = (T_RCD > T_RP)
                          ? ((T_RCD > T_CCD) ? T_RCD : T_CCD)
                          : ((T_RP  > T_CCD) ? T_RP  : T_CCD);
    localparam int TW     = (TMAX  > 1) ? $clog2(TMAX)   : 1;
    localparam int TBW    = (T_BURST > 1) ? $clog2(T_BURST) : 1;
    localparam int CAPW   = $clog2(ROWHIT_CAP+1);

    // =======================================================================
    // State
    // =======================================================================
    // Age-ordered transaction queue.  Entry 0 is always the OLDEST request;
    // a departure collapses the array, so the index IS the age rank and no
    // sequence numbers or age matrix are needed.
    logic [BANKW-1:0]  q_bank [QDEPTH];
    logic [ROWW-1:0]   q_row  [QDEPTH];
    logic [COLW-1:0]   q_col  [QDEPTH];
    logic [IDW-1:0]    q_id   [QDEPTH];
    logic              q_we   [QDEPTH];
    logic [CNTW-1:0]   q_cnt;

    // Per-bank row-buffer state and the shared data bus.
    logic [NBANKS-1:0] bnk_act;             // a row is open
    logic [ROWW-1:0]   bnk_row [NBANKS];    // which row is open
    logic [TW-1:0]     bnk_tmr [NBANKS];    // cycles until the bank is free
    logic [TBW-1:0]    dbus_tmr;            // cycles until the DQ bus is free

    // Consecutive column commands that have bypassed the queue head.
    logic [CAPW-1:0]   cap_cnt;

    // =======================================================================
    // Request address decode: addr = {row, bank, col}
    // =======================================================================
    logic [ROWW-1:0]  req_row;
    logic [BANKW-1:0] req_bank;
    logic [COLW-1:0]  req_colad;

    assign req_row   = req_addr[ADDRW-1 -: ROWW];
    assign req_bank  = req_addr[COLW +: BANKW];
    assign req_colad = req_addr[COLW-1:0];

    // =======================================================================
    // Per-entry scheduling predicates
    // =======================================================================
    logic [QDEPTH-1:0] e_valid;   // slot holds a request
    logic [QDEPTH-1:0] e_ready;   // its bank can accept a command this cycle
    logic [QDEPTH-1:0] e_hit;     // its row is the one currently open
    logic [QDEPTH-1:0] col_ok;    // may issue its column command now
    logic [QDEPTH-1:0] oth_ok;    // may issue the ACT or PRE it still needs

    // hit_pending[b]: some queued request targets the row bank b has open.
    // Used to forbid a precharge that would throw away a row somebody still
    // wants (the classic "don't close a row with hits pending" guard).
    logic [NBANKS-1:0] hit_pending;

    always_comb begin
        for (int b = 0; b < NBANKS; b++) begin
            hit_pending[b] = 1'b0;
            for (int j = 0; j < QDEPTH; j++) begin
                if ((j < q_cnt) && bnk_act[b] &&
                    (q_bank[j] == b) && (q_row[j] == bnk_row[b]))
                    hit_pending[b] = 1'b1;
            end
        end
    end

    always_comb begin
        for (int i = 0; i < QDEPTH; i++) begin
            logic [BANKW-1:0] b;
            b          = q_bank[i];
            e_valid[i] = (i < q_cnt);
            e_ready[i] = e_valid[i] && (bnk_tmr[b] == '0);
            e_hit[i]   = bnk_act[b] && (bnk_row[b] == q_row[i]);
            // Row hit -> column access, but the shared DQ bus must be free.
            col_ok[i]  = e_ready[i] &&  e_hit[i] && (dbus_tmr == '0);
            // Otherwise the entry needs an ACT (bank idle) or a PRE (bank
            // holding the wrong row); a PRE is held off while hits pend.
            oth_ok[i]  = e_ready[i] && !e_hit[i] &&
                         (!bnk_act[b] || !hit_pending[b]);
        end
    end

    // Lowest set index = oldest candidate (the FCFS half of FR-FCFS).
    function automatic [IDXW-1:0] oldest_of(input logic [QDEPTH-1:0] v);
        logic [IDXW-1:0] r;
        begin
            r = '0;
            for (int k = QDEPTH-1; k >= 0; k--)
                if (v[k]) r = k[IDXW-1:0];
            oldest_of = r;
        end
    endfunction

    // =======================================================================
    // Command selection
    //   1. head boost  - after ROWHIT_CAP bypasses the oldest request wins
    //                    outright (this is what bounds its wait)
    //   2. first-ready - any pending row hit, oldest first
    //   3. first-come  - otherwise the oldest request that needs an ACT/PRE
    // =======================================================================
    logic [BANKW-1:0]  head_bank;
    logic              head_oth_raw;   // head may ACT/PRE, precharge guard waived
    logic              boost;          // head is being priority-boosted
    logic              head_go;
    logic [IDXW-1:0]   sel;
    logic [BANKW-1:0]  sel_bank;

    assign head_bank    = q_bank[0];
    assign head_oth_raw = e_ready[0] && !e_hit[0];
    assign boost        = (cap_cnt == ROWHIT_CAP[CAPW-1:0]) && (q_cnt != '0);
    assign head_go      = boost && (col_ok[0] || head_oth_raw);

    always_comb begin
        cmd_valid = 1'b0;
        cmd_op    = OP_PRE;
        sel       = '0;

        if (head_go) begin
            cmd_valid = 1'b1;
            sel       = '0;
            cmd_op    = col_ok[0] ? OP_COL : (bnk_act[head_bank] ? OP_PRE : OP_ACT);
        end else if (|col_ok) begin
            cmd_valid = 1'b1;
            sel       = oldest_of(col_ok);
            cmd_op    = OP_COL;
        end else if (|oth_ok) begin
            cmd_valid = 1'b1;
            sel       = oldest_of(oth_ok);
            cmd_op    = bnk_act[q_bank[oldest_of(oth_ok)]] ? OP_PRE : OP_ACT;
        end
    end

    assign sel_bank   = q_bank[sel];
    assign cmd_bank   = sel_bank;
    assign cmd_row    = q_row[sel];
    assign cmd_col    = q_col[sel];
    assign cmd_we     = q_we[sel];
    assign cmd_id     = q_id[sel];
    assign cmd_bypass = cmd_valid && (cmd_op == OP_COL) && (sel != '0);

    // A column command retires its request.
    logic do_deq, do_enq;
    logic [CNTW-1:0] cnt_nxt;

    assign do_deq  = cmd_valid && (cmd_op == OP_COL);
    // Room now, or room being freed this very cycle.
    assign req_ready = (q_cnt < QDEPTH[CNTW-1:0]) || do_deq;
    assign do_enq  = req_valid && req_ready;
    assign cnt_nxt = q_cnt - (do_deq ? {{(CNTW-1){1'b0}},1'b1} : '0)
                           + (do_enq ? {{(CNTW-1){1'b0}},1'b1} : '0);

    // =======================================================================
    // Sequential update
    // =======================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            q_cnt    <= '0;
            bnk_act  <= '0;
            dbus_tmr <= '0;
            cap_cnt  <= '0;
            for (int b = 0; b < NBANKS; b++) begin
                bnk_row[b] <= '0;
                bnk_tmr[b] <= '0;
            end
            for (int i = 0; i < QDEPTH; i++) begin
                q_bank[i] <= '0;
                q_row[i]  <= '0;
                q_col[i]  <= '0;
                q_id[i]   <= '0;
                q_we[i]   <= 1'b0;
            end
        end else begin
            // ---- queue: collapse on departure, append on arrival ----------
            for (int i = 0; i < QDEPTH; i++) begin
                if (do_deq && (i >= sel) && ((i+1) < q_cnt)) begin
                    q_bank[i] <= q_bank[i+1];
                    q_row[i]  <= q_row[i+1];
                    q_col[i]  <= q_col[i+1];
                    q_id[i]   <= q_id[i+1];
                    q_we[i]   <= q_we[i+1];
                end else if (do_enq && (i == (cnt_nxt - 1))) begin
                    q_bank[i] <= req_bank;
                    q_row[i]  <= req_row;
                    q_col[i]  <= req_colad;
                    q_id[i]   <= req_id;
                    q_we[i]   <= req_we;
                end
            end
            q_cnt <= cnt_nxt;

            // ---- bank timers / row-buffer state ---------------------------
            for (int b = 0; b < NBANKS; b++) begin
                if (cmd_valid && (sel_bank == b)) begin
                    case (cmd_op)
                        OP_ACT: begin
                            bnk_act[b] <= 1'b1;
                            bnk_row[b] <= q_row[sel];
                            bnk_tmr[b] <= (T_RCD-1);
                        end
                        OP_PRE: begin
                            bnk_act[b] <= 1'b0;
                            bnk_tmr[b] <= (T_RP-1);
                        end
                        default: begin   // OP_COL
                            bnk_tmr[b] <= (T_CCD-1);
                        end
                    endcase
                end else if (bnk_tmr[b] != '0) begin
                    bnk_tmr[b] <= bnk_tmr[b] - 1'b1;
                end
            end

            // ---- shared data bus ------------------------------------------
            if (do_deq)                dbus_tmr <= (T_BURST-1);
            else if (dbus_tmr != '0)   dbus_tmr <= dbus_tmr - 1'b1;

            // ---- bypass cap: cleared when the head itself departs ---------
            if (do_deq) begin
                if (sel == '0)                            cap_cnt <= '0;
                else if (cap_cnt != ROWHIT_CAP[CAPW-1:0]) cap_cnt <= cap_cnt + 1'b1;
            end
        end
    end

    // =======================================================================
    // Status outputs
    // =======================================================================
    assign q_count     = q_cnt;
    assign q_full      = (q_cnt == QDEPTH[CNTW-1:0]);
    assign q_empty     = (q_cnt == '0);
    assign bank_active = bnk_act;

    genvar gb;
    generate
        for (gb = 0; gb < NBANKS; gb++) begin : g_open_row
            assign bank_open_row[gb*ROWW +: ROWW] = bnk_row[gb];
        end
    endgenerate

endmodule
