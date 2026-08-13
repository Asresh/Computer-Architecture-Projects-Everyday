// tb_dm_cache.sv - Day7
//
// Self-checking testbench for the direct-mapped write-back / write-allocate
// data cache.
//
// GOLDEN MODEL -- the elegant end-to-end check for any transparent cache:
// the cache + its backing main memory must, as seen by the CPU, behave as a
// single flat coherent memory. So the reference model is just an array
// `ref_mem[]`: every CPU store updates ref_mem[addr]; every CPU load must
// return ref_mem[addr] -- no matter how many hits, misses, evictions, or
// write-backs happened underneath. If a dirty line is written back with the
// wrong data, or a refill returns the wrong block, a later load mismatches.
//
// A behavioral main memory drives the cache's mem_* port: combinational read
// (mem_rdata = main_mem[mem_addr]) and registered write on a write-back beat.
// main_mem and ref_mem start identical; they legitimately diverge while a
// dirty line lives in the cache and re-converge on write-back -- the CPU
// never sees that divergence because loads flow through the cache.
//
// Stimulus:
//   * Directed - compulsory miss + allocate, then a hit; a store hit that
//     dirties the line; a conflict miss to the SAME index/different tag that
//     forces a WRITE-BACK of the dirty victim then an allocate; and finally a
//     re-read of the evicted address proving the written-back data survived a
//     round trip through main memory.
//   * Randomized - thousands of random loads/stores over a small,
//     conflict-heavy address window; every load checked against ref_mem.
//
// Prints "RESULT: *** PASS ***" only if every check passed. Global timeout
// watchdog; dumps dm_cache.vcd.

