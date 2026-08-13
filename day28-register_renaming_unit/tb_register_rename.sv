// -----------------------------------------------------------------------------
// Day28 - Self-checking testbench for the Explicit Register Renaming Unit.
// -----------------------------------------------------------------------------
// Lock-steps register_rename against an INDEPENDENT behavioural golden model
// (a mirror RAT + a mirror circular free-list FIFO) held entirely in the
// testbench. Every cycle it:
//   1. drives one dispatch request (+ optional commit/free),
//   2. samples the DUT's combinational outputs at the settled pre-edge instant,
//   3. compares them against the golden model computed from mirror state,
//   4. advances both DUT (rising edge) and golden model identically.
//
// The DUT instance is intentionally COMPACT (NARCH=8, NPHYS=12 -> only 4 free
// physicals) so the directed Phase-1 scenario can exercise the whole life-cycle
// -- allocate, WAW/RAW-through-rename, x0-no-alloc, drain-to-empty, stall,
// physical-register recycle, and a simultaneous alloc+free -- inside a short,
// renderable window. The module itself is parameterised (a realistic core uses
// NARCH=32, NPHYS>=64); Phase 2 pounds it with 5000 randomised ops.
//
//   RESULT: *** PASS ***   is printed only if every assertion held.
// -----------------------------------------------------------------------------

