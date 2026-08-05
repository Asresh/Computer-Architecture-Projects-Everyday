// -----------------------------------------------------------------------------
// Day30 - Self-checking testbench for the MESI snooping cache-coherence
//         controller.
// -----------------------------------------------------------------------------
// The testbench plays THREE roles at once:
//
//   1. the CPU              - issues loads/stores, holds each request until
//                             cpu_ready;
//   2. the shared bus + the OTHER core - completes BusRd/BusRdX/BusUpgr/BusWB
//                             transactions after a (randomised) latency, drives
//                             bus_shared from a shadow "does the remote cache
//                             hold a copy?" bit, and injects remote snoops;
//   3. an INDEPENDENT golden model - MESI expressed as protocol TRANSITION
//                             TABLES (`snoop_next_st`, `local_needs_bus`,
//                             `fill_next_st`) plus a small request tracker,
//                             rather than as a copy of the RTL's case
//                             statement.
//
// Every cycle it samples the DUT's combinational outputs at the settled
// pre-edge instant and compares cpu_ready / cpu_rdata / bus_req / bus_cmd /
// bus_addr / bus_wdata / snp_hit / snp_shared / snp_flush / snp_data / the FSM
// state / and the FULL per-line {state, tag, data} arrays against the model.
//
// On top of the lockstep comparison it checks three protocol INVARIANTS that
// are properties of coherence itself, not of this implementation:
//
//   A. single-writer  - if this cache holds a line in E or M, the shadow
//                       remote cache must NOT hold a copy of that address.
//   B. flush-only-if-dirty - snp_flush may only assert on an M line, and never
//                       for a BusUpgr.
//   C. value coherence - every load must return the architecturally correct
//                       value of that address (tracked in `ref_mem`, updated by
//                       CPU stores and by remote writes), and after draining
//                       all dirty lines out of the cache, main memory must
//                       equal `ref_mem` word for word. That is an end-to-end
//                       check of the write-back / flush data path.
//
// The DUT is a COMPACT demo configuration (ADDR_W=16, LINES=4, 16 words of
// memory => 4 tags competing for every set) so the directed Phase-1 scenario -
// read miss to E, silent E->M store, remote BusRd flush + M->S downgrade,
// S->M via BusUpgr, dirty-victim write-back, shared fill to S, remote BusUpgr
// invalidate - fits in one renderable 16-cycle window. Phase 1b then forces the
// upgrade-lost race, and Phase 2 pounds it with 4000 randomised cycles.
//
//   RESULT: *** PASS ***   is printed only if every assertion held.
// -----------------------------------------------------------------------------

