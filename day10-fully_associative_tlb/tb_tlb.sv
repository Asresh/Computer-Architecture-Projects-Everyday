// tb_tlb.sv - Day10
// Self-checking testbench for the fully-associative, true-LRU TLB.
`timescale 1ns/1ps
//
// An INDEPENDENT behavioural reference model re-implements the TLB spec from
// scratch (its own valid/tag/ppn arrays and its own NxN reference-matrix true
// LRU) and predicts every observable output each cycle: hit, miss, resp_ppn,
// hit_way, and fill_way (the victim/target the fill logic would pick). Because
// the victim choice (fill_way) is exposed and checked every cycle, the LRU
// replacement policy is fully verified, not just the lookups.
//
// The model reads ONLY the DUT's declared ports -- never its internal state --
// so it is a genuine golden model, not a mirror of the RTL's private signals.
//
// Timing contract: lookup is combinational; fills/invalidations/flush take
// effect at the clock edge. Inputs are driven just after each negedge and held
// through the following posedge, so both the DUT and the model observe the same
// inputs against the same (post-previous-edge) state.
//
// Stimulus: a directed sequence (reset, fills, hits, fill-to-full, a true-LRU
// eviction with a follow-up miss on the evicted page, single-page invalidate +
// refill into the freed slot, and a full flush) followed by many randomized
// operations from a deterministic xorshift32 stream over a small VPN pool (to
// force conflicts/evictions) plus occasional wide-range VPNs. A global timeout
// guards against a hang. Only if every check passes is "*** PASS ***" printed.

module tb_tlb;

    // Match the DUT parameters.
    localparam int VPN_W   = 20;
    localparam int PPN_W   = 22;
    localparam int ENT     = 4;
    localparam int IDXW    = (ENT > 1) ? $clog2(ENT) : 1;

    // DUT ports
    logic             clk, rst_n;
    logic             req_valid;
    logic [VPN_W-1:0] req_vpn;
    logic             hit, miss;
    logic [PPN_W-1:0] resp_ppn;
    logic [IDXW-1:0]  hit_way;
    logic             fill_valid;
    logic [VPN_W-1:0] fill_vpn;
    logic [PPN_W-1:0] fill_ppn;
    logic [IDXW-1:0]  fill_way;
    logic             inv_valid;
    logic [VPN_W-1:0] inv_vpn;
    logic             flush_all;

    tlb #(.VPN_W(VPN_W), .PPN_W(PPN_W), .ENTRIES(ENT)) dut (
        .clk       (clk),
        .rst_n     (rst_n),
        .req_valid (req_valid),
        .req_vpn   (req_vpn),
        .hit       (hit),
        .miss      (miss),
        .resp_ppn  (resp_ppn),
        .hit_way   (hit_way),
        .fill_valid(fill_valid),
        .fill_vpn  (fill_vpn),
        .fill_ppn  (fill_ppn),
        .fill_way  (fill_way),
        .inv_valid (inv_valid),
        .inv_vpn   (inv_vpn),
        .flush_all (flush_all)
    );

    // ---- Clock ----
    initial clk = 1'b0;
    always #5 clk = ~clk;   // 10 ns period

    // ---- Independent reference model state ----
    logic             r_valid [ENT];
    logic [VPN_W-1:0] r_tag   [ENT];
    logic [PPN_W-1:0] r_ppn   [ENT];
    logic [ENT-1:0]   r_use   [ENT];

    // Predicted (expected) outputs and cached selection results.
    logic             e_hit, e_miss, e_hitR;
    logic [PPN_W-1:0] e_ppn;
    logic [IDXW-1:0]  e_hit_way;
    logic [IDXW-1:0]  e_fill_way, e_target;

    integer checks;
    integer errors;

    // ---- Reference: predict combinational outputs from current inputs ----
    task automatic ref_predict();
        logic             dup, hinv, flru;
        logic [IDXW-1:0]  dup_w, inv_w, lru_w;
        logic [ENT-1:0]   rown;
        e_hitR = 1'b0;  e_hit_way = '0;  e_ppn = '0;
        for (int i = 0; i < ENT; i++)
            if (r_valid[i] && (r_tag[i] == req_vpn) && !e_hitR) begin
                e_hitR    = 1'b1;
                e_hit_way = i[IDXW-1:0];
                e_ppn     = r_ppn[i];
            end
        e_hit  = req_valid & e_hitR;
        e_miss = req_valid & ~e_hitR;

        dup = 1'b0; dup_w = '0;
        for (int i = 0; i < ENT; i++)
            if (r_valid[i] && (r_tag[i] == fill_vpn) && !dup) begin
                dup = 1'b1; dup_w = i[IDXW-1:0];
            end
        hinv = 1'b0; inv_w = '0;
        for (int i = 0; i < ENT; i++)
            if (!r_valid[i] && !hinv) begin
                hinv = 1'b1; inv_w = i[IDXW-1:0];
            end
        flru = 1'b0; lru_w = '0;
        for (int i = 0; i < ENT; i++) begin
            rown    = r_use[i];
            rown[i] = 1'b0;
            if ((rown == '0) && !flru) begin
                flru = 1'b1; lru_w = i[IDXW-1:0];
            end
        end
        e_target   = dup ? dup_w : (hinv ? inv_w : lru_w);
        e_fill_way = e_target;
    endtask

    // ---- Reference: advance model state (mirrors the RTL edge behaviour) ----
    task automatic ref_apply();
        logic            t_en;
        logic [IDXW-1:0] t_way;
        if (flush_all) begin
            for (int i = 0; i < ENT; i++) begin
                r_valid[i] = 1'b0;
                r_use[i]   = '0;
            end
        end else begin
            if (inv_valid)
                for (int i = 0; i < ENT; i++)
                    if (r_valid[i] && (r_tag[i] == inv_vpn))
                        r_valid[i] = 1'b0;
            if (fill_valid) begin
                r_valid[e_target] = 1'b1;
                r_tag  [e_target] = fill_vpn;
                r_ppn  [e_target] = fill_ppn;
            end
            t_en  = fill_valid | (req_valid & e_hitR);
            t_way = fill_valid ? e_target : e_hit_way;
            if (t_en)
                for (int i = 0; i < ENT; i++)
                    for (int j = 0; j < ENT; j++) begin
                        if (i == int'(t_way))      r_use[i][j] = 1'b1;
                        else if (j == int'(t_way)) r_use[i][j] = 1'b0;
                    end
        end
    endtask

    // ---- Compare one output ----
    task automatic chk(input string nm, input integer got, input integer exp,
                       input string lbl);
        checks = checks + 1;
        if (got !== exp) begin
            errors = errors + 1;
            if (errors <= 20)
                $display("  MISMATCH [%0s] %0s: got=%0d exp=%0d  (time %0t)",
                         lbl, nm, got, exp, $time);
        end
    endtask

    // ---- Drive one cycle: set inputs, check outputs, advance state ----
    task automatic step(input logic rv, input logic [VPN_W-1:0] rvpn,
                        input logic fv, input logic [VPN_W-1:0] fvpn,
                        input logic [PPN_W-1:0] fppn,
                        input logic iv, input logic [VPN_W-1:0] ivpn,
                        input logic fl, input string lbl);
        @(negedge clk);
        req_valid  = rv;   req_vpn  = rvpn;
        fill_valid = fv;   fill_vpn = fvpn;  fill_ppn = fppn;
        inv_valid  = iv;   inv_vpn  = ivpn;
        flush_all  = fl;
        #1;                        // let combinational logic settle
        ref_predict();
        chk("hit",      hit,      e_hit,          lbl);
        chk("miss",     miss,     e_miss,         lbl);
        chk("resp_ppn", resp_ppn, e_hit ? e_ppn : '0, lbl);
        chk("fill_way", fill_way, e_fill_way,     lbl);
        if (e_hit) chk("hit_way", hit_way, e_hit_way, lbl);
        // structural invariants (do not use the reference model)
        chk("h/m-excl", (hit & miss),      1'b0,      lbl);
        chk("h|m==rv",  (hit | miss),      req_valid, lbl);
        @(posedge clk);            // DUT commits; mirror it in the model
        ref_apply();
    endtask

    // ---- Deterministic PRNG (xorshift32) ----
    logic [31:0] rng;
    function automatic logic [31:0] xs32();
        rng = rng ^ (rng << 13);
        rng = rng ^ (rng >> 17);
        rng = rng ^ (rng << 5);
        return rng;
    endfunction

    // Convenience wrappers (VPN pool kept small so conflicts/evictions occur).
    localparam logic [VPN_W-1:0] A = 20'h00010, B = 20'h00020,
                                 C = 20'h00030, D = 20'h00040, E = 20'h00050;

    task automatic look (input logic [VPN_W-1:0] v, input string l);
        step(1'b1, v, 1'b0, '0, '0, 1'b0, '0, 1'b0, l);
    endtask
    task automatic fill (input logic [VPN_W-1:0] v, input logic [PPN_W-1:0] p,
                         input string l);
        step(1'b0, '0, 1'b1, v, p, 1'b0, '0, 1'b0, l);
    endtask
    task automatic invd (input logic [VPN_W-1:0] v, input string l);
        step(1'b0, '0, 1'b0, '0, '0, 1'b1, v, 1'b0, l);
    endtask
    task automatic flush(input string l);
        step(1'b0, '0, 1'b0, '0, '0, 1'b0, '0, 1'b1, l);
    endtask

    integer k;
    logic [VPN_W-1:0] rvpn;
    logic [VPN_W-1:0] pool [8];
    logic [31:0] t0, t1, t2;   // scratch for random draws (can't slice a call)
    logic [2:0]  op;

    initial begin
        $dumpfile("tlb.vcd");
        $dumpvars(0, tb_tlb);

        // init
        checks = 0;  errors = 0;  rng = 32'hC0FFEE42;
        req_valid = 0; req_vpn = 0;
        fill_valid = 0; fill_vpn = 0; fill_ppn = 0;
        inv_valid = 0; inv_vpn = 0; flush_all = 0;
        for (int i = 0; i < ENT; i++) begin
            r_valid[i] = 1'b0;  r_tag[i] = '0;  r_ppn[i] = '0;  r_use[i] = '0;
        end

        // reset
        rst_n = 1'b0;
        repeat (2) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;

        // ------------------- directed sequence (waveform window) ----------
        look (A, "miss-A-empty");      // 1: cold miss, TLB empty
        fill (A, 22'h100, "fill-A");   // 2: install A -> way0
        look (A, "hit-A");             // 3: hit, PPN=0x100, promote A
        fill (B, 22'h200, "fill-B");   // 4: install B -> way1
        fill (C, 22'h300, "fill-C");   // 5: install C -> way2
        fill (D, 22'h400, "fill-D");   // 6: install D -> way3 (TLB now full)
        look (B, "hit-B");             // 7: hit; recency MRU..LRU = B,D,C,A
        look (A, "hit-A2");            // 8: hit; recency = A,B,D,C -> LRU=C
        fill (E, 22'h500, "fill-E");   // 9: full -> evict LRU (C, way2)
        look (C, "miss-C-evicted");    // 10: C was evicted -> MISS
        look (E, "hit-E");             // 11: hit, PPN=0x500
        invd (B, "inv-B");             // 12: invalidate B (way1)
        look (B, "miss-B-inv");        // 13: B invalidated -> MISS, free=way1
        fill (B, 22'h2FF, "refill-B"); // 14: B remapped into freed way1
        flush("flush-all");            // 15: full flush
        look (A, "miss-A-flushed");    // 16: everything gone -> MISS

        // ------------------- randomized stress -----------------------------
        pool[0]=A; pool[1]=B; pool[2]=C; pool[3]=D;
        pool[4]=E; pool[5]=20'h00060; pool[6]=20'h00070; pool[7]=20'h00080;

        for (k = 0; k < 600; k++) begin
            t0 = xs32();
            op = t0[2:0] % 3'd7;            // bias toward lookups & fills
            if      (op <= 3'd3) begin      // lookup (over the small pool)
                t1 = xs32();
                look(pool[t1 % 8], "rand-look");
            end
            else if (op <= 3'd5) begin      // fill from the pool
                t1 = xs32();  t2 = xs32();
                fill(pool[t1 % 8], t2[PPN_W-1:0], "rand-fill");
            end
            else begin                      // occasional invalidate / flush
                t1 = xs32();
                if (t1[0]) begin
                    if (t1[1]) flush("rand-flush");
                    else begin
                        t2 = xs32();
                        invd(pool[t2 % 8], "rand-inv");
                    end
                end
                else begin                  // wide-range fill (unique pages)
                    t1 = xs32();  t2 = xs32();
                    fill(t1[VPN_W-1:0], t2[PPN_W-1:0], "rand-fill-wide");
                end
            end
        end

        // ------------------- verdict ---------------------------------------
        if (errors == 0)
            $display("RESULT: *** PASS *** (%0d checks, 0 mismatches)", checks);
        else
            $display("RESULT: *** FAIL *** (%0d checks, %0d mismatches)",
                     checks, errors);
        $finish;
    end

    // ---- Global timeout ----
    initial begin
        #200000;
        $display("RESULT: *** FAIL *** (TIMEOUT)");
        $finish;
    end

endmodule