`timescale 1ns / 1ps

module tb_register_rename;

    // ---- Compact demo configuration ----
    localparam int NARCH = 8;
    localparam int NPHYS = 12;
    localparam int ALOG  = $clog2(NARCH);   // 3
    localparam int PLOG  = $clog2(NPHYS);   // 4
    localparam int FREE_INIT = NPHYS - NARCH;

    // ---- DUT I/O ----
    logic             clk, rst_n;
    logic             rename_valid, has_rd;
    logic [ALOG-1:0]  rs1, rs2, rd;
    logic [PLOG-1:0]  psrc1, psrc2, pdst, pold;
    logic             alloc, stall;
    logic             free_valid;
    logic [PLOG-1:0]  free_preg;
    logic [PLOG:0]    dbg_free_count;

    register_rename #(.NARCH(NARCH), .NPHYS(NPHYS)) dut (
        .clk(clk), .rst_n(rst_n),
        .rename_valid(rename_valid), .rs1(rs1), .rs2(rs2), .rd(rd),
        .has_rd(has_rd),
        .psrc1(psrc1), .psrc2(psrc2), .pdst(pdst), .pold(pold),
        .alloc(alloc), .stall(stall),
        .free_valid(free_valid), .free_preg(free_preg),
        .dbg_free_count(dbg_free_count)
    );

    // ---- Clock : 10 ns period ----
    initial clk = 1'b0;
    always #5 clk = ~clk;

    // -------------------------------------------------------------------------
    // Independent golden model
    // -------------------------------------------------------------------------
    integer g_rat      [0:NARCH-1];
    integer g_freelist [0:NPHYS-1];
    integer g_head, g_tail, g_count;

    // Outstanding "old" physicals that an alloc has displaced and that may be
    // returned to the pool through the commit port (keeps the free count
    // bounded and every freed register physically meaningful).
    integer outstanding [0:NPHYS-1];
    integer out_cnt;

    integer checks;
    integer errors;

    task automatic golden_reset;
        integer i;
        begin
            for (i = 0; i < NARCH; i = i + 1) g_rat[i] = i;
            for (i = 0; i < NPHYS; i = i + 1)
                g_freelist[i] = (i < FREE_INIT) ? (NARCH + i) : 0;
            g_head  = 0;
            g_tail  = FREE_INIT;
            g_count = FREE_INIT;
            out_cnt = 0;
            checks  = 0;
            errors  = 0;
        end
    endtask

    // Compare one DUT output against expected; record mismatch.
    task automatic chk(input string name, input integer got, input integer exp);
        begin
            checks = checks + 1;
            if (got !== exp) begin
                errors = errors + 1;
                $display("  [MISMATCH] %-10s got=%0d exp=%0d  (t=%0t)",
                         name, got, exp, $time);
            end
        end
    endtask

    // -------------------------------------------------------------------------
    // Drive + check one cycle. Inputs are applied just after the negative edge;
    // the compare happens 1 ns before the rising edge (settled combinational
    // values), then both the DUT and the mirror advance on the rising edge.
    // -------------------------------------------------------------------------
    task automatic step(input logic v, input integer i_rs1, input integer i_rs2,
                        input integer i_rd, input logic i_has_rd,
                        input logic i_fv, input integer i_fp);
        // expected values
        integer e_need, e_alloc, e_stall;
        integer e_psrc1, e_psrc2, e_pold, e_pdst;
        begin
            @(negedge clk);
            rename_valid = v;
            rs1 = i_rs1[ALOG-1:0]; rs2 = i_rs2[ALOG-1:0]; rd = i_rd[ALOG-1:0];
            has_rd = i_has_rd;
            free_valid = i_fv; free_preg = i_fp[PLOG-1:0];

            // ---- golden combinational prediction (from mirror state) ----
            e_need  = v & i_has_rd & (i_rd != 0);
            e_alloc = e_need & (g_count != 0);
            e_stall = e_need & (g_count == 0);
            e_psrc1 = g_rat[i_rs1];
            e_psrc2 = g_rat[i_rs2];
            e_pold  = g_rat[i_rd];
            e_pdst  = g_freelist[g_head];

            #4;  // settle, sample 1 ns before the rising edge
            chk("psrc1", psrc1, e_psrc1);
            chk("psrc2", psrc2, e_psrc2);
            chk("pold",  pold,  e_pold);
            chk("pdst",  pdst,  e_pdst);
            chk("alloc", alloc, e_alloc);
            chk("stall", stall, e_stall);
            chk("count", dbg_free_count, g_count);

            @(posedge clk);   // DUT updates here

            // ---- advance the mirror identically ----
            if (e_alloc) begin
                // pop pdst
                g_head = (g_head + 1) % NPHYS;
                // record displaced old mapping as freeable
                outstanding[out_cnt] = g_rat[i_rd];
                out_cnt = out_cnt + 1;
                // install new mapping
                g_rat[i_rd] = e_pdst;
            end
            if (i_fv) begin
                g_freelist[g_tail] = i_fp;
                g_tail = (g_tail + 1) % NPHYS;
            end
            // net free-count change
            if (i_fv && !e_alloc) g_count = g_count + 1;
            else if (!i_fv && e_alloc) g_count = g_count - 1;
            // (both or neither -> unchanged)
        end
    endtask

    // -------------------------------------------------------------------------
    // Stimulus
    // -------------------------------------------------------------------------
    integer k, op, take_free;
    integer fp;

    initial begin
        $dumpfile("register_rename.vcd");
        $dumpvars(0, tb_register_rename);

        // ---- reset ----
        rename_valid = 0; has_rd = 0; rs1 = 0; rs2 = 0; rd = 0;
        free_valid = 0; free_preg = 0;
        rst_n = 0;
        golden_reset();
        repeat (3) @(posedge clk);
        @(negedge clk); rst_n = 1;

        // =====================================================================
        // Phase 1 : directed life-cycle scenario (this is what the waveform
        // renders). Free physicals at reset are {8,9,10,11}.
        // =====================================================================
        // c0  : x1 = x2 + x3            -> alloc p8,  old(x1)=1
        step(1, 2, 3, 1, 1,  0, 0);
        // c1  : x1 = x1 + x4  (WAW+RAW) -> alloc p9,  old(x1)=8
        step(1, 1, 4, 1, 1,  0, 0);
        // c2  : x5 = x1 + x2            -> alloc p10, old(x5)=5
        step(1, 1, 2, 5, 1,  0, 0);
        // c3  : x0 = x1 + x1  (x0 write)-> NO alloc (rd==0)
        step(1, 1, 1, 0, 1,  0, 0);
        // c4  : x6 = x5 + x3            -> alloc p11 (last free), pool -> empty
        step(1, 5, 3, 6, 1,  0, 0);
        // c5  : x7 = x6 + x2            -> STALL (free list empty)
        step(1, 6, 2, 7, 1,  0, 0);
        // c6  : commit frees physical 1 (no rename)
        step(0, 0, 0, 0, 0,  1, 1);
        // c7  : commit frees physical 10 (no rename)
        step(0, 0, 0, 0, 0,  1, 10);
        // c8  : x7 = x6 + x2  AND free 11  (simultaneous alloc+free) -> pdst p1
        step(1, 6, 2, 7, 1,  1, 11);
        // c9  : x7 = x7 + x1  (RAW on new x7) -> alloc p10 (recycled)
        step(1, 7, 1, 7, 1,  0, 0);
        // c10 : x3 = x2 + x4            -> alloc p11
        step(1, 2, 4, 3, 1,  0, 0);
        // c11 : x4 = x3 + x2            -> STALL again (empty)
        step(1, 3, 2, 4, 1,  0, 0);
        // c12 : commit frees physical 9 (no rename)
        step(0, 0, 0, 0, 0,  1, 9);

        $display("Phase 1 (directed life-cycle) done: %0d checks, %0d errors",
                 checks, errors);

        // =====================================================================
        // Phase 2 : randomised lock-step (5000 ops).
        //   - random rename requests (random rs1/rs2/rd/has_rd/valid)
        //   - random commits that free a genuinely-outstanding physical
        // Track only physicals displaced from here on, so every recycled
        // register is a real (still-unfreed) old mapping -- no duplicate frees.
        // =====================================================================
        out_cnt = 0;
        for (k = 0; k < 5000; k = k + 1) begin
            op        = $random;
            take_free = ($random % 3 == 0) && (out_cnt > 0);
            fp = 0;
            if (take_free) begin
                // pop one outstanding physical (LIFO) to recycle
                out_cnt = out_cnt - 1;
                fp = outstanding[out_cnt];
            end
            step( (op[0] | op[1]),                 // rename_valid (~75%)
                  (op >> 2) & (NARCH-1),           // rs1
                  (op >> 6) & (NARCH-1),           // rs2
                  (op >> 10) & (NARCH-1),          // rd
                  op[13],                          // has_rd
                  take_free, fp );
        end

        $display("Phase 2 (randomised) done: %0d total checks, %0d errors",
                 checks, errors);

        // ---- verdict ----
        if (errors == 0)
            $display("RESULT: *** PASS *** (%0d assertions)", checks);
        else
            $display("RESULT: *** FAIL *** (%0d errors / %0d assertions)",
                     errors, checks);

        $finish;
    end

    // ---- global timeout ----
    initial begin
        #300000;
        $display("RESULT: *** FAIL *** (timeout)");
        $finish;
    end

endmodule
