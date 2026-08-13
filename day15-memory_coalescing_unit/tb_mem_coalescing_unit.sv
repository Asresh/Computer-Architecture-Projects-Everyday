// ============================================================================
// tb_mem_coalescing_unit.sv - self-checking testbench for the GPU memory
// coalescing unit.
//
// An independent behavioral golden model recomputes, for the same warp request,
// the set of unique aligned segments, the leader lane of each, and the coalesced
// lane membership of each transaction. The DUT's registered response one cycle
// later is compared field-by-field. Covers directed corner cases (fully
// coalesced / fully scattered / stride patterns / masked-off lanes / broadcast /
// empty warp) plus a randomized stress stream. Dumps a VCD and prints
// RESULT: *** PASS ***.
// ============================================================================
`timescale 1ns/1ps
module tb_mem_coalescing_unit;

    localparam int NLANES     = 8;
    localparam int ADDR_WIDTH = 32;
    localparam int LINE_BYTES  = 32;
    localparam int OFFB        = $clog2(LINE_BYTES);
    localparam int SEGW        = ADDR_WIDTH - OFFB;
    localparam int CNTW        = $clog2(NLANES+1);

    logic                    clk, rst_n;
    logic                    req_valid;
    logic [NLANES-1:0]       active_mask;
    logic [ADDR_WIDTH-1:0]   lane_addr [NLANES];

    logic                    resp_valid;
    logic [NLANES-1:0]       leader_mask;
    logic [CNTW-1:0]         n_txn, n_active;
    logic [ADDR_WIDTH-1:0]   txn_base  [NLANES];
    logic [NLANES-1:0]       txn_lanes [NLANES];

    integer errors = 0;
    integer checks = 0;

    // ---------------- DUT ----------------
    mem_coalescing_unit #(
        .NLANES(NLANES), .ADDR_WIDTH(ADDR_WIDTH), .LINE_BYTES(LINE_BYTES)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .req_valid(req_valid), .active_mask(active_mask), .lane_addr(lane_addr),
        .resp_valid(resp_valid), .leader_mask(leader_mask),
        .n_txn(n_txn), .n_active(n_active),
        .txn_base(txn_base), .txn_lanes(txn_lanes)
    );

    // ---------------- clock ----------------
    initial clk = 1'b0;
    always #5 clk = ~clk;

    // ---------------- golden reference ----------------
    function automatic [SEGW-1:0] gseg(input [ADDR_WIDTH-1:0] a);
        gseg = a[ADDR_WIDTH-1:OFFB];
    endfunction

    // ---------------- scoreboard ----------------
    // Mirror the DUT's own 1-cycle request register so the expected request is
    // aligned in time with the registered response. r_valid tracks resp_valid
    // exactly; r_mask/r_addr hold the request that produced the response now
    // visible on the DUT outputs.
    logic [NLANES-1:0]     r_mask;
    logic [ADDR_WIDTH-1:0] r_addr [NLANES];
    logic                  r_valid;
    integer                mk;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            r_valid <= 1'b0;
            r_mask  <= '0;
        end else begin
            r_valid <= req_valid;
            if (req_valid) begin
                r_mask <= active_mask;
                for (mk = 0; mk < NLANES; mk++) r_addr[mk] <= lane_addr[mk];
            end
        end
    end

    task automatic check_response;
        logic [NLANES-1:0]     exp_leader;
        logic [CNTW-1:0]       exp_nactive, exp_ntxn;
        logic [NLANES-1:0]     exp_members [NLANES];
        logic [ADDR_WIDTH-1:0] exp_base;
        int i, j;
        begin
            exp_leader  = '0;
            exp_nactive = '0;
            exp_ntxn    = '0;
            for (i = 0; i < NLANES; i++) exp_members[i] = '0;

            for (i = 0; i < NLANES; i++) begin
                if (r_mask[i]) exp_nactive++;
            end
            for (i = 0; i < NLANES; i++) begin
                if (r_mask[i]) begin
                    logic lead;
                    lead = 1'b1;
                    for (j = 0; j < NLANES; j++) begin
                        if (r_mask[j] && (gseg(r_addr[j]) == gseg(r_addr[i]))) begin
                            exp_members[i][j] = 1'b1;
                            if (j < i) lead = 1'b0;
                        end
                    end
                    if (lead) begin
                        exp_leader[i] = 1'b1;
                        exp_ntxn++;
                    end
                end
            end

            checks++;
            if (n_active !== exp_nactive) begin
                errors++;
                $display("[%0t] FAIL n_active: got %0d exp %0d", $time, n_active, exp_nactive);
            end
            if (n_txn !== exp_ntxn) begin
                errors++;
                $display("[%0t] FAIL n_txn: got %0d exp %0d", $time, n_txn, exp_ntxn);
            end
            if (leader_mask !== exp_leader) begin
                errors++;
                $display("[%0t] FAIL leader_mask: got %b exp %b", $time, leader_mask, exp_leader);
            end
            for (i = 0; i < NLANES; i++) begin
                if (exp_leader[i]) begin
                    exp_base = {gseg(r_addr[i]), {OFFB{1'b0}}};
                    if (txn_base[i] !== exp_base) begin
                        errors++;
                        $display("[%0t] FAIL txn_base[%0d]: got %h exp %h", $time, i, txn_base[i], exp_base);
                    end
                    if (txn_lanes[i] !== exp_members[i]) begin
                        errors++;
                        $display("[%0t] FAIL txn_lanes[%0d]: got %b exp %b", $time, i, txn_lanes[i], exp_members[i]);
                    end
                end
            end
        end
    endtask

    // check registered responses as they come out
    always @(posedge clk) begin
        if (rst_n && resp_valid) begin
            check_response();
        end
    end

    // ---------------- test program ----------------
    // Requests are staged into the module-level `a[]` array before each drive()
    // (Icarus does not support unpacked-array subroutine ports).
    logic [ADDR_WIDTH-1:0] a [NLANES];
    integer t, i;
    integer seed = 32'hC0FFEE15;

    // ---------------- stimulus driver ----------------
    task automatic drive(input logic [NLANES-1:0] mask);
        int k;
        begin
            @(negedge clk);
            req_valid   = 1'b1;
            active_mask = mask;
            for (k = 0; k < NLANES; k++) lane_addr[k] = a[k];
            @(negedge clk);          // request captured on the intervening posedge;
            req_valid   = 1'b0;      // response + mirror appear on the next posedge
            active_mask = '0;
        end
    endtask

    initial begin
        $dumpfile("mem_coalescing_unit.vcd");
        $dumpvars(0, tb_mem_coalescing_unit);

        req_valid = 0; active_mask = 0;
        for (i = 0; i < NLANES; i++) lane_addr[i] = '0;
        rst_n = 0;
        repeat (3) @(negedge clk);
        rst_n = 1;
        @(negedge clk);

        // --- Directed 1: perfectly coalesced. Consecutive words in one 32B line
        //     (lane k -> base + 4*k) => all 8 lanes in ONE transaction.
        for (i = 0; i < NLANES; i++) a[i] = 32'h1000_0000 + i*4;
        drive('1);

        // --- Directed 2: fully scattered. Each lane in its own 32B segment
        //     (stride == LINE_BYTES) => 8 transactions, no coalescing.
        for (i = 0; i < NLANES; i++) a[i] = 32'h2000_0000 + i*LINE_BYTES;
        drive('1);

        // --- Directed 3: two segments. lanes 0..3 in line A, 4..7 in line B.
        for (i = 0; i < NLANES; i++)
            a[i] = (i < 4) ? (32'h3000_0000 + i*4)
                           : (32'h3000_0040 + (i-4)*4);
        drive('1);

        // --- Directed 4: masked-off lanes. Only even lanes active; line-aligned
        //     base + word stride keeps all active lanes in one 32B line => 1 txn.
        for (i = 0; i < NLANES; i++) a[i] = 32'h4000_0000 + i*4;
        drive(8'b0101_0101);

        // --- Directed 5: broadcast. Every lane hits the SAME address => 1 txn.
        for (i = 0; i < NLANES; i++) a[i] = 32'h5000_0020;
        drive('1);

        // --- Directed 6: empty warp (no active lanes) => 0 transactions.
        for (i = 0; i < NLANES; i++) a[i] = 32'h6000_0000 + i*4;
        drive('0);

        // --- Directed 7: strided-2 words. lane k -> base + 8*k. With a 32B line
        //     (8 words) lanes {0,1,2,3} share line 0 and {4,5,6,7} share line 1.
        for (i = 0; i < NLANES; i++) a[i] = 32'h7000_0000 + i*8;
        drive('1);

        // --- Randomized stress ---
        for (t = 0; t < 400; t++) begin
            logic [NLANES-1:0] m;
            m = $random(seed);
            for (i = 0; i < NLANES; i++) begin
                // narrow address space so random collisions/coalescing happen often
                a[i] = ($random(seed) & 32'h0000_01FF);
            end
            drive(m);
        end

        repeat (4) @(negedge clk);

        if (errors == 0)
            $display("RESULT: *** PASS *** (%0d checks, 0 mismatches)", checks);
        else
            $display("RESULT: *** FAIL *** (%0d checks, %0d mismatches)", checks, errors);
        $finish;
    end

    // ---------------- timeout ----------------
    initial begin
        #500000;
        $display("RESULT: *** FAIL *** (timeout)");
        $finish;
    end

endmodule
