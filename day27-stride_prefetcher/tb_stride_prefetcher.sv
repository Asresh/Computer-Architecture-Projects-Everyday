// ============================================================================
// tb_stride_prefetcher.sv  --  Day 27 self-checking testbench
//
// Lock-steps stride_prefetcher.sv against an INDEPENDENT behavioural golden
// RPT written from the same specification but with plain unpacked arrays and
// software control flow (no DUT internals are peeked). Every observed request
// checks the DUT's combinational outputs {pf_valid, pf_addr, dbg_hit,
// dbg_state, dbg_stride} against the golden model BEFORE the clock edge, then
// both advance.
//
//   Phase 1 : a directed scenario (drawn by render_waveform.py) exercising
//             allocate -> learn -> STEADY -> prefetch, per-PC independence,
//             a stride change (STEADY->INIT relock), a negative stride, and a
//             direct-mapped conflict eviction.
//   Phase 2 : 4000 randomised ops over an 8-PC pool mixing strided walks,
//             stride changes and random jumps (index aliasing forces
//             conflicts / evictions).
//
// Prints "RESULT: *** PASS ***" iff every assertion holds.
// ============================================================================

`timescale 1ns / 1ps

module tb_stride_prefetcher;

    // ---- parameters (mirror the DUT) ---------------------------------------
    localparam int PC_WIDTH   = 32;
    localparam int ADDR_WIDTH = 32;
    localparam int IDX_WIDTH  = 4;
    localparam int PC_ALIGN   = 2;
    localparam int LOOKAHEAD   = 1;
    localparam int SETS        = (1 << IDX_WIDTH);
    localparam int TAG_WIDTH   = PC_WIDTH - IDX_WIDTH - PC_ALIGN;

    localparam logic [1:0] S_INIT  = 2'd0;
    localparam logic [1:0] S_TRANS = 2'd1;
    localparam logic [1:0] S_STEADY= 2'd2;
    localparam logic [1:0] S_NOPRED= 2'd3;

    // ---- DUT I/O -----------------------------------------------------------
    logic                    clk, rst_n;
    logic                    req_valid;
    logic [PC_WIDTH-1:0]     req_pc;
    logic [ADDR_WIDTH-1:0]   req_addr;
    logic                    pf_valid;
    logic [ADDR_WIDTH-1:0]   pf_addr;
    logic                    dbg_hit;
    logic [1:0]              dbg_state;
    logic [ADDR_WIDTH-1:0]   dbg_stride;

    stride_prefetcher #(
        .PC_WIDTH(PC_WIDTH), .ADDR_WIDTH(ADDR_WIDTH), .IDX_WIDTH(IDX_WIDTH),
        .PC_ALIGN(PC_ALIGN), .LOOKAHEAD(LOOKAHEAD)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .req_valid(req_valid), .req_pc(req_pc), .req_addr(req_addr),
        .pf_valid(pf_valid), .pf_addr(pf_addr),
        .dbg_hit(dbg_hit), .dbg_state(dbg_state), .dbg_stride(dbg_stride)
    );

    // ---- clock -------------------------------------------------------------
    initial clk = 1'b0;
    always #5 clk = ~clk;

    // ---- independent golden RPT --------------------------------------------
    logic                  gv     [SETS];
    logic [TAG_WIDTH-1:0]  gtag   [SETS];
    logic [ADDR_WIDTH-1:0] glast  [SETS];
    logic [ADDR_WIDTH-1:0] gstride[SETS];
    logic [1:0]            gstate [SETS];

    integer errors;
    integer checks;

    function automatic logic [1:0] g_next(input logic [1:0] s, input logic m);
        case (s)
            S_INIT  : g_next = m ? S_STEADY : S_TRANS;
            S_TRANS : g_next = m ? S_STEADY : S_NOPRED;
            S_STEADY: g_next = m ? S_STEADY : S_INIT;
            S_NOPRED: g_next = m ? S_TRANS  : S_NOPRED;
            default : g_next = S_INIT;
        endcase
    endfunction

    task automatic g_reset;
        integer k;
        begin
            for (k = 0; k < SETS; k = k + 1) begin
                gv[k] = 1'b0; gtag[k] = '0; glast[k] = '0;
                gstride[k] = '0; gstate[k] = S_INIT;
            end
        end
    endtask

    // Drive one access, check DUT vs golden, then advance both.
    task automatic access(input logic [PC_WIDTH-1:0]   pc,
                          input logic [ADDR_WIDTH-1:0] addr);
        logic [IDX_WIDTH-1:0]  gi;
        logic [TAG_WIDTH-1:0]  gt;
        logic                  ghit, gmatch;
        logic [ADDR_WIDTH-1:0] gobs, exp_pf_addr;
        logic                  exp_pf_valid;
        logic [1:0]            exp_state;
        logic [ADDR_WIDTH-1:0] exp_stride;
        begin
            @(negedge clk);
            req_valid = 1'b1; req_pc = pc; req_addr = addr;
            #1;  // settle combinational DUT outputs

            gi   = pc[PC_ALIGN +: IDX_WIDTH];
            gt   = pc[PC_WIDTH-1 -: TAG_WIDTH];
            ghit = gv[gi] && (gtag[gi] == gt);
            gobs = addr - glast[gi];
            gmatch = ghit && (gobs == gstride[gi]);

            exp_pf_valid = ghit && (gstate[gi] == S_STEADY) && (gstride[gi] != '0);
            exp_pf_addr  = addr + (gstride[gi] * LOOKAHEAD);
            exp_state    = gstate[gi];
            exp_stride   = gstride[gi];

            // ---- checks (pre-edge, combinational outputs) ------------------
            checks = checks + 1;
            if (dbg_hit !== ghit) begin
                errors = errors + 1;
                $display("[%0t] HIT mismatch pc=%h addr=%h dut=%b exp=%b",
                         $time, pc, addr, dbg_hit, ghit);
            end
            if (dbg_state !== exp_state) begin
                errors = errors + 1;
                $display("[%0t] STATE mismatch pc=%h dut=%0d exp=%0d",
                         $time, pc, dbg_state, exp_state);
            end
            if (dbg_stride !== exp_stride) begin
                errors = errors + 1;
                $display("[%0t] STRIDE mismatch pc=%h dut=%h exp=%h",
                         $time, pc, dbg_stride, exp_stride);
            end
            if (pf_valid !== exp_pf_valid) begin
                errors = errors + 1;
                $display("[%0t] PF_VALID mismatch pc=%h addr=%h dut=%b exp=%b",
                         $time, pc, addr, pf_valid, exp_pf_valid);
            end
            if (exp_pf_valid && (pf_addr !== exp_pf_addr)) begin
                errors = errors + 1;
                $display("[%0t] PF_ADDR mismatch pc=%h dut=%h exp=%h",
                         $time, pc, pf_addr, exp_pf_addr);
            end

            // ---- advance golden to match the DUT's posedge update ----------
            if (!ghit) begin
                gv[gi] = 1'b1; gtag[gi] = gt; glast[gi] = addr;
                gstride[gi] = '0; gstate[gi] = S_INIT;
            end else begin
                glast[gi]  = addr;
                gstate[gi] = g_next(gstate[gi], gmatch);
                if (!gmatch) gstride[gi] = gobs;
            end

            @(posedge clk);       // DUT registers update here
            #1 req_valid = 1'b0;  // deassert until next access
        end
    endtask

    // ---- directed scenario PCs ---------------------------------------------
    localparam logic [PC_WIDTH-1:0] PC_A = 32'h0000_0100; // idx 0
    localparam logic [PC_WIDTH-1:0] PC_B = 32'h0000_0110; // idx 4 (independent)
    localparam logic [PC_WIDTH-1:0] PC_C = 32'h0001_0100; // idx 0, other tag -> conflict

    // ---- random pool -------------------------------------------------------
    localparam int NPOOL = 8;
    logic [PC_WIDTH-1:0]   pool_pc     [NPOOL];
    logic [ADDR_WIDTH-1:0] pool_walk   [NPOOL];
    logic [ADDR_WIDTH-1:0] pool_stride [NPOOL];

    integer seed;
    integer r, sel;
    logic [ADDR_WIDTH-1:0] a;

    initial begin
        $dumpfile("stride_prefetcher.vcd");
        $dumpvars(0, tb_stride_prefetcher);

        errors = 0; checks = 0; seed = 32'hC0FFEE27;
        req_valid = 1'b0; req_pc = '0; req_addr = '0;
        g_reset();

        // ---- reset ---------------------------------------------------------
        rst_n = 1'b0;
        repeat (3) @(posedge clk);
        #1 rst_n = 1'b1;
        @(negedge clk);

        // ================= PHASE 1 : directed scenario ======================
        $display("---- Phase 1: directed scenario ----");
        access(PC_A, 32'h0000_1000); // alloc INIT
        access(PC_A, 32'h0000_1040); // learn stride 0x40 -> TRANSIENT
        access(PC_A, 32'h0000_1080); // confirm -> STEADY
        access(PC_A, 32'h0000_10C0); // STEADY hit -> PF 0x1100
        access(PC_A, 32'h0000_1100); // STEADY -> PF 0x1140
        access(PC_B, 32'h0000_8000); // B alloc INIT (independent of A)
        access(PC_A, 32'h0000_1140); // A still STEADY -> PF 0x1180
        access(PC_A, 32'h0000_1200); // stride jumps 0xC0 -> STEADY->INIT relearn
        access(PC_A, 32'h0000_12C0); // obs 0xC0 == new stride -> INIT->STEADY
        access(PC_A, 32'h0000_1380); // STEADY on new stride -> PF 0x1440
        access(PC_B, 32'h0000_7F00); // B negative stride -0x100 -> TRANSIENT
        access(PC_C, 32'h0000_9000); // conflict: evicts A@idx0 (alloc INIT)
        access(PC_A, 32'h0000_1400); // A now misses (evicted) -> re-alloc INIT

        // ================= PHASE 2 : randomised =============================
        $display("---- Phase 2: 4000 randomised ops ----");
        for (r = 0; r < NPOOL; r = r + 1) begin
            pool_pc[r]     = {$random(seed)} & 32'h0000_FFFF; // small PC span -> aliasing
            pool_walk[r]   = {$random(seed)};
            pool_stride[r] = ({$random(seed)} & 32'h0000_00FF) + 32'd1; // 1..256
        end

        for (r = 0; r < 4000; r = r + 1) begin
            sel = {$random(seed)} % NPOOL;
            case ({$random(seed)} % 100)
                // 60%: continue the strided walk (drives INIT->STEADY)
                0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,
                20,21,22,23,24,25,26,27,28,29,30,31,32,33,34,35,36,37,38,39,
                40,41,42,43,44,45,46,47,48,49,50,51,52,53,54,55,56,57,58,59: begin
                    pool_walk[sel] = pool_walk[sel] + pool_stride[sel];
                    a = pool_walk[sel];
                end
                // 15%: change stride then step (STEADY->INIT relock)
                60,61,62,63,64,65,66,67,68,69,70,71,72,73,74: begin
                    pool_stride[sel] = ({$random(seed)} & 32'h0000_03FF) + 32'd1;
                    pool_walk[sel]   = pool_walk[sel] + pool_stride[sel];
                    a = pool_walk[sel];
                end
                // 25%: random jump (irregular access)
                default: begin
                    a = {$random(seed)};
                    pool_walk[sel] = a;
                end
            endcase
            access(pool_pc[sel], a);
        end

        // ---- verdict -------------------------------------------------------
        @(posedge clk);
        $display("Checks run : %0d", checks);
        $display("Errors     : %0d", errors);
        if (errors == 0)
            $display("RESULT: *** PASS ***");
        else
            $display("RESULT: *** FAIL *** (%0d errors)", errors);
        $finish;
    end

    // ---- global timeout ----------------------------------------------------
    initial begin
        #500000;
        $display("RESULT: *** FAIL *** (timeout)");
        $finish;
    end

endmodule
