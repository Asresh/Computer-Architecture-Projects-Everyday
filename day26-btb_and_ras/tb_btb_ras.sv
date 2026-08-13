// ============================================================================
// Day 26 : self-checking testbench for the BTB + RAS fetch-target predictor
// ----------------------------------------------------------------------------
// An independent behavioural golden model (plain SystemVerilog arrays + a
// software RAS) is kept in lock-step with the DUT. Every cycle we:
//   1. check the combinational PREDICT outputs against the golden model
//      computed from the *pre-edge* state, then
//   2. apply the UPDATE to both DUT (at the clock edge) and golden model, then
//   3. check the whole RAS observable state after the edge.
//
// Stimulus = a directed scenario that walks every behaviour (cold miss,
// allocate, hit, call-push, return-predict-from-RAS, RAS-empty fallback,
// conditional-not-taken eviction, RAS overflow & underflow) followed by 4000
// randomised back-to-back ops over an aliasing address pool.
// ============================================================================
`timescale 1ns/1ps
module tb_btb_ras;
    localparam int XLEN      = 32;
    localparam int BTB_SETS  = 16;
    localparam int RAS_DEPTH = 8;
    localparam int IDXW      = $clog2(BTB_SETS);
    localparam int TAGW      = XLEN - IDXW - 2;

    localparam logic [1:0] T_COND = 2'b00;
    localparam logic [1:0] T_JUMP = 2'b01;
    localparam logic [1:0] T_CALL = 2'b10;
    localparam logic [1:0] T_RET  = 2'b11;

    // -------- DUT I/O --------
    logic              clk, rst_n;
    logic [XLEN-1:0]   p_pc;
    logic              p_hit, p_taken, p_ras_used;
    logic [1:0]        p_type;
    logic [XLEN-1:0]   p_target;
    logic              u_valid, u_taken;
    logic [1:0]        u_type;
    logic [XLEN-1:0]   u_pc, u_target;
    logic [$clog2(RAS_DEPTH+1)-1:0] ras_count;
    logic [XLEN-1:0]   ras_top_o;
    logic              ovf_sticky, unf_sticky;

    btb_ras #(.XLEN(XLEN), .BTB_SETS(BTB_SETS), .RAS_DEPTH(RAS_DEPTH)) dut (
        .clk(clk), .rst_n(rst_n),
        .p_pc(p_pc), .p_hit(p_hit), .p_taken(p_taken), .p_type(p_type),
        .p_target(p_target), .p_ras_used(p_ras_used),
        .u_valid(u_valid), .u_pc(u_pc), .u_taken(u_taken),
        .u_type(u_type), .u_target(u_target),
        .ras_count(ras_count), .ras_top_o(ras_top_o),
        .ovf_sticky(ovf_sticky), .unf_sticky(unf_sticky)
    );

    // -------- golden model state --------
    bit              g_valid  [BTB_SETS];
    logic [TAGW-1:0] g_tag    [BTB_SETS];
    logic [XLEN-1:0] g_target [BTB_SETS];
    logic [1:0]      g_type   [BTB_SETS];
    logic [XLEN-1:0] g_ras    [RAS_DEPTH];
    int              g_sp;
    bit              g_ovf, g_unf;

    integer checks = 0;
    integer errors = 0;

    // -------- clock --------
    initial clk = 1'b0;
    always #5 clk = ~clk;

    function automatic logic [IDXW-1:0] idx_of(input logic [XLEN-1:0] pc);
        return pc[IDXW+1 : 2];
    endfunction
    function automatic logic [TAGW-1:0] tag_of(input logic [XLEN-1:0] pc);
        return pc[XLEN-1 : IDXW+2];
    endfunction

    // ------------------------------------------------------------------
    // check the combinational predict outputs against the golden model
    // (uses current, pre-edge golden state)
    // ------------------------------------------------------------------
    task automatic check_predict(input logic [XLEN-1:0] pc);
        logic [IDXW-1:0] i = idx_of(pc);
        logic [TAGW-1:0] t = tag_of(pc);
        bit              e_hit, e_taken, e_ras_used;
        logic [1:0]      e_type;
        logic [XLEN-1:0] e_target;
        begin
            e_hit   = g_valid[i] && (g_tag[i] == t);
            e_taken = e_hit;
            e_type  = g_type[i];
            if (e_hit && (g_type[i] == T_RET) && (g_sp != 0)) begin
                e_target   = g_ras[g_sp-1];
                e_ras_used = 1'b1;
            end else begin
                e_target   = g_target[i];
                e_ras_used = 1'b0;
            end

            checks++;
            // type/target are only architecturally meaningful on a hit
            if (p_hit !== e_hit || p_taken !== e_taken ||
                p_ras_used !== e_ras_used ||
                (e_hit && (p_type !== e_type || p_target !== e_target))) begin
                errors++;
                $display("  PREDICT MISMATCH @%0t pc=%08h", $time, pc);
                $display("    DUT   hit=%b taken=%b type=%b target=%08h ras_used=%b",
                         p_hit, p_taken, p_type, p_target, p_ras_used);
                $display("    GOLD  hit=%b taken=%b type=%b target=%08h ras_used=%b",
                         e_hit, e_taken, e_type, e_target, e_ras_used);
            end
        end
    endtask

    // apply an update to the golden model (mirror of the RTL)
    task automatic gold_update(input logic uv, input logic [XLEN-1:0] upc,
                               input logic ut, input logic [1:0] uty,
                               input logic [XLEN-1:0] utgt);
        logic [IDXW-1:0] i = idx_of(upc);
        logic [TAGW-1:0] t = tag_of(upc);
        begin
            if (uv) begin
                if (ut) begin
                    g_valid[i]  = 1'b1;
                    g_tag[i]    = t;
                    g_target[i] = utgt;
                    g_type[i]   = uty;
                end else if (uty == T_COND && g_valid[i] && g_tag[i] == t) begin
                    g_valid[i]  = 1'b0;
                end
                if (uty == T_CALL) begin
                    if (g_sp < RAS_DEPTH) begin g_ras[g_sp] = upc + 32'd4; g_sp++; end
                    else                       g_ovf = 1'b1;
                end else if (uty == T_RET) begin
                    if (g_sp != 0) g_sp--;
                    else           g_unf = 1'b1;
                end
            end
        end
    endtask

    // check RAS observability after the edge
    task automatic check_ras();
        logic [XLEN-1:0] e_top = (g_sp != 0) ? g_ras[g_sp-1] : '0;
        begin
            checks++;
            if (ras_count !== g_sp[$clog2(RAS_DEPTH+1)-1:0] ||
                ras_top_o !== e_top ||
                ovf_sticky !== g_ovf || unf_sticky !== g_unf) begin
                errors++;
                $display("  RAS MISMATCH @%0t", $time);
                $display("    DUT  count=%0d top=%08h ovf=%b unf=%b",
                         ras_count, ras_top_o, ovf_sticky, unf_sticky);
                $display("    GOLD count=%0d top=%08h ovf=%b unf=%b",
                         g_sp, e_top, g_ovf, g_unf);
            end
        end
    endtask

    // one full cycle: drive predict + update, check predict (pre-edge),
    // advance clock, mirror update, check RAS (post-edge)
    task automatic step(input logic [XLEN-1:0] pc,
                        input logic uv, input logic [XLEN-1:0] upc,
                        input logic ut, input logic [1:0] uty,
                        input logic [XLEN-1:0] utgt);
        begin
            @(negedge clk);
            p_pc = pc; u_valid = uv; u_pc = upc; u_taken = ut;
            u_type = uty; u_target = utgt;
            #1 check_predict(pc);
            @(posedge clk);
            gold_update(uv, upc, ut, uty, utgt);
            #1 check_ras();
        end
    endtask

    // -------- test program --------
    integer k;
    logic [XLEN-1:0] pool [16];
    logic [XLEN-1:0] rpc, rupc, rtgt;
    logic [1:0]      rty;
    logic            rt;

    initial begin
        $dumpfile("btb_ras.vcd");
        $dumpvars(0, tb_btb_ras);

        // reset
        rst_n   = 1'b0;
        p_pc    = '0;
        u_valid = 1'b0; u_pc = '0; u_taken = 1'b0; u_type = T_COND; u_target = '0;
        repeat (3) @(posedge clk);
        @(negedge clk) rst_n = 1'b1;

        // ================= DIRECTED WINDOW (drawn in the waveform) =========
        // c0 : cold miss on 0x100, no update
        step(32'h0000_0100, 1'b0, 32'h0, 1'b0, T_COND, 32'h0);
        // c1 : still miss; allocate a taken JUMP at 0x100 -> 0x400
        step(32'h0000_0100, 1'b1, 32'h0000_0100, 1'b1, T_JUMP, 32'h0000_0400);
        // c2 : 0x100 now HITs (target 0x400); allocate taken COND 0x104 -> 0x200
        step(32'h0000_0100, 1'b1, 32'h0000_0104, 1'b1, T_COND, 32'h0000_0200);
        // c3 : 0x104 HIT; CALL 0x108 taken -> push link 0x10C, target 0x800
        step(32'h0000_0104, 1'b1, 32'h0000_0108, 1'b1, T_CALL, 32'h0000_0800);
        // c4 : 0x108 HIT (CALL); CALL 0x10C taken -> push link 0x110  (RAS=2)
        step(32'h0000_0108, 1'b1, 32'h0000_010C, 1'b1, T_CALL, 32'h0000_0900);
        // c5 : idle predict; allocate a RET at 0x120 (fallback target 0x555)
        step(32'h0000_0108, 1'b1, 32'h0000_0120, 1'b1, T_RET,  32'h0000_0555);
        // c6 : 0x120 HIT RET -> target from RAS top (0x110); RET resolve pops
        step(32'h0000_0120, 1'b1, 32'h0000_0120, 1'b1, T_RET,  32'h0000_0110);
        // c7 : 0x120 RET -> RAS top now 0x10C; RET resolve pops (RAS -> 0)
        step(32'h0000_0120, 1'b1, 32'h0000_0120, 1'b1, T_RET,  32'h0000_010C);
        // c8 : 0x120 RET but RAS empty -> fallback to stored target 0x555;
        //      conditional 0x104 resolves NOT-taken -> evict its entry
        step(32'h0000_0120, 1'b1, 32'h0000_0104, 1'b0, T_COND, 32'h0);
        // c9 : 0x104 now MISS (evicted); RET resolve while empty -> underflow
        step(32'h0000_0104, 1'b1, 32'h0000_0120, 1'b1, T_RET,  32'h0000_010C);
        // c10: 0x108 still HIT (CALL); no update -> underflow sticky stays high
        step(32'h0000_0108, 1'b0, 32'h0, 1'b0, T_COND, 32'h0);

        // ================= DIRECTED RAS OVERFLOW =========================
        // nine calls into a DEPTH-8 stack: the 9th must set the overflow flag
        // and NOT corrupt the deepest frames.
        for (k = 0; k < 9; k++)
            step(32'h0000_0200, 1'b1, 32'h0000_0300 + k*4, 1'b1, T_CALL,
                 32'h0000_0A00);
        // drain everything back out (8 valid pops, extra pops keep unf high)
        for (k = 0; k < 10; k++)
            step(32'h0000_0200, 1'b1, 32'h0000_0200, 1'b1, T_RET, 32'h0000_0B00);

        // ================= RANDOMISED BACK-TO-BACK OPS ===================
        // aliasing pool: several PCs collide in the same BTB set so entries
        // are continually allocated, evicted, and re-fetched.
        pool[0]=32'h0000_0100; pool[1]=32'h0000_0140; pool[2]=32'h0000_0180;
        pool[3]=32'h0000_01C0; pool[4]=32'h0000_0104; pool[5]=32'h0000_0204;
        pool[6]=32'h0000_0304; pool[7]=32'h0000_0108; pool[8]=32'h0000_0208;
        pool[9]=32'h0000_010C; pool[10]=32'h0000_0110; pool[11]=32'h0000_0114;
        pool[12]=32'h0000_0118; pool[13]=32'h0000_011C; pool[14]=32'h0000_0120;
        pool[15]=32'h0000_0124;

        for (k = 0; k < 4000; k++) begin
            rpc  = pool[$urandom_range(15)];
            rupc = pool[$urandom_range(15)];
            rt   = $urandom_range(1);
            rty  = $urandom_range(3);
            rtgt = {$urandom} & 32'hFFFF_FFFC;
            step(rpc, 1'b1, rupc, rt, rty, rtgt);
        end

        // ---- report ----
        $display("");
        $display("==================================================");
        $display("Day26 BTB+RAS : %0d checks, %0d errors", checks, errors);
        if (errors == 0)
            $display("RESULT: *** PASS ***");
        else
            $display("RESULT: *** FAIL ***  (%0d mismatches)", errors);
        $display("==================================================");
        $finish;
    end

    // global timeout
    initial begin
        #2_000_000;
        $display("RESULT: *** FAIL ***  (timeout)");
        $finish;
    end
endmodule
