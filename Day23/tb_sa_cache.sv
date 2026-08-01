// tb_sa_cache.sv - Day23
//
// Self-checking testbench for the N-way set-associative, write-back,
// write-allocate, tree-PLRU data cache (sa_cache.sv).
//
// Reference model: an INDEPENDENT behavioral re-implementation of the exact
// same cache (associative tag search, invalid-way-first + tree-PLRU victim,
// write-allocate + write-back to a backing memory). Both the DUT and the
// golden model are driven by the identical op stream and start from an
// identical backing memory, so on every access we compare BOTH:
//     * the load data      (cpu_rdata == golden rdata)
//     * the hit/miss result(cpu_hit   == golden hit)
// Any divergence in placement, replacement victim, dirty write-back, or
// write-allocate ordering surfaces immediately as a data or hit mismatch.
//
// Stimulus: a directed window (cold misses filling a set, a hit, a dirtying
// store, a full-set eviction whose PLRU victim is dirty -> WRITEBACK+ALLOCATE,
// then a re-read proving the flushed store survived) followed by 4000
// randomized ops over a compact address range that keeps every set and way
// under constant replacement pressure. Timeout guard + VCD dump included.

`timescale 1ns/1ps

module tb_sa_cache;

    // ---- design parameters (kept small to force heavy thrashing) ----
    localparam int ADDR_BITS   = 12;
    localparam int WORD_BITS   = 32;
    localparam int BLOCK_WORDS = 4;
    localparam int NUM_SETS    = 4;
    localparam int WAYS        = 4;

    localparam int OFFSET_BITS = $clog2(BLOCK_WORDS);
    localparam int INDEX_BITS  = $clog2(NUM_SETS);
    localparam int WAY_BITS    = $clog2(WAYS);
    localparam int TAG_BITS    = ADDR_BITS - INDEX_BITS - OFFSET_BITS;
    localparam int MEMWORDS    = (1 << ADDR_BITS);

    // ---- DUT I/O ----
    logic                 clk, rst_n;
    logic                 cpu_req, cpu_we;
    logic [ADDR_BITS-1:0] cpu_addr;
    logic [WORD_BITS-1:0] cpu_wdata, cpu_rdata;
    logic                 cpu_ready, cpu_hit;

    logic                 mem_req, mem_we;
    logic [ADDR_BITS-1:0] mem_addr;
    logic [WORD_BITS-1:0] mem_wdata, mem_rdata;
    logic                 mem_ready;

    logic [1:0]           dbg_state;
    logic [7:0]           dbg_way;

    sa_cache #(
        .ADDR_BITS(ADDR_BITS), .WORD_BITS(WORD_BITS),
        .BLOCK_WORDS(BLOCK_WORDS), .NUM_SETS(NUM_SETS), .WAYS(WAYS)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .cpu_req(cpu_req), .cpu_we(cpu_we), .cpu_addr(cpu_addr),
        .cpu_wdata(cpu_wdata), .cpu_rdata(cpu_rdata),
        .cpu_ready(cpu_ready), .cpu_hit(cpu_hit),
        .mem_req(mem_req), .mem_we(mem_we), .mem_addr(mem_addr),
        .mem_wdata(mem_wdata), .mem_rdata(mem_rdata), .mem_ready(mem_ready),
        .dbg_state(dbg_state), .dbg_way(dbg_way)
    );

    // ---- clock ----
    initial clk = 1'b0;
    always #5 clk = ~clk;   // 100 MHz, 1 clk = 10 ns

    // ================= DUT-side main memory (always ready) =================
    logic [WORD_BITS-1:0] tb_mem [0:MEMWORDS-1];
    assign mem_ready = mem_req;                       // single-cycle memory
    assign mem_rdata = tb_mem[mem_addr];              // combinational read
    always_ff @(posedge clk) begin                    // registered write-back
        if (mem_req && mem_we) tb_mem[mem_addr] <= mem_wdata;
    end

    // ================= golden reference cache + memory =================
    logic                 g_valid [NUM_SETS][WAYS];
    logic                 g_dirty [NUM_SETS][WAYS];
    logic [TAG_BITS-1:0]  g_tag   [NUM_SETS][WAYS];
    logic [WORD_BITS-1:0] g_data  [NUM_SETS][WAYS][BLOCK_WORDS];
    logic [WAYS-2:0]      g_plru  [NUM_SETS];
    logic [WORD_BITS-1:0] g_mem   [0:MEMWORDS-1];

    // golden tree-PLRU (independent re-implementation of the DUT's policy)
    function automatic logic [WAY_BITS-1:0] gt_victim(input logic [WAYS-2:0] tr);
        int node; logic [WAY_BITS-1:0] w; logic b;
        node = 0; w = '0;
        for (int lvl = 0; lvl < WAY_BITS; lvl++) begin
            b    = tr[node];
            w    = (w << 1) | b;
            node = 2*node + 1 + (b ? 1 : 0);
        end
        return w;
    endfunction

    function automatic logic [WAYS-2:0] gt_touch(input logic [WAYS-2:0] tr,
                                                 input logic [WAY_BITS-1:0] w);
        int node; logic b; logic [WAYS-2:0] nt;
        nt = tr; node = 0;
        for (int lvl = 0; lvl < WAY_BITS; lvl++) begin
            b        = w[WAY_BITS-1-lvl];
            nt[node] = ~b;
            node     = 2*node + 1 + (b ? 1 : 0);
        end
        return nt;
    endfunction

    function automatic logic [ADDR_BITS-1:0] gbase(input int idx,
                                                   input logic [TAG_BITS-1:0] t);
        logic [ADDR_BITS-1:0] a;
        a = '0;
        a[OFFSET_BITS +: INDEX_BITS]          = idx[INDEX_BITS-1:0];
        a[OFFSET_BITS+INDEX_BITS +: TAG_BITS] = t;
        return a;
    endfunction

    // Reference access: returns predicted rdata + hit, updates golden state.
    task automatic golden_access(input  logic                 we,
                                 input  logic [ADDR_BITS-1:0] a,
                                 input  logic [WORD_BITS-1:0] d,
                                 output logic [WORD_BITS-1:0] rd,
                                 output logic                 ht);
        int off, idx, hw, vic;
        logic [TAG_BITS-1:0]  tg;
        logic                 found;
        logic [ADDR_BITS-1:0] base;
        off = a[OFFSET_BITS-1:0];
        idx = a[OFFSET_BITS +: INDEX_BITS];
        tg  = a[OFFSET_BITS+INDEX_BITS +: TAG_BITS];
        rd  = '0;

        found = 1'b0; hw = 0;
        for (int w = 0; w < WAYS; w++)
            if (g_valid[idx][w] && (g_tag[idx][w] == tg)) begin found = 1'b1; hw = w; end

        if (found) begin
            ht = 1'b1;
            if (we) begin g_data[idx][hw][off] = d; g_dirty[idx][hw] = 1'b1; end
            else          rd = g_data[idx][hw][off];
            g_plru[idx] = gt_touch(g_plru[idx], hw[WAY_BITS-1:0]);
        end else begin
            ht  = 1'b0;
            vic = -1;
            for (int w = 0; w < WAYS; w++)
                if (!g_valid[idx][w] && (vic < 0)) vic = w;
            if (vic < 0) vic = gt_victim(g_plru[idx]);
            if (g_valid[idx][vic] && g_dirty[idx][vic]) begin      // flush dirty victim
                base = gbase(idx, g_tag[idx][vic]);
                for (int k = 0; k < BLOCK_WORDS; k++) g_mem[base+k] = g_data[idx][vic][k];
            end
            base = gbase(idx, tg);                                 // refill
            for (int k = 0; k < BLOCK_WORDS; k++) g_data[idx][vic][k] = g_mem[base+k];
            g_tag[idx][vic] = tg; g_valid[idx][vic] = 1'b1; g_dirty[idx][vic] = 1'b0;
            if (we) begin g_data[idx][vic][off] = d; g_dirty[idx][vic] = 1'b1; end
            else          rd = g_data[idx][vic][off];
            g_plru[idx] = gt_touch(g_plru[idx], vic[WAY_BITS-1:0]);
        end
    endtask

    // ================= scoreboard =================
    integer errors = 0;
    integer checks = 0;

    // Drive one CPU access on the DUT and check it against the golden model.
    task automatic do_access(input logic we, input logic [ADDR_BITS-1:0] a,
                             input logic [WORD_BITS-1:0] d, input string tag);
        logic [WORD_BITS-1:0] exp_rd, got_rd;
        logic                 exp_ht, got_ht;

        golden_access(we, a, d, exp_rd, exp_ht);   // predict first (own state)

        @(posedge clk);
        cpu_req   <= 1'b1; cpu_we <= we; cpu_addr <= a; cpu_wdata <= d;
        @(posedge clk);
        cpu_req   <= 1'b0;
        while (cpu_ready !== 1'b1) @(posedge clk); // wait for completion pulse
        got_rd = cpu_rdata; got_ht = cpu_hit;

        // continuous lockstep invariant: DUT internal state must match golden
        for (int s = 0; s < NUM_SETS; s++)
            for (int w = 0; w < WAYS; w++)
                if (dut.valid[s][w] !== g_valid[s][w] ||
                    (g_valid[s][w] && dut.tag_a[s][w] !== g_tag[s][w]) ||
                    dut.dirty[s][w] !== g_dirty[s][w]) begin
                    errors++;
                    $display("  [STATE %0t] set%0d way%0d dut(v%0b t%0d d%0b) gold(v%0b t%0d d%0b)",
                             $time, s, w, dut.valid[s][w], dut.tag_a[s][w], dut.dirty[s][w],
                             g_valid[s][w], g_tag[s][w], g_dirty[s][w]);
                end

        checks++;
        if (got_ht !== exp_ht) begin
            errors++;
            $display("  [FAIL %0t] %-10s %s addr=%0d  hit dut=%0b exp=%0b",
                     $time, tag, we ? "ST" : "LD", a, got_ht, exp_ht);
            begin
                int sidx; sidx = a[OFFSET_BITS +: INDEX_BITS];
                $display("    set %0d  DUT plru=%b   GOLD plru=%b", sidx,
                         dut.plru[sidx], g_plru[sidx]);
                for (int w = 0; w < WAYS; w++)
                    $display("     way%0d  DUT v=%0b tag=%0d d=%0b | GOLD v=%0b tag=%0d d=%0b",
                             w, dut.valid[sidx][w], dut.tag_a[sidx][w], dut.dirty[sidx][w],
                             g_valid[sidx][w], g_tag[sidx][w], g_dirty[sidx][w]);
            end
        end
        if (!we && (got_rd !== exp_rd)) begin
            errors++;
            $display("  [FAIL %0t] %-10s LD addr=%0d  data dut=%08x exp=%08x",
                     $time, tag, a, got_rd, exp_rd);
        end
    endtask

    // ================= stimulus =================
    integer i;
    logic [ADDR_BITS-1:0] ra;
    logic                 rwe;
    logic [WORD_BITS-1:0] rd;

    initial begin
        $dumpfile("sa_cache.vcd");
        $dumpvars(0, tb_sa_cache);

        // init both backing memories identically (deterministic pattern)
        for (i = 0; i < MEMWORDS; i++) begin
            tb_mem[i] = 32'hA0000000 | i[ADDR_BITS-1:0];
            g_mem[i]  = 32'hA0000000 | i[ADDR_BITS-1:0];
        end
        // init golden cache to the DUT's reset state (all invalid, plru=0)
        for (int s = 0; s < NUM_SETS; s++) begin
            g_plru[s] = '0;
            for (int w = 0; w < WAYS; w++) begin
                g_valid[s][w] = 1'b0;
                g_dirty[s][w] = 1'b0;
                g_tag[s][w]   = '0;
            end
        end

        // reset
        cpu_req = 0; cpu_we = 0; cpu_addr = 0; cpu_wdata = 0;
        rst_n = 0;
        repeat (3) @(posedge clk);
        rst_n = 1;
        @(posedge clk);

        // ---------- DIRECTED WINDOW (drives the waveform) ----------
        // All addresses below map to SET 0 (addr[3:2]==0); tags differ by 16.
        do_access(1'b0, 12'd0,  32'd0,          "cold-miss");  // LD 0  -> ALLOC way0
        do_access(1'b0, 12'd1,  32'd0,          "hit");        // LD 1  -> HIT (same blk)
        do_access(1'b1, 12'd2,  32'hDEAD_BEEF,  "store-hit");  // ST 2  -> HIT, dirties way0
        do_access(1'b0, 12'd16, 32'd0,          "miss-fill");  // LD 16 -> ALLOC way1
        do_access(1'b0, 12'd32, 32'd0,          "miss-fill");  // LD 32 -> ALLOC way2
        do_access(1'b0, 12'd48, 32'd0,          "miss-fill");  // LD 48 -> ALLOC way3 (set full)
        do_access(1'b0, 12'd64, 32'd0,          "evict-dirty");// LD 64 -> victim way0 DIRTY: WB+ALLOC
        do_access(1'b0, 12'd2,  32'd0,          "refetch");    // LD 2  -> re-fetch tag0: sees DEADBEEF
        $display("  directed window done at %0t ns", $time);

        // ---------- RANDOMIZED STRESS ----------
        // Compact address range [0,255]: 4 sets x 16 tags -> constant eviction.
        for (i = 0; i < 4000; i++) begin
            ra  = {$random} % 256;
            rwe = {$random} & 32'h1;
            rd  = $random;
            do_access(rwe, ra, rd, "rand");
        end

        // ---------- verdict ----------
        $display("--------------------------------------------------");
        $display("  checks: %0d   errors: %0d", checks, errors);
        if (errors == 0)
            $display("RESULT: *** PASS ***");
        else
            $display("RESULT: *** FAIL *** (%0d mismatches)", errors);
        $display("--------------------------------------------------");
        $finish;
    end

    // ================= timeout guard =================
    initial begin
        #2_000_000; // 2 ms hard cap
        $display("RESULT: *** FAIL *** (timeout)");
        $finish;
    end

endmodule