`timescale 1ns / 1ps

module tb_mesi_cache;

    // ---- Compact demo configuration ----
    localparam int ADDR_W = 16;
    localparam int DATA_W = 32;
    localparam int LINES  = 4;
    localparam int IDX_W  = 2;                  // $clog2(LINES)
    localparam int TAG_W  = ADDR_W - IDX_W - 2; // 12
    localparam int NWORDS = 16;                 // 4 tags per set

    // ---- MESI states / bus commands (must match the RTL encodings) ----
    localparam integer ST_I = 0, ST_S = 1, ST_E = 2, ST_M = 3;
    localparam integer CMD_RD = 0, CMD_RDX = 1, CMD_UPGR = 2, CMD_WB = 3;
    localparam integer F_IDLE = 0, F_WB = 1, F_FILL = 2, F_UPGR = 3;

    // ---- DUT I/O ----
    logic                      clk, rst_n;
    logic                      cpu_req, cpu_we;
    logic [ADDR_W-1:0]         cpu_addr;
    logic [DATA_W-1:0]         cpu_wdata, cpu_rdata;
    logic                      cpu_ready;
    logic                      bus_req;
    logic [1:0]                bus_cmd;
    logic [ADDR_W-1:0]         bus_addr;
    logic [DATA_W-1:0]         bus_wdata;
    logic                      bus_done;
    logic [DATA_W-1:0]         bus_rdata;
    logic                      bus_shared;
    logic                      snp_valid;
    logic [1:0]                snp_cmd;
    logic [ADDR_W-1:0]         snp_addr;
    logic                      snp_hit, snp_shared, snp_flush;
    logic [DATA_W-1:0]         snp_data;
    logic [2*LINES-1:0]        dbg_state;
    logic [TAG_W*LINES-1:0]    dbg_tag;
    logic [DATA_W*LINES-1:0]   dbg_data;
    logic [1:0]                dbg_fsm;

    // Value the remote core writes when it takes ownership (RdX / Upgr snoop).
    logic [DATA_W-1:0]         snp_newval;

    // Per-line state broken out by name so the VCD / waveform is readable.
    wire [1:0] st0 = dbg_state[1:0];
    wire [1:0] st1 = dbg_state[3:2];
    wire [1:0] st2 = dbg_state[5:4];
    wire [1:0] st3 = dbg_state[7:6];

    mesi_cache #(
        .ADDR_W(ADDR_W), .DATA_W(DATA_W), .LINES(LINES)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .cpu_req(cpu_req), .cpu_we(cpu_we), .cpu_addr(cpu_addr),
        .cpu_wdata(cpu_wdata), .cpu_rdata(cpu_rdata), .cpu_ready(cpu_ready),
        .bus_req(bus_req), .bus_cmd(bus_cmd), .bus_addr(bus_addr),
        .bus_wdata(bus_wdata), .bus_done(bus_done), .bus_rdata(bus_rdata),
        .bus_shared(bus_shared),
        .snp_valid(snp_valid), .snp_cmd(snp_cmd), .snp_addr(snp_addr),
        .snp_hit(snp_hit), .snp_shared(snp_shared), .snp_flush(snp_flush),
        .snp_data(snp_data),
        .dbg_state(dbg_state), .dbg_tag(dbg_tag), .dbg_data(dbg_data),
        .dbg_fsm(dbg_fsm)
    );

    // ---- Clock : 10 ns period ----
    initial clk = 1'b0;
    always #5 clk = ~clk;

    // =========================================================================
    // Environment : main memory + shadow remote cache + architectural reference
    // =========================================================================
    integer mem     [0:NWORDS-1];   // bus-visible memory (stale while we hold M)
    integer ref_mem [0:NWORDS-1];   // architecturally correct value of each word
    integer rem_copy[0:NWORDS-1];   // 1 = the OTHER cache holds a copy

    integer bus_wait, bus_lat_cfg;

    // ---- statistics ----
    integer n_fill_rd, n_fill_rdx, n_upgr, n_wb, n_flush, n_silent_em;
    integer n_take_e, n_take_s, n_lost_upgr, n_blocked;

    // =========================================================================
    // Independent golden model
    // =========================================================================
    integer g_st  [0:LINES-1];
    integer g_tag [0:LINES-1];
    integer g_dat [0:LINES-1];
    integer g_fsm;
    integer g_paddr, g_pwdata, g_pwe, g_lost, g_wbaddr, g_wbdata;

    // expected combinational values for the current cycle
    integer e_cpu_ready, e_cpu_rdata;
    integer e_bus_req, e_bus_cmd, e_bus_addr, e_bus_wdata;
    integer e_snp_lhit, e_snp_shared, e_snp_flush, e_snp_data;
    integer e_blocked, e_hit, e_cst, e_upgr_kill;
    integer g_cidx, g_ctag, g_sidx, g_stag, g_pidx, g_ptag;

    integer checks, errors, cyc, trace_on;

    function automatic integer idxof(input integer a);
        begin idxof = (a >> 2) & (LINES - 1); end
    endfunction

    function automatic integer tagof(input integer a);
        begin tagof = a >> (2 + IDX_W); end
    endfunction

    function automatic integer addrof(input integer tg, input integer ix);
        begin addrof = (tg << (2 + IDX_W)) | (ix << 2); end
    endfunction

    // ---- MESI snoop transition table -----------------------------------------
    //           observed remote command
    //   my st |  BusRd   BusRdX  BusUpgr
    //   ------+-------------------------
    //     S   |    S       I        I
    //     E   |    S       I        I
    //     M   |    S*      I*       -      (* = we must flush the dirty data)
    // Invalid lines are unaffected (no hit at all).
    function automatic integer snoop_next_st(input integer cmd, input integer cur);
        begin
            if (cur == ST_I)          snoop_next_st = ST_I;
            else if (cmd == CMD_RD)   snoop_next_st = ST_S;
            else                      snoop_next_st = ST_I;   // RdX / Upgr
        end
    endfunction

    // ---- does a local access need the bus? -----------------------------------
    //   load  : only on a miss.
    //   store : on a miss, and on a hit in S (must invalidate the sharers).
    //           a hit in E or M needs NOTHING - that is the MESI payoff.
    function automatic integer local_needs_bus(input integer we, input integer hit,
                                               input integer cur);
        begin
            if (!hit)                        local_needs_bus = 1;
            else if (we && (cur == ST_S))    local_needs_bus = 1;
            else                             local_needs_bus = 0;
        end
    endfunction

    // ---- state a fill lands in ----------------------------------------------
    //   store fill (BusRdX)          -> M
    //   load fill, nobody answered   -> E   (Illinois protocol)
    //   load fill, a sharer answered -> S
    function automatic integer fill_next_st(input integer we, input integer shared);
        begin
            if (we)          fill_next_st = ST_M;
            else if (shared) fill_next_st = ST_S;
            else             fill_next_st = ST_E;
        end
    endfunction

    task automatic golden_eval;
        begin
            // ---------- snoop response (pure function of the arrays) ----------
            g_sidx = idxof(snp_addr);
            g_stag = tagof(snp_addr);
            e_snp_lhit = (snp_valid && (snp_cmd != CMD_WB) &&
                          (g_st[g_sidx] != ST_I) &&
                          (g_tag[g_sidx] == g_stag)) ? 1 : 0;
            e_snp_shared = (e_snp_lhit && (snp_cmd == CMD_RD)) ? 1 : 0;
            e_snp_flush  = (e_snp_lhit && (g_st[g_sidx] == ST_M) &&
                            (snp_cmd != CMD_UPGR)) ? 1 : 0;
            e_snp_data   = g_dat[g_sidx];

            // ---------- local lookup ----------
            g_cidx    = idxof(cpu_addr);
            g_ctag    = tagof(cpu_addr);
            e_cst     = g_st[g_cidx];
            e_hit     = ((e_cst != ST_I) && (g_tag[g_cidx] == g_ctag)) ? 1 : 0;
            e_blocked = (e_snp_lhit && (g_sidx == g_cidx)) ? 1 : 0;

            g_pidx = idxof(g_paddr);
            g_ptag = tagof(g_paddr);

            e_bus_req   = 0; e_bus_cmd   = CMD_RD;
            e_bus_addr  = 0; e_bus_wdata = 0;
            e_cpu_ready = 0; e_cpu_rdata = 0;
            e_upgr_kill = 0;

            case (g_fsm)
                F_IDLE: begin
                    if (cpu_req && !e_blocked && e_hit &&
                        !local_needs_bus(cpu_we, e_hit, e_cst)) begin
                        e_cpu_ready = 1;
                        e_cpu_rdata = cpu_we ? cpu_wdata : g_dat[g_cidx];
                    end
                end
                F_WB: begin
                    e_bus_req = 1; e_bus_cmd = CMD_WB;
                    e_bus_addr = g_wbaddr; e_bus_wdata = g_wbdata;
                end
                F_FILL: begin
                    e_bus_req  = 1;
                    e_bus_cmd  = g_pwe ? CMD_RDX : CMD_RD;
                    e_bus_addr = g_paddr;
                    if (bus_done) begin
                        e_cpu_ready = 1;
                        e_cpu_rdata = g_pwe ? g_pwdata : bus_rdata;
                    end
                end
                F_UPGR: begin
                    e_bus_req  = 1; e_bus_cmd = CMD_UPGR; e_bus_addr = g_paddr;
                    e_upgr_kill = (e_snp_lhit && (snp_cmd != CMD_RD) &&
                                   (g_sidx == g_pidx)) ? 1 : 0;
                    if (bus_done && !(g_lost || e_upgr_kill)) begin
                        e_cpu_ready = 1;
                        e_cpu_rdata = g_pwdata;
                    end
                end
            endcase
        end
    endtask

    task automatic golden_update;
        begin
            // ---- 1. the snoop port owns the arrays ----
            if (e_snp_lhit) g_st[g_sidx] = snoop_next_st(snp_cmd, g_st[g_sidx]);

            // ---- 2. the local access ----
            case (g_fsm)
                F_IDLE: begin
                    if (cpu_req && !e_blocked) begin
                        if (!local_needs_bus(cpu_we, e_hit, e_cst)) begin
                            if (cpu_we) begin           // store hit in E or M
                                if (e_cst == ST_E) n_silent_em = n_silent_em + 1;
                                g_dat[g_cidx] = cpu_wdata;
                                g_st [g_cidx] = ST_M;
                            end
                            // load hit: S / E / M all serve reads unchanged
                        end else if (e_hit) begin       // store hit in S
                            g_paddr  = cpu_addr; g_pwdata = cpu_wdata;
                            g_pwe    = 1;        g_lost   = 0;
                            g_fsm    = F_UPGR;
                        end else begin                  // miss
                            g_paddr  = cpu_addr; g_pwdata = cpu_wdata;
                            g_pwe    = cpu_we;
                            if (e_cst == ST_M) begin
                                g_wbaddr = addrof(g_tag[g_cidx], g_cidx);
                                g_wbdata = g_dat[g_cidx];
                                g_fsm    = F_WB;
                            end else begin
                                g_fsm    = F_FILL;
                            end
                            g_st[g_cidx] = ST_I;   // replacement drops the victim
                        end
                    end else if (cpu_req && e_blocked) begin
                        n_blocked = n_blocked + 1;
                    end
                end

                F_WB: if (bus_done) g_fsm = F_FILL;

                F_FILL: if (bus_done) begin
                    g_tag[g_pidx] = g_ptag;
                    g_dat[g_pidx] = g_pwe ? g_pwdata : bus_rdata;
                    g_st [g_pidx] = fill_next_st(g_pwe, bus_shared);
                    g_fsm         = F_IDLE;
                end

                F_UPGR: begin
                    if (bus_done) begin
                        if (g_lost || e_upgr_kill) begin
                            n_lost_upgr = n_lost_upgr + 1;
                            g_lost = 0;
                            g_fsm  = F_FILL;      // retried as BusRdX (g_pwe=1)
                        end else begin
                            g_dat[g_pidx] = g_pwdata;
                            g_st [g_pidx] = ST_M;
                            g_fsm         = F_IDLE;
                        end
                    end else if (e_upgr_kill) begin
                        g_lost = 1;
                    end
                end
            endcase
        end
    endtask

    // =========================================================================
    // Checking
    // =========================================================================
    task automatic chk(input string what, input integer got, input integer exp);
        begin
            checks = checks + 1;
            if (got !== exp) begin
                errors = errors + 1;
                if (errors < 40)
                    $display("  [FAIL] cyc=%0d %s got=%0d exp=%0d", cyc, what, got, exp);
            end
        end
    endtask

    task automatic chkh(input string what, input integer got, input integer exp);
        begin
            checks = checks + 1;
            if (got !== exp) begin
                errors = errors + 1;
                if (errors < 40)
                    $display("  [FAIL] cyc=%0d %s got=%08h exp=%08h", cyc, what, got, exp);
            end
        end
    endtask

    task automatic check_outputs;
        integer i, a;
        begin
            chk ("cpu_ready",  cpu_ready,  e_cpu_ready);
            chkh("cpu_rdata",  cpu_rdata,  e_cpu_rdata);
            chk ("bus_req",    bus_req,    e_bus_req);
            chk ("bus_cmd",    bus_cmd,    e_bus_req ? e_bus_cmd : bus_cmd);
            chk ("bus_addr",   e_bus_req ? bus_addr : 0, e_bus_req ? e_bus_addr : 0);
            chkh("bus_wdata",  bus_wdata,  e_bus_wdata);
            chk ("snp_hit",    snp_hit,    e_snp_lhit);
            chk ("snp_shared", snp_shared, e_snp_shared);
            chk ("snp_flush",  snp_flush,  e_snp_flush);
            chkh("snp_data",   snp_data,   e_snp_data);
            chk ("fsm",        dbg_fsm,    g_fsm);

            for (i = 0; i < LINES; i = i + 1) begin
                chk ("state",  dbg_state[2*i      +: 2],      g_st [i]);
                chkh("data",   dbg_data [DATA_W*i +: DATA_W], g_dat[i]);
                if (g_st[i] != ST_I)
                    chk("tag", dbg_tag[TAG_W*i +: TAG_W], g_tag[i]);
            end

            // ---- invariant B : a flush means dirty, and never on an upgrade ----
            if (snp_flush) begin
                chk("flush_implies_M", g_st[g_sidx], ST_M);
                chk("flush_not_upgr",  (snp_cmd != CMD_UPGR) ? 1 : 0, 1);
            end

            // ---- invariant A : single writer ----
            // Holding a line in E or M means we are the ONLY cache with a copy.
            for (i = 0; i < LINES; i = i + 1) begin
                if ((g_st[i] == ST_E) || (g_st[i] == ST_M)) begin
                    a = addrof(g_tag[i], i) >> 2;
                    if (a < NWORDS) chk("single_writer", rem_copy[a], 0);
                end
            end
        end
    endtask

    // =========================================================================
    // Bus environment : complete whatever transaction the cache is asking for.
    // Called at the negedge, when bus_req/bus_cmd/bus_addr are already settled
    // for this cycle.
    // =========================================================================
    task automatic bus_service;
        integer wa;
        begin
            bus_done   = 1'b0;
            bus_rdata  = '0;
            bus_shared = 1'b0;
            if (bus_req) begin
                if (bus_wait > 0) begin
                    bus_wait = bus_wait - 1;
                end else begin
                    bus_done = 1'b1;
                    wa       = bus_addr >> 2;
                    case (bus_cmd)
                        CMD_RD: begin
                            bus_rdata  = mem[wa][DATA_W-1:0];
                            bus_shared = rem_copy[wa][0];
                            if (rem_copy[wa]) n_take_s = n_take_s + 1;
                            else              n_take_e = n_take_e + 1;
                            n_fill_rd = n_fill_rd + 1;
                        end
                        CMD_RDX: begin
                            bus_rdata   = mem[wa][DATA_W-1:0];
                            rem_copy[wa] = 0;          // sharers invalidated
                            n_fill_rdx   = n_fill_rdx + 1;
                        end
                        CMD_UPGR: begin
                            rem_copy[wa] = 0;          // sharers invalidated
                            n_upgr       = n_upgr + 1;
                        end
                        CMD_WB: begin
                            mem[wa] = bus_wdata;       // DUT's write-back path
                            n_wb    = n_wb + 1;
                        end
                    endcase
                    bus_wait = bus_lat_cfg;
                end
            end else begin
                bus_wait = bus_lat_cfg;
            end
        end
    endtask

    // =========================================================================
    // Post-sample environment update : remote-core side effects + value checks.
    // Uses the GOLDEN expected-ready / expected-hit so a DUT bug cannot corrupt
    // the reference, but takes the DUT's flush data so the data path is really
    // exercised.
    // =========================================================================
    task automatic env_update;
        integer wa;
        begin
            // ---- the CPU access that completed this cycle ----
            if (cpu_req && e_cpu_ready) begin
                wa = cpu_addr >> 2;
                if (cpu_we) ref_mem[wa] = cpu_wdata;
                // invariant C (part 1): every load sees the architectural value
                else        chkh("load_value", cpu_rdata, ref_mem[wa]);
            end

            // ---- the remote transaction we injected this cycle ----
            if (snp_valid && (snp_cmd != CMD_WB)) begin
                wa = snp_addr >> 2;
                if (snp_flush) begin                  // we supplied dirty data
                    mem[wa] = snp_data;
                    n_flush = n_flush + 1;
                end
                if (snp_cmd == CMD_RD) begin
                    rem_copy[wa] = 1;                 // remote takes a shared copy
                end else begin
                    // remote takes ownership and immediately writes a new value,
                    // so memory (and the architectural reference) both move.
                    mem[wa]      = snp_newval;
                    ref_mem[wa]  = snp_newval;
                    rem_copy[wa] = 0;
                end
            end
        end
    endtask

    // =========================================================================
    // One cycle
    // =========================================================================
    task automatic step;
        begin
            #4;                       // settle: sample 1 ns before the rising edge
            golden_eval();
            check_outputs();
            if (trace_on)
                $display("  c%-2d cpu=%0d/%0d a=%03h rdy=%0d rd=%08h | fsm=%0s bus=%0d %0s a=%03h dn=%0d sh=%0d | snp=%0d %0s a=%03h hit=%0d fl=%0d | L0=%0s L1=%0s",
                         cyc, cpu_req, cpu_we, cpu_addr, cpu_ready, cpu_rdata,
                         fsm_name(dbg_fsm), bus_req, cmd_name(bus_cmd), bus_addr,
                         bus_done, bus_shared,
                         snp_valid, cmd_name(snp_cmd), snp_addr, snp_hit, snp_flush,
                         st_name(st0), st_name(st1));
            golden_update();
            env_update();
            cyc = cyc + 1;
            @(posedge clk);           // DUT state advances here
            @(negedge clk);           // ready for the next drive
        end
    endtask

    function automatic string st_name(input integer s);
        begin
            case (s)
                ST_I: st_name = "I";
                ST_S: st_name = "S";
                ST_E: st_name = "E";
                default: st_name = "M";
            endcase
        end
    endfunction

    function automatic string cmd_name(input integer c);
        begin
            case (c)
                CMD_RD:   cmd_name = "RD  ";
                CMD_RDX:  cmd_name = "RDX ";
                CMD_UPGR: cmd_name = "UPGR";
                default:  cmd_name = "WB  ";
            endcase
        end
    endfunction

    function automatic string fsm_name(input integer f);
        begin
            case (f)
                F_IDLE: fsm_name = "IDLE";
                F_WB:   fsm_name = "WB  ";
                F_FILL: fsm_name = "FILL";
                default:fsm_name = "UPGR";
            endcase
        end
    endfunction

    // =========================================================================
    // Stimulus helpers
    // =========================================================================
    task automatic idle_inputs;
        begin
            cpu_req = 1'b0; cpu_we = 1'b0; cpu_addr = '0; cpu_wdata = '0;
            snp_valid = 1'b0; snp_cmd = CMD_RD[1:0]; snp_addr = '0; snp_newval = '0;
            bus_done = 1'b0; bus_rdata = '0; bus_shared = 1'b0;
        end
    endtask

    // One fully-specified cycle (used by the directed phases).
    task automatic tick(input integer creq,  input integer cwe,
                        input integer caddr, input integer cwdat,
                        input integer sv,    input integer sc,
                        input integer saddr, input integer snew);
        begin
            bus_service();
            cpu_req    = creq[0];
            cpu_we     = cwe[0];
            cpu_addr   = caddr[ADDR_W-1:0];
            cpu_wdata  = cwdat[DATA_W-1:0];
            snp_valid  = sv[0];
            snp_cmd    = sc[1:0];
            snp_addr   = saddr[ADDR_W-1:0];
            snp_newval = snew[DATA_W-1:0];
            step();
        end
    endtask

    // ---- random helpers ----
    integer seed;

    function automatic integer rnd_pct(input integer pct);
        begin rnd_pct = (({$random(seed)} % 100) < pct) ? 1 : 0; end
    endfunction

    // A remote transaction to `wa` is only legal if the bus is not already
    // carrying a conflicting transaction for that line from THIS cache:
    //   * an outstanding fill  - our line is Invalid, so we could not answer and
    //     the requester would silently read around us;
    //   * an outstanding write-back - memory is momentarily stale;
    //   * a plain BusRd against an outstanding BusUpgr - our upgrade is about to
    //     invalidate the copy the reader would take.
    // A real snooping bus enforces exactly this with conflict-address blocking.
    // Invalidating snoops against an outstanding BusUpgr ARE legal - that is the
    // upgrade-lost race, and the protocol handles it.
    function automatic integer snoop_legal(input integer wa, input integer c);
        begin
            snoop_legal = 1;
            if (g_fsm == F_WB) begin
                if ((wa == (g_wbaddr >> 2)) || (wa == (g_paddr >> 2))) snoop_legal = 0;
            end else if (g_fsm == F_FILL) begin
                if (wa == (g_paddr >> 2)) snoop_legal = 0;
            end else if (g_fsm == F_UPGR) begin
                if ((wa == (g_paddr >> 2)) && (c == CMD_RD)) snoop_legal = 0;
            end
        end
    endfunction

    // =========================================================================
    // Main
    // =========================================================================
    integer k, i, wa, c, cpu_out, r_addr, r_we, r_wdat;

    initial begin
        $dumpfile("mesi_cache.vcd");
        $dumpvars(0, tb_mesi_cache);

        seed = 32'h0C0FFEE1;
        checks = 0; errors = 0; cyc = 0; trace_on = 1;
        n_fill_rd = 0; n_fill_rdx = 0; n_upgr = 0; n_wb = 0; n_flush = 0;
        n_silent_em = 0; n_take_e = 0; n_take_s = 0; n_lost_upgr = 0; n_blocked = 0;
        cpu_out = 0;

        // ---- memory + reference start identical and non-trivial ----
        for (i = 0; i < NWORDS; i = i + 1) begin
            mem[i]      = 32'hA0000000 + i * 32'h00010001;
            ref_mem[i]  = mem[i];
            rem_copy[i] = 0;
        end

        // ---- golden model reset image ----
        for (i = 0; i < LINES; i = i + 1) begin
            g_st[i] = ST_I; g_tag[i] = 0; g_dat[i] = 0;
        end
        g_fsm = F_IDLE; g_paddr = 0; g_pwdata = 0; g_pwe = 0; g_lost = 0;
        g_wbaddr = 0; g_wbdata = 0;
        bus_lat_cfg = 1; bus_wait = 1;

        idle_inputs();
        rst_n = 1'b0;
        repeat (3) @(negedge clk);
        rst_n = 1'b1;
        @(negedge clk);

        // Another core already holds a shared copy of word 4 (set 0, tag 1) -
        // that is what makes the Phase-1 fill at c14 land in S instead of E.
        rem_copy[4] = 1;

        $display("");
        $display("=====================================================================");
        $display(" Day30 : MESI Snooping Cache-Coherence Controller");
        $display("   ADDR_W=%0d DATA_W=%0d LINES=%0d  (IDX_W=%0d TAG_W=%0d, %0d words of memory)",
                 ADDR_W, DATA_W, LINES, IDX_W, TAG_W, NWORDS);
        $display("=====================================================================");
        $display("");
        $display("Phase 1 : directed MESI life-cycle (the 16-cycle waveform window)");
        $display("          A = 0x000 (set 0, tag 0)   B = 0x010 (set 0, tag 1)");
        $display("PHASE1_T0 = %0t", $time);

        // --------------------------------------------------------------------
        //  c0  idle
        //  c1  load A            -> miss, no sharer          -> BusRd
        //  c2  BusRd outstanding
        //  c3  BusRd done, bus_shared=0                      -> line 0 = E
        //  c4  store A           -> hit in E: SILENT E->M, ZERO bus traffic
        //  c5  idle
        //  c6  remote BusRd A    -> snp_hit+shared+FLUSH      -> M -> S
        //  c7  store A           -> hit in S                  -> BusUpgr
        //  c8  BusUpgr outstanding
        //  c9  BusUpgr done                                   -> S -> M
        //  c10 load B (same set) -> conflict miss, victim dirty -> BusWB
        //  c11 BusWB outstanding
        //  c12 BusWB done                                     -> BusRd B
        //  c13 BusRd outstanding
        //  c14 BusRd done, bus_shared=1                       -> line 0 = S
        //  c15 remote BusUpgr B  -> snp_hit, no flush (clean)  -> S -> I
        // --------------------------------------------------------------------
        tick(0,0,16'h000,0,             0,CMD_RD,  16'h000,0);           // c0
        tick(1,0,16'h000,0,             0,CMD_RD,  16'h000,0);           // c1
        tick(1,0,16'h000,0,             0,CMD_RD,  16'h000,0);           // c2
        tick(1,0,16'h000,0,             0,CMD_RD,  16'h000,0);           // c3
        tick(1,1,16'h000,32'hDEADBEEF,  0,CMD_RD,  16'h000,0);           // c4
        tick(0,0,16'h000,0,             0,CMD_RD,  16'h000,0);           // c5
        tick(0,0,16'h000,0,             1,CMD_RD,  16'h000,0);           // c6
        tick(1,1,16'h000,32'h11112222,  0,CMD_RD,  16'h000,0);           // c7
        tick(1,1,16'h000,32'h11112222,  0,CMD_RD,  16'h000,0);           // c8
        tick(1,1,16'h000,32'h11112222,  0,CMD_RD,  16'h000,0);           // c9
        tick(1,0,16'h010,0,             0,CMD_RD,  16'h000,0);           // c10
        tick(1,0,16'h010,0,             0,CMD_RD,  16'h000,0);           // c11
        tick(1,0,16'h010,0,             0,CMD_RD,  16'h000,0);           // c12
        tick(1,0,16'h010,0,             0,CMD_RD,  16'h000,0);           // c13
        tick(1,0,16'h010,0,             0,CMD_RD,  16'h000,0);           // c14
        tick(0,0,16'h000,0,             1,CMD_UPGR,16'h010,32'h5A5A0001);// c15
        idle_inputs();

        // --------------------------------------------------------------------
        // Phase 1b : the upgrade-lost race.
        //   Get word 8 (set 0, tag 2) into S, start a store (BusUpgr), then let
        //   the remote core steal the line with a BusRdX while our upgrade is
        //   still on the bus. The upgrade must be abandoned and retried as a
        //   BusRdX, so the store still ends up in M - with the remote's newer
        //   value having been fetched first.
        // --------------------------------------------------------------------
        $display("");
        $display("Phase 1b : upgrade-lost race (remote BusRdX steals an in-flight BusUpgr)");
        rem_copy[8] = 1;                       // remote holds a shared copy
        tick(1,0,16'h020,0, 0,CMD_RD,16'h000,0);   // load word 8 -> miss, BusRd
        tick(1,0,16'h020,0, 0,CMD_RD,16'h000,0);
        tick(1,0,16'h020,0, 0,CMD_RD,16'h000,0);   // fill, bus_shared=1 -> S
        tick(1,1,16'h020,32'h0BADF00D, 0,CMD_RD,16'h000,0);  // store -> BusUpgr
        // remote steals it mid-upgrade
        tick(1,1,16'h020,32'h0BADF00D, 1,CMD_RDX,16'h020,32'h77770001);
        tick(1,1,16'h020,32'h0BADF00D, 0,CMD_RD,16'h000,0);  // upgrade done -> void
        tick(1,1,16'h020,32'h0BADF00D, 0,CMD_RD,16'h000,0);  // retried BusRdX
        tick(1,1,16'h020,32'h0BADF00D, 0,CMD_RD,16'h000,0);
        tick(1,1,16'h020,32'h0BADF00D, 0,CMD_RD,16'h000,0);
        tick(1,1,16'h020,32'h0BADF00D, 0,CMD_RD,16'h000,0);
        idle_inputs();
        repeat (2) begin bus_service(); step(); end
        chk("upgrade_lost_seen", (n_lost_upgr > 0) ? 1 : 0, 1);

        // --------------------------------------------------------------------
        // Phase 2 : randomised traffic.
        //   Small address pool (16 words over 4 sets) so conflict misses, dirty
        //   evictions, sharing, upgrades and invalidations all happen densely.
        // --------------------------------------------------------------------
        $display("");
        $display("Phase 2 : 4000 randomised cycles (random loads/stores + remote");
        $display("          BusRd / BusRdX / BusUpgr snoops + random bus latency)");
        trace_on = 0;

        for (k = 0; k < 4000; k = k + 1) begin
            bus_lat_cfg = {$random(seed)} % 3;      // 0..2 wait cycles
            bus_service();

            // ---- CPU: hold the outstanding request, else maybe start one ----
            if (cpu_out == 0) begin
                if (rnd_pct(75)) begin
                    r_addr  = ({$random(seed)} % NWORDS) * 4;
                    r_we    = rnd_pct(45);
                    r_wdat  = $random(seed);
                    cpu_req = 1'b1; cpu_we = r_we[0];
                    cpu_addr = r_addr[ADDR_W-1:0]; cpu_wdata = r_wdat[DATA_W-1:0];
                    cpu_out = 1;
                end else begin
                    cpu_req = 1'b0; cpu_we = 1'b0;
                    cpu_addr = '0; cpu_wdata = '0;
                end
            end

            // ---- remote core: inject a legal snoop ----
            snp_valid = 1'b0; snp_cmd = CMD_RD[1:0];
            snp_addr = '0; snp_newval = '0;
            if (rnd_pct(35)) begin
                wa = {$random(seed)} % NWORDS;
                c  = {$random(seed)} % 3;                  // RD / RDX / UPGR
                if ((c == CMD_UPGR) && !rem_copy[wa]) c = CMD_RD;   // needs S
                if (!snoop_legal(wa, c) && (g_fsm == F_UPGR)) c = CMD_RDX;
                if (snoop_legal(wa, c)) begin
                    snp_valid  = 1'b1;
                    snp_cmd    = c[1:0];
                    snp_addr   = (wa * 4);
                    snp_newval = $random(seed);
                end
            end

            step();
            if (e_cpu_ready) cpu_out = 0;
        end
        idle_inputs();

        // let any outstanding access finish
        for (k = 0; k < 40; k = k + 1) begin
            bus_service();
            if (cpu_out == 0) begin cpu_req = 1'b0; cpu_we = 1'b0; end
            step();
            if (e_cpu_ready) cpu_out = 0;
        end
        idle_inputs();

        // --------------------------------------------------------------------
        // Phase 3 : drain every dirty line out of the cache with remote BusRd
        // snoops, then invariant C (part 2) - main memory must now match the
        // architectural reference word for word.
        // --------------------------------------------------------------------
        $display("");
        $display("Phase 3 : drain all dirty lines (remote BusRd sweep) and compare");
        $display("          main memory against the architectural reference");
        bus_lat_cfg = 0; bus_wait = 0;
        for (i = 0; i < NWORDS; i = i + 1) begin
            tick(0,0,16'h000,0, 1,CMD_RD, i*4, 0);
            tick(0,0,16'h000,0, 0,CMD_RD, 0,   0);
        end
        idle_inputs();
        repeat (2) begin bus_service(); step(); end

        for (i = 0; i < NWORDS; i = i + 1)
            chkh("memory_coherent", mem[i], ref_mem[i]);

        // no line may still be dirty after the sweep
        for (i = 0; i < LINES; i = i + 1)
            chk("no_dirty_left", (g_st[i] == ST_M) ? 1 : 0, 0);

        // --------------------------------------------------------------------
        $display("");
        $display("---------------------------------------------------------------------");
        $display("Bus traffic       : BusRd=%0d  BusRdX=%0d  BusUpgr=%0d  BusWB=%0d",
                 n_fill_rd, n_fill_rdx, n_upgr, n_wb);
        $display("Load fills        : took E=%0d (no sharer)   took S=%0d (sharer)",
                 n_take_e, n_take_s);
        $display("Silent E->M stores: %0d   (store hits that needed ZERO bus traffic)",
                 n_silent_em);
        $display("Dirty flushes     : %0d   Upgrades lost to a race: %0d",
                 n_flush, n_lost_upgr);
        $display("Snoop-blocked CPU : %0d cycles", n_blocked);
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
        #2000000;
        $display("RESULT: *** FAIL *** (timeout)");
        $finish;
    end

endmodule
