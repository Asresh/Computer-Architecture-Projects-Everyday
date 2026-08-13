// tb_smem_bank_conflict_unit.sv
// -----------------------------------------------------------------------------
// Self-checking testbench for the Day16 GPU shared-memory bank-conflict unit.
//
// The golden reference is computed with a DIFFERENT algorithm than the DUT:
// for every bank it builds, in first-appearance order, the list of distinct
// words requested in that bank (a fixed NBANKS x NLANES buffer, no queues). A
// lane's phase is 1 + its position in its bank's distinct-word list; the warp
// phase count is the longest such list, n_unique is the total number of
// distinct words, and broadcast lanes are the active lanes that are not the
// first requester of their word. This is a clean independent model of shared-
// memory bank arbitration, not a copy of the RTL's leader/rank formulation.
//
// Stimulus = directed corner cases (conflict-free stride, N-way conflict,
// full broadcast, partial mask, mixed conflict+broadcast, empty warp, 2-way,
// single lane) plus a large randomized campaign. Every response field is
// checked. A cycle watchdog aborts on hang. Prints "RESULT: *** PASS ***"
// only if all checks pass.
//
// (Icarus cannot pass unpacked arrays to subroutines, so stimulus, expected
//  values and golden scratch all live at module scope.)
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

module tb_smem_bank_conflict_unit;

    localparam int NLANES = 8;
    localparam int NBANKS = 8;   // power of two: bank = word mod NBANKS = low bits
    localparam int ADDR_W = 32;
    localparam int BYTES  = 4;
    localparam int BANK_W = (NBANKS > 1) ? $clog2(NBANKS) : 1;
    localparam int PH_W   = $clog2(NLANES + 1);
    localparam int CNT_W  = $clog2(NLANES + 1);
    localparam int OFFB   = (BYTES > 1) ? $clog2(BYTES) : 0;

    // ---- DUT I/O ----
    logic                    clk, rst_n;
    logic                    req_valid;
    logic [NLANES-1:0]       lane_active;
    logic [ADDR_W-1:0]       lane_addr [NLANES];

    logic                    resp_valid;
    logic [PH_W-1:0]         n_phases;
    logic                    conflict;
    logic [CNT_W-1:0]        n_active, n_unique, n_bcast;
    logic [PH_W-1:0]         lane_phase [NLANES];
    logic [BANK_W-1:0]       lane_bank  [NLANES];
    logic [NLANES-1:0]       lane_leader;

    smem_bank_conflict_unit #(
        .NLANES(NLANES), .NBANKS(NBANKS), .ADDR_W(ADDR_W), .BYTES(BYTES)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .req_valid(req_valid), .lane_active(lane_active), .lane_addr(lane_addr),
        .resp_valid(resp_valid), .n_phases(n_phases), .conflict(conflict),
        .n_active(n_active), .n_unique(n_unique), .n_bcast(n_bcast),
        .lane_phase(lane_phase), .lane_bank(lane_bank), .lane_leader(lane_leader)
    );

    // ---- clock ----
    initial clk = 1'b0;
    always #5 clk = ~clk;

    // ---- watchdog ----
    initial begin
        repeat (200000) @(posedge clk);
        $display("RESULT: *** FAIL *** (timeout / watchdog)");
        $fatal(1, "watchdog");
    end

    integer errors = 0;
    integer checks = 0;

    // ---- module-scope stimulus ----
    logic [NLANES-1:0]  q_active;
    logic [ADDR_W-1:0]  q_addr [NLANES];

    // ---- module-scope expected values (golden) ----
    int                 e_nphases, e_active, e_unique, e_bcast;
    int                 e_phase [NLANES];
    int                 e_bank  [NLANES];
    logic [NLANES-1:0]  e_leader;

    // ---- golden scratch: per-bank distinct-word list (fixed buffer) ----
    logic [ADDR_W-1:0]  bw  [NBANKS][NLANES]; // distinct words seen, in order
    int                 bwc [NBANKS];         // count of distinct words per bank

    // ------------------------------------------------------------------
    // Independent golden model, over q_active / q_addr -> e_* outputs.
    // ------------------------------------------------------------------
    task automatic golden;
        logic [ADDR_W-1:0] w;
        int b, k, pos;
        logic found;
        begin
            for (b = 0; b < NBANKS; b++) bwc[b] = 0;
            e_active = 0; e_unique = 0; e_bcast = 0; e_leader = '0;

            // build per-bank distinct-word lists in lane order
            for (int i = 0; i < NLANES; i++) begin
                e_phase[i] = 0;
                w          = q_addr[i] >> OFFB;
                b          = int'(w % NBANKS);
                e_bank[i]  = b;
                if (q_active[i]) begin
                    e_active++;
                    found = 1'b0;
                    for (k = 0; k < bwc[b]; k++)
                        if (bw[b][k] == w) found = 1'b1;
                    if (!found) begin
                        bw[b][bwc[b]] = w;   // new distinct word slot
                        bwc[b]        = bwc[b] + 1;
                    end
                end
            end

            // phase per lane = 1 + index of its word in its bank list;
            // leader = first active lane presenting that word.
            for (int i = 0; i < NLANES; i++) begin
                if (q_active[i]) begin
                    w   = q_addr[i] >> OFFB;
                    b   = int'(w % NBANKS);
                    pos = -1;
                    for (k = 0; k < bwc[b]; k++)
                        if (bw[b][k] == w) pos = k;
                    e_phase[i]  = pos + 1;
                    e_leader[i] = 1'b1;
                    for (int j = 0; j < i; j++)
                        if (q_active[j] && ((q_addr[j] >> OFFB) == w))
                            e_leader[i] = 1'b0;
                end
            end

            // warp-level aggregates
            e_nphases = 0;
            for (b = 0; b < NBANKS; b++)
                if (bwc[b] > e_nphases) e_nphases = bwc[b];
            for (int i = 0; i < NLANES; i++) if (e_leader[i]) e_unique++;
            e_bcast = e_active - e_unique;
        end
    endtask

    // ------------------------------------------------------------------
    // Drive one warp request (from q_*) and check the registered response.
    // ------------------------------------------------------------------
    task automatic run(input string tag);
        begin
            golden();

            @(negedge clk);
            req_valid   = 1'b1;
            lane_active = q_active;
            for (int i = 0; i < NLANES; i++) lane_addr[i] = q_addr[i];
            @(negedge clk);
            req_valid   = 1'b0;
            lane_active = '0;
            for (int i = 0; i < NLANES; i++) lane_addr[i] = '0;

            // response is now registered (sampled after the intervening posedge)
            checks++;
            if (!resp_valid) begin
                errors++; $display("  [%0s] FAIL resp_valid low", tag); end
            if (n_phases !== e_nphases[PH_W-1:0]) begin
                errors++; $display("  [%0s] FAIL n_phases got=%0d exp=%0d",
                                   tag, n_phases, e_nphases); end
            if (conflict !== (e_nphases > 1)) begin
                errors++; $display("  [%0s] FAIL conflict got=%0b exp=%0b",
                                   tag, conflict, (e_nphases > 1)); end
            if (n_active !== e_active[CNT_W-1:0]) begin
                errors++; $display("  [%0s] FAIL n_active got=%0d exp=%0d",
                                   tag, n_active, e_active); end
            if (n_unique !== e_unique[CNT_W-1:0]) begin
                errors++; $display("  [%0s] FAIL n_unique got=%0d exp=%0d",
                                   tag, n_unique, e_unique); end
            if (n_bcast !== e_bcast[CNT_W-1:0]) begin
                errors++; $display("  [%0s] FAIL n_bcast got=%0d exp=%0d",
                                   tag, n_bcast, e_bcast); end
            if (lane_leader !== e_leader) begin
                errors++; $display("  [%0s] FAIL lane_leader got=%b exp=%b",
                                   tag, lane_leader, e_leader); end
            for (int i = 0; i < NLANES; i++) begin
                if (lane_phase[i] !== e_phase[i][PH_W-1:0]) begin
                    errors++; $display("  [%0s] FAIL lane_phase[%0d] got=%0d exp=%0d",
                                       tag, i, lane_phase[i], e_phase[i]); end
                if (q_active[i] && (lane_bank[i] !== e_bank[i][BANK_W-1:0])) begin
                    errors++; $display("  [%0s] FAIL lane_bank[%0d] got=%0d exp=%0d",
                                       tag, i, lane_bank[i], e_bank[i]); end
            end
        end
    endtask

    // set q_addr[i] = base + i*stride_words*BYTES (module-scope write)
    task automatic mk_stride(input logic [ADDR_W-1:0] base, input int stride_words);
        for (int i = 0; i < NLANES; i++)
            q_addr[i] = base + i * stride_words * BYTES;
    endtask

    initial begin
        $dumpfile("smem_bank_conflict_unit.vcd");
        $dumpvars(0, tb_smem_bank_conflict_unit);

        req_valid   = 1'b0;
        lane_active = '0;
        for (int i = 0; i < NLANES; i++) lane_addr[i] = '0;
        rst_n = 1'b0;
        repeat (3) @(negedge clk);
        rst_n = 1'b1;
        @(negedge clk);

        $display("Day16 - GPU shared-memory bank-conflict unit: directed tests");

        // 1) conflict-free: lane i -> word i -> bank i (stride 1) => 1 phase
        mk_stride(32'h0000_1000, 1); q_active = '1;
        run("cfree-stride1");

        // 2) N-way conflict: same bank, distinct words (stride NBANKS) => NLANES phases
        mk_stride(32'h0000_2000, NBANKS); q_active = '1;
        run("Nway-conflict");

        // 3) full broadcast: all lanes same address => 1 unique word, 1 phase
        for (int i = 0; i < NLANES; i++) q_addr[i] = 32'h0000_3040;
        q_active = '1;
        run("broadcast-all");

        // 4) partial mask: even lanes active, stride 1 => distinct banks, 1 phase
        mk_stride(32'h0000_4000, 1);
        q_active = 8'b0101_0101;
        run("even-mask");

        // 5) 2-way conflict: stride NBANKS/4 -> banks cycle {0,2,4,6}, so each
        //    of those 4 banks is hit by 2 lanes wanting different words => 2 phases
        mk_stride(32'h0000_5000, NBANKS/4); q_active = '1;
        run("2way-conflict");

        // 6) mixed: lanes 0..3 -> word A (bank 0, broadcast); lanes 4..7 -> four
        //    more distinct words in bank 0 (stride NBANKS). Bank 0 holds 5
        //    distinct words => 5 phases; the four broadcasters share phase 1.
        q_addr[0] = 32'h0000_6000; q_addr[1] = 32'h0000_6000;
        q_addr[2] = 32'h0000_6000; q_addr[3] = 32'h0000_6000;
        q_addr[4] = 32'h0000_6000 + 1*NBANKS*BYTES;
        q_addr[5] = 32'h0000_6000 + 2*NBANKS*BYTES;
        q_addr[6] = 32'h0000_6000 + 3*NBANKS*BYTES;
        q_addr[7] = 32'h0000_6000 + 4*NBANKS*BYTES;
        q_active = '1;
        run("mixed-bcast+conf");

        // 7) empty warp: no active lanes => 0 phases, no conflict
        for (int i = 0; i < NLANES; i++) q_addr[i] = 32'h0000_7000;
        q_active = '0;
        run("empty-warp");

        // 8) single active lane => 1 phase, no conflict
        mk_stride(32'h0000_8000, 3);
        q_active = 8'b0010_0000;
        run("single-lane");

        // ---- randomized campaign ----
        $display("Day16 - randomized campaign (2000 warps)");
        for (int t = 0; t < 2000; t++) begin
            q_active = $random;
            for (int i = 0; i < NLANES; i++)
                // narrow, byte-aligned address span so conflicts & broadcasts
                // occur often (words 0..15)
                q_addr[i] = ($random & 32'h0000_003C);
            run("rand");
        end

        $display("checks=%0d errors=%0d", checks, errors);
        if (errors == 0)
            $display("RESULT: *** PASS ***");
        else
            $display("RESULT: *** FAIL *** (%0d mismatches)", errors);
        $finish;
    end

endmodule