`timescale 1ns/1ps

module tb_dm_cache;

    // ---- Geometry (kept small so main memory fits and conflicts are dense) ----
    localparam int ADDR_BITS   = 12;
    localparam int WORD_BITS   = 32;
    localparam int BLOCK_WORDS = 4;
    localparam int NUM_LINES   = 8;
    localparam int MEM_WORDS   = 1 << ADDR_BITS;

    // ---- DUT interface ----
    logic                 clk;
    logic                 rst_n;
    logic                 cpu_req;
    logic                 cpu_we;
    logic [ADDR_BITS-1:0] cpu_addr;
    logic [WORD_BITS-1:0] cpu_wdata;
    logic [WORD_BITS-1:0] cpu_rdata;
    logic                 cpu_ready;
    logic                 cpu_hit;

    logic                 mem_req;
    logic                 mem_we;
    logic [ADDR_BITS-1:0] mem_addr;
    logic [WORD_BITS-1:0] mem_wdata;
    logic [WORD_BITS-1:0] mem_rdata;
    logic                 mem_ready;
    logic [1:0]           dbg_state;

    dm_cache #(
        .ADDR_BITS(ADDR_BITS), .WORD_BITS(WORD_BITS),
        .BLOCK_WORDS(BLOCK_WORDS), .NUM_LINES(NUM_LINES)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .cpu_req(cpu_req), .cpu_we(cpu_we), .cpu_addr(cpu_addr),
        .cpu_wdata(cpu_wdata), .cpu_rdata(cpu_rdata),
        .cpu_ready(cpu_ready), .cpu_hit(cpu_hit),
        .mem_req(mem_req), .mem_we(mem_we), .mem_addr(mem_addr),
        .mem_wdata(mem_wdata), .mem_rdata(mem_rdata), .mem_ready(mem_ready),
        .dbg_state(dbg_state)
    );

    // ---- Clock ----
    initial clk = 1'b0;
    always #5 clk = ~clk;

    // ---- Behavioral main memory (always-ready, 1 word/beat) ----
    logic [WORD_BITS-1:0] main_mem [MEM_WORDS-1:0];
    assign mem_ready = mem_req;                 // single-cycle ready
    assign mem_rdata = main_mem[mem_addr];      // combinational read
    always_ff @(posedge clk) begin
        if (mem_req && mem_we)
            main_mem[mem_addr] <= mem_wdata;    // registered write-back
    end

    // ---- Golden reference: flat coherent memory ----
    logic [WORD_BITS-1:0] ref_mem [MEM_WORDS-1:0];

    // ---- Scoreboard counters ----
    integer errors;
    integer checks;
    integer hits;
    integer misses;

    // ---- One CPU access through the ready handshake ----
    task automatic do_access(input logic we,
                             input logic [ADDR_BITS-1:0] a,
                             input logic [WORD_BITS-1:0] wd,
                             output logic [WORD_BITS-1:0] rd,
                             output logic was_hit);
        begin
            @(negedge clk);
            cpu_req   <= 1'b1;
            cpu_we    <= we;
            cpu_addr  <= a;
            cpu_wdata <= wd;
            @(negedge clk);
            cpu_req   <= 1'b0;          // one-cycle request pulse (latched in IDLE)
            while (cpu_ready !== 1'b1)  // wait for completion pulse
                @(negedge clk);
            rd      = cpu_rdata;
            was_hit = cpu_hit;
        end
    endtask

    // ---- Load + check against the reference ----
    task automatic check_load(input logic [ADDR_BITS-1:0] a, input string tag);
        logic [WORD_BITS-1:0] rd;
        logic                 wh;
        begin
            do_access(1'b0, a, '0, rd, wh);
            checks = checks + 1;
            if (wh) hits = hits + 1; else misses = misses + 1;
            if (rd !== ref_mem[a]) begin
                errors = errors + 1;
                $display("  [FAIL] %-18s load  addr=%0d got=%08h exp=%08h",
                         tag, a, rd, ref_mem[a]);
            end else begin
                $display("  [ ok ] %-18s load  addr=%0d data=%08h %s",
                         tag, a, rd, wh ? "(hit)" : "(miss)");
            end
        end
    endtask

    // ---- Store (updates reference) ----
    task automatic do_store(input logic [ADDR_BITS-1:0] a,
                            input logic [WORD_BITS-1:0] wd, input string tag);
        logic [WORD_BITS-1:0] rd;
        logic                 wh;
        begin
            do_access(1'b1, a, wd, rd, wh);
            ref_mem[a] = wd;
            if (wh) hits = hits + 1; else misses = misses + 1;
            $display("  [ ok ] %-18s store addr=%0d data=%08h %s",
                     tag, a, wd, wh ? "(hit)" : "(miss)");
        end
    endtask

    integer k;
    logic [ADDR_BITS-1:0] a0, a1, a2;
    logic [WORD_BITS-1:0] rd;
    logic                 wh;

    initial begin
        $dumpfile("dm_cache.vcd");
        $dumpvars(0, tb_dm_cache);

        errors = 0; checks = 0; hits = 0; misses = 0;
        cpu_req = 0; cpu_we = 0; cpu_addr = 0; cpu_wdata = 0;

        // Initialize backing memory and reference identically.
        for (k = 0; k < MEM_WORDS; k = k + 1) begin
            main_mem[k] = 32'hD00D_0000 ^ k[WORD_BITS-1:0];
            ref_mem[k]  = main_mem[k];
        end

        // ---- Reset ----
        rst_n = 1'b0;
        repeat (3) @(negedge clk);
        rst_n = 1'b1;
        @(negedge clk);

        // Three addresses that collide on the SAME line (index) but carry
        // different tags. index = addr[OFFSET_BITS +: INDEX_BITS]; with
        // BLOCK_WORDS=4 (offset 2 bits) and NUM_LINES=8 (index 3 bits), the
        // line stride is BLOCK_WORDS*NUM_LINES = 32.
        a0 = 12'd8;             // index 2, tag 0
        a1 = 12'd8  + 12'd32;   // index 2, tag 1  (conflicts with a0)
        a2 = 12'd8  + 12'd64;   // index 2, tag 2  (conflicts with a0,a1)

        $display("=== Day7 direct-mapped write-back cache : directed tests ===");

        // Compulsory miss -> allocate, then an immediate hit.
        check_load(a0, "compulsory-miss");
        check_load(a0, "same-line-hit");

        // Store hit dirties the line.
        do_store(a0, 32'hCAFE_0001, "store-hit-dirty");
        check_load(a0, "read-back-store");

        // Conflict miss to same index, different tag: victim (a0) is dirty ->
        // WRITE-BACK then ALLOCATE.
        check_load(a1, "conflict-miss-wb");
        do_store(a1, 32'hBEEF_0002, "store-a1-dirty");

        // Second conflict evicts dirty a1 (write-back) and refills a2.
        check_load(a2, "conflict-miss-wb2");

        // Re-read a0: it was evicted long ago; its dirtied value must have
        // survived the round trip out to main memory and back.
        check_load(a0, "evicted-comeback");
        // And a1 likewise.
        check_load(a1, "evicted-comeback2");

        // ---- Randomized phase: dense conflicts over a 256-word window ----
        $display("=== randomized phase (2000 accesses over 256 words) ===");
        for (k = 0; k < 2000; k = k + 1) begin
            a0 = $urandom_range(0, 255);
            if ($urandom_range(0, 1)) begin
                do_access(1'b1, a0, $urandom, rd, wh);   // store
                ref_mem[a0] = cpu_wdata;
                if (wh) hits = hits + 1; else misses = misses + 1;
            end else begin
                do_access(1'b0, a0, '0, rd, wh);         // load
                checks = checks + 1;
                if (wh) hits = hits + 1; else misses = misses + 1;
                if (rd !== ref_mem[a0]) begin
                    errors = errors + 1;
                    $display("  [FAIL] random load addr=%0d got=%08h exp=%08h",
                             a0, rd, ref_mem[a0]);
                end
            end
        end

        // ---- Verdict ----
        $display("--------------------------------------------------------");
        $display("checks=%0d  hits=%0d  misses=%0d  errors=%0d",
                 checks, hits, misses, errors);
        if (errors == 0)
            $display("RESULT: *** PASS ***");
        else
            $display("RESULT: *** FAIL *** (%0d mismatches)", errors);
        $finish;
    end

    // ---- Timeout watchdog ----
    initial begin
        #500000;
        $display("RESULT: *** FAIL *** (timeout)");
        $finish;
    end

endmodule
